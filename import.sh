#!/usr/bin/env bash
# Pull configs from the current environment back into this repo.
# Only syncs the dirs/files that are already tracked here — never expands
# the set of things this repo manages.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$(uname -s)" in
  Darwin) fonts_src="$HOME/Library/Fonts" ;;
  *)      fonts_src="$HOME/.local/share/fonts" ;;
esac

for dir in "$repo"/.config/*/; do
  [ -d "$dir" ] || continue
  name="$(basename "$dir")"
  src="$HOME/.config/$name"
  if [ -d "$src" ]; then
    rsync -a --delete "$src/" "$dir"
    echo "config: $src  →  .config/$name"
  else
    echo "skip:   .config/$name (not present in env)"
  fi
done

for font in "$repo"/.local/share/fonts/*; do
  [ -e "$font" ] || continue
  name="$(basename "$font")"
  src="$fonts_src/$name"
  if [ -e "$src" ]; then
    cp "$src" "$font"
    echo "font:   $src  →  .local/share/fonts/$name"
  else
    echo "skip:   $name (not present in $fonts_src)"
  fi
done
