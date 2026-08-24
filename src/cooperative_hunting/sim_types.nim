## Types, constants and configuration for Cooperative Hunting.
##
## Forked from `Metta-AI/coworld-staghunt` `src/staghunt.nim` (the types and
## const block at its head) and extended with the four-variant knobs the
## design note adds: `CaptureRule`, `PlayerRole`, per-seat `level`, the
## `sideSeen` window stamps, and `Item` (ore / food / berry furniture).
##
## Pure: no mummy, no sockets, no file IO. The wasm replay module imports it.

import std/[random, unicode]
import bitworld/protocol
import bitworld/server

export random.Rand
export server.Facing, server.TransparentColorIndex
export protocol.InputState

const
  # Cooperative Hunting picks its own world tile size rather than inherit the
  # protocol's 6 px default. Bigger pixels per tile = recognizable art at the
  # cost of fewer visible tiles per viewport (~10 across instead of ~21).
  StagTileSize* = 12

  WorldWidthTiles* = 32
  WorldHeightTiles* = 32
  WorldWidthPixels* = WorldWidthTiles * StagTileSize
  WorldHeightPixels* = WorldHeightTiles * StagTileSize

  PlayerMoveCooldownTicks* = 5
  PreyThinkIntervalTicks* = 10  # default; preyThinkInterval() overrides per kind

  PreyFleeRadius* = 3
  PreyFleeProb1* = 75
  PreyFleeProb2* = 50
  PreyFleeProb3* = 25
  PreyWanderProb* = 30

  MaxEnergy* = 200
  PassiveRechargeMax* = 100
  StartEnergy* = 120
  MoveEnergyCost* = 2
  PassiveRechargeInterval* = 18

  ElephantThinkMin* = 12
  ElephantThinkMax* = 24
  ElephantTrampleEnergyLoss* = 30
  MooseGutProbCardinal* = 30
  MooseGutProbDiagonal* = 5
  MooseGutEnergyLoss* = 10
  MooseGutAnimSteps* = 4
  TrampleAnimSteps* = 4
  ElephantStrideProb* = 30
  ElephantStrideMin* = 1
  ElephantStrideMax* = 3

  KillGlowTicks* = 20
  TrampleGlowTicks* = 20
  CorpseLifetimeTicks* = 48
  AlertFlashTicks* = 6

  RabbitEnergyReward* = 15
  RabbitScoreReward* = 1
  BoarEnergyReward* = 90
  BoarScoreReward* = 3
  StagEnergyReward* = 60
  StagScoreReward* = 5
  MooseEnergyReward* = 140
  MooseScoreReward* = 10
  ElephantEnergyReward* = 220
  ElephantScoreReward* = 18

  TargetRabbits* = 12
  TargetBoars* = 6
  TargetStags* = 6
  TargetMooses* = 3
  TargetElephants* = 2

  RespawnIntervalTicks* = 60
  CatchupSpawnCooldown* = 3

  ObstacleDensityPerMille* = 110

  # --- Cooperative Hunting additions -------------------------------------
  ## The 40-tick (5 s at 8 Hz) round card, rescaled from staghunt's 240 at
  ## 24 fps. The world freezes and the per-seat overlay is forced on.
  RoundEndDisplayTicks* = 40

  ## coop-mining furniture.
  TargetIronNodes* = 18
  TargetGoldNodes* = 8
  IronScoreReward* = 1
  IronEnergyReward* = 10
  GoldScoreReward* = 8
  GoldEnergyReward* = 40
  CoopMiningWindowTicks* = 3

  ## lbf furniture.
  TargetFoodItems* = 14
  MaxFoodLevel* = 6
  LbfScorePerLevel* = 2
  LbfEnergyPerLevel* = 20

  ## predator-prey furniture.
  BerryTiles* = 40
  TallGrassTiles* = 120
  BerryRegrowTicks* = 90
  BerryScoreReward* = 1
  BerryEnergyReward* = 12
  TagScoreReward* = 6
  TagEnergyLoss* = 30
  TagRespawnTicks* = 24
  ## A forager on tall grass is invisible to a hunter beyond this Chebyshev
  ## distance in that hunter's per-seat frame. Always visible on /global.
  GrassRevealDistance* = 2

  MaxPlayerSlots* = 64
  NumSeatAliases* = 26

  # Sprite v1 layer/sprite/object layout ----------------------------------
  MapLayerId* = 0
  MapLayerKind* = 0
  MapLayerFlags* = 1

  PlayerViewportWidth* = ScreenWidth   # 128
  PlayerViewportHeight* = ScreenHeight # 128

  TreeSpriteId* = 1
  RockSpriteId* = 2
  CorpseSpriteId* = 4
  KillGlowSpriteId* = 5
  TrampleGlowSpriteId* = 6
  PreySpriteBase* = 10        # + PreyKind.ord (0..4)
  NumPlayerColors* = 20
  PlayerSpriteBase* = 100     # + colorSlot * 4 + facing.ord  (0..79)

  TileObjectBase* = 1000
  PlayerObjectBase* = 5000
  CorpseObjectBase* = 6000
  KillGlowObjectBase* = 7000
  TrampleGlowObjectBase* = 7100
  IndicatorObjectBase* = 9000
  PreyObjectBase* = 10000

  TerrainZ* = 0
  BackgroundSpriteId* = 3
  BackgroundObjectBase* = 8000

  PlayerSpriteSize* = 12
  RabbitSpriteSize* = 10
  BoarSpriteSize* = 12
  StagSpriteSize* = 12
  MooseSpriteSize* = 14
  ElephantSpriteSize* = 14

  CorpseSpriteSize* = 12
  KillGlowSpriteSize* = 16
  IndicatorSpriteSize* = 4
  IndicatorSpriteBase* = 20   # 20, 21, 22 for 1-dot, 2-dot, 3-dot

  DigitSpriteBase* = 30       # ids 30-39 for digits 0-9
  ScoreIconSpriteId* = 40
  EnergyIconSpriteId* = 41
  OverlayBgSpriteId* = 42
  DividerSpriteId* = 43
  DigitSpriteWidth* = 3
  DigitSpriteHeight* = 5
  HudObjectBase* = 11000
  OverlayObjectBase* = 12000
  HudZ* = 9999
  OverlayZ* = 10000

  ## New furniture sprites, all drawn with the pattern DSL in art.nim.
  IronSpriteId* = 50
  GoldSpriteId* = 51
  CountdownRingSpriteId* = 52
  BerryRipeSpriteId* = 53
  BerryPickedSpriteId* = 54
  TallGrassSpriteId* = 55
  LevelBadgeBase* = 60        # + digit 0..9, a 5x7 badge with a dark plate

  ItemObjectBase* = 13000     # + item index
  BerryObjectBase* = 14000    # + berry index
  GrassObjectBase* = 15000    # + tile index (0..1023) -- 15000..16023
  LevelBadgeObjectBase* = 16100  # + player index
  RingObjectBase* = 16200     # + item index

  ## The broadcast chrome rides as the LABEL of this reserved 1x1 sprite,
  ## re-emitted every tick. broadcast_core.js routes sprite 4090's label to
  ## onText and never registers it as drawable, so the same path works live,
  ## in the generic client and in the hosted static replay.
  ChromeSpriteId* = 4090
  ChromeObjectBase* = 16300
  MaxChromeLabelBytes* = 4096

  ## Reply / recorded-string caps. Every one of these is applied on RUNE
  ## boundaries (see `runeCap` below): a byte-cut multi-byte rune is what
  ## makes replay bytes fail a strict JSON parser while still rendering in a
  ## browser.
  MaxSayRunes* = 120
  MaxNoteRunes* = 200
  MaxPromptRunes* = 1200
  MaxNameRunes* = 64
  MaxErrorRunes* = 240
  MaxIntentChars* = 12
  MaxTargetChars* = 24
  MaxSideChars* = 3
  MaxWithItems* = 3
  MaxWithChars* = 8
  MaxRegistrationBytes* = 4096

  DefaultSeed* = 5743127

type
  PreyKind* = enum
    Rabbit
    Boar
    Stag
    Moose
    Elephant

  TileKind* = enum
    TileEmpty
    TileTree
    TileRock

  CaptureRule* = enum
    ## How occupied sides turn into a capture.
    crSides      ## staghunt / predator-prey tagging: the per-kind predicate
    crWindow     ## coop-mining: N distinct slots inside `windowTicks`
    crLevelSum   ## lbf: adjacent hunters' levels must sum to the item's level

  PlayerRole* = enum
    roleHunter
    roleForager

  ItemKind* = enum
    itIron
    itGold
    itFood

  PolicyKind* = enum
    pkScripted
    pkPrompt

  RoundPhase* = enum
    RoundPlaying
    RoundEnding

  EndReason* = enum
    ## Exactly three values are legal and the game emits nothing else.
    erComplete = "complete"
    erDeadline = "deadline"
    erNoPlayers = "no_players"

  SideStamp* = object
    ## The most recent tick a hunter stood on this side, and which slot.
    ## `tick == 0` means never.
    tick*: int
    slot*: int

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[string]      ## display names, spectator side only
    numAgents*: int
    seed*: int
    variant*: string
    rounds*: int
    ticksPerRound*: int
    tickHz*: int
    planIntervalTicks*: int
    planTimeoutSeconds*: int
    playBudgetSeconds*: int
    playerConnectTimeoutSeconds*: int
    maxOutputTokens*: int
    model*: string
    closedRoster*: bool
    focusElephant*: bool       ## local balance mode; never set by a variant

  PlayerStats* = object
    catches*: array[PreyKind, int]
    coCatches*: seq[int]

  Player* = object
    id*: int
    name*: string              ## real policy name, spectator side only
    alias*: string             ## Cog-A .. Cog-F, the only in-game identity
    slot*: int
    tileX*: int
    tileY*: int
    facing*: Facing
    energy*: int
    score*: int
    moveCooldown*: int
    killGlow*: int
    trampleGlow*: int
    rechargeCounter*: int
    colorIndex*: int
    overlayActive*: bool
    selectWasDown*: bool
    pushStep*: int
    pushDx*: int
    pushDy*: int
    # --- Cooperative Hunting additions ---
    level*: int                ## lbf loading level, 1..4
    role*: PlayerRole          ## predator-prey role for the current round
    kind*: PolicyKind
    disconnected*: bool
    respawnIn*: int            ## predator-prey: ticks until a tagged forager returns

  Prey* = object
    id*: int
    kind*: PreyKind
    tileX*: int
    tileY*: int
    thinkCooldown*: int
    alertFlash*: int
    trampleStep*: int
    trampleDx*: int
    trampleDy*: int
    gutStep*: int
    gutDx*: int
    gutDy*: int
    strideRemaining*: int
    strideDx*: int
    strideDy*: int
    sideSeen*: array[4, SideStamp]   ## N, S, E, W

  Item* = object
    ## coop-mining ore nodes and lbf food. Immobile.
    id*: int
    kind*: ItemKind
    tileX*: int
    tileY*: int
    level*: int                      ## lbf food level 1..6; 0 for ore
    sideSeen*: array[4, SideStamp]

  Berry* = object
    tileX*: int
    tileY*: int
    regrow*: int                     ## 0 = ripe, else ticks until ripe

  Corpse* = object
    tileX*: int
    tileY*: int
    ticksRemaining*: int

  RgbaSprite* = object
    width*: int
    height*: int
    pixels*: seq[uint8]

  SpriteCache* = object
    built*: bool
    treeSprite*: RgbaSprite
    rockSprite*: RgbaSprite
    backgroundSprite*: RgbaSprite
    corpseSprite*: RgbaSprite
    killGlowSprite*: RgbaSprite
    trampleGlowSprite*: RgbaSprite
    preySprites*: array[5, RgbaSprite]
    playerSprites*: array[NumPlayerColors * 4, RgbaSprite]
    indicatorSprites*: array[3, RgbaSprite]
    digitSprites*: array[10, RgbaSprite]
    levelBadges*: array[10, RgbaSprite]
    scoreIconSprite*: RgbaSprite
    energyIconSprite*: RgbaSprite
    overlayBgSprite*: RgbaSprite
    dividerSprite*: RgbaSprite
    ironSprite*: RgbaSprite
    goldSprite*: RgbaSprite
    countdownRingSprite*: RgbaSprite
    berryRipeSprite*: RgbaSprite
    berryPickedSprite*: RgbaSprite
    tallGrassSprite*: RgbaSprite
    chromeSprite*: RgbaSprite

  ViewerState* = object
    initialized*: bool

  EventRecord* = object
    ## One entry of the replay event vocabulary. `payload` is a compact JSON
    ## object body WITHOUT the surrounding braces, already escaped.
    tick*: int
    name*: string
    payload*: string

  Capture* = object
    ## What one resolved capture credited, for the feed and the replay.
    tick*: int
    label*: string             ## "stag", "gold node", "level 4 food", ...
    tileX*: int
    tileY*: int
    slots*: seq[int]
    scoreEach*: seq[int]
    energyEach*: int
    big*: bool                 ## drives the bigcatch / smallcatch beat kind

  SimServer* = object
    config*: GameConfig
    captureRule*: CaptureRule
    windowTicks*: int
    rewardSplit*: bool
    players*: seq[Player]
    prey*: seq[Prey]
    items*: seq[Item]
    berries*: seq[Berry]
    corpses*: seq[Corpse]
    tiles*: seq[TileKind]
    tallGrass*: seq[bool]
    rng*: Rand
    nextPlayerId*: int
    nextPreyId*: int
    nextItemId*: int
    tickCount*: int
    globalTick*: int           ## monotonic across rounds; the replay's `t`
    roundIndex*: int           ## 0-based
    phase*: RoundPhase
    respawnCooldown*: int
    stats*: seq[PlayerStats]
    focusElephant*: bool
    art*: SpriteCache
    ## Captures resolved on the current tick, drained by the caller.
    pendingCaptures*: seq[Capture]
    ## Events logged on the current tick, drained by the caller.
    pendingEvents*: seq[EventRecord]

proc runeCap*(text: string, limit: int): string =
  ## Truncate on a RUNE boundary, never a byte boundary. Applied to every
  ## string that reaches the replay, a sprite label or a results file: a
  ## byte-cut multi-byte rune renders fine in a browser and then fails a
  ## strict JSON parser downstream (playbook gotcha).
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc sanitizeLine*(text: string): string =
  ## Collapse control characters so a recorded string is a single safe line.
  result = newStringOfCap(text.len)
  for rune in text.runes:
    let value = int32(rune)
    if value < 0x20 or value == 0x7f:
      result.add(' ')
    else:
      result.add($rune)
  result = result.strip()

proc preyMinPlayers*(kind: PreyKind): int =
  case kind
  of Rabbit: 1
  of Boar: 2
  of Stag: 2
  of Moose: 3
  of Elephant: 4

proc rewardsFor*(kind: PreyKind): tuple[energy, score: int] =
  case kind
  of Rabbit: (RabbitEnergyReward, RabbitScoreReward)
  of Boar: (BoarEnergyReward, BoarScoreReward)
  of Stag: (StagEnergyReward, StagScoreReward)
  of Moose: (MooseEnergyReward, MooseScoreReward)
  of Elephant: (ElephantEnergyReward, ElephantScoreReward)

proc targetFor*(kind: PreyKind): int =
  case kind
  of Rabbit: TargetRabbits
  of Boar: TargetBoars
  of Stag: TargetStags
  of Moose: TargetMooses
  of Elephant: TargetElephants

proc preyLabel*(kind: PreyKind): string =
  case kind
  of Rabbit: "rabbit"
  of Boar: "boar"
  of Stag: "stag"
  of Moose: "moose"
  of Elephant: "elephant"

proc itemLabel*(item: Item): string =
  case item.kind
  of itIron: "iron"
  of itGold: "gold"
  of itFood: "level " & $item.level & " food"

proc captureRuleFor*(variant: string): CaptureRule =
  case variant
  of "coop-mining": crWindow
  of "lbf": crLevelSum
  else: crSides

proc windowTicksFor*(variant: string): int =
  if variant == "coop-mining": CoopMiningWindowTicks else: 1

proc rewardSplitFor*(variant: string): bool =
  variant == "lbf"

proc isKnownVariant*(variant: string): bool =
  variant in ["staghunt", "coop-mining", "lbf", "predator-prey"]

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    tokens: @[],
    players: @[],
    numAgents: 6,
    seed: DefaultSeed,
    variant: "staghunt",
    rounds: 3,
    ticksPerRound: 960,
    tickHz: 8,
    planIntervalTicks: 120,
    planTimeoutSeconds: 12,
    playBudgetSeconds: 660,
    playerConnectTimeoutSeconds: 120,
    maxOutputTokens: 900,
    model: "claude-haiku-4-5",
    closedRoster: false,
    focusElephant: false
  )

proc aliasForSlot*(index: int): string =
  ## Cog-A .. Cog-Z. The seeded permutation that assigns them lives in sim.nim.
  "Cog-" & $chr(ord('A') + (index mod NumSeatAliases))
