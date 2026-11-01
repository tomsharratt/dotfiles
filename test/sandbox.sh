#!/usr/bin/env bash
# test/sandbox.sh - sourced FIRST by every test file, before pq or wt: it points
# everything the two tools read from the environment at a throwaway root, so no
# test can read or remove real user state.
#
# Why it exists: pq and wt work out their paths from $HOME when they are sourced -
# PLANS_DIR from PQ_PLANS_DIR or ~/.claude/plans, PQ_HOME, wt's STATE_DIR,
# PROFILE_DIR and WORKTREE_ROOT - and a test that set a variable pq then reassigned
# (test/pq-tier.sh exported PLANS_DIR, which pq overwrote with ~/.claude/plans)
# removed the real directory in its cleanup. wt-rm.sh once removed real
# worktrees under ~/.herdr/worktrees the same way. A fresh HOME makes every
# default land inside the root; TMPDIR inside it too makes every mktemp a test
# makes land there; and sandbox_guard, called right after sourcing, refuses to
# go on if any path pq or wt resolved is outside it.
#
# One root per test file, made with mktemp: under TEST_BASE when test/run.sh
# runs the file (run.sh makes that with mktemp and removes it at the end), or
# under the caller's TMPDIR when the file is run on its own. sandbox_cleanup
# removes that root and nothing else.

if [ -n "${TEST_ROOT:-}" ]; then
  echo "sandbox.sh: sourced twice in one test file" >&2; exit 1
fi
# The template stays short: wt's tests bind unix sockets under the root, and a
# socket path longer than 103 bytes cannot be bound.
TEST_ROOT_BASE=${TEST_BASE:-${TMPDIR:-/tmp}}
TEST_ROOT_BASE=${TEST_ROOT_BASE%/}
TEST_ROOT=$(mktemp -d "$TEST_ROOT_BASE/XXXXXX") \
  || { echo "sandbox.sh: could not make a test root" >&2; exit 1; }
[ -n "$TEST_ROOT" ] && [ -d "$TEST_ROOT" ] || { echo "sandbox.sh: no test root" >&2; exit 1; }
# The resolved spelling as well (/var is /private/var on macOS): a path a tool
# canonicalised is still inside the root.
TEST_ROOT_REAL=$(cd "$TEST_ROOT" && pwd -P)
export TEST_ROOT TEST_ROOT_REAL

# asdf's shims (ruby, node) find their install and the global versions under
# HOME. The install is pinned to the real one, which they only read, and the
# global .tool-versions is COPIED into the new HOME below, never linked, so
# nothing a test does writes back to it.
REAL_HOME=$HOME
export ASDF_DATA_DIR="${ASDF_DATA_DIR:-$REAL_HOME/.asdf}"
export HOME="$TEST_ROOT/home"
export TMPDIR="$TEST_ROOT/t"
export XDG_STATE_HOME="$HOME/.local/state" XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$HOME/.cache" XDG_DATA_HOME="$HOME/.local/share"
export CLAUDE_CONFIG_DIR="$HOME/.claude"
# pq's own overrides, at the defaults a fresh HOME would give them anyway: a test
# that sets its own (to a mktemp directory, which is inside the root now too)
# replaces them.
export PQ_HOME="$XDG_STATE_HOME/pq" PQ_PLANS_DIR="$HOME/.claude/plans" PQ_WT="$HOME/.local/bin/wt"
mkdir -p "$TMPDIR" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" \
         "$CLAUDE_CONFIG_DIR" "$PQ_PLANS_DIR" "$HOME/.local/bin" \
  || { echo "sandbox.sh: could not lay out $TEST_ROOT" >&2; exit 1; }
# A bare `mktemp` or `mktemp -d` - the form every test uses - on macOS ignores
# TMPDIR and lands in the per-user temp dir, outside the root. So those two forms
# are made inside it here, in this shell and in every bash a test starts; any call
# with a template of its own is left to mktemp as written.
mktemp() {
  case "$*" in
    "")   command mktemp "$TMPDIR/tmp.XXXXXXXXXX" ;;
    "-d") command mktemp -d "$TMPDIR/tmp.XXXXXXXXXX" ;;
    *)    command mktemp "$@" ;;
  esac
}
export -f mktemp
[ -f "$REAL_HOME/.tool-versions" ] && cp "$REAL_HOME/.tool-versions" "$HOME/.tool-versions"
unset REAL_HOME
# git reads its identity from HOME, and a fresh one has none.
printf '[user]\n\tname = test\n\temail = test@test\n[init]\n\tdefaultBranch = master\n' > "$HOME/.gitconfig"
# Nothing a test runs may reach a real herdr session either.
unset HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID HERDR_PANE_ID HERDR_TAB_ID

sandbox_inside() {                      # path -> 0 when it is the root or under it
  case "$1" in
    "$TEST_ROOT"|"$TEST_ROOT"/*|"$TEST_ROOT_REAL"|"$TEST_ROOT_REAL"/*) return 0 ;;
  esac
  return 1
}

# Every path pq and wt resolve, checked once they are sourced (or, for a file that
# only runs them as commands, once the environment is set): one outside the root
# stops the file before it does anything. Unset ones are skipped, so it suits
# both tools and either alone.
sandbox_guard() {                       # [-q: say nothing when all is well]
  local v val bad=""
  for v in HOME TMPDIR XDG_STATE_HOME XDG_CONFIG_HOME CLAUDE_CONFIG_DIR \
           PQ_HOME PQ_PLANS_DIR PLANS_DIR STATE_DIR PROFILE_DIR WORKTREE_ROOT; do
    val=${!v:-}
    [ -n "$val" ] || continue
    sandbox_inside "$val" || bad="$bad $v=$val"
  done
  if [ -n "$bad" ]; then
    echo "sandbox: refusing to run - outside the test root $TEST_ROOT:$bad" >&2
    exit 1
  fi
  [ "${1:-}" = -q ] && return 0
  printf 'sandbox: %s (PLANS_DIR=%s PQ_HOME=%s STATE_DIR=%s)\n' "$TEST_ROOT" \
    "${PLANS_DIR:--}" "${PQ_HOME:--}" "${STATE_DIR:--}" >&2
}

# The only removal a test's cleanup makes: the root this file made, checked to
# still be exactly what mktemp handed back - a direct child of the base it was
# made in - before it goes.
sandbox_cleanup() {
  [ -n "${TEST_ROOT:-}" ] && [ -n "${TEST_ROOT_BASE:-}" ] && [ -d "$TEST_ROOT" ] || return 0
  [ "${TEST_ROOT%/*}" = "$TEST_ROOT_BASE" ] || return 0
  chmod -R u+w "$TEST_ROOT" 2>/dev/null
  rm -rf "$TEST_ROOT"
}
# Until the file sets a trap of its own (whose cleanup calls sandbox_cleanup), so
# a guard that stops the file early leaves nothing behind either.
trap sandbox_cleanup EXIT
