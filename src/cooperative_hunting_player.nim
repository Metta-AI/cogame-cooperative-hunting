## The one player binary. Same image, same entrypoint, switched by env:
##
##   PLAYER_PROMPT=<strategy>       an LLM prompt policy. The player
##                                  registers the prompt with the game and
##                                  executes the plans it gets back.
##   PLAYER_SCRIPTED=<name>         one of the eight compiled baselines.
##   PLAYER_FALLBACK_SCRIPTED=<n>   what a prompt seat plays between plans
##                                  and whenever a plan is unusable
##                                  (default big_game_hunter).
##
## Skeleton from `Metta-AI/coworld-staghunt` `players/rabbiteer/rabbiteer.nim`
## (connect URL building, the drain loop, the input packet). The executor is
## the design note's: the plan chooses WHAT and WITH WHOM, this chooses which
## tile next, using the same `findKillSpot` / `bestCaptureSide` / `navigate`
## the bundled bots use.

import std/[json, options, os, parseopt, strutils, unicode]
import whisky
import bitworld/protocol
import cooperative_hunting/sim_types
import cooperative_hunting/baselines

const
  PlayerWebSocketPath = "/player"
  ConnectRetryDelayMs = 250
  MaxConnectAttempts = 240   ## 60 s of retries, then give up and exit 0
  ## Every wait in this binary is bounded (checklist item 5). The socket read
  ## below used to be `receiveMessage(-1)`, which blocks forever: it was
  ## bounded only by the game closing the socket, so a game that stopped
  ## sending without closing left the container hanging until the platform
  ## killed the episode. 5 s is 40 frames at the 8 Hz tick, so it never fires
  ## during play; the roster wait before the first frame is 45 s, so 120 s of
  ## total silence is comfortably longer than any legitimate quiet stretch.
  ReceiveTimeoutMs = 5_000
  MaxIdleReceiveMs = 120_000

type
  Policy = object
    isPrompt: bool
    prompt: string
    baseline: BaselineKind

  ActivePlan = object
    valid: bool
    turn: int
    intent: string
    target: string
    side: string
    targetX: int
    targetY: int
    hasCoords: bool

# ---------------------------------------------------------------------------
# Policy selection
# ---------------------------------------------------------------------------

proc resolvePolicy(): Policy =
  let prompt = getEnv("PLAYER_PROMPT").strip()
  let scripted = getEnv("PLAYER_SCRIPTED").strip()
  let fallback = getEnv("PLAYER_FALLBACK_SCRIPTED").strip()
  # PLAYER_FALLBACK_SCRIPTED is what a PROMPT seat plays between plans and
  # when a plan falls back; PLAYER_SCRIPTED is what a scripted seat plays,
  # full stop. Reading the fallback first made it override PLAYER_SCRIPTED on
  # a seat that carries both, so a scripted seat would have played a bot
  # nobody asked it to play.
  result.baseline =
    if scripted.len > 0 and prompt.len == 0: parseBaselineKind(scripted)
    elif fallback.len > 0: parseBaselineKind(fallback)
    elif scripted.len > 0: parseBaselineKind(scripted)
    else: bkBigGameHunter
  if prompt.len > 0:
    result.isPrompt = true
    result.prompt = runeCap(prompt, MaxPromptRunes)

proc registrationBody(policy: Policy): string =
  if policy.isPrompt:
    $(%*{"kind": "prompt", "prompt": policy.prompt})
  else:
    $(%*{"kind": "scripted", "baseline": baselineName(policy.baseline)})

proc registrationPacket(policy: Policy): string =
  ## `0x90 <u16 len little-endian> <len bytes UTF-8 JSON>`, len <= 4096.
  var body = policy.registrationBody()
  if body.len > MaxRegistrationBytes:
    body = $(%*{"kind": "scripted", "baseline": "big_game_hunter"})
  var bytes: seq[uint8] = @[0x90'u8]
  bytes.add(uint8(body.len and 0xff))
  bytes.add(uint8((body.len shr 8) and 0xff))
  for ch in body:
    bytes.add(uint8(ord(ch)))
  blobFromBytes(bytes)

# ---------------------------------------------------------------------------
# The executor: a plan turned into per-tick masks
# ---------------------------------------------------------------------------

proc parsePlanMessage(data: string): ActivePlan =
  ## `0x91 <u16 len> <len bytes UTF-8 JSON>`.
  if data.len < 3 or data[0].uint8 != 0x91'u8:
    return
  let length = int(data[1].uint8) or (int(data[2].uint8) shl 8)
  if length <= 0 or data.len < 3 + length:
    return
  let body = data[3 ..< 3 + length]
  if validateUtf8(body) != -1:
    return
  try:
    let node = parseJson(body)
    result.turn = node{"turn"}.getInt()
    result.intent = node{"intent"}.getStr("hunt")
    result.target = node{"target"}.getStr("none")
    result.side = node{"side"}.getStr("any")
    result.valid = true
    let at = result.target.rfind('@')
    if at > 0 and at + 1 < result.target.len:
      let coords = result.target[at + 1 .. ^1].split(',')
      if coords.len == 2:
        try:
          result.targetX = parseInt(coords[0].strip())
          result.targetY = parseInt(coords[1].strip())
          result.hasCoords = true
        except ValueError:
          result.hasCoords = false
  except CatchableError:
    result.valid = false

proc sideOffset(side: string): tuple[dx, dy: int, found: bool] =
  case side.toUpperAscii()
  of "N": (0, -1, true)
  of "S": (0, 1, true)
  of "E": (1, 0, true)
  of "W": (-1, 0, true)
  else: (0, 0, false)

proc preyKindOfTarget(target: string): PreyKind =
  ## The plan's target id starts with the thing's own name. Ore and food map
  ## onto the coalition sizes the side chooser understands: iron and berries
  ## behave like a rabbit, gold and food like a boar.
  let head = target.split('@')[0].toLowerAscii()
  if head.startsWith("rabbit") or head.startsWith("iron") or
      head.startsWith("berries"): Rabbit
  elif head.startsWith("boar") or head.startsWith("gold") or
      head.startsWith("food"): Boar
  elif head.startsWith("stag") or head.startsWith("cog-"): Stag
  elif head.startsWith("moose"): Moose
  elif head.startsWith("elephant"): Elephant
  else: Boar

proc decideWithPlan(
  bot: var Bot, plan: ActivePlan, fallback: BaselineKind
): uint8 =
  ## Priority order: a capture this tick, then energy, then the plan, then
  ## the fallback baseline. If the target has disappeared the hunter holds
  ## position until the next plan rather than wandering off it.
  bot.deriveCamera()
  if not bot.cameraKnown:
    bot.intent = "no camera"
    return 0
  let players = bot.visiblePlayers()
  bot.findSelf(players)
  if not bot.selfFound:
    bot.intent = "no self"
    return 0
  bot.updateObstacleMap()

  let killSpot = bot.findKillSpot()
  if killSpot.found:
    bot.intent = "kill spot at (" & $killSpot.x & "," & $killSpot.y & ")"
    if bot.selfTileX == killSpot.x and bot.selfTileY == killSpot.y:
      bot.updateStuckState(0)
      return 0
    return bot.navigate(killSpot.x, killSpot.y)

  if bot.restGate():
    bot.intent = "resting (energy " & $bot.energy & ")"
    bot.updateStuckState(0)
    return 0

  if not plan.valid or plan.target == "none" or not plan.hasCoords:
    var scripted = bot
    scripted.kind = fallback
    let mask = scripted.decideMask()
    bot = scripted
    bot.intent = "no usable plan; " & baselineName(fallback) & ": " & bot.intent
    return mask

  # Is the named thing still there? The plan carries the tile it was on;
  # accept anything within one tile of it so a step of drift does not throw
  # the whole plan away.
  var stillThere = false
  for p in bot.visiblePrey():
    if chebyshev(p.tileX, p.tileY, plan.targetX, plan.targetY) <= 1:
      stillThere = true
      break
  if not stillThere:
    for p in players:
      if p.objectId == bot.selfObjectId:
        continue
      if chebyshev(p.tileX, p.tileY, plan.targetX, plan.targetY) <= 1:
        stillThere = true
        break
  if not stillThere:
    bot.intent = "plan target gone; holding for the next plan"
    bot.updateStuckState(0)
    return 0

  let kind = preyKindOfTarget(plan.target)
  var goalX = plan.targetX
  var goalY = plan.targetY
  let offset = sideOffset(plan.side)
  if offset.found:
    goalX = plan.targetX + offset.dx
    goalY = plan.targetY + offset.dy
  else:
    let side = bestCaptureSide(bot.selfTileX, bot.selfTileY, plan.targetX,
      plan.targetY, kind, players)
    if side.found:
      goalX = side.x
      goalY = side.y
    elif kind == Rabbit:
      # Solo capture: any cardinal side does, so walk at the thing itself
      # and let the 1-dot indicator finish the job.
      goalX = plan.targetX
      goalY = plan.targetY

  bot.intent = plan.intent & " " & plan.target & " side=" & plan.side
  if bot.selfTileX == goalX and bot.selfTileY == goalY:
    bot.updateStuckState(0)
    return 0
  bot.navigate(goalX, goalY)

# ---------------------------------------------------------------------------
# Connection
# ---------------------------------------------------------------------------

proc queryEscape(value: string): string =
  const Hex = "0123456789ABCDEF"
  for ch in value:
    if ch.isAlphaNumeric() or ch in {'-', '_', '.', '~'}:
      result.add(ch)
    else:
      let byteValue = ord(ch)
      result.add('%')
      result.add(Hex[(byteValue shr 4) and 0x0f])
      result.add(Hex[byteValue and 0x0f])

proc withPath(url, path: string): string =
  let schemePos = url.find("://")
  if schemePos < 0:
    return url
  let pathStart = url.find('/', schemePos + 3)
  if pathStart >= 0:
    return url
  url & path

proc addQueryParam(url, key, value: string): string =
  if value.len == 0:
    return url
  result = url
  if '?' in result:
    result.add('&')
  else:
    result.add('?')
  result.add(key)
  result.add('=')
  result.add(value.queryEscape())

proc connectUrl(address, url, name, token: string, port, slot: int): string =
  if url.len > 0:
    result = url.withPath(PlayerWebSocketPath)
  else:
    result = "ws://" & address & ":" & $port & PlayerWebSocketPath
  result = result.addQueryParam("name", name)
  if slot >= 0:
    result = result.addQueryParam("slot", $slot)
  if token.len > 0:
    result = result.addQueryParam("token", token)

proc playerInputBlob(mask: uint8): string =
  blobFromBytes([0x84'u8, mask and 0x7f'u8])

proc runPlayer(
  address, url, name, token: string, port, slot: int, policy: Policy
) =
  let endpoint = connectUrl(address, url, name, token, port, slot)
  var attempts = 0
  while true:
    var connected = false
    try:
      echo "cooperative-hunting-player connecting to ", endpoint,
        " policy=",
        (if policy.isPrompt: "prompt" else: baselineName(policy.baseline))
      var bot = initBot(policy.baseline, slot)
      var plan = ActivePlan()
      let ws = newWebSocket(endpoint)
      connected = true
      ws.send(registrationPacket(policy), BinaryMessage)
      var lastMask = 0xff'u8
      var idleMs = 0
      while true:
        # whisky's receiveMessage RAISES on a close frame or a truncated
        # read (only a timeout returns none), and mummy's send only queues,
        # so the game's quit(0) can outrun the flushed frame. Catching here
        # and exiting 0 is what keeps the player container's exit code 0
        # (raid 0.1.3 -> 0.1.4).
        let first = ws.receiveMessage(ReceiveTimeoutMs)
        if first.isNone:
          idleMs += ReceiveTimeoutMs
          if idleMs >= MaxIdleReceiveMs:
            echo "cooperative-hunting-player: no frame for ",
              MaxIdleReceiveMs div 1000, " s; exiting 0"
            quit(0)
          continue
        idleMs = 0
        var applied = false
        var message = first
        var drained = 0
        while true:
          if message.isSome:
            let data = message.get.data
            if message.get.kind == BinaryMessage and data.len > 0:
              if data[0].uint8 == 0x91'u8:
                let next = parsePlanMessage(data)
                if next.valid:
                  plan = next
              elif bot.applySpritePacket(data):
                inc bot.frameTick
                applied = true
            elif message.get.kind == Ping:
              ws.send(message.get.data, Pong)
          inc drained
          if drained >= MaxDrainMessages:
            break
          message = ws.receiveMessage(0)
          if message.isNone:
            break
        if not applied:
          continue
        let mask =
          if policy.isPrompt: bot.decideWithPlan(plan, policy.baseline)
          else: bot.decideMask()
        if mask != lastMask:
          ws.send(playerInputBlob(mask), BinaryMessage)
          lastMask = mask
    except CatchableError as error:
      if connected:
        echo "cooperative-hunting-player: socket closed (", error.msg,
          "); exiting 0"
        quit(0)
      inc attempts
      if attempts >= MaxConnectAttempts:
        echo "cooperative-hunting-player: could not reach ", endpoint,
          " after ", attempts, " attempts; exiting 0"
        quit(0)
      sleep(ConnectRetryDelayMs)

when isMainModule:
  var
    address = DefaultHost
    port = DefaultPort
    url = getEnv("COWORLD_PLAYER_WS_URL")
    name = getEnv("PLAYER_NAME")
    token = ""
    slot = -1

  for kind, key, value in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address": address = value
      of "port": port = parseInt(value)
      of "url": url = value
      of "name": name = value
      of "token": token = value
      of "slot": slot = parseInt(value)
      else: discard
    else: discard

  let policy = resolvePolicy()
  if name.len == 0:
    name =
      if policy.isPrompt: "cooperative-hunting-prompt"
      else: baselineName(policy.baseline)
  runPlayer(address, url, name, token, port, slot, policy)
