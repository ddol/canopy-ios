#!/usr/bin/env bash
# Upload the build to submit for App Store review: a Release build without the testing tools, at a release version
# (X.Y.Z, not a pre-release), from a commit on origin/main with no local changes, so what ships is what CI tested.
# Submitting it for review is then a step in App Store Connect; see docs/DEVICE-TESTING.md.
#
#   scripts/appstore.sh                  (make appstore)
#   UPLOAD=0 scripts/appstore.sh         archive and export the .ipa without uploading
#   ALLOW_UNMERGED=1 scripts/appstore.sh skip the commit checks, to try the build; never for a real submission
set -euo pipefail

cd "$(dirname "$0")/.."

fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

version="$(sed -nE 's/^CANOPY_VERSION[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' Configs/Version.xcconfig)"
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    fail "Version $version is a pre-release. App Store builds need X.Y.Z: set it in Configs/Version.xcconfig."

if [ "${ALLOW_UNMERGED:-0}" != "1" ]; then
    # Everything that goes into the build; Configs/Local.xcconfig is git-ignored.
    [ -z "$(git status --porcelain -- App Packages Fixtures Configs project.yml scripts)" ] ||
        fail "Commit or drop your local changes first, so the build matches a commit."
    git fetch --quiet origin main
    git merge-base --is-ancestor HEAD origin/main ||
        fail "$(git rev-parse --short HEAD) is not on origin/main. Release from merged code, which CI has tested."
fi

echo "==> App Store build of $version from $(git rev-parse --short HEAD)"
TESTING_TOOLS=0 scripts/testflight.sh
if [ "${UPLOAD:-1}" != "0" ]; then
    echo "==> Next, in App Store Connect: Canopy → iOS App $version → Build → choose this build → Add for Review."
fi
