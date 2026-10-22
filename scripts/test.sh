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

xcodebuild test \
    -project Canopy.xcodeproj \
    -scheme Canopy \
    -destination "id=$SIMULATOR_ID" \
    "$@"
