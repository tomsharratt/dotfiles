#!/usr/bin/env bash
# test/wt-open-dev.sh - `wt open` starts the dev server when nothing is serving
# the worktree's url, so one command does what `wt open && wt dev` did by hand.
#
# The gap it closes: provisioning routes <slug>.test at the worktree's port, but
# nothing answers there until the profile's dev server runs - and pq dispatches
# with --no-dev on purpose, so an overnight batch does not hold a foreman stack
# per task. `wt open` on last night's work therefore landed on a dead url, which
# reads exactly like broken puma routing.
#
# Every gate is a reason to touch nothing, and each is a case below: no herdr, no
# wt_dev, no WT_PORT (the mobile profiles), already listening, or a `dev` tab that
# already exists. The last one is the one that matters most - port_listening is
# false for the whole time a foreman stack is binding, so without it a second
# `wt open` inside that window would start a second stack: two `yarn build
# --watch` on one output directory, two sidekiq on one redis index.
#
# Separate from test/wt-open.sh on purpose. That file's premise is that `wt open`
# needs no herdr socket, which is exactly what this path does need - so it gets
# the socket-and-HOME recipe from test/wt-new-url.sh instead, rather than putting
# machinery behind ten assertions that do not want it.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WT="$HERE/../.local/bin/wt"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }

FIX=$(mktemp -d)
# AF_UNIX paths cap out near 104 bytes and mktemp's is already long, so the socket
# lives at a short path of its own - same reason as test/wt-new-url.sh.
SOCK="/tmp/wt-open-dev.$$.sock"
cleanup() {
  [ -n "${SOCKPID:-}" ] && kill "$SOCKPID" 2>/dev/null
  rm -rf "$FIX"; rm -f "$SOCK"
}
trap cleanup EXIT

# wt resolves herdr as "$HOME/.local/bin/herdr", by absolute path rather than off
# PATH, so HOME has to point at a fixture holding the stub. Nothing else HOME
# reaches here matters: the XDG dirs are set explicitly below, and SELF is only
# ever the command string sent to the dev pane - which is itself an assertion.
export HOME="$FIX/home"
export XDG_STATE_HOME="$FIX/state" XDG_CONFIG_HOME="$FIX/config"
STATE_DIR="$XDG_STATE_HOME/wt"
PROFILE_DIR="$XDG_CONFIG_HOME/wt/profiles"
mkdir -p "$HOME/.local/bin" "$STATE_DIR" "$PROFILE_DIR"

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

# ── a real repo with a linked worktree ──────────────────────────────────────
REPO="$FIX/repo"
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
REPO_NAME=$(basename "$REPO")
WTP="$FIX/wt-one"
git -C "$REPO" worktree add -q -b task/one "$WTP" master

# ── stubs ───────────────────────────────────────────────────────────────────
# lsof: "is anything LISTENing". Flips from no to yes once the call count passes
# LISTEN_AFTER, which is how a foreman stack that takes a moment to bind is
# modelled - 0 means "up all along", a large number means "never comes up".
LSOF_CALLS="$FIX/lsof-calls"; LISTEN_AFTER="$FIX/listen-after"
cat > "$HOME/.local/bin/lsof" <<EOF
#!/usr/bin/env bash
n=\$(cat "$LSOF_CALLS" 2>/dev/null || echo 0); n=\$((n + 1))
printf '%s' "\$n" > "$LSOF_CALLS"
after=\$(cat "$LISTEN_AFTER" 2>/dev/null || echo 999)
[ "\$n" -gt "\$after" ] && { printf 'ruby 1 tom 20u IPv4 TCP *:x (LISTEN)\n'; exit 0; }
exit 1
EOF

# herdr: `api snapshot` serves whatever tab list the case seeded; `tab create`
# records its argv and hands back a pane id; pane send-text records the command
# string, which is what proves the XDG carry-over reaches the new shell.
TABS="$FIX/tabs.json"; TABCREATE_LOG="$FIX/tab-create"; SENT="$FIX/sent"
printf '[]' > "$TABS"; : > "$TABCREATE_LOG"; : > "$SENT"
cat > "$HOME/.local/bin/herdr" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "api snapshot")
    printf '{"result":{"snapshot":{"tabs":%s}}}' "\$(cat "$TABS")" ;;
  "tab create")
    printf '%s\n' "\$*" >> "$TABCREATE_LOG"
    printf '{"result":{"root_pane":{"pane_id":"w1:pDev"}}}' ;;
  "pane send-text")
    # argv is: pane send-text <pane_id> <text>, so the text is \$4.
    printf '%s\n' "\$4" >> "$SENT" ;;
  "pane send-keys") ;;
  "worktree list")
    printf '{"result":{"worktrees":[{"path":"%s","branch":"task/one","open_workspace_id":"wFALLBACK"}]}}' "$WTP" ;;
  *) printf '{"result":{}}' ;;
esac
exit 0
EOF

# open: records the url instead of launching a browser.
OPEN_LOG="$FIX/open-calls"; : > "$OPEN_LOG"
cat > "$HOME/.local/bin/open" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$OPEN_LOG"
exit 0
EOF
chmod +x "$HOME/.local/bin/lsof" "$HOME/.local/bin/herdr" "$HOME/.local/bin/open"
export PATH="$HOME/.local/bin:$PATH"

# ── fixtures, reset per case ────────────────────────────────────────────────
SF="$STATE_DIR/$REPO_NAME--task-one.env"
write_state() {                          # [port] [workspace]
  {
    printf 'WT_NAME=task/one\nWT_SLUG=task-one\nWT_PATH=%s\n' "$WTP"
    printf 'WT_REPO=%s\nWT_REPO_NAME=%s\n' "$REPO" "$REPO_NAME"
    printf 'WT_DOMAIN=task-one.test\nWT_URL=https://task-one.test\n'
    [ -n "${1:-}" ] && printf 'WT_PORT=%s\n' "$1"
    [ -n "${2:-}" ] && printf 'WT_WORKSPACE=%s\n' "$2"
  } > "$SF"
}
write_profile() {                        # with_dev(1|0)
  { printf 'WT_RESOURCES="port"\n'
    [ "$1" = 1 ] && printf 'wt_dev() { :; }\n'
    printf 'wt_open_url() { printf "%%s" "https://$WT_DOMAIN"; }\n'
  } > "$PROFILE_DIR/$REPO_NAME.sh"
}
reset() {                                # listen_after
  printf '0' > "$LSOF_CALLS"; printf '%s' "$1" > "$LISTEN_AFTER"
  printf '[]' > "$TABS"; : > "$TABCREATE_LOG"; : > "$SENT"; : > "$OPEN_LOG"
}
run_open() { ( cd "$WTP" && WT_DEV_WAIT=2 "$WT" open 2>&1 ); }
tabs_made() { wc -l < "$TABCREATE_LOG" | tr -d ' '; }

echo "== nothing listening and no dev tab: wt open starts one, waits, then opens ==" >&2
reset 1; write_state 3101 w1; write_profile 1
out=$(run_open)
eq "$(tabs_made)" "1" "a dev tab should be created"
case "$(cat "$TABCREATE_LOG")" in
  *"--label dev"*)     ok ;; *) bad "the tab should be labelled dev (got: $(cat "$TABCREATE_LOG"))" ;;
esac
case "$(cat "$TABCREATE_LOG")" in
  *"--workspace w1"*)  ok ;; *) bad "the tab should go in the recorded workspace" ;;
esac
case "$(cat "$TABCREATE_LOG")" in
  *"--no-focus"*)      ok ;; *) bad "the tab must not steal focus - you asked for a browser" ;;
esac
case "$(cat "$SENT")" in
  *"dev"*"$WTP"*)      ok ;; *) bad "the pane should be sent 'wt dev <path>' (got: $(cat "$SENT"))" ;;
esac
# The new pane's shell inherits nothing, so a test whose XDG dirs are overridden
# is exactly the case that breaks if the carry-over is dropped.
case "$(cat "$SENT")" in
  *XDG_STATE_HOME*XDG_CONFIG_HOME*) ok ;;
  *) bad "the sent command must carry the XDG dirs across (got: $(cat "$SENT"))" ;;
esac
case "$out" in *"dev server up"*) ok ;; *) bad "it should report the server coming up (got: $out)" ;; esac
eq "$(cat "$OPEN_LOG")" "https://task-one.test" "and still open the url afterwards"

echo "== already listening: nothing is started ==" >&2
reset 0; write_state 3101 w1; write_profile 1
out=$(run_open)
eq "$(tabs_made)" "0" "a running server means no tab"
eq "$(cat "$OPEN_LOG")" "https://task-one.test" "the url still opens"
case "$out" in *"dev server up"*|*"waiting for"*) bad "it should say nothing about starting (got: $out)" ;; *) ok ;; esac

echo "== a dev tab that is still binding: no second stack, and it is waited for ==" >&2
# The window that matters, and the commonest way into it: `wt new` makes the tab,
# foreman starts binding, and `wt open` is the next keystroke - `wt new` opens no
# browser of its own. port_listening is false for that whole window, so without
# the tab check a second stack would start here: two `yarn build --watch` on one
# output directory and two sidekiq on one redis index. Waiting rather than warning
# is what keeps this path from landing on the very dead url it exists to fix.
reset 1; write_state 3101 w1; write_profile 1
printf '[{"tab_id":"w1:tDev","workspace_id":"w1","label":"dev"}]' > "$TABS"
out=$(run_open)
eq "$(tabs_made)" "0" "an existing dev tab must stop a second one"
case "$out" in *"waiting for the 'dev' tab"*) ok ;; *) bad "it should say it is waiting on that tab (got: $out)" ;; esac
case "$out" in *"dev server up"*) ok ;; *) bad "and report it coming up (got: $out)" ;; esac
eq "$(cat "$OPEN_LOG")" "https://task-one.test" "then open the url"

echo "== a dev tab whose server never binds: warned, still no second stack ==" >&2
reset 999; write_state 3101 w1; write_profile 1
printf '[{"tab_id":"w1:tDev","workspace_id":"w1","label":"dev"}]' > "$TABS"
out=$(run_open); rc=$?
eq "$(tabs_made)" "0" "a dead dev tab must not get a second stack either"
eq "$rc" "0" "and must not fail wt open"
case "$out" in *"the 'dev' tab has the detail"*) ok ;; *) bad "it should point at the tab holding the error (got: $out)" ;; esac
eq "$(cat "$OPEN_LOG")" "https://task-one.test" "the url still opens"

echo "== a dev tab in a DIFFERENT workspace is not this worktree's ==" >&2
reset 1; write_state 3101 w1; write_profile 1
printf '[{"tab_id":"w9:tDev","workspace_id":"w9","label":"dev"}]' > "$TABS"
run_open >/dev/null
eq "$(tabs_made)" "1" "another workspace's dev tab must not gate this one"

echo "== no WT_PORT: nothing to probe, so nothing is done (the mobile profiles) ==" >&2
reset 999; write_state "" w1; write_profile 1
run_open >/dev/null
eq "$(tabs_made)" "0" "a profile that allocates no port must be left alone"
eq "$(cat "$OPEN_LOG")" "https://task-one.test" "the url still opens"

echo "== no wt_dev in the profile: there is no server to start ==" >&2
reset 999; write_state 3101 w1; write_profile 0
run_open >/dev/null
eq "$(tabs_made)" "0" "a profile with no wt_dev must be left alone"
eq "$(cat "$OPEN_LOG")" "https://task-one.test" "the url still opens"

echo "== outside herdr: no tab, and the url still opens ==" >&2
reset 999; write_state 3101 w1; write_profile 1
out=$( cd "$WTP" && HERDR_ENV=0 WT_DEV_WAIT=2 "$WT" open 2>&1 )
eq "$(tabs_made)" "0" "with no herdr there is no pane to start a server in"
eq "$(cat "$OPEN_LOG")" "https://task-one.test" "the url still opens"

echo "== no WT_WORKSPACE recorded: it falls back to herdr's own answer ==" >&2
# A state file written before WT_WORKSPACE existed, or one whose workspace was
# reopened - herdr_ws_for is what keeps those working.
reset 1; write_state 3101 ""; write_profile 1
run_open >/dev/null
case "$(cat "$TABCREATE_LOG")" in
  *"--workspace wFALLBACK"*) ok ;;
  *) bad "it should use herdr_ws_for's workspace (got: $(cat "$TABCREATE_LOG"))" ;;
esac

echo "== a server that never binds warns but never blocks the url ==" >&2
reset 999; write_state 3101 w1; write_profile 1
out=$(run_open); rc=$?
eq "$rc" "0" "a dev server that never comes up must not fail wt open"
case "$out" in *"after 2s"*) ok ;; *) bad "it should say it gave up waiting (got: $out)" ;; esac
eq "$(cat "$OPEN_LOG")" "https://task-one.test" "the url opens regardless - that is what was asked for"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
