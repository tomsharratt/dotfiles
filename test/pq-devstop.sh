#!/usr/bin/env bash
# test/pq-devstop.sh - a task's dev server is stopped once its pull request is
# marked ready.
#
# Why: every dispatched task runs a foreman stack (puma, sidekiq, the css and js
# watchers) so its agent can verify and screenshot its work - and that work is
# finished once the pull request is ready. Left running, the stacks pile up
# behind every pull request waiting on review, which is most of them. So the
# tick runs `wt stop` on a ready task's worktree, once.
#
# Once is the point: a server started afterwards - Tom with `wt open`, the agent
# with `wt restart` for a CI failure or a review - was started on purpose, and
# the next tick must not take it down again.
#
# Exercised directly against devstop_task, then once through tick_body, with
# the same `wt` stub (through PQ_WT) and PIDX priming as test/pq-reap.sh.
#
# SC2034: the knobs, caches and herdr variables set here are read by the pq sourced below.
# SC2015: `ok` never fails, so `[ ... ] && ok || bad` is an if/else.
# shellcheck disable=SC2034,SC2015
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Every path this file writes to or removes is under one mktemp directory, kept in
# a variable of its own (T_ROOT) that pq never reads or reassigns - the cleanup
# removes only that. HOME, XDG_STATE_HOME and pq's own overrides all point inside
# it BEFORE pq is sourced, since pq computes PQ_HOME and PLANS_DIR from them at load
# time; and after the source each one is checked, so a pq that one day resolves a
# path differently stops this file rather than letting it touch the real ones.
# shellcheck source=test/sandbox.sh
source "$HERE/sandbox.sh"
T_ROOT=$(mktemp -d)
export HOME="$T_ROOT/home" XDG_STATE_HOME="$T_ROOT/state" XDG_CONFIG_HOME="$T_ROOT/config"
T_PQ="$T_ROOT/pq"; export PQ_HOME="$T_PQ" PQ_PLANS_DIR="$T_ROOT/plans"
mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME" "$PQ_HOME" "$PQ_PLANS_DIR"

STUBBIN="$T_ROOT/bin"
mkdir -p "$STUBBIN"
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

# The wt stub records the cwd it ran in and its arguments, tab separated.
WT_LOG="$STUBBIN/.wt-calls"
: > "$WT_LOG"
cat > "$STUBBIN/wt-stub" <<EOF
#!/bin/sh
{ printf '%s\t' "\$PWD"; for a in "\$@"; do printf '%s\t' "\$a"; done; printf '\n'; } >> "$WT_LOG"
[ -n "\${WT_STUB_ERR:-}" ] && printf '%s\n' "\$WT_STUB_ERR" >&2
exit "\${WT_STUB_RC:-0}"
EOF
chmod +x "$STUBBIN/wt-stub"
export PQ_WT="$STUBBIN/wt-stub"

# shellcheck source=/dev/null
source "$HERE/../.local/bin/pq"
pr_load_all() { :; }
sandbox_guard

[ "$PQ_HOME" = "$T_PQ" ] || { printf 'ABORT: pq resolved PQ_HOME=%s, not %s\n' "$PQ_HOME" "$T_PQ" >&2; sandbox_cleanup; exit 1; }
for p in "$PQ_HOME" "$PLANS_DIR" "$HOME"; do
  case "$p" in
    "$T_ROOT"/*) ;;
    *) printf 'ABORT: pq resolved %s, outside this test'"'"'s temp dir %s - refusing to run\n' "$p" "$T_ROOT" >&2
       sandbox_cleanup; exit 1 ;;
  esac
done

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }
has() { case "$1" in *"$2"*) ok ;; *) bad "$3 (got '$1')" ;; esac; }

cleanup() { sandbox_cleanup; }
trap cleanup EXIT
unset HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID

REPO="$T_ROOT/repo"
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$REPO/.git/refs/remotes/origin"
git -C "$REPO" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
WTS="$T_ROOT/worktrees"; mkdir -p "$WTS"

reset_tasks() {
  rm -rf "$T_PQ/new" "$T_PQ/queue" "$T_PQ/running" "$T_PQ/done"
  mkdir -p "$T_PQ/new" "$T_PQ/queue" "$T_PQ/running" "$T_PQ/done"
}
reset_wt_log() { : > "$WT_LOG"; }
reset_caches() { PR_CACHE="$T_PQ/.test.pr"; PR_ANS="$T_PQ/.test.ans"; : > "$PR_CACHE"; : > "$PR_ANS"; }

# A done task whose review gate has reached $2, with a live worktree and a pane
# Herdr reports as $3. Leaves the task directory in $d, rather than printing it for a
# command substitution, because the pane index it primes has to survive into the
# caller's shell.
n=0
mk_ready() {                            # slug review-state pane-state -> $d
  local slug=$1 dir wt
  n=$((n + 1))
  dir="$T_PQ/done/$(printf '%014d' $(( 20260101000000 + n )))-$slug"
  wt="$WTS/$slug"; mkdir -p "$dir" "$wt"
  {
    printf -- '---\n'
    printf 'repo:     %s\n' "$REPO"
    printf 'branch:   tom/%s\n' "$slug"
    printf 'model:    sonnet\n'
    printf 'effort:   medium\n'
    printf 'intent:   test fixture\n'
    printf 'added:    2026-01-01T00:00:00Z\n'
    printf -- '---\n\nplan body\n'
  } > "$dir/plan.md"
  st_set "$dir" PQ_WORKTREE "$wt"
  st_set "$dir" PQ_PANE "pane-$slug"
  st_set "$dir" PQ_REVIEW "$2"
  PIDX_OK=1; PIDX="pane-$slug"$'\tclaude\t'"$3"
  d=$dir
}
calls() { awk 'NF' "$WT_LOG" | wc -l | tr -d ' '; }

echo "== a ready task with a quiet agent has its dev server stopped ==" >&2
reset_tasks; reset_wt_log
mk_ready one ready idle
out=$(devstop_task "$d" 0 2>&1)
eq "$(calls)" "1" "wt is asked once"
eq "$(cut -f2- "$WT_LOG")" "stop	$WTS/one	" "to stop the task's own worktree"
eq "$(cut -f1 "$WT_LOG")" "$REPO" "from the task's repo, where wt takes its profile from"
[ -n "$(st "$d" PQ_DEVSTOP)" ] && [ "$(st "$d" PQ_DEVSTOP)" != failed ] && ok || bad "the stop is recorded with its time"
has "$out" "stopped its dev server" "and said"

echo "== ...exactly once: a server started afterwards stays up ==" >&2
reset_wt_log
devstop_task "$d" 0 >/dev/null 2>&1
devstop_task "$d" 0 >/dev/null 2>&1
eq "$(calls)" "0" "a later tick never stops a server Tom or the agent started on purpose"

echo "== an agent still working or on a dialog holds it, until it goes quiet ==" >&2
for s in working blocked; do
  reset_tasks; reset_wt_log
  mk_ready "held-$s" ready "$s"
  devstop_task "$d" 0 >/dev/null 2>&1
  eq "$(calls)" "0" "not while the agent is $s"
  eq "$(st "$d" PQ_DEVSTOP)" "" "and nothing is recorded, so a later tick tries"
  PIDX="pane-held-$s"$'\tclaude\tidle'
  devstop_task "$d" 0 >/dev/null 2>&1
  eq "$(calls)" "1" "the first quiet tick stops it ($s before)"
done

echo "== an agent that is done, or gone, holds nothing ==" >&2
for s in "done" noagent; do
  reset_tasks; reset_wt_log
  mk_ready "quiet-$s" ready idle
  if [ "$s" = noagent ]; then PIDX="pane-quiet-$s"$'\t\t'; else PIDX="pane-quiet-$s"$'\tclaude\tdone'; fi
  devstop_task "$d" 0 >/dev/null 2>&1
  eq "$(calls)" "1" "stopped with the agent $s"
done

echo "== only a gate that reached ready ==" >&2
for s in "" pending running posted prompted lapsed skipped; do
  reset_tasks; reset_wt_log
  mk_ready "gate-${s:-none}" "$s" idle
  devstop_task "$d" 0 >/dev/null 2>&1
  eq "$(calls)" "0" "a gate at '${s:-none}' keeps the server - the agent may still need it"
done

echo "== a settled pull request, or a worktree already gone, is the teardown's ==" >&2
reset_tasks; reset_wt_log
mk_ready merged ready idle; st_set "$d" PQ_MERGED "2026-01-02T00:00:00Z"
devstop_task "$d" 0 >/dev/null 2>&1
mk_ready closed ready idle; st_set "$d" PQ_CLOSED "2026-01-02T00:00:00Z"
devstop_task "$d" 0 >/dev/null 2>&1
mk_ready reaped ready idle; st_set "$d" PQ_REAPED "2026-01-02T00:00:00Z"
devstop_task "$d" 0 >/dev/null 2>&1
mk_ready gone ready idle; rm -rf "$WTS/gone"
devstop_task "$d" 0 >/dev/null 2>&1
eq "$(calls)" "0" "merged, closed, reaped or gone: nothing to stop"

echo "== a failure is warned once and never retried ==" >&2
reset_tasks; reset_wt_log
mk_ready broken ready idle
out=$(WT_STUB_RC=1 WT_STUB_ERR="wt: herdr: boom" devstop_task "$d" 0 2>&1)
has "$out" "could not stop its dev server" "the failure is said"
has "$out" "herdr: boom" "with wt's reason"
eq "$(st "$d" PQ_DEVSTOP)" "failed" "and recorded"
reset_wt_log
WT_STUB_RC=1 devstop_task "$d" 0 >/dev/null 2>&1
eq "$(calls)" "0" "a server left running is only what every task had before - not worth a retry a tick"

echo "== a dry run says what it would do, and does nothing ==" >&2
reset_tasks; reset_wt_log
mk_ready dry ready idle
out=$(devstop_task "$d" 1 2>&1)
has "$out" "would stop" "it says so"
eq "$(calls)" "0" "without calling wt"
eq "$(st "$d" PQ_DEVSTOP)" "" "or recording anything"

echo "== tick_body runs it, behind the same herdr gate as the teardown ==" >&2
reset_tasks; reset_wt_log; reset_caches
mk_ready ticked ready idle
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$REPO" tom/ticked 31 OPEN "" master >> "$PR_CACHE"
# shellcheck disable=SC2329  # called by the tick_body below
reap_ok() { return 1; }
tick_body 0 0 >/dev/null 2>&1
eq "$(grep -c '	stop	' "$WT_LOG")" "0" "with no herdr pane there is nothing wt stop could close"
# shellcheck disable=SC2329  # called by the tick_body below
reap_ok() { return 0; }
PIDX_OK=1; PIDX="pane-ticked"$'\tclaude\tidle'
# tick_body reloads the pane index; keep this one.
pidx_load() { PIDX_OK=1; PIDX="pane-ticked"$'\tclaude\tidle'; }
tick_body 0 0 >/dev/null 2>&1
eq "$(grep -c '	stop	' "$WT_LOG")" "1" "a tick stops a ready task's dev server"
[ -n "$(st "$d" PQ_DEVSTOP)" ] && ok || bad "and records it"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
