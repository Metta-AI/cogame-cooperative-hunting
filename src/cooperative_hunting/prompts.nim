## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const
  PromptBankVersion* = "cooperative-hunting-rules-v2"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

proc introduction*(selection: PromptSelection): string =
  case selection.selectedVariant
  of pvCanonical: "You are one hunter in a six-hunter cooperative hunting party on a 32x32 forest grid."
  of pvPlain: "You play one of six hunters cooperating on a 32x32 forest grid."
  of pvNumbered: "Your role: hunter. Party size: six hunters. Setting: a 32x32 forest grid for cooperative hunting."
  of pvQuestions: "Who are you? One hunter in a party of six. Where do you cooperate? A 32x32 forest grid."
  of pvReordered: "On a 32x32 forest grid, a party of six hunters cooperates; you control one hunter."
  of pvHeldoutBriefing: "Join the six-hunter cooperative party as one hunter in its 32x32 forest grid."
  of pvHeldoutReference: "Cooperative hunting role reference: one hunter, six-hunter party, 32x32 forest grid."
  of pvMixed: raise newException(ValueError, "mixed selection must resolve to a training wording")

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

proc rulesBriefing*(selection: PromptSelection, variant: string): string =
  let index = ord(selection.selectedVariant)
  case variant
  of "staghunt":
    let briefings = [
      "Rabbits die to one hunter. Boars need two hunters on perpendicular sides at once, stags\ntwo on opposite sides, moose any three sides, elephants all four. Everyone standing on a\nside when the animal falls scores the full value, so a moose or an elephant is worth many\nrabbits - but only if your allies commit to the same animal at the same time. A half-formed\nring gets trampled or gored and scores nothing.\nYou give one high-level plan; a controller walks you there tile by tile until your next plan.",
      "One hunter can take a rabbit. Taking a boar requires two hunters on perpendicular sides; a stag needs two opposite sides, a moose any three, and an elephant all four. Occupy the required sides simultaneously. Every participant gets the full value, so coordinated moose or elephant captures beat many rabbits. An incomplete ring can be trampled or gored and earns nothing.",
      "Capture requirements:\n1. Rabbit: one hunter.\n2. Boar: two perpendicular sides.\n3. Stag: two opposite sides.\n4. Moose: any three sides.\n5. Elephant: all four sides.\nOccupy these sides at once; each participant receives the full value. Moose and elephants are worth many rabbits only when allies commit together. An incomplete ring can suffer trampling or goring and scores nothing.",
      "What coalition takes each animal? One hunter for a rabbit, two perpendicular sides for a boar, two opposite sides for a stag, any three sides for a moose, and all four for an elephant. When must hunters commit? At the same time. Who scores? Everyone on a side when it falls gets full value. Moose and elephants beat many rabbits with coordination; an incomplete ring gets trampled or gored and scores nothing.",
      "Every hunter on a side at capture receives full value. Moose and elephants can therefore earn many rabbits' worth, provided allies commit to the same animal simultaneously. Required sides: one hunter for rabbit, two perpendicular for boar, two opposite for stag, any three for moose, all four for elephant. An incomplete ring risks trampling or goring and earns nothing.",
      "Hunting briefing: coordinate arrivals on the same animal. Rabbits take one hunter, boars two perpendicular sides, stags two opposite sides, moose any three, elephants all four, occupied simultaneously. Each participant receives full value; large animals are worth many rabbits when allies commit. A partial ring gets trampled or gored and scores nothing.",
      "Capture reference: rabbit = one hunter; boar = two perpendicular sides; stag = two opposite sides; moose = any three; elephant = all four. Timing: simultaneous. Reward: full value to everyone on a side when the animal falls. Coordination: moose and elephant values exceed many rabbits only with allies committed. Partial ring: trampling or goring, no score."
    ]
    result = briefings[index]
  of "coop-mining":
    let briefings = [
      "There are no animals. Mine immobile iron and gold. One adjacent participant takes iron for +1 score and +10 energy. Gold requires two different participants on any two sides within a 3-tick window; each receives +8 score and +40 energy.",
      "Approach iron alone for +1 score and +10 energy. For gold, coordinate two different participants on any two sides within 3 ticks; each gets +8 score and +40 energy. This mode has immobile ore instead of animals.",
      "Mining rules:\n1. Ore is immobile; there are no animals.\n2. Iron needs one adjacent participant and awards +1 score/+10 energy.\n3. Gold needs two different participants on any two sides within 3 ticks and awards +8 score/+40 energy to each.",
      "What do you collect? Immobile ore, not animals. How is iron mined? One adjacent participant gets +1 score and +10 energy. How is gold mined? Two different participants occupy any two sides within a 3-tick window, each gaining +8 score and +40 energy.",
      "Gold pays each participant +8 score and +40 energy when two different participants reach any two sides within 3 ticks. Iron pays +1 score and +10 energy to one adjacent participant. The targets are immobile ore; no animals occur.",
      "Mining briefing: iron is solo income, +1 score/+10 energy for one adjacent participant. Gold is coordinated income: two different participants on any two sides within 3 ticks, +8 score/+40 energy each. All ore is immobile; animals are absent.",
      "Mining reference: immobile iron/gold; no animals. Iron condition: one adjacent participant. Iron reward: +1 score/+10 energy. Gold condition: two different participants, any two sides, 3-tick window. Gold reward: +8 score/+40 energy each."
    ]
    result = briefings[index] & "\n" & "The world maintains 18 iron and 8 gold nodes, respawning on a 60-tick cadence."
  of "lbf":
    let briefings = [
      "Food has levels 1..6, and participants have levels 1..4. Collect food when the sum of levels of cardinally adjacent participants reaches the food level. The total score reward is twice the food level, split among participants.",
      "Combine adjacent participants' levels to meet or exceed a food item's level. Participant levels range from 1 to 4; food levels from 1 to 6. A successful collection splits a total score of twice the food level.",
      "Level rules:\n1. Participants have levels 1..4; food has levels 1..6.\n2. Sum the levels of cardinally adjacent participants.\n3. Collect when that sum meets or exceeds the food level.\n4. Split a total score of twice the food level among participants.",
      "What makes food collectible? The sum of cardinally adjacent participant levels must reach its level. What levels exist? Participants 1..4, food 1..6. What scores? Twice the food level in total, shared among participants.",
      "Share a total score of twice the food level when collecting. Collection succeeds only when cardinally adjacent participants' levels sum to at least the food level. Participants have levels 1..4, food 1..6.",
      "Foraging briefing: assemble enough level strength on cardinal sides of food. Participants have levels 1..4 and food levels 1..6; adjacent levels must sum to at least the food level. Successful participants split total score equal to twice that level.",
      "Foraging reference: participant levels 1..4; food levels 1..6. Collection threshold: cardinally adjacent levels sum to at least food level. Total score: twice food level, split among participants."
    ]
    result = briefings[index] & "\n" & "Each participant gets the integer floor of the score share; the lowest slot receives the remainder. Energy reward is 20 times food level, paid in full to every participant."
  of "predator-prey":
    let briefings = [
      "There are no animals. Three participants hunt and three forage; roles swap every round. Follow your current role in the observation. Two hunters on opposite cardinal sides tag a forager for +6 score each. Foragers collect berries for +1 score and +12 energy.",
      "Check your current role: three hunters face three foragers, and roles swap each round. There are no animals. Hunters tag a forager by taking opposite cardinal sides in a pair, earning +6 score each. Foragers gain +1 score and +12 energy by collecting berries.",
      "Role rules:\n1. Three participants hunt and three forage, swapping each round; your observation names your current role.\n2. No animals occur.\n3. Two hunters on opposite cardinal sides tag a forager for +6 score each.\n4. Foragers collect berries for +1 score and +12 energy.",
      "Who are you this round? Check your observation: three participants hunt and three forage, swapping roles each round. Are there animals? No. How do hunters score? Two on opposite cardinal sides tag a forager for +6 each. How do foragers score? Berries give +1 score and +12 energy.",
      "Foragers earn +1 score and +12 energy from berries. Hunters earn +6 each by pairing on opposite cardinal sides of a forager to tag it. Three participants have each role; roles swap every round. Read your current role in the observation. This mode has no animals.",
      "Role briefing: consult your observation. Three participants hunt while three forage, with roles swapped every round and no animals. Hunters coordinate opposite cardinal sides around a forager to tag it, earning +6 each. Foragers collect berries for +1 score and +12 energy.",
      "Predator-prey reference: three hunters, three foragers; roles alternate each round and current role appears in your observation. No animals. Tag condition: two hunters on opposite cardinal sides of a forager. Tag reward: +6 each. Berry reward for forager: +1 score/+12 energy."
    ]
    result = briefings[index] & "\n" & "A tagged forager loses 30 energy, no score, and respawns after 24 ticks near the map edge. Berries regrow after 90 ticks. Tall grass hides a forager from hunters farther than Chebyshev distance 2."
  else: raise newException(ValueError, "unknown hunting variant: " & variant)
  if variant != "staghunt" or selection.selectedVariant != pvCanonical:
    result.add("\nYou give one high-level plan; a controller walks you there tile by tile until your next plan.")
