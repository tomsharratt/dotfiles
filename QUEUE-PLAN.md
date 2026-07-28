# pq - a plan queue

Status: draft for iteration. Nothing built.

## What changed from the last draft

- The queue is **its own tool**, not `wt` subcommands. `wt` keeps owning worktrees and dev environments; `pq` owns plans and scheduling. They compose through one narrow seam.
- Plans come from **Claude Code's own plan mode**, not from a bespoke template. `pq add` takes what Claude wrote and prepends a settings header.
- **No reserved side lane.** Cap 3, and the fourth agent is simply you, working outside the queue whenever you want. Nothing to build.
- **Quota exhaustion is handled interactively**, not just avoided. When Claude asks whether to wait for the reset, `pq` answers, and re-prompts afterwards.
- **The cap is live state you can change or zero out mid-flight**, and the loop is safe to stop, restart, or run a manual tick alongside.
- Auto-park is gone entirely - the two-exits rule replaces it.

## The two tools and the seam

```
wt   worktrees + dev environments        already exists, stays as-is
pq   plans + queue + scheduling          new
```

`pq` needs exactly one thing from `wt`: *give me an isolated, provisioned worktree for this branch, don't take my focus, and tell me where it is.*

Today `cmd_new` also launches the agent and focuses the workspace, which is right for `prefix+t` and wrong for a 3am dispatch.
So the seam is one new flag combination on `wt`:

```
wt new --no-agent --no-focus [--no-dev] --json tom/live-chat-mentions
  → {"path":"...","workspace_id":"w14","root_pane_id":"p31","url":"https://...","port":3106}
```

`pq` then starts the agent itself, because `pq` is the thing that knows which model and effort this plan asked for.
Those flags are worth having in `wt` regardless - they are the honest separation between "prepare a worktree", "boot its dev server", and "start working in it".

**`pq` does not require `wt` in its own logic** - it shells out to it. If you ever want `pq` to drive a plain branch in the main checkout, that is a different provisioner behind the same seam.

### Do queued tasks need a dev server?

Worth deciding now rather than discovering at cap 4.
`wt new` currently provisions **and** boots the dev server.
On supercast at cap 3-4 that is three or four `pg_dump | psql` copies of the dev database and three or four foreman stacks - web, worker, css, js each.
You have only ever run this at one or two, hand-started.

Most plans are code-only and never touch the running app, so the proposal is a `dev:` header key **defaulting to `false`**:

- provisioning still runs, so the worktree has its own database and `wt run bin/rails test` / console work normally
- the foreman stack does not boot, which is the expensive, always-on part
- a plan that genuinely needs the app sets `dev: true`, and any agent can start it itself with `wt dev` if it turns out to need it

The one-time `pg_dump` is still paid per worktree. Whether *that* should also be skippable is open - it is what makes the isolated database exist, so skipping it means a task that runs tests fails in a confusing way.

## The plan file

Claude's plan mode writes `~/.claude/plans/<slug>.md`.
`pq add` copies that, unchanged, under a header:

```markdown
---
repo:     supercast
branch:   tom/live-chat-mentions
model:    sonnet
effort:   xhigh
priority: 20
intent:   >
  Make @-mentions in live chat resolve to member profiles, so hosts can
  reference attendees without pasting links. Covers the composer, the
  rendered message, and the notification that fires on being mentioned.
source:   ~/.claude/plans/floofy-hugging-dragonfly.md
added:    2026-07-27T09:12:00Z
---

# (Claude's plan, verbatim, from here down)
```

Defaults are **`sonnet` at `xhigh`**, overridable per plan (`opus`, `fable`; any effort level).

That pairing is the point of the whole split, and worth being explicit about: the plan session already did the expensive *thinking*, so the implementer does not need the expensive *model* - but it still benefits from real reasoning depth while executing. Sonnet at xhigh buys that at a fraction of a window.

**Header keys map to how the agent is launched, not to bespoke logic.**
That is what makes "some other parameters in the future" free:

| key | becomes |
|---|---|
| `model` | `claude --model sonnet` |
| `effort` | `claude --effort xhigh` |
| `claude_args` | appended to the command line verbatim |
| `settings` | written to a temp JSON and passed as `--settings` |

So anything Claude Code can be told on the command line or in a settings file is already expressible, and `pq` needs no change to support it.
`repo`, `branch`, `priority` and `dev` are the only keys `pq` interprets itself.

## `pq add`

```
pq add                      # the most recent plan in ~/.claude/plans/
pq add <path>               # a specific one
  --branch tom/foo          # see below - falls back to asking
  --model / --effort        # default: sonnet / xhigh
  --priority 20             # default: next multiple of 10
  --dev                     # boot the dev server for this one
  --hold                    # add it, but don't let tick pick it up yet
```

It **copies** rather than moves - `~/.claude/plans/` is Claude Code's directory and it prunes it.
The `source:` key keeps the trail back.

### Where the branch name comes from

Not the filename. Claude Code auto-names those, and your plans directory currently looks like:

```
floofy-hugging-dragonfly.md
a-recent-change-to-glimmering-turing.md
can-you-plan-out-twinkling-meerkat-agent-a0e9b3aa1d5ea3d4f.md
```

`tom/floofy-hugging-dragonfly` is not a branch you want on a pull request.
That third one also looks like a *subagent's* plan, which means bare `pq add` picking "the most recent file" can hand you something you did not author.

So `pq add` **asks Haiku**, from the plan itself, held to your convention - and gets the intent line out of the same call:

```
claude -p --model haiku --output-format json "Read this plan and return JSON:
  { \"branch\": \"tom/<3-5 dash-separated words describing the task>\",
    \"intent\":  \"<2-3 sentences: what this sets out to achieve, in the
                   author's terms - not a description of the diff>\" }" < plan.md
  → {"branch":"tom/live-chat-mentions","intent":"Make @-mentions in live chat..."}
```

One cheap call at add time rather than a guess at 3am, and it produces both things that need to read well to a human later: the branch on the PR, and the intent at the top of its description.
`--branch` always overrides, and `pq add` echoes both back so a bad one is caught while you are sitting there.

**`pq add` refuses a branch that already exists** - in `queue/`, `running/`, `done/`, or as a git branch in the repo.
This matters because `wt new` on an existing branch deliberately *checks it out* rather than failing, so without the guard two tasks could quietly land in the same worktree and fight over it.
Haiku returning the same name twice for two similar plans is exactly how that would happen.

## The queue on disk

```
~/.local/state/pq/
  queue/    020-live-chat-mentions/     waiting
  hold/     025-risky-refactor/         parked by you, tick ignores it
  running/  005-spotify-scope-fix/      dispatched
  done/     001-live-chat-links/        PR exists, slot freed
```

**A task is a directory, not a file:**

```
running/005-spotify-scope-fix/
  plan.md      header + Claude's plan, immutable once added
  state.env    KEY=VALUE runtime facts, appended as things happen
```

`state.env` uses exactly the pattern `wt` already uses for its worktree state - same shape, same `state_set` idea, proven and greppable:

```
PQ_BRANCH=tom/spotify-scope-fix
PQ_WORKTREE=/Users/tsharratt/.herdr/worktrees/supercast/tom-spotify-scope-fix
PQ_WORKSPACE=w14
PQ_PANE=p31
PQ_SESSION=941d1807-1681-4a91-89d3-30b7cc93f580   # not used by pq; kept so you can `claude --resume` by hand
PQ_CLAIMED=2026-07-27T02:13:01Z
PQ_LAUNCHED=2026-07-27T02:14:03Z
PQ_PR=6331
```

Splitting the immutable plan from the mutable state means the agent can re-read its plan at any point and never see it change underneath it.

**Priority is the numeric prefix, the slug is the identity.** `mv queue/030-live-chat-mentions queue/005-live-chat-mentions` promotes it, no command required.

But that means the number is *not* a stable handle - reprioritising changes it. So every command that names a task (`pq priority`, `pq retry`, `pq show`) takes the **slug**, or any unique prefix of it:

```
pq priority live-chat 5      # not `pq priority 020 5`
```

The number stays purely a sort key, and an ID you noted a minute ago never goes stale.

**State is which directory it is in**, and every transition is a `mv` - atomic on one filesystem, so an overlapping tick cannot dispatch the same plan twice. A failed move means another tick already claimed it.

## `pq tick`

One idempotent pass.

```
1. reconcile   for each running/ task, in order:
                 PR open?                    → mv to done/, slot freed
                 no PQ_LAUNCHED?             → incomplete dispatch, resume it (see below)
                 PQ_LAUNCHED but agent gone? → flag it (see below)
2. attend      for each running/ task whose agent is blocked → see quota handling
3. gate        over the usage threshold? → stop here, nothing new starts
4. fill        while active < cap: claim the lowest-numbered queue/ task
                 mv queue/NNN running/NNN                     ← atomic claim
                 record PQ_CLAIMED
                 wt new --no-agent --no-focus --json <branch> ← ~60s
                 record PQ_WORKTREE, PQ_WORKSPACE, PQ_PANE
                 herdr pane send-text <pane> "claude --model M --effort E '<prompt>'"
                 record PQ_LAUNCHED
```

Three notes:

- **`wt new` returning does not mean the worktree is ready.** Provisioning runs in a background tab, so `wt new --json` hands back a path and a port while the database copy is still 30-60 seconds from finishing. The agent is dispatched into a worktree that is still being built. For most plans that is fine - reading code and editing files needs nothing from the database - but a plan whose first act is `bin/rails test` can lose a race it will report as a broken checkout. Options when we get to phase 2: have the dispatch prompt tell the agent to expect it, or have `pq` wait for a readiness marker before sending the prompt. The existing failure signal is the herdr notification `wt` already raises.
- **"Agent gone" is three different things, and reconcile has to tell them apart.** `herdr agent list` reports only panes it has detected an agent in, so a pane missing from it can mean the agent crashed, *or* that Claude exited cleanly and dropped the pane to a shell, *or* that the session is still starting and its `SessionStart` hook has not reported yet. Phase 1's `pq ls` collapses all three to `gone`, which is fine when nothing dispatches, but reconcile would be deciding "this task is dead" on it. The discriminator is `herdr api snapshot`, which lists **all** panes rather than only agent-bearing ones: pane absent = the workspace is gone; pane present with no agent = the agent exited; recently dispatched with no agent yet = still starting, give it a grace period.
- **PR detection is `pq`'s own, not borrowed from `wt ls`.** It only ever asks about the handful of branches in `running/`, so it is one cheap `gh pr list --head <branch> --json state,number,isDraft --limit 1` each, run concurrently. It deliberately does not fetch `statusCheckRollup` - that is the field that makes `wt ls` slow, and a two-minute tick must not pay for it.
- **The plan is passed by path, never pasted into the pane.** The dispatch prompt is short and fixed:

  > Read `<path>/plan.md` and carry it out.
  >
  > Before opening a pull request, run `/code-review` on your diff and act on what it finds.
  >
  > Then commit, push, and open a PR whose description opens with the `intent` line from the plan header, followed by what you actually did.
  >
  > If you get stuck, or the plan turns out not to fit, commit what you have, push, and open a **draft** PR whose description explains what blocked you - then stop.
  >
  > Never wait for input.

  I have read "run `/code-review` when needed" as the agent's judgement call - it can skip it on a one-line copy change. If you meant *always*, that is one word in the prompt.

## Running the loop, and stopping it whenever you like

You will run `pq run` in a Herdr space rather than under launchd, so it inherits `HERDR_ENV` and `HERDR_SOCKET_PATH` for free.
(Launchd stays possible - verified that exporting just those two lets the Herdr CLI reach its server from a scrubbed environment - but it is no longer on the critical path.)

```
pq run [--interval 120] [--cap N]     tick, sleep, repeat. Ticks immediately on start.
pq tick                               a single pass, safe to run by hand at any time
```

**The cap is state, not an argument.**
It lives in `~/.local/state/pq/cap` and is re-read at the top of every tick, so:

```
pq cap 1      # daytime - one background task, plenty of quota left for you
pq cap 4      # going to bed
pq cap 0      # pause: nothing new starts, nothing running is touched
```

changes take effect on the next tick with no restart.
`--cap` on `pq run` just writes the file at startup.
This also means **pausing needs no separate concept** - `pq cap 0` is the pause, and it composes with everything else.

**Caps are soft, exactly as you described.** The fill step is `while active < cap`, so dropping 3 → 2 never kills anything; it simply starts nothing new until two slots are free again. There is no drain state and no bookkeeping for "over cap" - the arithmetic handles it.

**Stopping and restarting is safe by construction**, via three things:

1. **Ctrl-C finishes the work in flight, then stops.** The obstacle is that a terminal sends SIGINT to the whole foreground process group, so by default a `wt new` halfway through copying a database dies alongside the tick. The fix is to give that child a process group of its own - `set -m` does exactly this for a backgrounded job - after which the signal reaches only `pq`. The trap sets a stop flag, provisioning runs to completion, the dispatch finishes, and the loop exits. Verified by interrupting mid-provision: the child completed and the agent still started.

   A second Ctrl-C abandons it deliberately, killing the shielded child too - otherwise "force" would leave a `wt new` running with nobody left to record what it produced. The task keeps its claim without a launch record, which is exactly what reconcile resumes from.

   The same handler is installed for a one-shot `pq tick`, not just the loop: dispatch shields its child either way, so without it a Ctrl-C would kill `pq` and orphan the `wt new`.
2. **Every dispatch step is recorded as it completes.** The dangerous window is the ~60 seconds `wt new` takes: killed in there, you would otherwise leave a task sitting in `running/` with no agent, holding a slot forever. Instead, reconcile treats `running/` with no `PQ_LAUNCHED` as an **incomplete dispatch** and re-runs the dispatch from the top.

   This is safe for one specific reason, and it is worth being precise about it: **it only ever fires before an agent has been launched**, so there is no work in that worktree to lose. It is *not* safe because `wt new` is idempotent - it isn't. `wt new` backgrounds `wt provision`, and supercast's `wt_provision` **drops and recreates the database** on every run.

   Which gives a hard rule: **the post-launch failure case must never go back through `wt new`.** A `gone` task (agent died, work possibly on disk, no PR) is surfaced for you to look at, never silently re-dispatched - re-running provisioning under it would destroy the database its half-finished work depends on.

   Re-running `wt new` on a branch whose worktree already exists *is* now a supported route - it reopens rather than failing (phase 0 fixed this; it was broken). That is what makes incomplete-dispatch recovery work at all.
3. **One tick at a time.** An atomic `mkdir` lock (with a PID file, stale if the process is gone) stops two `pq run` loops - or a hand-run `pq tick` racing the loop - from both filling to cap and overshooting. The per-task `mv` claim already prevents the same plan being dispatched twice; the lock prevents *different* plans overshooting the cap. *Built in phase 2 rather than here: a tick that spends a minute inside `wt new` is racy the moment it exists, and phase 2 is when you start running it by hand.*

The net effect: stop it, start it, run a manual tick alongside it, kill the terminal - the queue converges on the next pass and no slot is ever silently lost.

## Opening a PR is the invariant

`pq` frees a slot on "a PR exists for this branch".
So an implementer that finishes cleanly and just stops has **deadlocked the queue** - done, idle, holding a slot until morning.
The success path needs an explicit exit exactly as much as the failure path does, which is why it is in the dispatch prompt above rather than left to each plan to remember.

The payoff is that the morning review sorts itself before you look:

| what you see | what it means |
|---|---|
| ready PR | shipped, review it |
| draft PR | got stuck, and the description says why |
| no PR, agent idle | the harness broke, not the task - this should be rare, and `pq ls` flags it |

## Quota handling

**Built. One layer, not two.**

The earlier draft had a second layer in front of this one: a gate that refused to *dispatch* while account usage was above a threshold, fed by side-writing `.rate_limits` out of the statusline.
That is dropped.
It decides when not to start work, which is not the problem - the problem is only that a walled agent never restarts itself.
A queued plan waiting an extra hour costs nothing; a gate that mis-reads a stale number and stalls the queue costs a night.

What the wall actually is, read out of the Claude Code binary rather than assumed:

- a 429 becomes `error: "rate_limit"`, which raises a dialog whose options are `{id:"wait", label:"Wait for limit to reset", hint:"Resets 8:00pm"}` alongside an adjust/upgrade entry
- every one of those handlers merely dismisses (`display:"skip"` / `value:"cancel"`) - **nothing schedules a resume**, which confirms the behaviour you described

So each tick reads the tail of every running agent's pane, and on the wall it dismisses, waits for the time the dialog names, and knocks until the agent moves again.

```
for each running task with an agent and no PR:
  herdr agent read <pane> --source visible   → last 30 lines
  hash the tail, compare with last tick
  classify:
    wall + tail unchanged → first sighting: Escape, record PQ_BLOCKED=quota,
                            wake at the "Resets ..." the dialog names (+60s),
                            or at now + PQ_QUOTA_RETRY if it names none
                            thereafter:     Escape + "Continue with what you were
                                            doing.", then every PQ_QUOTA_RETRY
    permission            → record PQ_BLOCKED=permission, touch nothing
    anything else         → clear, it is fine
```

Four properties, each chosen against the obvious alternative:

- **Detection is text, never Herdr's status.** The previous draft gated on `blocked` and flagged the risk that a walled pane might not report that way. It doesn't: `herdr agent explain` shows Herdr classifying from its own regexes over terminal regions, and its top rule (priority 1100, a braille spinner in the OSC title) outranks every `blocked` rule it has. A spinner is exactly what is on screen while the request that hit the wall is in flight. Claude Code *does* compute its own `{state:"blocked", needs:"rate limited - wait and retry"}` for this, but Herdr does not consume it.
- **Liveness is the tail's hash, not a status either.** Acting needs the wall showing *and* an unchanged tail. This cuts both ways: a working agent's tail moves constantly so a knock cannot interrupt one, and the wall's message lingers in the scrollback after recovery so the text alone would keep firing.
- **Escape, not an option.** There are at least two different limit dialogs in the binary with different option sets - one offers "Upgrade to Team plan" - so arrowing to the Nth entry bets on which one appeared. Escape is agnostic, and since every option only dismisses, it gives up nothing.
- **Wake at the time the dialog names; poll only as a fallback.** The hint is the best available source of that fact, because it comes from the error that walled us and so already names the right window - the account has two, and neither the statusline's numbers nor anything else on hand would say which one we are behind. Its format is fixed by Claude Code's `Jde()`: minutes omitted when zero (`8pm`), no date under 24 hours out (so a bare `1am` at 11pm is tomorrow), `Jul 28, 8:30pm` beyond that, plus a year only when it differs. All of those parse; anything else falls back to `PQ_QUOTA_RETRY` polling, as does a named time that turns out to have been optimistic. Waiting on an unparsed guess is the only outcome ruled out, since that strands a task silently where an early knock costs one instantly-failing call.

The wall is the only thing `pq` ever answers; a permission prompt is recorded and left, per the posture below.
After `PQ_QUOTA_MAX_TRIES` (40, ~7h) a task is marked `walled` and left alone rather than knocked at all night.

Tested end to end against a real Herdr pane with the real dialog text: first sighting records only, unchanged tail dismisses, the wake-up is scheduled from the named reset time and falls back to polling when the dialog names none, the knock lands in the pane, a moving tail is left alone, a permission prompt is classified and untouched, and clearing the wall text logs the recovery.
The reset parser is checked against every form `Jde()` can emit, including the day-rollover and across-new-year cases.
**A genuine 429 has not been through it** - that path cannot be provoked on demand.

## Permission posture

Queued agents run in **auto mode**, the same as everything else - no stricter overlay, nothing special.
If one hits a permission check it simply goes `blocked`, holds its slot, and waits for you to unblock it in the morning.

That is a deliberate trade and worth stating plainly: **a permission stop at midnight costs a slot until you wake up.** At cap 3, two of them means you spend the night running at one.

Two things make it an acceptable trade rather than a hole:

- auto mode already approves the ordinary things, so a stop should be genuinely unusual - and when it happens it is exactly the sort of thing you would want to look at rather than have approved on your behalf while asleep
- `pq ls` distinguishes `blocked (permission)` from `blocked (quota)`, so the morning triage is "these two need a decision from me" rather than a pile of stalled panes to work out

If it turns out to bite more than expected, the cheap lever is a per-plan `settings` overlay in the header for plans you know will touch something awkward - not a blanket loosening.

## `pq ls`

```
ID   STATUS   BRANCH                   MODEL   EFFORT  AGENT         PR           AGE
005  running  tom/spotify-scope-fix    sonnet  xhigh   working       -            41m
008  running  tom/premiere-copy        sonnet  xhigh   quota→6:30am  -            12m
011  running  tom/stripe-webhook-fix   sonnet  xhigh   permission    -            5h    ← needs you
012  running  tom/feed-dedupe          sonnet  xhigh   gone          -            3h    ← died, no PR
020  queued   tom/live-chat-mentions   sonnet  xhigh   -             -            2h
025  held     tom/risky-refactor       opus    xhigh   -             -            2h
001  done     tom/live-chat-links      sonnet  xhigh   -             #6327 ready  1d

cap 3 · 3 running (1 needs you) · usage 41% (resets 6:30am)
```

The AGENT column is the whole point of the morning read: `permission` and `gone` are the two that want you, `quota→` is handling itself.

Joined from the directory (status), `state.env` (facts), `herdr api snapshot` (live agent status), and `gh` (PR).
`--json` from day one, since this is the thing you will want to ask questions of.

## What `pq` never does

Worth stating as a rule, because it is what makes an unattended tool safe to leave running:

- tears down its own tasks, and only after a merge it verified against the forge - it never touches a worktree it did not create, and reclaiming anything else stays `wt gc`, driven by you
- never merges or closes a PR
- never force-pushes
- never answers a prompt it does not recognise

`pq` creates worktrees, tears down the ones it created once their PR has genuinely merged, and moves its own files. That is the whole blast radius.

## Changes needed in `wt`

Small, and all defensible on their own merits:

1. **`--no-agent`, `--no-focus` and `--no-dev` on `wt new`, plus `--json` output.** The seam. Focus-stealing at 3am is the immediate reason, but separating "prepare a worktree" from "boot its dev server" from "start working in it" is right anyway.
2. **`alloc_redis` ignores `WT_REDIS_MAX`** (`wt:212` hardcodes `seq 1 15`). `supercast.sh` sets it to 14 to reserve db 15 for the spec suite, and nothing reads it. Harmless at 4 worktrees; a queue churning through many will eventually hand out db 15 and collide with the spec suite - and it will look like flaky tests, not a `wt` bug. Fix before any batching.

`wt ls --json` is no longer needed for this - `pq` does its own PR lookups. Still nice to have, but it is not on the critical path any more.

## Build order

| phase | what | why here |
|---|---|---|
| 0 | ~~`wt` redis fix + `--no-agent/--no-focus/--no-dev/--json`~~ **done** | the seam, and a real bug |
| 1 | ~~`pq add`, `pq ls`, directories~~ **done** | get plans into the queue by hand and look at them; no dispatch yet |
| 2 | ~~`pq tick` - claim, dispatch, reconcile - cap 1, run by hand~~ **done** (took the lock with it) | prove atomic claim and slot accounting while watching |
| 3 | ~~`pq run` loop + cap file + SIGINT trap~~ **done** | the stop/start/restart safety you asked for |
| 4 | ~~usage.json side-write + dispatch gate~~ **dropped** | deciding when *not* to start was never the problem |
| 5 | ~~wall detection + knock until it moves~~ **done** | the last mile of unattended |
| 6 | `after:` dependencies for epics | only when an epic actually needs it |

Phase 2 is the checkpoint. If claim-and-dispatch is not boringly reliable at cap 1, nothing above it matters.

Phase 3 has its own test worth doing deliberately: kill `pq run` *during* a `wt new`, then restart it, and confirm the half-dispatched task recovers rather than sitting in `running/` holding a slot. That is the failure this phase exists to prevent, and it is easy to check on purpose and painful to discover at 4am.

Phase 5's two open questions were answered by reading the Claude Code binary and `herdr agent explain` rather than by waiting to hit the wall: the dialog's exact options and the fact that none of them resume, and that Herdr's status cannot be trusted as the trigger. Both are written up under Quota handling, and the design changed because of the second.

## Settled

- **Name:** `pq`.
- **Header knobs:** `model` (sonnet / opus / fable) and `effort`, defaulting to **sonnet / xhigh**.
- **Driver:** `pq run` in a Herdr space, not launchd. Cap is live-editable state; stop and restart freely.
- **No reserved side lane.** Cap 3 by default leaves you a fourth agent to use ad-hoc, outside the queue entirely.
- **Usage numbers:** not used. `pq` never decides when to start based on quota - it only restarts what the wall stopped.
- **Dispatch hours:** not needed as a concept. `pq cap` covers it, and one mechanism beats two.
- **Branch names:** generated by Haiku at `pq add` time, in the form `tom/<3-5 words>`, `--branch` overriding.
- **Permissions:** auto mode, same as everything else. A permission stop is a `blocked` agent that waits for you.
- **Gate:** no `no-mistakes`. The implementer runs `/code-review` on its own diff before opening the PR.
- **PR description:** opens with the `intent` line from the header, not the whole plan.
- **Into the queue:** manual `pq add`. The approval step stays explicit.

## Still open

All minor, none blocking.

1. **Should `pq` notify you?** `herdr notification show` is right there and `wt` already uses it. My lean: nothing per-event overnight, one summary when you first run `pq ls` in the morning, or a single notification when the queue drains. Per-event pings at 3am help nobody.

2. **A task whose agent died with no PR** (the `gone` row). My lean: leave it, flag it, add `pq retry <slug>` you trigger deliberately. Auto-retry is convenient overnight and also how a reliably-crashing plan burns a slot all night - and re-dispatch has to avoid `wt new`, since re-provisioning would drop the database under whatever work is on disk.

3. **Should provisioning itself be skippable**, not just the dev server? Makes dispatch near-instant, at the cost of a confusing failure for any plan that runs tests. Worth waiting until you see how slow dispatch actually feels.

4. **May `pq` assume `wt` is installed?** I have assumed yes - the separation you want reads as conceptual (two tools, two files, each understandable alone) rather than `pq` needing to run where `wt` doesn't exist. Say if not, and a fallback provisioner goes behind the same seam.
