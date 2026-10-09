#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# MOUTHY_VARIANT=dev builds "Mouthy Dev" (dev.mouthy.Mouthy.dev) into ~/Applications: a separate app
# with its own macOS permissions, so development rebuilds never disturb the notarized release.
variant="${MOUTHY_VARIANT:-release}"
if [[ "$variant" == dev ]]; then
    bundle_id=dev.mouthy.Mouthy.dev; display="Mouthy Dev"
    app="${MOUTHY_APP_PATH:-$HOME/Applications/Mouthy Dev.app}"
else
    bundle_id=dev.mouthy.Mouthy; display="Mouthy"
    app="${MOUTHY_APP_PATH:-$PWD/build/Mouthy.app}"
fi
app="${app:A}"
if pgrep -f "^$app/Contents/MacOS/Mouthy( |$)" >/dev/null; then
    print -u2 'Quit Mouthy before rebuilding so the running app and its permission identity stay consistent.'
    exit 1
fi
# Universal (Apple silicon + Intel), macOS 26 and later. SwiftPM already links release with -dead_strip.
swift build -c release --arch arm64 --arch x86_64
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
chmod -R u+w "$app/Contents/Resources"
bin_dir="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
cp "$bin_dir/Mouthy" "$app/Contents/MacOS/Mouthy"
# Strip only the bundle copy: keep SwiftPM symbols and dSYMs for debugging. Applies to dev too. All symbols go:
# nothing looks a symbol up in the executable (CSherpaOnnx dlsyms into the sherpa-onnx dylib only).
xcrun strip "$app/Contents/MacOS/Mouthy"
# Sparkle 2 (MIT), the updater: only the app executable links it, from Contents/Frameworks.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
rm -rf "$sparkle" && mkdir -p "$app/Contents/Frameworks" && ditto "$bin_dir/Sparkle.framework" "$sparkle"
# Mouthy is not sandboxed and sets neither SUEnableInstallerLauncherService nor SUEnableDownloaderService, so
# Sparkle never uses its XPC services; its headers only serve compiling against it.
rm -rf "$sparkle"/{Headers,PrivateHeaders,Modules,XPCServices} "$sparkle"/Versions/B/{Headers,PrivateHeaders,Modules,XPCServices}
otool -l "$app/Contents/MacOS/Mouthy" | grep -q '@executable_path/../Frameworks' ||
    install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/Mouthy"
cp Resources/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" -c "Set :CFBundleName $display" -c "Set :CFBundleDisplayName $display" "$app/Contents/Info.plist"
# Only the release answers mouthy:// links (Shortcuts, Raycast and similar launchers) and checks for updates:
# without a feed URL Sparkle never starts in Mouthy Dev.
[[ "$variant" == dev ]] && /usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" -c "Delete :SUFeedURL" "$app/Contents/Info.plist"
revision="$(git rev-parse --short HEAD)"
if ! git diff --quiet HEAD -- Sources Resources Package.swift Package.resolved; then
    revision="$revision-dirty"
fi
/usr/libexec/PlistBuddy -c "Add :MouthySourceRevision string $revision" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :MouthyBuildTimestamp string $(date -u +%Y-%m-%dT%H:%M:%SZ)" "$app/Contents/Info.plist"
cp -R Resources/ThirdParty "$app/Contents/Resources/"
cp ../LICENSE "$app/Contents/Resources/LICENSE.txt"   # GPL-3.0 text ships with the program
for resource in "$bin_dir"/*.bundle(N); do
    rm -rf "$app/Contents/Resources/${resource:t}"
    cp -R "$resource" "$app/Contents/Resources/"
done
# The speaker model for "Only my voice" ships inside the app, compiled here for the Neural Engine. It goes into the
# app only, never MouthyKit's resource bundle, so apps that embed MouthyKit don't carry it.
xcrun coremlcompiler compile Resources/Models/WeSpeakerResNet34LM.mlpackage "$app/Contents/Resources/" >/dev/null
[[ -f "$app/Contents/Resources/WeSpeakerResNet34LM.mlmodelc/coremldata.bin" ]] || {
    print -u2 'The speaker model (Resources/Models/WeSpeakerResNet34LM.mlpackage) did not compile into the app.'; exit 1; }
# MouthyKit's resource bundle carries the giraffe (Mascot/poses, heads, menubar, Mouthy.usdz); without it the
# app falls back to SF Symbols, so a build that lost it is a broken build.
mascot=("$app"/Contents/Resources/*_MouthyKit.bundle{/Contents/Resources,}/Mascot(N/))
[[ -n "${mascot[1]:-}" && -d "$mascot[1]/poses" && -d "$mascot[1]/heads" && -d "$mascot[1]/menubar" && -f "$mascot[1]/Mouthy.usdz" ]] || {
    print -u2 'MouthyKit resource bundle with the mascot art is missing from the build.'; exit 1; }
# Intel speech runtime: sherpa-onnx (Apache-2.0) with ONNX Runtime (MIT), pinned by SHA-256 and loaded only
# on Intel Macs, where it runs Parakeet ~9x faster than Core ML (see SherpaParakeet.swift).
mkdir -p build
sherpa_version=1.13.8
sherpa_sha256=c4d94cce92b6e04df1f17d247c3ac4e61b21359be80e940a0408e039e36a4d7e
sherpa_archive="build/sherpa-onnx-v$sherpa_version-osx-x64-shared-no-tts-lib.tar.bz2"
if [[ ! -f "$sherpa_archive" || "$(shasum -a 256 "$sherpa_archive" | cut -d' ' -f1)" != "$sherpa_sha256" ]]; then
    curl -fsSL -o "$sherpa_archive" "https://github.com/k2-fsa/sherpa-onnx/releases/download/v$sherpa_version/${sherpa_archive:t}"
fi
[[ "$(shasum -a 256 "$sherpa_archive" | cut -d' ' -f1)" == "$sherpa_sha256" ]] || { print -u2 'The sherpa-onnx archive does not match its checksum.'; exit 1; }
rm -rf build/sherpa-onnx && mkdir -p build/sherpa-onnx && tar -xjf "$sherpa_archive" -C build/sherpa-onnx
sherpa_dir="$app/Contents/Frameworks/sherpa-onnx"
rm -rf "$sherpa_dir" && mkdir -p "$sherpa_dir"
cp build/sherpa-onnx/*/lib/libsherpa-onnx-c-api.dylib build/sherpa-onnx/*/lib/libonnxruntime.dylib "$sherpa_dir/"
# Keep exported symbols for dlopen/dlsym and the ONNX dependency; remove debug/local symbols only.
for library in "$sherpa_dir"/*.dylib; do xcrun strip -S -x "$library"; done
swift scripts/make-icon.swift Resources/AppIcon.png build/Mouthy.iconset
iconutil -c icns build/Mouthy.iconset -o "$app/Contents/Resources/Mouthy.icns"
# Asset catalog: the giraffe-orange AccentColor (NSAccentColorName), so system controls never fall back to blue.
mkdir -p build
xcrun actool Resources/Assets.xcassets --compile "$app/Contents/Resources" --platform macosx --minimum-deployment-target 26.0 \
    --output-partial-info-plist build/assets-partial.plist --output-format human-readable-text --notices --warnings --errors >/dev/null
[[ -f "$app/Contents/Resources/Assets.car" ]] || { print -u2 'actool did not produce Assets.car.'; exit 1; }
# A stable signing identity keeps macOS permission grants across rebuilds. scripts/local.env
# (not in git) may set MOUTHY_SIGNING_IDENTITY, MOUTHY_SIGNING_KEYCHAIN and
# MOUTHY_SIGNING_KEYCHAIN_PASSWORD_FILE; without them the app is signed ad hoc. A separate review
# candidate can opt out of all local credentials with MOUTHY_AD_HOC=1.
identity=""
if [[ "${MOUTHY_AD_HOC:-0}" != 1 ]]; then
    [[ -f scripts/local.env ]] && source scripts/local.env
    identity="${MOUTHY_SIGNING_IDENTITY:-}"
fi
keychain_args=()
if [[ -n "$identity" && -n "${MOUTHY_SIGNING_KEYCHAIN:-}" ]]; then
    [[ -n "${MOUTHY_SIGNING_KEYCHAIN_PASSWORD_FILE:-}" ]] && security unlock-keychain -p "$(<"$MOUTHY_SIGNING_KEYCHAIN_PASSWORD_FILE")" "$MOUTHY_SIGNING_KEYCHAIN"
    keychain_args=(--keychain "$MOUTHY_SIGNING_KEYCHAIN")
fi
# Signed like the notarized release (package-mac.sh): hardened runtime and the same entitlements, so Dev and every
# local build hit the same permission rules the downloaded app does.
for library in "$sherpa_dir"/*.dylib; do codesign --force --options runtime "${keychain_args[@]}" --sign "${identity:--}" "$library"; done
# Inside out: Sparkle's Autoupdate and Updater.app, then the framework, then the app.
for part in "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"; do
    codesign --force --options runtime "${keychain_args[@]}" --sign "${identity:--}" --preserve-metadata=entitlements "$part"
done
# A local identity has no Team ID, so library validation would refuse the bundled Sparkle and sherpa-onnx; local builds
# alone allow their own bundled libraries. Every privacy entitlement stays exactly the release's.
entitlements="build/Mouthy-local.entitlements"
cp Resources/Mouthy.entitlements "$entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$entitlements"
codesign --force --options runtime --entitlements "$entitlements" "${keychain_args[@]}" --sign "${identity:--}" --identifier "$bundle_id" "$app"
codesign --verify --deep --strict "$app"
printf 'Built %s (signed: %s)\n' "$app" "${identity:-ad-hoc}"
if [[ -z "$identity" ]]; then
    print 'Ad-hoc build: code changes can invalidate macOS permissions. Re-enable Mouthy after rebuilding.'
fi
