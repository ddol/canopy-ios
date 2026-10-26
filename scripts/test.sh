#!/usr/bin/env bash
# Run the Canopy scheme's tests (app, UI and every package) on an iPhone simulator.
# Extra arguments are passed to xcodebuild, e.g. scripts/test.sh -skip-testing:CanopyUITests
# Set SIMULATOR_ID to choose the simulator; otherwise the iPhone with the newest iOS that Xcode offers is used.
set -euo pipefail

cd "$(dirname "$0")/.."

# Regenerate first so new or removed files are always in the project.
scripts/bootstrap.sh

if [ -z "${SIMULATOR_ID:-}" ]; then
    SIMULATOR_ID="$(
        xcodebuild -project Canopy.xcodeproj -scheme Canopy -showdestinations 2>/dev/null \
            | grep 'platform:iOS Simulator' | grep 'name:iPhone' \
            | sed -E 's/.*id:([^,]+), OS:([^,]+),.*/\2 \1/' \
            | sort -t. -k1,1n -k2,2n -k3,3n \
            | tail -n1 | awk '{print $2}'
    )"
fi
[ -n "$SIMULATOR_ID" ] || { echo "error: no iPhone simulator available to Xcode" >&2; exit 1; }
echo "==> Testing on simulator $SIMULATOR_ID"

# The stand-in Gerardus server (Packages/CanopyHarness) for the UI tests that load real trees, unless one is given or
# CANOPY_STAND_IN=0. The simulator reaches this machine's loopback address.
if [ "${CANOPY_STAND_IN:-1}" != 0 ] && [ -z "${TEST_RUNNER_CANOPY_STAND_IN_URL:-}" ]; then
    port="${CANOPY_STAND_IN_PORT:-50099}"
    echo "==> Starting the stand-in Gerardus server on port $port"
    swift build --package-path Packages/CanopyHarness --product canopy-harness
    "$(swift build --package-path Packages/CanopyHarness --show-bin-path)/canopy-harness" serve --port "$port" &
    stand_in=$!
    trap 'kill "$stand_in" 2>/dev/null || true' EXIT
    for _ in $(seq 1 50); do
        curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1 && break
        sleep 0.2
    done
    export TEST_RUNNER_CANOPY_STAND_IN_URL="http://127.0.0.1:$port"
fi

xcodebuild test \
    -project Canopy.xcodeproj \
    -scheme Canopy \
    -destination "id=$SIMULATOR_ID" \
    "$@"
