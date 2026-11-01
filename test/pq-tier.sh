#!/usr/bin/env bash
# test/pq-tier.sh - the review tier: a plan's `Review:` and `Budget:` lines read
# into its header at add, and the label, description line and `pq ls` word a
# ready pull request gets from them and from what its diff turned out to be.
#
# Same shape as test/pq-watch.sh: the tick's PR rows are written by hand, and a
# `gh` stub serves the files, the review threads and the description from files,
# logging every call and keeping each --body-file it is handed.
#
# SC2034: the caches set here are read by the pq sourced below.
# SC2015: `ok` never fails, so `[ ... ] && ok || bad` is an if/else.
# SC2016: the backticks in the sample plans are markdown, not a substitution.
# shellcheck disable=SC2034,SC2015,SC2016
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=test/sandbox.sh
source "$HERE/sandbox.sh"

PQ_HOME=$(mktemp -d)
export PQ_HOME
# pq reads PQ_PLANS_DIR into its own PLANS_DIR when it is sourced, so the test's
# directory is held in a name pq never assigns: cleanup must only ever remove
# what this file made with mktemp, never whatever pq's PLANS_DIR ends up being.
TEST_PLANS=$(mktemp -d)
export PQ_PLANS_DIR=$TEST_PLANS

STUBBIN=$(mktemp -d)
GH_LOG="$STUBBIN/.gh-calls"
FILES="$STUBBIN/.files.json"; THREADS="$STUBBIN/.threads.json"; BODY="$STUBBIN/.body"
: > "$GH_LOG"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/claude"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/herdr"
# `.labels-missing` makes the first label edit fail, as GitHub does for a label
# the repo does not have, until a `label create` has run. A body edit is kept in
# .edited, and becomes the body the next view serves.
cat > "$STUBBIN/gh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$GH_LOG"
[ -f "$STUBBIN/.gh-down" ] && exit 1
case "\$*" in
  *"/pulls/"*"/files"*) cat "$FILES" ;;
  "api graphql"*)       [ -f "$STUBBIN/.threads-down" ] && exit 1; cat "$THREADS" ;;
  "label create"*)      rm -f "$STUBBIN/.labels-missing" ;;
  "pr edit"*"--add-label"*) [ -f "$STUBBIN/.labels-missing" ] && exit 1; exit 0 ;;
  "pr edit"*"--body-file"*)
    f=""; prev=""
    for a in "\$@"; do [ "\$prev" = "--body-file" ] && f=\$a; prev=\$a; done
    cp "\$f" "$STUBBIN/.edited"; cp "\$f" "$BODY" ;;
  "pr view"*"body"*)    cat "$BODY" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$STUBBIN/claude" "$STUBBIN/gh" "$STUBBIN/herdr"
export PATH="$STUBBIN:$PATH"

# shellcheck source=/dev/null
source "$HERE/../.local/bin/pq"
sandbox_guard
# shellcheck source=test/lib.sh
source "$HERE/lib.sh"

pr_load_all() { :; }

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { if [ "$1" = "$2" ]; then ok; else bad "$3 (got '$1', want '$2')"; fi; }
has() { case "$1" in *"$2"*) ok ;; *) bad "$3 (got '$1')" ;; esac; }
hasnt() { case "$1" in *"$2"*) bad "$3 (got '$1')" ;; *) ok ;; esac; }

cleanup() { sandbox_cleanup; }
trap cleanup EXIT

REPO=$(mktemp -d)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$REPO/.git/refs/remotes/origin"
git -C "$REPO" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master

unset HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID

plan() { printf '%b' "$2" > "$TEST_PLANS/$1"; printf '%s' "$TEST_PLANS/$1"; }
[ "$PLANS_DIR" = "$TEST_PLANS" ] || { echo "pq-tier.sh: PLANS_DIR is not the test's own directory - refusing to run" >&2; exit 1; }

echo "== a plan's Review: and Budget: lines ==" >&2
P=$(plan a.md '# A\n\nReview: skim\nBudget: 250 app lines\n')
eq "$(plan_review "$P")" "skim" "a plain Review: line"
eq "$(plan_budget "$P")" "250" "and its budget"
P=$(plan b.md '# B\n\n- **Review:** `Visual` - copy only\nBudget: ~1,250 app lines\n')
eq "$(plan_review "$P")" "visual" "list marker, bold, backticks and case are all allowed"
eq "$(plan_budget "$P")" "1250" "a budget written with a tilde and a thousands comma"
P=$(plan c.md '# C\n\n```\nReview: visual\n```\n\nReview the guide first.\nReview: run it twice\nReview: deep\n')
eq "$(plan_review "$P")" "deep" "fenced examples, prose and a line naming no tier are passed over"
P=$(plan d.md '# D\n\nNo tier here, and a review: of sorts.\n')
eq "$(plan_review "$P")" "" "a plan that names no tier has none"
eq "$(plan_budget "$P")" "" "nor a budget"

echo "== pq add writes them into the header, and says so ==" >&2
P=$(plan e.md '# E\n\nReview: visual\nBudget: 120 app lines\n')
out=$(REPO=$REPO add_new "$P" 2>&1)
D=$(queue_ordered new | tail -1)
eq "$(hdr "$D/plan.md" review)" "visual" "review: in the header"
eq "$(hdr "$D/plan.md" budget)" "120" "budget: in the header"
has "$out" "review: visual, budget 120 app lines" "the add says what it read"
P=$(plan f.md '# F\n\nJust do it.\n')
out=$(REPO=$REPO add_new "$P" 2>&1)
D=$(queue_ordered new | tail -1)
eq "$(hdr "$D/plan.md" review)" "none" "review: none for a plan that names no tier"
grep -q '^budget:' "$D/plan.md" && bad "no budget: key either" || ok
has "$out" "names no Review: tier - its pull request will be labelled for a deep review" "and the add warns that it will be deep"
rm -rf "$PQ_HOME/new"

echo "== tier_of: the plan's tier, raised and never lowered ==" >&2
eq "$(tier_of visual "" "" 120 0 0)" "visual	0	as planned, 120 app lines" "a visual plan that stayed visual"
eq "$(tier_of skim 250 "" 233 0 0)" "skim	0	as planned, 233 of 250 budgeted app lines" "against its budget"
eq "$(tier_of "" "" "" 90 0 0)" "deep	0	no tier in the plan, 90 app lines" "no tier is deep"
eq "$(tier_of skim "" "" 165 1 0)" "deep	0	planned skim, 1 migration, 165 app lines" "a migration makes it deep"
eq "$(tier_of visual "" "" 184 5 0)" "deep	0	planned visual, 5 migrations, 184 app lines" "five of them"
eq "$(tier_of visual "" yes 50 0 0)" "deep	0	planned visual, security review, 50 app lines" "so does a security review"
eq "$(tier_of visual "" "" 80 0 2)" "skim	0	planned visual, 2 open review threads, 80 app lines" "declined findings make visual at least skim"
eq "$(tier_of visual "" "" 80 0 1)" "skim	0	planned visual, 1 open review thread, 80 app lines" "one of them"
eq "$(tier_of deep "" "" 80 0 3)" "deep	0	as planned, 3 open review threads, 80 app lines" "and never lower a deep one"
eq "$(tier_of visual 300 "" 512 0 0)" "skim	1	planned visual, 512 app lines - over the 400 cap" "oversize: at least skim, and flagged"
eq "$(tier_of skim "" "" 400 0 0)" "skim	0	as planned, 400 app lines" "the cap itself is not over it"

echo "== the files of a pull request: app lines and migrations ==" >&2
# Two pages, as gh api --paginate prints them: one JSON array after another.
cat > "$FILES" <<'EOF'
[{"filename":"app/models/season.rb","additions":100,"status":"added"},
 {"filename":"spec/models/season_spec.rb","additions":300,"status":"added"},
 {"filename":"db/migrate/20261030_create_seasons.rb","additions":20,"status":"added"},
 {"filename":"db/schema.rb","additions":40,"status":"modified"},
 {"filename":"db/redshift_schema.rb","additions":5,"status":"modified"},
 {"filename":"Gemfile.lock","additions":9,"status":"modified"}]
[{"filename":"app/javascript/season.test.js","additions":70,"status":"added"},
 {"filename":"app/javascript/season_controller.js","additions":30,"status":"added"},
 {"filename":"spec/services/migration/import_spec.rb","additions":11,"status":"added"},
 {"filename":"app/services/migration/import.rb","additions":12,"status":"added"},
 {"filename":"db/migrate/20250101_old.rb","additions":0,"status":"removed"},
 {"filename":"yarn.lock","additions":50,"status":"modified"},
 {"filename":"test/fixtures/x.yml","additions":4,"status":"added"}]
EOF
eq "$(tier_files "$REPO" 42)" "162	1" "tests, schema dumps and lockfiles left out; a removed migration and app/services/migration/ are not migrations"

echo "== a ready pull request is labelled, and its description gets the line ==" >&2
reset_caches() { PR_CACHE="$PQ_HOME/.test.pr"; PR_ANS="$PQ_HOME/.test.ans"; : > "$PR_CACHE"; : > "$PR_ANS"; }
cache_row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$PR_CACHE"; }   # repo branch num state draft base merge head
reset_logs() { : > "$GH_LOG"; rm -f "$STUBBIN/.gh-down" "$STUBBIN/.threads-down" "$STUBBIN/.labels-missing" "$STUBBIN/.edited"; }
threads() {                             # open outdated resolved
  jq -n --argjson o "$1" --argjson od "$2" --argjson r "$3" \
    '{data:{repository:{pullRequest:{reviewThreads:{
       nodes: ([range($o)  | {isResolved:false, isOutdated:false}]
             + [range($od) | {isResolved:false, isOutdated:true}]
             + [range($r)  | {isResolved:true,  isOutdated:false}]),
       pageInfo:{hasNextPage:false, endCursor:null}}}}}}' > "$THREADS"
}
mk_ready() {                            # prio slug [header lines] -> task_dir, its gate over
  local d
  d="$PQ_HOME/done/$(printf '%014d' $(( 20260101000000 + 10#$1 )))-$2"
  mkdir -p "$d"
  printf -- '---\nrepo:     %s\nbranch:   tom/%s\n%bmodel:    sonnet\neffort:   xhigh\nintent:   t\nadded:    2026-01-01T00:00:00Z\n---\n\nplan\n' \
    "$REPO" "$2" "${3:-}" > "$d/plan.md"
  st_set "$d" PQ_PR 42; st_set "$d" PQ_REVIEW ready
  printf '%s' "$d"
}
labels() { grep -- '--add-label' "$GH_LOG" | tail -1; }

echo "== a task from before tiers is never labelled ==" >&2
reset_caches; reset_logs
D=$(mk_ready 9 legacy)
cache_row "$REPO" tom/legacy 42 OPEN "" master "" sha9
threads 0 0 0
out=$(tier_task "$D" 0 2>&1)
eq "$(st "$D" PQ_TIER)" "" "no review: header - no tier worked out"
[ -s "$GH_LOG" ] && bad "and no call to the forge at all (got: $(cat "$GH_LOG"))" || ok

echo "== review: none is a plan with no tier ==" >&2
eq "$(tier_of none "" "" 90 0 0)" "deep	0	no tier in the plan, 90 app lines" "none reads as no tier"

reset_caches; reset_logs
D=$(mk_ready 1 seasons 'review:   skim\nbudget:   200\n')
cache_row "$REPO" tom/seasons 42 OPEN "" master "" sha1
threads 0 4 6
printf 'Seasons get a model.\n\n## Needs you\n\nNothing\n' > "$BODY"
out=$(tier_task "$D" 0 2>&1)
eq "$(st "$D" PQ_TIER)" "deep" "a migration in the diff makes the skim plan deep"
eq "$(tier_why "$D")" "planned skim, 1 migration, 162 of 200 budgeted app lines" "with why, kept beside state.env"
grep -q 'TIER_WHY' "$D/state.env" && bad "prose never goes into state.env, which is sourced" || ok
eq "$(st "$D" PQ_TIER_HEAD)" "sha1" "and the head it was worked out for"
eq "$(st "$D" PQ_TIER_LINES)" "162" "the app lines are kept"
has "$out" "seasons: #42 is a deep review - planned skim, 1 migration" "the tick says it"
has "$(labels)" "--add-label review: deep" "the deep label is added"
has "$(labels)" "--remove-label review: skim,review: visual,oversize" "and every other tier's, and oversize, removed"
E=$(cat "$STUBBIN/.edited")
eq "$(head -1 <<<"$E")" "**Review: deep** - planned skim, 1 migration, 162 of 200 budgeted app lines <!-- pq:tier -->" "the line goes first, bold tier then why, the marker trailing so the bold renders"
eq "$(sed -n 2p <<<"$E")" "" "a blank line after it"
eq "$(sed -n 3p <<<"$E")" "Seasons get a model." "then the description as it was"
has "$E" "## Needs you" "every section kept"

echo "== the same head again costs no call ==" >&2
reset_logs
tier_task "$D" 0 >/dev/null 2>&1
eq "$(wc -l < "$GH_LOG" | tr -d ' ')" "0" "nothing asked of gh while the head is the one labelled"

echo "== a moved head is worked out again; the line is replaced, not repeated ==" >&2
reset_caches; reset_logs
cache_row "$REPO" tom/seasons 42 OPEN "" master "" sha2
printf '[{"filename":"app/models/season.rb","additions":100,"status":"added"}]\n' > "$FILES"
threads 0 0 0
out=$(tier_task "$D" 0 2>&1)
eq "$(st "$D" PQ_TIER)" "skim" "the migration is gone, so it is skim as planned"
eq "$(st "$D" PQ_TIER_HEAD)" "sha2" "worked out for the new head"
has "$(labels)" "--add-label review: skim" "the label follows"
has "$(labels)" "--remove-label review: deep,review: visual,oversize" "the stale deep one removed"
E=$(cat "$STUBBIN/.edited")
eq "$(grep -c 'pq:tier' <<<"$E")" "1" "one tier line, the old one replaced"
eq "$(head -1 <<<"$E")" "**Review: skim** - as planned, 100 of 200 budgeted app lines <!-- pq:tier -->" "the new line on top"
eq "$(sed -n 3p <<<"$E")" "Seasons get a model." "the description below it untouched"
has "$out" "is a skim review" "a changed tier is said"

echo "== an unchanged description is not rewritten ==" >&2
reset_caches; reset_logs
cache_row "$REPO" tom/seasons 42 OPEN "" master "" sha3
out=$(tier_task "$D" 0 2>&1)
grep -q -- '--body-file' "$GH_LOG" && bad "the same line is not written again" || ok
eq "$out" "" "and the same tier is not announced again"

echo "== oversize, and declined findings, on a visual plan ==" >&2
reset_caches; reset_logs
D2=$(mk_ready 2 inbox 'review:   visual\n')
cache_row "$REPO" tom/inbox 42 OPEN "" master "" sha9
printf '[{"filename":"app/x.rb","additions":1086,"status":"added"},{"filename":"spec/x_spec.rb","additions":1324,"status":"added"}]\n' > "$FILES"
threads 4 4 0
printf 'Inbox.\n' > "$BODY"
tier_task "$D2" 0 >/dev/null 2>&1
eq "$(st "$D2" PQ_TIER)" "skim" "visual raised to skim"
eq "$(st "$D2" PQ_TIER_OVER)" "1" "and over the cap"
has "$(labels)" "--add-label review: skim,oversize" "oversize labelled too"
eq "$(head -1 "$STUBBIN/.edited")" "**Review: skim** - planned visual, 4 open review threads, 1086 app lines - over the 400 cap <!-- pq:tier -->" "outdated threads are not counted as declined"
eq "$(tier_cell "$D2")" "skim oversize" "the pq ls word"

echo "== the labels are created the first time a repo lacks them ==" >&2
reset_caches; reset_logs
D3=$(mk_ready 3 fresh 'review:   visual\n')
cache_row "$REPO" tom/fresh 42 OPEN "" master "" shaf
printf '[{"filename":"app/views/x.html.erb","additions":30,"status":"added"}]\n' > "$FILES"
threads 0 0 0
touch "$STUBBIN/.labels-missing"
tier_task "$D3" 0 >/dev/null 2>&1
eq "$(grep -c '^label create' "$GH_LOG")" "4" "all four created"
has "$(grep '^label create' "$GH_LOG" | head -1)" "--force" "with --force, so an existing one is updated rather than refused"
eq "$(grep -c -- '--add-label review: visual' "$GH_LOG")" "2" "and the edit tried again"
eq "$(st "$D3" PQ_TIER)" "visual" "visual stays visual"

echo "== a failure is said once and tried again next tick ==" >&2
reset_caches; reset_logs
D4=$(mk_ready 4 flaky 'review:   skim\n')
cache_row "$REPO" tom/flaky 42 OPEN "" master "" shax
touch "$STUBBIN/.threads-down"
out=$(tier_task "$D4" 0 2>&1)
has "$out" "could not read the review threads of #42 for its review tier - trying again next tick" "said"
eq "$(st "$D4" PQ_TIER)" "" "nothing recorded"
out=$(tier_task "$D4" 0 2>&1)
eq "$out" "" "and not said twice"
rm -f "$STUBBIN/.threads-down"
tier_task "$D4" 0 >/dev/null 2>&1
eq "$(st "$D4" PQ_TIER)" "skim" "labelled once gh answers"
eq "$(st "$D4" PQ_TIER_ERR)" "" "and the failure forgotten"

echo "== not before the gate is over, not on a draft, not once settled ==" >&2
reset_caches; reset_logs
D5=$(mk_ready 5 notyet 'review:   skim\n')
cache_row "$REPO" tom/notyet 42 OPEN "" master "" shan
st_set "$D5" PQ_REVIEW prompted
tier_task "$D5" 0 >/dev/null 2>&1
eq "$(wc -l < "$GH_LOG" | tr -d ' ')" "0" "a gate still in flight is not labelled"
st_set "$D5" PQ_REVIEW ready
reset_caches; cache_row "$REPO" tom/notyet 42 OPEN draft master "" shan
tier_task "$D5" 0 >/dev/null 2>&1
eq "$(wc -l < "$GH_LOG" | tr -d ' ')" "0" "nor a draft"
reset_caches; cache_row "$REPO" tom/notyet 42 MERGED "" master m1 shan
tier_task "$D5" 0 >/dev/null 2>&1
eq "$(wc -l < "$GH_LOG" | tr -d ' ')" "0" "nor a merged one"
reset_caches; cache_row "$REPO" tom/notyet 42 OPEN "" master "" shan
st_set "$D5" PQ_REVIEW lapsed
out=$(tier_task "$D5" 1 2>&1)
has "$out" "would label notyet's #42 with its review tier" "a lapsed gate ends like any other, and a dry run only says"
eq "$(wc -l < "$GH_LOG" | tr -d ' ')" "0" "a dry run asks gh nothing"

echo "== pq ls says the tier where it said open ==" >&2
reset_caches
cache_row "$REPO" tom/seasons 42 OPEN "" master "" sha3
cache_row "$REPO" tom/inbox 42 OPEN "" master "" sha9
cache_row "$REPO" tom/notyet 42 OPEN draft master "" shan
pidx_load() { PIDX=""; PIDX_OK=1; }
LS=$(cmd_ls 2>&1)
has "$(grep seasons <<<"$LS")" "#42 skim" "the tier in the PR column"
has "$(grep inbox <<<"$LS")" "#42 skim oversize" "with oversize"
has "$(grep notyet <<<"$LS")" "#42 draft" "a draft still reads draft"
J=$(cmd_ls --json 2>/dev/null)
eq "$(jq -r '.[] | select(.task | endswith("seasons")) | [.tier, .app_lines, .plan_review, .budget, .oversize, .tier_why] | @tsv' <<<"$J")" \
   "skim	100	skim	200	false	as planned, 100 of 200 budgeted app lines" "and in --json"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
