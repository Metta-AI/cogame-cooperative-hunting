"""Exercise every certified Cooperative Hunting variant through the numeric bridge."""

import json
import random
import subprocess
import sys
from pathlib import Path


MANIFEST = Path(__file__).resolve().parent.parent / "coworld_manifest_template.json"
VARIANTS = ("staghunt", "coop-mining", "lbf", "predator-prey")


def play(binary: Path, variant: str, teacher: bool) -> None:
    process = subprocess.Popen(
        [str(binary), str(MANIFEST), variant],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )
    assert process.stdin is not None and process.stdout is not None
    rng = random.Random(17)

    def request(payload: dict) -> dict:
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()
        return json.loads(process.stdout.readline())

    try:
        observation = request({"kind": "reset", "seed": f"ch-{variant}-{teacher}", "players": 6})
        widths = set()
        decisions = 0
        rounds = set()
        targets_seen = 0
        while observation["kind"] == "decision":
            encoding = request({"kind": "encode"})
            assert encoding["decision_id"] == observation["decision_id"]
            widths.add(len(encoding["values"]))
            heads = encoding["action_heads"]
            assert heads == [{"name": "mask", "choices": [0, 1, 2, 4, 8]}]
            assert observation["action_schema"]["properties"]["mask"]["enum"] == heads[0]["choices"]
            view = observation["semantic_view"]
            assert "seed" not in view and len(view["terrain"]) == 1024
            assert len(view["party"]) <= 6 and len(view["targets"]) <= 128
            targets_seen += len(view["targets"])
            rounds.add(view["round"])
            if teacher:
                action = json.loads(request({"kind": "teacher"})["response"])
            else:
                action = {"mask": rng.choice(heads[0]["choices"])}
            result = request(
                {"kind": "step", "decision_id": observation["decision_id"], "response": json.dumps(action)}
            )
            assert result["kind"] == "accepted" and result["action"] == action
            observation = result["observation"]
            decisions += 1
            assert decisions <= 6 * 4 * 960
        assert observation["kind"] == "terminal"
        assert set(observation["scores"]) == {str(i) for i in range(6)}
        assert set(observation["utilities"]) == {str(i) for i in range(6)}
        assert all(-1 <= value <= 1 for value in observation["utilities"].values())
        expected_rounds = 4 if variant == "predator-prey" else 3
        expected_ticks = 720 if variant == "predator-prey" else 960
        assert decisions == 6 * (expected_rounds * expected_ticks - 1)
        assert rounds == set(range(1, expected_rounds + 1))
        assert widths == {1835} and targets_seen > 0
        print(variant, "teacher" if teacher else "random", decisions, "decisions")
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0


def check_simultaneous_views(binary: Path) -> None:
    next_views = []
    for mask in (1, 8):
        process = subprocess.Popen(
            [str(binary), str(MANIFEST), "staghunt"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
        assert process.stdin is not None and process.stdout is not None

        def request(payload: dict) -> dict:
            process.stdin.write(json.dumps(payload) + "\n")
            process.stdin.flush()
            return json.loads(process.stdout.readline())

        request({"kind": "reset", "seed": "ch-simultaneous", "players": 6})
        next_views.append(request(
            {"kind": "step", "decision_id": 0, "response": json.dumps({"mask": mask})}
        )["observation"]["semantic_view"])
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0
    assert next_views[0] == next_views[1]


if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    check_simultaneous_views(binary)
    for variant in VARIANTS:
        for teacher in (True, False):
            play(binary, variant, teacher)
