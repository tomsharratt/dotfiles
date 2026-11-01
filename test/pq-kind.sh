#!/usr/bin/env bash
# test/pq-kind.sh - a design task, the first pull request of a series with
# screens: its plan's `Kind: design` line read into the header at add, what
# builds on one waiting for its merge rather than stacking on it - at the wizard,
# through naming, in `pq after`, `pq ls` and fill - and then forking from the
# default branch, and the two contracts: the design task's own, and the one a
# task built on a merged design gets.
#
# The forge is a hand-primed PR cache (pr_load_all stood in for), plus a `gh`
# stub that serves a pull request's files from a file, for the previews the
# second contract names. `wt` and `herdr` are the stubs test/pq-dispatch.sh uses.
#
# SC2034: the caches set here are read by the pq sourced below.
# SC2015: `ok` never fails, so `[ ... ] && ok || bad` is an if/else.
# SC2016: the backticks in the sample plans are markdown, not a substitution.
# shellcheck disable=SC2034,SC2015,SC2016
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=test/sandbox.sh
source "$HERE/sandbox.sh"

PQ_HOME=$(mktemp -d)
export PQ_HOME
# Held in a name pq never assigns, as test/pq-tier.sh does: cleanup only ever
# removes what this file made.
TEST_PLANS=$(mktemp -d)
export PQ_PLANS_DIR=$TEST_PLANS

STUBBIN=$(mktemp -d)
FILES="$STUBBIN/.files.json"; GH_LOG="$STUBBIN/.gh-calls"
HERDR_LOG="$STUBBIN/.herdr-calls"; WT_LOG="$STUBBIN/.wt-calls"
WT_PATH_DIR=$(mktemp -d)
: > "$GH_LOG"; : > "$HERDR_LOG"; : > "$WT_LOG"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/claude"
cat > "$STUBBIN/gh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$GH_LOG"
case "\$*" in
  *"/pulls/"*"/files"*) [ -f "$FILES" ] || exit 1; cat "$FILES" ;;
  *) exit 1 ;;
esac
EOF
cat > "$STUBBIN/herdr" <<EOF
#!/bin/sh
{ for a in "\$@"; do printf '%s\t' "\$a"; done; printf '\n'; } >> "$HERDR_LOG"
case "\$1 \$2" in
  "api snapshot") printf '{"result":{"snapshot":{"panes":[]}}}'; exit 0 ;;
  "agent start") printf '{"result":{"agent":{"pane_id":"%s","name":"%s"}}}\n' "\$5" "\$3"; exit 0 ;;
  "agent prompt") printf '{"result":{"submitted":true}}\n'; exit 0 ;;
esac
exit 1
EOF
cat > "$STUBBIN/wt-stub" <<EOF
#!/bin/sh
{ printf '%s\t' "\$PWD"; for a in "\$@"; do printf '%s\t' "\$a"; done; printf '\n'; } >> "$WT_LOG"
printf '{"root_pane_id":"w1:p1","dev_pane_id":"w1:p2","path":"%s","workspace_id":"w1","url":"https://task.test","port":3101}\n' "$WT_PATH_DIR"
EOF
chmod +x "$STUBBIN/claude" "$STUBBIN/gh" "$STUBBIN/herdr" "$STUBBIN/wt-stub"
export PATH="$STUBBIN:$PATH"
export PQ_WT="$STUBBIN/wt-stub"

# shellcheck source=/dev/null
source "$HERE/../.local/bin/pq"
sandbox_guard
# shellcheck source=test/lib.sh
source "$HERE/lib.sh"
gum_stub "$STUBBIN" "$PQ_HOME/.gum"
[ "$PLANS_DIR" = "$TEST_PLANS" ] || { echo "pq-kind.sh: PLANS_DIR is not the test's own directory - refusing to run" >&2; exit 1; }

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { if [ "$1" = "$2" ]; then ok; else bad "$3 (got '$1', want '$2')"; fi; }
has() { case "$1" in *"$2"*) ok ;; *) bad "$3 (got '$1')" ;; esac; }
hasnt() { case "$1" in *"$2"*) bad "$3 (got '$1')" ;; *) ok ;; esac; }

cleanup() { sandbox_cleanup; }
trap cleanup EXIT

# Resolved, as pq add resolves the repo it is run in: /var is /private/var here.
REPO=$(cd "$(mktemp -d)" && pwd -P)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$REPO/.git/refs/remotes/origin"
git -C "$REPO" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
git init -q -b master "$WT_PATH_DIR"
git -C "$WT_PATH_DIR" -c user.email=test@test -c user.name=test commit -q --allow-empty -m fork-point

unset HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID
PQ_DONE_KEEP=99

# The forge, as rows: `repo branch num state draft base` lines, which every
# pr_load_all - the tick's, `pq ls`'s, `pq after`'s - hands back as its cache.
ROWS=""
pr_load_all() {
  PR_CACHE="$PQ_HOME/.test.pr"; PR_ANS="$PQ_HOME/.test.ans"
  printf '%s' "$ROWS" > "$PR_CACHE"; : > "$PR_ANS"
}
row() { ROWS="$ROWS$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"$'\t'"$5"$'\tmaster\t\n'; }   # repo branch num state draft
prime() { pr_load_all; }

reset_tasks() {
  rm -rf "$PQ_HOME/new" "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done" "$PQ_HOME/tasks"
  mkdir -p "$PQ_HOME/new" "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done"
  ROWS=""; : > "$WT_LOG"; : > "$HERDR_LOG"; : > "$GH_LOG"; rm -f "$FILES"
}

mk_task() {                             # state prio slug branch [kind [design]] -> task_dir
  local state=$1 prio=$2 slug=$3 branch=$4 kind=${5:-} design=${6:-} dir
  dir="$PQ_HOME/$state/$(printf '%014d' $(( 20260101000000 + 10#$prio )))-$slug"
  mkdir -p "$dir"
  {
    printf -- '---\n'
    printf 'repo:     %s\n' "$REPO"
    printf 'branch:   %s\n' "$branch"
    [ -n "$kind" ] && printf 'kind:     %s\n' "$kind"
    [ -n "$design" ] && printf 'design:   %s\n' "$design"
    printf 'review:   visual\n'
    printf 'model:    sonnet\n'
    printf 'effort:   low\n'
    printf 'intent:   Show the new screens.\n'
    printf 'added:    2026-01-01T00:00:00Z\n'
    printf -- '---\n\nplan body\n'
  } > "$dir/plan.md"
  printf '%s' "$dir"
}

plan() { printf '%b' "$2" > "$TEST_PLANS/$1"; printf '%s' "$TEST_PLANS/$1"; }
verdict_of() { after_state "$1" | cut -f1; }
detail_of() { after_state "$1" | cut -f2; }

echo "== a plan's Kind: line ==" >&2
P=$(plan k1.md '# K1\n\nKind: design\nReview: visual\n')
eq "$(plan_kind "$P")" "design" "a plain Kind: line"
P=$(plan k2.md '# K2\n\n- **Kind:** `Design` - the components first\n')
eq "$(plan_kind "$P")" "design" "list marker, bold, backticks and case are all allowed"
P=$(plan k3.md '# K3\n\n```\nKind: design\n```\n\nKind of a big change.\nKind: feature\n')
eq "$(plan_kind "$P")" "" "a fenced example, prose and any other kind are no kind"
P=$(plan k4.md '# K4\n\nJust do it.\n')
eq "$(plan_kind "$P")" "" "a plan that names none has none"

echo "== pq add writes kind: design, and a design plan with no tier is visual ==" >&2
reset_tasks
P=$(plan add1.md '# Design the onboarding screens\n\nKind: design\nBudget: 280 app lines\n')
out=$(REPO=$REPO add_new "$P" 2>&1)
D=$(queue_ordered new | tail -1)
eq "$(hdr "$D/plan.md" kind)" "design" "kind: design in the header"
eq "$(hdr "$D/plan.md" review)" "visual" "and review: visual, since the plan names no tier"
has "$out" "kind:   design" "the add says what it read"
has "$out" "review: visual (a design plan that names no tier), budget 280 app lines" "and where the tier came from"
hasnt "$out" "labelled for a deep review" "with no warning that it will be deep"
P=$(plan add2.md '# Design with a tier\n\nKind: design\nReview: skim\n')
REPO=$REPO add_new "$P" >/dev/null 2>&1
D=$(queue_ordered new | tail -1)
eq "$(hdr "$D/plan.md" review)" "skim" "a design plan that names a tier keeps it"
P=$(plan add3.md '# Not a design\n\nReview: deep\n')
REPO=$REPO add_new "$P" >/dev/null 2>&1
D=$(queue_ordered new | tail -1)
grep -q '^kind:' "$D/plan.md" && bad "no kind: key for a plan that names none" || ok

echo "== the wizard: a design task is waited for, an ordinary one stacked on ==" >&2
reset_tasks
DS=$(mk_task queue 010 screens-design tom/screens-design design)
mk_task queue 020 other-task tom/other-task >/dev/null
run_pick_after() { local after_vals="" repo=$REPO; pick_after; printf '%s' "$after_vals"; }
gum_reset; gum_answer "@3"
out=$(run_pick_after 2>/dev/null)
eq "$out" "$(stamp_of "$DS")" "the design task can be picked"
case "$(gum_stdin 1 | sed -n 3p)" in *screens-design*queue*"design: wait for its merge") ok ;; *) bad "a design row waits for its merge (got: $(gum_stdin 1 | sed -n 3p))" ;; esac
case "$(gum_stdin 1 | sed -n 2p)" in *other-task*queue*"stack on it") ok ;; *) bad "an ordinary same-repo row still stacks (got: $(gum_stdin 1 | sed -n 2p))" ;; esac
# A design opens a series, and a series is a single line: one task builds on it.
B=$(mk_task queue 030 first-page tom/first-page)
after_line screens-design "$REPO" tom/screens-design design > "$B/after"
gum_reset; gum_answer "@1"
run_pick_after >/dev/null 2>&1
case "$(gum_stdin 1)" in *screens-design*) bad "a design something already builds on is not offered again (got: $(gum_stdin 1))" ;; *) ok ;; esac

echo "== pq add on a named design: the line carries design, and the add says it waits ==" >&2
reset_tasks
mk_task queue 010 screens-design tom/screens-design design >/dev/null
P=$(plan page1.md '# Build the onboarding page\n\nReview: skim\n')
out=$(REPO=$REPO add_new "$P" --after screens-design 2>&1)
D=$(queue_ordered new | tail -1)
eq "$(cat "$D/after")" "screens-design	$REPO	tom/screens-design	design" "the after line ends in design"
has "$out" "after:  screens-design (design) - starts from master once its pull request merges" "and the add says so"
# An ordinary same-repo dependency writes the line exactly as it always did.
reset_tasks
mk_task queue 010 plain-parent tom/plain-parent >/dev/null
P=$(plan page2.md '# Build on a plain one\n')
out=$(REPO=$REPO add_new "$P" --after plain-parent 2>&1)
D=$(queue_ordered new | tail -1)
eq "$(cat "$D/after")" "plain-parent	$REPO	tom/plain-parent" "three fields, as before"
has "$out" "on:     plain-parent - starts when its pull request is ready for review" "and it still stacks"

echo "== a design still in new/ when the next plan picks it: naming carries design over ==" >&2
reset_tasks
PD=$(plan series1.md '# Series design\n\nKind: design\n')
PB=$(plan series2.md '# Series page\n\nReview: skim\n')
REPO=$REPO add_new "$PD" >/dev/null 2>&1
ND=$(queue_ordered new | tail -1)
REPO=$REPO add_new "$PB" >/dev/null 2>&1
NB=$(queue_ordered new | tail -1)
printf '%s\n' "$(stamp_of "$ND")" > "$NB/after.new"
# shellcheck disable=SC2329  # called by name_task
( name_plan() { printf 'tom/series-design\t\t\n'; }; name_task "$ND" 0 ) >/dev/null 2>&1
# shellcheck disable=SC2329  # called by name_task
( name_plan() { printf 'tom/series-page\t\t\n'; }; name_task "$NB" 0 ) >/dev/null 2>&1
QB=$(find_task series-page 2>/dev/null)
[ -n "$QB" ] && ok || bad "the page task is named and queued"
eq "$(cat "$QB/after" 2>/dev/null)" "series-design	$REPO	tom/series-design	design" "its line carries design from the task it was held on"
eq "$(hdr "$(find_task series-design)/plan.md" kind)" "design" "and the design keeps its kind through naming"

echo "== after_state: a design is waited for until it merges, never stacked on ==" >&2
reset_tasks
mk_task running 010 screens-design tom/screens-design design >/dev/null
B=$(mk_task queue 020 first-page tom/first-page)
after_line screens-design "$REPO" tom/screens-design design > "$B/after"
ans() { printf '%s\t%s\n' "$REPO" "$1" >> "$PR_ANS"; }
prime; ans tom/screens-design
eq "$(verdict_of "$B")" "waiting screens-design 1" "no pull request yet: waiting"
eq "$(detail_of "$B")" "design" "with the detail design"
eq "$(agent_cell "$B" queue)" "design screens-design" "pq ls names the design task until it has a pull request"
row "$REPO" tom/screens-design 41 OPEN draft; prime
eq "$(verdict_of "$B")" "waiting screens-design 1" "a draft in review: still waiting"
eq "$(agent_cell "$B" queue)" "design #41" "and pq ls names its pull request"
ROWS=""; row "$REPO" tom/screens-design 41 OPEN ""; prime
eq "$(verdict_of "$B")" "waiting screens-design 1" "marked ready: still waiting - ready is not approved"
ROWS=""; row "$REPO" tom/screens-design 41 MERGED ""; prime
eq "$(verdict_of "$B")" "met" "merged: met, so it starts from the default branch"
eq "$(agent_cell "$B" queue)" "-" "and pq ls has nothing to say"
# The same pull request, on an ordinary line, is stacked on as it always was.
printf 'screens-design\t%s\ttom/screens-design\n' "$REPO" > "$B/after"
ROWS=""; row "$REPO" tom/screens-design 41 OPEN ""; prime
eq "$(verdict_of "$B")" "stack screens-design" "a three-field line still stacks on a ready pull request"

echo "== pq after: set on a design, and described ==" >&2
reset_tasks
mk_task "done" 010 screens-design tom/screens-design design >/dev/null
B=$(mk_task queue 020 first-page tom/first-page)
ROWS=""; row "$REPO" tom/screens-design 41 OPEN ""
out=$(main after first-page screens-design 2>&1); rc=$?
eq "$rc" "0" "pq after sets a design dependency"
eq "$(cat "$B/after")" "screens-design	$REPO	tom/screens-design	design" "with design on the line"
has "$out" "first-page waits for design screens-design - it starts from master once #41 merges" "and says it waits for the merge"
out=$(main after first-page 2>&1)
has "$out" "#41 open" "pq after <task> shows the design's pull request"
has "$out" "waiting for design #41 to merge" "and what it waits for"
ROWS=""; row "$REPO" tom/screens-design 41 MERGED ""
out=$(main after first-page 2>&1)
has "$out" "merged - first-page starts from master, which holds its components" "and once it merged, where it starts from"
# Given by branch, the owner's kind is read all the same.
main after first-page --clear >/dev/null 2>&1
ROWS=""; row "$REPO" tom/screens-design 41 OPEN ""
main after first-page tom/screens-design >/dev/null 2>&1
eq "$(cut -f4 "$B/after")" "design" "a design given by its branch is still a design"
# One task builds on a design: a second is refused, as a second stack child is.
C=$(mk_task queue 030 second-page tom/second-page)
out=$(main after second-page screens-design 2>&1) && bad "a second task cannot build on the same design" || ok
has "$out" "first-page already builds on screens-design" "and is told which one does"
[ -f "$C/after" ] && bad "and nothing is written" || ok

echo "== pq ls --json: a design dependency's kind ==" >&2
ROWS=""; row "$REPO" tom/screens-design 41 OPEN ""
ls_json=$(main ls --json 2>/dev/null)
eq "$(jq -r '[.[] | select(.task == "first-page")][0] | .after[0].kind' <<<"$ls_json")" "design" "kind is design"
eq "$(jq -r '[.[] | select(.task == "first-page")][0] | .blocked' <<<"$ls_json")" "true" "and it is blocked, ready or not"
out=$(PQ_WIDTH=200 main ls 2>/dev/null)
has "$out" "design #41" "pq ls reads design #41 for it"

echo "== an ordinary same-repo dependency still stacks through fill ==" >&2
reset_tasks
git -C "$REPO" update-ref refs/remotes/origin/tom/plain-parent refs/heads/master
mk_task "done" 010 plain-parent tom/plain-parent >/dev/null
B=$(mk_task queue 020 plain-child tom/plain-child)
printf 'plain-parent\t%s\ttom/plain-parent\n' "$REPO" > "$B/after"
row "$REPO" tom/plain-parent 50 OPEN ""
PQ_SUMMARY=""
tick_body 1 0 >/dev/null 2>&1
R=$(find_task plain-child 2>/dev/null)
eq "$(state_of "$R")" "running" "a ready parent lets the child start"
has "$(tr '\t' ' ' < "$WT_LOG")" "--base origin/tom/plain-parent --json tom/plain-child" "forked from its parent's branch"
eq "$(st "$R" PQ_STACK_PARENT)" "tom/plain-parent" "recorded as its stack parent"
eq "$(st "$R" PQ_DESIGN_PR)" "" "with no design recorded"
has "$(cat "$R/contract.md")" "## Building on #50" "and its contract is the stack one"
hasnt "$(cat "$R/contract.md")" "design" "with nothing about a design"

echo "== fill: held while the design is open, then forked from the default branch ==" >&2
reset_tasks
mk_task "done" 010 screens-design tom/screens-design design "Onboarding.dc.html" >/dev/null
B=$(mk_task queue 020 first-page tom/first-page "" "Onboarding.dc.html")
after_line screens-design "$REPO" tom/screens-design design > "$B/after"
row "$REPO" tom/screens-design 41 OPEN ""
PQ_SUMMARY=""
tick_body 1 0 >/dev/null 2>&1
[ -d "$B" ] && ok || bad "a ready design does not let the page task start"
grep -q "	new	" "$WT_LOG" && bad "and no worktree is made for it" || ok
cat > "$FILES" <<'JSON'
[{"filename":"app/components/onboarding/step_component.rb","status":"added","additions":40},
 {"filename":"spec/components/previews/onboarding/step_component_preview.rb","status":"added","additions":30},
 {"filename":"spec/components/previews/onboarding/step_component_preview/empty.html.erb","status":"added","additions":5},
 {"filename":"spec/components/previews/old_preview.rb","status":"removed","additions":0}]
JSON
ROWS=""; row "$REPO" tom/screens-design 41 MERGED ""
PQ_SUMMARY=""
tick_body 1 0 >/dev/null 2>&1
R=$(find_task first-page 2>/dev/null)
eq "$(state_of "$R")" "running" "once the design merges, the page task is dispatched"
has "$(tr '\t' ' ' < "$WT_LOG")" "new --no-agent --no-focus --json tom/first-page" "forked from the default branch"
grep -q -- "--base" "$WT_LOG" && bad "with no --base" || ok
eq "$(st "$R" PQ_STACK_PARENT)" "" "it builds on no branch"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
