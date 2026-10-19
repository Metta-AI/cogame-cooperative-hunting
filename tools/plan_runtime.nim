## Synchronous full-plan execution through the real simulator and player controller.
## Native transport latency, retries, and rate budgets are intentionally not simulated.
import std/[json, strutils]
import bitworld/protocol
import cooperative_hunting
import cooperative_hunting_player
import cooperative_hunting/[sim, sim_types, frames, art, baselines, llm, prompts, replay]

const OperatorPrompt* = "Coordinate with visible hunters and collect reachable rewards."

type PlanGame* = object
  game*: SimServer
  selection*: PromptSelection
  aliases*: seq[string]
  turn*: int
  done*: bool
  scores*: array[6, int]
  observations*: array[6, string]
  proposals*: array[6, Plan]
  bots: array[6, Bot]
  states: array[6, ViewerState]
  plans: array[6, ActivePlan]
  lastPlans: array[6, Plan]
  masks: array[6, uint8]
  recent: seq[string]

proc actionJson*(plan: Plan): JsonNode =
  %*{"intent": plan.intent, "target": plan.target, "side": plan.side,
    "with": plan.partners, "say": plan.say, "note": plan.note}

proc freezeViews(state: var PlanGame) =
  inc state.turn
  let turns = state.game.config.rounds * state.game.config.ticksPerRound div
    state.game.config.planIntervalTicks
  for seat in 0 ..< 6:
    state.observations[seat] = state.game.observationFor(seat, state.turn, turns,
      state.lastPlans[seat], state.lastPlans[seat].note, state.recent, "")

proc initPlanGame*(config: GameConfig, selection: PromptSelection): PlanGame =
  doAssert config.numAgents == 6
  result.selection = selection
  result.game = initSim(config)
  result.game.art.buildSpriteCache()
  result.aliases = seatAliases(6, config.seed)
  for seat in 0 ..< 6:
    discard result.game.addPlayer("policy-" & $seat, result.aliases[seat], seat, pkPrompt)
    result.bots[seat] = initBot(bkBigGameHunter, config.seed + seat)
  result.game.ensureStats(6)
  result.game.applyRolesPublic()
  result.game.logEvent("round_start", %*{
    "round": 1, "seed": config.seed, "ticks": config.ticksPerRound})
  for seat in 0 ..< 6:
    result.game.logEvent("player_spawn", %*{
      "slot": seat, "alias": result.aliases[seat],
      "x": result.game.players[seat].tileX, "y": result.game.players[seat].tileY})
  result.freezeViews()

proc teacher*(state: PlanGame, seat: int): JsonNode =
  let me = state.game.players[seat]
  var target = "none"
  var distance = high(int)
  for candidate in state.game.legalTargets(seat):
    let at = candidate.rfind('@')
    if at < 0: continue
    let xy = candidate[at + 1 .. ^1].split(',')
    let d = max(abs(parseInt(xy[0]) - me.tileX), abs(parseInt(xy[1]) - me.tileY))
    if d < distance:
      distance = d
      target = candidate
  %*{"intent": (if target == "none": "rest" else: "hunt"),
    "target": target, "side": "any", "with": [], "say": "", "note": ""}

proc collectFeed(state: var PlanGame) =
  for event in state.game.pendingEvents:
    let line = feedLineFor(event.name, parseJson("{" & event.payload & "}"))
    if line.text.len > 0:
      state.recent.add("t" & $event.tick & " " & line.text)
      if state.recent.len > 5: state.recent.delete(0)
  state.game.pendingEvents.setLen(0)

proc updatePlayers(state: var PlanGame) =
  for seat in 0 ..< 6:
    var nextState: ViewerState
    let frame = state.game.buildPlayerFrame(seat, state.states[seat], nextState)
    state.states[seat] = nextState
    var blob = newString(frame.len)
    for i, value in frame: blob[i] = char(value)
    doAssert state.bots[seat].applySpritePacket(blob)
    inc state.bots[seat].frameTick
    state.masks[seat] = state.bots[seat].decideWithPlan(state.plans[seat], bkBigGameHunter)

proc advancePlans*(state: var PlanGame) =
  ## All six proposals were parsed against the same frozen planning boundary.
  for seat in 0 ..< 6:
    let packet = planPacket(state.proposals[seat])
    var blob = newString(packet.len)
    for i, value in packet: blob[i] = char(value)
    state.plans[seat] = parsePlanMessage(blob)
    state.lastPlans[seat] = state.proposals[seat]
  for tick in 0 ..< state.game.config.planIntervalTicks:
    var inputs: array[6, InputState]
    for seat in 0 ..< 6:
      inputs[seat] = decodeInputMask(state.masks[seat])
    state.game.step(inputs)
    state.collectFeed()
    state.updatePlayers()
    if state.game.tickCount >= state.game.config.ticksPerRound:
      let roundIndex = state.game.roundIndex
      for seat in 0 ..< 6: state.scores[seat] += state.game.players[seat].score
      state.game.phase = RoundEnding
      for seat in 0 ..< 6: state.game.players[seat].overlayActive = true
      for cardTick in 1 .. RoundEndDisplayTicks:
        inc state.game.globalTick
        if cardTick == RoundEndDisplayTicks and roundIndex + 1 < state.game.config.rounds:
          state.game.startRound(roundIndex + 1)
          state.collectFeed()
        state.updatePlayers()
      state.done = roundIndex + 1 == state.game.config.rounds
      break
  if not state.done:
    state.freezeViews()
