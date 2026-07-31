#!/usr/bin/env bash
# test/pq-width.sh - term_width and render_table's shrink-to-fit: no rendered
# line exceeds the target width, no header cell is ever truncated, a table
# that already fits renders byte-identical to the pre-shrink renderer, and the
# unpadded last column truncates too instead of overflowing on its own.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PQ_HOME=$(mktemp -d)
export PQ_HOME

STUBBIN=$(mktemp -d)
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/claude"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/gh"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/herdr"
chmod +x "$STUBBIN/claude" "$STUBBIN/gh" "$STUBBIN/herdr"
export PATH="$STUBBIN:$PATH"

# shellcheck source=/dev/null
source "$HERE/../.local/bin/pq"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() {                                   # got want msg
  [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"
}

cleanup() { rm -rf "$PQ_HOME" "$STUBBIN"; }
trap cleanup EXIT

# Reference implementation of the PRE-shrink renderer - exactly what
# render_table did before this change - kept here (not sourced from pq) so
# "byte-identical when it already fits" is checked against a fixed baseline
# rather than against itself.
old_render_table() {
  awk -F'\t' '
    { rows = NR; if (NF > n) n = NF
      for (i = 1; i <= NF; i++) { cell[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) } }
    END {
      for (r = 1; r <= rows; r++) {
        line = ""
        for (i = 1; i <= n; i++) line = line (i == n ? cell[r, i] : sprintf("%-*s  ", w[i], cell[r, i]))
        sub(/[ \t]+$/, "", line); print line
      }
    }
  ' "$1"
}

widetbl() {                             # a table whose natural width is well over 80
  local tbl="$PQ_HOME/.wide.$$.tsv"
  printf 'TASK\tPROJECT\tSTATE\tAGENT\tPR\tAGE\n' > "$tbl"
  printf 'drop-mux-assets-table\tsupercast\tqueue\tafter remove-mux-vid..\t-\t22h\n' >> "$tbl"
  printf 'bulk-email-subscribers-with-a-really-long-name-here\tsupercast\tqueue\tafter fix-bulk-action-filter-injection +1\t-\t1h\n' >> "$tbl"
  printf 'remove-mux-video-backend\tsupercast\tdone\t-\t#6387 open with a rather long trailing status blob\t22h\n' >> "$tbl"
  printf '%s' "$tbl"
}

echo "== term_width: PQ_WIDTH is honoured when it is a sane number ==" >&2
eq "$(PQ_WIDTH=60 term_width)" "60" "PQ_WIDTH=60 should be used as-is"
eq "$(PQ_WIDTH=200 term_width)" "200" "a large PQ_WIDTH should be used as-is"

echo "== term_width: an out-of-range or non-numeric PQ_WIDTH falls back to 100 ==" >&2
eq "$(PQ_WIDTH=39 term_width)" "100" "below the 40-column floor should fall back to 100"
eq "$(PQ_WIDTH=0 term_width)" "100" "zero should fall back to 100"
eq "$(PQ_WIDTH=notanumber term_width)" "100" "a non-numeric override should fall back to 100"
eq "$(PQ_WIDTH=40 term_width)" "40" "exactly the 40-column floor should be accepted"

for W in 80 60 40; do
  echo "== render_table: at PQ_WIDTH=$W, no rendered line exceeds $W ==" >&2
  tbl=$(widetbl)
  out=$(PQ_WIDTH=$W render_table "$tbl")
  toowide=$(awk -v w="$W" '{ if (length($0) > w) print }' <<<"$out")
  [ -z "$toowide" ] && ok || bad "a line at PQ_WIDTH=$W exceeded it: $toowide"
  rm -f "$tbl"
done

echo "== render_table: no header cell is ever truncated, even far below its own headers total width ==" >&2
tbl=$(widetbl)
out=$(PQ_WIDTH=40 render_table "$tbl")
header=$(sed -n '1p' <<<"$out")
for word in TASK PROJECT STATE AGENT PR AGE; do
  case "$header" in *"$word"*) ok ;; *) bad "header should still contain '$word' intact (got: $header)" ;; esac
done
case "$header" in *".."*) bad "no header word should ever be truncated with '..' (got: $header)" ;; *) ok ;; esac
rm -f "$tbl"

echo "== render_table: a table that already fits renders byte-identical to the pre-shrink renderer ==" >&2
tbl=$(widetbl)
a=$(old_render_table "$tbl")
b=$(render_table "$tbl" 500)
eq "$b" "$a" "at a width nothing needs to shrink into, output must match the old renderer exactly"
rm -f "$tbl"

echo "== render_table: the last column truncates too, instead of overflowing on its own ==" >&2
tbl="$PQ_HOME/.lastcol.$$.tsv"
printf 'TASK\tPR\n' > "$tbl"
printf 'a\t#6387 open with a very long trailing status blob that would overflow unpadded\n' >> "$tbl"
out=$(render_table "$tbl" 30)
maxlen=$(awk '{ print length($0) }' <<<"$out" | sort -n | tail -1)
[ "$maxlen" -le 30 ] && ok || bad "the last column must be truncated to fit, not left to overflow (max line length $maxlen)"
lastline=$(sed -n '2p' <<<"$out")
case "$lastline" in *".."*) ok ;; *) bad "an over-long last-column cell should be truncated with '..' (got: $lastline)" ;; esac
rm -f "$tbl"

echo "== render_table: an explicit width argument overrides PQ_WIDTH/term_width ==" >&2
tbl=$(widetbl)
out=$(PQ_WIDTH=200 render_table "$tbl" 40)
toowide=$(awk '{ if (length($0) > 40) print }' <<<"$out")
[ -z "$toowide" ] && ok || bad "an explicit width argument should win over PQ_WIDTH: $toowide"
rm -f "$tbl"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
