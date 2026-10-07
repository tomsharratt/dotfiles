#!/usr/bin/env bash
# test/pq-order.sh - the timestamp queue: next_stamp and queue order.
#
# Plain bash, no framework, matching the repo's zero-dependency habit and
# test/pq-after.sh's preamble: a temp PQ_HOME exported before sourcing pq (so
# pq's own top-level `mkdir -p` for each state runs against the temp dir, not
# the real queue), plus claude/gh/herdr stubbed so nothing here ever makes a
# real call.
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

cleanup() { rm -rf "$PQ_HOME" "$STUBBIN" "${REPO:-}"; }
trap cleanup EXIT

# A real, throwaway git repo - branch_taken/git check-ref-format need one, even
# though nothing here ever resolves a remote or a PR.
REPO=$(mktemp -d)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init

reset_tasks() {
  rm -rf "$PQ_HOME/new" "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done"
  mkdir -p "$PQ_HOME/new" "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done"
}

PLAN="$PQ_HOME/.test-plan.md"
printf '# Test plan\n\nDo the thing.\n' > "$PLAN"

# The picker and the namer are stood in for: the claude stub above fails
# closed, so name_plan would never derive a name, and cmd_add would otherwise
# die before it ever allocates a stamp. Prints the slug the branch reduces to.
add_task() {                             # branch -> slug
  add_as "$PLAN" "$1" --repo "$REPO" 2>/dev/null && branch_to_slug "$1"
}

queue_slugs() {
  local d
  queue_ordered | while IFS= read -r d; do
    [ -n "$d" ] || continue
    printf '%s\n' "$(slug_of "$d")"
  done
}

# The queue is add-order and nothing else: there is no re-ordering after the
# fact, and no reserved range to jump it.
echo "== the queue is add-order ==" >&2
reset_tasks
add_task tom/order-a >/dev/null; add_task tom/order-b >/dev/null
eq "$(queue_slugs | tr '\n' ' ')" "order-a order-b " "fresh adds should queue in add-order"
add_task tom/order-c >/dev/null
eq "$(queue_slugs | tr '\n' ' ')" "order-a order-b order-c " "and a later add queues last"

# This file owned `pq urgent` and `pq later`; the guard covers every command
# removed since, so there is one place to look. Each is checked
# through `main`, which is where the dispatch decision actually lives - and in a
# command substitution, so `die`'s exit kills the subshell rather than this
# script.
echo "== the removed commands are gone from the dispatch table ==" >&2
reset_tasks
gone=$(add_task tom/order-gone)
for removed in show urgent later hold unhold archive base; do
  out=$(main "$removed" "$gone" 2>&1 1>/dev/null); rc=$?
  if [ "$rc" -ne 0 ] && [ "${out#*usage: pq}" != "$out" ]; then ok
  else bad "pq $removed should be an unknown subcommand now (rc=$rc, got: $out)"; fi
done

echo "== two adds inside the same second get strictly ascending stamps ==" >&2
reset_tasks
# Driven through two real `cmd_add` invocations, not two next_stamp calls:
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
got=$(next_stamp)
eq "$got" "29991231235960" "next_stamp should return one past the highest existing stamp, not today's date"

echo "== a hand-made NNN-slug directory in done/ does not break stamp_of or pq ls ==" >&2
reset_tasks
short="$PQ_HOME/done/060-short-task"
mkdir -p "$short"
{
  printf -- '---\n'
  printf 'repo:     %s\n' "$REPO"
  printf 'branch:   %s\n' "tom/short-task"
  printf 'model:    sonnet\n'
  printf 'effort:   xhigh\n'
  printf 'intent:   short-prefix fixture\n'
  printf 'added:    2026-01-01T00:00:00Z\n'
  printf -- '---\n\nplan body\n'
} > "$short/plan.md"
eq "$(stamp_of "$short")" "60" "stamp_of should tolerate a 3-digit prefix"
ls_out=$(main ls 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && ok || bad "pq ls must not choke on a short-prefix directory"
case "$ls_out" in *"short-task"*) ok ;; *) bad "pq ls should still list the short-prefix task (got: $ls_out)" ;; esac

echo "== a hand-made short-prefix directory sitting in queue/ still sorts predictably under queue_ordered ==" >&2
reset_tasks
# A bare mkdir, not add_task: this is what a directory made by hand looks like.
# queue_ordered is dispatch's own view and must stay well-defined even with a
# directory of a different width mixed in; all_tasks' glob order (what pq ls
# displays) can legitimately disagree with it in that case - see the caveat on
# all_tasks' own comment.
mkdir -p "$PQ_HOME/queue/900-short-in-queue"
add_task tom/order-fresh >/dev/null
eq "$(queue_slugs | tr '\n' ' ')" "short-in-queue order-fresh " \
  "queue_ordered must sort the short-prefix directory by its numeric stamp (900), ahead of a real 14-digit date"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
