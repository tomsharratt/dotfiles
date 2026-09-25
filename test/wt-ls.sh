#!/usr/bin/env bash
# test/wt-ls.sh - `wt ls` fits its table to the terminal it prints to, and only to one.
#
# The bug this pins: render_table padded every column to its widest cell with no
# limit, so on an 80-column terminal every row of the real inventory ran 85 to 128
# characters and wrapped onto a second line. It now shrinks the way `pq ls` does,
# and a url that cannot be shown whole is dropped rather than cut: a cut url is
# still a link, to a host that does not exist. Piped, the table is what it always
# was - nothing can wrap, and whatever reads it wants every cell whole.
#
# Driven through the real `wt ls` on a real pseudo-terminal: `script` gives the
# command one and `stty cols` sets its width. script refuses a stdin that is not a
# terminal, so stdin is /dev/null, and it echoes that EOF back as "^D" and two
# backspaces, wherever in the output that lands - all stripped, with the pty's
# carriage returns, before anything is measured.
#
# SC2015: `ok` never fails, so `[ ... ] && ok || bad` is an if/else.
# shellcheck disable=SC2015
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WT="$HERE/../.local/bin/wt"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT

# No herdr under this HOME, so AGENT reads "?"; nothing here needs one.
export HOME="$FIX/home" XDG_STATE_HOME="$FIX/state" XDG_CONFIG_HOME="$FIX/config"
STATE_DIR="$XDG_STATE_HOME/wt"
mkdir -p "$HOME" "$STATE_DIR" "$FIX/bin"

# Three worktrees with the lengths of the live ones. A fixed commit date keeps AGE
# the same from one run to the next, so two renderings can be compared.
REPO="$FIX/supercast"
git init -q -b master "$REPO"
GIT_COMMITTER_DATE="2020-01-01T00:00:00Z" \
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
port=3101
for b in tom/fix-follow-account-takeover tom/follower-gated-livestreams fix-back-to-back-premieres; do
  slug=${b//\//-}
  git -C "$REPO" worktree add -q -b "$b" "$FIX/wt/$slug"
  printf 'WT_REPO=%s\nWT_PATH=%s\nWT_SLUG=%s\nWT_PORT=%s\nWT_URL=https://%s.test\n' \
    "$REPO" "$FIX/wt/$slug" "$slug" "$port" "$slug" > "$STATE_DIR/supercast--$slug.env"
  port=$((port + 1))
done

cat > "$FIX/bin/gh" <<'EOF'
#!/bin/sh
case "$*" in
  *"--limit 200"*) printf '%s' '[
    {"number":6843,"state":"MERGED","headRefName":"tom/fix-follow-account-takeover"},
    {"number":6849,"state":"MERGED","headRefName":"tom/follower-gated-livestreams"},
    {"number":6738,"state":"CLOSED","headRefName":"fix-back-to-back-premieres"}]' ;;
  *) printf '[]' ;;
esac
EOF
chmod +x "$FIX/bin/gh"
export PATH="$FIX/bin:$PATH"

# Run from outside any repo: wt also lists the worktrees of the one it is run in.
ls_on_tty() {                           # cols -> the table wt ls prints on a terminal that wide
  script -q /dev/null bash -c "stty cols $1; cd '$FIX' && '$WT' ls 2>/dev/null" </dev/null 2>&1 \
    | tr -d '\r\010' | sed 's/\^D//g'
}
widest() { awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }'; }

PIPED=$(cd "$FIX" && "$WT" ls 2>/dev/null)
NATURAL=$(widest <<<"$PIPED")

echo "== piped, the table is whole: full branches and full urls ==" >&2
case "$PIPED" in *"tom/fix-follow-account-takeover "*) ok ;; *) bad "a piped table keeps the full branch (got: $PIPED)" ;; esac
case "$PIPED" in *"https://tom-follower-gated-livestreams.test"*) ok ;; *) bad "and the full url (got: $PIPED)" ;; esac
case "$PIPED" in *..*) bad "and cuts nothing (got: $PIPED)" ;; *) ok ;; esac
[ "$NATURAL" -gt 100 ] && ok || bad "the fixture is wider than 100 columns, so the cases below shrink it (got $NATURAL)"

echo "== on a terminal wide enough, exactly the piped table ==" >&2
eq "$(ls_on_tty 200)" "$PIPED" "a table that fits renders as it would with no width at all"

for cols in 80 60 40; do
  echo "== on a $cols-column terminal, no line is wider than it ==" >&2
  out=$(ls_on_tty "$cols")
  [ "$(widest <<<"$out")" -le "$cols" ] && ok || bad "a line exceeded $cols columns:
$out"
  [ "$(grep -c . <<<"$out")" = 4 ] && ok || bad "still a header and three rows at $cols (got: $out)"
  # No header is ever cut: they are the floor every column shrinks to.
  eq "$(head -1 <<<"$out" | tr -s ' ')" "REPO BRANCH PORT AGE AGENT PR" \
    "the headers are whole at $cols, and URL has gone"
  case "$out" in *https:*) bad "no url is cut short into a link to nowhere at $cols (got: $out)" ;; *) ok ;; esac
done

echo "== one column over, and it is the url that goes, not a character of anything else ==" >&2
out=$(ls_on_tty $((NATURAL - 1)))
case "$out" in *https:*) bad "the url column is dropped when the table misses by one (got: $out)" ;; *) ok ;; esac
case "$out" in *"tom/fix-follow-account-takeover "*) ok ;; *) bad "and the branch stays whole (got: $out)" ;; esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
