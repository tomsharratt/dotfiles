#!/usr/bin/env bash
# test/wt-sweep.sh - the supercast profile's database naming, and the one thing
# `wt gc --sweep` must never do: drop a live worktree's database.
#
# postgres identifiers are NAMEDATALEN-1 = 63 bytes, so `createdb` silently
# accepts a longer name and creates a shorter one. `_wt_db` did not truncate, so
# for any slug over the limit every later lookup asked for a name that was not
# there: `_wt_dropdb` found nothing and reported "no such database", leaving the
# database behind on `wt rm` and on every sweep after it.
#
# The sweep failure was the dangerous one. It recovered a slug from a database
# NAME by stripping the prefix and swapping underscores back to dashes - and a
# truncated name has no slug to recover, so the slug it built matched nothing on
# the live list and a LIVE worktree's database looked exactly like an orphan.
# Seven of supercast's thirteen worktree databases were over the limit when this
# was found.
#
# The profile is sourced directly. It needs msg/warn from wt and reads psql and
# dropdb from PATH, both of which are stubbed, so nothing here touches a real
# database.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

XDG_STATE_HOME=$(mktemp -d)
XDG_CONFIG_HOME=$(mktemp -d)
export XDG_STATE_HOME XDG_CONFIG_HOME
mkdir -p "$XDG_STATE_HOME/wt"
# HOME too, and before the profile is sourced. wt_sweep also sweeps
# $HOME/.puma-dev, and a real sweep below runs against two made-up live slugs -
# so with the real HOME it deleted the route of every actual worktree, and each
# one's .test url died at the next puma-dev restart.
HOME=$(mktemp -d)
export HOME
mkdir -p "$HOME/.puma-dev"

STUBBIN=$(mktemp -d)
DB_LIST="$STUBBIN/.databases"
DROP_LOG="$STUBBIN/.drops"
: > "$DROP_LOG"
# `psql -lqtA` is the only psql form the profile reads databases through; the
# pipe it feeds (`cut -d'|' -f1`) wants that column layout.
cat > "$STUBBIN/psql" <<EOF
#!/bin/sh
case "\$*" in
  *-lqtA*) sed 's/\$/|owner|UTF8|/' "$DB_LIST"; exit 0 ;;
esac
exit 0
EOF
cat > "$STUBBIN/dropdb" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> "$DROP_LOG"
exit "\${DROPDB_RC:-0}"
EOF
chmod +x "$STUBBIN/psql" "$STUBBIN/dropdb"
export PATH="$STUBBIN:$PATH"

# shellcheck source=/dev/null
source "$HERE/../.local/bin/wt"      # msg / warn / slugify
# shellcheck source=/dev/null
source "$HERE/../.config/wt/profiles/supercast.sh"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }

cleanup() { rm -rf "$XDG_STATE_HOME" "$XDG_CONFIG_HOME" "$STUBBIN" "$HOME"; }
trap cleanup EXIT

# The real branch whose database this was found on, and its slug.
LONG_SLUG=tom-conversion-chart-dynamic-bucketing
SHORT_SLUG=tom-login-code-submit-button

echo "== _wt_db never emits a name postgres would silently shorten ==" >&2
long_db=$(_wt_db "$LONG_SLUG")
eq "${#long_db}" 63 "a long slug's db name must be capped at postgres's 63-byte limit"
eq "$long_db" "supercast-web_development_tom_conversion_chart_dynamic_bucketin" \
  "and must be exactly the name createdb would have produced on its own"
short_db=$(_wt_db "$SHORT_SLUG")
eq "$short_db" "supercast-web_development_tom_login_code_submit_button" \
  "a slug within the limit is untouched"
[ "${#short_db}" -lt 63 ] && ok || bad "precondition: the short slug is genuinely under the limit"

echo "== _wt_db defaults to WT_SLUG, so every existing caller is unchanged ==" >&2
WT_SLUG=$SHORT_SLUG
eq "$(_wt_db)" "$short_db" "no argument means this worktree's own slug"
WT_SLUG=$LONG_SLUG
eq "$(_wt_db)" "$long_db" "including when that slug is over the limit"

echo "== _wt_dropdb finds the database _wt_db named ==" >&2
# The whole point of truncating: the name asked for is the name on disk.
printf '%s\n' "$long_db" > "$DB_LIST"
: > "$DROP_LOG"
_wt_dropdb "$(_wt_db "$LONG_SLUG")" && ok \
  || bad "a long-slug database must be found and dropped, not reported missing"
eq "$(cat "$DROP_LOG")" "$long_db" "and dropped by the name that is actually there"
: > "$DROP_LOG"
_wt_dropdb "supercast-web_development_never_existed" \
  && bad "a database that is not there must report non-zero" || ok
[ ! -s "$DROP_LOG" ] && ok || bad "and must not be handed to dropdb"

echo "== wt_sweep never sweeps a LIVE worktree's database ==" >&2
# Both live worktrees, one either side of the limit, plus one real orphan.
orphan_db=supercast-web_development_tom_long_gone_branch
cat > "$DB_LIST" <<EOF
supercast-web_development
$long_db
$short_db
$orphan_db
EOF
export WT_LIVE_SLUGS=$(printf '%s\n%s\n' "$LONG_SLUG" "$SHORT_SLUG")
# The dry run is the preview `wt gc --sweep` shows before asking to proceed, so
# what it lists is exactly what a real sweep would take.
preview=$(WT_SWEEP_DRY=1 wt_sweep 2>/dev/null)
case "$preview" in
  *"$long_db"*) bad "a live worktree's truncated database must never be swept - this is the data loss" ;;
  *) ok ;;
esac
case "$preview" in
  *"$short_db"*) bad "a live worktree's database must never be swept" ;;
  *) ok ;;
esac
case "$preview" in
  *"database $orphan_db"*) ok ;;
  *) bad "a genuine orphan must still be reclaimed (got '$preview')" ;;
esac
case "$preview" in
  *"database supercast-web_development"$'\n'*|"database supercast-web_development")
    bad "the canonical dev database must never match" ;;
  *) ok ;;
esac

echo "== wt_sweep with no live worktrees still spares the canonical dev db ==" >&2
export WT_LIVE_SLUGS=""
preview=$(WT_SWEEP_DRY=1 wt_sweep 2>/dev/null)
eq "$(grep -c 'supercast-web_development$' <<<"$preview")" 0 \
  "the prefix must require something after it, so the dev db can never match"
eq "$(grep -c '^database ' <<<"$preview")" 3 \
  "with nothing live, all three worktree databases are orphans"

echo "== a real sweep drops exactly what the preview listed ==" >&2
export WT_LIVE_SLUGS=$(printf '%s\n%s\n' "$LONG_SLUG" "$SHORT_SLUG")
# The canonical app's route sits below WT_PORT_BASE, so no sweep may take it.
printf '%s' 3000 > "$HOME/.puma-dev/supercast"
printf '%s' 3101 > "$HOME/.puma-dev/$LONG_SLUG"
printf '%s' 3105 > "$HOME/.puma-dev/tom-long-gone-branch"
: > "$DROP_LOG"
wt_sweep >/dev/null 2>&1
eq "$(cat "$DROP_LOG")" "$orphan_db" "only the orphan is dropped"
eq "$(cd "$HOME/.puma-dev" && printf '%s ' *)" "supercast $LONG_SLUG " \
  "and only the orphan's puma-dev route is swept"

echo "== _wt_test_db names a DIFFERENT database, at every slug length ==" >&2
# The bug this naming exists to prevent: _wt_db truncates to 63 bytes, so simply
# SUFFIXING it is a no-op for any slug long enough to already be at the cap - the
# "test" database would be the dev database, silently, for exactly the long slugs
# that caused the truncation incident. Demonstrate that the naive form collides
# and that the real one does not.
naive=$(printf '%s' "$(_wt_db "$LONG_SLUG")_test"); naive=${naive:0:63}
eq "$naive" "$(_wt_db "$LONG_SLUG")" \
  "precondition: suffixing a capped name collides with it exactly - this is the trap"
long_tdb=$(_wt_test_db "$LONG_SLUG")
[ "$long_tdb" != "$(_wt_db "$LONG_SLUG")" ] && ok \
  || bad "a long slug's test database must never be its dev database"
eq "${#long_tdb}" 63 "and must still be capped at postgres's 63-byte limit"
case "$long_tdb" in
  supercast-web_development_test_*) ok ;;
  *) bad "the test database must carry the test infix (got '$long_tdb')" ;;
esac
short_tdb=$(_wt_test_db "$SHORT_SLUG")
eq "$short_tdb" "supercast-web_development_test_tom_login_code_submit_button" \
  "a slug within the limit is untouched"
[ "$short_tdb" != "$(_wt_db "$SHORT_SLUG")" ] && ok \
  || bad "a short slug's test database must differ from its dev database too"
WT_SLUG=$SHORT_SLUG
eq "$(_wt_test_db)" "$short_tdb" "and it defaults to WT_SLUG like _wt_db does"

echo "== wt_sweep never sweeps a LIVE worktree's TEST database ==" >&2
# The sweep matches on the supercast-web_development_ prefix, which a test
# database also carries - so unless the live list is built from BOTH names, every
# live worktree's test database looks like an orphan and gets dropped mid-suite.
orphan_tdb=$(_wt_test_db tom-long-gone-branch)
cat > "$DB_LIST" <<EOF
supercast-web_development
$long_db
$long_tdb
$short_db
$short_tdb
$orphan_db
$orphan_tdb
EOF
export WT_LIVE_SLUGS=$(printf '%s\n%s\n' "$LONG_SLUG" "$SHORT_SLUG")
preview=$(WT_SWEEP_DRY=1 wt_sweep 2>/dev/null)
for db in "$long_tdb" "$short_tdb"; do
  case "$preview" in
    *"$db"*) bad "a live worktree's test database must never be swept - this is the data loss ($db)" ;;
    *) ok ;;
  esac
done
eq "$(grep -c '^database ' <<<"$preview")" 2 \
  "only the dead worktree's two databases are orphans"

echo "== a real sweep reclaims a dead worktree's test database ==" >&2
: > "$DROP_LOG"
wt_sweep >/dev/null 2>&1
eq "$(sort < "$DROP_LOG" | tr '\n' ' ')" "$(printf '%s\n%s\n' "$orphan_db" "$orphan_tdb" | sort | tr '\n' ' ')" \
  "both of the orphan's databases are dropped, and nothing else is"

echo "== wt_teardown reclaims BOTH of a worktree's databases ==" >&2
# The leak this prevents: a test database dropped by nothing is a database per
# worktree left behind for ever, and the sweep is the only other thing that would
# ever find it. WT_SLUG names a worktree with no puma-dev entry and no Procfile, so
# the two `rm -f` branches are skipped on their own -e guards, and WT_REDIS=0 keeps
# the redis flush off db 0 - leaving the database drops as the only side effect.
WT_SLUG=tom-teardown-case
WT_REDIS=0
td_db=$(_wt_db); td_tdb=$(_wt_test_db)
printf '%s\n%s\n' "$td_db" "$td_tdb" > "$DB_LIST"
: > "$DROP_LOG"
wt_teardown >/dev/null 2>&1
eq "$(sort < "$DROP_LOG" | tr '\n' ' ')" "$(printf '%s\n%s\n' "$td_db" "$td_tdb" | sort | tr '\n' ' ')" \
  "both the dev and the test database are dropped"

echo "== wt_teardown on a worktree that never had a test database is quiet ==" >&2
# _wt_dropdb returns non-zero for a database that is not there, and every caller
# is `_wt_dropdb x && msg ...`, so a worktree provisioned before test databases
# existed must tear down reporting only the one it has.
printf '%s\n' "$td_db" > "$DB_LIST"
: > "$DROP_LOG"
out=$(wt_teardown 2>&1)
eq "$(cat "$DROP_LOG")" "$td_db" "only the database that exists is handed to dropdb"
case "$out" in
  *"dropped test database"*) bad "it must not claim to have dropped a test database that was never there" ;;
  *) ok ;;
esac

echo "== wt_teardown's own exit status never invents a failure ==" >&2
# The bug: its last statement used to be `[ -e "$pf" ] && rm -f "$pf"`, so a
# worktree that never ran a dev server - every --no-dev worktree, which is every
# pq task - made the function return non-zero after a completely clean teardown,
# and `wt rm` printed "teardown reported errors" on top of it.
printf '%s\n%s\n' "$td_db" "$td_tdb" > "$DB_LIST"
: > "$DROP_LOG"
wt_teardown >/dev/null 2>&1 && ok \
  || bad "a clean teardown with no Procfile must not report failure"
printf '%s\n' "$td_db" > "$DB_LIST"
: > "$DROP_LOG"
wt_teardown >/dev/null 2>&1 && ok \
  || bad "nor must one whose test database was never created"

echo "== but a drop that genuinely fails is said out loud ==" >&2
# Silence here is what the old `_wt_dropdb x && msg ...` gave: a database still on
# disk because its connections could not be terminated looked exactly like one
# that had already gone.
printf '%s\n%s\n' "$td_db" "$td_tdb" > "$DB_LIST"
: > "$DROP_LOG"
out=$(DROPDB_RC=1 wt_teardown 2>&1)
case "$out" in
  *"could not drop database $td_db"*) ok ;;
  *) bad "a failed drop of the dev database must warn (got '$out')" ;;
esac
case "$out" in
  *"could not drop test database $td_tdb"*) ok ;;
  *) bad "a failed drop of the test database must warn too (got '$out')" ;;
esac
case "$out" in
  *"dropped database"*) bad "and must not also claim success" ;;
  *) ok ;;
esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
