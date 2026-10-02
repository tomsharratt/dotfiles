#!/usr/bin/env bash
# test/pq-pane.sh - reading a dispatched agent's pane: pane_tail and check_stall,
# directly and through tick_body, the same way test/pq-slots.sh does for the cap
# arithmetic.
#
# Two things are pinned here. pane_tail used to pipe `herdr ... --format text` -
# which is text - through `jq '.result.read.text'`, so it returned the empty
# string on every tick of every task and nothing below it ever ran. And the
# account's usage limit is a monthly hard stop, not a five-hour window to wait
# out: a pane showing it is not dismissed, knocked on or frozen on, the cap is
# what bounds how many tasks are dispatched into it, and a `quota` block left on
# file by the pq that did all of that holds nothing.
#
# SC2034: the knobs and caches set here are read by the pq sourced below.
# SC2015: `ok` never fails, so `[ ... ] && ok || bad` is an if/else.
# shellcheck disable=SC2034,SC2015
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PQ_HOME=$(mktemp -d)
export PQ_HOME

# Stubs so nothing here reaches a network or a real herdr socket - same reasoning as
# test/pq-slots.sh. This file's `herdr` serves `pane read` out of a per-pane file
# each case writes, and RECORDS every keystroke, text and prompt sent to a pane,
# because "did pq type anything at the agent" is the question for half the cases
# below.
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
  "agent prompt")    shift 3; printf 'prompt %s\n' "\$*" >> "$SENTLOG"
                     printf '{"id":"cli:agent:prompt","result":{"submitted":true}}\n'; exit 0 ;;
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

reset_tasks() {
  rm -rf "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done" "$PQ_HOME/archive"
  mkdir -p "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done" "$PQ_HOME/archive"
}
reset_tasks

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
  local dir
  dir="$PQ_HOME/$state/$(printf '%014d' $(( 20260101000000 + 10#$prio )))-$slug"
  mkdir -p "$dir"
  {
    printf -- '---\n'
    printf 'repo:     %s\n' "$REPO"
    printf 'branch:   %s\n' "$branch"
    printf 'model:    sonnet\n'
    printf 'effort:   xhigh\n'
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

# What a session that has run out of budget looks like: Claude Code's own line for
# an enterprise seat's monthly spend limit, with the statusline below it.
limit_text() {                          # pane
  set_text "$1" <<'EOF'
> ship the fix

⏺ You've hit your individual spend limit · visit claude.ai/admin-settings/usage to raise it

────────────────────────────────────────────────
❯
────────────────────────────────────────────────
  235.7K / 1M · budget 100% ($10K / $10K)
  ⏵⏵ auto mode on (shift+tab to cycle) · PR #12
EOF
}

# An ordinary working pane, which a tick must leave alone.
working_text() {                        # pane n
  set_text "$1" <<EOF
> ship the fix

⏺ Working on it - step $2.

────────────────────────────────────────────────
❯
────────────────────────────────────────────────
  235.7K / 1M · budget 2% (\$217 / \$10K)
EOF
}

permission_text() {                     # pane
  set_text "$1" <<'EOF'
⏺ Bash(rm -rf build/)

  Do you want to proceed?
  1. Yes
  2. Yes, and don't ask again
  3. No
EOF
}

# ── pane_tail ────────────────────────────────────────────────────────────────

echo "== pane_tail returns the pane's text, not the empty string ==" >&2
# The only pin that matters here: `herdr pane read --format text` prints raw
# terminal text, so anything that tries to unwrap a JSON envelope around it gets
# nothing, silently, for ever.
permission_text w9:p1
T=$(pane_tail w9:p1)
[ -n "$T" ] && ok || bad "pane_tail must return the pane's text (it returned nothing)"
has "$T" "Do you want to proceed?" "pane_tail must return the text verbatim"

echo "== pane_tail: no pane, no text, and an error envelope is not text ==" >&2
eq "$(pane_tail '')" "" "no pane id means no text"
eq "$(pane_tail wZ:p9)" "" "a pane herdr knows nothing about yields nothing"
# `pane read` answers for a pane with no agent bound - but it can still fail, and
# an error object must not be mistaken for something an agent printed.
set_text wE:p1 <<'EOF'
{"error":{"code":"pane_not_found","message":"pane target wE:p1 not found"},"id":"cli:pane:read"}
EOF
eq "$(pane_tail wE:p1)" "" "an error envelope is dropped rather than read"

echo "== pane_tail honours PQ_TAIL_LINES ==" >&2
{ for i in $(seq 1 60); do printf 'line %s\n' "$i"; done; } > "$(pane_file wT:p1)"
eq "$(pane_tail wT:p1 | wc -l | tr -d ' ')" "$PQ_TAIL_LINES" "only the last PQ_TAIL_LINES lines are read"
eq "$(pane_tail wT:p1 | tail -1)" "line 60" "and they are the ones at the bottom"

# ── check_stall ──────────────────────────────────────────────────────────────

# Deliberately does NOT call set_panes: this runs in a command substitution, so the
# PIDX globals it sets would be left behind in the subshell while PANES_JSON changed
# on disk - the two halves of pane_state disagreeing. Each case sets its own.
new_case() {                            # -> task_dir, in running/, pane w1:p1
  reset_tasks; sent_reset
  local d; d=$(mk_task 'running' 001 agent tom/agent w1:p1)
  st_set "$d" PQ_LAUNCHED "$(now)"
  printf '%s' "$d"
}

echo "== check_stall: a working pane is never touched ==" >&2
D=$(new_case)
set_panes "$(printf 'w1:p1\tclaude\tworking')"
working_text w1:p1 1; check_stall "$D"
working_text w1:p1 2; check_stall "$D"
eq "$(st "$D" PQ_BLOCKED)" "" "nothing is recorded about a healthy pane"
eq "$(sent)" "" "and nothing is typed at it"

echo "== check_stall: a permission prompt is recorded and never answered ==" >&2
D=$(new_case)
set_panes "$(printf 'w1:p1\tclaude\tblocked')"
permission_text w1:p1
check_stall "$D"
eq "$(st "$D" PQ_BLOCKED)" permission "the prompt is recorded"
eq "$(sent)" "" "and left strictly alone"
eq "$(block_cell "$D")" permission "which is what pq ls says about it"
eq "$(agent_cell "$D" running)" permission "on the running row, ahead of herdr's own word"
check_stall "$D"
eq "$(sent)" "" "a second read changes nothing"
set_panes "$(printf 'w1:p1\tclaude\tworking')"
working_text w1:p1 3; check_stall "$D"
eq "$(st "$D" PQ_BLOCKED)" "" "answered, the prompt is cleared"
eq "$(block_cell "$D")" "" "and the cell with it"

echo "== check_stall: a pane herdr cannot show us is left entirely alone ==" >&2
D=$(new_case)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
st_set "$D" PQ_PANE wGONE:p1
st_set "$D" PQ_BLOCKED permission
check_stall "$D"
eq "$(st "$D" PQ_BLOCKED)" permission "no text means no verdict - nothing is decided on a blind read"
eq "$(sent)" "" "and nothing is typed into the dark"

echo "== check_stall: the usage limit is a hard stop, not something to knock on ==" >&2
# There is no reset an hour or two out to wait for, so nothing is dismissed, timed
# or knocked on: the agent stops like any other, and is yours when the limit lifts.
D=$(new_case)
set_panes "$(printf 'w1:p1\tclaude\tblocked')"
limit_text w1:p1
check_stall "$D"; check_stall "$D"; check_stall "$D"
eq "$(st "$D" PQ_BLOCKED)" "" "the limit is not recorded as a block of pq's own"
eq "$(sent)" "" "nothing is dismissed or typed"
eq "$(agent_cell "$D" running)" blocked "herdr's word is the row - it wants you"

# ── through a whole tick ─────────────────────────────────────────────────────

echo "== tick_body: an agent at the limit freezes nothing ==" >&2
reset_tasks; reset_caches; sent_reset
R=$(mk_task 'running' 020 stopped tom/stopped w3:p1)
st_set "$R" PQ_LAUNCHED "$(now)"
mk_task 'queue' 021 next tom/next "" >/dev/null
set_panes "$(printf 'w3:p1\tclaude\tblocked')"
limit_text w3:p1
tick 3 1
has "$OUT" "would dispatch next" "the queue goes on while there is room under the cap"
hasnt "$PQ_SUMMARY" "walled" "and the summary names no wall"
hasnt "$PQ_SUMMARY" "starting nothing" "nor a freeze"
has "$(cmd_cap 3 2>&1)" "room for 2 more" "pq cap reports the room fill will use"
rm -f "$PQ_HOME/cap"

echo "== tick_body: the cap bounds how many are dispatched into the limit ==" >&2
# A task in running/ holds its slot until it opens a pull request, and an agent at
# the limit opens none - so at a cap of 1 the next task waits.
tick 1 1
hasnt "$OUT" "would dispatch next" "nothing more starts once the stopped agent fills the cap"
has "$OUT" "would skip next - cap reached" "and the skip says why"
tick 1 0
eq "$(sent)" "" "a real tick types nothing at the stopped agent either"

echo "== a quota block left by an older pq holds nothing, and is cleared ==" >&2
# The pq that knocked on the five-hour wall stored PQ_BLOCKED=quota, held the slot
# on it and froze the queue. A task carrying one across the upgrade must not.
reset_tasks; reset_caches; sent_reset
S=$(mk_task 'done' 030 legacy tom/legacy w4:p1)
st_set "$S" PQ_LAUNCHED "$(now)"; st_set "$S" PQ_PR 600; st_set "$S" PQ_FINISHED "$(now)"
st_set "$S" PQ_WRAPUP_SINCE "$(ago 900)"
st_set "$S" PQ_BLOCKED quota; st_set "$S" PQ_RESETS_AT 1790000000; st_set "$S" PQ_GAVEUP 1
cache_row "$REPO" tom/legacy 600 OPEN "" master
mk_task 'queue' 031 after tom/after "" >/dev/null
set_panes "$(printf 'w4:p1\tclaude\tidle')"
working_text w4:p1 4
eq "$(slot_state "$S")" "" "an idle agent past the grace holds no slot, quota or not"
eq "$(agent_cell "$S" "done")" "-" "and pq ls reads no quota off it"
tick 1 1
has "$OUT" "would dispatch after" "the queue moves"
has "$PQ_SUMMARY" "0 running (cap 1)" "with the slot free"
tick 0 0                                # cap 0: the real tick reads panes and starts nothing
eq "$(st "$S" PQ_BLOCKED)" "" "the first real tick that reads its pane clears the old block"

echo "== pq ls: a done row reports a prompt ahead of 'wrapping up' ==" >&2
reset_tasks; reset_caches
DN=$(mk_task 'done' 040 dprompt tom/dprompt w5:p1)
st_set "$DN" PQ_LAUNCHED "$(now)"; st_set "$DN" PQ_PR 700; st_set "$DN" PQ_FINISHED "$(now)"
set_panes "$(printf 'w5:p1\tclaude\tidle')"
st_set "$DN" PQ_BLOCKED permission
eq "$(agent_cell "$DN" "done")" permission "a permission prompt on a done row reads as one"
st_set "$DN" PQ_BLOCKED ""
eq "$(agent_cell "$DN" "done")" "wrapping up" "with nothing blocking it, it is just wrapping up"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
