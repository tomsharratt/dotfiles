#!/usr/bin/env bash
# test/pq-base.sh - the per-task `base:` header: what counts as merged when a
# task is not aimed at its repo's default branch, and where its worktree forks
# from.
#
# Same shape as test/pq-after.sh and test/pq-reap.sh - sources pq so the
# predicates are callable directly against a hand-primed PR cache, with no live
# PR and no `gh` in the loop.
#
# The rows that matter here are the ones that used to fail SILENTLY: a task
# whose PR merged into an integration branch read as "still in review" forever,
# its worktree was never torn down, and `pq ls` printed "merged" the whole time.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PQ_HOME=$(mktemp -d)
export PQ_HOME

STUBBIN=$(mktemp -d)
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/claude"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/gh"
cat > "$STUBBIN/herdr" <<'EOF'
#!/bin/sh
case "$*" in
  "api snapshot") echo '{"result":{"snapshot":{"panes":[]}}}'; exit 0 ;;
esac
exit 1
EOF
chmod +x "$STUBBIN/claude" "$STUBBIN/gh" "$STUBBIN/herdr"
export PATH="$STUBBIN:$PATH"

# A `wt` stub, so the fork-point assertions can read back exactly what pq asked
# `wt new` for without a real worktree, database or Herdr pane in sight.
WT_LOG="$STUBBIN/.wt-calls"
: > "$WT_LOG"
cat > "$STUBBIN/wt-stub" <<EOF
#!/bin/sh
{ printf '%s\t' "\$PWD"; for a in "\$@"; do printf '%s\t' "\$a"; done; printf '\n'; } >> "$WT_LOG"
echo '{"root_pane_id":"w1:p1","path":"/tmp/none","workspace_id":"w1","url":"","port":""}'
exit "\${WT_STUB_RC:-0}"
EOF
chmod +x "$STUBBIN/wt-stub"
export PQ_WT="$STUBBIN/wt-stub"

# shellcheck source=/dev/null
source "$HERE/../.local/bin/pq"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }

cleanup() { rm -rf "$PQ_HOME" "$STUBBIN" "${REPO:-}" "${REPO2:-}"; }
trap cleanup EXIT

# ── a real repo with a real integration branch ──────────────────────────────
# The ancestry arm of `merged_into` reads actual git history, so this fixture has
# to be genuine - a faked ref is not enough. The shape mirrors the case that
# provoked all of this:
#
#   master        A ── B                 B is part 3's merge commit
#                       \
#   live-events          C               cut from B, then part 6 landed as C
#
# So B (merged into master) IS present in live-events, while C (merged into
# live-events) is NOT present in master. Those two facts are the whole test.
REPO=$(mktemp -d)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m A
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m B
OID_B=$(git -C "$REPO" rev-parse HEAD)
mkdir -p "$REPO/.git/refs/remotes/origin"
git -C "$REPO" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
git -C "$REPO" branch live-events master
git -C "$REPO" -c user.email=test@test -c user.name=test \
  commit-tree -p "$OID_B" -m C "$(git -C "$REPO" rev-parse HEAD^{tree})" > "$PQ_HOME/.oidc"
OID_C=$(cat "$PQ_HOME/.oidc")
git -C "$REPO" update-ref refs/heads/live-events "$OID_C"
git -C "$REPO" update-ref refs/remotes/origin/live-events "$OID_C"

# A second repo, so the cross-repo blocker rule has somewhere to point.
REPO2=$(mktemp -d)
git init -q -b trunk "$REPO2"
git -C "$REPO2" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$REPO2/.git/refs/remotes/origin"
git -C "$REPO2" update-ref refs/remotes/origin/trunk refs/heads/trunk
git -C "$REPO2" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk

reset_caches() { PR_CACHE="$PQ_HOME/.test.pr"; PR_ANS="$PQ_HOME/.test.ans"; : > "$PR_CACHE"; : > "$PR_ANS"; }
# Seven fields now. The six-field form is kept as its own helper rather than
# defaulted, because a row with no merge oid is a real case worth naming: every
# PR row pq cached before this feature existed looks exactly like that.
cache_row()    { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$PR_CACHE"; }  # repo branch num state draft base oid
cache_row_v1() { printf '%s\t%s\t%s\t%s\t%s\t%s\n'     "$@" >> "$PR_CACHE"; }  # ...without the oid
ans_row()      { printf '%s\t%s\n' "$@" >> "$PR_ANS"; }

reset_tasks() {
  rm -rf "$PQ_HOME/queue" "$PQ_HOME/hold" "$PQ_HOME/running" "$PQ_HOME/done"
  mkdir -p "$PQ_HOME/queue" "$PQ_HOME/hold" "$PQ_HOME/running" "$PQ_HOME/done"
}
reset_tasks

# A task built by hand. $base is written as a `base:` header only when non-empty,
# exactly as cmd_add does it - a task with no base must produce a plan.md that is
# byte-for-byte what it would have been before this header existed.
mk_task() {                             # state prio slug repo branch base -> task_dir
  local st=$1 prio=$2 slug=$3 repo=$4 branch=$5 base=${6:-}
  local dir="$PQ_HOME/$st/$(printf '%014d' $(( 20260101000000 + 10#$prio )))-$slug"
  mkdir -p "$dir"
  {
    printf -- '---\n'
    printf 'repo:     %s\n' "$repo"
    printf 'branch:   %s\n' "$branch"
    [ -n "$base" ] && printf 'base:     %s\n' "$base"
    printf 'model:    sonnet\n'
    printf 'effort:   xhigh\n'
    printf 'intent:   test fixture\n'
    printf 'added:    2026-01-01T00:00:00Z\n'
    printf -- '---\n\nplan body\n'
  } > "$dir/plan.md"
  printf '%s' "$dir"
}

echo "== task_base ==" >&2
reset_tasks
d=$(mk_task queue 10 no-base "$REPO" tom/a)
eq "$(task_base "$d")" "master" "no base: header falls back to the repo default"
repo_base_reset
d=$(mk_task queue 11 with-base "$REPO" tom/b live-events)
eq "$(task_base "$d")" "live-events" "base: header wins over the repo default"
repo_base_reset
d=$(mk_task queue 12 nobase-repo "$REPO2/nope" tom/c)
eq "$(task_base "$d")" "" "unresolvable repo default reads empty, not a guess"
repo_base_reset

echo "== merged_into: the cheap arm (exact merge target) ==" >&2
reset_caches
cache_row "$REPO" tom/exact 1 MERGED "" live-events "$OID_C"
merged_into "$REPO" tom/exact live-events && ok \
  || bad "merged into live-events should be present in live-events"

# The bug, stated as a test: this is what returned false before, froze the
# queue, and left the worktree standing.
reset_caches
cache_row "$REPO" tom/feature 2 MERGED "" live-events "$OID_C"
{ pr_merged_into "$REPO" tom/feature master \
    && bad "pr_merged_into should still be exact - that is what makes it pure"; } || ok
merged_into "$REPO" tom/feature live-events && ok \
  || bad "a PR merged into the integration branch must count for a task based on it"

echo "== merged_into: the ancestry arm ==" >&2
# Part 3 merged into MASTER; part 4 is based on live-events, which was cut from
# master AFTER that merge. Exact matching calls this unmet and refreezes the
# queue inside the workflow the feature exists to support.
reset_caches
cache_row "$REPO" tom/part3 3 MERGED "" master "$OID_B"
{ pr_merged_into "$REPO" tom/part3 live-events \
    && bad "exact match cannot see this - the arms must be distinct"; } || ok
merged_into "$REPO" tom/part3 live-events && ok \
  || bad "a trunk merge contained in the integration branch must count"

# ...and the direction that must NOT be waved through: work that only exists on
# the integration branch is not in master, and a task based on master must wait.
reset_caches
cache_row "$REPO" tom/part6 4 MERGED "" live-events "$OID_C"
{ merged_into "$REPO" tom/part6 master \
    && bad "work only on live-events must NOT count as present in master"; } || ok

echo "== merged_into: fails closed ==" >&2
reset_caches
cache_row_v1 "$REPO" tom/legacy 5 MERGED "" live-events
{ merged_into "$REPO" tom/legacy master \
    && bad "a cached row with no merge oid must fail closed, not guess"; } || ok
reset_caches
cache_row "$REPO" tom/unknown-oid 6 MERGED "" live-events 0000000000000000000000000000000000000000
{ merged_into "$REPO" tom/unknown-oid master \
    && bad "an oid this repo does not have must fail closed"; } || ok
reset_caches
cache_row "$REPO" tom/nobase 7 MERGED "" live-events "$OID_C"
{ merged_into "$REPO" tom/nobase "" \
    && bad "an empty base must never read as met"; } || ok

echo "== base_fetch stays off unless the tick turns it on ==" >&2
# Proven by its own memo file: a no-op leaves nothing behind, and nothing here
# is allowed to reach the network.
rm -f "$PQ_HOME/.basefetch.$$"
base_fetch "$REPO" live-events
[ -f "$PQ_HOME/.basefetch.$$" ] && bad "base_fetch must be a no-op with PQ_FETCH_BASES unset" || ok
PQ_FETCH_BASES=1 base_fetch "$REPO" live-events
[ -f "$PQ_HOME/.basefetch.$$" ] && ok || bad "base_fetch should record its attempt when enabled"
PQ_FETCH_BASES=1 base_fetch "$REPO" live-events
eq "$(wc -l < "$PQ_HOME/.basefetch.$$" | tr -d ' ')" "1" "base_fetch memoises per (repo, base)"
rm -f "$PQ_HOME/.basefetch.$$"

echo "== blocker_state / after_state judge against the DEPENDENT's base ==" >&2
reset_tasks; reset_caches
# The blocker landed on live-events. Its owning task is done.
cache_row "$REPO" tom/blocker 8 MERGED "" live-events "$OID_C"
mk_task done 20 blocker-owner "$REPO" tom/blocker live-events >/dev/null

# A dependent based on live-events: met.
dep=$(mk_task queue 21 dep-on-feature "$REPO" tom/dep1 live-events)
printf 'blocker-owner\t%s\ttom/blocker\n' "$REPO" > "$dep/after"
eq "$(blocker_state "$REPO" tom/blocker "$(task_base "$dep")")" "met" \
  "blocker merged into the base the dependent forks from"
eq "$(after_state "$dep")" "met$(printf '\t')" "after_state: met via the dependent's base"
repo_base_reset

# The same blocker, same PR, a dependent based on master: still waiting, and
# correctly so - the work genuinely is not in master.
dep2=$(mk_task queue 22 dep-on-master "$REPO" tom/dep2)
printf 'blocker-owner\t%s\ttom/blocker\n' "$REPO" > "$dep2/after"
eq "$(blocker_state "$REPO" tom/blocker "$(task_base "$dep2")")" "waiting" \
  "the same merge does not satisfy a dependent aimed at master"
case "$(after_state "$dep2")" in
  waiting*) ok ;;
  *) bad "after_state should still be waiting for a master-based dependent (got '$(after_state "$dep2")')" ;;
esac
repo_base_reset

echo "== a cross-repo blocker keeps its OWN repo's default branch ==" >&2
# "Will my base contain it" is meaningless across two repositories with no
# shared history, so a blocker in another repo is judged against that repo's
# trunk - never the dependent's integration branch, which does not exist there.
reset_tasks; reset_caches
cache_row "$REPO2" ios/thing 9 MERGED "" trunk ""
mk_task done 30 ios-owner "$REPO2" ios/thing >/dev/null
dep3=$(mk_task queue 31 dep-cross-repo "$REPO" tom/dep3 live-events)
printf 'ios-owner\t%s\tios/thing\n' "$REPO2" > "$dep3/after"
eq "$(blocker_base "$dep3" "$REPO2")" "trunk" "cross-repo blocker judged against its own default"
eq "$(blocker_base "$dep3" "$REPO")"  "live-events" "same-repo blocker judged against the dependent's base"
eq "$(after_state "$dep3")" "met$(printf '\t')" "a cross-repo blocker on its own trunk is met"
repo_base_reset

echo "== reap_task honours the task's own base ==" >&2
reset_tasks; reset_caches
SOCK="$PQ_HOME/.sock"; python3 -c "
import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind('$SOCK')
" 2>/dev/null || SOCK=""
mk_reaped() {                           # prio slug branch base -> dir (with a live worktree)
  local dir; dir=$(mk_task done "$1" "$2" "$REPO" "$3" "${4:-}")
  local wt="$PQ_HOME/wt-$2"; mkdir -p "$wt"
  st_set "$dir" PQ_WORKTREE "$wt"
  printf '%s' "$dir"
}
: > "$WT_LOG"
# Aimed at live-events, landed on live-events -> tear it down.
r1=$(mk_reaped 40 reap-feature tom/reap1 live-events)
cache_row "$REPO" tom/reap1 11 MERGED "" live-events "$OID_C"
PIDX_OK=1 reap_task "$r1" 0 >/dev/null 2>&1
eq "$([ -n "$(st "$r1" PQ_MERGED)" ] && printf yes || printf no)" "yes" \
  "reap: a PR merged into the task's own base counts as merged"
grep -q "rm" "$WT_LOG" && ok || bad "reap: should have asked wt to remove the worktree"
repo_base_reset

# Aimed at master, landed on live-events -> left alone. This is the same PR
# state as above; only the header differs, which is the point.
: > "$WT_LOG"
reset_caches
r2=$(mk_reaped 41 reap-master tom/reap2)
cache_row "$REPO" tom/reap2 12 MERGED "" live-events "$OID_C"
PIDX_OK=1 reap_task "$r2" 0 >/dev/null 2>&1
eq "$([ -n "$(st "$r2" PQ_MERGED)" ] && printf yes || printf no)" "no" \
  "reap: a merge outside the task's base must not count"
eq "$([ -s "$WT_LOG" ] && printf called || printf quiet)" "quiet" \
  "reap: must not touch a worktree whose work is not in its base"
repo_base_reset

echo "== dispatch_prompt names the base only when there is one ==" >&2
p_plain=$(dispatch_prompt /tmp/plan.md)
case "$p_plain" in
  *--base*) bad "a task with no base must get the prompt it always got" ;;
  *) ok ;;
esac
p_based=$(dispatch_prompt /tmp/plan.md live-events)
case "$p_based" in
  *"--base live-events"*) ok ;;
  *) bad "a based task's prompt must tell the agent where the PR goes" ;;
esac
# The prompt is wrapped in single quotes when it is sent to the pane, so one
# appearing in it would break the command line - dispatch_task refuses to send
# such a prompt, which would silently strand every based task.
case "$p_based" in
  *"'"*) bad "the base clause must not introduce a single quote" ;;
  *) ok ;;
esac

echo "== dispatch_task forks from the declared base ==" >&2
reset_tasks; : > "$WT_LOG"
t=$(mk_task running 50 disp-based "$REPO" tom/disp1 live-events)
dispatch_task "$t" >/dev/null 2>&1
grep -q "	--base	origin/live-events	" "$WT_LOG" \
  && ok || bad "wt new should have been told to fork from origin/live-events"
: > "$WT_LOG"
t2=$(mk_task running 51 disp-plain "$REPO" tom/disp2)
dispatch_task "$t2" >/dev/null 2>&1
grep -q -- "--base" "$WT_LOG" \
  && bad "a task with no base must not pass --base at all" || ok
# A base that does not exist must stop the dispatch, not quietly fork the trunk.
: > "$WT_LOG"
t3=$(mk_task running 52 disp-bogus "$REPO" tom/disp3 no-such-branch)
dispatch_task "$t3" >/dev/null 2>&1 && bad "dispatch should fail on an unresolvable base" || ok
eq "$([ -s "$WT_LOG" ] && printf called || printf quiet)" "quiet" \
  "an unresolvable base must never reach wt new"

echo "== a base that no longer resolves must not burn a slot ==" >&2
# The failure this guards against is the one pq exists to prevent: fill claims a
# task into running/ BEFORE dispatch is attempted, so a dispatch that refuses
# leaves it there with no PR and no PQ_LAUNCHED. active_slots counts running/
# unconditionally, and the next tick sees an "interrupted dispatch" and retries -
# forever, holding one of three slots all night for a task that can never start.
#
# And this is the NORMAL end of the workflow the header exists for: you merge the
# integration branch into the trunk and delete it. Every task still queued behind
# it has a base that is gone.
reset_tasks; reset_caches; : > "$WT_LOG"
mk_task queue 60 base-is-gone "$REPO" tom/gone no-such-integration-branch >/dev/null
# Filesystem, never state_of: that reads the path STRING it is handed, so it would
# happily report "queue" for a directory fill had already moved to running/.
where() { ls -d "$PQ_HOME"/*/*-"$1" 2>/dev/null | head -1; }
PQ_SUMMARY="" tick_body 3 0 >/dev/null 2>&1
eq "$(basename "$(dirname "$(where base-is-gone)")")" "queue" \
  "a task whose base is gone stays in queue/, unclaimed"
eq "$([ -s "$WT_LOG" ] && printf called || printf quiet)" "quiet" \
  "wt must never be reached for a task that cannot be forked"
eq "$(ls -d "$PQ_HOME/running"/*/ 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "it must not be holding a slot"
# Once-only: the warning fires on the transition, not on every tick all night.
second=$(PQ_SUMMARY="" tick_body 3 0 2>&1 >/dev/null | grep -c "no-such-integration-branch")
eq "$second" "0" "the base warning is once-only, like every other block pq stamps"

echo "== ...and it recovers the moment the base comes back ==" >&2
eq "$(st "$(where base-is-gone)" PQ_BASE_GONE)" "1" "the block is stamped while the base is missing"
git -C "$REPO" update-ref refs/remotes/origin/no-such-integration-branch "$OID_C"
PQ_SUMMARY="" tick_body 3 0 >/dev/null 2>&1
eq "$(basename "$(dirname "$(where base-is-gone)")")" "running" "a recovered base lets the task dispatch"
eq "$(st "$(where base-is-gone)" PQ_BASE_GONE)" "" "and the block is cleared, so it can warn again later"
git -C "$REPO" update-ref -d refs/remotes/origin/no-such-integration-branch

echo "== pq ls surfaces a gone base, and counts it as needing you ==" >&2
# The stall this prevents: a task with no blockers and a deleted base showed `-`
# in the AGENT column and counted as healthy, so the queue sat still with nothing
# on screen accounting for it.
reset_tasks; reset_caches
nb=$(mk_task queue 65 ls-base-gone "$REPO" tom/lsgone no-such-integration-branch)
eq "$(agent_cell "$nb" queue)" "-" "before any tick has looked, there is nothing to report"
st_set "$nb" PQ_BASE_GONE 1
eq "$(agent_cell "$nb" queue)" "base gone" "once stamped, the listing says so"
case "$(agent_cell "$nb" queue)" in
  base\ *) ok ;;                        # the shape cmd_ls counts into "needs you"
  *) bad "the cell must match the base\ * pattern cmd_ls counts" ;;
esac
# It outranks a blocker verdict: both are true, but only one needs you.
printf 'someone\t%s\ttom/nope\n' "$REPO" > "$nb/after"
eq "$(agent_cell "$nb" queue)" "base gone" "a gone base outranks a blocker in the cell too"
st_set "$nb" PQ_BASE_GONE ""
case "$(agent_cell "$nb" queue)" in
  base\ *) bad "clearing the stamp must restore the blocker report" ;;
  *) ok ;;
esac

echo "== pq base: retarget or clear a queued task ==" >&2
reset_tasks; reset_caches
b=$(mk_task queue 70 rebase-me "$REPO" tom/rb live-events)
cmd_base rebase-me master >/dev/null 2>&1
eq "$(hdr "$b/plan.md" base)" "master" "pq base <task> <branch> rewrites the header"
eq "$(task_base "$b")" "master" "...and task_base agrees"
repo_base_reset
cmd_base rebase-me --clear >/dev/null 2>&1
eq "$(hdr "$b/plan.md" base)" "" "pq base --clear removes the header entirely"
eq "$(task_base "$b")" "master" "...falling back to the repo default"
repo_base_reset
# The plan BODY must survive being rewritten - it is the agent's instructions.
grep -q "plan body" "$b/plan.md" && ok || bad "pq base must not damage the plan body"
# Subshells around every expected-to-die call: this file SOURCES pq, so `die`
# would exit the test run itself rather than just the command under test.
( cmd_base rebase-me no-such-branch-at-all >/dev/null 2>&1 ) \
  && bad "pq base must reject a base that does not resolve" || ok
# Inserting a base where there was NEVER one: the awk's ^branch: rule has to fire
# for a header that has no base: line to drop first. This is the path taken by
# someone who realises mid-queue that a task should target an integration branch.
fresh=$(mk_task queue 72 no-base-yet "$REPO" tom/nby)
eq "$(hdr "$fresh/plan.md" base)" "" "fixture starts with no base: header at all"
cmd_base no-base-yet live-events >/dev/null 2>&1
eq "$(hdr "$fresh/plan.md" base)" "live-events" "pq base inserts a header where none existed"
eq "$(hdr "$fresh/plan.md" branch)" "tom/nby" "...without disturbing the branch it sits under"
eq "$(hdr "$fresh/plan.md" model)" "sonnet" "...or anything after it"
grep -q "plan body" "$fresh/plan.md" && ok || bad "insert must not damage the plan body"
eq "$(grep -c '^base:' "$fresh/plan.md")" "1" "exactly one base: line, never a duplicate"

# A held task is where a task with a stale base actually accumulates, so it must
# follow the same path as a queued one - gated, and warned about only once.
held=$(mk_task hold 73 held-base-gone "$REPO" tom/hbg no-such-integration-branch)
eq "$(base_check "$held")" "basegone no-such-integration-branch" "a held task is gated too"
eq "$(st "$held" PQ_BASE_GONE)" "1" "...and stamped on the transition"
eq "$(base_check "$held")" "basegone no-such-integration-branch" "still gated on the next pass"
second_warn=$(base_check "$held" 2>&1 >/dev/null)
eq "$second_warn" "" "a held task must not re-warn every tick while it sits there"

# Only what has not started, same rule as pq after's mutating forms.
r=$(mk_task running 71 already-going "$REPO" tom/ag)
( cmd_base already-going master >/dev/null 2>&1 ) \
  && bad "pq base must refuse a task that has already been dispatched" || ok

echo "== pq add infers the base from the branch the repo is on ==" >&2
# The workflow this serves: you plan the work while standing on the branch it
# belongs to, so the checkout already knows the answer and nobody has to remember
# --base. The failure it replaces was silent - a forgotten --base queues against
# the trunk and only shows up at dispatch.
reset_tasks
PLAN=$(mktemp -d); printf '# probe\n\nbody\n' > "$PLAN/plan.md"
addq() {                                # branch-to-stand-on [extra args...] -> the task dir
  local stand=$1; shift
  git -C "$REPO" checkout -q "$stand"
  ( cmd_add "$PLAN/plan.md" --repo "$REPO" --branch "tom/$1" --intent probe "${@:2}" >/dev/null 2>&1 )
  ls -d "$PQ_HOME"/queue/*-"$(branch_to_slug "tom/$1")" 2>/dev/null | head -1
}

# Standing on the integration branch: inherited, and recorded in the header.
d=$(addq live-events inherit-1)
eq "$(hdr "$d/plan.md" base)" "live-events" "standing on live-events queues against live-events"

# Standing on the default: nothing recorded, because task_base already answers
# master - every task queued before this feature keeps its exact plan.md.
d=$(addq master inherit-2)
eq "$(hdr "$d/plan.md" base)" "" "standing on the default writes no base: header at all"
eq "$(task_base "$d")" "master" "...and still resolves to master"
repo_base_reset

# An explicit --base always wins over the branch you happen to be on.
d=$(addq live-events inherit-3 --base master)
eq "$(hdr "$d/plan.md" base)" "" "--base master overrides the branch, and normalises to no header"
d=$(addq master inherit-4 --base live-events)
eq "$(hdr "$d/plan.md" base)" "live-events" "--base wins when standing on the default too"

# A branch that exists only locally cannot be forked from by wt, and no pull
# request can target it - so it must NOT be inherited.
git -C "$REPO" branch -q local-only master 2>/dev/null
d=$(addq local-only inherit-5)
eq "$(hdr "$d/plan.md" base)" "" "a branch that is not on origin is not inherited"
eq "$(task_base "$d")" "master" "...it falls back to the default"
repo_base_reset

# Detached HEAD has no branch to inherit.
git -C "$REPO" checkout -q --detach master
( cmd_add "$PLAN/plan.md" --repo "$REPO" --branch tom/inherit-6 --intent probe >/dev/null 2>&1 )
d=$(ls -d "$PQ_HOME"/queue/*-inherit-6 2>/dev/null | head -1)
eq "$(hdr "$d/plan.md" base)" "" "a detached HEAD inherits nothing"
git -C "$REPO" checkout -q master
rm -rf "$PLAN"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
