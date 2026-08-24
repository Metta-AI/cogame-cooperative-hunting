#!/usr/bin/env bash
# Assemble the worst-case renderer fixture (acceptance checklist item 15).
#
#   tools/ci/build_worst_case_fixture.sh <outdir>
#
# The fixture is the REAL chrome. `chrome.html` is client/replay_broadcast.html
# with the same two splices Dockerfile.replay-viewer performs on the shipped
# bundle, with ONE substitution: the wasm transport (static_replay.js) is
# replaced by tools/ci/fixtures/fixture_core_stub.js, which captures the
# callbacks the page hands createCore so the fixture can feed it a chrome
# label directly. Everything the fixture measures -- the feed rows, the six
# hunter plates, the end-card standings -- is drawn by the page's own code,
# under the page's own CSS.
#
# ci.yml then runs
#   node tools/ci/viewer_smoke.mjs --bundle <outdir> \
#     --replay tools/ci/fixtures/worst_case_chrome.json --strict-text-bounds
# and the harness turns any clipped, shortened or off-frame string into
# data-replay-error, which viewer_smoke reports as a failure.
set -euo pipefail

out="${1:?usage: build_worst_case_fixture.sh <outdir>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

rm -rf "${out}"
mkdir -p "${out}"

sed -e 's|<!-- CHROME_COMMON -->|<script src="./chrome_common.js"></script>|' \
    -e 's|<!-- BROADCAST_CORE -->|<script src="./fixture_core_stub.js"></script>|' \
    -e 's|</body>|<script src="./fixture_chrome_driver.js"></script>\n</body>|' \
    "${here}/client/replay_broadcast.html" > "${out}/chrome.html"

cp "${here}/client/chrome_common.js" "${out}/chrome_common.js"
cp "${here}/client/broadcast_core.js" "${out}/broadcast_core.js"
cp "${here}/tools/ci/fixtures/fixture_core_stub.js" "${out}/fixture_core_stub.js"
cp "${here}/tools/ci/fixtures/fixture_chrome_driver.js" "${out}/fixture_chrome_driver.js"
cp "${here}/tools/ci/fixtures/worst_case_chrome.json" "${out}/worst_case_chrome.json"
cp "${here}/tools/ci/fixtures/worst_case_harness.html" "${out}/index.html"

# A silently failed splice would leave the page loading nothing and the
# fixture would time out with no explanation.
for marker in '<!-- CHROME_COMMON -->' '<!-- BROADCAST_CORE -->'; do
  if grep -qF "${marker}" "${out}/chrome.html"; then
    echo "::error::splice failed: ${marker} still in ${out}/chrome.html"
    exit 1
  fi
done
for needle in 'fixture_core_stub.js' 'fixture_chrome_driver.js' 'chrome_common.js'; do
  if ! grep -qF "${needle}" "${out}/chrome.html"; then
    echo "::error::${needle} was not spliced into ${out}/chrome.html"
    exit 1
  fi
done

echo "worst-case fixture assembled in ${out}:"
find "${out}" -type f -printf '  %p (%s bytes)\n'
