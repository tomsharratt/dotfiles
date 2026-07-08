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
WT_AGENT="claude"

# The dev db has a hyphen; a bareword pg db name can't, so the slug's dashes
# become underscores for the worktree's db.
_wt_db() { printf 'supercast-web_development_%s' "${WT_SLUG//-/_}"; }

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

  # 2. Isolated database. Copy the current dev db with a logical dump (works
  #    while the canonical dev server is connected, unlike CREATE DATABASE ...
  #    TEMPLATE, which needs exclusive access to the source).
  if ! psql -lqtA 2>/dev/null | cut -d'|' -f1 | grep -qx "$db"; then
    msg "creating database $db (copy of supercast-web_development)"
    createdb "$db" || { warn "createdb $db failed"; return 1; }
    if ! pg_dump --no-owner --no-privileges "supercast-web_development" 2>/dev/null | psql -q -d "$db" >/dev/null 2>&1; then
      warn "seeding $db from the dev db failed"; return 1
    fi
  fi

  # 3. Apply this branch's own migrations to the isolated db (safe - nothing shared).
  msg "migrating $db"
  if ! ( cd "$WT_PATH" && DATABASE_URL="postgres:///$db" bin/rails db:migrate >/dev/null ); then
    warn "db:migrate failed - fix before testing"; return 1
  fi

  # 4. Route puma-dev's <slug>.test at this worktree's port.
  printf '%s' "$WT_PORT" > "$HOME/.puma-dev/$WT_SLUG"
  msg "puma-dev: https://$WT_DOMAIN -> :$WT_PORT"

  # Record human-facing facts for `wt ls`.
  wt_state_set WT_URL "https://$WT_DOMAIN"
  wt_state_set WT_DB "$db"
}

wt_dev() {
  local db pf; db=$(_wt_db); pf="${TMPDIR:-/tmp}/wt-${WT_SLUG}.Procfile"
  export PORT="$WT_PORT"
  export DATABASE_URL="postgres:///$db"
  export REDIS_URL="redis://localhost:6379/${WT_REDIS:-0}"
  export LOCAL_DOMAIN="$WT_DOMAIN"
  # Procfile.dev pins the web port to 3000, so it can't be shared. Generate a
  # per-worktree copy that binds this worktree's port instead - derived fresh
  # from the tracked Procfile.dev each boot (so it can't drift), written outside
  # the repo (so it never dirties the worktree). stripe_connect is dropped:
  # several `stripe listen` sessions would all receive and double-process the
  # same webhooks. This keeps the supercast repo itself untouched.
  sed "s/3000/$WT_PORT/g" "$WT_PATH/Procfile.dev" | grep -v '^stripe_connect:' > "$pf"
  msg "dev  ->  https://$WT_DOMAIN (:$PORT)  db=$db  redis/${WT_REDIS:-0}"
  # -d: foreman defaults its working dir to the Procfile's dir; point it at the
  # worktree since the generated Procfile lives outside the repo.
  exec foreman start -f "$pf" -d "$WT_PATH" --env /dev/null
}

wt_teardown() {
  local db; db=$(_wt_db)
  rm -f "$HOME/.puma-dev/$WT_SLUG" && msg "removed puma-dev entry $WT_SLUG"
  # Flush this worktree's redis db so a future worktree reusing the index inherits
  # no stale Sidekiq state. Guarded to > 0 so db 0 (the canonical dev db) is never touched.
  if [ "${WT_REDIS:-0}" -gt 0 ] 2>/dev/null; then
    redis-cli -n "$WT_REDIS" flushdb >/dev/null 2>&1 && msg "flushed redis db $WT_REDIS"
  fi
  if psql -lqtA 2>/dev/null | cut -d'|' -f1 | grep -qx "$db"; then
    # Drop any lingering connections (a still-running dev server) before dropdb.
    psql -q -d postgres -c \
      "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$db' AND pid<>pg_backend_pid();" \
      >/dev/null 2>&1
    dropdb "$db" && msg "dropped database $db"
  fi
}
