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

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() {                                   # got want msg
  [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"
}

cleanup() { rm -rf "$PQ_HOME" "$STUBBIN" "${REPO:-}"; }
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
  rm -rf "$PQ_HOME/queue" "$PQ_HOME/hold" "$PQ_HOME/running" "$PQ_HOME/done"
  mkdir -p "$PQ_HOME/queue" "$PQ_HOME/hold" "$PQ_HOME/running" "$PQ_HOME/done"
}

# A task directory built by hand, bypassing cmd_add (and the Haiku round trip
# it would otherwise make) - just enough of plan.md for hdr() and state_of() to
# work.
mk_task() {                              # state prio slug repo branch -> task_dir
  local st=$1 prio=$2 slug=$3 repo=$4 branch=$5
  # $prio is relative order, not a stamp - it is offset into the real
  # (non-urgent) range so a fixture never accidentally reads as --urgent.
  # $((10#$prio)) rather than a bare $prio: inside $(( )) a leading-zero
  # literal like 020 is octal, exactly the bug this fixture must not
  # reintroduce.
  local dir="$PQ_HOME/$st/$(printf '%014d' $(( 20260101000000 + 10#$prio )))-$slug"
  mkdir -p "$dir"
  {
    printf -- '---\n'
    printf 'repo:     %s\n' "$repo"
    printf 'branch:   %s\n' "$branch"
    printf 'model:    sonnet\n'
    printf 'effort:   xhigh\n'
    printf 'dev:      false\n'
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

# answered, no rows, a held task owns the branch -> waiting
reset_caches
ans_row "$REPO" tom/held-owner
mk_task hold 10 owner-held "$REPO" tom/held-owner >/dev/null
eq "$(blocker_state "$REPO" tom/held-owner master)" "waiting" "no PR yet, held owner"

# answered, no rows, no live task owns the branch -> orphan
reset_caches
ans_row "$REPO" tom/nobody-owns-this
eq "$(blocker_state "$REPO" tom/nobody-owns-this master)" "orphan" "no PR, no owner"

# OPEN, owner running -> waiting
reset_caches
cache_row "$REPO" tom/open-running 8 OPEN "" master
mk_task running 10 owner-running "$REPO" tom/open-running >/dev/null
eq "$(blocker_state "$REPO" tom/open-running master)" "waiting" "OPEN, owner running"

# OPEN, owner in done -> waiting (this is the chain WORKING, not stalled)
reset_caches
cache_row "$REPO" tom/open-done 9 OPEN "" master
mk_task done 10 owner-open-done "$REPO" tom/open-done >/dev/null
eq "$(blocker_state "$REPO" tom/open-done master)" "waiting" "OPEN, owner done"

# DRAFT, owner in done -> stalled (a stuck agent, not a healthy wait)
reset_caches
cache_row "$REPO" tom/draft-done 10 OPEN draft master
mk_task done 10 owner-draft-done "$REPO" tom/draft-done >/dev/null
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
case "$verdict" in waiting\ *) ok ;; *) bad "gh-down should read as waiting (got '$verdict')" ;; esac
after_check "$t" >/dev/null
[ "$(st "$t" PQ_AFTER_DEAD)" != 1 ] && ok || bad "gh-down must not set PQ_AFTER_DEAD"

# OPEN, owner in done is the chain WORKING - it must stay exactly as quiet as
# the gh-down case above, not just read as "waiting".
reset_tasks; reset_caches
cache_row "$REPO" tom/open-done-quiet 11 OPEN "" master
t=$(mk_task done 10 owner-open-done-quiet "$REPO" tom/open-done-quiet)
u=$(mk_task queue 20 open-done-dependent "$REPO" tom/open-done-dependent)
after_add "$u" "$(slug_of "$t")" "$REPO" tom/open-done-quiet
after_check "$u" >/dev/null
[ "$(st "$u" PQ_AFTER_DEAD)" != 1 ] && ok || bad "OPEN with owner in done must not warn - that is the chain working"

echo "== after_check: warn once, then re-arm on recovery ==" >&2

# stalled -> after_check sets PQ_AFTER_DEAD and warns exactly once; recovery
# (the draft goes away) clears it, per the plan's named re-arm requirement.
reset_tasks; reset_caches
cache_row "$REPO" tom/stall-branch 12 OPEN draft master
owner=$(mk_task done 10 stall-owner "$REPO" tom/stall-branch)
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
cache_row "$REPO" tom/no-newline-blocker 15 OPEN "" master
owner=$(mk_task queue 10 no-newline-owner "$REPO" tom/no-newline-blocker)
dep=$(mk_task queue 20 no-newline-dependent "$REPO" tom/no-newline-dependent)
# Written directly, WITHOUT a trailing newline - `after` is documented as
# "hand-editable", and this is what a hand edit (or an earlier bug in the
# writer) looks like on disk.
printf '%s\t%s\t%s' "$(slug_of "$owner")" "$REPO" tom/no-newline-blocker > "$dep/after"
verdict=$(after_state "$dep"); verdict=${verdict%%$'\t'*}
case "$verdict" in waiting\ *) ok ;; *) bad "a trailing-newline-less after file must still gate (got '$verdict')" ;; esac
deps=$(dependents_of "$REPO" tom/no-newline-blocker)
eq "$deps" "no-newline-dependent" "dependents_of must not drop the last line either"

echo "== queue_ordered: an urgent task sorts ahead of every normal one, and two normal stamps sort chronologically ==" >&2
reset_tasks
# A bare mkdir, not mk_task: queue_ordered never reads plan.md, and a real
# stamp under PQ_STAMP_REAL is exactly what an urgent task looks like on disk.
mkdir -p "$PQ_HOME/queue/$(printf '%014d' 1)-prio-urgent"
mk_task queue 20 prio-later "$REPO" tom/prio-later >/dev/null
mk_task queue 10 prio-earlier "$REPO" tom/prio-earlier >/dev/null
first_slug=$(slug_of "$(queue_ordered | sed -n 1p)")
mid_slug=$(slug_of "$(queue_ordered | sed -n 2p)")
last_slug=$(slug_of "$(queue_ordered | sed -n 3p)")
eq "$first_slug" "prio-urgent"  "an urgent stamp must sort ahead of every normal one"
eq "$mid_slug"   "prio-earlier" "the earlier normal stamp must come before the later one"
eq "$last_slug"  "prio-later"   "the later normal stamp must sort last"

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
Z=$(mk_task queue 30 cyc-z "$REPO" tom/cyc-z)
if ( main after "$(slug_of "$X")" tom/cyc-z ) >/dev/null 2>&1; then
  ok
else
  bad "a genuine, non-cyclic blocker should have been accepted"
fi

echo "== pq add: stdout is exactly the slug ==" >&2
reset_tasks
PLAN_FILE="$PQ_HOME/.test-plan.md"
printf '# Test plan\n\nDo the thing.\n' > "$PLAN_FILE"
add_out=$(main add "$PLAN_FILE" --branch tom/add-stdout-test --repo "$REPO" 2>"$PQ_HOME/.add.stderr")
add_rc=$?
[ "$add_rc" -eq 0 ] && ok || bad "pq add should succeed (rc=$add_rc): $(cat "$PQ_HOME/.add.stderr")"
lines=$(printf '%s\n' "$add_out" | wc -l | tr -d ' ')
eq "$lines" "1" "pq add stdout should be exactly one line"
eq "$add_out" "add-stdout-test" "pq add stdout should be the slug, nothing else"
if find_task "$add_out" >/dev/null 2>&1; then ok; else bad "find_task should resolve the printed slug"; fi

# Chaining: b=$(pq add planB.md --after "$a") - the whole point of the stdout
# contract.
b_out=$(main add "$PLAN_FILE" --branch tom/add-chain-b --repo "$REPO" --after "$add_out" 2>"$PQ_HOME/.add.stderr")
b_rc=$?
[ "$b_rc" -eq 0 ] && ok || bad "chained pq add should succeed: $(cat "$PQ_HOME/.add.stderr")"
b_dir=$(find_task "$b_out" 2>/dev/null)
if [ -n "$b_dir" ] && [ -f "$b_dir/after" ]; then ok; else bad "chained add should have written an after file"; fi
verdict=$(after_state "$b_dir" 2>/dev/null); verdict=${verdict%%$'\t'*}
case "$verdict" in waiting\ *) ok ;; *) bad "B should be waiting on A right after being chained (got '$verdict')" ;; esac

echo "== --json smoke test ==" >&2
add_json=$(main add "$PLAN_FILE" --branch tom/add-json-test --repo "$REPO" --after "$add_out" \
             --json 2>"$PQ_HOME/.add.stderr")
if printf '%s' "$add_json" | jq -e '.after | length == 1 and .[0].label == "add-stdout-test"' >/dev/null 2>&1
then ok; else bad "pq add --json should carry the resolved blocker (got '$add_json')"; fi

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

echo "== regression: cmd_add --after --json keeps the SAME cache for after_json ==" >&2
# A real MERGED row, through the actual pr_load -> gh -> jq pipeline (via the
# canned gh stub above) rather than a hand-primed cache - this is what the
# fixed ordering bug looked like: the merge-check loop reported "already
# merged" from a live cache, then --json's after_json read a cache already
# deleted out from under it and called the same blocker "unknown".
merged_out=$(main add "$PLAN_FILE" --branch tom/already-merged --repo "$REPO" 2>"$PQ_HOME/.add.stderr")
merged_rc=$?
[ "$merged_rc" -eq 0 ] && ok || bad "adding the already-merged task should succeed: $(cat "$PQ_HOME/.add.stderr")"
merged_json=$(main add "$PLAN_FILE" --branch tom/depends-on-merged --repo "$REPO" \
                --after "$merged_out" --json 2>"$PQ_HOME/.add.stderr")
if printf '%s' "$merged_json" | jq -e '.after[0].state == "met"' >/dev/null 2>&1
then ok; else bad "an already-merged blocker should read 'met' in the same pq add --json call (got '$merged_json')"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
