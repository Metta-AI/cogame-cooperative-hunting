## End-to-end: a whole episode, in process, writing results.json and
## replay.json, settling with reason `complete` and exiting 0.

import std/[json, os]
import cooperative_hunting
import cooperative_hunting/sim

var failures = 0
proc check(label: string, condition: bool) =
  if not condition:
    echo "FAIL: ", label
    inc failures
  else:
    echo "ok: ", label

const Baselines = @[
  "big_game_hunter", "big_game_hunter", "sidekick", "modeler",
  "stag_hunter", "rabbiteer"
]

block completeEpisode:
  var config = defaultGameConfig()
  config.numAgents = 6
  config.rounds = 2
  config.ticksPerRound = 120
  config.players = @["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]
  let dir = getTempDir() / "ch-episode"
  removeDir(dir)
  let outcome = runEpisodeOffline(config, Baselines,
    dir / "results.json", dir / "replay.json")

  check("the episode settles with reason complete",
    outcome.reason == erComplete)
  check("results.json exists", fileExists(dir / "results.json"))
  check("replay.json exists", fileExists(dir / "replay.json"))

  let results = parseJson(readFile(dir / "results.json"))
  check("results carries one name per seat",
    results["names"].len == config.numAgents)
  check("results.reason is complete",
    results["reason"].getStr() == "complete")

  let replay = parseJson(readFile(dir / "replay.json"))
  # Every round is ticksPerRound of play plus a 40-tick round card, and the
  # replay records a frame for each.
  let expectedTicks =
    config.rounds * (config.ticksPerRound + RoundEndDisplayTicks)
  check("the replay records one tick per simulated tick, round cards included",
    replay["ticks"].len == expectedTicks)
  check("the recorded tick count matches what the runner reported",
    outcome.ticks == expectedTicks)
  check("the replay declares one round entry per round",
    replay["rounds"].len == config.rounds)
  check("the replay's final tick matches results.final_tick",
    replay["ticks"][^1]["t"].getInt() == results["final_tick"].getInt())

  var kinds: seq[string] = @[]
  for tick in replay["ticks"]:
    if tick.hasKey("ev"):
      for event in tick["ev"]:
        let name = event["ev"].getStr()
        if name notin kinds:
          kinds.add(name)
  check("the episode logs a round_start", "round_start" in kinds)
  check("the episode logs a player_spawn", "player_spawn" in kinds)
  check("the episode logs a round_end", "round_end" in kinds)
  check("the episode logs an episode_end", "episode_end" in kinds)
  const Vocabulary = [
    "round_start", "player_spawn", "prey_spawn", "catch", "mine", "pickup",
    "forage", "tag", "trample", "moose_gut", "plan", "fallback", "deadline",
    "round_end", "episode_end"
  ]
  check("the episode emits only events in the declared vocabulary",
    (block:
      var ok = true
      for name in kinds:
        if name notin Vocabulary:
          echo "  unexpected event: ", name
          ok = false
      ok))
  check("the party actually catches something",
    "catch" in kinds)

block everyVariantCompletes:
  ## All four variants run end to end on the scripted baselines with no
  ## credentials at all -- that fallback is load-bearing for offline
  ## certification.
  for variant in ["staghunt", "coop-mining", "lbf", "predator-prey"]:
    var config = defaultGameConfig()
    config.numAgents = 6
    config.variant = variant
    config.rounds = 2
    config.ticksPerRound = 90
    config.players = @["a", "b", "c", "d", "e", "f"]
    let dir = getTempDir() / ("ch-episode-" & variant)
    removeDir(dir)
    let outcome = runEpisodeOffline(config, Baselines,
      dir / "results.json", dir / "replay.json")
    check(variant & " settles with reason complete",
      outcome.reason == erComplete)
    let results = parseJson(readFile(dir / "results.json"))
    check(variant & " reports its own variant",
      results["variant"].getStr() == variant)
    check(variant & " writes a parseable replay",
      parseJson(readFile(dir / "replay.json"))["ticks"].len > 0)

if failures > 0:
  quit("test_episode: " & $failures & " failures", 1)
echo "test_episode: all checks passed"
