#!/usr/bin/env bash
# test/pq-cost.sh - a task's ledger: one file per Claude session under <task>/cost/,
# written by cost_record and cost_book, summed by cost_sum, and shown by cost_total
# in `pq ls` - the COST column, only once some task has a ledger, and the cost
# fields of --json. The status line that writes the implementer's records is
# executed for real in test/pq-settings.sh; the reviewers' and the namer's booking
# in test/pq-review.sh, test/pq-security.sh, test/pq-design.sh and test/pq-reuse.sh.
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
has() { case "$1" in *"$2"*) ok ;; *) bad "$3 (got '$1')" ;; esac; }
hasnt() { case "$1" in *"$2"*) bad "$3 (got '$1')" ;; *) ok ;; esac; }

cleanup() { rm -rf "$(dirname "$PQ_HOME")" "$STUBBIN"; }
trap cleanup EXIT

mk_task() {                             # state stamp slug -> task_dir
  local d="$PQ_HOME/$1/$2-$3"
  mkdir -p "$d"
  printf -- '---\nrepo:     /nowhere\nbranch:   tom/%s\nmodel:    sonnet\neffort:   medium\nadded:    2026-01-01T00:00:00Z\n---\n\nplan\n' "$3" > "$d/plan.md"
  printf '%s' "$d"
}
records() { compgen -G "$1/cost/*.json" | wc -l | tr -d ' '; }

echo "== cost_record: one file per session, overwritten in place ==" >&2
T=$(mk_task queue 20260101000001 ledger)
cost_record "$T" name 4f1c2b9a-0d3e 0.0042
eq "$(cat "$T/cost/4f1c2b9a-0d3e.json")" '{"what":"name","usd":0.0042}' "the session's record"
cost_record "$T" implementer s-1 0.5
cost_record "$T" implementer s-1 1.25
eq "$(records "$T")" 2 "the same session twice is one file"
eq "$(jq -r .usd "$T/cost/s-1.json")" 1.25 "holding its latest total"
eq "$(compgen -G "$T/cost/*.json.*" | wc -l | tr -d ' ')" 0 "no temp file is left behind"
cost_record "$T" review '../a b/c' 0.3
eq "$(compgen -G "$T/cost/abc.json" | wc -l | tr -d ' ')" 1 "an id is cut down to a safe file name"
cost_record "$T" review "" 0.1; cost_record "$T" review "" 0.1
eq "$(records "$T")" 5 "and one with no id at all gets a file of its own each time"
cost_record "$T" security sec-1 'not a number'
eq "$(jq -c .usd "$T/cost/sec-1.json")" null "a cost that is not a number is unknown"
cost_record "$T" security sec-2 1e-3
eq "$(jq -c .usd "$T/cost/sec-2.json")" 0.001 "an exponent is a number"

echo "== cost_book: a reviewer try, read off its own result ==" >&2
B=$(mk_task "done" 20260101000002 booked)
# The shape of a real review.json, trimmed.
printf '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":1.9299977999999998,"duration_ms":368256,"session_id":"1301a432-1aba-4ccb-bbc2-53b5fc3baa67","modelUsage":{"claude-opus-5-5":{"costUSD":1.9299977999999998}}}' > "$B/review.json"
cost_book "$B" review
eq "$(jq -c . "$B/cost/1301a432-1aba-4ccb-bbc2-53b5fc3baa67.json")" '{"what":"review","usd":1.9299977999999998}' "under its session"
cost_book "$B" review
eq "$(records "$B")" 1 "booked twice - an interrupted tick - is still one record"
st_set "$B" PQ_SECURITY_TRIES 2
printf 'not json' > "$B/security.json"
cost_book "$B" security
eq "$(jq -c . "$B/cost/security-try-2.json")" '{"what":"security","usd":null}' "a result that is not JSON is the try, unknown"
rm -f "$B/security.json"; st_set "$B" PQ_SECURITY_TRIES 3
cost_book "$B" security
eq "$(jq -c .usd "$B/cost/security-try-3.json")" null "and so is no result at all"

echo "== cost_sum and cost_total ==" >&2
N=$(mk_task queue 20260101000003 nothing)
eq "$(cost_sum "$N")" "" "no ledger: nothing"
eq "$(cost_total "$N")" "" "and nothing shown"
mkdir -p "$N/cost"
eq "$(cost_sum "$N")" "" "an empty ledger: nothing either"
Q=$(mk_task queue 20260101000004 named)
cost_record "$Q" name n-1 0.006; cost_record "$Q" name n-2 0.004
eq "$(cost_sum "$Q")" $'0.01\tfalse\t0.01\t\t\t' "a queued task: naming, and nothing else yet"
eq "$(cost_total "$Q")" "\$0.01" "shown to the cent"
st_set "$Q" PQ_STARTED "2026-01-01T00:00:00Z"
eq "$(cut -f2 <<<"$(cost_sum "$Q")")" true "started with no implementer record: a lower bound"
eq "$(cost_total "$Q")" "\$0.01+" "and says so"
cost_record "$Q" implementer s-1 2.5
eq "$(cost_sum "$Q")" $'2.51\tfalse\t0.01\t2.5\t\t' "with one, the whole cost"
cost_record "$Q" implementer s-2 0.5
cost_record "$Q" review r-1 1.2
cost_record "$Q" security s-3 0.9
eq "$(cost_sum "$Q")" $'5.11\tfalse\t0.01\t3\t1.2\t0.9' "every kind, each summed across its sessions"
cost_record "$Q" review review-try-2 null
eq "$(cut -f1,2,5 <<<"$(cost_sum "$Q")")" $'5.11\ttrue\t1.2' "an unknown try adds nothing and makes it a lower bound"
eq "$(cost_total "$Q")" "\$5.11+" "shown as one"
printf '[]' > "$Q/cost/stray.json"
eq "$(cut -f1 <<<"$(cost_sum "$Q")")" 5.11 "a record that is not one is ignored"

echo "== pq ls: no COST column until some task has a ledger ==" >&2
rm -rf "$PQ_HOME/queue" "$PQ_HOME/done"; mkdir -p "$PQ_HOME/queue" "$PQ_HOME/done"
P1=$(mk_task queue 20260101000010 plain-one)
P2=$(mk_task queue 20260101000011 plain-two)
out=$(PQ_WIDTH=200 main ls 2>/dev/null)
eq "$(head -1 <<<"$out" | tr -s ' ')" "TASK STATE AGENT PR AGE" "the header is as it always was"
cost_record "$P1" name n-1 0.012
st_set "$P2" PQ_STARTED "2026-01-01T00:00:00Z"
out=$(PQ_WIDTH=200 main ls 2>/dev/null)
eq "$(head -1 <<<"$out" | tr -s ' ')" "TASK STATE AGENT PR COST AGE" "COST arrives with the first ledger, before AGE"
eq "$(grep plain-one <<<"$out" | awk '{ print $(NF-1) }')" "\$0.01" "the task's total"
eq "$(grep plain-two <<<"$out" | awk '{ print $(NF-1) }')" '-' "and - for one with no ledger"

echo "== pq ls --json: the total, whether it is a lower bound, and its parts ==" >&2
cost_record "$P1" implementer s-1 2; cost_record "$P1" review review-try-1 null
json=$(main ls --json 2>/dev/null)
eq "$(jq -c '.[] | select(.task == "plain-one") | [.cost_usd, .cost_partial, .cost]' <<<"$json")" \
  '[2.012,true,{"name":0.012,"implementer":2,"review":null,"security":null}]' "a ledger, every part, and a review whose only try is unknown is null, not free"
eq "$(jq -c '.[] | select(.task == "plain-two") | [.cost_usd, .cost_partial, .cost]' <<<"$json")" \
  '[null,false,null]' "no ledger: null, not zero"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
