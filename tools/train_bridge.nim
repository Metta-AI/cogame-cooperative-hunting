## Persistent low-level Sprite v1 bridge for Metta RL and native PufferLib.
## nim c -d:release --path:src -o:cooperative-hunting-train-bridge tools/train_bridge.nim

import std/[json, os, posix]
import bitworld/protocol
import bitworld/pathfinding
import cooperative_hunting
import cooperative_hunting/[sim, sim_types, frames, art, baselines]

const
  Variants = ["staghunt", "coop-mining", "lbf", "predator-prey"]
  Masks = [0, int(ButtonUp), int(ButtonDown), int(ButtonLeft), int(ButtonRight)]
  MaxVisibleTargets = 128
  MaxVisiblePlayers = 6

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32) + 1

proc heads(): JsonNode =
  %*[{"name": "mask", "choices": Masks}]

proc snapshot(bot: Bot, sim: SimServer, seat: int, variant: string):
    tuple[view, values: JsonNode] =
  var view = %*{
    "variant": variant, "round": sim.roundIndex + 1,
    "rounds": sim.config.rounds, "tick": sim.tickCount,
    "ticks_per_round": sim.config.ticksPerRound,
    "you": {"alias": sim.players[seat].alias, "tile_x": bot.selfTileX,
      "tile_y": bot.selfTileY, "energy": bot.energy,
      "score": sim.players[seat].score,
      "role": (if sim.players[seat].role == roleHunter: "hunter" else: "forager")},
    "terrain": newJArray(), "party": newJArray(), "targets": newJArray()
  }
  var values = newJArray()
  for name in Variants: values.add(%(if name == variant: 1 else: 0))
  for value in [sim.roundIndex + 1, sim.config.rounds, sim.tickCount,
      sim.config.ticksPerRound, bot.selfTileX, bot.selfTileY, bot.energy,
      sim.players[seat].score, (if sim.players[seat].role == roleHunter: 1 else: 0)]:
    values.add(%value)
  for ty in 0 ..< WorldHeightTiles:
    for tx in 0 ..< WorldWidthTiles:
      let status = %ord(bot.obstacleMap.getTile(tx, ty))
      view["terrain"].add(status)
      values.add(status)
  let players = bot.visiblePlayers()
  doAssert players.len <= MaxVisiblePlayers
  for i in 0 ..< MaxVisiblePlayers:
    if i < players.len:
      let player = players[i]
      view["party"].add(%*{"tile_x": player.tileX, "tile_y": player.tileY,
        "colour": player.color, "self": player.objectId == bot.selfObjectId})
      for value in [1, player.tileX, player.tileY, player.color,
          (if player.objectId == bot.selfObjectId: 1 else: 0)]: values.add(%value)
    else:
      for _ in 0 ..< 5: values.add(%0)
  let targets = bot.visiblePrey()
  doAssert targets.len <= MaxVisibleTargets
  for i in 0 ..< MaxVisibleTargets:
    if i < targets.len:
      let target = targets[i]
      view["targets"].add(%*{"tile_x": target.tileX, "tile_y": target.tileY,
        "kind": $target.kind, "animal": target.isAnimal,
        "item_sprite": target.itemSprite})
      for value in [1, target.tileX, target.tileY, ord(target.kind),
          (if target.isAnimal: 1 else: 0), target.itemSprite]: values.add(%value)
    else:
      for _ in 0 ..< 6: values.add(%0)
  (view, values)

proc decision(view: JsonNode, seat, id: int): JsonNode =
  %*{"kind": "decision", "game": "cooperative-hunting",
    "decision_id": id, "seat": seat, "engine_seat": seat,
    "turn": view["tick"], "semantic_view": view, "inbox": [],
    "messages": [], "speech_messages": [],
    "action_schema": {"type": "object", "properties": {
      "mask": {"enum": Masks}}, "required": ["mask"]},
    "typed_question": newJNull()}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2: quit("usage: cooperative-hunting-train-bridge MANIFEST VARIANT", 1)
  let variant = args[1]
  doAssert variant in Variants
  let manifest = parseFile(args[0])
  setCurrentDir(absolutePath(args[0]).parentDir)
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant: variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var config = parseGameConfig($variantConfig)
  doAssert config.numAgents == 6
  var game: SimServer
  var bots: array[6, Bot]
  var states: array[6, ViewerState]
  var views: array[6, JsonNode]
  var encodings: array[6, JsonNode]
  var teachers: array[6, int]
  var masks: array[6, int]
  var scores: array[6, int]
  var seat = 0
  var id = 0
  let protocolFd = dup(1)
  doAssert protocolFd >= 0 and dup2(2, 1) >= 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == 6
      config.seed = seedOf(request["seed"].getStr())
      game = initSim(config)
      game.art.buildSpriteCache()
      let aliases = seatAliases(6, config.seed)
      for actor in 0 ..< 6:
        discard game.addPlayer("policy-" & $actor, aliases[actor], actor, pkScripted)
      game.ensureStats(6)
      game.applyRolesPublic()
      for actor in 0 ..< 6:
        bots[actor] = initBot(bkBigGameHunter, config.seed + actor)
        states[actor] = ViewerState()
        scores[actor] = 0
      game.step(default(array[6, InputState]))
      seat = 0
      id = 0
      for actor in 0 ..< 6:
        var nextState: ViewerState
        let frame = game.buildPlayerFrame(actor, states[actor], nextState)
        states[actor] = nextState
        var blob = newString(frame.len)
        for i, value in frame: blob[i] = char(value)
        doAssert bots[actor].applySpritePacket(blob)
        inc bots[actor].frameTick
        teachers[actor] = int(bots[actor].decideMask())
        (views[actor], encodings[actor]) = snapshot(bots[actor], game, actor, variant)
      response = views[seat].decision(seat, id)
    of "encode":
      response = %*{"decision_id": id, "values": encodings[seat],
        "action_heads": heads()}
    of "teacher":
      response = %*{"response": $(%*{"mask": teachers[seat]})}
    of "step":
      doAssert request["decision_id"].getInt() == id
      let candidate = parseJson(request["response"].getStr())
      doAssert candidate["mask"] in heads()[0]["choices"]
      masks[seat] = candidate["mask"].getInt()
      inc id
      inc seat
      var observation: JsonNode
      if seat < 6:
        observation = views[seat].decision(seat, id)
      else:
        var inputs: array[6, InputState]
        for actor in 0 ..< 6: inputs[actor] = decodeInputMask(uint8(masks[actor]))
        game.step(inputs)
        if game.tickCount >= config.ticksPerRound:
          let finalRound = game.roundIndex + 1 >= config.rounds
          for actor in 0 ..< 6: scores[actor] += game.players[actor].score
          game.phase = RoundEnding
          for actor in 0 ..< 6: game.players[actor].overlayActive = true
          for actor in 0 ..< 6:
            var nextState: ViewerState
            let frame = game.buildPlayerFrame(actor, states[actor], nextState)
            states[actor] = nextState
            var blob = newString(frame.len)
            for i, value in frame: blob[i] = char(value)
            doAssert bots[actor].applySpritePacket(blob)
            inc bots[actor].frameTick
            teachers[actor] = int(bots[actor].decideMask())
          for cardTick in 1 .. RoundEndDisplayTicks:
            inc game.globalTick
            if cardTick == RoundEndDisplayTicks and not finalRound:
              game.startRound(game.roundIndex + 1)
              continue
            for actor in 0 ..< 6:
              var nextState: ViewerState
              let frame = game.buildPlayerFrame(actor, states[actor], nextState)
              states[actor] = nextState
              var blob = newString(frame.len)
              for i, value in frame: blob[i] = char(value)
              doAssert bots[actor].applySpritePacket(blob)
              inc bots[actor].frameTick
              teachers[actor] = int(bots[actor].decideMask())
          if finalRound:
            var resultScores = newJObject()
            var utilities = newJObject()
            var high = 1
            for score in scores: high = max(high, score)
            for actor in 0 ..< 6:
              resultScores[$actor] = %scores[actor]
              utilities[$actor] = %(2.0 * scores[actor].float / high.float - 1.0)
            observation = %*{"kind": "terminal", "scores": resultScores,
              "utilities": utilities}
        if observation.isNil:
          seat = 0
          for actor in 0 ..< 6:
            var nextState: ViewerState
            let frame = game.buildPlayerFrame(actor, states[actor], nextState)
            states[actor] = nextState
            var blob = newString(frame.len)
            for i, value in frame: blob[i] = char(value)
            doAssert bots[actor].applySpritePacket(blob)
            inc bots[actor].frameTick
            teachers[actor] = int(bots[actor].decideMask())
            (views[actor], encodings[actor]) = snapshot(bots[actor], game, actor, variant)
          observation = views[seat].decision(seat, id)
      response = %*{"kind": "accepted", "action": candidate,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.flushFile()
    doAssert dup2(protocolFd, 1) >= 0
    stdout.writeLine($response)
    stdout.flushFile()
    doAssert dup2(2, 1) >= 0
