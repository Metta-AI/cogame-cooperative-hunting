"""Complete published games through full-plan bridge and original source exporter."""
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE, ORIGINAL_EXPORTER, OUTPUT = (Path(value).resolve() for value in sys.argv[1:4])
OUTPUT.mkdir(parents=True, exist_ok=False)
WORDINGS = ["canonical", "plain", "numbered", "questions", "reordered",
            "heldout-briefing", "heldout-reference"]


def play(variant, seed, wording, prompt_seed, normalized=False):
    with subprocess.Popen([str(BRIDGE), str(ROOT / "coworld_manifest_template.json"), variant],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True) as process:
        def request(payload):
            process.stdin.write(json.dumps(payload) + "\n")
            process.stdin.flush()
            line = process.stdout.readline()
            assert line, process.stderr.read()
            return json.loads(line)

        observation = request({"kind": "reset", "seed": seed, "players": 6,
                               "promptVariant": wording, "promptSeed": prompt_seed,
                               "split": "test" if wording.startswith("heldout-") else "train"})
        trace, systems = [], {}
        while observation["kind"] == "decision":
            view = observation["semantic_view"].copy()
            metadata = view.pop("prompt_template")
            system, user = (message["content"] for message in observation["messages"])
            assert view["observation"] == user
            expected = WORDINGS[prompt_seed] if wording == "mixed" else wording
            assert metadata["variant"] == expected and metadata["bank"] == "cooperative-hunting-rules-v1"
            assert metadata["system_sha256"].lower() == hashlib.sha256(system.encode()).hexdigest()
            assert metadata["user_sha256"].lower() == hashlib.sha256(user.encode()).hexdigest()
            assert systems.setdefault(observation["seat"], system) == system
            assert "policy-" not in user and "seed" not in user.lower()
            proposal = request({"kind": "teacher"})["response"]
            if normalized:
                seat = observation["seat"]
                assert all(f"PRIVATE-SEAT-{other}" not in user for other in range(6) if other != seat)
                action = json.loads(proposal)
                action.update(side="invalid", intent="invalid", note=f"PRIVATE-SEAT-{seat}:" + "雪" * 220,
                              say="雪" * 140)
                proposal = json.dumps(action)
            accepted = request({"kind": "step", "decision_id": observation["decision_id"], "response": proposal})
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
        failed = subprocess.run([str(BRIDGE), str(ROOT / "coworld_manifest_template.json"), variant],
                                input=json.dumps({"kind": "reset", "seed": "17", "players": 6,
                                                  "promptVariant": heldout, "split": "train"}) + "\n",
                                capture_output=True, text=True, timeout=30)
        assert failed.returncode != 0 and "evaluation-only" in failed.stderr
    for seed in ("17", "946001"):
        canonical = None
        introductions = set()
        for wording, prompt_seed in [*((name, 0) for name in WORDINGS),
                                     *(("mixed", index) for index in range(5))]:
            trace, scores, systems = play(variant, seed, wording, prompt_seed)
            introductions.add(systems[0].split("\n", 1)[0])
            if wording == "canonical":
                canonical = trace, scores
                canonical_system = systems[0]
            else:
                assert (trace, scores) == canonical
                assert systems[0].split("\n", 1)[1] == canonical_system.split("\n", 1)[1]
        assert len(introductions) == 7
        print(variant, seed, "12 complete games, exact prompt hashes and matched outcomes PASS", flush=True)
        if seed != "17":
            continue
        hashed = 2166136261
        for char in seed:
            hashed = ((hashed ^ ord(char)) * 16777619) & 0xffffffff
        engine_seed = (hashed & 0x7fffffff) + 1
        output = OUTPUT / variant
        subprocess.run([str(ORIGINAL_EXPORTER), str(output), "10", str(engine_seed), variant],
                       cwd=ROOT.parent / "cooperative-hunting-baseline", check=True, timeout=600)
        original_trace = []
        for name in ("train.jsonl", "validation.jsonl"):
            with (output / name).open() as stream:
                for line in stream:
                    row = json.loads(line)
                    if row["episode_id"] == f"cooperative-hunting-{variant}-{engine_seed}":
                        assert row["prompt"][0]["content"] == canonical_system
                        original_trace.append((row["prompt"][1]["content"],
                                               json.loads(row["completion"][0]["content"])))
        manifest = json.loads((output / "manifest.json").read_text())
        original_scores = manifest["runs"][0]["scores"]
        assert canonical == (original_trace, {str(index): score for index, score in enumerate(original_scores)})
        print(variant, "original complete plan trajectory/outcome parity PASS", flush=True)

    play(variant, "17", "canonical", 0, normalized=True)
    print(variant, "complete normalized-plan and private-note game PASS", flush=True)
