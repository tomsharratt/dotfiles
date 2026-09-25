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
#
# SC2034: the WT_* set here are read by the profile sourced below.
# SC2015: `ok` never fails, so `[ ... ] && ok || bad` is an if/else.
# shellcheck disable=SC2034,SC2015
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

echo "== PORT and REDIS_URL are the same in either environment ==" >&2
for env in "" test; do
  eq "$(envvar "$env" PORT)" "3104" "PORT is unchanged (RAILS_ENV='$env')"
  eq "$(envvar "$env" REDIS_URL)" "redis://localhost:6379/3" \
    "REDIS_URL is unchanged (RAILS_ENV='$env') - the test redis index is NOT isolated"
done

echo "== the worktree's domain is the dev server's, and never the test suite's ==" >&2
# The seven failures every session re-proved under `wt test` were this. figaro
# skips a key already in ENV, so an exported `domain` beats application.yml's
# `test: domain: lvh.me`; session_store then scopes the test cookie to
# <slug>.test, rack-test drops it on a request to x.lvh.me, and every spec that
# carries a session across requests fails - along with the Spotify payload specs
# that build `https://app.#{ENV['domain']}/...`. The suite expects its own domain.
eq "$(envvar "" LOCAL_DOMAIN)" "$WT_DOMAIN" "the dev server still gets the worktree's LOCAL_DOMAIN"
eq "$(envvar "" domain)" "$WT_DOMAIN" "and its domain"
for key in LOCAL_DOMAIN domain; do
  eq "$(envvar test "$key")" "" "\`wt test\` exports no $key"
  # ...and takes one away that the calling shell already had: a `wt run` shell, or
  # a dev pane, has both exported, and inheriting them is the same failure.
  eq "$( ( export LOCAL_DOMAIN=x.test domain=x.test; envvar test "$key" ) )" "" \
    "nor lets the caller's $key through"
done

echo "== the dev server's Procfile: this port, no stripe, and a css watcher that stays up ==" >&2
# supercast's own Procfile.dev, as it stands.
PF=$(mktemp)
cat > "$PF" <<'EOF'
web: RUBY_YJIT_ENABLE=1 FEEDS_SERVICE_URL=https://feeds.dev-tunnel.supercast.tech rails s -p 3000 -b 0.0.0.0
worker: RUBY_YJIT_ENABLE=1 FEEDS_SERVICE_URL=https://feeds.dev-tunnel.supercast.tech bundle exec sidekiq
stripe_connect: stripe listen -c http://localhost:3000/webhooks/stripe/connect/events
css: rails tailwindcss:watch
js: yarn build --watch
EOF
out=$(_wt_procfile "$PF" 3104)
case "$out" in *"rails s -p 3104 -b 0.0.0.0"*) ok ;; *) bad "the web process binds the worktree's port (got '$out')" ;; esac
case "$out" in *stripe*) bad "stripe_connect is dropped - every worktree would process the same webhooks" ;; *) ok ;; esac
# Plain `tailwindcss:watch` exits after one build when stdin is not a terminal,
# and foreman takes the stack down with it.
eq "$(grep '^css:' <<<"$out")" 'css: rails "tailwindcss:watch[always]"' "the css watcher is told to stay up without a terminal"
eq "$(grep '^js:' <<<"$out")" "js: yarn build --watch" "the rest is as it was"
rm -f "$PF"

echo "== a bare \`bundle exec rspec\` gets what \`wt test\` gives it, through .rspec ==" >&2
# A worktree like supercast's: .rspec gitignored, and pushed, so nothing is unpushed.
WT_PATH=$(mktemp -d)
REMOTE=$(mktemp -d)
git init -q -b master "$WT_PATH"
printf '.rspec\n' > "$WT_PATH/.gitignore"
git -C "$WT_PATH" add .gitignore
git -C "$WT_PATH" -c user.email=t@t -c user.name=t commit -q -m init
git init -q --bare "$REMOTE"
git -C "$WT_PATH" remote add origin "$REMOTE"
git -C "$WT_PATH" push -q origin master 2>/dev/null
_wt_rspec
[ -f "$WT_PATH/.rspec" ] && ok || bad "provisioning writes the worktree's .rspec"
# The guard pq's reap relies on: a worktree with anything wt_rspec wrote showing
# as uncommitted would be refused by `wt rm` and held by pq forever.
eq "$(unpushed_work "$WT_PATH" "$WT_PATH" master)" "" "the .rspec leaves nothing unpushed for \`wt rm\` to refuse"

# The file through ERB and rspec-core's own comment filter, as rspec reads it.
# Prints the environment it leaves, then whatever it would pass rspec as options.
rspec_env() {                           # env assignments... -> db|redis|domain?|local?|options
  env -u DATABASE_URL -u REDIS_URL -u domain -u LOCAL_DOMAIN "$@" ruby -rerb -e '
    s = ERB.new(File.read(ARGV[0]), trim_mode: "-").result(binding)
    opts = s.split(/\n+/).reject { |l| l =~ /\A\s*#/ }.join(" ").strip
    puts [ENV["DATABASE_URL"], ENV["REDIS_URL"], ENV.key?("domain"), ENV.key?("LOCAL_DOMAIN"), opts].join("|")
  ' "$WT_PATH/.rspec"
}
eq "$(rspec_env)" "postgres://localhost/$TEST_DB|redis://localhost:6379/3|false|false|" \
  "with nothing set, the worktree's own test database and redis index, and no options"
eq "$(rspec_env DATABASE_URL="postgres:///$DEV_DB" domain=x.test LOCAL_DOMAIN=x.test)" \
  "postgres://localhost/$TEST_DB|redis://localhost:6379/3|false|false|" \
  "a \`wt run\` shell's dev database and domain are replaced, not inherited"
eq "$(rspec_env DATABASE_URL=postgres://localhost/mine_test REDIS_URL=redis://localhost:6379/9)" \
  "postgres://localhost/mine_test|redis://localhost:6379/9|false|false|" \
  "a DATABASE_URL and REDIS_URL set on purpose are kept"
eq "$(rspec_env DATABASE_URL="$(envvar test DATABASE_URL)")" \
  "postgres://localhost/$TEST_DB|redis://localhost:6379/3|false|false|" \
  "and \`wt test\`'s own is unchanged"

WT_REDIS=5 _wt_rspec
case "$(cat "$WT_PATH/.rspec")" in *"6379/5"*) ok ;; *) bad "wt's own .rspec is rewritten on the next boot" ;; esac
printf -- '--format documentation\n' > "$WT_PATH/.rspec"
_wt_rspec
eq "$(cat "$WT_PATH/.rspec")" "--format documentation" "a .rspec without wt's marker is someone else's, and left alone"
rm -rf "$WT_PATH" "$REMOTE"

# Where .rspec is not ignored, writing it would dirty the worktree: nothing is written.
WT_PATH=$(mktemp -d)
git init -q -b master "$WT_PATH"
_wt_rspec
[ -e "$WT_PATH/.rspec" ] && bad "a .rspec git does not ignore must not be written" || ok
rm -rf "$WT_PATH"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
