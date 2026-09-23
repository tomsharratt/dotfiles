#!/usr/bin/env bash
# test/pq-design.sh - designs travel with the task, and a plan that lays out
# several pull requests is offered as one task each: `--design`, auto-detection
# from the plan's text, the `design:` header
# and design/ directory, the wizard's two new questions, propagation through a
# split, and name_plan's multi-line reply.
#
# Same conventions as test/pq-add-pick.sh: plain bash, no framework, PQ_HOME and
# PQ_PLANS_DIR exported before sourcing pq, a PATH-stubbed `claude` that
# dispatches on --model and on a marker line in the plan it is handed, and a
# throwaway git repo with refs/remotes/origin/HEAD faked by hand.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PQ_HOME=$(mktemp -d)
export PQ_HOME
PQ_PLANS_DIR=$(mktemp -d)
export PQ_PLANS_DIR
# The default scan root for repo_candidates, permanently empty, so a --split
# here stays single-repo whatever else is sitting in $TMPDIR.
PQ_REPOS_DIR=$(mktemp -d)
export PQ_REPOS_DIR

STUBBIN=$(mktemp -d)
# `haiku` reads the plan on stdin, keeps the prompt it was given in
# .haiku-prompt next to itself, and answers off its marker line. Three
# shapes of reply: a full outline (three parts), a one-entry outline, and the
# pre-outline shape with no `parts` at all, which every existing caller still
# has to read. `opus` writes a two-part split whose first part names the
# design file and whose second does not.
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
      *"MARKER: three"*)
        printf '{"branch":"tom/three-parts","intent":"Three things, one plan.","parts":["Add the checklist step collection to Onboarding","Rebuild the Getting Started page around the new components","Add the Resources block and the sign-up link"]}\n' ;;
      *"MARKER: two"*)
        printf '{"branch":"tom/two-parts","intent":"Two things.","parts":["First half","Second half"]}\n' ;;
      *"MARKER: one"*)
        printf '{"branch":"tom/one-part","intent":"One thing.","parts":["The one thing"]}\n' ;;
      *"MARKER: plain"*)
        printf '{"branch":"tom/plain-plan","intent":"No outline at all."}\n' ;;
      *"MARKER: bare"*)
        printf '{"branch":"fix-login-swallow","intent":"Bare."}\n' ;;
      *"MARKER: slashed"*)
        printf '{"branch":"ios/tip-fee","intent":"Slashed."}\n' ;;
      *"MARKER: tomslashed"*)
        printf '{"branch":"tom/android/tip-fee","intent":"Slashed under tom."}\n' ;;
      *"MARKER: nobranch"*)
        printf '{"branch":"tom/","intent":"No words."}\n' ;;
      *"MARKER: part-a"*)
        printf '{"branch":"tom/part-a","intent":"Part A.","parts":["A"]}\n' ;;
      *"MARKER: part-b"*)
        printf '{"branch":"tom/part-b","intent":"Part B.","parts":["B"]}\n' ;;
      *) printf '{}\n' ;;
    esac
    ;;
  opus)
    printf 'MARKER: part-a\nBuild the screen to Onboarding Refresh.dc.html.\n' > 01-a.md
    printf 'MARKER: part-b\nWire the backend, nothing visual.\n' > 02-b.md
    printf '01-a.md\t\n02-b.md\t01-a.md\n' > graph.tsv
    printf '{"is_error":false,"total_cost_usd":0.1,"duration_ms":1000,"permission_denials":[]}\n'
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

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }
has() { case "$1" in *"$2"*) ok ;; *) bad "$3 (got '$1')" ;; esac; }
hasnt() { case "$1" in *"$2"*) bad "$3 (got '$1')" ;; *) ok ;; esac; }

cleanup() { rm -rf "$PQ_HOME" "$PQ_PLANS_DIR" "$PQ_REPOS_DIR" "$STUBBIN" "${REPO:-}" "${DES:-}" "${FAKEHOME:-}"; }
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
  rm -rf "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done" "$PQ_HOME/splits"
  mkdir -p "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done"
}
reset_tasks
queue_count() { ls -d "$PQ_HOME/queue"/*/ 2>/dev/null | wc -l | tr -d ' '; }
mkplan() {                              # file marker [extra lines...]
  local f=$1 m=$2; shift 2
  { printf '# A plan\n\nMARKER: %s\n\n' "$m"; for l in "$@"; do printf '%s\n' "$l"; done; } > "$f"
}

echo "== --design copies the files into design/ and writes the header ==" >&2
PLAN="$PQ_HOME/.p1.md"; mkplan "$PLAN" plain "Body."
slug=$(cmd_add "$PLAN" tom/d1 x --repo "$REPO" --design "$DC" --design "$DES/shot.png" 2>"$PQ_HOME/.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "add with two designs should succeed: $(cat "$PQ_HOME/.err")"
t=$(find_task "$slug")
[ -f "$t/design/Onboarding Refresh.dc.html" ] && ok || bad "the .dc.html should be copied into design/, space and all"
[ -f "$t/design/shot.png" ] && ok || bad "the png should be copied into design/"
eq "$(hdr "$t/plan.md" design)" "Onboarding Refresh.dc.html, shot.png" "the design: header lists the basenames, comma separated"
eq "$(design_list "$t" | tr '\n' '|')" "Onboarding Refresh.dc.html|shot.png|" "design_list reads them back one per line"
has "$(cat "$PQ_HOME/.err")" "design: Onboarding Refresh.dc.html, shot.png" "the add reports the design set"
cmp -s "$DC" "$t/design/Onboarding Refresh.dc.html" && ok || bad "the copy must be byte-identical to the source"
eq "$(readlink "$PQ_HOME/tasks/$(basename "$t")")" "$t" "add makes the stable tasks/ link"

echo "== a task with no design writes no design: header at all ==" >&2
slug=$(cmd_add "$PLAN" tom/d0 x --repo "$REPO" 2>/dev/null)
t=$(find_task "$slug")
grep -q '^design:' "$t/plan.md" && bad "no design set must mean no header, not an empty one" || ok
[ -d "$t/design" ] && bad "no design set must mean no design/ directory" || ok

echo "== a missing --design path dies before anything is queued ==" >&2
before=$(queue_count)
( cmd_add "$PLAN" tom/d2 x --repo "$REPO" --design /nonexistent/nope.png ) >/dev/null 2>"$PQ_HOME/.err" \
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
slug=$(HOME=$FAKEHOME cmd_add "$PLAN2" tom/d3 x --repo "$REPO" 2>"$PQ_HOME/.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "auto-detect add should succeed: $(cat "$PQ_HOME/.err")"
t=$(find_task "$slug")
eq "$(hdr "$t/plan.md" design)" "Onboarding Refresh.dc.html, mock.png" \
  "both the absolute path (with a space) and the ~ path are detected; the .html.erb is not"
[ -f "$t/design/Onboarding Refresh.dc.html" ] && ok || bad "the detected .dc.html is copied"
[ -f "$t/design/mock.png" ] && ok || bad "the detected ~ png is copied"
[ -f "$t/design/show.html.erb" ] && bad ".html.erb must never be treated as a design" || ok
hasnt "$(cat "$PQ_HOME/.err")" "not on disk" "nothing here was dangling"

echo "== auto-detection: a url is never read as a path ==" >&2
PLAN3="$PQ_HOME/.p3.md"
mkplan "$PLAN3" plain "Design source: https://claude.ai/design/p/1de6ab63?file=Audio+Player.dc.html and nothing else."
slug=$(cmd_add "$PLAN3" tom/d4 x --repo "$REPO" 2>"$PQ_HOME/.err")
t=$(find_task "$slug")
eq "$(hdr "$t/plan.md" design)" "" "a claude.ai url is not a design path"
hasnt "$(cat "$PQ_HOME/.err")" "not on disk" "and is not warned about as a dangling one either"
# ...but a plan that only cites a design by url IS a design plan with no file.
has "$(cat "$PQ_HOME/.err")" "no design file was found on disk or given" "a design cited with no file on disk warns, on an add that never reached the wizard"

echo "== auto-detection: a dangling path warns by name and does not block the add ==" >&2
PLAN4="$PQ_HOME/.p4.md"
mkplan "$PLAN4" plain "Design file: /nonexistent/Missing Board.dc.html"
slug=$(cmd_add "$PLAN4" tom/d5 x --repo "$REPO" 2>"$PQ_HOME/.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "a dangling design mention must not fail the add"
has "$(cat "$PQ_HOME/.err")" "not on disk: /nonexistent/Missing Board.dc.html" "the dangling path is named"
t=$(find_task "$slug")
eq "$(hdr "$t/plan.md" design)" "" "and nothing is attached"

echo "== design_mentions, directly: the shapes it reads ==" >&2
M="$PQ_HOME/.m.md"
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
# stands in for cmd_add exactly as test/pq-add-pick.sh's run_wizard does.
run_wizard() {                          # split hinted explicit outline -> "split=X design=[Y]"
  local split=$1 split_dir="" after_vals="" after_explicit=1 repo=$REPO
  local design_hinted=$2 design_explicit=$3 design_vals="" outline=$4
  # model_explicit=1 so the wizard's model question never fires here: every
  # case below feeds it exactly the line the DESIGN question should read, and a
  # question in front of it would eat that line. The model question's own cases
  # live in test/pq-add-pick.sh.
  local model=$PQ_DEFAULT_MODEL model_explicit=1
  add_wizard
  printf 'split=%s design=[%s]' "$split" "$design_vals"
}
out=$(run_wizard 1 1 0 "" <<<"$DES/shot.png" 2>"$PQ_HOME/.err")
eq "$out" "split=1 design=[$DES/shot.png"$'\n'"]" "a path typed at the question joins the design set"
has "$(cat "$PQ_HOME/.err")" "built from a design, but no design file was found" "the question says why it is asked"
out=$(run_wizard 1 1 0 "" <<<"" 2>"$PQ_HOME/.err")
eq "$out" "split=1 design=[]" "Enter goes without"
has "$(cat "$PQ_HOME/.err")" "build from the plan's prose alone" "and says so, loudly"
out=$(run_wizard 1 0 0 "" </dev/null 2>"$PQ_HOME/.err")
hasnt "$(cat "$PQ_HOME/.err")" "path to it" "a plan that is not design-built is not asked"
out=$(run_wizard 1 1 1 "" </dev/null 2>"$PQ_HOME/.err")
hasnt "$(cat "$PQ_HOME/.err")" "path to it" "--design given explicitly skips the question"
( run_wizard 1 1 0 "" <<<"/nonexistent/x.png" ) >/dev/null 2>"$PQ_HOME/.err" \
  && bad "a typed path that does not exist must die" || ok
has "$(cat "$PQ_HOME/.err")" "no such design file" "and say so"

echo "== add_wizard: a plan that lays out several pull requests is offered as one task each ==" >&2
THREE=$(printf 'Add the checklist step collection to Onboarding\nRebuild the Getting Started page around the new components\nAdd the Resources block and the sign-up link')
out=$(run_wizard 0 0 1 "$THREE" <<<"" 2>"$PQ_HOME/.err")
err=$(cat "$PQ_HOME/.err")
has "$err" "this plan lays out 3 pull requests:" "the outline is introduced with its count"
has "$err" "1. Add the checklist step collection to Onboarding" "title 1 is numbered first"
has "$err" "2. Rebuild the Getting Started page around the new components" "title 2 second"
has "$err" "3. Add the Resources block and the sign-up link" "title 3 third"
case "$err" in *"1. Add the checklist"*"2. Rebuild"*"3. Add the Resources"*) ok ;; *) bad "the titles must print in the plan's order" ;; esac
has "$err" "queue one task per pull request? [Y/n]" "the default is yes"
eq "$out" "split=1 design=[]" "so Enter splits"
out=$(run_wizard 0 0 1 "$THREE" <<<"n" 2>/dev/null)
eq "$out" "split=0 design=[]" "n still declines"

# Two is as much a plan's own say-so as three: there is no size threshold left.
TWO=$(printf 'First half\nSecond half')
out=$(run_wizard 0 0 1 "$TWO" <<<"" 2>"$PQ_HOME/.err")
err=$(cat "$PQ_HOME/.err")
has "$err" "this plan lays out 2 pull requests:" "a two-entry outline is shown"
has "$err" "[Y/n]" "and defaults to yes too"
eq "$out" "split=1 design=[]" "so Enter splits"
out=$(run_wizard 0 0 1 "$TWO" <<<"N" 2>/dev/null)
eq "$out" "split=0 design=[]" "N declines"

# A plan of one pull request - however big - has nothing to split along, so
# the question is not asked at all. The design question is left to read the
# next line, which is what a stray split question would have eaten.
out=$(run_wizard 0 1 0 "The one thing" <<<"$DES/shot.png" 2>"$PQ_HOME/.err")
err=$(cat "$PQ_HOME/.err")
hasnt "$err" "lays out" "a one-entry outline is not shown"
hasnt "$err" "pull request?" "and is not asked about"
eq "$out" "split=0 design=[$DES/shot.png"$'\n'"]" "so the next question reads the first line"
out=$(run_wizard 0 0 1 "" </dev/null 2>"$PQ_HOME/.err")
eq "$(cat "$PQ_HOME/.err")" "" "no outline at all asks nothing either"
eq "$out" "split=0 design=[]" "and splits nothing"

echo "== name_plan: the outline rides on line 2 onwards, and line 1 still reads alone ==" >&2
P3="$PQ_HOME/.three.md"; mkplan "$P3" three
named=$(name_plan "$P3")
eq "$(wc -l <<<"$named" | tr -d ' ')" "4" "branch/intent plus three titles is four lines"
IFS=$'\t' read -r b i <<<"$named"
eq "$b" "tom/three-parts" "IFS=tab read takes the branch off line 1"
eq "$i" "Three things, one plan." "...and the intent, with nothing from line 2 bleeding in"
eq "$(outline_of "$named" | sed -n 2p)" "Rebuild the Getting Started page around the new components" "outline_of returns the titles"
PP="$PQ_HOME/.plain.md"; mkplan "$PP" plain
named=$(name_plan "$PP")
eq "$(wc -l <<<"$named" | tr -d ' ')" "1" "a reply with no parts is still one line"
eq "$(outline_of "$named")" "" "and has no outline"

echo "== name_plan: the branch is always tom/<words>, whatever Haiku sent back ==" >&2
PB="$PQ_HOME/.bare.md"; mkplan "$PB" bare
IFS=$'\t' read -r b _ <<<"$(name_plan "$PB")"
eq "$b" "tom/fix-login-swallow" "a bare name gets the prefix"
# A slash inside the words keeps them all, as a dash: on a multi-repo split
# the repo in the name may be all that tells two parts apart.
PS="$PQ_HOME/.slashed.md"; mkplan "$PS" slashed
IFS=$'\t' read -r b _ <<<"$(name_plan "$PS")"
eq "$b" "tom/ios-tip-fee" "a slash without the prefix keeps every word"
PT="$PQ_HOME/.tomslashed.md"; mkplan "$PT" tomslashed
IFS=$'\t' read -r b _ <<<"$(name_plan "$PT")"
eq "$b" "tom/android-tip-fee" "and so does one under it"
IFS=$'\t' read -r b _ <<<"$(name_plan "$P3")"
eq "$b" "tom/three-parts" "a name that already has it is left alone"
PN="$PQ_HOME/.nobranch.md"; mkplan "$PN" nobranch
# `cut`, as cmd_add reads it: `read` would strip the empty field's leading tab.
named=$(name_plan "$PN")
eq "$(cut -f1 <<<"$named")" "" "a prefix with no words is no name at all"
eq "$(cut -f2 <<<"$named")" "No words." "and the intent still comes through"
reset_tasks
slug=$(cmd_add "$PB" "" "" --repo "$REPO" 2>"$PQ_HOME/.err")
t=$(find_task "$slug")
eq "$(hdr "$t/plan.md" branch)" "tom/fix-login-swallow" "the queued task carries the prefixed branch"
reset_tasks
( cmd_add "$PN" "" "" --repo "$REPO" ) >/dev/null 2>"$PQ_HOME/.err" && bad "a plan Haiku gave no words for must not queue" || ok
has "$(cat "$PQ_HOME/.err")" "could not name the plan" "and says so"

echo "== an unnamed add takes its name off line 1 of Haiku's reply, and never splits by itself ==" >&2
reset_tasks
slug=$(cmd_add "$P3" "" "" --repo "$REPO" 2>"$PQ_HOME/.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "an add of an outlined plan should succeed: $(cat "$PQ_HOME/.err")"
eq "$slug" "three-parts" "one task, named off line 1"
eq "$(queue_count)" "1" "never split without the wizard's say-so"
[ -d "$PQ_HOME/splits" ] && bad "no split directory may be created" || ok
t=$(find_task "$slug")
eq "$(hdr "$t/plan.md" branch)" "tom/three-parts" "the branch comes from line 1"
eq "$(hdr "$t/plan.md" intent)" "Three things, one plan." "the intent comes from line 1 - not a title"
P1="$PQ_HOME/.one.md"; mkplan "$P1" one

echo "== name_plan asks Haiku for the plan's own pull requests, not a division by size ==" >&2
name_plan "$P1" >/dev/null
hp=$(cat "$STUBBIN/.haiku-prompt")
has "$hp" "parts is a single entry unless the plan itself says this work ships as more than one pull request" "one entry unless the plan says otherwise"
has "$hp" "or changes code in more than one repository" "a repository each"
has "$hp" "Never divide a plan by its own sections, steps, stages, files or layers" "never by size"
hasnt "$hp" "naturally" "the old judged outline is gone"

echo "== pq ls --json carries the design set ==" >&2
reset_tasks
( cmd_add "$PLAN" tom/dj x --repo "$REPO" --design "$DES/shot.png" --design "$DC" ) >/dev/null 2>&1
( cmd_add "$PLAN" tom/dj0 x --repo "$REPO" ) >/dev/null 2>&1
out=$(main ls --json 2>/dev/null)
eq "$(jq -c '.[] | select(.task == "dj") | .design' <<<"$out")" '["shot.png","Onboarding Refresh.dc.html"]' "the design basenames, in order"
eq "$(jq -c '.[] | select(.task == "dj0") | .design' <<<"$out")" '[]' "and an empty array when there is none"

echo "== split_resume_hint carries --design, quoted for a shell ==" >&2
run_hint() {
  local repo=$REPO model=$PQ_DEFAULT_MODEL effort=$PQ_DEFAULT_EFFORT urgent=0 after_vals="" design_files
  design_files="$DC"$'\n'"$DES/shot.png"$'\n'
  split_resume_hint /tmp/sd
}
hint=$(run_hint)
has "$hint" "--design $(printf '%q' "$DC")" "the spaced path is %q-quoted"
has "$hint" "--design $DES/shot.png" "the plain path is carried as is"

echo "== split: a design follows the parts that name it ==" >&2
reset_tasks
PS="$PQ_HOME/.split-plan.md"
mkplan "$PS" split "Design file: $DC"
out=$(cmd_add "$PS" "" "" --repo "$REPO" --split <<<y 2>"$PQ_HOME/.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "a split with a design should succeed: $(cat "$PQ_HOME/.err")"
eq "$(queue_count)" "2" "two parts queued"
ta=$(find_task part-a); tb=$(find_task part-b)
eq "$(hdr "$ta/plan.md" design)" "Onboarding Refresh.dc.html" "the part that names the file carries it"
[ -f "$ta/design/Onboarding Refresh.dc.html" ] && ok || bad "...as a copy in its own design/"
eq "$(hdr "$tb/plan.md" design)" "" "the part that does not name it does not"
hasnt "$(cat "$PQ_HOME/.err")" "attaching it to every part" "no attach-to-all warning when a part cites it"
# The splitter was told to cite.
SD=$(ls -d "$PQ_HOME/splits"/*/ | head -1); SD=${SD%/}
[ -d "$SD" ] && ok || bad "a split directory should exist"

echo "== split: a design no part names goes to every part, with a warning ==" >&2
reset_tasks
out=$(cmd_add "$PS" "" "" --repo "$REPO" --split --design "$DES/shot.png" <<<y 2>"$PQ_HOME/.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "a split with an uncited design should still succeed: $(cat "$PQ_HOME/.err")"
has "$(cat "$PQ_HOME/.err")" "no part names the design file shot.png - attaching it to every part" "the miss is warned about by name"
ta=$(find_task part-a); tb=$(find_task part-b)
eq "$(hdr "$ta/plan.md" design)" "shot.png, Onboarding Refresh.dc.html" "part a: the uncited file (given first, on the command line) plus its own citation"
eq "$(hdr "$tb/plan.md" design)" "shot.png" "part b: only the uncited file"
[ -f "$tb/design/shot.png" ] && ok || bad "...copied into its design/"

echo "== splitter_prompt names the design files when there are any ==" >&2
run_prompt() { local design_hdr=$1; splitter_prompt "$(printf 'repo\t%s' "$REPO")"; }
has "$(run_prompt "Onboarding Refresh.dc.html")" "built from these design files: Onboarding Refresh.dc.html" "the splitter is told which files exist"
has "$(run_prompt "Onboarding Refresh.dc.html")" "by its exact filename" "and to cite them by name"
hasnt "$(run_prompt "")" "design files" "and nothing is said when there are none"

echo "== split_name_parts still reads a name from a multi-line namer reply ==" >&2
# The part markers reply with a `parts` array too; naming a split must take
# the branch off line 1 and ignore the rest.
reset_tasks
SD2="$PQ_HOME/splits/hand"; mkdir -p "$SD2"
printf '# source\n\nMARKER: split\n' > "$SD2/source.md"
printf '%s\t%s\n' "$(basename "$REPO")" "$REPO" > "$SD2/repos"
printf 'MARKER: part-a\nA.\n' > "$SD2/01-a.md"
printf '01-a.md\t\n' > "$SD2/graph.tsv"
out=$(main add --split-dir "$SD2" --repo "$REPO" <<<y 2>"$PQ_HOME/.err")
eq "$out" "part-a" "the part is named off line 1 of a multi-line reply"
t=$(find_task part-a)
eq "$(hdr "$t/plan.md" intent)" "Part A." "and its intent is line 1's, not a title"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
