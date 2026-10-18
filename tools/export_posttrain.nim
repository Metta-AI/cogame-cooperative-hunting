## Complete engine/controller episodes as private candidate evidence for shared review.
import std/[base64, json, os, osproc, strutils]
import cooperative_hunting
import cooperative_hunting/[llm, prompts, evidence]
import plan_runtime

when isMainModule:
  let args = commandLineParams()
  if args.len notin [2, 3, 4, 6]:
    quit("usage: export_posttrain OUTPUT EPISODES [FIRST_SEED] [VARIANT [PROMPT_VARIANT PROMPT_SEED]]", 1)
  let output = absolutePath(args[0])
  let episodes = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: "staghunt"
  let selection = promptSelection(if args.len == 6:
    %*{"promptVariant": args[4], "promptSeed": parseInt(args[5])} else: newJObject())
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    raise newException(ValueError, "held-out wording is evaluation-only")
  doAssert episodes >= 10 and firstSeed >= 1
  doAssert not dirExists(output) and not fileExists(output)
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit qualified source before generating a pinned candidate corpus"
  let head = execCmdEx("git rev-parse HEAD")
  doAssert head.exitCode == 0
  let revision = head.output.strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant: variantConfig = entry["game_config"]
  doAssert variantConfig.kind == JObject
  writePrivate(output / "trajectories.jsonl", "")
  let stream = open(output / "trajectories.jsonl", fmAppend)
  var runs = newJArray()
  try:
    for seed in firstSeed ..< firstSeed + episodes:
      var config = parseGameConfig($variantConfig)
      config.seed = seed
      var state = initPlanGame(config, selection)
      let family = "cooperative-hunting-" & $seed
      let episode = family & "-" & variant & "-" & $selection.selectedVariant & "-" & $selection.seed
      var decisionId = 0
      while not state.done:
        var messages, views, proposals: array[6, JsonNode]
        for seat in 0 ..< 6:
          let system = systemPromptFor(OperatorPrompt, selection)
          let user = state.observations[seat]
          messages[seat] = %*[{"role": "system", "content": system}, {"role": "user", "content": user}]
          views[seat] = %*{"observation": user, "prompt_template": selection.promptMetadata(system, user)}
          proposals[seat] = state.teacher(seat)
          state.proposals[seat] = parsePlan(proposals[seat], state.turn,
            state.game.legalTargets(seat), state.aliases)
        state.advancePlans()
        for seat in 0 ..< 6:
          let executed = state.proposals[seat].actionJson()
          let accepted = proposals[seat] == executed
          let attemptId = $decisionId & "-teacher"
          let attempt = %*{
            "attempt_id": attemptId, "policy": "nearest-legal-plan", "origin": "teacher",
            "inference_mode": "text_action", "prompt": messages[seat],
            "response": $proposals[seat], "parsed_action": proposals[seat], "accepted": accepted,
            "request": newJNull(), "platform_call_id": newJNull(), "behavior_logprobs": newJNull(),
            "rejection_reason": (if accepted: newJNull() else: %"engine-normalized-submission")
          }
          doAssert state.controls[seat].len == state.game.globalTick - state.startTick
          stream.writeLine($(%*{
            "schema_version": "1", "event_type": "decision", "episode_id": episode,
            "decision_id": $decisionId, "decision_index": decisionId,
            "game": "cooperative-hunting", "game_version": "source-" & revision,
            "source_revision": revision, "seat": $seat, "visibility": "private",
            "observation": views[seat], "prompt": (if accepted: messages[seat] else: newJNull()),
            "attempts": [attempt], "selected_attempt_id": (if accepted: %attemptId else: newJNull()),
            "executed_action": executed, "action_status": (if accepted: "accepted" else: "fallback"),
            "fallback_origin": (if accepted: newJNull() else: %"engine-normalized-submission"),
            "terminal": state.done and seat == 5,
            "execution": {"start_tick": state.startTick, "end_tick": state.game.globalTick,
              "tick_hz": config.tickHz, "control_encoding": "u8",
              "seat_controls_b64": encode(state.controls[seat])}
          }))
          inc decisionId
      var participants = newJObject()
      for seat in 0 ..< 6: participants[$seat] = %*{"score": state.scores[seat]}
      let outcome = %*{"scores": state.scores, "reason": "complete", "final_tick": state.game.globalTick}
      stream.writeLine($(%*{
        "schema_version": "1", "event_type": "episode", "episode_id": episode,
        "seed_family": family, "game": "cooperative-hunting", "game_version": "source-" & revision,
        "source_revision": revision, "status": "completed", "outcome": outcome,
        "participant_outcomes": participants
      }))
      runs.add(%*{"seed": seed, "decisions": decisionId, "scores": state.scores})
  finally:
    stream.close()
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "cooperative-hunting", "variant": variant,
    "source_revision": revision, "teacher": "nearest-legal-plan",
    "prompt_selection": selection.selectionMetadata(),
    "split_authority": "shared Coworld SDK and application importer by seed_family",
    "runs": runs}) & "\n")
  echo "complete games=", episodes
