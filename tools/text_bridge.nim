## Full-plan text decisions; published episode lengths and real player controllers.
import std/[json, os, posix]
import cooperative_hunting
import cooperative_hunting/[llm, prompts, sim_types]
import plan_runtime

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value: hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32) + 1

proc decision(state: PlanGame, seat, id: int): JsonNode =
  let system = systemPromptFor(OperatorPrompt, state.selection)
  let user = state.observations[seat]
  %*{"kind": "decision", "game": "cooperative-hunting",
    "decision_id": id, "seat": seat, "engine_seat": seat,
    "turn": state.turn, "semantic_view": {
      "observation": user, "prompt_template": state.selection.promptMetadata(system, user)},
    "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
    "inbox": [], "speech_messages": [], "typed_question": newJNull(),
    "action_schema": {"type": "object", "required": ["intent", "target", "side", "with", "say", "note"]}}

when isMainModule:
  let args = commandLineParams()
  doAssert args.len == 2, "usage: text_bridge MANIFEST VARIANT"
  let manifestPath = absolutePath(args[0])
  let manifest = parseFile(manifestPath)
  var variant = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == args[1]: variant = entry["game_config"]
  doAssert variant.kind == JObject
  setCurrentDir(manifestPath.parentDir)
  var state: PlanGame
  var seat, id: int
  let protocolFd = dup(1)
  doAssert protocolFd >= 0 and dup2(2, 1) >= 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == 6
      let selection = promptSelection(request)
      let split = if request.hasKey("split"): request["split"].getStr() else: "train"
      doAssert split in ["train", "validation", "test"]
      if split == "train" and selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
        raise newException(ValueError, "held-out wording is evaluation-only")
      var config = parseGameConfig($variant)
      config.seed = seedOf(request["seed"].getStr())
      state = initPlanGame(config, selection)
      seat = 0
      id = 0
      response = state.decision(seat, id)
    of "teacher":
      response = %*{"response": $state.teacher(seat)}
    of "step":
      doAssert not state.done and request["decision_id"].getInt() == id
      let plan = parsePlan(extractJsonObject(request["response"].getStr()), state.turn,
        state.game.legalTargets(seat), state.aliases)
      state.proposals[seat] = plan
      inc id
      inc seat
      var next: JsonNode
      if seat == 6:
        state.advancePlans()
        seat = 0
      if state.done:
        doAssert state.game.globalTick == state.game.config.rounds *
          (state.game.config.ticksPerRound + RoundEndDisplayTicks)
        var scores = newJObject()
        var utilities = newJObject()
        var highest = 1
        for score in state.scores: highest = max(highest, score)
        for actor in 0 ..< 6:
          scores[$actor] = %state.scores[actor]
          utilities[$actor] = %(2.0 * state.scores[actor].float / highest.float - 1.0)
        next = %*{"kind": "terminal", "scores": scores, "utilities": utilities}
      else:
        next = state.decision(seat, id)
      response = %*{"kind": "accepted", "action": plan.actionJson(), "observation": next}
    else:
      raise newException(ValueError, "unknown command")
    stdout.flushFile()
    doAssert dup2(protocolFd, 1) >= 0
    stdout.writeLine($response)
    stdout.flushFile()
    doAssert dup2(2, 1) >= 0
