#!/usr/bin/env bash
# test/pq-hooks.sh - the hooks.json pq hands every implementer, executed for real.
#
# Each hook runs on every tool call, so it is inline shell and jq, never pq. This
# runs each generated command the way Claude Code does - `sh -c`, payload on stdin -
# and asserts the agent.json it leaves. PQ_HOME contains a space, so a quoting
# mistake in the generated commands fails here rather than in somebody's pane.
#
# SC2015: `ok` never fails, so `[ ... ] && ok || bad` is an if/else.
# shellcheck disable=SC2015
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
hooks_write "$D" || bad "hooks_write failed"
HJ="$D/hooks.json"
A="$(task_home "$D")/agent.json"

# Run the hook for an event the way Claude Code does; prints what it wrote to stdout.
run_hook() {                            # event payload
  local cmd
  cmd=$(jq -r --arg e "$1" '.hooks[$e][0].hooks[0].command' "$HJ")
  printf '%s' "$2" | sh -c "$cmd"
}
field() { jq -r ".$1" "$A"; }

echo "== hooks.json is valid, with one command hook per event ==" >&2
jq -e . "$HJ" >/dev/null && ok || bad "hooks.json is not JSON"
for e in UserPromptSubmit PostToolUse PermissionRequest Stop StopFailure; do
  eq "$(jq -r --arg e "$e" '.hooks[$e][0].hooks[0].type' "$HJ")" command "$e is a command hook"
done
eq "$(compgen -G "$D/hooks.json.*" | wc -l | tr -d ' ')" 0 "no temp file is left behind"

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

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
