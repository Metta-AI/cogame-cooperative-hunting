## The eight scripted baselines, restructured from
## `Metta-AI/coworld-staghunt`'s eight `players/*.nim` binaries into one
## module with a dispatch.
##
## Every bot shares the starter's scene parser (sprite_v1 in, camera derived
## from a background tile, self located via the `0x07` identity packet,
## obstacle map rebuilt from visible tile sprites, own energy decoded from
## the HUD digits at y=7) and the starter's navigation
## (`bitworld/pathfinding`'s `pathStep` / `unstickStep` plus the anti-stuck
## ring buffer). Only `decide*` differs per bot, and those bodies are the
## starter's, not retuned in v1.
##
## `big_game_hunter` is the default and the fallback baseline.
##
## The LLM executor in the player binary reuses `findKillSpot`,
## `bestCaptureSide` and `navigate` from here, exactly as the design note
## specifies, so a prompt seat walks with the same feet as a scripted one.

import std/[algorithm, random, strutils]
import bitworld/protocol
import bitworld/pathfinding
import ./sim_types

const
  MaxDrainMessages* = 256
  MaxPlayers = 64
  MaxPreySlots = 256
  MaxItemSlots = 128
  MaxBerrySlots = 64
  MaxIndicatorSlots = 128
  MaxBackgroundIndex = WorldWidthTiles * WorldHeightTiles

  AllyChebyshevRadius = 6
  PreferredReachChebyshev = 12
  FollowDistance = 2
  StillFramesThreshold = 90
  LowEnergyThreshold = 30
  RechargedThreshold = 60
  CommitDistance = 3
  SafeDistance = 4

  BaselineNames* = [
    "rabbiteer", "nearest_hunter", "stag_hunter", "moose_hunter",
    "elephant_hunter", "big_game_hunter", "sidekick", "modeler"
  ]

type
  BaselineKind* = enum
    bkRabbiteer
    bkNearestHunter
    bkStagHunter
    bkMooseHunter
    bkElephantHunter
    bkBigGameHunter
    bkSidekick
    bkModeler

  SpriteKind* = enum
    SpriteUnknown
    SpriteBackground
    SpriteTree
    SpriteRock
    SpritePrey
    SpritePlayer
    SpriteIndicator
    SpriteItem
    SpriteBerry

  SpriteInfo* = object
    defined*: bool
    width*: int
    height*: int
    label*: string
    kind*: SpriteKind
    preyKind*: PreyKind
    colorSlot*: int
    facing*: int

  ObjectState* = object
    present*: bool
    x*: int
    y*: int
    z*: int
    layer*: int
    spriteId*: int

  PlayerSight* = object
    found*: bool
    objectId*: int
    color*: int
    tileX*: int
    tileY*: int

  PreySight* = object
    ## One targetable thing: an animal, an ore node, a food pile or a berry
    ## bush. `needs` is how many distinct hunters it still wants, so one
    ## chooser works across all four variants.
    found*: bool
    objectId*: int
    isAnimal*: bool
    kind*: PreyKind
    itemSprite*: int
    tileX*: int
    tileY*: int

  ColorMemory* = object
    seenCatch*: set[PreyKind]
    attempts*: array[PreyKind, int]
    failures*: array[PreyKind, int]

  PreyMemory* = object
    present*: bool
    kind*: PreyKind
    tileX*: int
    tileY*: int

  TrackedPlayer* = object
    objectId*: int
    lastTileX*: int
    lastTileY*: int
    stillFrames*: int

  Bot* = object
    kind*: BaselineKind
    sprites*: seq[SpriteInfo]
    objects*: seq[ObjectState]
    cameraX*: int
    cameraY*: int
    cameraKnown*: bool
    frameTick*: int
    selfObjectId*: int
    selfTileX*: int
    selfTileY*: int
    selfFound*: bool
    intent*: string
    obstacleMap*: ObstacleMap
    posHistory*: array[4, tuple[x, y: int]]
    posHistoryIdx*: int
    posHistoryCount*: int
    stuckCount*: int
    lastSentNonZero*: bool
    adjacentWaitTicks*: int
    lastAdjacentPreyId*: int
    energy*: int
    energyKnown*: bool
    resting*: bool
    rechargingUntil*: int
    exploreTargetX*: int
    exploreTargetY*: int
    exploreTargetAge*: int
    rng*: Rand
    # sidekick
    priorityList*: seq[TrackedPlayer]
    followTarget*: int
    # modeler
    colorMem*: array[NumPlayerColors, ColorMemory]
    preyMem*: array[MaxPreySlots, PreyMemory]
    lastKillGlowPresent*: array[MaxPlayers, bool]
    curAdjacentPreyObjId*: int
    curAdjacentPreyKind*: PreyKind
    curAdjacentTicks*: int

proc parseBaselineKind*(text: string): BaselineKind =
  ## Anything unrecognised is `big_game_hunter`: it is the default and the
  ## fallback baseline (`PLAYER_FALLBACK_SCRIPTED`).
  case text.strip().toLowerAscii()
  of "rabbiteer": bkRabbiteer
  of "nearest_hunter", "nearest-hunter": bkNearestHunter
  of "stag_hunter", "stag-hunter": bkStagHunter
  of "moose_hunter", "moose-hunter": bkMooseHunter
  of "elephant_hunter", "elephant-hunter": bkElephantHunter
  of "sidekick": bkSidekick
  of "modeler": bkModeler
  else: bkBigGameHunter

proc baselineName*(kind: BaselineKind): string =
  BaselineNames[kind.ord]

# ---------------------------------------------------------------------------
# sprite_v1 parsing
# ---------------------------------------------------------------------------

proc readU16(blob: string, offset: int): int =
  int(uint16(blob[offset].uint8) or (uint16(blob[offset + 1].uint8) shl 8))

proc readI16(blob: string, offset: int): int =
  let value = uint16(blob[offset].uint8) or (uint16(blob[offset + 1].uint8) shl 8)
  int(cast[int16](value))

proc readU32(blob: string, offset: int): int =
  int(uint32(blob[offset].uint8) or
    (uint32(blob[offset + 1].uint8) shl 8) or
    (uint32(blob[offset + 2].uint8) shl 16) or
    (uint32(blob[offset + 3].uint8) shl 24))

proc ensureSprite(bot: var Bot, spriteId: int) =
  if spriteId >= bot.sprites.len:
    bot.sprites.setLen(spriteId + 1)

proc ensureObject(bot: var Bot, objectId: int) =
  if objectId >= bot.objects.len:
    bot.objects.setLen(objectId + 1)

proc classifySprite(spriteId: int): SpriteInfo =
  result.kind = SpriteUnknown
  if spriteId == BackgroundSpriteId:
    result.kind = SpriteBackground
  elif spriteId == TreeSpriteId:
    result.kind = SpriteTree
  elif spriteId == RockSpriteId:
    result.kind = SpriteRock
  elif spriteId >= PreySpriteBase and spriteId < PreySpriteBase + 5:
    result.kind = SpritePrey
    result.preyKind = PreyKind(spriteId - PreySpriteBase)
  elif spriteId >= PlayerSpriteBase and
      spriteId < PlayerSpriteBase + NumPlayerColors * 4:
    let offset = spriteId - PlayerSpriteBase
    result.kind = SpritePlayer
    result.colorSlot = offset div 4
    result.facing = offset mod 4
  elif spriteId >= IndicatorSpriteBase and spriteId < IndicatorSpriteBase + 3:
    result.kind = SpriteIndicator
  elif spriteId in [IronSpriteId, GoldSpriteId, FoodSpriteId]:
    result.kind = SpriteItem
  elif spriteId in [BerryRipeSpriteId, BerryPickedSpriteId]:
    result.kind = SpriteBerry

proc refreshEnergyFromHud(bot: var Bot) =
  ## Decodes self-energy from the HUD digit sprites the server places at
  ## y=7. Browsers render those digits as the visible energy readout; we
  ## re-decode them as an integer, so bots and humans observe the same world
  ## through the same wire protocol -- no custom packet needed.
  const
    EnergyHudY = 7
    DigitSpriteMax = DigitSpriteBase + 9
    DigitStride = DigitSpriteWidth + 1
    DigitStartX = 5
  var
    digits: array[6, int]
    maxIdx = -1
  for obj in bot.objects:
    if not obj.present or obj.y != EnergyHudY:
      continue
    if obj.spriteId < DigitSpriteBase or obj.spriteId > DigitSpriteMax:
      continue
    let idx = (obj.x - DigitStartX) div DigitStride
    if idx < 0 or idx >= digits.len:
      continue
    digits[idx] = obj.spriteId - DigitSpriteBase
    if idx > maxIdx:
      maxIdx = idx
  if maxIdx < 0:
    return
  var value = 0
  for i in 0 .. maxIdx:
    value = value * 10 + digits[i]
  bot.energy = value
  bot.energyKnown = true

proc applySpritePacket*(bot: var Bot, packet: string): bool =
  ## Applies one or more server sprite protocol messages. Unknown message
  ## types make the whole frame invalid, which is exactly why `0x91` plans
  ## are only ever sent to seats that registered a prompt.
  var offset = 0
  while offset < packet.len:
    let messageType = packet[offset].uint8
    inc offset
    case messageType
    of 0x01:
      if offset + 10 > packet.len:
        return false
      let
        spriteId = packet.readU16(offset)
        width = packet.readU16(offset + 2)
        height = packet.readU16(offset + 4)
        compressedLen = packet.readU32(offset + 6)
      offset += 10
      if compressedLen < 0 or offset + compressedLen + 2 > packet.len:
        return false
      offset += compressedLen
      let labelLen = packet.readU16(offset)
      offset += 2
      if offset + labelLen > packet.len:
        return false
      let label =
        if labelLen > 0: packet.substr(offset, offset + labelLen - 1)
        else: ""
      offset += labelLen
      var info = classifySprite(spriteId)
      info.defined = true
      info.width = width
      info.height = height
      info.label = label
      bot.ensureSprite(spriteId)
      bot.sprites[spriteId] = info
    of 0x02:
      if offset + 11 > packet.len:
        return false
      let
        objectId = packet.readU16(offset)
        x = packet.readI16(offset + 2)
        y = packet.readI16(offset + 4)
        z = packet.readI16(offset + 6)
        layer = int(packet[offset + 8].uint8)
        spriteId = packet.readU16(offset + 9)
      offset += 11
      bot.ensureObject(objectId)
      bot.objects[objectId] = ObjectState(
        present: true, x: x, y: y, z: z, layer: layer, spriteId: spriteId
      )
    of 0x03:
      if offset + 2 > packet.len:
        return false
      let objectId = packet.readU16(offset)
      offset += 2
      if objectId >= 0 and objectId < bot.objects.len:
        bot.objects[objectId].present = false
    of 0x04:
      for item in bot.objects.mitems:
        item.present = false
      bot.cameraKnown = false
      bot.selfFound = false
      bot.selfObjectId = -1
    of 0x05:
      if offset + 5 > packet.len:
        return false
      offset += 5
    of 0x06:
      if offset + 3 > packet.len:
        return false
      offset += 3
    of 0x07:
      if offset + 2 > packet.len:
        return false
      bot.selfObjectId = packet.readU16(offset)
      offset += 2
    else:
      return false
  bot.refreshEnergyFromHud()
  true

# ---------------------------------------------------------------------------
# Scene queries
# ---------------------------------------------------------------------------

proc spriteInfo(bot: Bot, spriteId: int): SpriteInfo =
  if spriteId >= 0 and spriteId < bot.sprites.len:
    return bot.sprites[spriteId]
  SpriteInfo()

proc objectPresent(bot: Bot, objectId: int): bool =
  objectId >= 0 and objectId < bot.objects.len and bot.objects[objectId].present

proc deriveCamera(bot: var Bot) =
  ## Derives the world camera offset from any visible background tile: each
  ## grass tile has `objectId = BackgroundObjectBase + ty*32 + tx` and was
  ## drawn at `x = tx*StagTileSize - cameraX`.
  bot.cameraKnown = false
  let scanEnd = min(bot.objects.len, BackgroundObjectBase + MaxBackgroundIndex)
  for objectId in BackgroundObjectBase ..< scanEnd:
    if not bot.objects[objectId].present:
      continue
    let
      index = objectId - BackgroundObjectBase
      tx = index mod WorldWidthTiles
      ty = index div WorldWidthTiles
      obj = bot.objects[objectId]
    bot.cameraX = tx * StagTileSize - obj.x
    bot.cameraY = ty * StagTileSize - obj.y
    bot.cameraKnown = true
    return

proc chebyshev*(ax, ay, bx, by: int): int =
  max(abs(ax - bx), abs(ay - by))

proc manhattan*(ax, ay, bx, by: int): int =
  abs(ax - bx) + abs(ay - by)

proc visiblePlayers*(bot: Bot): seq[PlayerSight] =
  let scanEnd = min(bot.objects.len, PlayerObjectBase + MaxPlayers)
  for objectId in PlayerObjectBase ..< scanEnd:
    if not bot.objects[objectId].present:
      continue
    let obj = bot.objects[objectId]
    let info = bot.spriteInfo(obj.spriteId)
    if info.kind != SpritePlayer:
      continue
    let
      worldX = bot.cameraX + obj.x
      worldY = bot.cameraY + obj.y
    result.add PlayerSight(
      found: true,
      objectId: objectId,
      color: info.colorSlot,
      tileX: worldX div StagTileSize,
      tileY: worldY div StagTileSize
    )

proc visiblePrey*(bot: Bot): seq[PreySight] =
  ## Animals, ore nodes, food piles and ripe berry bushes, in one list, so
  ## one chooser works across all four variants.
  let preyEnd = min(bot.objects.len, PreyObjectBase + MaxPreySlots)
  for objectId in PreyObjectBase ..< preyEnd:
    if not bot.objects[objectId].present:
      continue
    let obj = bot.objects[objectId]
    let info = bot.spriteInfo(obj.spriteId)
    if info.kind != SpritePrey:
      continue
    let
      size = (if info.width > 0: info.width else: StagTileSize)
      centerOffset = (size - StagTileSize) div 2
      worldX = bot.cameraX + obj.x + centerOffset
      worldY = bot.cameraY + obj.y + centerOffset
    result.add PreySight(
      found: true, objectId: objectId, isAnimal: true, kind: info.preyKind,
      tileX: worldX div StagTileSize, tileY: worldY div StagTileSize
    )
  let itemEnd = min(bot.objects.len, ItemObjectBase + MaxItemSlots)
  for objectId in ItemObjectBase ..< itemEnd:
    if not bot.objects[objectId].present:
      continue
    let obj = bot.objects[objectId]
    let info = bot.spriteInfo(obj.spriteId)
    if info.kind != SpriteItem:
      continue
    let
      worldX = bot.cameraX + obj.x
      worldY = bot.cameraY + obj.y
    result.add PreySight(
      found: true, objectId: objectId, isAnimal: false,
      itemSprite: obj.spriteId,
      # Iron behaves like a rabbit (solo) and gold like a stag/boar (a pair);
      # food wants a coalition too. Mapping them onto PreyKind lets every
      # bundled bot's coalition logic work unchanged.
      kind: (if obj.spriteId == IronSpriteId: Rabbit else: Boar),
      tileX: worldX div StagTileSize, tileY: worldY div StagTileSize
    )
  let berryEnd = min(bot.objects.len, BerryObjectBase + MaxBerrySlots)
  for objectId in BerryObjectBase ..< berryEnd:
    if not bot.objects[objectId].present:
      continue
    let obj = bot.objects[objectId]
    if obj.spriteId != BerryRipeSpriteId:
      continue
    let
      worldX = bot.cameraX + obj.x
      worldY = bot.cameraY + obj.y
    result.add PreySight(
      found: true, objectId: objectId, isAnimal: false,
      itemSprite: obj.spriteId, kind: Rabbit,
      tileX: worldX div StagTileSize, tileY: worldY div StagTileSize
    )

proc findSelf(bot: var Bot, players: openArray[PlayerSight]) =
  bot.selfFound = false
  if bot.selfObjectId < 0:
    return
  for player in players:
    if player.objectId == bot.selfObjectId:
      bot.selfTileX = player.tileX
      bot.selfTileY = player.tileY
      bot.selfFound = true
      return

proc updateObstacleMap(bot: var Bot) =
  if not bot.cameraKnown: return
  let scanEnd = min(bot.objects.len, BackgroundObjectBase + MaxBackgroundIndex)
  for objectId in BackgroundObjectBase ..< scanEnd:
    if not bot.objects[objectId].present: continue
    let
      index = objectId - BackgroundObjectBase
      tx = index mod WorldWidthTiles
      ty = index div WorldWidthTiles
    # The background object itself is always grass; a tree or rock rides on
    # the SAME tile index at TileObjectBase, so consult that.
    if bot.objectPresent(TileObjectBase + index):
      let info = bot.spriteInfo(bot.objects[TileObjectBase + index].spriteId)
      if info.kind in {SpriteTree, SpriteRock}:
        bot.obstacleMap.markTile(tx, ty, TileBlocked)
        continue
    bot.obstacleMap.markTile(tx, ty, TileClear)

proc updateStuckState(bot: var Bot, mask: uint8) =
  if not bot.selfFound:
    return
  let lastIdx = (bot.posHistoryIdx + bot.posHistoryCount - 1 + 4) mod 4
  let posChanged = bot.posHistoryCount == 0 or
    bot.selfTileX != bot.posHistory[lastIdx].x or
    bot.selfTileY != bot.posHistory[lastIdx].y
  if posChanged:
    bot.posHistory[bot.posHistoryIdx] = (bot.selfTileX, bot.selfTileY)
    bot.posHistoryIdx = (bot.posHistoryIdx + 1) mod 4
    if bot.posHistoryCount < 4:
      inc bot.posHistoryCount
    bot.stuckCount = 0
  elif mask != 0:
    inc bot.stuckCount
  bot.lastSentNonZero = mask != 0

proc navigate*(bot: var Bot, targetX, targetY: int): uint8 =
  if bot.stuckCount >= 15:
    let mask = unstickStep(bot.obstacleMap, bot.selfTileX, bot.selfTileY,
      bot.frameTick)
    bot.updateStuckState(mask)
    return mask
  let mask = pathStep(bot.obstacleMap, bot.selfTileX, bot.selfTileY,
    targetX, targetY)
  bot.updateStuckState(mask)
  mask

proc navigateAvoiding(
  bot: var Bot, targetX, targetY: int, blocked: seq[tuple[x, y: int]]
): uint8 =
  var saved: seq[tuple[x, y: int, status: TileStatus]] = @[]
  for b in blocked:
    if inBounds(b.x, b.y):
      saved.add((b.x, b.y, bot.obstacleMap.getTile(b.x, b.y)))
      bot.obstacleMap.markTile(b.x, b.y, TileBlocked)
  result = bot.navigate(targetX, targetY)
  for entry in saved:
    bot.obstacleMap.markTile(entry.x, entry.y, entry.status)

proc findKillSpot*(bot: Bot): tuple[x, y: int, found: bool] =
  ## A 1-dot capture indicator within Manhattan 2: stepping there completes
  ## a capture THIS tick. Priority 1 for every baseline and for the LLM
  ## executor.
  const IndicatorTileOffset = (StagTileSize - IndicatorSpriteSize) div 2
  for slot in 0 ..< MaxIndicatorSlots:
    for sideOrd in 0 ..< 4:
      let objectId = IndicatorObjectBase + slot * 4 + sideOrd
      if not bot.objectPresent(objectId): continue
      let obj = bot.objects[objectId]
      let info = bot.spriteInfo(obj.spriteId)
      if not info.defined or info.kind != SpriteIndicator: continue
      if obj.spriteId != IndicatorSpriteBase: continue  # only 1-dot
      let
        worldX = bot.cameraX + obj.x - IndicatorTileOffset
        worldY = bot.cameraY + obj.y - IndicatorTileOffset
        tileX = worldX div StagTileSize
        tileY = worldY div StagTileSize
      if manhattan(bot.selfTileX, bot.selfTileY, tileX, tileY) <= 2:
        return (tileX, tileY, true)
  (0, 0, false)

proc pickExploreTarget(bot: var Bot) =
  bot.exploreTargetX = 2 + bot.rng.rand(WorldWidthTiles - 5)
  bot.exploreTargetY = 2 + bot.rng.rand(WorldHeightTiles - 5)
  bot.exploreTargetAge = 0

# ---------------------------------------------------------------------------
# Shared strategy helpers (staghunt's, unchanged)
# ---------------------------------------------------------------------------

type OccupiedSides* = object
  n*, s*, e*, w*: bool

proc occupiedSidesOf*(
  preyX, preyY: int, players: openArray[PlayerSight]
): OccupiedSides =
  for player in players:
    if player.tileX == preyX and player.tileY == preyY - 1:
      result.n = true
    elif player.tileX == preyX and player.tileY == preyY + 1:
      result.s = true
    elif player.tileX == preyX + 1 and player.tileY == preyY:
      result.e = true
    elif player.tileX == preyX - 1 and player.tileY == preyY:
      result.w = true

proc sideOccupied(sides: OccupiedSides, ord: int): bool =
  case ord
  of 0: sides.n
  of 1: sides.e
  of 2: sides.s
  of 3: sides.w
  else: true

proc cardinallyAdjacent*(ax, ay, bx, by: int): bool =
  let dx = abs(ax - bx)
  let dy = abs(ay - by)
  (dx == 1 and dy == 0) or (dx == 0 and dy == 1)

proc bestCaptureSide*(
  selfX, selfY, preyX, preyY: int,
  kind: PreyKind,
  players: openArray[PlayerSight]
): tuple[x, y: int, found: bool] =
  let sides = occupiedSidesOf(preyX, preyY, players)
  let selfIsN = (selfX == preyX and selfY == preyY - 1)
  let selfIsS = (selfX == preyX and selfY == preyY + 1)
  let selfIsE = (selfX == preyX + 1 and selfY == preyY)
  let selfIsW = (selfX == preyX - 1 and selfY == preyY)
  case kind
  of Stag:
    if sides.n and not sides.s and not selfIsN: return (preyX, preyY + 1, true)
    if sides.s and not sides.n and not selfIsS: return (preyX, preyY - 1, true)
    if sides.e and not sides.w and not selfIsE: return (preyX - 1, preyY, true)
    if sides.w and not sides.e and not selfIsW: return (preyX + 1, preyY, true)
    if selfIsN and not sides.s: return (preyX, preyY + 1, true)
    if selfIsS and not sides.n: return (preyX, preyY - 1, true)
    if selfIsE and not sides.w: return (preyX - 1, preyY, true)
    if selfIsW and not sides.e: return (preyX + 1, preyY, true)
  of Boar:
    if (sides.n or selfIsN) and not sides.e and not selfIsE:
      return (preyX + 1, preyY, true)
    if (sides.n or selfIsN) and not sides.w and not selfIsW:
      return (preyX - 1, preyY, true)
    if (sides.s or selfIsS) and not sides.e and not selfIsE:
      return (preyX + 1, preyY, true)
    if (sides.s or selfIsS) and not sides.w and not selfIsW:
      return (preyX - 1, preyY, true)
    if (sides.e or selfIsE) and not sides.n and not selfIsN:
      return (preyX, preyY - 1, true)
    if (sides.e or selfIsE) and not sides.s and not selfIsS:
      return (preyX, preyY + 1, true)
    if (sides.w or selfIsW) and not sides.n and not selfIsN:
      return (preyX, preyY - 1, true)
    if (sides.w or selfIsW) and not sides.s and not selfIsS:
      return (preyX, preyY + 1, true)
  of Moose, Elephant:
    if not sides.n and not selfIsN: return (preyX, preyY - 1, true)
    if not sides.s and not selfIsS: return (preyX, preyY + 1, true)
    if not sides.e and not selfIsE: return (preyX + 1, preyY, true)
    if not sides.w and not selfIsW: return (preyX - 1, preyY, true)
  of Rabbit:
    discard
  (0, 0, false)

proc rankAmongVisible(
  selfObjectId: int, players: openArray[PlayerSight]
): int =
  ## Number of other visible hunters with a smaller object id: a stable side
  ## assignment so several hunters with the same view land on different
  ## sides without coordinating.
  for pl in players:
    if pl.objectId == selfObjectId: continue
    if pl.objectId < selfObjectId: inc result

proc rankSide(
  preyX, preyY, rank: int,
  sides: OccupiedSides,
  obstacleMap: ObstacleMap
): tuple[x, y: int, found: bool] =
  const offsets = [(0, -1), (1, 0), (0, 1), (-1, 0)]
  let primary = rank mod 4
  for offset in 0 ..< 4:
    let ord = (primary + offset) mod 4
    if sideOccupied(sides, ord): continue
    let
      sx = preyX + offsets[ord][0]
      sy = preyY + offsets[ord][1]
    if not inBounds(sx, sy): continue
    if obstacleMap.getTile(sx, sy) == TileBlocked: continue
    return (sx, sy, true)
  (0, 0, false)

proc nearbyAllyCount(bot: Bot, players: openArray[PlayerSight]): int =
  if not bot.selfFound:
    return 0
  result = 1
  for player in players:
    if player.objectId == bot.selfObjectId:
      continue
    if chebyshev(player.tileX, player.tileY, bot.selfTileX,
        bot.selfTileY) <= AllyChebyshevRadius:
      inc result

proc catchableKinds(nearbyCount: int): set[PreyKind] =
  for kind in PreyKind:
    if preyMinPlayers(kind) <= nearbyCount:
      result.incl(kind)

proc preyReward(kind: PreyKind): int =
  rewardsFor(kind).score

proc allyBlockers(
  bot: Bot, players: openArray[PlayerSight]
): seq[tuple[x, y: int]] =
  for pl in players:
    if pl.objectId != bot.selfObjectId:
      result.add((pl.tileX, pl.tileY))

proc closeOnAllyOrExplore(
  bot: var Bot, players: openArray[PlayerSight]
): uint8 =
  ## The shared "no target in sight" behaviour: close on the nearest ally
  ## when it is far, otherwise patrol, routing around allies so two bots
  ## heading for the same quadrant do not collide and oscillate.
  let blocked = bot.allyBlockers(players)
  var nearestAlly: PlayerSight
  var nearestAllyDist = high(int)
  for pl in players:
    if pl.objectId == bot.selfObjectId: continue
    let d = chebyshev(bot.selfTileX, bot.selfTileY, pl.tileX, pl.tileY)
    if d < nearestAllyDist:
      nearestAllyDist = d
      nearestAlly = pl
  if nearestAlly.found and nearestAllyDist > 3:
    return bot.navigateAvoiding(nearestAlly.tileX, nearestAlly.tileY, blocked)
  inc bot.exploreTargetAge
  let atTarget = bot.selfTileX == bot.exploreTargetX and
    bot.selfTileY == bot.exploreTargetY
  if atTarget or bot.exploreTargetAge > 200 or bot.stuckCount > 30:
    bot.pickExploreTarget()
  bot.navigateAvoiding(bot.exploreTargetX, bot.exploreTargetY, blocked)

proc restGate(bot: var Bot): bool =
  ## Energy rest with hysteresis: in long games movement (2/step) outpaces
  ## passive recharge (+1/18 ticks), so below 30 the bot sits still until it
  ## is back to 60. Without this, long episodes end frozen at 0.
  if bot.energyKnown:
    if bot.energy < LowEnergyThreshold: bot.resting = true
    elif bot.energy >= RechargedThreshold: bot.resting = false
  bot.resting

# ---------------------------------------------------------------------------
# The eight strategies
# ---------------------------------------------------------------------------

proc decideRabbiteer(bot: var Bot, players: seq[PlayerSight]): uint8 =
  let prey = bot.visiblePrey()
  var target = PreySight()
  var bestDist = high(int)
  for p in prey:
    if p.isAnimal and p.kind != Rabbit: continue
    if not p.isAnimal and p.itemSprite notin [IronSpriteId, BerryRipeSpriteId]:
      continue
    let d = manhattan(bot.selfTileX, bot.selfTileY, p.tileX, p.tileY)
    if d < bestDist or (d == bestDist and target.found and
        p.objectId < target.objectId):
      bestDist = d
      target = p
  if not target.found:
    bot.intent = "no rabbit; exploring"
    return bot.navigate(WorldWidthTiles div 2, WorldHeightTiles div 2)
  bot.intent = "rabbit at (" & $target.tileX & "," & $target.tileY & ")"
  if manhattan(bot.selfTileX, bot.selfTileY, target.tileX, target.tileY) == 1:
    bot.updateStuckState(0)
    return 0
  bot.navigate(target.tileX, target.tileY)

proc chooseNearest(
  bot: Bot, prey: seq[PreySight], maxPlayers: int
): PreySight =
  var bestDistance = high(int)
  for p in prey:
    if preyMinPlayers(p.kind) > maxPlayers:
      continue
    let d = chebyshev(bot.selfTileX, bot.selfTileY, p.tileX, p.tileY)
    if d < bestDistance or (d == bestDistance and result.found and
        p.objectId < result.objectId):
      bestDistance = d
      result = p

proc decideNearestHunter(bot: var Bot, players: seq[PlayerSight]): uint8 =
  let prey = bot.visiblePrey()
  let nearby = bot.nearbyAllyCount(players)
  let target = bot.chooseNearest(prey, nearby)
  if not target.found:
    bot.intent = "no catchable prey; exploring"
    return bot.navigate(WorldWidthTiles div 2, WorldHeightTiles div 2)
  let distance = manhattan(bot.selfTileX, bot.selfTileY, target.tileX,
    target.tileY)
  if cardinallyAdjacent(bot.selfTileX, bot.selfTileY, target.tileX,
      target.tileY):
    if bot.lastAdjacentPreyId == target.objectId:
      inc bot.adjacentWaitTicks
    else:
      bot.lastAdjacentPreyId = target.objectId
      bot.adjacentWaitTicks = 1
    if bot.adjacentWaitTicks >= 12 and target.kind != Rabbit:
      let side = bestCaptureSide(bot.selfTileX, bot.selfTileY, target.tileX,
        target.tileY, target.kind, players)
      if side.found:
        bot.intent = "reposition to capture side"
        return bot.navigate(side.x, side.y)
    bot.intent = "hold beside target"
    bot.updateStuckState(0)
    return 0
  bot.adjacentWaitTicks = 0
  bot.lastAdjacentPreyId = -1
  if target.kind != Rabbit and distance <= 3:
    let side = bestCaptureSide(bot.selfTileX, bot.selfTileY, target.tileX,
      target.tileY, target.kind, players)
    if side.found:
      bot.intent = "approach capture side"
      return bot.navigate(side.x, side.y)
  bot.intent = "approach nearest"
  bot.navigate(target.tileX, target.tileY)

proc chooseByKind(
  bot: Bot, prey: seq[PreySight], want: PreyKind,
  players: seq[PlayerSight], required: int
): PreySight =
  ## The shared stag/moose/elephant chooser: pick the one whose FARTHEST
  ## visible hunter is closest, so every hunter with the same view converges
  ## on the same target, with a cooperation bonus for allies already there.
  var bestCost = high(int)
  for p in prey:
    if p.kind != want: continue
    var maxHunterDist = chebyshev(bot.selfTileX, bot.selfTileY, p.tileX, p.tileY)
    var alliesAdjacent = 0
    for pl in players:
      if pl.objectId == bot.selfObjectId: continue
      let d = chebyshev(pl.tileX, pl.tileY, p.tileX, p.tileY)
      if d > maxHunterDist: maxHunterDist = d
      if d == 1: inc alliesAdjacent
    if alliesAdjacent >= required:
      continue
    let cost = maxHunterDist - 3 * alliesAdjacent
    if cost < bestCost or (cost == bestCost and result.found and
        p.objectId < result.objectId):
      bestCost = cost
      result = p

proc decideStagHunter(bot: var Bot, players: seq[PlayerSight]): uint8 =
  let prey = bot.visiblePrey()
  # Distribute hunters across stags: a stag with two allies already adjacent
  # is being captured by them, so look elsewhere; one ally adjacent is a
  # cooperation bonus; allies closer than us are a crowding penalty.
  var stag = PreySight()
  var bestCost = high(int)
  for p in prey:
    if p.kind != Stag: continue
    let myDist = chebyshev(bot.selfTileX, bot.selfTileY, p.tileX, p.tileY)
    var alliesCloser = 0
    var alliesAdjacent = 0
    for pl in players:
      if pl.objectId == bot.selfObjectId: continue
      let allyDist = chebyshev(pl.tileX, pl.tileY, p.tileX, p.tileY)
      if allyDist < myDist: inc alliesCloser
      if allyDist == 1: inc alliesAdjacent
    if alliesAdjacent >= 2: continue
    let
      cooperationBonus = (if alliesAdjacent == 1: -8 else: 0)
      crowdingPenalty = max(0, alliesCloser - 1) * 6
      cost = myDist + crowdingPenalty + cooperationBonus
    if cost < bestCost or (cost == bestCost and stag.found and
        p.objectId < stag.objectId):
      bestCost = cost
      stag = p
  if not stag.found:
    bot.intent = "no stag; regrouping"
    bot.adjacentWaitTicks = 0
    bot.lastAdjacentPreyId = -1
    return bot.closeOnAllyOrExplore(players)

  bot.intent = "stag at (" & $stag.tileX & "," & $stag.tileY & ")"
  if cardinallyAdjacent(bot.selfTileX, bot.selfTileY, stag.tileX, stag.tileY):
    if bot.lastAdjacentPreyId == stag.objectId:
      inc bot.adjacentWaitTicks
    else:
      bot.lastAdjacentPreyId = stag.objectId
      bot.adjacentWaitTicks = 1
    let sides = occupiedSidesOf(stag.tileX, stag.tileY, players)
    let
      selfIsN = bot.selfTileX == stag.tileX and bot.selfTileY == stag.tileY - 1
      selfIsS = bot.selfTileX == stag.tileX and bot.selfTileY == stag.tileY + 1
      selfIsE = bot.selfTileX == stag.tileX + 1 and bot.selfTileY == stag.tileY
      selfIsW = bot.selfTileX == stag.tileX - 1 and bot.selfTileY == stag.tileY
      partneredOpposite =
        (selfIsN and sides.s) or (selfIsS and sides.n) or
        (selfIsE and sides.w) or (selfIsW and sides.e)
    if partneredOpposite:
      bot.updateStuckState(0)
      return 0
    if bot.adjacentWaitTicks >= 18:
      let side = bestCaptureSide(bot.selfTileX, bot.selfTileY, stag.tileX,
        stag.tileY, Stag, players)
      if side.found and not (bot.selfTileX == side.x and
          bot.selfTileY == side.y):
        return bot.navigate(side.x, side.y)
    bot.updateStuckState(0)
    return 0
  bot.adjacentWaitTicks = 0
  bot.lastAdjacentPreyId = -1
  let side = bestCaptureSide(bot.selfTileX, bot.selfTileY, stag.tileX,
    stag.tileY, Stag, players)
  if side.found:
    return bot.navigate(side.x, side.y)
  bot.navigate(stag.tileX, stag.tileY)

proc decideBigGameLike(
  bot: var Bot, players: seq[PlayerSight], want: PreyKind, required: int
): uint8 =
  ## The moose_hunter / elephant_hunter shape: hold any adjacency you have,
  ## otherwise claim a rank-assigned side and wait for the rest of the ring.
  let prey = bot.visiblePrey()
  for p in prey:
    if p.kind != want: continue
    if cardinallyAdjacent(bot.selfTileX, bot.selfTileY, p.tileX, p.tileY):
      bot.intent = "holding a side of the " & preyLabel(want)
      if bot.lastAdjacentPreyId == p.objectId:
        inc bot.adjacentWaitTicks
      else:
        bot.lastAdjacentPreyId = p.objectId
        bot.adjacentWaitTicks = 1
      bot.updateStuckState(0)
      return 0
  let target = bot.chooseByKind(prey, want, players, required)
  if not target.found:
    bot.intent = "no " & preyLabel(want) & "; regrouping"
    bot.adjacentWaitTicks = 0
    bot.lastAdjacentPreyId = -1
    return bot.closeOnAllyOrExplore(players)
  bot.adjacentWaitTicks = 0
  bot.lastAdjacentPreyId = -1
  let
    blocked = bot.allyBlockers(players)
    sides = occupiedSidesOf(target.tileX, target.tileY, players)
    rank = rankAmongVisible(bot.selfObjectId, players)
    side = rankSide(target.tileX, target.tileY, rank, sides, bot.obstacleMap)
  bot.intent = "claiming a side of the " & preyLabel(want)
  if side.found:
    return bot.navigateAvoiding(side.x, side.y, blocked)
  bot.navigateAvoiding(target.tileX, target.tileY, blocked)

proc decideElephantHunter(bot: var Bot, players: seq[PlayerSight]): uint8 =
  ## Elephants need ALL FOUR sides at once, so this bot pre-positions on the
  ## DIAGONAL corner (which a cardinal-only elephant cannot step onto) and
  ## commits only when three allies are also in position.
  let prey = bot.visiblePrey()
  let elephant = bot.chooseByKind(prey, Elephant, players, 4)
  if not elephant.found:
    bot.intent = "no elephant; regrouping"
    return bot.closeOnAllyOrExplore(players)
  let
    rank = rankAmongVisible(bot.selfObjectId, players)
    myDist = chebyshev(bot.selfTileX, bot.selfTileY, elephant.tileX,
      elephant.tileY)
  const cornerFor = [(0, -1, 1, -1), (1, 0, 1, 1), (0, 1, -1, 1),
                     (-1, 0, -1, -1)]
  let assignment = cornerFor[rank mod 4]
  var alliesInPosition = 0
  for pl in players:
    if pl.objectId == bot.selfObjectId: continue
    if chebyshev(pl.tileX, pl.tileY, elephant.tileX, elephant.tileY) <= 2:
      inc alliesInPosition
  let blocked = bot.allyBlockers(players)
  if alliesInPosition >= 3 and myDist <= 2:
    var targetX = elephant.tileX + assignment[0]
    var targetY = elephant.tileY + assignment[1]
    var taken = false
    for pl in players:
      if pl.tileX == targetX and pl.tileY == targetY:
        taken = true
        break
    if taken:
      let sides = occupiedSidesOf(elephant.tileX, elephant.tileY, players)
      let alt = rankSide(elephant.tileX, elephant.tileY, rank, sides,
        bot.obstacleMap)
      if alt.found:
        targetX = alt.x
        targetY = alt.y
    bot.intent = "committing to the elephant ring"
    if bot.selfTileX == targetX and bot.selfTileY == targetY:
      bot.updateStuckState(0)
      return 0
    return bot.navigateAvoiding(targetX, targetY, blocked)
  let
    cornerX = elephant.tileX + assignment[2]
    cornerY = elephant.tileY + assignment[3]
  bot.intent = "waiting at the elephant corner"
  if bot.selfTileX == cornerX and bot.selfTileY == cornerY:
    bot.updateStuckState(0)
    return 0
  var transitBlocked = blocked
  transitBlocked.add((elephant.tileX, elephant.tileY - 1))
  transitBlocked.add((elephant.tileX + 1, elephant.tileY))
  transitBlocked.add((elephant.tileX, elephant.tileY + 1))
  transitBlocked.add((elephant.tileX - 1, elephant.tileY))
  bot.navigateAvoiding(cornerX, cornerY, transitBlocked)

proc chooseBigGame(bot: Bot, prey: seq[PreySight], kinds: set[PreyKind]): PreySight =
  ## Highest reward within reasonable reach, ties by distance; otherwise the
  ## nearest catchable thing of any kind.
  var
    nearbyBest = PreySight()
    nearbyBestReward = -1
    nearbyBestDist = high(int)
    fallbackBest = PreySight()
    fallbackBestDist = high(int)
  for p in prey:
    if p.kind notin kinds:
      continue
    let d = chebyshev(p.tileX, p.tileY, bot.selfTileX, bot.selfTileY)
    if d < fallbackBestDist or (d == fallbackBestDist and
        preyReward(p.kind) > preyReward(fallbackBest.kind)):
      fallbackBest = p
      fallbackBestDist = d
    if d <= PreferredReachChebyshev:
      let reward = preyReward(p.kind)
      if reward > nearbyBestReward or
          (reward == nearbyBestReward and d < nearbyBestDist):
        nearbyBest = p
        nearbyBestReward = reward
        nearbyBestDist = d
  if nearbyBest.found:
    return nearbyBest
  fallbackBest

proc decideBigGameHunter(bot: var Bot, players: seq[PlayerSight]): uint8 =
  let
    prey = bot.visiblePrey()
    nearby = bot.nearbyAllyCount(players)
    kinds = catchableKinds(nearby)
    target = bot.chooseBigGame(prey, kinds)
  if not target.found:
    bot.intent = "no catchable prey (allies=" & $nearby & ") exploring"
    return bot.navigate(WorldWidthTiles div 2, WorldHeightTiles div 2)
  if cardinallyAdjacent(bot.selfTileX, bot.selfTileY, target.tileX,
      target.tileY):
    if bot.lastAdjacentPreyId == target.objectId:
      inc bot.adjacentWaitTicks
    else:
      bot.lastAdjacentPreyId = target.objectId
      bot.adjacentWaitTicks = 1
    if bot.adjacentWaitTicks >= 12 and target.kind != Rabbit:
      let side = bestCaptureSide(bot.selfTileX, bot.selfTileY, target.tileX,
        target.tileY, target.kind, players)
      if side.found:
        bot.intent = "reposition->capture " & preyLabel(target.kind)
        return bot.navigate(side.x, side.y)
    bot.intent = "hold beside " & preyLabel(target.kind) & " allies=" & $nearby
    bot.updateStuckState(0)
    return 0
  bot.adjacentWaitTicks = 0
  bot.lastAdjacentPreyId = -1
  let dist = manhattan(bot.selfTileX, bot.selfTileY, target.tileX, target.tileY)
  if target.kind != Rabbit and dist <= 4:
    let side = bestCaptureSide(bot.selfTileX, bot.selfTileY, target.tileX,
      target.tileY, target.kind, players)
    if side.found:
      bot.intent = "approach->capture " & preyLabel(target.kind)
      return bot.navigate(side.x, side.y)
  bot.intent = "approach " & preyLabel(target.kind) & " allies=" & $nearby
  bot.navigate(target.tileX, target.tileY)

proc findTrackedIndex(bot: Bot, objectId: int): int =
  for i, tracked in bot.priorityList:
    if tracked.objectId == objectId:
      return i
  -1

proc updatePriorityList(bot: var Bot, players: seq[PlayerSight]) =
  for p in players:
    if p.objectId == bot.selfObjectId:
      continue
    let idx = bot.findTrackedIndex(p.objectId)
    if idx < 0:
      bot.priorityList.add(TrackedPlayer(
        objectId: p.objectId, lastTileX: p.tileX, lastTileY: p.tileY,
        stillFrames: 0
      ))
    elif bot.priorityList[idx].lastTileX != p.tileX or
        bot.priorityList[idx].lastTileY != p.tileY:
      bot.priorityList[idx].lastTileX = p.tileX
      bot.priorityList[idx].lastTileY = p.tileY
      bot.priorityList[idx].stillFrames = 0
    else:
      inc bot.priorityList[idx].stillFrames
  var i = 0
  while i < bot.priorityList.len:
    if bot.priorityList[i].stillFrames >= StillFramesThreshold:
      var demoted = bot.priorityList[i]
      demoted.stillFrames = 0
      bot.priorityList.delete(i)
      bot.priorityList.add(demoted)
      if bot.followTarget == demoted.objectId:
        bot.followTarget = -1
    else:
      inc i

proc bestFollowTarget(bot: var Bot, players: seq[PlayerSight]): PlayerSight =
  for tracked in bot.priorityList:
    if tracked.objectId == bot.selfObjectId:
      continue
    for p in players:
      if p.objectId == tracked.objectId:
        bot.followTarget = p.objectId
        return p
  bot.followTarget = -1
  PlayerSight()

proc preyRank(kind: PreyKind): int =
  case kind
  of Elephant: 5
  of Moose: 4
  of Stag: 3
  of Boar: 2
  of Rabbit: 1

proc bestFlankSide(
  preyX, preyY: int, kind: PreyKind, allyX, allyY: int
): tuple[x, y: int, found: bool] =
  let
    allyIsN = allyX == preyX and allyY == preyY - 1
    allyIsS = allyX == preyX and allyY == preyY + 1
    allyIsE = allyX == preyX + 1 and allyY == preyY
    allyIsW = allyX == preyX - 1 and allyY == preyY
  case kind
  of Stag:
    if allyIsN: return (preyX, preyY + 1, true)
    if allyIsS: return (preyX, preyY - 1, true)
    if allyIsE: return (preyX - 1, preyY, true)
    if allyIsW: return (preyX + 1, preyY, true)
  of Boar:
    if allyIsN: return (preyX + 1, preyY, true)
    if allyIsS: return (preyX - 1, preyY, true)
    if allyIsE: return (preyX, preyY + 1, true)
    if allyIsW: return (preyX, preyY - 1, true)
  of Moose, Elephant:
    if not allyIsS: return (preyX, preyY + 1, true)
    if not allyIsN: return (preyX, preyY - 1, true)
    if not allyIsE: return (preyX + 1, preyY, true)
    if not allyIsW: return (preyX - 1, preyY, true)
  of Rabbit:
    discard
  (0, 0, false)

proc decideSidekick(bot: var Bot, players: seq[PlayerSight]): uint8 =
  bot.updatePriorityList(players)
  let ally = bot.bestFollowTarget(players)
  if not ally.found:
    bot.intent = "nobody to follow; heading for the middle"
    return bot.navigate(WorldWidthTiles div 2, WorldHeightTiles div 2)
  let prey = bot.visiblePrey()
  var allyPrey = PreySight()
  var bestRank = 0
  for p in prey:
    if cardinallyAdjacent(ally.tileX, ally.tileY, p.tileX, p.tileY):
      let rank = preyRank(p.kind)
      if rank > bestRank or (rank == bestRank and allyPrey.found and
          p.objectId < allyPrey.objectId):
        bestRank = rank
        allyPrey = p
  if allyPrey.found:
    let flank = bestFlankSide(allyPrey.tileX, allyPrey.tileY, allyPrey.kind,
      ally.tileX, ally.tileY)
    if flank.found:
      bot.intent = "flanking the " & preyLabel(allyPrey.kind)
      if bot.selfTileX == flank.x and bot.selfTileY == flank.y:
        bot.updateStuckState(0)
        return 0
      return bot.navigate(flank.x, flank.y)

  # Pre-position: the ally is approaching a multi-hunter target. Do not try
  # to predict which side it will pick -- claim the nearest free side and let
  # the ally's own side logic take the complement.
  var approaching = PreySight()
  bestRank = 0
  for p in prey:
    if p.kind == Rabbit: continue
    let d = manhattan(ally.tileX, ally.tileY, p.tileX, p.tileY)
    if d < 1 or d > 2: continue
    let rank = preyRank(p.kind)
    if rank > bestRank or (rank == bestRank and approaching.found and
        p.objectId < approaching.objectId):
      bestRank = rank
      approaching = p
  if approaching.found:
    const offsets = [(0, -1), (0, 1), (-1, 0), (1, 0)]
    var bestDx = 0
    var bestDy = 0
    var bestDist = high(int)
    var found = false
    for off in offsets:
      let
        sx = approaching.tileX + off[0]
        sy = approaching.tileY + off[1]
      if not inBounds(sx, sy): continue
      if bot.obstacleMap.getTile(sx, sy) == TileBlocked: continue
      var taken = false
      for p in players:
        if p.tileX == sx and p.tileY == sy:
          taken = true
          break
      if taken: continue
      let d = manhattan(bot.selfTileX, bot.selfTileY, sx, sy)
      if d < bestDist:
        bestDist = d
        bestDx = off[0]
        bestDy = off[1]
        found = true
    if found:
      let
        targetX = approaching.tileX + bestDx
        targetY = approaching.tileY + bestDy
      if not (bot.selfTileX == targetX and bot.selfTileY == targetY):
        bot.intent = "pre-positioning beside the ally's target"
        return bot.navigate(targetX, targetY)

  bot.intent = "following an ally"
  if manhattan(bot.selfTileX, bot.selfTileY, ally.tileX,
      ally.tileY) <= FollowDistance:
    bot.updateStuckState(0)
    return 0
  bot.navigate(ally.tileX, ally.tileY)

proc allyTrust(mem: ColorMemory, kind: PreyKind): float =
  ## Optimistic at 0.5 for an unseen pair, ~1.0 after one observed success,
  ## decaying toward 0 after several failed adjacency attempts.
  if kind in mem.seenCatch:
    return 1.0
  let
    fails = mem.failures[kind]
    attempts = mem.attempts[kind]
  if attempts == 0:
    return 0.5
  if fails >= 5:
    return 0.05
  max(0.1, 0.5 - 0.08 * float(fails))

proc detectCaptures(bot: var Bot, prey: seq[PreySight]) =
  ## The rising edge of a kill glow at a hunter's tile means that hunter
  ## just participated in a capture; the kind is inferred from a prey we had
  ## in memory last frame that is now gone from within one tile.
  var currentGlow: array[MaxPlayers, bool]
  for i in 0 ..< MaxPlayers:
    let glowObj = KillGlowObjectBase + i
    if bot.objectPresent(glowObj) and
        bot.objects[glowObj].spriteId == KillGlowSpriteId:
      currentGlow[i] = true
  var presentNow: array[MaxPreySlots, bool]
  for p in prey:
    let idx = p.objectId - PreyObjectBase
    if idx >= 0 and idx < MaxPreySlots: presentNow[idx] = true
  for i in 0 ..< MaxPlayers:
    if not currentGlow[i] or bot.lastKillGlowPresent[i]:
      continue
    let playerObj = PlayerObjectBase + i
    if not bot.objectPresent(playerObj): continue
    let pState = bot.objects[playerObj]
    let info = bot.spriteInfo(pState.spriteId)
    if info.kind != SpritePlayer: continue
    let
      colorSlot = info.colorSlot
      tileX = (bot.cameraX + pState.x) div StagTileSize
      tileY = (bot.cameraY + pState.y) div StagTileSize
    var caughtKind: PreyKind
    var found = false
    for idx in 0 ..< MaxPreySlots:
      if not bot.preyMem[idx].present: continue
      if presentNow[idx]: continue
      if abs(bot.preyMem[idx].tileX - tileX) <= 1 and
          abs(bot.preyMem[idx].tileY - tileY) <= 1:
        caughtKind = bot.preyMem[idx].kind
        found = true
        break
    if found and colorSlot >= 0 and colorSlot < NumPlayerColors:
      bot.colorMem[colorSlot].seenCatch.incl(caughtKind)
  for idx in 0 ..< MaxPreySlots:
    bot.preyMem[idx].present = false
  for p in prey:
    let idx = p.objectId - PreyObjectBase
    if idx >= 0 and idx < MaxPreySlots:
      bot.preyMem[idx] = PreyMemory(
        present: true, kind: p.kind, tileX: p.tileX, tileY: p.tileY
      )
  for i in 0 ..< MaxPlayers:
    bot.lastKillGlowPresent[i] = currentGlow[i]

proc updateAttempts(bot: var Bot, prey: seq[PreySight], players: seq[PlayerSight]) =
  var stillAdjacent = -1
  var adjKind = Rabbit
  for p in prey:
    if cardinallyAdjacent(bot.selfTileX, bot.selfTileY, p.tileX, p.tileY):
      stillAdjacent = p.objectId
      adjKind = p.kind
      break
  if stillAdjacent < 0:
    if bot.curAdjacentPreyObjId >= 0 and bot.curAdjacentTicks >= 10:
      let idx = bot.curAdjacentPreyObjId - PreyObjectBase
      let escaped = idx >= 0 and idx < MaxPreySlots and bot.preyMem[idx].present
      if escaped:
        for pl in players:
          if pl.objectId == bot.selfObjectId: continue
          if chebyshev(pl.tileX, pl.tileY, bot.preyMem[idx].tileX,
              bot.preyMem[idx].tileY) <= 2 and
              pl.color >= 0 and pl.color < NumPlayerColors:
            inc bot.colorMem[pl.color].failures[bot.curAdjacentPreyKind]
    bot.curAdjacentPreyObjId = -1
    bot.curAdjacentTicks = 0
  else:
    if bot.curAdjacentPreyObjId == stillAdjacent:
      inc bot.curAdjacentTicks
    else:
      bot.curAdjacentPreyObjId = stillAdjacent
      bot.curAdjacentPreyKind = adjKind
      bot.curAdjacentTicks = 1
    for pl in players:
      if pl.objectId == bot.selfObjectId: continue
      if manhattan(pl.tileX, pl.tileY, bot.selfTileX, bot.selfTileY) <= 3 and
          pl.color >= 0 and pl.color < NumPlayerColors and
          bot.frameTick mod 6 == 0:
        inc bot.colorMem[pl.color].attempts[bot.curAdjacentPreyKind]

proc decideModeler(bot: var Bot, players: seq[PlayerSight]): uint8 =
  let prey = bot.visiblePrey()
  bot.detectCaptures(prey)
  bot.updateAttempts(prey, players)

  for p in prey:
    if not cardinallyAdjacent(bot.selfTileX, bot.selfTileY, p.tileX, p.tileY):
      continue
    let required = preyMinPlayers(p.kind)
    if required == 1:
      bot.intent = "holding a solo capture"
      bot.updateStuckState(0)
      return 0
    var qualifiedAllies = 0
    for pl in players:
      if pl.objectId == bot.selfObjectId: continue
      if pl.color < 0 or pl.color >= NumPlayerColors: continue
      if chebyshev(pl.tileX, pl.tileY, p.tileX, p.tileY) <= 4 and
          allyTrust(bot.colorMem[pl.color], p.kind) >= 0.4:
        inc qualifiedAllies
    if 1 + qualifiedAllies >= required:
      bot.intent = "holding, trusted allies are in range"
      bot.updateStuckState(0)
      return 0

  var best = PreySight()
  var bestScore = -1.0
  for p in prey:
    let required = preyMinPlayers(p.kind)
    var trusts: seq[float] = @[]
    for pl in players:
      if pl.objectId == bot.selfObjectId: continue
      if chebyshev(pl.tileX, pl.tileY, p.tileX, p.tileY) <= 6 and
          pl.color >= 0 and pl.color < NumPlayerColors:
        trusts.add(allyTrust(bot.colorMem[pl.color], p.kind))
    if 1 + trusts.len < required:
      continue
    trusts.sort(SortOrder.Descending)
    var cooperationProb = 1.0
    for k in 0 ..< (required - 1):
      cooperationProb *= trusts[k]
    let
      myDist = chebyshev(bot.selfTileX, bot.selfTileY, p.tileX, p.tileY)
      distancePenalty = 1.0 / float(myDist + 2)
      score = float(preyReward(p.kind)) * cooperationProb * distancePenalty
    if score > bestScore:
      bestScore = score
      best = p
  if not best.found:
    bot.intent = "nothing worth hunting; clustering"
    return bot.closeOnAllyOrExplore(players)
  bot.intent = "expected value pick: " & preyLabel(best.kind)
  let side = bestCaptureSide(bot.selfTileX, bot.selfTileY, best.tileX,
    best.tileY, best.kind, players)
  if side.found:
    return bot.navigate(side.x, side.y)
  bot.navigate(best.tileX, best.tileY)

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

proc initBot*(kind: BaselineKind, seed = 0): Bot =
  result.kind = kind
  result.selfObjectId = -1
  result.lastAdjacentPreyId = -1
  result.curAdjacentPreyObjId = -1
  result.followTarget = -1
  result.rng = initRand(seed + 1 + kind.ord)
  result.exploreTargetX = WorldWidthTiles div 2
  result.exploreTargetY = WorldHeightTiles div 2

proc decideMask*(bot: var Bot): uint8 =
  ## The one dispatch over the eight bots. Emits at most ONE direction bit
  ## and never a bit the protocol does not define.
  bot.deriveCamera()
  if not bot.cameraKnown:
    bot.intent = "no camera"
    return 0
  let players = bot.visiblePlayers()
  bot.findSelf(players)
  if not bot.selfFound:
    bot.intent = "no self"
    return 0
  bot.updateObstacleMap()

  # Priority 1, shared by every bot: a 1-dot indicator within reach is a
  # capture THIS tick.
  let killSpot = bot.findKillSpot()
  if killSpot.found:
    bot.intent = "kill spot at (" & $killSpot.x & "," & $killSpot.y & ")"
    if bot.selfTileX == killSpot.x and bot.selfTileY == killSpot.y:
      bot.updateStuckState(0)
      return 0
    return bot.navigate(killSpot.x, killSpot.y)

  if bot.restGate():
    bot.intent = "resting (energy " & $bot.energy & ")"
    bot.updateStuckState(0)
    return 0

  result =
    case bot.kind
    of bkRabbiteer: bot.decideRabbiteer(players)
    of bkNearestHunter: bot.decideNearestHunter(players)
    of bkStagHunter: bot.decideStagHunter(players)
    of bkMooseHunter: bot.decideBigGameLike(players, Moose, 3)
    of bkElephantHunter: bot.decideElephantHunter(players)
    of bkBigGameHunter: bot.decideBigGameHunter(players)
    of bkSidekick: bot.decideSidekick(players)
    of bkModeler: bot.decideModeler(players)

  # Bounded orders: at most one direction bit, never an undefined bit. The
  # sim reads direction bits with priority up > down > left > right, so a
  # mask with two set would be a silent, untestable ambiguity.
  const directions = [ButtonUp, ButtonDown, ButtonLeft, ButtonRight]
  var firstDirection = 0'u8
  for bit in directions:
    if (result and bit) != 0:
      firstDirection = bit
      break
  result = firstDirection
