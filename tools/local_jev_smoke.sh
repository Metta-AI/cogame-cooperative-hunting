#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "${repo_dir}/dist"
output_dir="$(mktemp -d "${repo_dir}/dist/local-jev-smoke.XXXXXX")"
mock_port="${MOCK_PORT:-18998}"
image="${SMOKE_IMAGE:-coworld-cooperative-hunting:jev-policy}"

python3 - "${repo_dir}/coworld_manifest_template.json" "${output_dir}/manifest.json" "${mock_port}" <<'PY'
import json
import sys

source, target, port = sys.argv[1:]
manifest = json.load(open(source))
manifest["certification"]["game_config"]["rounds"] = 1
baseline = next(player for player in manifest["player"] if player["id"] == "big-game-hunter")
jev = dict(baseline)
jev["id"] = "jev-local"
jev["env"] = {
    "PLAYER_JEV": "1",
    "TYPESAFE_BASE_URL": f"http://host.docker.internal:{port}",
    "TYPESAFE_API_KEY": "mock",
}
manifest["player"].append(jev)
manifest["certification"]["players"][0] = {"player_id": "jev-local"}
json.dump(manifest, open(target, "w"))
PY

python3 "${repo_dir}/tools/mock_systemone.py" \
  --port "${mock_port}" --log "${output_dir}/model.jsonl" &
mock_pid=$!
trap 'kill "${mock_pid}" 2>/dev/null || true' EXIT

env -u ANTHROPIC_API_KEY -u ANTHROPIC_API_KEY_URI \
  SMOKE_MANIFEST="${output_dir}/manifest.json" \
  SMOKE_REPLAY_OUT="${output_dir}/replay.json" \
  SMOKE_TIMEOUT=150 \
  "${repo_dir}/tools/ci/docker_smoke.sh" "${image}"

python3 - "${output_dir}" <<'PY'
import json
import sys
from pathlib import Path

output = Path(sys.argv[1])
calls = [json.loads(line) for line in (output / "model.jsonl").read_text().splitlines()]
assert calls, "Jev made no model calls"
assert all(call["selected"] != "baseline" for call in calls)
results = json.loads((output / "results.json").read_text())
replay = json.loads((output / "replay.json").read_text())
assert results["kinds"][0] == "external"
assert replay["seats"][0]["kind"] == "external"
assert results["fallbacks"][0] == 0
assert len({tuple(tick["p"][0][:2]) for tick in replay["ticks"] if "p" in tick}) > 1
print(f"Jev calls: {len(calls)}; local artifacts: {output}")
PY
