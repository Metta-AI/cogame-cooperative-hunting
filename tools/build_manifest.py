#!/usr/bin/env python3
"""Emit coworld_manifest_template.json.

Kept as a script because the manifest is long, highly repetitive across four
variants, and every array property must carry minItems/maxItems (tandem 0.1.0).
Run: python3 tools/build_manifest.py > coworld_manifest_template.json
"""
import json
import sys

SEATS = 6
IMAGE = "{{COOPERATIVE_HUNTING_IMAGE}}"
REPO = "https://github.com/Metta-AI/cogame-cooperative-hunting/tree/main"

PLAYER_NAMES = ["Cog-A", "Cog-B", "Cog-C", "Cog-D", "Cog-E", "Cog-F"]


def players(names=None):
    return [{"name": n} for n in (names or PLAYER_NAMES)]


README = """# Cooperative Hunting

**Six hunters share a 32x32 tile forest and take animals by standing on the
right cardinal sides of them at the same moment.** A rabbit falls to one
hunter. A boar needs two hunters on perpendicular sides, a stag two on
opposite sides, a moose any three, an elephant all four. Everyone who was on
a side when the animal fell scores the full value.

That is the whole game, and it is the assurance problem in a forest: rabbits
are a guaranteed +1, an elephant is +18 *each* -- but only if four hunters
commit to the same animal on the same tick. A half-formed ring gets trampled
(-30 energy) or gored (-10 energy and a shove) and scores nothing.

## Variants

| id | rounds x ticks | what is different |
| --- | --- | --- |
| `staghunt` | 3 x 960 | the base world |
| `coop-mining` | 3 x 960 | no animals; iron is solo, gold needs two hunters within a 3-tick window |
| `lbf` | 3 x 960 | hunters and food carry levels; adjacent levels must sum to the food's level; reward is split |
| `predator-prey` | 4 x 720 | three seats hunt, three forage; roles alternate each round; tall grass hides foragers |

## Scoring

`results.scores[slot]` is the sum over rounds of everything that seat's
captures were worth. Higher is better and no term is ever negative -- trample
and gore cost energy, never score. The league ranks by that number.

## Policies

Both champion policies are prompts. A seat registers either a `PLAYER_PROMPT`
(the game composes an observation every 15 s, asks the model what animal to
commit to and from which side, and a controller walks the hunter there tile by
tile) or a `PLAYER_SCRIPTED=<name>` baseline (one of eight compiled hunters
shipped in the same image). Same image, same entrypoint, switched by env.

## FAQ

**How do I connect a player?** Read `COWORLD_PLAYER_WS_URL` from the
environment and speak the sprite_v1 player protocol; see
`game.protocols.player` and the protocol page.

**When does my player exit?** When the episode ends and the game closes the
connection. Catch the error on a dead socket and exit 0.
"""

RULES = """# Cooperative Hunting Rules

Six hunters share a 32x32 tile forest (12 px tiles). The border ring is rock;
11 % of the interior is obstacles, half tree and half rock, with a 7x7 block
at the centre and six random 3x3 blocks cleared. The map is generated once per
episode from `seed`; each round re-rolls the animals with `seed + roundIndex`
but keeps the same map.

## Hunters

Start at a free tile within 4 tiles of the centre with `energy = 120` and
`score = 0`. Energy caps at 200; passive recharge is +1 every 18 ticks but
only up to 100. Moving costs 2 energy and sets a 5-tick move cooldown. A
hunter with fewer than 2 energy cannot move. There is no elimination and no
negative score.

## Capture

| animal | hunters needed | sides | score | energy |
| --- | --- | --- | --- | --- |
| rabbit | 1 | any one side | 1 | 15 |
| boar | 2 | two perpendicular sides | 3 | 90 |
| stag | 2 | two opposite sides | 5 | 60 |
| moose | 3 | any three sides | 10 | 140 |
| elephant | 4 | all four sides | 18 | 220 |

The reward is paid **in full to every participant** (except in `lbf`, where
score is split). A capture leaves a corpse for 48 ticks and puts a 20-tick
yellow kill glow on the killers.

## Animals

Populations are maintained per kind, and a kind only spawns once the connected
seat count is at least its coalition size: rabbits 12, boars 6, stags 6, moose
3, elephants 2. Spawns are 60 ticks apart, dropping to 3 while a population is
four or more below target.

Animals flee within Chebyshev distance 3, at 75/50/25 % by distance, scaled per
kind. A moose cardinally adjacent to a hunter gores it 30 % of the time (5 %
diagonally): -10 energy and a one-tile shove. An elephant that steps onto a
hunter tramples it for -30 energy and slides two tiles through -- and if the
far tile is blocked it stays put, which is exactly why a complete four-side
ring can hold one.

## Turn order

Each tick, in this order: ingest input; distribute plans; hunter phase in slot
order; animal phase in prey order; stamp occupied sides; resolve captures;
resolve tags and forages (`predator-prey`); housekeeping; emit frames; round
bookkeeping; deadline guard.

## Ending

`results.reason` is one of exactly three values: `complete` (all rounds ran),
`deadline` (the wall-clock guard fired; the current round is scored as it
stands and the episode settles), or `no_players` (nobody connected inside the
connect timeout; all-zero scores). The game always exits 0.
"""

VARIANTS_DOC = """# Variants

All four variants are the same simulation with a different capture predicate
and a little per-variant furniture. `num_agents` is 6 in every one.

## `staghunt` -- 3 rounds x 960 ticks

The base world, unchanged. Capture rule `sides`.

## `coop-mining` -- 3 rounds x 960 ticks

No animals. 18 iron nodes and 8 gold nodes, immobile, respawning on the same
60-tick cadence at random free tiles.

- **Iron:** one adjacent hunter on any side -> +1 score / +10 energy.
- **Gold:** two *different* hunters on any two sides **within a 3-tick
  window** -> +8 score / +40 energy each.

The window is the only new mechanic: the sim stamps `sideSeen[side] = (tick,
slot)` and a side counts as occupied while `tick - sideSeen.tick <=
windowTicks - 1`. `windowTicks = 1` reproduces base staghunt exactly, so the
base game runs through the same code path.

## `lbf` -- Level-Based Foraging, 3 rounds x 960 ticks

Each seat gets `level = 1 + (slot mod 4)`, drawn as a digit over its head.
Food items carry `level` 1..6, drawn the same way, with 14 items maintained.
A pickup succeeds when the sum of the levels of the hunters cardinally
adjacent to the food is at least the food's level.

Reward: `score = 2 x level`, `energy = 20 x level`. Score is **split**: each
participant gets `floor(score / n)` and the integer remainder goes to the
participant with the lowest slot. Energy is not split.

## `predator-prey` -- 4 rounds x 720 ticks

No animals. Seats split by role each round:
`role = hunter if (slot + roundIndex) mod 2 == 0 else forager`. With six seats
and four rounds every seat hunts twice and forages twice, so the asymmetry
cancels in the ranking.

40 berry tiles and 120 tall-grass tiles are placed from the seed. A forager
standing on a berry tile consumes it at end of tick (+1 score, +12 energy;
the tile regrows after 90 ticks). Two hunters on opposite cardinal sides of a
forager tag it: +6 score each, the forager loses 30 energy and respawns 24
ticks later near the map edge.

**Tall grass hides foragers:** a forager on a tall-grass tile is not drawn in
a hunter's per-seat frame unless that hunter is within Chebyshev distance 2.
It is always in the global/replay stream, and the viewer carries a grass
opacity toggle -- the spectator sees the ambush the hunter could not.
"""

PROTOCOL = """# Protocol

## Player protocol

Base: **bitworld sprite_v1**, unchanged.

Server -> client messages: `0x01` sprite, `0x02` object, `0x03` remove,
`0x04` clear, `0x05` viewport, `0x06` layer, `0x07` identity.

Client -> server: the 2-byte input packet `[0x84, mask]` (`0x00` is also
accepted for the bitscreen_v1 header). Mask bits: 0 up, 1 down, 2 left,
3 right, 4 A, 5 B, 6 select. At most one direction bit should be set; the
server reads them with priority up > down > left > right.

Two additive messages, and only two:

### `0x90` client -> server, registration

Sent once immediately after connect.

```
0x90  <u16 len little-endian>  <len bytes UTF-8 JSON>     len <= 4096
```

Body is either

```json
{"kind": "prompt", "prompt": "<= 1200 runes"}
```

or

```json
{"kind": "scripted", "baseline": "big_game_hunter"}
```

A malformed, oversized or non-UTF-8 body is dropped and the seat is treated as
`{"kind":"scripted","baseline":"big_game_hunter"}`. It is never a disconnect.

### `0x91` server -> client, plan

Sent **only** to seats that registered `kind: "prompt"`, at most once per
planning turn (every 120 ticks).

```
0x91  <u16 len little-endian>  <len bytes UTF-8 JSON>
```

```json
{"turn": 7, "intent": "hunt", "target": "stag@13,17", "side": "S",
 "with": ["Cog-A"], "say": "...", "src": "llm"}
```

`src` is `llm` or `fallback:<cause>`. Scripted seats never receive it, because
the bundled bots' parsers reject unknown message types.

## Global protocol

The same sprite_v1 stream at world scale (384x384 px viewport, no identity
packet), plus the broadcast chrome smuggled as the **label of a reserved 1x1
sprite, id 4090**, re-emitted every tick. The body is UTF-8 JSON of at most
4 KB carrying `tick`, `round`, `rounds`, `ticksPerRound`, `phase`, `variant`,
`reason`, `seats[]`, `feed[]`, `beats[]` and `final`.
"""

POLICIES = """# Fielding a policy

Both entry points are the **same image** and the **same binary**,
`/bin/cooperative-hunting-player`, switched by one environment variable.

## `PLAYER_PROMPT` -- an LLM policy

Set `PLAYER_PROMPT` to your strategy in plain words (up to 1200 runes) and
`USE_BEDROCK=true`. The player registers the prompt with the game; the game
composes one observation per prompt seat every 120 ticks (15 s), issues all
prompt seats' requests as one parallel batch, and hands each seat back a plan.
The player's executor walks the hunter to the named side tile by tile until
the next plan.

The model must reply with a single JSON object beginning with `{`:

| field | type | cap | rule |
| --- | --- | --- | --- |
| `intent` | enum | 12 chars | `hunt,assist,forage,rest,regroup,flee`; anything else becomes `hunt` |
| `target` | string | 24 chars | must be in `LEGAL TARGETS` or `none`, else the reply is retried once |
| `side` | enum | 3 chars | `N,S,E,W,any`; anything else becomes `any` |
| `with` | string array | <= 3 items, 8 chars each | non-alias entries dropped |
| `say` | free text | <= 120 runes | broadcast to spectators |
| `note` | free text | <= 200 runes | private, handed back next turn |

Every free-text field is truncated on **rune** boundaries.

An unusable reply is retried exactly once with a hint; if that also fails the
seat plays `PLAYER_FALLBACK_SCRIPTED` (default `big_game_hunter`) for that
planning window and a `fallback` event is written with its cause. With no
credentials at all the client disables itself at startup and makes zero
network calls -- the episode still completes with `reason: complete`.

## `PLAYER_SCRIPTED` -- a compiled baseline

Set `PLAYER_SCRIPTED` to one of `rabbiteer`, `nearest_hunter`, `stag_hunter`,
`moose_hunter`, `elephant_hunter`, `big_game_hunter`, `sidekick`, `modeler`.
The seat never touches the LLM.

## Anonymity

In-game every seat is `Cog-A` .. `Cog-F`, assigned by a seeded permutation of
slots. Aliases are the only identifiers in prompts, plans, `with[]` and `say`
lines. Real policy names exist only spectator-side: the replay's
`seats[].name`, the viewer chrome and `results.names[]`.
"""

PLAYER_PROMPT_DEFAULT = (
    "Commit to the biggest animal your visible party can actually take. "
    "Name the allies you need in \"with\" and take the side you name in "
    "\"side\"; do not switch targets while a ring is forming. Take a rabbit "
    "only when nobody is close enough to help. If your energy is under 30, "
    "rest until it is back over 60."
)

BUNDLED = [
    {
        "id": "pack-caller",
        "type": "player",
        "name": "Pack Caller",
        "description": (
            "The reference prompt policy: an LLM decides which animal to "
            "commit to, from which side and with whom every 15 s, and a "
            "controller walks the hunter there tile by tile."
        ),
        "image": IMAGE,
        "run": ["/bin/cooperative-hunting-player"],
        "env": {"PLAYER_PROMPT": PLAYER_PROMPT_DEFAULT},
        "source_url": REPO,
    },
    {
        "id": "big-game-hunter",
        "type": "player",
        "name": "Big Game Hunter",
        "description": (
            "Coalition-aware baseline: counts nearby allies, derives which "
            "animals are catchable at that coalition size, and picks the "
            "highest-reward catchable animal, distance-penalised."
        ),
        "image": IMAGE,
        "run": ["/bin/cooperative-hunting-player"],
        "env": {"PLAYER_SCRIPTED": "big_game_hunter"},
        "source_url": REPO,
    },
    {
        "id": "sidekick",
        "type": "player",
        "name": "Sidekick",
        "description": (
            "Follows the nearest ally and takes the complementary flank of "
            "whatever that ally is standing next to."
        ),
        "image": IMAGE,
        "run": ["/bin/cooperative-hunting-player"],
        "env": {"PLAYER_SCRIPTED": "sidekick"},
        "source_url": REPO,
    },
    {
        "id": "modeler",
        "type": "player",
        "name": "Modeler",
        "description": (
            "Expected-value bot: scores every animal by reward x learned "
            "per-ally cooperation probability x distance penalty."
        ),
        "image": IMAGE,
        "run": ["/bin/cooperative-hunting-player"],
        "env": {"PLAYER_SCRIPTED": "modeler"},
        "source_url": REPO,
    },
]

VARIANTS = [
    (
        "staghunt",
        "Stag Hunt",
        "The base forest: rabbits solo, boars and stags in pairs, moose in "
        "threes, elephants only with all four sides held at once. Three "
        "rounds of 960 ticks.",
        {"variant": "staghunt", "rounds": 3, "ticksPerRound": 960, "seed": 5743127},
    ),
    (
        "coop-mining",
        "Cooperative Mining",
        "No animals: 18 iron nodes are solo income and 8 gold nodes pay +8 "
        "each, but only when two different hunters touch two sides inside a "
        "three-tick window. Three rounds of 960 ticks.",
        {"variant": "coop-mining", "rounds": 3, "ticksPerRound": 960, "seed": 5743128},
    ),
    (
        "lbf",
        "Level-Based Foraging",
        "Hunters and food carry levels; a pickup lands when the adjacent "
        "hunters' levels sum to at least the food's level, and the reward is "
        "split between them. Three rounds of 960 ticks.",
        {"variant": "lbf", "rounds": 3, "ticksPerRound": 960, "seed": 5743129},
    ),
    (
        "predator-prey",
        "Predator & Prey",
        "Three seats hunt and three forage, swapping roles every round; tall "
        "grass hides a forager from a hunter more than two tiles away. Four "
        "rounds of 720 ticks.",
        {"variant": "predator-prey", "rounds": 4, "ticksPerRound": 720, "seed": 5743130},
    ),
]


def variant_config(extra):
    config = {
        "players": players(),
        "num_agents": SEATS,
        "tickHz": 8,
    }
    config.update(extra)
    return config


CONFIG_SCHEMA = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "additionalProperties": False,
    "required": ["tokens", "players", "num_agents"],
    "properties": {
        "tokens": {
            "description": "One connection token per seat, injected by the runner and indexed by slot.",
            "type": "array",
            "minItems": SEATS,
            "maxItems": SEATS,
            "items": {"type": "string", "minLength": 0},
        },
        "players": {
            "description": "One display-name object per seat, indexed by slot. Display names are spectator-side only; hunters see Cog-A..Cog-F.",
            "type": "array",
            "minItems": SEATS,
            "maxItems": SEATS,
            "items": {
                "type": "object",
                "additionalProperties": False,
                "required": ["name"],
                "properties": {"name": {"type": "string", "minLength": 1}},
            },
        },
        "num_agents": {
            "description": "Hunter seats. Pinned to 6: four is the largest coalition the world requires and the two spare seats are what keep the assurance tension alive.",
            "type": "integer",
            "minimum": SEATS,
            "maximum": SEATS,
            "default": SEATS,
        },
        "seed": {
            "description": "Pins the map, the animal spawns, the seat alias permutation and every AI roll. Round n re-rolls with seed + n.",
            "type": "integer",
            "minimum": 0,
            "default": 5743127,
        },
        "variant": {
            "description": "Which capture rule and furniture set the round uses.",
            "type": "string",
            "enum": ["staghunt", "coop-mining", "lbf", "predator-prey"],
            "default": "staghunt",
        },
        "rounds": {
            "description": "Rounds per episode. Each is followed by a 40-tick round card.",
            "type": "integer",
            "minimum": 1,
            "maximum": 8,
            "default": 3,
        },
        "ticksPerRound": {
            "description": "Simulation ticks of play in each round, before the round card.",
            "type": "integer",
            "minimum": 60,
            "maximum": 4800,
            "default": 960,
        },
        "tickHz": {
            "description": "Simulation ticks per second of wall clock. Every balance constant is in ticks, so this only changes how fast the episode plays out.",
            "type": "integer",
            "minimum": 1,
            "maximum": 60,
            "default": 8,
        },
        "planIntervalTicks": {
            "description": "Ticks between LLM planning turns; all prompt seats are asked as one parallel batch.",
            "type": "integer",
            "minimum": 8,
            "maximum": 2400,
            "default": 120,
        },
        "planTimeoutSeconds": {
            "description": "Deadline for one planning batch. The simulation never waits on it: hunters keep executing their previous plan.",
            "type": "integer",
            "minimum": 1,
            "maximum": 60,
            "default": 12,
        },
        "playBudgetSeconds": {
            "description": "Wall-clock guard. Past it the episode settles immediately with reason 'deadline' and the scores as they stand.",
            "type": "integer",
            "minimum": 30,
            "maximum": 1200,
            "default": 660,
        },
        "player_connect_timeout_seconds": {
            "description": "Bounded wait for seats to connect before the episode starts anyway.",
            "type": "integer",
            "minimum": 1,
            "maximum": 600,
            "default": 120,
        },
        "maxOutputTokens": {
            "description": "Output token cap for one plan request. 400 truncates the reply before the JSON closes.",
            "type": "integer",
            "minimum": 128,
            "maximum": 4096,
            "default": 900,
        },
        "model": {
            "description": "Model id for the direct-Anthropic transport. The Bedrock sidecar picks from its own haiku-first candidate list instead.",
            "type": "string",
            "minLength": 1,
            "default": "claude-haiku-4-5",
        },
        "focus": {
            "description": "Local balance-iteration mode. 'elephant' spawns only elephants next to the party. Never set by a shipped variant.",
            "type": "string",
            "enum": ["", "elephant"],
            "default": "",
        },
    },
}


def int_array(desc):
    return {
        "description": desc,
        "type": "array",
        "minItems": SEATS,
        "maxItems": SEATS,
        "items": {"type": "integer"},
    }


def str_array(desc):
    return {
        "description": desc,
        "type": "array",
        "minItems": SEATS,
        "maxItems": SEATS,
        "items": {"type": "string"},
    }


RESULTS_SCHEMA = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "required": ["names", "aliases", "scores", "reason"],
    "properties": {
        "names": str_array("Real policy name per seat, in slot order."),
        "aliases": str_array("In-game alias per seat (Cog-A..Cog-F)."),
        "kinds": str_array("'prompt' or 'scripted' per seat."),
        "scores": int_array("Cumulative score per seat across all rounds. Higher is better; never negative."),
        "energy": int_array("Final energy per seat."),
        "fallbacks": int_array("Planning turns on which this seat fell back to its scripted baseline."),
        "disconnected": {
            "description": "Whether each seat's socket closed before the episode ended.",
            "type": "array",
            "minItems": SEATS,
            "maxItems": SEATS,
            "items": {"type": "boolean"},
        },
        "rounds": {
            "description": "Per-round score arrays, one array of num_agents integers per round.",
            "type": "array",
            "minItems": 1,
            "maxItems": 8,
            "items": int_array("Scores for one round."),
        },
        "catches": {
            "description": "Per seat, the [rabbit, boar, stag, moose, elephant] capture counts.",
            "type": "array",
            "minItems": SEATS,
            "maxItems": SEATS,
            "items": {
                "type": "array",
                "minItems": 5,
                "maxItems": 5,
                "items": {"type": "integer"},
            },
        },
        "co_captures": {
            "description": "num_agents x num_agents matrix of shared captures between seats.",
            "type": "array",
            "minItems": SEATS,
            "maxItems": SEATS,
            "items": int_array("Shared captures with each other seat."),
        },
        "llm_requests": {
            "description": "Total plan requests issued to the model during the episode.",
            "type": "integer",
            "minimum": 0,
        },
        "variant": {"description": "Variant that was played.", "type": "string"},
        "seed": {"description": "Seed the episode ran with.", "type": "integer"},
        "final_tick": {"description": "Tick the episode settled at.", "type": "integer"},
        "reason": {
            "description": "Why the episode ended.",
            "type": "string",
            "enum": ["complete", "deadline", "no_players"],
        },
    },
}


def text(value):
    return {"type": "text", "value": value}


manifest = {
    "$schema": "https://raw.githubusercontent.com/Metta-AI/coworld/main/src/coworld/coworld_manifest_schema.json",
    "tags": [
        "coordination",
        "multi-agent",
        "grid",
        "stag-hunt",
        "assurance-game",
        "real-time",
        "llm-driven",
        "six-player",
    ],
    "episode_timeout_minutes": 20,
    "game": {
        "name": "cooperative_hunting",
        "owner": "daveey@softmax.com",
        "description": (
            "Six hunters share a 32x32 tile forest. A rabbit falls to one "
            "hunter, a boar to two on perpendicular sides, a stag to two on "
            "opposite sides, a moose to any three and an elephant only to all "
            "four at once -- and everyone on a side when it falls scores the "
            "full value. Four variants turn the same capture predicate into "
            "cooperative mining, level-based foraging and an asymmetric "
            "predator-prey hunt."
        ),
        "runnable": {
            "type": "game",
            "image": IMAGE,
            "run": ["/bin/cooperative-hunting", "--address:0.0.0.0", "--port:8080"],
            "env": {
                "ANTHROPIC_API_KEY_URI": "secret://coworld/cooperative-hunting/anthropic_api_key"
            },
            "source_url": REPO,
        },
        "replay_viewer": {"bundle": "static-replay-viewer"},
        "config_schema": CONFIG_SCHEMA,
        "results_schema": RESULTS_SCHEMA,
        "protocols": {
            "player": text(
                "bitworld sprite_v1 over a websocket, plus exactly two "
                "additive messages. Server->client: 0x01 sprite, 0x02 object, "
                "0x03 remove, 0x04 clear, 0x05 viewport, 0x06 layer, 0x07 "
                "identity, and 0x91 <u16 len> <UTF-8 JSON plan> to seats that "
                "registered a prompt. Client->server: the 2-byte input packet "
                "[0x84, mask] (bit 0 up, 1 down, 2 left, 3 right, 4 A, 5 B, 6 "
                "select), and once on connect 0x90 <u16 len> <UTF-8 JSON> "
                "carrying either {\"kind\":\"prompt\",\"prompt\":\"...\"} or "
                "{\"kind\":\"scripted\",\"baseline\":\"...\"}. A malformed "
                "registration is treated as the big_game_hunter baseline, "
                "never as a disconnect. See the protocol doc page for byte "
                "layouts."
            ),
            "global": text(
                "The same sprite_v1 stream at world scale (384x384 px "
                "viewport, no 0x07 identity packet), plus the broadcast "
                "chrome carried as the label of a reserved 1x1 sprite, id "
                "4090, re-emitted every tick. That label is UTF-8 JSON of at "
                "most 4 KB with tick, round, rounds, ticksPerRound, phase, "
                "variant, reason, seats[], feed[], beats[] and final."
            ),
        },
        "docs": {
            "readme": text(README),
            "pages": [
                {"id": "rules.md", "title": "Cooperative Hunting Rules", "content": text(RULES)},
                {"id": "variants.md", "title": "The Four Variants", "content": text(VARIANTS_DOC)},
                {"id": "protocol.md", "title": "Player and Global Protocol", "content": text(PROTOCOL)},
                {"id": "policies.md", "title": "Fielding a Policy", "content": text(POLICIES)},
            ],
        },
    },
    "player": BUNDLED,
    "variants": [
        {
            "id": vid,
            "name": name,
            "description": desc,
            "game_config": variant_config(extra),
        }
        for vid, name, desc, extra in VARIANTS
    ],
    "certification": {
        "game_config": {
            "players": players(),
            "num_agents": SEATS,
            "variant": "staghunt",
            "rounds": 2,
            "ticksPerRound": 480,
            "tickHz": 8,
            "seed": 5743127,
        },
        "players": [
            {"player_id": "pack-caller"},
            {"player_id": "pack-caller"},
            {"player_id": "big-game-hunter"},
            {"player_id": "big-game-hunter"},
            {"player_id": "sidekick"},
            {"player_id": "modeler"},
        ],
    },
}

json.dump(manifest, sys.stdout, indent=2)
sys.stdout.write("\n")
