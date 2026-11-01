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

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
