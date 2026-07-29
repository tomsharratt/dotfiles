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

# The default scan root for `repo_candidates`: permanently empty, so every
# case below that does not deliberately opt into multi-repo scanning stays
# single-repo regardless of what else happens to be sitting in $TMPDIR.
PQ_REPOS_DIR=$(mktemp -d)
export PQ_REPOS_DIR

STUBBIN=$(mktemp -d)
SPLIT_COUNTER="$PQ_HOME/.opus-calls"
export SPLIT_COUNTER
: > "$SPLIT_COUNTER"

# Every `claude` invocation, one line of model<TAB>args, when CALL_LOG is set -
# a test asserts against this rather than the stub's return value when what
# matters is what the CALLER was told (an --add-dir per candidate, the repo
# hint in a naming prompt), not what it got back.
CALL_LOG="$PQ_HOME/.call-log"
export CALL_LOG
: > "$CALL_LOG"

# Dispatches on --model. `opus` writes a fixture part set + graph.tsv into
# cwd, keyed off ./source.md's marker line, and counts its own calls so a
# test can assert it was (or was not) re-entered. `haiku` reads the part on
# stdin and returns that part's {"branch":..,"intent":..}, keyed off its own
# marker line - two marker pairs additionally look at argv for the avoid-list
# sentence `name_plan` appends on retry, to drive the collision path.
#
# The multirepo fixtures read $REPO2 straight from the environment rather
# than hard-coding a label: a scanned or explicitly-named repo's label is its
# real basename (`repo_candidates`/the explicit `--repo` path both derive it
# that way), and $REPO2 is a fresh `mktemp -d` each run.
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
[ -n "${CALL_LOG:-}" ] && printf '%s\t%s\n' "$model" "$(tr '\n' ' ' <<<"$all_args")" >> "$CALL_LOG"

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
      # The more specific "multirepo-*" fixtures MUST be checked before the
      # bare "FIXTURE: multirepo" pattern below - a `case` pattern match is
      # first-match-wins, and `*"FIXTURE: multirepo"*` is also a substring of
      # "FIXTURE: multirepo-badlabel" and "FIXTURE: multirepo-dirty".
      *"FIXTURE: multirepo-badlabel"*)
        printf 'MARKER: mr-a\nDo the primary part.\n' > 01-mr-a.md
        printf '01-mr-a.md\t\ttotally-not-a-repo\n' > graph.tsv
        ;;
      *"FIXTURE: multirepo-dirty"*)
        label2=$(basename "$REPO2")
        printf 'MARKER: mr-a\nDo the primary part.\n'  > 01-mr-a.md
        printf 'MARKER: mr-b\nDo the other part.\n'    > 02-mr-b.md
        {
          printf '01-mr-a.md\t\n'
          printf '02-mr-b.md\t\t%s\n' "$label2"
        } > graph.tsv
        # Left behind on purpose: the splitter was only meant to read here.
        touch "$REPO2/oops-the-splitter-wrote-here.txt"
        ;;
      *"FIXTURE: multirepo"*)
        label2=$(basename "$REPO2")
        printf 'MARKER: mr-a\nDo the primary part.\n'  > 01-mr-a.md
        printf 'MARKER: mr-b\nDo the other part.\n'    > 02-mr-b.md
        {
          printf '01-mr-a.md\t\n'
          printf '02-mr-b.md\t\t%s\n' "$label2"
        } > graph.tsv
        ;;
      # No-primary/container mode: unlike every fixture above, BOTH parts
      # name their repo explicitly - an empty third field has nothing to
      # fall back to here, so the fixture itself must stay honest about that.
      *"FIXTURE: container"*)
        labela=$(basename "$CONTAINERA")
        labelb=$(basename "$CONTAINERB")
        printf 'MARKER: ctr-a\nDo A.\n' > 01-a.md
        printf 'MARKER: ctr-b\nDo B.\n' > 02-b.md
        {
          printf '01-a.md\t\t%s\n' "$labela"
          printf '02-b.md\t\t%s\n' "$labelb"
        } > graph.tsv
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
      *"MARKER: mr-server"*)  printf '{"branch":"tom/mr-server-thing","intent":"Server part."}\n' ;;
      *"MARKER: mr-client"*)  printf '{"branch":"tom/mr-client-thing","intent":"Client part."}\n' ;;
      *"MARKER: mr-solo2col"*) printf '{"branch":"tom/mr-solo2col-thing","intent":"One repo, one part."}\n' ;;
      *"MARKER: mr-branchcheck"*) printf '{"branch":"tom/mr-branchcheck-thing","intent":"Branch-check part."}\n' ;;
      *"MARKER: mr-a"*)       printf '{"branch":"tom/mr-a-thing","intent":"Part A."}\n' ;;
      *"MARKER: mr-b"*)       printf '{"branch":"tom/mr-b-thing","intent":"Part B."}\n' ;;
      *"MARKER: ctr-a"*)      printf '{"branch":"tom/ctr-a-thing","intent":"A."}\n' ;;
      *"MARKER: ctr-b"*)      printf '{"branch":"tom/ctr-b-thing","intent":"B."}\n' ;;
      *"MARKER: ctr-solo"*)   printf '{"branch":"tom/ctr-solo-thing","intent":"Do the one thing."}\n' ;;
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

cleanup() { rm -rf "$PQ_HOME" "$STUBBIN" "$PQ_REPOS_DIR" "${SIBLINGROOT:-}" "${REPO:-}" "${REPO2:-}" "${CONTAINERROOT:-}"; }
trap cleanup EXIT

# ── two throwaway git repos ─────────────────────────────────────────────────
REPO=$(mktemp -d)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$REPO/.git/refs/remotes/origin"
git -C "$REPO" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master

# REPO2 lives under its own SIBLINGROOT, not under $PQ_REPOS_DIR - so it is
# invisible to the scan by default, and only the cases that mean to test
# discovery point PQ_REPOS_DIR at SIBLINGROOT for that one invocation.
SIBLINGROOT=$(mktemp -d)
REPO2=$(mktemp -d "$SIBLINGROOT/repo2.XXXXXX")
export REPO2
git init -q -b master "$REPO2"
git -C "$REPO2" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$REPO2/.git/refs/remotes/origin"
git -C "$REPO2" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO2" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master

# CONTAINERROOT is itself NOT a git repo - it only holds two checkouts as
# peers, for the container/no-primary discovery mode: cwd (or an explicit
# --repo) naming a directory like this, rather than a repo, is what triggers
# it. Exported so the claude stub's "FIXTURE: container" case (which needs
# each child's real basename, exactly like $REPO2 above) can read them.
CONTAINERROOT=$(mktemp -d)
CONTAINERA=$(mktemp -d "$CONTAINERROOT/childA.XXXXXX")
git init -q -b master "$CONTAINERA"
git -C "$CONTAINERA" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
CONTAINERB=$(mktemp -d "$CONTAINERROOT/childB.XXXXXX")
git init -q -b master "$CONTAINERB"
git -C "$CONTAINERB" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
export CONTAINERA CONTAINERB

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

# The repos-file variant: REPO as the primary, REPO2 under a caller-chosen
# label - so a hand-built multi-repo split dir never needs the splitter stub.
new_split_dir_repos() {                  # name [repo2_label=repo2] -> prints the dir path
  local sd="$PQ_HOME/splits/$1" label=${2:-repo2}
  rm -rf "$sd"; mkdir -p "$sd"
  printf '# source plan\n\nSomething.\n' > "$sd/source.md"
  printf '%s\t%s\n%s\t%s\n' "$(basename "$REPO")" "$REPO" "$label" "$REPO2" > "$sd/repos"
  printf '%s' "$sd"
}

# The no-primary variant: row 1 is the empty-label sentinel do_split writes
# for a container split (see do_split), followed by CONTAINERA and
# CONTAINERB - so a hand-built container split dir never needs the splitter
# stub either.
new_split_dir_container() {              # name -> prints the dir path
  local sd="$PQ_HOME/splits/$1"
  rm -rf "$sd"; mkdir -p "$sd"
  printf '# source plan\n\nSomething.\n' > "$sd/source.md"
  {
    printf '\t%s\n' "$CONTAINERROOT"
    printf '%s\t%s\n' "$(basename "$CONTAINERA")" "$CONTAINERA"
    printf '%s\t%s\n' "$(basename "$CONTAINERB")" "$CONTAINERB"
  } > "$sd/repos"
  printf '%s' "$sd"
}

# The degenerate case: a no-primary split whose container only ever had ONE
# child - multi=0 in practice, but the label is still required (there is
# still no primary), which is exactly what makes this case worth its own
# fixture rather than assuming it behaves like new_split_dir_container's.
new_split_dir_container_one() {          # name -> prints the dir path
  local sd="$PQ_HOME/splits/$1"
  rm -rf "$sd"; mkdir -p "$sd"
  printf '# source plan\n\nSomething.\n' > "$sd/source.md"
  {
    printf '\t%s\n' "$CONTAINERONE"
    printf '%s\t%s\n' "$(basename "$CONTAINERONECHILD")" "$CONTAINERONECHILD"
  } > "$sd/repos"
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

p1=$(stamp_of "$t_schema"); p2=$(stamp_of "$t_parser"); p3=$(stamp_of "$t_notify"); p4=$(stamp_of "$t_admin")
[ "$p1" -lt "$p2" ] && [ "$p2" -le "$p3" ] && [ "$p3" -lt "$p4" ] && ok \
  || bad "stamps should ascend in topological order (got $p1 $p2 $p3 $p4)"

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
# Regression: the printed resume hint must not fabricate --urgent when the
# split itself was never given one.
case "$(cat "$PQ_HOME/.err")" in
  *"--urgent"*) bad "the resume hint must not fabricate --urgent when none was given" ;;
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

echo "== the resume hint DOES carry an explicit --urgent when one was given ==" >&2
reset_tasks
: > "$SPLIT_COUNTER"
PLAN2="$PQ_HOME/.solo-plan2.md"
printf 'FIXTURE: solo\n\nOne small thing.\n' > "$PLAN2"
main add "$PLAN2" --repo "$REPO" --split --urgent < /dev/null 2>"$PQ_HOME/.err" >/dev/null
case "$(cat "$PQ_HOME/.err")" in
  *"--urgent"*) ok ;;
  *) bad "an explicitly-given --urgent should survive into the resume hint (got: $(cat "$PQ_HOME/.err"))" ;;
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

# ── multi-repo splits ────────────────────────────────────────────────────────

echo "== multi-repo: 3-column graph.tsv assigns parts across repos; cross-repo after resolves to the dependency's own repo ==" >&2
reset_tasks
SD=$(new_split_dir_repos multirepo-basic repo2)
printf 'MARKER: mr-server\nDo the server part.\n' > "$SD/01-server.md"
printf 'MARKER: mr-client\nDo the client part.\n' > "$SD/02-client.md"
printf '01-server.md\t\n02-client.md\t01-server.md\trepo2\n' > "$SD/graph.tsv"
out=$(main add --split-dir "$SD" --repo "$REPO" -y 2>"$PQ_HOME/.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "a 3-column multi-repo split should succeed: $(cat "$PQ_HOME/.err")"
t_server=$(find_task mr-server-thing); t_client=$(find_task mr-client-thing)
eq "$(hdr "$t_server/plan.md" repo)" "$REPO" "the empty-label (primary) part lands in REPO"
eq "$(hdr "$t_client/plan.md" repo)" "$REPO2" "the repo2-labeled part lands in REPO2"
eq "$(cut -f1 "$t_client/after" 2>/dev/null)" "mr-server-thing" "the client part waits on the server part"
eq "$(cut -f2 "$t_client/after" 2>/dev/null)" "$REPO" "the after line's repo field is the dependency's OWN repo, not the client's"

echo "== multi-repo: an unknown repository label in graph.tsv dies with nothing queued ==" >&2
reset_tasks
SD=$(new_split_dir_repos multirepo-badlabel repo2)
printf 'MARKER: mr-server\nA.\n' > "$SD/01-a.md"
printf '01-a.md\t\tnonexistent-label\n' > "$SD/graph.tsv"
( main add --split-dir "$SD" --repo "$REPO" -y ) >/dev/null 2>&1 && bad "an unknown repo label should be rejected" || ok
eq "$(queue_count)" "0" "unknown repo label: nothing queued"

echo "== multi-repo: a plain 2-column graph.tsv still lands everything in the primary ==" >&2
reset_tasks
SD=$(new_split_dir_repos multirepo-2col repo2)
printf 'MARKER: mr-solo2col\nOne repo, one part.\n' > "$SD/01-solo2col.md"
printf '01-solo2col.md\t\n' > "$SD/graph.tsv"
out=$(main add --split-dir "$SD" --repo "$REPO" -y 2>"$PQ_HOME/.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "a 2-column graph.tsv alongside a repos file should still work: $(cat "$PQ_HOME/.err")"
t=$(find_task mr-solo2col-thing)
eq "$(hdr "$t/plan.md" repo)" "$REPO" "no third field at all still means the primary"

echo "== a legacy split directory (repo file only, no repos) still resumes, and repos gets materialized ==" >&2
reset_tasks
SD=$(new_split_dir legacy-resume)
printf 'MARKER: solo\nDo the one thing.\n' > "$SD/01-solo.md"
printf '01-solo.md\t\n' > "$SD/graph.tsv"
[ -f "$SD/repos" ] && bad "should not have a repos file yet" || ok
out=$(main add --split-dir "$SD" --repo "$REPO" -y 2>"$PQ_HOME/.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "resuming a legacy (repo-only) split dir should still work: $(cat "$PQ_HOME/.err")"
eq "$out" "do-solo-thing" "it should still queue the one part"
[ -s "$SD/repos" ] && ok || bad "resuming should materialize a repos file"
eq "$(cut -f2 "$SD/repos" | head -1)" "$REPO" "the materialized repos file's primary path is REPO"

echo "== multi-repo: branch_taken is checked against the PART'S OWN repo, not the primary ==" >&2
reset_tasks
git -C "$REPO" branch tom/mr-branchcheck-thing >/dev/null
SD=$(new_split_dir_repos multirepo-branchcheck repo2)
printf 'MARKER: mr-branchcheck\nClaims a branch that exists in REPO but not REPO2.\n' > "$SD/01-bc.md"
printf '01-bc.md\t\trepo2\n' > "$SD/graph.tsv"
out=$(main add --split-dir "$SD" --repo "$REPO" -y 2>"$PQ_HOME/.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "a part assigned to REPO2 must not be refused for a branch only live in REPO: $(cat "$PQ_HOME/.err")"
eq "$out" "mr-branchcheck-thing" "it should queue under its own name"
git -C "$REPO" branch -D tom/mr-branchcheck-thing >/dev/null 2>&1

echo "== multi-repo: the confirm table's REPO column appears only once a split spans more than one repo ==" >&2
reset_tasks
SD=$(new_split_dir_repos multirepo-column repo2)
printf 'MARKER: mr-server\nA.\n' > "$SD/01-server.md"
printf 'MARKER: mr-client\nB.\n' > "$SD/02-client.md"
printf '01-server.md\t\n02-client.md\t01-server.md\trepo2\n' > "$SD/graph.tsv"
main add --split-dir "$SD" --repo "$REPO" -y >/dev/null 2>"$PQ_HOME/.err"
case "$(cat "$PQ_HOME/.err")" in
  *"REPO"*) ok ;;
  *) bad "a multi-repo split's confirm table should show a REPO column (got: $(cat "$PQ_HOME/.err"))" ;;
esac
# The column must show the label actually recorded in $sd/repos ("repo2"),
# never basename($REPO2) (a random "repo2.XXXXXX" mktemp name) - a
# regression test for the label being recomputed instead of read.
case "$(cat "$PQ_HOME/.err")" in
  *"repo2"*) ok ;;
  *) bad "the REPO column should show the recorded label 'repo2' (got: $(cat "$PQ_HOME/.err"))" ;;
esac
case "$(cat "$PQ_HOME/.err")" in
  *"$(basename "$REPO2")"*) bad "the REPO column should not show REPO2's basename instead of its recorded label (got: $(cat "$PQ_HOME/.err"))" ;;
  *) ok ;;
esac

reset_tasks
SD2=$(new_split_dir single-repo-column)
printf 'MARKER: solo\nDo the one thing.\n' > "$SD2/01-solo.md"
printf '01-solo.md\t\n' > "$SD2/graph.tsv"
main add --split-dir "$SD2" --repo "$REPO" -y >/dev/null 2>"$PQ_HOME/.err"
case "$(cat "$PQ_HOME/.err")" in
  *"REPO"*) bad "a single-repo split's confirm table should not show a REPO column (got: $(cat "$PQ_HOME/.err"))" ;;
  *) ok ;;
esac

echo "== multi-repo: the namer gets the repo hint only on a multi-repo split ==" >&2
reset_tasks
: > "$CALL_LOG"
SD=$(new_split_dir_repos multirepo-hint repo2)
printf 'MARKER: mr-server\nA.\n' > "$SD/01-server.md"
printf 'MARKER: mr-client\nB.\n' > "$SD/02-client.md"
printf '01-server.md\t\n02-client.md\t01-server.md\trepo2\n' > "$SD/graph.tsv"
main add --split-dir "$SD" --repo "$REPO" -y >/dev/null 2>&1
case "$(awk -F'\t' '$1 == "haiku" { print }' "$CALL_LOG")" in
  *"lands in the repo2 repository"*) ok ;;
  *) bad "a multi-repo split's naming call should carry the repo hint with the recorded label 'repo2', not a recomputed basename" ;;
esac

reset_tasks
: > "$CALL_LOG"
SD2=$(new_split_dir single-repo-hint)
printf 'MARKER: solo\nDo the one thing.\n' > "$SD2/01-solo.md"
printf '01-solo.md\t\n' > "$SD2/graph.tsv"
main add --split-dir "$SD2" --repo "$REPO" -y >/dev/null 2>&1
case "$(awk -F'\t' '$1 == "haiku" { print }' "$CALL_LOG")" in
  *"lands in the"*) bad "a single-repo split's naming call should not carry the repo hint" ;;
  *) ok ;;
esac

echo "== repo_candidates: a purpose-built scan root with two repos, a plain dir, and a dotted dir returns exactly the two, primary first ==" >&2
SCAN9=$(mktemp -d)
RA=$(mktemp -d "$SCAN9/repoA.XXXXXX")
git init -q -b master "$RA"
git -C "$RA" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
RB=$(mktemp -d "$SCAN9/repoB.XXXXXX")
git init -q -b master "$RB"
git -C "$RB" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$SCAN9/plaindir"
mkdir -p "$SCAN9/.dotted"
result9=$(PQ_REPOS_DIR="$SCAN9" repo_candidates "$REPO")
eq "$(wc -l <<<"$result9" | tr -d ' ')" "3" "primary plus the two real git repos - the plain dir and the dotted dir are excluded"
eq "$(cut -f2 <<<"$result9" | sed -n 1p)" "$REPO" "the primary is listed first"
labels9=$(cut -f1 <<<"$result9" | tail -n +2 | tr '\n' ' ')
case "$labels9" in
  *"$(basename "$RA")"*"$(basename "$RB")"*) ok ;;
  *) bad "both scanned repos should be present, sorted by label (got: $labels9)" ;;
esac
rm -rf "$SCAN9"

echo "== multi-repo: explicit --repo (two or more) restricts the candidate set - a label outside it dies ==" >&2
reset_tasks
PLANMR="$PQ_HOME/.multirepo-badlabel-plan.md"
printf 'FIXTURE: multirepo-badlabel\n\nA plan.\n' > "$PLANMR"
if ( main add "$PLANMR" --repo "$REPO" --repo "$REPO2" --split -y ) >/dev/null 2>&1; then
  bad "a label outside the explicit --repo set should be rejected"
else
  ok
fi
eq "$(queue_count)" "0" "bad label with explicit --repo set: nothing queued"

echo "== multi-repo: a SINGLE --repo does not restrict the set - the scan still contributes ==" >&2
reset_tasks
PLANMR2="$PQ_HOME/.multirepo-plan.md"
printf 'FIXTURE: multirepo\n\nA plan.\n' > "$PLANMR2"
out=$(PQ_REPOS_DIR="$SIBLINGROOT" main add "$PLANMR2" --repo "$REPO" --split -y 2>"$PQ_HOME/.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "a scanned sibling should still queue with a single --repo: $(cat "$PQ_HOME/.err")"
t_a=$(find_task mr-a-thing); t_b=$(find_task mr-b-thing)
eq "$(hdr "$t_a/plan.md" repo)" "$REPO" "the primary part lands in REPO"
# repo_candidates resolves each scanned entry through `git worktree list
# --porcelain`, which realpath's it - on macOS that turns /var/folders/...
# into /private/var/folders/..., so the comparison must go through the same
# resolution rather than against $REPO2's own unresolved mktemp path.
eq "$(hdr "$t_b/plan.md" repo)" "$(cd "$REPO2" && pwd -P)" "the scanned sibling part lands in REPO2"

echo "== a non-split pq add with two --repo values is rejected ==" >&2
reset_tasks
if ( main add "/nonexistent-plan-file-xyz.md" --repo "$REPO" --repo "$REPO2" -y ) >/dev/null 2>&1; then
  bad "a non-split add with two --repo values should be rejected"
else
  ok
fi
eq "$(queue_count)" "0" "non-split, two --repo: nothing queued"

echo "== multi-repo: --add-dir is passed once per candidate ==" >&2
reset_tasks
: > "$CALL_LOG"
PLANMR3="$PQ_HOME/.multirepo-plan3.md"
printf 'FIXTURE: multirepo\n\nA plan.\n' > "$PLANMR3"
main add "$PLANMR3" --repo "$REPO" --repo "$REPO2" --split -y >/dev/null 2>&1
opusargs=$(awk -F'\t' '$1 == "opus" { print $2; exit }' "$CALL_LOG")
addcount=$(grep -o -- '--add-dir' <<<"$opusargs" | wc -l | tr -d ' ')
eq "$addcount" "2" "one --add-dir per candidate (primary + REPO2)"

echo "== multi-repo: a candidate left dirty by the splitter is warned about, naming that repo ==" >&2
reset_tasks
PLANMR4="$PQ_HOME/.multirepo-dirty-plan.md"
printf 'FIXTURE: multirepo-dirty\n\nA plan.\n' > "$PLANMR4"
main add "$PLANMR4" --repo "$REPO" --repo "$REPO2" --split -y >/dev/null 2>"$PQ_HOME/.err"
case "$(cat "$PQ_HOME/.err")" in
  *"$REPO2"*"dirty"*) ok ;;
  *) bad "leaving REPO2 dirty should warn naming REPO2 (got: $(cat "$PQ_HOME/.err"))" ;;
esac
rm -f "$REPO2/oops-the-splitter-wrote-here.txt"

echo "== repo_candidates: PQ_REPOS_MAX truncation warns naming every repo it dropped ==" >&2
SCAN15=$(mktemp -d)
made15=()
for i in 1 2 3 4; do
  d=$(mktemp -d "$SCAN15/extra$i.XXXXXX")
  git init -q -b master "$d"
  git -C "$d" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
  made15+=("$d")
done
warn15=$(PQ_REPOS_DIR="$SCAN15" PQ_REPOS_MAX=3 repo_candidates "$REPO" 2>&1 >/dev/null)
result15=$(PQ_REPOS_DIR="$SCAN15" PQ_REPOS_MAX=3 repo_candidates "$REPO" 2>/dev/null)
eq "$(wc -l <<<"$result15" | tr -d ' ')" "3" "primary plus 2 kept (PQ_REPOS_MAX=3)"
case "$warn15" in
  *"PQ_REPOS_MAX"*) ok ;;
  *) bad "should warn naming PQ_REPOS_MAX (got: $warn15)" ;;
esac
droppedcount=0
for d in "${made15[@]}"; do
  case "$warn15" in *"$(basename "$d")"*) droppedcount=$((droppedcount + 1)) ;; esac
done
eq "$droppedcount" "2" "the warning names exactly the repos that got dropped"
rm -rf "$SCAN15"

echo "== a split-level --after containing / is refused when 2+ --repo are given explicitly ==" >&2
reset_tasks
PLANMR16="$PQ_HOME/.multirepo-rawafter-plan.md"
printf 'FIXTURE: multirepo\n\nA plan.\n' > "$PLANMR16"
if ( main add "$PLANMR16" --repo "$REPO" --repo "$REPO2" --split --after tom/some-raw-branch -y ) >/dev/null 2>&1; then
  bad "a raw branch --after should be refused when --repo is given 2+ times"
else
  ok
fi
eq "$(queue_count)" "0" "raw-branch --after with explicit multi-repo: nothing queued"

echo "== ...but NOT refused merely because a resumed split's repos file already has more than one candidate ==" >&2
reset_tasks
SD=$(new_split_dir_repos multirepo-rawafter-resume repo2)
printf 'MARKER: mr-server\nA.\n' > "$SD/01-server.md"
printf '01-server.md\t\n' > "$SD/graph.tsv"
out=$(main add --split-dir "$SD" --repo "$REPO" --after tom/some-raw-branch -y 2>"$PQ_HOME/.err")
rc=$?
[ "$rc" -eq 0 ] && ok \
  || bad "resuming with only ONE --repo must not trip the multi-repo refusal just because \$sd/repos already has two candidates: $(cat "$PQ_HOME/.err")"

echo "== ...and still accepted on a single-repo split ==" >&2
reset_tasks
SD2=$(new_split_dir single-repo-rawafter)
printf 'MARKER: solo\nDo the one thing.\n' > "$SD2/01-solo.md"
printf '01-solo.md\t\n' > "$SD2/graph.tsv"
out=$(main add --split-dir "$SD2" --repo "$REPO" --after tom/some-raw-branch -y 2>"$PQ_HOME/.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "a raw branch --after should still work on a single-repo split: $(cat "$PQ_HOME/.err")"
t=$(find_task do-solo-thing)
eq "$(cut -f3 "$t/after" 2>/dev/null)" "tom/some-raw-branch" "the root part's after line records the raw branch"

# ── container/no-primary mode: cwd (or --repo) naming a directory that is
# NOT itself a git repo, only a container of several ────────────────────────

echo "== container mode: --repo pointing at a non-repo container discovers its children, no primary ==" >&2
reset_tasks
PLANC="$PQ_HOME/.container-plan.md"
printf 'FIXTURE: container\n\nA plan.\n' > "$PLANC"
# PQ_REPOS_DIR is globally pinned to an empty directory above so ordinary
# sibling-scan tests stay single-repo - repo_candidates_container reads that
# same override, so it must be cleared here or the container scan would look
# in the wrong place entirely and find nothing.
out=$(PQ_REPOS_DIR= main add "$PLANC" --repo "$CONTAINERROOT" --split -y 2>"$PQ_HOME/.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "container-mode split should succeed: $(cat "$PQ_HOME/.err")"
t_a=$(find_task ctr-a-thing); t_b=$(find_task ctr-b-thing)
eq "$(hdr "$t_a/plan.md" repo)" "$(cd "$CONTAINERA" && pwd -P)" "part A lands in childA"
eq "$(hdr "$t_b/plan.md" repo)" "$(cd "$CONTAINERB" && pwd -P)" "part B lands in childB"

echo "== container mode: cwd itself (not --repo) being a non-repo container triggers discovery ==" >&2
reset_tasks
PLANCWD="$PQ_HOME/.container-cwd-plan.md"
printf 'FIXTURE: container\n\nA plan.\n' > "$PLANCWD"
out=$(cd "$CONTAINERROOT" && PQ_REPOS_DIR= main add "$PLANCWD" --split -y 2>"$PQ_HOME/.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "running from cwd=container should discover its children: $(cat "$PQ_HOME/.err")"
t_a=$(find_task ctr-a-thing)
eq "$(hdr "$t_a/plan.md" repo)" "$(cd "$CONTAINERA" && pwd -P)" "part A lands in childA when discovered from cwd"

echo "== container mode: an empty repo field dies - there is no primary to default to ==" >&2
reset_tasks
SDEMPTY=$(new_split_dir_container container-emptyfield)
labela=$(basename "$CONTAINERA")
printf 'MARKER: ctr-a\nA.\n' > "$SDEMPTY/01-a.md"
printf 'MARKER: ctr-b\nB.\n' > "$SDEMPTY/02-b.md"
{
  printf '01-a.md\t\t%s\n' "$labela"
  printf '02-b.md\t\n'
} > "$SDEMPTY/graph.tsv"
if ( main add --split-dir "$SDEMPTY" -y ) >/dev/null 2>"$PQ_HOME/.err"; then
  bad "an empty repo field in a no-primary split should die"
else
  ok
fi
case "$(cat "$PQ_HOME/.err")" in
  *"no primary"*) ok ;;
  *) bad "should explain there is no primary to default to (got: $(cat "$PQ_HOME/.err"))" ;;
esac
eq "$(queue_count)" "0" "empty repo field in no-primary split: nothing queued"

echo "== container mode with exactly one child: still requires an explicit label; multi=0 hides the repo hint and REPO column ==" >&2
CONTAINERONE=$(mktemp -d)
CONTAINERONECHILD=$(mktemp -d "$CONTAINERONE/onlychild.XXXXXX")
git init -q -b master "$CONTAINERONECHILD"
git -C "$CONTAINERONECHILD" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
reset_tasks
: > "$CALL_LOG"
SDONE=$(new_split_dir_container_one container-onechild)
labelone=$(basename "$CONTAINERONECHILD")
printf 'MARKER: ctr-solo\nDo the one thing.\n' > "$SDONE/01-solo.md"
printf '01-solo.md\t\t%s\n' "$labelone" > "$SDONE/graph.tsv"
out=$(main add --split-dir "$SDONE" -y 2>"$PQ_HOME/.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "single-child container split should still succeed: $(cat "$PQ_HOME/.err")"
case "$(awk -F'\t' '$1 == "haiku" { print }' "$CALL_LOG")" in
  *"lands in the"*) bad "a split that only ever uses ONE repo should not carry the repo hint even in no-primary mode" ;;
  *) ok ;;
esac
case "$(cat "$PQ_HOME/.err")" in
  *"REPO"*) bad "single-repo-in-practice split should not show a REPO column" ;;
  *) ok ;;
esac
rm -rf "$CONTAINERONE"

echo "== container mode: zero child repos dies clearly ==" >&2
EMPTYCONTAINER=$(mktemp -d)
mkdir -p "$EMPTYCONTAINER/not-a-repo"
reset_tasks
PLANEMPTY="$PQ_HOME/.container-empty-plan.md"
printf 'FIXTURE: container\n\nA plan.\n' > "$PLANEMPTY"
if ( PQ_REPOS_DIR= main add "$PLANEMPTY" --repo "$EMPTYCONTAINER" --split -y ) >/dev/null 2>"$PQ_HOME/.err"; then
  bad "a container with no git-repo children should die"
else
  ok
fi
case "$(cat "$PQ_HOME/.err")" in
  *"no git repositories"*) ok ;;
  *) bad "should explain no git repositories were found (got: $(cat "$PQ_HOME/.err"))" ;;
esac
rm -rf "$EMPTYCONTAINER"

echo "== repo_candidates_container: PQ_REPOS_MAX truncation warns naming every repo it dropped ==" >&2
SCANC=$(mktemp -d)
madec=()
for i in 1 2 3 4; do
  d=$(mktemp -d "$SCANC/kid$i.XXXXXX")
  git init -q -b master "$d"
  git -C "$d" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
  madec+=("$d")
done
warnc=$(PQ_REPOS_DIR="$SCANC" PQ_REPOS_MAX=3 repo_candidates_container "$SCANC" 2>&1 >/dev/null)
resultc=$(PQ_REPOS_DIR="$SCANC" PQ_REPOS_MAX=3 repo_candidates_container "$SCANC" 2>/dev/null)
eq "$(wc -l <<<"$resultc" | tr -d ' ')" "3" "kept exactly PQ_REPOS_MAX (3) - no primary consuming a slot"
case "$warnc" in
  *"PQ_REPOS_MAX"*) ok ;;
  *) bad "should warn naming PQ_REPOS_MAX (got: $warnc)" ;;
esac
droppedcountc=0
for d in "${madec[@]}"; do
  case "$warnc" in *"$(basename "$d")"*) droppedcountc=$((droppedcountc + 1)) ;; esac
done
eq "$droppedcountc" "1" "the warning names exactly the one repo that got dropped (4 found, keep 3)"
rm -rf "$SCANC"

echo "== container mode: a raw-branch --after is refused even with NO explicit --repo (no primary at all) ==" >&2
reset_tasks
PLANRAW="$PQ_HOME/.container-rawafter-plan.md"
printf 'FIXTURE: container\n\nA plan.\n' > "$PLANRAW"
if ( PQ_REPOS_DIR= main add "$PLANRAW" --repo "$CONTAINERROOT" --split --after tom/some-raw-branch -y ) >/dev/null 2>&1; then
  bad "a raw branch --after should be refused in container/no-primary mode"
else
  ok
fi
eq "$(queue_count)" "0" "raw-branch --after in container mode: nothing queued"

echo "== container mode: resuming with --repo has no effect and warns ==" >&2
reset_tasks
SDRESUME=$(new_split_dir_container container-resume-repo-noop)
labela=$(basename "$CONTAINERA"); labelb=$(basename "$CONTAINERB")
printf 'MARKER: ctr-a\nA.\n' > "$SDRESUME/01-a.md"
printf 'MARKER: ctr-b\nB.\n' > "$SDRESUME/02-b.md"
{
  printf '01-a.md\t\t%s\n' "$labela"
  printf '02-b.md\t\t%s\n' "$labelb"
} > "$SDRESUME/graph.tsv"
out=$(main add --split-dir "$SDRESUME" --repo "$REPO" -y 2>"$PQ_HOME/.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "resuming a no-primary split with an extraneous --repo should still succeed: $(cat "$PQ_HOME/.err")"
case "$(cat "$PQ_HOME/.err")" in
  *"no effect"*) ok ;;
  *) bad "should warn that --repo has no effect on a no-primary resume (got: $(cat "$PQ_HOME/.err"))" ;;
esac
t_a=$(find_task ctr-a-thing)
# Unlike the fresh-split cases above, new_split_dir_container records
# $CONTAINERA verbatim (no scan through `git worktree list` to resolve it),
# so the recorded path here is the raw mktemp path, not its /private/var
# realpath - the comparison must match what was actually stored.
eq "$(hdr "$t_a/plan.md" repo)" "$CONTAINERA" "the --repo given at resume did NOT override childA's recorded path"

echo "== a plain (non-split) add from a directory that is not a git repo still dies clearly ==" >&2
reset_tasks
NOTAREPO=$(mktemp -d)
PLAINPLAN="$PQ_HOME/.notarepo-plan.md"
printf '# plan\n\nJust one thing.\n' > "$PLAINPLAN"
if ( cd "$NOTAREPO" && main add "$PLAINPLAN" -y ) >/dev/null 2>"$PQ_HOME/.err"; then
  bad "a plain add from a non-repo directory should die"
else
  ok
fi
case "$(cat "$PQ_HOME/.err")" in
  *"not inside a git repo"*) ok ;;
  *) bad "should die with the original 'not inside a git repo' message (got: $(cat "$PQ_HOME/.err"))" ;;
esac
eq "$(queue_count)" "0" "plain add from non-repo dir: nothing queued"
rm -rf "$NOTAREPO"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
