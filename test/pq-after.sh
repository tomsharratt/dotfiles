#!/usr/bin/env bash
# test/pq-after.sh - the blocker predicate and cmd_after, exercised directly.
#
# Plain bash, no framework, matching the repo's zero-dependency habit. This is
# the first test in the repo. It exists because most of the rows below are
# unreachable by hand without a dozen real PRs, and because the ones that fail
# SILENTLY rather than loudly - orphan, stalled, gh-down - are the ones that
# burn a whole night unattended.
#
# Sources pq rather than exec-ing it, so the pure predicate functions
# (pr_merged_into, pr_answered, blocker_state) are callable directly against a
# hand-primed cache, with no live PR and no `gh` call in the loop.
#
# SC2015: `ok` never fails, so `[ ... ] && ok || bad` is an if/else.
# shellcheck disable=SC2015
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# A temp PQ_HOME, exported BEFORE sourcing - pq's own top-level
# `for d in $STATES; do mkdir -p ...` runs at source time, so this is what
# keeps the whole rehearsal off the real queue.
PQ_HOME=$(mktemp -d)
export PQ_HOME

# Stub `claude`, `gh`, and `herdr` so nothing here ever makes a real network (or
# real-herdr-socket) call. name_plan already tolerates `claude` failing (its own
# `|| return 0`), and an unanswered `gh` is exactly the "gh never answered" row
# in the outcomes table - so the stub failing closed is realistic, not a
# workaround. `gh` additionally answers ONE canned row, for the one test below
# that needs a real MERGED PR to flow through the actual pr_load -> jq pipeline
# rather than a hand-primed cache.
#
# `herdr` matters even though this file never asserts anything about agent
# status: `tick_body` calls `pidx_load` at its very top on every real machine
# this happens to run on (this repo's own dev box included), which shells out
# to a REAL `herdr` if one is on PATH. Without a stub, this suite's outcome
# would depend on whether Herdr happens to be running - answering "no agents"
# either way, but nondeterministically so. `dead 2>/dev/null` on the socket
# check keeps `api snapshot` looking like an unreachable server rather than a
# hang.
STUBBIN=$(mktemp -d)
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/claude"
cat > "$STUBBIN/gh" <<'EOF'
#!/bin/sh
case "$*" in
  *"pr list --head tom/already-merged "*)
    echo '[{"number":99,"state":"MERGED","isDraft":false,"baseRefName":"master"}]'
    exit 0
    ;;
esac
exit 1
EOF
cat > "$STUBBIN/herdr" <<'EOF'
#!/bin/sh
case "$*" in
  "api snapshot") echo '{"result":{"snapshot":{"panes":[]}}}'; exit 0 ;;
esac
exit 1
EOF
chmod +x "$STUBBIN/claude" "$STUBBIN/gh" "$STUBBIN/herdr"
export PATH="$STUBBIN:$PATH"

# shellcheck source=/dev/null
source "$HERE/../.local/bin/pq"
# shellcheck source=test/lib.sh
source "$HERE/lib.sh"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() {                                   # got want msg
  [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"
}

cleanup() { rm -rf "$PQ_HOME" "$STUBBIN" "${REPO:-}" "${REPO2:-}"; }
first_dir() { [ -d "${1:-}" ] && printf '%s' "$1"; }
trap cleanup EXIT

# ── a real, throwaway git repo ──────────────────────────────────────────────
# repo_base mirrors wt's base_ref, which reads a real remote-tracking symbolic
# ref - so a fake path is not enough. This is offline: no `git remote add`, no
# network, just a local repo with `refs/remotes/origin/HEAD` faked by hand.
REPO=$(mktemp -d)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$REPO/.git/refs/remotes/origin"
git -C "$REPO" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master

reset_caches() {
  PR_CACHE="$PQ_HOME/.test.pr"; PR_ANS="$PQ_HOME/.test.ans"
  : > "$PR_CACHE"; : > "$PR_ANS"
}
cache_row() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$PR_CACHE"; }   # repo branch num state draft base
ans_row()   { printf '%s\t%s\n' "$@" >> "$PR_ANS"; }                    # repo branch

reset_tasks() {
  rm -rf "$PQ_HOME/new" "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done"
  mkdir -p "$PQ_HOME/new" "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done"
}

# A task directory built by hand, bypassing cmd_add (and the Haiku round trip
# it would otherwise make) - just enough of plan.md for hdr() and state_of() to
# work.
mk_task() {                              # state prio slug repo branch -> task_dir
  local st=$1 prio=$2 slug=$3 repo=$4 branch=$5
  # $prio is relative order, not a stamp - it is offset into a real
  # timestamp so a fixture reads like a task pq made.
  # $((10#$prio)) rather than a bare $prio: inside $(( )) a leading-zero
  # literal like 020 is octal, exactly the bug this fixture must not
  # reintroduce.
  local dir
  dir="$PQ_HOME/$st/$(printf '%014d' $(( 20260101000000 + 10#$prio )))-$slug"
  mkdir -p "$dir"
  {
    printf -- '---\n'
    printf 'repo:     %s\n' "$repo"
    printf 'branch:   %s\n' "$branch"
    printf 'model:    sonnet\n'
    printf 'effort:   xhigh\n'
    printf 'intent:   test fixture\n'
    printf 'added:    2026-01-01T00:00:00Z\n'
    printf -- '---\n\nplan body\n'
  } > "$dir/plan.md"
  printf '%s' "$dir"
}


echo "== pure predicates (no task directories at all) ==" >&2

# MERGED into the default branch -> met
reset_caches
cache_row "$REPO" tom/a 1 MERGED "" master
pr_merged_into "$REPO" tom/a master && ok || bad "pr_merged_into: MERGED into base should be true"
eq "$(blocker_state "$REPO" tom/a master)" "met" "MERGED into the default branch"

# MERGED into some other branch -> waiting
reset_caches
cache_row "$REPO" tom/b 2 MERGED "" develop
{ pr_merged_into "$REPO" tom/b master && bad "pr_merged_into: wrong base should be false"; } || ok
eq "$(blocker_state "$REPO" tom/b master)" "waiting" "MERGED into a different base"

# CLOSED only -> dead
reset_caches
cache_row "$REPO" tom/c 3 CLOSED "" master
eq "$(blocker_state "$REPO" tom/c master)" "dead" "every row CLOSED"

# no row and unanswered (gh down) -> blocker_state itself reads "unknown"
reset_caches
eq "$(blocker_state "$REPO" tom/d master)" "unknown" "no row, gh never answered"
{ pr_answered "$REPO" tom/d && bad "pr_answered: empty PR_ANS should be false"; } || ok
ans_row "$REPO" tom/d
pr_answered "$REPO" tom/d && ok || bad "pr_answered: a seeded row should be true"

# pr_all_closed: one open row among closed ones flips it
reset_caches
cache_row "$REPO" tom/e 5 CLOSED "" master
cache_row "$REPO" tom/e 6 CLOSED "" master
pr_all_closed "$REPO" tom/e && ok || bad "pr_all_closed: two closed rows should be true"
cache_row "$REPO" tom/e 7 OPEN "" master
{ pr_all_closed "$REPO" tom/e && bad "pr_all_closed: an open row should flip it false"; } || ok

echo "== blocker_state with real task directories ==" >&2
reset_tasks

# answered, no rows, a queued task owns the branch -> waiting
reset_caches
ans_row "$REPO" tom/queued-owner
mk_task queue 10 owner-queued "$REPO" tom/queued-owner >/dev/null
eq "$(blocker_state "$REPO" tom/queued-owner master)" "waiting" "no PR yet, queued owner"

# answered, no rows, no live task owns the branch -> orphan
reset_caches
ans_row "$REPO" tom/nobody-owns-this
eq "$(blocker_state "$REPO" tom/nobody-owns-this master)" "orphan" "no PR, no owner"

# OPEN and marked ready, owner running -> ready
reset_caches
cache_row "$REPO" tom/open-running 8 OPEN "" master
mk_task running 10 owner-running "$REPO" tom/open-running >/dev/null
eq "$(blocker_state "$REPO" tom/open-running master)" "ready" "OPEN and not a draft, owner running"

# OPEN and marked ready, owner in done -> ready (the chain WORKING, not stalled)
reset_caches
cache_row "$REPO" tom/open-done 9 OPEN "" master
mk_task "done" 10 owner-open-done "$REPO" tom/open-done >/dev/null
eq "$(blocker_state "$REPO" tom/open-done master)" "ready" "OPEN and not a draft, owner done"

# A DRAFT whose owner is still running is in review, not ready
reset_caches
cache_row "$REPO" tom/draft-running 9 OPEN draft master
mk_task running 10 owner-draft-running "$REPO" tom/draft-running >/dev/null
eq "$(blocker_state "$REPO" tom/draft-running master)" "waiting" "a draft, owner running"
pr_has_ready "$REPO" tom/draft-running && bad "pr_has_ready: a draft is not ready" || ok

# DRAFT, owner in done -> stalled (a stuck agent, not a healthy wait)
reset_caches
cache_row "$REPO" tom/draft-done 10 OPEN draft master
mk_task "done" 10 owner-draft-done "$REPO" tom/draft-done >/dev/null
eq "$(blocker_state "$REPO" tom/draft-done master)" "stalled" "DRAFT, owner done"

echo "== after_state / after_check aggregation ==" >&2

# orphan folds into after_state's "dead" bucket, with the finer detail carried
# in the second field for the warning text.
reset_tasks; reset_caches
ans_row "$REPO" tom/orphan-branch
t=$(mk_task queue 10 orphan-owner "$REPO" tom/orphan-owner)
after_add "$t" ghost "$REPO" tom/orphan-branch
verdict=$(after_state "$t"); detail=${verdict#*$'\t'}; verdict=${verdict%%$'\t'*}
case "$verdict" in dead\ *) ok ;; *) bad "orphan should read as dead at the after_state level (got '$verdict')" ;; esac
eq "$detail" "orphan" "orphan detail should distinguish it from a closed PR"

# gh-down reads as an ordinary wait, and after_check must not warn about it.
reset_tasks; reset_caches
t=$(mk_task queue 20 unknown-owner "$REPO" tom/unknown-owner)
after_add "$t" ghost "$REPO" tom/never-answered
verdict=$(after_state "$t"); verdict=${verdict%%$'\t'*}
eq "$verdict" "on ghost" "gh-down reads as an ordinary wait - for a same-repo parent, on it"
after_check "$t" >/dev/null
[ "$(st "$t" PQ_AFTER_DEAD)" != 1 ] && ok || bad "gh-down must not set PQ_AFTER_DEAD"

# OPEN, owner in done is the chain WORKING - it must stay exactly as quiet as
# the gh-down case above, not just read as "waiting".
reset_tasks; reset_caches
cache_row "$REPO" tom/open-done-quiet 11 OPEN "" master
t=$(mk_task "done" 10 owner-open-done-quiet "$REPO" tom/open-done-quiet)
u=$(mk_task queue 20 open-done-dependent "$REPO" tom/open-done-dependent)
after_add "$u" "$(slug_of "$t")" "$REPO" tom/open-done-quiet
after_check "$u" >/dev/null
[ "$(st "$u" PQ_AFTER_DEAD)" != 1 ] && ok || bad "OPEN with owner in done must not warn - that is the chain working"

echo "== after_check: warn once, then re-arm on recovery ==" >&2

# stalled -> after_check sets PQ_AFTER_DEAD and warns exactly once; recovery
# (the draft goes away) clears it, per the plan's named re-arm requirement.
reset_tasks; reset_caches
cache_row "$REPO" tom/stall-branch 12 OPEN draft master
owner=$(mk_task "done" 10 stall-owner "$REPO" tom/stall-branch)
dep=$(mk_task queue 20 stall-dependent "$REPO" tom/stall-dependent)
after_add "$dep" "$(slug_of "$owner")" "$REPO" tom/stall-branch

first_warn=$(after_check "$dep" 2>&1 1>/dev/null)
eq "$(st "$dep" PQ_AFTER_DEAD)" "1" "stalled should set PQ_AFTER_DEAD"
case "$first_warn" in *stalled*) ok ;; *) bad "stalled should warn once (got '$first_warn')" ;; esac
second_warn=$(after_check "$dep" 2>&1 1>/dev/null)
[ -z "$second_warn" ] && ok || bad "a second tick must stay quiet (got '$second_warn')"

# Recovery: the draft is marked ready (isDraft column cleared).
reset_caches
cache_row "$REPO" tom/stall-branch 12 OPEN "" master
after_check "$dep" >/dev/null
[ "$(st "$dep" PQ_AFTER_DEAD)" != 1 ] && ok || bad "a ready PR should clear PQ_AFTER_DEAD"

# dead -> same warn-once/clear shape, the other family member.
reset_tasks; reset_caches
cache_row "$REPO" tom/dead-branch 13 CLOSED "" master
dep=$(mk_task queue 10 dead-dependent "$REPO" tom/dead-dependent)
after_add "$dep" ghost "$REPO" tom/dead-branch
first_warn=$(after_check "$dep" 2>&1 1>/dev/null)
eq "$(st "$dep" PQ_AFTER_DEAD)" "1" "dead should set PQ_AFTER_DEAD"
case "$first_warn" in *"is dead"*) ok ;; *) bad "dead should warn once (got '$first_warn')" ;; esac
second_warn=$(after_check "$dep" 2>&1 1>/dev/null)
[ -z "$second_warn" ] && ok || bad "dead must also stay quiet on the second tick (got '$second_warn')"
reset_caches
cache_row "$REPO" tom/dead-branch 14 MERGED "" master
after_check "$dep" >/dev/null
[ "$(st "$dep" PQ_AFTER_DEAD)" != 1 ] && ok || bad "a later merge should clear PQ_AFTER_DEAD"

echo "== an after file with no trailing newline still gates (regression) ==" >&2
reset_tasks; reset_caches
cache_row "$REPO" tom/no-newline-blocker 15 OPEN draft master
owner=$(mk_task queue 10 no-newline-owner "$REPO" tom/no-newline-blocker)
dep=$(mk_task queue 20 no-newline-dependent "$REPO" tom/no-newline-dependent)
# Written directly, WITHOUT a trailing newline - `after` is documented as
# "hand-editable", and this is what a hand edit (or an earlier bug in the
# writer) looks like on disk.
printf '%s\t%s\t%s' "$(slug_of "$owner")" "$REPO" tom/no-newline-blocker > "$dep/after"
verdict=$(after_state "$dep"); verdict=${verdict%%$'\t'*}
case "$verdict" in on\ *) ok ;; *) bad "a trailing-newline-less after file must still gate (got '$verdict')" ;; esac
deps=$(dependents_of "$REPO" tom/no-newline-blocker)
eq "$deps" "no-newline-dependent" "dependents_of must not drop the last line either"

echo "== queue_ordered: two stamps sort chronologically, whatever order they were made in ==" >&2
reset_tasks
mk_task queue 20 prio-later "$REPO" tom/prio-later >/dev/null
mk_task queue 10 prio-earlier "$REPO" tom/prio-earlier >/dev/null
first_slug=$(slug_of "$(queue_ordered | sed -n 1p)")
last_slug=$(slug_of "$(queue_ordered | sed -n 2p)")
eq "$first_slug" "prio-earlier" "the earlier stamp must come first"
eq "$last_slug"  "prio-later"   "the later stamp must sort last"

echo "== a chain of three, middle link unmerged ==" >&2
reset_tasks
A=$(mk_task queue 10 chain-a "$REPO" tom/chain-a)
B=$(mk_task queue 20 chain-b "$REPO" tom/chain-b)
after_add "$B" "$(slug_of "$A")" "$REPO" tom/chain-a
C=$(mk_task queue 30 chain-c "$REPO" tom/chain-c)
after_add "$C" "$(slug_of "$B")" "$REPO" tom/chain-b

out=$(tick_body 3 1 2>&1 1>/dev/null)
case "$out" in *"would dispatch $(slug_of "$A")"*) ok ;; *) bad "chain: A should be eligible ($out)" ;; esac
case "$out" in *"would skip $(slug_of "$B")"*)     ok ;; *) bad "chain: B should be skipped ($out)" ;; esac
case "$out" in *"would skip $(slug_of "$C")"*)     ok ;; *) bad "chain: C should be skipped ($out)" ;; esac

echo "== a same-repo dependency builds on its parent: on, stack, met ==" >&2
# A second repo, for a dependency that crosses repos and so waits for a merge.
REPO2=$(mktemp -d)
git init -q -b main "$REPO2"
git -C "$REPO2" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$REPO2/.git/refs/remotes/origin"
git -C "$REPO2" update-ref refs/remotes/origin/main refs/heads/main
git -C "$REPO2" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
verdict_of() { local v; v=$(after_state "$1"); printf '%s' "${v%%$'\t'*}"; }

reset_tasks; reset_caches
mk_task running 10 stack-parent "$REPO" tom/stack-parent >/dev/null
K=$(mk_task queue 20 stack-child "$REPO" tom/stack-child)
after_add "$K" stack-parent "$REPO" tom/stack-parent
ans_row "$REPO" tom/stack-parent
eq "$(verdict_of "$K")" "on stack-parent" "no pull request yet: on its parent"
cache_row "$REPO" tom/stack-parent 30 OPEN draft master
eq "$(verdict_of "$K")" "on stack-parent" "a draft in review: still on its parent"
reset_caches
cache_row "$REPO" tom/stack-parent 30 OPEN "" master
eq "$(verdict_of "$K")" "stack stack-parent" "marked ready: it builds on it"
eq "$(agent_cell "$K" queue)" "-" "eligible, so pq ls has nothing to say about it"
reset_caches
cache_row "$REPO" tom/stack-parent 30 MERGED "" master
eq "$(verdict_of "$K")" "met" "merged: met, and it starts from the default branch"
reset_caches
ans_row "$REPO" tom/stack-parent
eq "$(agent_cell "$K" queue)" "on stack-parent" "pq ls reads on <label> while it waits"
eq "$(stack_branch "$K" stack-parent)" "tom/stack-parent" "stack_branch reads the branch off its after line"

echo "== a dependency in another repo waits for its merge, ready or not ==" >&2
reset_tasks; reset_caches
mk_task running 10 web-parent "$REPO2" tom/web-parent >/dev/null
M=$(mk_task queue 20 app-child "$REPO" tom/app-child)
after_add "$M" web-parent "$REPO2" tom/web-parent
cache_row "$REPO2" tom/web-parent 31 OPEN "" main
eq "$(verdict_of "$M")" "waiting web-parent 1" "marked ready is still waiting across repos"
eq "$(agent_cell "$M" queue)" "after web-parent" "and reads after <label>, as before"
reset_caches
cache_row "$REPO2" tom/web-parent 31 MERGED "" main
eq "$(verdict_of "$M")" "met" "merged into its own repo's default branch: met"

echo "== fill claims a stack task and records its parent, and skips one still on it ==" >&2
reset_tasks; reset_caches
mk_task running 10 fill-parent "$REPO" tom/fill-parent >/dev/null
W=$(mk_task queue 20 fill-waiting "$REPO" tom/fill-waiting)
after_add "$W" fill-parent "$REPO" tom/fill-parent
mk_task running 30 fill-ready "$REPO" tom/fill-ready >/dev/null
S=$(mk_task queue 40 fill-stack "$REPO" tom/fill-stack)
after_add "$S" fill-ready "$REPO" tom/fill-ready
# The tick loads its own cache; this stands in for the forge's answer.
# shellcheck disable=SC2329  # called by tick_body
pr_load_all() {
  PR_CACHE="$PQ_HOME/.test.pr"; PR_ANS="$PQ_HOME/.test.ans"
  printf '%s\t%s\n' "$REPO" tom/fill-parent "$REPO" tom/fill-ready > "$PR_ANS"
  printf '%s\ttom/fill-ready\t41\tOPEN\t\tmaster\t\n' "$REPO" > "$PR_CACHE"
}
out=$(tick_body 5 1 2>&1 1>/dev/null)
case "$out" in *"would skip fill-waiting - waiting for fill-parent to be marked ready"*) ok ;; *) bad "an on task is skipped, saying why ($out)" ;; esac
case "$out" in *"would dispatch fill-stack (tom/fill-stack), building on fill-ready"*) ok ;; *) bad "a stack task is eligible ($out)" ;; esac
case "$out" in *"1 waiting"*) ok ;; *) bad "the summary counts the on task as waiting, and not the stack one ($out)" ;; esac
# shellcheck disable=SC2329  # called by tick_body
( dispatch_try() { return 0; }; tick_body 5 0 ) >/dev/null 2>&1
S=$(first_dir "$PQ_HOME/running"/*-fill-stack)
[ -n "$S" ] && ok || bad "the stack task is claimed"
[ -n "$S" ] && eq "$(st "$S" PQ_STACK_PARENT)" "tom/fill-ready" "and records the branch it builds on at the claim"
[ -d "$W" ] && ok || bad "the on task stays queued"
unset -f pr_load_all

echo "== pr_targets brings a stacked task's parent along, while it can still change ==" >&2
reset_tasks
R=$(mk_task running 10 tgt-run "$REPO" tom/tgt-run); st_set "$R" PQ_STACK_PARENT tom/tgt-parent-a
D=$(mk_task "done" 20 tgt-done "$REPO" tom/tgt-done); st_set "$D" PQ_STACK_PARENT tom/tgt-parent-b
E=$(mk_task "done" 30 tgt-merged "$REPO" tom/tgt-merged); st_set "$E" PQ_STACK_PARENT tom/tgt-parent-c
st_set "$E" PQ_MERGED 2026-01-02T00:00:00Z
targets=$(pr_targets running)
case "$targets" in *"$REPO"$'\t'tom/tgt-parent-a*) ok ;; *) bad "a running task's parent is looked up ($targets)" ;; esac
case "$targets" in *tom/tgt-parent-b*) ok ;; *) bad "so is a done one's, while reap still watches it ($targets)" ;; esac
case "$targets" in *tom/tgt-parent-c*) bad "but not once its own pull request has merged ($targets)" ;; *) ok ;; esac
case "$(pr_targets all)" in *tom/tgt-parent-c*) bad "not even for pq ls" ;; *) ok ;; esac

echo "== cycle and self-reference rejected by pq after ==" >&2
reset_tasks
X=$(mk_task queue 10 cyc-x "$REPO" tom/cyc-x)
Y=$(mk_task queue 20 cyc-y "$REPO" tom/cyc-y)
after_add "$Y" "$(slug_of "$X")" "$REPO" tom/cyc-x   # Y after X

if ( main after "$(slug_of "$X")" tom/cyc-x ) >/dev/null 2>&1; then
  bad "self-reference should have been rejected"
else
  ok
fi
if ( main after "$(slug_of "$X")" tom/cyc-y ) >/dev/null 2>&1; then
  bad "the cycle (X after Y, Y already after X) should have been rejected"
else
  ok
fi
# A non-cyclic blocker on the same task must still be accepted.
mk_task queue 30 cyc-z "$REPO" tom/cyc-z >/dev/null
if ( main after "$(slug_of "$X")" tom/cyc-z ) >/dev/null 2>&1; then
  ok
else
  bad "a genuine, non-cyclic blocker should have been accepted"
fi

echo "== pq after sets one dependency, replacing any ==" >&2
reset_tasks
A=$(mk_task queue 10 one-a "$REPO" tom/one-a)
B=$(mk_task queue 20 one-b "$REPO" tom/one-b)
C=$(mk_task queue 30 one-c "$REPO" tom/one-c)
out=$( ( main after one-c one-a ) 2>&1 ); rc=$?
eq "$rc" "0" "setting a dependency succeeds"
case "$out" in *"one-c builds on one-a - it starts once its pull request is marked ready"*) ok ;; *) bad "and says what it set ($out)" ;; esac
( main after one-c one-b ) >/dev/null 2>&1
eq "$(cut -f1 "$C/after")" "one-b" "a second pq after replaces the first rather than adding to it"
eq "$(wc -l < "$C/after" | tr -d ' ')" "1" "one line, always"
( main after one-c one-b ) >/dev/null 2>&1 && ok || bad "setting the same one again is not a fan-out of itself"
( main after one-c one-a one-b ) >/dev/null 2>"$PQ_HOME/.err" && bad "two at once is refused" || ok
case "$(cat "$PQ_HOME/.err")" in *"takes one task or branch"*) ok ;; *) bad "saying why ($(cat "$PQ_HOME/.err"))" ;; esac
eq "$(cut -f1 "$C/after")" "one-b" "and changes nothing"

echo "== pq after refuses to build on what something else already builds on ==" >&2
out=$( ( main after one-a one-b ) 2>&1 ); rc=$?
[ "$rc" != 0 ] && ok || bad "one-b is already built on by one-c, so one-a cannot build on it"
case "$out" in *"one-c already builds on one-b - a stack is a single line, so build on one-c instead"*) ok ;; *) bad "saying so ($out)" ;; esac
[ -f "$A/after" ] && bad "and nothing is written" || ok
# Through a task in new/ that still holds its dependency by stamp.
N=$(mk_task new 40 unnamed-child "$REPO" "")
printf '%s\n' "$(stamp_of "$A")" > "$N/after.new"
out=$( ( main after one-b one-a ) 2>&1 ) && bad "a stamp held in new/ counts as building on it" || ok
case "$out" in *"unnamed-child already builds on one-a"*) ok ;; *) bad "naming the task in new/ ($out)" ;; esac
rm -rf "$N"
# Across repos it is a wait, not a stack, and many can wait on one merge.
REPO3=$(mktemp -d); git init -q -b master "$REPO3"
O=$(mk_task queue 50 other-repo "$REPO3" tom/other-repo)
after_add "$O" one-a "$REPO" tom/one-a
( main after one-b one-a ) >/dev/null 2>&1 && ok || bad "a task in another repo waiting on one-a does not stop one-b building on it"
out=$( ( main after other-repo one-c ) 2>&1 ); rc=$?
eq "$rc" "0" "a cross-repo wait is set"
case "$out" in *"other-repo waits for one-c ($(basename "$REPO")) to merge"*) ok ;; *) bad "and reads as one ($out)" ;; esac
rm -rf "$REPO3"

echo "== pq after <task> describes both kinds ==" >&2
reset_tasks
A=$(mk_task running 10 desc-a "$REPO" tom/desc-a)
B=$(mk_task queue 20 desc-b "$REPO" tom/desc-b)
after_add "$B" desc-a "$REPO" tom/desc-a
X=$(mk_task running 30 desc-x "$REPO2" tom/desc-x)
Y=$(mk_task queue 40 desc-y "$REPO" tom/desc-y)
after_add "$Y" desc-x "$REPO2" tom/desc-x
describe() {                            # task cache_rows -> pq after's line
  local rows=$2
  # shellcheck disable=SC2329  # called by cmd_after
  ( pr_load_all() {
      PR_CACHE="$PQ_HOME/.test.pr"; PR_ANS="$PQ_HOME/.test.ans"
      printf '%s' "$rows" > "$PR_CACHE"; : > "$PR_ANS"
    }
    main after "$1" ) 2>&1
}
case "$(describe desc-b "$REPO"$'\t'tom/desc-a$'\t'7$'\t'OPEN$'\t'draft$'\t'master$'\t'$'\n')" in
  *"#7 draft"*"waiting for #7 to be marked ready"*) ok ;; *) bad "a stack dependency in review waits to be marked ready" ;; esac
case "$(describe desc-b "$REPO"$'\t'tom/desc-a$'\t'7$'\t'OPEN$'\t'$'\t'master$'\t'$'\n')" in
  *"ready - desc-b builds on it"*) ok ;; *) bad "a ready one is built on" ;; esac
case "$(describe desc-b "$REPO"$'\t'tom/desc-a$'\t'7$'\t'MERGED$'\t'$'\t'master$'\t'$'\n')" in
  *"merged - desc-b starts from master"*) ok ;; *) bad "a merged one is where it starts from" ;; esac
case "$(describe desc-y "$REPO2"$'\t'tom/desc-x$'\t'8$'\t'OPEN$'\t'$'\t'main$'\t'$'\n')" in
  *"#8 open"*"in progress"*) ok ;; *) bad "a merge dependency reads as it always did, ready or not" ;; esac
case "$(main after desc-x 2>&1)" in *"builds on nothing and waits for nothing"*) ok ;; *) bad "a task with none says so" ;; esac

echo "== pq add --after: a blocker named by slug gates the new task ==" >&2
reset_tasks
PLAN_FILE="$PQ_HOME/.test-plan.md"
printf '# Test plan\n\nDo the thing.\n' > "$PLAN_FILE"
add_as "$PLAN_FILE" tom/add-chain-a --repo "$REPO" 2>"$PQ_HOME/.add.stderr"
add_rc=$?
[ "$add_rc" -eq 0 ] && ok || bad "pq add should succeed (rc=$add_rc): $(cat "$PQ_HOME/.add.stderr")"
if find_task add-chain-a >/dev/null 2>&1; then ok; else bad "the added task should be found by its slug"; fi

add_as "$PLAN_FILE" tom/add-chain-b --repo "$REPO" --after add-chain-a 2>"$PQ_HOME/.add.stderr"
b_rc=$?
[ "$b_rc" -eq 0 ] && ok || bad "chained pq add should succeed: $(cat "$PQ_HOME/.add.stderr")"
b_dir=$(find_task add-chain-b 2>/dev/null)
if [ -n "$b_dir" ] && [ -f "$b_dir/after" ]; then ok; else bad "chained add should have written an after file"; fi
verdict=$(after_state "$b_dir" 2>/dev/null); verdict=${verdict%%$'\t'*}
eq "$verdict" "on add-chain-a" "B should be on A right after being chained"

echo "== an --after blocker is recorded, and pq ls --json sees the task blocked ==" >&2
add_as "$PLAN_FILE" tom/add-json-test --repo "$REPO" --after add-chain-a 2>"$PQ_HOME/.add.stderr"
eq "$(cut -f1 "$(find_task add-json-test)/after")" "add-chain-a" "the blocker is recorded under its own label"

ls_json=$(main ls --json 2>/dev/null)
if printf '%s' "$ls_json" \
     | jq -e '[.[] | select(.task == "add-json-test")][0] | .blocked == true' >/dev/null 2>&1
then ok; else bad "pq ls --json should mark the chained task blocked=true"; fi

echo "== regression: repo_base_reset actually removes its cache file ==" >&2
# Through command substitution, like every real caller (base=$(repo_base ...))
# - calling it as a bare statement would run in the CURRENT shell rather than
# a subshell, which is exactly the difference that let the original bug hide.
base_via_subshell=$(repo_base "$REPO")
[ -n "$base_via_subshell" ] || bad "repo_base should have resolved a base in the fixture repo"
[ -f "$PQ_HOME/.base.$$" ] && ok || bad "repo_base should have created its memo file at \$PQ_HOME/.base.\$\$"
repo_base_reset
[ ! -f "$PQ_HOME/.base.$$" ] && ok || bad "repo_base_reset should have removed the memo file, not left it forever"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
