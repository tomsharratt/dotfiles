#!/usr/bin/env bash
# Sync configs from this repo into the current environment.
# Mirrors each .config/<name> dir into ~/.config/<name> and installs fonts
# from .local/share/fonts into the OS-appropriate font directory.

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

if [ -d "$repo/.local/share/fonts" ]; then
  mkdir -p "$fonts_dst"
  rsync -a "$repo/.local/share/fonts/" "$fonts_dst/"
  echo "fonts:         →  $fonts_dst"
fi
