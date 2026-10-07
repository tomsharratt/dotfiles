#!/usr/bin/env bash
# test/pq-settings.sh - the settings.json pq hands every implementer, executed for real.
#
# Each hook runs on every tool call, and the status line after every message, so
# they are inline shell and jq, never pq. This runs each generated command the way
# Claude Code does - `sh -c`, payload on stdin - and asserts what it leaves: the
# agent.json the hooks write, and the cost record and the bar the status line
# writes and prints. PQ_HOME contains a space, so a quoting mistake in the
# generated commands fails here rather than in somebody's pane.
#
# SC2015: `ok` never fails, so `[ ... ] && ok || bad` is an if/else.
# SC2016: the chained status lines are shell for the status line to run, not this file.
# shellcheck disable=SC2015,SC2016
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PQ_HOME="$(mktemp -d)/pq home"
mkdir -p "$PQ_HOME"
export PQ_HOME

STUBBIN=$(mktemp -d)
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/claude"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/gh"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/herdr"
chmod +x "$STUBBIN/claude" "$STUBBIN/gh" "$STUBBIN/herdr"
export PATH="$STUBBIN:$PATH"

# shellcheck source=/dev/null
source "$HERE/../.local/bin/pq"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }

cleanup() { rm -rf "$(dirname "$PQ_HOME")" "$STUBBIN"; }
trap cleanup EXIT

D="$PQ_HOME/running/20260101000000-hooked"
mkdir -p "$D" "$PQ_HOME/tasks"
task_link "$D"
# The worktree and user settings the status line is chained from, both empty to
# begin with: nothing to chain to.
WTREE="$(dirname "$PQ_HOME")/work tree"; mkdir -p "$WTREE/.claude"
CLAUDE_CONFIG_DIR="$(dirname "$PQ_HOME")/config"; mkdir -p "$CLAUDE_CONFIG_DIR"
export CLAUDE_CONFIG_DIR
settings_write "$D" "$WTREE" || bad "settings_write failed"
HJ="$D/settings.json"
A="$(task_home "$D")/agent.json"

# Run the hook for an event the way Claude Code does; prints what it wrote to stdout.
run_hook() {                            # event payload
  local cmd
  cmd=$(jq -r --arg e "$1" '.hooks[$e][0].hooks[0].command' "$HJ")
  printf '%s' "$2" | sh -c "$cmd"
}
field() { jq -r ".$1" "$A"; }

echo "== settings.json is valid, with one command hook per event ==" >&2
jq -e . "$HJ" >/dev/null && ok || bad "settings.json is not JSON"
for e in UserPromptSubmit PostToolUse PermissionRequest Stop StopFailure; do
  eq "$(jq -r --arg e "$e" '.hooks[$e][0].hooks[0].type' "$HJ")" command "$e is a command hook"
done
eq "$(compgen -G "$D/settings.json.*" | wc -l | tr -d ' ')" 0 "no temp file is left behind"

echo "== each lifecycle event writes its record ==" >&2
NOW=$(date +%s)
for pair in UserPromptSubmit:working PostToolUse:working PermissionRequest:permission Stop:idle; do
  rm -f "$A"
  out=$(run_hook "${pair%%:*}" '{"session_id":"s","hook_event_name":"x"}'); rc=$?
  eq "$rc" 0 "${pair%%:*} exits 0"
  eq "$out" "" "${pair%%:*} prints nothing, so it never answers a dialog"
  eq "$(field event)" "${pair##*:}" "${pair%%:*} records ${pair##*:}"
  [ "$(field at)" -ge "$NOW" ] && ok || bad "${pair%%:*} stamps the time"
done
eq "$(compgen -G "$A.*" | wc -l | tr -d ' ')" 0 "no temp file is left behind"

echo "== StopFailure records the error and the first line of the message ==" >&2
rm -f "$A"
MSG=$'You\'ve hit "your" $HOME `limit` \\ \xc3\xa9\xe2\x80\x94 \xe6\x97\xa5\xe6\x9c\xac\nsecond line'
payload=$(jq -nc --arg m "$MSG" '{hook_event_name:"StopFailure",error:"rate_limit",last_assistant_message:$m}')
out=$(run_hook StopFailure "$payload"); rc=$?
eq "$rc" 0 "exits 0"
eq "$out" "" "prints nothing"
eq "$(field event)" error "records error"
eq "$(field error)" rate_limit "with the error type"
eq "$(field message)" $'You\'ve hit "your" $HOME `limit` \\ \xc3\xa9\xe2\x80\x94 \xe6\x97\xa5\xe6\x9c\xac' "and the first line, quotes, \$, backslash and non-ASCII intact"
eq "$(agent_event "$D" | cut -f1,3)" $'error\trate_limit' "agent_event reads it back"

echo "== the message is cut to 120 characters ==" >&2
long=$(printf 'x%.0s' $(seq 1 300))
run_hook StopFailure "$(jq -nc --arg m "$long" '{error:"server_error",last_assistant_message:$m}')"
eq "$(field message | wc -c | tr -d ' ')" 121 "120 characters and the newline"

echo "== a payload with no message or error still records ==" >&2
run_hook StopFailure '{}'
eq "$(field error)" unknown "error falls back to unknown"
eq "$(field message)" "" "and the message is empty"

echo "== agent_event on nothing usable ==" >&2
rm -f "$A"
eq "$(agent_event "$D")" "" "no file"
printf 'not json' > "$A"
eq "$(agent_event "$D")" "" "an unparseable file"

# Run the status line the way Claude Code does; prints the bar.
run_status() {                          # payload
  printf '%s' "$1" | sh -c "$(jq -r '.statusLine.command' "$HJ")"
}
C="$D/cost"
payload() {                             # session cost -> a status line payload
  jq -nc --arg s "$1" --argjson c "$2" '{session_id: $s, cost: {total_cost_usd: $c, total_duration_ms: 1}, model: {id: "x"}}'
}

echo "== the status line records the session's running cost ==" >&2
eq "$(jq -r '.statusLine.type' "$HJ")" command "it is a command status line"
[ -d "$C" ] && ok || bad "the ledger exists from dispatch"
out=$(run_status "$(payload 9d798be4-aef8-43ef-9e61-5ab0a72559f1 0.0326373)"); rc=$?
eq "$rc" 0 "exits 0"
eq "$out" "" "and with nothing to chain to, shows nothing"
eq "$(cat "$C/9d798be4-aef8-43ef-9e61-5ab0a72559f1.json")" '{"what":"implementer","usd":0.0326373}' "one file for the session, its running total"
run_status "$(payload 9d798be4-aef8-43ef-9e61-5ab0a72559f1 0.5)" >/dev/null
eq "$(jq -r .usd "$C/9d798be4-aef8-43ef-9e61-5ab0a72559f1.json")" 0.5 "overwritten in place as the total grows"
run_status "$(payload 54123dcf-3852-4aa4-a37d-e10f87f8d46d 0.02)" >/dev/null
eq "$(compgen -G "$C/*.json" | wc -l | tr -d ' ')" 2 "a new session - after /clear - gets a file of its own"
eq "$(cut -f1,2,4 <<<"$(cost_sum "$D")")" $'0.52\tfalse\t0.52' "and the ledger sums them as the implementer's"
eq "$(compgen -G "$C/*.json.*" | wc -l | tr -d ' ')" 0 "no temp file is left behind"

echo "== nothing it cannot use is recorded, and nothing reaches the bar ==" >&2
rm -f "$C"/*
out=$(run_status 'not json' 2>&1); eq "$out" "" "a payload that is not JSON: silent"
out=$(run_status '{"session_id":"s1"}' 2>&1); eq "$out" "" "one with no cost: silent"
eq "$(compgen -G "$C/*" | wc -l | tr -d ' ')" 0 "and neither writes a record - a null would read as a lower bound"
MARK="$(dirname "$PQ_HOME")/ran"
run_status "$(payload "../../x y;\$(touch '$MARK')" 1)" >/dev/null
eq "$(cd "$C" && ls)" "xytouch$(tr -cd 'A-Za-z0-9-' <<<"$MARK").json" "a session id is cut down to a safe file name"
[ -e "$MARK" ] && bad "and is never run as a command" || ok
rm -f "$C"/*
chmod 500 "$C"
out=$(run_status "$(payload s2 1)" 2>&1); rc=$?
chmod 700 "$C"
eq "$out" "" "an unwritable ledger: silent"
eq "$rc" 0 "and still exits 0"

echo "== it hands the payload on to the status line it replaced ==" >&2
# Local outranks project outranks user, as in Claude Code; each chained command
# says which it is and echoes the session it was handed.
chained() { jq -n --arg c "$1" '{statusLine: {type: "command", command: $c}}'; }
chained 'printf "user:%s" "$(jq -r .session_id)" # a trailing comment' > "$CLAUDE_CONFIG_DIR/settings.json"
eq "$(statusline_inherited "$WTREE")" 'printf "user:%s" "$(jq -r .session_id)" # a trailing comment' "user settings, with no others"
chained 'printf "project:%s" "$(jq -r .session_id)"' > "$WTREE/.claude/settings.json"
eq "$(statusline_inherited "$WTREE")" 'printf "project:%s" "$(jq -r .session_id)"' "project over user"
printf '{"statusLine": null}' > "$WTREE/.claude/settings.local.json"
eq "$(statusline_inherited "$WTREE")" 'printf "project:%s" "$(jq -r .session_id)"' "a local file that sets none is passed over"
chained 'printf "local:%s" "$(jq -r .session_id)"' > "$WTREE/.claude/settings.local.json"
eq "$(statusline_inherited "$WTREE")" 'printf "local:%s" "$(jq -r .session_id)"' "local over both"
eq "$(statusline_inherited "")" 'printf "user:%s" "$(jq -r .session_id)" # a trailing comment' "no worktree: user settings"
rm -f "$WTREE/.claude/"*
D2="$PQ_HOME/running/20260101000001-chained"; mkdir -p "$D2"; task_link "$D2"
settings_write "$D2" "$WTREE"
out=$(printf '%s' "$(payload s3 0.25)" | sh -c "$(jq -r '.statusLine.command' "$D2/settings.json")"); rc=$?
eq "$out" "user:s3" "the bar is exactly the chained command's output, from the same payload"
eq "$rc" 0 "exits 0"
eq "$(jq -c . "$D2/cost/s3.json")" '{"what":"implementer","usd":0.25}' "after recording it - a trailing comment in the chained command swallows nothing"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
