#!/usr/bin/env bash
# Coworld replay-viewer build hook: invoked by `coworld build` with one
# argument, the absolute path of the static bundle directory to produce
# (<manifest-dir>/static-replay-viewer, which must end up containing
# index.html). `coworld build` refuses to package a source replay-viewer
# bundle unless this file is os.X_OK, so it ships mode 100755.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 /absolute/path/to/static-replay-viewer" >&2
  exit 1
fi

requested_output="$1"
if [[ "${requested_output}" != /* ]]; then
  echo "output dir must be absolute: ${requested_output}" >&2
  exit 1
fi
if [[ "$(basename "${requested_output}")" != "static-replay-viewer" ]]; then
  echo "unsafe bundle output: ${requested_output}" >&2
  exit 1
fi
# `coworld build` hands an absolute path whose parent it has already made, but
# CI asks for $PWD/dist/static-replay-viewer on a clean checkout, so make the
# parent before resolving it (ecos, 2026-08-23).
mkdir -p "$(dirname "${requested_output}")"
output_parent="$(cd "$(dirname "${requested_output}")" && pwd -P)"
output_dir="${output_parent}/static-replay-viewer"
if [[ -L "${output_dir}" ]]; then
  echo "unsafe bundle output (symlink): ${requested_output}" >&2
  exit 1
fi

image_tag="coworld-cooperative-hunting-replay-viewer-build:$$"
container_id=""
cleanup() {
  if [[ -n "${container_id}" ]]; then
    docker rm "${container_id}" >/dev/null 2>&1 || true
  fi
  docker image rm "${image_tag}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

build_args=(
  --platform linux/amd64
  --file "${repo_dir}/Dockerfile.replay-viewer"
  --target replay-viewer-builder
  --tag "${image_tag}"
  "${repo_dir}"
)
if docker buildx version >/dev/null 2>&1; then
  docker buildx build --load "${build_args[@]}"
else
  docker build "${build_args[@]}"
fi

container_id="$(docker create --platform linux/amd64 "${image_tag}")"
rm -rf "${output_dir}"
mkdir -p "${output_dir}"
docker cp \
  "${container_id}:/workspace/cooperative-hunting/replay-viewer/dist/." \
  "${output_dir}"

test -s "${output_dir}/index.html"
test -s "${output_dir}/cooperative_hunting_replay.wasm"
test -s "${output_dir}/static_replay.js"
test -s "${output_dir}/static_replay_worker.js"
test -s "${output_dir}/broadcast_core.js"
test -s "${output_dir}/chrome_common.js"
grep -q 'coworld-replay' "${output_dir}/static_replay.js"
echo "cooperative-hunting replay viewer bundle: ${output_dir}"
