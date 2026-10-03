#!/usr/bin/env bash
# test/pq-add-pick.sh - the interactive plan picker: recent_plans
# ordering, plan_title, cell, age_since, pick_plan, pick_after, add_wizard,
# and the wiring into cmd_add. The prompts are gum's, so a PATH-stubbed `gum`
# (test/lib.sh) answers them and logs what it was asked.
#
# Plain bash, no framework, a temp PQ_HOME exported BEFORE sourcing pq, a PATH-stubbed `claude` and `gh` so
# nothing here ever reaches the network, ok/bad/eq, trap cleanup EXIT, and a
# throwaway git repo with refs/remotes/origin/HEAD faked by hand.
#
# The first test in the repo to use PQ_PLANS_DIR - exported before `source`,
# exactly like PQ_HOME, since PLANS_DIR="${PQ_PLANS_DIR:-$HOME/.claude/plans}"
# is evaluated at source time. Exporting it after sourcing would leave
# PLANS_DIR baked to the real ~/.claude/plans, and every test below would
# read (and the wiring cases would queue) whatever is actually there.
#
# SC2015: `ok` never fails, so `[ ... ] && ok || bad` is an if/else.
# shellcheck disable=SC2015
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PQ_HOME=$(mktemp -d)
export PQ_HOME
PQ_PLANS_DIR=$(mktemp -d)
export PQ_PLANS_DIR

STUBBIN=$(mktemp -d)
# Dispatches on --model. Only the wiring cases at the bottom ever reach this
# without add_as standing in for the namer, so only one marker is needed.
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
# shellcheck source=test/lib.sh
source "$HERE/lib.sh"
gum_stub "$STUBBIN" "$PQ_HOME/.gum"
# The terminal is stood in for; the no-terminal case turns it off.
FAKE_TTY=1
at_terminal() { [ "$FAKE_TTY" = 1 ]; }

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
  rm -rf "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done"
  mkdir -p "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done"
}
reset_tasks

# A task built by hand, bypassing the real dispatch path - same idiom as
# test/pq-reap.sh's mk_done, just parameterised over the state.
mk_task() {                             # state prio slug repo branch -> task_dir
  local state=$1 prio=$2 slug=$3 repo=$4 branch=$5
  # $prio is relative order, not a stamp - it is offset into a real
  # timestamp so a fixture reads like a task pq made.
  # $((10#$prio)) rather than a bare $prio: inside $(( )) a leading-zero
  # literal like 020 is octal, exactly the bug this fixture must not
  # reintroduce - and this file's own call sites pass 010/020/030/040/005.
  local dir
  dir="$PQ_HOME/$state/$(printf '%014d' $(( 20260101000000 + 10#$prio )))-$slug"
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


echo "== recent_plans: ordering by max(mtime, birth) ==" >&2
# stat's %m and %B are whole seconds, so fixtures must be spaced out for real,
# not merely touch -t'd - touch cannot age a file anyway, since birth time is
# untouched by it and max(mtime, birth) would just return birth unchanged.
reset_plans
mkplan a.md "Plan A"; sleep 1.1
mkplan b.md "Plan B"; sleep 1.1
mkplan c.md "Plan C"

order() { recent_plans | awk -F'\t' '{ print $2 }' | xargs -n1 basename | tr '\n' ' '; }
eq "$(order)" "c.md b.md a.md " "recent_plans should list c, b, a - newest created first"

sleep 1.1
touch "$PQ_PLANS_DIR/a.md"
eq "$(order)" "a.md c.md b.md " "touching a should move it back to the front, ahead of c and b"

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
# filter, pager, confirm. Row 1 is the newest.
gum_reset; gum_answer "@2"; gum_answer ""; gum_answer ""
out=$(pick_plan 2>/dev/null); rc=$?
eq "$rc" "0" "choosing and confirming a plan succeeds"
eq "$out" "$PQ_PLANS_DIR/1-first.md" "row 2 (the older plan) returns exactly its path on stdout"
gum_reset; gum_answer "@1"; gum_answer ""; gum_answer ""
eq "$(pick_plan 2>/dev/null)" "$PQ_PLANS_DIR/2-second.md" "row 1 is the newest plan"

echo "== pick_plan: the list shows age, name and title, newest first ==" >&2
disp=$(gum_stdin 1)
eq "$(wc -l <<<"$disp" | tr -d ' ')" "2" "one line per plan"
case "$(sed -n 1p <<<"$disp")" in *2-second*"Second plan"*) ok ;; *) bad "the newest plan leads, with its name and title (got: $disp)" ;; esac

echo "== pick_plan: the chosen plan is paged to read, then confirmed ==" >&2
case "$(gum_calls)" in
  *"filter"*$'\n'*"pager"*$'\n'*"confirm"*"use this plan?"*) ok ;;
  *) bad "filter, then pager, then confirm should be asked in that order (got: $(gum_calls))" ;;
esac

echo "== pick_plan: declining goes back to the list, Esc there quits ==" >&2
gum_reset; gum_answer "@1"; gum_answer ""; gum_answer "" 1; gum_answer "@2"; gum_answer ""; gum_answer ""
eq "$(pick_plan 2>/dev/null)" "$PQ_PLANS_DIR/1-first.md" "decline plan 1, then pick 2 - should return plan 2's path"
gum_reset; gum_answer "" 130
out=$(pick_plan 2>/dev/null); rc=$?
eq "$rc" "1" "cancelling the list returns 1"
eq "$out" "" "and prints nothing to stdout"

echo "== pick_plan: an empty plans directory returns 2 ==" >&2
reset_plans
gum_reset
pick_plan >/dev/null 2>&1; rc=$?
eq "$rc" "2" "nothing in PLANS_DIR should return 2, not 1"
eq "$(gum_calls)" "" "and gum is never asked"

echo "== pick_after: ticked tasks come back as slugs; duplicates collapse ==" >&2
reset_tasks
mk_task queue 010 task-a "$REPO" tom/task-a >/dev/null
mk_task queue 020 task-b "$REPO" tom/task-b >/dev/null
mk_task queue 030 task-c "$REPO" tom/task-c >/dev/null

# `after_vals` and friends are cmd_add's own locals, reached through bash's
# dynamic scope - this wrapper stands in for cmd_add so pick_after can mutate
# them the same way it would there.
run_pick_after() {                      # -> echoes the resulting after_vals
  local after_vals="" repo=$REPO
  pick_after
  printf '%s' "$after_vals"
}
gum_reset; gum_answer $'task-a  queue   \ntask-c  queue   '
out=$(run_pick_after 2>/dev/null)
eq "$out" $'task-a\ntask-c' "ticking a and c selects task-a and task-c, in that order"
eq "$(gum_stdin 1 | wc -l | tr -d ' ')" "3" "all three queued tasks are offered"

echo "== pick_after: nothing ticked selects none, Esc stops ==" >&2
gum_reset; gum_answer ""
eq "$(run_pick_after 2>/dev/null)" "" "Enter with nothing ticked means no blockers"
gum_reset; gum_answer "" 130
( run_pick_after ) >/dev/null 2>&1 && bad "Esc at the blocker question should stop the add" || ok

echo "== pick_after: a done task is never offered ==" >&2
mk_task "done" 040 task-done "$REPO" tom/task-done >/dev/null
gum_reset; gum_answer ""
run_pick_after >/dev/null 2>&1
case "$(gum_stdin 1)" in *task-done*) bad "a done task must not count as a candidate" ;; *) ok ;; esac

echo "== pick_after: a running task IS offered - work in flight is a real blocker ==" >&2
mk_task running 050 task-run "$REPO" tom/task-run >/dev/null
gum_reset; gum_answer ""
run_pick_after >/dev/null 2>&1
case "$(gum_stdin 1)" in *task-run*running*) ok ;; *) bad "a running task should be listed with its state" ;; esac

echo "== pick_after: no candidates at all - gum is not asked ==" >&2
reset_tasks
gum_reset
out=$(run_pick_after 2>/dev/null)
eq "$out" "" "no candidates, no blockers"
eq "$(gum_calls)" "" "and no prompt"

echo "== pick_after: a project appears only once candidates span two repos ==" >&2
mk_task queue 010 task-a "$REPO" tom/task-a >/dev/null
gum_reset; gum_answer ""
run_pick_after >/dev/null 2>&1
case "$(gum_stdin 1)" in *"$(basename "$REPO")"*) bad "one repo needs no project column" ;; *) ok ;; esac
REPO2=$(mktemp -d)
git init -q -b master "$REPO2"
mk_task queue 030 task-e "$REPO2" tom/task-e >/dev/null
gum_reset; gum_answer ""
run_pick_after >/dev/null 2>&1
case "$(gum_stdin 1)" in *"$(basename "$REPO2")"*) ok ;; *) bad "candidates spanning two repos should name their project" ;; esac

echo "== add_wizard: model and effort are asked, starting on their defaults ==" >&2
reset_tasks
# shellcheck disable=SC2034  # add_wizard reads and sets these through bash's dynamic scope
run_wizard() {                          # -> "model=M effort=E after_vals=[Y]"
  local after_vals="" repo=$REPO model=$PQ_DEFAULT_MODEL effort=$PQ_DEFAULT_EFFORT
  local design_hinted=${1:-0} design_vals=""
  add_wizard
  printf 'model=%s effort=%s after_vals=[%s] design=[%s]' "$model" "$effort" "$after_vals" "$design_vals"
}
gum_reset; gum_answer "opus"; gum_answer "high"
out=$(run_wizard 2>/dev/null)
eq "$out" "model=opus effort=high after_vals=[] design=[]" "the model and effort chosen are the ones taken"
case "$(gum_calls)" in
  *"choose"*"--selected sonnet"*"sonnet opus fable"*$'\n'*"choose"*"--selected medium"*"low medium high xhigh max"*) ok ;;
  *) bad "each choice should start on its default (got: $(gum_calls))" ;;
esac
gum_reset; gum_answer "fable"; gum_answer "xhigh"
out=$(PQ_DEFAULT_MODEL=opus run_wizard 2>/dev/null)
eq "$out" "model=fable effort=xhigh after_vals=[] design=[]" "an overridden default is still only where the choice starts"
case "$(gum_calls)" in *"--selected sonnet"*) bad "the default is read when asked, not baked in" ;; *) ok ;; esac

echo "== add_wizard: Esc at a question stops the add ==" >&2
gum_reset; gum_answer "" 130
( run_wizard ) >/dev/null 2>"$PQ_HOME/.esc.err" && bad "Esc at the model question should stop" || ok
case "$(cat "$PQ_HOME/.esc.err")" in *cancelled*) ok ;; *) bad "and say so" ;; esac
gum_reset; gum_answer "opus"; gum_answer "" 130
( run_wizard ) >/dev/null 2>&1 && bad "Esc at the effort question should stop" || ok

echo "== add_wizard: the blocker question runs last ==" >&2
mk_task queue 010 task-a "$REPO" tom/task-a >/dev/null
gum_reset; gum_answer "sonnet"; gum_answer "medium"; gum_answer "task-a  queue"
out=$(run_wizard 2>/dev/null)
eq "$out" "model=sonnet effort=medium after_vals=[task-a"$'\n'"] design=[]" "picking task-a selects it"

echo "== add_wizard: a design plan with no file found asks for one; Esc goes without ==" >&2
reset_tasks
printf 'x' > "$PQ_HOME/shot.png"
gum_reset; gum_answer "sonnet"; gum_answer "medium"; gum_answer "$PQ_HOME/shot.png"
out=$(run_wizard 1 2>/dev/null)
eq "$out" "model=sonnet effort=medium after_vals=[] design=[$PQ_HOME/shot.png"$'\n'"]" "the picked file is the design"
gum_reset; gum_answer "sonnet"; gum_answer "medium"; gum_answer "" 1
out=$(run_wizard 1 2>"$PQ_HOME/.nod.err")
eq "$out" "model=sonnet effort=medium after_vals=[] design=[]" "Esc means none"
case "$(cat "$PQ_HOME/.nod.err")" in *"no design file"*) ok ;; *) bad "and it says so loudly" ;; esac
gum_reset; gum_answer "sonnet"; gum_answer "medium"
run_wizard 0 >/dev/null 2>&1
eq "$(gum_calls | grep -c ' file')" "0" "a plan that is not about a design is never asked for one"

echo "== wiring: with no terminal, pq add stops and queues nothing ==" >&2
reset_plans
reset_tasks
printf 'MARKER: wiring-fixture\n\nDo the wiring thing.\n' > "$PQ_PLANS_DIR/wiring.md"
gum_reset; FAKE_TTY=0
if ( cd "$REPO" && main add < /dev/null ) >/dev/null 2>"$PQ_HOME/.wire.err"; then
  bad "pq add with no terminal should stop"
else
  ok
fi
case "$(cat "$PQ_HOME/.wire.err")" in
  *"run it at a terminal"*) ok ;;
  *) bad "and say it needs a terminal (got: $(cat "$PQ_HOME/.wire.err"))" ;;
esac
eq "$(find "$PQ_HOME/queue" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "0" "nothing is queued"
eq "$(gum_calls)" "" "and nothing is asked"
FAKE_TTY=1

echo "== wiring: at a terminal, main add picks, names, asks and queues ==" >&2
# The answers, in order: the plan
# list, the pager, the confirm, the model, the effort. An empty queue leaves no
# blocker to ask about.
gum_reset; gum_answer "@1"; gum_answer ""; gum_answer ""; gum_answer "opus"; gum_answer "high"
out=$( ( cd "$REPO" && main add ) 2>"$PQ_HOME/.wire2.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "main add through the wizard should succeed: $(cat "$PQ_HOME/.wire2.err")"
eq "$out" "" "nothing goes to stdout - everything a human reads is on stderr"
t=$(find_task wiring-fixture-task)
eq "$(hdr "$t/plan.md" source)" "$PQ_PLANS_DIR/wiring.md" "the picked plan is the one queued"
eq "$(hdr "$t/plan.md" branch)" "tom/wiring-fixture-task" "named by Haiku"
eq "$(hdr "$t/plan.md" model)" "opus" "the model chosen"
eq "$(hdr "$t/plan.md" effort)" "high" "the effort chosen"

echo "== wiring: Esc at the effort question queues nothing ==" >&2
reset_tasks
gum_reset; gum_answer "@1"; gum_answer ""; gum_answer ""; gum_answer "opus"; gum_answer "" 130
( cd "$REPO" && main add ) >/dev/null 2>&1 && bad "a cancelled wizard should fail" || ok
eq "$(find "$PQ_HOME/queue" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "0" "nothing is queued"
eq "$(find "$PQ_HOME" -maxdepth 1 -name '.add.*' | wc -l | tr -d ' ')" "0" "and no staging is left behind"

echo "== wiring: a blocker ticked in the wizard lands in the task's after file ==" >&2
reset_tasks
mk_task queue 005 blocker-cand "$REPO" tom/blocker-cand >/dev/null
gum_reset; gum_answer "@1"; gum_answer ""; gum_answer ""; gum_answer "sonnet"; gum_answer "medium"; gum_answer "blocker-cand  queue"
( cd "$REPO" && main add ) >/dev/null 2>&1
t=$(find_task wiring-fixture-task)
case "$(cat "$t/after" 2>/dev/null)" in *tom/blocker-cand*) ok ;; *) bad "the blocker should gate the new task (after: $(cat "$t/after" 2>/dev/null))" ;; esac

echo "== wiring: pq add takes no arguments - the wizard is the way in ==" >&2
reset_tasks
for arg in "$PQ_PLANS_DIR/wiring.md" --model; do
  if ( cd "$REPO" && main add "$arg" < /dev/null ) >/dev/null 2>"$PQ_HOME/.explicit.err"; then
    bad "pq add '$arg' should be refused"
  else
    ok
  fi
  case "$(cat "$PQ_HOME/.explicit.err")" in
    *"pq add takes no arguments"*) ok ;;
    *) bad "the refusal should say why (got: $(cat "$PQ_HOME/.explicit.err"))" ;;
  esac
done

echo "== wiring: without gum, pq add and pq rm say what to install ==" >&2
for c in add rm; do
  # shellcheck disable=SC2086  # $c is one word
  out=$( ( PATH=/usr/bin:/bin; command -v gum >/dev/null && exit 9; cd "$REPO" && main $c </dev/null ) 2>&1 )
  case "$out" in *"brew install gum"*) ok ;; *) bad "pq $c without gum should say how to get it (got: $out)" ;; esac
done

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
