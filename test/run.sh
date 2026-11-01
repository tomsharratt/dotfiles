#!/usr/bin/env bash
# test/run.sh - run every test file in this directory. Each file is
# self-contained (its own PQ_HOME, its own stubs), so one failing file cannot
# hide a regression in another - all of them run regardless of earlier results.
#
# The whole run lives under one mktemp root with its own HOME, and each file makes
# its own sandbox inside it (test/sandbox.sh), so nothing a test does can reach
# real user state - see sandbox.sh for the incident that made this a rule. The
# root is the only thing this script removes.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# The base without its trailing slash (macOS's TMPDIR has one): a doubled slash
# in the root reaches every path a test compares.
RUN_ROOT_BASE=${TMPDIR:-/tmp}; RUN_ROOT_BASE=${RUN_ROOT_BASE%/}
RUN_ROOT=$(mktemp -d "$RUN_ROOT_BASE/pqrun.XXXXXX") || { echo "run.sh: could not make a test root" >&2; exit 1; }
# shellcheck disable=SC2329  # run by the trap below
run_cleanup() {
  [ -n "${RUN_ROOT:-}" ] && [ -d "$RUN_ROOT" ] && [ "${RUN_ROOT%/*}" = "$RUN_ROOT_BASE" ] || return 0
  chmod -R u+w "$RUN_ROOT" 2>/dev/null
  rm -rf "$RUN_ROOT"
}
trap run_cleanup EXIT
export TEST_BASE="$RUN_ROOT"
# asdf's install is read from where it really is, and its global versions are
# copied in, as sandbox.sh does for a file run on its own (see there).
export ASDF_DATA_DIR="${ASDF_DATA_DIR:-$HOME/.asdf}"
REAL_TOOL_VERSIONS="$HOME/.tool-versions"
export HOME="$RUN_ROOT/home" XDG_STATE_HOME="$RUN_ROOT/home/.local/state" XDG_CONFIG_HOME="$RUN_ROOT/home/.config"
export PQ_HOME="$XDG_STATE_HOME/pq" PQ_PLANS_DIR="$HOME/.claude/plans"
mkdir -p "$HOME"
[ -f "$REAL_TOOL_VERSIONS" ] && cp "$REAL_TOOL_VERSIONS" "$HOME/.tool-versions"
printf 'run.sh: test root %s (HOME=%s PQ_HOME=%s PQ_PLANS_DIR=%s)\n' "$RUN_ROOT" "$HOME" "$PQ_HOME" "$PQ_PLANS_DIR" >&2

rc=0
for f in "$HERE"/pq-*.sh "$HERE"/wt-*.sh; do
  [ -f "$f" ] || continue
  printf -- '── %s ──\n' "$(basename "$f")"
  bash "$f" || rc=1
  printf '\n'
done
exit $rc
