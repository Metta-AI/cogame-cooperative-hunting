"""Complete published games through full-plan bridge and original source exporter."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = Path(sys.argv[1]).resolve()
WORDINGS = [
    "canonical",
    "plain",
    "numbered",
    "questions",
    "reordered",
    "heldout-briefing",
    "heldout-reference",
]


def play(variant, seed, wording, prompt_seed, normalized=False):
    with subprocess.Popen(
        [str(BRIDGE), str(ROOT / "coworld_manifest_template.json"), variant],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    ) as process:

        def request(payload):
            process.stdin.write(json.dumps(payload) + "\n")
            process.stdin.flush()
            line = process.stdout.readline()
            assert line, process.stderr.read()
            return json.loads(line)

        observation = request(
            {
                "kind": "reset",
                "seed": seed,
                "players": 6,
                "promptVariant": wording,
                "promptSeed": prompt_seed,
                "split": "test" if wording.startswith("heldout-") else "train",
            }
        )
        trace, systems = [], {}
        while observation["kind"] == "decision":
            view = observation["semantic_view"].copy()
            metadata = view.pop("prompt_template")
            system, user = (message["content"] for message in observation["messages"])
            assert view["observation"] == user
            expected = WORDINGS[prompt_seed] if wording == "mixed" else wording
            assert (
                metadata["variant"] == expected
                and metadata["bank"] == "cooperative-hunting-rules-v2"
            )
            assert (
                metadata["system_sha256"].lower()
                == hashlib.sha256(system.encode()).hexdigest()
            )
            assert (
                metadata["user_sha256"].lower()
                == hashlib.sha256(user.encode()).hexdigest()
            )
            assert systems.setdefault(observation["seat"], system) == system
            assert "policy-" not in user and "seed" not in user.lower()
            proposal = request({"kind": "teacher"})["response"]
            if normalized:
                seat = observation["seat"]
                assert all(
                    f"PRIVATE-SEAT-{other}" not in user
                    for other in range(6)
                    if other != seat
                )
                action = json.loads(proposal)
                action.update(
                    side="invalid",
                    intent="invalid",
                    note=f"PRIVATE-SEAT-{seat}:" + "雪" * 220,
                    say="雪" * 140,
                )
                proposal = json.dumps(action)
            accepted = request(
                {
                    "kind": "step",
                    "decision_id": observation["decision_id"],
                    "response": proposal,
                }
            )
            assert accepted["kind"] == "accepted"
            if normalized:
                action = accepted["action"]
                assert action["side"] == "any" and action["intent"] == "hunt"
                assert len(action["note"]) == 200 and len(action["say"]) == 120
            else:
                assert accepted["action"] == json.loads(proposal)
            trace.append((user, accepted["action"]))
            observation = accepted["observation"]
        process.stdin.close()
        assert process.wait(timeout=30) == 0
        assert len(trace) == 144 and len(systems) == 6
        assert observation["kind"] == "terminal"
        return trace, observation["scores"], systems


for variant in ("staghunt", "coop-mining", "lbf", "predator-prey"):
    for heldout in WORDINGS[5:]:
        failed = subprocess.run(
            [str(BRIDGE), str(ROOT / "coworld_manifest_template.json"), variant],
            input=json.dumps(
                {
                    "kind": "reset",
                    "seed": "17",
                    "players": 6,
                    "promptVariant": heldout,
                    "split": "train",
                }
            )
            + "\n",
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert failed.returncode != 0 and "evaluation-only" in failed.stderr
    for seed in ("17",):
        canonical = None
        introductions = set()
        for wording, prompt_seed in [*((name, 0) for name in WORDINGS), ("mixed", 4)]:
            trace, scores, systems = play(variant, seed, wording, prompt_seed)
            introductions.add(systems[0])
            if wording == "canonical":
                canonical = trace, scores
                canonical_system = systems[0]
            else:
                assert (trace, scores) == canonical
        assert len(introductions) == 7
        print(
            variant,
            seed,
            "8 complete games, exact prompt hashes and matched outcomes PASS",
            flush=True,
        )
        play(variant, seed, "mixed", 4, normalized=True)
        print(variant, "full normalized-action game PASS", flush=True)
