## The Cooperative Hunting game server.
##
## Forked from `Metta-AI/coworld-staghunt` `src/staghunt.nim`'s server half
## (routes, roster, websocket plumbing, the tick loop, results) and extended
## with: the two additive protocol messages (`0x90` registration, `0x91`
## plan), the LLM planning turn on its own thread, the JSON replay, the
## three legal end reasons, and the 20 s shutdown grace.
##
## staghunt's binary replay blob and its `runReplayServer` / `/client/replay`
## live-server path are DELETED, not adapted: replays here are a static wasm
## bundle and are never served by a pod.

import std/[json, locks, monotimes, os, sets, strutils, tables, times, unicode]
import mummy
import bitworld/client
import bitworld/cogame_runtime
import bitworld/protocol
import cooperative_hunting/[sim, art, frames, replay, llm, baselines]

const
  WebSocketPath = "/player"
  GlobalWebSocketPath = "/global"
  HealthzPath = "/healthz"
  UnassignedPlayerIndex = 0x7fffffff

  MsgRegister = 0x90'u8
  MsgPlan = 0x91'u8

  ## After the artifacts are written, /healthz and /global keep answering for
  ## this long before quit(0). The certification runner pings /global AFTER
  ## the player pods start and a fast exit fails the episode (lantern 0.1.3).
  ShutdownGraceSeconds = 20

type
  Registration = object
    kind: PolicyKind
    prompt: string
    baseline: string

  Seat = object
    slot: int
    name: string
    alias: string
    kind: PolicyKind
    prompt: string
    baseline: string
    connected: bool
    disconnected: bool
    note: string
    lastPlan: Plan
    skipNextTurn: bool
    fallbacks: int

  WebSocketAppState = object
    lock: Lock
    config: GameConfig
    inputMasks: Table[WebSocket, uint8]
    playerSlots: Table[WebSocket, int]
    playerNames: Table[WebSocket, string]
    playerTokens: Table[WebSocket, string]
    playerIndices: Table[WebSocket, int]
    playerStates: Table[WebSocket, ViewerState]
    registrations: Table[WebSocket, Registration]
    globalViewers: HashSet[WebSocket]
    globalStates: Table[WebSocket, ViewerState]
    closedSockets: seq[WebSocket]

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

var appState: WebSocketAppState

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

proc playerNameOf(node: JsonNode): string =
  ## `players[]` entries are `{"name": "..."}` objects in the manifest; a
  ## bare string is accepted too so a hand-written config still works.
  if node.kind == JString: node.getStr()
  elif node.kind == JObject: node{"name"}.getStr()
  else: ""

proc parseGameConfig*(jsonStr: string): GameConfig =
  result = defaultGameConfig()
  if jsonStr.len == 0:
    return
  let node = parseJson(jsonStr)
  template intField(key: string, target: untyped) =
    if node.hasKey(key):
      target = node[key].getInt(target)
  intField("num_agents", result.numAgents)
  intField("seed", result.seed)
  intField("rounds", result.rounds)
  intField("ticksPerRound", result.ticksPerRound)
  intField("tickHz", result.tickHz)
  intField("planIntervalTicks", result.planIntervalTicks)
  intField("planTimeoutSeconds", result.planTimeoutSeconds)
  intField("playBudgetSeconds", result.playBudgetSeconds)
  intField("player_connect_timeout_seconds",
    result.playerConnectTimeoutSeconds)
  intField("maxOutputTokens", result.maxOutputTokens)
  if node.hasKey("variant"):
    let variant = node["variant"].getStr(result.variant)
    if isKnownVariant(variant):
      result.variant = variant
  if node.hasKey("model"):
    result.model = node["model"].getStr(result.model)
  if node.hasKey("focus"):
    result.focusElephant = node["focus"].getStr("") == "elephant"
  if node.hasKey("tokens"):
    for item in node["tokens"]:
      result.tokens.add(item.getStr(""))
    for t in result.tokens:
      if t.len > 0:
        result.closedRoster = true
        break
  if node.hasKey("players"):
    for item in node["players"]:
      result.players.add(runeCap(playerNameOf(item), MaxNameRunes))
  result.numAgents = max(1, result.numAgents)
  result.rounds = max(1, result.rounds)
  result.ticksPerRound = max(1, result.ticksPerRound)
  result.tickHz = max(1, result.tickHz)

# ---------------------------------------------------------------------------
# The LLM planning thread. The sim only ever POLLS a result slot: nothing in
# the tick loop blocks on a network read.
# ---------------------------------------------------------------------------

var planRequests: Channel[string]
var planReplies: Channel[string]
var llmThread: Thread[GameConfig]
var llmThreadRunning = false

proc llmWorker(config: GameConfig) {.thread.} =
  let client = newLlmClient(config)
  while true:
    let raw = planRequests.recv()
    if raw == "quit":
      break
    var reply = %*{"turn": 0, "plans": newJArray()}
    try:
      let request = parseJson(raw)
      let turn = request{"turn"}.getInt()
      var aliases: seq[string] = @[]
      for entry in request{"aliases"}:
        aliases.add(entry.getStr())
      var requests: seq[PlanRequest] = @[]
      var legal: seq[seq[string]] = @[]
      for entry in request{"seats"}:
        requests.add(PlanRequest(
          slot: entry{"slot"}.getInt(),
          system: entry{"system"}.getStr(),
          user: entry{"user"}.getStr()
        ))
        var targets: seq[string] = @[]
        for target in entry{"legal"}:
          targets.add(target.getStr())
        legal.add(targets)
      let replies = client.runPlanBatch(requests, legal, aliases, turn)
      var plans = newJArray()
      for r in replies:
        var partners = newJArray()
        for p in r.plan.partners:
          partners.add(%p)
        plans.add(%*{
          "slot": r.slot,
          "ok": r.ok,
          "cause": $r.cause,
          "intent": r.plan.intent,
          "target": r.plan.target,
          "side": r.plan.side,
          "with": partners,
          "say": r.plan.say,
          "note": r.plan.note
        })
      reply = %*{
        "turn": turn,
        "plans": plans,
        "requests": client.totalRequests,
        "disabled": client.disabled
      }
    except CatchableError as error:
      echo "cooperative-hunting llm worker: ", error.msg
    planReplies.send($reply)

# ---------------------------------------------------------------------------
# Episode state
# ---------------------------------------------------------------------------

type
  Episode = object
    config: GameConfig
    sim: SimServer
    seats: seq[Seat]
    writer: ReplayWriter
    beats: seq[ChromeBeat]
    newFeed: seq[ChromeFeedLine]
    recent: seq[string]
    roundScores: seq[seq[int]]
    turn: int
    turnsTotal: int
    reason: EndReason
    finished: bool
    roundEndTick: int
    batchInFlight: bool
    llmRequests: int
    llmEnabled: bool
    ingested: int
    planForSeat: seq[Plan]
    planReady: seq[bool]
    startedAt: MonoTime

proc episodeSeconds(ep: Episode): float =
  float((getMonoTime() - ep.startedAt).inMilliseconds) / 1000.0

proc chromeSeats(ep: Episode): seq[ChromeSeat] =
  for i, seat in ep.seats:
    let p = ep.sim.players[i]
    result.add(ChromeSeat(
      slot: seat.slot,
      alias: p.alias,
      name: seat.name,
      kind: (if seat.kind == pkPrompt: "prompt" else: "scripted"),
      color: p.colorIndex,
      score: p.score,
      energy: p.energy,
      level: p.level,
      role: (if p.role == roleHunter: "hunter" else: "forager"),
      dc: seat.disconnected
    ))

proc finalNode(ep: Episode): JsonNode =
  var order = newJArray()
  var indices: seq[int] = @[]
  for i in 0 ..< ep.seats.len:
    indices.add(i)
  var totals = newSeq[int](ep.seats.len)
  for round in ep.roundScores:
    for i in 0 ..< min(round.len, totals.len):
      totals[i] += round[i]
  for i in 0 ..< indices.high:
    for j in 0 ..< indices.high - i:
      if totals[indices[j]] < totals[indices[j + 1]]:
        swap(indices[j], indices[j + 1])
  for i in indices:
    order.add(%*{
      "alias": ep.sim.players[i].alias,
      "name": ep.seats[i].name,
      "score": totals[i]
    })
  %*{"reason": $ep.reason, "order": order}

proc ingestEvents(ep: var Episode) =
  ## Turn this tick's simulation events into feed lines and scrubber beats.
  ## Only events not yet seen: `advance` calls this several times per tick as
  ## the round card and the deadline guard add their own.
  if ep.ingested > ep.sim.pendingEvents.len:
    ep.ingested = 0
  let fresh = ep.sim.pendingEvents[ep.ingested ..< ep.sim.pendingEvents.len]
  ep.ingested = ep.sim.pendingEvents.len
  for event in fresh:
    let payload =
      try: parseJson("{" & event.payload & "}")
      except CatchableError: newJObject()
    let line = feedLineFor(event.name, payload)
    if line.text.len > 0:
      ep.newFeed.add(ChromeFeedLine(
        tick: event.tick, kind: line.kind, text: line.text))
      ep.recent.add("t" & $event.tick & " " & line.text)
      if ep.recent.len > 5:
        ep.recent.delete(0)
    let beat = beatKindForEvent(event.name, payload)
    if beat.len > 0:
      ep.beats.add(ChromeBeat(tick: event.tick, kind: beat))

proc currentChromeLabel(ep: var Episode, final: JsonNode): string =
  result = buildChromeLabel(
    ep.sim.globalTick,
    min(ep.sim.tickCount, ep.config.ticksPerRound),
    ep.sim.roundIndex + 1,
    ep.config.rounds,
    ep.config.ticksPerRound,
    (if ep.sim.phase == RoundEnding: "card" else: "play"),
    ep.config.variant,
    (if ep.finished: $ep.reason else: ""),
    ep.chromeSeats(),
    ep.newFeed,
    ep.beats,
    final
  )
  ep.newFeed.setLen(0)

proc resultsJson(ep: Episode): JsonNode =
  var
    names = newJArray()
    aliases = newJArray()
    kinds = newJArray()
    scores = newJArray()
    energy = newJArray()
    fallbacks = newJArray()
    disconnected = newJArray()
    roundsArr = newJArray()
    catchesArr = newJArray()
    coCapturesArr = newJArray()
  let seats = ep.seats.len
  var totals = newSeq[int](seats)
  for round in ep.roundScores:
    for i in 0 ..< min(round.len, seats):
      totals[i] += round[i]
  for i in 0 ..< seats:
    let p = ep.sim.players[i]
    names.add(%(if ep.seats[i].name.len > 0: ep.seats[i].name
                else: "player_" & $ep.seats[i].slot))
    aliases.add(%p.alias)
    kinds.add(%(if ep.seats[i].kind == pkPrompt: "prompt" else: "scripted"))
    scores.add(%max(0, totals[i]))
    energy.add(%p.energy)
    fallbacks.add(%ep.seats[i].fallbacks)
    disconnected.add(%ep.seats[i].disconnected)
    var catches = newJArray()
    for kind in PreyKind:
      catches.add(%(if i < ep.sim.stats.len: ep.sim.stats[i].catches[kind]
                    else: 0))
    catchesArr.add(catches)
    var co = newJArray()
    for j in 0 ..< seats:
      co.add(%(if i < ep.sim.stats.len and j < ep.sim.stats[i].coCatches.len:
                 ep.sim.stats[i].coCatches[j]
               else: 0))
    coCapturesArr.add(co)
  for round in ep.roundScores:
    var arr = newJArray()
    for i in 0 ..< seats:
      arr.add(%(if i < round.len: max(0, round[i]) else: 0))
    roundsArr.add(arr)
  %*{
    "names": names,
    "aliases": aliases,
    "kinds": kinds,
    "scores": scores,
    "energy": energy,
    "fallbacks": fallbacks,
    "disconnected": disconnected,
    "rounds": roundsArr,
    "catches": catchesArr,
    "co_captures": coCapturesArr,
    "llm_requests": ep.llmRequests,
    "variant": ep.config.variant,
    "seed": ep.config.seed,
    "final_tick": ep.sim.globalTick,
    "reason": $ep.reason
  }

proc freezeRound(ep: var Episode) =
  var scores: seq[int] = @[]
  for p in ep.sim.players:
    scores.add(p.score)
  ep.roundScores.add(scores)
  var roster = newJArray()
  for i, p in ep.sim.players:
    roster.add(%*{
      "slot": p.slot, "alias": p.alias, "score": p.score, "energy": p.energy
    })
  ep.sim.logEvent("round_end", %*{
    "round": ep.sim.roundIndex + 1, "players": roster
  })

proc roleNames(ep: Episode): seq[string] =
  for p in ep.sim.players:
    result.add(if p.role == roleHunter: "hunter" else: "forager")

proc newEpisode(config: GameConfig, seats: seq[Seat]): Episode =
  result.config = config
  result.seats = seats
  result.sim = initSim(config)
  result.sim.art.buildSpriteCache()
  result.reason = erComplete
  result.turnsTotal = max(1,
    (config.rounds * config.ticksPerRound) div max(1, config.planIntervalTicks))
  result.planForSeat = newSeq[Plan](seats.len)
  result.planReady = newSeq[bool](seats.len)
  let aliases = seatAliases(seats.len, config.seed)
  for i, seat in seats:
    discard result.sim.addPlayer(seat.name, aliases[i], seat.slot, seat.kind)
    result.sim.players[^1].disconnected = seat.disconnected
  result.sim.ensureStats(seats.len)
  result.sim.applyRolesPublic()
  var baselineNames: seq[string] = @[]
  for seat in seats:
    baselineNames.add(seat.baseline)
  result.writer = initReplayWriter(result.sim, baselineNames)
  result.writer.noteRound(0, 1, config.ticksPerRound, config.seed,
    result.roleNames())
  result.sim.logEvent("round_start", %*{
    "round": 1, "seed": config.seed, "ticks": config.ticksPerRound
  })
  for i, p in result.sim.players:
    result.sim.logEvent("player_spawn", %*{
      "slot": p.slot, "alias": p.alias, "x": p.tileX, "y": p.tileY
    })
  result.startedAt = getMonoTime()

# ---------------------------------------------------------------------------
# Planning turns
# ---------------------------------------------------------------------------

proc promptSeats(ep: Episode): seq[int] =
  for i, seat in ep.seats:
    if seat.kind == pkPrompt and not seat.disconnected and
        not seat.skipNextTurn:
      result.add(i)

proc dispatchPlanBatch(ep: var Episode) =
  ## ONE parallel batch per planning turn: decisions in this game are
  ## simultaneous, so they must be. The sim does not wait for it.
  if not ep.llmEnabled or ep.batchInFlight:
    return
  let seats = ep.promptSeats()
  for i, seat in ep.seats:
    if seat.kind == pkPrompt and seat.skipNextTurn:
      ep.seats[i].skipNextTurn = false
  if seats.len == 0:
    return
  inc ep.turn
  var aliases = newJArray()
  for p in ep.sim.players:
    aliases.add(%p.alias)
  var seatNodes = newJArray()
  for index in seats:
    let legal = ep.sim.legalTargets(index)
    var legalArr = newJArray()
    for target in legal:
      legalArr.add(%target)
    seatNodes.add(%*{
      "slot": ep.seats[index].slot,
      "system": systemPromptFor(ep.seats[index].prompt),
      "user": ep.sim.observationFor(index, ep.turn, ep.turnsTotal,
        ep.seats[index].lastPlan, ep.seats[index].note, ep.recent, ""),
      "legal": legalArr
    })
  planRequests.send($(%*{
    "turn": ep.turn, "aliases": aliases, "seats": seatNodes
  }))
  ep.batchInFlight = true

proc seatIndexOfSlot(ep: Episode, slot: int): int =
  for i, seat in ep.seats:
    if seat.slot == slot:
      return i
  -1

proc pollPlanBatch(ep: var Episode) =
  ## Poll only. A plan that lands late is applied on the next tick after it
  ## arrives, so the LLM contributes 0 s to the critical path.
  if not ep.batchInFlight:
    return
  let got = planReplies.tryRecv()
  if not got.dataAvailable:
    return
  ep.batchInFlight = false
  let reply =
    try: parseJson(got.msg)
    except CatchableError: newJObject()
  ep.llmRequests = reply{"requests"}.getInt(ep.llmRequests)
  if reply{"disabled"}.getBool():
    ep.llmEnabled = false
  let turn = reply{"turn"}.getInt()
  let plans = reply{"plans"}
  if plans.isNil or plans.kind != JArray:
    return
  for node in plans:
    let index = ep.seatIndexOfSlot(node{"slot"}.getInt())
    if index < 0:
      continue
    var plan = Plan(
      turn: turn,
      intent: node{"intent"}.getStr("hunt"),
      target: node{"target"}.getStr("none"),
      side: node{"side"}.getStr("any"),
      say: node{"say"}.getStr(),
      note: node{"note"}.getStr(),
      src: "llm"
    )
    let withNode = node{"with"}
    if not withNode.isNil and withNode.kind == JArray:
      for entry in withNode:
        plan.partners.add(entry.getStr())
    if node{"ok"}.getBool():
      ep.seats[index].note = plan.note
      ep.seats[index].lastPlan = plan
      ep.planForSeat[index] = plan
      ep.planReady[index] = true
      var partners = newJArray()
      for p in plan.partners:
        partners.add(%p)
      ep.sim.logEvent("plan", %*{
        "alias": ep.sim.players[index].alias,
        "turn": turn, "intent": plan.intent, "target": plan.target,
        "side": plan.side, "with": partners, "say": plan.say, "src": "llm"
      })
    else:
      let cause = node{"cause"}.getStr("parse")
      plan.src = "fallback:" & cause
      plan.target = "none"
      plan.intent = "hunt"
      ep.seats[index].lastPlan = plan
      ep.planForSeat[index] = plan
      ep.planReady[index] = true
      # A seat that consumed a retry skips its NEXT planning turn, so the
      # worst case stays at 2 requests per seat per 30 s = 24 req/min.
      ep.seats[index].skipNextTurn = true
      inc ep.seats[index].fallbacks
      ep.sim.logEvent("fallback", %*{
        "alias": ep.sim.players[index].alias,
        "baseline": (if ep.seats[index].baseline.len > 0:
                       ep.seats[index].baseline
                     else: "big_game_hunter"),
        "cause": cause
      })

proc planPacket(plan: Plan): seq[uint8] =
  var partners = newJArray()
  for p in plan.partners:
    partners.add(%p)
  let body = $(%*{
    "turn": plan.turn,
    "intent": plan.intent,
    "target": plan.target,
    "side": plan.side,
    "with": partners,
    "say": plan.say,
    "src": plan.src
  })
  result.add(MsgPlan)
  result.add(uint8(body.len and 0xff))
  result.add(uint8((body.len shr 8) and 0xff))
  for ch in body:
    result.add(uint8(ord(ch)))

# ---------------------------------------------------------------------------
# The tick
# ---------------------------------------------------------------------------

proc advance(ep: var Episode, inputs: openArray[InputState]) =
  ## One tick of the episode, including the round card and the deadline
  ## guard. Returns with `ep.finished` set when the episode has settled.
  ep.pollPlanBatch()
  case ep.sim.phase
  of RoundPlaying:
    ep.sim.step(inputs)
    ep.ingestEvents()
    if ep.sim.tickCount >= ep.config.ticksPerRound:
      ep.freezeRound()
      ep.ingestEvents()
      ep.sim.phase = RoundEnding
      ep.roundEndTick = 0
      for i in 0 ..< ep.sim.players.len:
        ep.sim.players[i].overlayActive = true
  of RoundEnding:
    # The world freezes for the round card; the clock keeps moving so the
    # replay has frames and the viewer's scrubber stays honest.
    ep.sim.pendingCaptures.setLen(0)
    inc ep.sim.globalTick
    inc ep.roundEndTick
    if ep.roundEndTick >= RoundEndDisplayTicks:
      if ep.sim.roundIndex + 1 >= ep.config.rounds:
        ep.finished = true
        ep.reason = erComplete
      else:
        let next = ep.sim.roundIndex + 1
        ep.sim.startRound(next)
        ep.writer.noteRound(next, ep.sim.globalTick + 1,
          ep.config.ticksPerRound, ep.config.seed + next, ep.roleNames())
        ep.ingestEvents()

  if not ep.finished and
      ep.episodeSeconds() >= float(ep.config.playBudgetSeconds):
    # Degrade, never hang. The current round is scored as it stands, the
    # remaining rounds are not played, and the episode settles and exits 0.
    if ep.sim.phase == RoundPlaying:
      ep.freezeRound()
    ep.sim.logEvent("deadline", %*{
      "tick": ep.sim.globalTick, "seconds": ep.episodeSeconds()
    })
    ep.ingestEvents()
    ep.finished = true
    ep.reason = erDeadline

  if ep.finished:
    ep.sim.logEvent("episode_end", %*{"reason": $ep.reason})
    ep.ingestEvents()

# ---------------------------------------------------------------------------
# Offline episode runner (no sockets): the harness tests/test_episode.nim
# drives, and the shape the live loop below mirrors exactly.
# ---------------------------------------------------------------------------

proc runEpisodeOffline*(
  config: GameConfig,
  baselineNames: seq[string],
  resultsPath, replayPath: string
): tuple[reason: EndReason, ticks: int] =
  var seats: seq[Seat] = @[]
  for slot in 0 ..< config.numAgents:
    seats.add(Seat(
      slot: slot,
      name: (if slot < config.players.len: config.players[slot]
             else: "player_" & $slot),
      kind: pkScripted,
      baseline: (if slot < baselineNames.len: baselineNames[slot]
                 else: "big_game_hunter"),
      connected: true
    ))
  var ep = newEpisode(config, seats)
  var bots: seq[Bot] = @[]
  var states: seq[ViewerState] = @[]
  for slot in 0 ..< config.numAgents:
    bots.add(initBot(parseBaselineKind(seats[slot].baseline), config.seed + slot))
    states.add(ViewerState())
  var masks = newSeq[uint8](config.numAgents)
  var recorded = 0
  while not ep.finished:
    var inputs: seq[InputState] = @[]
    for slot in 0 ..< config.numAgents:
      inputs.add(decodeInputMask(masks[slot]))
    ep.advance(inputs)
    let final = if ep.finished: ep.finalNode() else: nil
    let label = ep.currentChromeLabel(final)
    discard label
    ep.writer.recordTick(ep.sim, ep.sim.roundIndex + 1,
      (if ep.sim.phase == RoundEnding: "card" else: "play"),
      ep.sim.pendingEvents)
    ep.sim.pendingEvents.setLen(0)
    ep.ingested = 0
    inc recorded
    for slot in 0 ..< config.numAgents:
      var nextState: ViewerState
      let frame = ep.sim.buildPlayerFrame(slot, states[slot], nextState)
      states[slot] = nextState
      var blob = newString(frame.len)
      for k, b in frame:
        blob[k] = char(b)
      if bots[slot].applySpritePacket(blob):
        inc bots[slot].frameTick
        masks[slot] = bots[slot].decideMask()
  let results = ep.resultsJson()
  if resultsPath.len > 0:
    createDir(resultsPath.parentDir())
    writeFile(resultsPath, $results & "\n")
  if replayPath.len > 0:
    createDir(replayPath.parentDir())
    writeFile(replayPath, ep.writer.finish(results))
  (ep.reason, recorded)

# ---------------------------------------------------------------------------
# HTTP / websocket plumbing
# ---------------------------------------------------------------------------

proc initAppState(config: GameConfig) =
  initLock(appState.lock)
  appState.config = config
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.playerSlots = initTable[WebSocket, int]()
  appState.playerNames = initTable[WebSocket, string]()
  appState.playerTokens = initTable[WebSocket, string]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerStates = initTable[WebSocket, ViewerState]()
  appState.registrations = initTable[WebSocket, Registration]()
  appState.globalViewers = initHashSet[WebSocket]()
  appState.globalStates = initTable[WebSocket, ViewerState]()
  appState.closedSockets = @[]

proc serveHealthz(request: Request): bool =
  if request.path != HealthzPath or request.httpMethod notin ["GET", "HEAD"]:
    return false
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  request.respond(200, headers, "healthy")
  true

proc isWebSocketUpgrade(request: Request): bool =
  request.headers["Sec-WebSocket-Key"].len > 0

proc isStaticRoute(route: string): bool =
  case route
  of PlayerClientRoute, PlayerClientHtmlRoute,
      GlobalClientRoute, GlobalClientHtmlRoute,
      SnappyClientRoute, SnappyClientPath:
    true
  else:
    false

proc serveClientFile(request: Request, route: string): bool =
  ## Neither this nor any other static route opens a player socket: the
  ## certification runner probes /client/player and /client/global BEFORE
  ## starting the player pods, and a 404 or a socket side effect fails the
  ## episode (lantern 0.1.1).
  if request.httpMethod != "GET":
    return false
  let filePath = clientStaticPath(route)
  var headers: HttpHeaders
  headers["Content-Type"] = clientStaticContentType(route)
  headers["Cache-Control"] = "no-cache"
  if filePath.len == 0 or not fileExists(filePath):
    request.respond(200, headers,
      "<!doctype html><meta charset=\"utf-8\"><title>Cooperative Hunting" &
      "</title><body>Cooperative Hunting " & route & " client</body>")
    return true
  try:
    request.respond(200, headers, readFile(filePath))
  except IOError as e:
    request.respond(500, headers, "Could not read static client: " & e.msg)
  true

proc parsePlayerSlot(request: Request): int =
  let text = request.queryParams.getOrDefault("slot", "").strip()
  if text.len == 0:
    return -1
  try:
    result = parseInt(text)
  except ValueError:
    return -1
  if result < 0 or result >= MaxPlayerSlots:
    return -1

proc tokenValid(config: GameConfig, slot: int, token: string): bool =
  if not config.closedRoster:
    return true
  if slot < 0 or slot >= config.tokens.len:
    return false
  if config.tokens[slot].len == 0:
    return true
  config.tokens[slot] == token

proc httpHandler(request: Request) =
  if request.serveHealthz():
    discard
  elif request.path == WebSocketPath and request.httpMethod == "GET" and
      not request.isWebSocketUpgrade():
    discard request.serveClientFile(PlayerClientRoute)
  elif request.path == GlobalWebSocketPath and request.httpMethod == "GET" and
      not request.isWebSocketUpgrade():
    discard request.serveClientFile(GlobalClientRoute)
  elif request.path == WebSocketPath and request.httpMethod == "GET":
    let
      slot = request.parsePlayerSlot()
      token = request.queryParams.getOrDefault("token", "").strip()
      name = request.queryParams.getOrDefault("name", "").strip()
    var config: GameConfig
    {.gcsafe.}:
      withLock appState.lock:
        config = appState.config
    if not config.tokenValid(slot, token):
      var headers: HttpHeaders
      headers["Content-Type"] = "text/plain"
      request.respond(403, headers, "Invalid token for slot " & $slot)
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerIndices[websocket] = UnassignedPlayerIndex
        appState.inputMasks[websocket] = 0
        appState.playerStates[websocket] = ViewerState()
        appState.playerNames[websocket] = runeCap(name, MaxNameRunes)
        appState.playerSlots[websocket] = slot
        appState.playerTokens[websocket] = token
    echo "player connected: ",
      (if name.len > 0: name else: "anonymous"), " slot=", slot
  elif request.path == GlobalWebSocketPath and request.httpMethod == "GET":
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.globalViewers.incl(websocket)
        appState.globalStates[websocket] = ViewerState()
  elif request.path.isStaticRoute():
    discard request.serveClientFile(request.path)
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "Cooperative Hunting WebSocket server")

proc parseRegistration(body: string): Registration =
  ## A malformed, oversized or non-UTF-8 body is DROPPED and the seat is
  ## treated as the big_game_hunter baseline -- never a disconnect.
  result = Registration(kind: pkScripted, baseline: "big_game_hunter")
  if body.len == 0 or body.len > MaxRegistrationBytes:
    return
  if validateUtf8(body) != -1:
    return
  try:
    let node = parseJson(body)
    if node{"kind"}.getStr() == "prompt":
      let prompt = node{"prompt"}.getStr().strip()
      if prompt.len > 0:
        result.kind = pkPrompt
        result.prompt = runeCap(prompt, MaxPromptRunes)
        return
    let baseline = node{"baseline"}.getStr().strip()
    if baseline.len > 0:
      result.baseline = baselineName(parseBaselineKind(baseline))
  except CatchableError:
    discard

proc websocketHandler(
  websocket: WebSocket, event: WebSocketEvent, message: Message
) =
  case event
  of OpenEvent:
    discard
  of MessageEvent:
    if message.kind != BinaryMessage or message.data.len == 0:
      return
    let head = message.data[0].uint8
    if message.data.len == 2 and (head == PacketInput or head == 0x84'u8):
      {.gcsafe.}:
        withLock appState.lock:
          if websocket in appState.playerIndices:
            appState.inputMasks[websocket] = message.data[1].uint8 and 0x7f'u8
    elif head == MsgRegister and message.data.len >= 3:
      let length = int(message.data[1].uint8) or
        (int(message.data[2].uint8) shl 8)
      var body = ""
      if length > 0 and message.data.len >= 3 + length:
        body = message.data[3 ..< 3 + length]
      let registration = parseRegistration(body)
      {.gcsafe.}:
        withLock appState.lock:
          appState.registrations[websocket] = registration
  of ErrorEvent:
    discard
  of CloseEvent:
    {.gcsafe.}:
      withLock appState.lock:
        appState.closedSockets.add(websocket)

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

proc writeArtifacts(ep: Episode) =
  let results = ep.resultsJson()
  let resultsUri = getEnv(CogameResultsUriEnv)
  if resultsUri.len > 0:
    writeCogameUri(resultsUri, $results & "\n", "application/json",
      "results", cogameHttpMethod(CogameResultsMethodEnv))
    echo "results written to: ", resultsUri
  let replayUri = getEnv(CogameSaveReplayUriEnv)
  if replayUri.len > 0:
    writeCogameUri(replayUri, ep.writer.finish(results), "application/json",
      "replay", cogameHttpMethod(CogameSaveReplayMethodEnv))
    echo "replay written to: ", replayUri, " (", ep.writer.ticks.len,
      " ticks)"

proc writeNoPlayersResults(config: GameConfig) =
  ## Zero seats connected inside the connect timeout: results.json is
  ## written with all-zero scores and the process exits 0. Never a hang,
  ## never a non-zero exit.
  var
    names = newJArray()
    aliases = newJArray()
    kinds = newJArray()
    scores = newJArray()
    energy = newJArray()
    fallbacks = newJArray()
    disconnected = newJArray()
    catchesArr = newJArray()
    coCapturesArr = newJArray()
  let aliasNames = seatAliases(config.numAgents, config.seed)
  for slot in 0 ..< config.numAgents:
    names.add(%(if slot < config.players.len: config.players[slot]
                else: "player_" & $slot))
    aliases.add(%aliasNames[slot])
    kinds.add(%"scripted")
    scores.add(%0)
    energy.add(%0)
    fallbacks.add(%0)
    disconnected.add(%true)
    var catches = newJArray()
    for _ in 0 ..< 5:
      catches.add(%0)
    catchesArr.add(catches)
    var co = newJArray()
    for _ in 0 ..< config.numAgents:
      co.add(%0)
    coCapturesArr.add(co)
  var roundsArr = newJArray()
  let results = %*{
    "names": names, "aliases": aliases, "kinds": kinds, "scores": scores,
    "energy": energy, "fallbacks": fallbacks, "disconnected": disconnected,
    "rounds": roundsArr, "catches": catchesArr,
    "co_captures": coCapturesArr, "llm_requests": 0,
    "variant": config.variant, "seed": config.seed, "final_tick": 0,
    "reason": $erNoPlayers
  }
  let resultsUri = getEnv(CogameResultsUriEnv)
  if resultsUri.len > 0:
    writeCogameUri(resultsUri, $results & "\n", "application/json",
      "results", cogameHttpMethod(CogameResultsMethodEnv))
  let replayUri = getEnv(CogameSaveReplayUriEnv)
  if replayUri.len > 0:
    var sim = initSim(config)
    var writer = initReplayWriter(sim, @[])
    writeCogameUri(replayUri, writer.finish(results), "application/json",
      "replay", cogameHttpMethod(CogameSaveReplayMethodEnv))

proc runServerLoop(host: string, port: int, config: GameConfig) =
  initAppState(config)

  let httpServer = newServer(
    httpHandler, websocketHandler, workerThreads = 4, tcpNoDelay = true
  )
  var serverThread: Thread[ServerThreadArgs]
  let serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(serverThread, serverThreadProc,
    ServerThreadArgs(server: serverPtr, address: host, port: port))
  httpServer.waitUntilReady()

  # ---- roster ------------------------------------------------------------
  let rosterDeadline = getMonoTime() +
    initDuration(seconds = config.playerConnectTimeoutSeconds)
  var sockets = newSeq[WebSocket](config.numAgents)
  var haveSocket = newSeq[bool](config.numAgents)
  var connected = 0
  while connected < config.numAgents and getMonoTime() < rosterDeadline:
    {.gcsafe.}:
      withLock appState.lock:
        for websocket, slot in appState.playerSlots.pairs:
          if slot < 0 or slot >= config.numAgents or haveSocket[slot]:
            continue
          sockets[slot] = websocket
          haveSocket[slot] = true
          appState.playerIndices[websocket] = slot
          inc connected
    if connected >= config.numAgents:
      break
    sleep(100)
  echo "roster closed with ", connected, "/", config.numAgents, " seats"

  if connected == 0:
    writeNoPlayersResults(config)
    echo "no seats connected; settling with reason no_players"
    sleep(ShutdownGraceSeconds * 1000)
    httpServer.close()
    quit(0)

  # Give a connected seat a moment to send its 0x90 registration before the
  # roster is frozen. Bounded, like every other wait here.
  sleep(500)

  var seats: seq[Seat] = @[]
  for slot in 0 ..< config.numAgents:
    var seat = Seat(
      slot: slot,
      name: (if slot < config.players.len: config.players[slot]
             else: "player_" & $slot),
      kind: pkScripted,
      baseline: "big_game_hunter",
      connected: haveSocket[slot],
      disconnected: not haveSocket[slot]
    )
    if haveSocket[slot]:
      {.gcsafe.}:
        withLock appState.lock:
          let queryName = appState.playerNames.getOrDefault(sockets[slot], "")
          if queryName.len > 0:
            seat.name = queryName
          if sockets[slot] in appState.registrations:
            let registration = appState.registrations[sockets[slot]]
            seat.kind = registration.kind
            seat.prompt = registration.prompt
            if registration.baseline.len > 0:
              seat.baseline = registration.baseline
    seats.add(seat)

  var ep = newEpisode(config, seats)
  ep.llmEnabled = false
  for seat in seats:
    if seat.kind == pkPrompt:
      ep.llmEnabled = true
  if ep.llmEnabled:
    planRequests.open()
    planReplies.open()
    createThread(llmThread, llmWorker, config)
    llmThreadRunning = true

  var lastTick = getMonoTime()
  let frameDuration = initDuration(
    milliseconds = max(1, 1000 div max(1, config.tickHz)))
  var recorderState = ViewerState()

  while not ep.finished:
    # 1. Ingest input: the most recent mask since the last tick, last write
    #    wins; a seat that sent nothing keeps its previous mask; a
    #    disconnected seat contributes 0.
    var inputs = newSeq[InputState](config.numAgents)
    var closed: seq[WebSocket] = @[]
    {.gcsafe.}:
      withLock appState.lock:
        closed = appState.closedSockets
        appState.closedSockets.setLen(0)
        for slot in 0 ..< config.numAgents:
          if not haveSocket[slot]:
            continue
          let mask = appState.inputMasks.getOrDefault(sockets[slot], 0)
          inputs[slot] = decodeInputMask(mask)
    for websocket in closed:
      for slot in 0 ..< config.numAgents:
        if haveSocket[slot] and sockets[slot] == websocket:
          haveSocket[slot] = false
          ep.seats[slot].disconnected = true
          ep.sim.players[slot].disconnected = true
          inputs[slot] = InputState()
          echo "seat ", slot, " disconnected"

    # 2. Plan distribution, on a planning boundary only.
    if ep.sim.phase == RoundPlaying and
        ep.sim.tickCount mod config.planIntervalTicks == 0:
      ep.dispatchPlanBatch()

    ep.advance(inputs)

    let final = if ep.finished: ep.finalNode() else: nil
    let label = ep.currentChromeLabel(final)

    # 9. Emit: the global frame (with the chrome label on sprite 4090), the
    #    replay record, and each seat's per-seat frame.
    var nextRecorder: ViewerState
    let globalBytes = ep.sim.buildGlobalFrame(label, recorderState,
      nextRecorder)
    recorderState = nextRecorder
    ep.writer.recordTick(ep.sim, ep.sim.roundIndex + 1,
      (if ep.sim.phase == RoundEnding: "card" else: "play"),
      ep.sim.pendingEvents)
    ep.sim.pendingEvents.setLen(0)
    ep.ingested = 0

    var globalSockets: seq[WebSocket] = @[]
    var globalStates: seq[ViewerState] = @[]
    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.globalViewers:
          globalSockets.add(websocket)
          globalStates.add(
            appState.globalStates.getOrDefault(websocket, ViewerState()))
    for i in 0 ..< globalSockets.len:
      var nextState: ViewerState
      let bytes =
        if globalStates[i].initialized: globalBytes
        else: ep.sim.buildGlobalFrame(label, globalStates[i], nextState)
      try:
        globalSockets[i].send(blobFromBytes(bytes), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            appState.globalStates[globalSockets[i]] =
              ViewerState(initialized: true)
      except CatchableError:
        {.gcsafe.}:
          withLock appState.lock:
            appState.globalViewers.excl(globalSockets[i])
            appState.globalStates.del(globalSockets[i])

    for slot in 0 ..< config.numAgents:
      if not haveSocket[slot]:
        continue
      var state = ViewerState()
      {.gcsafe.}:
        withLock appState.lock:
          state = appState.playerStates.getOrDefault(sockets[slot],
            ViewerState())
      var nextState: ViewerState
      let bytes = ep.sim.buildPlayerFrame(slot, state, nextState)
      try:
        sockets[slot].send(blobFromBytes(bytes), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            appState.playerStates[sockets[slot]] = nextState
        # 0x91 goes ONLY to seats that registered a prompt: the bundled
        # bots' parsers reject unknown message types and would drop the
        # whole frame.
        if ep.seats[slot].kind == pkPrompt and ep.planReady[slot]:
          ep.planReady[slot] = false
          sockets[slot].send(blobFromBytes(planPacket(ep.planForSeat[slot])),
            BinaryMessage)
      except CatchableError:
        haveSocket[slot] = false
        ep.seats[slot].disconnected = true
        ep.sim.players[slot].disconnected = true

    let elapsed = getMonoTime() - lastTick
    if elapsed < frameDuration:
      sleep(int((frameDuration - elapsed).inMilliseconds))
    lastTick = getMonoTime()

  echo "episode settled: reason=", ep.reason, " tick=", ep.sim.globalTick
  ep.writeArtifacts()

  if llmThreadRunning:
    planRequests.send("quit")
    joinThread(llmThread)
    planRequests.close()
    planReplies.close()

  # The certification runner pings /global AFTER the player pods start and a
  # fast exit fails the episode (lantern 0.1.3), so keep answering for a
  # bounded grace before exiting 0.
  echo "artifacts written; holding /healthz and /global for ",
    ShutdownGraceSeconds, "s"
  sleep(ShutdownGraceSeconds * 1000)
  httpServer.close()
  quit(0)

when isMainModule:
  import std/parseopt

  var
    address = cogameHost("0.0.0.0")
    port = cogamePort(8080)
    configPath = pathFromCogameEnv(CogameConfigUriEnv)
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address": address = val
      of "port": port = parseInt(val)
      of "config-file": configPath = val
      else: discard
    else: discard

  var config = defaultGameConfig()
  if configPath.len > 0 and fileExists(configPath):
    echo "loading config from: ", configPath
    config = parseGameConfig(readFile(configPath))
  echo "starting cooperative_hunting on ", address, ":", port,
    " variant=", config.variant, " seats=", config.numAgents,
    " rounds=", config.rounds, "x", config.ticksPerRound,
    " tickHz=", config.tickHz
  runServerLoop(address, port, config)
