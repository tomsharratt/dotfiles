#!/usr/bin/env bash
# test/pq-add-pick.sh - the interactive plan picker: recent_plans/latest_plan
# ordering, plan_title, cell, age_since, pick_plan, pick_after, add_wizard,
# and the wiring into cmd_add.
#
# Same conventions as test/pq-split.sh: plain bash, no framework, a temp
# PQ_HOME exported BEFORE sourcing pq, a PATH-stubbed `claude` and `gh` so
# nothing here ever reaches the network, ok/bad/eq, trap cleanup EXIT, and a
# throwaway git repo with refs/remotes/origin/HEAD faked by hand.
#
# The first test in the repo to use PQ_PLANS_DIR - exported before `source`,
# exactly like PQ_HOME, since PLANS_DIR="${PQ_PLANS_DIR:-$HOME/.claude/plans}"
# is evaluated at source time. Exporting it after sourcing would leave
# PLANS_DIR baked to the real ~/.claude/plans, and every test below would
# read (and the wiring cases would queue) whatever is actually there.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PQ_HOME=$(mktemp -d)
export PQ_HOME
PQ_PLANS_DIR=$(mktemp -d)
export PQ_PLANS_DIR

STUBBIN=$(mktemp -d)
# Dispatches on --model, same shape as test/pq-split.sh's stub. Only the
# wiring cases at the bottom ever reach this without an explicit --branch
# (which skips the naming call entirely), so only one marker is needed.
cat > "$STUBBIN/claude" <<'STUBEOF'
#!/usr/bin/env bash
model=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) model=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$model" in
  haiku)
    content=$(cat)
    case "$content" in
      *"MARKER: wiring-fixture"*)
        printf '{"branch":"tom/wiring-fixture-task","intent":"Do the wiring thing."}\n' ;;
      *) printf '{}\n' ;;
    esac
    ;;
  *) exit 1 ;;
esac
STUBEOF
chmod +x "$STUBBIN/claude"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/gh"
chmod +x "$STUBBIN/gh"
export PATH="$STUBBIN:$PATH"

# shellcheck source=/dev/null
source "$HERE/../.local/bin/pq"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() {                                   # got want msg
  [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"
}

cleanup() { rm -rf "$PQ_HOME" "$PQ_PLANS_DIR" "$STUBBIN" "${REPO:-}" "${REPO2:-}"; }
trap cleanup EXIT

# ── a throwaway git repo ────────────────────────────────────────────────────
REPO=$(mktemp -d)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$REPO/.git/refs/remotes/origin"
git -C "$REPO" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master

reset_plans() { rm -rf "$PQ_PLANS_DIR"; mkdir -p "$PQ_PLANS_DIR"; }
mkplan() { printf '# %s\n\nBody.\n' "$2" > "$PQ_PLANS_DIR/$1"; }        # filename title

reset_tasks() {
  rm -rf "$PQ_HOME/queue" "$PQ_HOME/hold" "$PQ_HOME/running" "$PQ_HOME/done"
  mkdir -p "$PQ_HOME/queue" "$PQ_HOME/hold" "$PQ_HOME/running" "$PQ_HOME/done"
}
reset_tasks

# A task built by hand, bypassing the real dispatch path - same idiom as
# test/pq-reap.sh's mk_done, just parameterised over the state.
mk_task() {                             # state prio slug repo branch -> task_dir
  local state=$1 prio=$2 slug=$3 repo=$4 branch=$5
  # $prio is relative order, not a stamp - it is offset into the real
  # (non-urgent) range so a fixture never accidentally reads as --urgent.
  # $((10#$prio)) rather than a bare $prio: inside $(( )) a leading-zero
  # literal like 020 is octal, exactly the bug this fixture must not
  # reintroduce - and this file's own call sites pass 010/020/030/040/005.
  local dir="$PQ_HOME/$state/$(printf '%014d' $(( 20260101000000 + 10#$prio )))-$slug"
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

echo "== recent_plans / latest_plan: ordering by max(mtime, birth) ==" >&2
# stat's %m and %B are whole seconds, so fixtures must be spaced out for real,
# not merely touch -t'd - touch cannot age a file anyway, since birth time is
# untouched by it and max(mtime, birth) would just return birth unchanged.
reset_plans
mkplan a.md "Plan A"; sleep 1.1
mkplan b.md "Plan B"; sleep 1.1
mkplan c.md "Plan C"

order() { recent_plans | awk -F'\t' '{ print $2 }' | xargs -n1 basename | tr '\n' ' '; }
eq "$(order)" "c.md b.md a.md " "recent_plans should list c, b, a - newest created first"
eq "$(basename "$(latest_plan)")" "c.md" "latest_plan should be c before the touch"

sleep 1.1
touch "$PQ_PLANS_DIR/a.md"
eq "$(order)" "a.md c.md b.md " "touching a should move it back to the front, ahead of c and b"
eq "$(basename "$(latest_plan)")" "a.md" "latest_plan should be a after the touch"

echo "== plan_title ==" >&2
printf '# Real Title\n\nBody.\n' > "$PQ_HOME/.t1.md"
eq "$(plan_title "$PQ_HOME/.t1.md")" "Real Title" "an H1 has its marker stripped"

printf '\n\n  \nJust text, no heading.\nMore.\n' > "$PQ_HOME/.t2.md"
eq "$(plan_title "$PQ_HOME/.t2.md")" "Just text, no heading." \
  "no H1: the first non-blank line is the fallback, leading blanks skipped"

printf '## Sub Title\n\nBody.\n' > "$PQ_HOME/.t3.md"
eq "$(plan_title "$PQ_HOME/.t3.md")" "Sub Title" "## is stripped too, not just a single #"

echo "== cell ==" >&2
eq "$(cell "$(printf 'a\tb')" 10)" "a b" "a tab becomes a space rather than a column break"
eq "$(cell "$(printf 'caf\xc3\xa9')" 10)" "caf" "a multi-byte character is dropped, not counted"
long="this is a string that is definitely longer than the width given"
out=$(cell "$long" 20)
eq "${#out}" "20" "over-length truncates to exactly the given width"
eq "${out: -2}" ".." "truncation ends with .."

echo "== age_since ==" >&2
nowe=$(date -u '+%s')
eq "$(age_since "$nowe")" "0m" "now -> 0m"
eq "$(age_since $((nowe - 7200)))" "2h" "2 hours ago -> 2h"
eq "$(age_since $((nowe - 3 * 86400)))" "3d" "3 days ago -> 3d"
eq "$(age_since $((nowe + 600)))" "0m" "a future epoch clamps to 0m rather than going negative"

echo "== pick_plan: stdout is exactly the path, nothing else ==" >&2
reset_plans
mkplan 1-first.md "First plan"; sleep 1.1
mkplan 2-second.md "Second plan"
p_first="$PQ_PLANS_DIR/1-first.md"
p_second="$PQ_PLANS_DIR/2-second.md"

out=$(pick_plan 2>/dev/null <<<$'2\ny')
eq "$out" "$p_first" "picking row 2 (the older plan) returns exactly its path on stdout"

echo "== pick_plan: Enter defaults to row 1, the newest ==" >&2
out=$(pick_plan 2>/dev/null <<<$'\ny')
eq "$out" "$p_second" "Enter should pick row 1"

echo "== pick_plan: q quits, returns 1, prints nothing to stdout ==" >&2
out=$(pick_plan 2>/dev/null <<<'q'); rc=$?
eq "$rc" "1" "q should return 1"
eq "$out" "" "q should print nothing to stdout"

echo "== pick_plan: EOF declines, returns 1 ==" >&2
out=$(pick_plan 2>/dev/null </dev/null); rc=$?
eq "$rc" "1" "EOF at the number prompt should return 1"
eq "$out" "" "EOF should print nothing to stdout"

echo "== pick_plan: declining a preview returns to the number prompt, not aborted ==" >&2
out=$(pick_plan 2>/dev/null <<<$'1\nn\n2\ny')
eq "$out" "$p_first" "decline plan 1, then pick 2 - should return plan 2's path"

echo "== pick_plan: an out-of-range number re-prompts and recovers ==" >&2
out=$(pick_plan 2>/dev/null <<<$'9\n1\ny')
eq "$out" "$p_second" "9 is out of range with 2 plans; recovers on 1"

echo "== pick_plan: a non-numeric answer re-prompts and recovers ==" >&2
out=$(pick_plan 2>/dev/null <<<$'foo\n1\ny')
eq "$out" "$p_second" "foo is non-numeric; recovers on 1"

echo "== pick_plan: an empty plans directory returns 2 ==" >&2
reset_plans
pick_plan >/dev/null 2>&1; rc=$?
eq "$rc" "2" "nothing in PLANS_DIR should return 2, not 1"

echo "== pick_plan: PQ_PICK_LIMIT is a page, and n/p walk the pages ==" >&2
# Five plans at a limit of 2 is three pages, the last of them short - which is
# the only fixture shape that exercises a middle page and a partial one at once.
# Spaced with real sleeps, like the ordering fixtures at the top of this file:
# recent_plans breaks an epoch tie on the path, so five plans written inside one
# second would order by name, and a second boundary landing mid-loop would
# reorder them halfway. That is a flaky test, not a fast one.
reset_plans
mkplan p1-oldest.md "Plan One"; sleep 1.1
mkplan p2.md "Plan Two"; sleep 1.1
mkplan p3-middle.md "Plan Three"; sleep 1.1
mkplan p4.md "Plan Four"; sleep 1.1
mkplan p5-newest.md "Plan Five"
p1="$PQ_PLANS_DIR/p1-oldest.md"
p3="$PQ_PLANS_DIR/p3-middle.md"
# Rows, newest first: 1 p5-newest, 2 p4, 3 p3-middle, 4 p2, 5 p1-oldest.
# Which page a header reports is the one thing every case below asserts on, so
# it is read off stderr rather than inferred from what got picked: accepting any
# number in 1-$total means a paging key that did nothing at all would leave most
# stdout assertions passing anyway.
last_page() { grep -o 'page [0-9]/3' <<<"$1" | tail -1; }

err=$(PQ_PICK_LIMIT=2 pick_plan <<<'q' 2>&1 >/dev/null)
case "$err" in *"1-2 of 5 (page 1/3)"*) ok ;; *) bad "header should read '1-2 of 5 (page 1/3)' (got: $err)" ;; esac
case "$err" in *"p5-newest"*) ok ;; *) bad "the newest plan should render on page 1" ;; esac
case "$err" in *"p4"*) ok ;; *) bad "the second-newest plan should render on page 1 too" ;; esac
case "$err" in *"p3-middle"*) bad "page 1 must not render page 2's rows" ;; *) ok ;; esac
case "$err" in *"n older, p newer"*) ok ;; *) bad "more than one page should offer the paging keys" ;; esac

echo "== pick_plan: n pages back to older plans ==" >&2
err=$(PQ_PICK_LIMIT=2 pick_plan <<<$'n\nq' 2>&1 >/dev/null)
case "$err" in *"3-4 of 5 (page 2/3)"*) ok ;; *) bad "n should render page 2 as '3-4 of 5' (got: $err)" ;; esac
case "$err" in *"p3-middle"*) ok ;; *) bad "n should bring the third-newest plan into view" ;; esac

echo "== pick_plan: Enter takes the top of the CURRENT page ==" >&2
# The one case that cannot pass with paging broken: if n had been ignored, Enter
# would take row 1 (p5-newest) instead of row 3.
out=$(PQ_PICK_LIMIT=2 pick_plan <<<$'n\n\ny' 2>/dev/null)
eq "$out" "$p3" "Enter on page 2 should take that page's first row, not the newest plan"

echo "== pick_plan: p pages back towards newer plans ==" >&2
err=$(PQ_PICK_LIMIT=2 pick_plan <<<$'n\np\nq' 2>&1 >/dev/null)
eq "$(last_page "$err")" "page 1/3" "p from page 2 should land back on page 1"
case "$err" in *"page 2/3"*) ok ;; *) bad "page 2 should have been rendered on the way out" ;; esac

echo "== pick_plan: the last page is short, and n cannot go past it ==" >&2
err=$(PQ_PICK_LIMIT=2 pick_plan <<<$'n\nn\nn\nq' 2>&1 >/dev/null)
eq "$(last_page "$err")" "page 3/3" "n past the last page should stay on it"
case "$err" in *"5-5 of 5 (page 3/3)"*) ok ;; *) bad "a short final page should report its real range (got: $err)" ;; esac
case "$err" in *"p1-oldest"*) ok ;; *) bad "the last page should render the oldest plan" ;; esac
case "$err" in *"already at the oldest"*) ok ;; *) bad "n past the end should say so rather than no-op silently" ;; esac

echo "== pick_plan: p cannot go past the first page ==" >&2
err=$(PQ_PICK_LIMIT=2 pick_plan <<<$'p\nq' 2>&1 >/dev/null)
eq "$(last_page "$err")" "page 1/3" "p on page 1 should stay on page 1"
case "$err" in *"already at the newest"*) ok ;; *) bad "p at the front should say so rather than no-op silently" ;; esac

echo "== pick_plan: the numbering is absolute, so an off-page row is still selectable ==" >&2
out=$(PQ_PICK_LIMIT=2 pick_plan <<<$'5\ny' 2>/dev/null)
eq "$out" "$p1" "row 5 should be selectable from page 1"
err=$(PQ_PICK_LIMIT=2 pick_plan <<<$'6\nq' 2>&1 >/dev/null)
case "$err" in *"not a number from 1 to 5"*) ok ;; *) bad "past the last row is still out of range (got: $err)" ;; esac

echo "== pick_plan: declining a preview returns to the page you were reading ==" >&2
err=$(PQ_PICK_LIMIT=2 pick_plan <<<$'n\n3\nn\nq' 2>&1 >/dev/null)
eq "$(last_page "$err")" "page 2/3" "declining should re-render page 2, not the first page"

echo "== pick_plan: one page renders exactly as it did before paging existed ==" >&2
err=$(PQ_PICK_LIMIT=10 pick_plan <<<'q' 2>&1 >/dev/null)
case "$err" in *"5 most recent of 5"*) ok ;; *) bad "a single page keeps the old header (got: $err)" ;; esac
case "$err" in *"[1-5, Enter for 1, q to quit]"*) ok ;; *) bad "a single page keeps the old prompt (got: $err)" ;; esac
case "$err" in *"n older"*) bad "a single page should not offer keys that can only refuse" ;; *) ok ;; esac

echo "== pick_page: a rendered page reports success, and numbers rows absolutely ==" >&2
pp_rows=$(recent_plans)
pp="$PQ_HOME/.pp.tsv"
pick_page "$pp_rows" 1 2 "$pp"; rc=$?
eq "$rc" "0" "pick_page should report success on the first page"
eq "$(wc -l < "$pp" | tr -d ' ')" "3" "a two-row page is a header plus two rows"
eq "$(awk -F'\t' 'NR == 2 { print $1 }' "$pp")" "1" "page 1's first row is numbered 1"
pick_page "$pp_rows" 3 4 "$pp"; rc=$?
eq "$rc" "0" "pick_page should report success on a later page too"
eq "$(awk -F'\t' 'NR == 2 { print $1 }' "$pp")" "3" "page 2's first row keeps its absolute number 3"
eq "$(awk -F'\t' 'NR == 2 { print $3 }' "$pp")" "p3-middle" "page 2's first row is the third-newest plan"
pick_page "$pp_rows" 5 6 "$pp"; rc=$?
eq "$rc" "0" "a page whose upper bound runs past the last row is still a success"
eq "$(wc -l < "$pp" | tr -d ' ')" "2" "that page holds the one row that exists"
rm -f "$pp"

echo "== pick_after: 1,3 selects the right slugs; space/comma forms agree; duplicates collapse ==" >&2
reset_tasks
mk_task queue 010 task-a "$REPO" tom/task-a >/dev/null
mk_task queue 020 task-b "$REPO" tom/task-b >/dev/null
mk_task hold  030 task-c "$REPO" tom/task-c >/dev/null

# `after_vals` and friends are cmd_add's own locals, reached through bash's
# dynamic scope - this wrapper stands in for cmd_add so pick_after can mutate
# them the same way it would there. Run inside a command substitution: that
# forks a subshell, but the mutation only needs to survive long enough for
# this wrapper's own final printf, which happens before the subshell exits.
run_pick_after() {                      # repo -> echoes the resulting after_vals
  local split=0 split_dir="" after_vals="" after_explicit=0 repo=$1
  pick_after
  printf '%s' "$after_vals"
}

want=$(printf 'task-a\ntask-c\n')
out=$(run_pick_after "$REPO" <<<$'1,3\n' 2>/dev/null)
eq "$out" "$want" "1,3 should select task-a and task-c, in that order"
out=$(run_pick_after "$REPO" <<<$'1 3\n' 2>/dev/null)
eq "$out" "$want" "space-separated '1 3' should agree with '1,3'"
out=$(run_pick_after "$REPO" <<<$'1, 3\n' 2>/dev/null)
eq "$out" "$want" "'1, 3' (comma then space) should also agree"
out=$(run_pick_after "$REPO" <<<$'1,1,3\n' 2>/dev/null)
eq "$out" "$want" "a repeated '1,1,3' should collapse to the same result as '1,3'"

echo "== pick_after: Enter selects none ==" >&2
out=$(run_pick_after "$REPO" <<<$'\n' 2>/dev/null)
eq "$out" "" "Enter should leave after_vals empty"

echo "== pick_after: out-of-range or non-numeric rejects the whole line and re-prompts ==" >&2
out=$(run_pick_after "$REPO" <<<$'9\n1\n' 2>/dev/null)
eq "$out" "task-a" "an out-of-range line is rejected outright; the retry (1) picks task-a"
out=$(run_pick_after "$REPO" <<<$'foo\n2\n' 2>/dev/null)
eq "$out" "task-b" "a non-numeric line is rejected outright; the retry (2) picks task-b"

echo "== pick_after: a done task is never offered ==" >&2
mk_task done 040 task-d "$REPO" tom/task-d >/dev/null
err=$(run_pick_after "$REPO" <<<$'\n' 2>&1 >/dev/null)
case "$err" in *"3 tasks"*) ok ;; *) bad "a done task must not count as a candidate (got: $err)" ;; esac
case "$err" in *"task-d"*) bad "a done task must never be listed" ;; *) ok ;; esac

echo "== pick_after: no candidates at all - the prompt is skipped silently ==" >&2
reset_tasks
out=$(run_pick_after "$REPO" 2>"$PQ_HOME/.noneerr" </dev/null)
eq "$out" "" "no candidates: after_vals stays empty"
eq "$(cat "$PQ_HOME/.noneerr")" "" "no candidates: nothing is printed, not even an empty table"

echo "== pick_after: a PROJECT column appears only once candidates span two repos ==" >&2
reset_tasks
mk_task queue 010 task-a "$REPO" tom/task-a >/dev/null
mk_task queue 020 task-b "$REPO" tom/task-b >/dev/null
err=$(run_pick_after "$REPO" <<<$'\n' 2>&1 >/dev/null)
case "$err" in *PROJECT*) bad "a single-repo candidate list should not show a PROJECT column" ;; *) ok ;; esac

REPO2=$(mktemp -d)
git init -q -b master "$REPO2"
git -C "$REPO2" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mk_task queue 030 task-e "$REPO2" tom/task-e >/dev/null
err=$(run_pick_after "$REPO" <<<$'\n' 2>&1 >/dev/null)
case "$err" in *PROJECT*) ok ;; *) bad "candidates spanning two repos should show a PROJECT column" ;; esac

echo "== add_wizard: split=1 and after_explicit=1 together ask nothing at all ==" >&2
reset_tasks
run_wizard() {                          # split after_explicit -> "split=X after_vals=[Y]"
  local split=$1 split_dir="" after_vals="" after_explicit=$2 repo=$REPO
  add_wizard
  printf 'split=%s after_vals=[%s]' "$split" "$after_vals"
}
out=$(run_wizard 1 1 </dev/null)
eq "$out" "split=1 after_vals=[]" "both already decided: no prompt should even try to read stdin"

echo "== add_wizard: answering y to the split question sets split=1 ==" >&2
out=$(run_wizard 0 1 <<<$'y\n')
eq "$out" "split=1 after_vals=[]" "y at the split prompt should set split=1; after_explicit=1 skips the blocker prompt"

echo "== add_wizard: split already 1 skips that question; the blocker prompt still runs ==" >&2
mk_task queue 010 task-a "$REPO" tom/task-a >/dev/null
out=$(run_wizard 1 0 <<<$'1\n')
eq "$out" "split=1 after_vals=[task-a"$'\n'"]" \
  "split=1 skips its question outright; picking 1 at the blocker prompt selects task-a"

echo "== wiring: bare 'main add' with no tty queues latest_plan() ==" >&2
reset_plans
reset_tasks
printf 'MARKER: wiring-fixture\n\nDo the wiring thing.\n' > "$PQ_PLANS_DIR/wiring.md"
slug=$(main add --repo "$REPO" < /dev/null 2>"$PQ_HOME/.wire.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "bare 'main add' with no tty should succeed: $(cat "$PQ_HOME/.wire.err")"
t=$(find_task "$slug")
eq "$(hdr "$t/plan.md" source)" "$PQ_PLANS_DIR/wiring.md" \
  "with no tty and no plan given, source: should be latest_plan()'s path"

echo "== wiring: -y also takes the newest without asking ==" >&2
reset_tasks
slug=$(main add --repo "$REPO" -y < /dev/null 2>"$PQ_HOME/.wire2.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "-y should succeed: $(cat "$PQ_HOME/.wire2.err")"
t=$(find_task "$slug")
eq "$(hdr "$t/plan.md" source)" "$PQ_PLANS_DIR/wiring.md" "-y should also queue the newest plan"

echo "== wiring: a task queued with pick_after's blockers matches an equivalent --after ==" >&2
reset_tasks
mk_task queue 005 blocker-cand "$REPO" tom/blocker-cand >/dev/null
via_picker=$(run_pick_after "$REPO" <<<$'1\n' 2>/dev/null)
eq "$via_picker" "blocker-cand" "pick_after should resolve to the candidate's own slug"

out_x=$(main add "$PQ_PLANS_DIR/wiring.md" --repo "$REPO" --branch tom/task-x --intent x --after blocker-cand -y 2>"$PQ_HOME/.x.err")
t_x=$(find_task "$out_x")
out_y=$(main add "$PQ_PLANS_DIR/wiring.md" --repo "$REPO" --branch tom/task-y --intent y --after "$via_picker" -y 2>"$PQ_HOME/.y.err")
t_y=$(find_task "$out_y")
eq "$(cat "$t_x/after")" "$(cat "$t_y/after")" \
  "queuing via --after blocker-cand and via --after <pick_after's own output> must produce identical after files"

echo "== wiring: an explicit plan path is completely unchanged ==" >&2
reset_tasks
slug=$(main add "$PQ_PLANS_DIR/wiring.md" --repo "$REPO" --branch tom/explicit-path --intent explicit -y \
  2>"$PQ_HOME/.explicit.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "an explicit plan path should still work exactly as before: $(cat "$PQ_HOME/.explicit.err")"
t=$(find_task "$slug")
eq "$(hdr "$t/plan.md" source)" "$PQ_PLANS_DIR/wiring.md" "an explicit plan path should never reach the picker"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
