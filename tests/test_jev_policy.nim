import std/[json, strutils, tables]
import cooperative_hunting/[art, baselines, frames, jev_policy, sim,
  sim_types]

for variant in ["staghunt", "coop-mining", "lbf", "predator-prey"]:
  var config = defaultGameConfig()
  config.variant = variant
  config.numAgents = 6
  config.seed = 5743127
  var sim = initSim(config)
  sim.art.buildSpriteCache()
  for slot in 0 ..< config.numAgents:
    discard sim.addPlayer("p" & $slot, aliasForSlot(slot), slot)
  sim.ensureStats(config.numAgents)
  sim.applyRolesPublic()

  var bot = initBot(bkBigGameHunter, 0)
  var state = ViewerState()
  var nextState: ViewerState
  let frame = sim.buildPlayerFrame(0, state, nextState)
  state = nextState
  var blob = newString(frame.len)
  for index, byte in frame:
    blob[index] = char(byte)
  doAssert bot.applySpritePacket(blob)
  bot.deriveCamera()
  bot.findSelf(bot.visiblePlayers())
  doAssert bot.cameraKnown and bot.selfFound
  let targetX =
    if bot.selfTileX + 1 < WorldWidthTiles: bot.selfTileX + 1
    else: bot.selfTileX - 1
  bot.objects.setLen(max(bot.objects.len, PreyObjectBase + 1))
  bot.objects[PreyObjectBase] = ObjectState(present: true,
    x: targetX * StagTileSize - bot.cameraX,
    y: bot.selfTileY * StagTileSize - bot.cameraY,
    spriteId: PreySpriteBase)

  let menu = bot.jevMenu()
  doAssert menu.len > 1 and menu.len <= 255
  doAssert menu.hasKey("baseline")
  var selected = ""
  for name, action in menu.pairs:
    if name == "baseline":
      continue
    doAssert action.target != "none"
    var visible = false
    for sight in bot.visiblePrey():
      if sight.tileX == action.targetX and sight.tileY == action.targetY:
        visible = true
    for player in bot.visiblePlayers():
      if player.objectId != bot.selfObjectId and
          player.tileX == action.targetX and
          player.tileY == action.targetY:
        visible = true
    doAssert visible
    if selected.len == 0 and action.target.startsWith("rabbit@"):
      selected = name
  doAssert selected.len > 0

  var probabilities = newJObject()
  for name in menu.keys:
    probabilities[name] = %(if name == selected: 1.0 else: 0.0)
  let payload = %*{"answers": {"decision": {
    "type": "choice", "choice": selected, "probabilities": probabilities
  }}}
  let action = selectedAction(payload, menu)
  doAssert action.target != "none" and action.side.len > 0

echo "Cooperative Hunting Jev policy menu: four variants passed"
