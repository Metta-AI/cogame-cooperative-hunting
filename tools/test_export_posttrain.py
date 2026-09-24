"""Verify complete seeded exports for every Cooperative Hunting variant."""

import json
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
VARIANTS = ("staghunt", "coop-mining", "lbf", "predator-prey")


def rows(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines()]


if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory() as temp:
        for variant in VARIANTS:
            output = Path(temp) / variant
            subprocess.run([str(binary), str(output), "10", "1", variant], cwd=ROOT, check=True)
            train = rows(output / "train.jsonl")
            validation = rows(output / "validation.jsonl")
            manifest = json.loads((output / "manifest.json").read_text())
            assert len(train) == manifest["train_examples"] == 1152
            assert len(validation) == manifest["validation_examples"] == 288
            assert len(manifest["runs"]) == 10
            assert {row["seed"] for row in train}.isdisjoint({row["seed"] for row in validation})
            assert all(len(run["scores"]) == 6 and run["decisions"] == 144 for run in manifest["runs"])
            for row in train + validation:
                assert row["game"] == "cooperative-hunting"
                assert all("seed" not in message["content"].lower() for message in row["prompt"])
                plan = json.loads(row["completion"][0]["content"])
                assert plan["intent"] in {"hunt", "rest"} and plan["side"] == "any"
                legal = next(line for line in row["prompt"][1]["content"].splitlines()
                             if line.startswith("LEGAL TARGETS: "))
                assert plan["target"] in legal.removeprefix("LEGAL TARGETS: ").split(", ")
            print(variant, len(train), "train", len(validation), "validation")
