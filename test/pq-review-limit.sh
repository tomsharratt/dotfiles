#!/usr/bin/env bash
# test/pq-review-limit.sh - a reviewer that hits the usage limit. In `-p` the
# limit is not an error: the session exits 0 with the limit's one line as its
# whole reply, and the gate used to read that as a review that had posted. Now
# the reviewer - code or security - counts it as an ordinary failed try, with
# `limit` for its result, so the follow-up can say why. The limit is a monthly
# hard stop, so there is no reset to wait on and no session to resume.
#
# The fixture is the real output of the first review that hit a limit (#6831),
# byte for byte but for its reply, which is swapped for whichever limit line a
# case needs. The harness is test/pq-security.sh's: a pinned `epoch`, and a
# `claude` stub that records its argv and behaves per a mode file for each
# reviewer.
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
LIMIT="$STUBBIN/.limit.json"
LIMIT_LINE="$STUBBIN/.limit-line"
printf '{"result":{"snapshot":{"panes":[]}}}' > "$PANES_JSON"
: > "$HERDR_LOG"; : > "$CLAUDE_LOG"; : > "$GH_LOG"
printf 'ok' > "$MODE"; printf 'ok' > "$SMODE"; printf '0' > "$COMMENTS"
# The real reply, from ~/.local/state/pq/done/*-public-livestreams-anonymous-chat/review.json.
cat > "$STUBBIN/.limit-captured.json" <<'FIXEOF'
{"is_error":false,"duration_api_ms":0,"num_turns":0,"stop_reason":null,"session_id":"b1747627-d4f1-4d8c-958f-feb69fe51607","total_cost_usd":5.5221492,"usage":{"output_tokens_details":{"thinking_tokens":0},"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0,"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},"inference_geo":"","iterations":[],"speed":"standard"},"modelUsage":{"claude-opus-5-5":{"inputTokens":160,"outputTokens":82841,"cacheReadInputTokens":12929521,"cacheCreationInputTokens":255757,"webSearchRequests":0,"costUSD":5.5221492,"contextWindow":1000000,"maxOutputTokens":128000,"thinkingTokens":66783,"canonicalModel":"claude-opus-5-5","provider":"firstParty","costBasis":"list"}},"permission_denials":[],"fast_mode_state":"off","fast_mode_disabled_reason":"sdk_opt_in_required","subagent_stats":{"spawned":0,"requested":{"background":0,"foreground":0,"unset":0},"started_in_background":0,"max_depth":0,"spawned_by_subagents":0,"completed":0,"failed":0,"killed":{"parent":0,"user":0,"system":0},"refused":{"depth_limit":0,"concurrency_limit":0,"budget":0},"by_type":{}},"subtype":"success","result":"You've hit your session limit · resets 7pm (America/Toronto)","local_command":"code_review","type":"result","duration_ms":913570,"uuid":"7e2b7a73-e71c-427a-b3f7-4d3884b15c10","queued_turn_count":0,"result_index":0}
FIXEOF

cat > "$STUBBIN/claude" <<EOF
#!/bin/sh
{ printf '%s\t' "\$PWD"; for a in "\$@"; do printf '%s\t' "\$a"; done; printf '\n'; } >> "$CLAUDE_LOG"
last=""
for a in "\$@"; do last=\$a; done
case "\$last" in
  /security-review) kind=security; m=\$(cat "$SMODE") ;;
  /code-review*)    kind=code;     m=\$(cat "$MODE") ;;
  *) exit 1 ;;
esac
case "\$m" in
  limit)     cat "$LIMIT"; exit 0 ;;
  limiterr)  printf 'not json\n'; printf 'Error: request failed\n%s\n' "\$(cat "$LIMIT_LINE")" >&2; exit 1 ;;
  ratelimit) [ "\$kind" = code ] && echo \$(( \$(cat "$COMMENTS") + 2 )) > "$COMMENTS"
             jq -nc '{is_error:false,session_id:"s-2",result:"Two findings.\nThe new middleware returns 429 once clients hit your API limit, but never sets Retry-After."}'; exit 0 ;;
esac
if [ "\$kind" = code ]; then
  echo \$(( \$(cat "$COMMENTS") + 2 )) > "$COMMENTS"      # a review that lands posts inline comments
  printf '{"is_error":false,"total_cost_usd":1.2,"duration_ms":5000,"session_id":"s-code","permission_denials":[]}\n'; exit 0
fi
jq -nc '{is_error:false,total_cost_usd:0.9,duration_ms:90000,session_id:"s-sec",permission_denials:[],result:"# Security review\n\nNo vulnerabilities found."}'
EOF
cat > "$STUBBIN/gh" <<EOF
#!/bin/sh
case "\$*" in
  *"pr comment"*) printf '%s\n' "\$*" >> "$GH_LOG"; exit 0 ;;
  *"pr view"*)    [ -f "$PRJSON" ] && cat "$PRJSON" && exit 0; exit 1 ;;
  *"/comments"*)  awk -v n="\$(cat "$COMMENTS")" 'BEGIN { for (i = 1; i <= n; i++) print i }'; exit 0 ;;
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

cleanup() {
  local d
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
PQ_REVIEW_EFFORT=high

# The gate's clock is pinned, and walked forward by hand past each backoff.
FAKE_NOW=$(date -u '+%s')
epoch() { printf '%s' "$FAKE_NOW"; }
now()   { date -u -r "$FAKE_NOW" '+%Y-%m-%dT%H:%M:%SZ'; }

reset_caches() { PR_CACHE="$PQ_HOME/.test.pr"; PR_ANS="$PQ_HOME/.test.ans"; : > "$PR_CACHE"; : > "$PR_ANS"; }
cache_row() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$PR_CACHE"; }
reset_tasks() {
  local d
  for d in "$PQ_HOME"/done/*/; do [ -d "$d" ] && review_kill "${d%/}"; done
  rm -rf "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done" "$PQ_HOME/archive"
  mkdir -p "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done" "$PQ_HOME/archive"
  : > "$HERDR_LOG"; : > "$CLAUDE_LOG"; : > "$GH_LOG"
  FAKE_NOW=$(date -u '+%s')
  reset_caches
}
mode()  { printf '%s' "$1" > "$MODE"; }
smode() { printf '%s' "$1" > "$SMODE"; }
# The captured reply, with the given line for its whole answer.
limit_says() {                          # line
  printf '%s' "$1" > "$LIMIT_LINE"
  jq -c --arg r "$1" '.result = $r' "$STUBBIN/.limit-captured.json" > "$LIMIT"
}
SPEND="You've hit your individual spend limit · visit claude.ai/admin-settings/usage to raise it"
limit_says "$SPEND"
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
wait_for() { local _; for _ in $(seq 1 50); do "$@" && return 0; sleep 0.1; done; return 1; }
prompts()   { grep -c "^agent	prompt	" "$HERDR_LOG" 2>/dev/null || true; }
prompt_text() { grep "^agent	prompt	" "$HERDR_LOG" | tail -1 | cut -f4; }
launches() { grep -c . "$CLAUDE_LOG" 2>/dev/null || true; }

echo "== limit_reply: the limit's one line, in any plan's words, and nothing else ==" >&2
for line in "$SPEND" \
            "You've hit your org's monthly spend limit · ask your admin to raise it at claude.ai/admin-settings/usage" \
            "You're out of usage credits" \
            "Your org is out of usage · contact your admin" \
            "You've hit your session limit · resets 7pm (America/Toronto)"; do
  eq "$(limit_reply "$line")" "$line" "'$line' is the limit"
done
limit_reply "$(printf 'Two findings.\nClients hit your API limit without a Retry-After.\n')" && bad "a longer reply that mentions a limit is not the limit" || ok
limit_reply "" && bad "an empty reply is not the limit" || ok
limit_reply '{"branch":"tom/x","intent":"Warn before members run out of usage credits."}' && bad "a line of JSON is never the limit" || ok

echo "== the limit is a failed try, not a review that posted ==" >&2
reset_tasks; mode limit
G=$(mk_gated 010 limited w1:p1); set_idle w1:p1
review_task "$G" 0 >/dev/null 2>&1
wait_for test -f "$G/review.rc" || bad "the limited stub should have finished"
eq "$(cat "$G/review.rc")" "0" "the fixture exits 0, as the real one did"
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_REVIEW)" "pending" "back to pending on the backoff"
eq "$(st "$G" PQ_REVIEW_RESULT)" "limit" "with the limit for its result"
eq "$(st "$G" PQ_REVIEW_TRIES)" "1" "and the try spent"
eq "$(st "$G" PQ_REVIEW_RETRY_AT)" "$(( FAKE_NOW + PQ_REVIEW_RETRY ))" "retried like any other failure"
has "$(cat "$PQ_HOME/.out")" "review attempt 1 failed - the reviewer hit the usage limit ($SPEND)" "said, with the limit's own words"
eq "$(prompts)" "0" "nobody is told to resolve comments that do not exist"
eq "$(review_cell "$G")" "review due" "the cell names no reset"

echo "== the retry is a fresh review, and the last limit sends the follow-up ==" >&2
review_task "$G" 0 >/dev/null 2>&1
eq "$(launches)" "1" "nothing before the backoff is up"
FAKE_NOW=$(( $(st "$G" PQ_REVIEW_RETRY_AT) + 1 ))
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_REVIEW)" "running" "relaunched once it is"
wait_for test -f "$G/review.rc"
line=$(grep $'\t/code-review ' "$CLAUDE_LOG" | tail -1)
[ -n "$line" ] && ok || bad "the relaunch types the skill afresh"
hasnt "$line" "--resume" "and resumes nothing"
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_REVIEW)" "posted" "out of tries, the gate moves on"
eq "$(st "$G" PQ_REVIEW_RESULT)" "limit" "as the limit"
has "$(cat "$PQ_HOME/.out")" "review failed after 2 attempt(s) - the reviewer hit the usage limit" "said"
review_task "$G" 0 >/dev/null 2>&1
has "$(prompt_text)" "could not get an independent review of pull request #42 - the reviewer hit the usage limit." "the follow-up asks for a self-review, and says why"

echo "== a reply that is not JSON has its stderr read for the limit ==" >&2
reset_tasks; mode limiterr
G=$(mk_gated 020 stderr w1:p1); set_idle w1:p1
review_task "$G" 0 >/dev/null 2>&1; wait_for test -f "$G/review.rc"
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_REVIEW_RESULT)" "limit" "a limit on stderr is the limit"

echo "== a review that merely talks about limits is a review ==" >&2
reset_tasks; mode ratelimit
G=$(mk_gated 030 talks w1:p1); set_idle w1:p1
review_task "$G" 0 >/dev/null 2>&1; wait_for test -f "$G/review.rc"
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_REVIEW)" "posted" "a two-line reply that says hit your API limit is not the limit"
eq "$(st "$G" PQ_REVIEW_RESULT)" "ok" "it is the review"

echo "== the security reviewer: its limit is never posted ==" >&2
reset_tasks; mode ok; smode limit
G=$(mk_gated 040 seclimit w1:p1 yes); set_idle w1:p1
review_task "$G" 0 >/dev/null 2>&1
wait_for test -f "$G/review.rc"; wait_for test -f "$G/security.rc"
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_REVIEW)" "posted" "the code review is in"
eq "$(st "$G" PQ_SECURITY)" "pending" "the security review is retried"
eq "$(st "$G" PQ_SECURITY_RESULT)" "limit" "with the limit for its result"
eq "$(cat "$GH_LOG")" "" "and the limit's line was not posted on the pull request"
[ -f "$G/security.md" ] && bad "nor saved as a report" || ok
has "$(cat "$PQ_HOME/.out")" "security review attempt 1 failed - the security reviewer hit the usage limit" "said"
review_task "$G" 0 >/dev/null 2>&1
eq "$(prompts)" "0" "no follow-up while it is still to retry"
FAKE_NOW=$(( $(st "$G" PQ_SECURITY_RETRY_AT) + 1 ))
review_task "$G" 0 >/dev/null 2>&1; wait_for test -f "$G/security.rc"
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_SECURITY)/$(st "$G" PQ_SECURITY_RESULT)" "done/limit" "out of tries, it is done as the limit"
eq "$(cat "$GH_LOG")" "" "still nothing posted"
review_task "$G" 0 >/dev/null 2>&1
has "$(prompt_text)" "The security review the plan asked for did not happen - the security reviewer hit the usage limit." "and the one follow-up says why"

echo "== --dry-run changes nothing ==" >&2
reset_tasks; mode limit
G=$(mk_gated 050 dry w1:p1); set_idle w1:p1
review_task "$G" 0 >/dev/null 2>&1; wait_for test -f "$G/review.rc"
OUT=$(review_task "$G" 1 2>&1)
has "$OUT" "would count dry's review as a failed try - it hit the usage limit" "the would-line"
eq "$(st "$G" PQ_REVIEW)" "running" "state untouched"
eq "$(st "$G" PQ_REVIEW_TRIES)" "1" "nothing more counted"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
