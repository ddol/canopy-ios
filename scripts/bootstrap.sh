#!/usr/bin/env bash
# Prepare a checkout for development: make sure Xcode and XcodeGen are available, then generate
# Canopy.xcodeproj from project.yml.
set -euo pipefail

cd "$(dirname "$0")/.."

readonly XCODEGEN_MIN_VERSION="2.42.0"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

version_at_least() {
    # True when $1 >= $2, comparing dotted versions.
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)" = "$2" ]
}

# Xcode: xcodebuild needs the full Xcode, not just the Command Line Tools.
developer_dir="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
if [[ "$developer_dir" != *".app/Contents/Developer" ]]; then
    if [ -d /Applications/Xcode.app ]; then
        say "xcode-select points at '$developer_dir'. Using /Applications/Xcode.app for this script."
        say "To fix it for good: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    else
        fail "Xcode not found. Install Xcode 26.3 or later from the App Store or developer.apple.com."
    fi
fi
say "$(xcodebuild -version | head -n1)"

# XcodeGen
if ! command -v xcodegen >/dev/null 2>&1; then
    command -v brew >/dev/null 2>&1 \
        || fail "XcodeGen is missing and Homebrew is not installed. See https://github.com/yonaskolb/XcodeGen"
    say "Installing XcodeGen with Homebrew"
    brew install xcodegen
fi
xcodegen_version="$(xcodegen --version | awk '{print $2}')"
version_at_least "$xcodegen_version" "$XCODEGEN_MIN_VERSION" \
    || fail "XcodeGen $xcodegen_version is too old; need $XCODEGEN_MIN_VERSION or later (brew upgrade xcodegen)."

say "Generating Canopy.xcodeproj with XcodeGen $xcodegen_version"
xcodegen generate --spec project.yml --quiet

say "Done. Open Canopy.xcodeproj, or run the tests with scripts/test.sh"
