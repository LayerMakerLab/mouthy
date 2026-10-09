# Building and testing

The repository holds two apps that share their text rules:

```
mac/              Mac app (Swift, SwiftUI and AppKit)
windows-linux/    Windows and Linux app (Rust and Tauri)
shared/           text-rules.json: behavior cases both test suites check
docs/             documentation
```

## Mac

Requires macOS 26 or later and Xcode 27. Open `mac/Package.swift` in Xcode, or use the scripts:

```sh
cd mac
./scripts/build.sh            # builds, signs and packages build/Mouthy.app (Apple silicon and Intel)
MOUTHY_VARIANT=dev ./scripts/build.sh   # "Mouthy Dev" in ~/Applications, with its own permissions
open build/Mouthy.app
./scripts/test.sh             # fast tests, no permissions needed
```

Mouthy asks for Microphone and Accessibility permission on first use. Without a signing identity the build is signed ad hoc, and macOS may ask for permissions again after each rebuild. To keep them, put a signing identity in `mac/scripts/local.env` (not committed):

```sh
MOUTHY_SIGNING_IDENTITY="Your certificate name"
```

More tests, each opt-in because it uses real hardware or downloads:

| Command | What it checks |
| --- | --- |
| `./scripts/test.sh --native` | Apple speech recognition, audio conversion and Apple Intelligence with synthesized speech |
| `./scripts/test.sh --parakeet` | Parakeet recognition, silence and vocabulary boosting (downloads the model) |
| `./scripts/test.sh --whisper` | Whisper recognition and timestamps (model must be downloaded) |
| `./scripts/test.sh --delivery` | Pasting into a hidden test app; never touches your real apps or focus |
| `./scripts/test.sh --microphone` | Microphone capture, by playing synthetic speech through the speakers |

The first build downloads the sherpa-onnx runtime that Intel Macs use for Parakeet, pinned by its SHA-256 checksum, and embeds Sparkle (the updater, pinned in `Package.resolved`) in `Contents/Frameworks`, signed inside-out before the app. Mouthy Dev has no feed URL, so it never checks for updates.

Source layout: `Sources/MouthyCore` holds the platform-free rules and models (testable without permissions); `Sources/MouthyKit` holds the app, speech engines and text delivery; `Sources/MouthyNotch` holds the notch hub; `Sources/MouthyUpdates` wraps Sparkle and is linked only by `Sources/Mouthy`, the app's entry point. The `Package.swift` at the repository root offers MouthyKit, MouthyCore and MouthyNotch as libraries to other apps, without Sparkle.

## Windows and Linux

Requires [Rust](https://rustup.rs) and the [Tauri prerequisites](https://v2.tauri.app/start/prerequisites/) for your system. The speech runtime (sherpa-onnx) is downloaded automatically during the first build.

```sh
cd windows-linux
cargo test                                 # text rules, settings, agent protocol
cargo build --release -p mouthy-app
```

**Linux:** `sh scripts/install-linux.sh` builds and installs for the current user (`~/.local/opt/mouthy`). On Wayland, `wl-clipboard` and `wtype` must be installed, and global shortcuts are bound in your compositor to `mouthy --toggle` (the script adds bindings for Hyprland).

**Windows:** release builds are cross-compiled from Linux with [cargo-xwin](https://github.com/rust-cross/cargo-xwin):

```sh
cargo xwin build --release --target x86_64-pc-windows-msvc -p mouthy-app
```

Copy `mouthy.exe` and the DLLs next to it to Windows and run `scripts/install-windows.ps1`, which installs to `%LOCALAPPDATA%\Programs\Mouthy` with a Start menu entry. Building directly on Windows with the MSVC Rust toolchain should also work, but release builds are not made that way.

Real-model test (downloads both models):

```sh
MOUTHY_TEST_MODELS=1 MOUTHY_TEST_WAV=speech.wav cargo test --release -p mouthy-app real_models -- --nocapture
```

`speech.wav` must be 16 kHz mono; on a Mac, `say -o speech.wav --data-format=LEI16@16000 "Hello there"` makes one.

## Release packages

- `mac/scripts/package-mac.sh` builds `dist/Mouthy-<version>-mac.zip` (Mouthy.app, zipped with `ditto`) and the signed update feed `dist/appcast.xml` beside it; it uploads nothing. To sign the app with a Developer ID and notarize it, see the options at the top of the script. A ZIP of a notarized, stapled app passes Gatekeeper when downloaded; a DMG would have to be notarized itself.
  - The feed and the ZIP are signed with Sparkle's EdDSA key, made once with `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account dev.mouthy.Mouthy`, which keeps the private key in your login Keychain and prints the public key for `SUPublicEDKey` in `mac/Resources/Info.plist`. The first signing asks macOS to let `generate_appcast` use the key; choose Always Allow. With a key that does not match Info.plist, `generate_appcast` leaves the ZIP unsigned and the script stops. `MOUTHY_SPARKLE_KEY_FILE` signs with a key file instead.
  - The app reads the feed from `https://mouthy.dev/updates/appcast.xml` and the ZIP from the same folder, so both files go there together.
- `windows-linux/scripts/package.sh` (run on Linux x86-64) builds `dist/Mouthy-<version>-linux-x64.tar.gz` and `dist/Mouthy-<version>-windows-x64.zip`.

## Shared behavior

Text rules exist twice, in Swift (`mac/Sources/MouthyCore`) and Rust (`windows-linux/core`). Every rule change needs a case in `shared/text-rules.json`; both test suites read that file, so the platforms cannot drift apart.
