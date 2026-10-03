#!/usr/bin/env bash
# test/lib.sh - what the pq tests that drive `pq add` share. Sourced AFTER pq, since
# add_as uses what pq defines.
#
# `pq add` takes no flags: its model, effort, blockers and design are wizard
# questions answered through gum. Two seams, for two kinds of test:
#
#   gum_stub, gum_answer, gum_calls   a PATH `gum` that answers from a queue and
#       logs what it was asked, for the tests OF the prompts
#   add_as                            cmd_add with the picker, the namer and the
#       wizard stood in for, for the tests that only need a task queued

# A `gum` in $1 answering from a queue kept in $2. The Nth call it receives
# prints answer N (a.N, or the Nth stdin line for "@N") and exits with a.N.rc, or 0; with none queued it exits
# 130, as gum does on Ctrl-C. Every call's argv is appended to $2/calls, one
# line each, and what it was given on stdin goes to $2/stdin.N.
gum_stub() {                            # bindir statedir
  GUM_STATE=$2; export GUM_STATE
  mkdir -p "$1" "$GUM_STATE"
  cat > "$1/gum" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GUM_STATE/calls"
# A spinner just returns: ui_spin waits on the work itself, not on gum, and it is
# not an answer in the queue.
[ "$1" = spin ] && exit 0
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
# picks a row without knowing how it is laid out.
case "$a" in @*) sed -n "${a#@}p" "$GUM_STATE/stdin.$n" ;; *) printf '%s' "$a" ;; esac
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

# cmd_add run from inside $repo with the picker, the namer and the wizard stood
# in for, in a subshell: the plan is $1 and a branch given as $2 stands in for
# the namer too - empty leaves the test's own `claude` stub to name it. What the
# wizard would have answered comes as options, so one test reads like the add it
# stands for:
#   --repo R  --model M  --effort E  --after T (repeatable)  --design P (repeatable)
# The names the stand-ins set are cmd_add's own locals, reached through bash's
# dynamic scope at call time.
add_as() {                              # plan branch [options...]
  local as_plan=$1 as_branch=$2 as_repo=${REPO:-$PWD} as_model=$PQ_DEFAULT_MODEL as_effort=$PQ_DEFAULT_EFFORT
  local as_after="" as_design=""
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)   as_repo=$2 ;;
      --model)  as_model=$2 ;;
      --effort) as_effort=$2 ;;
      --after)  as_after="${as_after}$2"$'\n' ;;
      --design) as_design="${as_design}$2"$'\n' ;;
      *) echo "add_as: unknown option $1" >&2; return 2 ;;
    esac
    shift 2
  done
  # shellcheck disable=SC2329,SC2034  # called by cmd_add, not here
  ( cd "$as_repo" || exit 1
    at_terminal() { return 0; }
    pick_plan() { printf '%s' "$as_plan"; }
    if [ -n "$as_branch" ]; then name_plan() { printf '%s\t\t\n' "$as_branch"; }; fi
    need_gum() { :; }
    ui_spin() { shift; "$@"; }
    add_wizard() { model=$as_model; effort=$as_effort; after_vals=$as_after; design_vals="${design_vals:-}$as_design"; }
    cmd_add </dev/null )
}
