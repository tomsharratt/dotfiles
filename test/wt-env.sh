#!/usr/bin/env bash
# test/wt-env.sh - the supercast profile's wt_env picks a database from RAILS_ENV.
#
# Why this file exists: which database a worktree's specs hit is decided entirely
# here, and getting it wrong is SILENT. database.yml's `test:` entry carries both
# `url:` (reading DATABASE_URL) and an explicit `database: supercast-web_test`, and
# ActiveRecord merges the url on top of the yaml - so DATABASE_URL wins in every
# environment. Before this branch, `wt run` handed a test command the worktree's
# DEV database (a spec run loading schema over the data its own dev server was
# serving) and a bare `bundle exec rspec` fell through to the one machine-wide
# supercast-web_test that every other worktree was using too.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Exported BEFORE the source below: wt computes STATE_DIR and PROFILE_DIR at source
# time, so setting these afterwards would leave this file pointed at the real state
# directory.
XDG_STATE_HOME=$(mktemp -d)
XDG_CONFIG_HOME=$(mktemp -d)
export XDG_STATE_HOME XDG_CONFIG_HOME
mkdir -p "$XDG_STATE_HOME/wt" "$XDG_CONFIG_HOME/wt/profiles"

# wt for msg/warn, then the profile under test - the same pairing test/wt-sweep.sh
# uses. wt_env only exports variables, so nothing here needs a database stub, a
# git repo or a herdr socket.
# shellcheck source=/dev/null
source "$HERE/../.local/bin/wt"
# shellcheck source=/dev/null
source "$HERE/../.config/wt/profiles/supercast.sh"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }

cleanup() { rm -rf "$XDG_STATE_HOME" "$XDG_CONFIG_HOME"; }
trap cleanup EXIT

WT_SLUG=tom-login-code-submit-button
WT_PORT=3104
WT_REDIS=3
WT_DOMAIN=tom-login-code-submit-button.test
DEV_DB=$(_wt_db)
TEST_DB=$(_wt_test_db)

# A subshell per case: wt_env exports into the shell it runs in, and a value left
# behind would make the next case pass for the wrong reason.
envvar() {                              # rails_env key -> the exported value
  ( if [ -n "$1" ]; then export RAILS_ENV="$1"; else unset RAILS_ENV; fi
    wt_env >/dev/null 2>&1
    eval "printf '%s' \"\${$2:-}\"" )
}

echo "== with no RAILS_ENV, wt_env is exactly what it always was ==" >&2
eq "$(envvar "" DATABASE_URL)" "postgres:///$DEV_DB" \
  "a plain \`wt run\` must still get the worktree's dev database, socket form and all"

echo "== RAILS_ENV=test selects the worktree's own test database ==" >&2
eq "$(envvar test DATABASE_URL)" "postgres://localhost/$TEST_DB" \
  "\`wt test\` must get this worktree's test database, not its dev copy"
[ "$(envvar test DATABASE_URL)" != "$(envvar "" DATABASE_URL)" ] && ok \
  || bad "the test and dev database urls must never be the same string"

echo "== the test url names localhost EXPLICITLY ==" >&2
# Not cosmetic, and the reason is invisible from here: DatabaseCleaner's safeguard
# raises on a DATABASE_URL it reads as remote. It allows localhost, 127.0.0.1 and
# *.local, and returns early when there is no host - but
# URI.parse("postgres:///x").host is "", an empty string, which is TRUTHY in ruby,
# so the socket form sails past that no-host check, matches none of the allowed
# hosts, and is rejected. A regression to `postgres:///` here would not fail this
# suite at all; it would fail every spec run in every worktree, much later, with an
# error naming DatabaseCleaner rather than wt. So it is asserted directly.
turl=$(envvar test DATABASE_URL)
case "$turl" in
  postgres://localhost/*) ok ;;
  *) bad "the test url must carry an explicit localhost host (got '$turl')" ;;
esac
case "$turl" in
  postgres:///*) bad "the socket form is rejected by DatabaseCleaner's safeguard - see above" ;;
  *) ok ;;
esac

echo "== only 'test' switches; every other value is the dev database ==" >&2
# The check is `= test`, so anything else - development, production, a typo, an
# empty string - has to land on the dev copy rather than somewhere new.
for env in development production "" testing Test; do
  eq "$(envvar "$env" DATABASE_URL)" "postgres:///$DEV_DB" \
    "RAILS_ENV='$env' must resolve to the dev database"
done

echo "== nothing else wt_env exports is affected by RAILS_ENV ==" >&2
for env in "" test; do
  eq "$(envvar "$env" PORT)" "3104" "PORT is unchanged (RAILS_ENV='$env')"
  eq "$(envvar "$env" REDIS_URL)" "redis://localhost:6379/3" \
    "REDIS_URL is unchanged (RAILS_ENV='$env') - the test redis index is NOT isolated"
  eq "$(envvar "$env" LOCAL_DOMAIN)" "$WT_DOMAIN" "LOCAL_DOMAIN is unchanged (RAILS_ENV='$env')"
  eq "$(envvar "$env" domain)" "$WT_DOMAIN" "domain is unchanged (RAILS_ENV='$env')"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
