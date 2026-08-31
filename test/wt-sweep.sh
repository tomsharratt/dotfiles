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
exit 0
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

cleanup() { rm -rf "$XDG_STATE_HOME" "$XDG_CONFIG_HOME" "$STUBBIN"; }
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
: > "$DROP_LOG"
wt_sweep >/dev/null 2>&1
eq "$(cat "$DROP_LOG")" "$orphan_db" "only the orphan is dropped"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
