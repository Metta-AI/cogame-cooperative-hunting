## Capture predicates, positive and negative, across all four variants.

import std/[strutils]
import cooperative_hunting/sim

proc emptyWorld(variant: string, seats = 6): SimServer =
  var config = defaultGameConfig()
  config.variant = variant
  config.numAgents = seats
  result = initSim(config)
  # A clear arena: the predicates are the subject, not the map.
  for i in 0 ..< result.tiles.len:
    result.tiles[i] = TileEmpty
  result.ensureStats(seats)

proc place(sim: var SimServer, slot, tx, ty: int, level = 1) =
  discard sim.addPlayer("p" & $slot, aliasForSlot(slot), slot)
  sim.players[^1].tileX = tx
  sim.players[^1].tileY = ty
  sim.players[^1].level = level

proc addAnimal(sim: var SimServer, kind: PreyKind, tx, ty: int) =
  sim.prey.add(Prey(id: sim.nextPreyId, kind: kind, tileX: tx, tileY: ty,
    thinkCooldown: 1_000_000))
  inc sim.nextPreyId

proc addNode(sim: var SimServer, kind: ItemKind, tx, ty: int, level = 0) =
  sim.items.add(Item(id: sim.nextItemId, kind: kind, tileX: tx, tileY: ty,
    level: level))
  inc sim.nextItemId

proc runTicks(sim: var SimServer, count: int) =
  for _ in 0 ..< count:
    var inputs = newSeq[InputState](sim.players.len)
    sim.step(inputs)

proc captured(sim: SimServer): bool =
  sim.pendingCaptures.len > 0

var failures = 0
proc check(label: string, condition: bool) =
  if not condition:
    echo "FAIL: ", label
    inc failures
  else:
    echo "ok: ", label

# ---------------------------------------------------------------------------
# `sides`: the per-kind predicate
# ---------------------------------------------------------------------------

proc sidesOf(kind: PreyKind, occupied: openArray[int]): bool =
  ## occupied: indexes into SideOffsets (0 N, 1 S, 2 E, 3 W).
  var sim = emptyWorld("staghunt")
  sim.addAnimal(kind, 10, 10)
  for slot, side in occupied:
    sim.place(slot, 10 + SideOffsets[side].dx, 10 + SideOffsets[side].dy)
  sim.runTicks(1)
  captured(sim)

check("rabbit falls to one hunter on N", sidesOf(Rabbit, [0]))
check("rabbit falls to one hunter on S", sidesOf(Rabbit, [1]))
check("rabbit falls to one hunter on E", sidesOf(Rabbit, [2]))
check("rabbit falls to one hunter on W", sidesOf(Rabbit, [3]))

check("boar falls to N+E", sidesOf(Boar, [0, 2]))
check("boar falls to N+W", sidesOf(Boar, [0, 3]))
check("boar falls to S+E", sidesOf(Boar, [1, 2]))
check("boar falls to S+W", sidesOf(Boar, [1, 3]))
check("boar does NOT fall to N+S", not sidesOf(Boar, [0, 1]))
check("boar does NOT fall to E+W", not sidesOf(Boar, [2, 3]))
check("boar does NOT fall to one side", not sidesOf(Boar, [0]))

check("stag falls to N+S", sidesOf(Stag, [0, 1]))
check("stag falls to E+W", sidesOf(Stag, [2, 3]))
check("stag does NOT fall to N+E", not sidesOf(Stag, [0, 2]))
check("stag does NOT fall to S+W", not sidesOf(Stag, [1, 3]))
check("stag does NOT fall to one side", not sidesOf(Stag, [0]))

check("moose falls to three sides", sidesOf(Moose, [0, 1, 2]))
check("moose falls to four sides", sidesOf(Moose, [0, 1, 2, 3]))
check("moose does NOT fall to two sides", not sidesOf(Moose, [0, 1]))

check("elephant falls only to four sides", sidesOf(Elephant, [0, 1, 2, 3]))
check("elephant does NOT fall to three sides", not sidesOf(Elephant, [0, 1, 2]))

# ---------------------------------------------------------------------------
# `window`: coop-mining. windowTicks = 1 reproduces the base rule exactly, so
# the base game runs through the same code path.
# ---------------------------------------------------------------------------

block ironSolo:
  var sim = emptyWorld("coop-mining")
  check("coop-mining uses the window rule", sim.captureRule == crWindow)
  check("coop-mining window is 3 ticks", sim.windowTicks == 3)
  sim.addNode(itIron, 10, 10)
  sim.place(0, 10, 9)
  sim.runTicks(1)
  check("iron falls to one adjacent hunter", captured(sim))

block goldNeedsTwo:
  var sim = emptyWorld("coop-mining")
  sim.addNode(itGold, 10, 10)
  sim.place(0, 10, 9)
  sim.runTicks(3)
  check("gold does NOT fall to one hunter", sim.items.len == 1)

block goldTwoWithinWindow:
  var sim = emptyWorld("coop-mining")
  sim.addNode(itGold, 10, 10)
  sim.place(0, 10, 9)                 # slot 0 on N
  sim.place(1, 14, 14)                # slot 1 far away for now
  sim.runTicks(1)
  check("gold not yet taken with one side", sim.items.len == 1)
  # Two ticks later the second hunter arrives on the S side: within the
  # 3-tick window, so the N stamp still counts.
  sim.players[1].tileX = 10
  sim.players[1].tileY = 11
  sim.runTicks(2)
  check("gold falls to two hunters two ticks apart", sim.items.len == 0)

block goldOutsideWindow:
  var sim = emptyWorld("coop-mining")
  sim.addNode(itGold, 10, 10)
  sim.place(0, 10, 9)
  sim.place(1, 14, 14)
  sim.runTicks(1)
  sim.players[0].tileX = 20           # slot 0 leaves
  sim.players[0].tileY = 20
  sim.runTicks(3)                     # three ticks later, out of the window
  sim.players[1].tileX = 10
  sim.players[1].tileY = 11
  sim.runTicks(1)
  check("gold does NOT fall to hunters three ticks apart", sim.items.len == 1)

block goldCreditsBoth:
  var sim = emptyWorld("coop-mining")
  sim.addNode(itGold, 10, 10)
  sim.place(0, 10, 9)
  sim.place(1, 10, 11)
  sim.runTicks(1)
  check("gold credits both slots",
    sim.pendingCaptures.len == 1 and sim.pendingCaptures[0].slots == @[0, 1])
  check("gold pays 8 to each",
    sim.players[0].score == GoldScoreReward and
    sim.players[1].score == GoldScoreReward)

block baseRuleThroughWindowCode:
  ## windowTicks = 1 in staghunt: a side stamped on the PREVIOUS tick must
  ## not count, which is exactly the base rule.
  var sim = emptyWorld("staghunt")
  check("staghunt windowTicks is 1", sim.windowTicks == 1)
  sim.addAnimal(Stag, 10, 10)
  sim.place(0, 10, 9)
  sim.place(1, 14, 14)
  sim.runTicks(1)
  sim.players[0].tileX = 20
  sim.players[0].tileY = 20
  sim.players[1].tileX = 10
  sim.players[1].tileY = 11
  sim.runTicks(1)
  check("stag does NOT fall to sides held on different ticks",
    sim.prey.len == 1)

# ---------------------------------------------------------------------------
# `levelsum`: lbf
# ---------------------------------------------------------------------------

block levelSumPasses:
  var sim = emptyWorld("lbf")
  check("lbf uses the levelsum rule", sim.captureRule == crLevelSum)
  sim.addNode(itFood, 10, 10, level = 3)
  sim.place(0, 10, 9, level = 1)
  sim.place(1, 10, 11, level = 2)
  sim.runTicks(1)
  check("levels 1+2 take a level-3 food", sim.items.len == 0)

block levelSumFails:
  var sim = emptyWorld("lbf")
  sim.addNode(itFood, 10, 10, level = 3)
  sim.place(0, 10, 9, level = 1)
  sim.place(1, 10, 11, level = 1)
  sim.runTicks(1)
  check("levels 1+1 do NOT take a level-3 food", sim.items.len == 1)

block levelSumSplit:
  ## score = 2 x level = 10 over three participants: floor(10/3) = 3 each,
  ## and the remainder 1 goes to the LOWEST slot.
  var sim = emptyWorld("lbf")
  sim.addNode(itFood, 10, 10, level = 5)
  sim.place(0, 10, 9, level = 2)
  sim.place(1, 10, 11, level = 2)
  sim.place(2, 11, 10, level = 2)
  sim.runTicks(1)
  check("level-5 food is taken by 2+2+2", sim.items.len == 0)
  check("split floors to 3 each with the remainder to the lowest slot",
    sim.players[0].score == 4 and sim.players[1].score == 3 and
    sim.players[2].score == 3)
  check("energy is NOT split",
    sim.players[0].energy == sim.players[1].energy)

# ---------------------------------------------------------------------------
# predator-prey tagging
# ---------------------------------------------------------------------------

proc tagWith(sides: openArray[int]): bool =
  var sim = emptyWorld("predator-prey")
  sim.place(0, 10, 10)                     # the forager
  sim.players[0].role = roleForager
  var slot = 1
  for side in sides:
    sim.place(slot, 10 + SideOffsets[side].dx, 10 + SideOffsets[side].dy)
    sim.players[^1].role = roleHunter
    inc slot
  sim.runTicks(1)
  sim.players[0].respawnIn > 0

check("tag fires on opposite N+S", tagWith([0, 1]))
check("tag fires on opposite E+W", tagWith([2, 3]))
check("tag does NOT fire on perpendicular N+E", not tagWith([0, 2]))
check("tag does NOT fire on one hunter", not tagWith([0]))

block forageOnBerry:
  var sim = emptyWorld("predator-prey")
  sim.berries = @[Berry(tileX: 10, tileY: 10, regrow: 0)]
  sim.place(0, 10, 10)
  sim.players[0].role = roleForager
  sim.runTicks(1)
  check("a forager on a ripe berry tile scores",
    sim.players[0].score == BerryScoreReward)
  check("the berry tile starts regrowing", sim.berries[0].regrow > 0)
  sim.runTicks(1)
  check("a regrowing berry tile does not score again",
    sim.players[0].score == BerryScoreReward)

block rolesAlternate:
  ## With six seats and four rounds every seat hunts exactly twice and
  ## forages exactly twice, so the asymmetry cancels in the ranking.
  for slot in 0 ..< 6:
    var hunts = 0
    for round in 0 ..< 4:
      if roleFor(slot, round) == roleHunter:
        inc hunts
    check("slot " & $slot & " hunts exactly twice over four rounds",
      hunts == 2)

if failures > 0:
  quit("test_capture: " & $failures & " failures", 1)
echo "test_capture: all checks passed"
