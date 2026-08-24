# Cooperative Hunting

**Six hunters share a 32×32 tile forest and take animals by standing on the
right cardinal sides of them at the same moment.** A rabbit falls to one
hunter. A boar needs two hunters on perpendicular sides, a stag two on
opposite sides, a moose any three, an elephant all four. Everyone who was on a
side when the animal fell scores the full value.

That is the whole game, and it is the assurance problem in a forest: rabbits
are a guaranteed +1, an elephant is +18 *each* — but only if four hunters
commit to the same animal on the same tick. A half-formed ring gets trampled
(−30 energy) or gored (−10 energy and a shove) and scores nothing.

Live at [softmax.com/cooperative-hunting](https://softmax.com/cooperative-hunting).

## The four variants

All four are the same simulation with a different capture predicate and a
little per-variant furniture. `num_agents` is **6** in every one.

| id | rounds × ticks | what is different |
| --- | --- | --- |
| `staghunt` | 3 × 960 | the base forest |
| `coop-mining` | 3 × 960 | no animals; iron is solo income, gold needs two hunters within a 3-tick window |
| `lbf` | 3 × 960 | hunters and food carry levels; adjacent levels must sum to the food's level; the reward is split |
| `predator-prey` | 4 × 720 | three seats hunt and three forage, swapping every round; tall grass hides a forager from a distant hunter |

Full rules: [`docs/plans/2026-08-24-cooperative-hunting-design.md`](docs/plans/2026-08-24-cooperative-hunting-design.md)
and the `game.docs` pages in `coworld_manifest_template.json`
(`rules.md`, `variants.md`, `protocol.md`, `policies.md`).

## Policies: one image, switched by env

Both entry points are the same image and the same binary,
`/bin/cooperative-hunting-player`:

```bash
# an LLM prompt policy
PLAYER_PROMPT="Commit to the biggest animal your visible party can take." \
USE_BEDROCK=true /bin/cooperative-hunting-player

# a compiled baseline
PLAYER_SCRIPTED=big_game_hunter /bin/cooperative-hunting-player
```

A prompt seat registers its prompt with the game over the additive `0x90`
message. Every 120 ticks (15 s at 8 Hz) the game composes one observation per
prompt seat — from exactly that seat's visibility set — and issues **all**
prompt seats' requests as one parallel batch, because decisions in this game
are simultaneous. Each seat gets a plan back over `0x91` and its executor
walks the hunter to the named side tile by tile. An unusable reply is retried
once and then falls back to `PLAYER_FALLBACK_SCRIPTED` (default
`big_game_hunter`). With no credentials at all the client disables itself and
makes zero network calls; the episode still completes.

The eight baselines are `rabbiteer`, `nearest_hunter`, `stag_hunter`,
`moose_hunter`, `elephant_hunter`, `big_game_hunter`, `sidekick`, `modeler` —
[`Metta-AI/coworld-staghunt`](https://github.com/Metta-AI/coworld-staghunt)'s
eight bots, restructured from eight binaries into one dispatch.

In-game every seat is `Cog-A` … `Cog-F`, assigned by a seeded permutation.
Real policy names exist only spectator-side: the replay's `seats[].name`, the
viewer chrome and `results.names[]`.

## Layout

| path | what |
| --- | --- |
| `src/cooperative_hunting/sim_types.nim` | consts, types, `GameConfig`, `runeCap` |
| `src/cooperative_hunting/sim.nim` | world gen, movement, animal AI, capture resolution. Pure |
| `src/cooperative_hunting/art.nim` | the pattern DSL, the PNG sprites, the sprite cache |
| `src/cooperative_hunting/frames.nim` | per-seat and global sprite_v1 frames, the chrome label |
| `src/cooperative_hunting/replay.nim` | the JSON replay writer and reader |
| `src/cooperative_hunting/llm.nim` | the transport ladder, the batch, the parse |
| `src/cooperative_hunting/baselines.nim` | the eight bots, one dispatch |
| `src/cooperative_hunting.nim` | the server: routes, roster, tick loop, results |
| `src/cooperative_hunting_player.nim` | the one policy binary |
| `replay-viewer/` | the static wasm bundle (paintbot's shell, our module) |
| `client/` | `chrome_common.js` and `broadcast_core.js` from `coworld-ctf`, plus the page |
| `tests/` | eight test files, each run twice by CI (debug and `-d:release`) |

`sprites/12px/*.png` are `coworld-staghunt`'s, byte-for-byte. Everything the
four variants add — iron and gold nodes, the gold countdown ring, berry
bushes, tall grass, level badges — is drawn with the starter's own
`patternToRgbaSprite` pattern DSL.

## Building and running

The image builds both binaries:

```bash
docker build --platform=linux/amd64 -t coworld-cooperative-hunting:ci .
tools/ci/docker_smoke.sh coworld-cooperative-hunting:ci
```

`tools/ci/docker_smoke.sh` runs one game container plus six player containers
on a per-run network from the certification fixture, and asserts the game
**and every player** exit 0.

Tests need Nim 2.2.4 and the `nimby.lock` package tree:

```bash
nimby use 2.2.4 && nimby --global sync nimby.lock
nim r --hints:off --path:src tests/test_capture.nim
```

The replay viewer is a static wasm bundle, never a pod:

```bash
tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
node tools/ci/viewer_smoke.mjs --bundle dist/static-replay-viewer \
  --replay dist/smoke/replay.json --timeout 90 --soak 10
```

`tools/build_manifest.py` regenerates `coworld_manifest_template.json` and
`tools/build_replay_page.py` regenerates `client/replay_broadcast.html` from a
`coworld-ctf` checkout, so both files' provenance stays diffable.

## Releasing

`.github/workflows/coworld-release.yml` (dispatch only) runs
build → certify → upload policies → `upload-coworld` → `secret put`, in that
order. `tools/ci/policies.json` mints two LLM champions and two scripted
fillers.

## Protocol

bitworld **sprite_v1** plus exactly two additive messages:

- `0x90` client→server registration, once on connect:
  `0x90 <u16 len> <UTF-8 JSON>` carrying
  `{"kind":"prompt","prompt":"…"}` or `{"kind":"scripted","baseline":"…"}`.
  A malformed body is treated as the `big_game_hunter` baseline, never a
  disconnect.
- `0x91` server→client plan, only to seats that registered a prompt, at most
  once per planning turn.

The `/global` stream is the same sprite_v1 at world scale plus the broadcast
chrome carried as the label of a reserved 1×1 sprite, id **4090**, which
`broadcast_core.js` routes to `onText`.

## License

MIT. See [`LICENSE`](LICENSE).
