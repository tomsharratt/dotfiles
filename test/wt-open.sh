#!/usr/bin/env bash
# test/wt-open.sh - the wt_open hook contract (Part 1 of the mobile-profiles
# plan): a profile that defines wt_open takes `wt open` over outright, its
# stdout and exit status become wt open's own, wt_open_url keeps working
# unchanged when a profile defines only that, every argument is the profile's -
# wt open always opens the worktree it is run from - and load_profile never lets
# wt_open leak from one repo's profile into the next repo sourced in the same
# process. Then supercast's own wt_open_url: the login, on example by default or
# on the subdomain given. `wt open` needs no herdr socket, which is what makes it testable as
# a subprocess - same reasoning as test/pq-reap.sh for `wt`.
#
# SC2015: `ok` never fails, so `[ ... ] && ok || bad` is an if/else.
# shellcheck disable=SC2015
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

echo "== every argument is the profile's, a first one too - it is never a worktree name ==" >&2
: > "$OPEN_LOG"
cat > "$PROFILE_DIR/$REPO_NAME.sh" <<'EOF'
wt_open_url() { printf 'https://%s.example.test/' "$1"; }
EOF
(cd "$WT1" && "$WT" open task/one >/dev/null 2>&1)
grep -qF 'https://task/one.example.test/' "$OPEN_LOG" && ok \
  || bad "a first argument should reach wt_open_url as given (log: $(cat "$OPEN_LOG"))"

echo "== a wt_open_url that refuses stops wt open, and open is never called ==" >&2
: > "$OPEN_LOG"
cat > "$PROFILE_DIR/$REPO_NAME.sh" <<'EOF'
wt_open_url() { warn "not that one"; return 1; }
EOF
out=$(cd "$WT1" && "$WT" open nope 2>&1); rc=$?
eq "$rc" "1" "a refusal fails wt open"
case "$out" in *"not that one"*) ok ;; *) bad "and the profile's reason is what is shown (got '$out')" ;; esac
[ ! -s "$OPEN_LOG" ] && ok || bad "'open' must not be called after a refusal (log: $(cat "$OPEN_LOG"))"

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
cat > "$PROFILE_DIR/$REPO_NAME.sh" <<'EOF'
wt_open() { :; }
EOF
result=$(
  # shellcheck source=/dev/null
  source "$WT"
  load_profile "$REPO_NAME"
  declare -F wt_open >/dev/null && echo "sanity=ok" || echo "sanity=fail"
  load_profile "$REPO2_NAME"
  declare -F wt_open >/dev/null && echo "leaked=yes" || echo "leaked=no"
)
case "$result" in *"sanity=ok"*) ok ;; *) bad "sanity: wt_open should be defined right after loading $REPO_NAME's profile (got: $result)" ;; esac
case "$result" in *"leaked=no"*) ok ;; *) bad "wt_open leaked into a profile load for a repo that defines no wt_open (got: $result)" ;; esac

echo "== supercast's wt_open_url: the login on example by default, or on the subdomain given ==" >&2
supercast_url() {                       # args... -> the real profile's url, its reason on stderr
  (
    # shellcheck source=/dev/null
    source "$WT"
    # shellcheck source=/dev/null
    source "$HERE/../.config/wt/profiles/supercast.sh"
    export WT_DOMAIN=tom-x.test
    wt_open_url "$@"
  )
}
url_of() { local u rc; u=$(supercast_url "$@" 2>/dev/null); rc=$?; printf '%s %s' "$rc" "$u"; }
eq "$(url_of)" "0 https://example.tom-x.test/login?user[email]=admin@supercast.tech" "bare: the example login, the seed admin pre-filled"
eq "$(url_of example)" "0 https://example.tom-x.test/login?user[email]=admin@supercast.tech" "example named outright is the same"
eq "$(url_of app)" "0 https://app.tom-x.test/login?user[email]=admin@supercast.tech" "app is still one argument away"
eq "$(url_of mypodcast)" "0 https://mypodcast.tom-x.test/login?user[email]=admin@supercast.tech" "any other subdomain opens the same login there"
eq "$(url_of "$WT1")" "1 " "a path is refused - wt open no longer takes one"
eq "$(url_of a b)" "1 " "and so is a second argument"
err=$(supercast_url "$WT1" 2>&1 >/dev/null)
case "$err" in *"wt open takes a subdomain"*"run it from inside the worktree"*) ok ;; *) bad "the refusal says what it takes (got '$err')" ;; esac

echo "== outside a worktree, wt open asks which one - from the main checkout or from nowhere ==" >&2
# gum stands in for a person: it records the list it was shown and answers with
# the row named in PICK. The terminal is stood in for too, by sourcing wt, since
# a test has no tty on stdin.
cat > "$STUBBIN/gum" <<GUM
#!/bin/sh
cat > "$STUBBIN/.gum-items"
grep -F -- "\$PICK" "$STUBBIN/.gum-items" | head -1
GUM
chmod +x "$STUBBIN/gum"
cat > "$PROFILE_DIR/$REPO_NAME.sh" <<'EOF'
wt_open() { printf 'opened %s on %s with: %s\n' "$WT_NAME" "$(pwd -P)" "$*"; }
EOF
pick_open() {                           # dir pick args...
  local dir=$1 pick=$2; shift 2
  ( cd "$dir" && PICK=$pick bash -c 'wt=$1; shift; source "$wt"; at_terminal() { return 0; }; cmd_open "$@"' _ "$WT" "$@" 2>&1 )
}
want_pick="opened task/one on $(cd "$WT1" && pwd -P) with:"
out=$(pick_open "$REPO" "task/one")
case "$out" in *"$want_pick"*) ok ;; *) bad "from the main checkout, the picked worktree should open (got '$out')" ;; esac
grep -q "task/one" "$STUBBIN/.gum-items" && grep -q "$REPO_NAME" "$STUBBIN/.gum-items" && ok \
  || bad "the list should show repo and branch (got '$(cat "$STUBBIN/.gum-items")')"
nowhere=$(mktemp -d)
out=$(pick_open "$nowhere" "task/one" mypodcast)
rmdir "$nowhere"
case "$out" in *"$want_pick mypodcast"*) ok ;; *) bad "from outside any repo it should still pick, and pass args on (got '$out')" ;; esac
out=$(cd "$REPO" && "$WT" open </dev/null 2>&1); rc=$?
eq "$rc" "1" "with no terminal to ask at, it refuses rather than guess"
case "$out" in *"not inside a worktree"*) ok ;; *) bad "the refusal should say why (got '$out')" ;; esac
cat > "$STUBBIN/gum" <<'EOF'
#!/bin/sh
cat > /dev/null
exit 130
EOF
out=$(pick_open "$REPO" "")
case "$out" in *"opened"*) bad "cancelling the pick must open nothing (got '$out')" ;; *) ok ;; esac
rm -f "$STUBBIN/gum"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
