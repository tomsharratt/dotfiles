#!/usr/bin/env bash
# test/pq-add-pick.sh - the interactive plan picker: recent_plans
# ordering, plan_rows, cell, age_since, pick_plan, pick_after, add_wizard,
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
        : > "$(dirname "$0")/.haiku-called"
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
# Physical, as pq add resolves it through git worktree list (/private/var, not /var).
REPO=$(cd "$(mktemp -d)" && pwd -P)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$REPO/.git/refs/remotes/origin"
git -C "$REPO" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master

reset_plans() { rm -rf "$PQ_PLANS_DIR"; mkdir -p "$PQ_PLANS_DIR"; }
mkplan() { printf '# %s\n\nBody.\n' "$2" > "$PQ_PLANS_DIR/$1"; }        # filename title

reset_tasks() {
  rm -rf "$PQ_HOME/new" "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done"
  mkdir -p "$PQ_HOME/new" "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done"
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

echo "== plan_rows: the title ==" >&2
title_of() { printf '0\t%s\n' "$1" | plan_rows | cut -c 11-; }
printf '# Real Title\n\nBody.\n' > "$PQ_HOME/.t1.md"
eq "$(title_of "$PQ_HOME/.t1.md")" "Real Title" "an H1 has its marker stripped"

printf '\n\n  \nJust text, no heading.\nMore.\n' > "$PQ_HOME/.t2.md"
eq "$(title_of "$PQ_HOME/.t2.md")" "Just text, no heading." \
  "no H1: the first non-blank line is the fallback, leading blanks skipped"

printf '## Sub Title\n\nBody.\n' > "$PQ_HOME/.t3.md"
eq "$(title_of "$PQ_HOME/.t3.md")" "Sub Title" "## is stripped too, not just a single #"

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

echo "== pick_plan: the list shows age and title, newest first ==" >&2
disp=$(gum_stdin 1)
eq "$(wc -l <<<"$disp" | tr -d ' ')" "2" "one line per plan"
case "$(sed -n 1p <<<"$disp")" in *"Second plan"*) ok ;; *) bad "the newest plan leads, with its title (got: $disp)" ;; esac

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

echo "== pick_after: nothing comes first, then the candidates, newest first ==" >&2
reset_tasks
A=$(mk_task queue 010 task-a "$REPO" tom/task-a)
mk_task queue 020 task-b "$REPO" tom/task-b >/dev/null
C=$(mk_task queue 030 task-c "$REPO" tom/task-c)

# `after_vals` and `repo` are cmd_add's own locals, reached through bash's
# dynamic scope - this wrapper stands in for cmd_add so pick_after can read and
# mutate them the same way it would there.
run_pick_after() {                      # -> echoes the resulting after_vals
  local after_vals="" repo=$REPO
  pick_after
  printf '%s' "$after_vals"
}
gum_reset; gum_answer "@1"
out=$(run_pick_after 2>/dev/null)
eq "$out" "" "picking the first row means no dependency"
eq "$(gum_stdin 1 | sed -n 1p)" "nothing - start from master" "the first row is nothing, naming the default branch"
eq "$(gum_stdin 1 | sed -n '2,$p' | awk '{ print $1 }' | tr '\n' ' ')" "task-c task-b task-a " "the candidates follow, newest first"
case "$(gum_stdin 1 | sed -n 2p)" in *task-c*queue*"stack on it") ok ;; *) bad "a same-repo row reads stack on it (got: $(gum_stdin 1 | sed -n 2p))" ;; esac
eq "$(gum_stdin 1 | grep -c ' $')" "0" "with no trailing padding on any line"
case "$(gum_calls)" in *"--no-limit"*) bad "one pick, not a checklist (got: $(gum_calls))" ;; *) ok ;; esac
case "$(gum_calls)" in *"--selected"*) bad "no --selected: the cursor starts on nothing (got: $(gum_calls))" ;; *) ok ;; esac
case "$(gum_calls)" in *"--header build on which? Enter picks"*) ok ;; *) bad "the question is build on which (got: $(gum_calls))" ;; esac

echo "== pick_after: the nothing row never asks the forge ==" >&2
# No origin/HEAD: the row names the default branch from origin's refs, or not at
# all - never through repo_base's gh fallback, which would stall pq add.
git -C "$REPO" symbolic-ref --delete refs/remotes/origin/HEAD
printf '#!/bin/sh\necho "$*" >> "%s"\nexit 1\n' "$PQ_HOME/.gh-asked" > "$STUBBIN/gh"
gum_reset; gum_answer "@1"
run_pick_after >/dev/null 2>&1
eq "$(gum_stdin 1 | sed -n 1p)" "nothing - start from master" "origin's master names it"
[ -e "$PQ_HOME/.gh-asked" ] && bad "gh was asked: $(cat "$PQ_HOME/.gh-asked")" || ok
git -C "$REPO" update-ref -d refs/remotes/origin/master
gum_reset; gum_answer "@1"
run_pick_after >/dev/null 2>&1
eq "$(gum_stdin 1 | sed -n 1p)" "nothing - start from the default branch" "and with nothing known, it says so"
git -C "$REPO" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/gh"

echo "== pick_after: one pick comes back as its stamp; Enter on nothing, or Esc ==" >&2
gum_reset; gum_answer "@4"
eq "$(run_pick_after 2>/dev/null)" "$(stamp_of "$A")" "picking task-a selects its stamp"
gum_reset; gum_answer "@2"
eq "$(run_pick_after 2>/dev/null)" "$(stamp_of "$C")" "the row under nothing is the newest"
gum_reset; gum_answer ""
eq "$(run_pick_after 2>/dev/null)" "" "an empty answer is nothing too"
gum_reset; gum_answer "" 130
( run_pick_after ) >/dev/null 2>&1 && bad "Esc at the question should stop the add" || ok

echo "== pick_after: a done task is offered until its pull request merges or closes ==" >&2
# Done is where a task waits on its reviewers, and on you - work that has not
# landed, and a real thing to build on. Only the verdict pq has recorded is read.
D=$(mk_task "done" 040 task-review "$REPO" tom/task-review)
gum_reset; gum_answer ""
run_pick_after >/dev/null 2>&1
case "$(gum_stdin 1)" in *task-review*done*) ok ;; *) bad "a done task still in review should be offered (got: $(gum_stdin 1))" ;; esac
st_set "$D" PQ_MERGED 2026-01-02T00:00:00Z
M=$(mk_task "done" 041 task-closed "$REPO" tom/task-closed)
st_set "$M" PQ_CLOSED 2026-01-02T00:00:00Z
gum_reset; gum_answer ""
run_pick_after >/dev/null 2>&1
case "$(gum_stdin 1)" in *task-review*) bad "a merged task has nothing left to build on" ;; *) ok ;; esac
case "$(gum_stdin 1)" in *task-closed*) bad "nor has a closed one" ;; *) ok ;; esac
rm -rf "$D" "$M"

echo "== pick_after: a task with no name yet is offered, under its plan's title ==" >&2
N=$(mk_task new 045 step-1-pr-01a-schema "$REPO" "")
gum_reset; gum_answer "@2"
out=$(run_pick_after 2>/dev/null)
case "$(gum_stdin 1)" in *step-1-pr-01a-schema*new*) ok ;; *) bad "a new task should be listed with its state (got: $(gum_stdin 1))" ;; esac
eq "$out" "$(stamp_of "$N")" "and comes back as its stamp, the one name naming does not change"
rm -rf "$N"

echo "== pick_after: a running task IS offered - work in flight can be built on ==" >&2
mk_task running 050 task-run "$REPO" tom/task-run >/dev/null
gum_reset; gum_answer ""
run_pick_after >/dev/null 2>&1
case "$(gum_stdin 1)" in *task-run*running*) ok ;; *) bad "a running task should be listed with its state" ;; esac

echo "== pick_after: a task something already builds on is not offered ==" >&2
reset_tasks
P=$(mk_task queue 010 built-parent "$REPO" tom/built-parent)
K=$(mk_task queue 020 built-child "$REPO" tom/built-child)
printf 'built-parent\t%s\ttom/built-parent\n' "$REPO" > "$K/after"
U=$(mk_task new 030 unnamed-parent "$REPO" "")
V=$(mk_task new 040 unnamed-child "$REPO" "")
printf '%s\n' "$(stamp_of "$U")" > "$V/after.new"
gum_reset; gum_answer ""
run_pick_after >/dev/null 2>&1
case "$(gum_stdin 1)" in *built-parent*) bad "built-parent is built on by built-child, through after" ;; *) ok ;; esac
case "$(gum_stdin 1)" in *unnamed-parent*) bad "unnamed-parent is built on by unnamed-child, through after.new" ;; *) ok ;; esac
case "$(gum_stdin 1)" in *built-child*) ok ;; *) bad "the top of a line is still offered (got: $(gum_stdin 1))" ;; esac
case "$(gum_stdin 1)" in *unnamed-child*) ok ;; *) bad "so is one in new/" ;; esac
rm -f "$K/after" "$V/after.new"; : "$P"

echo "== pick_after: no candidates at all - gum is not asked ==" >&2
reset_tasks
gum_reset
out=$(run_pick_after 2>/dev/null)
eq "$out" "" "no candidates, no dependency"
eq "$(gum_calls)" "" "and no prompt"

echo "== pick_after: a task in another repo is waited for, and names its repo ==" >&2
mk_task queue 010 task-a "$REPO" tom/task-a >/dev/null
REPO2=$(cd "$(mktemp -d)" && pwd -P)
git init -q -b master "$REPO2"
W=$(mk_task queue 030 task-e "$REPO2" tom/task-e)
gum_reset; gum_answer ""
run_pick_after >/dev/null 2>&1
case "$(gum_stdin 1)" in *task-a*"queue"*"stack on it"*) ok ;; *) bad "the same-repo row is a stack (got: $(gum_stdin 1))" ;; esac
case "$(gum_stdin 1)" in *task-e*"$(basename "$REPO2"): wait for its merge"*) ok ;; *) bad "the other-repo row names its repo and waits (got: $(gum_stdin 1))" ;; esac
case "$(gum_stdin 1 | grep task-a)" in *"$(basename "$REPO")"*) bad "a same-repo row needs no repo name" ;; *) ok ;; esac
# A task in another repo waiting for task-a is a wait, not a stack on it.
printf 'task-a\t%s\ttom/task-a\n' "$REPO" > "$W/after"
gum_reset; gum_answer ""
run_pick_after >/dev/null 2>&1
case "$(gum_stdin 1)" in *task-a*) ok ;; *) bad "a cross-repo wait does not hide task-a" ;; esac
rm -f "$W/after"

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

echo "== add_wizard: the build-on question runs last ==" >&2
A=$(mk_task queue 010 task-a "$REPO" tom/task-a)
gum_reset; gum_answer "sonnet"; gum_answer "medium"; gum_answer "@2"
out=$(run_wizard 2>/dev/null)
eq "$out" "model=sonnet effort=medium after_vals=[$(stamp_of "$A")"$'\n'"] design=[]" "picking task-a selects it"

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

echo "== wiring: at a terminal, main add picks and asks, and leaves the naming to the tick ==" >&2
# The answers, in order: the plan
# list, the pager, the confirm, the model, the effort. An empty queue leaves no
# blocker to ask about.
rm -f "$STUBBIN/.haiku-called"
gum_reset; gum_answer "@1"; gum_answer ""; gum_answer ""; gum_answer "opus"; gum_answer "high"
out=$( ( cd "$REPO" && main add ) 2>"$PQ_HOME/.wire2.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "main add through the wizard should succeed: $(cat "$PQ_HOME/.wire2.err")"
eq "$out" "" "nothing goes to stdout - everything a human reads is on stderr"
[ -e "$STUBBIN/.haiku-called" ] && bad "pq add must not wait on Haiku - naming is the tick's" || ok
t=$(find_task marker-wiring-fixture)
eq "$(state_of "$t")" "new" "it lands in new/, under its plan's title"
eq "$(hdr "$t/plan.md" source)" "$PQ_PLANS_DIR/wiring.md" "the picked plan is the one added"
eq "$(hdr "$t/plan.md" branch)" "" "with no branch yet"
eq "$(hdr "$t/plan.md" model)" "opus" "the model chosen"
eq "$(hdr "$t/plan.md" effort)" "high" "the effort chosen"
case "$(cat "$PQ_HOME/.wire2.err")" in *"added:  new/"*"the next tick names it"*) ok ;; *) bad "and it says the tick names it (got: $(cat "$PQ_HOME/.wire2.err"))" ;; esac
name_task "$t" 0 2>/dev/null && ok || bad "the tick's naming should queue it"
t=$(find_task wiring-fixture-task)
eq "$(state_of "$t")" "queue" "named by Haiku, and queued"
eq "$(hdr "$t/plan.md" branch)" "tom/wiring-fixture-task" "under Haiku's branch"
eq "$(hdr "$t/plan.md" model)" "opus" "keeping the model chosen"

echo "== wiring: Esc at the effort question queues nothing ==" >&2
reset_tasks
gum_reset; gum_answer "@1"; gum_answer ""; gum_answer ""; gum_answer "opus"; gum_answer "" 130
( cd "$REPO" && main add ) >/dev/null 2>&1 && bad "a cancelled wizard should fail" || ok
eq "$(find "$PQ_HOME/queue" "$PQ_HOME/new" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "0" "nothing is added"
eq "$(find "$PQ_HOME" -maxdepth 1 -name '.add.*' | wc -l | tr -d ' ')" "0" "and no staging is left behind"

echo "== wiring: the task picked in the wizard lands in the task's after file ==" >&2
reset_tasks
mk_task queue 005 blocker-cand "$REPO" tom/blocker-cand >/dev/null
gum_reset; gum_answer "@1"; gum_answer ""; gum_answer ""; gum_answer "sonnet"; gum_answer "medium"; gum_answer "@2"
( cd "$REPO" && main add ) >/dev/null 2>"$PQ_HOME/.pick.err"
t=$(find_task marker-wiring-fixture)
eq "$(cat "$t/after" 2>/dev/null)" "blocker-cand"$'\t'"$REPO"$'\t'"tom/blocker-cand" "one line, the task it builds on"
case "$(cat "$PQ_HOME/.pick.err")" in *"on:     blocker-cand - starts when its pull request is ready for review"*) ok ;; *) bad "the add says what it builds on (got: $(cat "$PQ_HOME/.pick.err"))" ;; esac

echo "== wiring: nothing picked means no after file at all ==" >&2
reset_tasks
mk_task queue 005 blocker-cand "$REPO" tom/blocker-cand >/dev/null
gum_reset; gum_answer "@1"; gum_answer ""; gum_answer ""; gum_answer "sonnet"; gum_answer "medium"; gum_answer "@1"
( cd "$REPO" && main add ) >/dev/null 2>"$PQ_HOME/.pick.err"
t=$(find_task marker-wiring-fixture)
[ -e "$t/after" ] || [ -e "$t/after.new" ] && bad "nothing picked writes no dependency" || ok
case "$(cat "$PQ_HOME/.pick.err")" in *"on:  "*|*"after:  "*) bad "and says none" ;; *) ok ;; esac

echo "== wiring: a task in another repo is waited for, and one with no name is held by stamp ==" >&2
reset_tasks
mk_task queue 005 web-cand "$REPO2" tom/web-cand >/dev/null
gum_reset; gum_answer "@1"; gum_answer ""; gum_answer ""; gum_answer "sonnet"; gum_answer "medium"; gum_answer "@2"
( cd "$REPO" && main add ) >/dev/null 2>"$PQ_HOME/.pick.err"
t=$(find_task marker-wiring-fixture)
eq "$(cut -f1,3 "$t/after" 2>/dev/null)" "web-cand"$'\t'"tom/web-cand" "the other repo's task lands in after"
case "$(cat "$PQ_HOME/.pick.err")" in *"after:  web-cand ($(basename "$REPO2")) - starts once it merges"*) ok ;; *) bad "and the add says it waits for the merge (got: $(cat "$PQ_HOME/.pick.err"))" ;; esac
reset_tasks
U=$(mk_task new 005 unnamed-cand "$REPO" "")
gum_reset; gum_answer "@1"; gum_answer ""; gum_answer ""; gum_answer "sonnet"; gum_answer "medium"; gum_answer "@2"
( cd "$REPO" && main add ) >/dev/null 2>&1
t=$(find_task marker-wiring-fixture)
eq "$(cat "$t/after.new" 2>/dev/null)" "$(stamp_of "$U")" "a pick with no name yet is held by its stamp"
[ -e "$t/after" ] && bad "and has no after line until it is named" || ok

echo "== wiring: adding from a pushed feature branch writes no base: header ==" >&2
# Every task forks from and aims at its repo's default branch, whatever branch
# the checkout is standing on when you add it.
reset_tasks
git -C "$REPO" checkout -q -b tom/feature
git -C "$REPO" update-ref refs/remotes/origin/tom/feature refs/heads/tom/feature
gum_reset; gum_answer "@1"; gum_answer ""; gum_answer ""; gum_answer "sonnet"; gum_answer "medium"
( cd "$REPO" && main add ) >/dev/null 2>"$PQ_HOME/.feature.err"
t=$(find_task marker-wiring-fixture)
[ -n "$t" ] && ok || bad "the add from a feature branch should succeed: $(cat "$PQ_HOME/.feature.err")"
[ -n "$t" ] && eq "$(hdr "$t/plan.md" base)" "" "no base: header, though the repo is on a pushed feature branch"
case "$(cat "$PQ_HOME/.feature.err")" in *"base:   "*|*"queuing against"*) bad "and nothing said about a base (got: $(cat "$PQ_HOME/.feature.err"))" ;; *) ok ;; esac
git -C "$REPO" checkout -q master
git -C "$REPO" branch -q -D tom/feature
git -C "$REPO" update-ref -d refs/remotes/origin/tom/feature

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
