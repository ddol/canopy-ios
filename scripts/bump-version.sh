#!/usr/bin/env bash
# Move Canopy's version on by one: a pre-release to the next pre-release, anything else to the next patch.
#
#   0.1.0 → 0.1.1     0.2.13 → 0.2.14     0.1.1-pre2 → 0.1.1-pre3
#
#   scripts/bump-version.sh                bump Configs/Version.xcconfig (make bump-version)
#   scripts/bump-version.sh 0.1.1-pre2     print the version after 0.1.1-pre2 and change nothing
set -euo pipefail

cd "$(dirname "$0")/.."

file=Configs/Version.xcconfig

next() {
    if [[ $1 =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)-pre([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}-pre$((10#${BASH_REMATCH[4]} + 1))"
    elif [[ $1 =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((10#${BASH_REMATCH[3]} + 1))"
    else
        echo "error: cannot bump '$1': expected X.Y.Z or X.Y.Z-preN" >&2
        return 1
    fi
}

if [ $# -gt 0 ]; then
    next "$1"
    exit
fi

current="$(sed -nE 's/^CANOPY_VERSION[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$file")"
[ -n "$current" ] || { echo "error: no CANOPY_VERSION in $file" >&2; exit 1; }
new="$(next "$current")"
# App Store Connect takes only the numbers: 0.1.1-pre3 ships as 0.1.1.
release="${new%%-*}"

sed -i '' -E \
    -e "s/^(CANOPY_VERSION[[:space:]]*=[[:space:]]*).*/\1$new/" \
    -e "s/^(MARKETING_VERSION[[:space:]]*=[[:space:]]*).*/\1$release/" \
    "$file"
echo "$current → $new (App Store version $release)"
