"""Full native socket episodes against a loopback fixture (never a teacher).

Pass --before for the unchanged native server and --game for the candidate.
All artifacts, including failures, are retained in a new --out directory.
The accelerated clock checks complete native execution, not hosted latency.
"""

import argparse
import base64
import concurrent.futures
import hashlib
import http.server
import json
import os
import re
import socket
import subprocess
import threading
import time
import urllib.request
import uuid
from pathlib import Path


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def clean_env():
    # No ambient credential, proxy, endpoint or private-artifact URI can escape.
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(
            ("AWS_", "ANTHROPIC_", "BEDROCK_", "COWORLD_", "COGAME_", "PLAYER_")
        )
        and key.lower() not in {"http_proxy", "https_proxy", "all_proxy"}
    }
    env["NO_PROXY"] = "127.0.0.1,localhost"
    return env


class Fixture(http.server.ThreadingHTTPServer):
    def __init__(self, mode, destination):
        self.mode, self.calls = mode, []
        self.destination = destination
        super().__init__(("127.0.0.1", 0), Handler)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        assert self.path == "/v1/messages"
        assert self.client_address[0] == "127.0.0.1"
        assert "Authorization" not in self.headers and "x-api-key" not in self.headers
        body = self.rfile.read(int(self.headers["Content-Length"]))
        request = json.loads(body)
        user = request["messages"][0]["content"]
        assert self.headers["X-Coworld-Player-Slot"] == "0"
        # Select a visible native target solely to exercise real plan execution.
        targets = (
            re.search(r"^LEGAL TARGETS: (.*)$", user, re.MULTILINE).group(1).split(", ")
        )
        action = {
            "intent": "hunt",
            "target": next((item for item in targets if item != "none"), "none"),
            "side": "any",
            "with": [],
            "say": "local fixture",
            "note": "fixture private note",
        }
        if self.server.mode == "late":
            time.sleep(0.6)
        number = len(self.server.calls)
        if self.server.mode == "normalized":
            action["intent"] = "INVALID"
        malformed = self.server.mode == "malformed" and number == 0
        status = 429 if self.server.mode == "429" else 200
        text = "malformed: no JSON" if malformed else json.dumps(action)
        response = {
            "model": "local-fixture-no-teacher",
            "stop_reason": "end_turn",
            "content": [{"type": "text", "text": text}],
            "usage": {"input_tokens": 101, "output_tokens": 31},
        }
        if status == 429:
            response = {"error": {"message": "local fixture throttled"}}
        encoded = json.dumps(response).encode()
        identity = str(uuid.uuid4())
        call = {
            "request": request,
            "response_body_b64": base64.b64encode(encoded).decode(),
            "call_id": identity,
            "status": status,
            "action": action,
            "time": time.time(),
            "teacher_authorized": False,
        }
        self.server.calls.append(call)
        self.server.destination.write_text(
            json.dumps(self.server.calls, indent=2) + "\n"
        )
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("X-Softmax-Llm-Call-Id", identity)
        self.send_header("request-id", "local-" + identity)
        self.end_headers()
        self.wfile.write(encoded)


def run_case(args, name, mode, binary, expected_capture):
    destination = args.out / name
    destination.mkdir()
    fixture = Fixture(mode, destination / "fixture-calls.json")
    thread = threading.Thread(target=fixture.serve_forever, daemon=True)
    thread.start()
    game_port = port()
    config = {
        "seed": 18 if name == "different-map" else 17,
        "variant": name.removeprefix("variant-")
        if name.startswith("variant-")
        else "staghunt",
        "num_agents": 6,
        "rounds": 3,
        "ticksPerRound": 960,
        "tickHz": 200,
        "planIntervalTicks": 120,
        "planTimeoutSeconds": 2,
        "playBudgetSeconds": 90,
        "player_connect_timeout_seconds": 15,
    }
    if config["variant"] == "predator-prey":
        config.update(rounds=4, ticksPerRound=720)
    if name in {"artifact-failure", "late-unapplied"}:
        config.update(rounds=1, ticksPerRound=1)
    if name == "no-players":
        config["player_connect_timeout_seconds"] = 1
    if name == "deadline":
        config["playBudgetSeconds"] = 1
    if name == "renamed-wording":
        config.update(promptVariant="heldout-reference", promptSeed=91)
    (destination / "config.json").write_text(json.dumps(config))
    env = clean_env()
    env.update(
        COGAME_CONFIG_URI=(destination / "config.json").as_uri(),
        COGAME_RESULTS_URI=(destination / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(destination / "replay.json").as_uri(),
        COGAME_SAVE_TRAJECTORY_URI=(destination / "decisions.jsonl").as_uri(),
        COWORLD_EPISODE_ID="loopback-" + name,
        COWORLD_GAME_VERSION="local-capture-candidate",
        COWORLD_SOURCE_REVISION=subprocess.check_output(
            ["git", "rev-parse", "HEAD"], text=True
        ).strip(),
    )
    if name == "artifact-failure":
        env["COGAME_RESULTS_URI"] = destination.as_uri()
    if mode != "no-credentials":
        env.update(
            COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{fixture.server_port}",
            COWORLD_LLM_MODEL="local-fixture-no-teacher",
        )
    processes, logs = [], []
    try:
        log = (destination / "game.log").open("wb")
        logs.append(log)
        game = subprocess.Popen(
            [str(binary), "--address:127.0.0.1", f"--port:{game_port}"],
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
        )
        processes.append(game)
        for _ in range(200):
            assert game.poll() is None, (destination / "game.log").read_text()
            try:
                with urllib.request.urlopen(
                    f"http://127.0.0.1:{game_port}/healthz", timeout=0.1
                ):
                    break
            except OSError:
                time.sleep(0.05)
        else:
            raise AssertionError("server did not become healthy")
        for slot in range(0 if name == "no-players" else 6):
            player_env = clean_env()
            if slot == 0:
                player_env["PLAYER_PROMPT"] = (
                    "Coordinate on a visible target. Keep notes private."
                )
            else:
                player_env["PLAYER_SCRIPTED"] = "big_game_hunter"
            player_log = (destination / f"player-{slot}.log").open("wb")
            logs.append(player_log)
            processes.append(
                subprocess.Popen(
                    [
                        str(args.player),
                        "--address:127.0.0.1",
                        f"--port:{game_port}",
                        f"--slot:{slot}",
                        f"--name:{name}-policy-{slot}",
                    ],
                    env=player_env,
                    stdout=player_log,
                    stderr=subprocess.STDOUT,
                )
            )
        code = game.wait(timeout=110)
        if name == "artifact-failure":
            assert code != 0
            rows = [
                json.loads(line)
                for line in (destination / "decisions.jsonl").read_text().splitlines()
            ]
            assert (
                rows[-1]["status"] == "failed" and rows[-1]["outcome"]["runtime_error"]
            )
            return {
                "case": name,
                "capture": True,
                "failure_retained": True,
                "teacher_authorized": False,
                "family": rows[-1]["seed_family"],
            }
        assert code == 0, (destination / "game.log").read_text()
        results = json.loads((destination / "results.json").read_text())
        replay = json.loads((destination / "replay.json").read_text())
        if name in {"no-players", "deadline"}:
            rows = [
                json.loads(line)
                for line in (destination / "decisions.jsonl").read_text().splitlines()
            ]
            assert rows[-1]["status"] == (
                "failed" if name == "no-players" else "truncated"
            )
            assert results["reason"] == (
                "no_players" if name == "no-players" else "deadline"
            )
            assert results["final_tick"] < 3000
            if name == "no-players":
                assert len(rows) == 1 and not fixture.calls
            return {
                "case": name,
                "capture": True,
                "runtime": results,
                "terminal_status": rows[-1]["status"],
                "teacher_authorized": False,
                "family": rows[-1]["seed_family"],
            }
        expected_ticks = config["rounds"] * (config["ticksPerRound"] + 40)
        assert (
            results["reason"] == "complete" and results["final_tick"] == expected_ticks
        )
        assert (
            len(replay["ticks"]) == expected_ticks
            and len(replay["rounds"]) == config["rounds"]
        )
        assert "fixture private note" not in (destination / "replay.json").read_text()
        assert results["kinds"] == ["prompt"] + ["scripted"] * 5
        assert results["disconnected"] == [False] * 6
        if mode != "late":
            assert len(fixture.calls) == results["llm_requests"]
        if not expected_capture:
            assert not (destination / "decisions.jsonl").exists()
            return {
                "case": name,
                "runtime": results,
                "capture": False,
                "teacher_authorized": False,
                "fixture_calls": len(fixture.calls),
            }
        evidence = [
            json.loads(line)
            for line in (destination / "decisions.jsonl").read_text().splitlines()
        ]
        assert evidence[-1]["status"] == "completed"
        assert (destination / "decisions.jsonl").stat().st_mode & 0o777 == 0o600
        decisions = evidence[:-1]
        assert decisions and all(row["seat"] == "0" for row in decisions)
        calls = {call["call_id"]: call for call in fixture.calls}
        attempts = [attempt for row in decisions for attempt in row["attempts"]]
        assert len(attempts) == len(calls)
        for attempt in attempts:
            call = calls[attempt["platform_call_id"]]
            assert attempt["request"] == call["request"]
            assert attempt["response_body_b64"] == call["response_body_b64"]
            assert attempt["raw_response"].encode() == base64.b64decode(
                call["response_body_b64"]
            )
            assert attempt["http_status"] == call["status"]
            assert (
                attempt["response_headers"]["X-Softmax-Llm-Call-Id"] == call["call_id"]
            )
            assert attempt["origin"] == "model" and "teacher" not in attempt["policy"]
            assert attempt["response_complete"]
        accepted = [row for row in decisions if row["action_status"] == "accepted"]
        for row in decisions:
            physical = row["execution"]
            if physical:
                masks = base64.b64decode(physical["seat_controls_b64"])
                assert len(masks) == physical["end_tick"] - physical["start_tick"] > 0
                assert (
                    physical["control_encoding"] == "u8" and physical["tick_hz"] == 200
                )
            if row["action_status"] == "accepted":
                selected = [
                    item
                    for item in row["attempts"]
                    if item["attempt_id"] == row["selected_attempt_id"]
                ]
                assert len(selected) == 1 and selected[0]["accepted"]
                assert (
                    selected[0]["parsed_action"] == row["executed_action"] and physical
                )
        if mode == "late":
            assert not accepted and len(calls) == 1
            assert all(row["execution"] is None for row in decisions)
            assert (
                evidence[-1]["outcome"][
                    "native_worker_requests_including_terminal_drain"
                ]
                == 1
            )
            assert results["llm_requests"] == 0 and not results["fallbacks"][0]
        elif mode in {"success", "malformed"}:
            assert len(accepted) >= 20 and results["fallbacks"][0] == 0
        elif mode == "normalized":
            assert not accepted and any(
                "normalized" in item["rejection_reason"] for item in attempts
            )
        else:
            assert not accepted and results["fallbacks"][0] > 0
        if mode == "malformed":
            assert attempts[0]["rejection_reason"] and not attempts[0]["accepted"]
            assert len(decisions[0]["attempts"]) == 2 and len(calls) == 25
        if mode == "429":
            assert calls and all(item["status"] == 429 for item in calls.values())
            assert len(calls) <= 28
        if mode == "no-credentials":
            assert not calls
        # The public replay does not include controls; retain it as outcome proof;
        # do not fabricate an acknowledgement or claim policy causality from scores.
        intervals = [row["execution"] for row in decisions if row["execution"]]
        controls = b"".join(
            base64.b64decode(item["seat_controls_b64"]) for item in intervals
        )
        summary = {
            "retry_attempts": sum(
                max(0, len(row["attempts"]) - 1) for row in decisions
            ),
            "rejected_attempts": sum(not item["accepted"] for item in attempts),
            "accepted_target_none": sum(
                row["executed_action"]["target"] == "none" for row in accepted
            ),
            "physical_control_ticks": len(controls),
            "nonzero_control_ticks": sum(mask != 0 for mask in controls),
            "teacher_quality": "unknown: loopback fixture is never teacher-authorized; controller priorities and five scripted peers confound score attribution",
            "case": name,
            "runtime": results,
            "capture": True,
            "teacher_authorized": False,
            "fixture_calls": len(fixture.calls),
            "decisions": len(decisions),
            "accepted": len(accepted),
            "family": evidence[-1]["seed_family"],
            "trajectory_sha256": hashlib.sha256(
                (destination / "decisions.jsonl").read_bytes()
            ).hexdigest(),
        }
        (destination / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        return summary
    finally:
        fixture.shutdown()
        fixture.server_close()
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        for log in logs:
            log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ("game", "player", "before", "out"):
        parser.add_argument("--" + key, type=Path, required=key != "before")
    parser.add_argument("--families", action="store_true")
    args = parser.parse_args()
    args.out = args.out.resolve()
    args.out.mkdir(exist_ok=False)
    args.game, args.player = args.game.resolve(), args.player.resolve()
    cases = [
        ("positive", "success", args.game, True),
        ("malformed-retry", "malformed", args.game, True),
        ("429-fallback", "429", args.game, True),
        ("no-credentials", "no-credentials", args.game, True),
        ("normalized-rejected", "normalized", args.game, True),
    ]
    cases.extend(
        [
            ("artifact-failure", "success", args.game, True),
            ("late-unapplied", "late", args.game, True),
            ("no-players", "success", args.game, True),
            ("deadline", "success", args.game, True),
        ]
    )
    if args.families:
        cases.extend(
            ("variant-" + variant, "success", args.game, True)
            for variant in ("coop-mining", "lbf", "predator-prey")
        )
        cases.extend(
            (name, "success", args.game, True)
            for name in ("different-map", "renamed-wording")
        )
    if args.before:
        cases.insert(0, ("before", "success", args.before.resolve(), False))
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        futures = [executor.submit(run_case, args, *case) for case in cases]
        summaries = [future.result() for future in futures]
    families = {
        row["family"]
        for row in summaries
        if row["capture"] and row["case"] != "different-map"
    }
    assert len(families) == 1
    if args.families:
        different = next(row for row in summaries if row["case"] == "different-map")
        assert different["family"] not in families
        for row in summaries:
            if not row["capture"] or row.get("failure_retained"):
                continue
            terminal = json.loads(
                (args.out / row["case"] / "decisions.jsonl")
                .read_text()
                .splitlines()[-1]
            )
            initial = terminal["outcome"]["initial_state"]
            actual = {"width": 32, "height": 32, "tiles": initial["terrain"]}
            family = (
                "cooperative-hunting-forest-v1-"
                + hashlib.sha256(
                    json.dumps(actual, separators=(",", ":")).encode()
                ).hexdigest()
            )
            assert terminal["seed_family"] == family

    (args.out / "summary.json").write_text(json.dumps(summaries, indent=2) + "\n")
    print(json.dumps(summaries, indent=2))


if __name__ == "__main__":
    main()
