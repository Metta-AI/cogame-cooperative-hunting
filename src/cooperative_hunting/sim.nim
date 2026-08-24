## The Cooperative Hunting simulation.
##
## Forked from `Metta-AI/coworld-staghunt` `src/staghunt.nim` (world gen,
## movement, prey AI, capture detection, the step loop) and generalised over
## the design note's four variants: the capture predicate becomes a
## `CaptureRule` knob, side occupancy becomes a `windowTicks` stamp, and the
## per-variant furniture (ore, level-bearing food, berries, tall grass,
## roles) rides alongside the animals.
##
## PURE. No mummy, no sockets, no files, no globals. `initSim` builds a whole
## world from a `GameConfig` and `step` advances it one tick. The wasm replay
## module imports this file and re-derives every frame from recorded state.

import std/[algorithm, json, math, random, sequtils, strutils]
import ./sim_types

export sim_types

# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------

proc tileIndex*(tx, ty: int): int = ty * WorldWidthTiles + tx

proc inTileBounds*(tx, ty: int): bool =
  tx >= 0 and ty >= 0 and tx < WorldWidthTiles and ty < WorldHeightTiles

proc tileIsBlocked*(sim: SimServer, tx, ty: int): bool =
  if not inTileBounds(tx, ty):
    return true
  sim.tiles[tileIndex(tx, ty)] != TileEmpty

proc playerAt*(sim: SimServer, tx, ty: int, exceptIndex: int = -1): int =
  for i, p in sim.players:
    if i == exceptIndex or p.disconnected or p.respawnIn > 0:
      continue
    if p.tileX == tx and p.tileY == ty:
      return i
  -1

proc preyAt*(sim: SimServer, tx, ty: int, exceptIndex: int = -1): int =
  for i, p in sim.prey:
    if i == exceptIndex:
      continue
    if p.tileX == tx and p.tileY == ty:
      return i
  -1

proc itemAt*(sim: SimServer, tx, ty: int): int =
  for i, item in sim.items:
    if item.tileX == tx and item.tileY == ty:
      return i
  -1

proc canOccupy*(
  sim: SimServer,
  tx, ty: int,
  exceptPlayerIndex: int = -1,
  exceptPreyIndex: int = -1
): bool =
  if tileIsBlocked(sim, tx, ty):
    return false
  if playerAt(sim, tx, ty, exceptPlayerIndex) >= 0:
    return false
  if preyAt(sim, tx, ty, exceptPreyIndex) >= 0:
    return false
  if itemAt(sim, tx, ty) >= 0:
    return false
  true

proc chebyshevDistance*(ax, ay, bx, by: int): int =
  max(abs(ax - bx), abs(ay - by))

proc manhattanDistance*(ax, ay, bx, by: int): int =
  abs(ax - bx) + abs(ay - by)

proc signOf*(v: int): int =
  if v < 0: -1
  elif v > 0: 1
  else: 0

proc isTallGrass*(sim: SimServer, tx, ty: int): bool =
  inTileBounds(tx, ty) and sim.tallGrass.len == sim.tiles.len and
    sim.tallGrass[tileIndex(tx, ty)]

proc hasAnimals*(sim: SimServer): bool =
  sim.config.variant == "staghunt"

proc hasItems*(sim: SimServer): bool =
  sim.config.variant in ["coop-mining", "lbf"]

proc isPredatorPrey*(sim: SimServer): bool =
  sim.config.variant == "predator-prey"

# ---------------------------------------------------------------------------
# Event logging (in memory; the caller drains it into the replay)
# ---------------------------------------------------------------------------

proc logEvent*(sim: var SimServer, name: string, fields: JsonNode) =
  var body = ""
  for key, value in fields.pairs:
    if body.len > 0:
      body.add(',')
    body.add(escapeJson(key))
    body.add(':')
    body.add($value)
  sim.pendingEvents.add EventRecord(
    tick: sim.globalTick, name: name, payload: body
  )

# ---------------------------------------------------------------------------
# World generation
# ---------------------------------------------------------------------------

proc clearSpawnArea(sim: var SimServer, cx, cy, radius: int) =
  for ty in cy - radius .. cy + radius:
    for tx in cx - radius .. cx + radius:
      if inTileBounds(tx, ty):
        sim.tiles[tileIndex(tx, ty)] = TileEmpty

proc generateWorld(sim: var SimServer) =
  sim.tiles = newSeq[TileKind](WorldWidthTiles * WorldHeightTiles)
  for ty in 0 ..< WorldHeightTiles:
    for tx in 0 ..< WorldWidthTiles:
      if tx == 0 or ty == 0 or tx == WorldWidthTiles - 1 or
          ty == WorldHeightTiles - 1:
        sim.tiles[tileIndex(tx, ty)] = TileRock
        continue
      if sim.rng.rand(999) < ObstacleDensityPerMille:
        if sim.rng.rand(1) == 0:
          sim.tiles[tileIndex(tx, ty)] = TileTree
        else:
          sim.tiles[tileIndex(tx, ty)] = TileRock

  let cx = WorldWidthTiles div 2
  let cy = WorldHeightTiles div 2
  sim.clearSpawnArea(cx, cy, 3)

  for _ in 0 ..< 6:
    let
      bx = 4 + sim.rng.rand(WorldWidthTiles - 8)
      by = 4 + sim.rng.rand(WorldHeightTiles - 8)
    sim.clearSpawnArea(bx, by, 1)

proc findOpenTileNear(
  sim: var SimServer,
  nearX, nearY, radius: int
): tuple[tx, ty: int, ok: bool] =
  for _ in 0 ..< 96:
    let
      dx = sim.rng.rand(radius * 2 + 1) - radius
      dy = sim.rng.rand(radius * 2 + 1) - radius
      tx = nearX + dx
      ty = nearY + dy
    if sim.canOccupy(tx, ty):
      return (tx, ty, true)
  (0, 0, false)

proc findOpenTileAnywhere(sim: var SimServer): tuple[tx, ty: int, ok: bool] =
  for _ in 0 ..< 256:
    let
      tx = 1 + sim.rng.rand(WorldWidthTiles - 3)
      ty = 1 + sim.rng.rand(WorldHeightTiles - 3)
    if sim.canOccupy(tx, ty):
      return (tx, ty, true)
  (0, 0, false)

proc addPlayer*(
  sim: var SimServer,
  name = "",
  alias = "",
  slot = -1,
  kind = pkScripted
): int =
  let
    cx = WorldWidthTiles div 2
    cy = WorldHeightTiles div 2
    spawn = sim.findOpenTileNear(cx, cy, 4)
    (tx, ty) = if spawn.ok: (spawn.tx, spawn.ty) else: (cx, cy)
    assignedSlot = if slot >= 0: slot else: sim.players.len

  sim.players.add Player(
    id: sim.nextPlayerId,
    name: runeCap(name, MaxNameRunes),
    alias: (if alias.len > 0: alias else: aliasForSlot(assignedSlot)),
    slot: assignedSlot,
    tileX: tx,
    tileY: ty,
    facing: FaceDown,
    energy: StartEnergy,
    colorIndex: assignedSlot mod NumPlayerColors,
    level: 1 + (assignedSlot mod 4),
    role: roleHunter,
    kind: kind
  )
  inc sim.nextPlayerId
  sim.players.high

# ---------------------------------------------------------------------------
# Prey population
# ---------------------------------------------------------------------------

proc addPrey(sim: var SimServer, kind: PreyKind) =
  var cx, cy, searchRadius: int
  if sim.focusElephant and kind == Elephant and sim.players.len > 0:
    var sx, sy = 0
    for pl in sim.players:
      sx += pl.tileX
      sy += pl.tileY
    cx = sx div sim.players.len
    cy = sy div sim.players.len
    searchRadius = 2
  else:
    cx = 1 + sim.rng.rand(WorldWidthTiles - 3)
    cy = 1 + sim.rng.rand(WorldHeightTiles - 3)
    searchRadius = 10
  let spot = sim.findOpenTileNear(cx, cy, searchRadius)
  if not spot.ok:
    return
  sim.prey.add Prey(
    id: sim.nextPreyId,
    kind: kind,
    tileX: spot.tx,
    tileY: spot.ty,
    thinkCooldown: sim.rng.rand(PreyThinkIntervalTicks)
  )
  sim.logEvent("prey_spawn", %*{
    "kind": preyLabel(kind), "id": sim.nextPreyId, "x": spot.tx, "y": spot.ty
  })
  inc sim.nextPreyId

proc countKind(sim: SimServer, kind: PreyKind): int =
  for p in sim.prey:
    if p.kind == kind:
      inc result

proc connectedSeats*(sim: SimServer): int =
  for p in sim.players:
    if not p.disconnected:
      inc result

proc preyCatchable*(kind: PreyKind, playerCount: int): bool =
  preyMinPlayers(kind) <= playerCount

proc catchableTargetTotal(playerCount: int): int =
  for kind in PreyKind:
    if preyCatchable(kind, playerCount):
      result += targetFor(kind)

proc cullUncatchablePrey(sim: var SimServer) =
  let playerCount = sim.connectedSeats()
  var kept: seq[Prey] = @[]
  for p in sim.prey:
    if preyCatchable(p.kind, playerCount):
      kept.add(p)
  sim.prey = kept

proc maintainPrey(sim: var SimServer) =
  let playerCount = sim.connectedSeats()
  if playerCount == 0:
    return

  sim.cullUncatchablePrey()

  dec sim.respawnCooldown
  if sim.respawnCooldown > 0:
    return

  var spawned = false
  for kind in PreyKind:
    if sim.focusElephant and kind != Elephant:
      continue
    let target =
      if sim.focusElephant: 1
      else: targetFor(kind)
    if preyCatchable(kind, playerCount) and sim.countKind(kind) < target:
      sim.addPrey(kind)
      spawned = true
      break

  if not spawned:
    sim.respawnCooldown = RespawnIntervalTicks
    return

  let
    target = catchableTargetTotal(playerCount)
    have = sim.prey.len
  if target - have >= 4:
    sim.respawnCooldown = CatchupSpawnCooldown
  else:
    sim.respawnCooldown = RespawnIntervalTicks

# ---------------------------------------------------------------------------
# Item population (coop-mining ore, lbf food)
# ---------------------------------------------------------------------------

proc countItems(sim: SimServer, kind: ItemKind): int =
  for item in sim.items:
    if item.kind == kind:
      inc result

proc addItem(sim: var SimServer, kind: ItemKind) =
  let spot = sim.findOpenTileAnywhere()
  if not spot.ok:
    return
  var level = 0
  if kind == itFood:
    level = 1 + sim.rng.rand(MaxFoodLevel - 1)
  sim.items.add Item(
    id: sim.nextItemId,
    kind: kind,
    tileX: spot.tx,
    tileY: spot.ty,
    level: level
  )
  sim.logEvent("prey_spawn", %*{
    "kind": (case kind
             of itIron: "iron"
             of itGold: "gold"
             of itFood: "food"),
    "id": sim.nextItemId, "x": spot.tx, "y": spot.ty, "level": level
  })
  inc sim.nextItemId

proc maintainItems(sim: var SimServer) =
  if not sim.hasItems():
    return
  dec sim.respawnCooldown
  if sim.respawnCooldown > 0:
    return
  var spawned = false
  if sim.config.variant == "coop-mining":
    if sim.countItems(itIron) < TargetIronNodes:
      sim.addItem(itIron)
      spawned = true
    elif sim.countItems(itGold) < TargetGoldNodes:
      sim.addItem(itGold)
      spawned = true
  else:
    if sim.countItems(itFood) < TargetFoodItems:
      sim.addItem(itFood)
      spawned = true
  if not spawned:
    sim.respawnCooldown = RespawnIntervalTicks
    return
  let missing =
    if sim.config.variant == "coop-mining":
      TargetIronNodes + TargetGoldNodes - sim.items.len
    else:
      TargetFoodItems - sim.items.len
  sim.respawnCooldown =
    if missing >= 4: CatchupSpawnCooldown else: RespawnIntervalTicks

# ---------------------------------------------------------------------------
# predator-prey furniture
# ---------------------------------------------------------------------------

proc roleFor*(slot, roundIndex: int): PlayerRole =
  if (slot + roundIndex) mod 2 == 0: roleHunter else: roleForager

proc placePredatorPreyFurniture(sim: var SimServer) =
  sim.tallGrass = newSeq[bool](WorldWidthTiles * WorldHeightTiles)
  sim.berries = @[]
  var placed = 0
  var attempts = 0
  while placed < TallGrassTiles and attempts < TallGrassTiles * 40:
    inc attempts
    let
      tx = 1 + sim.rng.rand(WorldWidthTiles - 3)
      ty = 1 + sim.rng.rand(WorldHeightTiles - 3)
    if sim.tileIsBlocked(tx, ty) or sim.tallGrass[tileIndex(tx, ty)]:
      continue
    sim.tallGrass[tileIndex(tx, ty)] = true
    inc placed
  placed = 0
  attempts = 0
  var taken = newSeq[bool](WorldWidthTiles * WorldHeightTiles)
  while placed < BerryTiles and attempts < BerryTiles * 40:
    inc attempts
    let
      tx = 1 + sim.rng.rand(WorldWidthTiles - 3)
      ty = 1 + sim.rng.rand(WorldHeightTiles - 3)
    if sim.tileIsBlocked(tx, ty) or taken[tileIndex(tx, ty)]:
      continue
    taken[tileIndex(tx, ty)] = true
    sim.berries.add Berry(tileX: tx, tileY: ty, regrow: 0)
    inc placed

proc applyRoles(sim: var SimServer) =
  if not sim.isPredatorPrey():
    for i in 0 ..< sim.players.len:
      sim.players[i].role = roleHunter
    return
  for i in 0 ..< sim.players.len:
    sim.players[i].role = roleFor(sim.players[i].slot, sim.roundIndex)

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

proc applyVariant*(sim: var SimServer) =
  sim.captureRule = captureRuleFor(sim.config.variant)
  sim.windowTicks = windowTicksFor(sim.config.variant)
  sim.rewardSplit = rewardSplitFor(sim.config.variant)

proc initSim*(config: GameConfig): SimServer =
  ## Build a fresh world. Deterministic in `config.seed`; the art cache is
  ## NOT populated here (art.nim owns that, so this module stays file-free).
  result.config = config
  result.applyVariant()
  result.rng = initRand(config.seed)
  result.generateWorld()
  result.respawnCooldown = RespawnIntervalTicks
  result.focusElephant = config.focusElephant
  result.phase = RoundPlaying
  result.tallGrass = newSeq[bool](WorldWidthTiles * WorldHeightTiles)
  if result.isPredatorPrey():
    result.placePredatorPreyFurniture()

proc seatAliases*(numAgents, seed: int): seq[string] =
  ## A seeded permutation of Cog-A..Cog-F over the slots, so no policy can
  ## infer "slot 0 is always the strongest entrant".
  var order = toSeq(0 ..< numAgents)
  var rng = initRand(seed xor 0x5EA7A11A)
  for i in countdown(order.high, 1):
    let j = rng.rand(i)
    swap(order[i], order[j])
  result = newSeq[string](numAgents)
  for slot in 0 ..< numAgents:
    result[slot] = aliasForSlot(order[slot])

# ---------------------------------------------------------------------------
# Hunter phase
# ---------------------------------------------------------------------------

proc applyPlayerInput(sim: var SimServer, playerIndex: int, input: InputState) =
  template p: untyped = sim.players[playerIndex]

  if p.disconnected:
    return

  if p.respawnIn > 0:
    dec p.respawnIn
    if p.respawnIn == 0:
      # Come back at a free tile within 4 of the map edge.
      var spot = (tx: 0, ty: 0, ok: false)
      for _ in 0 ..< 64:
        let edge = sim.rng.rand(3)
        let along = 1 + sim.rng.rand(WorldWidthTiles - 3)
        let depth = 1 + sim.rng.rand(3)
        let (tx, ty) =
          case edge
          of 0: (along, depth)
          of 1: (along, WorldHeightTiles - 1 - depth)
          of 2: (depth, along)
          else: (WorldWidthTiles - 1 - depth, along)
        if sim.canOccupy(tx, ty, exceptPlayerIndex = playerIndex):
          spot = (tx, ty, true)
          break
      if spot.ok:
        p.tileX = spot.tx
        p.tileY = spot.ty
      sim.logEvent("player_spawn", %*{
        "slot": p.slot, "alias": p.alias, "x": p.tileX, "y": p.tileY
      })
    return

  if input.select and not p.selectWasDown:
    p.overlayActive = not p.overlayActive
  p.selectWasDown = input.select

  inc p.rechargeCounter
  if p.rechargeCounter >= PassiveRechargeInterval:
    p.rechargeCounter = 0
    if p.energy < PassiveRechargeMax:
      inc p.energy

  if p.killGlow > 0:
    dec p.killGlow

  if p.trampleGlow > 0:
    dec p.trampleGlow

  if p.pushStep > 0:
    dec p.pushStep

  if p.moveCooldown > 0:
    dec p.moveCooldown
    return

  var dx = 0
  var dy = 0
  if input.up: dy = -1
  elif input.down: dy = 1
  elif input.left: dx = -1
  elif input.right: dx = 1

  if dx == 0 and dy == 0:
    return

  if dx > 0: p.facing = FaceRight
  elif dx < 0: p.facing = FaceLeft
  elif dy > 0: p.facing = FaceDown
  elif dy < 0: p.facing = FaceUp

  if p.energy < MoveEnergyCost:
    return

  let nx = p.tileX + dx
  let ny = p.tileY + dy
  if sim.canOccupy(nx, ny, exceptPlayerIndex = playerIndex):
    p.tileX = nx
    p.tileY = ny
    p.energy -= MoveEnergyCost
    p.moveCooldown = PlayerMoveCooldownTicks

# ---------------------------------------------------------------------------
# Animal AI (verbatim from staghunt; balance constants are not retuned in v1)
# ---------------------------------------------------------------------------

proc tryPreyMove(sim: var SimServer, preyIndex, dx, dy: int): bool =
  template p: untyped = sim.prey[preyIndex]
  let nx = p.tileX + dx
  let ny = p.tileY + dy
  if sim.canOccupy(nx, ny, exceptPreyIndex = preyIndex):
    p.tileX = nx
    p.tileY = ny
    return true
  false

proc thinkElephant(sim: var SimServer, preyIndex: int): int =
  template p: untyped = sim.prey[preyIndex]

  var dx: int
  var dy: int
  if p.strideRemaining > 0:
    dx = p.strideDx
    dy = p.strideDy
    dec p.strideRemaining
    result = ElephantThinkMin
  else:
    const allDirs = [(0, -1), (1, 0), (0, 1), (-1, 0)]
    var openDirs: seq[tuple[dx, dy: int]] = @[]
    for d in allDirs:
      let
        nx = p.tileX + d[0]
        ny = p.tileY + d[1]
      if inTileBounds(nx, ny) and not sim.tileIsBlocked(nx, ny):
        openDirs.add(d)
    if openDirs.len == 0:
      result = ElephantThinkMin +
        sim.rng.rand(ElephantThinkMax - ElephantThinkMin)
      return
    let pick = openDirs[sim.rng.rand(openDirs.len - 1)]
    dx = pick.dx
    dy = pick.dy
    result = ElephantThinkMin +
      sim.rng.rand(ElephantThinkMax - ElephantThinkMin)

  let
    nx = p.tileX + dx
    ny = p.tileY + dy
  if not inTileBounds(nx, ny) or sim.tileIsBlocked(nx, ny):
    p.strideRemaining = 0
    return
  let playerIdx = sim.playerAt(nx, ny)
  if playerIdx >= 0:
    sim.players[playerIdx].energy =
      max(0, sim.players[playerIdx].energy - ElephantTrampleEnergyLoss)
    sim.players[playerIdx].trampleGlow = TrampleGlowTicks
    sim.logEvent("trample", %*{
      "alias": sim.players[playerIdx].alias,
      "slot": sim.players[playerIdx].slot,
      "energy_after": sim.players[playerIdx].energy
    })
    p.trampleStep = TrampleAnimSteps
    p.trampleDx = dx
    p.trampleDy = dy
    return
  if sim.preyAt(nx, ny, exceptIndex = preyIndex) >= 0:
    p.strideRemaining = 0
    return
  p.tileX = nx
  p.tileY = ny
  if p.strideRemaining == 0 and sim.rng.rand(99) < ElephantStrideProb:
    p.strideRemaining = ElephantStrideMin +
      sim.rng.rand(ElephantStrideMax - ElephantStrideMin)
    p.strideDx = dx
    p.strideDy = dy

proc thinkPrey(sim: var SimServer, preyIndex: int) =
  template p: untyped = sim.prey[preyIndex]

  if p.alertFlash > 0:
    dec p.alertFlash

  if p.kind == Elephant and p.trampleStep > 0:
    dec p.trampleStep
    if p.trampleStep == 0:
      let
        fx = p.tileX + p.trampleDx * 2
        fy = p.tileY + p.trampleDy * 2
      if inTileBounds(fx, fy) and not sim.tileIsBlocked(fx, fy) and
          sim.playerAt(fx, fy) < 0 and
          sim.preyAt(fx, fy, exceptIndex = preyIndex) < 0:
        p.tileX = fx
        p.tileY = fy
    return

  if p.kind == Moose and p.gutStep > 0:
    dec p.gutStep
    return

  if p.thinkCooldown > 0:
    dec p.thinkCooldown
    return
  if p.kind == Elephant:
    p.thinkCooldown = sim.thinkElephant(preyIndex)
    return

  p.thinkCooldown =
    case p.kind
    of Rabbit: PreyThinkIntervalTicks       # 10
    of Boar: PreyThinkIntervalTicks + 4     # 14
    of Stag: PreyThinkIntervalTicks + 6     # 16
    of Moose: PreyThinkIntervalTicks + 10   # 20
    of Elephant: PreyThinkIntervalTicks     # unreachable; handled above

  var nearestDist = high(int)
  var nearestX = 0
  var nearestY = 0
  var nearestPlayerIdx = -1
  for i, pl in sim.players:
    if pl.disconnected or pl.respawnIn > 0:
      continue
    let d = chebyshevDistance(p.tileX, p.tileY, pl.tileX, pl.tileY)
    if d < nearestDist:
      nearestDist = d
      nearestX = pl.tileX
      nearestY = pl.tileY
      nearestPlayerIdx = i

  if nearestPlayerIdx < 0:
    return

  let alerted = nearestDist > 0 and nearestDist <= PreyFleeRadius

  if alerted:
    p.alertFlash = AlertFlashTicks

    if p.kind == Moose and nearestDist == 1 and nearestPlayerIdx >= 0:
      let manhattan = abs(nearestX - p.tileX) + abs(nearestY - p.tileY)
      let gutProb =
        if manhattan == 1: MooseGutProbCardinal
        else: MooseGutProbDiagonal
      if sim.rng.rand(99) < gutProb:
        let pushDx = signOf(nearestX - p.tileX)
        let pushDy = signOf(nearestY - p.tileY)
        let pushedX = nearestX + pushDx
        let pushedY = nearestY + pushDy
        sim.players[nearestPlayerIdx].energy =
          max(0, sim.players[nearestPlayerIdx].energy - MooseGutEnergyLoss)
        sim.players[nearestPlayerIdx].trampleGlow = TrampleGlowTicks
        var pushed = false
        if sim.canOccupy(pushedX, pushedY,
            exceptPlayerIndex = nearestPlayerIdx):
          sim.players[nearestPlayerIdx].tileX = pushedX
          sim.players[nearestPlayerIdx].tileY = pushedY
          pushed = true
          sim.players[nearestPlayerIdx].pushStep = MooseGutAnimSteps
          sim.players[nearestPlayerIdx].pushDx = pushDx
          sim.players[nearestPlayerIdx].pushDy = pushDy
          p.gutStep = MooseGutAnimSteps
          p.gutDx = pushDx
          p.gutDy = pushDy
        sim.logEvent("moose_gut", %*{
          "alias": sim.players[nearestPlayerIdx].alias,
          "slot": sim.players[nearestPlayerIdx].slot,
          "energy_after": sim.players[nearestPlayerIdx].energy,
          "pushed": pushed
        })
        return

    let baseProb =
      case nearestDist
      of 1: PreyFleeProb1
      of 2: PreyFleeProb2
      else: PreyFleeProb3
    let fleeProb =
      case p.kind
      of Rabbit: baseProb
      of Boar: (baseProb * 80) div 100
      of Stag: (baseProb * 70) div 100
      of Moose:
        case nearestDist
        of 1: (baseProb * 20) div 100
        of 2: (baseProb * 60) div 100
        else: (baseProb * 40) div 100
      of Elephant: (baseProb * 25) div 100
    if sim.rng.rand(99) < fleeProb:
      let dx = signOf(p.tileX - nearestX)
      let dy = signOf(p.tileY - nearestY)
      if dx != 0 or dy != 0:
        if sim.tryPreyMove(preyIndex, dx, dy):
          return
        if dx != 0 and sim.tryPreyMove(preyIndex, dx, 0):
          return
        if dy != 0 and sim.tryPreyMove(preyIndex, 0, dy):
          return
        if dy != 0:
          if sim.tryPreyMove(preyIndex, 1, dy):
            return
          if sim.tryPreyMove(preyIndex, -1, dy):
            return
        if dx != 0:
          if sim.tryPreyMove(preyIndex, dx, 1):
            return
          if sim.tryPreyMove(preyIndex, dx, -1):
            return
        if dx != 0 and sim.tryPreyMove(preyIndex, 0, 1):
          return
        if dx != 0 and sim.tryPreyMove(preyIndex, 0, -1):
          return
        if dy != 0 and sim.tryPreyMove(preyIndex, 1, 0):
          return
        if dy != 0 and sim.tryPreyMove(preyIndex, -1, 0):
          return
    return

  if sim.rng.rand(99) < PreyWanderProb:
    let dx = sim.rng.rand(2) - 1
    let dy = sim.rng.rand(2) - 1
    if dx == 0 and dy == 0:
      return
    discard sim.tryPreyMove(preyIndex, dx, dy)

# ---------------------------------------------------------------------------
# Side bookkeeping and capture resolution
# ---------------------------------------------------------------------------

const SideOffsets*: array[4, tuple[dx, dy: int]] =
  [(0, -1), (0, 1), (1, 0), (-1, 0)]   ## N, S, E, W
const SideNames*: array[4, string] = ["N", "S", "E", "W"]

proc stampSides(sim: var SimServer) =
  ## Step 5 of the tick: for every animal and node, stamp
  ## `sideSeen[side] = (tick, slot)` for each cardinal tile a hunter is on.
  for i in 0 ..< sim.prey.len:
    for side in 0 ..< 4:
      let
        tx = sim.prey[i].tileX + SideOffsets[side].dx
        ty = sim.prey[i].tileY + SideOffsets[side].dy
        who = sim.playerAt(tx, ty)
      if who >= 0:
        sim.prey[i].sideSeen[side] =
          SideStamp(tick: sim.globalTick, slot: sim.players[who].slot)
  for i in 0 ..< sim.items.len:
    for side in 0 ..< 4:
      let
        tx = sim.items[i].tileX + SideOffsets[side].dx
        ty = sim.items[i].tileY + SideOffsets[side].dy
        who = sim.playerAt(tx, ty)
      if who >= 0:
        sim.items[i].sideSeen[side] =
          SideStamp(tick: sim.globalTick, slot: sim.players[who].slot)

proc restampSides*(sim: var SimServer) =
  ## Public entry point for the replay viewer: after a tick's positions have
  ## been restored from the recorded arrays, re-derive the side stamps so the
  ## capture indicators and the gold countdown ring render exactly as they
  ## did live.
  sim.stampSides()

proc sideIsOccupied*(sim: SimServer, stamp: SideStamp): bool =
  ## A side counts as occupied when `tick - sideSeen.tick <= windowTicks - 1`.
  ## `windowTicks = 1` reproduces the base rule exactly, so staghunt and
  ## coop-mining run through the same code path.
  stamp.tick > 0 and sim.globalTick - stamp.tick <= sim.windowTicks - 1

proc occupiedSides*(sim: SimServer, stamps: array[4, SideStamp]): array[4, bool] =
  for side in 0 ..< 4:
    result[side] = sim.sideIsOccupied(stamps[side])

proc isCapturedBySides*(sides: array[4, bool], kind: PreyKind): bool =
  let
    n = sides[0]
    s = sides[1]
    e = sides[2]
    w = sides[3]
  case kind
  of Rabbit:
    n or s or e or w
  of Boar:
    (n and e) or (n and w) or (s and e) or (s and w)
  of Stag:
    (n and s) or (e and w)
  of Moose:
    (if n: 1 else: 0) + (if s: 1 else: 0) + (if e: 1 else: 0) +
      (if w: 1 else: 0) >= 3
  of Elephant:
    n and s and e and w

proc distinctSlots*(
  sim: SimServer, stamps: array[4, SideStamp], sides: array[4, bool]
): seq[int] =
  for side in 0 ..< 4:
    if not sides[side]:
      continue
    let slot = stamps[side].slot
    if slot >= 0 and slot notin result:
      result.add(slot)
  result.sort()

proc playerIndexOfSlot*(sim: SimServer, slot: int): int =
  for i, p in sim.players:
    if p.slot == slot:
      return i
  -1

proc levelSumOf(sim: SimServer, slots: seq[int]): int =
  for slot in slots:
    let idx = sim.playerIndexOfSlot(slot)
    if idx >= 0:
      result += sim.players[idx].level

proc creditCapture(
  sim: var SimServer,
  slots: seq[int],
  scoreTotal, energyEach: int,
  label: string,
  tx, ty: int,
  big: bool,
  splitScore: bool
): Capture =
  ## Awards score and energy, sets the kill glow, and returns the record the
  ## caller turns into an event, a feed line and a beat.
  result = Capture(
    tick: sim.globalTick, label: label, tileX: tx, tileY: ty,
    slots: slots, energyEach: energyEach, big: big
  )
  result.scoreEach = newSeq[int](slots.len)
  for i, slot in slots:
    var award = scoreTotal
    if splitScore and slots.len > 0:
      award = scoreTotal div slots.len
      if i == 0:  # slots is sorted ascending, so slots[0] is the lowest slot
        award += scoreTotal mod slots.len
    result.scoreEach[i] = award
    let idx = sim.playerIndexOfSlot(slot)
    if idx >= 0:
      sim.players[idx].score += award
      sim.players[idx].energy =
        min(MaxEnergy, sim.players[idx].energy + energyEach)
      sim.players[idx].killGlow = KillGlowTicks

proc recordCaptureEvent(sim: var SimServer, capture: Capture, name: string) =
  var by = newJArray()
  for i, slot in capture.slots:
    let idx = sim.playerIndexOfSlot(slot)
    by.add(%*{
      "slot": slot,
      "alias": (if idx >= 0: sim.players[idx].alias else: aliasForSlot(slot)),
      "score": (if idx >= 0: sim.players[idx].score else: 0),
      "gain": capture.scoreEach[i]
    })
  sim.logEvent(name, %*{
    "kind": capture.label,
    "x": capture.tileX,
    "y": capture.tileY,
    "by": by,
    "energy": capture.energyEach
  })

proc bumpStats(sim: var SimServer, slots: seq[int], kind: PreyKind) =
  for slot in slots:
    if slot < 0 or slot >= sim.stats.len:
      continue
    inc sim.stats[slot].catches[kind]
    for other in slots:
      if other != slot and other >= 0 and other < sim.stats[slot].coCatches.len:
        inc sim.stats[slot].coCatches[other]

proc applyAnimalCaptures(sim: var SimServer) =
  var removed: seq[int] = @[]
  for i in 0 ..< sim.prey.len:
    let sides = sim.occupiedSides(sim.prey[i].sideSeen)
    if not isCapturedBySides(sides, sim.prey[i].kind):
      continue
    let reward = rewardsFor(sim.prey[i].kind)
    let slots = sim.distinctSlots(sim.prey[i].sideSeen, sides)
    if slots.len == 0:
      continue
    let capture = sim.creditCapture(
      slots, reward.score, reward.energy, preyLabel(sim.prey[i].kind),
      sim.prey[i].tileX, sim.prey[i].tileY,
      big = sim.prey[i].kind in {Stag, Moose, Elephant},
      splitScore = false
    )
    sim.bumpStats(slots, sim.prey[i].kind)
    sim.corpses.add Corpse(
      tileX: sim.prey[i].tileX,
      tileY: sim.prey[i].tileY,
      ticksRemaining: CorpseLifetimeTicks
    )
    sim.recordCaptureEvent(capture, "catch")
    sim.pendingCaptures.add(capture)
    removed.add(i)
  for i in countdown(removed.high, 0):
    sim.prey.delete(removed[i])

proc applyItemCaptures(sim: var SimServer) =
  var removed: seq[int] = @[]
  for i in 0 ..< sim.items.len:
    let sides = sim.occupiedSides(sim.items[i].sideSeen)
    let slots = sim.distinctSlots(sim.items[i].sideSeen, sides)
    if slots.len == 0:
      continue
    var scoreTotal = 0
    var energyEach = 0
    var big = false
    var eventName = "mine"
    case sim.items[i].kind
    of itIron:
      if slots.len < 1:
        continue
      scoreTotal = IronScoreReward
      energyEach = IronEnergyReward
    of itGold:
      if slots.len < 2:
        continue
      scoreTotal = GoldScoreReward
      energyEach = GoldEnergyReward
      big = true
    of itFood:
      eventName = "pickup"
      if sim.levelSumOf(slots) < sim.items[i].level:
        continue
      scoreTotal = LbfScorePerLevel * sim.items[i].level
      energyEach = LbfEnergyPerLevel * sim.items[i].level
      big = sim.items[i].level >= 4
    let capture = sim.creditCapture(
      slots, scoreTotal, energyEach, itemLabel(sim.items[i]),
      sim.items[i].tileX, sim.items[i].tileY, big,
      splitScore = sim.rewardSplit and sim.items[i].kind == itFood
    )
    sim.corpses.add Corpse(
      tileX: sim.items[i].tileX,
      tileY: sim.items[i].tileY,
      ticksRemaining: CorpseLifetimeTicks div 2
    )
    sim.recordCaptureEvent(capture, eventName)
    sim.pendingCaptures.add(capture)
    removed.add(i)
  for i in countdown(removed.high, 0):
    sim.items.delete(removed[i])

proc applyTagsAndForage(sim: var SimServer) =
  ## predator-prey only. Tag resolution first, then forage resolution.
  if not sim.isPredatorPrey():
    return
  for target in 0 ..< sim.players.len:
    if sim.players[target].role != roleForager:
      continue
    if sim.players[target].disconnected or sim.players[target].respawnIn > 0:
      continue
    var sideSlot: array[4, int] = [-1, -1, -1, -1]
    for side in 0 ..< 4:
      let
        tx = sim.players[target].tileX + SideOffsets[side].dx
        ty = sim.players[target].tileY + SideOffsets[side].dy
        who = sim.playerAt(tx, ty)
      if who >= 0 and sim.players[who].role == roleHunter:
        sideSlot[side] = sim.players[who].slot
    # The stag predicate applied to a player: two hunters on opposite sides.
    let opposedNS = sideSlot[0] >= 0 and sideSlot[1] >= 0
    let opposedEW = sideSlot[2] >= 0 and sideSlot[3] >= 0
    if not (opposedNS or opposedEW):
      continue
    var slots: seq[int] = @[]
    for side in 0 ..< 4:
      if sideSlot[side] >= 0 and sideSlot[side] notin slots:
        slots.add(sideSlot[side])
    slots.sort()
    let capture = sim.creditCapture(
      slots, TagScoreReward, 0, "tag on " & sim.players[target].alias,
      sim.players[target].tileX, sim.players[target].tileY,
      big = true, splitScore = false
    )
    sim.players[target].energy =
      max(0, sim.players[target].energy - TagEnergyLoss)
    sim.players[target].trampleGlow = TrampleGlowTicks
    sim.players[target].respawnIn = TagRespawnTicks
    var by = newJArray()
    for i, slot in slots:
      let idx = sim.playerIndexOfSlot(slot)
      by.add(%*{
        "slot": slot,
        "alias": (if idx >= 0: sim.players[idx].alias else: aliasForSlot(slot)),
        "gain": capture.scoreEach[i]
      })
    sim.logEvent("tag", %*{
      "target": sim.players[target].alias,
      "target_slot": sim.players[target].slot,
      "x": capture.tileX, "y": capture.tileY,
      "by": by
    })
    sim.pendingCaptures.add(capture)

  for b in 0 ..< sim.berries.len:
    if sim.berries[b].regrow > 0:
      continue
    let who = sim.playerAt(sim.berries[b].tileX, sim.berries[b].tileY)
    if who < 0 or sim.players[who].role != roleForager:
      continue
    sim.players[who].score += BerryScoreReward
    sim.players[who].energy =
      min(MaxEnergy, sim.players[who].energy + BerryEnergyReward)
    sim.players[who].killGlow = KillGlowTicks
    sim.berries[b].regrow = BerryRegrowTicks
    let capture = Capture(
      tick: sim.globalTick,
      label: "berries",
      tileX: sim.berries[b].tileX,
      tileY: sim.berries[b].tileY,
      slots: @[sim.players[who].slot],
      scoreEach: @[BerryScoreReward],
      energyEach: BerryEnergyReward,
      big: false
    )
    sim.logEvent("forage", %*{
      "alias": sim.players[who].alias,
      "slot": sim.players[who].slot,
      "x": capture.tileX, "y": capture.tileY,
      "gain": BerryScoreReward
    })
    sim.pendingCaptures.add(capture)

# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------

proc ageCorpses(sim: var SimServer) =
  var kept: seq[Corpse] = @[]
  for c in sim.corpses:
    if c.ticksRemaining > 1:
      var alive = c
      dec alive.ticksRemaining
      kept.add(alive)
  sim.corpses = kept

proc tickBerries(sim: var SimServer) =
  for b in 0 ..< sim.berries.len:
    if sim.berries[b].regrow > 0:
      dec sim.berries[b].regrow

# ---------------------------------------------------------------------------
# Visibility (the SAME predicate the per-seat frame builder uses)
# ---------------------------------------------------------------------------

proc playerCamera*(player: Player): tuple[x, y: int] =
  proc clampCamera(value, worldMax, viewMax: int): int =
    if worldMax <= viewMax:
      return (worldMax - viewMax) div 2
    value.clamp(0, worldMax - viewMax)
  let
    centerX = player.tileX * StagTileSize + StagTileSize div 2
    centerY = player.tileY * StagTileSize + StagTileSize div 2
  (
    clampCamera(centerX - PlayerViewportWidth div 2, WorldWidthPixels,
      PlayerViewportWidth),
    clampCamera(centerY - PlayerViewportHeight div 2, WorldHeightPixels,
      PlayerViewportHeight)
  )

proc tileInViewport*(cameraX, cameraY, tx, ty: int): bool =
  let
    sx = tx * StagTileSize - cameraX
    sy = ty * StagTileSize - cameraY
  sx > -StagTileSize and sy > -StagTileSize and
    sx < PlayerViewportWidth and sy < PlayerViewportHeight

proc foragerHidden*(sim: SimServer, viewerIndex, targetIndex: int): bool =
  ## Tall grass hides foragers: a forager standing on a tall-grass tile is
  ## not drawn in a hunter's per-seat frame unless that hunter is within
  ## Chebyshev distance 2. It is ALWAYS drawn in the global/replay stream.
  if not sim.isPredatorPrey():
    return false
  if viewerIndex == targetIndex or viewerIndex < 0 or targetIndex < 0:
    return false
  if sim.players[targetIndex].role != roleForager:
    return false
  if not sim.isTallGrass(sim.players[targetIndex].tileX,
      sim.players[targetIndex].tileY):
    return false
  chebyshevDistance(
    sim.players[viewerIndex].tileX, sim.players[viewerIndex].tileY,
    sim.players[targetIndex].tileX, sim.players[targetIndex].tileY
  ) > GrassRevealDistance

proc visibleToSeat*(sim: SimServer, viewerIndex, targetIndex: int): bool =
  ## Whether hunter `viewerIndex` can see hunter `targetIndex` right now.
  ## The LLM observation is composed from EXACTLY this predicate, so a prompt
  ## seat cannot see further than a scripted seat.
  if viewerIndex < 0 or viewerIndex >= sim.players.len:
    return false
  if targetIndex < 0 or targetIndex >= sim.players.len:
    return false
  if sim.players[targetIndex].disconnected:
    return false
  if sim.players[targetIndex].respawnIn > 0 and viewerIndex != targetIndex:
    return false
  let (cameraX, cameraY) = playerCamera(sim.players[viewerIndex])
  if not tileInViewport(cameraX, cameraY,
      sim.players[targetIndex].tileX, sim.players[targetIndex].tileY):
    return false
  not sim.foragerHidden(viewerIndex, targetIndex)

proc preyVisibleToSeat*(sim: SimServer, viewerIndex, preyIndex: int): bool =
  if viewerIndex < 0 or viewerIndex >= sim.players.len:
    return false
  let (cameraX, cameraY) = playerCamera(sim.players[viewerIndex])
  tileInViewport(cameraX, cameraY, sim.prey[preyIndex].tileX,
    sim.prey[preyIndex].tileY)

proc itemVisibleToSeat*(sim: SimServer, viewerIndex, itemIndex: int): bool =
  if viewerIndex < 0 or viewerIndex >= sim.players.len:
    return false
  let (cameraX, cameraY) = playerCamera(sim.players[viewerIndex])
  tileInViewport(cameraX, cameraY, sim.items[itemIndex].tileX,
    sim.items[itemIndex].tileY)

# ---------------------------------------------------------------------------
# Capture-readiness indicators
# ---------------------------------------------------------------------------

proc validIndicatorSides*(kind: PreyKind, sides: array[4, bool]): array[4, bool] =
  ## Which unoccupied sides (N,S,E,W) would move a capture forward.
  let
    n = sides[0]
    s = sides[1]
    e = sides[2]
    w = sides[3]
  case kind
  of Rabbit:
    result = [false, false, false, false]
  of Boar:
    if n or s:
      result[2] = not e
      result[3] = not w
    if e or w:
      result[0] = not n
      result[1] = not s
  of Stag:
    if n: result[1] = not s
    if s: result[0] = not n
    if e: result[3] = not w
    if w: result[2] = not e
  of Moose, Elephant:
    result[0] = not n
    result[1] = not s
    result[2] = not e
    result[3] = not w

proc sideCountOf*(sides: array[4, bool]): int =
  for side in sides:
    if side: inc result

proc itemNeeds*(sim: SimServer, item: Item, sides: array[4, bool]): int =
  ## How many more distinct hunters this node needs.
  let have = sideCountOf(sides)
  case item.kind
  of itIron: max(0, 1 - have)
  of itGold: max(0, 2 - have)
  of itFood:
    if have == 0: 1
    else:
      var slots: seq[int] = @[]
      for side in 0 ..< 4:
        if sides[side] and item.sideSeen[side].slot notin slots:
          slots.add(item.sideSeen[side].slot)
      if sim.levelSumOf(slots) >= item.level: 0 else: 1

# ---------------------------------------------------------------------------
# The tick
# ---------------------------------------------------------------------------

proc step*(sim: var SimServer, inputs: openArray[InputState]) =
  ## One simulation tick, in the exact resolution order the design note
  ## specifies. Nothing in that list is order-independent, so the list IS the
  ## specification. Ties resolve by ascending slot, then ascending index.
  sim.pendingCaptures.setLen(0)
  sim.pendingEvents.setLen(0)
  inc sim.tickCount
  inc sim.globalTick

  # 3. Hunter phase, ascending slot.
  for playerIndex in 0 ..< sim.players.len:
    let input =
      if playerIndex < inputs.len: inputs[playerIndex] else: InputState()
    sim.applyPlayerInput(playerIndex, input)

  # 4. Animal phase, ascending prey index.
  for preyIndex in 0 ..< sim.prey.len:
    sim.thinkPrey(preyIndex)

  # 5. Side bookkeeping.
  sim.stampSides()

  # 6. Capture resolution.
  sim.applyAnimalCaptures()
  sim.applyItemCaptures()

  # 7. predator-prey tag + forage resolution.
  sim.applyTagsAndForage()

  # 8. Housekeeping.
  sim.ageCorpses()
  sim.tickBerries()
  if sim.hasAnimals():
    sim.maintainPrey()
  elif sim.hasItems():
    sim.maintainItems()

proc ensureStats*(sim: var SimServer, slots: int) =
  while sim.stats.len < slots:
    var s = PlayerStats()
    s.coCatches = newSeq[int](max(slots, MaxPlayerSlots))
    sim.stats.add(s)

proc resetRound*(sim: var SimServer, roundIndex: int) =
  ## Re-roll prey with `seed + roundIndex`, keep the same map.
  sim.prey = @[]
  sim.items = @[]
  sim.corpses = @[]
  sim.tickCount = 0
  sim.roundIndex = roundIndex
  sim.phase = RoundPlaying
  sim.respawnCooldown = RespawnIntervalTicks
  sim.rng = initRand(sim.config.seed + roundIndex)
  for b in 0 ..< sim.berries.len:
    sim.berries[b].regrow = 0
  sim.applyRoles()
  let
    cx = WorldWidthTiles div 2
    cy = WorldHeightTiles div 2
  for i in 0 ..< sim.players.len:
    let spawn = sim.findOpenTileNear(cx, cy, 4)
    let (tx, ty) = if spawn.ok: (spawn.tx, spawn.ty) else: (cx, cy)
    sim.players[i].tileX = tx
    sim.players[i].tileY = ty
    sim.players[i].facing = FaceDown
    sim.players[i].energy = StartEnergy
    sim.players[i].score = 0
    sim.players[i].moveCooldown = 0
    sim.players[i].killGlow = 0
    sim.players[i].trampleGlow = 0
    sim.players[i].pushStep = 0
    sim.players[i].rechargeCounter = 0
    sim.players[i].respawnIn = 0
    sim.players[i].overlayActive = false

proc startRound*(sim: var SimServer, roundIndex: int) =
  sim.resetRound(roundIndex)
  sim.logEvent("round_start", %*{
    "round": roundIndex + 1,
    "seed": sim.config.seed + roundIndex,
    "ticks": sim.config.ticksPerRound
  })

proc stateDigest*(sim: SimServer): string =
  ## A cheap order-sensitive digest of the whole simulation state, used by
  ## the determinism test. Two runs from the same seed and the same input
  ## script must produce the same string.
  var acc: uint64 = 1469598103934665603'u64
  proc mix(acc: var uint64, value: int) =
    acc = acc xor uint64(value and 0xffffff)
    acc = acc * 1099511628211'u64
  mix(acc, sim.globalTick)
  mix(acc, sim.roundIndex)
  for p in sim.players:
    mix(acc, p.tileX); mix(acc, p.tileY); mix(acc, ord(p.facing))
    mix(acc, p.energy); mix(acc, p.score); mix(acc, p.moveCooldown)
    mix(acc, p.killGlow); mix(acc, p.trampleGlow); mix(acc, p.level)
    mix(acc, ord(p.role)); mix(acc, p.respawnIn)
  for q in sim.prey:
    mix(acc, q.id); mix(acc, ord(q.kind)); mix(acc, q.tileX); mix(acc, q.tileY)
    mix(acc, q.thinkCooldown); mix(acc, q.trampleStep); mix(acc, q.gutStep)
    mix(acc, q.strideRemaining)
  for item in sim.items:
    mix(acc, item.id); mix(acc, ord(item.kind)); mix(acc, item.tileX)
    mix(acc, item.tileY); mix(acc, item.level)
  for b in sim.berries:
    mix(acc, b.tileX); mix(acc, b.tileY); mix(acc, b.regrow)
  for c in sim.corpses:
    mix(acc, c.tileX); mix(acc, c.tileY); mix(acc, c.ticksRemaining)
  toHex(acc)
