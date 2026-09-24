#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "${repo_dir}/dist"
output_dir="$(mktemp -d "${repo_dir}/dist/local-jev-smoke.XXXXXX")"
mock_port="${MOCK_PORT:-18998}"
image="${SMOKE_IMAGE:-coworld-cooperative-hunting:jev-policy}"
jev_slot="${JEV_SLOT:-0}"
variant="${SMOKE_VARIANT:-staghunt}"
rounds="${SMOKE_ROUNDS:-1}"

python3 - "${repo_dir}/coworld_manifest_template.json" "${output_dir}/manifest.json" "${mock_port}" "${jev_slot}" "${variant}" "${rounds}" <<'PY'
import json
import sys

source, target, port, slot, variant, rounds = sys.argv[1:]
slot = int(slot)
manifest = json.load(open(source))
manifest["certification"]["game_config"]["rounds"] = int(rounds)
manifest["certification"]["game_config"]["variant"] = variant
baseline = next(player for player in manifest["player"] if player["id"] == "big-game-hunter")
jev = dict(baseline)
jev["id"] = "jev-local"
jev["env"] = {
    "PLAYER_JEV": "1",
    "TYPESAFE_BASE_URL": f"http://host.docker.internal:{port}",
    "TYPESAFE_API_KEY": "mock",
}
manifest["player"].append(jev)
manifest["certification"]["players"][slot] = {"player_id": "jev-local"}
json.dump(manifest, open(target, "w"))
PY

python3 "${repo_dir}/tools/mock_systemone.py" \
  --port "${mock_port}" --log "${output_dir}/model.jsonl" &
mock_pid=$!
trap 'kill "${mock_pid}" 2>/dev/null || true' EXIT

env -u ANTHROPIC_API_KEY -u ANTHROPIC_API_KEY_URI \
  SMOKE_MANIFEST="${output_dir}/manifest.json" \
  SMOKE_REPLAY_OUT="${output_dir}/replay.json" \
  SMOKE_TIMEOUT=200 \
  "${repo_dir}/tools/ci/docker_smoke.sh" "${image}"

python3 - "${output_dir}" "${jev_slot}" "${variant}" "${rounds}" <<'PY'
import json
import sys
from pathlib import Path

output = Path(sys.argv[1])
slot = int(sys.argv[2])
variant = sys.argv[3]
rounds = int(sys.argv[4])
calls = [json.loads(line) for line in (output / "model.jsonl").read_text().splitlines()]
assert calls, "Jev made no model calls"
assert all(call["selected"] != "baseline" for call in calls)
assert all(f"variant {variant}" in call["state"] for call in calls)
if variant == "predator-prey":
    roles = {"hunter" if (slot + round_index) % 2 == 0 else "forager" for round_index in range(rounds)}
    assert all(any(f"You are a {role}" in call["state"] for role in roles) for call in calls)
    if rounds > 1:
        assert all(any(f"You are a {role}" in call["state"] for call in calls) for role in roles)
    for call in calls:
        if "You are a hunter" not in call["state"]:
            continue
        assert call["selected"].startswith("player-")
        target_id = int(call["selected"].split("@")[0].split("-")[1])
        visible = json.loads(call["state"].split("Visible players: ")[1])
        assert any(
            player["object_id"] == target_id and player["role"] == "forager"
            for player in visible
        )
results = json.loads((output / "results.json").read_text())
replay = json.loads((output / "replay.json").read_text())
assert results["kinds"][slot] == "external"
assert replay["seats"][slot]["kind"] == "external"
assert results["fallbacks"][slot] == 0
if variant == "predator-prey" and rounds == 1 and "forager" in roles:
    assert results["scores"][slot] > 0, "forager did not reach a berry tile"
assert len({tuple(tick["p"][slot][:2]) for tick in replay["ticks"] if "p" in tick}) > 1
print(f"Jev calls: {len(calls)}; local artifacts: {output}")
PY
