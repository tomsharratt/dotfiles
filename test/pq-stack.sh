#!/usr/bin/env bash
# test/pq-stack.sh - linking a stacked task's pull request into its parent's
# stack on GitHub (stack_link), against a `gh` stub that answers `stack --help`,
# `stack link` and the stacks API the way the real ones did in the sandbox on
# 2026-10-16, and logs every call it gets.
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
printf '#!/bin/sh\ncase "$*" in "api snapshot") echo %s; exit 0 ;; esac\nexit 1\n' \
  "'{\"result\":{\"snapshot\":{\"panes\":[]}}}'" > "$STUBBIN/herdr"
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

cleanup() { rm -rf "$PQ_HOME" "$STUBBIN" "${REPO:-}"; }
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

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
