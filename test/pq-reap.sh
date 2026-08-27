#!/usr/bin/env bash
# test/pq-reap.sh - tearing a task down once its PR has merged, exercised
# directly against reap_ok / reap_watching / reap_task / pr_targets, the same
# way test/pq-after.sh exercises the blocker predicate.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PQ_HOME=$(mktemp -d)
export PQ_HOME

# Stub `claude`, `gh`, and `herdr` so nothing here ever makes a real network (or
# real-herdr-socket) call - same reasoning as test/pq-after.sh. `herdr` answers
# an empty pane snapshot: every case in this file either calls `reap_task`
# directly (which never touches herdr) or steers `pane_state` by priming PIDX
# by hand before going through `tick_body`, so the snapshot's actual content
# never matters - only that `pidx_load` gets valid JSON back instead of hitting
# a real socket.
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

# A `wt` stub, wired in through PQ_WT so the real wt script never runs. Records
# one line per call: the cwd it was invoked from, then its arguments, tab
# separated - enough to confirm both WHAT reap_task asked for and WHERE.
WT_LOG="$STUBBIN/.wt-calls"
: > "$WT_LOG"
cat > "$STUBBIN/wt-stub" <<EOF
#!/bin/sh
{ printf '%s\t' "\$PWD"; for a in "\$@"; do printf '%s\t' "\$a"; done; printf '\n'; } >> "$WT_LOG"
exit "\${WT_STUB_RC:-0}"
EOF
chmod +x "$STUBBIN/wt-stub"
export PQ_WT="$STUBBIN/wt-stub"

# shellcheck source=/dev/null
source "$HERE/../.local/bin/pq"

# Every tick_body-level test in this file hand-primes PR_CACHE/PR_ANS itself
# (reset_caches/cache_row below, same idiom pq-after.sh uses for the pure
# predicates) and must not have it clobbered by a real `pr_load_all` round
# trip through `gh` - so it is neutered for the whole file. Direct `reap_task`
# calls never go through it at all.
pr_load_all() { :; }

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }

cleanup() { rm -rf "$PQ_HOME" "$STUBBIN" "${REPO:-}" "${REPO2:-}" "${SOCKDIR:-}"; }
trap cleanup EXIT

# Declared up front (not just inside the python3-gated block below) so later
# references under `set -u` never hit an unbound variable when python3 is
# unavailable and that block is skipped.
SOCKDIR=""

# ── two real, throwaway git repos ───────────────────────────────────────────
# repo_base mirrors wt's base_ref, which reads a real remote-tracking symbolic
# ref - so a fake path is not enough. REPO has one faked by hand, offline;
# REPO2 deliberately does not, for the "default branch unresolvable" case.
REPO=$(mktemp -d)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$REPO/.git/refs/remotes/origin"
git -C "$REPO" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master

REPO2=$(mktemp -d)
git init -q -b trunk "$REPO2"
git -C "$REPO2" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
# No refs/remotes/origin/* at all, and no local main/master either - repo_base
# has nothing to resolve from, and the stubbed `gh` fails too.

reset_caches() { PR_CACHE="$PQ_HOME/.test.pr"; PR_ANS="$PQ_HOME/.test.ans"; : > "$PR_CACHE"; : > "$PR_ANS"; }
cache_row() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$PR_CACHE"; }   # repo branch num state draft base
reset_wt_log() { : > "$WT_LOG"; }

reset_tasks() {
  rm -rf "$PQ_HOME/queue" "$PQ_HOME/hold" "$PQ_HOME/running" "$PQ_HOME/done"
  mkdir -p "$PQ_HOME/queue" "$PQ_HOME/hold" "$PQ_HOME/running" "$PQ_HOME/done"
}
reset_tasks

# A done task built by hand, bypassing the real dispatch path - just enough of
# plan.md for hdr()/state_of() to work, plus PQ_WORKTREE set to whatever path
# the case needs (a real directory for a "live" worktree, anything else for
# "already gone").
mk_done() {                             # prio slug repo branch worktree_path -> task_dir
  local prio=$1 slug=$2 repo=$3 branch=$4 wt=$5
  # $prio is relative order, not a stamp - it is offset into the real
  # (non-urgent) range so a fixture never accidentally reads as --urgent.
  # $((10#$prio)) rather than a bare $prio: inside $(( )) a leading-zero
  # literal like 020 is octal, exactly the bug this fixture must not
  # reintroduce.
  local dir="$PQ_HOME/done/$(printf '%014d' $(( 20260101000000 + 10#$prio )))-$slug"
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
  st_set "$dir" PQ_WORKTREE "$wt"
  printf '%s' "$dir"
}

# A clean baseline regardless of the ambient environment this happens to run
# in (this IS a Herdr-managed dev box) - every case sets exactly what it needs.
unset HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID

echo "== reap_ok: the pass's own precondition ==" >&2
if ! command -v python3 >/dev/null 2>&1; then
  printf 'SKIP: python3 not on PATH - cannot bind a real socket for reap_ok\n' >&2
else
  SOCKDIR=$(mktemp -d)
  SOCKPATH="$SOCKDIR/test.sock"
  python3 - "$SOCKPATH" <<'PYEOF' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.listen(1)
time.sleep(20)
PYEOF
  SOCK_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$SOCKPATH" ] && break; sleep 0.2; done

  PIDX_OK=1 HERDR_ENV=1 HERDR_SOCKET_PATH="$SOCKPATH" reap_ok \
    && ok || bad "reap_ok should pass with PIDX_OK, HERDR_ENV, and a live socket all set"
  PIDX_OK=0 HERDR_ENV=1 HERDR_SOCKET_PATH="$SOCKPATH" reap_ok \
    && bad "reap_ok should fail when herdr never answered the snapshot (PIDX_OK=0)" || ok
  PIDX_OK=1 HERDR_ENV= HERDR_SOCKET_PATH="$SOCKPATH" reap_ok \
    && bad "reap_ok should fail without HERDR_ENV - a plain terminal, not a Herdr pane" || ok
  PIDX_OK=1 HERDR_ENV=1 HERDR_SOCKET_PATH="$SOCKDIR/no-such-socket" reap_ok \
    && bad "reap_ok should fail when the socket path names nothing live" || ok

  kill "$SOCK_PID" 2>/dev/null; wait "$SOCK_PID" 2>/dev/null
fi

echo "== MERGED into base, agent idle: torn down ==" >&2
reset_caches; reset_wt_log
wt1=$(mktemp -d)
d1=$(mk_done 10 case1 "$REPO" tom/case1 "$wt1")
st_set "$d1" PQ_PANE pane-1
cache_row "$REPO" tom/case1 1 MERGED "" master
PIDX_OK=1; PIDX=$'pane-1\tclaude\tidle'
reap_task "$d1" 0
rc=$?
[ "$rc" -eq 0 ] && ok || bad "a merged, idle task should report a teardown (rc=$rc)"
grep -q "$(printf '%s\t' "$(cd "$REPO" && pwd)")" "$WT_LOG" \
  && ok || bad "wt should have run in the repo's cwd (log: $(cat "$WT_LOG"))"
grep -q "$(printf 'rm\t--yes\ttom/case1\t')" "$WT_LOG" \
  && ok || bad "wt should have been called as rm --yes tom/case1 (log: $(cat "$WT_LOG"))"
[ -n "$(st "$d1" PQ_MERGED)" ] && ok || bad "PQ_MERGED should be stamped"
[ -n "$(st "$d1" PQ_REAPED)" ] && ok || bad "PQ_REAPED should be stamped"
rm -rf "$wt1"

echo "== MERGED into some other branch: still just waiting ==" >&2
reset_caches; reset_wt_log
wt2=$(mktemp -d)
d2=$(mk_done 10 case2 "$REPO" tom/case2 "$wt2")
cache_row "$REPO" tom/case2 2 MERGED "" develop
PIDX_OK=1; PIDX=""
reap_task "$d2" 0
rc=$?
[ "$rc" -ne 0 ] && ok || bad "merged into the wrong base must not report a teardown"
[ ! -s "$WT_LOG" ] && ok || bad "wt must never be invoked for the wrong base"
[ -z "$(st "$d2" PQ_MERGED)" ] && ok || bad "PQ_MERGED must not be stamped for the wrong base"
rm -rf "$wt2"

echo "== MERGED, pane working: held, warns once ==" >&2
reset_caches; reset_wt_log
wt3=$(mktemp -d)
d3=$(mk_done 10 case3 "$REPO" tom/case3 "$wt3")
st_set "$d3" PQ_PANE pane-3
cache_row "$REPO" tom/case3 3 MERGED "" master
PIDX_OK=1; PIDX=$'pane-3\tclaude\tworking'
first=$(reap_task "$d3" 0 2>&1 1>/dev/null); rc1=$?
[ "$rc1" -ne 0 ] && ok || bad "held on a working agent must not report a teardown"
[ ! -s "$WT_LOG" ] && ok || bad "wt must never be invoked while the agent is working"
eq "$(st "$d3" PQ_REAP_HELD)" "agent" "PQ_REAP_HELD should read agent"
case "$first" in *"holding"*) ok ;; *) bad "first pass should warn about the hold (got '$first')" ;; esac
second=$(reap_task "$d3" 0 2>&1 1>/dev/null)
[ -z "$second" ] && ok || bad "a second pass with no change must stay silent (got '$second')"

echo "== MERGED, pane working then idle: cleared, then reaped ==" >&2
reset_caches
cache_row "$REPO" tom/case3 3 MERGED "" master
PIDX_OK=1; PIDX=$'pane-3\tclaude\tidle'
reap_task "$d3" 0
rc=$?
[ "$rc" -eq 0 ] && ok || bad "once idle, the held task should now be torn down (rc=$rc)"
[ -s "$WT_LOG" ] && ok || bad "wt should have been invoked once the hold cleared"
eq "$(st "$d3" PQ_REAP_HELD)" "" "PQ_REAP_HELD should be cleared"
[ -n "$(st "$d3" PQ_REAPED)" ] && ok || bad "PQ_REAPED should be stamped once reaped"
rm -rf "$wt3"

echo "== MERGED, pq running in the task's own workspace: held as 'here' ==" >&2
reset_caches; reset_wt_log
wt5=$(mktemp -d)
d5=$(mk_done 10 case5 "$REPO" tom/case5 "$wt5")
st_set "$d5" PQ_PANE pane-5
st_set "$d5" PQ_WORKSPACE wsX
cache_row "$REPO" tom/case5 5 MERGED "" master
PIDX_OK=1; PIDX=$'pane-5\tclaude\tidle'   # idle - proves 'here' outranks the agent check, not just stands in for it
HERDR_WORKSPACE_ID=wsX
reap_task "$d5" 0
rc=$?
[ "$rc" -ne 0 ] && ok || bad "held on pq's own workspace must not report a teardown"
[ ! -s "$WT_LOG" ] && ok || bad "wt must never be invoked while pq sits in this task's workspace"
eq "$(st "$d5" PQ_REAP_HELD)" "here" "PQ_REAP_HELD should read here"
unset HERDR_WORKSPACE_ID
rm -rf "$wt5"

echo "== MERGED, repo_base unresolvable: held as 'nobase', then resolves ==" >&2
reset_caches; reset_wt_log
wt6=$(mktemp -d)
d6=$(mk_done 10 case6 "$REPO2" tom/case6 "$wt6")
st_set "$d6" PQ_PANE pane-6
PIDX_OK=1; PIDX=$'pane-6\tclaude\tidle'
reap_task "$d6" 0
rc=$?
[ "$rc" -ne 0 ] && ok || bad "an unresolvable default branch must not report a teardown"
[ ! -s "$WT_LOG" ] && ok || bad "wt must never be invoked with no base to check against"
[ -z "$(st "$d6" PQ_MERGED)" ] && ok || bad "PQ_MERGED must not be stamped with no base"
eq "$(st "$d6" PQ_REAP_HELD)" "nobase" "PQ_REAP_HELD should read nobase"

# Now the base resolves. repo_base memoises per-process, so a fresh tick's
# clean slate has to be simulated explicitly here.
mkdir -p "$REPO2/.git/refs/remotes/origin"
git -C "$REPO2" update-ref refs/remotes/origin/trunk refs/heads/trunk
git -C "$REPO2" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
repo_base_reset
reset_caches
cache_row "$REPO2" tom/case6 6 MERGED "" trunk
reap_task "$d6" 0
rc=$?
[ "$rc" -eq 0 ] && ok || bad "once the base resolves and the PR is merged, it should be torn down (rc=$rc)"
[ -s "$WT_LOG" ] && ok || bad "wt should have been invoked once the base resolved"
eq "$(st "$d6" PQ_REAP_HELD)" "" "PQ_REAP_HELD should be cleared once resolved"
[ -n "$(st "$d6" PQ_REAPED)" ] && ok || bad "PQ_REAPED should be stamped"
rm -rf "$wt6"

echo "== every PR CLOSED: left alone, warns once ==" >&2
reset_caches; reset_wt_log
wt7=$(mktemp -d)
d7=$(mk_done 10 case7 "$REPO" tom/case7 "$wt7")
cache_row "$REPO" tom/case7 7 CLOSED "" master
PIDX_OK=1; PIDX=""
first=$(reap_task "$d7" 0 2>&1 1>/dev/null); rc1=$?
[ "$rc1" -ne 0 ] && ok || bad "an every-PR-closed task must not report a teardown"
[ ! -s "$WT_LOG" ] && ok || bad "wt must never be invoked for a closed-without-merging task"
[ -n "$(st "$d7" PQ_CLOSED)" ] && ok || bad "PQ_CLOSED should be stamped"
case "$first" in *"closed"*) ok ;; *) bad "should warn once about the closed PR (got '$first')" ;; esac
second=$(reap_task "$d7" 0 2>&1 1>/dev/null)
[ -z "$second" ] && ok || bad "a second pass on an already-closed task must stay silent (got '$second')"
eq "$(agent_cell "$d7" done)" "closed" "agent_cell should surface a closed-without-merging task rather than reading as settled"
rm -rf "$wt7"

echo "== PR still OPEN: not yet, still watched ==" >&2
reset_caches; reset_wt_log
wt8=$(mktemp -d)
d8=$(mk_done 10 case8 "$REPO" tom/case8 "$wt8")
cache_row "$REPO" tom/case8 8 OPEN "" master
PIDX_OK=1; PIDX=""
reap_task "$d8" 0
rc=$?
[ "$rc" -ne 0 ] && ok || bad "an open PR must not report a teardown"
[ ! -s "$WT_LOG" ] && ok || bad "wt must never be invoked while the PR is still open"
[ -z "$(st "$d8" PQ_MERGED)" ] && [ -z "$(st "$d8" PQ_CLOSED)" ] && [ -z "$(st "$d8" PQ_REAPED)" ] \
  && ok || bad "nothing should be stamped while still in review"
reap_watching "$d8" && ok || bad "reap_watching should still be true - nothing terminal is set"
case "$(pr_targets running)" in
  *"$(printf '%s\t%s' "$REPO" tom/case8)"*) ok ;;
  *) bad "pr_targets running should still list an unresolved done task's branch" ;;
esac
rm -rf "$wt8"

echo "== a VERDICT marker: pr_targets running stops listing it (regression) ==" >&2
# PQ_REAPED is deliberately not in this list any more. It says the worktree is
# gone, which is silent about whether the pull request merged - and treating it
# as terminal is what stopped a task being watched through the window where its
# merge actually landed. Only a verdict ends the watch; the PQ_REAPED case is
# asserted on its own below.
for marker in PQ_MERGED PQ_CLOSED; do
  reset_caches
  wtN=$(mktemp -d)
  dN=$(mk_done 20 "term-$marker" "$REPO" "tom/term-$marker" "$wtN")
  cache_row "$REPO" "tom/term-$marker" 9 OPEN "" master
  case "$(pr_targets running)" in
    *"$(printf '%s\t%s' "$REPO" "tom/term-$marker")"*) ok ;;
    *) bad "$marker: should be listed before any terminal marker is set" ;;
  esac
  st_set "$dN" "$marker" "$(now)"
  reap_watching "$dN" && bad "$marker: reap_watching should now be false" || ok
  case "$(pr_targets running)" in
    *"$(printf '%s\t%s' "$REPO" "tom/term-$marker")"*)
      bad "$marker: pr_targets running should no longer list this branch - the forever-poll regression" ;;
    *) ok ;;
  esac
  rm -rf "$wtN" "$dN"
done

# The other half of the same rule: reaped, with no verdict, must STAY listed.
reset_caches
wtR=$(mktemp -d)
dR=$(mk_done 20 term-reaped-only "$REPO" tom/term-reaped-only "$wtR")
cache_row "$REPO" tom/term-reaped-only 9 OPEN "" master
st_set "$dR" PQ_REAPED "$(now)"
reap_watching "$dR" && ok || bad "PQ_REAPED alone must not end the watch - there is no verdict yet"
case "$(pr_targets running)" in
  *"$(printf '%s\t%s' "$REPO" tom/term-reaped-only)"*) ok ;;
  *) bad "a reaped row with no verdict must stay in pr_targets, or its merge is never seen" ;;
esac
rm -rf "$wtR" "$dR"

echo "== PQ_WORKTREE gone from disk, gh silent: nothing stamped, still watching ==" >&2
reset_caches; reset_wt_log
d10=$(mk_done 10 case10 "$REPO" tom/case10 "$PQ_HOME/no-such-worktree-anywhere")
# No cache_row at all - gh never answered, so no verdict is there to record.
reap_task "$d10" 0
rc=$?
[ "$rc" -ne 0 ] && ok || bad "a gone worktree must not itself report a teardown"
[ ! -s "$WT_LOG" ] && ok || bad "wt must never be invoked when the worktree is already gone"
# Inverted deliberately. This used to stamp PQ_REAPED here, which read "stop
# asking" - so a task whose worktree vanished while gh was unreachable, or while
# its pull request was simply still open, was written off before any verdict
# existed. With nothing to record, the right move is to record nothing.
[ -z "$(st "$d10" PQ_REAPED)" ] && ok || bad "nothing is settled yet, so PQ_REAPED must not be stamped"
[ -z "$(st "$d10" PQ_MERGED)" ] && [ -z "$(st "$d10" PQ_CLOSED)" ] \
  && ok || bad "no verdict should be stamped when gh never answered"
reap_watching "$d10" && ok || bad "it must stay watched until gh does answer"
archivable "$d10" && bad "with no verdict it must not be archivable" || ok

echo "== PQ_WORKTREE gone from disk, cache says MERGED: the verdict is recorded, not thrown away ==" >&2
reset_caches; reset_wt_log
d10m=$(mk_done 11 case10m "$REPO" tom/case10m "$PQ_HOME/no-such-worktree-anywhere")
# The row is already sitting in the cache the tick paid for (reap_watching
# kept it in pr_targets running) - this is exactly what section 3 of the plan
# fixes: the old code stamped PQ_REAPED and returned before ever looking.
cache_row "$REPO" tom/case10m 10 MERGED "" master
reap_task "$d10m" 0
rc=$?
[ "$rc" -ne 0 ] && ok || bad "a gone worktree must not itself report a teardown"
[ ! -s "$WT_LOG" ] && ok || bad "wt must never be invoked when the worktree is already gone"
[ -n "$(st "$d10m" PQ_REAPED)" ] && ok || bad "PQ_REAPED should be stamped"
[ -n "$(st "$d10m" PQ_MERGED)" ] && ok || bad "PQ_MERGED should be stamped from the already-loaded cache"
archivable "$d10m" && ok || bad "merged+reaped should now be archivable"

echo "== PQ_WORKTREE gone from disk, cache says every PR CLOSED: PQ_CLOSED recorded too ==" >&2
reset_caches; reset_wt_log
d10c=$(mk_done 12 case10c "$REPO" tom/case10c "$PQ_HOME/no-such-worktree-anywhere")
cache_row "$REPO" tom/case10c 11 CLOSED "" master
reap_task "$d10c" 0
rc=$?
[ "$rc" -ne 0 ] && ok || bad "a gone worktree must not itself report a teardown"
[ ! -s "$WT_LOG" ] && ok || bad "wt must never be invoked when the worktree is already gone"
[ -n "$(st "$d10c" PQ_REAPED)" ] && ok || bad "PQ_REAPED should be stamped"
[ -n "$(st "$d10c" PQ_CLOSED)" ] && ok || bad "PQ_CLOSED should be stamped from the already-loaded cache"
archivable "$d10c" && ok || bad "closed should now be archivable"

echo "== gh down (no rows, no PR_ANS): nothing stamped, retries next pass ==" >&2
reset_caches; reset_wt_log
wt11=$(mktemp -d)
d11=$(mk_done 10 case11 "$REPO" tom/case11 "$wt11")
# reset_caches alone: no cache_row, no ans_row - gh never answered at all.
reap_task "$d11" 0
rc=$?
[ "$rc" -ne 0 ] && ok || bad "gh-down must not report a teardown"
[ ! -s "$WT_LOG" ] && ok || bad "wt must never be invoked when gh has not answered"
[ -z "$(st "$d11" PQ_MERGED)" ] && [ -z "$(st "$d11" PQ_CLOSED)" ] && [ -z "$(st "$d11" PQ_REAPED)" ] \
  && ok || bad "nothing should be stamped when gh has not answered"
rm -rf "$wt11"

echo "== --dry-run: prints, stamps nothing, invokes nothing ==" >&2
reset_caches; reset_wt_log
wt13=$(mktemp -d)
d13=$(mk_done 10 case13 "$REPO" tom/case13 "$wt13")
st_set "$d13" PQ_PANE pane-13
cache_row "$REPO" tom/case13 13 MERGED "" master
PIDX_OK=1; PIDX=$'pane-13\tclaude\tidle'
before=$(cat "$d13/state.env" 2>/dev/null)
out=$(reap_task "$d13" 1 2>&1 1>/dev/null)
rc=$?
after=$(cat "$d13/state.env" 2>/dev/null)
[ "$rc" -ne 0 ] && ok || bad "--dry-run must never report an actual teardown"
eq "$rc" "2" "a would-tear-down should return 2, the signal tick_body counts separately from an actual teardown"
[ ! -s "$WT_LOG" ] && ok || bad "--dry-run must never invoke wt"
eq "$before" "$after" "--dry-run must leave state.env exactly as it was"
case "$out" in *"would tear down case13 (tom/case13)"*) ok ;; *) bad "should print the would-tear-down message (got '$out')" ;; esac
rm -rf "$wt13"

echo "== --dry-run on a held task: rc=1, distinct from a would-tear-down ==" >&2
reset_caches; reset_wt_log
wt13h=$(mktemp -d)
d13h=$(mk_done 10 case13h "$REPO" tom/case13h "$wt13h")
st_set "$d13h" PQ_PANE pane-13h
cache_row "$REPO" tom/case13h 13 MERGED "" master
PIDX_OK=1; PIDX=$'pane-13h\tclaude\tworking'
out=$(reap_task "$d13h" 1 2>&1 1>/dev/null)
rc=$?
eq "$rc" "1" "a held task's dry-run must not return 2 - nothing would actually tear down yet"
[ -z "$(st "$d13h" PQ_REAP_HELD)" ] && ok || bad "--dry-run must not stamp PQ_REAP_HELD either"
case "$out" in *"would leave case13h alone"*) ok ;; *) bad "should print the would-leave-alone message (got '$out')" ;; esac
rm -rf "$wt13h"

echo "== wt rm exits non-zero: PQ_REAPED not stamped, next pass retries ==" >&2
reset_caches; reset_wt_log
wt14=$(mktemp -d)
d14=$(mk_done 10 case14 "$REPO" tom/case14 "$wt14")
st_set "$d14" PQ_PANE pane-14
cache_row "$REPO" tom/case14 14 MERGED "" master
PIDX_OK=1; PIDX=$'pane-14\tclaude\tidle'
WT_STUB_RC=1 reap_task "$d14" 0
rc=$?
[ "$rc" -ne 0 ] && ok || bad "a failing wt rm must not report a teardown"
[ -s "$WT_LOG" ] && ok || bad "wt should still have been invoked (and failed)"
[ -z "$(st "$d14" PQ_REAPED)" ] && ok || bad "PQ_REAPED must not be stamped when wt rm fails"
[ -n "$(st "$d14" PQ_MERGED)" ] && ok || bad "PQ_MERGED should still be recorded even though wt rm failed"
rm -rf "$wt14"

echo "== reap_ok false: the whole pass is skipped by tick_body ==" >&2
reset_tasks
reset_caches; reset_wt_log
wt12=$(mktemp -d)
d12=$(mk_done 10 case12 "$REPO" tom/case12 "$wt12")
cache_row "$REPO" tom/case12 12 MERGED "" master
unset HERDR_ENV HERDR_SOCKET_PATH
tick_body 0 0 >/dev/null 2>&1
[ ! -s "$WT_LOG" ] && ok || bad "reap_ok=false must mean tick_body never calls wt"
[ -z "$(st "$d12" PQ_MERGED)" ] && ok || bad "reap_ok=false must mean tick_body stamps nothing"
rm -rf "$wt12"

echo "== tick_body wiring: torn-down count and the held-pane note ==" >&2
reset_tasks
reset_caches; reset_wt_log
wtA=$(mktemp -d)
dA=$(mk_done 10 tickA "$REPO" tom/tickA "$wtA")
st_set "$dA" PQ_PANE pane-A
cache_row "$REPO" tom/tickA 20 MERGED "" master
PIDX_OK=1; PIDX=$'pane-A\tclaude\tidle'
HERDR_ENV=1
HERDR_SOCKET_PATH="$SOCKDIR/wired-fake"   # reap_ok itself is redefined below - contents unchecked
reap_ok() { return 0; }                  # exercise tick_body's wiring, not the environment gate again
PQ_SUMMARY=""
tick_body 0 0 >/dev/null 2>&1
case "$PQ_SUMMARY" in *", 1 torn down"*) ok ;; *) bad "summary should report 1 torn down (got '$PQ_SUMMARY')" ;; esac
[ -s "$WT_LOG" ] && ok || bad "wt should have been invoked via tick_body's own reap pass"
rm -rf "$wtA"

reset_tasks
reset_caches; reset_wt_log
wtB=$(mktemp -d)
dB=$(mk_done 10 tickB "$REPO" tom/tickB "$wtB")
cache_row "$REPO" tom/tickB 21 MERGED "" master
reap_ok() { return 1; }                  # gate closed, but done/ still has something merged and unreaped
PQ_SUMMARY=""
tick_body 0 0 >/dev/null 2>&1
case "$PQ_SUMMARY" in *"teardown needs a herdr pane"*) ok ;; *) bad "summary should note the closed gate (got '$PQ_SUMMARY')" ;; esac
[ ! -s "$WT_LOG" ] && ok || bad "wt must not be invoked while the gate is closed"
rm -rf "$wtB"

reset_tasks
reset_caches; reset_wt_log
wtC=$(mktemp -d)
dC=$(mk_done 10 tickC "$REPO" tom/tickC "$wtC")
st_set "$dC" PQ_PANE pane-C
cache_row "$REPO" tom/tickC 22 MERGED "" master
PIDX_OK=1; PIDX=$'pane-C\tclaude\tidle'
reap_ok() { return 0; }
PQ_SUMMARY=""
tick_body 0 1 >/dev/null 2>&1   # dry=1
case "$PQ_SUMMARY" in *", 1 would tear down"*) ok ;; *) bad "dry-run summary should report a would-be teardown (got '$PQ_SUMMARY')" ;; esac
[ ! -s "$WT_LOG" ] && ok || bad "a dry-run tick must never invoke wt"
[ -z "$(st "$dC" PQ_MERGED)" ] && ok || bad "a dry-run tick must stamp nothing"
rm -rf "$wtC"

echo "== repo gone: a specific diagnosis, not a generic wt-rm-failed ==" >&2
reset_caches; reset_wt_log
wt15=$(mktemp -d)
d15=$(mk_done 10 case15 "$PQ_HOME/no-such-repo-anywhere" tom/case15 "$wt15")
out=$(reap_task "$d15" 0 2>&1 1>/dev/null)
rc=$?
[ "$rc" -ne 0 ] && ok || bad "a gone repo must not report a teardown"
[ ! -s "$WT_LOG" ] && ok || bad "wt must never be invoked when the repo itself is gone"
case "$out" in *"repo"*"is gone"*) ok ;; *) bad "should name the repo as gone, not a generic wt-rm failure (got '$out')" ;; esac
rm -rf "$wt15"

echo "== a worktree gone while the PR is still open keeps its verdict alive ==" >&2
# The nine-minute window, as a test. sup-7-centralize-video-output was reaped at
# 16:22:17 with its pull request still open, and merged at 16:31:26 - by which
# time PQ_REAPED had already taken it out of pr_targets, so PQ_MERGED was never
# stamped and archivable() could never be true. It sat in done/ for eight days.
reset_tasks; reset_caches; reset_wt_log
d16=$(mk_done 16 wt-gone-pr-open "$REPO" tom/case16 "$PQ_HOME/no-such-worktree")
cache_row "$REPO" tom/case16 16 OPEN "" master        # still in review
reap_task "$d16" 0 >/dev/null 2>&1
eq "$(st "$d16" PQ_REAPED)" "" "an open PR must NOT be stamped reaped just because the worktree went"
eq "$(st "$d16" PQ_MERGED)" "" "and no verdict is invented"
reap_watching "$d16" && ok || bad "it must stay watched, or its merge lands with nobody listening"

# ...and the message is once-only, since this can last for days.
first=$(reap_task "$d16" 0 2>&1 >/dev/null | grep -c "still watching")
second=$(reap_task "$d16" 0 2>&1 >/dev/null | grep -c "still watching")
eq "$first"  "0" "the worktree-gone notice does not repeat once stamped"
eq "$second" "0" "...and stays quiet"

# Now the merge lands, exactly as it did nine minutes later.
reset_caches
cache_row "$REPO" tom/case16 16 MERGED "" master
reap_task "$d16" 0 >/dev/null 2>&1
[ -n "$(st "$d16" PQ_MERGED)" ] && ok || bad "the merge that arrives later must still be recorded"
[ -n "$(st "$d16" PQ_REAPED)" ] && ok || bad "and reaped stamped alongside it"
archivable "$d16" && ok || bad "which is what finally lets it leave done/"
eq "$([ -s "$WT_LOG" ] && printf called || printf quiet)" "quiet" \
  "wt is never invoked for a worktree that is already gone"

echo "== a row stranded by the old rule heals itself ==" >&2
# PQ_REAPED with no verdict is exactly the state the four stuck rows were in.
# Nothing hand-repairs them: they simply become watchable again and the next
# tick that reaches a verdict records it.
reset_tasks; reset_caches; reset_wt_log
d17=$(mk_done 17 stranded "$REPO" tom/case17 "$PQ_HOME/gone-too")
st_set "$d17" PQ_REAPED "2026-08-18T16:22:17Z"        # stamped, no verdict
reap_watching "$d17" && ok || bad "a reaped row with no verdict must be watched again"
cache_row "$REPO" tom/case17 17 MERGED "" master
reap_task "$d17" 0 >/dev/null 2>&1
[ -n "$(st "$d17" PQ_MERGED)" ] && ok || bad "the stranded row must pick up its verdict"
archivable "$d17" && ok || bad "and become archivable without being touched by hand"

# A settled row is still left alone, and still costs no gh call.
reset_tasks; reset_caches
d18=$(mk_done 18 settled "$REPO" tom/case18 "$PQ_HOME/gone3")
st_set "$d18" PQ_MERGED "2026-08-01T00:00:00Z"; st_set "$d18" PQ_REAPED "2026-08-01T00:00:01Z"
reap_watching "$d18" && bad "a merged+reaped row must stop being watched" || ok
reap_task "$d18" 0; eq "$?" "1" "...and reap_task leaves it alone"
d19=$(mk_done 19 closed-row "$REPO" tom/case19 "$PQ_HOME/gone4")
st_set "$d19" PQ_CLOSED "2026-08-01T00:00:00Z"
reap_watching "$d19" && bad "a closed row must stop being watched" || ok

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
