#!/usr/bin/env bash
# test/wt-open.sh - the wt_open hook contract (Part 1 of the mobile-profiles
# plan): a profile that defines wt_open takes `wt open` over outright, its
# stdout and exit status become wt open's own, wt_open_url keeps working
# unchanged when a profile defines only that, a leading `-` argument passes
# through instead of being read as a branch name, and load_profile never lets
# wt_open leak from one repo's profile into the next repo sourced in the same
# process. `wt open` needs no herdr socket, which is what makes it testable as
# a subprocess - same reasoning as test/pq-reap.sh for `wt`.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WT="$HERE/../.local/bin/wt"

XDG_STATE_HOME=$(mktemp -d)
XDG_CONFIG_HOME=$(mktemp -d)
export XDG_STATE_HOME XDG_CONFIG_HOME
PROFILE_DIR="$XDG_CONFIG_HOME/wt/profiles"
mkdir -p "$PROFILE_DIR" "$XDG_STATE_HOME/wt"

# Stub `open` so a profile that falls back to wt_open_url (or the bare `wt open`
# default) never actually launches a browser - it just records what it was
# called with.
STUBBIN=$(mktemp -d)
OPEN_LOG="$STUBBIN/.open-calls"
: > "$OPEN_LOG"
cat > "$STUBBIN/open" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$OPEN_LOG"
exit 0
EOF
chmod +x "$STUBBIN/open"
export PATH="$STUBBIN:$PATH"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }

cleanup() { rm -rf "$XDG_STATE_HOME" "$XDG_CONFIG_HOME" "$STUBBIN" "${REPO:-}" "${WT1_PARENT:-}" "${REPO2:-}"; }
trap cleanup EXIT

# ── one real, throwaway git repo with a linked worktree ─────────────────────
REPO=$(mktemp -d)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
REPO_NAME=$(basename "$REPO")

WT1_PARENT=$(mktemp -d)
WT1="$WT1_PARENT/wt1"
git -C "$REPO" worktree add -q -b task/one "$WT1" master

# A minimal state file so cmd_open's load_state_for_path succeeds without ever
# running `wt provision` - wt open only reads this, never writes it.
cat > "$XDG_STATE_HOME/wt/$REPO_NAME--task-one.env" <<EOF
WT_NAME=task/one
WT_SLUG=task-one
WT_PATH=$WT1
WT_REPO=$REPO
WT_REPO_NAME=$REPO_NAME
WT_DOMAIN=task-one.test
EOF

echo "== a profile defining wt_open runs it, and 'open' is never called ==" >&2
cat > "$PROFILE_DIR/$REPO_NAME.sh" <<'EOF'
wt_open() { printf 'wt_open ran: %s\n' "$*"; }
EOF
out=$(cd "$WT1" && "$WT" open 2>&1)
case "$out" in *"wt_open ran:"*) ok ;; *) bad "wt_open should have run (got '$out')" ;; esac
[ ! -s "$OPEN_LOG" ] && ok || bad "'open' must never be called when a profile defines wt_open (log: $(cat "$OPEN_LOG"))"

echo "== wt_open's stdout reaches the caller, and its exit code becomes wt open's ==" >&2
cat > "$PROFILE_DIR/$REPO_NAME.sh" <<'EOF'
wt_open() { printf 'distinctive output\n'; return 7; }
EOF
out=$(cd "$WT1" && "$WT" open 2>/dev/null)
rc=$?
case "$out" in *"distinctive output"*) ok ;; *) bad "wt_open's stdout should reach the caller (got '$out')" ;; esac
eq "$rc" "7" "wt_open's non-zero exit should become wt open's own exit code"

echo "== a profile with only wt_open_url still opens the url (no regression) ==" >&2
: > "$OPEN_LOG"
cat > "$PROFILE_DIR/$REPO_NAME.sh" <<'EOF'
wt_open_url() { printf 'https://example.test/x'; }
EOF
(cd "$WT1" && "$WT" open >/dev/null 2>&1)
rc=$?
eq "$rc" "0" "wt open should succeed when the profile defines only wt_open_url"
grep -qF 'https://example.test/x' "$OPEN_LOG" && ok || bad "open should have been called with wt_open_url's url (log: $(cat "$OPEN_LOG"))"

echo "== wt open --launch-only on the current worktree: flag passed through, not read as a branch ==" >&2
cat > "$PROFILE_DIR/$REPO_NAME.sh" <<'EOF'
wt_open() { printf 'args: %s\n' "$*"; }
EOF
out=$(cd "$WT1" && "$WT" open --launch-only 2>&1)
case "$out" in
  *"no worktree name given"*|*"no saved state"*)
    bad "--launch-only must not be read as an unknown branch name (got '$out')" ;;
  *"args: --launch-only"*) ok ;;
  *) bad "wt_open should have received --launch-only as an argument (got '$out')" ;;
esac

echo "== wt open <branch> --launch-only from outside the worktree: same, with an explicit name ==" >&2
out=$(cd "$REPO" && "$WT" open task/one --launch-only 2>&1)
case "$out" in
  *"no worktree name given"*|*"no saved state"*)
    bad "an explicit branch plus --launch-only must not be misread (got '$out')" ;;
  *"args: --launch-only"*) ok ;;
  *) bad "wt_open should have received --launch-only as an argument (got '$out')" ;;
esac

echo "== load_profile: wt_open defined by one repo's profile must not leak into the next ==" >&2
REPO2=$(mktemp -d)
git init -q -b master "$REPO2"
git -C "$REPO2" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
REPO2_NAME=$(basename "$REPO2")
# REPO2 deliberately gets no profile file at all - the regression this guards
# against is wt_open surviving from the PREVIOUS profile sourced in this
# process (wt ls / wt gc load one profile after another in a single process),
# not one REPO2 would define itself. Run in a subshell so sourcing wt (which
# defines its own `main`, `msg`, etc. into this shell) can't collide with
# anything above; results come back as two lines on stdout rather than through
# the subshell's own copy of $pass/$fail, which a subshell can't mutate for us.
result=$(
  # shellcheck source=/dev/null
  source "$WT"
  load_profile "$REPO" "$REPO_NAME"
  declare -F wt_open >/dev/null && echo "sanity=ok" || echo "sanity=fail"
  load_profile "$REPO2" "$REPO2_NAME"
  declare -F wt_open >/dev/null && echo "leaked=yes" || echo "leaked=no"
)
case "$result" in *"sanity=ok"*) ok ;; *) bad "sanity: wt_open should be defined right after loading $REPO_NAME's profile (got: $result)" ;; esac
case "$result" in *"leaked=no"*) ok ;; *) bad "wt_open leaked into a profile load for a repo that defines no wt_open (got: $result)" ;; esac

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
