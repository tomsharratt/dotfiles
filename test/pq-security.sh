#!/usr/bin/env bash
# test/pq-security.sh - the security reviewer: a plan that asks for a security
# review gets an independent `/security-review` beside the gate's `/code-review`,
# run by pq in the background, its report posted on the pull request, and one
# follow-up to the implementer about both.
#
# Same shape as test/pq-review.sh - a pinned clock, `set_panes` steering herdr's
# snapshot, a `claude` stub that records how it was called - but the stub tells
# its callers apart by the prompt: the namer (haiku) answers off a marker line in
# the plan, the splitter writes parts, and each reviewer behaves per a mode file
# of its own, so "the code review passed and the security review failed" is one
# test rather than a race. `hold` keeps a reviewer running until the test
# releases it, which is how the two are made to finish in a chosen order.
#
# SC2034: the knobs and caches set here are read by the pq sourced below.
# SC2015: `ok` never fails, so `[ ... ] && ok || bad` is an if/else.
# shellcheck disable=SC2034,SC2015
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PQ_HOME=$(mktemp -d)
export PQ_HOME
PQ_PLANS_DIR=$(mktemp -d)
export PQ_PLANS_DIR
# An empty scan root, so a --split here stays single-repo.
PQ_REPOS_DIR=$(mktemp -d)
export PQ_REPOS_DIR

STUBBIN=$(mktemp -d)
PANES_JSON="$STUBBIN/.panes.json"
HERDR_LOG="$STUBBIN/.herdr-calls"
CLAUDE_LOG="$STUBBIN/.claude-calls"
CLAUDE_ENV="$STUBBIN/.claude-env"
GH_LOG="$STUBBIN/.gh-calls"
MODE="$STUBBIN/.mode"                   # the code reviewer's behaviour
SMODE="$STUBBIN/.smode"                 # the security reviewer's
PRJSON="$STUBBIN/.pr.json"
COMMENTS="$STUBBIN/.comments"
REPORT="$STUBBIN/.report"
printf '{"result":{"snapshot":{"panes":[]}}}' > "$PANES_JSON"
: > "$HERDR_LOG"; : > "$CLAUDE_LOG"; : > "$CLAUDE_ENV"; : > "$GH_LOG"
printf 'ok' > "$MODE"; printf 'ok' > "$SMODE"; printf '0' > "$COMMENTS"
# shellcheck disable=SC2016  # the backticks are markdown in the report, not a substitution
printf '# Security review: PR #42\n\n# Vuln 1: SQL injection: `app/notes.rb:12`\n\n* Severity: High\n* Recommendation: bind the term.\n' > "$REPORT"

cat > "$STUBBIN/claude" <<EOF
#!/bin/sh
{ printf '%s\t' "\$PWD"; for a in "\$@"; do printf '%s\t' "\$a"; done; printf '\n'; } >> "$CLAUDE_LOG"
model="" prev="" last=""
for a in "\$@"; do [ "\$prev" = --model ] && model=\$a; prev=\$a; last=\$a; done
if [ "\$model" = haiku ]; then
  content=\$(cat)
  case "\$content" in
    *"MARKER: secure"*)     printf '{"branch":"tom/secure-it","intent":"Lock it down.","security":true,"parts":["Lock it down"]}\n' ;;
    *"MARKER: guessed"*)    printf '{"branch":"tom/guessed-it","intent":"Guessed.","security":true,"parts":["Guessed"]}\n' ;;
    *"MARKER: waived"*)     printf '{"branch":"tom/waived-it","intent":"Waived.","security":false,"parts":["Waived"]}\n' ;;
    *"MARKER: nointent"*)   printf '{"branch":"tom/no-intent","intent":"","security":true,"parts":["No intent"]}\n' ;;
    *"MARKER: splitsec"*)   printf '{"branch":"tom/split-source","intent":"Two parts.","security":true,"parts":["API","UI"]}\n' ;;
    *"MARKER: part-sec"*)   printf '{"branch":"tom/part-api","intent":"The API.","security":true,"parts":["API"]}\n' ;;
    *"MARKER: part-plain"*) printf '{"branch":"tom/part-ui","intent":"The UI.","security":false,"parts":["UI"]}\n' ;;
    *) printf '{}\n' ;;
  esac
  exit 0
fi
printf 'pane=%s tab=%s workspace=%s\n' "\${HERDR_PANE_ID-unset}" "\${HERDR_TAB_ID-unset}" "\${HERDR_WORKSPACE_ID-unset}" >> "$CLAUDE_ENV"
case "\$last" in
  /security-review) kind=security; m=\$(cat "$SMODE") ;;
  /code-review*)    kind=code;     m=\$(cat "$MODE") ;;
  "Read ./source.md"*)
    printf '%s' "\$last" > "$STUBBIN/.splitter-prompt"
    printf 'MARKER: part-sec\nThe API. Run \`/security-review\` as well: it must stay tenant-scoped.\n' > 01-api.md
    printf 'MARKER: part-plain\nThe UI, nothing security-relevant.\n' > 02-ui.md
    printf '01-api.md\t\n02-ui.md\t01-api.md\n' > graph.tsv
    printf '{"is_error":false,"total_cost_usd":0.1,"duration_ms":1000,"permission_denials":[]}\n'
    exit 0 ;;
  *) exit 1 ;;
esac
if [ "\$m" = hold ]; then
  i=0
  while [ ! -f "$STUBBIN/.release-\$kind" ] && [ \$i -lt 300 ]; do sleep 0.1; i=\$((i + 1)); done
  m=ok
fi
case "\$m" in
  sleep) sleep 30; exit 0 ;;
  fail)  printf '{"is_error":true}\n'; exit 1 ;;
esac
if [ "\$kind" = code ]; then
  printf '{"is_error":false,"total_cost_usd":1.2,"duration_ms":5000,"permission_denials":[]}\n'; exit 0
fi
case "\$m" in
  ok)        jq -nc --rawfile r "$REPORT" '{is_error:false,total_cost_usd:0.9,duration_ms:90000,permission_denials:[],result:\$r}' ;;
  empty)     printf '{"is_error":false,"result":"  "}\n' ;;
  otherdeny) jq -nc --rawfile r "$REPORT" '{is_error:false,permission_denials:[{tool_name:"Bash",tool_input:{command:"gh pr view 42"}}],result:\$r}' ;;
esac
exit 0
EOF
cat > "$STUBBIN/gh" <<EOF
#!/bin/sh
case "\$*" in
  *"pr comment"*)
    [ -f "$STUBBIN/.comment-fail" ] && exit 1
    printf '%s\n' "\$*" >> "$GH_LOG"
    f="" prev=""
    for a in "\$@"; do [ "\$prev" = --body-file ] && f=\$a; prev=\$a; done
    cat "\$f" > "$STUBBIN/.comment-body"; exit 0 ;;
  *"pr view"*)   [ -f "$PRJSON" ] && cat "$PRJSON" && exit 0; exit 1 ;;
  *"/comments"*) cat "$COMMENTS"; exit 0 ;;
esac
exit 1
EOF
cat > "$STUBBIN/herdr" <<EOF
#!/bin/sh
{ for a in "\$@"; do printf '%s\t' "\$a"; done; printf '\n'; } >> "$HERDR_LOG"
case "\$1 \$2" in
  "api snapshot") cat "$PANES_JSON"; exit 0 ;;
  "agent prompt") printf '{"id":"cli:agent:prompt","result":{"submitted":true}}\n'; exit 0 ;;
esac
exit 1
EOF
printf '#!/bin/sh\nexit 0\n' > "$STUBBIN/wt-stub"
chmod +x "$STUBBIN/claude" "$STUBBIN/gh" "$STUBBIN/herdr" "$STUBBIN/wt-stub"
export PATH="$STUBBIN:$PATH"
export PQ_WT="$STUBBIN/wt-stub"

# shellcheck source=/dev/null
source "$HERE/../.local/bin/pq"

pr_load_all() { :; }

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }
eq() { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }
has() { case "$1" in *"$2"*) ok ;; *) bad "$3 (got '$1')" ;; esac; }
hasnt() { case "$1" in *"$2"*) bad "$3 (got '$1')" ;; *) ok ;; esac; }

# A reviewer still running - sleeping, or held - must not outlive this file.
cleanup() {
  local d
  touch "$STUBBIN/.release-code" "$STUBBIN/.release-security" 2>/dev/null
  for d in "$PQ_HOME"/done/*/; do [ -d "$d" ] && review_kill "${d%/}"; done
  rm -rf "$PQ_HOME" "$PQ_PLANS_DIR" "$PQ_REPOS_DIR" "$STUBBIN" "${REPO:-}" "${WT:-}"
}
trap cleanup EXIT

REPO=$(mktemp -d)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$REPO/.git/refs/remotes/origin"
git -C "$REPO" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
WT=$(mktemp -d)                         # the task's worktree, where both reviewers must run

unset HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID
PQ_DONE_KEEP=99
PQ_WRAPUP_GRACE=300
PQ_REVIEW_TIMEOUT=1500
PQ_REVIEW_MAX_TRIES=2
PQ_REVIEW_RETRY=600
PQ_REVIEW_SPLIT_LINES=150
PQ_REVIEW_EFFORT=high                   # not the default, so the argv assertions prove it is passed through

FAKE_NOW=$(date -u '+%s')
epoch() { printf '%s' "$FAKE_NOW"; }
now()   { date -u -r "$FAKE_NOW" '+%Y-%m-%dT%H:%M:%SZ'; }
ago()   { date -u -r "$(( FAKE_NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }

reset_caches() { PR_CACHE="$PQ_HOME/.test.pr"; PR_ANS="$PQ_HOME/.test.ans"; : > "$PR_CACHE"; : > "$PR_ANS"; }
cache_row() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$PR_CACHE"; }   # repo branch num state draft base
reset_tasks() {
  local d
  touch "$STUBBIN/.release-code" "$STUBBIN/.release-security"
  for d in "$PQ_HOME"/done/*/ "$PQ_HOME"/running/*/; do [ -d "$d" ] && review_kill "${d%/}"; done
  rm -f "$STUBBIN/.release-code" "$STUBBIN/.release-security"
  rm -rf "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done" "$PQ_HOME/archive" "$PQ_HOME/splits"
  mkdir -p "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done" "$PQ_HOME/archive"
}
reset_tasks
reset_logs() {
  : > "$HERDR_LOG"; : > "$CLAUDE_LOG"; : > "$CLAUDE_ENV"; : > "$GH_LOG"
  rm -f "$STUBBIN/.comment-fail" "$STUBBIN/.comment-body"
}
mode()  { printf '%s' "$1" > "$MODE"; }
smode() { printf '%s' "$1" > "$SMODE"; }
release() { touch "$STUBBIN/.release-$1"; }
pr_json() {                             # title state draft commits additions deletions
  jq -nc --arg t "$1" --arg s "$2" --argjson d "$3" --argjson c "$4" --argjson a "$5" --argjson r "$6" \
    '{title:$t, state:$s, isDraft:$d, commits:[range($c)|{oid:"x"}], additions:$a, deletions:$r}' > "$PRJSON"
}
pr_json "Do the thing" OPEN true 3 100 20

TICKOUT="$PQ_HOME/.tick.out"
tick() {                                # cap dry -> stdout+stderr in $OUT
  PQ_SUMMARY=""
  tick_body "$1" "$2" > "$TICKOUT" 2>&1
  OUT=$(cat "$TICKOUT")
}

mk_task() {                             # state prio slug branch pane security -> task_dir
  local state=$1 prio=$2 slug=$3 branch=$4 pane=$5 sec=${6:-}
  local dir
  dir="$PQ_HOME/$state/$(printf '%014d' $(( 20260101000000 + 10#$prio )))-$slug"
  mkdir -p "$dir"
  {
    printf -- '---\n'
    printf 'repo:     %s\n' "$REPO"
    printf 'branch:   %s\n' "$branch"
    [ "$sec" = yes ] && printf 'security: yes\n'
    printf 'model:    sonnet\n'
    printf 'effort:   xhigh\n'
    printf 'intent:   test fixture\n'
    printf 'added:    2026-01-01T00:00:00Z\n'
    printf -- '---\n\nplan body\n'
  } > "$dir/plan.md"
  [ -n "$pane" ] && st_set "$dir" PQ_PANE "$pane"
  st_set "$dir" PQ_WORKTREE "$WT"
  task_link "$dir"
  printf '%s' "$dir"
}
# A done task with an open draft PR #42 whose plan asked for a security review,
# both ladders pending - what reconcile leaves behind.
mk_gated() {                            # prio slug pane -> task_dir
  local d; d=$(mk_task "done" "$1" "$2" "tom/$2" "$3" yes)
  st_set "$d" PQ_LAUNCHED "$(now)"; st_set "$d" PQ_PR 42; st_set "$d" PQ_FINISHED "$(now)"
  st_set "$d" PQ_REVIEW pending; st_set "$d" PQ_SECURITY pending
  cache_row "$REPO" "tom/$2" 42 OPEN draft master
  printf '%s' "$d"
}
set_panes() {                           # "pane<TAB>agent<TAB>status" lines
  PIDX=$1; PIDX_OK=1
  if [ -z "$1" ]; then printf '{"result":{"snapshot":{"panes":[]}}}' > "$PANES_JSON"; return; fi
  jq -Rs 'split("\n") | map(select(length > 0) | split("\t")
            | { pane_id: .[0],
                agent:        (if (.[1] // "") == "" then null else .[1] end),
                agent_status: (if (.[2] // "") == "" then null else .[2] end) })
          | { result: { snapshot: { panes: . } } }' <<<"$1" > "$PANES_JSON"
}
sec_calls()  { grep -c $'\t/security-review\t$' "$CLAUDE_LOG" 2>/dev/null || true; }
code_calls() { grep -c $'\t/code-review ' "$CLAUDE_LOG" 2>/dev/null || true; }
wait_for() {                            # command... -> polls up to 5s
  local i; for i in $(seq 1 50); do "$@" && return 0; sleep 0.1; done
  return 1
}
calls_at_least() { [ "$("$1")" -ge "$2" ]; }
prompt_text() { grep "^agent	prompt	" "$HERDR_LOG" | tail -1 | cut -f4; }
prompts()     { grep -c "^agent	prompt	" "$HERDR_LOG" 2>/dev/null || true; }

echo "== name_plan: a yes only for a plan that asks, and never for one that only might ==" >&2
mkplan() {                              # file marker [lines...]
  local f=$1 m=$2; shift 2
  { printf '# A plan\n\nMARKER: %s\n\n' "$m"; for l in "$@"; do printf '%s\n' "$l"; done; } > "$f"
}
PSEC="$PQ_PLANS_DIR/secure.md"; mkplan "$PSEC" secure "Run \`/security-review\` as well as \`/code-review\`."
PGUESS="$PQ_PLANS_DIR/guessed.md"; mkplan "$PGUESS" guessed "Nothing about reviews at all."
PWAIVE="$PQ_PLANS_DIR/waived.md"; mkplan "$PWAIVE" waived "\`/security-review\` is not warranted - this is presentational."
PNOINT="$PQ_PLANS_DIR/nointent.md"; mkplan "$PNOINT" nointent "A security review is warranted."
eq "$(head -1 <<<"$(name_plan "$PSEC")" | cut -f3)" "yes" "a plan that asks, read as asking, is a yes"
eq "$(head -1 <<<"$(name_plan "$PGUESS")" | cut -f3)" "" "a yes for a plan that never mentions one is Haiku guessing - dropped"
eq "$(head -1 <<<"$(name_plan "$PWAIVE")" | cut -f3)" "" "a plan that waives it is a no"
IFS=$'\t' read -r _ i <<<"$(name_plan "$PWAIVE")"
eq "$i" "Waived." "an IFS=tab read of branch and intent still gets a clean intent"
eq "$(outline_of "$(name_plan "$PSEC")")" "Lock it down" "and the outline still rides below line 1"
grep -q 'security is true only when the plan asks for a security review' "$CLAUDE_LOG" \
  && ok || bad "the namer is told what a yes means"

echo "== cmd_add: the verdict becomes the header, and a stale caller fails loudly ==" >&2
reset_tasks
slug=$(cmd_add "$PSEC" "" "" "" --repo "$REPO" 2>"$PQ_HOME/.err")
t=$(find_task "$slug")
eq "$(hdr "$t/plan.md" security)" "yes" "a plan that asks carries security: yes"
has "$(cat "$PQ_HOME/.err")" "review: code and security - the plan asks for a /security-review" "and the add says so"
slug=$(cmd_add "$PWAIVE" "" "" "" --repo "$REPO" 2>"$PQ_HOME/.err")
t=$(find_task "$slug")
grep -q '^security:' "$t/plan.md" && bad "a waived review writes no header at all" || ok
hasnt "$(cat "$PQ_HOME/.err")" "review: code and security" "and the add says nothing about it"
# The verdict is the third field of line 1: an empty intent before it must not
# let it slide into the intent's place, as a tab-split `read` would.
slug=$(cmd_add "$PNOINT" "" "" "" --repo "$REPO" 2>"$PQ_HOME/.err")
t=$(find_task "$slug")
eq "$(hdr "$t/plan.md" security)" "yes" "an empty intent does not swallow the verdict"
eq "$(hdr "$t/plan.md" intent)" "" "nor does the verdict become the intent"
( cmd_add "$PSEC" tom/stale x --repo "$REPO" ) >/dev/null 2>"$PQ_HOME/.err" && bad "a three-positional caller must fail" || ok
has "$(cat "$PQ_HOME/.err")" "security verdict is yes or empty, not '--repo'" "and name what it got"
( cmd_add "$PSEC" tom/named x yes --repo "$REPO" ) >/dev/null 2>&1
t=$(find_task named)
eq "$(hdr "$t/plan.md" security)" "yes" "a caller that names the task hands its verdict in too"

echo "== a split: each part gets its own verdict, and the splitter is told to carry the ask ==" >&2
reset_tasks
PSPLIT="$PQ_PLANS_DIR/splitsec.md"; mkplan "$PSPLIT" splitsec "PR 1: the API. PR 2: the UI." "Run \`/security-review\` on the API."
out=$(cmd_add "$PSPLIT" "" "" "" --repo "$REPO" --split <<<y 2>"$PQ_HOME/.err")
eq "$(grep -c . <<<"$out")" "2" "two parts queued: $(tail -3 "$PQ_HOME/.err")"
ta=$(find_task part-api); tu=$(find_task part-ui)
eq "$(hdr "$ta/plan.md" security)" "yes" "the part that asks carries the header"
eq "$(hdr "$tu/plan.md" security)" "" "the part that does not, does not"
has "$(cat "$STUBBIN/.splitter-prompt" 2>/dev/null)" "ask for one in every part whose changes that review is about" "the splitter is told to carry it"
named=""
for f in "$PQ_HOME"/splits/*/.named.tsv; do [ -f "$f" ] && named=$f && break; done
eq "$(awk -F'\t' '$1 == "01-api.md" { print $5 }' "$named")" "yes" ".named.tsv carries the verdict in its fifth column"

echo "== the contract names the security reviewer only when the plan asked ==" >&2
reset_tasks
C=$(mk_task running 001 contracted tom/contracted w1:p1 yes)
contract_write "$C"
has "$(cat "$C/contract.md")" "The plan asks for a security review, and pq runs that too" "a task that asked is told pq runs it"
has "$(cat "$C/contract.md")" "Do not run one yourself." "and not to run it itself"
C2=$(mk_task running 002 plain tom/plain w1:p2)
contract_write "$C2"
hasnt "$(cat "$C2/contract.md")" "security" "a task that did not ask hears nothing about it"

echo "== reconcile opens the security ladder beside the gate, for a plan that asked ==" >&2
reset_tasks; reset_caches; reset_logs
R=$(mk_task running 003 asked tom/asked w1:p1 yes)
st_set "$R" PQ_LAUNCHED "$(now)"
R2=$(mk_task running 004 unasked tom/unasked w1:p2)
st_set "$R2" PQ_LAUNCHED "$(now)"
cache_row "$REPO" tom/asked 42 OPEN draft master
cache_row "$REPO" tom/unasked 43 OPEN draft master
set_panes "$(printf 'w1:p1\tclaude\tworking\nw1:p2\tclaude\tworking')"
tick 3 0
D=$(ls -d "$PQ_HOME"/done/*-asked); D=${D%/}
D2=$(ls -d "$PQ_HOME"/done/*-unasked); D2=${D2%/}
eq "$(st "$D" PQ_REVIEW)" "pending" "the gate opens"
eq "$(st "$D" PQ_SECURITY)" "pending" "and the security ladder with it"
eq "$(st "$D2" PQ_SECURITY)" "" "a plan that did not ask gets no ladder at all"

echo "== the security reviewer waits for the gate's own probe ==" >&2
reset_tasks; reset_caches; reset_logs; mode sleep; smode sleep
G=$(mk_gated 010 waits w1:p1)
set_panes "$(printf 'w1:p1\tclaude\tworking')"
review_task "$G" 0
eq "$(st "$G" PQ_SECURITY)" "pending" "a working agent holds both back"
rm -f "$PRJSON"
set_panes "$(printf 'w1:p1\tclaude\tidle')"
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_REVIEW)" "pending" "a probe that failed leaves the gate pending"
eq "$(st "$G" PQ_SECURITY)" "pending" "and the security reviewer with it - nothing is known about the PR"
sleep 0.3
eq "$(sec_calls)" "0" "no security reviewer went out blind"
pr_json "Do the thing" OPEN true 3 100 20

echo "== launch: both reviewers go out on one tick, the security one with its own command ==" >&2
reset_tasks; reset_caches; reset_logs; mode sleep; smode sleep
G=$(mk_gated 011 launched w1:p1)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
T0=$(date +%s)
launch_out=$(export HERDR_PANE_ID=w9:p9 HERDR_TAB_ID=w9:t9 HERDR_WORKSPACE_ID=w9; review_task "$G" 0 2>&1)
T1=$(date +%s)
[ $(( T1 - T0 )) -lt 5 ] && ok || bad "review_task must wait for neither reviewer (took $(( T1 - T0 ))s)"
eq "$(st "$G" PQ_REVIEW)" "running" "the code reviewer is running"
eq "$(st "$G" PQ_SECURITY)" "running" "and so is the security reviewer, on the same tick"
has "$launch_out" "reviewing #42 with opus in the background" "the code launch is said"
has "$launch_out" "security-reviewing #42 with opus in the background" "and the security one"
eq "$(st "$G" PQ_SECURITY_TRIES)" "1" "one security try"
wait_for calls_at_least sec_calls 1
line=$(grep $'\t/security-review\t$' "$CLAUDE_LOG" | head -1)
home="$PQ_HOME/tasks/$(basename "$G")"
eq "$(cut -f1 <<<"$line")" "$WT" "it runs in the task's worktree"
grep -q "pane=unset tab=unset workspace=unset" "$CLAUDE_ENV" && [ "$(grep -c "pane=w9" "$CLAUDE_ENV")" = 0 ] \
  && ok || bad "neither reviewer inherits the launching pane's identity: $(cat "$CLAUDE_ENV")"
has "$line" "	-p	" "in print mode"
has "$line" "	--model	opus	" "with the reviewer model"
has "$line" "	--effort	high	" "at the review effort"
has "$line" "	--permission-mode	auto	" "in auto mode"
hasnt "$line" "--allowedTools" "with nothing allowed by rule - it posts nothing"
has "$line" "	--disallowedTools	Edit(/$HOME/**)	Bash(gh:*)	Bash(git checkout:*)	Bash(git switch:*)	Bash(git restore:*)	Bash(git reset:*)	Bash(git stash:*)	Bash(git clean:*)	Bash(git commit:*)	Bash(git push:*)	--append-system-prompt	" \
  "read-only under home, no gh at all, and none of the git verbs that write over the implementer's work"
has "$line" "	--append-system-prompt	You are running a security review of pull request #42 " "briefed on this pull request"
has "$line" "\`git diff origin/master...HEAD\`" "told the diff it is reviewing, off the task's base"
has "$line" "$home/plan.md" "pointed at the plan, through the stable path"
has "$line" "no pushes, and no gh" "and told pq does the posting"
has "$line" "through \`wt test <cmd>\`" "and to run specs through wt test"
case "$(security_brief 42 "$home" master)" in *"'"*|*$'\n'*) bad "the brief must be one line and quote-free" ;; *) ok ;; esac
has "$line" "	--add-dir	$home	" "with the task's own directory opened to it"
has "$line" "	--output-format	json	/security-review	" "JSON out, and the skill as the prompt, last"
PID=$(st "$G" PQ_SECURITY_PID)
[ -n "$PID" ] && review_alive "$PID" && ok || bad "the security reviewer's process group is recorded and alive"
[ "$PID" != "$(st "$G" PQ_REVIEW_PID)" ] && ok || bad "and it is not the code reviewer's"

echo "== a task on an integration branch has its base named in the brief ==" >&2
has "$(security_brief 42 /x integration)" "exactly \`git diff origin/integration...HEAD\`: where the diff shown to you differs from that" \
  "the base the pull request is aimed at, not origin/HEAD"
hasnt "$(security_brief 42 /x "")" "git diff origin/" "and with no base known, no command is invented"

echo "== code first: posted waits on the security review, then one follow-up about both ==" >&2
reset_tasks; reset_caches; reset_logs; mode ok; smode hold
G=$(mk_gated 020 codefirst w1:p1)
home="$PQ_HOME/tasks/$(basename "$G")"
set_panes "$(printf 'w1:p1\tclaude\tidle')"
review_task "$G" 0 >/dev/null 2>&1
wait_for test -f "$G/review.rc" && ok || bad "the code stub should have finished"
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_REVIEW)" "posted" "the code review is collected"
eq "$(st "$G" PQ_SECURITY)" "running" "the security review is still going"
eq "$(review_cell "$G")" "security review $(age_since "$(st "$G" PQ_SECURITY_AT)")" "and the cell says what the gate is waiting on"
review_inflight "$G" && ok || bad "the slot stays held"
review_task "$G" 0 >/dev/null 2>&1
eq "$(prompts)" "0" "no follow-up while the security review runs"
eq "$(st "$G" PQ_REVIEW)" "posted" "still posted"
release security
wait_for test -f "$G/security.rc" && ok || bad "the held security stub should have finished"
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_SECURITY)" "done" "collected"
eq "$(st "$G" PQ_SECURITY_RESULT)" "ok" "as ok"
eq "$(st "$G" PQ_SECURITY_POSTED)" "1" "and posted"
has "$(cat "$PQ_HOME/.out")" "security review of #42 posted (\$0.90, 1m30s)" "with its cost"
cmp -s "$G/security.md" "$REPORT" && ok || bad "security.md is the report the reviewer replied with"
has "$(cat "$GH_LOG")" "pr comment 42 --body-file" "pq posted it on the pull request itself"
body=$(cat "$STUBBIN/.comment-body" 2>/dev/null)
has "$body" "_An independent \`/security-review\` of this pull request, run by pq because its plan asked for one._" "led by a line saying what it is"
has "$body" "# Vuln 1: SQL injection: \`app/notes.rb:12\`" "then the report, whole"
eq "$(st "$G" PQ_REVIEW)" "prompted" "and the follow-up went on the tick the security review finished"
eq "$(prompts)" "1" "once"
P=$(prompt_text)
has "$P" "inline review comments" "it still covers the code review"
has "$P" "The security review the plan asked for has run as well, and its report is posted on the pull request and saved in $home/security.md." "and the security one, with where to read it"
has "$P" "Resolve every finding it raises: fix it and push, or answer it in a comment on the pull request with why it is not exploitable." "and what to do about it"
has "$P" "Leave no comment unanswered. The security review" "in order: the code review, then the security review"
has "$P" "gh pr ready 42" "then marking it ready"
hasnt "$P" "'" "quote-free"

echo "== security first: the gate takes its own steps, and delivers both ==" >&2
reset_tasks; reset_caches; reset_logs; mode hold; smode ok
G=$(mk_gated 021 secfirst w1:p1)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
review_task "$G" 0 >/dev/null 2>&1
wait_for test -f "$G/security.rc" && ok || bad "the security stub should have finished"
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_SECURITY)" "done" "the security review is collected while the code review runs"
eq "$(st "$G" PQ_REVIEW)" "running" "the gate is still running"
eq "$(review_cell "$G")" "reviewing $(age_since "$(st "$G" PQ_REVIEW_AT)")" "and says so"
release code
wait_for test -f "$G/review.rc" && ok || bad "the held code stub should have finished"
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_REVIEW)" "posted" "one step: collected"
eq "$(review_cell "$G")" "reviewed" "reviewed, with both done"
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_REVIEW)" "prompted" "the next: delivered"
has "$(prompt_text)" "The security review the plan asked for has run as well" "about both"

echo "== code ok, security failed twice: the follow-up asks for a security self-review ==" >&2
reset_tasks; reset_caches; reset_logs; mode ok; smode fail
G=$(mk_gated 030 secfails w1:p1)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
review_task "$G" 0 >/dev/null 2>&1
wait_for test -f "$G/review.rc"; wait_for test -f "$G/security.rc"
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_REVIEW)" "posted" "the code review is in"
eq "$(st "$G" PQ_SECURITY)" "pending" "the failed security review is back to pending"
eq "$(st "$G" PQ_SECURITY_RETRY_AT)" "$(( FAKE_NOW + PQ_REVIEW_RETRY ))" "on the gate's backoff"
has "$(cat "$PQ_HOME/.out")" "security review attempt 1 failed - the security reviewer exited 1" "said, with the attempt"
eq "$(review_cell "$G")" "security review due" "the cell says what is holding the gate"
review_task "$G" 0 >/dev/null 2>&1
eq "$(prompts)" "0" "no follow-up while a retry is due"
eq "$(sec_calls)" "1" "and no relaunch inside the backoff"
FAKE_NOW=$(( FAKE_NOW + PQ_REVIEW_RETRY + 1 ))
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_SECURITY)" "running" "the retry launches beside a posted gate"
wait_for calls_at_least sec_calls 2
eq "$(st "$G" PQ_SECURITY_TRIES)" "2" "second try"
wait_for test -f "$G/security.rc"
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_SECURITY)" "done" "the second failure is final"
eq "$(st "$G" PQ_SECURITY_RESULT)" "failed" "as failed"
has "$(cat "$PQ_HOME/.out")" "security review failed after 2 attempt(s)" "said"
eq "$(st "$G" PQ_REVIEW)" "prompted" "and the follow-up goes"
P=$(prompt_text)
has "$P" "inline review comments" "with the code review's findings"
has "$P" "The security review the plan asked for did not happen - the security reviewer exited with an error." "saying the security review did not happen, and why"
has "$P" "Review your own diff for the security risks the plan names, fix and push, and say in a comment on the pull request what you checked." "and asking for a security self-review"
hasnt "$P" "has run as well" "without pretending there is a report"
st_set "$G" PQ_REVIEW posted; st_set "$G" PQ_REVIEW_RESULT ok
eq "$(review_cell "$G")" "security review failed" "a posted gate with a failed security review says which one failed"

echo "== code failed, security ok: both texts, in order ==" >&2
reset_tasks; reset_caches; reset_logs; mode fail; smode ok
PQ_REVIEW_MAX_TRIES=1
G=$(mk_gated 031 codefails w1:p1)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
review_task "$G" 0 >/dev/null 2>&1
wait_for test -f "$G/review.rc"; wait_for test -f "$G/security.rc"
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_REVIEW_RESULT)" "failed" "the code review failed"
eq "$(st "$G" PQ_SECURITY_RESULT)" "ok" "the security review did not"
eq "$(review_cell "$G")" "review failed" "the code review's failure is the one the cell names"
review_task "$G" 0 >/dev/null 2>&1
P=$(prompt_text)
has "$P" "could not get an independent review of pull request #42" "the code fallback"
has "$P" "fix and push. The security review the plan asked for has run as well" "then the security report"

echo "== both failed ==" >&2
reset_tasks; reset_caches; reset_logs; mode fail; smode fail
G=$(mk_gated 032 bothfail w1:p1)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
review_task "$G" 0 >/dev/null 2>&1
wait_for test -f "$G/review.rc"; wait_for test -f "$G/security.rc"
review_task "$G" 0 >/dev/null 2>&1
review_task "$G" 0 >/dev/null 2>&1
P=$(prompt_text)
has "$P" "could not get an independent review" "the code fallback"
has "$P" "The security review the plan asked for did not happen" "and the security one"

echo "== a reply with no report is a failed try, and says so ==" >&2
reset_tasks; reset_caches; reset_logs; mode ok; smode empty
G=$(mk_gated 033 empty w1:p1)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
review_task "$G" 0 >/dev/null 2>&1
wait_for test -f "$G/security.rc"
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_SECURITY_RESULT)" "failed" "an empty report is not a review"
has "$(cat "$PQ_HOME/.out")" "the security reviewer finished without a report - see $G/security.json" "and is named for what it was"
[ -f "$G/security.md" ] && bad "no security.md for a review that produced none" || ok
PQ_REVIEW_MAX_TRIES=2

echo "== a denial is warned about and changes nothing ==" >&2
reset_tasks; reset_caches; reset_logs; mode ok; smode otherdeny
G=$(mk_gated 034 curious w1:p1)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
review_task "$G" 0 >/dev/null 2>&1
wait_for test -f "$G/security.rc"
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_SECURITY_RESULT)" "ok" "a denied gh read is still a review"
has "$(cat "$PQ_HOME/.out")" "the security reviewer reached for things it was denied (1 denials)" "but is reported"

echo "== a comment that does not land: the implementer is asked to post it ==" >&2
reset_tasks; reset_caches; reset_logs; mode ok; smode ok
G=$(mk_gated 040 unposted w1:p1)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
touch "$STUBBIN/.comment-fail"
review_task "$G" 0 >/dev/null 2>&1
wait_for test -f "$G/review.rc"; wait_for test -f "$G/security.rc"
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_SECURITY_RESULT)" "ok" "the review itself is fine"
eq "$(st "$G" PQ_SECURITY_POSTED)" "" "but it is not on the pull request"
has "$(cat "$PQ_HOME/.out")" "but could not be posted on it - the implementer will be asked to" "said"
ls "$G"/.security-comment.* >/dev/null 2>&1 && bad "the comment body is cleaned up either way" || ok
review_task "$G" 0 >/dev/null 2>&1
home="$PQ_HOME/tasks/$(basename "$G")"
has "$(prompt_text)" "pq could not post it on the pull request, so post it there yourself with gh pr comment 42 --body-file $home/security.md." "the follow-up hands the posting over"

echo "== timeout: killed, retried, then given up on as out of time ==" >&2
reset_tasks; reset_caches; reset_logs; mode ok; smode sleep
G=$(mk_gated 050 slow w1:p1)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
review_task "$G" 0 >/dev/null 2>&1
wait_for test -f "$G/review.rc"
PID=$(st "$G" PQ_SECURITY_PID)
FAKE_NOW=$(( FAKE_NOW + PQ_REVIEW_TIMEOUT + 1 ))
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
sleep 0.3
review_alive "$PID" && bad "the security reviewer's process group must be dead" || ok
eq "$(st "$G" PQ_SECURITY)" "pending" "back to pending - one try left"
eq "$(st "$G" PQ_SECURITY_RESULT)" "timeout" "with the reason"
has "$(cat "$PQ_HOME/.out")" "security review attempt 1 failed - ran past ${PQ_REVIEW_TIMEOUT}s" "said out loud"
eq "$(st "$G" PQ_REVIEW)" "posted" "the code review was collected on the same tick"
FAKE_NOW=$(( FAKE_NOW + PQ_REVIEW_RETRY + 1 ))
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_SECURITY)" "running" "relaunched"
FAKE_NOW=$(( FAKE_NOW + PQ_REVIEW_TIMEOUT + 1 ))
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_SECURITY)" "done" "the second timeout is final"
eq "$(st "$G" PQ_SECURITY_RESULT)" "timeout" "as a timeout"
has "$(prompt_text)" "The security review the plan asked for did not happen - the security reviewer ran out of time." "and the follow-up says so"

echo "== a PR that settles mid-review kills both reviewers ==" >&2
reset_tasks; reset_caches; reset_logs; mode sleep; smode sleep
G=$(mk_gated 060 settled w1:p1)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
review_task "$G" 0 >/dev/null 2>&1
CPID=$(st "$G" PQ_REVIEW_PID); SPID=$(st "$G" PQ_SECURITY_PID)
reset_caches; cache_row "$REPO" tom/settled 42 MERGED "" master
review_task "$G" 0 >/dev/null 2>&1
sleep 0.3
review_alive "$CPID" && bad "the code reviewer must be dead" || ok
review_alive "$SPID" && bad "and the security reviewer" || ok
eq "$(st "$G" PQ_REVIEW)" "skipped" "the gate is skipped"
eq "$(st "$G" PQ_SECURITY)" "skipped" "and the security ladder with it"
eq "$(st "$G" PQ_SECURITY_WHY)" "settled" "as settled"
review_inflight "$G" && bad "nothing holds the slot" || ok

echo "== STUCK: neither reviewer runs ==" >&2
reset_tasks; reset_caches; reset_logs; mode ok; smode ok
pr_json "STUCK: the model is not where the plan says" OPEN true 1 50 5
G=$(mk_gated 070 stuck w1:p1)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_SECURITY)" "skipped" "the security ladder is skipped with the gate"
eq "$(st "$G" PQ_SECURITY_WHY)" "stuck" "for the same reason"
sleep 0.3
eq "$(sec_calls)" "0" "no security reviewer"
pr_json "Do the thing" OPEN true 3 100 20

echo "== pq rm kills a security reviewer the gate is waiting on ==" >&2
reset_tasks; reset_caches; reset_logs; mode ok; smode sleep
K=$(mk_gated 080 removed w1:p1)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
review_task "$K" 0 >/dev/null 2>&1
wait_for test -f "$K/review.rc"
review_task "$K" 0 >/dev/null 2>&1
eq "$(st "$K" PQ_REVIEW)" "posted" "the gate is past running"
SPID=$(st "$K" PQ_SECURITY_PID)
review_alive "$SPID" && ok || bad "while the security reviewer runs"
( main rm removed <<<"y" ) >/dev/null 2>&1
sleep 0.3
review_alive "$SPID" && bad "pq rm must kill the security reviewer too" || ok
[ -d "$K" ] && bad "and the task is gone" || ok

echo "== an agent that is gone: the security review is let finish, then the gate lapses ==" >&2
reset_tasks; reset_caches; reset_logs; mode ok; smode hold
G=$(mk_gated 090 exited w1:p1)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
review_task "$G" 0 >/dev/null 2>&1
wait_for test -f "$G/review.rc"
review_task "$G" 0 >/dev/null 2>&1
set_panes "$(printf 'w1:p1\t\t')"
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_REVIEW)" "posted" "no lapse while the security review is still running"
release security
wait_for test -f "$G/security.rc"
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_SECURITY_POSTED)" "1" "its report still reaches the pull request"
eq "$(st "$G" PQ_REVIEW)" "lapsed" "and then the gate lapses"
eq "$(st "$G" PQ_REVIEW_WHY)" "noagent" "for that reason"
eq "$(prompts)" "0" "nothing is prompted into an empty pane"

echo "== no worktree to run in: given up on at once, with the reason ==" >&2
reset_tasks; reset_caches; reset_logs; mode ok; smode ok
G=$(mk_gated 100 noworktree w1:p1)
st_set "$G" PQ_WORKTREE /nonexistent/worktree
set_panes "$(printf 'w1:p1\tclaude\tidle')"
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_REVIEW)" "running" "the code reviewer runs from the main checkout"
eq "$(st "$G" PQ_SECURITY)" "done" "the security reviewer, which reads the worktree's HEAD, cannot"
eq "$(st "$G" PQ_SECURITY_RESULT)" "failed" "and is a failure the follow-up explains"
has "$(cat "$PQ_HOME/.out")" "no worktree to run the security review in (/nonexistent/worktree)" "said"
sleep 0.3
eq "$(sec_calls)" "0" "nothing launched"

echo "== PQ_REVIEW_MAX_TRIES=0: neither reviewer, both fallbacks ==" >&2
reset_tasks; reset_caches; reset_logs
G=$(mk_gated 110 degraded w1:p1)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
PQ_REVIEW_MAX_TRIES=0
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_REVIEW)" "posted" "the gate goes straight to posted"
eq "$(st "$G" PQ_SECURITY)" "done" "and the security ladder straight to done"
eq "$(st "$G" PQ_SECURITY_RESULT)" "failed" "as a failure"
review_task "$G" 0 >/dev/null 2>&1
PQ_REVIEW_MAX_TRIES=2
has "$(prompt_text)" "The security review the plan asked for did not happen" "the follow-up asks for both self-reviews"
sleep 0.3
eq "$(code_calls)$(sec_calls)" "00" "nothing launched"

echo "== a task that never asked gets, byte for byte, the prompt it always got ==" >&2
for r in ok failed timeout denied; do
  eq "$(review_prompt 42 "$r" "" "" master "" "" "")" "$(review_prompt 42 "$r" "" "" master)" "$r: no security arguments, no difference"
  hasnt "$(review_prompt 42 "$r" 1 900 master)" "security" "$r: and no word of it"
done
reset_tasks; reset_caches; reset_logs; mode ok
U=$(mk_task "done" 120 unasked tom/unasked w1:p1)
st_set "$U" PQ_LAUNCHED "$(now)"; st_set "$U" PQ_PR 42; st_set "$U" PQ_REVIEW pending
cache_row "$REPO" tom/unasked 42 OPEN draft master
set_panes "$(printf 'w1:p1\tclaude\tidle')"
review_task "$U" 0 >/dev/null 2>&1
wait_for test -f "$U/review.rc"
review_task "$U" 0 >/dev/null 2>&1
review_task "$U" 0 >/dev/null 2>&1
eq "$(st "$U" PQ_REVIEW)" "prompted" "the gate runs as it always did"
eq "$(sec_calls)" "0" "with no security reviewer"
hasnt "$(prompt_text)" "security" "and no word of one in the follow-up"

echo "== pq ls: the cells and --json ==" >&2
reset_tasks; reset_caches; reset_logs
G=$(mk_gated 130 listed w1:p1)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
st_set "$G" PQ_REVIEW posted; st_set "$G" PQ_REVIEW_RESULT ok
st_set "$G" PQ_SECURITY running; st_set "$G" PQ_SECURITY_AT "$(( $(date -u +%s) - 180 ))"
eq "$(agent_cell "$G" "done")" "security review 3m" "a posted gate waiting on a running security review"
st_set "$G" PQ_SECURITY pending
eq "$(agent_cell "$G" "done")" "security review due" "or on one yet to launch"
st_set "$G" PQ_SECURITY "done"; st_set "$G" PQ_SECURITY_RESULT ok
eq "$(agent_cell "$G" "done")" "reviewed" "both done and ok"
st_set "$G" PQ_SECURITY_RESULT timeout
eq "$(agent_cell "$G" "done")" "security review failed" "the security one failed"
J=$(main ls --json 2>/dev/null)
eq "$(jq -r '.[] | select(.task == "listed") | .security' <<<"$J")" "done" "--json carries security"
eq "$(jq -r '.[] | select(.task == "listed") | .security_result' <<<"$J")" "timeout" "and security_result"
st_set "$G" PQ_SECURITY ""; st_set "$G" PQ_SECURITY_RESULT ""
eq "$(jq -r '.[] | select(.task == "listed") | .security' <<<"$(main ls --json 2>/dev/null)")" "null" "a task that never asked reads null"

echo "== --dry-run: would-lines only ==" >&2
reset_tasks; reset_caches; reset_logs
G=$(mk_gated 140 dry w1:p1)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
st_set "$G" PQ_REVIEW running
OUT=$(security_step "$G" 1 42 idle 2>&1)
has "$OUT" "would launch a security review of dry" "the would-line"
eq "$(st "$G" PQ_SECURITY)" "pending" "nothing changed"
sleep 0.3
eq "$(sec_calls)" "0" "nothing launched"

echo "== through tick_body: both reviewers, one follow-up ==" >&2
reset_tasks; reset_caches; reset_logs; mode ok; smode ok
W=$(mk_gated 150 whole w1:p1)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
tick 3 0
eq "$(st "$W" PQ_REVIEW)" "running" "tick 1 launches the code reviewer"
eq "$(st "$W" PQ_SECURITY)" "running" "and the security one"
has "$PQ_SUMMARY" ", 1 reviewing" "counted once, as one task under review"
wait_for test -f "$W/review.rc"; wait_for test -f "$W/security.rc"
reset_caches; cache_row "$REPO" tom/whole 42 OPEN draft master
tick 3 0
eq "$(st "$W" PQ_REVIEW)" "posted" "tick 2 collects the code review"
eq "$(st "$W" PQ_SECURITY)" "done" "and the security one"
reset_caches; cache_row "$REPO" tom/whole 42 OPEN draft master
tick 3 0
eq "$(st "$W" PQ_REVIEW)" "prompted" "tick 3 delivers"
eq "$(prompts)" "1" "one follow-up"
reset_caches; cache_row "$REPO" tom/whole 42 OPEN "" master
tick 3 0
eq "$(st "$W" PQ_REVIEW)" "ready" "tick 4 sees the draft marked ready"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
