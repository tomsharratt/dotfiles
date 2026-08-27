#!/usr/bin/env bash
# test/pq-slots.sh - what the cap actually counts. Exercises slot_held /
# slot_state / active_slots directly, then the whole thing through tick_body,
# the same way test/pq-reap.sh exercises the teardown pass.
#
# The bug these pin down: reconcile frees a slot the moment a pull request
# exists, but a Claude Code agent does not exit when it opens one - so a cap of
# 3 was running six agents, three in running/ and three still wrapping up in
# done/. The release therefore has to be a timer (an agent that has genuinely
# finished sits `idle` forever), and the boundary cases below are the difference
# between over-dispatching and stalling the queue outright.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PQ_HOME=$(mktemp -d)
export PQ_HOME

# Stubs so nothing here reaches a network or a real herdr socket - same
# reasoning as test/pq-reap.sh. Unlike that file, the `herdr` stub here serves a
# snapshot each case CHOOSES, out of a file set_panes writes: tick_body calls
# pidx_load itself, so a hand-primed PIDX global would be overwritten the moment
# a case went through the tick rather than calling slot_held directly. Going
# through the real pidx_load also means these cases exercise its jq extraction
# rather than a hand-built imitation of it.
STUBBIN=$(mktemp -d)
PANES_JSON="$STUBBIN/.panes.json"
printf '{"result":{"snapshot":{"panes":[]}}}' > "$PANES_JSON"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/claude"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/gh"
cat > "$STUBBIN/herdr" <<EOF
#!/bin/sh
case "\$*" in
  "api snapshot") cat "$PANES_JSON"; exit 0 ;;
esac
exit 1
EOF
printf '#!/bin/sh\nexit 0\n' > "$STUBBIN/wt-stub"
chmod +x "$STUBBIN/claude" "$STUBBIN/gh" "$STUBBIN/herdr" "$STUBBIN/wt-stub"
export PATH="$STUBBIN:$PATH"
export PQ_WT="$STUBBIN/wt-stub"

# shellcheck source=/dev/null
source "$HERE/../.local/bin/pq"

# Never let a tick_body case pay for a real `gh` round trip - each one primes
# PR_CACHE itself. Same neutering as test/pq-reap.sh.
pr_load_all() { :; }

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }

cleanup() { rm -rf "$PQ_HOME" "$STUBBIN" "${REPO:-}"; }
trap cleanup EXIT

# A real throwaway repo: hdr's repo field is checked for existence on the
# dispatch path, and repo_base reads a genuine remote-tracking symbolic ref.
REPO=$(mktemp -d)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$REPO/.git/refs/remotes/origin"
git -C "$REPO" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master

# A clean baseline regardless of the ambient environment - this test may well
# run inside a Herdr pane, and reap_ok reads exactly these.
unset HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID

# archive_pass must not quietly move fixtures out from under a tick_body case.
PQ_DONE_KEEP=99
PQ_WRAPUP_GRACE=300

reset_caches() { PR_CACHE="$PQ_HOME/.test.pr"; PR_ANS="$PQ_HOME/.test.ans"; : > "$PR_CACHE"; : > "$PR_ANS"; }
cache_row() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$PR_CACHE"; }   # repo branch num state draft base

reset_tasks() {
  rm -rf "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done" "$PQ_HOME/archive"
  mkdir -p "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done" "$PQ_HOME/archive"
}
reset_tasks

# An ISO stamp N seconds in the past. BSD `date -v`, like every date call in pq
# itself - this is a darwin tool.
# The clock is PINNED for this file rather than read off the wall, because the
# boundary cases below sit one second either side of PQ_WRAPUP_GRACE.
#
# `st_set ... "$(ago 299)"` followed by a `slot_held` that reads the real clock is
# a one-second race: any pause between those two lines - a loaded machine, another
# test's `git`, a real `pq run` ticking alongside - makes the difference 300, the
# `>=` fires, and "an agent idle for less than the grace still holds its slot"
# fails for a reason that has nothing to do with the code under test. Observed
# once in ~13 full-suite runs, and reproducible on demand by putting a `sleep 1`
# between the two lines.
#
# Pinning does not weaken the assertion - it sharpens it. 299 and 300 now differ
# by exactly one second no matter how long the shell takes to get there, which is
# what makes testing a `>=` boundary meaningful at all. `now` is pinned alongside
# `epoch` so the stamp slot_held WRITES and the clock it later reads agree.
FAKE_NOW=$(date -u '+%s')
epoch() { printf '%s' "$FAKE_NOW"; }
now()   { date -u -r "$FAKE_NOW" '+%Y-%m-%dT%H:%M:%SZ'; }
ago()   { date -u -r "$(( FAKE_NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }

# tick_body writes its verdict to the PQ_SUMMARY global, which a command
# substitution would strip along with the subshell it ran in - so its output
# goes through a file and the call itself stays in this shell.
TICKOUT="$PQ_HOME/.tick.out"
tick() {                                # cap dry -> stdout+stderr in $OUT
  PQ_SUMMARY=""
  tick_body "$1" "$2" > "$TICKOUT" 2>&1
  OUT=$(cat "$TICKOUT")
}

# A task built by hand in any state, bypassing dispatch - just enough plan.md
# for hdr()/state_of(), plus a pane id for pane_state to be steered against.
mk_task() {                             # state prio slug branch pane -> task_dir
  local state=$1 prio=$2 slug=$3 branch=$4 pane=$5
  local dir="$PQ_HOME/$state/$(printf '%014d' $(( 20260101000000 + 10#$prio )))-$slug"
  mkdir -p "$dir"
  {
    printf -- '---\n'
    printf 'repo:     %s\n' "$REPO"
    printf 'branch:   %s\n' "$branch"
    printf 'model:    sonnet\n'
    printf 'effort:   xhigh\n'
    printf 'intent:   test fixture\n'
    printf 'added:    2026-01-01T00:00:00Z\n'
    printf -- '---\n\nplan body\n'
  } > "$dir/plan.md"
  [ -n "$pane" ] && st_set "$dir" PQ_PANE "$pane"
  printf '%s' "$dir"
}

# Steer pane_state, both ways at once: the PIDX global for cases that call
# slot_held/slot_state directly, and the snapshot the stubbed herdr serves for
# cases that go through tick_body's own pidx_load. An empty agent or status
# field becomes JSON null, which is what herdr really sends and what pidx_load's
# `// ""` is there to absorb.
set_panes() {                           # "pane<TAB>agent<TAB>status" lines
  PIDX=$1; PIDX_OK=1
  if [ -z "$1" ]; then
    printf '{"result":{"snapshot":{"panes":[]}}}' > "$PANES_JSON"
    return
  fi
  jq -Rs 'split("\n") | map(select(length > 0) | split("\t")
            | { pane_id: .[0],
                agent:        (if (.[1] // "") == "" then null else .[1] end),
                agent_status: (if (.[2] // "") == "" then null else .[2] end) })
          | { result: { snapshot: { panes: . } } }' <<<"$1" > "$PANES_JSON"
}

echo "== slot_held: one done task, every pane state ==" >&2
reset_tasks
D=$(mk_task 'done' 001 wrapping tom/wrapping w1:p1)

set_panes "$(printf 'w1:p1\tclaude\tworking')"
slot_held "$D" && ok || bad "a working agent must hold its slot"
eq "$(st "$D" PQ_WRAPUP_SINCE)" "" "working leaves no wrap-up clock running"

set_panes "$(printf 'w1:p1\tclaude\tblocked')"
slot_held "$D" && ok || bad "a blocked agent must hold its slot - it will resume, it has not finished"
eq "$(st "$D" PQ_WRAPUP_SINCE)" "" "blocked leaves no wrap-up clock running"

set_panes "$(printf 'w1:p1\tclaude\tidle')"
slot_held "$D" && ok || bad "a just-gone-idle agent still holds its slot - the clock only starts now"
[ -n "$(st "$D" PQ_WRAPUP_SINCE)" ] && ok || bad "going idle must start the wrap-up clock"

# The clock having started, wind it back past the grace and the slot goes.
st_set "$D" PQ_WRAPUP_SINCE "$(ago 301)"
slot_held "$D" && bad "an agent idle past PQ_WRAPUP_GRACE must release its slot" || ok

st_set "$D" PQ_WRAPUP_SINCE "$(ago 299)"
slot_held "$D" && ok || bad "an agent idle for less than the grace still holds its slot"

# Exactly at the boundary: >= is the documented comparison, so 300 releases.
st_set "$D" PQ_WRAPUP_SINCE "$(ago 300)"
slot_held "$D" && bad "idle for exactly PQ_WRAPUP_GRACE must release (the check is >=)" || ok

# Coming back to life clears the clock, so a later idle spell starts fresh
# rather than inheriting a stale stamp that would release it instantly.
st_set "$D" PQ_WRAPUP_SINCE "$(ago 299)"
set_panes "$(printf 'w1:p1\tclaude\tworking')"
slot_held "$D" && ok || bad "an agent back at work holds its slot again"
eq "$(st "$D" PQ_WRAPUP_SINCE)" "" "going back to work must clear the wrap-up clock"

echo "== slot_held: unknown runs the clock too, so it can never stall ==" >&2
# agent bound, no status. Counts (pq's house style: no idea is not dead) but
# on a deadline - a permanently unknown pane must not hold a slot forever.
set_panes "$(printf 'w1:p1\tclaude\t')"
eq "$(pane_state w1:p1)" "unknown" "a bound agent with no status reads as unknown"
st_set "$D" PQ_WRAPUP_SINCE ""
slot_held "$D" && ok || bad "an unknown agent holds its slot at first"
[ -n "$(st "$D" PQ_WRAPUP_SINCE)" ] && ok || bad "unknown must start the wrap-up clock, or it stalls the queue"
st_set "$D" PQ_WRAPUP_SINCE "$(ago 301)"
slot_held "$D" && bad "an unknown pane past the grace must release its slot" || ok

echo "== slot_held: herdr's 'done' is per-turn, so it gets the grace too ==" >&2
# The five words herdr's agent_status can hold are idle/working/blocked/done/
# unknown. `done` means the agent finished the TURN it was on - an agent that
# opens a PR and then goes back in to fix CI passes through it every time - so
# releasing the moment it appears would be the original bug in a subtler form.
set_panes "$(printf 'w1:p1\tclaude\tdone')"
eq "$(pane_state w1:p1)" "done" "herdr's done status reaches pane_state intact"
st_set "$D" PQ_WRAPUP_SINCE ""
slot_held "$D" && ok || bad "a just-finished turn must not hand the slot away between turns"
[ -n "$(st "$D" PQ_WRAPUP_SINCE)" ] && ok || bad "done must start the wrap-up clock"
st_set "$D" PQ_WRAPUP_SINCE "$(ago 301)"
slot_held "$D" && bad "done past the grace must release the slot" || ok
# And going back to work between turns clears it, so the grace restarts.
set_panes "$(printf 'w1:p1\tclaude\tworking')"
slot_held "$D" && ok || bad "back to working after a done turn holds the slot again"
eq "$(st "$D" PQ_WRAPUP_SINCE)" "" "a new turn clears the clock the finished turn started"

echo "== slot_held: a status pq has never heard of is still bounded ==" >&2
# The safe default for a word herdr adds later: hold the slot, but on the clock,
# so nothing can hold one for ever on a status this code cannot interpret.
set_panes "$(printf 'w1:p1\tclaude\tsomething-new')"
st_set "$D" PQ_WRAPUP_SINCE ""
slot_held "$D" && ok || bad "an unrecognised status should hold the slot at first"
[ -n "$(st "$D" PQ_WRAPUP_SINCE)" ] && ok || bad "an unrecognised status must still be put on the clock"
st_set "$D" PQ_WRAPUP_SINCE "$(ago 301)"
slot_held "$D" && bad "an unrecognised status must release past the grace" || ok

echo "== slot_held: merged but not yet torn down still holds its slot ==" >&2
# reap_task holds a teardown off while the agent is still going, stamping
# PQ_MERGED without PQ_REAPED. That gap is exactly when the agent is still
# there, so the slot has to survive it - only PQ_REAPED ends it.
set_panes "$(printf 'wm:p1\tclaude\tworking')"
M=$(mk_task 'done' 005 mergedheld tom/mergedheld wm:p1)
st_set "$M" PQ_MERGED "$(now)"
st_set "$M" PQ_REAP_HELD agent
slot_held "$M" && ok || bad "merged-but-held means the agent is still going - the slot stays"
st_set "$M" PQ_REAPED "$(now)"
slot_held "$M" && bad "once torn down, the slot goes even with the pane still listed" || ok

echo "== slot_held: the states that release at once ==" >&2
st_set "$D" PQ_WRAPUP_SINCE ""
set_panes "$(printf 'w1:p1\t\t')"
eq "$(pane_state w1:p1)" "noagent" "a pane with no agent reads as noagent"
slot_held "$D" && bad "noagent means Claude exited - the slot goes at once, no grace" || ok

set_panes "$(printf 'w9:p9\tclaude\tworking')"
eq "$(pane_state w1:p1)" "missing" "a pane absent from the snapshot reads as missing"
slot_held "$D" && bad "missing means the workspace is gone - the slot goes at once" || ok

echo "== slot_held: herdr silent holds the slot rather than guessing ==" >&2
# PIDX_OK=0 is "no idea", and guessing 'finished' is the over-dispatch this
# whole mechanism exists to stop. Dispatch needs herdr too, so nothing is lost.
PIDX=""; PIDX_OK=0
eq "$(pane_state w1:p1)" "" "pane_state says nothing at all when herdr never answered"
st_set "$D" PQ_WRAPUP_SINCE ""
slot_held "$D" && ok || bad "a herdr outage must hold the slot, not release it"
eq "$(st "$D" PQ_WRAPUP_SINCE)" "" "a herdr outage must not start the clock - there is nothing to time"

echo "== slot_held: terminal tasks and missing panes hold nothing ==" >&2
set_panes "$(printf 'w1:p1\tclaude\tworking')"
R=$(mk_task 'done' 002 reaped tom/reaped w1:p1)
st_set "$R" PQ_REAPED "$(now)"
slot_held "$R" && bad "a reaped task holds no slot - its workspace is closed" || ok
C=$(mk_task 'done' 003 closed tom/closed w1:p1)
st_set "$C" PQ_CLOSED "$(now)"
slot_held "$C" && bad "a closed task holds no slot - it is over" || ok
N=$(mk_task 'done' 004 nopane tom/nopane "")
slot_held "$N" && bad "a task with no pane recorded holds no slot" || ok

echo "== slot_held: a corrupt clock holds the slot and rewrites itself ==" >&2
set_panes "$(printf 'w1:p1\tclaude\tidle')"
st_set "$D" PQ_WRAPUP_SINCE "not-a-date"
slot_held "$D" && ok || bad "an unparseable stamp must hold the slot, not release on a bad read"
eq "$(epoch_of "$(st "$D" PQ_WRAPUP_SINCE)" > /dev/null; echo $?)" "0" "the corrupt stamp is rewritten"
[ "$(st "$D" PQ_WRAPUP_SINCE)" != "not-a-date" ] && ok || bad "a corrupt stamp must be rewritten, not left to fail forever"

echo "== PQ_WRAPUP_GRACE=0 restores the old release-on-PR behaviour ==" >&2
set_panes "$(printf 'w1:p1\tclaude\tidle')"
st_set "$D" PQ_WRAPUP_SINCE "$(now)"
( PQ_WRAPUP_GRACE=0; slot_held "$D" ) \
  && bad "at grace 0 an idle agent must release its slot immediately" || ok

echo "== slot_state: the same verdict, with nothing written ==" >&2
set_panes "$(printf 'w1:p1\tclaude\tidle')"
st_set "$D" PQ_WRAPUP_SINCE ""
eq "$(slot_state "$D")" "wrapping up" "an idle agent with no clock yet still reads as wrapping up"
# The trap this guards: a listing that stamped the clock would restart the
# grace period every time you ran `pq ls`, so an agent could hold its slot for
# as long as you kept looking at it.
eq "$(st "$D" PQ_WRAPUP_SINCE)" "" "slot_state must not start the clock"
st_set "$D" PQ_WRAPUP_SINCE "$(ago 301)"
eq "$(slot_state "$D")" "" "past the grace, slot_state reports no slot held"
set_panes "$(printf 'w1:p1\tclaude\tworking')"
eq "$(slot_state "$D")" "wrapping up" "a working agent reads as wrapping up"
st_set "$D" PQ_WRAPUP_SINCE "$(ago 301)"
eq "$(st "$D" PQ_WRAPUP_SINCE)" "$(st "$D" PQ_WRAPUP_SINCE)" "slot_state left the stamp alone"
set_panes "$(printf 'w1:p1\t\t')"
eq "$(slot_state "$D")" "" "noagent reads as no slot held"
eq "$(slot_state "$R")" "" "a reaped task reads as no slot held"
eq "$(slot_state "$C")" "" "a closed task reads as no slot held"

echo "== active_slots: running/ counts unconditionally, done/ only while live ==" >&2
reset_tasks
mk_task 'running' 010 one   tom/one   w1:p1 >/dev/null
mk_task 'running' 011 two   tom/two   w2:p1 >/dev/null
W=$(mk_task 'done' 012 three tom/three w3:p1)
set_panes "$(printf 'w1:p1\tclaude\tworking\nw2:p1\t\t\nw3:p1\tclaude\tworking')"
eq "$(active_slots)" "$(printf '2\t1')" "two running (one with no agent - still counts) plus one live done task"

# The whole point: a running/ task whose agent has exited still holds its slot.
# It has no PR, so nothing will move it on, and dropping it from the count
# would leak a worktree while letting a fresh agent start beside it.
set_panes "$(printf 'w1:p1\t\t\nw2:p1\t\t\nw3:p1\t\t')"
eq "$(active_slots)" "$(printf '2\t0')" "running/ counts even with every agent gone; done/ does not"

# And a done task past its grace stops counting while running/ is untouched.
set_panes "$(printf 'w1:p1\tclaude\tworking\nw2:p1\tclaude\tworking\nw3:p1\tclaude\tidle')"
st_set "$W" PQ_WRAPUP_SINCE "$(ago 301)"
eq "$(active_slots)" "$(printf '2\t0')" "a done task past the grace releases its slot"

echo "== tick_body: the reported bug - 3 running + 3 wrapping up at cap 3 ==" >&2
reset_tasks; reset_caches
# Exactly the live state that prompted this: three fresh tasks in running/ and
# three in done/ whose PRs exist but whose agents are still working. Six live
# agents at a cap of 3, and the old arithmetic saw three.
WRAPS=()
for i in 1 2 3; do
  d=$(mk_task 'running' "02$i" "run$i" "tom/run$i" "wr$i:p1")
  st_set "$d" PQ_LAUNCHED "$(now)"
done
for i in 1 2 3; do
  d=$(mk_task 'done' "03$i" "wrap$i" "tom/wrap$i" "ww$i:p1")
  WRAPS+=("$d")
  st_set "$d" PQ_PR "$((100 + i))"; st_set "$d" PQ_FINISHED "$(now)"
  cache_row "$REPO" "tom/wrap$i" "$((100 + i))" OPEN "" master
done
mk_task 'queue' 040 next tom/next "" >/dev/null
set_panes "$(printf 'wr1:p1\tclaude\tworking\nwr2:p1\tclaude\tworking\nwr3:p1\tclaude\tworking\nww1:p1\tclaude\tworking\nww2:p1\tclaude\tworking\nww3:p1\tclaude\tworking')"

tick 3 1
eq "$(active_slots)" "$(printf '3\t3')" "six live agents are six slots, not three"
case "$OUT" in
  *"would dispatch next"*) bad "at cap 3 with six live agents, nothing may start" ;;
  *) ok ;;
esac
case "$OUT" in
  *"would skip next - cap reached"*) ok ;;
  *) bad "the queued task should be skipped for the cap, with that reason (got: $OUT)" ;;
esac
# The summary is the other half of the fix: "3 running (cap 3)" is what made
# six agents look healthy for as long as this lasted.
case "$PQ_SUMMARY" in
  *"3 running + 3 wrapping up (cap 3)"*) ok ;;
  *) bad "the summary must name both halves (got: $PQ_SUMMARY)" ;;
esac

echo "== tick_body: once the wrap-ups go idle past the grace, fill proceeds ==" >&2
for d in "${WRAPS[@]}"; do st_set "$d" PQ_WRAPUP_SINCE "$(ago 301)"; done
set_panes "$(printf 'wr1:p1\tclaude\tworking\nwr2:p1\tclaude\tworking\nwr3:p1\tclaude\tworking\nww1:p1\tclaude\tidle\nww2:p1\tclaude\tidle\nww3:p1\tclaude\tidle')"
eq "$(active_slots)" "$(printf '3\t0')" "three settled done tasks hold nothing"
tick 4 1
case "$OUT" in
  *"would dispatch next"*) ok ;;
  *) bad "with the wrap-ups settled and a free slot, the queue must advance (got: $OUT)" ;;
esac

echo "== tick_body: a wrapping-up task still blocks at a cap it fills alone ==" >&2
# The narrow case the directory count could never express: nothing at all in
# running/, one agent still going in done/, cap 1. The old arithmetic read zero
# and would happily start a second agent beside it.
reset_tasks; reset_caches
d=$(mk_task 'done' 050 solo tom/solo ws:p1)
st_set "$d" PQ_PR 200; st_set "$d" PQ_FINISHED "$(now)"
cache_row "$REPO" tom/solo 200 OPEN draft master
mk_task 'queue' 051 next2 tom/next2 "" >/dev/null
set_panes "$(printf 'ws:p1\tclaude\tworking')"
eq "$(active_slots)" "$(printf '0\t1')" "an empty running/ plus one live wrap-up is one slot"
tick 1 1
case "$OUT" in
  *"would dispatch next2"*) bad "cap 1 is already spent by the agent still wrapping up" ;;
  *) ok ;;
esac
case "$PQ_SUMMARY" in
  *"0 running + 1 wrapping up (cap 1)"*) ok ;;
  *) bad "the summary must account for the slot (got: $PQ_SUMMARY)" ;;
esac

echo "== tick_body --dry-run counts the slot without starting anybody's clock ==" >&2
# --dry-run promises to change nothing, and the wrap-up clock is state like any
# other. The count still has to come out the same, or a dry run would report a
# tick different from the one it is previewing.
reset_tasks; reset_caches
dd=$(mk_task 'done' 060 dryrun tom/dryrun wd:p1)
st_set "$dd" PQ_PR 300; st_set "$dd" PQ_FINISHED "$(now)"
cache_row "$REPO" tom/dryrun 300 OPEN "" master
mk_task 'queue' 061 next3 tom/next3 "" >/dev/null
set_panes "$(printf 'wd:p1\tclaude\tidle')"
tick 1 1
eq "$(st "$dd" PQ_WRAPUP_SINCE)" "" "--dry-run must not stamp the wrap-up clock"
case "$PQ_SUMMARY" in
  *"0 running + 1 wrapping up (cap 1)"*) ok ;;
  *) bad "--dry-run must still count the slot (got: $PQ_SUMMARY)" ;;
esac
case "$OUT" in
  *"would dispatch next3"*) bad "--dry-run must not claim a slot the wrap-up is holding" ;;
  *) ok ;;
esac
# A real tick over the identical state agrees on the count, and does start it.
tick 1 0
[ -n "$(st "$dd" PQ_WRAPUP_SINCE)" ] && ok || bad "a real tick must start the clock the dry run left alone"
case "$PQ_SUMMARY" in
  *"0 running + 1 wrapping up (cap 1)"*) ok ;;
  *) bad "a real tick must reach the same count as the dry run (got: $PQ_SUMMARY)" ;;
esac

echo "== agent_cell: a done row says which slot it is holding ==" >&2
reset_tasks; reset_caches
d=$(mk_task 'done' 070 cell tom/cell wc:p1)
st_set "$d" PQ_PR 400; st_set "$d" PQ_FINISHED "$(now)"
set_panes "$(printf 'wc:p1\tclaude\tworking')"
eq "$(agent_cell "$d" 'done')" "wrapping up" "a live done task reads as wrapping up"
st_set "$d" PQ_WRAPUP_SINCE "$(ago 301)"
set_panes "$(printf 'wc:p1\tclaude\tidle')"
eq "$(agent_cell "$d" 'done')" "-" "a settled done task goes back to reading as nothing"
# The two reap holds that want a decision from you outrank the slot report;
# `held agent` does not, because `wrapping up` says the same thing and says
# what it costs.
# A blocked agent holds its slot with no deadline, and nothing knocks on a done/
# pane - so it must not hide behind `wrapping up`, which reads as "nothing wants
# you". `blocked` is already one of the words cmd_ls counts into "needs you".
st_set "$d" PQ_WRAPUP_SINCE ""
set_panes "$(printf 'wc:p1\tclaude\tblocked')"
eq "$(agent_cell "$d" 'done')" "blocked" "a blocked done agent says so, rather than reading as wrapping up"
eq "$(slot_state "$d")" "wrapping up" "...while still being counted as holding its slot"

set_panes "$(printf 'wc:p1\tclaude\tworking')"
st_set "$d" PQ_REAP_HELD here
eq "$(agent_cell "$d" 'done')" "held here" "held here outranks the slot report"
st_set "$d" PQ_REAP_HELD nobase
eq "$(agent_cell "$d" 'done')" "held nobase" "held nobase outranks the slot report"
st_set "$d" PQ_REAP_HELD agent
eq "$(agent_cell "$d" 'done')" "wrapping up" "held agent is reported as wrapping up instead"
st_set "$d" PQ_REAP_HELD ""
st_set "$d" PQ_CLOSED "$(now)"
eq "$(agent_cell "$d" 'done')" "closed" "a closed task still reads as closed"

echo "== epoch_of: pq's own stamps, and everything that is not one ==" >&2
eq "$(epoch_of 1970-01-01T00:00:01Z)" "1" "a real stamp parses to epoch seconds"
eq "$(epoch_of "")" "" "an empty stamp yields nothing"
eq "$(epoch_of nonsense)" "" "an unparseable stamp yields nothing, not 0"
eq "$(age_of "$(ago 120)")" "2m" "age_of still works over the shared parse"
eq "$(age_of nonsense)" "-" "age_of still degrades to a dash"

printf '\n%s passed, %s failed\n' "$pass" "$fail" >&2
[ "$fail" = 0 ]
