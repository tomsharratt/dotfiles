#!/usr/bin/env bash
# test/pq-design.sh - designs travel with the task: `--design`, auto-detection
# from the plan's text, the `design:` header and design/ directory, the
# wizard's design question - and name_plan's reading of Haiku's reply.
#
# Same conventions as test/pq-add-pick.sh: plain bash, no framework, PQ_HOME and
# PQ_PLANS_DIR exported before sourcing pq, a PATH-stubbed `claude` that
# dispatches on --model and on a marker line in the plan it is handed, and a
# throwaway git repo with refs/remotes/origin/HEAD faked by hand.
#
# SC2034: the locals its wizard cases hand in through bash's dynamic scope are
# read by the pq sourced below.
# SC2015: `ok` never fails, so `[ ... ] && ok || bad` is an if/else.
# shellcheck disable=SC2034,SC2015
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PQ_HOME=$(mktemp -d)
export PQ_HOME
PQ_PLANS_DIR=$(mktemp -d)
export PQ_PLANS_DIR

STUBBIN=$(mktemp -d)
# `haiku` reads the plan on stdin, keeps the prompt it was given in
# .haiku-prompt next to itself, and answers off its marker line.
cat > "$STUBBIN/claude" <<'STUBEOF'
#!/usr/bin/env bash
model="" prompt=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) model=$2; shift 2 ;;
    -p) shift ;;
    *) prompt=$1; shift ;;
  esac
done
case "$model" in
  haiku)
    content=$(cat)
    printf '%s' "$prompt" > "$(dirname "$0")/.haiku-prompt"
    case "$content" in
      *"MARKER: plain"*)
        printf '{"branch":"tom/plain-plan","intent":"Just the one thing."}\n' ;;
      *"MARKER: bare"*)
        printf '{"branch":"fix-login-swallow","intent":"Bare."}\n' ;;
      *"MARKER: slashed"*)
        printf '{"branch":"ios/tip-fee","intent":"Slashed."}\n' ;;
      *"MARKER: tomslashed"*)
        printf '{"branch":"tom/android/tip-fee","intent":"Slashed under tom."}\n' ;;
      *"MARKER: nobranch"*)
        printf '{"branch":"tom/","intent":"No words."}\n' ;;
      *) printf '{}\n' ;;
    esac
    ;;
  *) exit 1 ;;
esac
STUBEOF
chmod +x "$STUBBIN/claude"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/gh"
cat > "$STUBBIN/herdr" <<'EOF'
#!/bin/sh
case "$*" in
  "api snapshot") echo '{"result":{"snapshot":{"panes":[]}}}'; exit 0 ;;
esac
exit 1
EOF
chmod +x "$STUBBIN/gh" "$STUBBIN/herdr"
export PATH="$STUBBIN:$PATH"

# shellcheck source=/dev/null
source "$HERE/../.local/bin/pq"
# shellcheck source=test/lib.sh
source "$HERE/lib.sh"
gum_stub "$STUBBIN" "$PQ_HOME/.gum"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }
# The first path a glob matched, or nothing: `ls -d glob | head -1` without parsing ls.
first_of() { [ ! -e "${1:-}" ] || printf '%s' "$1"; }
has() { case "$1" in *"$2"*) ok ;; *) bad "$3 (got '$1')" ;; esac; }
hasnt() { case "$1" in *"$2"*) bad "$3 (got '$1')" ;; *) ok ;; esac; }

cleanup() { rm -rf "$PQ_HOME" "$PQ_PLANS_DIR" "$STUBBIN" "${REPO:-}" "${DES:-}" "${FAKEHOME:-}"; }
trap cleanup EXIT

REPO=$(mktemp -d)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$REPO/.git/refs/remotes/origin"
git -C "$REPO" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master

# The design files. A space in the name is the case that matters: Claude
# Design names its files that way ("Onboarding Refresh.dc.html").
DES=$(mktemp -d)
DC="$DES/Onboarding Refresh.dc.html"
printf '<html><body>artboard</body></html>\n' > "$DC"
printf 'PNG\n' > "$DES/shot.png"
# A view template that exists on disk and ends in .html.erb - must never match.
mkdir -p "$DES/app/views"
printf '<%%= yield %%>\n' > "$DES/app/views/show.html.erb"

reset_tasks() {
  rm -rf "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done"
  mkdir -p "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done"
}
reset_tasks
queue_count() { dir_count "$PQ_HOME/queue"; }
mkplan() {                              # file marker [extra lines...]
  local f=$1 m=$2; shift 2
  { printf '# A plan\n\nMARKER: %s\n\n' "$m"; for l in "$@"; do printf '%s\n' "$l"; done; } > "$f"
}
echo "== --design copies the files into design/ and writes the header ==" >&2
PLAN="$PQ_HOME/.p1.md"; mkplan "$PLAN" plain "Body."
add_as "$PLAN" tom/d1 --repo "$REPO" --design "$DC" --design "$DES/shot.png" 2>"$PQ_HOME/.err"
rc=$?
[ "$rc" -eq 0 ] && ok || bad "add with two designs should succeed: $(cat "$PQ_HOME/.err")"
t=$(find_task d1)
[ -f "$t/design/Onboarding Refresh.dc.html" ] && ok || bad "the .dc.html should be copied into design/, space and all"
[ -f "$t/design/shot.png" ] && ok || bad "the png should be copied into design/"
eq "$(hdr "$t/plan.md" design)" "Onboarding Refresh.dc.html, shot.png" "the design: header lists the basenames, comma separated"
has "$(cat "$PQ_HOME/.err")" "design: Onboarding Refresh.dc.html, shot.png" "the add reports the design set"
cmp -s "$DC" "$t/design/Onboarding Refresh.dc.html" && ok || bad "the copy must be byte-identical to the source"
eq "$(readlink "$PQ_HOME/tasks/$(basename "$t")")" "$t" "add makes the stable tasks/ link"

echo "== a task with no design writes no design: header at all ==" >&2
add_as "$PLAN" tom/d0 --repo "$REPO" 2>/dev/null
t=$(find_task d0)
grep -q '^design:' "$t/plan.md" && bad "no design set must mean no header, not an empty one" || ok
[ -d "$t/design" ] && bad "no design set must mean no design/ directory" || ok

echo "== a missing --design path dies before anything is queued ==" >&2
before=$(queue_count)
add_as "$PLAN" tom/d2 --repo "$REPO" --design /nonexistent/nope.png >/dev/null 2>"$PQ_HOME/.err" \
  && bad "a missing design path must fail the add" || ok
has "$(cat "$PQ_HOME/.err")" "no such design file: /nonexistent/nope.png" "and say which path"
eq "$(queue_count)" "$before" "nothing may be queued when a design is missing"

echo "== auto-detection: an absolute path and a ~ path in the plan text ==" >&2
# The ~ form needs a file under $HOME, so HOME is pointed at a throwaway
# directory for this one add - design_expand reads it at call time.
FAKEHOME=$(mktemp -d)
printf 'PNG\n' > "$FAKEHOME/mock.png"
PLAN2="$PQ_HOME/.p2.md"
mkplan "$PLAN2" plain "Design file: $DC" "The mock is at ~/mock.png, roughly." "Not a design: $DES/app/views/show.html.erb"
HOME=$FAKEHOME add_as "$PLAN2" tom/d3 --repo "$REPO" 2>"$PQ_HOME/.err"
rc=$?
[ "$rc" -eq 0 ] && ok || bad "auto-detect add should succeed: $(cat "$PQ_HOME/.err")"
t=$(find_task d3)
eq "$(hdr "$t/plan.md" design)" "Onboarding Refresh.dc.html, mock.png" \
  "both the absolute path (with a space) and the ~ path are detected; the .html.erb is not"
[ -f "$t/design/Onboarding Refresh.dc.html" ] && ok || bad "the detected .dc.html is copied"
[ -f "$t/design/mock.png" ] && ok || bad "the detected ~ png is copied"
[ -f "$t/design/show.html.erb" ] && bad ".html.erb must never be treated as a design" || ok
hasnt "$(cat "$PQ_HOME/.err")" "not on disk" "nothing here was dangling"

echo "== auto-detection: a url is never read as a path ==" >&2
PLAN3="$PQ_HOME/.p3.md"
mkplan "$PLAN3" plain "Design source: https://claude.ai/design/p/1de6ab63?file=Audio+Player.dc.html and nothing else."
add_as "$PLAN3" tom/d4 --repo "$REPO" 2>"$PQ_HOME/.err"
t=$(find_task d4)
eq "$(hdr "$t/plan.md" design)" "" "a claude.ai url is not a design path"
hasnt "$(cat "$PQ_HOME/.err")" "not on disk" "and is not warned about as a dangling one either"
# (A plan that only cites a design by url is still design-built, so the wizard
# asks for a file - see the add_wizard cases below.)

echo "== auto-detection: a dangling path warns by name and does not block the add ==" >&2
PLAN4="$PQ_HOME/.p4.md"
mkplan "$PLAN4" plain "Design file: /nonexistent/Missing Board.dc.html"
add_as "$PLAN4" tom/d5 --repo "$REPO" 2>"$PQ_HOME/.err"
rc=$?
[ "$rc" -eq 0 ] && ok || bad "a dangling design mention must not fail the add"
has "$(cat "$PQ_HOME/.err")" "not on disk: /nonexistent/Missing Board.dc.html" "the dangling path is named"
t=$(find_task d5)
eq "$(hdr "$t/plan.md" design)" "" "and nothing is attached"

echo "== design_mentions, directly: the shapes it reads ==" >&2
M="$PQ_HOME/.m.md"
# shellcheck disable=SC2016  # the backticks are markdown, not a substitution
printf 'See `%s` for the board.\n' "$DES/shot.png" > "$M"
eq "$(design_mentions "$M")" "$DES/shot.png" "a backticked path is read up to the closing backtick"
printf 'Two: %s and %s.\n' "$DES/shot.png" "$DES/shot.png" > "$M"
eq "$(design_mentions "$M")" "$DES/shot.png" "the same path twice is one design"
printf 'Files: %s, then %s.\n' "$DES/shot.png" "$DES/app/views/show.html.erb" > "$M"
eq "$(design_mentions "$M")" "$DES/shot.png" "trailing punctuation is stripped; the .html.erb is not a design"
printf 'Design file: %s\n' "$DC" > "$M"
eq "$(design_mentions "$M")" "$DC" "the own-line citation with a space in the name is read whole"
printf 'nothing here\n' > "$M"
eq "$(design_mentions "$M")" "" "a plan with no design extension yields nothing"
design_hinted "$PLAN3" && ok || bad "a claude.ai/design url marks the plan as design-built"
design_hinted "$PLAN4" && ok || bad "a .dc.html mention marks the plan as design-built"
design_hinted "$PLAN" && bad "a plain plan is not design-built" || ok

echo "== add_wizard: the design question, asked only when it should be ==" >&2
# The wizard reaches cmd_add's locals through dynamic scope; this wrapper
# stands in for cmd_add exactly as test/pq-add-pick.sh's run_wizard does. The
# model and effort questions come first, so each case answers them too.
run_wizard() {                          # hinted -> "design=[Y]"
  local after_vals="" repo=$REPO
  local design_hinted=$1 design_vals=""
  local model=$PQ_DEFAULT_MODEL effort=$PQ_DEFAULT_EFFORT
  add_wizard
  printf 'design=[%s]' "$design_vals"
}
reset_tasks                             # nothing queued, so no blocker question follows
gum_reset; gum_answer sonnet; gum_answer medium; gum_answer "$DES/shot.png"
out=$(run_wizard 1 2>"$PQ_HOME/.err")
eq "$out" "design=[$DES/shot.png"$'\n'"]" "a file picked at the question joins the design set"
has "$(cat "$PQ_HOME/.err")" "built from a design, but no design file was found" "the question says why it is asked"
has "$(gum_calls)" "file --height 15 $HOME" "and starts the picker in a directory that exists"
gum_reset; gum_answer sonnet; gum_answer medium; gum_answer "" 1
out=$(run_wizard 1 2>"$PQ_HOME/.err")
eq "$out" "design=[]" "Esc goes without"
has "$(cat "$PQ_HOME/.err")" "build from the plan's prose alone" "and says so, loudly"
gum_reset; gum_answer sonnet; gum_answer medium
out=$(run_wizard 0 2>"$PQ_HOME/.err")
hasnt "$(gum_calls)" "file" "a plan that is not design-built is not asked"

echo "== name_plan: one line, branch then intent then the security verdict ==" >&2
PP="$PQ_HOME/.plain.md"; mkplan "$PP" plain
named=$(name_plan "$PP")
eq "$(wc -l <<<"$named" | tr -d ' ')" "1" "the reply is one line"
IFS=$'\t' read -r b i <<<"$named"
eq "$b" "tom/plain-plan" "IFS=tab read takes the branch"
eq "$i" "Just the one thing." "...and the intent"
hp=$(cat "$STUBBIN/.haiku-prompt")
hasnt "$hp" "parts" "Haiku is no longer asked for the plan's pull requests"

echo "== name_plan: the branch is always tom/<words>, whatever Haiku sent back ==" >&2
PB="$PQ_HOME/.bare.md"; mkplan "$PB" bare
IFS=$'\t' read -r b _ <<<"$(name_plan "$PB")"
eq "$b" "tom/fix-login-swallow" "a bare name gets the prefix"
# A slash inside the words keeps them all, as a dash, rather than cutting the
# name down to its last segment.
PS="$PQ_HOME/.slashed.md"; mkplan "$PS" slashed
IFS=$'\t' read -r b _ <<<"$(name_plan "$PS")"
eq "$b" "tom/ios-tip-fee" "a slash without the prefix keeps every word"
PT="$PQ_HOME/.tomslashed.md"; mkplan "$PT" tomslashed
IFS=$'\t' read -r b _ <<<"$(name_plan "$PT")"
eq "$b" "tom/android-tip-fee" "and so does one under it"
IFS=$'\t' read -r b _ <<<"$(name_plan "$PP")"
eq "$b" "tom/plain-plan" "a name that already has it is left alone"
PN="$PQ_HOME/.nobranch.md"; mkplan "$PN" nobranch
# `cut`, as cmd_add reads it: `read` would strip the empty field's leading tab.
named=$(name_plan "$PN")
eq "$(cut -f1 <<<"$named")" "" "a prefix with no words is no name at all"
eq "$(cut -f2 <<<"$named")" "No words." "and the intent still comes through"
reset_tasks
add_as "$PB" "" --repo "$REPO" 2>"$PQ_HOME/.err"
t=$(find_task fix-login-swallow)
eq "$(hdr "$t/plan.md" branch)" "tom/fix-login-swallow" "the queued task carries the prefixed branch"
reset_tasks
add_as "$PN" "" --repo "$REPO" >/dev/null 2>"$PQ_HOME/.err" && bad "a plan Haiku gave no words for must not queue" || ok
has "$(cat "$PQ_HOME/.err")" "could not name the plan" "and says so"

echo "== pq ls --json carries the design set ==" >&2
reset_tasks
add_as "$PLAN" tom/dj --repo "$REPO" --design "$DES/shot.png" --design "$DC" >/dev/null 2>&1
add_as "$PLAN" tom/dj0 --repo "$REPO" >/dev/null 2>&1
out=$(main ls --json 2>/dev/null)
eq "$(jq -c '.[] | select(.task == "dj") | .design' <<<"$out")" '["shot.png","Onboarding Refresh.dc.html"]' "the design basenames, in order"
eq "$(jq -c '.[] | select(.task == "dj0") | .design' <<<"$out")" '[]' "and an empty array when there is none"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
