"""Full published episodes with six real players and a closed inference endpoint."""
import argparse
import hashlib
import json
import os
import socket
import subprocess
import time
from pathlib import Path


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("game", type=Path)
    parser.add_argument("player", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    manifest = json.loads((root / "coworld_manifest_template.json").read_text())
    variants = {entry["id"]: entry["game_config"] for entry in manifest["variants"]}
    cases = [(name, "canonical") for name in variants]
    cases += [("staghunt", wording) for wording in
              ("plain", "numbered", "questions", "reordered", "heldout-briefing", "heldout-reference", "mixed")]
    if args.smoke:
        cases = [("staghunt", "canonical"), ("predator-prey", "canonical")]
    args.output.mkdir(parents=True, exist_ok=False, mode=0o700)
    for variant, wording in cases:
        work = args.output / f"{variant}-{wording}"
        work.mkdir(mode=0o700)
        config = dict(variants[variant])
        config.update(seed=7, promptVariant=wording, promptSeed=4,
                      tokens=[f"t{seat}" for seat in range(6)],
                      players=[{"name": f"policy-{seat}"} for seat in range(6)])
        (work / "config.json").write_text(json.dumps(config))
        port, closed_port = free_port(), free_port()
        env = os.environ.copy()
        for key in ("ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY_URI", "AWS_BEARER_TOKEN_BEDROCK",
                    "AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "PLAYER_SCRIPTED"):
            env.pop(key, None)
        env.update(COGAME_HOST="127.0.0.1", COGAME_PORT=str(port),
                   COGAME_CONFIG_URI=(work / "config.json").as_uri(),
                   COGAME_RESULTS_URI=(work / "results.json").as_uri(),
                   COGAME_SAVE_REPLAY_URI=(work / "replay.json").as_uri(),
                   COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{closed_port}",
                   COOPERATIVE_HUNTING_HOST_TRACE_PATH=str(work / "host.jsonl"),
                   COOPERATIVE_HUNTING_ATTEMPT_TRACE_DIR=str(work / "attempts"),
                   COOPERATIVE_HUNTING_SOURCE_REVISION="uncommitted-cooperative-hunting-validation")
        processes, logs = [], []
        try:
            log = (work / "game.log").open("w")
            logs.append(log)
            game = subprocess.Popen([str(args.game)], cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
            processes.append(game)
            for _ in range(200):
                assert game.poll() is None, work
                with socket.socket() as probe:
                    ready = probe.connect_ex(("127.0.0.1", port)) == 0
                if ready:
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError(f"host did not start: {work}")
            for seat in range(6):
                player_env = dict(env, COWORLD_PLAYER_WS_URL=f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
                                  PLAYER_PROMPT=f"PRIVATE-STRATEGY-{seat}: Coordinate with visible hunters.")
                log = (work / f"player-{seat}.log").open("w")
                logs.append(log)
                processes.append(subprocess.Popen([str(args.player)], cwd=root, env=player_env,
                                                   stdout=log, stderr=subprocess.STDOUT))
            assert game.wait(timeout=manifest["episode_timeout_minutes"] * 60 + 30) == 0
            for player in processes[1:]:
                assert player.wait(timeout=15) == 0
            results = json.loads((work / "results.json").read_text())
            expected_ticks = config["rounds"] * (config["ticksPerRound"] + 40)
            assert results["reason"] == "complete" and results["final_tick"] == expected_ticks
            with (work / "host.jsonl").open() as stream:
                records = [json.loads(line) for line in stream]
            assert records[0]["event_type"] == "episode_start"
            assert records[-1]["event_type"] == "episode_end" and records[-1]["results"] == results
            controls = [row for row in records if row["event_type"] == "controls"]
            assert len(controls) == expected_ticks
            for tick, row in enumerate(controls):
                assert row["start_tick"] == tick and row["end_tick"] == tick + 1
                assert len(row["input_masks"]) == 6 and row["tick_hz"] == config["tickHz"]
                if row["phase"] == "card":
                    assert row["input_masks"] == [0] * 6
            dispatch = {(row["turn"], seat["slot"]): seat for row in records
                        if row["event_type"] == "plan_dispatch" for seat in row["seats"]}
            starts = [json.loads(path.read_text()) for path in (work / "attempts").glob("*-start.json")]
            finishes = {row["attempt_id"]: row for path in (work / "attempts").glob("*-finish.json")
                        for row in [json.loads(path.read_text())]}
            assert starts and len(starts) == len(finishes) == results["llm_requests"]
            for start in starts:
                finish = finishes[start["attempt_id"]]
                assert finish["transport_error"] and not finish["parse_ok"]
                assert finish["platform_call_id"] is None and finish["behavior_logprobs"] is None
                seat = dispatch[(start["turn"], start["slot"])]
                system, user = (message["content"] for message in start["prompt"])
                assert system == seat["system"]
                assert user.startswith(seat["user"])
                assert start["request"]["system"] == system
                assert start["request"]["messages"][0]["content"] == user
                assert all(f"PRIVATE-STRATEGY-{other}" not in system for other in range(6) if other != start["slot"])
                metadata = start["prompt_template"]
                assert metadata["variant"] == ("reordered" if wording == "mixed" else wording)
                for role, text in (("system", system), ("user", user)):
                    assert metadata[f"{role}_sha256"].lower() == hashlib.sha256(text.encode()).hexdigest()
            plans = [row for row in records if row["event_type"] == "host_plan"]
            assert plans and all(row["source"].startswith("fallback:") for row in plans)
            assert sum(results["fallbacks"]) == len(plans)
            assert all(row["selected_attempt_id"] is None for row in plans)
            assert {identity for row in plans for identity in row["attempt_ids"]} == set(finishes)
            sends = [row for row in records if row["event_type"] == "plan_send_queued"]
            assert sends and all(row["player_acknowledgement"] is None for row in sends)
            public = (work / "replay.json").read_text()
            assert "PRIVATE-STRATEGY-" not in public and "prompt_template" not in public
            assert (work / "host.jsonl").stat().st_mode & 0o777 == 0o600
            print(work.name, expected_ticks, "ticks;", len(starts), "actual attempts;",
                  len(plans), "fallback plans; six real players PASS", flush=True)
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
            for log in logs:
                log.close()


if __name__ == "__main__":
    main()
