#!/usr/bin/env bash
# test/pq-merged.sh - what counts as merged: a task's work is present in its
# repo's default branch, and a blocker's in its own repo's default branch.
#
# Same shape as test/pq-after.sh and test/pq-reap.sh - sources pq so the
# predicates are callable directly against a hand-primed PR cache, with no live
# PR and no `gh` in the loop.
#
# The rows that matter here are the ones that would fail SILENTLY: an upper
# layer of a stack merged from its top is recorded as merged into the branch
# below it, not into the trunk, so exact matching would read it as "still in
# review" forever, never tear its worktree down, and freeze its dependents.
#
# SC2015: `ok` never fails, so `[ ... ] && ok || bad` is an if/else.
# shellcheck disable=SC2015
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

# A `wt` stub, so the reap assertions can read back whether pq asked `wt` to
# remove a worktree, without a real worktree, database or Herdr pane in sight.
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
# shellcheck source=test/lib.sh
source "$HERE/lib.sh"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }

cleanup() { rm -rf "$PQ_HOME" "$STUBBIN" "${REPO:-}" "${REPO2:-}"; }
trap cleanup EXIT

# ── a real repo with a real stack ───────────────────────────────────────────
# The ancestry arm of `merged_into` reads actual git history, so this fixture has
# to be genuine - a faked ref is not enough. The shape is a stack merged from
# its top, as GitHub records it:
#
#   master        A ── B                 B is the upper layer's merge commit,
#                       \                landed on master with the whole stack
#   tom/lower            C               C is only on the lower layer's branch
#
# GitHub reports the upper pull request as MERGED with baseRefName=tom/lower
# (supercast #6999), yet its merge commit B is on master. A row into tom/lower
# whose merge commit C is NOT on master has not landed. Those two facts are the
# whole test.
REPO=$(mktemp -d)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m A
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m B
OID_B=$(git -C "$REPO" rev-parse HEAD)
mkdir -p "$REPO/.git/refs/remotes/origin"
git -C "$REPO" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
git -C "$REPO" branch tom/lower master
git -C "$REPO" -c user.email=test@test -c user.name=test \
  commit-tree -p "$OID_B" -m C "$(git -C "$REPO" rev-parse "HEAD^{tree}")" > "$PQ_HOME/.oidc"
OID_C=$(cat "$PQ_HOME/.oidc")
git -C "$REPO" update-ref refs/heads/tom/lower "$OID_C"
git -C "$REPO" update-ref refs/remotes/origin/tom/lower "$OID_C"

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
  rm -rf "$PQ_HOME/new" "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done"
  mkdir -p "$PQ_HOME/new" "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done"
}
reset_tasks

# A task built by hand, with the header cmd_add and naming write.
mk_task() {                             # state prio slug repo branch -> task_dir
  local st=$1 prio=$2 slug=$3 repo=$4 branch=$5
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


echo "== merged_into: the cheap arm (exact merge target) ==" >&2
reset_caches
cache_row "$REPO" tom/exact 1 MERGED "" master "$OID_B"
pr_merged_into "$REPO" tom/exact master && ok \
  || bad "a MERGED row into master is an exact match"
merged_into "$REPO" tom/exact master && ok \
  || bad "merged into master should be present in master"

echo "== merged_into: the ancestry arm ==" >&2
# The upper layer of a stack merged from its top: recorded as merged into the
# layer below, landed on master all the same. Exact matching calls this unmet
# and freezes the queue.
reset_caches
cache_row "$REPO" tom/upper 2 MERGED "" tom/lower "$OID_B"
{ pr_merged_into "$REPO" tom/upper master \
    && bad "pr_merged_into should still be exact - that is what makes it pure"; } || ok
merged_into "$REPO" tom/upper master && ok \
  || bad "a row into tom/lower whose merge commit is on master must count as merged into master"

# ...and the direction that must NOT be waved through: work that only exists on
# the lower branch is not in master, and must wait.
reset_caches
cache_row "$REPO" tom/stranded 3 MERGED "" tom/lower "$OID_C"
{ merged_into "$REPO" tom/stranded master \
    && bad "work only on tom/lower must NOT count as present in master"; } || ok

echo "== merged_into: fails closed ==" >&2
reset_caches
cache_row_v1 "$REPO" tom/legacy 5 MERGED "" tom/lower
{ merged_into "$REPO" tom/legacy master \
    && bad "a cached row with no merge oid must fail closed, not guess"; } || ok
reset_caches
cache_row "$REPO" tom/unknown-oid 6 MERGED "" tom/lower 0000000000000000000000000000000000000000
{ merged_into "$REPO" tom/unknown-oid master \
    && bad "an oid this repo does not have must fail closed"; } || ok
reset_caches
cache_row "$REPO" tom/nobase 7 MERGED "" master "$OID_B"
{ merged_into "$REPO" tom/nobase "" \
    && bad "an empty base must never read as met"; } || ok

echo "== base_fetch stays off unless the tick turns it on ==" >&2
# Proven by its own memo file: a no-op leaves nothing behind, and nothing here
# is allowed to reach the network.
rm -f "$PQ_HOME/.basefetch.$$"
base_fetch "$REPO" master
[ -f "$PQ_HOME/.basefetch.$$" ] && bad "base_fetch must be a no-op with PQ_FETCH_BASES unset" || ok
PQ_FETCH_BASES=1 base_fetch "$REPO" master
[ -f "$PQ_HOME/.basefetch.$$" ] && ok || bad "base_fetch should record its attempt when enabled"
PQ_FETCH_BASES=1 base_fetch "$REPO" master
eq "$(wc -l < "$PQ_HOME/.basefetch.$$" | tr -d ' ')" "1" "base_fetch memoises per (repo, base)"
rm -f "$PQ_HOME/.basefetch.$$"

echo "== task_base is the repo's default branch ==" >&2
reset_tasks
d=$(mk_task queue 10 plain "$REPO" tom/a)
eq "$(task_base "$d")" "master" "a task's base is its repo's default branch"
repo_base_reset
# An old `base:` header is ignored: nothing reads it any more.
awk '{ print } /^branch:/ { print "base:     tom/lower" }' "$d/plan.md" > "$d/plan.tmp" && mv "$d/plan.tmp" "$d/plan.md"
eq "$(hdr "$d/plan.md" base)" "tom/lower" "the fixture does carry an old base: header"
eq "$(task_base "$d")" "master" "...and task_base ignores it"
repo_base_reset
d=$(mk_task queue 12 nobase-repo "$REPO2/nope" tom/c)
eq "$(task_base "$d")" "" "unresolvable repo default reads empty, not a guess"
repo_base_reset

echo "== a blocker is judged against its repo's default branch ==" >&2
reset_tasks; reset_caches
cache_row "$REPO" tom/blocker 8 MERGED "" tom/lower "$OID_B"
mk_task "done" 20 blocker-owner "$REPO" tom/blocker >/dev/null
dep=$(mk_task queue 21 dep "$REPO" tom/dep1)
printf 'blocker-owner\t%s\ttom/blocker\n' "$REPO" > "$dep/after"
eq "$(after_state "$dep")" "met$(printf '\t')" "a blocker whose merge commit is on master is met"
repo_base_reset

reset_caches
cache_row "$REPO" tom/blocker 8 MERGED "" tom/lower "$OID_C"
case "$(after_state "$dep")" in
  on\ *) ok ;;
  *) bad "a blocker whose work is only on tom/lower is still waiting (got '$(after_state "$dep")')" ;;
esac
repo_base_reset

echo "== a cross-repo blocker keeps its OWN repo's default branch ==" >&2
# A blocker in another repo is judged against that repo's trunk - the
# dependent's default branch does not exist there.
reset_tasks; reset_caches
cache_row "$REPO2" ios/thing 9 MERGED "" trunk ""
mk_task "done" 30 ios-owner "$REPO2" ios/thing >/dev/null
dep3=$(mk_task queue 31 dep-cross-repo "$REPO" tom/dep3)
printf 'ios-owner\t%s\tios/thing\n' "$REPO2" > "$dep3/after"
eq "$(after_state "$dep3")" "met$(printf '\t')" "a cross-repo blocker merged into its own trunk is met"
repo_base_reset

echo "== reap_task judges against the default branch ==" >&2
reset_tasks; reset_caches
mk_reaped() {                           # prio slug branch -> dir (with a live worktree)
  local dir; dir=$(mk_task "done" "$1" "$2" "$REPO" "$3")
  local wt="$PQ_HOME/wt-$2"; mkdir -p "$wt"
  st_set "$dir" PQ_WORKTREE "$wt"
  printf '%s' "$dir"
}
# The upper layer of a stack merged from its top -> tear it down.
: > "$WT_LOG"
r1=$(mk_reaped 40 reap-upper tom/reap1)
cache_row "$REPO" tom/reap1 11 MERGED "" tom/lower "$OID_B"
PIDX_OK=1 reap_task "$r1" 0 >/dev/null 2>&1
eq "$([ -n "$(st "$r1" PQ_MERGED)" ] && printf yes || printf no)" "yes" \
  "reap: a merge whose commit is on master counts as merged"
grep -q "rm" "$WT_LOG" && ok || bad "reap: should have asked wt to remove the worktree"
repo_base_reset

# The same PR state, but its merge commit never reached master -> left alone.
: > "$WT_LOG"
reset_caches
r2=$(mk_reaped 41 reap-stranded tom/reap2)
cache_row "$REPO" tom/reap2 12 MERGED "" tom/lower "$OID_C"
PIDX_OK=1 reap_task "$r2" 0 >/dev/null 2>&1
eq "$([ -n "$(st "$r2" PQ_MERGED)" ] && printf yes || printf no)" "no" \
  "reap: a merge that is not on the default branch must not count"
eq "$([ -s "$WT_LOG" ] && printf called || printf quiet)" "quiet" \
  "reap: must not touch a worktree whose work is not on the default branch"
repo_base_reset

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
