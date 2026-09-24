# Numeric training

The persistent bridge covers the four certified Cooperative Hunting variants:
`staghunt`, `coop-mining`, `lbf`, and `predator-prey`. It builds each seat's
actual Sprite v1 frame and parses it with the published `big_game_hunter`
player. The 1,835 numeric features encode the player's discovered terrain,
visible party and targets, position, energy, score, role, and round clock. The
structured training observation is also available as `semantic_view`. A learner
chooses one of the five legal button masks: idle, up, down, left, or right.
All six observations and scripted actions are frozen before each 8 Hz tick.

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/cooperative-hunting-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/cooperative-hunting-train-bridge
```

For Metta RL use `recipes.external.coworld_metta_rl.train`; for native
PufferLib use `recipes.external.coworld.train`. Pass
`[/tmp/cooperative-hunting-train-bridge,
/path/to/coworld_manifest_template.json, staghunt]`, choose any certified
variant, and set `players=6`. The bridge resolves game assets from the
manifest directory. Set `max_decisions=20000`: complete games require
17,274 seat decisions, including scripted opponents. Set a finite timestep
limit of at least 3,000 learner decisions to observe a terminal reward.

A seeded full `staghunt` episode using the bridge's scripted teacher returned
scores `[52, 53, 48, 33, 62, 33]`, exactly matching the source's
`runEpisodeOffline` with six `big_game_hunter` players and the same seed.
Full teacher and random episodes completed in all four variants.

# Metta post-training data

The hosted prompt player expects plans with a legal target and side. The
exporter uses the game's observation builder, plan parser, wire packet, and
player executor to record complete games from a nearest legal target teacher.
Each decision includes the seat's hosted system and user messages and the
parsed plan. The teacher chooses from the same visible legal target list the
prompt policy receives; its data measure a runnable training path, not league
strength.

```sh
nim c -d:release --path:src -o:/tmp/ch-export-posttrain tools/export_posttrain.nim
/tmp/ch-export-posttrain /tmp/ch-staghunt 10 1 staghunt
```

Replace the output path and final argument for another certified variant.
The exporter refuses to overwrite existing output and splits by game seed.
Train with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/ch-staghunt \
  --output /tmp/ch-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

Each local ten-game variant exported 1,152 train and 288 validation examples.
All examples fit a 4,096-token context. One CPU optimizer step reduced
four-example validation loss from 1.7379 to 1.7325 (Stag Hunt), 1.7359 to
1.7306 (Cooperative Mining), 1.7379 to 1.7325 (Level-Based Foraging), and
1.7284 to 1.7230 (Predator–Prey). This verifies training input and update;
it does not establish stronger league play.
