# Prompt variants and complete plan episodes

Hosted configuration accepts five training wordings: canonical, plain, numbered,
questions, and reordered. Mixed selection requires an explicit nonnegative
promptSeed and chooses seed modulo five. Heldout-briefing and heldout-reference
are evaluation-only. Selection stays fixed for the episode and uses no simulation
randomness. The canonical staghunt prompt preserves the original text. Mining, level-based
foraging, and predator-prey now describe their own capture and reward rules
instead of the old animal-encirclement instructions. Each mode has five training
briefings and two evaluation briefings with the same facts.

The full-plan text bridge accepts a manifest and published variant:

    nim c -d:release --path:src -o:/tmp/hunting-text tools/text_bridge.nim

All six actions are parsed against frozen planning observations. The real
simulator, sprite observations, plan parser, and bundled player controllers then
execute the published episode. Private notes and full plan fields remain
available. The numeric movement-mask bridge is unchanged.

This synchronous bridge does not reproduce native inference latency, retries,
rate budgets, or late plan delivery. Native socket episodes must validate those
paths separately. Neither scripted outcomes nor imitation loss demonstrate
learned robustness.

The source exporter requires a clean committed checkout:

    nim c -d:release --path:src -o:/tmp/hunting-export tools/export_posttrain.nim
    /tmp/hunting-export OUTPUT 10 1 staghunt mixed 4

It preserves the original train.jsonl, validation.jsonl, and manifest.json format.
The exporter and text bridge share the real simulator/controller runtime. Mixed
exports cycle the five training wordings separately within each split. This
prevents every-fifth-seed validation from excluding a training wording.
Episode IDs include the requested selection, resolved wording, and prompt seed
so matched exports remain distinct. Scenario seed families stay unchanged.
The nearest-legal-plan teacher is a deterministic fixture, not an expert policy.

Keep every wording, variant, and seat from one scenario seed in the same split.
Seeds divisible by five enter validation; other seeds enter training. Held-out
wordings are rejected by training exports and training resets.

For matched model experiments, hold scenario seeds, seat assignments, other
policies, and inference budgets fixed. Report valid plans, retries, fallbacks,
skipped turns, incomplete games, captures, scores, and actual control intervals.

Run `python tools/test_prompt_variants.py TEXT_BRIDGE` for full published
episodes across every mode and wording. Run the existing
`tools/test_export_posttrain.py` against the exporter for complete mixed corpora.
These checks cover private observations, normalized plans, and scripted outcome
parity. They do not reproduce asynchronous native inference timing.

## Native private trajectories

The native server supports `COGAME_SAVE_TRAJECTORY_URI`, separately from public
results and replay destinations. Set `COWORLD_EPISODE_ID`,
`COWORLD_GAME_VERSION`, and `COWORLD_SOURCE_REVISION` to the exact execution
identity. Missing identity fails capture rather than inventing source pins.
Local files use exclusive creation with mode 0600. Private observations, notes,
requests and responses never enter the public replay or player protocol.

Each dispatched prompt seat retains its frozen visible observation and prompt
selection, every native request body, decoded prompt, returned body bytes in
base64, received HTTP headers/status, provider and platform call IDs when
actually returned, usage and stop reason. `response_headers_b64` stays null:
the pinned HTTP library exposes parsed headers, not the original header block.
`latency_ms` is the parallel batch wall time, an upper bound per response.
A retry retains its actual added retry instruction. The engine independently
parses responses against the dispatch-time legal targets and aliases. Supplied
fields changed by the permissive native parser are retained as rejected targets.
No fixture or scripted fallback gains teacher authority.

A target requires a successful existing 0x91 send and subsequent physical
execution. The private `execution` interval records the exact u8 masks consumed
by the simulation, with zero masks during frozen round cards. These controls
include the native controller's capture, energy and fallback priorities; they
do not establish that a model plan caused a particular score, nor constitute a
player acknowledgement. Final in-flight calls are joined and retained without
installing a late plan or changing settled public outcomes. Unexecuted plans,
transport failures, retries, fallbacks and failed artifact writes remain
non-target evidence. A deadline is truncated, never completed. Process death
before sealing produces no complete private artifact and cannot qualify.

Native seed families hash the actual initial 32x32 terrain array, using
`cooperative-hunting-forest-v1`. The same physical forest stays together across
policy names, alias assignments, wording, roles and game variants. Private audit
metadata retains variant rules, role/player setup, tall grass, RNG state and
clocks. This deliberately conservative grouping avoids splitting the same map;
it does not by itself prove all held-out independence. Historical synchronous
fixture exports keep their original seed-based format and are not native
receipt-bound evidence. Do not infer physical held-out independence from those
old seed labels or treat the nearest-target fixture as an authorized teacher.

Build both native binaries with the production flags and run the system check:

```sh
nim c -d:release -d:useMalloc --opt:speed --stackTrace:on --path:src \
  --out:/tmp/hunting-game src/cooperative_hunting.nim
nim c -d:release -d:useMalloc --opt:speed --stackTrace:on --path:src \
  --out:/tmp/hunting-player src/cooperative_hunting_player.nim
python3 tools/test_native_capture_system.py --game /tmp/hunting-game \
  --player /tmp/hunting-player --out /tmp/hunting-native-proof --families
```

An optional `--before ORIGINAL_GAME_BINARY` records the original server's lack
of private trajectories while checking its complete public runtime. The check
uses a loopback-only HTTP fixture, six real native player processes, published
round/tick counts and an accelerated clock. It covers positive plans, malformed
reply plus retry, 429 fallback, no credentials, normalized targets, terminal
late replies, failed output, absent players, deadlines, all four variants and physical family invariance.
It never calls a real provider. Accelerated local timing does not qualify normal
hosted latency. For two ordinary 8 Hz episodes with one prompt seat and five
scripted peers, reserve at most 96 native attempts (24 turns per game, two
attempts per turn). Report actual spend and requests, complete games, valid and
normalized plans, retries, fallbacks, skipped turns, target-none frequency,
physical control coverage, per-seat scores/catches/co-captures and disconnects.
Teacher strength, coordination and learned improvement still require separate
matched evaluation; passing this transport check does not establish them.
