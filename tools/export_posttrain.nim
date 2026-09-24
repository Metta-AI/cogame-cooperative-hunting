## Export hosted plan decisions from complete scripted Cooperative Hunting games.
## nim r -d:release --path:src tools/export_posttrain.nim OUTPUT EPISODES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import bitworld/protocol
import cooperative_hunting
import cooperative_hunting_player
import cooperative_hunting/[sim, sim_types, frames, art, baselines, llm, replay]

const
  Variants = ["staghunt", "coop-mining", "lbf", "predator-prey"]
  OperatorPrompt = "Coordinate with visible hunters and collect reachable rewards."

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT EPISODES [FIRST_SEED] [VARIANT]", 1)
  let output = absolutePath(args[0])
  let episodes = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: "staghunt"
  if episodes < 10 or firstSeed < 1:
    quit("at least ten episodes and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown certified variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant: variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  createDir(output)
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + episodes:
    var config = parseGameConfig($variantConfig)
    config.seed = seed
    var game = initSim(config)
    game.art.buildSpriteCache()
    let aliases = seatAliases(6, seed)
    for actor in 0 ..< 6:
      discard game.addPlayer("policy-" & $actor, aliases[actor], actor, pkPrompt)
    game.ensureStats(6)
    game.applyRolesPublic()
    game.logEvent("round_start", %*{
      "round": 1, "seed": seed, "ticks": config.ticksPerRound})
    for actor in 0 ..< 6:
      game.logEvent("player_spawn", %*{
        "slot": actor, "alias": aliases[actor],
        "x": game.players[actor].tileX, "y": game.players[actor].tileY})
    var
      bots: array[6, Bot]
      states: array[6, ViewerState]
      plans: array[6, ActivePlan]
      lastPlans: array[6, Plan]
      masks: array[6, uint8]
      scores: array[6, int]
      rows: seq[string]
      recent: seq[string]
      turn = 0
    for actor in 0 ..< 6:
      bots[actor] = initBot(bkBigGameHunter, seed + actor)
    for roundIndex in 0 ..< config.rounds:
      while game.tickCount < config.ticksPerRound:
        if game.tickCount mod config.planIntervalTicks == 0:
          inc turn
          var proposed: array[6, Plan]
          var prompts: array[6, string]
          let turnsTotal = config.rounds * config.ticksPerRound div config.planIntervalTicks
          for actor in 0 ..< 6:
            let legal = game.legalTargets(actor)
            let me = game.players[actor]
            var target = "none"
            var distance = high(int)
            for candidate in legal:
              let at = candidate.rfind('@')
              if at < 0: continue
              let xy = candidate[at + 1 .. ^1].split(',')
              let d = max(abs(parseInt(xy[0]) - me.tileX),
                abs(parseInt(xy[1]) - me.tileY))
              if d < distance:
                distance = d
                target = candidate
            let payload = %*{"intent": (if target == "none": "rest" else: "hunt"),
              "target": target, "side": "any", "with": [], "say": "", "note": ""}
            proposed[actor] = parsePlan(payload, turn, legal, aliases)
            prompts[actor] = game.observationFor(actor, turn, turnsTotal,
              lastPlans[actor], lastPlans[actor].note, recent, "")
          for actor in 0 ..< 6:
            let plan = proposed[actor]
            let packet = planPacket(plan)
            var blob = newString(packet.len)
            for i, value in packet: blob[i] = char(value)
            plans[actor] = parsePlanMessage(blob)
            lastPlans[actor] = plan
            rows.add($(%*{
              "episode_id": "cooperative-hunting-" & variant & "-" & $seed,
              "seed": "cooperative-hunting-" & variant & "-" & $seed,
              "decision_id": rows.len,
              "prompt": [
                {"role": "system", "content": systemPromptFor(OperatorPrompt)},
                {"role": "user", "content": prompts[actor]}
              ],
              "completion": [{"role": "assistant", "content": $(%*{
                "intent": plan.intent, "target": plan.target, "side": plan.side,
                "with": plan.partners, "say": plan.say, "note": plan.note})}],
              "game": "cooperative-hunting",
              "action_schema_revision": "cooperative-hunting-plan-v1"
            }))
        var inputs: array[6, InputState]
        for actor in 0 ..< 6: inputs[actor] = decodeInputMask(masks[actor])
        game.step(inputs)
        for event in game.pendingEvents:
          let line = feedLineFor(event.name, parseJson("{" & event.payload & "}"))
          if line.text.len > 0:
            recent.add("t" & $event.tick & " " & line.text)
            if recent.len > 5: recent.delete(0)
        game.pendingEvents.setLen(0)
        for actor in 0 ..< 6:
          var nextState: ViewerState
          let frame = game.buildPlayerFrame(actor, states[actor], nextState)
          states[actor] = nextState
          var blob = newString(frame.len)
          for i, value in frame: blob[i] = char(value)
          doAssert bots[actor].applySpritePacket(blob)
          inc bots[actor].frameTick
          masks[actor] = bots[actor].decideWithPlan(plans[actor], bkBigGameHunter)
      for actor in 0 ..< 6: scores[actor] += game.players[actor].score
      game.phase = RoundEnding
      for actor in 0 ..< 6: game.players[actor].overlayActive = true
      for cardTick in 1 .. RoundEndDisplayTicks:
        inc game.globalTick
        if cardTick == RoundEndDisplayTicks and roundIndex + 1 < config.rounds:
          game.startRound(roundIndex + 1)
          for event in game.pendingEvents:
            let line = feedLineFor(event.name, parseJson("{" & event.payload & "}"))
            if line.text.len > 0:
              recent.add("t" & $event.tick & " " & line.text)
              if recent.len > 5: recent.delete(0)
          game.pendingEvents.setLen(0)
        for actor in 0 ..< 6:
          var nextState: ViewerState
          let frame = game.buildPlayerFrame(actor, states[actor], nextState)
          states[actor] = nextState
          var blob = newString(frame.len)
          for i, value in frame: blob[i] = char(value)
          doAssert bots[actor].applySpritePacket(blob)
          inc bots[actor].frameTick
          masks[actor] = bots[actor].decideWithPlan(plans[actor], bkBigGameHunter)
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len, "scores": scores})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "cooperative-hunting",
    "variant": variant, "source_revision": sourceRevision,
    "teacher": "nearest-legal-plan", "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len, "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
