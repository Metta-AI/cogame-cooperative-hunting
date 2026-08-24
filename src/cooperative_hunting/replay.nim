## The replay document: one strict-UTF-8 JSON file, self-sufficient.
##
## Replaces `Metta-AI/coworld-staghunt`'s binary frame blob and its
## `runReplayServer` / `/client/replay` pod entirely -- replays are never
## served by a pod here. `docker_smoke.sh` parses this file, the wasm module
## parses it in the browser, and nothing else is contacted: no server, no
## config lookup, no name service.
##
## `p` is present on every tick. `q`, `c` and `ev` are OMITTED when unchanged
## or empty; an absent field means "identical to the previous tick". That is
## the only compression, and it is what takes a 3000-tick episode from about
## 2.1 MB to about 400 KB.

import std/[json, strutils, times]
import ./sim_types
import ./sim

const
  ReplayFormat* = "cooperative-hunting/1"
  ReplayVersion* = "0.1.0"

  ## `flags` bits, players and animals alike.
  FlagKillGlow* = 1
  FlagHurtGlow* = 2
  FlagAlerted* = 4
  FlagHiddenGrass* = 8
  FlagDisconnected* = 16

  ## `q` kind ordinals: 0..4 are PreyKind, then the furniture.
  QIron* = 5
  QGold* = 6
  QFood* = 7
  QBerryRipe* = 8
  QBerryPicked* = 9

  EventVocabulary* = [
    "round_start", "player_spawn", "prey_spawn", "catch", "mine", "pickup",
    "forage", "tag", "trample", "moose_gut", "plan", "fallback", "deadline",
    "round_end", "episode_end"
  ]

type
  ReplayWriter* = object
    ## Accumulates the document while the episode runs.
    header*: JsonNode
    seats*: JsonNode
    rounds*: JsonNode
    ticks*: seq[string]      ## already-serialised tick objects
    lastQ: string
    lastC: string

  ReplayTick* = object
    tick*: int
    roundNo*: int
    phase*: string
    p*: JsonNode
    q*: JsonNode
    c*: JsonNode
    ev*: JsonNode

  ReplaySeat* = object
    slot*: int
    alias*: string
    name*: string
    kind*: string
    baseline*: string
    color*: int
    level*: int
    disconnected*: bool

  ReplayDoc* = object
    ## The parsed document, plus everything the viewer needs to re-derive a
    ## frame: the world, the seats, and the per-tick state.
    raw*: JsonNode
    variant*: string
    seed*: int
    width*: int
    height*: int
    tiles*: seq[TileKind]
    tallGrass*: seq[bool]
    berryTiles*: seq[tuple[x, y: int]]
    seats*: seq[ReplaySeat]
    roundRoles*: seq[seq[string]]
    ticks*: seq[ReplayTick]
    config*: GameConfig

# ---------------------------------------------------------------------------
# Feed lines (shared by the live server and the replay viewer, so the two
# never drift)
# ---------------------------------------------------------------------------

proc aliasList(node: JsonNode): string =
  var names: seq[string] = @[]
  if not node.isNil and node.kind == JArray:
    for entry in node:
      names.add(entry{"alias"}.getStr())
  case names.len
  of 0: ""
  of 1: names[0]
  of 2: names[0] & " + " & names[1]
  else: names[0 ..< names.high].join(", ") & " + " & names[^1]

proc feedLineFor*(name: string, payload: JsonNode): tuple[kind, text: string] =
  ## Plain language for the spectator feed. "render 10, not T."
  case name
  of "catch":
    let by = payload{"by"}
    var gain = 0
    if not by.isNil and by.kind == JArray and by.len > 0:
      gain = by[0]{"gain"}.getInt()
    result = ("catch", aliasList(by) & " bring down a " &
      payload{"kind"}.getStr() & "  +" & $gain & " each")
  of "mine":
    let by = payload{"by"}
    var gain = 0
    if not by.isNil and by.kind == JArray and by.len > 0:
      gain = by[0]{"gain"}.getInt()
    result = ("catch", aliasList(by) & " work a " & payload{"kind"}.getStr() &
      " node  +" & $gain & " each")
  of "pickup":
    let by = payload{"by"}
    result = ("catch", aliasList(by) & " lift " & payload{"kind"}.getStr())
  of "forage":
    result = ("forage", payload{"alias"}.getStr() & " eats berries  +" &
      $payload{"gain"}.getInt())
  of "tag":
    result = ("tag", aliasList(payload{"by"}) & " corner " &
      payload{"target"}.getStr())
  of "trample":
    result = ("hurt", payload{"alias"}.getStr() &
      " is trampled by an elephant  -30 energy")
  of "moose_gut":
    result = ("hurt", payload{"alias"}.getStr() &
      " is gored by a moose  -10 energy")
  of "plan":
    let say = payload{"say"}.getStr()
    if say.len == 0:
      result = ("", "")
    else:
      result = ("say", payload{"alias"}.getStr() & ": " & say)
  of "fallback":
    result = ("fallback", payload{"alias"}.getStr() &
      " fell back to " & payload{"baseline"}.getStr() & " \u2014 " &
      payload{"cause"}.getStr())
  of "round_start":
    result = ("round", "ROUND " & $payload{"round"}.getInt() & " begins")
  of "round_end":
    result = ("round", "ROUND " & $payload{"round"}.getInt() & " ends")
  of "deadline":
    result = ("round", "Time called \u2014 settling the round as it stands")
  of "episode_end":
    result = ("round", "HUNT OVER \u2014 " & payload{"reason"}.getStr())
  else:
    result = ("", "")

proc beatKindForEvent*(name: string, payload: JsonNode): string =
  ## The complete set of beat kinds the scrubber may carry. Every one of
  ## these has CSS in the page; nothing else is ever emitted.
  case name
  of "round_start", "round_end": "round"
  of "catch":
    let kind = payload{"kind"}.getStr()
    if kind in ["stag", "moose", "elephant"]: "bigcatch" else: "smallcatch"
  of "mine":
    if payload{"kind"}.getStr() == "gold": "bigcatch" else: "smallcatch"
  of "pickup": "smallcatch"
  of "tag": "tag"
  of "episode_end": "end"
  else: ""

# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------

proc configNode*(config: GameConfig): JsonNode =
  ## Every resolved field, defaults expanded, so the replay stands alone.
  var playerNames = newJArray()
  for name in config.players:
    playerNames.add(%runeCap(name, MaxNameRunes))
  %*{
    "num_agents": config.numAgents,
    "seed": config.seed,
    "variant": config.variant,
    "rounds": config.rounds,
    "ticksPerRound": config.ticksPerRound,
    "tickHz": config.tickHz,
    "planIntervalTicks": config.planIntervalTicks,
    "planTimeoutSeconds": config.planTimeoutSeconds,
    "playBudgetSeconds": config.playBudgetSeconds,
    "player_connect_timeout_seconds": config.playerConnectTimeoutSeconds,
    "maxOutputTokens": config.maxOutputTokens,
    "model": config.model,
    # Every resolved field means every field: these two are set from the
    # variant node and from `focus`, and a replay that omits them cannot say
    # which world it recorded.
    "closedRoster": config.closedRoster,
    "focusElephant": config.focusElephant,
    "players": playerNames
  }

proc worldNode*(sim: SimServer): JsonNode =
  var tiles = newStringOfCap(WorldWidthTiles * WorldHeightTiles)
  for ty in 0 ..< WorldHeightTiles:
    for tx in 0 ..< WorldWidthTiles:
      tiles.add(
        case sim.tiles[tileIndex(tx, ty)]
        of TileEmpty: '.'
        of TileTree: 'T'
        of TileRock: 'R'
      )
  var grass = newJArray()
  for ty in 0 ..< WorldHeightTiles:
    for tx in 0 ..< WorldWidthTiles:
      if sim.isTallGrass(tx, ty):
        grass.add(%*[tx, ty])
  var berries = newJArray()
  for b in sim.berries:
    berries.add(%*[b.tileX, b.tileY])
  %*{
    "w": WorldWidthTiles,
    "h": WorldHeightTiles,
    "tilePx": StagTileSize,
    "tiles": tiles,
    "grass": grass,
    "berries": berries
  }

proc seatsNode*(sim: SimServer, baselines: seq[string]): JsonNode =
  result = newJArray()
  for i, p in sim.players:
    result.add(%*{
      "slot": p.slot,
      "alias": runeCap(p.alias, MaxNameRunes),
      "name": runeCap(p.name, MaxNameRunes),
      "kind": (if p.kind == pkPrompt: "prompt" else: "scripted"),
      "baseline": (if i < baselines.len: baselines[i] else: ""),
      "color": p.colorIndex,
      "level": p.level,
      "disconnected": p.disconnected
    })

proc initReplayWriter*(
  sim: SimServer, baselines: seq[string]
): ReplayWriter =
  result.header = %*{
    "format": ReplayFormat,
    "version": ReplayVersion,
    "coworld": "cooperative_hunting",
    "variant": sim.config.variant,
    "generated_at": now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    "seed": sim.config.seed,
    "config": configNode(sim.config),
    "world": worldNode(sim)
  }
  result.seats = seatsNode(sim, baselines)
  result.rounds = newJArray()
  result.lastQ = ""
  result.lastC = ""

proc noteRound*(
  writer: var ReplayWriter, roundIndex, startTick, ticks, seed: int,
  roles: seq[string]
) =
  var rolesArr = newJArray()
  for role in roles:
    rolesArr.add(%role)
  writer.rounds.add(%*{
    "n": roundIndex + 1,
    "startTick": startTick,
    "ticks": ticks,
    "seed": seed,
    "roles": rolesArr
  })

proc playersArray(sim: SimServer): string =
  var parts: seq[string] = @[]
  for p in sim.players:
    var flags = 0
    if p.killGlow > 0: flags = flags or FlagKillGlow
    if p.trampleGlow > 0: flags = flags or FlagHurtGlow
    if p.pushStep > 0: flags = flags or FlagAlerted
    if sim.isPredatorPrey() and p.role == roleForager and
        sim.isTallGrass(p.tileX, p.tileY):
      flags = flags or FlagHiddenGrass
    if p.disconnected: flags = flags or FlagDisconnected
    parts.add("[" & $p.tileX & "," & $p.tileY & "," & $ord(p.facing) & "," &
      $p.energy & "," & $p.score & "," & $flags & "]")
  "[" & parts.join(",") & "]"

proc entitiesArray(sim: SimServer): string =
  var parts: seq[string] = @[]
  for q in sim.prey:
    var flags = 0
    if q.alertFlash > 0: flags = flags or FlagAlerted
    parts.add("[" & $q.id & "," & $ord(q.kind) & "," & $q.tileX & "," &
      $q.tileY & "," & $flags & "]")
  for item in sim.items:
    let ord =
      case item.kind
      of itIron: QIron
      of itGold: QGold
      of itFood: QFood
    # The lbf level rides in bits 8..11 so one array shape covers everything.
    parts.add("[" & $item.id & "," & $ord & "," & $item.tileX & "," &
      $item.tileY & "," & $(item.level shl 8) & "]")
  for i, b in sim.berries:
    parts.add("[" & $(1000000 + i) & "," &
      $(if b.regrow == 0: QBerryRipe else: QBerryPicked) & "," &
      $b.tileX & "," & $b.tileY & ",0]")
  "[" & parts.join(",") & "]"

proc corpsesArray(sim: SimServer): string =
  var parts: seq[string] = @[]
  for c in sim.corpses:
    parts.add("[" & $c.tileX & "," & $c.tileY & "," & $c.ticksRemaining & "]")
  "[" & parts.join(",") & "]"

proc recordTick*(
  writer: var ReplayWriter,
  sim: SimServer,
  roundNo: int,
  phase: string,
  events: seq[EventRecord]
) =
  ## One tick record. `p` is always written; `q`, `c` and `ev` only when they
  ## changed or are non-empty.
  var parts: seq[string] = @[]
  parts.add("\"t\":" & $sim.globalTick)
  parts.add("\"r\":" & $roundNo)
  parts.add("\"ph\":" & escapeJson(phase))
  parts.add("\"p\":" & playersArray(sim))
  let q = entitiesArray(sim)
  if q != writer.lastQ:
    parts.add("\"q\":" & q)
    writer.lastQ = q
  let c = corpsesArray(sim)
  if c != writer.lastC:
    parts.add("\"c\":" & c)
    writer.lastC = c
  if events.len > 0:
    var evParts: seq[string] = @[]
    for e in events:
      var body = "{\"ev\":" & escapeJson(e.name)
      if e.payload.len > 0:
        body.add(',')
        body.add(e.payload)
      body.add('}')
      evParts.add(body)
    parts.add("\"ev\":[" & evParts.join(",") & "]")
  writer.ticks.add("{" & parts.join(",") & "}")

proc finish*(writer: ReplayWriter, results: JsonNode): string =
  ## Serialise the whole document. Built by hand rather than through one big
  ## JsonNode because the tick array is already text and re-parsing a
  ## multi-megabyte array to print it again is pure waste.
  var parts: seq[string] = @[]
  for key, value in writer.header.pairs:
    parts.add(escapeJson(key) & ":" & $value)
  parts.add("\"seats\":" & $writer.seats)
  parts.add("\"rounds\":" & $writer.rounds)
  parts.add("\"ticks\":[" & writer.ticks.join(",") & "]")
  parts.add("\"results\":" & $results)
  "{" & parts.join(",") & "}"

# ---------------------------------------------------------------------------
# Reading (the wasm viewer's half)
# ---------------------------------------------------------------------------

proc parseReplayDoc*(bytes: string): ReplayDoc =
  let node = parseJson(bytes)
  if node{"format"}.getStr() != ReplayFormat:
    raise newException(ValueError,
      "unexpected replay format: " & node{"format"}.getStr())
  result.raw = node
  result.variant = node{"variant"}.getStr("staghunt")
  result.seed = node{"seed"}.getInt()

  let world = node{"world"}
  if world.isNil:
    raise newException(ValueError, "replay has no world block")
  result.width = world{"w"}.getInt(WorldWidthTiles)
  result.height = world{"h"}.getInt(WorldHeightTiles)
  let tiles = world{"tiles"}.getStr()
  result.tiles = newSeq[TileKind](result.width * result.height)
  for i in 0 ..< min(tiles.len, result.tiles.len):
    result.tiles[i] =
      case tiles[i]
      of 'T': TileTree
      of 'R': TileRock
      else: TileEmpty
  result.tallGrass = newSeq[bool](result.width * result.height)
  let grass = world{"grass"}
  if not grass.isNil and grass.kind == JArray:
    for entry in grass:
      if entry.kind == JArray and entry.len >= 2:
        let
          x = entry[0].getInt()
          y = entry[1].getInt()
        if x >= 0 and y >= 0 and x < result.width and y < result.height:
          result.tallGrass[y * result.width + x] = true
  let berries = world{"berries"}
  if not berries.isNil and berries.kind == JArray:
    for entry in berries:
      if entry.kind == JArray and entry.len >= 2:
        result.berryTiles.add((entry[0].getInt(), entry[1].getInt()))

  let cfg = node{"config"}
  result.config = defaultGameConfig()
  if not cfg.isNil:
    result.config.numAgents = cfg{"num_agents"}.getInt(6)
    result.config.seed = cfg{"seed"}.getInt(result.seed)
    result.config.variant = cfg{"variant"}.getStr(result.variant)
    result.config.rounds = cfg{"rounds"}.getInt(3)
    result.config.ticksPerRound = cfg{"ticksPerRound"}.getInt(960)
    result.config.tickHz = cfg{"tickHz"}.getInt(8)

  let seats = node{"seats"}
  if not seats.isNil and seats.kind == JArray:
    for seat in seats:
      result.seats.add(ReplaySeat(
        slot: seat{"slot"}.getInt(),
        alias: seat{"alias"}.getStr(),
        name: seat{"name"}.getStr(),
        kind: seat{"kind"}.getStr("scripted"),
        baseline: seat{"baseline"}.getStr(),
        color: seat{"color"}.getInt(),
        level: seat{"level"}.getInt(1),
        disconnected: seat{"disconnected"}.getBool()
      ))

  let rounds = node{"rounds"}
  if not rounds.isNil and rounds.kind == JArray:
    for entry in rounds:
      var roles: seq[string] = @[]
      let rolesNode = entry{"roles"}
      if not rolesNode.isNil and rolesNode.kind == JArray:
        for role in rolesNode:
          roles.add(role.getStr())
      result.roundRoles.add(roles)

  let ticks = node{"ticks"}
  if ticks.isNil or ticks.kind != JArray:
    raise newException(ValueError, "replay has no ticks array")
  var lastQ: JsonNode = newJArray()
  var lastC: JsonNode = newJArray()
  var roundNo = 1
  var phase = "play"
  for entry in ticks:
    var frame = ReplayTick(tick: entry{"t"}.getInt())
    if entry.hasKey("r"):
      roundNo = entry["r"].getInt()
    if entry.hasKey("ph"):
      phase = entry["ph"].getStr()
    frame.roundNo = roundNo
    frame.phase = phase
    frame.p = entry{"p"}
    if entry.hasKey("q"):
      lastQ = entry["q"]
    if entry.hasKey("c"):
      lastC = entry["c"]
    frame.q = lastQ
    frame.c = lastC
    frame.ev = (if entry.hasKey("ev"): entry["ev"] else: newJArray())
    result.ticks.add(frame)

proc initSimFromDoc*(doc: ReplayDoc): SimServer =
  ## A world with the recorded map and seats and no dynamic state; the caller
  ## then calls `applyTick` for each frame.
  var config = doc.config
  config.players = @[]
  for seat in doc.seats:
    config.players.add(seat.name)
  result.config = config
  result.applyVariant()
  result.tiles = doc.tiles
  result.tallGrass = doc.tallGrass
  result.phase = RoundPlaying
  for seat in doc.seats:
    result.players.add(Player(
      id: seat.slot,
      name: seat.name,
      alias: seat.alias,
      slot: seat.slot,
      colorIndex: seat.color,
      level: seat.level,
      facing: FaceDown,
      energy: StartEnergy,
      kind: (if seat.kind == "prompt": pkPrompt else: pkScripted)
    ))

proc applyTick*(sim: var SimServer, doc: ReplayDoc, index: int) =
  ## Rebuild the tick's simulation state from the recorded arrays, then
  ## re-derive the side stamps from the player positions so the capture
  ## indicators and the gold countdown ring render exactly as they did live.
  if index < 0 or index >= doc.ticks.len:
    return
  let frame = doc.ticks[index]
  sim.globalTick = frame.tick
  sim.roundIndex = max(0, frame.roundNo - 1)
  # The tick WITHIN the round, so the viewer's clock can print real play
  # numbers ("1080 / 2880") rather than a global frame index.
  var roundStart = 1
  for entry in doc.raw{"rounds"}:
    if entry{"n"}.getInt() == frame.roundNo:
      roundStart = entry{"startTick"}.getInt(1)
  sim.tickCount = max(1, min(frame.tick - roundStart + 1,
    sim.config.ticksPerRound))
  sim.phase = (if frame.phase == "card": RoundEnding else: RoundPlaying)

  if not frame.p.isNil and frame.p.kind == JArray:
    for i in 0 ..< min(frame.p.len, sim.players.len):
      let row = frame.p[i]
      if row.kind != JArray or row.len < 6:
        continue
      sim.players[i].tileX = row[0].getInt()
      sim.players[i].tileY = row[1].getInt()
      sim.players[i].facing = Facing(row[2].getInt() mod 4)
      sim.players[i].energy = row[3].getInt()
      sim.players[i].score = row[4].getInt()
      let flags = row[5].getInt()
      sim.players[i].killGlow =
        (if (flags and FlagKillGlow) != 0: KillGlowTicks else: 0)
      sim.players[i].trampleGlow =
        (if (flags and FlagHurtGlow) != 0: TrampleGlowTicks else: 0)
      # The gore shove rides the same bit playersArray writes it from, so a
      # re-derived tick carries it too: without this the re-derivation
      # silently dropped the flag on every tick a hunter was being pushed.
      sim.players[i].pushStep =
        (if (flags and FlagAlerted) != 0: MooseGutAnimSteps else: 0)
      sim.players[i].disconnected = (flags and FlagDisconnected) != 0
      if sim.isPredatorPrey() and sim.roundIndex < doc.roundRoles.len and
          i < doc.roundRoles[sim.roundIndex].len:
        sim.players[i].role =
          if doc.roundRoles[sim.roundIndex][i] == "forager": roleForager
          else: roleHunter

  sim.prey.setLen(0)
  sim.items.setLen(0)
  sim.berries.setLen(0)
  if not frame.q.isNil and frame.q.kind == JArray:
    for row in frame.q:
      if row.kind != JArray or row.len < 5:
        continue
      let
        id = row[0].getInt()
        kindOrd = row[1].getInt()
        x = row[2].getInt()
        y = row[3].getInt()
        flags = row[4].getInt()
      if kindOrd in 0 .. 4:
        sim.prey.add(Prey(
          id: id, kind: PreyKind(kindOrd), tileX: x, tileY: y,
          alertFlash: (if (flags and FlagAlerted) != 0: AlertFlashTicks else: 0)
        ))
      elif kindOrd in QIron .. QFood:
        sim.items.add(Item(
          id: id,
          kind: (case kindOrd
                 of QIron: itIron
                 of QGold: itGold
                 else: itFood),
          tileX: x, tileY: y, level: (flags shr 8) and 0xf
        ))
      elif kindOrd in QBerryRipe .. QBerryPicked:
        sim.berries.add(Berry(
          tileX: x, tileY: y,
          regrow: (if kindOrd == QBerryRipe: 0 else: BerryRegrowTicks)
        ))

  sim.corpses.setLen(0)
  if not frame.c.isNil and frame.c.kind == JArray:
    for row in frame.c:
      if row.kind != JArray or row.len < 3:
        continue
      sim.corpses.add(Corpse(
        tileX: row[0].getInt(), tileY: row[1].getInt(),
        ticksRemaining: row[2].getInt()
      ))

  sim.restampSides()

proc allBeats*(doc: ReplayDoc): seq[tuple[tick: int, kind: string]] =
  ## Every scrubber beat in the whole replay, shipped complete on the first
  ## frame (paintbot's ingestBeats pattern) so the timeline tells the story
  ## before playback reaches it.
  for frame in doc.ticks:
    if frame.ev.isNil or frame.ev.kind != JArray:
      continue
    for event in frame.ev:
      let kind = beatKindForEvent(event{"ev"}.getStr(), event)
      if kind.len > 0:
        result.add((frame.tick, kind))
