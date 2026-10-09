#!/bin/zsh
# Builds a distributable ../dist/Mouthy-<version>-mac.zip (Mouthy.app, zipped by ditto) and its signed update feed
# ../dist/appcast.xml. A ZIP rather than a DMG: Gatekeeper and syspolicy_check accept a downloaded ZIP of a notarized,
# stapled app, while a DMG must itself be notarized (a signed, unnotarized DMG is rejected; so is an unsigned one).
#   Default: signed with the local identity (opens cleanly only on this Mac).
#   MOUTHY_DEVELOPER_ID="Developer ID Application: Name (TEAMID)" MOUTHY_DEVELOPER_ID_HOST=<ssh host>:
#     signs with that identity in the host Mac's keychain and notarizes the app through the Apple account Xcode
#     is signed in to there (stapled). The extracted app must pass Gatekeeper's check for downloaded apps, or
#     nothing is packaged. The host may be this Mac (localhost).
#   Without a host, MOUTHY_NOTARY_PROFILE=<notarytool keychain profile> notarizes and staples the app here.
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
identity="${MOUTHY_DEVELOPER_ID:-}"
team=$(print -r -- "$identity" | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p')
if [[ -n "${MOUTHY_DEVELOPER_ID_HOST:-}" && -z "$team" ]]; then
    print -u2 'Set MOUTHY_DEVELOPER_ID to your "Developer ID Application: Name (TEAMID)" identity.'; exit 1
fi
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
stage="$PWD/build/package"
zip="../dist/Mouthy-$version-mac.zip"
# A DMG from before the ZIP never sits beside it.
rm -rf "$stage"; mkdir -p "$stage" ../dist; rm -f "$zip" "../dist/Mouthy-$version-mac.dmg"
# build.sh strips the executable and the two bundled Intel dylibs before any signing.
# Developer ID signing below therefore never needs to mutate a signed Mach-O.
MOUTHY_APP_PATH="$stage/Mouthy.app" ./scripts/build.sh
if [[ -n "${MOUTHY_DEVELOPER_ID_HOST:-}" ]]; then
    # Sign with the Developer ID in that Mac's keychain and notarize through the Apple account Xcode
    # is signed in to there, all inside its logged-in session (no keys or passwords leave it).
    host="$MOUTHY_DEVELOPER_ID_HOST"
    build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$stage/Mouthy.app/Contents/Info.plist")
    # A fresh owner-only staging folder: other accounts on that Mac cannot plant or swap its contents.
    remote=$(ssh "$host" 'mktemp -d "${TMPDIR:-/tmp}/mouthy-package.XXXXXX"')
    [[ "$remote" == /*/mouthy-package.* && "$remote" != *[[:space:]]* ]] || { print -u2 "Could not create a staging folder on $host."; exit 1; }
    ssh "$host" "mkdir -p $remote/Mouthy.xcarchive/Products/Applications"
    rsync -a Resources/Mouthy.entitlements "$host:$remote/"
    rsync -a "$stage/Mouthy.app" "$host:$remote/Mouthy.xcarchive/Products/Applications/"
    ssh "$host" "cat > $remote/Mouthy.xcarchive/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>ApplicationProperties</key><dict>
<key>ApplicationPath</key><string>Applications/Mouthy.app</string>
<key>CFBundleIdentifier</key><string>dev.mouthy.Mouthy</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build</string>
<key>SigningIdentity</key><string>$identity</string>
<key>Team</key><string>$team</string>
</dict>
<key>ArchiveVersion</key><integer>2</integer>
<key>CreationDate</key><date>$(date -u +%Y-%m-%dT%H:%M:%SZ)</date>
<key>Name</key><string>Mouthy</string>
<key>SchemeName</key><string>Mouthy</string>
</dict></plist>
PLIST
    ssh "$host" "cat > $remote/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>destination</key><string>upload</string>
<key>teamID</key><string>$team</string>
<key>signingStyle</key><string>manual</string>
<key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
PLIST
    ssh "$host" "cat > $remote/package.command" <<SIGN
#!/bin/zsh
cd $remote
{
  for library in Mouthy.xcarchive/Products/Applications/Mouthy.app/Contents/Frameworks/sherpa-onnx/*.dylib; do codesign --force --options runtime --timestamp --sign "$identity" "\$library" || exit 1; done &&
  sparkle=Mouthy.xcarchive/Products/Applications/Mouthy.app/Contents/Frameworks/Sparkle.framework &&
  for part in \$sparkle/Versions/B/Autoupdate \$sparkle/Versions/B/Updater.app \$sparkle; do codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$identity" "\$part" || exit 1; done &&
  codesign --force --options runtime --timestamp --entitlements Mouthy.entitlements --identifier dev.mouthy.Mouthy --sign "$identity" Mouthy.xcarchive/Products/Applications/Mouthy.app &&
  xcodebuild -exportArchive -archivePath Mouthy.xcarchive -exportOptionsPlist ExportOptions.plist -exportPath upload -allowProvisioningUpdates &&
  for i in {1..40}; do xcodebuild -exportNotarizedApp -archivePath Mouthy.xcarchive -exportPath notarized && break; sleep 30; done &&
  test -d notarized/Mouthy.app && test -f notarized/Mouthy.app/Contents/Resources/Assets.car &&
  test -n "\$(ls -d notarized/Mouthy.app/Contents/Resources/*_MouthyKit.bundle 2>/dev/null)" &&
  xcrun stapler validate notarized/Mouthy.app &&
  ditto -c -k --sequesterRsrc --keepParent notarized/Mouthy.app Mouthy.zip && echo NOTARIZED-AND-SIGNED
} > package.log 2>&1
echo DONE >> package.log
osascript -e 'tell application "Terminal" to close (every window whose name contains "package.command")' >/dev/null 2>&1 &
SIGN
    ssh "$host" "chmod +x $remote/package.command && open $remote/package.command; for i in \$(seq 1 900); do grep -q DONE $remote/package.log 2>/dev/null && break; sleep 2; done; tail -3 $remote/package.log"
    ssh "$host" "grep -q NOTARIZED-AND-SIGNED $remote/package.log" || { print -u2 'Developer ID signing or notarization failed.'; exit 1; }
    scp -q "$host:$remote/Mouthy.zip" "$zip"
    ssh "$host" "rm -rf $remote"
    # The ZIP is what people download: unzipped with a browser's quarantine flag, Gatekeeper must accept the app
    # as notarized Developer ID with its ticket stapled.
    check="$PWD/build/package-check"
    rm -rf "$check"; mkdir -p "$check"
    ditto -x -k "$zip" "$check"
    xattr -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;" "$check/Mouthy.app"
    spctl -a -t exec -vv "$check/Mouthy.app" 2>&1 | grep -q 'source=Notarized Developer ID' && xcrun stapler validate "$check/Mouthy.app" >/dev/null 2>&1 ||
        { print -u2 "$zip does not hold a notarized, stapled Developer ID app."; rm -rf "$check"; rm -f "$zip"; exit 1; }
    rm -rf "$check"
else
    if [[ -n "${MOUTHY_NOTARY_PROFILE:-}" ]]; then
        ditto -c -k --sequesterRsrc --keepParent "$stage/Mouthy.app" "$zip"
        xcrun notarytool submit "$zip" --keychain-profile "$MOUTHY_NOTARY_PROFILE" --wait
        xcrun stapler staple "$stage/Mouthy.app"
        rm -f "$zip"
    fi
    ditto -c -k --sequesterRsrc --keepParent "$stage/Mouthy.app" "$zip"
fi
rm -rf "$stage"
# The signed static update feed, written beside the ZIP and uploaded nowhere: Sparkle's generate_appcast signs
# the ZIP and the feed with the EdDSA key that generate_keys keeps in this Mac's login Keychain (account
# dev.mouthy.Mouthy; macOS asks once to let Sparkle's tools use it). MOUTHY_SPARKLE_KEY_FILE signs with a key
# file instead. The app reads the feed at https://mouthy.dev/updates/appcast.xml.
feed_dir="$PWD/build/appcast"
rm -rf "$feed_dir"; mkdir -p "$feed_dir"; cp "$zip" "$feed_dir/"
key_args=(--account dev.mouthy.Mouthy)
[[ -n "${MOUTHY_SPARKLE_KEY_FILE:-}" ]] && key_args=(--ed-key-file "$MOUTHY_SPARKLE_KEY_FILE")
.build/artifacts/sparkle/Sparkle/bin/generate_appcast "${key_args[@]}" --download-url-prefix https://mouthy.dev/updates/ "$feed_dir"
grep -q 'sparkle:edSignature=' "$feed_dir/appcast.xml" || { print -u2 'The update feed has no EdDSA signature.'; exit 1; }
cp "$feed_dir/appcast.xml" ../dist/appcast.xml; rm -rf "$feed_dir"
printf 'Packaged %s and ../dist/appcast.xml\n' "$zip"
