#!/usr/bin/env bash
# Build Canopy, install it on a paired iPhone or iPad, and launch it.
#
# Needs DEVELOPMENT_TEAM in Configs/Local.xcconfig, Xcode signed in to that team (Settings → Accounts), and the
# device paired with this Mac with Developer Mode on. See docs/DEVICE-TESTING.md.
#
#   scripts/device.sh                       first paired iOS device, Debug build
#   DEVICE_ID=<udid> scripts/device.sh      a specific device (xcrun devicectl list devices)
#   CONFIGURATION=Release scripts/device.sh
set -euo pipefail

cd "$(dirname "$0")/.."

fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

grep -qE '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]{10}' Configs/Local.xcconfig 2>/dev/null \
    || fail "Set DEVELOPMENT_TEAM in Configs/Local.xcconfig (see docs/DEVICE-TESTING.md)."

scripts/bootstrap.sh

if [ -z "${DEVICE_ID:-}" ]; then
    json="$(mktemp)"
    trap 'rm -f "$json"' EXIT
    xcrun devicectl list devices --json-output "$json" >/dev/null
    i=0
    while udid="$(plutil -extract "result.devices.$i.hardwareProperties.udid" raw -o - "$json" 2>/dev/null)"; do
        platform="$(plutil -extract "result.devices.$i.hardwareProperties.platform" raw -o - "$json" 2>/dev/null || true)"
        pairing="$(plutil -extract "result.devices.$i.connectionProperties.pairingState" raw -o - "$json" 2>/dev/null || true)"
        if [ "$platform" = "iOS" ] && [ "$pairing" = "paired" ]; then
            DEVICE_ID="$udid"
            break
        fi
        i=$((i + 1))
    done
fi
[ -n "${DEVICE_ID:-}" ] || fail "No paired iPhone or iPad. Connect one, tap Trust, and turn on Developer Mode."

configuration="${CONFIGURATION:-Debug}"
derived=build/DerivedData
echo "==> Building $configuration for device $DEVICE_ID"
xcodebuild build \
    -project Canopy.xcodeproj \
    -scheme Canopy \
    -configuration "$configuration" \
    -destination "id=$DEVICE_ID" \
    -derivedDataPath "$derived" \
    -allowProvisioningUpdates \
    -quiet

app="$derived/Build/Products/$configuration-iphoneos/Canopy.app"
bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$app/Info.plist")"
echo "==> Installing $bundle_id"
xcrun devicectl device install app --device "$DEVICE_ID" "$app"
echo "==> Launching"
xcrun devicectl device process launch --device "$DEVICE_ID" "$bundle_id"
