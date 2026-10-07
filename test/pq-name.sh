#!/usr/bin/env bash
# test/pq-name.sh - naming: `pq add` leaves a task in new/, under its plan's
# title, and the tick names it and queues it. The add has to be over the moment
# its last question is answered, so it can close the popup it runs in; so naming
# must be right without it - in stamp order, so a chain added a minute apart
# lands whole on one pass; told once, not every tick, when it cannot be; and
# never spending Haiku on a dry run, on the limit, or past its tries.
#
# Haiku is a stub that answers by a MARKER line in the plan it is handed, and
# keeps what it was handed. `gh` knows of no pull request and `herdr` of no pane.
#
# SC2015: `ok` never fails, so `[ ... ] && ok || bad` is an if/else.
# shellcheck disable=SC2015
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PQ_HOME=$(mktemp -d)
export PQ_HOME

STUBBIN=$(mktemp -d)
HAIKU="$STUBBIN/haiku"
mkdir -p "$HAIKU"
# Each call's stdin is kept as $HAIKU/<n>, so a test can count the calls and read
# what the namer was shown. $STUBBIN/.limit turns every reply into the limit's.
cat > "$STUBBIN/claude" <<EOF
#!/bin/sh
n=\$(ls "$HAIKU" | wc -l | tr -d ' '); n=\$((n + 1))
cat > "$HAIKU/\$n"
reply() { jq -nc --arg r "\$1" '{result: \$r, total_cost_usd: 0.002, session_id: ("s-" + (\$r | length | tostring))}'; }
if [ -f "$STUBBIN/.limit" ]; then reply "You've hit your org's monthly spend limit"; exit 0; fi
case "\$(cat "$HAIKU/\$n")" in
  *"MARKER: junk"*) reply 'Sorry, I cannot.' ;;
  *"MARKER: "*)
    m=\$(sed -n 's/^MARKER: //p' "$HAIKU/\$n" | head -1)
    reply "{\"branch\":\"tom/\$m\",\"intent\":\"Do \$m.\",\"security\":false}" ;;
  *) reply '{}' ;;
esac
EOF
# No pull request anywhere: an empty list, or nothing at all through a `-q`.
printf '#!/bin/sh\ncase " $* " in *" -q "*) exit 0 ;; esac\necho "[]"\n' > "$STUBBIN/gh"
cat > "$STUBBIN/herdr" <<'EOF'
#!/bin/sh
case "$*" in
  "api snapshot") echo '{"result":{"snapshot":{"panes":[]}}}'; exit 0 ;;
esac
exit 1
EOF
printf '#!/bin/sh\nexit 0\n' > "$STUBBIN/wt-stub"
chmod +x "$STUBBIN/claude" "$STUBBIN/gh" "$STUBBIN/herdr" "$STUBBIN/wt-stub"
export PATH="$STUBBIN:$PATH"
export PQ_WT="$STUBBIN/wt-stub"

# shellcheck source=/dev/null
source "$HERE/../.local/bin/pq"
# shellcheck source=test/lib.sh
source "$HERE/lib.sh"
gum_stub "$STUBBIN" "$PQ_HOME/.gum"
at_terminal() { return 0; }

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { if [ "$1" = "$2" ]; then ok; else bad "$3 (got '$1', want '$2')"; fi; }
has()   { case "$1" in *"$2"*) ok ;; *) bad "$3 (got '$1')" ;; esac; }
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
  rm -rf "$PQ_HOME/new" "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done" "$PQ_HOME/archive" "$PQ_HOME/tasks"
  mkdir -p "$PQ_HOME/new" "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done" "$PQ_HOME/archive" "$PQ_HOME/tasks"
  rm -f "$HAIKU"/* "$STUBBIN/.limit"
}
haiku_calls() { find "$HAIKU" -type f | wc -l | tr -d ' '; }
# A plan with a title, and the marker that tells the stub what to call it.
mkplan() {                              # file title marker
  printf '# %s\n\nMARKER: %s\n\nDo it.\n' "$2" "$3" > "$1"
}
# One pass of the tick, at cap 0 so nothing is dispatched; its stderr is kept.
tick() { tick_body 0 "${1:-0}" 2>"$PQ_HOME/.tick.err"; }
said() { cat "$PQ_HOME/.tick.err"; }

PA="$PQ_HOME/.a.md"; PB="$PQ_HOME/.b.md"; PC="$PQ_HOME/.c.md"

echo "== pq add leaves the task in new/, under its plan's title, and asks Haiku nothing ==" >&2
reset_tasks
mkplan "$PA" "Step 1 PR 01a - Schema, models and deletion paths" chain-a
add_new "$PA" --model opus --effort high 2>/dev/null; rc=$?
eq "$rc" 0 "the add goes through"
a=$(queue_ordered new | tail -1)
eq "$(slug_of "$a")" "step-1-pr-01a-schema-models-and-deletion" "named for its title, cut between words"
eq "$(haiku_calls)" 0 "and no naming call was made"
eq "$(hdr "$a/plan.md" branch)" "" "it has no branch yet"
eq "$(hdr "$a/plan.md" model)/$(hdr "$a/plan.md" effort)" "opus/high" "but has every answer the wizard took"
[ -e "$PQ_HOME/tasks/$(basename "$a")" ] && bad "a task in new/ is handed to nothing, so it has no stable link" || ok

echo "== pq ls shows it, waiting to be named ==" >&2
out=$(PQ_WIDTH=200 main ls 2>&1)
has "$out" "step-1-pr-01a-schema-models-and-deletion" "under its title"
has "$(grep step-1-pr-01a <<<"$out")" " new " "as new"
has "$out" "naming" "and what it is waiting for"
has "$out" "0 queued, 1 new" "and the summary counts it"
eq "$(main ls --json 2>/dev/null | jq -r '.[0] | "\(.state) \(.branch)"')" "new null" "--json says so, with no branch"

echo "== a chain added before any tick is named whole on one pass, in order ==" >&2
mkplan "$PB" "Step 1 PR 01b - Token specs" chain-b
add_new "$PB" --after "$(slug_of "$a")" 2>/dev/null
b=$(queue_ordered new | tail -1)
eq "$(cat "$b/after.new" 2>/dev/null)" "$(stamp_of "$a")" "a blocker with no name yet is held by its stamp"
[ -e "$b/after" ] && bad "and nothing is resolved before it has a branch" || ok
out=$(PQ_WIDTH=200 main ls 2>&1)
has "$out" "after step-1-pr-01a-.." "the dependent says what it waits on"
sa=$(stamp_of "$a"); sb=$(stamp_of "$b")
tick
qa=$(task_by_stamp "$sa"); qb=$(task_by_stamp "$sb")
eq "$(state_of "$qa")/$(slug_of "$qa")" "queue/chain-a" "the blocker is queued under the slug its branch reduces to"
eq "$(state_of "$qb")/$(slug_of "$qb")" "queue/chain-b" "and so is what waits on it, on the same pass"
eq "$(stamp_of "$qa") $(stamp_of "$qb")" "$sa $sb" "each keeping its stamp, so the queue is still add-order"
eq "$(cat "$qb/after")" "chain-a"$'\t'"$(hdr "$qa/plan.md" repo)"$'\t'"tom/chain-a" "the stamp became the blocker's (label, repo, branch)"
[ -e "$qb/after.new" ] || [ -e "$qb/state.env" ] && bad "a queued task keeps nothing of its naming" || ok
eq "$(after_state "$qb" | cut -f1)" "waiting chain-a 1" "and it gates the dependent"
[ -L "$PQ_HOME/tasks/$(basename "$qa")" ] && ok || bad "the named task gets its stable link"
[ -e "$PQ_HOME/tasks/$(basename "$a")" ] && bad "and none is left under its old name" || ok
has "$(said)" "queued chain-a - tom/chain-a" "the run log says what each was named"
has "$(said)" ", 2 named" "and the summary counts them"
eq "$(cut -f1,3 <<<"$(cost_sum "$qa")")" $'0.002\t0.002' "the naming call is in the task's ledger"

echo "== the header gains its three keys where pq add always wrote them ==" >&2
eq "$(sed -n '2,8p' "$qb/plan.md" | cut -d: -f1 | tr '\n' ' ')" "repo branch model effort intent source added " "in the same order as ever"
eq "$(hdr "$qb/plan.md" intent)" "Do chain-b." "the intent is Haiku's"
eq "$(plan_body "$qb/plan.md")" "$(cat "$PB")" "and the plan itself is untouched"

echo "== the namer reads the task's own copy, without its header ==" >&2
reset_tasks
mkplan "$PC" "A plan edited after it was added" as-added
add_new "$PC" 2>/dev/null
mkplan "$PC" "A plan edited after it was added" as-edited
tick
eq "$(slug_of "$(queue_ordered | tail -1)")" "as-added" "named for the plan that was added, not what the source says now"
hasnt "$(cat "$HAIKU/1")" "repo:" "and shown no header"
has "$(cat "$HAIKU/1")" "# A plan edited after it was added" "but the whole plan"

echo "== a blocker that already has a name resolves at the add ==" >&2
add_new "$PA" --after as-added 2>/dev/null
c=$(queue_ordered new | tail -1)
eq "$(cut -f3 "$c/after")" "tom/as-added" "straight to its branch"
[ -e "$c/after.new" ] && bad "with nothing held by stamp" || ok

echo "== a dry run names nothing and asks Haiku nothing ==" >&2
n0=$(haiku_calls)
tick 1
has "$(said)" "would name $(slug_of "$c")" "it says what it would name"
eq "$(haiku_calls)" "$n0" "without a naming call"
eq "$(state_of "$(task_by_stamp "$(stamp_of "$c")")")" "new" "and it stays in new/"

echo "== naming that cannot go through is said once, and given up after its tries ==" >&2
reset_tasks
mkplan "$PA" "A plan Haiku cannot name" junk
add_new "$PA" 2>/dev/null; j=$(queue_ordered new | tail -1)
mkplan "$PB" "Waits on it" waiter
add_new "$PB" --after "$(slug_of "$j")" 2>/dev/null; w=$(queue_ordered new | tail -1)
tick
has "$(said)" "could not name it - Haiku gave no usable branch - the next tick tries again" "the first failure is said"
eq "$(haiku_calls)" 1 "and what waits on it is not named before it - no call is spent on it"
eq "$(state_of "$w")" "new" "it waits, unnamed, with its blocker"
tick
hasnt "$(said)" "could not name" "the same failure again is not said again"
eq "$(st "$j" PQ_NAME_FAILS)" 2 "but it is counted"
tick
has "$(said)" "3 tries in a row, so it is left for you (pq rm" "the last try gives up, and says so"
tick
eq "$(haiku_calls)" 3 "and no more is spent on it"
out=$(PQ_WIDTH=200 main ls 2>&1)
has "$out" "naming failed" "pq ls shows it"
has "$out" "(1 needs you)" "as wanting you"
has "$out" "after a-plan-haiku-c.." "while its dependent names what it waits on"

echo "== a blocker removed before it was named holds its dependent for good ==" >&2
reset_tasks
mkplan "$PA" "Gone before its name" gone
add_new "$PA" 2>/dev/null; x=$(queue_ordered new | tail -1)
mkplan "$PB" "Still wants it" still-wants
add_new "$PB" --after "$(slug_of "$x")" 2>/dev/null; y=$(queue_ordered new | tail -1)
gum_reset; gum_answer ""
out=$( (main rm "$(slug_of "$x")") 2>&1)
has "$out" "removed $(slug_of "$x")" "a task in new/ is removed by its title"
has "$out" "was a blocker for: $(slug_of "$y") - with no name ever, nothing says which branch they meant" "and pq rm says what that strands"
tick
has "$(said)" "waits on a task that was removed before it was named" "the tick says it is held"
eq "$(state_of "$y")" "new" "and holds it"
eq "$(haiku_calls)" 0 "without asking for a name it could never use"
tick
hasnt "$(said)" "removed before it was named" "said once"
has "$(PQ_WIDTH=200 main ls 2>&1)" "blocker gone" "and pq ls shows why"

echo "== the usage limit is waited out, quietly, and never counted as a try ==" >&2
reset_tasks
mkplan "$PA" "Named once the limit lifts" after-limit
add_new "$PA" 2>/dev/null; l=$(queue_ordered new | tail -1)
touch "$STUBBIN/.limit"
tick
has "$(said)" "naming hit the usage limit (You've hit your org's monthly spend limit) - it is named once the limit lifts" "said in the limit's own words"
tick
hasnt "$(said)" "usage limit" "and not again while it lasts"
eq "$(st "$l" PQ_NAME_FAILS)" "" "with no try counted"
rm -f "$STUBBIN/.limit"
tick
eq "$(slug_of "$(queue_ordered | tail -1)")" "after-limit" "once it lifts, the next tick names it"

echo "== pq after refuses a task with no name, as either side ==" >&2
reset_tasks
mkplan "$PA" "Unnamed" unnamed-one
add_new "$PA" 2>/dev/null; u=$(queue_ordered new | tail -1)
q=$(add_as "$PB" tom/named-one 2>/dev/null; queue_ordered | tail -1)
out=$( (main after "$(slug_of "$u")" "$(slug_of "$q")") 2>&1); rc=$?
eq "$rc" 1 "as the task given blockers"
has "$out" "has no name yet" "saying why"
out=$( (main after "$(slug_of "$q")" "$(slug_of "$u")") 2>&1); rc=$?
eq "$rc" 1 "and as the blocker given"
has "$out" "has no name yet, so there is no branch to wait on" "saying why"
[ -e "$q/after" ] && bad "nothing is written either way" || ok

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
