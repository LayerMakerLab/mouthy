#!/bin/sh
# Run on Linux x86_64. Produces dist/Mouthy-<version>-linux-x64.tar.gz (with install.sh) and
# dist/Mouthy-<version>-windows-x64.zip (cross-compiled with cargo-xwin; includes install-windows.ps1).
set -eu
cd "$(dirname "$0")/.."
version=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
mkdir -p ../dist
target="${CARGO_TARGET_DIR:-target}"
rm -f "../dist/Mouthy-$version-linux-x64.tar.gz" "../dist/Mouthy-$version-windows-x64.zip"
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
ls -lh ../dist
