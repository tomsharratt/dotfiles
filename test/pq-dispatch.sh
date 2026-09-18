#!/usr/bin/env bash
# test/pq-dispatch.sh - what dispatch does to a task: the dev server is no
# longer dropped, the contract is written once, and the agent is started and
# prompted through herdr's agent API rather than typed into the pane.
#
# Merges test/pq-base.sh's JSON-returning `wt` stub with test/pq-quota.sh's
# recording `herdr` stub, plus `agent start` / `agent prompt` arms that answer
# the way herdr really does: JSON on stdout and exit 0 either way, an error
# being an {"error":{"code":...}} body.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PQ_HOME=$(mktemp -d)
export PQ_HOME

STUBBIN=$(mktemp -d)
PANES_JSON="$STUBBIN/.panes.json"
HERDR_LOG="$STUBBIN/.herdr-calls"
WT_LOG="$STUBBIN/.wt-calls"
WT_PATH_DIR=$(mktemp -d)
printf '{"result":{"snapshot":{"panes":[]}}}' > "$PANES_JSON"
: > "$HERDR_LOG"; : > "$WT_LOG"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/claude"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/gh"
# Every call is logged as one line of tab-separated argv. `agent start` fails
# with the code in .start-fail (once, when .start-fail-once), `agent prompt`
# with the code in .prompt-fail.
cat > "$STUBBIN/herdr" <<EOF
#!/bin/sh
{ for a in "\$@"; do printf '%s\t' "\$a"; done; printf '\n'; } >> "$HERDR_LOG"
case "\$1 \$2" in
  "api snapshot") cat "$PANES_JSON"; exit 0 ;;
  "agent start")
    if [ -f "$STUBBIN/.start-fail-once" ]; then
      code=\$(cat "$STUBBIN/.start-fail-once"); rm -f "$STUBBIN/.start-fail-once"
      printf '{"error":{"code":"%s","message":"stub"},"id":"cli:agent:start"}\n' "\$code"; exit 0
    fi
    if [ -f "$STUBBIN/.start-fail" ]; then
      printf '{"error":{"code":"%s","message":"stub"},"id":"cli:agent:start"}\n' "\$(cat "$STUBBIN/.start-fail")"; exit 0
    fi
    printf '{"id":"cli:agent:start","result":{"agent":{"pane_id":"%s","name":"%s"}}}\n' "\$5" "\$3"; exit 0 ;;
  "agent prompt")
    if [ -f "$STUBBIN/.prompt-fail" ]; then
      printf '{"error":{"code":"%s","message":"stub"},"id":"cli:agent:prompt"}\n' "\$(cat "$STUBBIN/.prompt-fail")"; exit 0
    fi
    printf '{"id":"cli:agent:prompt","result":{"submitted":true}}\n'; exit 0 ;;
esac
exit 1
EOF
cat > "$STUBBIN/wt-stub" <<EOF
#!/bin/sh
{ printf '%s\t' "\$PWD"; for a in "\$@"; do printf '%s\t' "\$a"; done; printf '\n'; } >> "$WT_LOG"
printf '{"root_pane_id":"w1:p1","dev_pane_id":"w1:p2","path":"%s","workspace_id":"w1","url":"https://task.test","port":3101}\n' "$WT_PATH_DIR"
exit 0
EOF
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

cleanup() { rm -rf "$PQ_HOME" "$STUBBIN" "$WT_PATH_DIR" "${REPO:-}"; }
trap cleanup EXIT

REPO=$(mktemp -d)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$REPO/.git/refs/remotes/origin"
git -C "$REPO" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
git -C "$REPO" branch -q live-events master
git -C "$REPO" update-ref refs/remotes/origin/live-events refs/heads/live-events

unset HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID
PQ_DONE_KEEP=99

reset_tasks() {
  rm -rf "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done"
  mkdir -p "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done"
}
reset_tasks
reset_logs() { : > "$HERDR_LOG"; : > "$WT_LOG"; rm -f "$STUBBIN/.start-fail" "$STUBBIN/.start-fail-once" "$STUBBIN/.prompt-fail"; }

mk_task() {                             # state prio slug branch [base] [design] -> task_dir
  local state=$1 prio=$2 slug=$3 branch=$4 base=${5:-} design=${6:-}
  local dir="$PQ_HOME/$state/$(printf '%014d' $(( 20260101000000 + 10#$prio )))-$slug"
  mkdir -p "$dir"
  {
    printf -- '---\n'
    printf 'repo:     %s\n' "$REPO"
    printf 'branch:   %s\n' "$branch"
    [ -n "$base" ] && printf 'base:     %s\n' "$base"
    [ -n "$design" ] && printf 'design:   %s\n' "$design"
    printf 'model:    sonnet\n'
    printf 'effort:   xhigh\n'
    printf 'intent:   Make the thing better.\n'
    printf 'added:    2026-01-01T00:00:00Z\n'
    printf -- '---\n\nplan body\n'
  } > "$dir/plan.md"
  printf '%s' "$dir"
}
set_panes() {                           # "pane<TAB>agent<TAB>status" lines
  PIDX=$1; PIDX_OK=1
  if [ -z "$1" ]; then printf '{"result":{"snapshot":{"panes":[]}}}' > "$PANES_JSON"; return; fi
  jq -Rs 'split("\n") | map(select(length > 0) | split("\t")
            | { pane_id: .[0],
                agent:        (if (.[1] // "") == "" then null else .[1] end),
                agent_status: (if (.[2] // "") == "" then null else .[2] end) })
          | { result: { snapshot: { panes: . } } }' <<<"$1" > "$PANES_JSON"
}
herdr_calls() { cut -f1,2 "$HERDR_LOG" | tr '\t' ' ' | grep -v '^api snapshot' | tr '\n' ';'; }
start_line() { grep "^agent	start	" "$HERDR_LOG" | head -1 | tr '\t' ' ' | sed 's/ *$//'; }
prompt_text() { grep "^agent	prompt	" "$HERDR_LOG" | head -1 | cut -f4; }

echo "== a fresh dispatch: wt new keeps the dev server, and every fact is recorded ==" >&2
reset_tasks; reset_logs; set_panes ""
D=$(mk_task running 001 first tom/first)
dispatch_task "$D" >/dev/null 2>&1; rc=$?
eq "$rc" "0" "dispatch should succeed"
grep -q "	new	" "$WT_LOG" && ok || bad "wt new should have been called"
grep -q -- "--no-dev" "$WT_LOG" && bad "wt new must no longer be told --no-dev - the implementer needs a running app" || ok
grep -q -- "--no-agent" "$WT_LOG" && ok || bad "pq starts its own agent, so wt must not"
eq "$(st "$D" PQ_PANE)" "w1:p1" "the root pane is recorded"
eq "$(st "$D" PQ_DEV_PANE)" "w1:p2" "the dev pane is recorded too"
eq "$(st "$D" PQ_URL)" "https://task.test" "and the url"
[ -n "$(st "$D" PQ_STARTED)" ] && ok || bad "a successful start is recorded"
[ -n "$(st "$D" PQ_LAUNCHED)" ] && ok || bad "a delivered prompt is recorded"

echo "== the agent is started and prompted through herdr's agent API ==" >&2
eq "$(herdr_calls)" "agent start;agent prompt;" "exactly one start, then one prompt, and nothing typed into the pane"
grep -q "^pane	send-text" "$HERDR_LOG" && bad "nothing may be typed into the pane any more" || ok
eq "$(start_line)" "agent start first --kind claude --pane w1:p1 --timeout 60000 -- --model sonnet --effort xhigh" \
  "the start names the agent after the slug and passes model and effort after --"
H="$PQ_HOME/tasks/$(basename "$D")"
eq "$(readlink "$H")" "$D" "the stable tasks/ link points at the task"
P=$(prompt_text)
has "$P" "Read $H/plan.md and carry it out." "the prompt points at the plan through the STABLE path - the real one moves"
has "$P" "$H/contract.md is how to deliver it" "and at the contract, the same way"
hasnt "$P" "$D/" "never the state directory, which is gone the moment reconcile moves the task"
has "$P" "Never wait for input - there is nobody watching." "and says nobody is watching"
hasnt "$P" "'" "quote-free by convention"
hasnt "$P" "--base" "no base clause for a task on the default branch"
eq "$(grep -c "^agent	prompt	" "$HERDR_LOG")" "1" "one prompt"
eq "$(awk -F'\t' '$1 == "agent" && $2 == "prompt" { print $3 }' "$HERDR_LOG")" "w1:p1" "aimed at the task's pane"

echo "== the contract, written once, with what the header says ==" >&2
C="$D/contract.md"
[ -f "$C" ] && ok || bad "contract.md should be written at dispatch"
has "$(cat "$C")" "## Working" "it has the working rules"
has "$(cat "$C")" "## Verifying, before the pull request" "the verification rules"
has "$(cat "$C")" "## The pull request" "and the pull request rules"
has "$(cat "$C")" "pq evidence first" "it names the evidence command for this slug"
has "$(cat "$C")" "https://task.test" "it names the worktree's own url"
has "$(cat "$C")" "wt dev $WT_PATH_DIR" "and how to restart its server"
has "$(cat "$C")" "gh pr create --draft" "the pull request opens as a draft"
has "$(cat "$C")" "STUCK:" "and a stuck agent knows how to say so"
has "$(cat "$C")" "$H/evidence/" "screenshots go into the task's evidence/, through the stable path"
hasnt "$(cat "$C")" "$D/" "the contract never names the state directory either"
[ -d "$H/" ] && ok || bad "the stable path resolves to a real directory"
has "$(cat "$C")" "Make the thing better." "the intent line is carried in"
hasnt "$(cat "$C")" "## Design fidelity" "no design section without a design"
hasnt "$(cat "$C")" "forked from" "no base clause without a base"
grep -q -- '—' "$C" && bad "no em dashes" || ok
printf 'MARKER-KEEP\n' >> "$C"
st_set "$D" PQ_LAUNCHED ""
set_panes "$(printf 'w1:p1\tclaude\tidle')"
dispatch_task "$D" >/dev/null 2>&1
grep -q MARKER-KEEP "$C" && ok || bad "a re-entered dispatch must never rewrite a running agent's contract"

echo "== the contract carries the design and base sections when the header does ==" >&2
reset_tasks; reset_logs; set_panes ""
DB=$(mk_task running 002 based tom/based live-events "Onboarding Refresh.dc.html, shot.png")
dispatch_task "$DB" >/dev/null 2>&1
C="$DB/contract.md"
has "$(cat "$C")" "## Design fidelity" "a design task gets the design section"
has "$(cat "$C")" "Onboarding Refresh.dc.html, shot.png" "naming its files"
has "$(cat "$C")" "$PQ_HOME/tasks/$(basename "$DB")/design/" "and where they are, through the stable path"
has "$(cat "$C")" "NN-<screen>-design.png" "and how to name the comparison pairs"
has "$(cat "$C")" "## Design fidelity\` table" "the PR section asks for the fidelity table"
has "$(cat "$C")" "forked from \`live-events\`" "a based task gets the base clause"
has "$(cat "$C")" "gh pr create --base live-events" "with the flag to pass"
P=$(prompt_text)
has "$P" "--base live-events" "and the prompt carries the base too"
grep -q "	--base	origin/live-events	" "$WT_LOG" && ok || bad "wt new forks from the base"

echo "== re-entry with PQ_STARTED set logs no second start ==" >&2
reset_logs
st_set "$DB" PQ_LAUNCHED ""
set_panes "$(printf 'w1:p1\tclaude\tidle')"
dispatch_task "$DB" >/dev/null 2>&1; rc=$?
eq "$rc" "0" "the resumed dispatch succeeds"
eq "$(herdr_calls)" "agent prompt;" "only the prompt is repeated"
grep -q "	new	" "$WT_LOG" && bad "wt new must not run again while the pane is there" || ok

echo "== re-entry without PQ_STARTED but with an agent already in the pane skips the start ==" >&2
reset_logs
st_set "$DB" PQ_STARTED ""; st_set "$DB" PQ_LAUNCHED ""
set_panes "$(printf 'w1:p1\tclaude\tidle')"
dispatch_task "$DB" >/dev/null 2>"$PQ_HOME/.err"
eq "$(herdr_calls)" "agent prompt;" "an agent herdr already reports is not started over"
has "$(cat "$PQ_HOME/.err")" "already in w1:p1" "and says so"
[ -n "$(st "$DB" PQ_STARTED)" ] && ok || bad "the start is recorded as done"

echo "== re-entry without PQ_STARTED and an empty pane starts the agent ==" >&2
reset_logs
st_set "$DB" PQ_STARTED ""; st_set "$DB" PQ_LAUNCHED ""
set_panes "$(printf 'w1:p1\t\t')"
dispatch_task "$DB" >/dev/null 2>&1
eq "$(herdr_calls)" "agent start;agent prompt;" "a pane with only a shell in it gets the agent started"

echo "== a failing start leaves PQ_LAUNCHED (and PQ_STARTED) empty ==" >&2
reset_tasks; reset_logs; set_panes ""
printf 'agent_start_timeout' > "$STUBBIN/.start-fail"
DF=$(mk_task running 003 failing tom/failing)
dispatch_task "$DF" >/dev/null 2>"$PQ_HOME/.err"; rc=$?
eq "$rc" "1" "dispatch reports failure"
eq "$(st "$DF" PQ_LAUNCHED)" "" "no launch recorded"
eq "$(st "$DF" PQ_STARTED)" "" "no start recorded"
eq "$(st "$DF" PQ_PANE)" "w1:p1" "but the worktree it did make is recorded, so the retry does not make another"
has "$(cat "$PQ_HOME/.err")" "could not start the agent in w1:p1 - agent_start_timeout" "the herdr code is named"
grep -q "^agent	prompt" "$HERDR_LOG" && bad "no prompt goes to an agent that did not start" || ok

echo "== a taken name is retried once with a suffix ==" >&2
reset_tasks; reset_logs; set_panes ""
printf 'agent_name_taken' > "$STUBBIN/.start-fail-once"
DN=$(mk_task running 004 taken tom/taken)
dispatch_task "$DN" >/dev/null 2>&1; rc=$?
eq "$rc" "0" "the retry succeeds"
eq "$(grep -c "^agent	start	" "$HERDR_LOG")" "2" "two starts"
first=$(awk -F'\t' '$1 == "agent" && $2 == "start" { print $3 }' "$HERDR_LOG" | sed -n 1p)
second=$(awk -F'\t' '$1 == "agent" && $2 == "start" { print $3 }' "$HERDR_LOG" | sed -n 2p)
eq "$first" "taken" "the first try uses the plain name"
case "$second" in taken-*) ok ;; *) bad "the second try must suffix the name (got '$second')" ;; esac

echo "== agent_not_ready still counts as started ==" >&2
reset_tasks; reset_logs; set_panes ""
printf 'agent_not_ready' > "$STUBBIN/.start-fail"
DR=$(mk_task running 005 notready tom/notready)
dispatch_task "$DR" >/dev/null 2>"$PQ_HOME/.err"; rc=$?
eq "$rc" "0" "an agent that came up on a dialog is up"
[ -n "$(st "$DR" PQ_STARTED)" ] && ok || bad "and is recorded as started"
has "$(cat "$PQ_HOME/.err")" "not ready for input yet" "with a note"

echo "== a refused prompt leaves PQ_LAUNCHED empty, so the resume path retries ==" >&2
reset_tasks; reset_logs; set_panes ""
printf 'agent_blocked' > "$STUBBIN/.prompt-fail"
DP=$(mk_task running 006 blockedp tom/blockedp)
dispatch_task "$DP" >/dev/null 2>"$PQ_HOME/.err"; rc=$?
eq "$rc" "1" "dispatch reports failure"
[ -n "$(st "$DP" PQ_STARTED)" ] && ok || bad "the start itself succeeded and is kept"
eq "$(st "$DP" PQ_LAUNCHED)" "" "no launch recorded"
has "$(cat "$PQ_HOME/.err")" "could not deliver the prompt to w1:p1 (agent_blocked)" "the refusal is named"
# ...and the retry, once the dialog is gone, prompts without starting again.
reset_logs
set_panes "$(printf 'w1:p1\tclaude\tidle')"
dispatch_task "$DP" >/dev/null 2>&1; rc=$?
eq "$rc" "0" "the retry succeeds"
eq "$(herdr_calls)" "agent prompt;" "with only the prompt"
[ -n "$(st "$DP" PQ_LAUNCHED)" ] && ok || bad "and the launch is recorded"

echo "== herdr answering nothing at all is a failure, not a success ==" >&2
# herdr exits 0 with a JSON body either way; an empty body with exit 0 is the
# one shape that must not read as success.
mkdir -p "$STUBBIN/quiet"
printf '#!/bin/sh\nexit 0\n' > "$STUBBIN/quiet/herdr"; chmod +x "$STUBBIN/quiet/herdr"
reset_tasks; set_panes ""
DQ=$(mk_task running 007 quiet tom/quiet)
( PATH="$STUBBIN/quiet:$PATH" dispatch_task "$DQ" ) >/dev/null 2>&1; rc=$?
eq "$rc" "1" "a silent herdr fails the dispatch"
eq "$(st "$DQ" PQ_STARTED)" "" "and records no start"

echo "== the helpers ==" >&2
eq "$(herdr_err '{"error":{"code":"agent_blocked"}}')" "agent_blocked" "herdr_err reads the code"
eq "$(herdr_err '{"result":{}}')" "" "and nothing on success"
eq "$(herdr_err '')" "" "or on an empty body"
eq "$(agent_name live-chat-mentions)" "live-chat-mentions" "a plain slug is its own name"
eq "$(agent_name 2fa-fix)" "t-2fa-fix" "a slug starting with a digit is prefixed"
longname=$(agent_name a-very-long-slug-that-runs-well-past-the-limit-herdr-sets)
eq "${#longname}" "24" "a long slug is cut to 24"
eq "$(agent_name fix 123)" "fix-123" "a suffix is appended"
code=$(agent_prompt w1:p1 hello); rc=$?
eq "$rc" "0" "agent_prompt returns 0 on success"
eq "$code" "" "and prints nothing"
printf 'agent_blocked' > "$STUBBIN/.prompt-fail"
code=$(agent_prompt w1:p1 hello); rc=$?
eq "$rc" "2" "agent_blocked is 2"
eq "$code" "agent_blocked" "and the code is printed"
printf 'agent_not_found' > "$STUBBIN/.prompt-fail"
code=$(agent_prompt w1:p1 hello); rc=$?
eq "$rc" "1" "any other error is 1"
reset_logs

echo "== dispatch_prompt ==" >&2
p=$(dispatch_prompt /tasks/x)
has "$p" "Read /tasks/x/plan.md" "the plan path"
has "$p" "/tasks/x/contract.md" "the contract path"
hasnt "$p" "--base" "no base clause without a base"
p=$(dispatch_prompt /tasks/x live-events)
has "$p" "--base live-events" "the base clause with one"
hasnt "$p" "'" "quote-free"

echo "== a directory in running/ with no plan.md is a phantom, not a task ==" >&2
# What a stale path produces: an agent's `mkdir -p` into a task directory that
# reconcile has already moved. It must not be resumed as a dispatch, and must
# not spend a slot.
reset_tasks; reset_logs; set_panes ""
mkdir -p "$PQ_HOME/running/00020260101000099-phantom/evidence"
mk_task queue 011 real tom/real >/dev/null
PQ_SUMMARY=""
tick_body 1 0 >"$PQ_HOME/.tick" 2>&1
has "$(cat "$PQ_HOME/.tick")" "has no plan.md - not a task pq made" "the phantom is named for what it is"
has "$(cat "$PQ_HOME/.tick")" "rm -rf $PQ_HOME/running/00020260101000099-phantom" "with the fix"
hasnt "$(cat "$PQ_HOME/.tick")" "dispatch was interrupted" "and not mistaken for an interrupted dispatch"
[ -n "$(ls -d "$PQ_HOME"/running/*-real 2>/dev/null)" ] && ok || bad "the phantom must not spend the one slot - the real task dispatches"
PQ_SUMMARY=""
tick_body 1 0 >"$PQ_HOME/.tick2" 2>&1
hasnt "$(cat "$PQ_HOME/.tick2")" "has no plan.md" "warned once, not every tick"

echo "== through tick_body: a queued task is dispatched end to end ==" >&2
reset_tasks; reset_logs; set_panes ""
mk_task queue 010 viatick tom/viatick >/dev/null
PQ_SUMMARY=""
tick_body 1 0 >/dev/null 2>&1
T=$(ls -d "$PQ_HOME/running"/*-viatick 2>/dev/null | head -1)
[ -n "$T" ] && ok || bad "the task should have been claimed into running/"
[ -n "$(st "$T" PQ_LAUNCHED)" ] && ok || bad "and launched"
[ -f "$T/contract.md" ] && ok || bad "with a contract"
eq "$(readlink "$PQ_HOME/tasks/$(basename "$T")")" "$T" "and the stable link followed it into running/"
eq "$(herdr_calls)" "agent start;agent prompt;" "start then prompt"
has "$PQ_SUMMARY" "1 started" "the summary counts it"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
