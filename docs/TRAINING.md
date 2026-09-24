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

The hosted prompt player expects a plan with a legal target and side. The
published scripted player emits button masks, not plans, so this bridge does
not claim a Metta post-training dataset for that prompt policy.
