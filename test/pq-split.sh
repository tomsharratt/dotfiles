#!/usr/bin/env bash
# test/pq-split.sh - `pq add --split` and everything under `do_split`.
#
# Same conventions as test/pq-after.sh: plain bash, no framework, a temp
# PQ_HOME exported BEFORE sourcing pq, a throwaway git repo with
# refs/remotes/origin/HEAD faked by hand, ok/bad/eq, and a PATH-stubbed
# `claude` and `gh` so nothing here ever reaches the network.
#
# Most cases drive `do_split` through `--split-dir` against a split
# directory built by hand - validation runs before any naming, so those
# never need the stub at all. Only the true end-to-end cases (a fresh
# `--split`, and the collision retry, which needs the namer) exercise the
# stub's `opus` and `haiku` branches.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PQ_HOME=$(mktemp -d)
export PQ_HOME

STUBBIN=$(mktemp -d)
SPLIT_COUNTER="$PQ_HOME/.opus-calls"
export SPLIT_COUNTER
: > "$SPLIT_COUNTER"

# Dispatches on --model. `opus` writes a fixture part set + graph.tsv into
# cwd, keyed off ./source.md's marker line, and counts its own calls so a
# test can assert it was (or was not) re-entered. `haiku` reads the part on
# stdin and returns that part's {"branch":..,"intent":..}, keyed off its own
# marker line - two marker pairs additionally look at argv for the avoid-list
# sentence `name_plan` appends on retry, to drive the collision path.
cat > "$STUBBIN/claude" <<'STUBEOF'
#!/usr/bin/env bash
all_args="$*"
model=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) model=$2; shift 2 ;;
    *) shift ;;
  esac
done

case "$model" in
  opus)
    [ -n "${SPLIT_COUNTER:-}" ] && printf 'x\n' >> "$SPLIT_COUNTER"
    src=$(cat source.md)
    case "$src" in
      *"FIXTURE: diamond"*)
        printf 'MARKER: schema\nAdd the columns.\n'          > 01-schema.md
        printf 'MARKER: parser\nParse the mentions.\n'       > 02-parser.md
        printf 'MARKER: notify\nFan out notifications.\n'    > 03-notify.md
        printf 'MARKER: admin\nAdd the admin UI.\n'           > 04-admin.md
        {
          printf '01-schema.md\t\n'
          printf '02-parser.md\t01-schema.md\n'
          printf '03-notify.md\t01-schema.md\n'
          printf '04-admin.md\t02-parser.md,03-notify.md\n'
        } > graph.tsv
        ;;
      *"FIXTURE: solo"*)
        printf 'MARKER: solo\nDo the one thing.\n' > 01-solo.md
        printf '01-solo.md\t\n' > graph.tsv
        ;;
    esac
    printf '{"is_error":false,"total_cost_usd":0.42,"duration_ms":12345,"permission_denials":[]}\n'
    ;;
  haiku)
    content=$(cat)
    avoid=0
    case "$all_args" in *"already taken"*) avoid=1 ;; esac
    case "$content" in
      *"MARKER: alpha"*)      printf '{"branch":"tom/task-alpha","intent":"Do A."}\n' ;;
      *"MARKER: bravo"*)      printf '{"branch":"tom/task-bravo","intent":"Do B."}\n' ;;
      *"MARKER: schema"*)     printf '{"branch":"tom/add-schema-columns","intent":"Add the schema columns."}\n' ;;
      *"MARKER: parser"*)     printf '{"branch":"tom/parse-mentions","intent":"Parse the mentions."}\n' ;;
      *"MARKER: notify"*)     printf '{"branch":"tom/notify-fanout","intent":"Fan out notifications."}\n' ;;
      *"MARKER: admin"*)      printf '{"branch":"tom/admin-ui","intent":"Add the admin UI."}\n' ;;
      *"MARKER: solo"*)       printf '{"branch":"tom/do-solo-thing","intent":"Do the solo thing."}\n' ;;
      *"MARKER: collide-a"*)  printf '{"branch":"tom/collide","intent":"Part A."}\n' ;;
      *"MARKER: collide-b"*)
        if [ "$avoid" = 1 ]; then printf '{"branch":"tom/collide-2","intent":"Part B."}\n'
        else printf '{"branch":"tom/collide","intent":"Part B."}\n'; fi ;;
      *"MARKER: forever-a"*)  printf '{"branch":"tom/collide-forever","intent":"Part A."}\n' ;;
      *"MARKER: forever-b"*)  printf '{"branch":"tom/collide-forever","intent":"Part B."}\n' ;;
      *) printf '{}\n' ;;
    esac
    ;;
  *) exit 1 ;;
esac
STUBEOF
chmod +x "$STUBBIN/claude"

printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/gh"
chmod +x "$STUBBIN/gh"
export PATH="$STUBBIN:$PATH"

# shellcheck source=/dev/null
source "$HERE/../.local/bin/pq"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() {                                   # got want msg
  [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"
}

cleanup() { rm -rf "$PQ_HOME" "$STUBBIN" "${REPO:-}" "${REPO2:-}"; }
trap cleanup EXIT

# ── two throwaway git repos ─────────────────────────────────────────────────
REPO=$(mktemp -d)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$REPO/.git/refs/remotes/origin"
git -C "$REPO" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master

REPO2=$(mktemp -d)
git init -q -b master "$REPO2"
git -C "$REPO2" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$REPO2/.git/refs/remotes/origin"
git -C "$REPO2" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO2" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master

reset_tasks() {
  rm -rf "$PQ_HOME/queue" "$PQ_HOME/hold" "$PQ_HOME/running" "$PQ_HOME/done"
  mkdir -p "$PQ_HOME/queue" "$PQ_HOME/hold" "$PQ_HOME/running" "$PQ_HOME/done"
}

# A split directory built by hand: source.md + repo file, so the validation-
# only cases never need to go anywhere near the `claude` stub.
new_split_dir() {                        # name -> prints the dir path
  local sd="$PQ_HOME/splits/$1"
  rm -rf "$sd"; mkdir -p "$sd"
  printf '# source plan\n\nSomething.\n' > "$sd/source.md"
  printf '%s\n' "$REPO" > "$sd/repo"
  printf '%s' "$sd"
}

queue_count() { ls -d "$PQ_HOME/queue"/*/ 2>/dev/null | wc -l | tr -d ' '; }

echo "== happy path: a four-part diamond, fresh --split ==" >&2
reset_tasks
PLAN="$PQ_HOME/.diamond-plan.md"
printf 'FIXTURE: diamond\n\nA whole feature.\n' > "$PLAN"
out=$(main add "$PLAN" --repo "$REPO" --split -y 2>"$PQ_HOME/.err")
rc=$?
err=$(cat "$PQ_HOME/.err")
[ "$rc" -eq 0 ] && ok || bad "happy path should succeed (rc=$rc): $err"
eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "4" "four slugs on stdout"
eq "$(printf '%s\n' "$out" | sed -n 1p)" "add-schema-columns" "part 1's slug first"
eq "$(printf '%s\n' "$out" | sed -n 2p)" "parse-mentions"     "part 2's slug second"
eq "$(printf '%s\n' "$out" | sed -n 3p)" "notify-fanout"      "part 3's slug third"
eq "$(printf '%s\n' "$out" | sed -n 4p)" "admin-ui"           "part 4's slug fourth"
eq "$(queue_count)" "4" "all four parts landed in queue/"

t_schema=$(find_task add-schema-columns); t_parser=$(find_task parse-mentions)
t_notify=$(find_task notify-fanout);      t_admin=$(find_task admin-ui)
[ -f "$t_schema/after" ] && bad "the root part must have no after file" || ok
eq "$(cat "$t_parser/after" | cut -f1)" "add-schema-columns" "parser waits on schema"
eq "$(cat "$t_notify/after" | cut -f1)" "add-schema-columns" "notify waits on schema"
after_admin=$(cut -f1 "$t_admin/after" | tr '\n' ',')
case "$after_admin" in
  parse-mentions,notify-fanout,|notify-fanout,parse-mentions,) ok ;;
  *) bad "admin should wait on both parser and notify (got '$after_admin')" ;;
esac

p1=$(prio_of "$t_schema"); p2=$(prio_of "$t_parser"); p3=$(prio_of "$t_notify"); p4=$(prio_of "$t_admin")
[ "$p1" -lt "$p2" ] && [ "$p2" -le "$p3" ] && [ "$p3" -lt "$p4" ] && ok \
  || bad "priorities should ascend in topological order (got $p1 $p2 $p3 $p4)"

case "$err" in *"3 waves"*) ok ;; *) bad "the diamond should report 3 waves (got: $err)" ;; esac
case "$err" in *'$0.42'*) ok ;; *) bad "the cost report should surface total_cost_usd (got: $err)" ;; esac

echo "== pq tick --dry-run actually gates on the diamond's --after wiring ==" >&2
tick_out=$(tick_body 4 1 2>&1 1>/dev/null)
case "$tick_out" in
  *"would dispatch $(slug_of "$t_schema")"*) ok ;;
  *) bad "tick --dry-run should dispatch the unblocked root part (got: $tick_out)" ;;
esac
case "$tick_out" in
  *"would skip $(slug_of "$t_parser")"*) ok ;;
  *) bad "tick --dry-run should skip parser, which waits on schema (got: $tick_out)" ;;
esac
case "$tick_out" in
  *"would skip $(slug_of "$t_notify")"*) ok ;;
  *) bad "tick --dry-run should skip notify, which waits on schema (got: $tick_out)" ;;
esac
case "$tick_out" in
  *"would skip $(slug_of "$t_admin")"*) ok ;;
  *) bad "tick --dry-run should skip admin, which waits on both parser and notify (got: $tick_out)" ;;
esac

echo "== --split --json emits one object per part with resolved blockers ==" >&2
reset_tasks
SD=$(new_split_dir diamond-json)
printf 'MARKER: schema\nAdd the columns.\n'          > "$SD/01-schema.md"
printf 'MARKER: parser\nParse the mentions.\n'       > "$SD/02-parser.md"
printf 'MARKER: notify\nFan out notifications.\n'    > "$SD/03-notify.md"
printf 'MARKER: admin\nAdd the admin UI.\n'           > "$SD/04-admin.md"
{
  printf '01-schema.md\t\n'
  printf '02-parser.md\t01-schema.md\n'
  printf '03-notify.md\t01-schema.md\n'
  printf '04-admin.md\t02-parser.md,03-notify.md\n'
} > "$SD/graph.tsv"
json_out=$(main add --split-dir "$SD" --repo "$REPO" -y --json 2>"$PQ_HOME/.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "--split-dir --json should succeed: $(cat "$PQ_HOME/.err")"
if printf '%s' "$json_out" | jq -e 'length == 4' >/dev/null 2>&1; then ok
else bad "should emit exactly 4 objects (got '$json_out')"; fi
if printf '%s' "$json_out" | jq -e '.[1].after | length == 1' >/dev/null 2>&1; then ok
else bad "part 2's object should carry its one resolved blocker"; fi
if printf '%s' "$json_out" | jq -e '.[3].after | length == 2' >/dev/null 2>&1; then ok
else bad "part 4's object should carry its two resolved blockers"; fi

echo "== declining queues nothing; --split-dir then resumes without a second opus call ==" >&2
reset_tasks
: > "$SPLIT_COUNTER"
PLAN="$PQ_HOME/.solo-plan.md"
printf 'FIXTURE: solo\n\nOne small thing.\n' > "$PLAN"
declined_out=$(main add "$PLAN" --repo "$REPO" --split < /dev/null 2>"$PQ_HOME/.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "declining should still exit 0: $(cat "$PQ_HOME/.err")"
eq "$declined_out" "" "declining should print nothing to stdout"
eq "$(queue_count)" "0" "declining should queue nothing"
eq "$(wc -l < "$SPLIT_COUNTER" | tr -d ' ')" "1" "opus should have run exactly once so far"
# Regression: cmd_add now always computes a real default priority before
# do_split runs (so split_queue's own ascending-by-10 logic has a real
# starting point) - the printed resume hint must not turn that computed
# default into an explicit --priority the user never asked for.
case "$(cat "$PQ_HOME/.err")" in
  *"--priority"*) bad "the resume hint must not fabricate --priority when none was given" ;;
  *) ok ;;
esac

SD=$(ls -d "$PQ_HOME/splits"/*solo*/ | head -1); SD=${SD%/}
resumed_out=$(main add --split-dir "$SD" --repo "$REPO" -y 2>"$PQ_HOME/.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "resuming via --split-dir should succeed: $(cat "$PQ_HOME/.err")"
eq "$resumed_out" "do-solo-thing" "resuming should queue the one part"
eq "$(wc -l < "$SPLIT_COUNTER" | tr -d ' ')" "1" "opus must NOT be re-entered on --split-dir"

echo "== a single-part split queues exactly one task with no after file ==" >&2
t=$(find_task do-solo-thing)
[ -f "$t/after" ] && bad "a single part has nothing to wait on - no after file" || ok

echo "== the resume hint DOES carry an explicit --priority when one was given ==" >&2
reset_tasks
: > "$SPLIT_COUNTER"
PLAN2="$PQ_HOME/.solo-plan2.md"
printf 'FIXTURE: solo\n\nOne small thing.\n' > "$PLAN2"
main add "$PLAN2" --repo "$REPO" --split --priority 500 < /dev/null 2>"$PQ_HOME/.err" >/dev/null
case "$(cat "$PQ_HOME/.err")" in
  *"--priority 500"*) ok ;;
  *) bad "an explicitly-given --priority should survive into the resume hint (got: $(cat "$PQ_HOME/.err"))" ;;
esac

echo "== a graph.tsv with no trailing tab and no final newline still gates as 'no deps' ==" >&2
reset_tasks
SD=$(new_split_dir no-newline)
printf 'MARKER: solo\nDo the one thing.\n' > "$SD/01-solo.md"
printf '%s' "01-solo.md" > "$SD/graph.tsv"        # no tab, no newline at all
out=$(main add --split-dir "$SD" --repo "$REPO" -y 2>"$PQ_HOME/.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "a tab-less, newline-less graph.tsv should still queue: $(cat "$PQ_HOME/.err")"
eq "$out" "do-solo-thing" "it should still queue the one part"
t=$(find_task do-solo-thing)
[ -f "$t/after" ] && bad "still no after file - it had no dependency" || ok

echo "== a space after the comma in graph.tsv's deps field must not break the slug lookup (regression) ==" >&2
reset_tasks
SD=$(new_split_dir space-after-comma)
printf 'MARKER: schema\nAdd columns.\n' > "$SD/01-schema.md"
printf 'MARKER: parser\nParse.\n' > "$SD/02-parser.md"
printf '01-schema.md\t\n02-parser.md\t 01-schema.md\n' > "$SD/graph.tsv"     # note the space before 01-schema.md
out=$(main add --split-dir "$SD" --repo "$REPO" -y 2>"$PQ_HOME/.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "a space after the comma must not fail the split: $(cat "$PQ_HOME/.err")"
eq "$(queue_count)" "2" "both parts should have queued despite the stray space"
t_parser2=$(find_task parse-mentions)
eq "$(cut -f1 "$t_parser2/after" 2>/dev/null)" "add-schema-columns" "the blocker slug must not carry a leading space"

echo "== --split and --split-dir together are rejected ==" >&2
reset_tasks
SD=$(new_split_dir split-and-split-dir)
printf 'MARKER: solo\nDo the one thing.\n' > "$SD/01-solo.md"
printf '01-solo.md\t\n' > "$SD/graph.tsv"
if ( main add --split-dir "$SD" --repo "$REPO" --split -y ) >/dev/null 2>&1; then
  bad "--split and --split-dir together should be rejected"
else
  ok
fi
eq "$(queue_count)" "0" "--split + --split-dir: nothing queued"

echo "== --json alone still prompts; -y is the only thing that skips it ==" >&2
reset_tasks
SD=$(new_split_dir json-prompts-yes)
printf 'MARKER: solo\nDo the one thing.\n' > "$SD/01-solo.md"
printf '01-solo.md\t\n' > "$SD/graph.tsv"
accepted=$(main add --split-dir "$SD" --repo "$REPO" --json <<<"y" 2>"$PQ_HOME/.err")
[ -n "$accepted" ] && printf '%s' "$accepted" | jq -e 'length == 1' >/dev/null 2>&1 && ok \
  || bad "--json with 'y' piped in should still queue (got '$accepted')"

reset_tasks
SD=$(new_split_dir json-prompts-no)
printf 'MARKER: solo\nDo the one thing.\n' > "$SD/01-solo.md"
printf '01-solo.md\t\n' > "$SD/graph.tsv"
declined=$(main add --split-dir "$SD" --repo "$REPO" --json < /dev/null 2>"$PQ_HOME/.err")
eq "$declined" "" "--json with nothing piped in should decline, not silently queue"
eq "$(queue_count)" "0" "a declined --json split queues nothing"

echo "== --split with --branch is rejected ==" >&2
reset_tasks
before_splits=$(ls -d "$PQ_HOME/splits"/*/ 2>/dev/null | wc -l | tr -d ' ')
if ( main add "$PLAN" --repo "$REPO" --split --branch tom/whatever -y ) >/dev/null 2>"$PQ_HOME/.err"; then
  bad "--split with --branch should be rejected"
else
  ok
fi
after_splits=$(ls -d "$PQ_HOME/splits"/*/ 2>/dev/null | wc -l | tr -d ' ')
eq "$after_splits" "$before_splits" "a rejected --split --branch should not create a split directory"

echo "== sibling branch collision: retry with the avoid-list resolves it ==" >&2
reset_tasks
SD=$(new_split_dir collide-resolves)
printf 'MARKER: collide-a\nDo A.\n' > "$SD/01-alpha.md"
printf 'MARKER: collide-b\nDo B.\n' > "$SD/02-beta.md"
{ printf '01-alpha.md\t\n02-beta.md\t\n'; } > "$SD/graph.tsv"
out=$(main add --split-dir "$SD" --repo "$REPO" -y 2>"$PQ_HOME/.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "a resolvable collision should still succeed: $(cat "$PQ_HOME/.err")"
eq "$(queue_count)" "2" "both parts should have queued after the retry"
case "$(cat "$PQ_HOME/.err")" in *"collides"*"retrying"*) ok ;; *) bad "should have warned about the collision and the retry"; esac

echo "== sibling branch collision: a stub that collides twice dies with nothing queued ==" >&2
reset_tasks
SD=$(new_split_dir collide-forever)
printf 'MARKER: forever-a\nDo A.\n' > "$SD/01-x.md"
printf 'MARKER: forever-b\nDo B.\n' > "$SD/02-y.md"
{ printf '01-x.md\t\n02-y.md\t\n'; } > "$SD/graph.tsv"
if ( main add --split-dir "$SD" --repo "$REPO" -y ) >/dev/null 2>"$PQ_HOME/.err"; then
  bad "an unresolvable collision should fail the whole split"
else
  ok
fi
eq "$(queue_count)" "0" "an unresolvable collision must queue NEITHER part"

echo "== validation failures: nothing is ever queued ==" >&2

reset_tasks
SD=$(new_split_dir val-unknown-dep)
printf 'MARKER: alpha\nA.\n' > "$SD/01-a.md"
printf '01-a.md\t99-nonexistent.md\n' > "$SD/graph.tsv"
( main add --split-dir "$SD" --repo "$REPO" -y ) >/dev/null 2>&1 && bad "an unknown dependency should be rejected" || ok
eq "$(queue_count)" "0" "unknown dependency: nothing queued"

reset_tasks
SD=$(new_split_dir val-forgotten-file)
printf 'MARKER: alpha\nA.\n' > "$SD/01-a.md"
printf 'MARKER: bravo\nB.\n' > "$SD/02-b.md"
printf '01-a.md\t\n' > "$SD/graph.tsv"          # 02-b.md exists but is never listed
( main add --split-dir "$SD" --repo "$REPO" -y ) >/dev/null 2>&1 && bad "a *.md missing from graph.tsv should be rejected" || ok
eq "$(queue_count)" "0" "forgotten file: nothing queued"

reset_tasks
SD=$(new_split_dir val-bad-filename)
printf 'MARKER: alpha\nA.\n' > "$SD/weird_name.md"
printf 'weird_name.md\t\n' > "$SD/graph.tsv"
( main add --split-dir "$SD" --repo "$REPO" -y ) >/dev/null 2>&1 && bad "a badly-formed part filename should be rejected" || ok
eq "$(queue_count)" "0" "bad filename: nothing queued"

reset_tasks
SD=$(new_split_dir val-duplicate-part)
printf 'MARKER: alpha\nA.\n' > "$SD/01-a.md"
printf '01-a.md\t\n01-a.md\t\n' > "$SD/graph.tsv"           # listed twice, exists once
dup_err=$( ( main add --split-dir "$SD" --repo "$REPO" -y ) 2>&1 >/dev/null )
case "$dup_err" in
  *"more than once"*) ok ;;
  *) bad "a duplicated graph.tsv line should be diagnosed as a duplicate, not a missing file (got '$dup_err')" ;;
esac
eq "$(queue_count)" "0" "duplicate part: nothing queued"

reset_tasks
SD=$(new_split_dir val-cycle)
printf 'MARKER: alpha\nA.\n' > "$SD/01-a.md"
printf 'MARKER: bravo\nB.\n' > "$SD/02-b.md"
{ printf '01-a.md\t02-b.md\n02-b.md\t01-a.md\n'; } > "$SD/graph.tsv"
( main add --split-dir "$SD" --repo "$REPO" -y ) >/dev/null 2>&1 && bad "a cycle should be rejected" || ok
eq "$(queue_count)" "0" "cycle: nothing queued"

reset_tasks
SD=$(new_split_dir val-sibling-ref)
printf 'MARKER: alpha\nThis references 02-b.md somewhere in its text.\n' > "$SD/01-a.md"
printf 'MARKER: bravo\nNothing special.\n' > "$SD/02-b.md"
printf '01-a.md\t\n02-b.md\t\n' > "$SD/graph.tsv"
( main add --split-dir "$SD" --repo "$REPO" -y ) >/dev/null 2>&1 && bad "a part naming a sibling should be rejected" || ok
eq "$(queue_count)" "0" "sibling reference: nothing queued"

reset_tasks
SD=$(new_split_dir val-dash-fence)
printf -- '---\nMARKER: alpha\nA.\n' > "$SD/01-a.md"
printf '01-a.md\t\n' > "$SD/graph.tsv"
( main add --split-dir "$SD" --repo "$REPO" -y ) >/dev/null 2>&1 && bad "a part starting with '---' should be rejected" || ok
eq "$(queue_count)" "0" "dash fence: nothing queued"

reset_tasks
SD=$(new_split_dir val-zero-parts)
: > "$SD/graph.tsv"
( main add --split-dir "$SD" --repo "$REPO" -y ) >/dev/null 2>&1 && bad "zero parts should be rejected" || ok
eq "$(queue_count)" "0" "zero parts: nothing queued"

reset_tasks
SD=$(new_split_dir val-thirteen-parts)
for i in 01 02 03 04 05 06 07 08 09 10 11 12 13; do printf '%s-p.md\t\n' "$i"; done > "$SD/graph.tsv"
( main add --split-dir "$SD" --repo "$REPO" -y ) >/dev/null 2>&1 && bad "thirteen parts should be rejected" || ok
eq "$(queue_count)" "0" "thirteen parts: nothing queued"

reset_tasks
SD=$(new_split_dir val-repo-mismatch)
printf 'MARKER: alpha\nA.\n' > "$SD/01-a.md"
printf '01-a.md\t\n' > "$SD/graph.tsv"
printf '%s\n' "$REPO" > "$SD/repo"
# No --repo passed - resolved from cwd, which is REPO2 here, so it disagrees
# with the recorded REPO and must be rejected.
if ( cd "$REPO2" && main add --split-dir "$SD" ) >/dev/null 2>&1; then
  bad "a --split-dir repo mismatch (no --repo override) should be rejected"
else
  ok
fi
eq "$(queue_count)" "0" "repo mismatch: nothing queued"
# Passing --repo explicitly is how you say "yes, I mean it" - same mismatch,
# but now allowed.
reset_tasks
if ( cd "$REPO2" && main add --split-dir "$SD" --repo "$REPO2" -y ) >/dev/null 2>&1; then ok
else bad "an EXPLICIT --repo should override the mismatch guard"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
