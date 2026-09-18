#!/usr/bin/env bash
# test/pq-evidence.sh - `pq evidence`: publishing a task's screenshots to the
# one shared pq-evidence branch with plumbing, and printing the markdown.
#
# A local bare repository stands in for origin, so every push here is real git
# against a real remote and nothing reaches the network. `gh` is stubbed to
# answer the one question asked of it (the repository's owner/name).
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PQ_HOME=$(mktemp -d)
export PQ_HOME

REALGIT=$(command -v git)
STUBBIN=$(mktemp -d)
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/claude"
cat > "$STUBBIN/gh" <<'EOF'
#!/bin/sh
case "$*" in
  *"repo view"*) printf 'Acme/widgets\n'; exit 0 ;;
esac
exit 1
EOF
cat > "$STUBBIN/herdr" <<'EOF'
#!/bin/sh
case "$*" in
  "api snapshot") echo '{"result":{"snapshot":{"panes":[]}}}'; exit 0 ;;
esac
exit 1
EOF
# A `git` wrapper for the concurrency case: when the flag file exists, the
# first `push` first advances the bare branch behind pq's back (a competitor
# publishing between pq's fetch and its push), then runs the real push, which
# the bare repo rejects as a non-fast-forward.
RACE_FLAG="$STUBBIN/.race"
cat > "$STUBBIN/git" <<EOF
#!/bin/sh
case " \$* " in
  *" push "*)
    if [ -f "$RACE_FLAG" ]; then
      rm -f "$RACE_FLAG"
      sh "$STUBBIN/compete.sh"
    fi ;;
esac
exec "$REALGIT" "\$@"
EOF
chmod +x "$STUBBIN/claude" "$STUBBIN/gh" "$STUBBIN/herdr" "$STUBBIN/git"
export PATH="$STUBBIN:$PATH"

# shellcheck source=/dev/null
source "$HERE/../.local/bin/pq"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }
has() { case "$1" in *"$2"*) ok ;; *) bad "$3 (got '$1')" ;; esac; }

cleanup() { rm -rf "$PQ_HOME" "$STUBBIN" "${BARE:-}" "${REPO:-}"; }
trap cleanup EXIT

# origin, and a clone of it that plays both the repo and the task's worktree.
BARE=$(mktemp -d)
"$REALGIT" init -q --bare -b master "$BARE"
REPO=$(mktemp -d)
"$REALGIT" clone -q "$BARE" "$REPO" 2>/dev/null
"$REALGIT" -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
"$REALGIT" -C "$REPO" push -q origin master 2>/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

# The competitor: adds one file under other/ on top of the bare's current
# pq-evidence tip, straight into the bare repo with plumbing.
cat > "$STUBBIN/compete.sh" <<EOF
set -e
export GIT_AUTHOR_NAME=other GIT_AUTHOR_EMAIL=o@o GIT_COMMITTER_NAME=other GIT_COMMITTER_EMAIL=o@o
tip=\$("$REALGIT" -C "$BARE" rev-parse --verify --quiet refs/heads/pq-evidence) || tip=""
idx="$STUBBIN/.compete.index"; rm -f "\$idx"
if [ -n "\$tip" ]; then GIT_INDEX_FILE=\$idx "$REALGIT" -C "$BARE" read-tree "\$tip"; else GIT_INDEX_FILE=\$idx "$REALGIT" -C "$BARE" read-tree --empty; fi
blob=\$(printf 'theirs\n' | "$REALGIT" -C "$BARE" hash-object -w --stdin)
GIT_INDEX_FILE=\$idx "$REALGIT" -C "$BARE" update-index --add --cacheinfo "100644,\$blob,other/theirs.png"
tree=\$(GIT_INDEX_FILE=\$idx "$REALGIT" -C "$BARE" write-tree)
if [ -n "\$tip" ]; then c=\$("$REALGIT" -C "$BARE" commit-tree "\$tree" -p "\$tip" -m "evidence: other"); else c=\$("$REALGIT" -C "$BARE" commit-tree "\$tree" -m "evidence: other"); fi
"$REALGIT" -C "$BARE" update-ref refs/heads/pq-evidence "\$c"
EOF

mkdir -p "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done"
mk_task() {                             # prio slug worktree -> task_dir (done/)
  local dir="$PQ_HOME/done/$(printf '%014d' $(( 20260101000000 + 10#$1 )))-$2"
  mkdir -p "$dir/evidence"
  {
    printf -- '---\n'
    printf 'repo:     %s\n' "$REPO"
    printf 'branch:   tom/%s\n' "$2"
    printf 'model:    sonnet\n'
    printf 'effort:   xhigh\n'
    printf 'intent:   test fixture\n'
    printf 'added:    2026-01-01T00:00:00Z\n'
    printf -- '---\n\nplan body\n'
  } > "$dir/plan.md"
  st_set "$dir" PQ_WORKTREE "$3"
  printf '%s' "$dir"
}
tree_of() { "$REALGIT" -C "$BARE" ls-tree -r --name-only refs/heads/pq-evidence 2>/dev/null | sort | tr '\n' ' '; }
# Every `main evidence` runs in a subshell: cmd_evidence sets its own EXIT trap
# for its temporary index and clears it afterwards, which would drop this
# file's cleanup trap if it ran in this shell.
publish() { ( main evidence "$@" ) ; }

echo "== the first publish creates the branch with <slug>/<file> ==" >&2
A=$(mk_task 001 alpha "$REPO")
printf 'PNG-A\n' > "$A/evidence/01-home-before.png"
out=$(publish alpha 2>"$PQ_HOME/.err"); rc=$?
eq "$rc" "0" "publishing should succeed: $(cat "$PQ_HOME/.err")"
eq "$out" "![01-home-before.png](https://github.com/Acme/widgets/raw/pq-evidence/alpha/01-home-before.png)" \
  "stdout is exactly the markdown image line"
"$REALGIT" -C "$BARE" show-ref --verify --quiet refs/heads/pq-evidence && ok || bad "the branch should now exist on origin"
eq "$(tree_of)" "alpha/01-home-before.png " "the tree holds the file under the slug"
eq "$("$REALGIT" -C "$BARE" log -1 --format=%s refs/heads/pq-evidence)" "evidence: alpha" "the commit names the slug"
has "$(cat "$PQ_HOME/.err")" "published 1 file(s) to pq-evidence/alpha/" "the human line is on stderr"
# The worktree itself is untouched: no checkout, no index change, no new branch.
eq "$("$REALGIT" -C "$REPO" status --porcelain | wc -l | tr -d ' ')" "0" "the worktree stays clean"
"$REALGIT" -C "$REPO" show-ref --verify --quiet refs/heads/pq-evidence && bad "no local branch is created" || ok
eq "$("$REALGIT" -C "$REPO" rev-parse --abbrev-ref HEAD)" "master" "and HEAD is where it was"

echo "== a second task appends without disturbing the first ==" >&2
B=$(mk_task 002 beta "$PQ_HOME/no-such-worktree")   # gone: falls back to the repo
printf 'PNG-B\n' > "$B/evidence/01-settings-after.png"
printf 'notes\n' > "$B/evidence/notes.txt"           # not an image: never published
out=$(publish beta 2>/dev/null); rc=$?
eq "$rc" "0" "the second publish succeeds"
eq "$(tree_of)" "alpha/01-home-before.png beta/01-settings-after.png " "both slugs' files are in the tree, and the .txt is not"
eq "$("$REALGIT" -C "$BARE" rev-list --count refs/heads/pq-evidence)" "2" "one commit per publish"

echo "== re-publishing replaces the slug's own files and nothing else ==" >&2
rm "$A/evidence/01-home-before.png"
printf 'PNG-A2\n' > "$A/evidence/01-home-after.png"
printf 'PNG-A3\n' > "$A/evidence/02-home responsive.png"
out=$(publish alpha 2>/dev/null); rc=$?
eq "$rc" "0" "re-publishing succeeds"
eq "$(tree_of)" "alpha/01-home-after.png alpha/02-home responsive.png beta/01-settings-after.png " \
  "alpha's old file is gone, its new ones are in, beta is untouched"
has "$out" "raw/pq-evidence/alpha/02-home%20responsive.png" "a space in a filename is percent-encoded in the url"
has "$out" "![02-home responsive.png]" "but left alone in the alt text"
eq "$(wc -l <<<"$out" | tr -d ' ')" "2" "one line per file published"

echo "== a concurrent publish is retried on top of the competitor ==" >&2
touch "$RACE_FLAG"
printf 'PNG-B2\n' > "$B/evidence/02-settings-before.png"
out=$(publish beta 2>"$PQ_HOME/.err"); rc=$?
eq "$rc" "0" "a rejected push is retried, not fatal: $(cat "$PQ_HOME/.err")"
[ -f "$RACE_FLAG" ] && bad "the race should have fired" || ok
has "$(cat "$PQ_HOME/.err")" "was rejected (another task published first?) - rebuilding" "the retry is announced"
eq "$(tree_of)" "alpha/01-home-after.png alpha/02-home responsive.png beta/01-settings-after.png beta/02-settings-before.png other/theirs.png " \
  "the competitor's file survives and ours land beside it"
eq "$("$REALGIT" -C "$BARE" log -1 --format=%s refs/heads/pq-evidence)" "evidence: beta" "ours is the tip"
eq "$("$REALGIT" -C "$BARE" log -2 --format=%s refs/heads/pq-evidence | tail -1)" "evidence: other" "built on theirs"

echo "== stdout carries only markdown ==" >&2
out=$(publish beta 2>/dev/null)
eq "$(grep -vc '^!\[' <<<"$out")" "0" "every stdout line is an image line"
err=$(publish beta 2>&1 >/dev/null)
[ -n "$err" ] && ok || bad "the human report goes to stderr"

echo "== resolving the task from the cwd ==" >&2
out=$(cd "$REPO" && publish 2>/dev/null); rc=$?
eq "$rc" "0" "inside the worktree, no argument is needed"
has "$out" "raw/pq-evidence/alpha/" "and it resolves to the task whose PQ_WORKTREE this is"
( cd / && publish ) >/dev/null 2>"$PQ_HOME/.err" && bad "outside any worktree, with no argument, it must die" || ok
has "$(cat "$PQ_HOME/.err")" "not inside a task's worktree" "and say how to name the task"

echo "== an empty evidence/ dies ==" >&2
E=$(mk_task 003 empty "$REPO")
( publish empty ) >/dev/null 2>"$PQ_HOME/.err" && bad "nothing to publish must fail" || ok
has "$(cat "$PQ_HOME/.err")" "nothing to publish" "and say so"
"$REALGIT" -C "$BARE" ls-tree -r --name-only refs/heads/pq-evidence | grep -q '^empty/' && bad "and push nothing" || ok

echo "== a gh that cannot name the repo dies before pushing ==" >&2
mkdir -p "$STUBBIN/nogh"; printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/nogh/gh"; chmod +x "$STUBBIN/nogh/gh"
G=$(mk_task 004 gamma "$REPO")
printf 'PNG\n' > "$G/evidence/x.png"
n_before=$("$REALGIT" -C "$BARE" rev-list --count refs/heads/pq-evidence)
( PATH="$STUBBIN/nogh:$PATH" publish gamma ) >/dev/null 2>"$PQ_HOME/.err" && bad "no owner/name means no urls, so it must die" || ok
has "$(cat "$PQ_HOME/.err")" "could not read the GitHub repository name" "and say why"
eq "$("$REALGIT" -C "$BARE" rev-list --count refs/heads/pq-evidence)" "$n_before" "with nothing pushed"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
