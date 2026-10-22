#!/usr/bin/env bash
# Archive a Release build of Canopy and upload it to App Store Connect for TestFlight.
#
# Needs DEVELOPMENT_TEAM in Configs/Local.xcconfig, Xcode signed in to that team (or an App Store Connect API key,
# below), and the app record in App Store Connect. See docs/DEVICE-TESTING.md.
#
#   scripts/testflight.sh                    build number from the current UTC time, e.g. 20261021.1507
#   BUILD_NUMBER=42 scripts/testflight.sh
#   TESTING_TOOLS=0 scripts/testflight.sh    leave out the testing tools (share GLB, simulated approval, reset)
#   UPLOAD=0 scripts/testflight.sh           archive and export an .ipa without uploading
#
# Without an Xcode account (for example on CI), set ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID to an App Store
# Connect API key.
set -euo pipefail

cd "$(dirname "$0")/.."

fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

team="$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Z0-9]{10}).*/\1/p' Configs/Local.xcconfig 2>/dev/null | head -n1)"
[ -n "$team" ] || fail "Set DEVELOPMENT_TEAM in Configs/Local.xcconfig (see docs/DEVICE-TESTING.md)."

scripts/bootstrap.sh

build_number="${BUILD_NUMBER:-$(date -u +%Y%m%d.%H%M)}"
archive=build/Canopy.xcarchive
export_path=build/export
options=build/ExportOptions.plist
mkdir -p build

auth=()
if [ -n "${ASC_KEY_PATH:-}" ]; then
    auth=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "${ASC_KEY_ID:?}"
        -authenticationKeyIssuerID "${ASC_ISSUER_ID:?}")
fi

conditions=()
if [ "${TESTING_TOOLS:-1}" != "0" ]; then
    conditions=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) TESTING_TOOLS')
fi

echo "==> Archiving build $build_number for team $team"
rm -rf "$archive"
xcodebuild archive \
    -project Canopy.xcodeproj \
    -scheme Canopy \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$archive" \
    -allowProvisioningUpdates \
    ${auth[@]+"${auth[@]}"} \
    CURRENT_PROJECT_VERSION="$build_number" \
    ${conditions[@]+"${conditions[@]}"} \
    -quiet

destination=upload
[ "${UPLOAD:-1}" = "0" ] && destination=export
cat > "$options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>$destination</string>
	<key>teamID</key>
	<string>$team</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
PLIST

echo "==> Exporting ($destination)"
rm -rf "$export_path"
xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportOptionsPlist "$options" \
    -exportPath "$export_path" \
    -allowProvisioningUpdates \
    ${auth[@]+"${auth[@]}"}

if [ "$destination" = upload ]; then
    echo "==> Uploaded build $build_number. It appears in App Store Connect → TestFlight after processing."
else
    echo "==> Exported to $export_path"
fi
