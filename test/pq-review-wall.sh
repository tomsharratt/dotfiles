#!/usr/bin/env bash
# test/pq-review-wall.sh - a reviewer that hits the usage limit. In `-p` the wall
# is not an error: the session exits 0 with the wall's one line as its whole
# reply, and the gate used to read that as a review that had posted. Now the
# reviewer - code or security - waits out the reset, spends none of its tries on
# it, resumes its own session, and freezes the queue while it waits.
#
# The fixture is the real output of the first walled review (#6831), byte for
# byte but for its reset time, which is moved to a time relative to now so the
# test reads the same at any hour. The harness is test/pq-security.sh's: a
# pinned `epoch`, a `claude` stub that records its argv and behaves per a mode
# file for each reviewer, and `hold` to choose which finishes first.
#
# SC2034: the knobs and caches set here are read by the pq sourced below.
# SC2015: `ok` never fails, so `[ ... ] && ok || bad` is an if/else.
# shellcheck disable=SC2034,SC2015
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PQ_HOME=$(mktemp -d)
export PQ_HOME

STUBBIN=$(mktemp -d)
PANES_JSON="$STUBBIN/.panes.json"
HERDR_LOG="$STUBBIN/.herdr-calls"
CLAUDE_LOG="$STUBBIN/.claude-calls"
GH_LOG="$STUBBIN/.gh-calls"
MODE="$STUBBIN/.mode"                   # the code reviewer's behaviour
SMODE="$STUBBIN/.smode"                 # the security reviewer's
PRJSON="$STUBBIN/.pr.json"
COMMENTS="$STUBBIN/.comments"
WALL="$STUBBIN/.wall.json"
WALL_LINE="$STUBBIN/.wall-line"
printf '{"result":{"snapshot":{"panes":[]}}}' > "$PANES_JSON"
: > "$HERDR_LOG"; : > "$CLAUDE_LOG"; : > "$GH_LOG"
printf 'ok' > "$MODE"; printf 'ok' > "$SMODE"; printf '0' > "$COMMENTS"
# The real walled reply, from ~/.local/state/pq/done/*-public-livestreams-anonymous-chat/review.json.
cat > "$STUBBIN/.wall-captured.json" <<'FIXEOF'
{"is_error":false,"duration_api_ms":0,"num_turns":0,"stop_reason":null,"session_id":"b1747627-d4f1-4d8c-958f-feb69fe51607","total_cost_usd":5.5221492,"usage":{"output_tokens_details":{"thinking_tokens":0},"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0,"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},"inference_geo":"","iterations":[],"speed":"standard"},"modelUsage":{"claude-opus-5-5":{"inputTokens":160,"outputTokens":82841,"cacheReadInputTokens":12929521,"cacheCreationInputTokens":255757,"webSearchRequests":0,"costUSD":5.5221492,"contextWindow":1000000,"maxOutputTokens":128000,"thinkingTokens":66783,"canonicalModel":"claude-opus-5-5","provider":"firstParty","costBasis":"list"}},"permission_denials":[],"fast_mode_state":"off","fast_mode_disabled_reason":"sdk_opt_in_required","subagent_stats":{"spawned":0,"requested":{"background":0,"foreground":0,"unset":0},"started_in_background":0,"max_depth":0,"spawned_by_subagents":0,"completed":0,"failed":0,"killed":{"parent":0,"user":0,"system":0},"refused":{"depth_limit":0,"concurrency_limit":0,"budget":0},"by_type":{}},"subtype":"success","result":"You've hit your session limit · resets 7pm (America/Toronto)","local_command":"code_review","type":"result","duration_ms":913570,"uuid":"7e2b7a73-e71c-427a-b3f7-4d3884b15c10","queued_turn_count":0,"result_index":0}
FIXEOF

cat > "$STUBBIN/claude" <<EOF
#!/bin/sh
{ printf '%s\t' "\$PWD"; for a in "\$@"; do printf '%s\t' "\$a"; done; printf '\n'; } >> "$CLAUDE_LOG"
prev="" last="" sid=""
for a in "\$@"; do [ "\$prev" = --resume ] && sid=\$a; prev=\$a; last=\$a; done
case "\$last" in
  /security-review|*"this security review"*) kind=security; m=\$(cat "$SMODE") ;;
  /code-review*|*"this review"*)            kind=code;     m=\$(cat "$MODE") ;;
  *) exit 1 ;;
esac
if [ -n "\$sid" ] && [ -f "$STUBBIN/.sessions-gone" ]; then
  printf 'No conversation found with session ID: %s\n' "\$sid" >&2; exit 1
fi
if [ "\$m" = hold ]; then
  i=0
  while [ ! -f "$STUBBIN/.release-\$kind" ] && [ \$i -lt 300 ]; do sleep 0.1; i=\$((i + 1)); done
  m=ok
fi
case "\$m" in
  walled)    cat "$WALL"; exit 0 ;;
  wallerr)   printf 'not json\n'; printf 'Error: request failed\n%s\n' "\$(cat "$WALL_LINE")" >&2; exit 1 ;;
  fail)      printf '{"is_error":true}\n'; exit 1 ;;
  sleep)     sleep 30; exit 0 ;;
  ratelimit) jq -nc '{is_error:false,session_id:"s-2",result:"Two findings.\nThe new middleware returns 429 once clients hit your API limit, but never sets Retry-After."}'; exit 0 ;;
esac
if [ "\$kind" = code ]; then
  printf '{"is_error":false,"total_cost_usd":1.2,"duration_ms":5000,"session_id":"s-code","permission_denials":[]}\n'; exit 0
fi
jq -nc '{is_error:false,total_cost_usd:0.9,duration_ms:90000,session_id:"s-sec",permission_denials:[],result:"# Security review\n\nNo vulnerabilities found."}'
EOF
cat > "$STUBBIN/gh" <<EOF
#!/bin/sh
case "\$*" in
  *"pr comment"*) printf '%s\n' "\$*" >> "$GH_LOG"; exit 0 ;;
  *"pr view"*)    [ -f "$PRJSON" ] && cat "$PRJSON" && exit 0; exit 1 ;;
  *"/comments"*)  cat "$COMMENTS"; exit 0 ;;
esac
exit 1
EOF
cat > "$STUBBIN/herdr" <<EOF
#!/bin/sh
{ for a in "\$@"; do printf '%s\t' "\$a"; done; printf '\n'; } >> "$HERDR_LOG"
case "\$1 \$2" in
  "api snapshot") cat "$PANES_JSON"; exit 0 ;;
  "agent prompt") printf '{"id":"cli:agent:prompt","result":{"submitted":true}}\n'; exit 0 ;;
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
eq() { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }
has() { case "$1" in *"$2"*) ok ;; *) bad "$3 (got '$1')" ;; esac; }
hasnt() { case "$1" in *"$2"*) bad "$3 (got '$1')" ;; *) ok ;; esac; }
near() { [ -n "$1" ] && [ "$1" -ge $(( $2 - 90 )) ] && [ "$1" -le $(( $2 + 90 )) ] && ok || bad "$3 (got '$1', want ~$2)"; }

cleanup() {
  local d
  touch "$STUBBIN/.release-code" "$STUBBIN/.release-security" 2>/dev/null
  for d in "$PQ_HOME"/done/*/; do [ -d "$d" ] && review_kill "${d%/}"; done
  rm -rf "$PQ_HOME" "$STUBBIN" "${REPO:-}" "${WT:-}"
}
trap cleanup EXIT

REPO=$(mktemp -d)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$REPO/.git/refs/remotes/origin"
git -C "$REPO" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
WT=$(mktemp -d)

unset HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID
PQ_DONE_KEEP=99
PQ_WRAPUP_GRACE=300
PQ_REVIEW_TIMEOUT=1500
PQ_REVIEW_MAX_TRIES=2
PQ_REVIEW_RETRY=600
PQ_QUOTA_RETRY=600
PQ_QUOTA_MAX_TRIES=40
PQ_REVIEW_EFFORT=high

# The gate's clock is pinned; parse_reset reads the real one, so every reset in
# here is built off the real clock and FAKE_NOW is walked past it by hand.
FAKE_NOW=$(date -u '+%s')
epoch() { printf '%s' "$FAKE_NOW"; }
now()   { date -u -r "$FAKE_NOW" '+%Y-%m-%dT%H:%M:%SZ'; }
real()  { date '+%s'; }

reset_caches() { PR_CACHE="$PQ_HOME/.test.pr"; PR_ANS="$PQ_HOME/.test.ans"; : > "$PR_CACHE"; : > "$PR_ANS"; }
cache_row() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$PR_CACHE"; }
reset_tasks() {
  local d
  touch "$STUBBIN/.release-code" "$STUBBIN/.release-security"
  for d in "$PQ_HOME"/done/*/; do [ -d "$d" ] && review_kill "${d%/}"; done
  rm -f "$STUBBIN/.release-code" "$STUBBIN/.release-security" "$STUBBIN/.sessions-gone"
  rm -rf "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done" "$PQ_HOME/archive"
  mkdir -p "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done" "$PQ_HOME/archive"
  : > "$HERDR_LOG"; : > "$CLAUDE_LOG"; : > "$GH_LOG"
  FAKE_NOW=$(real)
  reset_caches
}
mode()  { printf '%s' "$1" > "$MODE"; }
smode() { printf '%s' "$1" > "$SMODE"; }
release() { touch "$STUBBIN/.release-$1"; }
# The captured reply, walled until the given time - or naming none at all.
wall_at() {                             # epoch | "" -> the fixture's .result, rewritten
  local line
  if [ -n "$1" ]; then line="You've hit your session limit · resets $(clock_of "$1") (America/Toronto)"
  else line="Claude AI usage limit reached"; fi
  printf '%s' "$line" > "$WALL_LINE"
  jq -c --arg r "$line" '.result = $r' "$STUBBIN/.wall-captured.json" > "$WALL"
}
jq -nc '{title:"Do the thing", state:"OPEN", isDraft:true, commits:[{oid:"a"},{oid:"b"}], additions:40, deletions:4}' > "$PRJSON"

mk_gated() {                            # prio slug pane [security] -> task_dir
  local dir
  dir="$PQ_HOME/done/$(printf '%014d' $(( 20260101000000 + 10#$1 )))-$2"
  mkdir -p "$dir"
  {
    printf -- '---\nrepo:     %s\nbranch:   tom/%s\n' "$REPO" "$2"
    [ "${4:-}" = yes ] && printf 'security: yes\n'
    printf 'model:    sonnet\neffort:   xhigh\nintent:   test fixture\nadded:    2026-01-01T00:00:00Z\n---\n\nplan body\n'
  } > "$dir/plan.md"
  st_set "$dir" PQ_PANE "$3"; st_set "$dir" PQ_WORKTREE "$WT"
  st_set "$dir" PQ_LAUNCHED "$(now)"; st_set "$dir" PQ_PR 42; st_set "$dir" PQ_FINISHED "$(now)"
  st_set "$dir" PQ_REVIEW pending
  [ "${4:-}" = yes ] && st_set "$dir" PQ_SECURITY pending
  cache_row "$REPO" "tom/$2" 42 OPEN draft master
  task_link "$dir"
  printf '%s' "$dir"
}
set_idle() {                            # pane -> herdr reads it as an idle claude
  jq -nc --arg p "$1" '{result:{snapshot:{panes:[{pane_id:$p,agent:"claude",agent_status:"idle"}]}}}' > "$PANES_JSON"
  PIDX=$(printf '%s\tclaude\tidle' "$1"); PIDX_OK=1
}
wait_for() { local i; for i in $(seq 1 50); do "$@" && return 0; sleep 0.1; done; return 1; }
last_call() { grep "$1" "$CLAUDE_LOG" | tail -1; }
prompts()   { grep -c "^agent	prompt	" "$HERDR_LOG" 2>/dev/null || true; }
prompt_text() { grep "^agent	prompt	" "$HERDR_LOG" | tail -1 | cut -f4; }

echo "== the captured wall is a wall, not a review that posted ==" >&2
reset_tasks; mode walled
G=$(mk_gated 010 walled w1:p1); set_idle w1:p1
T=$(( $(real) + 7200 )); wall_at "$T"
review_task "$G" 0 >/dev/null 2>&1
wait_for test -f "$G/review.rc" || bad "the walled stub should have finished"
eq "$(cat "$G/review.rc")" "0" "the fixture exits 0, as the real one did"
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_REVIEW)" "pending" "the gate goes back to pending - not posted"
eq "$(st "$G" PQ_REVIEW_RESULT)" "" "with no result recorded"
eq "$(st "$G" PQ_REVIEW_TRIES)" "0" "the try it launched with is handed back"
eq "$(st "$G" PQ_REVIEW_WALLS)" "1" "and the wall counted apart"
eq "$(st "$G" PQ_REVIEW_SESSION)" "b1747627-d4f1-4d8c-958f-feb69fe51607" "its session is kept, to resume"
near "$(st "$G" PQ_REVIEW_RESETS_AT)" "$T" "the reset is read off its line"
eq "$(st "$G" PQ_REVIEW_RETRY_AT)" "$(( $(st "$G" PQ_REVIEW_RESETS_AT) + 60 ))" "and the retry is a minute past it"
has "$(cat "$PQ_HOME/.out")" "the reviewer hit the usage limit - resuming it at $(clock_of $(( $(st "$G" PQ_REVIEW_RESETS_AT) + 60 )))" "said, with when"
eq "$(prompts)" "0" "nobody is told to resolve comments that do not exist"
eq "$(review_cell "$G")" "review quota $(clock_of "$(st "$G" PQ_REVIEW_RESETS_AT)")" "the cell reads like a walled pane's"
review_inflight "$G" && ok || bad "the slot stays held"
IFS=$'\t' read -r wb wa <<<"$(walled_slot)"
eq "$wb" "walled's review" "and the queue freezes on it, as on a walled pane - named as the review, not the task's agent"
eq "$wa" "$(st "$G" PQ_REVIEW_RESETS_AT)" "until its reset"
has "$(main cap 3 2>&1)" "but walled's review is walled until $(clock_of "$wa"), so nothing new starts" "pq cap says which is walled"
rm -f "$PQ_HOME/cap"

echo "== nothing before the reset; after it, the same session is resumed ==" >&2
review_task "$G" 0 >/dev/null 2>&1
eq "$(grep -c . "$CLAUDE_LOG")" "1" "no relaunch before the retry is due"
mode ok
FAKE_NOW=$(( $(st "$G" PQ_REVIEW_RETRY_AT) + 1 ))
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_REVIEW)" "running" "relaunched once the reset has come round"
has "$(cat "$PQ_HOME/.out")" "resuming the review of #42 after the usage limit" "said"
wait_for test -f "$G/review.rc"
line=$(last_call "this review")
has "$line" "	--resume	b1747627-d4f1-4d8c-958f-feb69fe51607	" "resuming the session that walled"
has "$line" "	--allowedTools	Bash(gh:*)	" "with gh still allowed, to post"
has "$line" "	--disallowedTools	Edit(/$HOME/**)	" "and still read-only"
has "$line" "	--append-system-prompt	You are reviewing pull request #42 " "still briefed"
has "$line" "	--add-dir	$PQ_HOME/tasks/$(basename "$G")	" "with the task opened to it"
has "$line" "	The usage limit that stopped you has reset. Carry on with this review exactly where you left off, and post it on the pull request as the review asked.	" "told to carry on, not handed the skill again"
hasnt "$line" "/code-review" "which would start the review over"
case "$(review_cmd 42 /x sid)" in *"'"*) bad "the continue prompt is quote-free" ;; *) ok ;; esac 2>/dev/null
eq "$(st "$G" PQ_REVIEW_WALL)" "" "the wall is cleared on relaunch"
eq "$(walled_slot)" "" "and so is the freeze"
eq "$(review_cell "$G")" "reviewing $(age_since "$(st "$G" PQ_REVIEW_AT)")" "the cell says reviewing again"
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_REVIEW)" "posted" "the resumed review is collected"
eq "$(st "$G" PQ_REVIEW_RESULT)" "ok" "as ok"
eq "$(st "$G" PQ_REVIEW_TRIES)" "1" "having spent one try in all"
review_task "$G" 0 >/dev/null 2>&1
has "$(prompt_text)" "inline review comments" "and the follow-up is the ordinary one"

echo "== a reply that names no reset is polled ==" >&2
reset_tasks; mode walled
G=$(mk_gated 020 noreset w1:p1); set_idle w1:p1
wall_at ""
review_task "$G" 0 >/dev/null 2>&1; wait_for test -f "$G/review.rc"
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_REVIEW)" "pending" "still a wall"
eq "$(st "$G" PQ_REVIEW_RESETS_AT)" "" "with no reset on file"
eq "$(st "$G" PQ_REVIEW_RETRY_AT)" "$(( FAKE_NOW + PQ_QUOTA_RETRY ))" "and the retry on the poll"
has "$(cat "$PQ_HOME/.out")" "no reset time in its reply, so trying again every 10m" "said"
eq "$(review_cell "$G")" "review quota" "a bare cell"
IFS=$'\t' read -r wb wa <<<"$(walled_slot)"
eq "$wb/$wa" "noreset's review/" "the freeze holds, with no time to name"

echo "== a wall collected after its reset had come round is not tomorrow's ==" >&2
reset_tasks; mode walled
G=$(mk_gated 030 late w1:p1); set_idle w1:p1
PAST=$(( $(real) - 600 )); wall_at "$PAST"
review_task "$G" 0 >/dev/null 2>&1; wait_for test -f "$G/review.rc"
# Printed twenty minutes ago, before its reset; collected only now, after it.
touch -t "$(date -r $(( $(real) - 1200 )) '+%Y%m%d%H%M.%S')" "$G/review.rc"
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_REVIEW_RETRY_AT)" "$FAKE_NOW" "the retry is now, not a day out"
has "$(cat "$PQ_HOME/.out")" "its reset has already come round, so resuming it now" "said"
# The same line printed AFTER the time it names means the next one, a day out.
reset_tasks; mode walled
G=$(mk_gated 031 tomorrow w1:p1); set_idle w1:p1
wall_at $(( $(real) - 600 ))
review_task "$G" 0 >/dev/null 2>&1; wait_for test -f "$G/review.rc"
review_task "$G" 0 >/dev/null 2>&1
[ "$(st "$G" PQ_REVIEW_RETRY_AT)" -gt $(( FAKE_NOW + 80000 )) ] && ok || bad "a reset named after it passed is tomorrow's (got $(st "$G" PQ_REVIEW_RETRY_AT))"

echo "== a reply that is not JSON has its stderr read for the wall ==" >&2
reset_tasks; mode wallerr
G=$(mk_gated 040 stderr w1:p1); set_idle w1:p1
T=$(( $(real) + 3600 )); wall_at "$T"
review_task "$G" 0 >/dev/null 2>&1; wait_for test -f "$G/review.rc"
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_REVIEW)" "pending" "a wall on stderr is a wall"
eq "$(st "$G" PQ_REVIEW_TRIES)" "0" "and spends no try"
near "$(st "$G" PQ_REVIEW_RESETS_AT)" "$T" "its reset read all the same"

echo "== a review that merely talks about limits is a review ==" >&2
reset_tasks; mode ratelimit
G=$(mk_gated 050 talks w1:p1); set_idle w1:p1
review_task "$G" 0 >/dev/null 2>&1; wait_for test -f "$G/review.rc"
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_REVIEW)" "posted" "a two-line reply that says hit your API limit is not the wall"
eq "$(st "$G" PQ_REVIEW_RESULT)" "ok" "it is the review"

echo "== a session that has gone starts the review afresh, and costs no try ==" >&2
reset_tasks; mode walled
G=$(mk_gated 060 gone w1:p1); set_idle w1:p1
wall_at $(( $(real) + 120 ))
review_task "$G" 0 >/dev/null 2>&1; wait_for test -f "$G/review.rc"
review_task "$G" 0 >/dev/null 2>&1
touch "$STUBBIN/.sessions-gone"; mode ok
FAKE_NOW=$(( $(st "$G" PQ_REVIEW_RETRY_AT) + 1 ))
review_task "$G" 0 >/dev/null 2>&1; wait_for test -f "$G/review.rc"
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_REVIEW)" "pending" "a resume that found nothing is back to pending"
eq "$(st "$G" PQ_REVIEW_SESSION)" "" "with the session forgotten"
eq "$(st "$G" PQ_REVIEW_TRIES)" "0" "and no try spent"
eq "$(st "$G" PQ_REVIEW_RETRY_AT)" "" "and nothing to wait for"
has "$(cat "$PQ_HOME/.out")" "the session of the walled reviewer is gone - starting it afresh" "said"
rm -f "$STUBBIN/.sessions-gone"
review_task "$G" 0 >/dev/null 2>&1
wait_for test -f "$G/review.rc"
line=$(grep $'\t/code-review ' "$CLAUDE_LOG" | tail -1)
[ -n "$line" ] && ok || bad "the next launch is a fresh one, with the skill"
hasnt "$line" "--resume" "and no resume"

echo "== a resumed review that errors is an ordinary failed try, and the next is fresh ==" >&2
reset_tasks; mode walled
G=$(mk_gated 070 errs w1:p1); set_idle w1:p1
wall_at $(( $(real) + 120 ))
review_task "$G" 0 >/dev/null 2>&1; wait_for test -f "$G/review.rc"
review_task "$G" 0 >/dev/null 2>&1
mode fail
FAKE_NOW=$(( $(st "$G" PQ_REVIEW_RETRY_AT) + 1 ))
review_task "$G" 0 >/dev/null 2>&1; wait_for test -f "$G/review.rc"
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_REVIEW)" "pending" "a failed try with one left"
eq "$(st "$G" PQ_REVIEW_TRIES)" "1" "counted"
eq "$(st "$G" PQ_REVIEW_SESSION)" "" "and the session that failed is not resumed again"
eq "$(st "$G" PQ_REVIEW_WALL)" "" "nor is this a wall"

echo "== walls run out at PQ_QUOTA_MAX_TRIES, and the follow-up says why ==" >&2
reset_tasks; mode walled
PQ_QUOTA_MAX_TRIES=2
G=$(mk_gated 080 walls w1:p1); set_idle w1:p1
for n in 1 2 3; do
  wall_at $(( $(real) + 120 ))
  FAKE_NOW=$(( $(real) + 200 * n ))
  [ "$n" = 1 ] && FAKE_NOW=$(real)
  review_task "$G" 0 >/dev/null 2>&1; wait_for test -f "$G/review.rc"
  review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
done
eq "$(st "$G" PQ_REVIEW_WALLS)" "3" "three walls"
eq "$(st "$G" PQ_REVIEW)" "posted" "the third is past the bound: final"
eq "$(st "$G" PQ_REVIEW_RESULT)" "quota" "as quota"
has "$(cat "$PQ_HOME/.out")" "the reviewer is still walled after 2 tries" "said"
eq "$(walled_slot)" "" "and the freeze lets go"
review_task "$G" 0 >/dev/null 2>&1
has "$(prompt_text)" "could not get an independent review of pull request #42 - the reviewer kept hitting the usage limit." "the follow-up asks for a self-review, and says why"
PQ_QUOTA_MAX_TRIES=40

echo "== a settled pull request ends the wait, and the freeze with it ==" >&2
reset_tasks; mode walled
G=$(mk_gated 090 settles w1:p1); set_idle w1:p1
wall_at $(( $(real) + 7200 ))
review_task "$G" 0 >/dev/null 2>&1; wait_for test -f "$G/review.rc"
review_task "$G" 0 >/dev/null 2>&1
[ -n "$(walled_slot)" ] && ok || bad "walled, and freezing"
reset_caches; cache_row "$REPO" tom/settles 42 MERGED "" master
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_REVIEW)" "skipped" "skipped with the settle"
eq "$(walled_slot)" "" "and nothing is left freezing the queue"
eq "$(review_cell "$G")" "" "nor saying quota"

echo "== the security reviewer: its wall is never posted, and the follow-up waits ==" >&2
reset_tasks; mode ok; smode walled
G=$(mk_gated 100 secwall w1:p1 yes); set_idle w1:p1
T=$(( $(real) + 3600 )); wall_at "$T"
review_task "$G" 0 >/dev/null 2>&1
wait_for test -f "$G/review.rc"; wait_for test -f "$G/security.rc"
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_REVIEW)" "posted" "the code review is in"
eq "$(st "$G" PQ_SECURITY)" "pending" "the walled security review waits"
eq "$(st "$G" PQ_SECURITY_TRIES)" "0" "with no try spent"
eq "$(cat "$GH_LOG")" "" "and its wall was not posted on the pull request"
[ -f "$G/security.md" ] && bad "nor saved as a report" || ok
has "$(cat "$PQ_HOME/.out")" "the security reviewer hit the usage limit - resuming it at" "said"
eq "$(review_cell "$G")" "review quota $(clock_of "$(st "$G" PQ_SECURITY_RESETS_AT)")" "the gate reads quota"
review_task "$G" 0 >/dev/null 2>&1
eq "$(prompts)" "0" "no follow-up while it waits"
smode ok
FAKE_NOW=$(( $(st "$G" PQ_SECURITY_RETRY_AT) + 1 ))
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
has "$(cat "$PQ_HOME/.out")" "resuming the security review of #42 after the usage limit" "resumed beside a posted gate"
line=$(last_call "this security review")
has "$line" "	--resume	b1747627-d4f1-4d8c-958f-feb69fe51607	" "its own session"
has "$line" "	--disallowedTools	Edit(/$HOME/**)	Bash(gh:*)	" "still read-only, still no gh"
has "$line" "	The usage limit that stopped you has reset. Carry on with this security review exactly where you left off, and reply with the markdown report as the review asked.	" "told to carry on"
wait_for test -f "$G/security.rc"
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_SECURITY_RESULT)" "ok" "the resumed security review is collected"
eq "$(st "$G" PQ_REVIEW)" "prompted" "and the one follow-up goes"
has "$(prompt_text)" "The security review the plan asked for has run as well" "about both"

echo "== both wall on one tick; the security relaunch waits for the gate's ==" >&2
reset_tasks; mode walled; smode walled
G=$(mk_gated 110 bothwall w1:p1 yes); set_idle w1:p1
wall_at $(( $(real) + 600 ))
review_task "$G" 0 >/dev/null 2>&1
wait_for test -f "$G/review.rc"; wait_for test -f "$G/security.rc"
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_REVIEW)/$(st "$G" PQ_SECURITY)" "pending/pending" "both wait"
eq "$(st "$G" PQ_REVIEW_WALL)/$(st "$G" PQ_SECURITY_WALL)" "1/1" "both on the wall"
mode ok; smode ok
FAKE_NOW=$(( $(st "$G" PQ_REVIEW_RETRY_AT) + 1 ))
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_REVIEW)/$(st "$G" PQ_SECURITY)" "running/running" "and both resume on the same tick"

echo "== the code reviewer walls while the security one is due: it waits for the gate ==" >&2
reset_tasks; mode walled; smode fail
PQ_REVIEW_MAX_TRIES=2
G=$(mk_gated 120 codewall w1:p1 yes); set_idle w1:p1
wall_at $(( $(real) + 3600 ))
review_task "$G" 0 >/dev/null 2>&1
wait_for test -f "$G/review.rc"; wait_for test -f "$G/security.rc"
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_REVIEW)" "pending" "the code reviewer is on the wall"
eq "$(st "$G" PQ_SECURITY)" "pending" "the security reviewer failed and wants a retry"
smode ok
FAKE_NOW=$(( $(st "$G" PQ_SECURITY_RETRY_AT) + 1 ))
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_SECURITY)" "pending" "its retry waits for the gate to relaunch, not the other way round"
FAKE_NOW=$(( $(st "$G" PQ_REVIEW_RETRY_AT) + 1 )); mode ok
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_REVIEW)/$(st "$G" PQ_SECURITY)" "running/running" "then both go"

echo "== --dry-run changes nothing ==" >&2
reset_tasks; mode walled
G=$(mk_gated 130 dry w1:p1); set_idle w1:p1
wall_at $(( $(real) + 600 ))
review_task "$G" 0 >/dev/null 2>&1; wait_for test -f "$G/review.rc"
OUT=$(review_task "$G" 1 2>&1)
has "$OUT" "would hold dry's review for the usage limit" "the would-line"
eq "$(st "$G" PQ_REVIEW)" "running" "state untouched"
eq "$(st "$G" PQ_REVIEW_WALLS)" "" "nothing counted"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
