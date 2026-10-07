#!/usr/bin/env bash
# test/lib.sh - what the pq tests that drive `pq add` share. Sourced AFTER pq, since
# add_as uses what pq defines.
#
# `pq add` takes no flags: its model, effort, blockers and design are wizard
# questions answered through gum. Two seams, for two kinds of test:
#
#   gum_stub, gum_answer, gum_calls   a PATH `gum` that answers from a queue and
#       logs what it was asked, for the tests OF the prompts
#   add_as                            cmd_add with the picker and the wizard stood
#       in for, then the tick's naming of what it added, for the tests that only
#       need a task queued

# A `gum` in $1 answering from a queue kept in $2. The Nth call it receives
# prints answer N (a.N, or stdin lines for "@N" or "@N,M") and exits with a.N.rc, or 0; with none queued it exits
# 130, as gum does on Ctrl-C. Every call's argv is appended to $2/calls, one
# line each, and what it was given on stdin goes to $2/stdin.N.
gum_stub() {                            # bindir statedir
  GUM_STATE=$2; export GUM_STATE
  mkdir -p "$1" "$GUM_STATE"
  cat > "$1/gum" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GUM_STATE/calls"
n=$(cat "$GUM_STATE/n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$GUM_STATE/n"
# Only the prompts that take their items on stdin read it - confirm and pager
# never do, and reading a pipe nobody closes would hang the test.
case "$1 $*" in
  "filter "*) cat > "$GUM_STATE/stdin.$n" ;;
  "choose "*--selected*) ;;
  "choose "*) cat > "$GUM_STATE/stdin.$n" ;;
esac
[ -f "$GUM_STATE/a.$n" ] || exit 130
a=$(cat "$GUM_STATE/a.$n")
# "@N" answers with the Nth line the call was handed on stdin, which is how a test
# picks a row without knowing how it is laid out; "@N,M" with several, one per
# line, as `gum choose --no-limit` hands back what was ticked.
case "$a" in
  @*) for i in $(tr ',' ' ' <<<"${a#@}"); do sed -n "${i}p" "$GUM_STATE/stdin.$n"; done ;;
  *) printf '%s' "$a" ;;
esac
exit "$(cat "$GUM_STATE/a.$n.rc" 2>/dev/null || echo 0)"
STUB
  chmod +x "$1/gum"
  gum_reset
}
gum_reset() { rm -rf "${GUM_STATE:?}"; mkdir -p "$GUM_STATE"; : > "$GUM_STATE/calls"; }
# Queue the answer to the next call nobody has answered yet; $2 is its exit status.
gum_answer() {                          # text [rc]
  local q; q=$(cat "$GUM_STATE/q" 2>/dev/null || echo 0); q=$((q + 1)); echo "$q" > "$GUM_STATE/q"
  printf '%s' "$1" > "$GUM_STATE/a.$q"
  if [ -n "${2:-}" ]; then printf '%s' "$2" > "$GUM_STATE/a.$q.rc"; fi
  return 0
}
gum_calls() { cat "$GUM_STATE/calls"; }
gum_stdin() { cat "$GUM_STATE/stdin.$1"; }     # what call N was handed on stdin

# cmd_add run from inside $repo with the picker and the wizard stood in for, in a
# subshell, leaving the task in new/ as a real `pq add` does: the plan is $1.
# What the wizard would have answered comes as options, so one test reads like
# the add it stands for:
#   --repo R  --model M  --effort E  --after T (repeatable)  --design P (repeatable)
# --after takes a task's slug, and hands the wizard its stamp, as pick_after
# does. The names the stand-ins set are cmd_add's own locals, reached through
# bash's dynamic scope at call time.
add_new() {                             # plan [options...]
  local as_plan=$1 as_repo=${REPO:-$PWD} as_model=$PQ_DEFAULT_MODEL as_effort=$PQ_DEFAULT_EFFORT
  local as_after="" as_design=""
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)   as_repo=$2 ;;
      --model)  as_model=$2 ;;
      --effort) as_effort=$2 ;;
      --after)  as_after="${as_after}$(stamp_of "$(find_task "$2")")"$'\n' ;;
      --design) as_design="${as_design}$2"$'\n' ;;
      *) echo "add_new: unknown option $1" >&2; return 2 ;;
    esac
    shift 2
  done
  # shellcheck disable=SC2329,SC2034  # called by cmd_add, not here
  ( cd "$as_repo" || exit 1
    at_terminal() { return 0; }
    pick_plan() { printf '%s' "$as_plan"; }
    need_gum() { :; }
    add_wizard() { model=$as_model; effort=$as_effort; after_vals=$as_after; design_vals="${design_vals:-}$as_design"; }
    cmd_add </dev/null )
}

# add_new, and then the task it left in new/ named as the next tick would name
# it - for the tests that only need a task queued. A branch given as $2 stands in
# for the namer; empty leaves the test's own `claude` stub to name it. 0 only
# once the task is queued. `as_branch`, not `branch`: the stand-in reads it when
# name_task calls it, where a plain `branch` is name_task's own local.
add_as() {                              # plan branch [add_new options...]
  local as_plan=$1 as_branch=$2; shift 2
  add_new "$as_plan" "$@" || return
  # shellcheck disable=SC2329  # called by name_task, not here
  ( if [ -n "$as_branch" ]; then name_plan() { printf '%s\t\t\n' "$as_branch"; }; fi
    name_task "$(queue_ordered new | tail -1)" 0 </dev/null )
}
