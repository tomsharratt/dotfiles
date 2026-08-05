#!/usr/bin/env bash
# test/pq-quota.sh - the session wall: detecting it, waiting it out, and knocking.
# Exercises pane_tail / reset_hint / parse_reset / clock_of / check_stall directly,
# then the whole thing through tick_body, the same way test/pq-slots.sh does for the
# cap arithmetic.
#
# Three bugs are pinned here, and every one of them was silent. The section had never
# once fired in production:
#
#   1. pane_tail piped `herdr ... --format text` - which is text - through
#      `jq '.result.read.text'`, so it returned the empty string on every tick of
#      every task, and check_stall read that as "could not see the pane" and left.
#      Everything below it was dead code.
#   2. The reset hint was stored as prose. `PQ_RESETS=3pm (PDT)` is a bash SYNTAX
#      ERROR, and `st` reads state.env by sourcing it - so bash abandoned the file at
#      that line and every key check_stall wrote after it (PQ_BLOCKED, PQ_QUOTA_SINCE,
#      PQ_TRIES, PQ_RETRY_AT - all four of them) read back empty. The state machine
#      could never leave first-detection: it re-detected, re-dismissed, and never
#      reached a knock.
#   3. The retry schedule was cancelled whenever the wall was not on screen. Claude
#      Code's banner is live UI derived from the reset time, so it clears ITSELF at
#      the reset - which is exactly when the knock comes due. The plan was thrown
#      away at the one moment it mattered.
#
# The case that decides whether the cure is real is the one where a rate-limit
# statusline turns over at the reset while the agent stays idle: the tail moves, the
# banner goes, nothing has resumed, and pq must knock rather than forget.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PQ_HOME=$(mktemp -d)
export PQ_HOME

# Stubs so nothing here reaches a network or a real herdr socket - same reasoning as
# test/pq-slots.sh. This file's `herdr` has to do rather more than that one's: it
# serves `pane read` out of a per-pane file each case writes, and it RECORDS every
# send-keys/send-text, because "what did pq type at the agent" is the entire question
# for half the cases below.
STUBBIN=$(mktemp -d)
PANES_JSON="$STUBBIN/.panes.json"
SENTLOG="$STUBBIN/.sent"
printf '{"result":{"snapshot":{"panes":[]}}}' > "$PANES_JSON"
: > "$SENTLOG"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/claude"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/gh"
cat > "$STUBBIN/herdr" <<EOF
#!/bin/sh
# Pane ids carry a colon; the files they are stored in do not.
key=\$(printf '%s' "\$3" | tr ':' '_')
case "\$1 \$2" in
  "api snapshot")    cat "$PANES_JSON"; exit 0 ;;
  "pane read")       [ -f "$STUBBIN/pane.\$key" ] && cat "$STUBBIN/pane.\$key"; exit 0 ;;
  "pane send-keys")  shift 3; printf 'keys %s\n' "\$*" >> "$SENTLOG"; exit 0 ;;
  "pane send-text")  shift 3; printf 'text %s\n' "\$*" >> "$SENTLOG"; exit 0 ;;
esac
exit 1
EOF
printf '#!/bin/sh\nexit 0\n' > "$STUBBIN/wt-stub"
chmod +x "$STUBBIN/claude" "$STUBBIN/gh" "$STUBBIN/herdr" "$STUBBIN/wt-stub"
export PATH="$STUBBIN:$PATH"
export PQ_WT="$STUBBIN/wt-stub"

# shellcheck source=/dev/null
source "$HERE/../.local/bin/pq"

# Never let a tick_body case pay for a real `gh` round trip - each one primes
# PR_CACHE itself. Same neutering as test/pq-slots.sh.
pr_load_all() { :; }
# unstick sleeps a second between dismissing a dialog and typing into what is behind
# it. That is a UI settle, not logic, and paying it on every knock case would put
# seconds on the suite for nothing.
sleep() { :; }

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }
has() { case "$1" in *"$2"*) ok ;; *) bad "$3 (got '$1')" ;; esac; }
hasnt() { case "$1" in *"$2"*) bad "$3 (got '$1')" ;; *) ok ;; esac; }

cleanup() { rm -rf "$PQ_HOME" "$STUBBIN" "${REPO:-}"; }
trap cleanup EXIT

# A real throwaway repo, for the same reason test/pq-slots.sh builds one: hdr's repo
# field is checked for existence on the dispatch path.
REPO=$(mktemp -d)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$REPO/.git/refs/remotes/origin"
git -C "$REPO" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master

# A clean baseline regardless of the ambient environment - this test may well run
# inside a Herdr pane, and reap_ok reads exactly these.
unset HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID

PQ_DONE_KEEP=99
PQ_WRAPUP_GRACE=300
PQ_QUOTA_RETRY=600
PQ_QUOTA_MAX_TRIES=40

reset_tasks() {
  rm -rf "$PQ_HOME/queue" "$PQ_HOME/hold" "$PQ_HOME/running" "$PQ_HOME/done" "$PQ_HOME/archive"
  mkdir -p "$PQ_HOME/queue" "$PQ_HOME/hold" "$PQ_HOME/running" "$PQ_HOME/done" "$PQ_HOME/archive"
}
reset_tasks

now_e() { date '+%s'; }
ago() { date -u -v-"$1"S '+%Y-%m-%dT%H:%M:%SZ'; }

TICKOUT="$PQ_HOME/.tick.out"
tick() {                                # cap dry -> stdout+stderr in $OUT
  PQ_SUMMARY=""
  tick_body "$1" "$2" > "$TICKOUT" 2>&1
  OUT=$(cat "$TICKOUT")
}

reset_caches() { PR_CACHE="$PQ_HOME/.test.pr"; PR_ANS="$PQ_HOME/.test.ans"; : > "$PR_CACHE"; : > "$PR_ANS"; }
cache_row() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$PR_CACHE"; }

mk_task() {                             # state prio slug branch pane -> task_dir
  local state=$1 prio=$2 slug=$3 branch=$4 pane=$5
  local dir="$PQ_HOME/$state/$(printf '%014d' $(( 20260101000000 + 10#$prio )))-$slug"
  mkdir -p "$dir"
  {
    printf -- '---\n'
    printf 'repo:     %s\n' "$REPO"
    printf 'branch:   %s\n' "$branch"
    printf 'model:    sonnet\n'
    printf 'effort:   xhigh\n'
    printf 'dev:      false\n'
    printf 'intent:   test fixture\n'
    printf 'added:    2026-01-01T00:00:00Z\n'
    printf -- '---\n\nplan body\n'
  } > "$dir/plan.md"
  [ -n "$pane" ] && st_set "$dir" PQ_PANE "$pane"
  printf '%s' "$dir"
}

set_panes() {                           # "pane<TAB>agent<TAB>status" lines
  PIDX=$1; PIDX_OK=1
  if [ -z "$1" ]; then
    printf '{"result":{"snapshot":{"panes":[]}}}' > "$PANES_JSON"
    return
  fi
  jq -Rs 'split("\n") | map(select(length > 0) | split("\t")
            | { pane_id: .[0],
                agent:        (if (.[1] // "") == "" then null else .[1] end),
                agent_status: (if (.[2] // "") == "" then null else .[2] end) })
          | { result: { snapshot: { panes: . } } }' <<<"$1" > "$PANES_JSON"
}

pane_file() { printf '%s/pane.%s' "$STUBBIN" "$(printf '%s' "$1" | tr ':' '_')"; }
set_text() { cat > "$(pane_file "$1")"; }        # pane, text on stdin

sent_reset() { : > "$SENTLOG"; }
sent() { cat "$SENTLOG"; }

# What a walled Claude Code session actually looks like: the banner it prints
# ("You've hit your session limit · resets 3pm (PDT)" - kNt.five_hour plus an
# absolute reset), and below it a statusline reporting the same rate limits from the
# other end. Both carry a "resets", which is the whole reason reset_hint has to
# choose between them.
walled_text() {                         # pane banner_time statusline_pct statusline_time
  set_text "$1" <<EOF
> ship the fix

⏺ You've hit your session limit · resets $2 (PDT)

────────────────────────────────────────────────
❯
────────────────────────────────────────────────
  235.7K / 1M · session $3% (resets $4)
  ⏵⏵ auto mode on (shift+tab to cycle) · PR #12
EOF
}

# The same pane after the wall is over: the banner has cleared itself, and only the
# statusline is left - carrying a new percentage and a new window.
settled_text() {                        # pane statusline_pct statusline_time
  set_text "$1" <<EOF
> ship the fix

⏺ Working on it.

────────────────────────────────────────────────
❯
────────────────────────────────────────────────
  235.7K / 1M · session $2% (resets $3)
  ⏵⏵ auto mode on (shift+tab to cycle) · PR #12
EOF
}

# ── pane_tail: the read that was returning nothing at all ────────────────────

echo "== pane_tail returns the pane's text, not the empty string ==" >&2
# Bug 1, and the only pin that matters: `herdr pane read --format text` prints raw
# terminal text, so anything that tries to unwrap a JSON envelope around it gets
# nothing, silently, for ever.
set_text w9:p1 <<'EOF'
⏺ You've hit your session limit · resets 3pm (PDT)
EOF
T=$(pane_tail w9:p1)
[ -n "$T" ] && ok || bad "pane_tail must return the pane's text (it returned nothing - bug 1)"
has "$T" "hit your session limit" "pane_tail must return the text verbatim"
eq "$(classify_tail "$T")" quota "and that text must classify as the wall"

echo "== pane_tail: no pane, no text, and an error envelope is not text ==" >&2
eq "$(pane_tail '')" "" "no pane id means no text"
eq "$(pane_tail wZ:p9)" "" "a pane herdr knows nothing about yields nothing"
# `pane read` answers for a pane with no agent bound, which is what makes the
# noagent case work at all - but it can still fail, and an error object must not be
# mistaken for something an agent printed.
set_text wE:p1 <<'EOF'
{"error":{"code":"pane_not_found","message":"pane target wE:p1 not found"},"id":"cli:pane:read"}
EOF
eq "$(pane_tail wE:p1)" "" "an error envelope is dropped rather than classified"

echo "== pane_tail honours PQ_TAIL_LINES ==" >&2
{ for i in $(seq 1 60); do printf 'line %s\n' "$i"; done; } > "$(pane_file wT:p1)"
eq "$(pane_tail wT:p1 | wc -l | tr -d ' ')" "$PQ_TAIL_LINES" "only the last PQ_TAIL_LINES lines are read"
eq "$(pane_tail wT:p1 | tail -1)" "line 60" "and they are the ones at the bottom"

# ── reset_hint / parse_reset / clock_of ──────────────────────────────────────

echo "== reset_hint prefers the wall's own line over the statusline's ==" >&2
# The statusline is drawn BELOW the transcript, so `tail -1` took its hint every
# time - naming the five-hour window even when the weekly one was what walled us,
# and handing parse_reset a trailing bracket it could not read.
BOTH=$(printf '%s\n%s\n' \
  "⏺ You've hit your weekly limit · resets Jul 28, 8pm" \
  "  235.7K / 1M · session 98% (resets 10:40pm)")
eq "$(reset_hint "$BOTH")" "Jul 28, 8pm" "the wall's hint wins"
eq "$(reset_hint "  235.7K / 1M · session 70% (resets 10:40pm)")" "10:40pm" \
   "with no wall on screen the statusline is the fallback, bracket stripped"
eq "$(reset_hint "$(printf 'session 70%% (resets Sat 1:00am)')")" "1:00am" \
   "a weekday is dropped: parse_reset reads a bare clock time as the next time it comes round"
eq "$(reset_hint "You've hit your session limit · resets 3pm (PDT)")" "3pm (PDT" \
   "a timezone suffix is left for parse_reset, which already trims it"
eq "$(reset_hint 'nothing here')" "" "no hint at all is empty, and the caller polls"

echo "== reset_hint must not mistake a MONTH for a weekday ==" >&2
# Both are three letters. Stripping "Jul" off "Jul 28, 8pm" would move the reset by
# up to a year, which is why the strip is anchored to a whole bare clock time.
eq "$(reset_hint 'resets Jul 28, 8pm')" "Jul 28, 8pm" "the month survives"
eq "$(reset_hint 'resets Jan 3, 2027, 9am')" "Jan 3, 2027, 9am" "so does a year"

echo "== parse_reset: every form Claude Code prints, and nothing else ==" >&2
NOWE=$(now_e)
for h in "3pm" "8:30pm" "3pm (PDT)" "10:40pm" "Jul 28, 8pm" "Jan 3, 2027, 9am"; do
  e=$(parse_reset "$h") && ok || bad "parse_reset must read '$h'"
done
# A bare clock time is the next time the clock reads it, so one that has already gone
# today is tomorrow.
PAST=$(clock_of $(( NOWE - 7200 )))
e=$(parse_reset "$PAST") || e=0
[ "$e" -gt "$NOWE" ] && ok || bad "a clock time already gone today must roll to tomorrow (got $e for '$PAST')"
# Fails closed, every time: waiting on a guess strands a task silently, where a knock
# sent early costs one instantly-failing call.
for h in "" "banana" "Sat 1:00am" "3 o'clock" "99:99xm"; do
  parse_reset "$h" >/dev/null && bad "parse_reset must fail closed on '$h'" || ok
done

echo "== clock_of: parse_reset's inverse, in Claude Code's own format ==" >&2
MID=$(date -j -f '%Y-%m-%d %H:%M:%S' "$(date '+%Y-%m-%d') 15:00:00" '+%s')
eq "$(clock_of "$MID")" "3pm" "minutes are dropped when they are zero"
eq "$(clock_of $(( MID + 1830 )))" "3:30pm" "and kept when they are not"
has "$(clock_of $(( MID + 86400 )))" "$(date -r $(( MID + 86400 )) '+%a')" \
    "a reset that is not today carries its weekday"
eq "$(clock_of '')" "" "nothing in, nothing out"
# The round trip is what pq ls depends on: an epoch is stored, a clock time is shown.
eq "$(parse_reset "$(clock_of "$MID")")" "$MID" "clock_of and parse_reset agree"

# ── check_stall ──────────────────────────────────────────────────────────────

# One task, one pane, driven a tick at a time. Detection needs the tail to be STILL,
# which takes two reads of the same text - the first only records the hash.
#
# Deliberately does NOT call set_panes: this runs in a command substitution, so the
# PIDX globals it sets would be left behind in the subshell while PANES_JSON changed
# on disk - the two halves of pane_state disagreeing, and every direct check_stall
# case silently reading the previous case's pane status. Each case sets its own.
new_case() {                            # -> task_dir, in running/, pane w1:p1
  reset_tasks; sent_reset
  local d; d=$(mk_task 'running' 001 walled tom/walled w1:p1)
  st_set "$d" PQ_LAUNCHED "$(now)"
  printf '%s' "$d"
}

echo "== check_stall: a moving pane is never touched ==" >&2
D=$(new_case)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
settled_text w1:p1 40 "10:40pm"
check_stall "$D"
settled_text w1:p1 41 "10:40pm"          # the tail moved
check_stall "$D"
eq "$(st "$D" PQ_BLOCKED)" "" "nothing is recorded about a healthy pane"
eq "$(sent)" "" "and nothing is typed at it"

echo "== check_stall: the wall on a MOVING screen is not yet stuck ==" >&2
# The request that hit the wall can still be in flight, spinner and all. Only a
# screen that has stopped moving counts.
D=$(new_case)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
BANNER=$(clock_of $(( $(now_e) + 3600 )))
walled_text w1:p1 "$BANNER" 100 "10:40pm"
check_stall "$D"                          # first read: records the hash only
eq "$(st "$D" PQ_BLOCKED)" "" "one sighting is not enough - there is no previous hash to compare"
[ -n "$(st "$D" PQ_TAIL)" ] && ok || bad "but the hash must be recorded (this key was never once written before the fix)"
walled_text w1:p1 "$BANNER" 99 "10:40pm"  # same wall, moved screen
check_stall "$D"
eq "$(st "$D" PQ_BLOCKED)" "" "a wall on a screen that is still moving is left alone"
eq "$(sent)" "" "and nothing is dismissed"

echo "== check_stall: the wall on a STILL screen is dismissed and dated ==" >&2
D=$(new_case)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
DUE=$(( $(now_e) + 3600 ))
BANNER=$(clock_of "$DUE")
walled_text w1:p1 "$BANNER" 100 "10:40pm"
check_stall "$D"
walled_text w1:p1 "$BANNER" 100 "10:40pm"
check_stall "$D"
eq "$(st "$D" PQ_BLOCKED)" quota "a still wall is the wall"
eq "$(sent)" "keys escape" "it is dismissed with Escape, and nothing is typed yet"
[ -n "$(st "$D" PQ_QUOTA_SINCE)" ] && ok || bad "the block must be dated"
eq "$(st "$D" PQ_TRIES)" 0 "with no knocks yet"
# Bug 2, pinned where it bit: every one of these keys is written AFTER the reset
# time, so a reset stored as prose took all of them with it.
RA=$(st "$D" PQ_RESETS_AT)
case "$RA" in ''|*[!0-9]*) bad "the reset must be stored as an epoch, not prose (got '$RA')" ;; *) ok ;; esac
[ "$RA" -ge $(( DUE - 90 )) ] && [ "$RA" -le $(( DUE + 90 )) ] \
  && ok || bad "the stored reset must be the one the BANNER named, not the statusline's (got $RA, want ~$DUE)"
eq "$(st "$D" PQ_RETRY_AT)" "$(( RA + 60 ))" "and the knock is armed a minute past it, for clock skew"

echo "== check_stall: what pq ls says about it ==" >&2
eq "$(block_cell "$D")" "quota $(clock_of "$RA")" "the row names the time it comes back"
st_set "$D" PQ_GAVEUP 1
eq "$(block_cell "$D")" "walled $(clock_of "$RA")" "and says 'walled' once pq has stopped knocking"
st_set "$D" PQ_GAVEUP ""

echo "== check_stall: the schedule survives the banner clearing itself ==" >&2
# Bug 3, and the reason the whole section never worked even in principle. The banner
# is live UI derived from the reset time, so it disappears AT the reset - the exact
# moment the knock comes due. Cancelling on "the wall is no longer on screen" threw
# the plan away every time.
settled_text w1:p1 0 "3:40am"             # banner gone, statusline turned over
check_stall "$D"
eq "$(st "$D" PQ_BLOCKED)" quota "the block outlives the banner"
eq "$(st "$D" PQ_RETRY_AT)" "$(( RA + 60 ))" "and so does the time it is due"
eq "$(sent)" "keys escape" "nothing new is sent before it is due"

echo "== check_stall: due, and the statusline is the only thing that moved ==" >&2
# The case that decides whether the cure is real. At the reset the statusline flips -
# a one-tick tail change, landing at precisely `due + 60`, indistinguishable from the
# agent picking its work back up unless you also ask herdr whether it is working.
# Believing movement alone here would clear the block on an idle agent and strand it,
# which is the original bug wearing a clock.
st_set "$D" PQ_RETRY_AT "$(( $(now_e) - 5 ))"
sent_reset
settled_text w1:p1 1 "3:40am"             # moved again, still idle
check_stall "$D"
eq "$(st "$D" PQ_BLOCKED)" quota "an idle agent is still walled, whatever the statusline did"
eq "$(st "$D" PQ_TRIES)" 1 "so pq knocks"
has "$(sent)" "text Continue with what you were doing." "with the words that resume the work"
has "$(sent)" "keys enter" "and it presses enter, or the prompt just sits there"
eq "$(st "$D" PQ_RESETS_AT)" "" "a reset time already gone is worse than none at all"
AT=$(st "$D" PQ_RETRY_AT)
[ "$AT" -gt "$(now_e)" ] && ok || bad "the next attempt must be re-armed into the future"
eq "$(block_cell "$D")" "quota $(age_of "$(st "$D" PQ_QUOTA_SINCE)")" \
   "with no reset time left, the row falls back to how long it has been gone"

echo "== check_stall: knocks stop the moment the agent is genuinely working ==" >&2
# Movement AND `working`. Together they are only ever true of an agent doing work:
# while walled and dismissed the pane is both still and idle.
sent_reset
set_panes "$(printf 'w1:p1\tclaude\tworking')"
settled_text w1:p1 2 "3:40am"
check_stall "$D"
eq "$(st "$D" PQ_BLOCKED)" "" "a working agent clears the block"
eq "$(st "$D" PQ_TRIES)" "" "and everything the wall left behind with it"
eq "$(sent)" "" "nothing is typed at an agent that is already working"

echo "== check_stall: a rescued agent is believed before the reset, not after ==" >&2
# You wake up, poke the agent yourself, and it carries on. Waiting for the reset
# before believing that would leave a block on file for hours - and a block on file
# freezes the queue, so a stale one is expensive.
D=$(new_case)
st_set "$D" PQ_BLOCKED quota
st_set "$D" PQ_QUOTA_SINCE "$(ago 60)"
st_set "$D" PQ_TRIES 0
st_set "$D" PQ_RETRY_AT "$(( $(now_e) + 3600 ))"
st_set "$D" PQ_TAIL 12345
set_panes "$(printf 'w1:p1\tclaude\tworking')"
settled_text w1:p1 3 "3:40am"
check_stall "$D"
eq "$(st "$D" PQ_BLOCKED)" "" "an agent back at work is out of the wall, clock or no clock"

echo "== check_stall: a still pane that is 'working' is still walled ==" >&2
# herdr calls a walled agent `working` off the spinner left in its title, which is
# the whole reason detection reads the text instead. A pane that has not moved is not
# working, whatever the title says.
D=$(new_case)
st_set "$D" PQ_BLOCKED quota
st_set "$D" PQ_QUOTA_SINCE "$(ago 60)"
st_set "$D" PQ_TRIES 0
st_set "$D" PQ_RETRY_AT "$(( $(now_e) - 5 ))"
set_panes "$(printf 'w1:p1\tclaude\tworking')"
settled_text w1:p1 4 "3:40am"
check_stall "$D"                          # records the hash
sent_reset
check_stall "$D"                          # same text: still
eq "$(st "$D" PQ_BLOCKED)" quota "a spinner in the title does not release a still pane"
eq "$(st "$D" PQ_TRIES)" 1 "it gets knocked on"

echo "== check_stall: a permission prompt ends a wall and is never answered ==" >&2
# A session asking for something is a session running again. Ending the wall here
# matters: the alternative is a knock sending Escape at the prompt - refusing it -
# and then doing that again every ten minutes.
D=$(new_case)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
st_set "$D" PQ_BLOCKED quota
st_set "$D" PQ_QUOTA_SINCE "$(ago 60)"
st_set "$D" PQ_TRIES 3
st_set "$D" PQ_RETRY_AT "$(( $(now_e) - 5 ))"
sent_reset
set_text w1:p1 <<'EOF'
⏺ Bash(rm -rf build/)

  Do you want to proceed?
  1. Yes
  2. Yes, and don't ask again
  3. No
EOF
check_stall "$D"
eq "$(st "$D" PQ_BLOCKED)" permission "the wall gives way to what is actually on screen"
eq "$(st "$D" PQ_TRIES)" "" "and the wall's bookkeeping is cleared"
eq "$(sent)" "" "a permission prompt is recorded and left strictly alone"
eq "$(block_cell "$D")" permission "which is what pq ls says about it"

echo "== check_stall: after PQ_QUOTA_MAX_TRIES it gives up, once ==" >&2
D=$(new_case)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
DUE=$(( $(now_e) + 3600 ))
walled_text w1:p1 "$(clock_of "$DUE")" 100 "10:40pm"
st_set "$D" PQ_BLOCKED quota
st_set "$D" PQ_QUOTA_SINCE "$(ago 600)"
st_set "$D" PQ_TRIES "$PQ_QUOTA_MAX_TRIES"
st_set "$D" PQ_RETRY_AT "$(( $(now_e) - 5 ))"
sent_reset
ERR=$(check_stall "$D" 2>&1)
has "$ERR" "still walled after" "it says so"
eq "$(st "$D" PQ_GAVEUP)" 1 "and records that it has stopped"
eq "$(sent)" "" "no further knocks"
ERR=$(check_stall "$D" 2>&1)
eq "$ERR" "" "and it does not say so again every two minutes all night"

echo "== check_stall: a pane herdr cannot show us is left entirely alone ==" >&2
D=$(new_case)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
st_set "$D" PQ_PANE wGONE:p1
st_set "$D" PQ_BLOCKED quota
st_set "$D" PQ_RETRY_AT "$(( $(now_e) - 5 ))"
st_set "$D" PQ_TRIES 2
sent_reset
check_stall "$D"
eq "$(st "$D" PQ_TRIES)" 2 "no text means no verdict - nothing is decided on a blind read"
eq "$(sent)" "" "and nothing is typed into the dark"

# ── the wall through a whole tick ────────────────────────────────────────────

echo "== tick_body: an agent walled while wrapping up its PR gets knocked ==" >&2
# `done/` is where an unattended agent spends most of the night - answering review,
# fixing CI - and for a long time nothing knocked on those panes at all. Three agents
# wrapping up at midnight, all three walled, none of them touched by morning: the
# reported bug.
reset_tasks; reset_caches; sent_reset
W=$(mk_task 'done' 010 wrapup tom/wrapup w2:p1)
st_set "$W" PQ_LAUNCHED "$(now)"; st_set "$W" PQ_PR 500; st_set "$W" PQ_FINISHED "$(now)"
cache_row "$REPO" tom/wrapup 500 OPEN "" master
set_panes "$(printf 'w2:p1\tclaude\tidle')"
DUE=$(( $(now_e) + 3600 ))
walled_text w2:p1 "$(clock_of "$DUE")" 100 "10:40pm"
tick 3 0
tick 3 0
eq "$(st "$W" PQ_BLOCKED)" quota "the wall is found on a wrapping-up pane too"
eq "$(sent)" "keys escape" "and dismissed there"

echo "== tick_body: a walled wrap-up holds its slot even though it reads idle ==" >&2
# Dismissing the dialog stops the spinner, so herdr calls a walled agent `idle` -
# and the wrap-up grace would hand its slot away while it waits for its window, then
# take it back on the very tick the agent resumes.
st_set "$W" PQ_WRAPUP_SINCE "$(ago 900)"
eq "$(active_slots 1)" "$(printf '0\t1')" "a walled wrap-up is still a live agent"
eq "$(slot_state "$W")" "wrapping up" "and still spending a slot"
st_set "$W" PQ_BLOCKED ""
eq "$(active_slots 1)" "$(printf '0\t0')" "with no wall, the same idle agent releases it"
st_set "$W" PQ_BLOCKED quota

echo "== tick_body: a wall anywhere starts nothing new ==" >&2
# Every agent pq runs draws on one account-wide window, so a second agent dispatched
# behind the wall does not get its own allowance - it walls on its first request,
# having spent a minute of `wt new`, a database and a port to get there.
reset_tasks; reset_caches; sent_reset
R=$(mk_task 'running' 020 stuck tom/stuck w3:p1)
st_set "$R" PQ_LAUNCHED "$(now)"
st_set "$R" PQ_BLOCKED quota
st_set "$R" PQ_QUOTA_SINCE "$(ago 60)"
st_set "$R" PQ_RETRY_AT "$(( $(now_e) + 3600 ))"
st_set "$R" PQ_RESETS_AT "$DUE"
mk_task 'queue' 021 next tom/next "" >/dev/null
set_panes "$(printf 'w3:p1\tclaude\tidle')"
settled_text w3:p1 100 "10:40pm"
tick 3 1
hasnt "$OUT" "would dispatch next" "nothing starts while somebody is behind the wall"
has "$OUT" "would skip next - walled until $(clock_of "$DUE")" \
    "and the skip names the wall, not the cap - they want opposite things from you"
has "$PQ_SUMMARY" "walled until $(clock_of "$DUE") - starting nothing" \
    "the summary says it, or a frozen queue leaves a log that just goes quiet"

echo "== pq cap reports the freeze rather than room it will not use ==" >&2
has "$(cmd_cap 3 2>&1)" "stuck is walled until $(clock_of "$DUE"), so nothing new starts" \
    "'room for 2 more' would be a lie while the wall is up"

echo "== tick_body: the freeze lifts when the block does ==" >&2
st_set "$R" PQ_BLOCKED ""
tick 3 1
has "$OUT" "would dispatch next" "with nobody walled, the queue advances again"
hasnt "$PQ_SUMMARY" "walled" "and the summary stops saying it"

echo "== tick_body: an EXITED agent's dead banner must not freeze the queue ==" >&2
# Reading the pane properly is what makes this possible, and it is the one way the
# fix could have been worse than the bug. Claude Code renders inline rather than on
# the alternate screen, so a session that exited while walled leaves its banner
# sitting in the visible viewport above a shell prompt - and `pane read`, unlike the
# `agent read` it replaced, returns that quite happily. classify_tail would go on
# reading `quota` off dead scrollback for ever, the knocks would land on bash, and a
# freeze that only asked whether the PANE existed would hold the whole queue until
# somebody looked in the morning.
st_set "$R" PQ_BLOCKED quota
set_panes "$(printf 'w3:p1\t\t')"        # pane present, no agent bound
eq "$(pane_state w3:p1)" noagent "the pane is there; Claude is not"
[ -n "$(pane_tail w3:p1)" ] && ok || bad "its scrollback is still readable, which is the hazard"
tick 3 1
has "$OUT" "would dispatch next" "a dead agent's banner freezes nothing"
hasnt "$PQ_SUMMARY" "walled" "and is not reported as a wall anybody is waiting on"

echo "== tick_body: a vanished workspace does not freeze it either ==" >&2
set_panes ""                              # the pane is gone from the snapshot
eq "$(pane_state w3:p1)" missing "the workspace itself has gone"
tick 3 1
has "$OUT" "would dispatch next" "a task nothing can resume must not hold the queue"

echo "== tick_body: a task pq has given up on stops freezing the queue ==" >&2
# The only bound on how long a freeze can last, and the reason it needs one:
# detection is a regex over a terminal, so any pane showing the words is a candidate -
# a diff of pq itself, a plan quoting the wall, this test file. One that goes idle
# rather than resuming can never satisfy `moved && working`, so without this the cost
# of a single misread pane is every night after it rather than one status cell.
set_panes "$(printf 'w3:p1\tclaude\tidle')"
tick 3 1
hasnt "$OUT" "would dispatch next" "while pq is still knocking, the freeze holds"
st_set "$R" PQ_GAVEUP 1
tick 3 1
has "$OUT" "would dispatch next" "once it has given up and left the task for you, the queue moves"
hasnt "$PQ_SUMMARY" "walled" "and it stops being reported as a wall anybody is waiting on"
eq "$(block_cell "$R")" "walled $(clock_of "$DUE")" "the row still says walled, because it still wants you"
st_set "$R" PQ_GAVEUP ""

echo "== pq ls: a done row reports its wall ahead of 'wrapping up' ==" >&2
# Through the real caller, not block_cell directly: this is the branch the done/ knock
# made necessary, and a walled wrap-up that reads as "wrapping up" says the one thing
# it is not - quietly waiting, with nothing wanted from anyone.
reset_tasks; reset_caches
DN=$(mk_task 'done' 040 dwall tom/dwall w5:p1)
st_set "$DN" PQ_LAUNCHED "$(now)"; st_set "$DN" PQ_PR 700; st_set "$DN" PQ_FINISHED "$(now)"
st_set "$DN" PQ_BLOCKED quota; st_set "$DN" PQ_QUOTA_SINCE "$(ago 60)"; st_set "$DN" PQ_RESETS_AT "$DUE"
set_panes "$(printf 'w5:p1\tclaude\tidle')"
eq "$(agent_cell "$DN" done)" "quota $(clock_of "$DUE")" "the done row names the wall and when it lifts"
st_set "$DN" PQ_BLOCKED permission
eq "$(agent_cell "$DN" done)" permission "and a permission prompt there still reads as one"
st_set "$DN" PQ_BLOCKED ""
eq "$(agent_cell "$DN" done)" "wrapping up" "with nothing blocking it, it is just wrapping up"

echo "== a walled agent still counts against the cap while it waits ==" >&2
# The freeze is not the only thing keeping the arithmetic honest: it lifts on the
# tick the block clears, which is the tick the agent starts working again, and the
# slot has to have been spent all along or fill hands it to somebody else.
reset_tasks; reset_caches
S=$(mk_task 'done' 030 slot tom/slot w4:p1)
st_set "$S" PQ_LAUNCHED "$(now)"; st_set "$S" PQ_PR 600; st_set "$S" PQ_FINISHED "$(now)"
st_set "$S" PQ_WRAPUP_SINCE "$(ago 900)"
st_set "$S" PQ_BLOCKED quota
cache_row "$REPO" tom/slot 600 OPEN "" master
mk_task 'queue' 031 after tom/after "" >/dev/null
set_panes "$(printf 'w4:p1\tclaude\tidle')"
settled_text w4:p1 100 "10:40pm"
tick 1 1
has "$PQ_SUMMARY" "0 running + 1 wrapping up (cap 1)" "the walled wrap-up is counted"
# And with the wall gone but the agent still idle past the grace, the slot goes.
st_set "$S" PQ_BLOCKED ""
tick 1 1
has "$PQ_SUMMARY" "0 running (cap 1)" "an agent that really has finished releases it"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
