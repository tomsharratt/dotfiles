#!/usr/bin/env bash
# test/wt-new-room.sh - `wt new` with no room left: every redis index the
# profile hands out is held by a live worktree.
#
# The bug this pins: prepare_state allocated only after Herdr had created the
# worktree and its workspace, so a full pool died there and left both behind
# with no state file - invisible to `wt rm` and gc. The next `wt new` then
# found the branch already there, ignored --base, and reopened the orphan at
# the commit it was first forked from; for a stacked task whose parent had
# been rebased meanwhile, that was 81 commits of the wrong history. And the
# exit was a plain 1, so pq counted it as a failed dispatch and gave the task
# up after three ticks, when all it needed was to wait for a merge.
#
# So: a full pool exits 75 before Herdr is asked for anything, a worktree being
# reopened keeps the index it already holds, and once one is freed `wt new`
# hands it out.
#
# Driven through the real `wt new --no-agent --no-focus --json`, which is what
# pq dispatches, with the same herdr stub and fixture as test/wt-new-url.sh.
#
# SC2015: `ok` never fails, so `[ ... ] && ok || bad` is an if/else.
# shellcheck disable=SC2015
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WT="$HERE/../.local/bin/wt"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }
has() { case "$1" in *"$2"*) ok ;; *) bad "$3 (got '$1')" ;; esac; }

FIX=$(mktemp -d)
# AF_UNIX paths are capped near 104 bytes and mktemp's is already long, so the
# socket lives at a short path of its own rather than under the fixture.
SOCK="/tmp/wt-new-room.$$.sock"
cleanup() {
  [ -n "${SOCKPID:-}" ] && kill "$SOCKPID" 2>/dev/null
  rm -rf "$FIX"; rm -f "$SOCK"
}
trap cleanup EXIT

export HOME="$FIX/home"
export XDG_STATE_HOME="$FIX/state" XDG_CONFIG_HOME="$FIX/config"
STATE_DIR="$XDG_STATE_HOME/wt"
PROFILE_DIR="$XDG_CONFIG_HOME/wt/profiles"
WTROOT="$FIX/worktrees"
HERDR_LOG="$FIX/herdr-calls"
mkdir -p "$HOME/.local/bin" "$STATE_DIR" "$PROFILE_DIR" "$WTROOT"
: > "$HERDR_LOG"

# ── a real git repo ─────────────────────────────────────────────────────────
REPO="$FIX/repo"
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
REPO_NAME=$(basename "$REPO")

# ── a real unix socket, so in_herdr() is satisfied ──────────────────────────
python3 -c "
import socket, signal
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind('$SOCK'); s.listen(1)
signal.pause()
" 2>/dev/null &
SOCKPID=$!
disown "$SOCKPID" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$SOCK" ] && break; sleep 0.2; done
[ -S "$SOCK" ] || { printf 'SKIP: could not create a unix socket for in_herdr()\n' >&2; exit 0; }
export HERDR_ENV=1 HERDR_SOCKET_PATH="$SOCK"

# ── stub herdr at the path wt resolves, logging every call ──────────────────
# `worktree create` makes a real linked worktree (or finds the one already on
# that branch) and answers in herdr's envelope shape.
cat > "$HOME/.local/bin/herdr" <<EOF
#!/usr/bin/env bash
{ for a in "\$@"; do printf '%s ' "\$a"; done; printf '\n'; } >> "$HERDR_LOG"
case "\$1 \$2" in
  "worktree create")
    branch=""; cwd=""
    while [ \$# -gt 0 ]; do
      case "\$1" in --branch) branch=\$2; shift 2 ;; --cwd) cwd=\$2; shift 2 ;; *) shift ;; esac
    done
    slug=\$(printf '%s' "\$branch" | tr '/_' '-')
    path="$WTROOT/\$slug"
    [ -d "\$path" ] || git -C "\$cwd" worktree add -q -b "\$branch" "\$path" master 2>/dev/null
    printf '{"result":{"workspace":{"workspace_id":"w9"},"root_pane":{"pane_id":"w9:p1"},"worktree":{"path":"%s"}}}' "\$path"
    ;;
  "worktree list") printf '{"result":{}}' ;;
  "tab create")    printf '{}' ;;
  *)               printf '{"result":{}}' ;;
esac
exit 0
EOF
chmod +x "$HOME/.local/bin/herdr"
ln -sf "$WT" "$HOME/.local/bin/wt"

# ── a profile with a pool of two redis indexes ──────────────────────────────
cat > "$PROFILE_DIR/$REPO_NAME.sh" <<'EOF'
WT_RESOURCES="redis"
WT_REDIS_MAX=2
EOF

# ── two live worktrees holding both ─────────────────────────────────────────
hold() {                                # branch slug redis
  git -C "$REPO" worktree add -q -b "$1" "$WTROOT/$2" master
  cat > "$STATE_DIR/$REPO_NAME--$2.env" <<EOF
WT_PATH=$WTROOT/$2
WT_NAME=$1
WT_SLUG=$2
WT_REPO=$REPO
WT_REPO_NAME=$REPO_NAME
WT_DOMAIN=$2.test
WT_REDIS=$3
EOF
}
hold one/task one-task 1
hold two/task two-task 2

wt_new() { (cd "$REPO" && "$WT" new --no-agent --no-focus --json "$@"); }

echo "== a full pool stops before Herdr creates anything, and exits 75 ==" >&2
out=$(wt_new my/new-task 2>"$FIX/err"); rc=$?
eq "$rc" "75" "no room is its own exit, not a failure"
has "$(cat "$FIX/err")" "no free redis db (1-2) available" "saying which pool ran out"
has "$(cat "$FIX/err")" "wt gc --settled" "and what frees one"
eq "$out" "" "with no JSON to mistake for a worktree"
grep -q '^worktree create ' "$HERDR_LOG" && bad "herdr must not be asked to create the worktree" || ok
git -C "$REPO" show-ref --verify --quiet refs/heads/my/new-task && bad "no branch is left behind" || ok
[ -e "$WTROOT/my-new-task" ] && bad "no worktree is left behind" || ok
[ -e "$STATE_DIR/$REPO_NAME--my-new-task.env" ] && bad "no state file is written" || ok

echo "== a worktree being reopened keeps its index, full pool or not ==" >&2
: > "$HERDR_LOG"
out=$(wt_new two/task 2>"$FIX/err"); rc=$?
eq "$rc" "0" "reopening needs no new index"
eq "$(printf '%s' "$out" | jq -r '.redis // empty')" "2" "and keeps the one it holds"

echo "== once an index is freed, the next wt new is handed it ==" >&2
git -C "$REPO" worktree remove --force "$WTROOT/one-task"
out=$(wt_new my/new-task 2>"$FIX/err"); rc=$?
eq "$rc" "0" "there is room again"
eq "$(printf '%s' "$out" | jq -r '.redis // empty')" "1" "and the freed index goes to the new worktree"
grep -q '^WT_REDIS=1$' "$STATE_DIR/$REPO_NAME--my-new-task.env" 2>/dev/null && ok || bad "recorded in its state file"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
