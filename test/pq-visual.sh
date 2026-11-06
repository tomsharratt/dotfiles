#!/usr/bin/env bash
# test/pq-visual.sh - the design reviewer: a task built from a design gets an
# independent `/design-review` beside the gate's `/code-review` (and beside a
# security review, when its plan asked for one), run by pq in the background,
# its report posted on the pull request, and one follow-up about all of them.
#
# Same shape as test/pq-security.sh, which is the same shape as test/pq-review.sh - a pinned clock, `set_panes` steering herdr's
# snapshot, a `claude` stub that records how it was called - but the stub tells
# its callers apart by the prompt: the namer (haiku) answers off a marker line in
# the plan, and each reviewer behaves per a mode file
# of its own, so "the code review passed and the security review failed" is one
# test rather than a race. `hold` keeps a reviewer running until the test
# releases it, which is how the two are made to finish in a chosen order.
#
# SC2034: the knobs and caches set here are read by the pq sourced below.
# SC2015: `ok` never fails, so `[ ... ] && ok || bad` is an if/else.
# shellcheck disable=SC2034,SC2015
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=test/sandbox.sh
source "$HERE/sandbox.sh"

PQ_HOME=$(mktemp -d)
export PQ_HOME
PQ_PLANS_DIR=$(mktemp -d)
export PQ_PLANS_DIR

STUBBIN=$(mktemp -d)
PANES_JSON="$STUBBIN/.panes.json"
HERDR_LOG="$STUBBIN/.herdr-calls"
CLAUDE_LOG="$STUBBIN/.claude-calls"
CLAUDE_ENV="$STUBBIN/.claude-env"
GH_LOG="$STUBBIN/.gh-calls"
MODE="$STUBBIN/.mode"                   # the code reviewer's behaviour
SMODE="$STUBBIN/.smode"                 # the security reviewer's
VMODE="$STUBBIN/.vmode"                 # the design reviewer's
VREPORT="$STUBBIN/.vreport"
PRJSON="$STUBBIN/.pr.json"
COMMENTS="$STUBBIN/.comments"
REPORT="$STUBBIN/.report"
FILES="$STUBBIN/.files"                 # the pull request's files, as the API pages them; none is a failure
printf '{"result":{"snapshot":{"panes":[]}}}' > "$PANES_JSON"
: > "$HERDR_LOG"; : > "$CLAUDE_LOG"; : > "$CLAUDE_ENV"; : > "$GH_LOG"
printf 'ok' > "$MODE"; printf 'ok' > "$SMODE"; printf 'ok' > "$VMODE"; printf '0' > "$COMMENTS"
# shellcheck disable=SC2016  # the backticks are markdown in the report, not a substitution
printf '# Design review: #42\n\nReference: Board.dc.html, 2 frames.\n\n## Findings\n\n1. **Must fix - Summary, 1440: the title is the wrong size.**\n   Design 20px/600; built 18px/500.\n\n## Verdict\n\n1 must-fix finding.\n' > "$VREPORT"
# shellcheck disable=SC2016  # the backticks are markdown in the report, not a substitution
printf '# Security review: PR #42\n\n# Vuln 1: SQL injection: `app/notes.rb:12`\n\n* Severity: High\n* Confidence: 9\n* Exploit: a search term reaches the query unbound.\n* Recommendation: bind the term.\n' > "$REPORT"

cat > "$STUBBIN/claude" <<EOF
#!/bin/sh
{ printf '%s\t' "\$PWD"; for a in "\$@"; do printf '%s\t' "\$a"; done; printf '\n'; } >> "$CLAUDE_LOG"
model="" prev="" last=""
for a in "\$@"; do [ "\$prev" = --model ] && model=\$a; prev=\$a; last=\$a; done
if [ "\$model" = haiku ]; then
  content=\$(cat)
  case "\$content" in
    *"MARKER: secure"*)     printf '{"branch":"tom/secure-it","intent":"Lock it down.","security":true}\n' ;;
    *"MARKER: guessed"*)    printf '{"branch":"tom/guessed-it","intent":"Guessed.","security":true}\n' ;;
    *"MARKER: waived"*)     printf '{"branch":"tom/waived-it","intent":"Waived.","security":false}\n' ;;
    *"MARKER: nointent"*)   printf '{"branch":"tom/no-intent","intent":"","security":true}\n' ;;
    *) printf '{}\n' ;;
  esac
  exit 0
fi
printf 'pane=%s session=%s args=%s\n' "\${HERDR_PANE_ID-unset}" "\${CHROME_DEVTOOLS_AXI_SESSION-unset}" "\${CHROME_DEVTOOLS_AXI_CHROME_ARGS-unset}" >> "$CLAUDE_ENV"
case "\$last" in
  /security-review) kind=security; m=\$(cat "$SMODE") ;;
  /design-review*)  kind=visual;   m=\$(cat "$VMODE") ;;
  /code-review*)    kind=code;     m=\$(cat "$MODE") ;;
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
  echo \$(( \$(cat "$COMMENTS") + 2 )) > "$COMMENTS"      # a review that lands posts inline comments
  printf '{"is_error":false,"total_cost_usd":1.2,"duration_ms":5000,"session_id":"code-1","permission_denials":[]}\n'; exit 0
fi
if [ "\$kind" = visual ]; then
  case "\$m" in
    ok)    jq -nc --rawfile r "$VREPORT" '{is_error:false,total_cost_usd:2.5,duration_ms:300000,session_id:"visual-1",permission_denials:[],result:\$r}' ;;
    short) printf '{"is_error":false,"result":"Two sub-agents are comparing the frames; I will report once they finish."}\n' ;;
  esac
  exit 0
fi
case "\$m" in
  ok)        jq -nc --rawfile r "$REPORT" '{is_error:false,total_cost_usd:0.9,duration_ms:90000,session_id:"security-1",permission_denials:[],result:\$r}' ;;
  empty)     printf '{"is_error":false,"result":"  "}\n' ;;
  short)     printf '{"is_error":false,"total_cost_usd":4.67,"result":"The vulnerability-identification sub-task is still running. I will verify its findings once it reports back."}\n' ;;
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
  *"/pulls/"*"/files"*) printf '%s\n' "\$*" >> "$GH_LOG"; [ -f "$FILES" ] || exit 1; cat "$FILES"; exit 0 ;;
  *"/comments"*) awk -v n="\$(cat "$COMMENTS")" 'BEGIN { for (i = 1; i <= n; i++) print i }'; exit 0 ;;
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
# The design reviewer's browser is stopped by pq; the stub logs who asked.
# shellcheck disable=SC2016  # the stub's own shell expands these, not this one
printf '#!/bin/sh\nprintf "%%s %%s\\n" "$CHROME_DEVTOOLS_AXI_SESSION" "$*" >> "%s/.axi-calls"\nexit 0\n' "$STUBBIN" > "$STUBBIN/chrome-devtools-axi"
chmod +x "$STUBBIN/chrome-devtools-axi"
chmod +x "$STUBBIN/claude" "$STUBBIN/gh" "$STUBBIN/herdr" "$STUBBIN/wt-stub"
export PATH="$STUBBIN:$PATH"
export PQ_WT="$STUBBIN/wt-stub"

# shellcheck source=/dev/null
source "$HERE/../.local/bin/pq"
sandbox_guard
# shellcheck source=test/lib.sh
source "$HERE/lib.sh"
gum_stub "$STUBBIN" "$PQ_HOME/.gum"
# pq rm asks through gum, at a terminal: the terminal is stood in for.
# shellcheck disable=SC2329  # called by pq rm, not here
at_terminal() { return 0; }

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
  touch "$STUBBIN/.release-code" "$STUBBIN/.release-security" "$STUBBIN/.release-visual" 2>/dev/null
  for d in "$PQ_HOME"/done/*/; do [ -d "$d" ] && review_kill "${d%/}"; done
  sandbox_cleanup
}
trap cleanup EXIT

REPO=$(mktemp -d)
git init -q -b master "$REPO"
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
mkdir -p "$REPO/.git/refs/remotes/origin"
git -C "$REPO" update-ref refs/remotes/origin/master refs/heads/master
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
TASK_WT=$(mktemp -d)                         # the task's worktree, where both reviewers must run

unset HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID
PQ_DONE_KEEP=99
PQ_WRAPUP_GRACE=300
PQ_REVIEW_TIMEOUT=1500
PQ_REVIEW_MAX_TRIES=2
PQ_REVIEW_RETRY=600
PQ_REVIEW_SPLIT_LINES=150
# Neither is its default, and they differ, so the argv assertions prove each
# reviewer runs at its own.
PQ_REVIEW_EFFORT=low
PQ_SECURITY_EFFORT=max

FAKE_NOW=$(date -u '+%s')
epoch() { printf '%s' "$FAKE_NOW"; }
now()   { date -u -r "$FAKE_NOW" '+%Y-%m-%dT%H:%M:%SZ'; }
ago()   { date -u -r "$(( FAKE_NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }

reset_caches() { PR_CACHE="$PQ_HOME/.test.pr"; PR_ANS="$PQ_HOME/.test.ans"; : > "$PR_CACHE"; : > "$PR_ANS"; }
cache_row() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$PR_CACHE"; }   # repo branch num state draft base
reset_tasks() {
  local d
  touch "$STUBBIN/.release-code" "$STUBBIN/.release-security" "$STUBBIN/.release-visual"
  for d in "$PQ_HOME"/done/*/ "$PQ_HOME"/running/*/; do [ -d "$d" ] && review_kill "${d%/}"; done
  rm -f "$STUBBIN/.release-code" "$STUBBIN/.release-security" "$STUBBIN/.release-visual"
  rm -rf "$PQ_HOME/new" "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done" "$PQ_HOME/archive"
  mkdir -p "$PQ_HOME/new" "$PQ_HOME/queue" "$PQ_HOME/running" "$PQ_HOME/done" "$PQ_HOME/archive"
}
reset_tasks
reset_logs() {
  : > "$HERDR_LOG"; : > "$CLAUDE_LOG"; : > "$CLAUDE_ENV"; : > "$GH_LOG"
  rm -f "$STUBBIN/.comment-fail" "$STUBBIN/.comment-body" "$FILES"
}
mode()  { printf '%s' "$1" > "$MODE"; }
smode() { printf '%s' "$1" > "$SMODE"; }
vmode() { printf '%s' "$1" > "$VMODE"; }
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

mk_task() {                             # state prio slug branch pane security design kind -> task_dir
  local state=$1 prio=$2 slug=$3 branch=$4 pane=$5 sec=${6:-} design=${7:-} kind=${8:-}
  local dir
  dir="$PQ_HOME/$state/$(printf '%014d' $(( 20260101000000 + 10#$prio )))-$slug"
  mkdir -p "$dir"
  {
    printf -- '---\n'
    printf 'repo:     %s\n' "$REPO"
    printf 'branch:   %s\n' "$branch"
    [ "$sec" = yes ] && printf 'security: yes\n'
    [ -n "$design" ] && printf 'design:   %s\n' "$design"
    [ -n "$kind" ] && printf 'kind:     %s\n' "$kind"
    printf 'model:    sonnet\n'
    printf 'effort:   xhigh\n'
    printf 'intent:   test fixture\n'
    printf 'added:    2026-01-01T00:00:00Z\n'
    printf -- '---\n\nplan body\n'
  } > "$dir/plan.md"
  [ -n "$pane" ] && st_set "$dir" PQ_PANE "$pane"
  st_set "$dir" PQ_WORKTREE "$TASK_WT"
  task_link "$dir"
  printf '%s' "$dir"
}
# A done task with an open draft PR #42 built from a design board, served from
# a dev tab, its gate and the design ladder pending - what reconcile leaves
# behind. A fourth argument of `yes` asks for a security review as well, and a
# fifth of `design` makes it a design task.
mk_gated() {                            # prio slug pane [security] [kind] -> task_dir
  local d; d=$(mk_task "done" "$1" "$2" "tom/$2" "$3" "${4:-}" Board.dc.html "${5:-}")
  st_set "$d" PQ_LAUNCHED "$(now)"; st_set "$d" PQ_PR 42; st_set "$d" PQ_FINISHED "$(now)"
  st_set "$d" PQ_URL "https://tom-$2.test"; st_set "$d" PQ_DEV_PANE w1:p2
  st_set "$d" PQ_REVIEW pending; st_set "$d" PQ_VISUAL pending
  [ "${4:-}" = yes ] && st_set "$d" PQ_SECURITY pending
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
vis_calls()  { grep -c $'\t/design-review ' "$CLAUDE_LOG" 2>/dev/null || true; }
code_calls() { grep -c $'\t/code-review ' "$CLAUDE_LOG" 2>/dev/null || true; }
wait_for() {                            # command... -> polls up to 5s
  local _; for _ in $(seq 1 50); do "$@" && return 0; sleep 0.1; done
  return 1
}
calls_at_least() { [ "$("$1")" -ge "$2" ]; }
prompt_text() { grep "^agent	prompt	" "$HERDR_LOG" | tail -1 | cut -f4; }
prompts()     { grep -c "^agent	prompt	" "$HERDR_LOG" 2>/dev/null || true; }
files_json()  { jq -nc '$ARGS.positional | map({filename: ., status: "modified", additions: 1})' --args "$@"; }
draws()       { jq -sr "$SCREEN_FILES_JQ" <<<"$(files_json "$@")"; }


echo "== which tasks get a design review ==" >&2
reset_tasks
V1=$(mk_task running 001 boarded tom/boarded w1:p1 "" Board.dc.html)
visual_wanted "$V1" && ok || bad "a task carrying design files gets one"
V2=$(mk_task running 002 designtask tom/designtask w1:p1 "" "" design)
visual_wanted "$V2" && ok || bad "a design task gets one"
V3=$(mk_task running 003 builton tom/builton w1:p1)
after_line "design-it" "$REPO" tom/design-it design > "$V3/after"
visual_wanted "$V3" && ok || bad "a task built on a merged design gets one"
V4=$(mk_task running 004 plainold tom/plainold w1:p1)
visual_wanted "$V4" && bad "a task with no design gets none" || ok

echo "== the contract names the design reviewer only for a task built from a design ==" >&2
contract_write "$V1"
has "$(cat "$V1/contract.md")" "pq also runs an independent \`/design-review\` of the pull request" "a design task is told pq runs it"
has "$(cat "$V1/contract.md")" "A pull request that changes no file that draws a screen - no template, component, stylesheet, frontend code, copy or asset - gets no design review" "and that a pull request drawing nothing gets none"
contract_write "$V2"
has "$(cat "$V2/contract.md")" "pq also runs an independent \`/design-review\` of the pull request" "a design task is told pq runs it"
hasnt "$(cat "$V2/contract.md")" "gets no design review" "and never that it may not: a design task always draws"
contract_write "$V4"
hasnt "$(cat "$V4/contract.md")" "design-review" "a task with no design hears nothing about it"

echo "== reconcile opens the design ladder beside the gate ==" >&2
reset_tasks; reset_caches; reset_logs
R=$(mk_task running 005 drawn tom/drawn w1:p1 "" Board.dc.html)
st_set "$R" PQ_LAUNCHED "$(now)"
R2=$(mk_task running 006 undrawn tom/undrawn w1:p2)
st_set "$R2" PQ_LAUNCHED "$(now)"
cache_row "$REPO" tom/drawn 42 OPEN draft master
cache_row "$REPO" tom/undrawn 43 OPEN draft master
set_panes "$(printf 'w1:p1\tclaude\tworking\nw1:p2\tclaude\tworking')"
tick 3 0
D=$(ls -d "$PQ_HOME"/done/*-drawn); D=${D%/}
D2=$(ls -d "$PQ_HOME"/done/*-undrawn); D2=${D2%/}
eq "$(st "$D" PQ_VISUAL)" "pending" "a task built from a design gets the design ladder"
eq "$(st "$D2" PQ_VISUAL)" "" "one with no design gets none"

echo "== launch: the design reviewer goes out with the code reviewer, in a browser of its own ==" >&2
reset_tasks; reset_caches; reset_logs; mode sleep; vmode sleep
G=$(mk_gated 011 launched w1:p1)
home="$PQ_HOME/tasks/$(basename "$G")"
set_panes "$(printf 'w1:p1\tclaude\tidle')"
out=$(export HERDR_PANE_ID=w9:p9; review_task "$G" 0 2>&1)
eq "$(st "$G" PQ_REVIEW)" "running" "the code reviewer is running"
eq "$(st "$G" PQ_VISUAL)" "running" "and the design reviewer, on the same tick"
has "$out" "design-reviewing #42 with opus in the background" "said"
wait_for calls_at_least vis_calls 1
line=$(grep $'\t/design-review ' "$CLAUDE_LOG" | head -1)
eq "$(cut -f1 <<<"$line")" "$TASK_WT" "it runs in the task's worktree"
has "$line" "	--effort	high	" "at PQ_VISUAL_EFFORT"
has "$line" "	--permission-mode	auto	" "in auto mode"
has "$line" "	--disallowedTools	Edit(/$HOME/**)	Bash(gh pr comment:*)	Bash(gh pr review:*)	Bash(gh pr edit:*)	Bash(gh pr ready:*)	Bash(gh pr merge:*)	Bash(gh pr close:*)	Bash(gh api:*)	Bash(wt open:*)	Bash(git checkout:*)" \
  "read-only, posting nothing, and never opening the user's own browser"
has "$line" "	--add-dir	$home	" "with the task's own directory opened to it"
has "$line" "	--output-format	json	/design-review 42 --out $home/visual	" "the skill, the pull request, and where its screenshots go"
[ -d "$G/visual" ] && ok || bad "the screenshot directory is made for it"
has "$line" "The reference is the design board in $home/design/ (Board.dc.html), opened as file://$home/design/<file>." "held to the board"
has "$line" "The app is served at https://tom-launched.test" "told where the app is"
has "$line" "use them only to learn which screens and states it built, never as your evidence" "and not to trust the implementer's screenshots"
has "$line" "Run any sub-agent you start in the foreground and wait for its result" "and to wait for its sub-agents"
has "$line" "\`git diff origin/master...HEAD\`" "told the diff it is reviewing"
case "$(visual_brief "$G" 42 master)" in *"'"*|*$'\n'*) bad "the brief must be one line and quote-free" ;; *) ok ;; esac
grep -q "pane=unset session=pq-visual-launched args=--ignore-certificate-errors" "$CLAUDE_ENV" \
  && ok || bad "a browser session of its own, past the .test certificate: $(cat "$CLAUDE_ENV")"

echo "== the reference follows the kind of task ==" >&2
reset_tasks
B=$(mk_task "done" 012 designtask tom/designtask w1:p1 "" Board.dc.html design)
has "$(visual_brief "$B" 42 master)" "This is a design pull request" "a design task's previews are held to the board"
B2=$(mk_task "done" 013 builton tom/builton w1:p1 "" Board.dc.html)
after_line "design-it" "$REPO" tom/design-it design > "$B2/after"
st_set "$B2" PQ_DESIGN_PR 40
P=$(visual_brief "$B2" 42 master)
has "$P" "built on design pull request #40 (\`tom/design-it\`), which has merged: its component previews are the reference" "a task built on a design is held to its previews"
has "$P" "where the two differ, the previews win" "with the board as the draft"
B3=$(mk_task "done" 014 noserver tom/noserver w1:p1 "" Board.dc.html)
has "$(visual_brief "$B3" 42 master)" "This worktree has no dev server" "no dev tab: told to compare the code instead"

echo "== the report is posted, and the one follow-up waits for it ==" >&2
reset_tasks; reset_caches; reset_logs; mode ok; vmode hold
G=$(mk_gated 020 posted w1:p1)
home="$PQ_HOME/tasks/$(basename "$G")"
set_panes "$(printf 'w1:p1\tclaude\tidle')"
review_task "$G" 0 >/dev/null 2>&1
wait_for test -f "$G/review.rc"
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_REVIEW)" "posted" "the code review is collected"
has "$(cat "$PQ_HOME/.out")" "- the follow-up waits for the design review, running" "and the wait is said"
has "$(review_cell "$G")" "design review " "the cell says what the gate waits on"
review_task "$G" 0 >/dev/null 2>&1
eq "$(prompts)" "0" "no follow-up while the design review runs"
release visual
wait_for test -f "$G/visual.rc"
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_VISUAL)" "done" "collected"
eq "$(st "$G" PQ_VISUAL_RESULT)" "ok" "as ok"
eq "$(st "$G" PQ_VISUAL_POSTED)" "1" "and posted"
grep -qx "pq-visual-posted stop" "$STUBBIN/.axi-calls" && ok || bad "its browser session is stopped once it is collected: $(cat "$STUBBIN/.axi-calls" 2>/dev/null)"
has "$(cat "$PQ_HOME/.out")" "design review of #42 posted (\$2.50, 5m0s)" "with its cost"
eq "$(cut -f7 <<<"$(cost_sum "$G")")" "2.5" "in the ledger under its own kind"
cmp -s "$G/visual.md" "$VREPORT" && ok || bad "visual.md is the report"
body=$(cat "$STUBBIN/.comment-body" 2>/dev/null)
has "$body" "_An independent \`/design-review\` of this pull request against its design, run by pq._" "led by a line saying what it is"
has "$body" "1. **Must fix - Summary, 1440: the title is the wrong size.**" "then the report, whole"
eq "$(st "$G" PQ_REVIEW)" "prompted" "and the follow-up went on the tick it finished"
P=$(prompt_text)
has "$P" "pq has also run an independent design review" "about the design review"
has "$P" "posted on the pull request and saved in $home/visual.md" "with where to read it"
has "$P" "Fix every must-fix finding" "and what to do about it"
has "$P" "Leave no comment unanswered. pq has also run" "after the code review's text"
hasnt "$P" "'" "quote-free"

echo "== with a security review too: one follow-up, security then design ==" >&2
reset_tasks; reset_caches; reset_logs; mode ok; smode ok; vmode ok
G=$(mk_gated 030 both w1:p1 yes)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_SECURITY)$(st "$G" PQ_VISUAL)" "runningrunning" "all three go out on one tick"
wait_for test -f "$G/review.rc"; wait_for test -f "$G/security.rc"; wait_for test -f "$G/visual.rc"
review_task "$G" 0 >/dev/null 2>&1
review_task "$G" 0 >/dev/null 2>&1
eq "$(prompts)" "1" "one follow-up about all three"
P=$(prompt_text)
case "$P" in *"The security review the plan asked for has run as well"*"pq has also run an independent design review"*) ok ;; *) bad "security before design in the follow-up: $P" ;; esac

echo "== a reply too short to be a report, then a failure: the fallback ==" >&2
reset_tasks; reset_caches; reset_logs; mode ok; vmode short
G=$(mk_gated 040 short w1:p1)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
review_task "$G" 0 >/dev/null 2>&1
wait_for test -f "$G/visual.rc"
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_VISUAL_RESULT)" "incomplete" "a one-line reply is not a report"
has "$(cat "$PQ_HOME/.out")" "the design reviewer replied before its report was written" "said"
[ -f "$STUBBIN/.comment-body" ] && bad "and is never posted" || ok
vmode fail
FAKE_NOW=$(( FAKE_NOW + PQ_REVIEW_RETRY + 1 ))
review_task "$G" 0 >/dev/null 2>&1
wait_for test -f "$G/visual.rc"
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_VISUAL)" "done" "the second failure is final"
has "$(prompt_text)" "The design review did not happen - the design reviewer exited with an error. Compare every screen you built against the design once more yourself" "the follow-up asks for the implementer's own comparison"
st_set "$G" PQ_REVIEW posted; st_set "$G" PQ_REVIEW_RESULT ok
eq "$(review_cell "$G")" "design review failed" "and the cell says which failed"

echo "== STUCK and settled stop it with the gate ==" >&2
reset_tasks; reset_caches; reset_logs; mode ok; vmode ok
pr_json "STUCK: no fit" OPEN true 3 100 20
G=$(mk_gated 050 stuck w1:p1)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_VISUAL)" "skipped" "a STUCK pull request gets no design review"
sleep 0.3
eq "$(vis_calls)" "0" "nothing launched"
pr_json "Do the thing" OPEN true 3 100 20

echo "== which files draw a screen ==" >&2
eq "$(draws app/models/plan.rb app/services/products/unlock_offer.rb app/controllers/x_controller.rb \
            app/presenters/current_subscriber_presenter.rb config/routes.rb db/migrate/1_add_x.rb db/schema.rb \
            spec/models/plan_spec.rb spec/components/x_component_spec.rb features/x.feature)" "0" \
  "models, services, controllers, presenters, routes, migrations and tests draw nothing"
for f in app/views/x/show.html.erb engines/e/app/components/e/x_component.rb app/components/x_component_controller.js \
         app/assets/stylesheets/a.scss app/frontend/packs/p.js app/helpers/price_helper.rb config/locales/en.yml \
         spec/components/previews/x_component_preview.rb test/components/previews/y_preview.rb \
         app/javascript/controllers/z_controller.ts public/logo.svg app/assets/images/a.png; do
  eq "$(draws "$f")" "1" "$f draws a screen"
done
eq "$(draws app/frontend/x.test.js app/components/__snapshots__/x.snap package-lock.json)" "0" \
  "a frontend test, a snapshot and a lockfile do not"
eq "$(jq -sr "$SCREEN_FILES_JQ" <<<"$(files_json app/models/a.rb) $(files_json app/views/a.html.erb)")" "1" \
  "every page is read"

echo "== a pull request that draws no screen gets no design review ==" >&2
reset_tasks; reset_caches; reset_logs; mode ok; vmode ok
files_json app/models/plan.rb app/services/products/unlock_offer.rb spec/models/plan_spec.rb > "$FILES"
G=$(mk_gated 070 backend w1:p1)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_REVIEW)" "running" "the code reviewer goes out as ever"
eq "$(st "$G" PQ_VISUAL)" "skipped" "the design review does not"
eq "$(st "$G" PQ_VISUAL_WHY)" "noscreen" "and why is kept"
has "$(cat "$PQ_HOME/.out")" "backend: no design review of #42 - it changes no file that draws a screen" "said"
grep -q 'pulls/42/files' "$GH_LOG" && ok || bad "decided off the pull request's own files"
wait_for test -f "$G/review.rc"
review_task "$G" 0 >"$PQ_HOME/.out" 2>&1
eq "$(st "$G" PQ_REVIEW)" "posted" "the code review is collected"
hasnt "$(cat "$PQ_HOME/.out")" "the follow-up waits for" "and nothing holds the follow-up"
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_REVIEW)" "prompted" "which goes out on the next tick, as for a task with no design"
P=$(prompt_text)
hasnt "$P" "design review" "and says nothing of a design review"
hasnt "$P" "Compare every screen you built" "nor asks for a comparison by hand"
sleep 0.3
eq "$(vis_calls)" "0" "no design reviewer was launched"
st_set "$G" PQ_REVIEW posted
eq "$(review_cell "$G")" "reviewed" "and the cell does not call it failed"

echo "== one that draws a screen still gets one ==" >&2
reset_tasks; reset_caches; reset_logs; mode sleep; vmode sleep
files_json app/models/plan.rb app/components/x_component.html.erb > "$FILES"
G=$(mk_gated 071 drawing w1:p1)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_VISUAL)" "running" "a template among the models: launched"
wait_for calls_at_least vis_calls 1 && ok || bad "the design reviewer ran"

echo "== files that cannot be read leave the review to run ==" >&2
reset_tasks; reset_caches; reset_logs; mode sleep; vmode sleep
G=$(mk_gated 072 unread w1:p1)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
review_task "$G" 0 >/dev/null 2>&1
grep -q 'pulls/42/files' "$GH_LOG" && ok || bad "the files were asked for"
eq "$(st "$G" PQ_VISUAL)" "running" "and, unread, the review launched as it always did"

echo "== a design task is always design-reviewed ==" >&2
reset_tasks; reset_caches; reset_logs; mode sleep; vmode sleep
files_json app/models/plan.rb > "$FILES"
G=$(mk_gated 073 designpr w1:p1 "" design)
set_panes "$(printf 'w1:p1\tclaude\tidle')"
review_task "$G" 0 >/dev/null 2>&1
eq "$(st "$G" PQ_VISUAL)" "running" "launched, whatever its files"
grep -q 'pulls/42/files' "$GH_LOG" && bad "without reading them" || ok

echo "== a dry run reads nothing ==" >&2
reset_tasks; reset_caches; reset_logs
files_json app/models/plan.rb > "$FILES"
G=$(mk_gated 074 dryrun w1:p1)
st_set "$G" PQ_REVIEW posted; st_set "$G" PQ_REVIEW_RESULT ok
set_panes "$(printf 'w1:p1\tclaude\tidle')"
out=$(review_task "$G" 1 2>&1)
has "$out" "would read #42's files and launch a design review of dryrun if one draws a screen" "says what it would do"
eq "$(st "$G" PQ_VISUAL)" "pending" "and changes nothing"
grep -q 'pulls/42/files' "$GH_LOG" && bad "nor calls the forge" || ok

echo "== pq ls --json carries it ==" >&2
reset_tasks; reset_caches
G=$(mk_gated 060 listed w1:p1)
st_set "$G" PQ_VISUAL "done"; st_set "$G" PQ_VISUAL_RESULT timeout
J=$(main ls --json 2>/dev/null)
eq "$(jq -r '.[] | select(.task == "listed") | .visual' <<<"$J")" "done" "--json carries visual"
eq "$(jq -r '.[] | select(.task == "listed") | .visual_result' <<<"$J")" "timeout" "and visual_result"

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
