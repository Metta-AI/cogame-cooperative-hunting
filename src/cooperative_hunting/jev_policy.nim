## Jev chooses a visible target and side inside the player process.

import std/[algorithm, json, os, strutils, tables]
import curly
import ./baselines
import ./sim_types

const
  MaxJevPreyTargets = 40 # five choices each, plus players and baseline: below 255
  Sides = ["N", "S", "E", "W", "any"]

type
  JevAction* = object
    intent*: string
    target*: string
    side*: string
    targetX*: int
    targetY*: int

  JevMenu* = OrderedTable[string, JevAction]

proc targetName(sight: PreySight): string =
  if sight.isAnimal:
    return preyLabel(sight.kind).toLowerAscii()
  case sight.itemSprite
  of IronSpriteId: "iron"
  of GoldSpriteId: "gold"
  of BerryRipeSpriteId: "berries"
  else: "food"

proc jevMenu*(
  bot: Bot, variant, role: string, playerRoles: Table[int, string]
): JevMenu =
  result = initOrderedTable[string, JevAction]()
  result["baseline"] = JevAction(target: "none", side: "any")
  var targets = bot.visiblePrey()
  targets.sort(proc(a, b: PreySight): int =
    let aDistance = abs(a.tileX - bot.selfTileX) +
      abs(a.tileY - bot.selfTileY)
    let bDistance = abs(b.tileX - bot.selfTileX) +
      abs(b.tileY - bot.selfTileY)
    result = cmp(aDistance, bDistance)
    if result == 0:
      result = cmp(a.objectId, b.objectId)
  )
  for sight in targets[0 ..< min(targets.len, MaxJevPreyTargets)]:
    if (role == "forager") != (sight.itemSprite == BerryRipeSpriteId):
      continue
    let target = sight.targetName() & "@" & $sight.tileX & "," &
      $sight.tileY
    if sight.itemSprite == BerryRipeSpriteId:
      result[target & "|on"] = JevAction(
        intent: "forage", target: target, side: "on",
        targetX: sight.tileX, targetY: sight.tileY)
      continue
    for side in Sides:
      result[target & "|" & side] = JevAction(
        intent: (if sight.isAnimal: "hunt" else: "forage"),
        target: target, side: side, targetX: sight.tileX,
        targetY: sight.tileY)
  if role == "hunter":
    for player in bot.visiblePlayers():
      if player.objectId == bot.selfObjectId:
        continue
      if variant == "predator-prey" and
          (not playerRoles.hasKey(player.objectId) or
           playerRoles[player.objectId] != "forager"):
        continue
      let target = "player-" & $player.objectId & "@" &
        $player.tileX & "," & $player.tileY
      for side in Sides:
        result[target & "|" & side] = JevAction(
          intent: "regroup", target: target, side: side,
          targetX: player.tileX, targetY: player.tileY)

proc selectedAction*(payload: JsonNode, menu: JevMenu): JevAction =
  let answer = payload["answers"]["decision"]
  let probabilities = answer["probabilities"]
  doAssert answer["type"].getStr() == "choice"
  doAssert probabilities.len == menu.len
  var total = 0.0
  var best = -1.0
  var selected = ""
  for choice, probability in probabilities.pairs:
    doAssert menu.hasKey(choice)
    let value = probability.getFloat()
    doAssert value >= 0 and value <= 1
    total += value
    if value > best:
      best = value
      selected = choice
  doAssert abs(total - 1) <= 0.01
  result = menu[selected]

proc chooseJevAction*(
  bot: Bot, slot: int, variant, role: string,
  playerRoles: Table[int, string]
): JevAction =
  let menu = bot.jevMenu(variant, role, playerRoles)
  var criteria = newJObject()
  for choice, action in menu.pairs:
    criteria[choice] = %(if choice == "baseline":
      "Use the compiled big-game hunter policy this turn."
    else:
      "Pursue " & action.target & " from side " & action.side &
      "; distance " & $(abs(action.targetX - bot.selfTileX) +
        abs(action.targetY - bot.selfTileY)))

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  let endpoint =
    if sidecar.len > 0: sidecar
    elif capture.len > 0: capture
    else: getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
  let model =
    if sidecar.len > 0: "typesafe/jev-1.13"
    elif capture.len > 0: getEnv("METTA_CAPTURE_MODEL", "jev-latest")
    else: getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
  let key =
    if sidecar.len > 0: ""
    elif capture.len > 0: getEnv("METTA_CAPTURE_KEY").strip()
    else: getEnv("TYPESAFE_API_KEY").strip()
  doAssert sidecar.len > 0 or key.len > 0,
    "Cooperative Hunting Jev policy has no model transport"

  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $slot
  var seenPlayers = newJArray()
  for player in bot.visiblePlayers():
    if playerRoles.hasKey(player.objectId):
      seenPlayers.add(%*{"object_id": player.objectId,
        "x": player.tileX, "y": player.tileY,
        "self": player.objectId == bot.selfObjectId,
        "role": playerRoles[player.objectId]})
  let body = %*{
    "model": model,
    "state": "You are a " & role & " in Cooperative Hunting variant " &
      variant & ". Choose a target and a side using only your seat-visible " &
      "sprites. Rabbits and iron can score solo; larger prey and gold need " &
      "allies on distinct sides. Foragers score on ripe berries. Visible " &
      "player roles are shown for visible players only. " &
      "A half-formed ring can lose energy. The player executor navigates " &
      "toward your choice until the next planning turn. Your tile is (" &
      $bot.selfTileX & "," & $bot.selfTileY & "), energy " &
      $(if bot.energyKnown: bot.energy else: -1) & ". Visible players: " &
      $seenPlayers,
    "questions": {"decision": {
      "type": "choice",
      "instructions": "Choose the plan most likely to increase your score.",
      "criteria": criteria
    }}
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, 30)
  doAssert response.code >= 200 and response.code < 300,
    "Jev HTTP " & $response.code
  let payload = parseJson(response.body)
  result = selectedAction(payload, menu)
  echo "Cooperative Hunting Jev player: target ", result.target,
    " side ", result.side, " input_tokens ",
    payload["usage"]{"input_tokens"}.getInt(), " output_tokens ",
    payload["usage"]{"output_tokens"}.getInt()
