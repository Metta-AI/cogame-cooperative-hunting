## Export complete engine/controller games in the original training dataset format.
import std/[json, os, osproc, strutils]
import cooperative_hunting
import cooperative_hunting/[llm, prompts, sim]
import plan_runtime

when isMainModule:
  let args = commandLineParams()
  if args.len notin [2, 3, 4, 6]:
    quit("usage: export_posttrain OUTPUT EPISODES [FIRST_SEED] [VARIANT [PROMPT_VARIANT PROMPT_SEED]]", 1)
  let output = absolutePath(args[0])
  let episodes = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: "staghunt"
  let initialSelection = promptSelection(if args.len == 6:
    %*{"promptVariant": args[4], "promptSeed": parseInt(args[5])} else: newJObject())
  if initialSelection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
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
  createDir(output)
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  var
    trainRows, validationRows: seq[string]
    runs = newJArray()
    wordingCounts: array[2, int]
  for seed in firstSeed ..< firstSeed + episodes:
    var selection = initialSelection
    let partition = ord(seed mod 5 == 0)
    if selection.variant == pvMixed:
      selection.seed += wordingCounts[partition]
    inc wordingCounts[partition]
    var config = parseGameConfig($variantConfig)
    config.seed = seed
    var state = initPlanGame(config, selection)
    var rows: seq[string]
    while not state.done:
      for seat in 0 ..< 6:
        let proposal = state.teacher(seat)
        state.proposals[seat] = parsePlan(proposal, state.turn,
          state.game.legalTargets(seat), state.aliases)
        doAssert state.proposals[seat].actionJson() == proposal
        rows.add($(%*{
          "episode_id": "cooperative-hunting-" & variant & "-" & $seed & "-" & $selection.selectedVariant,
          "seed": "cooperative-hunting-" & $seed,
          "decision_id": rows.len,
          "prompt": [
            {"role": "system", "content": systemPromptFor(OperatorPrompt, selection, variant)},
            {"role": "user", "content": state.observations[seat]}
          ],
          "completion": [{"role": "assistant", "content": $proposal}],
          "game": "cooperative-hunting",
          "action_schema_revision": "cooperative-hunting-plan-v1"
        }))
      state.advancePlans()
    doAssert rows.len == 144
    if seed mod 5 == 0: validationRows.add(rows)
    else: trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "prompt_selection": selection.selectionMetadata(),
      "scores": state.scores, "final_tick": state.game.globalTick})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "cooperative-hunting", "variant": variant,
    "source_revision": revision, "teacher": "nearest-legal-plan",
    "operator_prompt": OperatorPrompt, "train_examples": trainRows.len,
    "validation_examples": validationRows.len, "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
