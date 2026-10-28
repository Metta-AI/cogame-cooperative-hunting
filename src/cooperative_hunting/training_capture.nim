## Private native decision evidence. This adapter observes the existing socket
## path; it neither changes player observations nor grants teacher authority.
import std/[base64, json, options, os, tables]
import crunchy
import bitworld/protocol
import ./[decision_trajectory, llm, prompts, sim_types]

type
  CapturedTurn = ref object
    turn, slot, startTick, playingTicks: int
    observation: JsonNode
    legal, aliases: seq[string]
    attempts: seq[DecisionAttempt]
    action: JsonNode
    controls: string
    delivered, modelPlan: bool
  RuntimeCapture* = ref object
    trajectory: DecisionTrajectory
    pending: OrderedTable[string, CapturedTurn]
    active: Table[int, CapturedTurn]
    destination: string
    initial: JsonNode
    sealed*: bool
    writeAttempted: bool
    tickHz, finalWorkerRequests: int
    unmatched: JsonNode

proc physicalFamily*(sim: SimServer): string =
  ## Deliberately conservative across variants, roles and wording: identical
  ## physical forests cannot cross a split under a new seed/policy alias.
  var tiles = newJArray()
  for tile in sim.tiles: tiles.add(%ord(tile))
  "cooperative-hunting-forest-v1-" & sha256($(%*{
    "width": WorldWidthTiles, "height": WorldHeightTiles, "tiles": tiles})).toHex

proc newRuntimeCapture*(sim: SimServer, selection: PromptSelection): RuntimeCapture =
  let destination = getEnv(CogameSaveTrajectoryUriEnv)
  if destination.len == 0: return nil
  for publicArtifact in [getEnv("COGAME_RESULTS_URI"), getEnv("COGAME_SAVE_REPLAY_URI")]:
    if destination == publicArtifact:
      raise newException(ValueError, "private trajectory destination must differ from public artifacts")
  let episodeId = getEnv("COWORLD_EPISODE_ID", getEnv("EPISODE_ID"))
  if episodeId.len == 0:
    raise newException(ValueError, "private capture requires COWORLD_EPISODE_ID")
  var players = newJArray()
  for player in sim.players:
    players.add(%*{"slot": player.slot, "alias": player.alias,
      "x": player.tileX, "y": player.tileY, "level": player.level,
      "energy": player.energy, "role": $player.role, "policy_kind": $player.kind})
  var tiles = newJArray()
  for tile in sim.tiles: tiles.add(%ord(tile))
  var grass = newJArray()
  for tile in sim.tallGrass: grass.add(%tile)
  RuntimeCapture(trajectory: newDecisionTrajectory(episodeId, physicalFamily(sim),
    "cooperative_hunting", getEnv("COWORLD_GAME_VERSION"), getEnv("COWORLD_SOURCE_REVISION")),
    destination: destination, tickHz: sim.config.tickHz, unmatched: newJArray(),
    initial: %*{"config": {"seed": sim.config.seed, "variant": sim.config.variant,
      "num_agents": sim.config.numAgents, "rounds": sim.config.rounds,
      "ticks_per_round": sim.config.ticksPerRound, "tick_hz": sim.config.tickHz,
      "plan_interval_ticks": sim.config.planIntervalTicks,
      "plan_timeout_seconds": sim.config.planTimeoutSeconds,
      "play_budget_seconds": sim.config.playBudgetSeconds,
      "focus_elephant": sim.config.focusElephant},
      "players": players, "terrain": tiles,
      "tall_grass": grass, "rng_state": $sim.rng,
      "capture_rule": $sim.captureRule, "window_ticks": sim.windowTicks,
      "reward_split": sim.rewardSplit, "prompt_selection": selection.selectionMetadata()})

proc turnKey(turn, slot: int): string = $turn & "-" & $slot

proc beginBatch*(capture: RuntimeCapture, turn, tick, round, roundTick: int,
    seats, aliases: JsonNode, selection: PromptSelection) =
  if capture == nil: return
  for seat in seats:
    let slot = seat["slot"].getInt()
    var frozen = CapturedTurn(turn: turn, slot: slot, action: newJNull(),
      observation: %*{"turn": turn, "dispatch_tick": tick, "round": round,
        "round_tick": roundTick, "text": seat["user"],
        "prompt_metadata": selection.promptMetadata(seat["system"].getStr(), seat["user"].getStr())})
    for target in seat["legal"]: frozen.legal.add(target.getStr())
    for alias in aliases: frozen.aliases.add(alias.getStr())
    capture.pending[turnKey(turn, slot)] = frozen

proc received*(capture: RuntimeCapture, reply: JsonNode) =
  if capture == nil: return
  capture.finalWorkerRequests = reply{"requests"}.getInt(capture.finalWorkerRequests)
  let turn = reply{"turn"}.getInt()
  let plans = reply{"plans"}
  if plans.isNil or plans.kind != JArray:
    capture.unmatched.add(copy(reply))
    return
  for plan in plans:
    let key = turnKey(turn, plan{"slot"}.getInt())
    if key notin capture.pending:
      capture.unmatched.add(copy(plan))
      continue
    let frozen = capture.pending[key]
    let evidence = plan{"attempts"}
    if evidence.isNil or evidence.kind != JArray: continue
    for payload in evidence:
      var attempt = readAttemptEvidence(payload)
      try:
        if attempt.response.kind != JString:
          raise newException(ValueError, "no usable native response text")
        let proposal = extractJsonObject(attempt.response.getStr())
        let parsed = parsePlan(proposal, turn, frozen.legal, frozen.aliases)
        attempt.parsedAction = parsed.planActionJson()
        # The native parser is permissive. Never silently train on repaired or
        # truncated fields; only fields actually supplied must match exactly.
        for field in ["intent", "target", "side", "with", "say", "note"]:
          if proposal.hasKey(field) and proposal[field] != attempt.parsedAction[field]:
            raise newException(ValueError, "native parser normalized supplied " & field)
        if attempt.rejectionReason.isNone: attempt.accepted = true
      except CatchableError as error:
        attempt.accepted = false
        if attempt.rejectionReason.isNone: attempt.rejectionReason = some(error.msg)
      frozen.attempts.add(attempt)

proc flush(capture: RuntimeCapture, frozen: CapturedTurn) =
  var selected = none(string)
  var execution = none(ExecutionEvidence)
  let ran = frozen.delivered and frozen.controls.len > 0 and frozen.playingTicks > 0
  if ran:
    execution = some(ExecutionEvidence(controlEncoding: ceU8,
      startTick: frozen.startTick, endTick: frozen.startTick + frozen.controls.len,
      tickHz: capture.tickHz, seatControlsBase64: encode(frozen.controls)))
    if frozen.modelPlan:
      for attempt in frozen.attempts:
        if attempt.accepted and attempt.parsedAction == frozen.action:
          selected = some(attempt.attemptId)
  for attempt in frozen.attempts.mitems:
    if selected.isNone or attempt.attemptId != selected.get():
      attempt.accepted = false
      if attempt.rejectionReason.isNone:
        attempt.rejectionReason = some(if not ran: "plan had no subsequent physical execution"
          else: "proposal was not the selected unmodified installed plan")
  capture.trajectory.recordDecision(turnKey(frozen.turn, frozen.slot), $frozen.slot,
    frozen.observation, frozen.attempts, selected, frozen.action,
    (if selected.isSome: asAccepted
     elif ran and not frozen.modelPlan: asFallback else: asRejected),
    fallbackOrigin = (if ran and not frozen.modelPlan: some("native_scripted_controller")
      else: none(string)), execution = execution)

proc delivered*(capture: RuntimeCapture, slot, tick: int, plan: Plan) =
  ## Called only after 0x91 send succeeds; the observed subsequent input stream
  ## is the execution proof. Socket send alone is not a target.
  if capture == nil: return
  if slot in capture.active:
    let previous = capture.active[slot]
    capture.flush(previous)
    capture.pending.del(turnKey(previous.turn, slot))
    capture.active.del(slot)
  let key = turnKey(plan.turn, slot)
  if key notin capture.pending: return
  let frozen = capture.pending[key]
  frozen.delivered = true
  frozen.startTick = tick
  frozen.action = plan.planActionJson()
  frozen.modelPlan = plan.src == "llm"
  capture.active[slot] = frozen

proc appliedInputs*(capture: RuntimeCapture, inputs: openArray[InputState], playing: bool) =
  if capture == nil: return
  for slot, frozen in capture.active:
    let mask = if playing and slot < inputs.len: encodeInputMask(inputs[slot]) else: 0'u8
    frozen.controls.add(char(mask))
    if playing: inc frozen.playingTicks

proc finishCapture*(capture: RuntimeCapture, outcome: JsonNode, failed = "") =
  if capture == nil or capture.sealed or capture.writeAttempted: return
  for frozen in capture.pending.values: capture.flush(frozen)
  var privateOutcome = copy(outcome)
  privateOutcome["initial_state"] = capture.initial
  privateOutcome["native_worker_requests_including_terminal_drain"] = %capture.finalWorkerRequests
  privateOutcome["latency_ms_scope"] = %"parallel batch wall time; upper bound for each response"
  privateOutcome["unmatched_worker_evidence"] = capture.unmatched
  privateOutcome["execution_semantics"] = %"u8 masks actually consumed by sim; round-card ticks are frozen and encoded zero; delivery is successful native 0x91 send, not a player acknowledgement"
  if failed.len > 0: privateOutcome["runtime_error"] = %failed
  let status = if failed.len > 0: esFailed
    elif outcome{"reason"}.getStr() == "complete": esCompleted
    elif outcome{"reason"}.getStr() == "deadline": esTruncated else: esFailed
  capture.trajectory.finish(status, privateOutcome, outcome{"scores"})
  capture.writeAttempted = true
  capture.trajectory.writeEventsToUri(capture.destination)
  capture.sealed = true
