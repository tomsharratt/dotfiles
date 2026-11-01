#!/usr/bin/env bash
# test/wt-redis.sh - the redis pool wt hands worktrees their indexes from.
#
# The pool used to be 1..WT_REDIS_MAX, a number a profile wrote down beside
# redis's own default of 16 databases - supercast's 14 kept 15 for its spec
# suite, and fourteen worktrees became the ceiling on everything pq could run.
# Now the ceiling is whatever the running redis serves (`CONFIG GET databases`),
# and a profile reserves what it must keep by name (WT_REDIS_RESERVED), so
# raising `databases` in redis.conf is the whole fix, with no second number in a
# profile to keep in step with it.
#
# And a worktree can hold two indexes - `redis` for the dev server and
# `redis_test` for its spec suite - which is where allocation gets subtle: both
# are handed out in one prepare_state, before either is written to a state
# file, so the second must not be handed the index the first just took.
#
# `redis-cli` is a PATH stub answering from $DATABASES, so nothing here reads or
# writes the machine's real redis.
#
# SC2034: the WT_* set here are read by the wt sourced below.
# SC2015: `ok` never fails, so `[ ... ] && ok || bad` is an if/else.
# shellcheck disable=SC2034,SC2015
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }
has() { case "$1" in *"$2"*) ok ;; *) bad "$3 (got '$1')" ;; esac; }

FIX=$(mktemp -d)
cleanup() { rm -rf "$FIX"; }
trap cleanup EXIT

# Exported BEFORE the source below: wt computes STATE_DIR and PROFILE_DIR (and
# SELF and HERDR, from HOME) at source time. Every path this file writes or
# removes is under $FIX, a variable wt never reads, and the cleanup removes only it.
export HOME="$FIX/home" XDG_STATE_HOME="$FIX/state" XDG_CONFIG_HOME="$FIX/config"
STATE="$FIX/state/wt"
mkdir -p "$HOME" "$STATE" "$FIX/config/wt/profiles" "$FIX/bin"

# redis-cli: `config get databases` answers as redis does - the key, then the
# value, one per line - from $FIX/databases; "down" exits 1 with nothing, as a
# redis-cli that cannot connect does. Every call is logged.
cat > "$FIX/bin/redis-cli" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$FIX/redis-calls"
d=\$(cat "$FIX/databases" 2>/dev/null)
[ "\$d" = down ] && { echo "Could not connect to Redis at 127.0.0.1:6379: Connection refused" >&2; exit 1; }
case "\$*" in
  "config get databases") printf 'databases\n%s\n' "\$d" ;;
esac
exit 0
EOF
chmod +x "$FIX/bin/redis-cli"
export PATH="$FIX/bin:$PATH"
databases() { printf '%s' "$1" > "$FIX/databases"; }

# shellcheck source=/dev/null
source "$HERE/../.local/bin/wt"

# Refuse to go on if wt resolved anywhere real: the cases below write state files
# and allocate indexes, and must only ever do it in the fixture.
[ "$STATE_DIR" = "$STATE" ] || { printf 'ABORT: wt resolved STATE_DIR=%s, not %s\n' "$STATE_DIR" "$STATE" >&2; exit 1; }
case "$PROFILE_DIR" in "$FIX"/*) ;; *) printf 'ABORT: wt resolved PROFILE_DIR=%s outside %s\n' "$PROFILE_DIR" "$FIX" >&2; exit 1 ;; esac
[ "$(command -v redis-cli)" = "$FIX/bin/redis-cli" ] || { printf 'ABORT: redis-cli is not the stub - refusing to reach a real redis\n' >&2; exit 1; }

held() {                                # slug redis [redis_test]
  { printf 'WT_PATH=/nowhere/%s\nWT_SLUG=%s\nWT_REDIS=%s\n' "$1" "$1" "$2"
    [ -n "${3:-}" ] && printf 'WT_REDIS_TEST=%s\n' "$3"
  } > "$STATE/repo--$1.env"
}
reset() { rm -f "$STATE"/*.env "$FIX/redis-calls"; WT_REDIS="" WT_REDIS_TEST="" WT_REDIS_RESERVED=""; }
# A fresh process each time, as every real `wt` invocation is - alloc_redis is
# what a subshell would run.
alloc() { ( alloc_redis ); }

echo "== the pool's ceiling is the running redis's database count ==" >&2
reset; databases 4
eq "$(alloc)" "1" "db 0 is the canonical dev db, so the floor stays 1"
held a 1; held b 2; held c 3
alloc >/dev/null && bad "with databases 4, indexes 1-3 are the whole pool" || ok
databases 64
eq "$(alloc)" "4" "raising databases in redis.conf is all it takes to grow it"

echo "== a reserved index is never handed out ==" >&2
reset; databases 64; WT_REDIS_RESERVED="1 2"
eq "$(alloc)" "3" "the profile's reserved list is skipped"
WT_REDIS_RESERVED="15"
held a 1; held b 2; held c 3; held d 4; held e 5; held f 6; held g 7
held h 8; held i 9; held j 10; held k 11; held l 12; held m 13; held n 14
eq "$(alloc)" "16" "supercast's 15 stays the canonical checkout's spec db"

echo "== both of a worktree's indexes count as held, in every state file ==" >&2
reset; databases 64
held a 1 2; held b 3 4
eq "$(alloc)" "5" "WT_REDIS_TEST is as held as WT_REDIS"

echo "== an index this process has just taken is held too ==" >&2
reset; databases 64
WT_REDIS=1
eq "$(alloc)" "2" "the second allocation of a prepare_state skips the first, still unwritten"
WT_REDIS="" WT_REDIS_TEST=3
eq "$(alloc)" "1" "and the same for a test index taken first"

echo "== a redis wt cannot reach falls back to redis's default 16 databases ==" >&2
reset; databases down
WT_REDIS_RESERVED="15"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do held "w$i" "$i"; done
alloc >/dev/null && bad "1-14 held and 15 reserved fills the default pool" || ok
databases "not-a-number"
alloc >/dev/null && bad "an answer that is not a count falls back the same way" || ok
databases 1
alloc >/dev/null && bad "a count with no index past db 0 is an empty pool" || ok

echo "== prepare_state hands a worktree two different indexes ==" >&2
reset; databases 64
REPO="$FIX/repo"
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
held other 1 2
out=$( WT_RESOURCES="redis redis_test"
       prepare_state my/task "$FIX/wt-task" "$REPO" repo >/dev/null 2>&1
       printf '%s %s' "$WT_REDIS" "$WT_REDIS_TEST" )
eq "$out" "3 4" "the dev index and the test index, both past what another worktree holds"
sf="$STATE/repo--my-task.env"
eq "$(state_get "$sf" WT_REDIS) $(state_get "$sf" WT_REDIS_TEST)" "3 4" "and both are written to its state file"
out=$( WT_RESOURCES="redis redis_test"
       prepare_state my/task "$FIX/wt-task" "$REPO" repo >/dev/null 2>&1
       printf '%s %s' "$WT_REDIS" "$WT_REDIS_TEST" )
eq "$out" "3 4" "provisioning again keeps both"

echo "== a worktree made before redis_test is handed one on its next dev boot ==" >&2
# Every supercast worktree alive when the resource arrived has a state file with
# no WT_REDIS_TEST. Provisioning again would allocate it, but supercast's
# provisioning drops and recreates the dev database - so the dev boot, which
# `wt restart` and `wt open` both reach, tops it up instead.
reset; databases 64
WTP="$FIX/wt-old"
git -C "$REPO" worktree add -q -b old/task "$WTP" master
cat > "$FIX/config/wt/profiles/repo.sh" <<'EOF'
WT_RESOURCES="redis redis_test"
wt_dev() { printf '%s' "${WT_REDIS_TEST:-none}" > "$WT_DEV_SAW"; exit 0; }
EOF
printf 'WT_PATH=%s\nWT_NAME=old/task\nWT_SLUG=old-task\nWT_REDIS=1\n' "$WTP" > "$STATE/repo--old-task.env"
held other 2 3
export WT_DEV_SAW="$FIX/saw"
"$HERE/../.local/bin/wt" dev "$WTP" >/dev/null 2>&1
eq "$(cat "$WT_DEV_SAW" 2>/dev/null)" "4" "the dev server boots with a test index of its own"
eq "$(state_get "$STATE/repo--old-task.env" WT_REDIS_TEST)" "4" "recorded, so the next boot keeps it"
eq "$(state_get "$STATE/repo--old-task.env" WT_REDIS)" "1" "and its dev index is untouched"
"$HERE/../.local/bin/wt" dev "$WTP" >/dev/null 2>&1
eq "$(cat "$WT_DEV_SAW" 2>/dev/null)" "4" "the next boot keeps the same one"

echo "== ...and with no room, boots anyway on the profile's fallback ==" >&2
databases 5
grep -v '^WT_REDIS_TEST=' "$STATE/repo--old-task.env" > "$FIX/sf" && mv "$FIX/sf" "$STATE/repo--old-task.env"
held full 4
err=$("$HERE/../.local/bin/wt" dev "$WTP" 2>&1 >/dev/null)
eq "$(cat "$WT_DEV_SAW" 2>/dev/null)" "none" "a full pool never stops the dev server"
has "$err" "no free redis db" "it says why"
eq "$(state_get "$STATE/repo--old-task.env" WT_REDIS_TEST)" "" "and records nothing"

echo "== the exhausted message names the pool redis actually serves ==" >&2
reset; databases 3
held a 1; held b 2
err=$( ( WT_RESOURCES="redis"; exhausted redis ) 2>&1 ); rc=$?
eq "$rc" "75" "a full pool is exit 75"
has "$err" "no free redis db (1-2) available" "with the range redis serves"
err=$( ( WT_REDIS_RESERVED="2"; exhausted redis ) 2>&1 )
has "$err" "1-2, less 2 reserved" "and what the profile keeps back"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
