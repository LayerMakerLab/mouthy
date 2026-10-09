#!/bin/sh
# Builds Mouthy and installs it for the current user: ~/.local/opt/mouthy, ~/.local/bin/mouthy,
# a desktop entry, and (on Hyprland with a Lua config) Super+Alt+D / Super+Alt+Z bindings.
set -eu
cd "$(dirname "$0")/.."
cargo build --release -p mouthy-app
dest="$HOME/.local/opt/mouthy"
mkdir -p "$dest" "$HOME/.local/bin" "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/256x256/apps"
install -m 755 target/release/mouthy "$dest/mouthy"
cp -P target/release/*.so* "$dest/"
ln -sf "$dest/mouthy" "$HOME/.local/bin/mouthy"
install -m 644 app/icons/icon.png "$HOME/.local/share/icons/hicolor/256x256/apps/mouthy.png"
cat > "$HOME/.local/share/applications/mouthy.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Mouthy
Comment=Local dictation with Parakeet and Whisper
Exec=$dest/mouthy
Icon=mouthy
Categories=Utility;Accessibility;
DESKTOP
bindings="$HOME/.config/hypr/bindings.lua"
if [ -f "$bindings" ] && ! grep -q "mouthy --toggle" "$bindings"; then
  printf '\n-- >>> mouthy dictation >>>\no.bind("SUPER + ALT + D", "Mouthy dictation", "%s --toggle")\no.bind("SUPER + ALT + Z", "Cancel dictation", "%s --cancel")\n-- <<< mouthy dictation <<<\n' "$dest/mouthy" "$dest/mouthy" >> "$bindings"
fi
echo "Installed Mouthy to $dest"
