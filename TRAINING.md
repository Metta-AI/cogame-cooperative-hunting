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
