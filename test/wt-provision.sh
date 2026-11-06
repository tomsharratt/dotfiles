#!/usr/bin/env bash
# test/wt-provision.sh - a worktree's state file records its path absolute,
# however the path was handed to wt.
#
# The bug this pins: an implementer whose .test url 500ed ran `wt provision .`
# from inside its worktree, and prepare_state stored WT_PATH=. verbatim. WT_PATH
# is the key every later lookup finds a state file by, and state_index resolves
# it against whoever is asking - so from then on the file described whichever
# worktree the next `wt` ran in, and when the pull request merged `wt rm` found it
# describing `.`, not the worktree it was removing, ignored it, and left the port
# and both redis indexes behind for good.
#
# Driven through the real `wt provision`, with a profile whose wt_provision does
# nothing but record that it ran.
#
# SC2034: the WT_* set in the guard's subshells are read by provision_guard.
# SC2015: `ok` never fails, so `[ ... ] && ok || bad` is an if/else.
# shellcheck disable=SC2015,SC2034
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=test/sandbox.sh
source "$HERE/sandbox.sh"
WT="$HERE/../.local/bin/wt"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }
state_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1; }   # file key

FIX=$(cd "$(mktemp -d)" && pwd -P)
cleanup() { sandbox_cleanup; }
trap cleanup EXIT

export HOME="$FIX/home" XDG_STATE_HOME="$FIX/state" XDG_CONFIG_HOME="$FIX/config"
STATE="$FIX/state/wt"
mkdir -p "$HOME" "$STATE" "$FIX/config/wt/profiles"
sandbox_guard

REPO="$FIX/repo"
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
WTP="$FIX/wt-task"
git -C "$REPO" worktree add -q -b my/task "$WTP" master
cat > "$FIX/config/wt/profiles/repo.sh" <<'EOF'
wt_provision() { wt_state_set WT_URL "https://$WT_DOMAIN"; }
EOF
sf="$STATE/repo--my-task.env"

echo "== wt provision . records the worktree's absolute path ==" >&2
( cd "$WTP" && "$WT" provision . >/dev/null 2>&1 )
eq "$(state_get "$sf" WT_PATH)" "$WTP" "the state file names the worktree, not the caller's '.'"
eq "$(state_get "$sf" WT_URL)" "https://my-task.test" "and provisioning ran to the end"

echo "== a relative path from elsewhere is resolved the same way ==" >&2
rm -f "$sf"
( cd "$FIX" && "$WT" provision wt-task >/dev/null 2>&1 )
eq "$(state_get "$sf" WT_PATH)" "$WTP" "wt-task from the fixture root is the same worktree"

echo "== re-provisioning a worktree stuck with '.' heals its state file ==" >&2
# The worktree this was found on: the file already says `.`. Provisioning again
# from inside it must find that file - by the slug, since the path names nothing
# - and correct it, never fork a second one.
printf 'WT_PATH=.\nWT_NAME=my/task\nWT_SLUG=my-task\nWT_REPO=%s\nWT_REPO_NAME=repo\n' "$REPO" > "$sf"
( cd "$WTP" && "$WT" provision >/dev/null 2>&1 )
eq "$(state_get "$sf" WT_PATH)" "$WTP" "the '.' is replaced by the real path"
eq "$(find "$STATE" -name '*.env' | wc -l | tr -d ' ')" "1" "and there is still exactly one state file"

# ── provisioning in progress ────────────────────────────────────────────────
# `wt new` provisions in the dev tab, and `wt restart` closes that tab - so a
# restart sent while it ran killed it, 17 seconds in, and left a worktree with no
# puma-dev route and no url or database on file. Provisioning now marks itself
# while it runs; restart and stop wait for it rather than kill it.
# shellcheck source=/dev/null
source "$WT"
mark=$(provision_mark "$sf")
profile() { printf '%s\n' "$1" > "$FIX/config/wt/profiles/repo.sh"; }

echo "== a provisioning that succeeds leaves no mark ==" >&2
profile 'wt_provision() { :; }'
( cd "$WTP" && "$WT" provision >/dev/null 2>&1 )
[ ! -e "$mark" ] && ok || bad "the mark goes once provisioning succeeds"
eq "$(provision_status "$sf")" "" "and the worktree reads as provisioned"

echo "== one that fails is marked failed, and restart refuses it ==" >&2
profile 'wt_provision() { return 1; }'
( cd "$WTP" && "$WT" provision >/dev/null 2>&1 ); rc=$?
eq "$rc" 1 "wt provision still exits with the failure"
eq "$(provision_status "$sf")" failed "the worktree reads as failed"
err=$( (WT_STATE_FILE=$sf WT_PATH=$WTP; provision_guard restarting) 2>&1 ); rc=$?
[ "$rc" != 0 ] && ok || bad "the guard stops a restart of a worktree whose provisioning failed"
case "$err" in *"provisioning failed"*"wt provision $WTP"*) ok ;; *) bad "and says how to fix it (got '$err')" ;; esac

echo "== one that is running is waited for, not killed ==" >&2
profile "wt_provision() { while [ ! -e '$FIX/go' ]; do sleep 0.1; done; }"
rm -f "$FIX/go"
( cd "$WTP" && exec "$WT" provision >/dev/null 2>&1 ) &
ppid=$!
for _ in $(seq 1 50); do [ "$(provision_status "$sf")" = running ] && break; sleep 0.1; done
eq "$(provision_status "$sf")" running "a provisioning under way reads as running"
( sleep 2; touch "$FIX/go" ) &
start=$SECONDS
err=$( (WT_STATE_FILE=$sf WT_PATH=$WTP; provision_guard restarting; echo "rc=$? waited=$PROVISION_WAITED") 2>&1 )
case "$err" in *"rc=0 waited=1"*) ok ;; *) bad "the guard waits it out and then lets the restart go on (got '$err')" ;; esac
[ $((SECONDS - start)) -ge 1 ] && ok || bad "and it really did wait"
wait "$ppid" 2>/dev/null
eq "$(provision_status "$sf")" "" "the finished provisioning took its mark with it"

echo "== one that was killed reads as interrupted ==" >&2
rm -f "$FIX/go"
( cd "$WTP" && exec "$WT" provision >/dev/null 2>&1 ) &
ppid=$!
for _ in $(seq 1 50); do [ "$(provision_status "$sf")" = running ] && break; sleep 0.1; done
kill -KILL "$ppid"; wait "$ppid" 2>/dev/null
eq "$(provision_status "$sf")" interrupted "a provisioning that died mid-way is not mistaken for running or done"
err=$( (WT_STATE_FILE=$sf WT_PATH=$WTP; provision_guard restarting) 2>&1 ); rc=$?
case "$rc:$err" in 0:*) bad "the guard must stop a restart of a half-provisioned worktree" ;; *"run it again: wt provision $WTP"*) ok ;; *) bad "and says to provision again (got '$err')" ;; esac
touch "$FIX/go"

echo "== one that ends as it is read is not mistaken for a kill ==" >&2
# A provisioning ends by taking its mark away, or writing `failed` into it, and
# then exiting; a read that lands between the two once said `interrupted`, and
# the waiting test above failed about one run in eight. `kill` stands in for the
# process ending exactly as its pid is checked.
# shellcheck disable=SC2329,SC2317  # called by provision_status, not here
kill() { rm -f "$mark"; return 1; }
printf '%s\n' "$$" > "$mark"
eq "$(provision_status "$sf")" "" "a mark taken away as its pid was checked: it finished"
# shellcheck disable=SC2329,SC2317
kill() { printf 'failed\n' > "$mark"; return 1; }
printf '%s\n' "$$" > "$mark"
eq "$(provision_status "$sf")" failed "and one marked failed as it was checked: it failed"
unset -f kill
rm -f "$mark"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
