# shellcheck shell=bash  # sourced by wt, never run
# wt profile for supercast - a Rails app served by puma-dev at *.test, run via a
# foreman Procfile (web / worker / css / js / stripe). Each worktree runs fully
# isolated: its own postgres database (a copy of the dev db), its own redis db
# index, its own puma-dev url, and its own port. Sourced by ~/.local/bin/wt.
#
# App wiring this relies on (already in the supercast repo):
#   - database.yml dev reads ENV["DATABASE_URL"]           -> per-worktree db
#   - config/initializers/sidekiq.rb reads ENV["REDIS_URL"] -> per-worktree redis db
#   - config/initializers/redis.rb reads ENV["REDIS_TEST_DB"] in test (15 without it)
#                                                      -> per-worktree test redis db
#   - development.rb + session_store.rb honor ENV["LOCAL_DOMAIN"] -> per-worktree url
#   - Procfile.dev binds ${PORT:-3000}                      -> per-worktree port
#   - config/application.rb has config.hosts.clear          -> any *.test host is allowed

# shellcheck disable=SC2034  # WT_RESOURCES and WT_REDIS_RESERVED are read by the wt sourcing this
WT_RESOURCES="port redis redis_test"   # an isolated port (from wt's 3101 - 3000 stays with the canonical
                                       # checkout), a redis db index for the dev server and one for the specs
# config/initializers/redis.rb gives the spec suite REDIS_TEST_DB, and 15 when that is
# unset - which it is in the canonical checkout, and in a worktree from before
# redis_test until its next dev boot. So 15 is never a worktree's.
# shellcheck disable=SC2034
WT_REDIS_RESERVED="15"
# Every db:migrate re-dumps db/schema.rb from this machine's postgres - wt_provision
# runs one, and so does an agent adding a migration - and postgres 18 renders some
# partial-index clauses differently from whichever one dumped the committed file. So
# a worktree that changed nothing about the schema can still show it modified, and
# that alone held a merged task's teardown. A real schema change comes with its
# migration, a new file, which still counts as work. The migrates wt runs itself -
# provisioning's and the dev boot's - go further and put the committed file back when
# the re-dump can only be that noise (see _wt_migrate).
# shellcheck disable=SC2034
WT_REGENERATED="db/schema.rb"

# The dev db has a hyphen; a bareword pg db name can't, so the slug's dashes
# become underscores for the worktree's db.
#
# Truncated to 63 bytes because postgres does it anyway: an identifier is
# NAMEDATALEN-1, so `createdb` silently accepts a longer name and creates a
# shorter one. Everything that looked the name up afterwards then missed it -
# `_wt_dropdb` searched for the name it asked for, found nothing and reported
# "no such database", so `wt rm` and `wt gc --sweep` both left the database
# behind forever. Worse, wt_sweep reads a slug back OUT of the db name, and a
# truncated name yields a slug that matches no live worktree - so a live
# worktree's database looked exactly like an orphan. Seven of supercast's
# thirteen worktree databases were over the limit when this was found.
# Truncating here is what makes create, drop and sweep all name the same thing.
# Slugs are ASCII by construction (slugify), so bytes and characters agree.
_wt_db() { local s=${1:-$WT_SLUG}; s="supercast-web_development_${s//-/_}"; printf '%s' "${s:0:63}"; }

# The worktree's own TEST database, separate from the dev copy above.
#
# Without one, `RAILS_ENV=test` in a worktree lands in one of two wrong places.
# database.yml's `test:` entry carries BOTH `url:` (reading DATABASE_URL) and an
# explicit `database: supercast-web_test`, and ActiveRecord merges the url on top
# of the yaml (url_config.rb), so DATABASE_URL wins: with wt_env loaded a spec run
# loads schema over the dev data this worktree's own server is serving, and with no
# DATABASE_URL at all it falls through to the single machine-wide
# supercast-web_test that every other worktree is using too - which is where the
# PG::ObjectInUse, re-appearing PendingMigrationError and truncation deadlocks
# between unrelated worktrees came from.
#
# INFIXED, not suffixed. _wt_db already truncates to 63 bytes (see above), so
# "$(_wt_db)_test" is byte-identical to _wt_db's own output for any slug of 37
# characters or more - the test database would BE the dev database, silently, for
# exactly the long slugs that caused the last naming incident. This prefix is 31
# bytes, leaving 32 for the underscored slug.
_wt_test_db() { local s=${1:-$WT_SLUG}; s="supercast-web_development_test_${s//-/_}"; printf '%s' "${s:0:63}"; }

# Drop a db, first terminating any connections to it (a still-running dev server)
# so dropdb can't fail on "database is being accessed by other users". Silent -
# the caller prints its own context. Returns non-zero if the db doesn't exist or
# the drop fails, so `_wt_dropdb x && msg ...` reports only a real drop.
_wt_dropdb() {
  local db=$1
  psql -lqtA 2>/dev/null | cut -d'|' -f1 | grep -qx "$db" || return 1
  psql -q -d postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$db' AND pid<>pg_backend_pid();" \
    >/dev/null 2>&1
  dropdb "$db"
}

# Drop a db and SAY what happened. _wt_dropdb returns non-zero both for "the drop
# failed" and for "it was never there", and the bare `_wt_dropdb x && msg ...` this
# replaces printed nothing in either case - so a database that genuinely could not
# be dropped (a connection wt could not terminate) was reclaimed silently in the
# same way as one that had already gone. Only the first of those deserves a warning,
# so re-check the list afterwards to tell them apart.
_wt_drop_reported() {                   # db label
  local db=$1 label=$2
  if _wt_dropdb "$db"; then msg "dropped $label$db"; return 0; fi
  psql -lqtA 2>/dev/null | cut -d'|' -f1 | grep -qx "$db" \
    && warn "could not drop $label$db - still on disk"
  return 0
}

# Point puma-dev's <slug>.test at this worktree's port, restarting the daemon when that
# is not the port it already has on file.
#
# puma-dev reads ~/.puma-dev/<slug> exactly ONCE - the first time it builds a proxy for
# that hostname - and then holds that proxy for the life of the process. It does not
# watch the directory, SIGUSR1 and `puma-dev -stop` both leave proxy apps untouched, and
# even deleting the entry keeps the cached proxy serving. So a port that MOVES under a
# running daemon strands it: puma-dev keeps dialing the port it read the first time and
# every request to the worktree 502s, while the dev server sits perfectly healthy on the
# new one. That is invisible from the browser - the url is right, the app is up, and the
# only evidence is a "dial tcp 127.0.0.1:<old>: connection refused" line in
# ~/Library/Logs/puma-dev.log.
#
# Two ordinary things move a port. supercast's own bin/preview-setup registers the same
# slug at :3100, its default, which is outside wt's range and so is never what wt then
# writes. And a torn-down slug that comes back - `wt rm` then `wt new` on the same branch
# - gets whatever port is free next, while puma-dev still holds the proxy from its first
# life.
#
# Restarting is the only thing that clears the pool. Cheap, but not free: every entry in
# ~/.puma-dev is a port file, so no app is actually stopped, and launchd holds the :80/:443
# sockets so a connection opened after the kill just queues - but a connection puma-dev had
# already accepted dies with it. So anything in flight on ANY .test host - a page mid-load,
# an open ActionCable socket - is dropped and has to retry. Hence only on a real change:
# a re-provision that keeps its port stays silent, and the cost is paid on `wt new` and on
# a genuine move, which is where a stale pool would otherwise break the worktree outright.
_wt_puma_dev_route() {
  local entry="$HOME/.puma-dev/$WT_SLUG" had label
  [ -f "$entry" ] && had=$(tr -dc '0-9' < "$entry" 2>/dev/null)
  printf '%s' "$WT_PORT" > "$entry"
  msg "puma-dev: https://$WT_DOMAIN -> :$WT_PORT"
  [ "${had:-}" = "$WT_PORT" ] && return 0
  for label in io.puma.dev homebrew.mxcl.puma-dev; do
    launchctl list "$label" >/dev/null 2>&1 || continue
    launchctl kickstart -k "gui/$(id -u)/$label" >/dev/null 2>&1 \
      && { msg "restarted puma-dev so $WT_DOMAIN re-reads :$WT_PORT"; return 0; }
  done
  # Not fatal: the dev server still serves the port directly, it is only the .test url
  # that is stale. Say exactly what to run, since nothing else will reveal the cause.
  warn "puma-dev is not under launchd - it may still route $WT_DOMAIN at ${had:-an old port};"
  warn "  restart it to pick up :$WT_PORT"
  return 0
}

# The migrations in this worktree's db/migrate that DB has not run, one path per line
# (relative to the worktree), oldest first, and nothing when it is current. Non-zero
# when the database cannot be read at all - postgres down, the database gone, no
# schema_migrations table - so a caller can tell "nothing pending" from "cannot tell".
#
# Asked of postgres directly rather than through `bin/rails db:migrate:status`, which
# boots the whole app: several seconds on every dev boot to learn, almost always, that
# there is nothing to do. One query and a glob take milliseconds.
_wt_pending_migrations() {              # db
  local applied f
  applied=$(psql -XqtA -d "$1" -c 'SELECT version FROM schema_migrations' 2>/dev/null) || return 1
  for f in "$WT_PATH"/db/migrate/[0-9]*_*.rb; do
    [ -e "$f" ] && printf '%s\n' "${f##*/}"
  done | awk -F_ 'NR == FNR { if ($0 != "") done[$0]; next }
                  !($1 in done) { print "db/migrate/" $0 }' <(printf '%s\n' "$applied") -
}

# Whether db:migrate applying PENDING can change db/schema.rb only by the re-dump noise
# WT_REGENERATED describes, so the committed file is the one to keep. True when
# schema.rb is exactly as committed and every pending migration is, byte for byte, one
# the default branch already has: that branch's schema.rb describes each of them, and a
# worktree rebased onto it carries that schema.rb. That is the common case, and the one
# that broke a worktree: master gains a migration after the worktree's database was
# copied, the branch is rebased onto it, and the migrate that catches the database up
# leaves schema.rb dirty with nothing in it but postgres 18's rendering.
#
# Anything else is the branch's own, and its re-dump is kept: a schema.rb it had already
# changed, or a migration that is new on the branch, edited, or not even committed -
# where the re-dump may be the only record of the schema change. No default branch to
# compare with also counts as the branch's own, the safe direction to be wrong in.
_wt_schema_redump_only() {              # pending (newline-separated paths)
  local st base f
  [ -f "$WT_PATH/db/schema.rb" ] || return 1
  st=$(git -C "$WT_PATH" status --porcelain -- db/schema.rb 2>/dev/null) || return 1
  [ -z "$st" ] || return 1
  base=$(base_ref "$WT_PATH"); [ -n "$base" ] || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    git -C "$WT_PATH" ls-files --error-unmatch -- "$f" >/dev/null 2>&1 || return 1
    git -C "$WT_PATH" cat-file -e "$base:$f" 2>/dev/null || return 1
    git -C "$WT_PATH" diff --quiet "$base" -- "$f" 2>/dev/null || return 1
  done <<<"$1"
  return 0
}

# Run db:migrate on DB, returning its status, with its output in _WT_MIGRATE_OUT for the
# caller to show when it fails. With RESTORE=1 - the
# caller's _wt_schema_redump_only verdict - db/schema.rb is put back exactly as it was
# afterwards, and the annotate gem's model re-annotation (supercast runs it after every
# development db:migrate) is skipped, since what the default branch already has changes
# no file either. Sets _WT_SCHEMA_RESTORED=1 when the re-dump really did differ and was
# undone, for the caller to say so.
_wt_migrate() {                         # db restore(0|1)
  local db=$1 restore=$2 snap="" rc
  _WT_SCHEMA_RESTORED="" _WT_MIGRATE_OUT=""
  if [ "$restore" = 1 ]; then
    snap=$(mktemp) || snap=""
    if [ -n "$snap" ] && ! cp "$WT_PATH/db/schema.rb" "$snap"; then rm -f "$snap"; snap=""; fi
  fi
  if [ -n "$snap" ]; then
    _WT_MIGRATE_OUT=$(cd "$WT_PATH" && DATABASE_URL="postgres:///$db" skip_on_db_migrate=1 bin/rails db:migrate 2>&1)
  else
    _WT_MIGRATE_OUT=$(cd "$WT_PATH" && DATABASE_URL="postgres:///$db" bin/rails db:migrate 2>&1)
  fi
  rc=$?
  if [ -n "$snap" ]; then
    cmp -s "$snap" "$WT_PATH/db/schema.rb" || { cp "$snap" "$WT_PATH/db/schema.rb" && _WT_SCHEMA_RESTORED=1; }
    rm -f "$snap"
  fi
  return "$rc"
}

# Catch the worktree's database up with its migrations before the dev server boots on
# it. Nothing else does: provisioning migrates once, against the copy it makes, and the
# branch keeps moving afterwards - rebased onto a master that has gained a migration,
# its server came back from a restart serving ActiveRecord::PendingMigrationError on
# every page and its sidekiq jobs failing on PG::UndefinedColumn, until somebody ran the
# migrate by hand - which then left db/schema.rb dirty with postgres's re-dump noise.
#
# Silent and quick when there is nothing pending, which is nearly every boot. A
# migration that fails does not stop the server: the error is shown here, loudly, and
# the app itself shows the pending migration, which is a better place to see it than a
# dev pane that never came up.
_wt_dev_migrate() {                     # db
  local db=$1 pending n s restore=0
  if ! pending=$(_wt_pending_migrations "$db"); then
    warn "could not read $db's schema_migrations - not checking it for pending migrations"
    return 0
  fi
  [ -n "$pending" ] || return 0
  n=$(grep -c . <<<"$pending"); s=s; [ "$n" = 1 ] && s=""
  _wt_schema_redump_only "$pending" && restore=1
  if _wt_migrate "$db" "$restore"; then
    msg "migrated $n pending migration$s$([ -n "$_WT_SCHEMA_RESTORED" ] && printf -- ' - db/schema.rb left as committed')"
  else
    warn "db:migrate FAILED on $n pending migration$s - starting the dev server anyway; the app will show it until it is fixed:"
    tail -n 30 <<<"$_WT_MIGRATE_OUT" | sed 's/^/    /' >&2
    warn "fix the migration, then: wt restart - the dev boot migrates again"
  fi
  return 0
}

wt_provision() {
  local canonical=$WT_REPO db tdb key rel
  db=$(_wt_db); tdb=$(_wt_test_db)

  # 1. Link the gitignored secrets a fresh checkout needs to boot.
  for key in "$canonical"/config/master.key "$canonical"/config/credentials/*.key; do
    [ -e "$key" ] || continue
    rel=${key#"$canonical"/}
    [ -e "$WT_PATH/$rel" ] || { mkdir -p "$(dirname "$WT_PATH/$rel")"; ln -s "$key" "$WT_PATH/$rel"; msg "linked $rel"; }
  done
  # node_modules is a big shared build cache - symlink it rather than reinstall.
  if [ -d "$canonical/node_modules" ] && [ ! -e "$WT_PATH/node_modules" ]; then
    ln -s "$canonical/node_modules" "$WT_PATH/node_modules"; msg "linked node_modules"
  fi

  # 2. Gems, before anything here runs bin/rails. node_modules is shared by
  #    symlink above, but the gem set is not: a worktree forked from a fresher
  #    origin/master whose lockfile wants gems the shared asdf gem set does not
  #    have dies on the first bin/rails with Bundler::GemNotFound. That used to
  #    surface as "db:migrate failed" and send you looking at wt or at postgres.
  msg "installing gems"
  if ! ( cd "$WT_PATH" && bundle install --quiet ); then
    warn "bundle install failed - bin/rails cannot run in this worktree"; return 1
  fi

  # 3. Isolated database, always a fresh copy of the current dev db. Re-running
  #    provision RESETS it: an existing worktree db is dropped (terminating the
  #    dev server if it's still attached) and re-seeded, so provision is the way
  #    back to a clean copy. A logical dump is used rather than CREATE DATABASE
  #    ... TEMPLATE, which needs exclusive access to the source the canonical dev
  #    server holds open.
  if psql -lqtA 2>/dev/null | cut -d'|' -f1 | grep -qx "$db"; then
    msg "resetting database $db (fresh copy of supercast-web_development)"
    _wt_dropdb "$db" || { warn "dropping $db failed"; return 1; }
  else
    msg "creating database $db (copy of supercast-web_development)"
  fi
  createdb "$db" || { warn "createdb $db failed"; return 1; }
  if ! pg_dump --no-owner --no-privileges "supercast-web_development" 2>/dev/null | psql -q -d "$db" >/dev/null 2>&1; then
    warn "seeding $db from the dev db failed"; return 1
  fi

  # 4. Apply this branch's own migrations to the isolated db (safe - nothing shared),
  #    keeping the committed db/schema.rb when the re-dump can only be postgres's
  #    noise - see _wt_schema_redump_only. A pending list that cannot be read keeps
  #    the re-dump, and still migrates.
  local pending restore=0
  msg "migrating $db"
  pending=$(_wt_pending_migrations "$db") && _wt_schema_redump_only "$pending" && restore=1
  if ! _wt_migrate "$db" "$restore"; then
    tail -n 30 <<<"$_WT_MIGRATE_OUT" >&2
    warn "db:migrate failed - fix before testing"; return 1
  fi
  [ -n "$_WT_SCHEMA_RESTORED" ] && msg "db/schema.rb left as committed - its re-dump differed only in postgres's rendering"

  # 5. This worktree's own test database. Schema only, never a copy of dev: a test
  #    database is meant to start empty, and rails_helper's maintain_test_schema!
  #    keeps it current from here - so provisioning only has to make it exist at
  #    the right schema. Loaded under RAILS_ENV=test so ar_internal_metadata
  #    records `test` and a spec run never trips EnvironmentMismatchError. Reset on
  #    re-provision, the same contract as the dev copy above.
  if psql -lqtA 2>/dev/null | cut -d'|' -f1 | grep -qx "$tdb"; then
    msg "resetting test database $tdb"
    _wt_dropdb "$tdb" || { warn "dropping $tdb failed"; return 1; }
  else
    msg "creating test database $tdb"
  fi
  createdb "$tdb" || { warn "createdb $tdb failed"; return 1; }
  if ! ( cd "$WT_PATH" && RAILS_ENV=test DATABASE_URL="postgres://localhost/$tdb" \
           bin/rails db:schema:load >/dev/null ); then
    warn "loading the schema into $tdb failed - fix before testing"; return 1
  fi
  #    And point a bare `bundle exec rspec` at it too - see _wt_rspec.
  _wt_rspec

  # 6. Build the assets a full-page render needs. app/assets/builds/ is gitignored
  #    and empty in a fresh worktree, so every request or feature spec rendering
  #    through a layout 500s with Propshaft::MissingAssetError - which reads like
  #    the branch broke rendering, in specs it never touched. These are the two
  #    commands CI's setup-build action runs. They go stale the moment a view is
  #    edited, so anyone doing visual work still rebuilds; the point is that a
  #    fresh worktree runs its specs without first diagnosing this.
  #    Not fatal: a worktree with no built assets is still a working worktree.
  msg "building assets"
  if ! ( cd "$WT_PATH" && yarn build >/dev/null 2>&1 \
           && bin/rails tailwindcss:build >/dev/null 2>&1 ); then
    warn "building assets failed - full-page specs will 500 until this is fixed"
  fi

  # 7. Seed feature flags so the worktree matches dev instead of starting with
  #    every flag off. flipper (config/initializers/features.rb -> Redis.new,
  #    which honors REDIS_URL) lives on this worktree's redis db index, and a
  #    fresh index is empty. flipper-redis keeps a SET `flipper_features` of
  #    feature names plus one HASH per feature keyed by the bare name; copy the
  #    set and each feature hash from the canonical dev db (redis 0). Server-side
  #    COPY (redis >= 6.2) avoids round-tripping values through the shell. Only
  #    when the target has no flags yet, so in-worktree toggles and re-provisions
  #    are never clobbered.
  if [ "${WT_REDIS:-0}" -gt 0 ] 2>/dev/null && \
     [ "$(redis-cli -n "$WT_REDIS" scard flipper_features 2>/dev/null)" = "0" ]; then
    local feat n
    redis-cli -n 0 copy flipper_features flipper_features DB "$WT_REDIS" REPLACE >/dev/null 2>&1
    # Only ~a quarter of registered features carry a gate HASH (the rest are off
    # by default); copy whichever exist. `copy` of an absent key is a no-op.
    while IFS= read -r feat; do
      [ -n "$feat" ] || continue
      redis-cli -n 0 copy "$feat" "$feat" DB "$WT_REDIS" REPLACE >/dev/null 2>&1
    done < <(redis-cli -n 0 smembers flipper_features 2>/dev/null)
    n=$(redis-cli -n "$WT_REDIS" scard flipper_features 2>/dev/null)
    [ "${n:-0}" -gt 0 ] 2>/dev/null && msg "seeded $n feature flags into redis db $WT_REDIS (from dev)"
  fi

  # 8. Route puma-dev's <slug>.test at this worktree's port.
  _wt_puma_dev_route

  # Record human-facing facts for `wt ls`.
  wt_state_set WT_URL "https://$WT_DOMAIN"
  wt_state_set WT_DB "$db"
}

# Export this worktree's isolated runtime environment: its own postgres db, redis
# db index, puma-dev url and port. This is the SINGLE source of truth for every
# process that runs against the worktree - the long-running dev server (wt_dev)
# AND one-off commands (`wt run`, e.g. `wt run bin/rails console`). Keeping both
# on the same function is what stops a console from silently reading the canonical
# dev db while the server reads the isolated one.
wt_env() {
  export PORT="$WT_PORT"
  # WHICH database depends on what is about to run, and that is decided here
  # because DATABASE_URL beats database.yml's own `database:` key in every
  # environment (see _wt_test_db). That precedence is the mechanism rather than a
  # problem: aim it at the test database for a test command and at the dev copy
  # otherwise, and both environments get this worktree's own database.
  #
  # Rails offers nothing environment-specific to use instead. It resolves
  # <CONFIG_NAME>_DATABASE_URL - PRIMARY_DATABASE_URL here - keyed on the database
  # config's name rather than on the environment, and skips that lookup entirely
  # for a config whose yaml already carries a `url:` key, which supercast's do.
  # TEST_DATABASE_URL is not honored anywhere in activerecord or railties.
  #
  # The test url names localhost EXPLICITLY, and must. DatabaseCleaner's safeguard
  # raises on a DATABASE_URL it reads as remote; it allows localhost, 127.0.0.1 and
  # *.local, and returns early when there is no host - but
  # URI.parse("postgres:///x").host is "", an empty string, which is truthy in
  # ruby, so the socket form sails past that no-host check, matches none of the
  # allowed hosts and is rejected. postgres://localhost/x is allowed outright,
  # which is why no DATABASE_CLEANER_ALLOW_REMOTE_DATABASE_URL is needed.
  if [ "${RAILS_ENV:-}" = test ]; then
    DATABASE_URL="postgres://localhost/$(_wt_test_db)"
  else
    DATABASE_URL="postgres:///$(_wt_db)"
  fi
  export DATABASE_URL
  export REDIS_URL="redis://localhost:6379/${WT_REDIS:-0}"
  # The spec suite's redis db is this worktree's own too. Exported whatever RAILS_ENV
  # says, so a bare `bundle exec rspec` from a `wt run` shell lands on it as well; and
  # unset when the worktree has none yet, so a value inherited from another worktree's
  # shell is never used - supercast then falls back to 15, where it always was.
  if [ -n "${WT_REDIS_TEST:-}" ]; then
    export REDIS_TEST_DB="$WT_REDIS_TEST"
  else
    unset REDIS_TEST_DB
  fi
  # The domain is the dev server's alone. The test suite has its own - application.yml's
  # `test: domain: lvh.me`, which the specs build their hosts and urls from - and figaro
  # skips a key already in ENV, so exporting the worktree's here beat it: the test
  # session cookie was scoped to <slug>.test, rack-test dropped it on a request to
  # x.lvh.me, and every spec carrying a session across requests failed, beside the
  # Spotify payload specs that build `https://app.#{ENV['domain']}/...`. Those were
  # the seven "known environment-only failures" every session under `wt test`
  # re-proved. Unset rather than merely not exported: a `wt run` shell or a dev pane
  # already has both, and inheriting them is the same failure.
  if [ "${RAILS_ENV:-}" = test ]; then
    unset LOCAL_DOMAIN domain
    return 0
  fi
  export LOCAL_DOMAIN="$WT_DOMAIN"
  # Scope the session cookie to THIS worktree's host. figaro loads config/application.yml,
  # which sets ENV["domain"]="supercast.test"; the session_store treats a LOCAL_DOMAIN host as
  # "known" and scopes the cookie to ENV["domain"], so without this the browser drops the
  # cookie (domain=supercast.test on a <slug>.test host) and login silently fails. figaro skips
  # keys already in ENV, so exporting it here wins.
  export domain="$WT_DOMAIN"
}

# The same test environment for a bare `bundle exec rspec`, which never goes through
# wt_env: without it a spec run in a worktree falls through to the one machine-wide
# supercast-web_test - 36 of 160 spec runs in the implementer transcripts did that.
# RSpec reads the project's .rspec through ERB before it loads anything, so ruby there
# can set the environment first. supercast gitignores .rspec, so the file never dirties
# the worktree - which matters beyond tidiness, since a dirty worktree is one `wt rm`
# refuses and pq's reap holds. Written only where git ignores it, and never over a
# .rspec of someone else's: one without the marker line is left alone.
#
# A DATABASE_URL set on purpose is kept - agents point concurrent runs at test
# databases of their own. Only an unset one, or this worktree's dev database inherited
# from a `wt run` shell, is replaced. The rest mirrors wt_env's test branch.
#
# Rewritten on every dev boot, like the Procfile, so it cannot drift from this profile
# and a worktree made before it existed picks it up on its next `wt restart`.
_WT_RSPEC_MARK="# Written by wt's supercast profile, and rewritten on every dev boot - delete this line to keep your own."
_wt_rspec() {
  local f="$WT_PATH/.rspec" redis_test_line=""
  git -C "$WT_PATH" check-ignore -q .rspec 2>/dev/null || return 0
  [ -e "$f" ] && [ "$(head -1 "$f")" != "$_WT_RSPEC_MARK" ] && return 0
  # The test redis db as wt_env sets it, kept when set on purpose; with no index of
  # its own yet the worktree sets nothing, and supercast falls back to 15.
  [ -n "${WT_REDIS_TEST:-}" ] && redis_test_line="  ENV[\"REDIS_TEST_DB\"] ||= \"$WT_REDIS_TEST\""
  cat > "$f" <<EOF
$_WT_RSPEC_MARK
# A bare "bundle exec rspec" here gets what "wt test" gives it: this worktree's own
# test database, not the supercast-web_test every other worktree shares.
<%
  if [nil, "", "postgres:///$(_wt_db)"].include?(ENV["DATABASE_URL"])
    ENV["DATABASE_URL"] = "postgres://localhost/$(_wt_test_db)"
  end
  ENV["REDIS_URL"] ||= "redis://localhost:6379/${WT_REDIS:-0}"
$redis_test_line
  ENV.delete("LOCAL_DOMAIN")
  ENV.delete("domain")
-%>
EOF
}

# Browser entry point for `wt open [subdomain]`: the login with the seed admin's
# email pre-filled, so a fresh worktree drops you onto a session in one click.
# puma-dev routes any *.<slug>.test host through this worktree's entry, and the
# login is served on every subdomain, so the one argument picks where that
# session starts - the example podcast by default, or any other subdomain (app
# included).
wt_open_url() {
  local sub=${1:-example}
  [ $# -le 1 ] || { warn "wt open takes one subdomain, not $#"; return 1; }
  [[ "$sub" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] \
    || { warn "wt open takes a subdomain - example, app, or a podcast's - not '$sub'; run it from inside the worktree"; return 1; }
  printf 'https://%s.%s/login?user[email]=admin@supercast.tech' "$sub" "$WT_DOMAIN"
}

# The Procfile a worktree's dev server runs: Procfile.dev, derived fresh each boot
# (so it can't drift) and written outside the repo (so it never dirties the
# worktree), with three changes. The web port is this worktree's, not 3000.
# stripe_connect is dropped: several `stripe listen` sessions would all receive and
# double-process the same webhooks. And the css watcher is `tailwindcss:watch[always]`:
# plain `tailwindcss:watch` exits after one build when its stdin is not a terminal,
# and foreman then takes the whole stack down with it - which is what a `wt dev`
# started from anywhere but a pane did, an agent's own Bash tool included. This keeps
# the supercast repo itself untouched.
_wt_procfile() {                        # procfile port
  sed -e "s/3000/$2/g" -e 's/tailwindcss:watch[[:space:]]*$/"tailwindcss:watch[always]"/' "$1" \
    | grep -v '^stripe_connect:'
}

wt_dev() {
  local db pf; db=$(_wt_db); pf="${TMPDIR:-/tmp}/wt-${WT_SLUG}.Procfile"
  # Isolated db / redis / url / port - identical to what `wt run` hands the console.
  wt_env
  _wt_rspec
  # Clear a stale server pidfile (only if its process is dead) so a restart after a
  # hard kill isn't blocked by "A server is already running".
  local pidfile="$WT_PATH/tmp/pids/server.pid" oldpid
  if [ -f "$pidfile" ]; then
    oldpid=$(tr -dc '0-9' < "$pidfile" 2>/dev/null)
    { [ -z "$oldpid" ] || ! kill -0 "$oldpid" 2>/dev/null; } && rm -f "$pidfile"
  fi
  # The database caught up with the branch's migrations first, or the app 500s on
  # every page with PendingMigrationError - see _wt_dev_migrate.
  _wt_dev_migrate "$db"
  # Procfile.dev pins the web port to 3000, so it can't be shared. Generate a
  # per-worktree copy that binds this worktree's port instead - see _wt_procfile.
  _wt_procfile "$WT_PATH/Procfile.dev" "$WT_PORT" > "$pf"
  msg "dev  ->  https://$WT_DOMAIN (:$PORT)  db=$db  redis/${WT_REDIS:-0}  test redis/${WT_REDIS_TEST:-15}"
  # -d: foreman defaults its working dir to the Procfile's dir; point it at the
  # worktree since the generated Procfile lives outside the repo. Not exec'd, so
  # when the server stops (crash or Ctrl-C) `wt dev` drops to a shell you can
  # restart from rather than the pane vanishing.
  foreman start -f "$pf" -d "$WT_PATH" --env /dev/null
}

# Reclaim what this profile allocates once a worktree is gone entirely, so nothing
# records it any more: its puma-dev entry and its database. `wt gc --sweep` passes
# WT_LIVE_SLUGS - every slug that still has a live worktree - and anything of ours not
# on that list is an orphan.
#
# Both checks are deliberately narrow, because a sweep deletes on a name pattern rather
# than on a recorded fact:
#   - ~/.puma-dev holds one file per app, containing a port, and other apps and tools
#     write there too. So we only claim entries pointing at a port from OUR range
#     (>= WT_PORT_BASE). That leaves the canonical supercast entry (:3000) and the older
#     bin/preview-setup entries (:3100) alone - they are not wt's to reclaim.
#   - a database must carry the supercast-web_development_ prefix WITH something after
#     it, so the canonical supercast-web_development can never match.
#
# That prefix also matches a worktree's TEST database (supercast-web_development_test_*),
# so the live list below is built from BOTH names for every live slug. Building it from
# _wt_db alone would leave every live worktree's test database looking like an orphan and
# drop it mid-suite - the same class of failure as the truncation bug described below.
#
# The databases are matched by NAME, not by a slug read back out of the name. That
# reverse mapping cannot be done safely: _wt_db truncates to postgres's 63-byte
# identifier limit, so a long slug's db name has no slug to recover - and the
# truncated one it produced matched nothing on the live list, which made a live
# worktree's database look like an orphan to a pass that drops what it does not
# recognise. Going forwards instead - build each live slug's db name and compare
# those - is exact for every slug length.
wt_sweep() {
  local live f slug port db livedbs dry=${WT_SWEEP_DRY:-}
  live=$(printf '%s\n' "${WT_LIVE_SLUGS:-}" | sed '/^$/d')
  # printf, because _wt_db deliberately emits no trailing newline - it is written to
  # be read through command substitution. Without one every name here lands on a
  # single line and matches nothing, which is the same live-database-looks-orphaned
  # failure this rewrite exists to remove.
  livedbs=$(while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    printf '%s\n' "$(_wt_db "$slug")"
    printf '%s\n' "$(_wt_test_db "$slug")"
  done <<<"$live")

  for f in "$HOME"/.puma-dev/*; do
    [ -f "$f" ] || continue
    slug=$(basename "$f")
    grep -qxF "$slug" <<<"$live" && continue
    port=$(tr -dc '0-9' < "$f" 2>/dev/null)
    [ -n "$port" ] && [ "$port" -ge "$WT_PORT_BASE" ] 2>/dev/null || continue
    [ -n "$dry" ] && { printf 'puma-dev entry %s (:%s)\n' "$slug" "$port"; continue; }
    rm -f "$f" && msg "swept puma-dev entry $slug (was :$port)"
  done

  while IFS= read -r db; do
    [ -n "$db" ] || continue
    grep -qxF "$db" <<<"$livedbs" && continue
    [ -n "$dry" ] && { printf 'database %s\n' "$db"; continue; }
    _wt_dropdb "$db" && msg "swept database $db"
  done < <(psql -lqtA 2>/dev/null | cut -d'|' -f1 | grep '^supercast-web_development_.')
}

wt_teardown() {
  local db tdb pf; db=$(_wt_db); tdb=$(_wt_test_db); pf="${TMPDIR:-/tmp}/wt-${WT_SLUG}.Procfile"
  # -e first: `rm -f` succeeds on a path that was never there, so without the test this
  # reports removing an entry that never existed (every worktree created outside wt).
  [ -e "$HOME/.puma-dev/$WT_SLUG" ] && rm -f "$HOME/.puma-dev/$WT_SLUG" \
    && msg "removed puma-dev entry $WT_SLUG"
  # Flush this worktree's redis dbs so a future worktree reusing either index inherits
  # no stale Sidekiq state or spec keys. Guarded to > 0 so db 0 (the canonical dev db)
  # is never touched, and the test index to anything but 15, the canonical checkout's
  # spec db, which a worktree is never handed (WT_REDIS_RESERVED) - so a state file
  # claiming it is wrong, and flushing on its say-so would hit another suite's run.
  if [ "${WT_REDIS:-0}" -gt 0 ] 2>/dev/null; then
    redis-cli -n "$WT_REDIS" flushdb >/dev/null 2>&1 && msg "flushed redis db $WT_REDIS"
  fi
  if [ "${WT_REDIS_TEST:-0}" -gt 0 ] 2>/dev/null && [ "$WT_REDIS_TEST" != 15 ]; then
    redis-cli -n "$WT_REDIS_TEST" flushdb >/dev/null 2>&1 && msg "flushed test redis db $WT_REDIS_TEST"
  fi
  _wt_drop_reported "$db" "database "
  _wt_drop_reported "$tdb" "test database "
  # wt_dev writes this outside the repo (see there); nothing else removes it.
  # No -e guard: `rm -f` is already silent about a path that was never there, and
  # as the LAST statement the guard made this function return non-zero for every
  # worktree that never ran a dev server - which was every pq task, while pq
  # dispatched without one - and `wt rm` reported "teardown reported errors" after a
  # completely clean teardown. Each step above now reports its own failure, so the
  # function's own status carries no information and should not invent any.
  rm -f "$pf"
  return 0
}
