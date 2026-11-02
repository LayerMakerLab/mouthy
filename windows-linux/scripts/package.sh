#!/bin/sh
# Run on Linux x86_64. Produces dist/Mouthy-<version>-linux-x64.tar.gz (with install.sh) and
# dist/Mouthy-<version>-windows-x64.zip (cross-compiled with cargo-xwin; includes install-windows.ps1).
# With the updater key present (MOUTHY_UPDATER_KEY, default ~/.config/mouthy/updater/mouthy.key, made by
# `cargo tauri signer generate`), it also signs both archives and writes the update feed dist/latest.json.
# `package.sh sign` does only that part, for a machine that holds the key but does not build. Nothing is
# uploaded: at release the archives go to the GitHub release and latest.json to https://mouthy.dev/updates/.
set -eu
cd "$(dirname "$0")/.."
version=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
mkdir -p ../dist
target="${CARGO_TARGET_DIR:-target}"
key="${MOUTHY_UPDATER_KEY:-$HOME/.config/mouthy/updater/mouthy.key}"
if [ "${1:-}" = sign ]; then
  [ -f "$key" ] || { echo "No updater key at $key" >&2; exit 1; }
else
conf_version=$(sed -n 's/^  "version": "\(.*\)",/\1/p' app/tauri.conf.json)
[ "$conf_version" = "$version" ] || { echo "tauri.conf.json says $conf_version but Cargo.toml says $version" >&2; exit 1; }
export MOUTHY_UPDATES=1   # the only builds that update themselves (updates::install_dir)
rm -f "../dist/Mouthy-$version-linux-x64.tar.gz" "../dist/Mouthy-$version-windows-x64.zip" ../dist/Mouthy-"$version"-*.sig ../dist/latest.json
# Keep build-machine paths (home folder, checkout) out of the shipped binaries.
cargo_home="${CARGO_HOME:-$HOME/.cargo}"
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$cargo_home=/cargo --remap-path-prefix=$(cd .. && pwd)=/mouthy --remap-path-prefix=$HOME=/build"
cargo build --release -p mouthy-app
# Refuse to ship a binary that carries this machine's home folder (Tauri's codegen embeds the crate's absolute path,
# which --remap-path-prefix does not reach): build from a checkout outside $HOME.
leaks() { for f in "$@"; do if LC_ALL=C grep -aqF "$HOME/" "$f"; then echo "refusing to package: $f contains $HOME/" >&2; return 0; fi; done; return 1; }
leaks "$target"/release/mouthy "$target"/release/*.so* && exit 1
linux="$(mktemp -d)/mouthy"
mkdir -p "$linux"
cp "$target"/release/mouthy "$target"/release/*.so* app/icons/icon.png "$linux/"
cp ../LICENSE "$linux/LICENSE.txt"; cp THIRD-PARTY.md "$linux/"   # GPL-3.0 text and notices ship with the program
cat > "$linux/install.sh" <<'SH'
#!/bin/sh
# Installs Mouthy for the current user from this folder.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.local/opt/mouthy"
mkdir -p "$dest" "$HOME/.local/bin" "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/256x256/apps"
cp "$here"/mouthy "$here"/*.so* "$dest/"
ln -sf "$dest/mouthy" "$HOME/.local/bin/mouthy"
cp "$here/icon.png" "$HOME/.local/share/icons/hicolor/256x256/apps/mouthy.png"
printf '[Desktop Entry]\nType=Application\nName=Mouthy\nComment=Local dictation\nExec=%s\nIcon=mouthy\nCategories=Utility;Accessibility;\n' "$dest/mouthy" > "$HOME/.local/share/applications/mouthy.desktop"
echo "Installed Mouthy. On Wayland, bind a key to: $dest/mouthy --toggle"
SH
chmod +x "$linux/install.sh"
# no builder user or group names in the archive
tar --owner=0 --group=0 --numeric-owner -C "$(dirname "$linux")" -czf "../dist/Mouthy-$version-linux-x64.tar.gz" mouthy
XWIN_ACCEPT_LICENSE=1 cargo xwin build --release --target x86_64-pc-windows-msvc -p mouthy-app
leaks "$target"/x86_64-pc-windows-msvc/release/mouthy.exe "$target"/x86_64-pc-windows-msvc/release/*.dll && exit 1
win="$(mktemp -d)/Mouthy"
mkdir -p "$win"
cp "$target"/x86_64-pc-windows-msvc/release/mouthy.exe "$target"/x86_64-pc-windows-msvc/release/*.dll scripts/install-windows.ps1 "$win/"
cp ../LICENSE "$win/LICENSE.txt"; cp THIRD-PARTY.md "$win/"
(cd "$(dirname "$win")" && zip -qrX "$OLDPWD/../dist/Mouthy-$version-windows-x64.zip" Mouthy)
fi
if [ -f "$key" ]; then
  rm -f ../dist/Mouthy-"$version"-*.sig ../dist/latest.json
  downloads="https://github.com/LayerMakerLab/mouthy/releases/download/v$version"
  for archive in linux-x64.tar.gz windows-x64.zip; do
    # Writes <archive>.sig next to it; the key itself is never printed.
    TAURI_SIGNING_PRIVATE_KEY_PASSWORD="" cargo tauri signer sign -f "$key" --app-version "$version" "../dist/Mouthy-$version-$archive" >/dev/null
  done
  printf '{\n  "version": "%s",\n  "pub_date": "%s",\n  "platforms": {\n    "linux-x86_64": { "url": "%s", "signature": "%s" },\n    "windows-x86_64": { "url": "%s", "signature": "%s" }\n  }\n}\n' \
    "$version" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$downloads/Mouthy-$version-linux-x64.tar.gz" "$(cat "../dist/Mouthy-$version-linux-x64.tar.gz.sig")" \
    "$downloads/Mouthy-$version-windows-x64.zip" "$(cat "../dist/Mouthy-$version-windows-x64.zip.sig")" > ../dist/latest.json
else
  echo "No updater key at $key: built the archives without the update feed."
fi
ls -lh ../dist
