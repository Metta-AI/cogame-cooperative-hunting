## The LLM half of a champion policy.
##
## Ported from `cogame-bullwhip/src/bullwhip/llm.nim`: same transport ladder
## (Bedrock sidecar via `AWS_ENDPOINT_URL_BEDROCK_RUNTIME` +
## `AWS_BEARER_TOKEN_BEDROCK`, else `ANTHROPIC_API_KEY`, else
## `ANTHROPIC_API_KEY_URI`, else disabled), same haiku-first model list, same
## `curly.makeRequests` ONE-parallel-batch shape, same tolerant parse ->
## retry once -> scripted fallback.
##
## Decisions in this game are SIMULTANEOUS, so every prompt seat's request
## goes out in the same batch. The batch has a 12 s deadline and the sim
## never waits on it: hunters keep executing their previous plan while it is
## in flight, so the LLM contributes 0 s to the critical path.
##
## With no credentials at all the client marks itself disabled at startup and
## makes ZERO network calls; every prompt seat plays the fallback baseline
## and the episode still completes with `reason: complete`.

import std/[algorithm, json, monotimes, os, sequtils, strutils, unicode]
import curly
import bitworld/cogame_runtime
import ./sim_types
import ./sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

  ## Rate discipline. Six seats per 15 s planning turn is 24 req/min against
  ## the sidecar's 30 req/min-per-episode cap; this rolling budget is the
  ## hard backstop that keeps a retry storm underneath it.
  RateBudgetRequests* = 28
  RateBudgetSeconds* = 60.0

  LegalIntents* = ["hunt", "assist", "forage", "rest", "regroup", "flee"]
  LegalSides* = ["N", "S", "E", "W", "any"]

  RetryHint* = "Your last reply was not usable. Reply with ONE JSON object " &
    "beginning with { and a target from LEGAL TARGETS."

  SystemPromptBase* = """You are one hunter in a six-hunter cooperative hunting party on a 32x32 forest grid.
Rabbits die to one hunter. Boars need two hunters on perpendicular sides at once, stags
two on opposite sides, moose any three sides, elephants all four. Everyone standing on a
side when the animal falls scores the full value, so a moose or an elephant is worth many
rabbits - but only if your allies commit to the same animal at the same time. A half-formed
ring gets trampled or gored and scores nothing.
You give one high-level plan; a controller walks you there tile by tile until your next plan.
Reply with a single JSON object and NOTHING else. Your reply MUST begin with the character {.
Schema:
{"intent":"hunt|assist|forage|rest|regroup|flee","target":"<one id from LEGAL TARGETS, or none>",
 "side":"N|S|E|W|any","with":["<ally alias>",...],"say":"<=120 chars","note":"<=200 chars"}
"say" is broadcast to spectators. "note" is private and is handed back to you next turn."""

type
  FallbackCause* = enum
    fcNone = ""
    fcTimeout = "timeout"
    fcParse = "parse"
    fcIllegalTarget = "illegal_target"
    fcRateBudget = "rate_budget"
    fcNoCredentials = "no_credentials"

  Plan* = object
    turn*: int
    intent*: string
    target*: string
    side*: string
    partners*: seq[string]
    say*: string
    note*: string
    src*: string          ## "llm" or "fallback:<cause>"

  PlanRequest* = object
    slot*: int
    system*: string
    user*: string

  PlanReply* = object
    slot*: int
    plan*: Plan
    ok*: bool
    cause*: FallbackCause
    error*: string

  LlmTransport* = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport*: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model*: string
    maxOutputTokens*: int
    timeoutSeconds*: int
    disabled*: bool
    requestTimes: seq[float]   ## monotonic seconds, for the rolling budget
    totalRequests*: int

  ChError* = object of CatchableError

# ---------------------------------------------------------------------------
# Credentials and transport
# ---------------------------------------------------------------------------

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    let path = pathFromCogameUri(uri, "ANTHROPIC_API_KEY_URI")
    if path.len > 0 and fileExists(path):
      result = readFile(path).strip()
  except CatchableError as error:
    echo "cooperative-hunting llm: failed to fetch ANTHROPIC_API_KEY_URI: ",
      error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Haiku leads: hosted Bedrock capacity is shared account-wide and the
  ## sonnet profiles run out of daily tokens first. `us.anthropic.
  ## claude-sonnet-4-6` is deliberately NOT a candidate -- it times out on
  ## every sidecar call and one throttle cascades into scripted fallbacks
  ## (raid round 2, 2026-08-23).
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "cooperative-hunting llm: ",
    client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.planTimeoutSeconds
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "cooperative-hunting llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel]
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "cooperative-hunting llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "cooperative-hunting llm: no LLM credentials; every prompt seat ",
      "plays the scripted fallback and no network call is made"

proc newDisabledLlmClient*(): LlmClient =
  ## The offline client used by the tests and by any episode with no
  ## credentials. Makes zero network calls, by construction.
  LlmClient(transport: ltNone, disabled: true, maxOutputTokens: 900,
    timeoutSeconds: 12, model: "claude-haiku-4-5")

proc monoSeconds(): float =
  float(getMonoTime().ticks) / 1_000_000_000.0

proc budgetAvailable*(client: LlmClient, wanted: int): bool =
  ## The hard rolling budget: at most `RateBudgetRequests` in any
  ## `RateBudgetSeconds` window, retries included.
  let now = monoSeconds()
  var live: seq[float] = @[]
  for t in client.requestTimes:
    if now - t < RateBudgetSeconds:
      live.add(t)
  client.requestTimes = live
  live.len + wanted <= RateBudgetRequests

proc noteRequests(client: LlmClient, count: int) =
  let now = monoSeconds()
  for _ in 0 ..< count:
    client.requestTimes.add(now)
  client.totalRequests += count

# ---------------------------------------------------------------------------
# Observation: composed from EXACTLY the per-seat visibility predicate, so a
# prompt seat can never see further than a scripted seat.
# ---------------------------------------------------------------------------

proc targetIdFor*(kind: PreyKind, x, y: int): string =
  preyLabel(kind) & "@" & $x & "," & $y

proc targetIdForItem*(item: Item): string =
  (case item.kind
   of itIron: "iron"
   of itGold: "gold"
   of itFood: "food" & $item.level) & "@" & $item.tileX & "," & $item.tileY

proc targetIdForForager*(player: Player): string =
  player.alias & "@" & $player.tileX & "," & $player.tileY

proc legalTargets*(sim: SimServer, seatIndex: int): seq[string] =
  ## Precomputed by the SAME predicate the validator applies: shipping the
  ## legal set in the observation is what actually fixes formal-output
  ## fallbacks (escrow 2026-08-23); prompt drills alone only halve them.
  if seatIndex < 0 or seatIndex >= sim.players.len:
    return @["none"]
  for i in 0 ..< sim.prey.len:
    if sim.preyVisibleToSeat(seatIndex, i):
      result.add(targetIdFor(sim.prey[i].kind, sim.prey[i].tileX,
        sim.prey[i].tileY))
  for i in 0 ..< sim.items.len:
    if sim.itemVisibleToSeat(seatIndex, i):
      result.add(targetIdForItem(sim.items[i]))
  if sim.isPredatorPrey():
    if sim.players[seatIndex].role == roleHunter:
      for i in 0 ..< sim.players.len:
        if i == seatIndex or sim.players[i].role != roleForager:
          continue
        if sim.visibleToSeat(seatIndex, i):
          result.add(targetIdForForager(sim.players[i]))
    else:
      let (cameraX, cameraY) = playerCamera(sim.players[seatIndex])
      for b in sim.berries:
        if b.regrow == 0 and tileInViewport(cameraX, cameraY, b.tileX, b.tileY):
          result.add("berries@" & $b.tileX & "," & $b.tileY)
          if result.len >= 12:
            break
  if result.len > 12:
    result.setLen(12)
  result.add("none")

proc sidesTakenText(sim: SimServer, stamps: array[4, SideStamp]): string =
  let sides = sim.occupiedSides(stamps)
  var taken: seq[string] = @[]
  for side in 0 ..< 4:
    if sides[side]:
      taken.add(SideNames[side])
  if taken.len == 0: "-" else: taken.join("")

proc coalitionText(kind: PreyKind): string =
  case kind
  of Rabbit: "needs 1"
  of Boar: "needs 2 (perpendicular sides)"
  of Stag: "needs 2 (opposite sides)"
  of Moose: "needs 3 (any sides)"
  of Elephant: "needs 4 (all sides)"

proc observationFor*(
  sim: SimServer,
  seatIndex: int,
  turn, turns: int,
  lastPlan: Plan,
  note: string,
  recent: seq[string],
  prompt: string
): string =
  ## Deterministic, bounded, and built from the per-seat visibility set.
  if seatIndex < 0 or seatIndex >= sim.players.len:
    return ""
  let me = sim.players[seatIndex]
  let roundNo = sim.roundIndex + 1
  result.add("TURN " & $turn & "/" & $turns & "  ROUND " & $roundNo & "/" &
    $sim.config.rounds & "  TICK " & $sim.tickCount & "/" &
    $sim.config.ticksPerRound & "  VARIANT " & sim.config.variant & "\n")
  result.add("YOU " & me.alias & " at (" & $me.tileX & "," & $me.tileY &
    ") facing " & (case me.facing
                   of FaceUp: "N"
                   of FaceDown: "S"
                   of FaceLeft: "W"
                   of FaceRight: "E") &
    " energy " & $me.energy & "/" & $MaxEnergy & " score " & $me.score &
    " level " & $me.level & " role " &
    (if me.role == roleHunter: "hunter" else: "forager") & "\n")

  result.add("PARTY VISIBLE (<=5 lines)\n")
  var partyLines = 0
  for i in 0 ..< sim.players.len:
    if i == seatIndex or partyLines >= 5:
      continue
    if not sim.visibleToSeat(seatIndex, i):
      continue
    result.add("  " & sim.players[i].alias & " (" & $sim.players[i].tileX &
      "," & $sim.players[i].tileY & ") d=" &
      $chebyshevDistance(me.tileX, me.tileY, sim.players[i].tileX,
        sim.players[i].tileY) & "\n")
    inc partyLines
  if partyLines == 0:
    result.add("  (nobody in sight)\n")

  result.add("ANIMALS VISIBLE (<=12 lines, nearest first)\n")
  var lines: seq[tuple[dist: int, text: string]] = @[]
  for i in 0 ..< sim.prey.len:
    if not sim.preyVisibleToSeat(seatIndex, i):
      continue
    let d = chebyshevDistance(me.tileX, me.tileY, sim.prey[i].tileX,
      sim.prey[i].tileY)
    lines.add((d, "  " & targetIdFor(sim.prey[i].kind, sim.prey[i].tileX,
      sim.prey[i].tileY) & " " & coalitionText(sim.prey[i].kind) &
      " sides taken: " & sim.sidesTakenText(sim.prey[i].sideSeen) &
      " d=" & $d & " worth " & $rewardsFor(sim.prey[i].kind).score))
  for i in 0 ..< sim.items.len:
    if not sim.itemVisibleToSeat(seatIndex, i):
      continue
    let d = chebyshevDistance(me.tileX, me.tileY, sim.items[i].tileX,
      sim.items[i].tileY)
    let need =
      case sim.items[i].kind
      of itIron: "needs 1"
      of itGold: "needs 2 (any sides, within 3 ticks)"
      of itFood: "needs adjacent levels summing to " & $sim.items[i].level
    let worth =
      case sim.items[i].kind
      of itIron: IronScoreReward
      of itGold: GoldScoreReward
      of itFood: LbfScorePerLevel * sim.items[i].level
    lines.add((d, "  " & targetIdForItem(sim.items[i]) & " " & need &
      " sides taken: " & sim.sidesTakenText(sim.items[i].sideSeen) &
      " d=" & $d & " worth " & $worth))
  if sim.isPredatorPrey():
    if me.role == roleHunter:
      for i in 0 ..< sim.players.len:
        if i == seatIndex or sim.players[i].role != roleForager:
          continue
        if not sim.visibleToSeat(seatIndex, i):
          continue
        let d = chebyshevDistance(me.tileX, me.tileY, sim.players[i].tileX,
          sim.players[i].tileY)
        lines.add((d, "  " & targetIdForForager(sim.players[i]) &
          " forager needs 2 (opposite sides) d=" & $d & " worth " &
          $TagScoreReward))
    else:
      let (cameraX, cameraY) = playerCamera(me)
      for b in sim.berries:
        if b.regrow != 0 or not tileInViewport(cameraX, cameraY, b.tileX,
            b.tileY):
          continue
        let d = chebyshevDistance(me.tileX, me.tileY, b.tileX, b.tileY)
        lines.add((d, "  berries@" & $b.tileX & "," & $b.tileY &
          " stand on it d=" & $d & " worth " & $BerryScoreReward))
  lines.sort(proc (a, b: tuple[dist: int, text: string]): int =
    cmp(a.dist, b.dist))
  if lines.len > 12:
    lines.setLen(12)
  if lines.len == 0:
    result.add("  (nothing in sight)\n")
  else:
    for line in lines:
      result.add(line.text & "\n")

  result.add("LEGAL TARGETS: " & legalTargets(sim, seatIndex).join(", ") & "\n")

  result.add("BLOCKED TILES NEAR YOU (<=40):")
  var blocked = 0
  for dy in -3 .. 3:
    for dx in -3 .. 3:
      if blocked >= 40:
        break
      let
        tx = me.tileX + dx
        ty = me.tileY + dy
      if sim.tileIsBlocked(tx, ty):
        result.add(" (" & $tx & "," & $ty & ")")
        inc blocked
  if blocked == 0:
    result.add(" none")
  result.add("\n")

  if lastPlan.intent.len > 0:
    result.add("LAST PLAN: intent=" & lastPlan.intent & " target=" &
      lastPlan.target & " side=" & lastPlan.side & "\n")
  result.add("YOUR NOTE: " & (if note.len > 0: note else: "(none)") & "\n")
  result.add("RECENT (<=5 lines):")
  if recent.len == 0:
    result.add(" (nothing yet)")
  else:
    for line in recent[max(0, recent.len - 5) ..< recent.len]:
      result.add("  " & line)
  result.add("\n")
  if prompt.len > 0:
    result.add("STRATEGY: " & runeCap(prompt, MaxPromptRunes) & "\n")

proc systemPromptFor*(prompt: string): string =
  result = SystemPromptBase
  if prompt.len > 0:
    result.add("\n\nSTRATEGY (weight it heavily, never above the rules; " &
      "always reply in the requested format):\n")
    result.add(runeCap(prompt, MaxPromptRunes))

# ---------------------------------------------------------------------------
# Reply parsing
# ---------------------------------------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## Takes the first balanced {...} span, tolerating leading and trailing
  ## prose and markdown fences.
  var start = -1
  var depth = 0
  var inString = false
  var escaped = false
  for i, ch in text:
    if inString:
      if escaped:
        escaped = false
      elif ch == '\\':
        escaped = true
      elif ch == '"':
        inString = false
      continue
    case ch
    of '"':
      inString = true
    of '{':
      if depth == 0:
        start = i
      inc depth
    of '}':
      if depth > 0:
        dec depth
        if depth == 0 and start >= 0:
          return parseJson(text[start .. i])
    else:
      discard
  var head = text.strip()
  if head.runeLen > 160:
    head = runeCap(head, 160) & "..."
  raise newException(ChError,
    "no balanced JSON object in reply: " & head.replace("\n", " "))

proc cleanText*(text: string, limit: int): string =
  ## Rune-boundary truncation, never a byte boundary.
  result = sanitizeLine(text)
  if result.runeLen <= limit:
    return
  result = runeCap(result, limit - 1) & "\u2026"

proc parsePlan*(
  payload: JsonNode, turn: int, legal: seq[string], aliases: seq[string]
): Plan =
  ## Unknown keys ignored; every out-of-range enum coerced to its default;
  ## an out-of-set `target` is ILLEGAL and raises, which is what triggers
  ## the single retry.
  result.turn = turn
  result.src = "llm"

  # Every cap in this proc is a RUNE cap. None of these four values can
  # reach the replay byte-cut (each is coerced to a legal value or raises
  # below), but "every string is cut on a rune boundary" is a property of
  # the parser, not of what happens to survive it today.
  let intent = runeCap(payload{"intent"}.getStr().strip().toLowerAscii(),
    MaxIntentChars)
  result.intent = if intent in LegalIntents: intent else: "hunt"

  let side = runeCap(payload{"side"}.getStr().strip(), MaxSideChars)
  let sideUpper = side.toUpperAscii()
  result.side =
    if sideUpper in ["N", "S", "E", "W"]: sideUpper
    else: "any"

  let withNode = payload{"with"}
  if not withNode.isNil and withNode.kind == JArray:
    for entry in withNode:
      if result.partners.len >= MaxWithItems:
        break
      let name = runeCap(entry.getStr().strip(), MaxWithChars)
      if name in aliases and name notin result.partners:
        result.partners.add(name)

  result.say = cleanText(payload{"say"}.getStr(), MaxSayRunes)
  result.note = cleanText(payload{"note"}.getStr(), MaxNoteRunes)

  var target = runeCap(payload{"target"}.getStr().strip(), MaxTargetChars)
  if target.len == 0:
    target = "none"
  if target notin legal:
    raise newException(ChError, "target not in LEGAL TARGETS: " & target)
  result.target = target

# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present, so it is never
    ## sent (playbook Phase 1).
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(
  client: LlmClient, response: Response, error, url: string
): string =
  if error.len > 0:
    raise newException(ChError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = response.body[0 .. min(response.body.high, 400)]
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(ChError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(ChError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body[0 .. min(response.body.high, 300)]
    discard client.tryNextBedrockModel("throttled")
    raise newException(ChError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(ChError, "anthropic error " & $response.code & ": " &
      response.body[0 .. min(response.body.high, 300)])
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(ChError, "anthropic refusal")
  let content = payload{"content"}
  if not content.isNil and content.kind == JArray:
    for contentBlock in content:
      if contentBlock{"type"}.getStr() == "text":
        result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(ChError, "reply cut off at max_tokens before any " &
      "JSON: " & result[0 .. min(result.high, 160)].replace("\n", " "))

proc runPlanBatch*(
  client: LlmClient,
  requests: seq[PlanRequest],
  legal: seq[seq[string]],
  aliases: seq[string],
  turn: int
): seq[PlanReply] =
  ## ONE parallel batch per planning turn, then at most ONE retry for the
  ## seats that failed. Never raises: every seat comes back with either a
  ## plan or a fallback cause.
  result = newSeq[PlanReply](requests.len)
  for i, request in requests:
    result[i] = PlanReply(slot: request.slot, ok: false, cause: fcNone)

  if requests.len == 0:
    return
  if client.isNil or client.disabled:
    for i in 0 ..< result.len:
      result[i].cause = fcNoCredentials
    return
  if not client.budgetAvailable(requests.len):
    for i in 0 ..< result.len:
      result[i].cause = fcRateBudget
    return

  var open = toSeq(0 ..< requests.len)
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    if attempt > 0 and not client.budgetAvailable(open.len):
      for index in open:
        result[index].cause = fcRateBudget
      return
    var batch: RequestBatch
    for index in open:
      var user = requests[index].user
      if attempt > 0:
        user.add("\n" & RetryHint)
      let request = client.requestFor(requests[index].system, user)
      batch.post(request.url, request.headers, request.body, $index)
    client.noteRequests(open.len)
    let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
    var stillOpen: seq[int] = @[]
    for position, index in open:
      try:
        let text = client.textOf(responses[position].response,
          responses[position].error, batch[position].url)
        result[index].plan = parsePlan(extractJsonObject(text), turn,
          legal[index], aliases)
        result[index].ok = true
        result[index].cause = fcNone
      except CatchableError as error:
        let message = runeCap(error.msg, MaxErrorRunes)
        result[index].error = message
        result[index].cause =
          if "LEGAL TARGETS" in message: fcIllegalTarget
          elif "transport" in message or "timed out" in message or
               "timeout" in message: fcTimeout
          else: fcParse
        echo "cooperative-hunting llm: slot ", requests[index].slot,
          " attempt ", attempt, " failed: ", message
        stillOpen.add(index)
    open = stillOpen
