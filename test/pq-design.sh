#!/usr/bin/env bash
# test/pq-design.sh - designs travel with the task, and Haiku's outline suggests
# a split: `--design`, auto-detection from the plan's text, the `design:` header
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
# `haiku` reads the plan on stdin and answers off its marker line. Three
# shapes of reply: a full outline (three parts), a one-entry outline, and the
# pre-outline shape with no `parts` at all, which every existing caller still
# has to read. `opus` writes a two-part split whose first part names the
# design file and whose second does not.
cat > "$STUBBIN/claude" <<'STUBEOF'
#!/usr/bin/env bash
model=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) model=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$model" in
  haiku)
    content=$(cat)
    case "$content" in
      *"MARKER: three"*)
        printf '{"branch":"tom/three-parts","intent":"Three things, one plan.","parts":["Add the checklist step collection to Onboarding","Rebuild the Getting Started page around the new components","Add the Resources block and the sign-up link"]}\n' ;;
      *"MARKER: two"*)
        printf '{"branch":"tom/two-parts","intent":"Two things.","parts":["First half","Second half"]}\n' ;;
      *"MARKER: one"*)
        printf '{"branch":"tom/one-part","intent":"One thing.","parts":["The one thing"]}\n' ;;
      *"MARKER: plain"*)
        printf '{"branch":"tom/plain-plan","intent":"No outline at all."}\n' ;;
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
slug=$(main add "$PLAN" --repo "$REPO" --branch tom/d1 --intent x --design "$DC" --design "$DES/shot.png" -y 2>"$PQ_HOME/.err")
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
slug=$(main add "$PLAN" --repo "$REPO" --branch tom/d0 --intent x -y 2>/dev/null)
t=$(find_task "$slug")
grep -q '^design:' "$t/plan.md" && bad "no design set must mean no header, not an empty one" || ok
[ -d "$t/design" ] && bad "no design set must mean no design/ directory" || ok

echo "== a missing --design path dies before anything is queued ==" >&2
before=$(queue_count)
( main add "$PLAN" --repo "$REPO" --branch tom/d2 --intent x --design /nonexistent/nope.png -y ) >/dev/null 2>"$PQ_HOME/.err" \
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
slug=$(HOME=$FAKEHOME main add "$PLAN2" --repo "$REPO" --branch tom/d3 --intent x -y 2>"$PQ_HOME/.err")
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
slug=$(main add "$PLAN3" --repo "$REPO" --branch tom/d4 --intent x -y 2>"$PQ_HOME/.err")
t=$(find_task "$slug")
eq "$(hdr "$t/plan.md" design)" "" "a claude.ai url is not a design path"
hasnt "$(cat "$PQ_HOME/.err")" "not on disk" "and is not warned about as a dangling one either"
# ...but a plan that only cites a design by url IS a design plan with no file.
has "$(cat "$PQ_HOME/.err")" "no design file was found on disk or given" "a design cited with no file on disk warns under -y"

echo "== auto-detection: a dangling path warns by name and does not block the add ==" >&2
PLAN4="$PQ_HOME/.p4.md"
mkplan "$PLAN4" plain "Design file: /nonexistent/Missing Board.dc.html"
slug=$(main add "$PLAN4" --repo "$REPO" --branch tom/d5 --intent x -y 2>"$PQ_HOME/.err")
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

echo "== add_wizard: the outline is shown, in order, and flips the default at the threshold ==" >&2
THREE=$(printf 'Add the checklist step collection to Onboarding\nRebuild the Getting Started page around the new components\nAdd the Resources block and the sign-up link')
out=$(run_wizard 0 0 1 "$THREE" <<<"" 2>"$PQ_HOME/.err")
err=$(cat "$PQ_HOME/.err")
has "$err" "Haiku reads this plan as 3 separately reviewable pull requests:" "the outline is introduced with its count"
has "$err" "1. Add the checklist step collection to Onboarding" "title 1 is numbered first"
has "$err" "2. Rebuild the Getting Started page around the new components" "title 2 second"
has "$err" "3. Add the Resources block and the sign-up link" "title 3 third"
case "$err" in *"1. Add the checklist"*"2. Rebuild"*"3. Add the Resources"*) ok ;; *) bad "the titles must print in build order" ;; esac
has "$err" "[Y/n]" "at the threshold (3) the default is yes"
eq "$out" "split=1 design=[]" "so Enter splits"
out=$(run_wizard 0 0 1 "$THREE" <<<"n" 2>/dev/null)
eq "$out" "split=0 design=[]" "n still declines"

TWO=$(printf 'First half\nSecond half')
out=$(run_wizard 0 0 1 "$TWO" <<<"" 2>"$PQ_HOME/.err")
err=$(cat "$PQ_HOME/.err")
has "$err" "Haiku reads this plan as 2 separately reviewable pull requests:" "a two-entry outline is still shown"
has "$err" "[y/N]" "below the threshold the default is no"
eq "$out" "split=0 design=[]" "so Enter does not split"
out=$(run_wizard 0 0 1 "$TWO" <<<"y" 2>/dev/null)
eq "$out" "split=1 design=[]" "y still splits"
out=$(PQ_SPLIT_SUGGEST=2 run_wizard 0 0 1 "$TWO" <<<"" 2>"$PQ_HOME/.err")
has "$(cat "$PQ_HOME/.err")" "[Y/n]" "PQ_SPLIT_SUGGEST moves the threshold"
eq "$out" "split=1 design=[]" "...and Enter follows it"

out=$(run_wizard 0 0 1 "The one thing" <<<"" 2>"$PQ_HOME/.err")
err=$(cat "$PQ_HOME/.err")
hasnt "$err" "Haiku reads" "a one-entry outline is not shown"
has "$err" "split into a stack of parts? [y/N]" "the plain question is asked as it always was"
eq "$out" "split=0 design=[]" "and Enter means no"
out=$(run_wizard 0 0 1 "" <<<"" 2>"$PQ_HOME/.err")
hasnt "$(cat "$PQ_HOME/.err")" "Haiku reads" "no outline at all is the plain question too"

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

echo "== -y prints the outline as a warning, says consider --split, and never splits ==" >&2
reset_tasks
slug=$(main add "$P3" --repo "$REPO" -y 2>"$PQ_HOME/.err")
rc=$?
[ "$rc" -eq 0 ] && ok || bad "a -y add of an outlined plan should succeed: $(cat "$PQ_HOME/.err")"
err=$(cat "$PQ_HOME/.err")
has "$err" "Haiku reads this plan as 3 separately reviewable pull requests:" "the outline is printed"
has "$err" "2. Rebuild the Getting Started page" "with its titles"
has "$err" "consider --split" "and the suggestion"
eq "$slug" "three-parts" "one task, named off line 1"
eq "$(queue_count)" "1" "never auto-split"
[ -d "$PQ_HOME/splits" ] && bad "no split directory may be created by a suggestion" || ok
t=$(find_task "$slug")
eq "$(hdr "$t/plan.md" branch)" "tom/three-parts" "the branch comes from line 1"
eq "$(hdr "$t/plan.md" intent)" "Three things, one plan." "the intent comes from line 1 - not a title"

echo "== a one-entry outline is not worth a warning ==" >&2
reset_tasks
P1="$PQ_HOME/.one.md"; mkplan "$P1" one
main add "$P1" --repo "$REPO" -y >/dev/null 2>"$PQ_HOME/.err"
hasnt "$(cat "$PQ_HOME/.err")" "Haiku reads" "one pull request is what every plan should be"
hasnt "$(cat "$PQ_HOME/.err")" "consider --split" "so nothing is suggested"

echo "== --json carries the design set ==" >&2
reset_tasks
out=$(main add "$PLAN" --repo "$REPO" --branch tom/dj --intent x --design "$DES/shot.png" --design "$DC" -y --json 2>/dev/null)
eq "$(jq -c '.design' <<<"$out")" '["shot.png","Onboarding Refresh.dc.html"]' "--json lists the design basenames"
out=$(main add "$PLAN" --repo "$REPO" --branch tom/dj0 --intent x -y --json 2>/dev/null)
eq "$(jq -c '.design' <<<"$out")" '[]' "and an empty array when there is none"
out=$(main ls --json 2>/dev/null)
eq "$(jq -r '.[] | select(.task == "dj") | .design | length' <<<"$out")" "2" "pq ls --json carries it too"

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
out=$(main add "$PS" --repo "$REPO" --split -y 2>"$PQ_HOME/.err")
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
out=$(main add "$PS" --repo "$REPO" --split --design "$DES/shot.png" -y 2>"$PQ_HOME/.err")
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
out=$(main add --split-dir "$SD2" --repo "$REPO" -y 2>"$PQ_HOME/.err")
eq "$out" "part-a" "the part is named off line 1 of a multi-line reply"
t=$(find_task part-a)
eq "$(hdr "$t/plan.md" intent)" "Part A." "and its intent is line 1's, not a title"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
