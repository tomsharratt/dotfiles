#!/usr/bin/env bash
# test/pq-small.sh - the smaller bugs, each on its own:
#
#   pq rm, and the mutating forms of pq after, acting on a task a tick had
#     moved since they found it
#   name_plan cutting Haiku's JSON at the last `{`, not the first
#   the tick lock: a missing pid read as stale, and a reused pid read as alive
#   a dispatch that can never succeed, retried every tick without end
#   the namer reading the usage limit as an unusable reply
#   a pane id herdr has since given to another workspace, knocked on as ours
#
# SC2034: the knobs and pane index set here are read by the pq sourced below.
# SC2015: `ok` never fails, so `[ ... ] && ok || bad` is an if/else.
# shellcheck disable=SC2034,SC2015
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PQ_HOME=$(mktemp -d)
export PQ_HOME

STUBBIN=$(mktemp -d)
PANES_JSON="$STUBBIN/.panes.json"
HERDR_LOG="$STUBBIN/.herdr-calls"
REPLY="$STUBBIN/.reply"
printf '{"result":{"snapshot":{"panes":[]}}}' > "$PANES_JSON"
: > "$HERDR_LOG"
# `claude` answers with whatever $REPLY holds, however it was asked.
cat > "$STUBBIN/claude" <<EOF
#!/bin/sh
cat >/dev/null
cat "$REPLY"
EOF
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/gh"
cat > "$STUBBIN/herdr" <<EOF
#!/bin/sh
{ for a in "\$@"; do printf '%s\t' "\$a"; done; printf '\n'; } >> "$HERDR_LOG"
key=\$(printf '%s' "\$3" | tr ':' '_')
case "\$1 \$2" in
  "api snapshot") cat "$PANES_JSON"; exit 0 ;;
  "pane read")    [ -f "$STUBBIN/pane.\$key" ] && cat "$STUBBIN/pane.\$key"; exit 0 ;;
  "agent prompt") printf '{"id":"cli:agent:prompt","result":{"submitted":true}}\n'; exit 0 ;;
esac
exit 1
EOF
WT_LOG="$STUBBIN/.wt-calls"
: > "$WT_LOG"
cat > "$STUBBIN/wt-stub" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$WT_LOG"
echo "wt: boom" >&2
exit 1
EOF
chmod +x "$STUBBIN/claude" "$STUBBIN/gh" "$STUBBIN/herdr" "$STUBBIN/wt-stub"
export PATH="$STUBBIN:$PATH"
export PQ_WT="$STUBBIN/wt-stub"

# shellcheck source=/dev/null
source "$HERE/../.local/bin/pq"
# shellcheck source=test/lib.sh
source "$HERE/lib.sh"
gum_stub "$STUBBIN" "$PQ_HOME/.gum"
# pq rm asks through gum, at a terminal: the terminal is stood in for.
# shellcheck disable=SC2329  # called by pq rm, not here
at_terminal() { return 0; }

# shellcheck disable=SC2329  # called by the pq sourced above
pr_load_all() { :; }

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }
has() { case "$1" in *"$2"*) ok ;; *) bad "$3 (got '$1')" ;; esac; }
hasnt() { case "$1" in *"$2"*) bad "$3 (got '$1')" ;; *) ok ;; esac; }

SLEEPER=""
cleanup() { [ -n "$SLEEPER" ] && kill "$SLEEPER" 2>/dev/null; rm -rf "$PQ_HOME" "$STUBBIN" "${REPO:-}"; }
trap cleanup EXIT

REPO=$(mktemp -d)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$REPO/.git/refs/remotes/origin"
git -C "$REPO" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master

unset HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID
LOCK_WAIT=2

reset_tasks() {
  rm -rf "$PQ_HOME/new" "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done" "$PQ_HOME/archive" "$PQ_HOME/.tick.lock"
  mkdir -p "$PQ_HOME/new" "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done" "$PQ_HOME/archive"
}
mk_task() {                             # state prio slug -> task_dir
  local d
  d="$PQ_HOME/$1/$(printf '%014d' $(( 20260101000000 + 10#$2 )))-$3"
  mkdir -p "$d"
  printf -- '---\nrepo:     %s\nbranch:   tom/%s\nmodel:    sonnet\neffort:   xhigh\nintent:   t\nadded:    2026-01-01T00:00:00Z\n---\n\nplan\n' \
    "$REPO" "$3" > "$d/plan.md"
  printf '%s' "$d"
}
set_panes() {                           # "pane<TAB>agent<TAB>status<TAB>cwd" lines
  jq -Rs 'split("\n") | map(select(length > 0) | split("\t")
            | { pane_id: .[0],
                agent:        (if (.[1] // "") == "" then null else .[1] end),
                agent_status: (if (.[2] // "") == "" then null else .[2] end),
                cwd: (.[3] // null), foreground_cwd: (.[3] // null) })
          | { result: { snapshot: { panes: . } } }' <<<"$1" > "$PANES_JSON"
  pidx_load
}

echo "== pq rm: a task claimed while you were answering is not removed ==" >&2
reset_tasks
Q=$(mk_task queue 10 claimed)
# The answer goes down a fifo held open read-write, so pq rm finds the task and
# asks at once, and only then does the tick move it and the answer arrive.
FIFO="$STUBBIN/.answer"; mkfifo "$FIFO"; exec 3<>"$FIFO"
# A gum that logs its question and waits for the answer on the fifo.
cat > "$STUBBIN/gum" <<GUMEOF
#!/bin/sh
printf 'asked: %s\\n' "\$*" >> "$STUBBIN/.rm.out"
read -r ans <&3
[ "\$ans" = y ]
GUMEOF
chmod +x "$STUBBIN/gum"
( main rm claimed <&3 > "$STUBBIN/.rm.out" 2>&1 ) &
RMPID=$!
for _ in $(seq 1 50); do grep -q 'asked: confirm' "$STUBBIN/.rm.out" 2>/dev/null && break; sleep 0.1; done
has "$(cat "$STUBBIN/.rm.out")" 'remove task "claimed" (queue)?' "the question is about the queued task"
mv "$Q" "$PQ_HOME/running/"             # ...and a tick claims it
echo y >&3
wait "$RMPID"; rmrc=$?; exec 3>&-
R="$PQ_HOME/running/$(basename "$Q")"
[ -d "$R" ] && ok || bad "the claimed task must survive in running/"
hasnt "$(cat "$STUBBIN/.rm.out")" "removed claimed" "and pq rm must not say it removed it"
has "$(cat "$STUBBIN/.rm.out")" "moved to running/ while you were answering" "it says what happened"
eq "$rmrc" "1" "and fails"
[ -e "$PQ_HOME/.tick.lock" ] && bad "the lock is released" || ok

echo "== ...and one that stayed put is removed, under the lock ==" >&2
reset_tasks
Q=$(mk_task queue 11 stayed)
gum_stub "$STUBBIN" "$PQ_HOME/.gum"
gum_answer ""
out=$( (main rm stayed) 2>&1)
[ -d "$Q" ] && bad "a task nothing moved is removed" || ok
has "$out" "removed stayed" "and says so"
[ -e "$PQ_HOME/.tick.lock" ] && bad "the lock is released" || ok

echo "== pq after waits for a tick that is running, rather than race it ==" >&2
reset_tasks
Q=$(mk_task queue 12 blocked)
sleep 30 & SLEEPER=$!
ln -s "$(lock_owner "$SLEEPER")" "$PQ_HOME/.tick.lock"
out=$( (main after blocked tom/some-branch) 2>&1); rc=$?
eq "$rc" "1" "a tick holding the lock past LOCK_WAIT stops pq after"
has "$out" "try again once it is done" "saying so"
[ -f "$Q/after" ] && bad "and nothing is written" || ok
kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null; SLEEPER=""
out=$( (main after blocked tom/some-branch) 2>&1); rc=$?
eq "$rc" "0" "once the tick is gone (its lock stale), it goes through"
[ -f "$Q/after" ] && ok || bad "and the blocker is written"
[ -e "$PQ_HOME/.tick.lock" ] && bad "the lock is released" || ok

echo "== name_plan takes Haiku's JSON from its first brace, not its last ==" >&2
PLANF="$STUBBIN/plan.md"; printf '# A plan\n\nAdd placeholders.\n' > "$PLANF"
printf '%s\n' 'Here it is: {"branch":"tom/template-placeholders","intent":"Adds {placeholder} support to templates.","security":false} - done.' > "$REPLY"
out=$(name_plan "$PLANF")
eq "$(head -1 <<<"$out" | cut -f1)" "tom/template-placeholders" "a brace inside the intent no longer breaks naming"
eq "$(head -1 <<<"$out" | cut -f2)" "Adds {placeholder} support to templates." "and the intent keeps it"
printf '%s\n' '```json' '{"branch":"tom/fenced","intent":"i","security":false}' '```' > "$REPLY"
eq "$(name_plan "$PLANF" | head -1 | cut -f1)" "tom/fenced" "a fenced reply still reads"

echo "== the namer knows the usage limit when it sees it ==" >&2
printf "You've hit your individual spend limit · visit claude.ai/admin-settings/usage to raise it\n" > "$REPLY"
out=$(name_plan "$PLANF" 2>/dev/null); rc=$?
eq "$rc" "3" "the namer's limit is its own answer"
eq "$out" "You've hit your individual spend limit · visit claude.ai/admin-settings/usage to raise it" "and it hands back the limit's own words"
reset_tasks
out=$(add_as "$PLANF" "" --repo "$REPO" 2>&1); rc=$?
eq "$rc" "1" "the task is not queued"
has "$out" "naming hit the usage limit (You've hit your individual spend limit" "naming says so, in the limit's own words"
has "$out" "it is named once the limit lifts" "and when it can work"
hasnt "$out" "Haiku gave no usable branch" "not that the reply was unusable"
eq "$(st "$(queue_ordered new | tail -1)" PQ_NAME_FAILS)" "" "nor is it counted as a failed try"
# What the real one sends under --output-format json: a clean, successful
# envelope whose whole result is the limit's line - the shape that once had a
# reviewer read as having posted.
jq -nc '{type: "result", subtype: "success", is_error: false, total_cost_usd: 0, session_id: "s-limit",
         result: "You'"'"'ve hit your org'"'"'s monthly spend limit"}' > "$REPLY"
out=$(name_plan "$PLANF" 2>/dev/null); rc=$?
eq "$rc" "3" "the limit inside the result envelope is the limit too"
eq "$out" "You've hit your org's monthly spend limit" "in its own words"
reset_tasks
out=$(add_as "$PLANF" "" --repo "$REPO" 2>&1); rc=$?
eq "$rc" "1" "and naming waits on it"
has "$out" "naming hit the usage limit (You've hit your org's monthly spend limit)" "saying so"
# The namer's own answer is one line too, and a plan about running out of
# credits puts the limit's very words in it.
printf '%s\n' '{"branch":"tom/usage-banner","intent":"Warn members before they run out of usage credits or hit your plan limit.","security":false}' > "$REPLY"
out=$(name_plan "$PLANF" 2>/dev/null); rc=$?
eq "$rc" "0" "a one-line JSON answer that mentions the limit is an answer"
eq "$(head -1 <<<"$out" | cut -f1)" "tom/usage-banner" "and names the plan"

echo "== the tick lock: atomic with its owner, and a reused pid is not its owner ==" >&2
reset_tasks
take_lock && ok || bad "a free lock is taken"
[ -L "$PQ_HOME/.tick.lock" ] && ok || bad "as a symlink naming its owner"
eq "$(lock_pid)" "$$" "which is this process"
( take_lock ) && bad "a live owner's lock is not taken" || ok
release_lock
[ -e "$PQ_HOME/.tick.lock" ] && bad "and released" || ok
# A pid alive now, but not the process that took the lock: after a reboot the
# pid on file belongs to someone else, and it used to block every tick.
ln -s "$$ Thu Jan  1 00:00:00 1970" "$PQ_HOME/.tick.lock"
out=$(take_lock 2>&1 && printf TOOK); rc=$?
has "$out" "TOOK" "a lock whose pid now names another process is stale"
has "$out" "cleared a stale tick lock" "and said"
release_lock; rm -f "$PQ_HOME/.tick.lock"
# The old directory form, with no pid in it yet: somebody is taking it right now.
mkdir "$PQ_HOME/.tick.lock"
( take_lock ) && bad "a lock being taken this second is not stale" || ok
rmdir "$PQ_HOME/.tick.lock"
mkdir "$PQ_HOME/.tick.lock"; printf '999999' > "$PQ_HOME/.tick.lock/pid"
( take_lock >/dev/null 2>&1 && printf TOOK ) | grep -q TOOK && ok || bad "an old-form lock with a dead pid is stale"
rm -rf "$PQ_HOME/.tick.lock"

echo "== a dispatch that keeps failing is given up on, and holds no slot ==" >&2
reset_tasks; : > "$WT_LOG"
set_panes ""
D=$(mk_task running 20 broken)
st_set "$D" PQ_CLAIMED 2026-01-01T00:00:00Z
PR_CACHE="$PQ_HOME/.test.pr"; PR_ANS="$PQ_HOME/.test.ans"
for i in 1 2 3; do : > "$PR_CACHE"; : > "$PR_ANS"; tick_body 0 0 >"$STUBBIN/.tick.$i" 2>&1; done
eq "$(grep -c 'new' "$WT_LOG")" "3" "tried three times"
eq "$(st "$D" PQ_DISPATCH_FAILS)" "3" "counted"
eq "$(st "$D" PQ_DISPATCH_GAVEUP)" "1" "and given up on"
has "$(cat "$STUBBIN/.tick.3")" "dispatch failed 3 times in a row - leaving it for you" "said on the third"
: > "$PR_CACHE"; : > "$PR_ANS"; tick_body 0 0 >"$STUBBIN/.tick.4" 2>&1
eq "$(grep -c 'new' "$WT_LOG")" "3" "and never tried again"
hasnt "$(cat "$STUBBIN/.tick.4")" "broken" "nor mentioned"
eq "$(running_count)" "0" "it holds no slot"
eq "$(agent_cell "$D" running)" "failed" "pq ls says so"
has "$(PQ_WIDTH=200 main ls 2>&1)" "(1 needs you)" "and counts it"

echo "== a prompt waiting on a dialog is not a failure ==" >&2
reset_tasks
B=$(mk_task running 21 dialog)
# shellcheck disable=SC2329  # called by dispatch_try
dispatch_task() { return 2; }
dispatch_try "$B"; dispatch_try "$B"; dispatch_try "$B"; dispatch_try "$B"
eq "$(st "$B" PQ_DISPATCH_FAILS)" "" "four waits count for nothing"
dispatch_gaveup "$B" && bad "and it is never given up on" || ok
unset -f dispatch_task
# shellcheck source=/dev/null
source "$HERE/../.local/bin/pq"; pr_load_all() { :; }; LOCK_WAIT=2

echo "== a pane id reissued to another workspace is not the task's pane ==" >&2
reset_tasks
WT_A=$(mktemp -d); WT_B=$(mktemp -d)
T=$(mk_task running 30 mine)
st_set "$T" PQ_PANE w5:p1; st_set "$T" PQ_WORKTREE "$WT_A"; st_set "$T" PQ_LAUNCHED 2026-01-01T00:00:00Z
set_panes "$(printf 'w5:p1\tclaude\tidle\t%s' "$WT_B")"
eq "$(task_pane "$T")" "" "a pane sitting in another worktree is not this task's"
eq "$(pane_state "$(task_pane "$T")")" "missing" "so the task's own pane reads as missing"
mkdir -p "$PQ_HOME/tasks"; task_link "$T"
printf '{"event":"error","at":1,"error":"server_error","message":"x"}' > "$(task_home "$T")/agent.json"
: > "$HERDR_LOG"                        # set_panes' own snapshot read is not the question
check_quiet "$T" >/dev/null 2>&1
grep -q "w5:p1" "$HERDR_LOG" && bad "and nothing reads or knocks on somebody else's pane" || ok
set_panes "$(printf 'w5:p1\tclaude\tidle\t%s/app' "$WT_A")"
eq "$(task_pane "$T")" "w5:p1" "a pane inside the task's own worktree is its pane"
set_panes "$(printf 'w5:p1\tclaude\tidle')"
eq "$(task_pane "$T")" "w5:p1" "and one herdr gives no cwd for is taken as it stands"
rm -rf "$WT_A" "$WT_B"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
