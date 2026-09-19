#!/usr/bin/env bash
# test/pq-review.sh - the review gate: one independent `/code-review` per pull
# request, run by pq in the background, then a follow-up prompt to the
# implementer to resolve the findings and mark the draft ready.
#
# Same shape as test/pq-slots.sh - a pinned clock, `set_panes` steering herdr's
# snapshot, `tick_body` for the end-to-end cases - plus a `claude` stub that
# records how it was called and behaves per a mode file (sleeps, succeeds, fails,
# is denied), and a `gh` stub serving the one probe and the one comment count the
# gate asks for.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PQ_HOME=$(mktemp -d)
export PQ_HOME

STUBBIN=$(mktemp -d)
PANES_JSON="$STUBBIN/.panes.json"
HERDR_LOG="$STUBBIN/.herdr-calls"
CLAUDE_LOG="$STUBBIN/.claude-calls"
MODE="$STUBBIN/.mode"
PRJSON="$STUBBIN/.pr.json"
COMMENTS="$STUBBIN/.comments"
printf '{"result":{"snapshot":{"panes":[]}}}' > "$PANES_JSON"
: > "$HERDR_LOG"; : > "$CLAUDE_LOG"; printf 'ok' > "$MODE"; printf '0' > "$COMMENTS"
# One line per call: the cwd, then argv, tab separated - and then whatever the
# mode says. `sleep` is the reviewer still running; the test kills it.
cat > "$STUBBIN/claude" <<EOF
#!/bin/sh
{ printf '%s\t' "\$PWD"; for a in "\$@"; do printf '%s\t' "\$a"; done; printf '\n'; } >> "$CLAUDE_LOG"
case "\$(cat "$MODE")" in
  sleep)     sleep 30; exit 0 ;;
  ok)        printf '{"is_error":false,"total_cost_usd":1.2,"duration_ms":5000,"permission_denials":[]}\n'; exit 0 ;;
  fail)      printf '{"is_error":true}\n'; exit 1 ;;
  malformed) printf 'not json at all\n'; exit 0 ;;
  denied)    printf '{"is_error":false,"permission_denials":[{"tool_name":"Bash","tool_input":{"command":"gh api repos/x/y/pulls/42/comments -f body=hi"}}]}\n'; exit 0 ;;
  otherdeny) printf '{"is_error":false,"permission_denials":[{"tool_name":"Bash","tool_input":{"command":"bundle info activesupport"}}]}\n'; exit 0 ;;
esac
exit 1
EOF
cat > "$STUBBIN/gh" <<EOF
#!/bin/sh
case "\$*" in
  *"pr view"*)  [ -f "$PRJSON" ] && cat "$PRJSON" && exit 0; exit 1 ;;
  *"/comments"*) cat "$COMMENTS"; exit 0 ;;
esac
exit 1
EOF
cat > "$STUBBIN/herdr" <<EOF
#!/bin/sh
{ for a in "\$@"; do printf '%s\t' "\$a"; done; printf '\n'; } >> "$HERDR_LOG"
case "\$1 \$2" in
  "api snapshot") cat "$PANES_JSON"; exit 0 ;;
  "agent prompt")
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

# Any reviewer still sleeping when this file ends must not outlive it.
cleanup() {
  local d
  for d in "$PQ_HOME"/done/*/; do [ -d "$d" ] && review_kill "${d%/}"; done
  rm -rf "$PQ_HOME" "$STUBBIN" "${REPO:-}" "${WT:-}"
}
trap cleanup EXIT

REPO=$(mktemp -d)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$REPO/.git/refs/remotes/origin"
git -C "$REPO" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
WT=$(mktemp -d)                         # the task's worktree, where the reviewer must run

unset HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID
PQ_DONE_KEEP=99
PQ_WRAPUP_GRACE=300
PQ_REVIEW_TIMEOUT=1500
PQ_REVIEW_MAX_TRIES=2
PQ_REVIEW_RETRY=600
PQ_REVIEW_SPLIT_LINES=150
PQ_REVIEW_EFFORT=high                   # deliberately not the default (xhigh), so the assertions below prove the knob is passed through

# The clock is pinned, as in test/pq-slots.sh: the gate's timeout, retry and
# grace comparisons all sit on boundaries, and `epoch` is what review_task reads.
FAKE_NOW=$(date -u '+%s')
epoch() { printf '%s' "$FAKE_NOW"; }
now()   { date -u -r "$FAKE_NOW" '+%Y-%m-%dT%H:%M:%SZ'; }
ago()   { date -u -r "$(( FAKE_NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }

reset_caches() { PR_CACHE="$PQ_HOME/.test.pr"; PR_ANS="$PQ_HOME/.test.ans"; : > "$PR_CACHE"; : > "$PR_ANS"; }
cache_row() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$PR_CACHE"; }   # repo branch num state draft base
reset_tasks() {
  local d
  for d in "$PQ_HOME"/done/*/; do [ -d "$d" ] && review_kill "${d%/}"; done
  rm -rf "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done" "$PQ_HOME/archive"
  mkdir -p "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done" "$PQ_HOME/archive"
}
reset_tasks
reset_logs() { : > "$HERDR_LOG"; : > "$CLAUDE_LOG"; rm -f "$STUBBIN/.prompt-fail"; }
mode() { printf '%s' "$1" > "$MODE"; }
pr_json() {                             # title state draft commits additions deletions
  jq -nc --arg t "$1" --arg s "$2" --argjson d "$3" --argjson c "$4" --argjson a "$5" --argjson r "$6" \
    '{title:$t, state:$s, isDraft:$d, commits:[range($c)|{oid:"x"}], additions:$a, deletions:$r}' > "$PRJSON"
}
pr_json "Do the thing" OPEN true 3 100 20

TICKOUT="$PQ_HOME/.tick.out"
tick() {                                # cap dry -> stdout+stderr in $OUT
  PQ_SUMMARY=""
  tick_body "$1" "$2" > "$TICKOUT" 2>&1
  OUT=$(cat "$TICKOUT")
}

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
    printf 'intent:   test fixture\n'
    printf 'added:    2026-01-01T00:00:00Z\n'
    printf -- '---\n\nplan body\n'
  } > "$dir/plan.md"
  [ -n "$pane" ] && st_set "$dir" PQ_PANE "$pane"
  st_set "$dir" PQ_WORKTREE "$WT"
  printf '%s' "$dir"
}
# A done task with an open draft PR #42, its review gate pending.
mk_gated() {                            # prio slug pane -> task_dir
  local d; d=$(mk_task done "$1" "$2" "tom/$2" "$3")
  st_set "$d" PQ_LAUNCHED "$(now)"; st_set "$d" PQ_PR 42; st_set "$d" PQ_FINISHED "$(now)"
  st_set "$d" PQ_REVIEW pending
  cache_row "$REPO" "tom/$2" 42 OPEN draft master
  printf '%s' "$d"
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
claude_calls() { grep -c . "$CLAUDE_LOG" 2>/dev/null || true; }
# The reviewer is launched in the background and review_task returns at once,
# so the stub's log line lands a moment later - poll for it rather than race it.
wait_calls() {                          # n
  local i; for i in $(seq 1 50); do [ "$(claude_calls)" -ge "$1" ] && return 0; sleep 0.1; done
  return 1
}
prompt_text() { grep "^agent	prompt	" "$HERDR_LOG" | tail -1 | cut -f4; }
# Wait for the stub to have finished writing review.rc - it is a real background
# process, so a bounded poll rather than a fixed sleep.
wait_rc() {                             # task_dir
  local i; for i in $(seq 1 50); do [ -f "$1/review.rc" ] && return 0; sleep 0.1; done
  return 1
}

echo "== reconcile stamps pending, once, and not under --dry-run ==" >&2
reset_tasks; reset_caches; reset_logs
R=$(mk_task running 001 fresh tom/fresh w1:p1)
st_set "$R" PQ_LAUNCHED "$(now)"
cache_row "$REPO" tom/fresh 42 OPEN draft master
set_panes "$(printf 'w1:p1\tclaude\tworking')"
tick 3 1
eq "$(st "$R" PQ_REVIEW)" "" "--dry-run stamps nothing"
[ -d "$R" ] && ok || bad "--dry-run moves nothing either"
reset_caches; cache_row "$REPO" tom/fresh 42 OPEN draft master
tick 3 0
D=$(ls -d "$PQ_HOME"/done/*-fresh); D=${D%/}
[ -d "$D" ] && ok || bad "the task reaches done/"
eq "$(st "$D" PQ_REVIEW)" "pending" "and its gate is opened"
eq "$(st "$D" PQ_PR)" "42" "alongside the PR number"
eq "$(readlink "$PQ_HOME/tasks/$(basename "$D")")" "$D" "the stable link now points into done/"
review_settled "$D" && bad "pending is not settled" || ok
review_inflight "$D" && ok || bad "pending is in flight"
eq "$(claude_calls)" "0" "the agent was still working, so nothing launched on that tick"

echo "== a task from before the gate is never touched ==" >&2
L=$(mk_task done 002 legacy tom/legacy w2:p1)
st_set "$L" PQ_LAUNCHED "$(now)"; st_set "$L" PQ_PR 7; st_set "$L" PQ_FINISHED "$(now)"
reset_caches; cache_row "$REPO" tom/legacy 7 OPEN draft master; cache_row "$REPO" tom/fresh 42 OPEN draft master
set_panes "$(printf 'w1:p1\tclaude\tworking\nw2:p1\tclaude\tidle')"
tick 3 0
eq "$(st "$L" PQ_REVIEW)" "" "an unset key stays unset"
review_settled "$L" && ok || bad "and reads as settled, exactly as it always did"
eq "$(agent_cell "$L" done)" "wrapping up" "with the cell it always had"

echo "== pending defers while the agent is working, blocked, walled, or herdr is silent ==" >&2
reset_tasks; reset_caches; reset_logs
G=$(mk_gated 010 gated w1:p1)
for s in working blocked; do
  set_panes "$(printf 'w1:p1\tclaude\t%s' "$s")"
  review_task "$G" 0
  eq "$(st "$G" PQ_REVIEW)" "pending" "a $s agent is left alone"
done
set_panes "$(printf 'w1:p1\tclaude\tidle')"
st_set "$G" PQ_BLOCKED quota
review_task "$G" 0
eq "$(st "$G" PQ_REVIEW)" "pending" "a dismissed wall reads idle to herdr - PQ_BLOCKED holds it back"
st_set "$G" PQ_BLOCKED ""
PIDX=""; PIDX_OK=0
review_task "$G" 0
eq "$(st "$G" PQ_REVIEW)" "pending" "herdr silent is no verdict"
eq "$(claude_calls)" "0" "and nothing was launched through any of that"

echo "== --dry-run says what it would do and changes nothing ==" >&2
set_panes "$(printf 'w1:p1\tclaude\tidle')"
OUT=$(review_task "$G" 1 2>&1)
has "$OUT" "would probe #42 and launch a review of gated" "the would-line"
eq "$(st "$G" PQ_REVIEW)" "pending" "state untouched"
eq "$(claude_calls)" "0" "nothing launched"
eq "$(st "$G" PQ_REVIEW_TRIES)" "" "no try counted"

echo "== launch: idle agent, the reviewer runs in the worktree, and the tick returns at once ==" >&2
mode sleep; printf '3' > "$COMMENTS"
# Through a command substitution on purpose: a pipe stays open until its last
# writer exits, so a background reviewer that inherited the tick's stdout would
# make `out=$(pq tick)` wait for the whole review. This is how a monitor hung
# for twenty minutes the first time the gate ran.
T0=$(date +%s)
launch_out=$(review_task "$G" 0 2>&1)
T1=$(date +%s)
[ $(( T1 - T0 )) -lt 5 ] && ok || bad "review_task must not wait for the reviewer, even when its output is captured (took $(( T1 - T0 ))s)"
has "$launch_out" "reviewing #42 with opus in the background" "and says it launched"
eq "$(st "$G" PQ_REVIEW)" "running" "the gate is running"
eq "$(st "$G" PQ_REVIEW_TRIES)" "1" "one try"
eq "$(st "$G" PQ_REVIEW_COMMENTS)" "3" "the comment count at launch is recorded"
wait_calls 1
eq "$(claude_calls)" "1" "one reviewer"
line=$(head -1 "$CLAUDE_LOG")
eq "$(cut -f1 <<<"$line")" "$WT" "it runs in the task's worktree"
has "$line" "	-p	" "in print mode"
has "$line" "	--model	opus	" "with the reviewer model"
has "$line" "	--permission-mode	acceptEdits	" "accepting edits"
has "$line" "	--allowedTools	Bash(gh:*),Bash(git:*)	" "with gh and git allowed, or it cannot post"
has "$line" "	--output-format	json	" "and JSON out"
has "$line" "	--add-dir	$PQ_HOME/tasks/$(basename "$G")	" "with the task's own directory opened to it, through the stable path"
has "$line" "	/code-review 42 high --comment	" "the skill, the PR, the level, and --comment as the prompt"
PID=$(st "$G" PQ_REVIEW_PID)
[ -n "$PID" ] && review_alive "$PID" && ok || bad "the process group is recorded and alive"
[ -f "$G/review.rc" ] && bad "no exit code yet while it runs" || ok
eq "$(review_cell "$G")" "reviewing $(age_since "$(st "$G" PQ_REVIEW_AT)")" "the cell says reviewing, with an age"

echo "== once-only: a running gate launches nothing more ==" >&2
review_task "$G" 0 >/dev/null 2>&1
sleep 0.3
eq "$(claude_calls)" "1" "still one reviewer"
eq "$(st "$G" PQ_REVIEW)" "running" "still running"

echo "== slot_held and slot_state hold the slot with no clock while in flight ==" >&2
st_set "$G" PQ_WRAPUP_SINCE "$(ago 900)"
slot_held "$G" && ok || bad "an idle implementer under review still holds its slot"
eq "$(st "$G" PQ_WRAPUP_SINCE)" "" "and the wrap-up clock is cleared, not run"
eq "$(slot_state "$G")" "wrapping up" "slot_state agrees"
eq "$(active_slots)" "$(printf '0\t1')" "so the cap counts it"
eq "$(agent_cell "$G" done)" "reviewing $(age_since "$(st "$G" PQ_REVIEW_AT)")" "and the listing says why"

echo "== timeout kills the process group and counts a failed try ==" >&2
FAKE_NOW=$(( FAKE_NOW + PQ_REVIEW_TIMEOUT + 1 ))
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
sleep 0.3
review_alive "$PID" && bad "the reviewer's process group must be dead" || ok
eq "$(st "$G" PQ_REVIEW)" "pending" "back to pending - one try left"
eq "$(st "$G" PQ_REVIEW_RESULT)" "timeout" "with the reason"
eq "$(st "$G" PQ_REVIEW_RETRY_AT)" "$(( FAKE_NOW + PQ_REVIEW_RETRY ))" "and a retry armed"
has "$(cat "$PQ_HOME/.out")" "ran past ${PQ_REVIEW_TIMEOUT}s" "said out loud"

echo "== RETRY_AT is honoured, then the second try runs ==" >&2
reset_logs; mode ok
review_task "$G" 0 >/dev/null 2>&1
eq "$(claude_calls)" "0" "nothing before the retry is due"
FAKE_NOW=$(( FAKE_NOW + PQ_REVIEW_RETRY + 1 ))
review_task "$G" 0 >/dev/null 2>&1
wait_calls 1
eq "$(claude_calls)" "1" "the retry launches"
eq "$(st "$G" PQ_REVIEW_TRIES)" "2" "second try"

echo "== completion: posted, then the follow-up is delivered ==" >&2
wait_rc "$G" && ok || bad "the ok stub should have written review.rc"
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_REVIEW)" "posted" "collected as posted"
eq "$(st "$G" PQ_REVIEW_RESULT)" "ok" "with an ok result"
has "$(cat "$PQ_HOME/.out")" "review of #42 posted (\$1.20, 0m5s)" "cost and duration are reported"
eq "$(review_cell "$G")" "reviewed" "the cell says reviewed"
review_inflight "$G" && ok || bad "posted is still in flight - the follow-up has not gone"
st_set "$G" PQ_WRAPUP_SINCE "$(ago 100)"
reset_logs
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_REVIEW)" "prompted" "delivered"
[ -n "$(st "$G" PQ_REVIEW_PROMPTED)" ] && ok || bad "and stamped"
eq "$(st "$G" PQ_WRAPUP_SINCE)" "" "the wrap-up clock is cleared - this tick's snapshot predates the prompt"
P=$(prompt_text)
has "$P" "pull request #42" "the prompt names the PR"
has "$P" "inline review comments" "and says the findings are inline comments"
has "$P" "gh api repos/{owner}/{repo}/pulls/42/comments" "and how to read them"
has "$P" "gh pr ready 42" "and how to mark it ready"
has "$P" "Never wait for input" "and that nobody is watching"
hasnt "$P" "'" "quote-free"
hasnt "$P" "single commit" "no restructure clause for a three-commit PR"
grep -q -- "--wait" "$HERDR_LOG" && bad "no herdr call may carry --wait inside a tick" || ok
eq "$(awk -F'\t' '$1 == "agent" && $2 == "prompt" { print $3 }' "$HERDR_LOG")" "w1:p1" "aimed at the task's pane"
eq "$(review_cell "$G")" "resolving" "the cell says resolving"
review_inflight "$G" && bad "prompted is not in flight - the agent owns its PR again" || ok
review_settled "$G" && bad "but not settled either" || ok

echo "== prompted -> ready once the draft is marked ready; closed and merged settle it ==" >&2
reset_caches; cache_row "$REPO" tom/gated 42 OPEN draft master
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_REVIEW)" "prompted" "still a draft, still prompted"
reset_caches; cache_row "$REPO" tom/gated 42 OPEN "" master
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_REVIEW)" "ready" "no longer a draft: ready"
has "$(cat "$PQ_HOME/.out")" "#42 marked ready - the review gate is done" "and said"
eq "$(review_cell "$G")" "" "the cell falls silent"
review_settled "$G" && ok || bad "ready is settled"
st_set "$G" PQ_REVIEW prompted
reset_caches; cache_row "$REPO" tom/gated 42 CLOSED "" master
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_REVIEW)" "skipped" "a closed PR ends the gate"
eq "$(st "$G" PQ_REVIEW_WHY)" "settled" "as settled"
st_set "$G" PQ_REVIEW prompted
reset_caches; cache_row "$REPO" tom/gated 42 MERGED "" master
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_REVIEW)" "ready" "a merged PR is as ready as it gets"

echo "== prompted lapses when the agent goes quiet with the draft still open ==" >&2
reset_caches; cache_row "$REPO" tom/gated 42 OPEN draft master
st_set "$G" PQ_REVIEW prompted; st_set "$G" PQ_REVIEW_WHY ""
set_panes "$(printf 'w1:p1\tclaude\tidle')"
st_set "$G" PQ_WRAPUP_SINCE "$(ago 100)"
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_REVIEW)" "prompted" "idle inside the grace is still working on it"
st_set "$G" PQ_WRAPUP_SINCE "$(ago 301)"
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_REVIEW)" "lapsed" "idle past the grace with a draft: lapsed"
eq "$(st "$G" PQ_REVIEW_WHY)" "idle" "for that reason"
has "$(cat "$PQ_HOME/.out")" "still a draft and the agent has gone quiet - look at it" "warned"
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(cat "$PQ_HOME/.out")" "" "once"
eq "$(review_cell "$G")" "review lapsed" "the cell says so"
st_set "$G" PQ_REVIEW prompted
set_panes "$(printf 'w1:p1\t\t')"
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_REVIEW)" "lapsed" "an agent that exited with the draft open: lapsed"
eq "$(st "$G" PQ_REVIEW_WHY)" "noagent" "for that reason"

echo "== pq ls: the cells, the needs-you tally, and --json ==" >&2
set_panes "$(printf 'w1:p1\tclaude\tidle')"
reset_caches; cache_row "$REPO" tom/gated 42 OPEN draft master
for pair in "pending:review due" "posted:reviewed" "prompted:resolving" "lapsed:review lapsed"; do
  st_set "$G" PQ_REVIEW "${pair%%:*}"; st_set "$G" PQ_REVIEW_RESULT ok
  eq "$(agent_cell "$G" done)" "${pair#*:}" "cell for ${pair%%:*}"
done
st_set "$G" PQ_REVIEW posted; st_set "$G" PQ_REVIEW_RESULT failed
eq "$(agent_cell "$G" done)" "review failed" "cell for a failed review"
st_set "$G" PQ_REVIEW running; st_set "$G" PQ_REVIEW_AT "$(( $(date -u +%s) - 420 ))"
eq "$(agent_cell "$G" done)" "reviewing 7m" "cell for a running review"
st_set "$G" PQ_BLOCKED permission
eq "$(agent_cell "$G" done)" "permission" "a block word keeps precedence"
st_set "$G" PQ_BLOCKED ""
st_set "$G" PQ_REVIEW lapsed
LS=$(PQ_WIDTH=200 main ls 2>&1)
has "$LS" "review lapsed" "pq ls shows the lapsed gate"
has "$LS" "(1 needs you)" "and counts it as needing you"
J=$(main ls --json 2>/dev/null)
eq "$(jq -r '.[] | select(.task == "gated") | .review' <<<"$J")" "lapsed" "--json carries review"
st_set "$G" PQ_REVIEW posted; st_set "$G" PQ_REVIEW_RESULT ok
J=$(main ls --json 2>/dev/null)
eq "$(jq -r '.[] | select(.task == "gated") | .review_result' <<<"$J")" "ok" "and review_result"

echo "== STUCK: skipped, never reviewed, and a dependent reads it as stalled ==" >&2
reset_tasks; reset_caches; reset_logs; mode ok
S=$(mk_gated 020 stuck w3:p1)
pr_json "STUCK: the model is not where the plan says" OPEN true 1 50 5
set_panes "$(printf 'w3:p1\tclaude\tidle')"
# During the gate, a draft is the gate working - not a stalled chain.
eq "$(blocker_state "$REPO" tom/stuck master)" "waiting" "a pending gate's draft is not stalled"
review_task "$S" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$S" PQ_REVIEW)" "skipped" "a STUCK title is skipped"
eq "$(st "$S" PQ_REVIEW_WHY)" "stuck" "for that reason"
eq "$(claude_calls)" "0" "no reviewer"
has "$(cat "$PQ_HOME/.out")" "STUCK pull request - not reviewing it" "said"
eq "$(blocker_state "$REPO" tom/stuck master)" "stalled" "once the gate is settled, the draft is a stalled chain"
eq "$(agent_cell "$S" done)" "wrapping up" "skipped has no cell of its own"
pr_json "Do the thing" OPEN true 3 100 20

echo "== one big commit adds the restructure clause; several commits or few lines do not ==" >&2
reset_tasks; reset_caches; reset_logs; mode ok
B=$(mk_gated 030 big w4:p1)
pr_json "Big blob" OPEN true 1 900 300
set_panes "$(printf 'w4:p1\tclaude\tidle')"
review_task "$B" 0 >/dev/null 2>&1
eq "$(st "$B" PQ_REVIEW_SPLIT)" "1" "one commit over the line is flagged"
eq "$(st "$B" PQ_REVIEW_LINES)" "1200" "with its size"
wait_rc "$B"; review_task "$B" 0 >/dev/null 2>&1; review_task "$B" 0 >/dev/null 2>&1
P=$(prompt_text)
has "$P" "single commit of 1200 changed lines" "the prompt says so"
has "$P" "small logical commits" "and asks for a restructure"
has "$P" "push with --force-with-lease" "with the push that allows it"
for shape in "5 900 300" "1 15 5"; do
  reset_tasks; reset_caches; reset_logs
  # shellcheck disable=SC2086
  set -- $shape
  B2=$(mk_gated 031 small w4:p1)
  pr_json "Fine" OPEN true "$1" "$2" "$3"
  review_task "$B2" 0 >/dev/null 2>&1
  eq "$(st "$B2" PQ_REVIEW_SPLIT)" "" "$1 commit(s) of $(( $2 + $3 )) lines is not flagged"
  wait_rc "$B2"; review_task "$B2" 0 >/dev/null 2>&1; review_task "$B2" 0 >/dev/null 2>&1
  hasnt "$(prompt_text)" "single commit" "and its prompt has no restructure clause"
done
pr_json "Do the thing" OPEN true 3 100 20

echo "== a failing reviewer is retried, then falls back to self-review ==" >&2
reset_tasks; reset_caches; reset_logs; mode fail
F=$(mk_gated 040 flaky w5:p1)
set_panes "$(printf 'w5:p1\tclaude\tidle')"
review_task "$F" 0 >/dev/null 2>&1
wait_rc "$F"
review_task "$F" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$F" PQ_REVIEW)" "pending" "first failure: back to pending"
eq "$(st "$F" PQ_REVIEW_RESULT)" "failed" "as failed"
has "$(cat "$PQ_HOME/.out")" "review attempt 1 failed" "warned with the attempt number"
has "$(cat "$PQ_HOME/.out")" "retrying in 10m" "and the backoff"
review_task "$F" 0 >/dev/null 2>&1
eq "$(claude_calls)" "1" "RETRY_AT holds the second launch back"
FAKE_NOW=$(( FAKE_NOW + PQ_REVIEW_RETRY + 1 ))
review_task "$F" 0 >/dev/null 2>&1
wait_calls 2
eq "$(claude_calls)" "2" "then it launches again"
wait_rc "$F"
review_task "$F" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$F" PQ_REVIEW)" "posted" "second failure at MAX_TRIES=2: posted"
eq "$(st "$F" PQ_REVIEW_RESULT)" "failed" "as failed"
has "$(cat "$PQ_HOME/.out")" "review failed after 2 attempt(s)" "warned"
has "$(cat "$PQ_HOME/.out")" "asked to self-review instead" "with the fallback named"
eq "$(review_cell "$F")" "review failed" "the cell says review failed"
reset_logs
review_task "$F" 0 >/dev/null 2>&1
eq "$(st "$F" PQ_REVIEW)" "prompted" "the fallback prompt goes out"
P=$(prompt_text)
has "$P" "could not get an independent review of pull request #42" "it says the review did not happen"
has "$P" "the reviewer exited with an error" "and why"
has "$P" "git diff origin/master...HEAD" "and asks for a self-review against the base"
has "$P" "gh pr ready 42" "and still asks for the PR to be marked ready"
hasnt "$P" "inline review comments" "without pretending there are comments to read"

echo "== a malformed reply is a failed try too ==" >&2
reset_tasks; reset_caches; reset_logs; mode malformed
M=$(mk_gated 041 garbled w5:p1)
review_task "$M" 0 >/dev/null 2>&1; wait_rc "$M"; review_task "$M" 0 >/dev/null 2>&1
eq "$(st "$M" PQ_REVIEW)" "pending" "garbage out is a failed try"
eq "$(st "$M" PQ_REVIEW_RESULT)" "failed" "recorded as failed"

echo "== a probe that fails counts as a try with backoff ==" >&2
reset_tasks; reset_caches; reset_logs; mode ok
rm -f "$PRJSON"
Q=$(mk_gated 042 unprobed w5:p1)
review_task "$Q" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$Q" PQ_REVIEW)" "pending" "no probe, no launch"
eq "$(st "$Q" PQ_REVIEW_TRIES)" "1" "but the try is counted"
has "$(cat "$PQ_HOME/.out")" "could not read #42 with gh" "and named"
eq "$(claude_calls)" "0" "nothing launched blind"
pr_json "Do the thing" OPEN true 3 100 20

echo "== denied: gh refused and nothing landed - no retry, straight to the fallback ==" >&2
reset_tasks; reset_caches; reset_logs; mode denied; printf '0' > "$COMMENTS"
N=$(mk_gated 050 refused w6:p1)
set_panes "$(printf 'w6:p1\tclaude\tidle')"
review_task "$N" 0 >/dev/null 2>&1; wait_rc "$N"
review_task "$N" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$N" PQ_REVIEW)" "posted" "denied is not retried - it cannot succeed"
eq "$(st "$N" PQ_REVIEW_RESULT)" "denied" "recorded as denied"
has "$(cat "$PQ_HOME/.out")" "denied permission to post through gh - check PQ_REVIEW_TOOLS" "loud, and it names the knob"
wait_calls 1
eq "$(claude_calls)" "1" "one launch only"
reset_logs
review_task "$N" 0 >/dev/null 2>&1
has "$(prompt_text)" "the reviewer was denied permission to post" "the fallback prompt says why"

echo "== a gh refusal with comments landing anyway is a review that posted ==" >&2
reset_tasks; reset_caches; reset_logs; mode denied; printf '0' > "$COMMENTS"
N2=$(mk_gated 051 landed w6:p1)
review_task "$N2" 0 >/dev/null 2>&1; wait_rc "$N2"
printf '11' > "$COMMENTS"                 # eleven comments appeared while it ran
review_task "$N2" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$N2" PQ_REVIEW_RESULT)" "ok" "the count went up, so it posted"
has "$(cat "$PQ_HOME/.out")" "reached for things it was denied" "the denial is still warned about"
printf '0' > "$COMMENTS"

echo "== denials off the posting path never change the verdict ==" >&2
reset_tasks; reset_caches; reset_logs; mode otherdeny
N3=$(mk_gated 052 curious w6:p1)
review_task "$N3" 0 >/dev/null 2>&1; wait_rc "$N3"
review_task "$N3" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$N3" PQ_REVIEW_RESULT)" "ok" "a bundle denial is not a posting failure"
has "$(cat "$PQ_HOME/.out")" "1 denials, 0 of them gh" "but is reported"
mode ok

echo "== a stale pid is a failed try ==" >&2
reset_tasks; reset_caches; reset_logs; mode sleep
Z=$(mk_gated 060 vanished w7:p1)
set_panes "$(printf 'w7:p1\tclaude\tidle')"
review_task "$Z" 0 >/dev/null 2>&1
PID=$(st "$Z" PQ_REVIEW_PID)
kill -KILL -- "-$PID" 2>/dev/null; sleep 0.3
rm -f "$Z/review.rc"
review_task "$Z" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$Z" PQ_REVIEW)" "pending" "a reviewer that died without an exit code is a failed try"
has "$(cat "$PQ_HOME/.out")" "gone without leaving an exit code" "said"
mode ok

echo "== agent_blocked: the follow-up waits, says so once, and lands later ==" >&2
reset_tasks; reset_caches; reset_logs; mode ok
A=$(mk_gated 070 dialog w8:p1)
st_set "$A" PQ_REVIEW posted; st_set "$A" PQ_REVIEW_RESULT ok
set_panes "$(printf 'w8:p1\tclaude\tidle')"
printf 'agent_blocked' > "$STUBBIN/.prompt-fail"
review_task "$A" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$A" PQ_REVIEW)" "posted" "still posted"
eq "$(st "$A" PQ_REVIEW_WAIT)" "blocked" "waiting on the dialog"
has "$(cat "$PQ_HOME/.out")" "the review follow-up waits for you to answer it" "said"
review_task "$A" 0 >"$PQ_HOME/.out" 2>&1
eq "$(cat "$PQ_HOME/.out")" "" "once"
rm -f "$STUBBIN/.prompt-fail"
review_task "$A" 0 >/dev/null 2>&1
eq "$(st "$A" PQ_REVIEW)" "prompted" "delivered on the first tick the dialog is gone"
eq "$(st "$A" PQ_REVIEW_WAIT)" "" "and the wait is cleared"

echo "== posted with no agent lapses, once ==" >&2
reset_tasks; reset_caches; reset_logs
X=$(mk_gated 080 exited w9:p1)
st_set "$X" PQ_REVIEW posted; st_set "$X" PQ_REVIEW_RESULT ok
set_panes "$(printf 'w9:p1\t\t')"
review_task "$X" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$X" PQ_REVIEW)" "lapsed" "no agent to prompt"
eq "$(st "$X" PQ_REVIEW_WHY)" "noagent" "for that reason"
has "$(cat "$PQ_HOME/.out")" "its agent is gone - resolve the comments yourself" "warned"
review_task "$X" 0 >"$PQ_HOME/.out" 2>&1
eq "$(cat "$PQ_HOME/.out")" "" "once"
grep -q "^agent	prompt" "$HERDR_LOG" && bad "nothing is prompted into an empty pane" || ok

echo "== a PR that settles mid-review kills the reviewer, and reap is not held ==" >&2
reset_tasks; reset_caches; reset_logs; mode sleep
V=$(mk_gated 090 settled wA:p1)
set_panes "$(printf 'wA:p1\tclaude\tidle')"
review_task "$V" 0 >/dev/null 2>&1
PID=$(st "$V" PQ_REVIEW_PID)
review_alive "$PID" && ok || bad "the reviewer is running"
reset_caches; cache_row "$REPO" tom/settled 42 MERGED "" master
review_task "$V" 0 >"$PQ_HOME/.out" 2>&1
sleep 0.3
review_alive "$PID" && bad "a settled PR must kill its reviewer" || ok
eq "$(st "$V" PQ_REVIEW)" "skipped" "and skip the gate"
eq "$(st "$V" PQ_REVIEW_WHY)" "settled" "as settled"
has "$(cat "$PQ_HOME/.out")" "review skipped - #42 has settled" "said"
review_inflight "$V" && bad "nothing holds the slot any more" || ok
st_set "$V" PQ_WRAPUP_SINCE "$(ago 301)"
slot_held "$V" && bad "an idle agent past its grace releases" || ok
mode ok

echo "== pq rm kills a running reviewer ==" >&2
reset_tasks; reset_caches; reset_logs; mode sleep
K=$(mk_gated 095 removed wB:p1)
set_panes "$(printf 'wB:p1\tclaude\tidle')"
review_task "$K" 0 >/dev/null 2>&1
PID=$(st "$K" PQ_REVIEW_PID)
review_alive "$PID" && ok || bad "the reviewer is running"
task_link "$K"
( main rm removed <<<"y" ) >/dev/null 2>&1
sleep 0.3
review_alive "$PID" && bad "pq rm must kill the reviewer before deleting its directory" || ok
[ -d "$K" ] && bad "and the task is gone" || ok
[ -L "$PQ_HOME/tasks/$(basename "$K")" ] && bad "and so is its stable link" || ok
mode ok

echo "== PQ_REVIEW_MAX_TRIES=0 is the honest degraded mode ==" >&2
reset_tasks; reset_caches; reset_logs
H=$(mk_gated 096 degraded wC:p1)
set_panes "$(printf 'wC:p1\tclaude\tidle')"
( PQ_REVIEW_MAX_TRIES=0 review_task "$H" 0 ) >/dev/null 2>&1
eq "$(st "$H" PQ_REVIEW)" "posted" "no reviewer, straight to posted"
eq "$(st "$H" PQ_REVIEW_RESULT)" "failed" "as a failure the fallback prompt explains"
eq "$(claude_calls)" "0" "nothing launched"

echo "== through tick_body: the whole gate, and the summary counts it ==" >&2
reset_tasks; reset_caches; reset_logs; mode ok
W=$(mk_gated 100 whole wD:p1)
set_panes "$(printf 'wD:p1\tclaude\tidle')"
tick 3 0
eq "$(st "$W" PQ_REVIEW)" "running" "tick 1 launches"
has "$PQ_SUMMARY" ", 1 reviewing" "and the summary counts it"
has "$PQ_SUMMARY" "0 running + 1 wrapping up (cap 3)" "while the slot stays spent"
wait_rc "$W"
reset_caches; cache_row "$REPO" tom/whole 42 OPEN draft master
tick 3 0
eq "$(st "$W" PQ_REVIEW)" "posted" "tick 2 collects"
reset_caches; cache_row "$REPO" tom/whole 42 OPEN draft master
tick 3 0
eq "$(st "$W" PQ_REVIEW)" "prompted" "tick 3 delivers"
hasnt "$PQ_SUMMARY" "reviewing" "prompted is no longer counted as reviewing"
reset_caches; cache_row "$REPO" tom/whole 42 OPEN "" master
tick 3 0
eq "$(st "$W" PQ_REVIEW)" "ready" "tick 4 sees the draft marked ready"

echo "== through tick_body --dry-run: would-lines only ==" >&2
reset_tasks; reset_caches; reset_logs
Y=$(mk_gated 110 dry wE:p1)
set_panes "$(printf 'wE:p1\tclaude\tidle')"
tick 3 1
has "$OUT" "would probe #42 and launch a review of dry" "the would-line"
eq "$(st "$Y" PQ_REVIEW)" "pending" "nothing changed"
eq "$(claude_calls)" "0" "nothing launched"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
