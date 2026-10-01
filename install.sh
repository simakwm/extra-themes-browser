#!/bin/bash
# Sync this checkout into the Omarchy plugin directory. A real directory (not a
# symlink) is required: the shell rejects bar widgets that load through one.
set -euo pipefail
src=$(cd "$(dirname "$0")" && pwd)
dest="$HOME/.config/omarchy/plugins/io.github.simakwm.extra-themes"

[[ -L $dest ]] && rm "$dest"
mkdir -p "$dest"
rsync -a --delete --exclude '.git' --exclude 'install.sh' "$src/" "$dest/"
omarchy plugin validate "$dest"
omarchy-shell shell rescanPlugins >/dev/null
echo "Installed to $dest"
