#!/usr/bin/env bash
# Sync configs from this repo into the current environment.
# Mirrors each .config/<name> dir into ~/.config/<name>, installs the
# executables under .local/bin, and installs fonts from .local/share/fonts
# into the OS-appropriate font directory.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$(uname -s)" in
  Darwin) fonts_dst="$HOME/Library/Fonts" ;;
  *)      fonts_dst="$HOME/.local/share/fonts" ;;
esac

for dir in "$repo"/.config/*/; do
  [ -d "$dir" ] || continue
  name="$(basename "$dir")"
  dst="$HOME/.config/$name"
  mkdir -p "$dst"
  rsync -a --delete "$dir" "$dst/"
  echo "config: $name  →  $dst"
done

# Executables under .local/bin: install each tracked file individually.
# Unlike .config, this dir is shared with unmanaged binaries, so never --delete;
# copy file-by-file and preserve the executable bit.
if [ -d "$repo/.local/bin" ]; then
  mkdir -p "$HOME/.local/bin"
  for f in "$repo"/.local/bin/*; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    install -m 0755 "$f" "$HOME/.local/bin/$name"
    echo "bin:    $name  →  $HOME/.local/bin/$name"
  done
fi

if [ -d "$repo/.local/share/fonts" ]; then
  mkdir -p "$fonts_dst"
  rsync -a "$repo/.local/share/fonts/" "$fonts_dst/"
  echo "fonts:         →  $fonts_dst"
fi
