#!/bin/zsh
# Installs the notarized release from ../dist/ into /Applications (quits Mouthy and Mouthy Dev first).
set -euo pipefail
cd "${0:A:h:h}"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
zip="../dist/Mouthy-$version-mac.zip"
[[ -f "$zip" ]] || { print -u2 "Build it first with ./scripts/package-mac.sh (see its header for Developer ID signing)."; exit 1; }
unpacked=$(mktemp -d)
trap 'rm -rf "$unpacked"' EXIT
ditto -x -k "$zip" "$unpacked"
spctl -a -vv --type exec "$unpacked/Mouthy.app" 2>&1 | grep -q "Notarized Developer ID" || { print -u2 "The ZIP's app is not notarized."; exit 1; }
osascript -e 'quit app "Mouthy"' -e 'quit app "Mouthy Dev"' >/dev/null 2>&1 || true
for i in {1..20}; do pgrep -xq Mouthy || break; sleep 0.5; done
rm -rf /Applications/Mouthy.app
ditto "$unpacked/Mouthy.app" /Applications/Mouthy.app
print "Installed notarized Mouthy $version to /Applications."
