#!/usr/bin/env bash
# test/pq-stack.sh - linking a stacked task's pull request into its parent's
# stack on GitHub (stack_link), against a `gh` stub that answers `stack --help`,
# `stack link` and the stacks API the way the real ones did in the sandbox on
# 2026-10-16, and logs every call it gets - and then restacking a layer whose
# parent moved (stack_task), against real git: a bare origin, a clone standing
# in for the repo, and a second clone playing GitHub, which rewrites branches on
# origin. The predicate reads real history, so a faked ref would not do.
#
# SC2034: the knobs and caches set here are read by the pq sourced below.
# SC2015: `ok` never fails, so `[ ... ] && ok || bad` is an if/else.
# shellcheck disable=SC2034,SC2015
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PQ_HOME=$(mktemp -d)
export PQ_HOME

STUBBIN=$(mktemp -d)
GH_LOG="$STUBBIN/.gh-calls"
STACKS="$STUBBIN/.stacks"               # "pr<TAB>stack" lines: what the stacks API answers
: > "$GH_LOG"; : > "$STACKS"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/claude"
# herdr answers its snapshot from .panes.json (set_panes) and records every
# `agent prompt`, failing it with .prompt-fail's code when that is there.
PANES_JSON="$STUBBIN/.panes.json"; HERDR_LOG="$STUBBIN/.herdr-calls"
printf '{"result":{"snapshot":{"panes":[]}}}' > "$PANES_JSON"; : > "$HERDR_LOG"
cat > "$STUBBIN/herdr" <<EOF
#!/bin/sh
{ for a in "\$@"; do printf '%s\t' "\$a"; done; printf '\n'; } >> "$HERDR_LOG"
case "\$1 \$2" in
  "api snapshot") cat "$PANES_JSON"; exit 0 ;;
  "agent prompt")
    if [ -f "$STUBBIN/.prompt-fail" ]; then
      printf '{"error":{"code":"%s","message":"stub"}}\n' "\$(cat "$STUBBIN/.prompt-fail")"; exit 1
    fi
    printf '{"result":{"submitted":true}}\n'; exit 0 ;;
esac
exit 1
EOF
# `stack link` exits with .link-rc (default 0) and prints .link-out; on success it
# puts every number it was given into one stack - the first argument's stack when
# that is a stack number already listed, a new one (100) otherwise - as GitHub
# does. `.nocli` makes `gh stack` unknown, as a gh without the extension is.
cat > "$STUBBIN/gh" <<EOF
#!/bin/sh
{ for a in "\$@"; do printf '%s\t' "\$a"; done; printf '\n'; } >> "$GH_LOG"
case "\$1 \$2" in
  "stack --help") [ -f "$STUBBIN/.nocli" ] && exit 1; exit 0 ;;
  "stack link")
    rc=\$(cat "$STUBBIN/.link-rc" 2>/dev/null || echo 0)
    cat "$STUBBIN/.link-out" 2>/dev/null
    [ "\$rc" = 0 ] || exit "\$rc"
    if awk -F'\t' -v s="\$3" '\$2 == s { f = 1 } END { exit !f }' "$STACKS"; then stack=\$3; shift 3
    else stack=100; shift 2; fi
    for pr in "\$@"; do printf '%s\t%s\n' "\$pr" "\$stack" >> "$STACKS"; done
    exit 0 ;;
  "api -H")
    [ -f "$STUBBIN/.api-down" ] && exit 1
    pr=\$(printf '%s' "\$4" | sed -n 's/.*pull_request=//p')
    awk -F'\t' -v p="\$pr" '\$1 == p { print \$2; exit }' "$STACKS"
    exit 0 ;;
esac
exit 1
EOF
chmod +x "$STUBBIN/claude" "$STUBBIN/herdr" "$STUBBIN/gh"
export PATH="$STUBBIN:$PATH"

# shellcheck source=/dev/null
source "$HERE/../.local/bin/pq"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }
has() { case "$1" in *"$2"*) ok ;; *) bad "$3 (got '$1')" ;; esac; }
hasnt() { case "$1" in *"$2"*) bad "$3 (got '$1')" ;; *) ok ;; esac; }

cleanup() { rm -rf "$PQ_HOME" "$STUBBIN" "${REPO:-}" "${GITS:-}"; }
trap cleanup EXIT

REPO=$(mktemp -d)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$REPO/.git/refs/remotes/origin"
git -C "$REPO" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master

reset_tasks() {
  rm -rf "$PQ_HOME/new" "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done"
  mkdir -p "$PQ_HOME/new" "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done"
}
reset_gh() { : > "$GH_LOG"; : > "$STACKS"; rm -f "$STUBBIN/.link-rc" "$STUBBIN/.link-out" "$STUBBIN/.nocli" "$STUBBIN/.api-down"; }
reset_caches() {
  PR_CACHE="$PQ_HOME/.test.pr"; PR_ANS="$PQ_HOME/.test.ans"
  : > "$PR_CACHE"; : > "$PR_ANS"
}
cache_row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t\n' "$@" >> "$PR_CACHE"; }   # repo branch num state draft base
links() { grep -c "^stack	link	" "$GH_LOG" 2>/dev/null || true; }
link_args() { grep "^stack	link	" "$GH_LOG" | tail -1 | cut -f3- | tr '\t' ' ' | sed 's/ *$//'; }
gh_calls() { wc -l < "$GH_LOG" | tr -d ' '; }

# A done task that builds on tom/<parent> and has opened pull request #<pr>.
mk_child() {                            # prio slug parent pr -> task_dir
  local d
  d="$PQ_HOME/done/$(printf '%014d' $(( 20260101000000 + 10#$1 )))-$2"
  mkdir -p "$d"
  printf -- '---\nrepo:     %s\nbranch:   tom/%s\nmodel:    sonnet\neffort:   low\nintent:   t\nadded:    2026-01-01T00:00:00Z\n---\n\nplan\n' \
    "$REPO" "$2" > "$d/plan.md"
  st_set "$d" PQ_STACK_PARENT "tom/$3"; st_set "$d" PQ_PR "$4"
  printf '%s' "$d"
}

echo "== the first link of a series makes a stack of the pair, by PR number ==" >&2
reset_tasks; reset_gh; reset_caches
cache_row "$REPO" tom/bottom 10 OPEN "" master
cache_row "$REPO" tom/second 11 OPEN draft tom/bottom
B=$(mk_child 10 second bottom 11)
out=$(stack_link "$B" 0 2>&1)
eq "$(links)" "1" "one link"
eq "$(link_args)" "10 11" "the parent's PR, then the child's"
grep "^stack	link	" "$GH_LOG" | cut -f3- | tr '\t' '\n' | sed '/^$/d' | grep -qv '^[0-9][0-9]*$' \
  && bad "only PR numbers are ever passed, never a branch name: $(link_args)" || ok
eq "$(st "$B" PQ_STACK)" "100" "the stack the API lists it in is recorded"
has "$out" "second: #11 joined #10's stack (stack 100)" "and said"

echo "== once recorded, a second tick does nothing at all ==" >&2
: > "$GH_LOG"
out=$(stack_link "$B" 0 2>&1)
eq "$(gh_calls)" "0" "no gh call, once PQ_STACK is set"
eq "$out" "" "and nothing said"

echo "== the next link goes through the parent's stack number ==" >&2
# The pair form refuses once the stack is longer than the pair - gh-stack exits
# 5 with "would remove #10 from the stack" - so the stack's number is used.
reset_gh; reset_caches
printf '10\t100\n11\t100\n' > "$STACKS"
cache_row "$REPO" tom/second 11 OPEN "" tom/bottom
cache_row "$REPO" tom/third 12 OPEN draft master
C=$(mk_child 20 third second 12)
stack_link "$C" 0 >/dev/null 2>&1
eq "$(link_args)" "100 12" "the parent's stack, then the child, even with the child aimed at the wrong base"
eq "$(st "$C" PQ_STACK)" "100" "it joins the same stack"

echo "== a pull request already in a stack is recorded without linking ==" >&2
reset_gh; reset_caches
printf '10\t100\n11\t100\n' > "$STACKS"
cache_row "$REPO" tom/bottom 10 OPEN "" master
B=$(mk_child 30 by-hand bottom 11)
stack_link "$B" 0 >/dev/null 2>&1
eq "$(links)" "0" "no link: it is already there, linked by hand or by a tick that stopped short"
eq "$(st "$B" PQ_STACK)" "100" "and the stack is recorded"

echo "== a parent that is not OPEN is left alone ==" >&2
for state in MERGED CLOSED; do
  reset_tasks; reset_gh; reset_caches
  cache_row "$REPO" tom/gone 10 "$state" "" master
  G=$(mk_child 40 orphan gone 11)
  out=$(stack_link "$G" 0 2>&1)
  eq "$(gh_calls)" "0" "$state parent: no gh call"
  eq "$(st "$G" PQ_STACK)$(st "$G" PQ_STACK_LINK)" "" "$state parent: nothing recorded, for the restack to deal with"
done
reset_tasks; reset_gh; reset_caches
G=$(mk_child 41 no-row nowhere 11)
stack_link "$G" 0 >/dev/null 2>&1
eq "$(gh_calls)" "0" "no row for the parent this tick: nothing to judge"

echo "== a parent whose own link has not happened yet is waited for ==" >&2
reset_tasks; reset_gh; reset_caches
cache_row "$REPO" tom/middle 11 OPEN "" tom/bottom
cache_row "$REPO" tom/top 12 OPEN draft tom/middle
M="$PQ_HOME/done/00020260101000050-middle"; mkdir -p "$M"
printf -- '---\nrepo:     %s\nbranch:   tom/middle\n---\n' "$REPO" > "$M/plan.md"
T=$(mk_child 51 top middle 12)
stack_link "$T" 0 >/dev/null 2>&1
eq "$(links)" "0" "no stack is started with a feature branch for its trunk"
eq "$(st "$T" PQ_STACK)$(st "$T" PQ_STACK_LINK)" "" "and nothing is recorded: the next tick looks again"
st_set "$M" PQ_STACK_LINK failed
out=$(stack_link "$T" 0 2>&1)
eq "$(st "$T" PQ_STACK_LINK)" "below" "once the parent's own link has given up, so does the child's"
has "$out" "#11 never joined a stack of its own, so #12 stays a plain chained pull request on it" "said once"
eq "$(stack_link "$T" 0 2>&1)" "" "and not again"

echo "== a parent pq does not run, off the trunk and in no stack, is not waited for ==" >&2
reset_tasks; reset_gh; reset_caches
cache_row "$REPO" tom/foreign 11 OPEN "" tom/elsewhere
O=$(mk_child 55 on-foreign foreign 12)
out=$(stack_link "$O" 0 2>&1)
eq "$(links)" "0" "no stack is started on a feature branch"
eq "$(st "$O" PQ_STACK_LINK)" "below" "and nothing else will ever link that parent, so it stops here"
has "$out" "#11 never joined a stack of its own, so #12 stays a plain chained pull request on it" "said once"
: > "$GH_LOG"
stack_link "$O" 0 >/dev/null 2>&1
eq "$(gh_calls)" "0" "and costs nothing on every tick after"

echo "== a stacks API that cannot answer is asked again, never read as no stack ==" >&2
reset_tasks; reset_gh; reset_caches
printf '10\t100\n11\t100\n' > "$STACKS"
cache_row "$REPO" tom/second 11 OPEN "" tom/bottom
A=$(mk_child 56 api-down second 12)
touch "$STUBBIN/.api-down"
stack_link "$A" 0 >/dev/null 2>&1
eq "$(links)" "0" "no pair-form link that a longer stack would refuse"
eq "$(st "$A" PQ_STACK)$(st "$A" PQ_STACK_LINK)$(st "$A" PQ_STACK_LINK_FAILS)" "" "and no try counted"
rm -f "$STUBBIN/.api-down"
stack_link "$A" 0 >/dev/null 2>&1
eq "$(link_args)" "100 12" "the next tick links through the stack"

echo "== no gh stack: said once, and the pull request stays chained ==" >&2
reset_tasks; reset_gh; reset_caches; touch "$STUBBIN/.nocli"
cache_row "$REPO" tom/bottom 10 OPEN "" master
N=$(mk_child 60 no-cli bottom 11)
out=$(stack_link "$N" 0 2>&1)
eq "$(st "$N" PQ_STACK_LINK)" "nocli" "recorded"
has "$out" "no-cli: gh stack is not installed (gh extension install github/gh-stack) - #11 stays a plain chained pull request on #10" "with how to get it"
eq "$(links)" "0" "and no link is tried"
: > "$GH_LOG"
eq "$(stack_link "$N" 0 2>&1)" "" "said once"
eq "$(gh_calls)" "0" "and never asked again"

echo "== stacks off for the repo (exit 9): said once ==" >&2
reset_tasks; reset_gh; reset_caches; printf 9 > "$STUBBIN/.link-rc"
cache_row "$REPO" tom/bottom 10 OPEN "" master
X=$(mk_child 70 disabled bottom 11)
out=$(stack_link "$X" 0 2>&1)
eq "$(st "$X" PQ_STACK_LINK)" "disabled" "recorded"
has "$out" "stacked pull requests are not enabled for $(basename "$REPO") - #11 stays a plain chained pull request on #10" "and said"
: > "$GH_LOG"
eq "$(stack_link "$X" 0 2>&1)" "" "once"
eq "$(gh_calls)" "0" "and never tried again"

echo "== any other failure is tried three times, then said once ==" >&2
reset_tasks; reset_gh; reset_caches; printf 5 > "$STUBBIN/.link-rc"
printf 'Checking existing stacks...\nCannot update stack: this would remove #10 from the stack\n' > "$STUBBIN/.link-out"
cache_row "$REPO" tom/bottom 10 OPEN "" master
F=$(mk_child 80 flaky bottom 11)
out=$(stack_link "$F" 0 2>&1)
eq "$(st "$F" PQ_STACK_LINK_FAILS)" "1" "the first failure is counted"
eq "$out" "" "and kept quiet"
stack_link "$F" 0 >/dev/null 2>&1
eq "$(st "$F" PQ_STACK_LINK)" "" "the second is still a retry"
out=$(stack_link "$F" 0 2>&1)
eq "$(st "$F" PQ_STACK_LINK)" "failed" "the third gives up"
has "$out" "could not add #11 to #10's stack after 3 tries (Cannot update stack: this would remove #10 from the stack) - it stays a plain chained pull request" "with the last error"
eq "$(links)" "3" "three tries"
eq "$(stack_link "$F" 0 2>&1)" "" "and said once"
eq "$(links)" "3" "with no fourth"
# A link gh says worked but the API does not list is a failure too.
reset_tasks; reset_gh; reset_caches
cache_row "$REPO" tom/bottom 10 OPEN "" master
U=$(mk_child 81 unlisted bottom 11)
# shellcheck disable=SC2329  # called by stack_link_run
gh() { if [ "$1 $2" = "stack link" ]; then printf 'stack\tlink\t%s\t%s\t\n' "$3" "$4" >> "$GH_LOG"; return 0; fi; command gh "$@"; }
stack_link "$U" 0 >/dev/null 2>&1
unset -f gh
eq "$(st "$U" PQ_STACK)" "" "nothing is recorded as linked"
eq "$(st "$U" PQ_STACK_LINK_FAILS)" "1" "and it counts as a try"

echo "== --dry-run says what it would do and writes nothing ==" >&2
reset_tasks; reset_gh; reset_caches
cache_row "$REPO" tom/bottom 10 OPEN "" master
D=$(mk_child 90 dry bottom 11)
out=$(stack_link "$D" 1 2>&1)
has "$out" "would add #11 to #10's stack" "it says so"
eq "$(gh_calls)" "0" "without asking gh anything"
[ -f "$D/state.env" ] && eq "$(grep -c 'PQ_STACK=\|PQ_STACK_LINK' "$D/state.env")" "0" "and records nothing" || ok

echo "== through the tick: a done task is linked on the pass that sees its pull request ==" >&2
reset_tasks; reset_gh
D=$(mk_child 95 ticked bottom 11)
real_pr_load_all=$(declare -f pr_load_all)
# shellcheck disable=SC2329  # called by tick_body
pr_load_all() {
  PR_CACHE="$PQ_HOME/.test.pr"; PR_ANS="$PQ_HOME/.test.ans"; : > "$PR_ANS"
  printf '%s\ttom/bottom\t10\tOPEN\t\tmaster\t\n%s\ttom/ticked\t11\tOPEN\tdraft\ttom/bottom\t\n' "$REPO" "$REPO" > "$PR_CACHE"
}
out=$(tick_body 0 1 2>&1)
has "$out" "would add #11 to #10's stack" "a dry tick says it would"
tick_body 0 0 >/dev/null 2>&1
eq "$(st "$D" PQ_STACK)" "100" "and a real one links it"
eval "$real_pr_load_all"

# ── restacking a layer ──────────────────────────────────────────────────────
GITS=$(mktemp -d)
ORIGIN="$GITS/origin.git"; GHC="$GITS/github"; RREPO="$GITS/repo"
git init -q --bare -b main "$ORIGIN"
git clone -q "$ORIGIN" "$GHC" 2>/dev/null
g() { git -C "$GHC" -c user.email=gh@test -c user.name=gh "$@"; }
gcommit() { printf '%s\n' "$2" >> "$GHC/$1"; g add -A; g commit -q -m "$1: $2"; }   # file line
gpush() { g push -q -f origin "$@" 2>/dev/null; }
g checkout -q -b main; gcommit README one; gpush main
git clone -q "$ORIGIN" "$RREPO" 2>/dev/null
PQ_FETCH_BASES=1

# A fresh parent and child on origin, as dispatch left them: the child forked
# from the parent's head (F) and added one commit of its own. RREPO has fetched
# everything, as the repo a worktree was made from has.
stack_pair() {                          # n -> PA CH F
  PA=tom/pa-$1; CH=tom/ch-$1
  g checkout -q main; g checkout -q -b "$PA"; gcommit "pa-$1" a
  F=$(g rev-parse HEAD)
  g checkout -q -b "$CH"; gcommit "ch-$1" b
  gpush "$PA" "$CH"
  git -C "$RREPO" fetch -q origin 2>/dev/null
}
# A done task on CH, stacked on PA, with pull request #11 on #10.
mk_stacked() {                          # prio -> task_dir
  local d
  d="$PQ_HOME/done/$(printf '%014d' $(( 20260201000000 + 10#$1 )))-${CH#tom/}"
  mkdir -p "$d"
  printf -- '---\nrepo:     %s\nbranch:   %s\nmodel:    sonnet\neffort:   low\nintent:   t\nadded:    2026-01-01T00:00:00Z\n---\n\nplan\n' \
    "$RREPO" "$CH" > "$d/plan.md"
  st_set "$d" PQ_STACK_PARENT "$PA"; st_set "$d" PQ_PR 11; st_set "$d" PQ_STACK_FORK "$F"
  printf '%s' "$d"
}
rows_open() {                           # the parent open and ready, the child open on it
  reset_caches
  cache_row "$RREPO" "$PA" 10 OPEN "" main
  cache_row "$RREPO" "$CH" 11 OPEN "" "$PA"
}
rows_merged() {                         # merge_oid: the parent merged into main
  reset_caches
  printf '%s\t%s\t10\tMERGED\t\tmain\t%s\n' "$RREPO" "$PA" "$1" >> "$PR_CACHE"
  cache_row "$RREPO" "$CH" 11 OPEN "" main
}
# One tick's worth: the fetch memo goes, as it does between ticks.
restack() { repo_base_reset; stack_task "$1" "${2:-0}"; }
need() { printf '%s %s' "$(st "$1" PQ_STACK_DUE)" "$(st "$1" PQ_STACK_NEEDS)" | sed 's/ *$//'; }
# Which way the verdict moves the layer, as stack_task reads it.
verdict() { repo_base_reset; stack_verdict "$1" | cut -f1; }
fp() { printf '%s %s' "$1" "$2" | cksum | awk '{ print $1 }'; }

echo "== restack: a child on its parent's head needs nothing ==" >&2
reset_tasks; stack_pair 1; rows_open
S=$(mk_stacked 1)
out=$(restack "$S" 2>&1)
eq "$(need "$S")" "" "linear: no need"
eq "$(st "$S" PQ_STACK_FORK)" "$F" "and the fork point stays"
eq "$out" "" "and nothing said"

echo "== restack: a parent that only gained commits needs nothing ==" >&2
g checkout -q "$PA"; gcommit "pa-1" fix; gpush "$PA"
restack "$S" >/dev/null 2>&1
eq "$(need "$S")" "" "gained commits: no need"
eq "$(st "$S" PQ_STACK_FORK)" "$F" "and the fork point stays where the child forked"

echo "== restack: once the child sits on the new head, that head is its fork point ==" >&2
P=$(g rev-parse "$PA")
g rebase -q --onto "$PA" "$F" "$CH"; gpush "$CH"
restack "$S" >/dev/null 2>&1
eq "$(st "$S" PQ_STACK_FORK)" "$P" "the fork point follows the parent's head"
eq "$(need "$S")" "" "with no need"

echo "== restack: a rebased parent needs the child moved onto it ==" >&2
reset_tasks; stack_pair 2; rows_open
S=$(mk_stacked 2)
g checkout -q "$PA"; g commit -q --amend -m "pa-2: a, resolved"; gpush "$PA"
P=$(g rev-parse "$PA")
restack "$S" >/dev/null 2>&1
eq "$(need "$S")" "$(fp "$P" "$F")" "due, fingerprinted by the parent's head and the fork point"
eq "$(verdict "$S")" "rebased" "onto the parent"
eq "$(st "$S" PQ_STACK_FORK)" "$F" "the fork point is where the child's own commits start, until it moves"
echo "== restack: the child moved onto it clears the need ==" >&2
g rebase -q --onto "$PA" "$F" "$CH"; gpush "$CH"
restack "$S" >/dev/null 2>&1
eq "$(need "$S")" "" "cleared"
eq "$(st "$S" PQ_STACK_FORK)" "$P" "and the fork point moved"

echo "== restack: Rebase stack, parent and child rewritten together, needs nothing ==" >&2
reset_tasks; stack_pair 3; rows_open
S=$(mk_stacked 3)
g checkout -q main; gcommit README two; gpush main
g rebase -q main "$PA"; P=$(g rev-parse "$PA")
g rebase -q --onto "$PA" "$F" "$CH"; gpush main "$PA" "$CH"
restack "$S" >/dev/null 2>&1
eq "$(need "$S")" "" "no need, though both shas changed"
eq "$(st "$S" PQ_STACK_FORK)" "$P" "and the fork point is the parent's new head"

echo "== restack: squash-merged, and GitHub restacked the child: landed ==" >&2
reset_tasks; stack_pair 4
S=$(mk_stacked 4)
g checkout -q main; g merge -q --squash "$PA" >/dev/null; g commit -q -m "squash pa-4"; SQ=$(g rev-parse HEAD)
g rebase -q --onto main "$F" "$CH"; gpush main "$CH"
rows_merged "$SQ"
out=$(restack "$S" 2>&1)
eq "$(st "$S" PQ_STACK_PARENT)" "" "the parent is cleared"
eq "$(need "$S")" "" "with no need"
has "$out" "ch-4: #10 merged - #11 is the bottom of its stack now" "and said"
eq "$(restack "$S" 2>&1)" "" "and from then on it is not looked at"

echo "== restack: squash-merged, and the child still carries the parent's old commits ==" >&2
reset_tasks; stack_pair 5
S=$(mk_stacked 5)
g checkout -q main; g merge -q --squash "$PA" >/dev/null; g commit -q -m "squash pa-5"; SQ=$(g rev-parse HEAD); gpush main
rows_merged "$SQ"
restack "$S" >/dev/null 2>&1
eq "$(need "$S")" "$(fp main "$F")" "due, fingerprinted by the default branch's name and the fork point"
eq "$(verdict "$S")" "stale" "onto the default branch"
eq "$(st "$S" PQ_STACK_PARENT)" "$PA" "the parent is kept until it lands"
g rebase -q --onto main "$F" "$CH"; gpush "$CH"
restack "$S" >/dev/null 2>&1
eq "$(st "$S" PQ_STACK_PARENT)" "" "the child's own restack lands it"
eq "$(need "$S")" "" "and clears the need"

echo "== restack: a merge-commit merge puts the fork point on main: landed ==" >&2
reset_tasks; stack_pair 6
S=$(mk_stacked 6)
g checkout -q main; g merge -q --no-ff -m "merge pa-6" "$PA"; MC=$(g rev-parse HEAD); gpush main
rows_merged "$MC"
restack "$S" >/dev/null 2>&1
eq "$(st "$S" PQ_STACK_PARENT)$(need "$S")" "" "landed, with no need"

echo "== restack: a closed parent is handed over once, and recovers if it reopens ==" >&2
reset_tasks; stack_pair 7
S=$(mk_stacked 7)
reset_caches
cache_row "$RREPO" "$PA" 10 CLOSED "" main
cache_row "$RREPO" "$CH" 11 OPEN "" "$PA"
out=$(restack "$S" 2>&1)
eq "$(st "$S" PQ_STACK_NEEDS)" "closed" "handed over"
has "$out" "ch-7: #10, which #11 is stacked on, was closed without merging - decide what becomes of #11" "and said"
eq "$(restack "$S" 2>&1)" "" "once"
rows_open
restack "$S" >/dev/null 2>&1
eq "$(need "$S")" "" "reopened: cleared"

echo "== restack: a missing ref or object gives no verdict and writes nothing ==" >&2
reset_tasks; stack_pair 8; rows_open
g checkout -q "$PA"; g commit -q --amend -m "pa-8: rewritten"; gpush "$PA"
S=$(mk_stacked 8)
st_set "$S" PQ_STACK_FORK 0123456789abcdef0123456789abcdef01234567
before=$(cat "$S/state.env")
restack "$S" >/dev/null 2>&1
eq "$(cat "$S/state.env")" "$before" "an unknown fork point: nothing written"
st_set "$S" PQ_STACK_FORK "$F"
reset_caches
cache_row "$RREPO" "$PA" 10 OPEN "" main
cache_row "$RREPO" tom/nowhere 11 OPEN "" "$PA"
sed -i '' "s#^branch: .*#branch:   tom/nowhere#" "$S/plan.md"
before=$(cat "$S/state.env")
restack "$S" >/dev/null 2>&1
eq "$(cat "$S/state.env")" "$before" "a branch not on origin: nothing written"
reset_caches; cache_row "$RREPO" tom/nowhere 11 OPEN "" "$PA"
restack "$S" >/dev/null 2>&1
eq "$(cat "$S/state.env")" "$before" "no row for the parent this tick: nothing written"

echo "== restack: its own pull request settled takes the need with it ==" >&2
reset_tasks; stack_pair 9; rows_open
S=$(mk_stacked 9)
st_set "$S" PQ_STACK_DUE 123; st_set "$S" PQ_STACK_NEEDS restack
reset_caches; cache_row "$RREPO" "$CH" 11 MERGED "" main
restack "$S" >/dev/null 2>&1
eq "$(need "$S")" "" "nothing left to hold the gate or read in pq ls"

echo "== restack: --dry-run writes nothing ==" >&2
reset_tasks; stack_pair 10; rows_open
S=$(mk_stacked 10)
g checkout -q "$PA"; g commit -q --amend -m "pa-10: rewritten"; gpush "$PA"
before=$(cat "$S/state.env")
restack "$S" 1 >/dev/null 2>&1
eq "$(cat "$S/state.env")" "$before" "a rebased parent: nothing written"
g checkout -q main; g merge -q --squash "$PA" >/dev/null; g commit -q -m "squash pa-10"; SQ=$(g rev-parse HEAD)
g rebase -q --onto main "$F" "$CH"; gpush main "$CH"
rows_merged "$SQ"
out=$(restack "$S" 1 2>&1)
has "$out" "would record that #11 is the bottom of its stack now - #10 merged" "landed: says so"
eq "$(cat "$S/state.env")" "$before" "and writes nothing"

# ── asking the agent ────────────────────────────────────────────────────────
set_panes() {                           # "pane<TAB>agent<TAB>status" lines
  PIDX=$1; PIDX_OK=1
  jq -Rs 'split("\n") | map(select(length > 0) | split("\t")
            | { pane_id: .[0],
                agent:        (if (.[1] // "") == "" then null else .[1] end),
                agent_status: (if (.[2] // "") == "" then null else .[2] end) })
          | { result: { snapshot: { panes: . } } }' <<<"$1" > "$PANES_JSON"
}
idle()    { set_panes "$(printf 'w1:p1\tclaude\tidle')"; }
working() { set_panes "$(printf 'w1:p1\tclaude\tworking')"; }
prompts() { grep -c "^agent	prompt	" "$HERDR_LOG" 2>/dev/null || true; }
prompt_text() { grep "^agent	prompt	" "$HERDR_LOG" | tail -1 | cut -f4; }
perm_on()  { mkdir -p "$PQ_HOME/tasks"; task_link "$1"; printf '{"event":"permission","at":1}' > "$(task_home "$1")/agent.json"; }
perm_off() { rm -f "$(task_home "$1")/agent.json"; }
# The ask, a minute old.
age_asked() { st_set "$1" PQ_STACK_ASKED "$(( $(epoch) - STACK_DEBOUNCE - 1 ))"; }
# The debounce, run out: the need was first seen over a minute ago.
age_seen() { st_set "$1" PQ_STACK_SEEN_AT "$(( $(st "$1" PQ_STACK_SEEN_AT) - STACK_DEBOUNCE - 1 ))"; }
# A stacked task whose parent was rebased, seen once, with an idle agent in w1:p1.
due() {                                 # n -> S PA CH F P
  reset_tasks; stack_pair "$1"; rows_open
  S=$(mk_stacked "$1"); st_set "$S" PQ_PANE w1:p1; st_set "$S" PQ_REVIEW ready
  g checkout -q "$PA"; g commit -q --amend -m "$PA: rewritten"; gpush "$PA"; P=$(g rev-parse "$PA")
  idle; : > "$HERDR_LOG"; rm -f "$STUBBIN/.prompt-fail"
  restack "$S" >/dev/null 2>&1
}

echo "== debounce: no prompt on first sight, one after a minute with the same need ==" >&2
due 20
eq "$(prompts)" "0" "first sight: no prompt"
eq "$(st "$S" PQ_STACK_SEEN_FP)" "$(fp "$P" "$F")" "the need is noted"
eq "$(st "$S" PQ_STACK_DUE)" "$(fp "$P" "$F")" "and due from the first sight, so the gate and the watch hold off"
restack "$S" >/dev/null 2>&1
eq "$(prompts)" "0" "seconds later: still no prompt - GitHub's own restack may be landing"
age_seen "$S"; st_set "$S" PQ_WRAPUP_SINCE 2026-01-01T00:00:00Z
out=$(restack "$S" 2>&1)
eq "$(prompts)" "1" "a minute on: the agent is asked"
has "$out" "ch-20: #10 was rebased - asked its agent to move #11 onto it" "and said"
[[ "$(st "$S" PQ_STACK_ASKED)" =~ ^[0-9]+$ ]] && ok || bad "asked, when (got '$(st "$S" PQ_STACK_ASKED)')"
eq "$(st "$S" PQ_STACK_FIXES)" "1" "one try"
eq "$(st "$S" PQ_STACK_FP)" "$(fp "$P" "$F")" "for this need"
eq "$(st "$S" PQ_WRAPUP_SINCE)" "" "and its slot is held while it works"
T=$(prompt_text)
has "$T" "Pull request #10 (tom/pa-20), which this one is stacked on, was rebased" "the onto-parent text"
case "$T" in "First run git pull --rebase --autostash origin tom/ch-20: "*) ok ;; *) bad "it opens with the sync line (got '$T')" ;; esac
has "$T" "After that pull, run git fetch origin tom/pa-20. If git merge-base --is-ancestor origin/tom/pa-20 HEAD now succeeds, it already sits on it: stop there." "the guard, on a fresh parent"
has "$T" "git rebase --onto origin/tom/pa-20 $F." "--onto with the full fork sha"
has "$T" "git push --force-with-lease --force-if-includes" "the push flags"
has "$T" "this replaces any rule in your contract against rebasing a ready pull request" "and what it replaces"
hasnt "$T" "gh pr edit" "no retarget while the parent is open"
hasnt "$T" "'" "quote-free"

echo "== while asked: no second prompt; once idle, the same need left is handed over ==" >&2
idle
restack "$S" >/dev/null 2>&1
[ -n "$(st "$S" PQ_STACK_ASKED)" ] && ok || bad "idle on the next tick, a moment after the ask: not answered yet - the agent may not have started"
eq "$(st "$S" PQ_STACK_NEEDS)" "" "and not handed over mid-rebase"
age_asked "$S"
working
restack "$S" >/dev/null 2>&1
[ -n "$(st "$S" PQ_STACK_ASKED)" ] && ok || bad "working: still asked"
eq "$(prompts)" "1" "and no second prompt"
idle
out=$(restack "$S" 2>&1)
eq "$(st "$S" PQ_STACK_ASKED)" "" "idle again: the ask is answered"
eq "$(st "$S" PQ_STACK_NEEDS)" "restack" "the same need left: handed over"
has "$out" "ch-20: #10 was rebased, so #11 no longer sits on it, and its agent looked and left it as it was - look at it" "warned"
eq "$(prompts)" "1" "not asked again"
eq "$(restack "$S" 2>&1)" "" "warned once"

echo "== an ask is answered even on a tick that cannot judge the layer ==" >&2
saved_fork=$(st "$S" PQ_STACK_FORK); st_set "$S" PQ_STACK_ASKED 1
st_set "$S" PQ_STACK_FORK 0123456789abcdef0123456789abcdef01234567
restack "$S" >/dev/null 2>&1
eq "$(st "$S" PQ_STACK_ASKED)" "" "idle, with no verdict: the ask is still answered, so the watch is not held off"
st_set "$S" PQ_STACK_FORK "$saved_fork"

echo "== a new fingerprint restarts the clock ==" >&2
g checkout -q "$PA"; g commit -q --amend -m "$PA: again"; gpush "$PA"; P2=$(g rev-parse "$PA")
restack "$S" >/dev/null 2>&1
eq "$(st "$S" PQ_STACK_SEEN_FP)" "$(fp "$P2" "$F")" "the new need is noted"
eq "$(prompts)" "1" "and not prompted on first sight"
age_seen "$S"
restack "$S" >/dev/null 2>&1
eq "$(prompts)" "2" "a minute on, it is asked about the new one"
idle; g rebase -q --onto "$PA" "$F" "$CH"; gpush "$CH"
restack "$S" >/dev/null 2>&1
eq "$(need "$S")" "" "the agent's restack clears the need, and the handover with it"

echo "== the head it was asked onto is the fork point, though the parent gained a commit since ==" >&2
due 28; age_seen "$S"
restack "$S" >/dev/null 2>&1
eq "$(prompts)" "1" "asked onto the rebased head"
g rebase -q --onto "$PA" "$F" "$CH"; gpush "$CH"
g checkout -q "$PA"; gcommit "pa-28" "review fix"; gpush "$PA"
age_asked "$S"; idle
restack "$S" >/dev/null 2>&1
eq "$(st "$S" PQ_STACK_FORK)" "$P" "the fork point is the head it was moved onto"
eq "$(need "$S")" "" "and the parent's review fix since is only a gained commit"
eq "$(st "$S" PQ_STACK_TARGET)" "" "the ask's target is spent"

echo "== gating: no prompt to a working agent, a dialog, the watch's turn or the reviewer's ==" >&2
due 21; age_seen "$S"
working; restack "$S" >/dev/null 2>&1; eq "$(prompts)" "0" "working"
idle; perm_on "$S"; restack "$S" >/dev/null 2>&1; eq "$(prompts)" "0" "on a permission dialog"
perm_off "$S"
st_set "$S" PQ_WATCH_ASKED ci; restack "$S" >/dev/null 2>&1; eq "$(prompts)" "0" "the watch asked it something"
st_set "$S" PQ_WATCH_ASKED ""
for r in running posted; do
  st_set "$S" PQ_REVIEW "$r"; restack "$S" >/dev/null 2>&1; eq "$(prompts)" "0" "review $r"
done
st_set "$S" PQ_REVIEW pending; restack "$S" >/dev/null 2>&1; eq "$(prompts)" "1" "review pending: the restack goes first"
eq "$(st "$S" PQ_STACK_NEEDS)" "" "nothing was handed over on the way"

echo "== a dialog or a herdr error: said once, and retried ==" >&2
due 22; age_seen "$S"
printf agent_blocked > "$STUBBIN/.prompt-fail"
out=$(restack "$S" 2>&1)
has "$out" "the agent is on a dialog - telling it that #10 was rebased, so #11 no longer sits on it waits for you to answer it" "a dialog"
eq "$(restack "$S" 2>&1)" "" "said once"
eq "$(st "$S" PQ_STACK_ASKED)$(st "$S" PQ_STACK_FIXES)" "" "and nothing counted"
printf boom > "$STUBBIN/.prompt-fail"
out=$(restack "$S" 2>&1)
has "$out" "could not tell its agent that #10 was rebased, so #11 no longer sits on it (boom) - retrying each tick" "an error"
rm -f "$STUBBIN/.prompt-fail"
restack "$S" >/dev/null 2>&1
[ -n "$(st "$S" PQ_STACK_ASKED)" ] && [ -z "$(st "$S" PQ_STACK_WAIT)" ] && ok || bad "the next tick gets through, and the wait clears"

echo "== handover: the agent gone, or three tries ==" >&2
n=23
for gone in noagent missing; do
  due "$n"; n=$((n + 10)); age_seen "$S"
  if [ "$gone" = noagent ]; then set_panes "$(printf 'w1:p1\t\t')"; else set_panes ""; fi
  out=$(restack "$S" 2>&1)
  eq "$(st "$S" PQ_STACK_NEEDS)" "restack" "$gone: handed over"
  has "$out" "and its agent is gone - look at it" "$gone: said why"
  eq "$(prompts)" "0" "$gone: no prompt"
done
due 24; age_seen "$S"; st_set "$S" PQ_STACK_FIXES 3
out=$(restack "$S" 2>&1)
eq "$(st "$S" PQ_STACK_NEEDS)" "restack" "three tries: handed over"
has "$out" "its agent has had 3 goes at restacking it - look at it" "said why"
eq "$(prompts)" "0" "with no fourth"

echo "== onto the default branch: its own text ==" >&2
reset_tasks; stack_pair 25
S=$(mk_stacked 25); st_set "$S" PQ_PANE w1:p1; st_set "$S" PQ_REVIEW ready
g checkout -q main; g merge -q --squash "$PA" >/dev/null; g commit -q -m "squash pa-25"; SQ=$(g rev-parse HEAD); gpush main
rows_merged "$SQ"; idle; : > "$HERDR_LOG"
restack "$S" >/dev/null 2>&1; age_seen "$S"
out=$(restack "$S" 2>&1)
has "$out" "ch-25: #10 merged but #11 still carries its old commits - asked its agent to move it onto main" "said"
T=$(prompt_text)
has "$T" "Pull request #10 (tom/pa-25), which this one was stacked on, has merged into main, but this branch still carries its commits" "the onto-default text"
case "$T" in "First run git pull --rebase --autostash origin tom/ch-25: "*) ok ;; *) bad "it opens with the sync line (got '$T')" ;; esac
has "$T" "After that pull, move your own commits onto main: git fetch origin main, then git rebase --onto origin/main $F." "--onto main with the full fork sha"
has "$T" "git push --force-with-lease --force-if-includes" "the push flags"
has "$T" "If the pull request is not aimed at main yet, aim it there: gh pr edit 11 --base main." "the retarget"
has "$T" "This replaces any rule in your contract against rebasing a ready pull request." "and what it replaces"

echo "== --dry-run says what it would do about a need and writes nothing ==" >&2
reset_tasks; stack_pair 27; rows_open
S=$(mk_stacked 27); st_set "$S" PQ_PANE w1:p1
g checkout -q "$PA"; g commit -q --amend -m "$PA: rewritten"; gpush "$PA"
idle; : > "$HERDR_LOG"
before=$(cat "$S/state.env")
out=$(restack "$S" 1 2>&1)
has "$out" "would wait 60s to see whether GitHub restacks ch-27" "first sight: says it would wait"
eq "$(cat "$S/state.env")" "$before" "and writes nothing, not even when it was seen"
restack "$S" >/dev/null 2>&1; age_seen "$S"; before=$(cat "$S/state.env")
out=$(restack "$S" 1 2>&1)
has "$out" "would prompt ch-27 - #10 was rebased, so #11 no longer sits on it" "due: says it would prompt"
eq "$(prompts)" "0" "without prompting"
eq "$(cat "$S/state.env")" "$before" "or writing"
st_set "$S" PQ_STACK_FIXES 3; before=$(cat "$S/state.env")
out=$(restack "$S" 1 2>&1)
has "$out" "would leave ch-27's restack to you" "a handover: says it would"
eq "$(cat "$S/state.env")" "$before" "and writes nothing"

echo "== pq ls: restacking, restack and parent closed, the needs-you count and --json ==" >&2
reset_tasks; idle
ls_task() {                             # prio word -> task_dir
  CH=tom/ls-$2; PA=tom/below-$2; F=$(g rev-parse main)
  local d; d=$(mk_stacked "$1"); st_set "$d" PQ_PANE w1:p1; printf '%s' "$d"
}
LA=$(ls_task 41 asked);   st_set "$LA" PQ_STACK_ASKED 1
LR=$(ls_task 42 restack); st_set "$LR" PQ_STACK_NEEDS restack
LC=$(ls_task 43 closed);  st_set "$LC" PQ_STACK_NEEDS closed
LN=$(ls_task 44 none)
eq "$(agent_cell "$LA" "done")" "restacking" "its agent is on it"
eq "$(agent_cell "$LR" "done")" "restack" "handed to you"
eq "$(agent_cell "$LC" "done")" "parent closed" "the parent closed"
hasnt "$(agent_cell "$LN" "done")" "restack" "nothing to restack: none of them"
out=$(PQ_WIDTH=200 cmd_ls 2>&1)
has "$out" "(2 needs you)" "restack and parent closed count into needs you, restacking does not"
json=$(cmd_ls --json 2>/dev/null)
eq "$(jq -r '[.[] | {(.task): .restack}] | add | [.["ls-asked"], .["ls-restack"], .["ls-closed"], .["ls-none"]] | map(tostring) | join(" ")' <<<"$json")" \
  "asked restack closed null" "--json: a restack key"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
