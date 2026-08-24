## Frame builders: the per-seat sprite_v1 frame, the world-scale global frame
## and the broadcast chrome label.
##
## Forked from `Metta-AI/coworld-staghunt` `src/staghunt.nim`
## (`buildPlayerFrame` / `buildGlobalFrame` and their object emitters) and
## extended with the four variants' furniture (ore nodes and their countdown
## rings, berry bushes, tall grass, level badges over heads) plus the chrome
## label on sprite 4090 that paintbot's `broadcast_core.js` routes to onText.
##
## Pure apart from what art.nim already loaded: the wasm replay module calls
## exactly these functions, so the hosted replay is drawn by the same code the
## live server uses.

import std/[json, strutils]
import ./sim_types
import ./sim
import ./art

const
  ItemIndicatorSlotBase* = 64
  ## Baselines scan indicator object ids for `preyIdx` in 0 ..< this bound,
  ## which covers both the animal block (0..63) and the item block (64..127).
  IndicatorScanSlots* = 128

type
  ChromeSeat* = object
    slot*: int
    alias*: string
    name*: string
    kind*: string
    color*: int
    score*: int
    energy*: int
    level*: int
    role*: string
    dc*: bool

  ChromeFeedLine* = object
    tick*: int
    kind*: string
    text*: string

  ChromeBeat* = object
    tick*: int
    kind*: string

# ---------------------------------------------------------------------------
# Terrain, furniture and actors
# ---------------------------------------------------------------------------

proc addTerrainObjects(
  packet: var seq[uint8],
  sim: SimServer,
  cameraX, cameraY, viewportWidth, viewportHeight: int
) =
  let
    startTx = max(0, cameraX div StagTileSize)
    startTy = max(0, cameraY div StagTileSize)
    endTx = min(WorldWidthTiles - 1,
      (cameraX + viewportWidth - 1) div StagTileSize)
    endTy = min(WorldHeightTiles - 1,
      (cameraY + viewportHeight - 1) div StagTileSize)
  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      let
        index = tileIndex(tx, ty)
        kind = sim.tiles[index]
        screenX = tx * StagTileSize - cameraX
        screenY = ty * StagTileSize - cameraY
      packet.addObject(
        BackgroundObjectBase + index,
        screenX, screenY, TerrainZ,
        MapLayerId, BackgroundSpriteId
      )
      if sim.isTallGrass(tx, ty):
        packet.addObject(
          GrassObjectBase + index,
          screenX, screenY, screenY + 1,
          MapLayerId, TallGrassSpriteId
        )
      let spriteId =
        case kind
        of TileTree: TreeSpriteId
        of TileRock: RockSpriteId
        of TileEmpty: 0
      if spriteId == 0:
        continue
      packet.addObject(
        TileObjectBase + index,
        screenX, screenY, screenY + 1,
        MapLayerId, spriteId
      )

proc addPreyObjects(
  packet: var seq[uint8],
  sim: SimServer,
  cameraX, cameraY, viewportWidth, viewportHeight: int
) =
  for i in 0 ..< sim.prey.len:
    let
      prey = sim.prey[i]
      size = preySpriteSize(prey.kind)
    var screenX: int
    var screenY: int
    if prey.kind == Moose:
      screenX = prey.tileX * StagTileSize - cameraX
      screenY = prey.tileY * StagTileSize - cameraY - (size - StagTileSize)
    else:
      let centerOffset = -((size - StagTileSize) div 2)
      screenX = prey.tileX * StagTileSize - cameraX + centerOffset
      screenY = prey.tileY * StagTileSize - cameraY + centerOffset
    if prey.kind == Rabbit:
      if prey.alertFlash == 0:
        let phase = ((sim.globalTick + i * 7) shr 4) and 1
        if phase == 1:
          screenY -= 1
    if prey.alertFlash > 0:
      if (prey.alertFlash and 1) == 1:
        screenX += 1
      else:
        screenX -= 1
    var preyZ = screenY + 2
    if prey.kind == Elephant and prey.trampleStep > 0:
      let progress = TrampleAnimSteps - prey.trampleStep + 1
      let pixelOffset =
        (progress * 2 * StagTileSize) div (TrampleAnimSteps + 1)
      screenX += prey.trampleDx * pixelOffset
      screenY += prey.trampleDy * pixelOffset
      preyZ = screenY + 200
    if prey.kind == Moose and prey.gutStep > 0:
      let progress = MooseGutAnimSteps - prey.gutStep + 1
      let halfWay = (MooseGutAnimSteps + 1) div 2
      let triangleNum =
        if progress <= halfWay: progress
        else: (MooseGutAnimSteps + 1) - progress
      let pixelOffset = (triangleNum * (StagTileSize div 2)) div halfWay
      screenX += prey.gutDx * pixelOffset
      screenY += prey.gutDy * pixelOffset
      preyZ = screenY + 200
    if screenX + size <= 0 or screenY + size <= 0:
      continue
    if screenX >= viewportWidth or screenY >= viewportHeight:
      continue
    packet.addObject(
      PreyObjectBase + i,
      screenX, screenY, preyZ,
      MapLayerId, preySpriteId(prey.kind)
    )

proc addItemObjects(
  packet: var seq[uint8],
  sim: SimServer,
  cameraX, cameraY, viewportWidth, viewportHeight: int
) =
  for i in 0 ..< sim.items.len:
    let item = sim.items[i]
    let
      screenX = item.tileX * StagTileSize - cameraX
      screenY = item.tileY * StagTileSize - cameraY
    if screenX + StagTileSize <= 0 or screenY + StagTileSize <= 0:
      continue
    if screenX >= viewportWidth or screenY >= viewportHeight:
      continue
    let spriteId =
      case item.kind
      of itIron: IronSpriteId
      of itGold: GoldSpriteId
      of itFood: BerryRipeSpriteId
    packet.addObject(
      ItemObjectBase + i,
      screenX, screenY, screenY + 2,
      MapLayerId, spriteId
    )
    # The countdown ring: a gold node with at least one side inside the
    # window but not yet enough hunters is the whole coop-mining mechanic,
    # so it gets its own art rather than an invisible timer.
    if item.kind == itGold:
      let sides = sim.occupiedSides(item.sideSeen)
      let taken = sideCountOf(sides)
      if taken == 1:
        const ringOffset = -((KillGlowSpriteSize - StagTileSize) div 2)
        packet.addObject(
          RingObjectBase + i,
          screenX + ringOffset, screenY + ringOffset, screenY + 3,
          MapLayerId, CountdownRingSpriteId
        )
    # The lbf food level badge, drawn over the item the same way it is drawn
    # over a hunter's head.
    if item.kind == itFood:
      packet.addObject(
        ItemObjectBase + 500 + i,
        screenX + 4, screenY - 8, screenY + 4,
        MapLayerId, LevelBadgeBase + (item.level mod 10)
      )

proc addBerryObjects(
  packet: var seq[uint8],
  sim: SimServer,
  cameraX, cameraY, viewportWidth, viewportHeight: int
) =
  for i in 0 ..< sim.berries.len:
    let
      screenX = sim.berries[i].tileX * StagTileSize - cameraX
      screenY = sim.berries[i].tileY * StagTileSize - cameraY
    if screenX + StagTileSize <= 0 or screenY + StagTileSize <= 0:
      continue
    if screenX >= viewportWidth or screenY >= viewportHeight:
      continue
    packet.addObject(
      BerryObjectBase + i,
      screenX, screenY, screenY + 2,
      MapLayerId,
      (if sim.berries[i].regrow == 0: BerryRipeSpriteId
       else: BerryPickedSpriteId)
    )

proc addCorpseObjects(
  packet: var seq[uint8],
  sim: SimServer,
  cameraX, cameraY, viewportWidth, viewportHeight: int
) =
  for i, c in sim.corpses:
    let
      screenX = c.tileX * StagTileSize - cameraX
      screenY = c.tileY * StagTileSize - cameraY
    if screenX + CorpseSpriteSize <= 0 or screenY + CorpseSpriteSize <= 0:
      continue
    if screenX >= viewportWidth or screenY >= viewportHeight:
      continue
    packet.addObject(
      CorpseObjectBase + i,
      screenX, screenY, screenY + 1,
      MapLayerId, CorpseSpriteId
    )

proc addIndicatorObjects(
  packet: var seq[uint8],
  sim: SimServer,
  cameraX, cameraY, viewportWidth, viewportHeight: int
) =
  proc place(
    packet: var seq[uint8],
    slotBase, tileX, tileY, side, dots: int
  ) =
    const indicatorOffset = (StagTileSize - IndicatorSpriteSize) div 2
    let
      tx = tileX + SideOffsets[side].dx
      ty = tileY + SideOffsets[side].dy
    if not inTileBounds(tx, ty):
      return
    if sim.tiles[tileIndex(tx, ty)] != TileEmpty:
      return
    let
      screenX = tx * StagTileSize - cameraX + indicatorOffset
      screenY = ty * StagTileSize - cameraY + indicatorOffset
    if screenX + IndicatorSpriteSize <= 0 or screenY + IndicatorSpriteSize <= 0:
      return
    if screenX >= viewportWidth or screenY >= viewportHeight:
      return
    packet.addObject(
      IndicatorObjectBase + slotBase * 4 + side,
      screenX, screenY, screenY + 2,
      MapLayerId, IndicatorSpriteBase + max(min(dots, 3), 1) - 1
    )

  for i in 0 ..< sim.prey.len:
    let sides = sim.occupiedSides(sim.prey[i].sideSeen)
    let occupied = sideCountOf(sides)
    if occupied == 0:
      continue
    let needed = preyMinPlayers(sim.prey[i].kind) - occupied
    if needed <= 0:
      continue
    let valid = validIndicatorSides(sim.prey[i].kind, sides)
    for side in 0 ..< 4:
      if valid[side]:
        packet.place(i, sim.prey[i].tileX, sim.prey[i].tileY, side, needed)

  for i in 0 ..< sim.items.len:
    let sides = sim.occupiedSides(sim.items[i].sideSeen)
    if sideCountOf(sides) == 0:
      continue
    let needed = sim.itemNeeds(sim.items[i], sides)
    if needed <= 0:
      continue
    for side in 0 ..< 4:
      if sides[side]:
        continue
      packet.place(ItemIndicatorSlotBase + i,
        sim.items[i].tileX, sim.items[i].tileY, side, needed)

  if sim.isPredatorPrey():
    # A forager already flanked by one hunter: mark the opposite side, which
    # is exactly the tile that completes the tag.
    for t in 0 ..< sim.players.len:
      if sim.players[t].role != roleForager or sim.players[t].disconnected:
        continue
      if sim.players[t].respawnIn > 0:
        continue
      var occupied: array[4, bool]
      for side in 0 ..< 4:
        let who = sim.playerAt(
          sim.players[t].tileX + SideOffsets[side].dx,
          sim.players[t].tileY + SideOffsets[side].dy)
        occupied[side] = who >= 0 and sim.players[who].role == roleHunter
      const opposite = [1, 0, 3, 2]
      for side in 0 ..< 4:
        if occupied[side] and not occupied[opposite[side]]:
          packet.place(ItemIndicatorSlotBase - 8 + t,
            sim.players[t].tileX, sim.players[t].tileY, opposite[side], 1)

proc addPlayerObjects(
  packet: var seq[uint8],
  sim: SimServer,
  viewerIndex: int,
  cameraX, cameraY, viewportWidth, viewportHeight: int
) =
  const glowOffset = -((KillGlowSpriteSize - PlayerSpriteSize) div 2)
  for i in 0 ..< sim.players.len:
    let player = sim.players[i]
    if player.disconnected:
      continue
    if player.respawnIn > 0 and i != viewerIndex:
      continue
    # Tall grass hides foragers from a hunter's per-seat frame only; the
    # global stream (viewerIndex < 0) always draws them.
    if viewerIndex >= 0 and sim.foragerHidden(viewerIndex, i):
      continue
    var
      screenX = player.tileX * StagTileSize - cameraX
      screenY = player.tileY * StagTileSize - cameraY
    if player.pushStep > 0:
      let progress = MooseGutAnimSteps - player.pushStep + 1
      let pixelOffset =
        ((MooseGutAnimSteps + 1 - progress) * StagTileSize) div
          (MooseGutAnimSteps + 1)
      screenX -= player.pushDx * pixelOffset
      screenY -= player.pushDy * pixelOffset
    if screenX + PlayerSpriteSize <= 0 or screenY + PlayerSpriteSize <= 0:
      continue
    if screenX >= viewportWidth or screenY >= viewportHeight:
      continue
    packet.addObject(
      PlayerObjectBase + i,
      screenX, screenY, screenY + 3,
      MapLayerId, playerSpriteId(player.colorIndex, player.facing)
    )
    if player.killGlow > 0 and (player.killGlow div 3) mod 2 == 0:
      packet.addObject(
        KillGlowObjectBase + i,
        screenX + glowOffset, screenY + glowOffset, screenY + 4,
        MapLayerId, KillGlowSpriteId
      )
    if player.trampleGlow > 0 and (player.trampleGlow div 3) mod 2 == 0:
      packet.addObject(
        TrampleGlowObjectBase + i,
        screenX + glowOffset, screenY + glowOffset, screenY + 4,
        MapLayerId, TrampleGlowSpriteId
      )
    # Levels over heads: the lbf badge, one pixel above the hunter.
    if sim.config.variant == "lbf":
      packet.addObject(
        LevelBadgeObjectBase + i,
        screenX + 4, screenY - 8, screenY + 5,
        MapLayerId, LevelBadgeBase + (player.level mod 10)
      )

proc addHudObjects(packet: var seq[uint8], score, energy: int) =
  var objIdx = 0
  packet.addObject(HudObjectBase + objIdx, 1, 1, HudZ, MapLayerId,
    ScoreIconSpriteId)
  inc objIdx
  let scoreStr = $max(0, score)
  var sx = 5
  for ch in scoreStr:
    let digit = ord(ch) - ord('0')
    packet.addObject(HudObjectBase + objIdx, sx, 1, HudZ, MapLayerId,
      DigitSpriteBase + digit)
    inc objIdx
    sx += DigitSpriteWidth + 1
  packet.addObject(HudObjectBase + objIdx, 1, 7, HudZ, MapLayerId,
    EnergyIconSpriteId)
  inc objIdx
  let energyStr = $max(0, energy)
  var ex = 5
  for ch in energyStr:
    let digit = ord(ch) - ord('0')
    packet.addObject(HudObjectBase + objIdx, ex, 7, HudZ, MapLayerId,
      DigitSpriteBase + digit)
    inc objIdx
    ex += DigitSpriteWidth + 1

proc addOverlayDigits(
  packet: var seq[uint8], x, y, num: int, objIdx: var int
) =
  let s = $max(0, num)
  var dx = x
  for ch in s:
    let digit = ord(ch) - ord('0')
    packet.addObject(OverlayObjectBase + objIdx, dx, y, OverlayZ, MapLayerId,
      DigitSpriteBase + digit)
    inc objIdx
    dx += DigitSpriteWidth + 1

proc addOverlayObjects(packet: var seq[uint8], sim: SimServer) =
  var objIdx = 0
  packet.addObject(OverlayObjectBase + objIdx, 0, 0, OverlayZ, MapLayerId,
    OverlayBgSpriteId)
  inc objIdx

  const animalStartY = 4
  const animalRowH = 24
  const animalX = 4
  for kind in PreyKind:
    let row = kind.ord
    let by = animalStartY + row * animalRowH
    packet.addObject(OverlayObjectBase + objIdx, animalX, by, OverlayZ,
      MapLayerId, preySpriteId(kind))
    inc objIdx
    let infoX = animalX + 16
    packet.addObject(OverlayObjectBase + objIdx, infoX, by + 2, OverlayZ,
      MapLayerId, ScoreIconSpriteId)
    inc objIdx
    let (energy, score) = rewardsFor(kind)
    packet.addOverlayDigits(infoX + 5, by + 2, score, objIdx)
    packet.addObject(OverlayObjectBase + objIdx, infoX, by + 9, OverlayZ,
      MapLayerId, EnergyIconSpriteId)
    inc objIdx
    packet.addOverlayDigits(infoX + 5, by + 9, energy, objIdx)

  const dividerX = 52
  packet.addObject(OverlayObjectBase + objIdx, dividerX, 0, OverlayZ,
    MapLayerId, DividerSpriteId)
  inc objIdx

  const playerStartX = 56
  const playerStartY = 4
  const playerRowH = 12
  for i in 0 ..< sim.players.len:
    let by = playerStartY + i * playerRowH
    if by + playerRowH > PlayerViewportHeight:
      break
    let p = sim.players[i]
    packet.addObject(OverlayObjectBase + objIdx, playerStartX, by, OverlayZ,
      MapLayerId, playerSpriteId(p.colorIndex, FaceDown))
    inc objIdx
    packet.addObject(OverlayObjectBase + objIdx, playerStartX + 14, by + 2,
      OverlayZ, MapLayerId, ScoreIconSpriteId)
    inc objIdx
    packet.addOverlayDigits(playerStartX + 20, by + 2, p.score, objIdx)

# ---------------------------------------------------------------------------
# Frames
# ---------------------------------------------------------------------------

proc buildPlayerFrame*(
  sim: SimServer,
  playerIndex: int,
  state: ViewerState,
  nextState: var ViewerState
): seq[uint8] =
  nextState = state
  if not nextState.initialized:
    result.addSpriteProtocolInit(sim.art, PlayerViewportWidth,
      PlayerViewportHeight)
    nextState.initialized = true
  result.addClearObjects()
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  result.addIdentity(PlayerObjectBase + playerIndex)
  if sim.players[playerIndex].overlayActive:
    result.addOverlayObjects(sim)
    return
  let (cameraX, cameraY) = playerCamera(sim.players[playerIndex])
  result.addTerrainObjects(sim, cameraX, cameraY, PlayerViewportWidth,
    PlayerViewportHeight)
  result.addCorpseObjects(sim, cameraX, cameraY, PlayerViewportWidth,
    PlayerViewportHeight)
  result.addBerryObjects(sim, cameraX, cameraY, PlayerViewportWidth,
    PlayerViewportHeight)
  result.addItemObjects(sim, cameraX, cameraY, PlayerViewportWidth,
    PlayerViewportHeight)
  result.addPreyObjects(sim, cameraX, cameraY, PlayerViewportWidth,
    PlayerViewportHeight)
  result.addIndicatorObjects(sim, cameraX, cameraY, PlayerViewportWidth,
    PlayerViewportHeight)
  result.addPlayerObjects(sim, playerIndex, cameraX, cameraY,
    PlayerViewportWidth, PlayerViewportHeight)
  result.addHudObjects(sim.players[playerIndex].score,
    sim.players[playerIndex].energy)

proc buildGlobalFrame*(
  sim: SimServer,
  chromeLabel: string,
  state: ViewerState,
  nextState: var ViewerState
): seq[uint8] =
  ## The spectator / replay frame. The broadcast chrome rides as the LABEL of
  ## sprite 4090, re-emitted every tick: broadcast_core.js routes that label
  ## to onText and never registers it as drawable, so the same path works
  ## live, in the generic client and in the hosted static replay.
  nextState = state
  if not nextState.initialized:
    result.addSpriteProtocolInit(sim.art, WorldWidthPixels, WorldHeightPixels)
    nextState.initialized = true
  result.addSprite(ChromeSpriteId, sim.art.chromeSprite, chromeLabel)
  result.addClearObjects()
  result.addTerrainObjects(sim, 0, 0, WorldWidthPixels, WorldHeightPixels)
  result.addCorpseObjects(sim, 0, 0, WorldWidthPixels, WorldHeightPixels)
  result.addBerryObjects(sim, 0, 0, WorldWidthPixels, WorldHeightPixels)
  result.addItemObjects(sim, 0, 0, WorldWidthPixels, WorldHeightPixels)
  result.addPreyObjects(sim, 0, 0, WorldWidthPixels, WorldHeightPixels)
  result.addIndicatorObjects(sim, 0, 0, WorldWidthPixels, WorldHeightPixels)
  result.addPlayerObjects(sim, -1, 0, 0, WorldWidthPixels, WorldHeightPixels)
  result.addObject(ChromeObjectBase, 0, 0, -1, MapLayerId, ChromeSpriteId)

# ---------------------------------------------------------------------------
# The broadcast chrome label
# ---------------------------------------------------------------------------

const LegalBeatKinds* = ["round", "bigcatch", "smallcatch", "tag", "end"]

proc beatKindFor*(capture: Capture): string =
  if capture.label.startsWith("tag on "): "tag"
  elif capture.big: "bigcatch"
  else: "smallcatch"

proc chromeSeatNode(seat: ChromeSeat): JsonNode =
  %*{
    "slot": seat.slot,
    "alias": runeCap(seat.alias, MaxNameRunes),
    "name": runeCap(seat.name, MaxNameRunes),
    "kind": seat.kind,
    "color": seat.color,
    "score": seat.score,
    "energy": seat.energy,
    "level": seat.level,
    "role": seat.role,
    "dc": seat.dc
  }

proc buildChromeLabel*(
  tick, roundNo, rounds, ticksPerRound: int,
  phase, variant, reason: string,
  seats: seq[ChromeSeat],
  feed: seq[ChromeFeedLine],
  beats: seq[ChromeBeat],
  final: JsonNode
): string =
  ## <= 4 KB of strict UTF-8 JSON, every free-text field rune-truncated.
  ## `beats` ships COMPLETE on the first frame (paintbot's ingestBeats
  ## pattern) so the scrubber tells the story before playback reaches it;
  ## `feed` carries only lines new since the previous frame.
  var seatsArr = newJArray()
  for seat in seats:
    seatsArr.add(chromeSeatNode(seat))
  var beatsArr = newJArray()
  for beat in beats:
    if beat.kind notin LegalBeatKinds:
      continue
    beatsArr.add(%*{"t": beat.tick, "k": beat.kind})
  var feedArr = newJArray()
  for line in feed:
    feedArr.add(%*{
      "t": line.tick,
      "kind": line.kind,
      "text": sanitizeLine(runeCap(line.text, MaxSayRunes))
    })
  var doc = %*{
    "tick": tick,
    "round": roundNo,
    "rounds": rounds,
    "ticksPerRound": ticksPerRound,
    "phase": phase,
    "variant": variant,
    "reason": (if reason.len == 0: newJNull() else: %reason),
    "seats": seatsArr,
    "feed": feedArr,
    "beats": beatsArr,
    "final": (if final.isNil: newJNull() else: final)
  }
  result = $doc
  # Cap at 4 KB by dropping feed lines first, then beats: the seats block and
  # the clock are what the page cannot render without.
  while result.len > MaxChromeLabelBytes and feedArr.len > 0:
    var trimmed = newJArray()
    for i in 1 ..< feedArr.len:
      trimmed.add(feedArr[i])
    feedArr = trimmed
    doc["feed"] = feedArr
    result = $doc
  while result.len > MaxChromeLabelBytes and beatsArr.len > 0:
    var trimmed = newJArray()
    for i in 1 ..< beatsArr.len:
      trimmed.add(beatsArr[i])
    beatsArr = trimmed
    doc["beats"] = beatsArr
    result = $doc
  if result.len > MaxChromeLabelBytes:
    doc["seats"] = newJArray()
    result = $doc
