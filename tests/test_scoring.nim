## Scoring per variant, cumulative round totals, sign, and the shape of
## results.json -- including the deadline path scoring the partial round
## rather than zeroing it.

import std/[json, os, strutils]
import cooperative_hunting
import cooperative_hunting/sim

var failures = 0
proc check(label: string, condition: bool) =
  if not condition:
    echo "FAIL: ", label
    inc failures
  else:
    echo "ok: ", label

proc clearWorld(variant: string, seats = 6): SimServer =
  var config = defaultGameConfig()
  config.variant = variant
  config.numAgents = seats
  result = initSim(config)
  for i in 0 ..< result.tiles.len:
    result.tiles[i] = TileEmpty
  result.ensureStats(seats)

proc place(sim: var SimServer, slot, tx, ty: int, level = 1) =
  discard sim.addPlayer("p" & $slot, aliasForSlot(slot), slot)
  sim.players[^1].tileX = tx
  sim.players[^1].tileY = ty
  sim.players[^1].level = level

proc tick(sim: var SimServer) =
  sim.step(newSeq[InputState](sim.players.len))

# ---------------------------------------------------------------------------
# The reward table, in full, and paid to EVERY participant
# ---------------------------------------------------------------------------

block animalRewards:
  const expected = [
    (Rabbit, RabbitScoreReward, RabbitEnergyReward),
    (Boar, BoarScoreReward, BoarEnergyReward),
    (Stag, StagScoreReward, StagEnergyReward),
    (Moose, MooseScoreReward, MooseEnergyReward),
    (Elephant, ElephantScoreReward, ElephantEnergyReward)
  ]
  for (kind, score, energy) in expected:
    var sim = clearWorld("staghunt")
    sim.prey.add(Prey(kind: kind, tileX: 10, tileY: 10,
      thinkCooldown: 1_000_000))
    let sides = preyMinPlayers(kind)
    for slot in 0 ..< sides:
      sim.place(slot, 10 + SideOffsets[slot].dx, 10 + SideOffsets[slot].dy)
    # Boar needs perpendicular sides; SideOffsets 0,1 are N and S.
    if kind == Boar:
      sim.players[1].tileX = 11
      sim.players[1].tileY = 10
    for slot in 0 ..< sides:
      sim.players[slot].energy = 0
    sim.tick()
    check(preyLabel(kind) & " pays " & $score & " to every participant",
      sim.players.len >= sides and
      (block:
        var ok = true
        for slot in 0 ..< sides:
          if sim.players[slot].score != score: ok = false
        ok))
    check(preyLabel(kind) & " pays " & $energy & " energy to each (capped)",
      (block:
        var ok = true
        for slot in 0 ..< sides:
          if sim.players[slot].energy != min(MaxEnergy, energy): ok = false
        ok))

block energyCaps:
  var sim = clearWorld("staghunt")
  sim.prey.add(Prey(kind: Elephant, tileX: 10, tileY: 10,
    thinkCooldown: 1_000_000))
  for slot in 0 ..< 4:
    sim.place(slot, 10 + SideOffsets[slot].dx, 10 + SideOffsets[slot].dy)
    sim.players[slot].energy = MaxEnergy - 1
  sim.tick()
  check("energy never exceeds the 200 cap",
    sim.players[0].energy == MaxEnergy)

# ---------------------------------------------------------------------------
# Per-variant scoring
# ---------------------------------------------------------------------------

block coopMiningScoring:
  var sim = clearWorld("coop-mining")
  sim.items.add(Item(kind: itIron, tileX: 5, tileY: 5))
  sim.items.add(Item(kind: itGold, tileX: 10, tileY: 10))
  sim.place(0, 5, 4)
  sim.place(1, 10, 9)
  sim.place(2, 10, 11)
  sim.tick()
  check("iron pays 1 to its single miner",
    sim.players[0].score == IronScoreReward)
  check("gold pays 8 to each of two miners",
    sim.players[1].score == GoldScoreReward and
    sim.players[2].score == GoldScoreReward)

block lbfSplitting:
  ## score = 2 x level, split floor with the remainder to the LOWEST slot.
  var sim = clearWorld("lbf")
  sim.items.add(Item(kind: itFood, tileX: 10, tileY: 10, level: 4))
  sim.place(1, 10, 9, level = 2)
  sim.place(3, 10, 11, level = 2)
  sim.tick()
  check("a level-4 food pays 8, split 4 and 4",
    sim.players[0].score == 4 and sim.players[1].score == 4)
  # A level-5 food is worth 10; three participants take floor(10/3) = 3 and
  # the remainder 1 goes to the LOWEST slot (slot 1 here), deterministically.
  var odd = clearWorld("lbf")
  odd.items.add(Item(kind: itFood, tileX: 10, tileY: 10, level: 5))
  odd.place(3, 10, 9, level = 2)
  odd.place(1, 10, 11, level = 2)
  odd.place(5, 11, 10, level = 2)
  odd.tick()
  check("an odd split gives the remainder to the lowest slot",
    odd.playerIndexOfSlot(1) >= 0 and
    odd.players[odd.playerIndexOfSlot(1)].score == 4 and
    odd.players[odd.playerIndexOfSlot(3)].score == 3 and
    odd.players[odd.playerIndexOfSlot(5)].score == 3)

block predatorPreyScoring:
  var sim = clearWorld("predator-prey")
  sim.place(0, 10, 10)
  sim.players[0].role = roleForager
  sim.place(1, 10, 9)
  sim.place(2, 10, 11)
  sim.players[1].role = roleHunter
  sim.players[2].role = roleHunter
  sim.tick()
  check("a tag pays 6 to each hunter",
    sim.players[1].score == TagScoreReward and
    sim.players[2].score == TagScoreReward)
  check("a tagged forager scores nothing", sim.players[0].score == 0)
  check("a tagged forager loses 30 energy",
    sim.players[0].energy == StartEnergy - TagEnergyLoss)
  check("a tagged forager respawns 24 ticks later",
    sim.players[0].respawnIn == TagRespawnTicks)

# ---------------------------------------------------------------------------
# Sign: no term is ever negative
# ---------------------------------------------------------------------------

block signIsPositive:
  ## Trample and gore cost ENERGY, never score. Run a long hazardous world
  ## and assert no score ever goes down.
  var config = defaultGameConfig()
  config.numAgents = 6
  var sim = initSim(config)
  for slot in 0 ..< 6:
    discard sim.addPlayer("p" & $slot, aliasForSlot(slot), slot)
  sim.ensureStats(6)
  var previous = newSeq[int](6)
  var decreased = false
  for _ in 0 ..< 1500:
    sim.tick()
    for slot in 0 ..< 6:
      if sim.players[slot].score < previous[slot]:
        decreased = true
      previous[slot] = sim.players[slot].score
  check("no score is ever decremented", not decreased)
  check("no score is ever negative",
    (block:
      var ok = true
      for p in sim.players:
        if p.score < 0: ok = false
      ok))

# ---------------------------------------------------------------------------
# results.json shape
# ---------------------------------------------------------------------------

const LegalReasons = ["complete", "deadline", "no_players"]

proc runAndRead(config: GameConfig, dir: string): JsonNode =
  removeDir(dir)
  discard runEpisodeOffline(config,
    @["big_game_hunter", "big_game_hunter", "sidekick", "modeler",
      "stag_hunter", "rabbiteer"],
    dir / "results.json", dir / "replay.json")
  parseJson(readFile(dir / "results.json"))

block resultsShape:
  var config = defaultGameConfig()
  config.numAgents = 6
  config.rounds = 2
  config.ticksPerRound = 90
  config.players = @["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]
  let results = runAndRead(config, getTempDir() / "ch-scoring-shape")
  for key in ["names", "aliases", "kinds", "scores", "energy", "fallbacks",
      "disconnected", "catches", "co_captures"]:
    check("results." & key & " has one entry per seat",
      results[key].len == config.numAgents)
  check("results.reason is one of the three legal values",
    results["reason"].getStr() in LegalReasons)
  # Phase 60 counts what the model did and did not get to do: a planning
  # turn skipped because the previous batch was still in flight is neither a
  # request nor a fallback, so it needs its own counter or it leaves no
  # trace.
  check("results counts the planning turns that were skipped",
    results.hasKey("plan_turns_skipped") and
    results["plan_turns_skipped"].getInt() >= 0)
  check("results.rounds has one array per round",
    results["rounds"].len == config.rounds)
  check("every round array has one entry per seat",
    (block:
      var ok = true
      for round in results["rounds"]:
        if round.len != config.numAgents: ok = false
      ok))
  check("every score is a non-negative integer",
    (block:
      var ok = true
      for score in results["scores"]:
        if score.kind != JInt or score.getInt() < 0: ok = false
      ok))
  check("results.scores is the sum of the round arrays",
    (block:
      var ok = true
      for slot in 0 ..< config.numAgents:
        var total = 0
        for round in results["rounds"]:
          total += round[slot].getInt()
        if total != results["scores"][slot].getInt(): ok = false
      ok))
  check("names carry the real policy names",
    results["names"][0].getStr() == "alpha")
  check("aliases are Cog- aliases and never the real names",
    results["aliases"][0].getStr().startsWith("Cog-"))
  check("every alias is distinct",
    (block:
      var seen: seq[string] = @[]
      var ok = true
      for alias in results["aliases"]:
        if alias.getStr() in seen: ok = false
        seen.add(alias.getStr())
      ok))

block deadlinePath:
  ## The wall-clock guard settles the CURRENT round as it stands rather than
  ## zeroing it, so a deadline episode is still rankable.
  var config = defaultGameConfig()
  config.numAgents = 6
  config.rounds = 4
  config.ticksPerRound = 4000     # far more than the budget allows
  config.playBudgetSeconds = 1
  config.players = @["a", "b", "c", "d", "e", "f"]
  let dir = getTempDir() / "ch-scoring-deadline"
  let results = runAndRead(config, dir)
  check("a blown budget settles with reason deadline",
    results["reason"].getStr() == "deadline")
  check("the partial round is scored, not dropped",
    results["rounds"].len == 1)
  check("scores are still present on the deadline path",
    results["scores"].len == config.numAgents)
  check("the deadline event is in the replay",
    "\"ev\":\"deadline\"" in readFile(dir / "replay.json"))

if failures > 0:
  quit("test_scoring: " & $failures & " failures", 1)
echo "test_scoring: all checks passed"
