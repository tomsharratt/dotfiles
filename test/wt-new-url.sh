#!/usr/bin/env bash
# test/wt-new-url.sh - `wt new --json` must report the url of the worktree it
# just made, never one belonging to some other reservation.
#
# The bug this pins: WT_URL is written only by a profile's wt_provision, which
# runs in a separate Herdr tab, so it is never legitimately set in the `wt new`
# process. gc_run, cmd_new's third statement, sources EVERY state file in the
# state dir - its `continue` for a live worktree fires after the load - and
# calls wt_reset only at the TOP of each iteration, so it returns holding the
# last file's WT_*. prepare_state then clears WT_PORT/WT_REDIS/WT_SLUG but not
# WT_URL, and the --json block emits that leftover.
#
# The symptom was 57 of 75 pq-dispatched tasks recording another worktree's
# url, the same wrong value sticking for several dispatches in a row, while
# PQ_PORT beside it was correct - exactly the split prepare_state's selective
# reset predicts. A wrong url reads as broken puma routing, which is why the
# repair reached for was `wt provision` then `wt open && wt dev`.
#
# Driven through the real `wt new --no-agent --no-focus --no-dev --json`, which
# is what pq dispatches. Unlike test/wt-open.sh, `wt new` does need a herdr
# socket, and wt resolves the binary as "$HOME/.local/bin/herdr" rather than
# off PATH - so HOME is pointed at a fixture holding a stub. HOME reaches
# nothing else here that matters: SELF (the command string sent to the dev tab,
# which the stub swallows), the XDG defaults (both set explicitly below), and
# rm_leftover's safety guard.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WT="$HERE/../.local/bin/wt"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }

FIX=$(mktemp -d)
# AF_UNIX paths are capped near 104 bytes and mktemp's is already long, so the
# socket lives at a short path of its own rather than under the fixture.
SOCK="/tmp/wt-new-url.$$.sock"
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
mkdir -p "$HOME/.local/bin" "$STATE_DIR" "$PROFILE_DIR" "$WTROOT"

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
# Off the job table, so killing it in cleanup does not print a "Terminated"
# notice into the middle of the suite's output.
disown "$SOCKPID" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$SOCK" ] && break; sleep 0.2; done
[ -S "$SOCK" ] || { printf 'SKIP: could not create a unix socket for in_herdr()\n' >&2; exit 0; }
export HERDR_ENV=1 HERDR_SOCKET_PATH="$SOCK"

# ── stub herdr at the path wt resolves ──────────────────────────────────────
# `worktree create` makes a real linked worktree, so gc_run and prepare_state
# both see a genuine path, and answers in herdr's envelope shape. `tab create`
# answers nothing, so wt warns and skips provisioning - faithful to the real
# thing, where provisioning runs in another shell and so is never what sets
# WT_URL in this process.
cat > "$HOME/.local/bin/herdr" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "worktree create")
    branch=""; cwd=""
    while [ \$# -gt 0 ]; do
      case "\$1" in --branch) branch=\$2; shift 2 ;; --cwd) cwd=\$2; shift 2 ;; *) shift ;; esac
    done
    slug=\$(printf '%s' "\$branch" | tr '/_' '-')
    path="$WTROOT/\$slug"
    git -C "\$cwd" worktree add -q -b "\$branch" "\$path" master 2>/dev/null
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

# ── a profile shaped like supercast's: the url is the PROVISIONER's to write ──
cat > "$PROFILE_DIR/$REPO_NAME.sh" <<'EOF'
WT_RESOURCES="port"
wt_provision() { wt_state_set WT_URL "https://$WT_DOMAIN"; }
wt_dev() { :; }
EOF

# ── a foreign reservation, alive and well, that sorts last in the state dir ──
# Alive on purpose: gc reclaims nothing here, which is what proves the leak is
# not about orphans. gc_run sources every state file it walks past, and the
# last one it walks is left behind in the process.
FOREIGN="$WTROOT/zzz-other-task"
git -C "$REPO" worktree add -q -b other/task "$FOREIGN" master
cat > "$STATE_DIR/$REPO_NAME--zzz-other-task.env" <<EOF
WT_NAME=other/task
WT_SLUG=zzz-other-task
WT_PATH=$FOREIGN
WT_REPO=$REPO
WT_REPO_NAME=$REPO_NAME
WT_DOMAIN=zzz-other-task.test
WT_URL=https://zzz-other-task.test
WT_PORT=3199
EOF

# ── an orphan, sorting first, so gc has real work to do on the way past ─────
# Guards the loop's exit change: gc_run's "glob matched nothing" arm became a
# break so the reset below it always runs, and reclaiming must still work.
# Sorts before the live one above, so the last file walked is still the live
# reservation - which is the case that leaks.
cat > "$STATE_DIR/$REPO_NAME--aaa-gone-task.env" <<EOF
WT_NAME=gone/task
WT_SLUG=aaa-gone-task
WT_PATH=$WTROOT/aaa-gone-task
WT_REPO=$REPO
WT_REPO_NAME=$REPO_NAME
WT_DOMAIN=aaa-gone-task.test
WT_URL=https://aaa-gone-task.test
WT_PORT=3198
EOF

# ── the exact call pq dispatches ────────────────────────────────────────────
ERRLOG="$FIX/wt-new.err"
out=$(cd "$REPO" && "$WT" new --no-agent --no-focus --no-dev --json my/new-task 2>"$ERRLOG")
# All of wt's human-facing output is on stderr, so an empty stdout means it died
# there - show that rather than reporting four blank-value failures.
[ -n "$out" ] || printf 'wt new produced no JSON; its stderr was:\n%s\n' "$(cat "$ERRLOG")" >&2

url=$(printf '%s' "$out" | jq -r '.url // empty')
domain=$(printf '%s' "$out" | jq -r '.domain // empty')
slug=$(printf '%s' "$out" | jq -r '.slug // empty')
port=$(printf '%s' "$out" | jq -r '.port // empty')

eq "$slug" "my-new-task" "slug should name the new worktree"
eq "$domain" "my-new-task.test" "domain should name the new worktree"

# The heart of it: no field may describe some other worktree.
case "$url" in
  *zzz-other-task*) bad "url leaked the foreign reservation's value (got '$url')" ;;
  *) ok ;;
esac
eq "$url" "https://my-new-task.test" "url should fall back to the new worktree's own domain"

# The contrast that identified the cause: the port is right because
# prepare_state clears it, so a good port beside a bad url is the signature.
case "$port" in
  3199) bad "port leaked the foreign reservation's value (3199)" ;;
  *) ok ;;
esac

# The state file wt just wrote must not carry the foreign url either, since
# `wt ls`, `wt open` and `wt dev` all read it back.
sf="$STATE_DIR/$REPO_NAME--my-new-task.env"
if [ -f "$sf" ]; then
  case "$(grep '^WT_URL=' "$sf" 2>/dev/null | head -1)" in
    *zzz-other-task*) bad "the new worktree's state file recorded the foreign url" ;;
    *) ok ;;
  esac
else
  bad "no state file written for the new worktree"
fi

# And the foreign reservation must come out untouched - a leak that wrote back
# would corrupt the worktree it was borrowed from.
case "$(grep '^WT_PORT=' "$STATE_DIR/$REPO_NAME--zzz-other-task.env" | head -1)" in
  WT_PORT=3199) ok ;;
  *) bad "the foreign reservation was modified by an unrelated wt new" ;;
esac

# gc still reclaims: the orphan's reservation is gone, the live one is not.
[ -f "$STATE_DIR/$REPO_NAME--aaa-gone-task.env" ] \
  && bad "gc_run should have reclaimed the orphan reservation" || ok
[ -f "$STATE_DIR/$REPO_NAME--zzz-other-task.env" ] \
  && ok || bad "gc_run reclaimed a live worktree's reservation"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
