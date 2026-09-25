#!/usr/bin/env bash
# test/pq-watch.sh - a pull request marked ready is still watched: CI failing,
# a conflict with its base, and a person's review feedback each get its agent
# prompted, once, and anything its agent cannot deal with is handed to you.
#
# Same shape as test/pq-review.sh: `set_panes` steers herdr's snapshot, a
# recording `herdr` answers `agent prompt`, and `gh` serves the pull request
# view and the three comment endpoints from files.
#
# SC2034: the caches and pane index set here are read by the pq sourced below.
# SC2015: `ok` never fails, so `[ ... ] && ok || bad` is an if/else.
# shellcheck disable=SC2034,SC2015
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PQ_HOME=$(mktemp -d)
export PQ_HOME

STUBBIN=$(mktemp -d)
PANES_JSON="$STUBBIN/.panes.json"
HERDR_LOG="$STUBBIN/.herdr-calls"
GH_LOG="$STUBBIN/.gh-calls"
VIEW="$STUBBIN/.view.json"
INLINE="$STUBBIN/.inline.json"; ISSUE="$STUBBIN/.issue.json"; REVIEWS="$STUBBIN/.reviews.json"
printf '{"result":{"snapshot":{"panes":[]}}}' > "$PANES_JSON"
: > "$HERDR_LOG"; : > "$GH_LOG"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/claude"
cat > "$STUBBIN/gh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$GH_LOG"
[ -f "$STUBBIN/.gh-down" ] && exit 1
case "\$*" in
  *"pr view"*)          cat "$VIEW" ;;
  *"/pulls/"*"/comments"*) cat "$INLINE" ;;
  *"/issues/"*"/comments"*) cat "$ISSUE" ;;
  *"/reviews"*)         cat "$REVIEWS" ;;
  *) exit 1 ;;
esac
EOF
cat > "$STUBBIN/herdr" <<EOF
#!/bin/sh
{ for a in "\$@"; do printf '%s\t' "\$a"; done; printf '\n'; } >> "$HERDR_LOG"
case "\$1 \$2" in
  "api snapshot") cat "$PANES_JSON"; exit 0 ;;
  "agent prompt")
    if [ -f "$STUBBIN/.prompt-fail" ]; then
      printf '{"error":{"code":"%s","message":"stub"},"id":"cli:agent:prompt"}\n' "\$(cat "$STUBBIN/.prompt-fail")"; exit 0
    fi
    printf '{"id":"cli:agent:prompt","result":{"submitted":true}}\n'; exit 0 ;;
esac
exit 1
EOF
printf '#!/bin/sh\nexit 0\n' > "$STUBBIN/wt-stub"
chmod +x "$STUBBIN/claude" "$STUBBIN/gh" "$STUBBIN/herdr" "$STUBBIN/wt-stub"
export PATH="$STUBBIN:$PATH"
export PQ_WT="$STUBBIN/wt-stub"

# shellcheck source=/dev/null
source "$HERE/../.local/bin/pq"

pr_load_all() { :; }

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { if [ "$1" = "$2" ]; then ok; else bad "$3 (got '$1', want '$2')"; fi; }
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

unset HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID

reset_caches() { PR_CACHE="$PQ_HOME/.test.pr"; PR_ANS="$PQ_HOME/.test.ans"; : > "$PR_CACHE"; : > "$PR_ANS"; }
cache_row() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$PR_CACHE"; }   # repo branch num state draft base
reset_logs() { : > "$HERDR_LOG"; : > "$GH_LOG"; rm -f "$STUBBIN/.prompt-fail" "$STUBBIN/.gh-down"; }
set_panes() {                           # "pane<TAB>agent<TAB>status" lines
  PIDX=$1; PIDX_OK=1
  jq -Rs 'split("\n") | map(select(length > 0) | split("\t")
            | { pane_id: .[0],
                agent:        (if (.[1] // "") == "" then null else .[1] end),
                agent_status: (if (.[2] // "") == "" then null else .[2] end) })
          | { result: { snapshot: { panes: . } } }' <<<"$1" > "$PANES_JSON"
}
prompts() { grep -c "^agent	prompt	" "$HERDR_LOG" 2>/dev/null || true; }
prompt_text() { grep "^agent	prompt	" "$HERDR_LOG" | tail -1 | cut -f4; }

# The pull request as `gh pr view` would give it. Checks are "name:conclusion"
# or "name:" for one still running, each with its own run and job.
view() {                                # head base_oid mergeable merge_state check...
  local head=$1 boid=$2 mergeable=$3 mstate=$4 c name concl checks="[]" i=0; shift 4
  for c in "$@"; do
    i=$((i + 1)); name=${c%%:*}; concl=${c#*:}
    checks=$(jq -c --arg n "$name" --arg c "$concl" --arg u "https://github.com/o/r/actions/runs/$((900 + i))/job/$((700 + i))$JOBSALT" \
      '. + [ if $c == "" then {__typename:"CheckRun", name:$n, status:"IN_PROGRESS", conclusion:"", detailsUrl:$u}
             else {__typename:"CheckRun", name:$n, status:"COMPLETED", conclusion:$c, detailsUrl:$u} end ]' <<<"$checks")
  done
  jq -n --arg h "$head" --arg b "$boid" --arg m "$mergeable" --arg s "$mstate" --argjson c "$checks" \
    '{headRefOid:$h, baseRefName:"master", baseRefOid:$b, mergeable:$m, mergeStateStatus:$s,
      author:{login:"tom", is_bot:false}, statusCheckRollup:$c}' > "$VIEW"
}
JOBSALT=""
no_feedback() { echo '[]' > "$INLINE"; echo '[]' > "$ISSUE"; echo '[]' > "$REVIEWS"; }
no_feedback

mk_ready() {                            # prio slug pane -> task_dir, its gate over and its PR #42 open and ready
  local d
  d="$PQ_HOME/done/$(printf '%014d' $(( 20260101000000 + 10#$1 )))-$2"
  mkdir -p "$d"
  printf -- '---\nrepo:     %s\nbranch:   tom/%s\nmodel:    sonnet\neffort:   xhigh\nintent:   t\nadded:    2026-01-01T00:00:00Z\n---\n\nplan\n' \
    "$REPO" "$2" > "$d/plan.md"
  st_set "$d" PQ_PANE "$3"; st_set "$d" PQ_PR 42; st_set "$d" PQ_REVIEW ready
  cache_row "$REPO" "tom/$2" 42 OPEN "" master
  printf '%s' "$d"
}

echo "== CI failing on a ready pull request: its idle agent is told, with the runs ==" >&2
reset_caches; reset_logs
D=$(mk_ready 10 cifail w1:p1)
st_set "$D" PQ_WRAPUP_SINCE 2026-01-01T00:00:00Z
set_panes "$(printf 'w1:p1\tclaude\tidle')"
view sha1 base1 MERGEABLE UNSTABLE "build:FAILURE" "lint:SUCCESS" "Deploy Preview:SKIPPED"
out=$(watch_task "$D" 0 2>&1)
eq "$(prompts)" "1" "one prompt"
P=$(prompt_text)
has "$P" "CI failed on pull request #42: build (run 901)" "naming the failed check and its run"
has "$P" "gh run view <run> --log-failed" "how to read why"
has "$P" "gh run rerun <run> --failed" "and how to rerun a flake, rather than fix what is not broken"
hasnt "$P" "lint" "a passing check is not mentioned"
hasnt "$P" "'" "quote-free"
eq "$(st "$D" PQ_WATCH_ASKED)" "ci" "the ask is recorded"
eq "$(st "$D" PQ_WATCH_FIXES)" "1" "and counted"
eq "$(st "$D" PQ_WRAPUP_SINCE)" "" "the wrap-up clock is cleared, as the review follow-up clears it"
has "$out" "CI is failing on it - asked its agent to deal with it" "said in the log"
eq "$(agent_cell "$D" "done")" "fixing ci" "pq ls says the agent is on it"

echo "== ...and not told again while it works on it ==" >&2
reset_logs
set_panes "$(printf 'w1:p1\tclaude\tworking')"
watch_task "$D" 0 >/dev/null 2>&1
eq "$(prompts)" "0" "no second prompt while the agent is working"
eq "$(agent_cell "$D" "done")" "fixing ci" "and pq ls says what it is working on"

echo "== the same failure, the agent idle again with no new commit: handed to you ==" >&2
set_panes "$(printf 'w1:p1\tclaude\tidle')"
out=$(watch_task "$D" 0 2>&1)
eq "$(prompts)" "0" "the same failure is never asked about twice"
eq "$(st "$D" PQ_WATCH_NEEDS)" "ci" "it is yours now"
has "$out" "its agent looked and left it as it was - look at it" "said once"
eq "$(agent_cell "$D" "done")" "ci failed" "pq ls says so"
LS=$(PQ_WIDTH=200 main ls 2>&1)
has "$LS" "(1 needs you)" "and counts it as needing you"
reset_caches; cache_row "$REPO" tom/cifail 42 OPEN "" master   # pq ls removes the cache it read
out=$(watch_task "$D" 0 2>&1)
eq "$out" "" "once"

echo "== a push that fails again is a new failure, and a new prompt ==" >&2
view sha2 base1 MERGEABLE UNSTABLE "build:FAILURE"
watch_task "$D" 0 >/dev/null 2>&1
eq "$(prompts)" "1" "a new head is a new failure"
eq "$(st "$D" PQ_WATCH_FIXES)" "2" "the second go"
eq "$(st "$D" PQ_WATCH_NEEDS)" "" "and it is the agent's again"

echo "== ...so is a rerun of the same job that fails again ==" >&2
reset_logs
JOBSALT=0; view sha2 base1 MERGEABLE UNSTABLE "build:FAILURE"; JOBSALT=""
watch_task "$D" 0 >/dev/null 2>&1
eq "$(prompts)" "1" "the rerun's job failed too - a new prompt"
eq "$(st "$D" PQ_WATCH_FIXES)" "3" "the third go"

echo "== WATCH_FIXES goes and it is handed to you ==" >&2
reset_logs
view sha3 base1 MERGEABLE UNSTABLE "build:FAILURE"
out=$(watch_task "$D" 0 2>&1)
eq "$(prompts)" "0" "no fourth prompt"
has "$out" "its agent has had 3 goes at fixing it" "said why"
eq "$(agent_cell "$D" "done")" "ci failed" "and it is yours"

echo "== CI still running, or passing: nothing to say ==" >&2
reset_caches; reset_logs
R=$(mk_ready 11 cirun w2:p1)
set_panes "$(printf 'w2:p1\tclaude\tidle')"
view sha1 base1 MERGEABLE UNSTABLE "build:FAILURE" "rspec:"
watch_task "$R" 0 >/dev/null 2>&1
eq "$(prompts)" "0" "one check still running holds the prompt until they have all finished"
view sha1 base1 MERGEABLE CLEAN "build:SUCCESS" "rspec:SUCCESS" "Deploy Preview:SKIPPED"
watch_task "$R" 0 >/dev/null 2>&1
eq "$(prompts)" "0" "a green pull request wants nothing"
eq "$(agent_cell "$R" "done")" "wrapping up" "and reads as it always did"

echo "== a conflict outranks CI, and asks for a merge, not a rebase ==" >&2
reset_caches; reset_logs
C=$(mk_ready 12 conflicted w3:p1)
set_panes "$(printf 'w3:p1\tclaude\tidle')"
view sha1 base1 CONFLICTING DIRTY "build:FAILURE"
watch_task "$C" 0 >/dev/null 2>&1
P=$(prompt_text)
has "$P" "Pull request #42 has merge conflicts with master" "the conflict is what it is told about"
has "$P" "git merge origin/master" "merging the base in"
has "$P" "do not rebase and do not force-push" "not rewriting a ready pull request"
hasnt "$P" "CI failed" "one thing at a time"
eq "$(agent_cell "$C" "done")" "fixing conflict" "pq ls"
reset_logs
set_panes "$(printf 'w3:p1\tclaude\tworking')"
view sha1 base2 CONFLICTING DIRTY "build:FAILURE"
watch_task "$C" 0 >/dev/null 2>&1
eq "$(prompts)" "0" "the agent still has the first ask while it works"
set_panes "$(printf 'w3:p1\tclaude\tidle')"
view sha1 base1 CONFLICTING DIRTY "build:FAILURE"
out=$(watch_task "$C" 0 2>&1)
eq "$(prompts)" "0" "idle again with the same conflict: no second prompt"
eq "$(agent_cell "$C" "done")" "conflict" "it is yours"

echo "== a person's review feedback after ready, and only that ==" >&2
reset_caches; reset_logs
F=$(mk_ready 13 feedback w4:p1)
set_panes "$(printf 'w4:p1\tclaude\tidle')"
view sha1 base1 MERGEABLE CLEAN "build:SUCCESS"
watch_task "$F" 0 >/dev/null 2>&1
eq "$(prompts)" "0" "nothing yet"
S=$(st "$F" PQ_WATCH_SINCE)
[ -n "$S" ] && ok || bad "the watch records when it began"
after=$(date -u -r $(( $(epoch_of "$S") + 60 )) '+%Y-%m-%dT%H:%M:%SZ')
later=$(date -u -r $(( $(epoch_of "$S") + 120 )) '+%Y-%m-%dT%H:%M:%SZ')
before=2025-01-01T00:00:00Z
jq -n --arg a "$after" --arg l "$later" --arg b "$before" '[
  {id:1, user:{login:"tom", type:"User"}, in_reply_to_id:null, created_at:$b},
  {id:2, user:{login:"tom", type:"User"}, in_reply_to_id:1,    created_at:$a},
  {id:3, user:{login:"copilot[bot]", type:"Bot"}, in_reply_to_id:null, created_at:$a},
  {id:4, user:{login:"alice", type:"User"}, in_reply_to_id:1, created_at:$l}]' > "$INLINE"
jq -n --arg a "$after" '[
  {id:5, user:{login:"github-actions[bot]", type:"Bot"}, created_at:$a},
  {id:6, user:{login:"tom", type:"User"}, created_at:$a}]' > "$ISSUE"
jq -n --arg a "$after" '[
  {id:7, user:{login:"tom", type:"User"}, state:"COMMENTED", body:"", submitted_at:$a},
  {id:8, user:{login:"bob", type:"User"}, state:"CHANGES_REQUESTED", body:"", submitted_at:$a}]' > "$REVIEWS"
watch_task "$F" 0 >/dev/null 2>&1
eq "$(prompts)" "1" "alice's reply and bob's requested changes are feedback"
P=$(prompt_text)
has "$P" "new review feedback on pull request #42 since it was marked ready, from alice, bob" \
  "named by who left it - not the author's own replies, a bot, or the author's conversation comments"
has "$P" "Leave none unanswered" "and every point answered"
eq "$(st "$F" PQ_WATCH_SINCE)" "$later" "the watermark moves past what was handed over"
eq "$(agent_cell "$F" "done")" "answering review" "pq ls"
reset_logs
watch_task "$F" 0 >/dev/null 2>&1
eq "$(prompts)" "0" "the same feedback is not handed over twice"
set_panes "$(printf 'w4:p1\tclaude\tidle')"
watch_task "$F" 0 >/dev/null 2>&1
eq "$(agent_cell "$F" "done")" "wrapping up" "its turn over, the ask is answered"
last=$(date -u -r $(( $(epoch_of "$S") + 180 )) '+%Y-%m-%dT%H:%M:%SZ')
jq -n --arg l "$last" '[{id:9, user:{login:"tom", type:"User"}, in_reply_to_id:null, created_at:$l}]' > "$INLINE"
echo '[]' > "$ISSUE"; echo '[]' > "$REVIEWS"
watch_task "$F" 0 >/dev/null 2>&1
eq "$(prompts)" "1" "a new inline thread counts even from the author - that is you, reviewing"
no_feedback

echo "== an agent that is gone: handed to you, once ==" >&2
reset_caches; reset_logs
G=$(mk_ready 14 gone w5:p1)
set_panes "$(printf 'w5:p1\t\t')"
view sha1 base1 MERGEABLE UNSTABLE "build:FAILURE"
out=$(watch_task "$G" 0 2>&1)
eq "$(prompts)" "0" "nothing is prompted into an empty pane"
has "$out" "CI is failing on it and its agent is gone" "said"
eq "$(agent_cell "$G" "done")" "ci failed" "and it is yours"
eq "$(watch_task "$G" 0 2>&1)" "" "once"

echo "== the agent busy, blocked, walled or on a dialog: it waits ==" >&2
reset_caches; reset_logs
B=$(mk_ready 15 busy w6:p1)
view sha1 base1 MERGEABLE UNSTABLE "build:FAILURE"
for s in working blocked; do
  set_panes "$(printf 'w6:p1\tclaude\t%s' "$s")"
  watch_task "$B" 0 >/dev/null 2>&1
done
set_panes "$(printf 'w6:p1\tclaude\tidle')"
st_set "$B" PQ_BLOCKED quota
watch_task "$B" 0 >/dev/null 2>&1
st_set "$B" PQ_BLOCKED ""
eq "$(prompts)" "0" "not while it is working, blocked or behind the wall"
printf 'agent_blocked' > "$STUBBIN/.prompt-fail"
out=$(watch_task "$B" 0 2>&1)
has "$out" "waits for you to answer it" "a dialog is said once"
eq "$(st "$B" PQ_WATCH_ASKED)" "" "and nothing is recorded as asked"
rm -f "$STUBBIN/.prompt-fail"
watch_task "$B" 0 >/dev/null 2>&1
eq "$(st "$B" PQ_WATCH_ASKED)" "ci" "it goes on the first tick the dialog is gone"

echo "== not watched: a draft, a settled pull request, a gate not over, gh silent ==" >&2
reset_caches; reset_logs
N=$(mk_ready 16 notyet w7:p1)
set_panes "$(printf 'w7:p1\tclaude\tidle')"
view sha1 base1 MERGEABLE UNSTABLE "build:FAILURE"
reset_caches; cache_row "$REPO" tom/notyet 42 OPEN draft master
watch_task "$N" 0 >/dev/null 2>&1
reset_caches; cache_row "$REPO" tom/notyet 42 MERGED "" master
watch_task "$N" 0 >/dev/null 2>&1
reset_caches; cache_row "$REPO" tom/notyet 42 OPEN "" master
st_set "$N" PQ_REVIEW prompted
watch_task "$N" 0 >/dev/null 2>&1
eq "$(prompts)" "0" "none of those is watched"
eq "$(grep -c 'pr view' "$GH_LOG")" "0" "and none of them costs a gh call"
st_set "$N" PQ_REVIEW ready
touch "$STUBBIN/.gh-down"
watch_task "$N" 0 >/dev/null 2>&1
eq "$(prompts)" "0" "gh silent is nothing to judge"
rm -f "$STUBBIN/.gh-down"

echo "== --dry-run says what it would do and changes nothing ==" >&2
reset_caches; reset_logs
Y=$(mk_ready 17 dry w8:p1)
set_panes "$(printf 'w8:p1\tclaude\tidle')"
view sha1 base1 MERGEABLE UNSTABLE "build:FAILURE"
before=$(cat "$Y/state.env")
out=$(watch_task "$Y" 1 2>&1)
has "$out" "would prompt dry about #42 - CI is failing on it" "the would-line"
eq "$(cat "$Y/state.env")" "$before" "state untouched"
eq "$(prompts)" "0" "nothing prompted"

echo "== through tick_body ==" >&2
reset_caches; reset_logs
rm -rf "$PQ_HOME/done"; mkdir -p "$PQ_HOME/done"
T=$(mk_ready 18 ticked w9:p1)
set_panes "$(printf 'w9:p1\tclaude\tidle')"
view sha1 base1 MERGEABLE UNSTABLE "build:FAILURE"
tick_body 3 0 >/dev/null 2>&1
eq "$(st "$T" PQ_WATCH_ASKED)" "ci" "a tick prompts the agent"
grep -q -- "--wait" "$HERDR_LOG" && bad "no herdr call may carry --wait inside a tick" || ok

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
