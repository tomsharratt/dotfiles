#!/usr/bin/env bash
# test/run.sh - run every test file in this directory. Each file is
# self-contained (its own PQ_HOME, its own stubs), so one failing file cannot
# hide a regression in another - all of them run regardless of earlier results.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

rc=0
for f in "$HERE"/pq-*.sh "$HERE"/wt-*.sh; do
  [ -f "$f" ] || continue
  printf -- '── %s ──\n' "$(basename "$f")"
  bash "$f" || rc=1
  printf '\n'
done
exit $rc
