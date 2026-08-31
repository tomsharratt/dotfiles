#!/usr/bin/env bash
# test/pq-archive.sh - the fifth state: archivable, archive_pass, and every
# place `all_tasks`'s live/all scope had to change so archive/ stays invisible
# to display and dispatch but still counts for stamp and slug uniqueness.
#
# Same conventions as test/pq-reap.sh: plain bash, no framework, a temp
# PQ_HOME exported before sourcing pq, claude/gh/herdr stubbed so nothing here
# ever makes a real call, ok/bad/eq, trap cleanup EXIT.
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

# Pinned so pq ls's render_table pass is deterministic without a tty, same
# reasoning as test/pq-width.sh.
export PQ_WIDTH=200

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
REPO=$(mktemp -d)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$REPO/.git/refs/remotes/origin"
git -C "$REPO" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master

reset_tasks() {
  rm -rf "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done" "$PQ_HOME/archive"
  mkdir -p "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done" "$PQ_HOME/archive"
}
reset_caches() { PR_CACHE="$PQ_HOME/.test.pr"; PR_ANS="$PQ_HOME/.test.ans"; : > "$PR_CACHE"; : > "$PR_ANS"; }
ans_row()   { printf '%s\t%s\n' "$@" >> "$PR_ANS"; }                    # repo branch

# A task built directly on disk, in any of the five states (archive included -
# that is exactly what a hand-mkdir'd archive/ directory looks like too, since
# archiving is nothing but a plain `mv`). Trailing args are state.env
# KEY=VALUE pairs, so a fixture can arrive already carrying whatever
# reap_task or archive_pass would have stamped.
mk_task() {                             # state prefix slug repo branch [KEY=VALUE...]
  local state=$1 prefix=$2 slug=$3 repo=$4 branch=$5; shift 5
  local dir="$PQ_HOME/$state/${prefix}-${slug}"
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
  local kv
  for kv in "$@"; do st_set "$dir" "${kv%%=*}" "${kv#*=}"; done
  printf '%s' "$dir"
}

reset_tasks

echo "== archivable: all six shapes ==" >&2
d=$(mk_task done 20260101000001 shape-merged-reaped "$REPO" tom/shape-merged-reaped \
  PQ_MERGED=2026-01-01T00:00:00Z PQ_REAPED=2026-01-01T00:00:01Z)
archivable "$d" && ok || bad "merged+reaped should be archivable"

d=$(mk_task done 20260101000002 shape-closed-reaped "$REPO" tom/shape-closed-reaped \
  PQ_CLOSED=2026-01-01T00:00:00Z PQ_REAPED=2026-01-01T00:00:01Z)
archivable "$d" && ok || bad "closed+reaped should be archivable"

# A closed PR now earns a teardown, so the verdict alone is not terminal any more.
# Archiving here would file the task into archive/ - which tick never walks - with its
# worktree, database and port still held and nothing left to reclaim them.
d=$(mk_task done 20260101000006 shape-closed-only "$REPO" tom/shape-closed-only \
  PQ_CLOSED=2026-01-01T00:00:00Z)
archivable "$d" && bad "closed with no teardown yet must not be archivable" || ok

d=$(mk_task done 20260101000003 shape-reaped-only "$REPO" tom/shape-reaped-only \
  PQ_REAPED=2026-01-01T00:00:00Z)
archivable "$d" && bad "reaped with no merge verdict must not be archivable" || ok

d=$(mk_task done 20260101000004 shape-merged-held "$REPO" tom/shape-merged-held \
  PQ_MERGED=2026-01-01T00:00:00Z PQ_REAP_HELD=agent)
archivable "$d" && bad "merged but still held (no REAPED yet) must not be archivable" || ok

d=$(mk_task done 20260101000005 shape-no-verdict "$REPO" tom/shape-no-verdict)
archivable "$d" && bad "no verdict at all must not be archivable" || ok

echo "== archive_pass: tail retention sorts by stamp_of, not glob order ==" >&2
reset_tasks
PQ_DONE_KEEP=2
# "800" and "900" are legacy-width stamps - numerically far smaller than any
# real UTC timestamp (which starts with 2, for the year), but ALPHABETICALLY
# they sort after one (since '8'/'9' > '2'). A plain lexical sort here would
# archive the two modern ones and keep the legacy pair behind - exactly
# backwards. Mirrors the disagreement done/ header comment (:313-318) warns
# about.
old1=$(mk_task done 800 legacy-old "$REPO" tom/legacy-old PQ_CLOSED=2026-01-01T00:00:00Z PQ_REAPED=2026-01-01T00:00:01Z)
old2=$(mk_task done 900 legacy-mid "$REPO" tom/legacy-mid PQ_CLOSED=2026-01-01T00:00:00Z PQ_REAPED=2026-01-01T00:00:01Z)
new1=$(mk_task done 20260101000001 modern-1 "$REPO" tom/modern-1 PQ_CLOSED=2026-01-01T00:00:00Z PQ_REAPED=2026-01-01T00:00:01Z)
new2=$(mk_task done 20260101000002 modern-2 "$REPO" tom/modern-2 PQ_CLOSED=2026-01-01T00:00:00Z PQ_REAPED=2026-01-01T00:00:01Z)
n_arch=$(archive_pass 0 2>/dev/null)
eq "$n_arch" "2" "with 4 archivable and a tail of 2, exactly 2 should be archived"
[ ! -d "$old1" ] && [ ! -d "$old2" ] && ok || bad "the two numerically-oldest (legacy-old, legacy-mid) should have left done/"
[ -d "$new1" ] && [ -d "$new2" ] && ok || bad "the two numerically-newest (modern-1, modern-2) should stay in done/"
[ -d "$PQ_HOME/archive/800-legacy-old" ] && ok || bad "legacy-old should now sit in archive/"
[ -d "$PQ_HOME/archive/900-legacy-mid" ] && ok || bad "legacy-mid should now sit in archive/"

echo "== archive_pass: PQ_DONE_KEEP=0 is legal and means no tail ==" >&2
reset_tasks
PQ_DONE_KEEP=0
mk_task done 20260101000001 keep-none-a "$REPO" tom/keep-none-a PQ_CLOSED=2026-01-01T00:00:00Z PQ_REAPED=2026-01-01T00:00:01Z >/dev/null
n_arch=$(archive_pass 0 2>/dev/null)
eq "$n_arch" "1" "PQ_DONE_KEEP=0 should archive every archivable task, none held back"

echo "== archive_pass: --dry-run moves nothing ==" >&2
reset_tasks
PQ_DONE_KEEP=1
da=$(mk_task done 20260101000001 dry-a "$REPO" tom/dry-a \
  PQ_MERGED=2026-01-01T00:00:00Z PQ_REAPED=2026-01-01T00:00:01Z)
db=$(mk_task done 20260101000002 dry-b "$REPO" tom/dry-b PQ_CLOSED=2026-01-01T00:00:00Z PQ_REAPED=2026-01-01T00:00:01Z)
msgs=$(archive_pass 1 2>&1 1>/dev/null)
n_arch=$(archive_pass 1 2>/dev/null)
eq "$n_arch" "1" "one of the two archivable tasks exceeds the tail of 1"
[ -d "$da" ] && [ -d "$db" ] && ok || bad "--dry-run must leave both tasks exactly where they were"
[ -z "$(ls -A "$PQ_HOME/archive" 2>/dev/null)" ] && ok || bad "--dry-run must move nothing into archive/"
case "$msgs" in *"would archive dry-a"*) ok ;; *) bad "should name the older task it would archive (got: $msgs)" ;; esac

echo "== archive_pass: a destination collision warns and skips, never dies ==" >&2
reset_tasks
PQ_DONE_KEEP=0
dcol=$(mk_task done 20260101000001 collide "$REPO" tom/collide PQ_CLOSED=2026-01-01T00:00:00Z PQ_REAPED=2026-01-01T00:00:01Z)
mkdir -p "$PQ_HOME/archive/$(basename "$dcol")"     # hand-corrupted: already occupied
out=$(archive_pass 0 2>&1 1>/dev/null)
n_arch=$(archive_pass 0 2>/dev/null)
eq "$n_arch" "0" "a colliding destination must not count as archived"
[ -d "$dcol" ] && ok || bad "the source task must be left in done/ when its destination is taken"
case "$out" in *"could not archive"*) ok ;; *) bad "should warn about the collision (got: $out)" ;; esac

echo "== tick_body wiring: the archived count folds into the summary ==" >&2
reset_tasks
PQ_DONE_KEEP=0
dt=$(mk_task done 20260101000001 tickarch-a "$REPO" tom/tickarch-a PQ_CLOSED=2026-01-01T00:00:00Z PQ_REAPED=2026-01-01T00:00:01Z)
PQ_SUMMARY=""
tick_body 0 0 >/dev/null 2>&1
case "$PQ_SUMMARY" in *", 1 archived"*) ok ;; *) bad "summary should report 1 archived (got '$PQ_SUMMARY')" ;; esac
[ -d "$PQ_HOME/archive/$(basename "$dt")" ] && ok || bad "the task should now sit in archive/"
[ ! -d "$dt" ] && ok || bad "the task should no longer sit in done/"

reset_tasks
PQ_DONE_KEEP=0
mk_task done 20260101000001 tickarch-dry "$REPO" tom/tickarch-dry PQ_CLOSED=2026-01-01T00:00:00Z PQ_REAPED=2026-01-01T00:00:01Z >/dev/null
PQ_SUMMARY=""
tick_body 0 1 >/dev/null 2>&1   # dry=1
case "$PQ_SUMMARY" in *", 1 would archive"*) ok ;; *) bad "dry-run summary should report a would-archive (got '$PQ_SUMMARY')" ;; esac
eq "$(ls -A "$PQ_HOME/archive" 2>/dev/null)" "" "a dry-run tick must archive nothing"

echo "== pq ls: hides archive/ by default, --all shows it and its count ==" >&2
reset_tasks
mk_task queue 20260101000001 visible-task "$REPO" tom/visible-task >/dev/null
mk_task archive 20260101000000 hidden-history "$REPO" tom/hidden-history \
  PQ_CLOSED=2026-01-01T00:00:00Z PQ_ARCHIVED=2026-01-01T00:00:00Z >/dev/null
out=$(main ls 2>&1)
case "$out" in *"visible-task"*) ok ;; *) bad "a live task must still be listed (got: $out)" ;; esac
case "$out" in *"hidden-history"*) bad "an archived task must not be listed by default" ;; *) ok ;; esac
case "$out" in *"1 archived"*"--all"*) ok ;; *) bad "the summary should say how many are hidden and how to see them (got: $out)" ;; esac
out_all=$(main ls --all 2>&1)
case "$out_all" in *"hidden-history"*) ok ;; *) bad "pq ls --all should show the archived task (got: $out_all)" ;; esac

echo "== pq ls --json: composes with --all ==" >&2
json_default=$(main ls --json 2>/dev/null)
eq "$(jq 'length' <<<"$json_default")" "1" "pq ls --json without --all should list only the live task"
json_all=$(main ls --all --json 2>/dev/null)
eq "$(jq 'length' <<<"$json_all")" "2" "pq ls --all --json should list both the live and the archived task"

echo "== find_task: a unique live prefix wins even though archive shares it ==" >&2
reset_tasks
mk_task queue 20260101000010 widget-live "$REPO" tom/widget-live >/dev/null
mk_task archive 20260101000009 widget-old "$REPO" tom/widget-old PQ_CLOSED=2026-01-01T00:00:00Z >/dev/null
resolved=$(find_task widget)
eq "$(slug_of "$resolved")" "widget-live" "a unique live prefix match must resolve to the live task"

echo "== find_task: falls back to archive only when live has nothing at all ==" >&2
resolved=$(find_task widget-old)
eq "$(slug_of "$resolved")" "widget-old" "an exact archived slug with no live match should resolve via the fallback"

echo "== find_task: an ambiguous prefix among live tasks errors without ever consulting archive ==" >&2
reset_tasks
mk_task queue 20260101000011 poke-beta "$REPO" tom/poke-beta >/dev/null
mk_task queue 20260101000012 poke-gamma "$REPO" tom/poke-gamma >/dev/null
mk_task archive 20260101000008 poke-alpha "$REPO" tom/poke-alpha PQ_CLOSED=2026-01-01T00:00:00Z >/dev/null
err=$(find_task poke 2>&1 1>/dev/null); rc=$?
[ "$rc" -ne 0 ] && ok || bad "an ambiguous live prefix should still die"
case "$err" in *"poke-beta"*"poke-gamma"*) ok ;; *) bad "should list the two live matches (got: $err)" ;; esac
case "$err" in *"poke-alpha"*) bad "must not pull the archived match into the ambiguity - live already decided it" ;; *) ok ;; esac

echo "== find_task: an archived slug with no live match at all still resolves (pq rm) ==" >&2
reset_tasks
mk_task archive 20260101000001 lone-archived "$REPO" tom/lone-archived PQ_CLOSED=2026-01-01T00:00:00Z >/dev/null
resolved=$(find_task lone-archived)
eq "$(slug_of "$resolved")" "lone-archived" "an archived slug with nothing live sharing it should still resolve"

echo "== slug_taken_in: an archived slug still blocks a fresh one ==" >&2
reset_tasks
mk_task archive 20260101000001 taken-slug "$REPO" tom/taken-slug PQ_CLOSED=2026-01-01T00:00:00Z >/dev/null
eq "$(slug_taken_in taken-slug)" "archive" "slug_taken_in should see an archived slug"

echo "== task_by_branch: finds an archived owner, so blocker_state never reports orphan ==" >&2
reset_tasks
mk_task archive 20260101000002 shipped-owner "$REPO" tom/shipped-owner \
  PQ_MERGED=2026-01-01T00:00:00Z PQ_REAPED=2026-01-01T00:00:01Z >/dev/null
found=$(task_by_branch "$REPO" tom/shipped-owner)
[ -n "$found" ] && ok || bad "task_by_branch should find the archived owner"
eq "$(slug_of "$found")" "shipped-owner" "task_by_branch should resolve to the archived task"

reset_caches
ans_row "$REPO" tom/shipped-owner   # gh answered: zero rows for this branch
bst=$(blocker_state "$REPO" tom/shipped-owner master)
eq "$bst" "waiting" "an archived owner must read as waiting, never orphan"

echo "== next_stamp: spans archive, so an urgent stamp is never reissued once its task has archived ==" >&2
reset_tasks
mk_task archive 00000000000005 urgent-done "$REPO" tom/urgent-done PQ_CLOSED=2026-01-01T00:00:00Z >/dev/null
got=$(next_stamp 1)
eq "$got" "6" "next_stamp 1 should return one past the archived urgent maximum, not 1"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
