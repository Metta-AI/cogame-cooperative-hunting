# Prompt variants and complete plan episodes

Hosted configuration accepts five training wordings: canonical, plain, numbered,
questions, and reordered. Mixed selection requires an explicit nonnegative
promptSeed and chooses seed modulo five. Heldout-briefing and heldout-reference
are evaluation-only. Selection stays fixed for the episode and uses no simulation
randomness. The default canonical prompt preserves the original text.

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

It writes private trajectories.jsonl candidate evidence and a source manifest,
not train/validation labels. Records preserve proposed and normalized plans,
exact prompt hashes, applied input masks for every tick, final scores, and
unknown inference metadata. Frozen round cards carry zero applied controls.
The nearest-legal-plan teacher is a deterministic workflow fixture, not an
expert-policy claim.

Convert these records with the shared Coworld trajectory importer, then obtain
independent application review before training admission. Keep every wording,
variant, and seat from one scenario seed in the same split. Held-out wordings
are rejected by the training exporter and by training resets.

For matched model experiments, hold scenario seeds, seat assignments, other
policies, and inference budgets fixed. Report valid plans, retries, fallbacks,
skipped turns, incomplete games, captures, scores, and actual control intervals.

For native capture, set COOPERATIVE_HUNTING_HOST_TRACE_PATH to a fresh private
file and COOPERATIVE_HUNTING_SOURCE_REVISION to the checked source identity.
Set COOPERATIVE_HUNTING_ATTEMPT_TRACE_DIR to a fresh private directory for actual
request start/finish records. Retry records hash the actual augmented user prompt.
Budget skips create no inference records. Host records identify selected plans,
queued sends, every applied control tick, and the terminal result. A queued send
is not a player acknowledgement; acknowledgement remains unknown.

Private artifacts contain strategy text and notes. They are separate from the
public replay. Late responses and incomplete attempts must remain visible during
review rather than being relabeled as successful decisions.
