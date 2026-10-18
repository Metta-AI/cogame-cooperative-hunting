"""Verify complete engine/controller candidate exports for every published variant."""
import base64
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VARIANTS = ("staghunt", "coop-mining", "lbf", "predator-prey")

if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    families: dict[str, set[str]] = {}
    with tempfile.TemporaryDirectory() as temp:
        for variant in VARIANTS:
            output = Path(temp) / variant
            subprocess.run([str(binary), str(output), "10", "1", variant], cwd=ROOT, check=True)
            manifest = json.loads((output / "manifest.json").read_text())
            assert len(manifest["runs"]) == 10
            assert all(len(run["scores"]) == 6 and run["decisions"] == 144 for run in manifest["runs"])
            source = output / "trajectories.jsonl"
            assert source.stat().st_mode & 0o777 == 0o600
            decisions, episodes = 0, 0
            ticks: dict[str, int] = {}
            with source.open() as stream:
                for line in stream:
                    row = json.loads(line)
                    assert row["game"] == "cooperative-hunting"
                    assert row["source_revision"] == manifest["source_revision"]
                    if row["event_type"] == "episode":
                        assert row["status"] == "completed" and decisions == 144
                        assert row["outcome"]["final_tick"] == (3040 if variant == "predator-prey" else 3000)
                        assert set(ticks.values()) == {row["outcome"]["final_tick"]}
                        families.setdefault(row["seed_family"], set()).add(variant)
                        decisions = 0
                        ticks.clear()
                        episodes += 1
                        continue
                    assert row["event_type"] == "decision" and row["visibility"] == "private"
                    assert row["decision_index"] == decisions
                    decisions += 1
                    attempt, = row["attempts"]
                    assert attempt["origin"] == "teacher" and attempt["request"] is None
                    assert attempt["platform_call_id"] is None and attempt["behavior_logprobs"] is None
                    plan = json.loads(attempt["response"])
                    assert plan == row["executed_action"] == attempt["parsed_action"]
                    assert row["selected_attempt_id"] == attempt["attempt_id"] and attempt["accepted"]
                    metadata = row["observation"]["prompt_template"]
                    for message in attempt["prompt"]:
                        assert "seed" not in message["content"].lower()
                        assert hashlib.sha256(message["content"].encode()).hexdigest() == metadata[
                            message["role"] + "_sha256"].lower()
                    legal = next(line for line in attempt["prompt"][1]["content"].splitlines()
                                 if line.startswith("LEGAL TARGETS: "))
                    assert plan["target"] in legal.removeprefix("LEGAL TARGETS: ").split(", ")
                    execution = row["execution"]
                    assert execution["control_encoding"] == "u8" and execution["tick_hz"] == 8
                    assert execution["start_tick"] == ticks.get(row["seat"], 0)
                    controls = base64.b64decode(execution["seat_controls_b64"], validate=True)
                    assert len(controls) == execution["end_tick"] - execution["start_tick"]
                    ticks[row["seat"]] = execution["end_tick"]
            assert episodes == 10 and decisions == 0
            print(variant, "10 complete private episodes with applied controls PASS")
    assert len(families) == 10 and all(variants == set(VARIANTS) for variants in families.values())
