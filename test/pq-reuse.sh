#!/usr/bin/env bash
# test/pq-reuse.sh - a branch name used before must not bring its old pull
# request with it.
#
# `gh pr list --head B --state all` answers every pull request that branch name
# has ever had, and reconcile took any row as the task's own. So a task Haiku
# happened to name after a branch whose old pull request had merged read as
# "finished #old merged" one tick after dispatch; its review was skipped as
# settled, and reap force-removed the live worktree at the agent's first idle
# tick. The fix has two halves, both here: a task only ever owns pull requests
# opened after it was claimed, and `branch_taken` refuses a name with any pull
# request history at all.
#
# Everything goes through the real pr_load -> gh -> jq pipeline: `gh` answers
# from $PRS/<branch with / as ->.json, the rows the forge would return.
#
# SC2034: the caches and pane index set here are read by the pq sourced below.
# SC2015: `ok` never fails, so `[ ... ] && ok || bad` is an if/else.
# shellcheck disable=SC2034,SC2015
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PQ_HOME=$(mktemp -d)
export PQ_HOME

STUBBIN=$(mktemp -d)
PRS="$STUBBIN/prs"
mkdir -p "$PRS"
echo '[]' > "$STUBBIN/.empty.json"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/claude"
# `pr list --head B` answers $PRS/B.json, or fails like an unreachable forge
# when $STUBBIN/.offline exists. `-q` is honoured for branch_taken's lookup.
cat > "$STUBBIN/gh" <<EOF
#!/bin/sh
[ -f "$STUBBIN/.offline" ] && exit 1
head="" q=""
while [ \$# -gt 0 ]; do
  case "\$1" in --head) head=\$2; shift ;; -q|--jq) q=\$2; shift ;; esac
  shift
done
[ -n "\$head" ] || exit 1
f="$PRS/\$(printf '%s' "\$head" | tr / -).json"
[ -f "\$f" ] || f="$STUBBIN/.empty.json"
if [ -n "\$q" ]; then jq -r "\$q" "\$f"; else cat "\$f"; fi
EOF
cat > "$STUBBIN/herdr" <<'EOF'
#!/bin/sh
case "$*" in
  "api snapshot") echo '{"result":{"snapshot":{"panes":[]}}}'; exit 0 ;;
esac
exit 1
EOF
WT_LOG="$STUBBIN/.wt-calls"
: > "$WT_LOG"
cat > "$STUBBIN/wt-stub" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$WT_LOG"
exit 0
EOF
chmod +x "$STUBBIN/claude" "$STUBBIN/gh" "$STUBBIN/herdr" "$STUBBIN/wt-stub"
export PATH="$STUBBIN:$PATH"
export PQ_WT="$STUBBIN/wt-stub"

# shellcheck source=/dev/null
source "$HERE/../.local/bin/pq"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { if [ "$1" = "$2" ]; then ok; else bad "$3 (got '$1', want '$2')"; fi; }

cleanup() { rm -rf "$PQ_HOME" "$STUBBIN" "${REPO:-}" "${WTDIR:-}"; }
trap cleanup EXIT

REPO=$(mktemp -d)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$REPO/.git/refs/remotes/origin"
git -C "$REPO" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
WTDIR=$(mktemp -d)

reset_tasks() {
  rm -rf "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done" "$PQ_HOME/archive"
  mkdir -p "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done" "$PQ_HOME/archive"
  rm -f "$PRS"/*.json
  : > "$WT_LOG"
}
mk_task() {                              # state prio slug branch -> task_dir
  local dir
  dir="$PQ_HOME/$1/$(printf '%014d' $(( 20260101000000 + 10#$2 )))-$3"
  mkdir -p "$dir"
  printf -- '---\nrepo:     %s\nbranch:   %s\nmodel:    sonnet\neffort:   xhigh\nintent:   t\nadded:    2026-01-01T00:00:00Z\n---\n\nplan\n' \
    "$REPO" "$4" > "$dir/plan.md"
  printf '%s' "$dir"
}
# One row the forge would return for a pull request.
pr_json() {                              # number state created [base]
  printf '{"number":%s,"state":"%s","isDraft":false,"baseRefName":"%s","createdAt":"%s","mergeCommit":{"oid":""}}' \
    "$1" "$2" "${4:-master}" "$3"
}
prs() {                                  # branch json-row...
  local f; f="$PRS/$(printf '%s' "$1" | tr / -).json"; shift
  local IFS=,; printf '[%s]\n' "$*" > "$f"
}

echo "== reconcile does not adopt a pull request opened before the task was claimed ==" >&2
reset_tasks
d=$(mk_task running 10 reused tom/reused)
st_set "$d" PQ_CLAIMED 2026-09-20T10:00:00Z; st_set "$d" PQ_LAUNCHED 2026-09-20T10:01:00Z
st_set "$d" PQ_PANE w1:p1; st_set "$d" PQ_WORKTREE "$WTDIR"
prs tom/reused "$(pr_json 100 MERGED 2026-08-01T00:00:00Z)"
out=$(tick_body 0 0 2>&1)
[ -d "$d" ] && ok || bad "a task with only an old pull request must stay in running/ (tick said: $out)"
eq "$(st "$d" PQ_PR)" "" "it must not record the old pull request as its own"
case "$out" in *"finished reused"*) bad "and must not read as finished (got '$out')" ;; *) ok ;; esac

echo "== ...and adopts the one it opens itself ==" >&2
prs tom/reused "$(pr_json 131 OPEN 2026-09-20T12:00:00Z)" "$(pr_json 100 MERGED 2026-08-01T00:00:00Z)"
tick_body 0 0 >/dev/null 2>&1
done_d="$PQ_HOME/done/$(basename "$d")"
[ -d "$done_d" ] && ok || bad "the task's own pull request moves it to done/"
eq "$(st "$done_d" PQ_PR)" "131" "and it is that one, not the old one, that it records"

echo "== reap never tears down on an old pull request's merge ==" >&2
# The whole cost of the bug: the old merge settled the task, and reap removed a
# worktree whose agent was still working in it.
reset_tasks
d=$(mk_task "done" 11 reaped-early tom/reaped-early)
st_set "$d" PQ_CLAIMED 2026-09-20T10:00:00Z; st_set "$d" PQ_WORKTREE "$WTDIR"; st_set "$d" PQ_PANE w1:p1
prs tom/reaped-early "$(pr_json 132 OPEN 2026-09-20T12:00:00Z)" "$(pr_json 101 MERGED 2026-08-01T00:00:00Z)"
pr_load_all "$(pr_targets running)"
PIDX_OK=1; PIDX=$'w1:p1\tclaude\tidle'
reap_task "$d" 0 >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok || bad "an open pull request of its own is not a verdict, whatever an old one did"
[ ! -s "$WT_LOG" ] && ok || bad "wt must not be asked to remove the worktree"
eq "$(st "$d" PQ_MERGED)" "" "and no merge is recorded"

echo "== a blocker owned by a task still in the queue is not met by an old merge ==" >&2
# The queued owner has not been claimed, so no pull request can be its work yet.
reset_tasks
mk_task queue 12 owner tom/owner >/dev/null
w=$(mk_task queue 13 waiter tom/waiter)
printf 'owner\t%s\ttom/owner\n' "$REPO" > "$w/after"
prs tom/owner "$(pr_json 102 MERGED 2026-08-01T00:00:00Z)"
pr_load_all "$(pr_targets)"
eq "$(cut -f1 <<<"$(after_state "$w")")" "waiting owner 1" \
  "an unclaimed owner's branch has no pull request of its own to have merged"
repo_base_reset

echo "== a blocker naming a branch no task owns is judged on its pull requests as before ==" >&2
reset_tasks
w=$(mk_task queue 14 waiter2 tom/waiter2)
printf 'raw\t%s\ttom/raw\n' "$REPO" > "$w/after"
prs tom/raw "$(pr_json 103 MERGED 2026-08-01T00:00:00Z)"
pr_load_all "$(pr_targets)"
eq "$(cut -f1 <<<"$(after_state "$w")")" "met" "a raw branch's merged pull request still meets it"
repo_base_reset

echo "== a task claimed before PQ_CLAIMED existed is not filtered ==" >&2
reset_tasks
d=$(mk_task running 15 legacy tom/legacy)
st_set "$d" PQ_LAUNCHED 2026-08-01T10:01:00Z; st_set "$d" PQ_PANE w1:p1; st_set "$d" PQ_WORKTREE "$WTDIR"
prs tom/legacy "$(pr_json 104 OPEN 2026-08-01T12:00:00Z)"
tick_body 0 0 >/dev/null 2>&1
[ -d "$PQ_HOME/done/$(basename "$d")" ] && ok || bad "with no claim time on file, any pull request is its own, as before"

echo "== branch_taken refuses a name with pull request history ==" >&2
reset_tasks
prs tom/shipped-once "$(pr_json 105 MERGED 2026-08-01T00:00:00Z)"
why=$(branch_taken tom/shipped-once "$REPO"); rc=$?
eq "$rc" 0 "a branch whose pull request merged is taken"
case "$why" in *"#105"*) ok ;; *) bad "and the reason names the pull request (got '$why')" ;; esac
prs tom/closed-once "$(pr_json 106 CLOSED 2026-08-01T00:00:00Z)"
branch_taken tom/closed-once "$REPO" >/dev/null && ok || bad "so is one whose pull request was closed"
branch_taken tom/never-used "$REPO" >/dev/null && bad "a name with no history is free" || ok

echo "== ...fails open offline, like the ls-remote check beside it ==" >&2
touch "$STUBBIN/.offline"
branch_taken tom/shipped-once "$REPO" >/dev/null && bad "an unreachable forge must not make every name taken" || ok
rm -f "$STUBBIN/.offline"

echo "== ...and counts a finished task's branch, even with the forge silent ==" >&2
reset_tasks
touch "$STUBBIN/.offline"
mk_task archive 16 old-work tom/old-work >/dev/null
why=$(branch_taken tom/old-work "$REPO"); rc=$?
eq "$rc" 0 "an archived task's branch is taken"
case "$why" in *"old-work"*) ok ;; *) bad "the reason names the task (got '$why')" ;; esac
mk_task "done" 17 recent tom/recent >/dev/null
branch_taken tom/recent "$REPO" >/dev/null && ok || bad "and so is a done task's"
rm -f "$STUBBIN/.offline"

echo "== pq add asks Haiku once more when the name it chose is taken ==" >&2
reset_tasks
prs tom/shipped-once "$(pr_json 105 MERGED 2026-08-01T00:00:00Z)"
cat > "$STUBBIN/claude" <<'EOF'
#!/bin/sh
cat >/dev/null
case "$*" in
  *"already taken: tom/shipped-once"*) echo '{"branch":"tom/fresh-name","intent":"the retry","security":false,"parts":["p"]}' ;;
  *) echo '{"branch":"tom/shipped-once","intent":"the first","security":false,"parts":["p"]}' ;;
esac
EOF
PLAN="$PQ_HOME/plan-src.md"; printf '# A plan\n\nDo it.\n' > "$PLAN"
slug=$(cmd_add "$PLAN" "" "" "" --repo "$REPO" 2>"$PQ_HOME/.err"); rc=$?
eq "$rc" 0 "the add goes through on the second name ($(cat "$PQ_HOME/.err"))"
eq "$slug" "fresh-name" "under the name Haiku gave when told the first was taken"
t=$(find_task fresh-name)
eq "$(hdr "$t/plan.md" intent)" "the retry" "with that reply's intent"
case "$(cat "$PQ_HOME/.err")" in *"tom/shipped-once"*"#105"*) ok ;; *) bad "and it says why it asked again (got '$(cat "$PQ_HOME/.err")')" ;; esac

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
