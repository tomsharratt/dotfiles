#!/usr/bin/env bash
# test/wt-dev-migrate.sh - supercast's dev boot applies pending migrations to the
# worktree's own database before foreman starts, and keeps db/schema.rb clean.
#
# Why this file exists: a worktree created a while ago served HTTP 500 on every page
# after a dev server restart, with ActiveRecord::PendingMigrationError. Master had
# gained a migration after the worktree's database was copied, the branch was rebased
# onto it, and nothing ran pending migrations when the dev server booted - its sidekiq
# jobs were failing on PG::UndefinedColumn too. Running the migrate by hand fixed it,
# but re-dumped db/schema.rb in postgres 18's rendering of partial-index clauses, which
# left the worktree dirty - and a dirty worktree is one `wt rm` refuses.
#
# Each case runs `wt dev <path>` as the dev pane does - and the last few
# `wt provision <path>`, whose migrate keeps schema.rb by the same rule - against a
# real repo and a linked worktree. `psql`, `foreman` and everything else provisioning
# runs are PATH stubs, and the worktree's own bin/rails is a stub committed to the
# fixture repo, so nothing here reaches a real database, redis, migrate or dev server.
# psql's query, rails and foreman log to one file, which is what proves the migrate
# ran before foreman.
#
# SC2015: `ok` never fails, so `[ ... ] && ok || bad` is an if/else.
# shellcheck disable=SC2015
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=test/sandbox.sh
source "$HERE/sandbox.sh"
WT="$HERE/../.local/bin/wt"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq()  { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }
has() { case "$1" in *"$2"*) ok ;; *) bad "$3 (got '$1')" ;; esac; }
hasnt() { case "$1" in *"$2"*) bad "$3 (got '$1')" ;; *) ok ;; esac; }

FIX=$(mktemp -d)
cleanup() { sandbox_cleanup; }
trap cleanup EXIT

# wt computes STATE_DIR and PROFILE_DIR from the sandbox's XDG dirs, inside its root,
# as is everything this file writes.
STATE_DIR="$XDG_STATE_HOME/wt"
PROFILE_DIR="$XDG_CONFIG_HOME/wt/profiles"
mkdir -p "$STATE_DIR" "$PROFILE_DIR" "$FIX/bin"
sandbox_guard
# The profile under test, where wt looks for a repo named supercast.
cp "$HERE/../.config/wt/profiles/supercast.sh" "$PROFILE_DIR/supercast.sh"

CALLS="$FIX/calls"          # psql, rails and foreman, in the order they ran
APPLIED="$FIX/applied"      # the worktree database's schema_migrations

# psql: answers the schema_migrations query from $APPLIED, or fails as a psql that
# cannot reach postgres does when $FIX/psql-down exists. For provisioning it lists no
# databases and swallows the seed it is piped; only the query is logged.
cat > "$FIX/bin/psql" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *schema_migrations*) ;;
  -lqtA) exit 0 ;;
  *) cat >/dev/null; exit 0 ;;
esac
printf 'psql %s\n' "\$*" >> "$CALLS"
[ -f "$FIX/psql-down" ] && { echo 'psql: error: connection to server on socket "/tmp/.s.PGSQL.5432" failed' >&2; exit 2; }
cat "$APPLIED"
EOF
# The rest of what provisioning runs, each a stub that only says it was called.
for c in bundle createdb dropdb pg_dump yarn launchctl; do
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %s "$*" >> "%s"\n' "$c" "$FIX/provision-calls" > "$FIX/bin/$c"
  chmod +x "$FIX/bin/$c"
done
# foreman: the dev server, which only has to say it started.
cat > "$FIX/bin/foreman" <<EOF
#!/usr/bin/env bash
printf 'foreman %s\n' "\$*" >> "$CALLS"
EOF
# redis-cli: nothing here should ask redis anything - the state file below already
# holds both of the worktree's indexes - so a call is only logged, never passed on.
cat > "$FIX/bin/redis-cli" <<EOF
#!/usr/bin/env bash
printf 'redis-cli %s\n' "\$*" >> "$FIX/redis-calls"
exit 1
EOF
chmod +x "$FIX/bin/psql" "$FIX/bin/foreman" "$FIX/bin/redis-cli"
export PATH="$FIX/bin:$PATH"
[ "$(command -v psql)" = "$FIX/bin/psql" ] || { echo "ABORT: psql is not the stub - refusing to reach a real postgres" >&2; exit 1; }
[ "$(command -v redis-cli)" = "$FIX/bin/redis-cli" ] || { echo "ABORT: redis-cli is not the stub - refusing to reach a real redis" >&2; exit 1; }
for c in bundle createdb dropdb pg_dump yarn launchctl; do
  [ "$(command -v "$c")" = "$FIX/bin/$c" ] || { echo "ABORT: $c is not the stub - refusing to run the real one" >&2; exit 1; }
done
[ "$(command -v foreman)" = "$FIX/bin/foreman" ] || { echo "ABORT: foreman is not the stub - refusing to start a real dev server" >&2; exit 1; }

# ── a repo named supercast, its origin, and a linked worktree ──────────────────
REMOTE="$FIX/origin.git"
REPO="$FIX/supercast"
git init -q --bare -b master "$REMOTE"
git clone -q "$REMOTE" "$REPO" 2>/dev/null
mkdir -p "$REPO/bin" "$REPO/db/migrate"
printf 'web: rails s -p 3000\nworker: bundle exec sidekiq\n' > "$REPO/Procfile.dev"
# The committed schema, as an older postgres dumped it.
cat > "$REPO/db/schema.rb" <<'EOF'
ActiveRecord::Schema[8.0].define(version: 2026_10_28_130000) do
  create_table "notifications", force: :cascade do |t|
    t.string "medium"
    t.integer "batch_id"
    t.index ["medium"], name: "index_notifications_on_medium", where: "((medium)::text = ANY ((ARRAY['a'::character varying, 'b'::character varying])::text[]))"
  end
end
EOF
printf 'class CreateNotifications < ActiveRecord::Migration[8.0]; end\n' \
  > "$REPO/db/migrate/20260101000000_create_notifications.rb"
# bin/rails: a migrate that records each version on disk as applied, and re-dumps
# db/schema.rb as postgres 18 renders that index - or, with $FIX/migrate-fails, the
# kind of failure a real migration has. What it was run with is logged.
cat > "$REPO/bin/rails" <<EOF
#!/usr/bin/env bash
printf 'rails %s DATABASE_URL=%s skip_on_db_migrate=%s\n' "\$*" "\${DATABASE_URL:-}" "\${skip_on_db_migrate:-}" >> "$CALLS"
[ "\$*" = db:migrate ] || exit 0
if [ -f "$FIX/migrate-fails" ]; then
  echo "== 20261028130000 AddBulkBatchColumnsToNotifications: migrating ======"
  echo 'PG::DuplicateColumn: ERROR:  column "batch_id" of relation "notifications" already exists' >&2
  echo 'bin/rails aborted!' >&2
  exit 1
fi
for f in db/migrate/*.rb; do
  v=\${f##*/}; v=\${v%%_*}
  grep -qx "\$v" "$APPLIED" || printf '%s\n' "\$v" >> "$APPLIED"
done
sed "s/ANY ((ARRAY\['a'::character varying, 'b'::character varying\])::text\[\])/ANY (ARRAY[('a'::character varying)::text, ('b'::character varying)::text])/" \
  db/schema.rb > db/schema.rb.dump && mv db/schema.rb.dump db/schema.rb
EOF
chmod +x "$REPO/bin/rails"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m init
git -C "$REPO" push -q origin master 2>/dev/null
git -C "$REPO" remote set-head origin master >/dev/null 2>&1

WTP="$FIX/wt-one"
git -C "$REPO" worktree add -q -b task/one "$WTP" origin/master 2>/dev/null

# Then master gains a migration - schema.rb updated to match - after the worktree's
# database was copied, and the branch is rebased onto it.
printf 'class AddBulkBatchColumnsToNotifications < ActiveRecord::Migration[8.0]; end\n' \
  > "$REPO/db/migrate/20261028130000_add_bulk_batch_columns_to_notifications.rb"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "add bulk batch columns"
git -C "$REPO" push -q origin master 2>/dev/null

DB="supercast-web_development_task_one"
cat > "$STATE_DIR/supercast--task-one.env" <<EOF
WT_NAME=task/one
WT_SLUG=task-one
WT_PATH=$WTP
WT_REPO=$REPO
WT_REPO_NAME=supercast
WT_DOMAIN=task-one.test
WT_URL=https://task-one.test
WT_PORT=3101
WT_REDIS=1
WT_REDIS_TEST=2
EOF
COMMITTED_SCHEMA=$(git -C "$REPO" show origin/master:db/schema.rb)

# Each case starts from the rebased branch, clean, with its database caught up to
# the versions given.
reset() {                               # applied versions...
  git -C "$WTP" reset -q --hard origin/master
  git -C "$WTP" clean -qfd
  rm -f "$FIX/psql-down" "$FIX/migrate-fails"
  : > "$CALLS"
  printf '%s\n' "$@" > "$APPLIED"
}
# `wt dev`, as the dev pane runs it. SHELL is what wt drops to once the server
# stops, and true lets the command return.
run_dev() { ( cd "$WTP" && SHELL=/usr/bin/true "$WT" dev "$WTP" 2>&1 ); }
calls() { cat "$CALLS"; }
# The first word of each logged call, in order.
order() { cut -d' ' -f1 "$CALLS" | tr '\n' ' ' | sed 's/ $//'; }
schema() { cat "$WTP/db/schema.rb"; }
status() { git -C "$WTP" status --porcelain; }

echo "== nothing pending: one cheap query, no migrate, and the server starts ==" >&2
reset 20260101000000 20261028130000
out=$(run_dev)
eq "$(order)" "psql foreman" "a current database costs one psql query and nothing else before foreman"
has "$(calls)" "psql -XqtA -d $DB" "the query goes to the worktree's own database"
hasnt "$out" "migrat" "and nothing is said about migrations"
eq "$(status)" "" "the worktree is left clean"

echo "== master's migration pending: applied before foreman, schema.rb kept as committed ==" >&2
reset 20260101000000
out=$(run_dev)
eq "$(order)" "psql rails foreman" "the migrate runs once, after the check and before foreman"
has "$(calls)" "rails db:migrate DATABASE_URL=postgres:///$DB " "against the worktree's own dev database"
eq "$(grep -c 'migrated' <<<"$out")" "1" "what it did is one line"
has "$out" "migrated 1 pending migration - db/schema.rb left as committed" "and that line says it"
eq "$(tail -1 "$APPLIED")" "20261028130000" "the database now has master's migration"
eq "$(schema)" "$COMMITTED_SCHEMA" "schema.rb is byte for byte the committed file, not postgres 18's re-dump"
eq "$(status)" "" "so the worktree is clean, and \`wt rm\` will not refuse it"
# What master already has changes no file - nor do annotate's model comments.
has "$(calls)" "skip_on_db_migrate=1" "annotate's re-annotation is skipped when nothing of the branch's is pending"

echo "== two pending: counted in the plural ==" >&2
reset
out=$(run_dev)
has "$out" "migrated 2 pending migrations" "the count is in the plural"

echo "== schema.rb already changed on the branch: its migrate's output is kept ==" >&2
reset 20260101000000
printf '# a change of the branch'"'"'s own\n' >> "$WTP/db/schema.rb"
out=$(run_dev)
eq "$(order)" "psql rails foreman" "the pending migration is still applied before foreman"
has "$out" "migrated 1 pending migration" "and said so"
hasnt "$out" "left as committed" "without claiming schema.rb was put back"
has "$(schema)" "a change of the branch's own" "the branch's own change is still there"
has "$(schema)" "ANY (ARRAY[('a'::character varying)::text" "beside what its migrate dumped"
eq "$(grep -c 'skip_on_db_migrate=$' "$CALLS")" "1" "and annotate runs as on any migrate"

echo "== the branch adds the migration: its re-dump is kept ==" >&2
reset 20260101000000 20261028130000
printf 'class AddBranchThing < ActiveRecord::Migration[8.0]; end\n' \
  > "$WTP/db/migrate/20261101000000_add_branch_thing.rb"
git -C "$WTP" add -A
git -C "$WTP" commit -q -m "a migration of the branch's own"
out=$(run_dev)
eq "$(order)" "psql rails foreman" "the branch's migration is applied before foreman"
eq "$(tail -1 "$APPLIED")" "20261101000000" "to the worktree's database"
hasnt "$out" "left as committed" "and schema.rb is not put back"
eq "$(status)" " M db/schema.rb" "its re-dump may be the only record of the schema change, so it stays"

echo "== a migration nobody has committed yet is the branch's own too ==" >&2
reset 20260101000000
printf 'class Wip < ActiveRecord::Migration[8.0]; end\n' > "$WTP/db/migrate/20261101000001_wip.rb"
out=$(run_dev)
has "$out" "migrated 2 pending migrations" "master's and the uncommitted one are both applied"
hasnt "$out" "left as committed" "and with one of them the branch's, schema.rb is not put back"
has "$(status)" " M db/schema.rb" "so its re-dump stays"

echo "== master's migration edited on the branch: not master's any more ==" >&2
reset 20260101000000
printf '# edited\n' >> "$WTP/db/migrate/20261028130000_add_bulk_batch_columns_to_notifications.rb"
git -C "$WTP" commit -qam "edit master's migration"
out=$(run_dev)
hasnt "$out" "left as committed" "a migration that differs from master's keeps the re-dump"

echo "== a failing migration: warned with its error, and the server starts anyway ==" >&2
reset 20260101000000
touch "$FIX/migrate-fails"
out=$(run_dev)
eq "$(order)" "psql rails foreman" "foreman still starts after the migrate fails"
has "$out" "db:migrate FAILED on 1 pending migration" "the failure is said out loud"
has "$out" 'PG::DuplicateColumn: ERROR:  column "batch_id" of relation "notifications" already exists' \
  "with the migration's own error"
has "$out" "starting the dev server anyway" "and that the server starts regardless"
hasnt "$out" "migrated 1" "it does not claim to have migrated"
eq "$(schema)" "$COMMITTED_SCHEMA" "schema.rb is left as it was"
eq "$(status)" "" "and the worktree clean"

echo "== a database that cannot be read: warned, no migrate, and the server starts ==" >&2
reset 20260101000000
touch "$FIX/psql-down"
out=$(run_dev)
eq "$(order)" "psql foreman" "no migrate is attempted against a database nobody could read"
has "$out" "could not read $DB's schema_migrations" "and the check is reported as skipped"

echo "== and the dev boot never asked redis anything ==" >&2
[ ! -s "$FIX/redis-calls" ] && ok || bad "redis-cli was called: $(cat "$FIX/redis-calls")"

# Provisioning's own migrate keeps schema.rb by the same rule. Its database is a fresh
# copy of the canonical dev db, which is often behind master - so the migrate there
# re-dumped schema.rb on nearly every `wt new`.
mkdir -p "$HOME/.puma-dev"
run_provision() { ( cd "$WTP" && "$WT" provision "$WTP" 2>&1 ); }

echo "== provisioning: master's migrations pending on the copy, schema.rb kept as committed ==" >&2
reset 20260101000000
out=$(run_provision); rc=$?
eq "$rc" "0" "provisioning succeeds"
eq "$(grep -c '^rails db:migrate' "$CALLS")" "1" "its migrate runs once"
has "$out" "db/schema.rb left as committed" "and says schema.rb was put back"
eq "$(schema)" "$COMMITTED_SCHEMA" "schema.rb is the committed file"
eq "$(status)" "" "so a fresh worktree starts clean"

echo "== provisioning a branch with a migration of its own keeps the re-dump ==" >&2
reset 20260101000000 20261028130000
printf 'class AddBranchThing < ActiveRecord::Migration[8.0]; end\n' \
  > "$WTP/db/migrate/20261101000000_add_branch_thing.rb"
git -C "$WTP" add -A
git -C "$WTP" commit -q -m "a migration of the branch's own"
out=$(run_provision)
hasnt "$out" "left as committed" "schema.rb is not put back"
eq "$(status)" " M db/schema.rb" "its re-dump stays"

echo "== provisioning stops on a failing migrate, and shows its error ==" >&2
reset 20260101000000
touch "$FIX/migrate-fails"
out=$(run_provision); rc=$?
[ "$rc" -ne 0 ] && ok || bad "a failed migrate still fails provisioning"
has "$out" "PG::DuplicateColumn" "with the migration's own error"
has "$out" "db:migrate failed - fix before testing" "and the reason"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
