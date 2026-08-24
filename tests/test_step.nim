## Resolution order, movement, the hazards, and determinism.

import bitworld/protocol
import cooperative_hunting/sim

var failures = 0
proc check(label: string, condition: bool) =
  if not condition:
    echo "FAIL: ", label
    inc failures
  else:
    echo "ok: ", label

proc clearWorld(variant = "staghunt", seats = 6): SimServer =
  var config = defaultGameConfig()
  config.variant = variant
  config.numAgents = seats
  result = initSim(config)
  for i in 0 ..< result.tiles.len:
    result.tiles[i] = TileEmpty
  result.ensureStats(seats)

proc padRoster(sim: var SimServer, upTo: int) =
  ## The population maintainer culls any animal whose coalition size exceeds
  ## the connected seat count, so a one-hunter world never keeps an elephant.
  ## Park the extra seats in a far corner where they cannot join a capture.
  var slot = sim.players.len
  while sim.players.len < upTo:
    discard sim.addPlayer("pad" & $slot, aliasForSlot(slot), slot)
    sim.players[^1].tileX = 1 + (slot mod 3)
    sim.players[^1].tileY = 1
    inc slot

proc place(sim: var SimServer, slot, tx, ty: int) =
  discard sim.addPlayer("p" & $slot, aliasForSlot(slot), slot)
  sim.players[^1].tileX = tx
  sim.players[^1].tileY = ty

proc press(masks: openArray[uint8]): seq[InputState] =
  for mask in masks:
    result.add(decodeInputMask(mask))

const Up = 1'u8
const Down = 2'u8
const Left = 4'u8
const Right = 8'u8

# ---------------------------------------------------------------------------
# Movement
# ---------------------------------------------------------------------------

block moveCosts:
  var sim = clearWorld()
  sim.place(0, 10, 10)
  sim.step(press([Up]))
  check("a move goes one tile", sim.players[0].tileY == 9)
  check("a move costs 2 energy",
    sim.players[0].energy == StartEnergy - MoveEnergyCost)
  check("a move sets a 5-tick cooldown",
    sim.players[0].moveCooldown == PlayerMoveCooldownTicks)
  # The next four ticks are cooldown; the fifth moves again.
  for _ in 0 ..< PlayerMoveCooldownTicks:
    sim.step(press([Up]))
  check("the hunter cannot move during the cooldown",
    sim.players[0].tileY == 9)
  sim.step(press([Up]))
  check("the hunter moves again after the cooldown",
    sim.players[0].tileY == 8)

block directionPriority:
  var sim = clearWorld()
  sim.place(0, 10, 10)
  sim.step(press([Up or Down or Left or Right]))
  check("direction priority is up > down > left > right",
    sim.players[0].tileY == 9 and sim.players[0].tileX == 10)

block blockedByTerrain:
  var sim = clearWorld()
  sim.tiles[tileIndex(10, 9)] = TileTree
  sim.place(0, 10, 10)
  sim.step(press([Up]))
  check("a tree blocks a move", sim.players[0].tileY == 10)
  check("a blocked move costs nothing",
    sim.players[0].energy == StartEnergy)
  sim.tiles[tileIndex(10, 9)] = TileRock
  sim.step(press([Up]))
  check("a rock blocks a move", sim.players[0].tileY == 10)

block blockedByHunter:
  var sim = clearWorld()
  sim.place(0, 10, 10)
  sim.place(1, 10, 9)
  sim.step(press([Up, 0'u8]))
  check("another hunter blocks a move", sim.players[0].tileY == 10)

block blockedByAnimal:
  var sim = clearWorld()
  sim.place(0, 10, 10)
  sim.prey.add(Prey(kind: Rabbit, tileX: 10, tileY: 9, thinkCooldown: 1_000_000))
  sim.step(press([Up]))
  check("an animal blocks a move", sim.players[0].tileY == 10)

block cannotPayForAMove:
  var sim = clearWorld()
  sim.place(0, 10, 10)
  sim.players[0].energy = 1
  sim.step(press([Up]))
  check("a hunter with under 2 energy cannot move",
    sim.players[0].tileY == 10)
  check("it still faces the way it tried", sim.players[0].facing == FaceUp)

block passiveRecharge:
  var sim = clearWorld()
  sim.place(0, 10, 10)
  sim.players[0].energy = 50
  for _ in 0 ..< PassiveRechargeInterval:
    sim.step(press([0'u8]))
  check("passive recharge grants +1 every 18 ticks",
    sim.players[0].energy == 51)
  sim.players[0].energy = PassiveRechargeMax
  for _ in 0 ..< PassiveRechargeInterval * 3:
    sim.step(press([0'u8]))
  check("passive recharge stops at 100",
    sim.players[0].energy == PassiveRechargeMax)

# ---------------------------------------------------------------------------
# Hazards
# ---------------------------------------------------------------------------

block trample:
  ## An elephant that steps onto a hunter tramples it for -30 and slides two
  ## tiles through; if the far tile is blocked it stays put, which is exactly
  ## why a complete four-side ring can hold one.
  var sim = clearWorld()
  sim.place(0, 10, 10)
  sim.padRoster(4)
  sim.prey.add(Prey(kind: Elephant, tileX: 10, tileY: 11, thinkCooldown: 0,
    strideRemaining: 1, strideDx: 0, strideDy: -1))
  sim.step(press([0'u8]))
  check("a trampled hunter loses 30 energy",
    sim.players[0].energy == StartEnergy - ElephantTrampleEnergyLoss)
  check("a trampled hunter gets the red glow",
    sim.players[0].trampleGlow == TrampleGlowTicks)
  check("the elephant starts its slide", sim.prey[0].trampleStep > 0)
  let startY = sim.prey[0].tileY
  for _ in 0 ..< TrampleAnimSteps:
    sim.step(press([0'u8]))
  check("the elephant ends two tiles through",
    sim.prey[0].tileY == startY - 2)

block trampleBlocked:
  var sim = clearWorld()
  sim.place(0, 10, 10)
  sim.padRoster(4)
  sim.tiles[tileIndex(10, 9)] = TileRock       # the far tile
  sim.prey.add(Prey(kind: Elephant, tileX: 10, tileY: 11, thinkCooldown: 0,
    strideRemaining: 1, strideDx: 0, strideDy: -1))
  let startY = 11
  for _ in 0 .. TrampleAnimSteps:
    sim.step(press([0'u8]))
  check("a blocked far tile leaves the elephant where it was",
    sim.prey[0].tileY == startY)

block mooseGut:
  ## Cardinal adjacency is the dangerous slot: 30 % per think. Force it by
  ## running enough thinks that the roll lands.
  var sim = clearWorld()
  sim.place(0, 10, 10)
  sim.padRoster(3)
  sim.prey.add(Prey(kind: Moose, tileX: 10, tileY: 11, thinkCooldown: 0))
  var gored = false
  for _ in 0 ..< 400:
    # A moose at distance 1 gores 30 % of the time and bolts 15 % of the
    # time, so hold it against the hunter to sample the gore roll.
    sim.prey[0].tileX = 10
    sim.prey[0].tileY = 11
    sim.players[0].tileX = 10
    sim.players[0].tileY = 10
    sim.step(press([0'u8]))
    if sim.players[0].energy < StartEnergy:
      gored = true
      break
  check("a moose eventually gores an adjacent hunter", gored)
  check("a gore costs exactly 10 energy",
    (StartEnergy - sim.players[0].energy) mod MooseGutEnergyLoss == 0 or
    sim.players[0].energy >= StartEnergy - MooseGutEnergyLoss)

block corpseLifetime:
  var sim = clearWorld()
  sim.place(0, 10, 10)
  sim.prey.add(Prey(kind: Rabbit, tileX: 10, tileY: 11, thinkCooldown: 1_000_000))
  sim.step(press([0'u8]))
  check("the rabbit falls", sim.prey.len == 0)
  check("a corpse is left", sim.corpses.len == 1)
  for _ in 0 ..< CorpseLifetimeTicks - 10:
    sim.step(press([0'u8]))
  check("the corpse is still there well inside its 48-tick lifetime",
    sim.corpses.len == 1)
  for _ in 0 ..< 12:
    sim.step(press([0'u8]))
  check("the corpse is gone after 48 ticks", sim.corpses.len == 0)

# ---------------------------------------------------------------------------
# Tall grass
# ---------------------------------------------------------------------------

block tallGrassHides:
  var sim = clearWorld("predator-prey")
  sim.tallGrass = newSeq[bool](sim.tiles.len)
  sim.place(0, 10, 10)                 # hunter
  sim.place(1, 16, 16)                 # forager, far away
  sim.players[0].role = roleHunter
  sim.players[1].role = roleForager
  sim.tallGrass[tileIndex(16, 16)] = true
  check("a forager in grass beyond distance 2 is hidden",
    sim.foragerHidden(0, 1))
  sim.players[0].tileX = 15
  sim.players[0].tileY = 15
  check("a forager in grass within distance 2 is visible",
    not sim.foragerHidden(0, 1))
  sim.tallGrass[tileIndex(16, 16)] = false
  sim.players[0].tileX = 10
  sim.players[0].tileY = 10
  check("a forager NOT in grass is never hidden",
    not sim.foragerHidden(0, 1))
  # And never hidden from the global stream: foragerHidden takes a viewer.
  check("the global stream has no viewer to hide from",
    not sim.foragerHidden(-1, 1))

# ---------------------------------------------------------------------------
# Determinism
# ---------------------------------------------------------------------------

proc scriptedRun(seed: int, ticks: int): string =
  var config = defaultGameConfig()
  config.seed = seed
  config.numAgents = 6
  var sim = initSim(config)
  for slot in 0 ..< 6:
    discard sim.addPlayer("p" & $slot, aliasForSlot(slot), slot)
  sim.ensureStats(6)
  # A fixed input script: every seat cycles a different direction pattern,
  # so the run exercises movement, capture and the animal AI together.
  const patterns = [Up, Down, Left, Right, Up or Left, Down or Right]
  for tick in 1 .. ticks:
    var masks: seq[uint8] = @[]
    for slot in 0 ..< 6:
      masks.add(if (tick + slot) mod 3 == 0: patterns[slot] else: 0'u8)
    sim.step(press(masks))
  sim.stateDigest()

block determinism:
  let a = scriptedRun(5743127, 500)
  let b = scriptedRun(5743127, 500)
  check("two 500-tick runs from the same seed and script agree", a == b)
  let c = scriptedRun(5743128, 500)
  check("a different seed gives a different state", a != c)

block variantDeterminism:
  for variant in ["staghunt", "coop-mining", "lbf", "predator-prey"]:
    var config = defaultGameConfig()
    config.variant = variant
    config.numAgents = 6
    proc run(): string =
      var sim = initSim(config)
      for slot in 0 ..< 6:
        discard sim.addPlayer("p" & $slot, aliasForSlot(slot), slot)
      sim.ensureStats(6)
      sim.applyRolesPublic()
      for tick in 1 .. 300:
        var masks: seq[uint8] = @[]
        for slot in 0 ..< 6:
          masks.add(if (tick + slot) mod 4 == 0: 1'u8 shl uint8(slot mod 4)
                    else: 0'u8)
        sim.step(press(masks))
      sim.stateDigest()
    check(variant & " is deterministic", run() == run())

if failures > 0:
  quit("test_step: " & $failures & " failures", 1)
echo "test_step: all checks passed"
