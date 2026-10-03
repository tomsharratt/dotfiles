#!/usr/bin/env bash
# test/pq-quiet.sh - an agent that stops with no prompt on screen.
#
# tap-to-reveal sat idle 56 minutes, then 52 more, with no pull request, until Tom
# asked "has this stalled?". tiptap sat 18 minutes on "Login expired · Please run
# /login" until he typed "continue". check_quiet reads the agent's own hook record
# (agent.json) and knocks on both: a turn that ended on an API error gets
# "continue", and an agent idle and still for QUIET_AFTER with no pull request gets
# nudged back to its contract - each bounded, and handed to you past the bound.
#
# The harness is test/pq-review.sh's recording `agent prompt`, with the clock pinned
# and agent.json written by hand where the hooks would write it.
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
rec() {                                 # task_dir event [error message] - what a hook writes, stamped now
  jq -nc --arg e "$2" --argjson at "$FAKE_NOW" --arg err "${3:-}" --arg m "${4:-}" \
    '{event:$e,at:$at} + (if $err == "" then {} else {error:$err,message:$m} end)' \
    > "$(task_home "$1")/agent.json"
}
prompts() { grep -c "^agent	prompt	" "$HERDR_LOG" 2>/dev/null || true; }
prompt_text() { grep "^agent	prompt	" "$HERDR_LOG" | tail -1 | cut -f4; }
reset_logs() { : > "$HERDR_LOG"; rm -f "$STUBBIN/.prompt-fail"; }

mk_task() {                             # state prio slug pane -> task_dir
  local d
  d="$PQ_HOME/$1/$(printf '%014d' $(( 20260101000000 + 10#$2 )))-$3"
  mkdir -p "$d"
  printf -- '---\nrepo:     %s\nbranch:   tom/%s\nmodel:    sonnet\neffort:   xhigh\nintent:   t\nadded:    2026-01-01T00:00:00Z\n---\n\nplan\n' \
    "$REPO" "$3" > "$d/plan.md"
  mkdir -p "$PQ_HOME/tasks"; task_link "$d"
  st_set "$d" PQ_PANE "$4"; st_set "$d" PQ_LAUNCHED 2026-01-01T00:00:00Z
  printf '%s' "$d"
}

echo "== an agent idle and still with no pull request is nudged after QUIET_AFTER ==" >&2
R=$(mk_task running 10 tapreveal w1:p1)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
rec "$R" idle
check_quiet "$R" >/dev/null 2>&1
eq "$(prompts)" "0" "a fresh record is not quiet yet"
later $(( QUIET_AFTER - 60 )); check_quiet "$R" >/dev/null 2>&1
eq "$(prompts)" "0" "not before QUIET_AFTER"
later 60; out=$(check_quiet "$R" 2>&1)
eq "$(prompts)" "1" "at QUIET_AFTER, timed from the record's own stamp, it is nudged"
P=$(prompt_text)
has "$P" "idle for 15 minutes without opening a pull request" "saying how long"
has "$P" "$PQ_HOME/tasks/$(basename "$R")/contract.md" "pointing at its contract, through the stable path"
has "$P" "STUCK:" "and at the way to say it is stuck"
hasnt "$P" "'" "quote-free"
has "$out" "idle 15m with no pull request - nudged it (nudge 1 of 3)" "said in the log"
eq "$(st "$R" PQ_NUDGES)" "1" "counted"
eq "$(agent_cell "$R" running)" "idle" "a nudged agent still reads as what it is"

echo "== the agent moving after a nudge does not buy it more nudges ==" >&2
rec "$R" working; rec "$R" idle                # it replied, and stopped again
later "$QUIET_AFTER"; check_quiet "$R" >/dev/null 2>&1
eq "$(st "$R" PQ_NUDGES)" "2" "quiet again: the second nudge"
rec "$R" idle
later "$QUIET_AFTER"; check_quiet "$R" >/dev/null 2>&1
eq "$(st "$R" PQ_NUDGES)" "3" "the third"
rec "$R" idle
later "$QUIET_AFTER"; out=$(check_quiet "$R" 2>&1)
eq "$(prompts)" "3" "and no fourth"
has "$out" "idle with no pull request after 3 nudges - look at it" "it is handed to you"
eq "$(agent_cell "$R" running)" "quiet" "pq ls says so"
LS=$(PQ_WIDTH=200 main ls 2>&1)
has "$LS" "(1 needs you)" "and counts it as needing you"
later "$QUIET_AFTER"; eq "$(check_quiet "$R" 2>&1)" "" "once"
set_panes "$(printf 'w1:p1\tclaude\tworking')"
eq "$(agent_cell "$R" running)" "working" "set going again, it simply reads as working"

echo "== pq's own nudge restarts the stretch, not the record ==" >&2
reset_logs
N=$(mk_task running 19 nudgeclock w1:p2)
set_panes "$(printf 'w1:p2\tclaude\tidle')"
rec "$N" idle
later "$QUIET_AFTER"; check_quiet "$N" >/dev/null 2>&1
eq "$(prompts)" "1" "nudged"
later $(( QUIET_AFTER - 1 )); check_quiet "$N" >/dev/null 2>&1
eq "$(prompts)" "1" "not again until a full QUIET_AFTER after the nudge"
later 1; check_quiet "$N" >/dev/null 2>&1
eq "$(prompts)" "2" "then it is"

echo "== an interrupted turn (last record still working, herdr idle) is nudged ==" >&2
reset_logs
X=$(mk_task running 20 esc w1:p3)
set_panes "$(printf 'w1:p3\tclaude\tidle')"
rec "$X" working
later "$QUIET_AFTER"; check_quiet "$X" >/dev/null 2>&1
eq "$(prompts)" "1" "a turn ended with Esc has no Stop, and is still nudged"

echo "== a working agent is never quiet, and a done one is never nudged ==" >&2
reset_logs
W=$(mk_task running 11 busy w2:p1)
set_panes "$(printf 'w2:p1\tclaude\tworking')"
rec "$W" working
later $(( QUIET_AFTER * 2 )); check_quiet "$W" >/dev/null 2>&1
eq "$(prompts)" "0" "herdr says working: no nudge, however old the record"
D=$(mk_task "done" 12 finished w3:p1)
set_panes "$(printf 'w3:p1\tclaude\tidle')"
rec "$D" idle
later $(( QUIET_AFTER * 2 )); check_quiet "$D" >/dev/null 2>&1
eq "$(prompts)" "0" "a done agent resting idle is finished, not quiet"

echo "== no agent.json: no signal, no knocks, no nudges ==" >&2
reset_logs
Z=$(mk_task running 21 nohooks w1:p4)
set_panes "$(printf 'w1:p4\tclaude\tidle')"
later $(( QUIET_AFTER * 3 )); check_quiet "$Z" >/dev/null 2>&1
eq "$(prompts)" "0" "nothing to read, nothing done"
eq "$(agent_cell "$Z" running)" "idle" "and it reads as herdr says"
printf 'not json' > "$(task_home "$Z")/agent.json"
check_quiet "$Z" >/dev/null 2>&1
eq "$(prompts)" "0" "an unreadable record is no signal either"

echo "== a turn that ended on an API error is knocked on with continue ==" >&2
reset_logs
E=$(mk_task running 13 apierror w4:p1)
set_panes "$(printf 'w4:p1\tclaude\tidle')"
rec "$E" error server_error "API Error: 500 Internal server error"
out=$(check_quiet "$E" 2>&1)
eq "$(prompts)" "1" "knocked on"
eq "$(prompt_text)" "Continue with what you were doing." "with a plain continue"
has "$out" "stopped on server_error (\"API Error: 500 Internal server error\")" "naming the error"
has "$out" "knocked (attempt 1)" "and the attempt"
rec "$E" error server_error "API Error: 500 again"
later 120; check_quiet "$E" >/dev/null 2>&1
eq "$(prompts)" "1" "not again inside ERROR_RETRY"
later "$ERROR_RETRY"; check_quiet "$E" >/dev/null 2>&1
eq "$(prompts)" "2" "and again once it is due"
for n in 3 4 5 6; do rec "$E" error overloaded "API Error: 529 ($n)"; later "$ERROR_RETRY"; check_quiet "$E" >/dev/null 2>&1; done
eq "$(st "$E" PQ_ERR_KNOCKS)" "6" "up to ERROR_KNOCKS"
later "$ERROR_RETRY"; out=$(check_quiet "$E" 2>&1)
eq "$(prompts)" "6" "and no further"
has "$out" "after 6 knocks - look at it" "handed to you"
eq "$(agent_cell "$E" running)" "error" "pq ls says so"

echo "== a turn that ends in idle is the recovery ==" >&2
rec "$E" idle
check_quiet "$E" >/dev/null 2>&1
eq "$(st "$E" PQ_ERR_KNOCKS)" "" "the count resets"
eq "$(agent_cell "$E" running)" "idle" "and it reads as idle again"

echo "== the account limit is handed over at once, never knocked on ==" >&2
reset_logs
for kind in rate_limit billing_error; do
  A=$(mk_task running 2$RANDOM "limit-$kind" w1:p5)
  set_panes "$(printf 'w1:p5\tclaude\tidle')"
  rec "$A" error "$kind" "You've hit your session limit"
  out=$(check_quiet "$A" 2>&1)
  eq "$(prompts)" "0" "$kind: no knock"
  has "$out" "stopped on $kind" "$kind: said"
  eq "$(agent_cell "$A" running)" "error" "$kind: pq ls says so at once"
done

echo "== a login that expired, in a done task too ==" >&2
reset_logs
L=$(mk_task "done" 14 tiptap w5:p1)
set_panes "$(printf 'w5:p1\tclaude\tidle')"
rec "$L" error authentication_failed "Login expired · Please run /login"
check_quiet "$L" >/dev/null 2>&1
eq "$(prompts)" "1" "a done agent stopped on an error is knocked on as well"

echo "== a permission record is left alone, and never knocked on ==" >&2
reset_logs
G=$(mk_task running 22 perm w1:p6)
set_panes "$(printf 'w1:p6\tclaude\tidle')"
rec "$G" permission
later $(( QUIET_AFTER * 2 )); check_quiet "$G" >/dev/null 2>&1
eq "$(prompts)" "0" "no nudge for an agent on a dialog"
eq "$(agent_cell "$G" running)" "permission" "and it reads as permission"

echo "== a knock the pane refuses is said, not counted ==" >&2
reset_logs
K=$(mk_task running 16 dialog w7:p1)
set_panes "$(printf 'w7:p1\tclaude\tidle')"
rec "$K" error server_error "API Error: 500"
printf 'agent_blocked' > "$STUBBIN/.prompt-fail"
out=$(check_quiet "$K" 2>&1)
has "$out" "could not knock (agent_blocked)" "said"
eq "$(st "$K" PQ_ERR_KNOCKS)" "" "and not counted"

echo "== through tick_body ==" >&2
reset_logs
rm -rf "$PQ_HOME/running" "$PQ_HOME/done"; mkdir -p "$PQ_HOME/running" "$PQ_HOME/done"
PR_CACHE="$PQ_HOME/.test.pr"; PR_ANS="$PQ_HOME/.test.ans"; : > "$PR_CACHE"; : > "$PR_ANS"
T=$(mk_task running 17 ticked w8:p1)
set_panes "$(printf 'w8:p1\tclaude\tidle')"
rec "$T" idle
later "$QUIET_AFTER"
: > "$PR_CACHE"; : > "$PR_ANS"
tick_body 0 0 >/dev/null 2>&1
eq "$(st "$T" PQ_NUDGES)" "1" "a tick nudges a quiet running agent"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
