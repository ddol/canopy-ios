#!/usr/bin/env bash
# Run the Canopy scheme's tests (app, UI and every package) on one iPhone simulator.
# Extra arguments are passed to xcodebuild, e.g. scripts/test.sh -skip-testing:CanopyUITests
# Set SIMULATOR_ID to choose the simulator; otherwise the iPhone with the newest iOS that Xcode offers is used.
#
# One simulator at a time on this machine (see AGENTS.md): a run waits for any other run from this repository (any
# checkout or worktree) to finish, shuts down every other booted simulator, tests without cloning the simulator, and
# shuts its simulator down when it ends. CANOPY_KEEP_SIMULATOR=1 leaves it booted. Several simulators rendering at once
# panicked the Mac mini's Intel graphics driver and took the whole machine down.
set -euo pipefail

cd "$(dirname "$0")/.."

# Regenerate first so new or removed files are always in the project.
scripts/bootstrap.sh

# One run at a time: a lock in the repository's shared git directory, which every worktree can write.
lock="$(cd "$(git rev-parse --git-common-dir)" && pwd)/canopy-simulator.lock"
stand_in=""
cleanup() {
    if [ -n "$stand_in" ]; then kill "$stand_in" 2>/dev/null || true; fi
    if [ "${CANOPY_KEEP_SIMULATOR:-0}" != 1 ] && [ -n "${SIMULATOR_ID:-}" ]; then
        xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
    fi
    if [ "$(cat "$lock/pid" 2>/dev/null || true)" = "$$" ]; then rm -rf "$lock"; fi
}
trap cleanup EXIT

waiting=0
until mkdir "$lock" 2>/dev/null; do
    [ -d "$lock" ] || { echo "error: cannot create the simulator lock $lock" >&2; exit 1; }
    holder="$(cat "$lock/pid" 2>/dev/null || true)"
    # A lock whose process is gone, or one left without a process for over a minute, is stale.
    if { [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; } \
        || { [ -z "$holder" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; }; then
        echo "==> Removing a stale simulator lock (process ${holder:-unknown})"
        rm -rf "$lock"
        continue
    fi
    if [ "$waiting" = 0 ]; then
        echo "==> Waiting for the test run in $(cat "$lock/checkout" 2>/dev/null || echo 'another checkout') (process ${holder:-?}) to finish"
        waiting=1
    fi
    sleep 5
done
echo $$ >"$lock/pid"
pwd >"$lock/checkout"

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

# Only this simulator may be booted while it runs.
for booted in $(xcrun simctl list devices booted | sed -nE 's/.*\(([0-9A-F-]{36})\) \(Booted\).*/\1/p'); do
    [ "$booted" = "$SIMULATOR_ID" ] && continue
    echo "==> Shutting down simulator $booted: one simulator at a time"
    xcrun simctl shutdown "$booted" >/dev/null 2>&1 || true
done
echo "==> Testing on simulator $SIMULATOR_ID"

# The stand-in Gerardus server (Packages/CanopyHarness) for the UI tests that load real trees, unless one is given or
# CANOPY_STAND_IN=0. The simulator reaches this machine's loopback address.
if [ "${CANOPY_STAND_IN:-1}" != 0 ] && [ -z "${TEST_RUNNER_CANOPY_STAND_IN_URL:-}" ]; then
    port="${CANOPY_STAND_IN_PORT:-50099}"
    echo "==> Starting the stand-in Gerardus server on port $port"
    swift build --package-path Packages/CanopyHarness --product canopy-harness
    "$(swift build --package-path Packages/CanopyHarness --show-bin-path)/canopy-harness" serve --port "$port" &
    stand_in=$!
    for _ in $(seq 1 50); do
        curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1 && break
        sleep 0.2
    done
    export TEST_RUNNER_CANOPY_STAND_IN_URL="http://127.0.0.1:$port"
fi

# Parallel testing would clone the simulator, booting more of them: test on this one only.
xcodebuild test \
    -project Canopy.xcodeproj \
    -scheme Canopy \
    -destination "id=$SIMULATOR_ID" \
    -parallel-testing-enabled NO \
    -maximum-concurrent-test-simulator-destinations 1 \
    "$@"
