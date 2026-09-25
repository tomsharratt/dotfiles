#!/usr/bin/env bash
# test/pq-quiet.sh - an agent that stops with no wall and no prompt on screen.
#
# tap-to-reveal sat idle 56 minutes, then 52 more, with no pull request, until Tom
# asked "has this stalled?". tiptap sat 18 minutes on "Login expired · Please run
# /login" until he typed "continue". check_quiet reads the same pane check_stall
# does and knocks on both: an error line at the bottom of the pane gets
# "continue", and an agent idle and still for QUIET_AFTER with no pull request gets
# nudged back to its contract - each bounded, and handed to you past the bound.
#
# The harness is test/pq-quota.sh's `pane read` stub and test/pq-review.sh's
# recording `agent prompt`, with the clock pinned.
#
# SC2034: the pane index set here is read by the pq sourced below.
# SC2015: `ok` never fails, so `[ ... ] && ok || bad` is an if/else.
# shellcheck disable=SC2034,SC2015
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PQ_HOME=$(mktemp -d)
export PQ_HOME

STUBBIN=$(mktemp -d)
PANES_JSON="$STUBBIN/.panes.json"
HERDR_LOG="$STUBBIN/.herdr-calls"
printf '{"result":{"snapshot":{"panes":[]}}}' > "$PANES_JSON"
: > "$HERDR_LOG"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/claude"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/gh"
cat > "$STUBBIN/herdr" <<EOF
#!/bin/sh
key=\$(printf '%s' "\$3" | tr ':' '_')
case "\$1 \$2" in
  "api snapshot") cat "$PANES_JSON"; exit 0 ;;
  "pane read")    [ -f "$STUBBIN/pane.\$key" ] && cat "$STUBBIN/pane.\$key"; exit 0 ;;
  "agent prompt")
    { for a in "\$@"; do printf '%s\t' "\$a"; done; printf '\n'; } >> "$HERDR_LOG"
    if [ -f "$STUBBIN/.prompt-fail" ]; then
      printf '{"error":{"code":"%s","message":"stub"},"id":"cli:agent:prompt"}\n' "\$(cat "$STUBBIN/.prompt-fail")"; exit 0
    fi
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

pr_load_all() { :; }

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }
has() { case "$1" in *"$2"*) ok ;; *) bad "$3 (got '$1')" ;; esac; }
hasnt() { case "$1" in *"$2"*) bad "$3 (got '$1')" ;; *) ok ;; esac; }

cleanup() { rm -rf "$PQ_HOME" "$STUBBIN" "${REPO:-}"; }
trap cleanup EXIT

REPO=$(mktemp -d)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$REPO/.git/refs/remotes/origin"
git -C "$REPO" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master

unset HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID

FAKE_NOW=$(date -u '+%s')
epoch() { printf '%s' "$FAKE_NOW"; }
later() { FAKE_NOW=$(( FAKE_NOW + $1 )); }

set_panes() {                           # "pane<TAB>agent<TAB>status" lines
  PIDX=$1; PIDX_OK=1
  jq -Rs 'split("\n") | map(select(length > 0) | split("\t")
            | { pane_id: .[0],
                agent:        (if (.[1] // "") == "" then null else .[1] end),
                agent_status: (if (.[2] // "") == "" then null else .[2] end) })
          | { result: { snapshot: { panes: . } } }' <<<"$1" > "$PANES_JSON"
}
screen() { printf '%s\n' "$2" > "$STUBBIN/pane.$(tr ':' '_' <<<"$1")"; }   # pane text
prompts() { grep -c "^agent	prompt	" "$HERDR_LOG" 2>/dev/null || true; }
prompt_text() { grep "^agent	prompt	" "$HERDR_LOG" | tail -1 | cut -f4; }
reset_logs() { : > "$HERDR_LOG"; rm -f "$STUBBIN/.prompt-fail"; }

mk_task() {                             # state prio slug pane -> task_dir
  local d
  d="$PQ_HOME/$1/$(printf '%014d' $(( 20260101000000 + 10#$2 )))-$3"
  mkdir -p "$d"
  printf -- '---\nrepo:     %s\nbranch:   tom/%s\nmodel:    sonnet\neffort:   xhigh\nintent:   t\nadded:    2026-01-01T00:00:00Z\n---\n\nplan\n' \
    "$REPO" "$3" > "$d/plan.md"
  st_set "$d" PQ_PANE "$4"; st_set "$d" PQ_LAUNCHED 2026-01-01T00:00:00Z
  printf '%s' "$d"
}
IDLE_SCREEN=$'I have read the plan and made a start on the model.\n\n> \n  opus 5.5 | ctx 41%'

echo "== an agent idle and still with no pull request is nudged after QUIET_AFTER ==" >&2
R=$(mk_task running 10 tapreveal w1:p1)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
screen w1:p1 "$IDLE_SCREEN"
check_stall "$R" >/dev/null 2>&1
eq "$(prompts)" "0" "one glimpse starts the stretch and judges nothing"
[ -n "$(st "$R" PQ_QUIET_SINCE)" ] && ok || bad "the stretch is on file"
later $(( QUIET_AFTER - 60 )); check_stall "$R" >/dev/null 2>&1
eq "$(prompts)" "0" "not before QUIET_AFTER"
later 60; out=$(check_stall "$R" 2>&1)
eq "$(prompts)" "1" "at QUIET_AFTER it is nudged"
P=$(prompt_text)
has "$P" "idle for 15 minutes without opening a pull request" "saying how long"
has "$P" "$PQ_HOME/tasks/$(basename "$R")/contract.md" "pointing at its contract, through the stable path"
has "$P" "STUCK:" "and at the way to say it is stuck"
hasnt "$P" "'" "quote-free"
has "$out" "idle 15m with no pull request - nudged it (nudge 1 of 3)" "said in the log"
eq "$(st "$R" PQ_NUDGES)" "1" "counted"
eq "$(agent_cell "$R" running)" "idle" "a nudged agent still reads as what it is"

echo "== the pane moving after a nudge does not buy it more nudges ==" >&2
screen w1:p1 $'Understood - I will carry on.\n\n> '
check_stall "$R" >/dev/null 2>&1          # the reply: a new screen starts a new stretch
later "$QUIET_AFTER"; check_stall "$R" >/dev/null 2>&1
eq "$(st "$R" PQ_NUDGES)" "2" "quiet again: the second nudge"
screen w1:p1 $'Carrying on.\n\n> '
check_stall "$R" >/dev/null 2>&1
later "$QUIET_AFTER"; check_stall "$R" >/dev/null 2>&1
eq "$(st "$R" PQ_NUDGES)" "3" "the third"
screen w1:p1 $'Still carrying on.\n\n> '
check_stall "$R" >/dev/null 2>&1
later "$QUIET_AFTER"; out=$(check_stall "$R" 2>&1)
eq "$(prompts)" "3" "and no fourth"
has "$out" "idle with no pull request after 3 nudges - look at it" "it is handed to you"
eq "$(agent_cell "$R" running)" "quiet" "pq ls says so"
LS=$(PQ_WIDTH=200 main ls 2>&1)
has "$LS" "(1 needs you)" "and counts it as needing you"
later "$QUIET_AFTER"; eq "$(check_stall "$R" 2>&1)" "" "once"
set_panes "$(printf 'w1:p1\tclaude\tworking')"
eq "$(agent_cell "$R" running)" "working" "set going again, it simply reads as working"

echo "== a working agent is never quiet, and a done one is never nudged ==" >&2
reset_logs
W=$(mk_task running 11 busy w2:p1)
set_panes "$(printf 'w2:p1\tclaude\tworking')"
screen w2:p1 "$IDLE_SCREEN"
check_stall "$W" >/dev/null 2>&1; later $(( QUIET_AFTER * 2 )); check_stall "$W" >/dev/null 2>&1
eq "$(prompts)" "0" "a working pane has no stretch at all"
eq "$(st "$W" PQ_QUIET_SINCE)" "" "and none on file"
D=$(mk_task "done" 12 finished w3:p1)
set_panes "$(printf 'w3:p1\tclaude\tidle')"
screen w3:p1 "$IDLE_SCREEN"
check_stall "$D" >/dev/null 2>&1; later $(( QUIET_AFTER * 2 )); check_stall "$D" >/dev/null 2>&1
eq "$(prompts)" "0" "a done agent resting idle is finished, not quiet"

echo "== an error at the bottom of the pane is knocked on with continue ==" >&2
reset_logs
E=$(mk_task running 13 apierror w4:p1)
set_panes "$(printf 'w4:p1\tclaude\tidle')"
screen w4:p1 $'Running the specs now.\n  ⎿  API Error: 500 {"type":"error","error":{"type":"api_error","message":"Internal server error"}}\n\n> \n  opus 5.5 | ctx 41%'
check_stall "$E" >/dev/null 2>&1
eq "$(prompts)" "0" "not off one glimpse"
later 120; out=$(check_stall "$E" 2>&1)
eq "$(prompts)" "1" "a tick later, it is knocked on"
eq "$(prompt_text)" "Continue with what you were doing." "with the knock the wall gets"
has "$out" "stopped on \"API Error: 500" "naming the error"
has "$out" "knocked (attempt 1)" "and the attempt"
screen w4:p1 $'Running the specs now.\n  ⎿  API Error: 500 again\n\n> '
check_stall "$E" >/dev/null 2>&1; later 120; check_stall "$E" >/dev/null 2>&1
eq "$(prompts)" "1" "not again inside ERROR_RETRY"
later "$ERROR_RETRY"; check_stall "$E" >/dev/null 2>&1
eq "$(prompts)" "2" "and again once it is due"
for n in 3 4 5 6; do screen w4:p1 "  ⎿  API Error: 529 overloaded ($n)"; check_stall "$E" >/dev/null 2>&1; later "$ERROR_RETRY"; check_stall "$E" >/dev/null 2>&1; done
eq "$(st "$E" PQ_ERR_KNOCKS)" "6" "up to ERROR_KNOCKS"
screen w4:p1 "API Error: 529 overloaded - still"
check_stall "$E" >/dev/null 2>&1; later "$ERROR_RETRY"; out=$(check_stall "$E" 2>&1)
eq "$(prompts)" "6" "and no further"
has "$out" "after 6 knocks - look at it" "handed to you"
eq "$(agent_cell "$E" running)" "error" "pq ls says so"

echo "== a turn that ends without the error is the recovery ==" >&2
screen w4:p1 $'All green.\n\n> '
check_stall "$E" >/dev/null 2>&1; later 120; check_stall "$E" >/dev/null 2>&1
eq "$(st "$E" PQ_ERR_KNOCKS)" "" "the count resets"
eq "$(agent_cell "$E" running)" "idle" "and it reads as idle again"

echo "== a login that expired, in a done task too ==" >&2
reset_logs
L=$(mk_task "done" 14 tiptap w5:p1)
set_panes "$(printf 'w5:p1\tclaude\tidle')"
screen w5:p1 $'Pushed the fix.\n  ⎿  Login expired · Please run /login\n\n> '
check_stall "$L" >/dev/null 2>&1; later 120; check_stall "$L" >/dev/null 2>&1
eq "$(prompts)" "1" "a done agent stopped on an error is knocked on as well"

echo "== an error scrolled up out of the bottom lines is not the last thing it said ==" >&2
reset_logs
O=$(mk_task running 15 scrolled w6:p1)
set_panes "$(printf 'w6:p1\tclaude\tidle')"
screen w6:p1 "$(printf 'API Error: 500 an hour ago\n'; for i in $(seq 1 15); do printf 'line %s of what came after\n' "$i"; done)"
check_stall "$O" >/dev/null 2>&1; later 120; check_stall "$O" >/dev/null 2>&1
eq "$(prompts)" "0" "no knock for an old error"

echo "== ...and the words mid-line are not the error: a diff, a command ==" >&2
reset_logs
M=$(mk_task running 18 midline w9:p1)
set_panes "$(printf 'w9:p1\tclaude\tidle')"
screen w9:p1 $'  +    # retry once on an API Error from the upstream\n  $ grep -n "Login expired" app/auth.rb\n\n> '
check_stall "$M" >/dev/null 2>&1; later 120; check_stall "$M" >/dev/null 2>&1
eq "$(prompts)" "0" "no knock for code that mentions them"

echo "== a knock the pane refuses is said, not counted ==" >&2
reset_logs
K=$(mk_task running 16 dialog w7:p1)
set_panes "$(printf 'w7:p1\tclaude\tidle')"
screen w7:p1 $'API Error: 500\n\n> '
printf 'agent_blocked' > "$STUBBIN/.prompt-fail"
check_stall "$K" >/dev/null 2>&1; later 120; out=$(check_stall "$K" 2>&1)
has "$out" "could not knock (agent_blocked)" "said"
eq "$(st "$K" PQ_ERR_KNOCKS)" "" "and not counted"

echo "== through tick_body ==" >&2
reset_logs
rm -rf "$PQ_HOME/running" "$PQ_HOME/done"; mkdir -p "$PQ_HOME/running" "$PQ_HOME/done"
PR_CACHE="$PQ_HOME/.test.pr"; PR_ANS="$PQ_HOME/.test.ans"; : > "$PR_CACHE"; : > "$PR_ANS"
T=$(mk_task running 17 ticked w8:p1)
set_panes "$(printf 'w8:p1\tclaude\tidle')"
screen w8:p1 "$IDLE_SCREEN"
tick_body 0 0 >/dev/null 2>&1
later "$QUIET_AFTER"
: > "$PR_CACHE"; : > "$PR_ANS"
tick_body 0 0 >/dev/null 2>&1
eq "$(st "$T" PQ_NUDGES)" "1" "a tick nudges a quiet running agent"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
