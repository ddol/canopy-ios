#!/usr/bin/env bash
# Run the Canopy scheme's tests (app, UI and every package) on an available iPhone simulator.
# Extra arguments are passed to xcodebuild, e.g. scripts/test.sh -skip-testing:CanopyUITests
set -euo pipefail

cd "$(dirname "$0")/.."

[ -d Canopy.xcodeproj ] || scripts/bootstrap.sh

# Pick the newest available iPhone simulator unless SIMULATOR_ID is set.
simulator_id="${SIMULATOR_ID:-$(xcrun simctl list devices available iPhone \
    | grep -E '^\s+iPhone' | tail -n1 | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}')}"
[ -n "$simulator_id" ] || { echo "error: no available iPhone simulator" >&2; exit 1; }
echo "==> Testing on simulator $simulator_id"

xcodebuild test \
    -project Canopy.xcodeproj \
    -scheme Canopy \
    -destination "id=$simulator_id" \
    "$@"
