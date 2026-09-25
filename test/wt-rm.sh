#!/usr/bin/env bash
# test/wt-rm.sh - `wt rm` must release the resources of the worktree it was ASKED
# about, and nobody else's.
#
# The bug this pins down: state_index, state_get and load_state all read a state
# file by SOURCING it, and a source only sets the keys the file happens to carry.
# Every other WT_* is whatever the calling process already had - and a `wt` run
# from a dev server or a profile function has WT_PATH, WT_SLUG, WT_PORT and WT_DB
# exported into it by run_profile_fn. So a state file missing a key used to answer
# with the CALLER's value in its place, as though it were a recorded fact.
#
# For WT_PATH that was not a cosmetic leak. A state file with no WT_PATH of its own
# got indexed under the caller's path, and since sf_for_path takes the first match
# in glob order it then outranked the correct file for the caller's own worktree.
# `wt rm` went on to drop THAT worktree's database, delete its state file and close
# the Herdr workspace its agent was working in, while git removed the worktree it
# was actually asked to. That is a live agent killed and an unrelated environment
# torn down, and the only clue was a stale-state warning.
#
# `reap_one` is exercised directly rather than through the `wt rm` subcommand:
# cmd_rm calls need_herdr, and the interesting half is all below it. cmd_rm's own
# branch->path resolution gets its own case at the bottom, through state_get.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Exported BEFORE the source below: wt computes STATE_DIR and PROFILE_DIR at source
# time, so setting these afterwards would leave the whole file pointed at the real
# state directory - and this file writes state files and removes worktrees.
XDG_STATE_HOME=$(mktemp -d)
XDG_CONFIG_HOME=$(mktemp -d)
export XDG_STATE_HOME XDG_CONFIG_HOME
mkdir -p "$XDG_STATE_HOME/wt" "$XDG_CONFIG_HOME/wt/profiles"

STUBBIN=$(mktemp -d)
HERDR_LOG="$STUBBIN/.herdr-calls"
: > "$HERDR_LOG"
cat > "$STUBBIN/herdr" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$HERDR_LOG"
exit 0
EOF
chmod +x "$STUBBIN/herdr"

# shellcheck source=/dev/null
source "$HERE/../.local/bin/wt"

# Reassigned AFTER the source, not put on PATH: wt resolves herdr as an absolute
# path (HERDR="$HOME/.local/bin/herdr"), so a PATH stub is never consulted. Getting
# this wrong makes the workspace assertions below silently vacuous - which is the
# whole point of the test, since closing the wrong workspace is what kills an agent.
HERDR="$STUBBIN/herdr"
# in_herdr() gates every herdr call on both of these.
HERDR_ENV=1
export HERDR_ENV
HERDR_SOCKET_PATH="$STUBBIN/sock"
export HERDR_SOCKET_PATH
python3 -c "import socket; socket.socket(socket.AF_UNIX).bind('$HERDR_SOCKET_PATH')" 2>/dev/null

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }

cleanup() { rm -rf "$XDG_STATE_HOME" "$XDG_CONFIG_HOME" "$STUBBIN" "${REPO:-}" "${WTROOT:-}"; }
trap cleanup EXIT

# ── one real, throwaway git repo with two linked worktrees ──────────────────
# The names matter: `tom-aaa-victim` sorts before `tom-zzz-target` in the state dir glob,
# which is what lets a mis-indexed file win the first-match race in sf_for_path.
REPO=$(mktemp -d)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
RN=$(basename "$REPO")
WTROOT=$(mktemp -d)
git -C "$REPO" worktree add -q -b tom/aaa-victim "$WTROOT/aaa-victim" master
git -C "$REPO" worktree add -q -b tom/zzz-target "$WTROOT/zzz-target" master

# A profile that records whose resources a teardown was handed, so a wrong-target
# teardown is visible rather than merely possible.
cat > "$XDG_CONFIG_HOME/wt/profiles/$RN.sh" <<EOF
wt_teardown() { printf '%s\n' "\${WT_SLUG:-}" >> "$STUBBIN/.teardown"; }
EOF
: > "$STUBBIN/.teardown"

# The victim: caught exactly as prepare_state leaves a fresh state file between its
# first state_set and the one that records WT_PATH - and permanently, if a `wt new`
# is interrupted in that window.
victim_sf="$XDG_STATE_HOME/wt/$RN--tom-aaa-victim.env"
write_victim() {
  cat > "$victim_sf" <<EOF
WT_NAME=tom/aaa-victim
WT_SLUG=tom-aaa-victim
WT_REPO=$REPO
WT_REPO_NAME=$RN
WT_WORKSPACE=w27
EOF
}
target_sf="$XDG_STATE_HOME/wt/$RN--tom-zzz-target.env"
write_target() {
  cat > "$target_sf" <<EOF
WT_NAME=tom/zzz-target
WT_SLUG=tom-zzz-target
WT_PATH=$WTROOT/zzz-target
WT_REPO=$REPO
WT_REPO_NAME=$RN
WT_WORKSPACE=w29
EOF
}

echo "== state_index skips a WT_PATH-less file instead of indexing it under the caller's path ==" >&2
write_victim; write_target
# Exactly what a `wt` launched from a dev server or a profile function inherits.
export WT_PATH="$WTROOT/zzz-target"
sidx_load
eq "$(sf_for_path "$WTROOT/zzz-target")" "$target_sf" \
  "the target's own path must resolve to the target's state file"
[ -z "$(awk -F'\t' -v f="$victim_sf" '$2 == f { print }' <<<"$SIDX")" ] && ok \
  || bad "a state file with no WT_PATH must not appear in the index at all"

echo "== state_get reads the FILE, never the caller's variable of the same name ==" >&2
eq "$(state_get "$victim_sf" WT_PATH)" "" \
  "a key absent from the file must read empty, not as the caller's WT_PATH"
eq "$(state_get "$target_sf" WT_PATH)" "$WTROOT/zzz-target" \
  "a key the file does record must still be read"
# The live route this protects: cmd_rm resolves a worktree git no longer lists
# through state_get, and would otherwise be handed the caller's own worktree.
WT_PORT=9999 eq "$(state_get "$victim_sf" WT_PORT)" "" \
  "an absent WT_PORT must not fall through to the caller's"

echo "== reap_one releases the resources of the worktree it was asked about ==" >&2
write_victim; write_target
: > "$HERDR_LOG"; : > "$STUBBIN/.teardown"
reap_one "$REPO" "$RN" tom/zzz-target "$WTROOT/zzz-target" y >/dev/null 2>&1
eq "$(cat "$STUBBIN/.teardown")" "tom-zzz-target" \
  "teardown must run for the target's slug, not another worktree's"
[ ! -f "$target_sf" ] && ok || bad "the target's own state file should be gone"
[ -f "$victim_sf" ] && ok || bad "the victim's state file must survive - it was never asked about"
case "$(cat "$HERDR_LOG")" in
  *"--workspace w29"*) ok ;;
  *) bad "herdr should be asked to close the target's workspace w29 (got '$(cat "$HERDR_LOG")')" ;;
esac
case "$(cat "$HERDR_LOG")" in
  *"w27"*) bad "the victim's workspace w27 must never be closed - that is a live agent" ;;
  *) ok ;;
esac
eq "$(git -C "$REPO" branch --format='%(refname:short)' | tr '\n' ' ')" "master tom/aaa-victim " \
  "only the target's branch should be deleted"
[ -d "$WTROOT/aaa-victim" ] && ok || bad "the victim's worktree directory must still be there"

echo "== reap_one refuses a state file that describes a different worktree ==" >&2
# The backstop: even with the index fixed, `sf` can still be the wrong file. When no
# state file records the path being reaped, reap_one falls back to the one the BRANCH's
# slug implies - and that file may describe some other worktree entirely, which is the
# shape left behind by a worktree removed and recreated elsewhere under the same branch.
# Nothing below reap_one's load re-checks that, so the guard is the only thing standing
# between a stale record and another worktree's database, state file and live agent.
write_victim; write_target
# The target's slug file now points at the VICTIM's worktree: stale by one recreation.
cat > "$target_sf" <<EOF
WT_NAME=tom/zzz-target
WT_SLUG=stale-slug
WT_PATH=$WTROOT/aaa-victim
WT_REPO=$REPO
WT_REPO_NAME=$RN
WT_WORKSPACE=w27
EOF
: > "$HERDR_LOG"; : > "$STUBBIN/.teardown"
sidx_load
# Precondition: nothing indexes the target's own path, so the slug fallback is taken.
eq "$(sf_for_path "$WTROOT/zzz-target")" "" "precondition: the target's path is unindexed"
out=$(reap_one "$REPO" "$RN" tom/zzz-target "$WTROOT/zzz-target" n 2>&1)
case "$out" in
  *"describes $WTROOT/aaa-victim"*) ok ;;
  *) bad "should say the state file describes another worktree (got '$out')" ;;
esac
# It still tears down, but against the slug DERIVED from the branch it was asked about -
# never `stale-slug`, the one the rejected file recorded for a different worktree.
eq "$(cat "$STUBBIN/.teardown")" "tom-zzz-target" \
  "must release the target's own resources, not the ones the rejected file named"
[ -f "$target_sf" ] && ok || bad "a state file that describes another worktree must not be deleted"
case "$(cat "$HERDR_LOG")" in
  *"w27"*) bad "must not close the workspace named by a state file it rejected" ;;
  *) ok ;;
esac
[ -d "$WTROOT/aaa-victim" ] && ok || bad "the worktree that file describes must be untouched"
[ ! -d "$WTROOT/zzz-target" ] && ok \
  || bad "the worktree it WAS asked about should still be removed - a leak, not a no-op"

# ── work that exists nowhere else ───────────────────────────────────────────
# `wt rm --yes` is `git worktree remove --force` plus `git branch -D`, and pq runs
# it unattended the moment a pull request settles. Edits nobody committed, files
# nobody added and commits nobody pushed exist only in the worktree and its
# branch, so both are gone for good once it runs. It must refuse them, with an
# exit code of its own so pq can tell a refusal from a failure, before anything
# at all is released - the teardown drops the database first.
#
# `gh` answers "which commit heads each pull request" from $PR_HEADS, one
# `branch sha` per line, which is how the pruned-remote case below is staged.
PR_HEADS="$STUBBIN/.pr-heads"
: > "$PR_HEADS"
cat > "$STUBBIN/gh" <<EOF
#!/bin/sh
head=""
while [ \$# -gt 0 ]; do
  [ "\$1" = --head ] && { head=\$2; shift; }
  shift
done
[ -n "\$head" ] || exit 1
awk -v b="\$head" '\$1 == b { print \$2 }' "$PR_HEADS"
EOF
chmod +x "$STUBBIN/gh"
export PATH="$STUBBIN:$PATH"

# A worktree on its own branch, with one commit of its own on top of master.
mk_wt() {                               # name -> its path
  git -C "$REPO" worktree add -q -b "tom/$1" "$WTROOT/$1" master
  git -C "$WTROOT/$1" -c user.email=test@test -c user.name=test commit -q --allow-empty -m "work on $1"
  printf '%s' "$WTROOT/$1"
}
# The same worktree's commit, pushed: a remote-tracking ref pointing at its tip.
mk_pushed() { git -C "$REPO" update-ref "refs/remotes/origin/tom/$1" "refs/heads/tom/$1"; }
# `wt rm` as pq runs it: from inside the repo, answering both prompts with --yes.
rm_yes() { ( cd "$REPO" && cmd_rm --yes "tom/$1" ) >/dev/null 2>&1; }
branch_exists() { git -C "$REPO" show-ref --verify --quiet "refs/heads/tom/$1"; }

echo "== wt rm --yes refuses a worktree with uncommitted changes ==" >&2
p=$(mk_wt dirty); mk_pushed dirty
printf 'unsaved\n' > "$p/edited.txt"
: > "$STUBBIN/.teardown"
rm_yes dirty; rc=$?
eq "$rc" 3 "an uncommitted file must be refused, with the refusal's own exit code"
[ -f "$p/edited.txt" ] && ok || bad "the uncommitted file must still be there"
branch_exists dirty && ok || bad "the branch must not be deleted"
[ ! -s "$STUBBIN/.teardown" ] && ok || bad "nothing may be released before the refusal - the teardown drops the database"
out=$( ( cd "$REPO" && cmd_rm --yes tom/dirty ) 2>&1 >/dev/null)
case "$out" in *"1 uncommitted file"*) ok ;; *) bad "the refusal must say what is at stake (got '$out')" ;; esac

echo "== wt rm --yes refuses a worktree whose commits were never pushed ==" >&2
p=$(mk_wt ahead)
rm_yes ahead; rc=$?
eq "$rc" 3 "a commit on no remote must be refused"
[ -d "$p" ] && ok || bad "the worktree must still be there"
branch_exists ahead && ok || bad "the branch holding the only copy of the commit must survive"
out=$( ( cd "$REPO" && cmd_rm --yes tom/ahead ) 2>&1 >/dev/null)
case "$out" in *"1 unpushed commit"*) ok ;; *) bad "the refusal must count the unpushed commit (got '$out')" ;; esac

echo "== ...including a commit made after the last push ==" >&2
p=$(mk_wt later); mk_pushed later
git -C "$p" -c user.email=test@test -c user.name=test commit -q --allow-empty -m "after the push"
rm_yes later; rc=$?
eq "$rc" 3 "a commit ahead of the pushed tip must be refused"
branch_exists later && ok || bad "the branch must survive"

echo "== an untracked file is work too ==" >&2
p=$(mk_wt untracked); mk_pushed untracked
printf 'new\n' > "$p/new-file.rb"
rm_yes untracked; rc=$?
eq "$rc" 3 "a file nobody added must be refused"
[ -f "$p/new-file.rb" ] && ok || bad "the untracked file must still be there"

echo "== a clean, pushed worktree is removed as before ==" >&2
p=$(mk_wt clean); mk_pushed clean
: > "$STUBBIN/.teardown"
rm_yes clean; rc=$?
eq "$rc" 0 "a worktree with nothing unsaved must be removed"
[ ! -d "$p" ] && ok || bad "its directory must be gone"
branch_exists clean && bad "its branch must be deleted under --yes" || ok
eq "$(cat "$STUBBIN/.teardown")" "tom-clean" "and its resources released"

echo "== a branch the forge pruned after its merge is not a false alarm ==" >&2
# GitHub deletes a pull request's branch once it merges, and a pruning fetch then
# takes the remote-tracking ref too - so every commit reads as on no remote. The
# forge still names the tip as the pull request's head, and that settles it.
p=$(mk_wt pruned)
printf 'tom/pruned %s\n' "$(git -C "$p" rev-parse HEAD)" > "$PR_HEADS"
rm_yes pruned; rc=$?
eq "$rc" 0 "a tip the forge holds as a pull request's head was pushed"
[ ! -d "$p" ] && ok || bad "so the worktree is removed"
: > "$PR_HEADS"

echo "== ...but a local commit on top of that head still counts ==" >&2
p=$(mk_wt pruned2)
printf 'tom/pruned2 %s\n' "$(git -C "$p" rev-parse HEAD)" > "$PR_HEADS"
git -C "$p" -c user.email=test@test -c user.name=test commit -q --allow-empty -m "never pushed"
rm_yes pruned2; rc=$?
eq "$rc" 3 "a commit past the pull request's head was never pushed"
: > "$PR_HEADS"

echo "== at a terminal, wt rm asks instead - and N keeps everything ==" >&2
# at_terminal stands in for a tty, in the subshell only.
out=$( ( at_terminal() { return 0; }; cd "$REPO" && cmd_rm tom/dirty ) <<<$'n\n' 2>&1 >/dev/null); rc=$?
eq "$rc" 0 "declining is a clean cancel"
case "$out" in *"1 uncommitted file"*"edited.txt"*) ok ;; *) bad "the question must name what would be lost (got '$out')" ;; esac
case "$out" in *"discard"*) ok ;; *) bad "and ask about discarding it in so many words (got '$out')" ;; esac
[ -f "$WTROOT/dirty/edited.txt" ] && ok || bad "declining must keep the work"

echo "== ...and y discards it, on your say-so ==" >&2
( at_terminal() { return 0; }; cd "$REPO" && cmd_rm tom/dirty ) <<<$'y\ny\n' >/dev/null 2>&1; rc=$?
eq "$rc" 0 "an explicit yes removes it"
[ ! -d "$WTROOT/dirty" ] && ok || bad "the worktree goes once you have said so"

echo "== wt gc --settled leaves a settled worktree holding unpushed work where it is ==" >&2
p=$(mk_wt settled-dirty); mk_pushed settled-dirty
printf 'unsaved\n' > "$p/edited.txt"
q=$(mk_wt settled-clean); mk_pushed settled-clean
# Both pull requests merged; gc_settled asks through pr_load's batch list.
cat > "$STUBBIN/gh" <<'EOF'
#!/bin/sh
case "$*" in
  *"pr list --state all --limit 200"*)
    printf '[{"number":1,"state":"MERGED","headRefName":"tom/settled-dirty"},{"number":2,"state":"MERGED","headRefName":"tom/settled-clean"}]\n' ;;
  *) printf '[]\n' ;;
esac
EOF
printf 'WT_REPO=%s\nWT_PATH=%s\n' "$REPO" "$q" > "$XDG_STATE_HOME/wt/$RN--tom-settled-clean.env"
out=$( (cd / && gc_settled 1) 2>&1 >/dev/null)
[ -f "$p/edited.txt" ] && ok || bad "a settled worktree with uncommitted work must be left alone, even under -y"
branch_exists settled-dirty && ok || bad "and its branch kept"
[ ! -d "$q" ] && ok || bad "a clean settled worktree beside it is still reclaimed"
case "$out" in *"tom/settled-dirty"*"1 uncommitted file"*) ok ;; *) bad "gc must say which worktree it left and why (got '$out')" ;; esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
