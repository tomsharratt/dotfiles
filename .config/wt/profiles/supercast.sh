# wt profile for supercast - a Rails app served by puma-dev at *.test, run via a
# foreman Procfile (web / worker / css / js / stripe). Each worktree runs fully
# isolated: its own postgres database (a copy of the dev db), its own redis db
# index, its own puma-dev url, and its own port. Sourced by ~/.local/bin/wt.
#
# App wiring this relies on (already in the supercast repo):
#   - database.yml dev reads ENV["DATABASE_URL"]           -> per-worktree db
#   - config/initializers/sidekiq.rb reads ENV["REDIS_URL"] -> per-worktree redis db
#   - development.rb + session_store.rb honor ENV["LOCAL_DOMAIN"] -> per-worktree url
#   - Procfile.dev binds ${PORT:-3000}                      -> per-worktree port
#   - config/application.rb has config.hosts.clear          -> any *.test host is allowed

WT_RESOURCES="port redis"   # allocate an isolated port + redis db index
WT_PORT_BASE=3101           # 3000 stays with the canonical checkout
WT_REDIS_MAX=14             # reserve db 15 for the spec suite (config/initializers/redis.rb)
WT_AGENT="claude"

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

wt_provision() {
  local canonical=$WT_REPO db key rel
  db=$(_wt_db)

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

  # 2. Isolated database, always a fresh copy of the current dev db. Re-running
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

  # 3. Apply this branch's own migrations to the isolated db (safe - nothing shared).
  msg "migrating $db"
  if ! ( cd "$WT_PATH" && DATABASE_URL="postgres:///$db" bin/rails db:migrate >/dev/null ); then
    warn "db:migrate failed - fix before testing"; return 1
  fi

  # 4. Seed feature flags so the worktree matches dev instead of starting with
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

  # 5. Route puma-dev's <slug>.test at this worktree's port.
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
  local db; db=$(_wt_db)
  export PORT="$WT_PORT"
  export DATABASE_URL="postgres:///$db"
  export REDIS_URL="redis://localhost:6379/${WT_REDIS:-0}"
  export LOCAL_DOMAIN="$WT_DOMAIN"
  # Scope the session cookie to THIS worktree's host. figaro loads config/application.yml,
  # which sets ENV["domain"]="supercast.test"; the session_store treats a LOCAL_DOMAIN host as
  # "known" and scopes the cookie to ENV["domain"], so without this the browser drops the
  # cookie (domain=supercast.test on a <slug>.test host) and login silently fails. figaro skips
  # keys already in ENV, so exporting it here wins.
  export domain="$WT_DOMAIN"
}

# Browser entry point for `wt open`: the app login with an email pre-filled, so a
# fresh worktree drops you onto a session in one click. Served off the app.
# subdomain - puma-dev routes any *.<slug>.test host through this worktree's entry,
# so app.<slug>.test resolves the same as the bare <slug>.test does. Override the
# email with `wt open <name> <email>` or WT_OPEN_EMAIL; default is the seed admin.
wt_open_url() {
  local email=${1:-${WT_OPEN_EMAIL:-admin@supercast.tech}}
  printf 'https://app.%s/login?user[email]=%s' "$WT_DOMAIN" "$email"
}

wt_dev() {
  local db pf; db=$(_wt_db); pf="${TMPDIR:-/tmp}/wt-${WT_SLUG}.Procfile"
  # Isolated db / redis / url / port - identical to what `wt run` hands the console.
  wt_env
  # Clear a stale server pidfile (only if its process is dead) so a restart after a
  # hard kill isn't blocked by "A server is already running".
  local pidfile="$WT_PATH/tmp/pids/server.pid" oldpid
  if [ -f "$pidfile" ]; then
    oldpid=$(tr -dc '0-9' < "$pidfile" 2>/dev/null)
    { [ -z "$oldpid" ] || ! kill -0 "$oldpid" 2>/dev/null; } && rm -f "$pidfile"
  fi
  # Procfile.dev pins the web port to 3000, so it can't be shared. Generate a
  # per-worktree copy that binds this worktree's port instead - derived fresh
  # from the tracked Procfile.dev each boot (so it can't drift), written outside
  # the repo (so it never dirties the worktree). stripe_connect is dropped:
  # several `stripe listen` sessions would all receive and double-process the
  # same webhooks. This keeps the supercast repo itself untouched.
  sed "s/3000/$WT_PORT/g" "$WT_PATH/Procfile.dev" | grep -v '^stripe_connect:' > "$pf"
  msg "dev  ->  https://$WT_DOMAIN (:$PORT)  db=$db  redis/${WT_REDIS:-0}"
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
    [ -n "$slug" ] && printf '%s\n' "$(_wt_db "$slug")"
  done <<<"$live")

  for f in "$HOME"/.puma-dev/*; do
    [ -f "$f" ] || continue
    slug=$(basename "$f")
    grep -qxF "$slug" <<<"$live" && continue
    port=$(tr -dc '0-9' < "$f" 2>/dev/null)
    [ -n "$port" ] && [ "$port" -ge "${WT_PORT_BASE:-3101}" ] 2>/dev/null || continue
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
  local db pf; db=$(_wt_db); pf="${TMPDIR:-/tmp}/wt-${WT_SLUG}.Procfile"
  # -e first: `rm -f` succeeds on a path that was never there, so without the test this
  # reports removing an entry that never existed (every worktree created outside wt).
  [ -e "$HOME/.puma-dev/$WT_SLUG" ] && rm -f "$HOME/.puma-dev/$WT_SLUG" \
    && msg "removed puma-dev entry $WT_SLUG"
  # Flush this worktree's redis db so a future worktree reusing the index inherits
  # no stale Sidekiq state. Guarded to > 0 so db 0 (the canonical dev db) is never touched.
  if [ "${WT_REDIS:-0}" -gt 0 ] 2>/dev/null; then
    redis-cli -n "$WT_REDIS" flushdb >/dev/null 2>&1 && msg "flushed redis db $WT_REDIS"
  fi
  _wt_dropdb "$db" && msg "dropped database $db"
  # wt_dev writes this outside the repo (see there); nothing else removes it.
  [ -e "$pf" ] && rm -f "$pf"
}
