#!/usr/bin/env bash
# ~/.config/tmux/next-meeting.sh
#
# Prints the next (or currently-in-progress) *timed* calendar event for today
# into the tmux status bar, in Rose Pine colors. Prints a muted "no meetings"
# segment once the day's meetings are done. All-day items (holidays, PTO,
# birthdays) are ignored -- they aren't meetings you show up to at a time.
#
# Reads the local macOS Calendar via icalBuddy and caches the fetch for TTL
# seconds, so the 5s status tick never hammers the calendar. The *display*
# (countdown / in-progress) is recomputed live on every tick from the cache,
# so "in 14m" stays accurate to the minute without re-fetching.
#
# Wire into tmux.conf (see next-meeting section):
#   set -g status-right "#[fg=$subtle]%a %d %b #(/Users/tsharratt/.config/tmux/next-meeting.sh)"

set -euo pipefail

ICALBUDDY="/opt/homebrew/bin/icalBuddy"
CACHE="${TMPDIR:-/tmp}/tmux-next-meeting.cache"
LOCK="${TMPDIR:-/tmp}/tmux-next-meeting.lock"
TTL=60                         # seconds between real calendar fetches
SEP=$'\t'                       # icalBuddy field separator -- a tab can never appear in a title

# Rose Pine (main) -- keep in sync with tmux.conf palette.
IRIS="#c4a7e7"; GOLD="#f6c177"; MUTED="#6e6a86"; TEXT="#e0def4"; HL_MED="#403d52"

# ── Refresh the cache if stale ──────────────────────────────────────────
# Cache line format:  START_MIN <TAB> END_MIN <TAB> title
#   START_MIN / END_MIN = minutes since local midnight (integers)
refresh() {
  local out
  out="$("$ICALBUDDY" -nc -nrd -b '' -ps "|$SEP|" \
        -iep 'datetime,title' -po 'datetime,title' \
        -df '%Y-%m-%d' -tf '%H:%M' eventsToday 2>/dev/null)" || return 1

  printf '%s\n' "$out" \
    | awk -v FS="$SEP" '
        {
          dt = $1; title = $2
          # Pull HH:MM tokens out of the datetime field: 1st = start, 2nd = end.
          n = 0; s = dt
          while (match(s, /[0-9][0-9]:[0-9][0-9]/)) {
            tok = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
            split(tok, hm, ":"); mins = hm[1] * 60 + hm[2]
            n++
            if (n == 1) start = mins
            if (n == 2) end   = mins
          }
          if (n == 0) next            # all-day event -> not a meeting
          if (n == 1) end = start + 60 # no end parsed -> assume 60 min
          gsub(/^[ \t]+|[ \t]+$/, "", title)
          if (title == "") next
          printf "%d\t%d\t%s\n", start, end, title
        }' \
    | sort -n > "$CACHE.tmp" && mv -f "$CACHE.tmp" "$CACHE"
}

# Is the cache stale (missing, or older than TTL)?
now_epoch=$(date +%s)
stale=1
if [[ -f "$CACHE" ]]; then
  mtime=$(stat -f %m "$CACHE" 2>/dev/null || echo 0)
  (( now_epoch - mtime < TTL )) && stale=0
fi

# Refresh under a single-writer lock; other panes fall back to the cache.
if (( stale )); then
  # Reclaim a lock orphaned by a refresh that was killed before its EXIT trap ran
  # (SIGKILL, machine sleep). The lock only guards a sub-second fetch, so any lock
  # older than the TTL is defunct - without this, one orphaned lock freezes the
  # calendar (stuck on the last cache) until the temp dir is cleared by hand.
  if [[ -d "$LOCK" ]]; then
    lock_mtime=$(stat -f %m "$LOCK" 2>/dev/null || echo 0)
    (( now_epoch - lock_mtime >= TTL )) && rmdir "$LOCK" 2>/dev/null || true
  fi
  if mkdir "$LOCK" 2>/dev/null; then
    trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
    refresh || true
  fi
fi

[[ -f "$CACHE" ]] || exit 0

# ── Pick + format the next / in-progress event ──────────────────────────
now_min=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))

awk -F '\t' -v now="$now_min" \
    -v iris="$IRIS" -v gold="$GOLD" -v muted="$MUTED" -v text="$TEXT" -v hl="$HL_MED" '
  $2 > now {                              # event has not ended yet
    if (!found || $1 < best_start) { found = 1; best_start = $1; best_title = $3 }
  }
  END {
    sep = "#[fg=" hl "]│ "
    if (!found) {                         # no upcoming / in-progress meetings today
      printf "%s#[fg=%s]no meetings ", sep, muted
      exit 0
    }
    t = best_title
    gsub(/#/, "##", t)                    # tmux treats # as a format directive
    if (length(t) > 26) t = substr(t, 1, 25) "…"
    if (best_start <= now) {              # in progress right now
      printf "%s#[fg=%s]● now #[fg=%s]· #[fg=%s]%s ", sep, gold, muted, text, t
    } else {
      d = best_start - now
      if (d <= 60) label = d "m"          # within the hour: countdown
      else label = sprintf("%d:%02d", int(best_start / 60), best_start % 60)
      printf "%s#[fg=%s]○ %s #[fg=%s]· #[fg=%s]%s ", sep, iris, label, muted, text, t
    }
  }' "$CACHE"
