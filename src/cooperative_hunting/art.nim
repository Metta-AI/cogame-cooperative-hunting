## Sprite patterns, PNG loading, the sprite cache and the sprite_v1 wire
## helpers.
##
## Forked from `Metta-AI/coworld-staghunt` `src/staghunt.nim` (the pattern
## DSL, `loadPngSprite`, `buildSpriteCache`, `addSpriteProtocolInit`). The
## animal/hunter/terrain art is the starter's PNGs, kept byte-for-byte in
## `sprites/12px/`. Everything the four variants add is drawn HERE with the
## same `patternToRgbaSprite` pattern DSL that draws the kill glow and the
## indicator dots -- iron and gold nodes, the gold countdown ring, the berry
## bush, tall grass and the level digit badges. No placeholder boxes.

import std/[os, strutils]
import pixie
import supersnappy
import bitworld/protocol
import bitworld/server
import ./sim_types

# ---------------------------------------------------------------------------
# Pattern DSL
# ---------------------------------------------------------------------------

proc parsePatternChar(c: char, playerBody, playerAccent: uint8): uint8 =
  case c
  of '.':
    TransparentColorIndex
  of 'P':
    playerBody
  of 'Q':
    playerAccent
  of '0' .. '9':
    uint8(ord(c) - ord('0'))
  of 'a' .. 'f':
    uint8(ord(c) - ord('a') + 10)
  else:
    TransparentColorIndex

proc newRgbaSprite*(width, height: int): RgbaSprite =
  RgbaSprite(
    width: width,
    height: height,
    pixels: newSeq[uint8](width * height * 4)
  )

proc putRgbaPixel*(sprite: var RgbaSprite, x, y: int, color: ColorRGBA) =
  if x < 0 or y < 0 or x >= sprite.width or y >= sprite.height:
    return
  let base = (y * sprite.width + x) * 4
  sprite.pixels[base + 0] = color.r
  sprite.pixels[base + 1] = color.g
  sprite.pixels[base + 2] = color.b
  sprite.pixels[base + 3] = color.a

proc paletteRgba(index: uint8): ColorRGBA =
  if index == TransparentColorIndex:
    return ColorRGBA(r: 0, g: 0, b: 0, a: 0)
  if int(index) >= Palette.len:
    return ColorRGBA(r: 0, g: 0, b: 0, a: 0)
  Palette[int(index)]

proc patternToRgbaSprite*(
  pattern: openArray[string],
  playerBody: uint8 = 0,
  playerAccent: uint8 = 0,
  facing: Facing = FaceDown
): RgbaSprite =
  let h = pattern.len
  if h == 0:
    return newRgbaSprite(0, 0)
  let w = pattern[0].len
  result = newRgbaSprite(w, h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let color = parsePatternChar(pattern[y][x], playerBody, playerAccent)
      if color == TransparentColorIndex:
        continue
      var dx = x
      var dy = y
      case facing
      of FaceDown:
        discard
      of FaceUp:
        dx = w - 1 - x
        dy = h - 1 - y
      of FaceLeft:
        dx = y
        dy = w - 1 - x
      of FaceRight:
        dx = h - 1 - y
        dy = x
      result.putRgbaPixel(dx, dy, paletteRgba(color))

# ---------------------------------------------------------------------------
# Patterns.
# '.' transparent; 0-9 a-f are palette indices; P/Q = player body/accent.
# Palette (DB16): 0 black, 1 gray, 2 white, 3 red, 4 pink, 5 dk-brown,
# 6 tan, 7 orange, 8 yellow, 9 dk-teal, a dk-green, b green, c navy,
# d dk-blue, e blue, f lt-blue.
# ---------------------------------------------------------------------------

const
  KillGlowPattern = [
    "....88888888....",
    "...8........8...",
    "..8..........8..",
    ".8............8.",
    "8..............8",
    "8..............8",
    "8..............8",
    "8..............8",
    "8..............8",
    "8..............8",
    "8..............8",
    "8..............8",
    ".8............8.",
    "..8..........8..",
    "...8........8...",
    "....88888888....",
  ]

  TrampleGlowPattern = [
    "....33333333....",
    "...3........3...",
    "..3..........3..",
    ".3............3.",
    "3..............3",
    "3..............3",
    "3..............3",
    "3..............3",
    "3..............3",
    "3..............3",
    "3..............3",
    "3..............3",
    ".3............3.",
    "..3..........3..",
    "...3........3...",
    "....33333333....",
  ]

  Indicator1Pattern = [
    "....",
    ".88.",
    ".88.",
    "....",
  ]

  Indicator2Pattern = [
    ".8..",
    "....",
    "....",
    "..8.",
  ]

  Indicator3Pattern = [
    ".8.8",
    "....",
    "....",
    "8...",
  ]

  DigitPatterns: array[10, array[5, string]] = [
    ["222", "2.2", "2.2", "2.2", "222"],
    [".2.", "22.", ".2.", ".2.", "222"],
    ["222", "..2", "222", "2..", "222"],
    ["222", "..2", "222", "..2", "222"],
    ["2.2", "2.2", "222", "..2", "..2"],
    ["222", "2..", "222", "..2", "222"],
    ["222", "2..", "222", "2.2", "222"],
    ["222", "..2", "..2", "..2", "..2"],
    ["222", "2.2", "222", "2.2", "222"],
    ["222", "2.2", "222", "..2", "222"],
  ]

  ScoreIconPattern = [
    ".8.",
    "888",
    ".8.",
    "8.8",
    "...",
  ]

  EnergyIconPattern = [
    ".bb",
    ".b.",
    "bb.",
    ".b.",
    "b..",
  ]

  ## An iron node: the rock silhouette with three white flecks of ore.
  ## Deliberately the same 12x12 boulder shape as the terrain rock, so a
  ## spectator reads "a rock worth mining" without a legend.
  IronNodePattern = [
    "............",
    "....11111...",
    "...1111111..",
    "..111211111.",
    ".11111111111",
    ".11121111211",
    ".11111111111",
    ".11111211111",
    ".01111111110",
    "..011111110.",
    "...0000000..",
    "............",
  ]

  ## A gold node: the same silhouette, index-8 (yellow) flecks.
  GoldNodePattern = [
    "............",
    "....11111...",
    "...1111111..",
    "..111811111.",
    ".11111111111",
    ".11181111811",
    ".11111111811",
    ".11111811111",
    ".01111111110",
    "..011111110.",
    "...0000000..",
    "............",
  ]

  ## The 3-tick countdown ring: a broken yellow ring around a gold node
  ## whose first side has just been taken. Drawn at 16x16 like the kill
  ## glow, and cycled through three phases by dropping arcs.
  CountdownRingPattern = [
    "....8888.8......",
    "...8........8...",
    "..8..........8..",
    ".8............8.",
    "8..............8",
    "...............8",
    "8..............8",
    "8...............",
    "8..............8",
    "...............8",
    "8..............8",
    "8...............",
    ".8............8.",
    "..8..........8..",
    "...8........8...",
    "......8888.8....",
  ]

  ## Berry bush, ripe: the tree silhouette recoloured to green with three
  ## index-3 (red) berries.
  BerryRipePattern = [
    "............",
    "....aaa.....",
    "...aabaaa...",
    "..aab3baaa..",
    "..abaaab3a..",
    ".aab3baaaba.",
    ".aaaaabaaaa.",
    "..abaaa3ba..",
    "...aabaaa...",
    "....a5a.....",
    "....555.....",
    "............",
  ]

  ## Berry bush, picked: the same bush without the berries, dimmer.
  BerryPickedPattern = [
    "............",
    "....aaa.....",
    "...aaaaaa...",
    "..aaaaaaaa..",
    "..aaaaaaaa..",
    ".aaaaaaaaaa.",
    ".aaaaaaaaaa.",
    "..aaaaaaaa..",
    "...aaaaaa...",
    "....a5a.....",
    "....555.....",
    "............",
  ]

  ## Tall grass: two rows of blades over the grass tile, drawn with alpha
  ## from the palette's two greens so a forager standing in it still reads
  ## as partly hidden.
  TallGrassPattern = [
    "............",
    "..b...b...b.",
    ".ab..ab..ab.",
    ".ab..ab..ab.",
    "aab.aab.aab.",
    "aabaaabaaaba",
    ".b..b...b..b",
    "ab.ab..ab.ab",
    "ab.ab..ab.ab",
    "aabaab.aabaa",
    "aaaaabaaaaab",
    "............",
  ]

  ## The chrome carrier: a single transparent pixel. broadcast_core.js reads
  ## sprite 4090's LABEL and never registers it as drawable.
  ChromePattern = [
    ".",
  ]

## A 5x7 level badge: one digit on a dark plate, drawn one pixel above the
## head. Reuses the DigitPatterns glyphs so the level over a hunter and the
## level over a food item are the same shape as the HUD digits.
proc levelBadgePattern(digit: int): array[7, string] =
  let glyph = DigitPatterns[digit mod 10]
  result[0] = "00000"
  result[1] = "0" & glyph[0] & "0"
  result[2] = "0" & glyph[1] & "0"
  result[3] = "0" & glyph[2] & "0"
  result[4] = "0" & glyph[3] & "0"
  result[5] = "0" & glyph[4] & "0"
  result[6] = "00000"

# ---------------------------------------------------------------------------
# PNG loading
# ---------------------------------------------------------------------------

proc spriteDir*(): string =
  ## Resolved at runtime: the game container chdirs to the repo root and the
  ## wasm bundle preloads `sprites` at the emscripten filesystem root.
  let local = getCurrentDir() / "sprites" / "12px"
  if dirExists(local): local
  else: "/sprites/12px"

proc loadPngSprite*(path: string): RgbaSprite =
  let img = readImage(path)
  result = newRgbaSprite(img.width, img.height)
  for y in 0 ..< img.height:
    for x in 0 ..< img.width:
      let c = img[x, y]
      let base = (y * img.width + x) * 4
      result.pixels[base + 0] = c.r
      result.pixels[base + 1] = c.g
      result.pixels[base + 2] = c.b
      result.pixels[base + 3] = c.a

proc preySpriteSize*(kind: PreyKind): int =
  case kind
  of Rabbit: RabbitSpriteSize
  of Boar: BoarSpriteSize
  of Stag: StagSpriteSize
  of Moose: MooseSpriteSize
  of Elephant: ElephantSpriteSize

const PlayerColors*: array[NumPlayerColors, tuple[body, accent: ColorRGBA] ] = [
  (ColorRGBA(r: 255, g: 0, b: 77, a: 255), ColorRGBA(r: 128, g: 0, b: 38, a: 255)),
  (ColorRGBA(r: 41, g: 173, b: 255, a: 255), ColorRGBA(r: 20, g: 86, b: 128, a: 255)),
  (ColorRGBA(r: 255, g: 163, b: 0, a: 255), ColorRGBA(r: 128, g: 60, b: 0, a: 255)),
  (ColorRGBA(r: 255, g: 119, b: 168, a: 255), ColorRGBA(r: 180, g: 40, b: 80, a: 255)),
  (ColorRGBA(r: 255, g: 236, b: 39, a: 255), ColorRGBA(r: 180, g: 140, b: 0, a: 255)),
  (ColorRGBA(r: 0, g: 228, b: 54, a: 255), ColorRGBA(r: 0, g: 100, b: 30, a: 255)),
  (ColorRGBA(r: 131, g: 118, b: 200, a: 255), ColorRGBA(r: 60, g: 50, b: 120, a: 255)),
  (ColorRGBA(r: 255, g: 241, b: 232, a: 255), ColorRGBA(r: 160, g: 160, b: 160, a: 255)),
  (ColorRGBA(r: 0, g: 135, b: 81, a: 255), ColorRGBA(r: 0, g: 60, b: 40, a: 255)),
  (ColorRGBA(r: 171, g: 82, b: 54, a: 255), ColorRGBA(r: 90, g: 40, b: 25, a: 255)),
  (ColorRGBA(r: 29, g: 43, b: 83, a: 255), ColorRGBA(r: 10, g: 15, b: 40, a: 255)),
  (ColorRGBA(r: 126, g: 37, b: 83, a: 255), ColorRGBA(r: 60, g: 15, b: 40, a: 255)),
  (ColorRGBA(r: 0, g: 200, b: 200, a: 255), ColorRGBA(r: 0, g: 100, b: 100, a: 255)),
  (ColorRGBA(r: 194, g: 195, b: 199, a: 255), ColorRGBA(r: 80, g: 80, b: 85, a: 255)),
  (ColorRGBA(r: 255, g: 100, b: 100, a: 255), ColorRGBA(r: 200, g: 50, b: 0, a: 255)),
  (ColorRGBA(r: 180, g: 230, b: 80, a: 255), ColorRGBA(r: 80, g: 120, b: 30, a: 255)),
  (ColorRGBA(r: 220, g: 150, b: 255, a: 255), ColorRGBA(r: 120, g: 60, b: 160, a: 255)),
  (ColorRGBA(r: 255, g: 200, b: 120, a: 255), ColorRGBA(r: 180, g: 100, b: 40, a: 255)),
  (ColorRGBA(r: 100, g: 220, b: 170, a: 255), ColorRGBA(r: 40, g: 110, b: 80, a: 255)),
  (ColorRGBA(r: 255, g: 80, b: 180, a: 255), ColorRGBA(r: 150, g: 30, b: 100, a: 255)),
]

proc playerBodyRgba*(colorIndex: int): ColorRGBA =
  PlayerColors[colorIndex mod NumPlayerColors].body

proc playerAccentRgba*(colorIndex: int): ColorRGBA =
  PlayerColors[colorIndex mod NumPlayerColors].accent

proc playerColorHex*(colorIndex: int): string =
  let c = playerBodyRgba(colorIndex)
  "#" & toHex(int(c.r), 2) & toHex(int(c.g), 2) & toHex(int(c.b), 2)

proc recolorPng(
  source: RgbaSprite,
  bodyColor, accentColor: ColorRGBA,
): RgbaSprite =
  ## Replaces the placeholder colors #0044ff / #00227f with the seat's body
  ## and accent colors.
  let w = source.width
  let h = source.height
  result = newRgbaSprite(w, h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let srcBase = (y * w + x) * 4
      let r = source.pixels[srcBase + 0]
      let g = source.pixels[srcBase + 1]
      let b = source.pixels[srcBase + 2]
      let a = source.pixels[srcBase + 3]
      if r == 0 and g == 68 and b == 255:
        result.pixels[srcBase + 0] = bodyColor.r
        result.pixels[srcBase + 1] = bodyColor.g
        result.pixels[srcBase + 2] = bodyColor.b
        result.pixels[srcBase + 3] = a
      elif r == 0 and g == 34 and b == 127:
        result.pixels[srcBase + 0] = accentColor.r
        result.pixels[srcBase + 1] = accentColor.g
        result.pixels[srcBase + 2] = accentColor.b
        result.pixels[srcBase + 3] = a
      else:
        result.pixels[srcBase + 0] = r
        result.pixels[srcBase + 1] = g
        result.pixels[srcBase + 2] = b
        result.pixels[srcBase + 3] = a

proc buildSpriteCache*(cache: var SpriteCache) =
  ## Loads the starter's PNGs and bakes the pattern-drawn furniture. The
  ## only file IO in the whole sim; the wasm bundle preloads `sprites/`.
  loadPalette()
  let dir = spriteDir()

  cache.treeSprite = loadPngSprite(dir / "tree.png")
  cache.rockSprite = loadPngSprite(dir / "rock.png")
  cache.backgroundSprite = loadPngSprite(dir / "grass.png")
  cache.corpseSprite = loadPngSprite(dir / "ded.png")

  cache.killGlowSprite = patternToRgbaSprite(KillGlowPattern)
  cache.trampleGlowSprite = patternToRgbaSprite(TrampleGlowPattern)

  const preyFileNames: array[5, string] =
    ["rabbit", "boar", "stag", "moose", "elephant"]
  for kind in PreyKind:
    cache.preySprites[kind.ord] =
      loadPngSprite(dir / preyFileNames[kind.ord] & ".png")

  let hunterFile = loadPngSprite(dir / "hunter.png")
  for colorSlot in 0 ..< NumPlayerColors:
    let body = playerBodyRgba(colorSlot)
    let accent = playerAccentRgba(colorSlot)
    for facing in Facing:
      cache.playerSprites[colorSlot * 4 + facing.ord] =
        recolorPng(hunterFile, body, accent)

  cache.indicatorSprites[0] = patternToRgbaSprite(Indicator1Pattern)
  cache.indicatorSprites[1] = patternToRgbaSprite(Indicator2Pattern)
  cache.indicatorSprites[2] = patternToRgbaSprite(Indicator3Pattern)

  for d in 0 ..< 10:
    cache.digitSprites[d] = patternToRgbaSprite(DigitPatterns[d])
    cache.levelBadges[d] = patternToRgbaSprite(levelBadgePattern(d))
  cache.scoreIconSprite = patternToRgbaSprite(ScoreIconPattern)
  cache.energyIconSprite = patternToRgbaSprite(EnergyIconPattern)

  cache.ironSprite = patternToRgbaSprite(IronNodePattern)
  cache.goldSprite = patternToRgbaSprite(GoldNodePattern)
  cache.countdownRingSprite = patternToRgbaSprite(CountdownRingPattern)
  cache.berryRipeSprite = patternToRgbaSprite(BerryRipePattern)
  cache.berryPickedSprite = patternToRgbaSprite(BerryPickedPattern)
  cache.tallGrassSprite = patternToRgbaSprite(TallGrassPattern)
  cache.chromeSprite = patternToRgbaSprite(ChromePattern)

  cache.overlayBgSprite =
    newRgbaSprite(PlayerViewportWidth, PlayerViewportHeight)
  let bgColor = ColorRGBA(r: 26, g: 28, b: 44, a: 255)
  for y in 0 ..< PlayerViewportHeight:
    for x in 0 ..< PlayerViewportWidth:
      cache.overlayBgSprite.putRgbaPixel(x, y, bgColor)

  cache.dividerSprite = newRgbaSprite(1, PlayerViewportHeight)
  let divColor = ColorRGBA(r: 86, g: 108, b: 134, a: 255)
  for y in 0 ..< PlayerViewportHeight:
    cache.dividerSprite.putRgbaPixel(0, y, divColor)

  cache.built = true

# ---------------------------------------------------------------------------
# sprite_v1 wire helpers
# ---------------------------------------------------------------------------

proc addU8*(packet: var seq[uint8], value: uint8) =
  packet.add(value)

proc addU16*(packet: var seq[uint8], value: int) =
  let v = uint16(value)
  packet.add(uint8(v and 0xff'u16))
  packet.add(uint8(v shr 8))

proc addU32*(packet: var seq[uint8], value: int) =
  let v = uint32(value)
  for shift in countup(0, 24, 8):
    packet.add(uint8((v shr shift) and 0xff'u32))

proc addI16*(packet: var seq[uint8], value: int) =
  let v = cast[uint16](int16(value))
  packet.add(uint8(v and 0xff'u16))
  packet.add(uint8(v shr 8))

proc addLayer*(packet: var seq[uint8], layer, kind, flags: int) =
  packet.addU8(0x06'u8)
  packet.addU8(uint8(layer))
  packet.addU8(uint8(kind))
  packet.addU8(uint8(flags))

proc addViewport*(packet: var seq[uint8], layer, width, height: int) =
  packet.addU8(0x05'u8)
  packet.addU8(uint8(layer))
  packet.addU16(width)
  packet.addU16(height)

proc addSprite*(
  packet: var seq[uint8],
  spriteId: int,
  sprite: RgbaSprite,
  label: string
) =
  packet.addU8(0x01'u8)
  packet.addU16(spriteId)
  packet.addU16(sprite.width)
  packet.addU16(sprite.height)
  let compressed = supersnappy.compress(sprite.pixels)
  packet.addU32(compressed.len)
  for byteValue in compressed:
    packet.addU8(byteValue)
  packet.addU16(label.len)
  for ch in label:
    packet.addU8(uint8(ord(ch)))

proc addObject*(
  packet: var seq[uint8],
  objectId, x, y, z, layer, spriteId: int
) =
  packet.addU8(0x02'u8)
  packet.addU16(objectId)
  packet.addI16(x)
  packet.addI16(y)
  packet.addI16(z)
  packet.addU8(uint8(layer))
  packet.addU16(spriteId)

proc addClearObjects*(packet: var seq[uint8]) =
  packet.addU8(0x04'u8)

proc addIdentity*(packet: var seq[uint8], objectId: int) =
  packet.addU8(0x07'u8)
  packet.addU16(objectId)

proc playerSpriteId*(colorSlot: int, facing: Facing): int =
  PlayerSpriteBase + (colorSlot mod NumPlayerColors) * 4 + facing.ord

proc preySpriteId*(kind: PreyKind): int =
  PreySpriteBase + kind.ord

proc addSpriteProtocolInit*(
  packet: var seq[uint8],
  cache: SpriteCache,
  viewportWidth, viewportHeight: int
) =
  packet.addLayer(MapLayerId, MapLayerKind, MapLayerFlags)
  packet.addViewport(MapLayerId, viewportWidth, viewportHeight)
  packet.addSprite(BackgroundSpriteId, cache.backgroundSprite, "grass")
  packet.addSprite(TreeSpriteId, cache.treeSprite, "tree")
  packet.addSprite(RockSpriteId, cache.rockSprite, "rock")
  packet.addSprite(CorpseSpriteId, cache.corpseSprite, "corpse")
  packet.addSprite(KillGlowSpriteId, cache.killGlowSprite, "kill glow")
  packet.addSprite(TrampleGlowSpriteId, cache.trampleGlowSprite, "trample glow")
  for kind in PreyKind:
    packet.addSprite(preySpriteId(kind), cache.preySprites[kind.ord],
      preyLabel(kind))
  for colorSlot in 0 ..< NumPlayerColors:
    for facing in Facing:
      packet.addSprite(
        playerSpriteId(colorSlot, facing),
        cache.playerSprites[colorSlot * 4 + facing.ord],
        "hunter " & $colorSlot & " " & $facing
      )
  for i in 0 ..< 3:
    packet.addSprite(
      IndicatorSpriteBase + i,
      cache.indicatorSprites[i],
      "indicator " & $(i + 1)
    )
  for d in 0 ..< 10:
    packet.addSprite(DigitSpriteBase + d, cache.digitSprites[d], "digit " & $d)
    packet.addSprite(LevelBadgeBase + d, cache.levelBadges[d], "level " & $d)
  packet.addSprite(ScoreIconSpriteId, cache.scoreIconSprite, "score icon")
  packet.addSprite(EnergyIconSpriteId, cache.energyIconSprite, "energy icon")
  packet.addSprite(OverlayBgSpriteId, cache.overlayBgSprite, "overlay bg")
  packet.addSprite(DividerSpriteId, cache.dividerSprite, "divider")
  packet.addSprite(IronSpriteId, cache.ironSprite, "iron node")
  packet.addSprite(GoldSpriteId, cache.goldSprite, "gold node")
  packet.addSprite(CountdownRingSpriteId, cache.countdownRingSprite,
    "countdown ring")
  packet.addSprite(BerryRipeSpriteId, cache.berryRipeSprite, "berry bush")
  packet.addSprite(BerryPickedSpriteId, cache.berryPickedSprite,
    "picked berry bush")
  packet.addSprite(TallGrassSpriteId, cache.tallGrassSprite, "tall grass")
