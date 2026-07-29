#!/usr/bin/env bash
# test/pq-order.sh - the timestamp queue: next_stamp, --urgent, pq urgent/later.
#
# Plain bash, no framework, matching the repo's zero-dependency habit and
# test/pq-after.sh's preamble: a temp PQ_HOME exported before sourcing pq (so
# pq's own top-level `mkdir -p` for each state runs against the temp dir, not
# the real queue), plus claude/gh/herdr stubbed so nothing here ever makes a
# real call.
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

# A real, throwaway git repo - branch_taken/git check-ref-format need one, even
# though nothing here ever resolves a remote or a PR.
REPO=$(mktemp -d)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init

reset_tasks() {
  rm -rf "$PQ_HOME/queue" "$PQ_HOME/hold" "$PQ_HOME/running" "$PQ_HOME/done"
  mkdir -p "$PQ_HOME/queue" "$PQ_HOME/hold" "$PQ_HOME/running" "$PQ_HOME/done"
}

PLAN="$PQ_HOME/.test-plan.md"
printf '# Test plan\n\nDo the thing.\n' > "$PLAN"

# --branch is mandatory here: the claude stub above fails closed, so
# name_plan never derives one, and cmd_add would otherwise die before it ever
# allocates a stamp.
add_task() {                             # branch [extra cmd_add args...] -> slug
  local branch=$1; shift
  main add "$PLAN" --repo "$REPO" --branch "$branch" -y "$@" 2>/dev/null
}

queue_slugs() {
  local d
  queue_ordered | while IFS= read -r d; do
    [ -n "$d" ] || continue
    printf '%s\n' "$(slug_of "$d")"
  done
}

echo "== pq urgent moves a queued task ahead of everything; pq later moves it behind everything ==" >&2
reset_tasks
a=$(add_task tom/order-a); add_task tom/order-b >/dev/null; c=$(add_task tom/order-c)
eq "$(queue_slugs | tr '\n' ' ')" "order-a order-b order-c " "fresh adds should queue in add-order"
main urgent "$c" >/dev/null 2>&1
eq "$(queue_slugs | tr '\n' ' ')" "order-c order-a order-b " "pq urgent should move c to the very front"
main later "$a" >/dev/null 2>&1
eq "$(queue_slugs | tr '\n' ' ')" "order-c order-b order-a " "pq later should move a to the very back"

echo "== pq urgent on an already-urgent task is a no-op and does not reshuffle the urgent group ==" >&2
reset_tasks
u1=$(add_task tom/urgent-one --urgent); u2=$(add_task tom/urgent-two --urgent)
eq "$(queue_slugs | tr '\n' ' ')" "urgent-one urgent-two " "two urgent adds should queue in urgent add-order"
out=$(main urgent "$u1" 2>&1 1>/dev/null)
case "$out" in *"already urgent"*) ok ;; *) bad "urgent on the frontmost urgent task should say so (got: $out)" ;; esac
eq "$(queue_slugs | tr '\n' ' ')" "urgent-one urgent-two " "a no-op urgent call must not reshuffle the urgent group"
out=$(main urgent "$u2" 2>&1 1>/dev/null)
case "$out" in *"already urgent"*) ok ;; *) bad "urgent on a non-frontmost urgent task should also say so (got: $out)" ;; esac
eq "$(queue_slugs | tr '\n' ' ')" "urgent-one urgent-two " "still no reshuffle after the second no-op call"

echo "== pq urgent and pq later both refuse a running or done task ==" >&2
reset_tasks
r=$(add_task tom/order-running)
retitle "$(find_task "$r")" running >/dev/null
out=$(main urgent "$r" 2>&1 1>/dev/null); rc=$?
[ "$rc" -ne 0 ] && ok || bad "pq urgent on a running task should fail"
case "$out" in *"ordering only moves what has not started"*) ok ;; *) bad "should carry order_movable's message (got: $out)" ;; esac
out=$(main later "$r" 2>&1 1>/dev/null); rc=$?
[ "$rc" -ne 0 ] && ok || bad "pq later on a running task should fail"
case "$out" in *"ordering only moves what has not started"*) ok ;; *) bad "should carry order_movable's message (got: $out)" ;; esac

reset_tasks
dn=$(add_task tom/order-done)
retitle "$(find_task "$dn")" done >/dev/null
out=$(main urgent "$dn" 2>&1 1>/dev/null); rc=$?
[ "$rc" -ne 0 ] && ok || bad "pq urgent on a done task should fail"
out=$(main later "$dn" 2>&1 1>/dev/null); rc=$?
[ "$rc" -ne 0 ] && ok || bad "pq later on a done task should fail"

echo "== two adds inside the same second get strictly ascending stamps ==" >&2
reset_tasks
# Driven through two real `main add` invocations, not two next_stamp calls:
# next_stamp is stateless, so two back-to-back next_stamp calls in one process
# would return the same value and this would pass vacuously. Monotonicity here
# comes entirely from the first part's directory existing on disk by the time
# the second one scans all_tasks.
s1=$(add_task tom/order-same1)
s2=$(add_task tom/order-same2)
st1=$(stamp_of "$(find_task "$s1")"); st2=$(stamp_of "$(find_task "$s2")")
[ "$st2" -gt "$st1" ] 2>/dev/null && ok || bad "the second add should get a strictly greater stamp than the first (got $st1 then $st2)"

echo "== a clock behind the highest existing stamp still yields max + 1 ==" >&2
reset_tasks
# Built directly on disk, not through a `date` stub on PATH: a `date` stub
# would also rewrite the added: field cmd_add writes, testing two things at
# once instead of one.
mkdir -p "$PQ_HOME/queue/29991231235959-future-task"
got=$(next_stamp 0)
eq "$got" "29991231235960" "next_stamp should return one past the highest existing real stamp, not today's date"

echo "== pq ls renders queue! for an urgent task and queue for a normal one ==" >&2
reset_tasks
add_task tom/order-normal >/dev/null
add_task tom/order-urgent-ls --urgent >/dev/null
ls_out=$(main ls 2>/dev/null)
urgent_line=$(printf '%s\n' "$ls_out" | grep '^order-urgent-ls')
normal_line=$(printf '%s\n' "$ls_out" | grep '^order-normal')
case "$urgent_line" in *"queue!"*) ok ;; *) bad "an urgent queued task should render STATE as queue! (got: $urgent_line)" ;; esac
case "$normal_line" in
  *"queue!"*) bad "a normal queued task should not render queue! (got: $normal_line)" ;;
  *"queue"*)  ok ;;
  *)          bad "a normal queued task should render STATE as queue (got: $normal_line)" ;;
esac

echo "== a legacy NNN-slug directory in done/ does not break stamp_of or pq ls ==" >&2
reset_tasks
legacy="$PQ_HOME/done/060-legacy-task"
mkdir -p "$legacy"
{
  printf -- '---\n'
  printf 'repo:     %s\n' "$REPO"
  printf 'branch:   %s\n' "tom/legacy-task"
  printf 'model:    sonnet\n'
  printf 'effort:   xhigh\n'
  printf 'dev:      false\n'
  printf 'intent:   legacy fixture\n'
  printf 'added:    2026-01-01T00:00:00Z\n'
  printf -- '---\n\nplan body\n'
} > "$legacy/plan.md"
eq "$(stamp_of "$legacy")" "60" "stamp_of should tolerate a legacy 3-digit prefix"
ls_out=$(main ls 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && ok || bad "pq ls must not choke on a legacy directory"
case "$ls_out" in *"legacy-task"*) ok ;; *) bad "pq ls should still list the legacy task (got: $ls_out)" ;; esac

echo "== a legacy short-prefix directory sitting in queue/ still sorts predictably under queue_ordered ==" >&2
reset_tasks
# A bare mkdir, not add_task: this is what a directory left over from before
# this rewrite - or dropped into a queue that skipped the migration - looks
# like. queue_ordered is dispatch's own view and must stay well-defined even
# with a directory of a different width mixed in; all_tasks' glob order
# (what pq ls displays) can legitimately disagree with it in that case - see
# the caveat on all_tasks' own comment - which is exactly why the migration
# step exists, and why pq later is the escape hatch for a directory that
# landed at the front because of it.
mkdir -p "$PQ_HOME/queue/900-legacy-in-queue"
add_task tom/order-fresh >/dev/null
eq "$(queue_slugs | tr '\n' ' ')" "legacy-in-queue order-fresh " \
  "queue_ordered must sort the legacy directory by its numeric stamp (900), ahead of a real 14-digit date"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
