# dotfiles

## About

Personal dotfiles for macOS. Manages:

- `~/.config/nvim` - Neovim config.
- `~/.config/ghostty` - Ghostty terminal config.
- `~/.config/tmux` - tmux config (Rose Pine theme; splits inherit the pane's directory).
- `~/.config/herdr` - Herdr config: the theme and the `prefix+t` worktree keybinding. Only `config.toml` is tracked; Herdr's sockets, logs, and session state are excluded from sync.
- `~/.local/bin/wt` - worktree workflow backend: creates an isolated worktree (its own database, redis db, url and port) through Herdr, provisions it, and starts the dev server + Claude on it. Project-agnostic; the per-project steps live in profiles.
- `~/.config/wt/profiles/<repo>.sh` - per-project provisioning + dev-server steps for `wt` (e.g. `supercast.sh`, `supercast-ios.sh`, `supercast-android.sh`).
- `~/.local/bin/pq` - plan queue: holds Claude Code plans and runs them as unattended implementer sessions, one worktree each, via `wt`.
- `~/.claude/settings.json` - Claude Code settings. Agent status now comes from Herdr's built-in Claude integration (`herdr integration install claude`), which installs a `SessionStart` hook. Git-tracked for reference but applied manually - `install.sh` does not touch `~/.claude`.
- `AGENTS.md` - global agent instructions, read by Claude Code via the `~/.claude/CLAUDE.md` symlink (mirrors `~/AGENTS.md`). Git-tracked for reference but applied manually - the sync scripts don't touch it.
- Hack Nerd Font.

This repo keeps my personal configuration files - shell, editor, and tool configs - under version control, so the setup can be tracked over time and reused across machines.

### Worktree workflow (Herdr)

Agent work runs inside [Herdr](https://herdr.dev), a terminal workspace manager for AI coding agents.
Herdr provides, as first-class features, the two things this repo previously hand-built in tmux:

**Claude session status.**
`herdr integration install claude` wires a `SessionStart` hook that reports each Claude session (and its transcript) to Herdr, which then tracks every agent as working / blocked / idle in its sidebar.
This replaces the old `claude-tmux-signal` + window-glyph machinery (now removed).
Because Herdr owns the pane-to-agent binding itself, rather than inferring the window from `$TMUX_PANE` and racing on tmux options, it does not suffer the flakiness the tmux version had.
The trade-off: status is shown only for agents running inside a Herdr pane.

**Worktrees with full isolation.**
`wt` (bound to `prefix+t` in `~/.config/herdr/config.toml`) creates a worktree through Herdr and runs it isolated, so several branches can be developed and tested at the same time.
`wt new <name>` forks a branch off the up-to-date default branch, opens it as a Herdr workspace, provisions it, then starts Claude in the workspace's main pane and the dev server in its own `dev` tab.

Isolation is per project, described by a *profile*.
`wt` itself is project-agnostic: it resolves the branch, allocates a free port and redis db index, and calls the profile's steps.
Profiles are discovered at `<repo>/.wt/profile.sh` (committed with the project) or `~/.config/wt/profiles/<repo>.sh` (personal, tracked here).
A profile declares which resources to allocate and defines `wt_provision`, `wt_dev`, `wt_open`, and `wt_teardown`.
A repo with no profile still gets a worktree + Claude - it just has no dev server.

For `supercast` (`~/.config/wt/profiles/supercast.sh`) each worktree gets:

- its own postgres database - a logical copy of `supercast-web_development`, so migrations and data changes never touch the shared dev db or the other worktrees;
- its own redis db index, so Sidekiq queues don't collide;
- its own puma-dev url `https://<name>.test` on its own port.

So `wt new premier-video` and `wt new spotify-reconcile` can run side by side, each serving its own url against its own database, with no handoff between them.
The app needs no changes for this: its `database.yml`, `sidekiq.rb`, and `development.rb`/`session_store.rb` already honor `DATABASE_URL` / `REDIS_URL` / `LOCAL_DOMAIN`, and `config.hosts.clear` allows any `*.test` host.
The profile injects the port by generating a per-worktree Procfile (the tracked `Procfile.dev` pins the web port to 3000), written outside the repo so the checkout stays clean.

For the two mobile repos (`~/.config/wt/profiles/supercast-ios.sh`, `supercast-android.sh`) there is nothing to isolate per worktree, because both apps build a fixed bundle id/applicationId - a second install on the same device just replaces the first.
So instead of per-worktree isolation, each profile targets the one shared simulator or emulator, and the last `wt open` wins: it builds that worktree's branch, installs it, and launches it, so "look at this branch on a device" is a single command, and rerunning it is the reload.
There is no *device* lifecycle tied to a worktree, so neither profile ever creates or removes a simulator/emulator on `wt new`/`wt rm`.
supercast-android has nothing else to reclaim either, so it defines no `wt_teardown`/`wt_sweep` at all; supercast-ios still builds into a per-worktree DerivedData directory, so it keeps both, purely to free that disk space.
Since there's no bundler or watcher to keep running, the dev tab for a mobile worktree is instead a stream of that app's device logs, which keeps working across every later `wt open`.
Both apps are thin Hotwire native shells that point at the canonical `https://app.supercast.test`, not at a per-worktree backend, so the canonical Rails app needs to actually be running for either to show real content - `wt open` warns, but does not fail, when it isn't.

Commands:

```
wt new [name]        create/open an isolated worktree, provision, start dev + Claude
wt dev  <path>       run a worktree's dev server (this is the dev pane's command)
wt run  [cmd...]     run a command with the worktree's isolated env loaded
wt open [name]       open the worktree's dev url in the browser, or hand the
                     command to the profile's own open action (build, install
                     and launch on a device) when it defines one instead of a url
                     (the mobile profiles' own open action accepts --launch-only/
                     -l to skip the build and just relaunch - this is a convention
                     of those two profiles, not a flag `wt` itself parses)
wt provision <path>  re-run provisioning for a worktree (idempotent)
wt rm  [-y] [name]   tear a worktree down (drop db, free port, remove worktree)
wt ls                list worktrees with their allocated port / redis / url / db
wt gc                reclaim resources from worktrees removed outside wt rm
```

`wt new` layers three things on top of "prepare a worktree", and each can be dropped so the command can be driven by a script rather than by `prefix+t`:

```
--no-agent   don't start Claude in the root pane
--no-dev     provision, but don't boot the dev server
--no-focus   leave focus where it is
--json       print the worktree's facts (path, pane ids, port, url) to stdout
```

Human-facing output always goes to stderr, so `--json` leaves stdout clean for a caller to parse.
`--no-dev` deliberately still provisions: the dev server is four long-running foreman processes, while provisioning is the one-off that creates the isolated database - skip that too and `wt run bin/rails test` inside the worktree fails confusingly.

### Plan queue (`pq`)

`pq` is a queue of Claude Code plans waiting to be run as implementer sessions, built on top of `wt` but separable from it.
The split it exists to make: one long-lived session, in plan mode, does the thinking and produces a plan that has already answered every question; `pq` then runs those plans later, unattended, several at a time, as cheap implementer sessions that only have to execute.

A task is a directory, and the directory it sits in is its state - `queue/`, `hold/`, `running/`, `done/`, `archive/` under `~/.local/state/pq`.
Every transition is a `mv`, which is atomic within a filesystem, so two dispatchers cannot claim the same task.
Each task holds an immutable `plan.md` (a settings header prepended to whatever Claude Code wrote) and a `state.env` of runtime facts, so an agent can re-read its plan at any point and never see it change underneath it.

`pq add` with no plan, at a terminal, shows the ten most recently touched plans in `~/.claude/plans` - `n` and `p` page back through the older ones - and lets you pick one rather than silently guessing.
See "Picking a plan" below.
Either way, it then asks Haiku for a branch name and a one-line statement of intent (Claude Code auto-names plan files, so the filename is never a usable branch), and refuses a branch that is already spoken for - `wt new` checks out an existing branch rather than failing, so two tasks sharing a name would quietly land in the same worktree.

Each task records its own project, so one queue serves all of them.
The project is wherever you were standing when you added the plan, resolved to the main checkout so adding from inside a worktree still queues against the repo the new worktree gets forked from; `--repo PATH` sets it explicitly.
Dispatch runs `wt new` in that repo, which picks up its profile, and everything downstream is per-task from there - `pq ls` grows a `PROJECT` column as soon as the queue holds more than one.
Branch *lookups* are keyed on the repo as well as the name, but a task's slug is a single global namespace, so two live tasks can never share a branch leaf even across two different projects - `tom/fix-timezone` cannot be queued in both at once.

```
pq add [plan]            add a plan to the queue (no plan, at a terminal: pick one)
pq add --urgent          allocate from a reserved range, ahead of every real date
pq add --after T         repeatable, at add time: don't dispatch until T's PR has merged
pq add --repo PATH       repeatable, only with --split/--split-dir: name the repos a split may use
pq add --split           split a plan into a stack of standalone parts, wired with --after
pq add --split-dir D     queue an already-split directory, skipping the split step
pq after <task>          list a task's blockers and what each is waiting on
pq after <task> T...     add blockers to a task still in queue/ or hold/
pq after <task> --clear  drop them all
pq ls [--all] [--json]   every task, its state, and what it is waiting on
pq show <task>           one task's header and plan
pq tick [--cap N]        free finished slots, then fill them from the queue
pq run [--interval S]    tick on an interval until you stop it
pq cap [N]               how many may run at once; 0 pauses
pq urgent <task>         move it to the very front of the queue
pq later <task>          move it to the very back of the queue
pq hold / unhold         park a task, or put it back
pq rm <task>             drop a task (never touches a worktree or a branch)
pq archive <task>        file a done task away by hand (done only)
```

The fourteen-digit prefix on a task directory is a UTC timestamp and nothing else - promoting a task (`pq urgent`, `pq later`) renames its directory, so commands take the task's slug, or any unique prefix of it.

#### Picking a plan

A bare `pq add` at a terminal shows the ten most recently touched plans in `~/.claude/plans`, each with its age and its title - the first `# H1` in the file, since Claude Code names the file itself from your opening prompt and that name is rarely what the plan is actually about.
"Most recently touched" means whichever is newer, mtime or birth time, so a plan edited this morning outranks one merely created today, and a plan restored by `cp -p`, `rsync -a`, or a git checkout doesn't fall to the bottom on a stale mtime.

Ten is a page, not a limit.
`n` pages back to older plans and `p` pages forward again, and the header says where you are - `11-20 of 47 (page 2/5)`.
The keys are offered only when there is more than one page, and paging past either end says so rather than doing nothing.
`PQ_PICK_LIMIT` sets the page size.

Row numbers are absolute: row 11 is the eleventh-newest plan whichever page you are looking at, so a number always means the same plan and any listed row can be picked from any page.
Pick a number - Enter takes the top row of the page you are on, which is the most recent plan on page one - and it previews the plan before asking `use this plan? [y/N]`; answering `n` returns to the number prompt, on the page you were reading, rather than aborting the whole command.
That `n` is "no", not "next page" - the two prompts read the key differently, and each one's hint says which is in force.
Once you confirm, it asks the two things that actually shape how a task runs: whether to split it into a stack of small PRs, and which of the tasks already queued, held, or running it should wait on.

Passing a flag the wizard would otherwise ask about skips just that one question - `pq add --split` picks a plan and skips straight past the split question (it still asks about blockers), `pq add --after some-task` picks a plan and skips straight past the blocker question (it still asks about splitting).

`-y` and no tty (a script, a cron run, an agent) skip the picker altogether and take the newest plan without asking anything - exactly what `pq add` has always done.
A plan path given explicitly skips the picker too, but uses exactly that plan rather than the newest one - also unchanged from before.

#### Order

The queue is add-order, oldest first - a task's position is exactly when it was added, nothing more.
`--urgent` allocates from a reserved range below any real date, so an urgent task always sorts ahead of every ordinary one.
Two urgent tasks are still ordered oldest first between themselves, by the order they were made urgent.
`pq urgent <task>` and `pq later <task>` are the only two moves - "do this next" and "not yet".
There is no number to slot between two tasks, because plans are added in the order they should run, so there was never anything to insert between them.
The fourteen-digit prefix is a fixed-width UTC timestamp, which is what makes bash's own glob order agree with numeric order - `pq ls` and the queue's actual dispatch order are the same order, as long as every task directory carries that prefix.
A lingering directory from before this scheme won't - that is what the one-time migration is for.

#### Blockers

Large work wants to be split into several small plans, each a reviewable PR, where the second usually cannot start until the first has shipped.
`pq add B --after A` (or `pq after B A` once both are queued) says exactly that: B is not eligible for dispatch until A's PR has merged into A's repo's default branch.

Blocked is derived, not stored - a blocked task sits in `queue/` like any other and fill just skips it, the same way the cap is soft arithmetic rather than a drain state.
A task's blockers live in a third file, `after`, alongside `plan.md` and `state.env`: one blocker per line, `label<TAB>repo<TAB>branch`.
A blocker is a resolved `(label, repo, branch)` triple, not a task reference - it is captured at the moment you type it, so it survives `pq rm A`, survives A ageing out of `done/`, and survives a slug being reused.
That is also what makes a cross-repo blocker work for free, and lets a blocker name a branch that was never added to `pq` at all.

Merge state comes from the forge, never from git ancestry: a squash-merged branch's tip is not an ancestor of its default branch, so `git branch --merged` misses every real merge.
`pq` asks `gh` instead, and only trusts a `MERGED` pull request whose base is genuinely the repo's default branch - merged into some other branch does not count.

`pq add` prints the new task's slug on stdout - everything else it prints is for a human, on stderr - which is what makes chaining a one-liner:

```
a=$(pq add planA.md)
b=$(pq add planB.md --after "$a")
c=$(pq add planC.md --after "$b")
```

`pq after <task>` answers "why has this not started": per blocker, both the state of the task that owns the branch and the state of its pull request, since either one can be the reason and the fix differs.
A blocker that has already merged is fine to add - `pq` says so rather than refusing.
Self-reference and cycles are rejected at the moment you try to create them.

Three situations short-circuit the ordinary wait and warn once, because they read as healthy waiting until you look closer: a **dead** blocker (every pull request for it is closed), an **orphan** (nothing owns that branch, so nothing will ever open one), and a **stalled** chain (the owning task already reached `done` with only a draft PR open - a stuck agent, not a chain in review).
None of the three auto-holds anything; fill already costs no slot on a blocked task, and `pq` does not re-order your work on its own judgement.

`pq tick` is one idempotent pass: reconcile, then fill.
Reconcile runs first so a task that shipped leaves the queue promptly - any pull request, in any state, means the work is out of `queue`'s hands.
Leaving the queue and giving up the slot are separate things, though: see the cap below, which keeps counting a task whose agent is still working on its PR.
Fill claims a task by moving it to `running/` *before* calling `wt new`, because that call takes the better part of a minute and an unclaimed task is one a second tick would happily pick up too.
Each dispatch step records itself as it succeeds, so an interrupted tick is resumed rather than restarted - and resuming deliberately skips `wt new` when the pane is still there, since re-provisioning would drop the worktree's database.
A `mkdir` lock keeps two ticks from both filling to cap.

`pq tick --dry-run` shows what it would do and changes nothing.

`pq run` sits in a Herdr space and ticks on an interval, so it inherits the socket and you can watch it.
It prints a summary only when one differs from the last, so an idle night leaves a log of what changed rather than a line per interval.

The cap is **state, not an argument**: it lives in a file that is re-read at the top of every tick, so `pq cap 1` in the morning and `pq cap 4` at bedtime take effect on the next pass with no restart.
`pq cap 0` is the pause, which is why pausing needs no separate concept.
Caps are soft - lowering one never kills anything, it just starts nothing new until enough slots free up.
The default is 1, deliberately: a fresh machine should not start dispatching several unattended agents because nobody had said otherwise yet.

What the cap counts is **live agents, not directories**.
Those are the same number only while "has a pull request" means "has stopped working", and it does not: a Claude Code agent that opens a PR keeps going - answering review, fixing CI, pushing again - and never exits on its own.
So a task that reconcile has already moved to `done/` goes on spending its slot until its agent is actually finished, and `pq ls` marks it **wrapping up** while it does.
Counting only `running/` is what once ran six agents at a cap of 3, three fresh ones alongside three still wrapping up, and reported it as "3 running".

The release has to be a timer rather than an exit, because an agent that has genuinely finished sits idle indefinitely instead of exiting - so waiting for one to disappear would stall the queue outright rather than merely overshoot it.
`PQ_WRAPUP_GRACE` (default 300s) is that timer: once an agent has not been working for that long, its slot goes.
It governs the tasks whose PR is still open or in draft; a task whose PR has *merged* gets torn down by the reap pass as soon as its agent stops, and a torn-down task releases its slot at once with no grace at all.
The grace applies to `idle` and to herdr's `done` alike, because both are per-turn rather than per-task: an agent that opens a PR and then goes back in to fix CI passes through them between every turn, and releasing on the first sighting would be the same bug in a subtler form.
A `blocked` agent - a permission prompt, a quota wall - holds its slot too, the same trade `running/` already makes, since it will resume rather than having finished.
That row reads as **permission** or **quota 8:30pm** rather than "wrapping up", and a permission prompt counts into "needs you": it is holding a slot until you answer it.
A quota wall does not, because `pq` answers that one itself, on a `done/` pane as readily as on a running one.
Note that a dismissed wall reads as `idle` to herdr - dismissing the dialog is what stops the spinner - so `pq`'s own verdict is what holds that slot, or the grace below would hand it away while the agent waits for its window and then take it back on the tick the agent resumes.
An exited agent or a vanished workspace releases immediately, with no grace at all, and while herdr is unreachable the slot is held rather than guessed at.
Setting `PQ_WRAPUP_GRACE=0` restores the old release-on-PR behaviour.

The other reason the queue can sit still with slots apparently free is that **a wall anywhere stops dispatch entirely**.
Every agent `pq` runs draws on one account-wide usage window, so a second agent started behind the wall does not get an allowance of its own: it walls on its first request, having spent a minute of `wt new`, a database, a port and a puma-dev entry to get there, and it arrives with its own knock cycle to run.
So fill starts nothing at all until whoever is walled is moving again, and both the tick summary and `pq cap` say so rather than reporting room that will not be used.
It takes a *live* agent to freeze anything: a task whose Claude has exited, or whose workspace is gone, holds nothing up, however much of the wall is still legible on its pane.
Nor does one `pq` has given up knocking on - see the session limit section for why that bound matters.

Ctrl-C is a graceful shutdown: during the sleep it stops immediately, and during a tick it lets the work in flight finish first.
That needs a little care, because a terminal signals the whole foreground process group - so by default a `wt new` halfway through copying a database would die alongside the tick.
`pq` gives that child a process group of its own, which leaves the signal going only where it should: provisioning completes, the dispatch finishes, and then the loop exits.

A second Ctrl-C abandons the work in flight, killing that child too, so "force" does not leave a `wt new` running with nobody to record what it produced.
Either way nothing is lost - a task caught mid-dispatch keeps its claim without a launch record, which the next reconcile recognises and resumes.

#### Splitting a large plan

A plan-mode session naturally produces a plan for a whole feature, but a whole feature is almost never one pull request worth reviewing.
`pq add plan.md --split` runs one Opus session that reads the plan, decides where the real seams are, and writes one standalone plan per part plus a dependency graph - then queues every part through the ordinary `pq add` path, with `--after` already wired from the graph.
The result is a stack of small, individually reviewable PRs where nothing downstream starts until you have merged what it depends on, and a plan that turns out to be wrong is wrong for one PR rather than for a whole night.

The load-bearing constraint is that parts wait for merges, never for branches - no part is ever built on top of a sibling's branch.
Each part starts from the default branch with its declared dependencies already merged, and every part is written for an agent that sees only that one file: it never mentions another part, its filename, or its branch.
`pq` validates this before anything is queued - full coverage of the original plan, no missing or forgotten parts, no cycles, and no part referencing a sibling by name - and refuses to queue anything if a check fails.

The split artifacts land in `$PQ_HOME/splits/<plan>-<stamp>-<pid>/`: the source plan, one `NN-short-slug.md` per part, and `graph.tsv` recording which parts must merge before which others.
Before queueing anything, `pq` shows a table of the parts, their wave (how many merges deep they are), their branch, and what each waits on, then asks to confirm - `-y` skips the prompt, but `--json` does not, so a caller after machine-readable output never gets tasks queued unlooked-at.
Declining leaves the split directory on disk and costs nothing: `pq add --split-dir <dir>` resumes from it later, without paying for the Opus session again, which is what makes hand-editing a part before it ships a first-class path.

`--after` on the split itself only applies to the root parts - the ones with no dependency inside the split - since `pq after`'s own reporting already surfaces the rest of the chain to anyone asking why a downstream part hasn't started.

A plan that names more than one checkout - a mobile feature spanning the Rails monolith and the iOS app, say - gets its parts assigned across repositories instead of forced into one.
The splitter is shown every git checkout sitting alongside the primary, or under `PQ_REPOS_DIR` if you'd rather point it somewhere else, and told to use the primary unless the plan clearly places some of the work elsewhere - it never assigns a part to a repository the plan doesn't talk about.
A part belongs to exactly one repository, because a part is one pull request; work that genuinely spans two repositories is two parts, wired with an ordinary `--after` the same way an intra-repo dependency is - a client part waiting on the server part it needs is just that edge crossing a repo boundary.
`--repo PATH` is repeatable and is the escape hatch for the discovery, not the normal path: passing it once still lets the scan contribute, which is how you fix a wrong cwd without silently turning multi-repo splitting off, and only passing it two or more times narrows the set to exactly those repos.
`-y` accepts the splitter's repo assignment sight unseen - the confirmation table, which grows a `REPO` column once a split actually spans more than one repository, always prints to stderr before that early return, so it is the audit trail even when nothing pauses to ask.

Running `pq add --split` from `~/projects` itself - a directory that holds several checkouts but is not a checkout of anything - works the same way in reverse: instead of scanning the primary's siblings, `pq` discovers `~/projects`' own immediate children that are git repositories and offers those as the candidate set.
There is no primary in that case, deliberately: nothing among a container's children is privileged as a default the splitter can fall back into, so every part's repository assignment becomes required rather than optional, and a part left unassigned fails validation instead of silently landing wherever the primary would have been.
The same `--repo PATH` naming a directory instead of a checkout triggers this from anywhere, not only from inside the container itself.

#### Hitting the session limit

When a Claude session runs out of its usage window it says so on the pane - "You've hit your session limit · resets 3pm (PDT)" - and puts up a dialog whose every option only dismisses it.
Nothing resumes by itself, so an agent that hits the wall at 2am would otherwise sit there until morning holding a slot.
Each tick reads the last lines of every dispatched agent's pane, and when it finds the wall it dismisses the dialog, waits for the time the message names, and then knocks with "Continue with what you were doing" until the agent picks its work back up.
Agents wrapping up in `done/` are read the same way as running ones: that is where an unattended agent spends most of the night, answering review and fixing CI, and it can hit the wall there just as easily.

Four details make that safe to leave running unattended.

**Detection is the pane's text, not Herdr's status.**
Herdr derives agent status from its own regexes over the terminal, and its highest-priority rule reads a spinner in the window title as `working` - which is exactly what is on screen while the request that hit the wall is still in flight.
Waiting for Herdr to say `blocked` would risk never firing at all.
The read is `herdr pane read` rather than `herdr agent read`, because the wall has to stay detectable on a pane whose agent binding has lapsed, and only the first of those answers for one.

**Only a screen that has stopped moving counts as stuck.**
`pq` hashes the tail each tick and acts only when the wall is showing *and* the hash is unchanged since last time.
A working agent's tail moves every few seconds, so this cannot interrupt one.

**Once the wall has been seen, the schedule is `pq`'s own.**
That message is live UI, not transcript text: Claude Code derives it from the reset time it is waiting for, so it clears *itself* at the reset - which is the exact moment the knock comes due.
Treating "the wall is no longer on screen" as recovery therefore threw the plan away at the one moment it mattered.
So the text only ever puts the block *on*; from there the stored reset time decides, and what is on screen decides nothing until the knock is due.

What takes the block off is evidence the agent is moving again, and that needs two things rather than one: a tail that has changed **and** Herdr calling the pane `working`.
A changed tail alone is not enough, because a statusline reporting rate limits sits inside the tail and turns over at the reset all by itself - a one-tick change landing at precisely the moment the knock is due, indistinguishable from the agent resuming, and believing it would clear the block on an idle agent and strand it.
That is not a retreat from the first rule above: that one governs detection, where the spinner makes `working` unreliable; by the time a knock is due the dialog is long dismissed and nothing is in flight.
An agent you rescue yourself is believed straight away, clock or no clock, since a block still on file is a block that freezes the queue.

**It waits for the time the message names, and polls only when it cannot read one.**
The wall's own line carries "resets 3pm", and that hint beats any other source of the same fact, because it comes from the error that walled us and so already refers to the right window - the account has both a five-hour and a weekly limit, and nothing else on hand would say which one you are behind.
A statusline that reports rate limits carries a "resets" of its own, and it is only ever the fallback, since it always names the five-hour window even when the weekly one is what walled you.
Two habits of Claude Code's formatter are worth knowing, since both will catch out anything that assumes otherwise: minutes are dropped when they are zero, so it reads `8pm` rather than `8:00pm`, and no date is printed for a reset less than 24 hours out, so a bare `1am` seen at 11pm means tomorrow.
Beyond 24 hours it becomes `Jul 28, 8:30pm`, gaining a year only when the year differs.
What is *stored* is the epoch, and `pq ls` formats it back on the way out - state files are read by sourcing them, so a value like `3pm (PDT)` is a syntax error that silently truncates everything written after it.

A hint that cannot be read is not a failure: ten-minute polling is the fallback, and it also takes over if the knock at the named time turns out to be too early.
The one outcome ruled out is waiting on a guess, because that strands a task silently, where an early knock costs a single instantly-failing call.

The wall is the only thing `pq` ever answers.
A permission prompt is recorded as `permission` and deliberately left alone - that is the trade for running everything in auto mode - so `pq ls` separates the agents waiting on the clock from the ones waiting on you.
One appearing where a wall was is taken as recovery, because a session asking for something is a session running again, and the alternative is a knock sending Escape at the prompt - refusing it - every ten minutes.
After forty unanswered knocks a task is marked `walled` and left, rather than knocking all night - and at that point it stops freezing dispatch, which is the only bound on how long a freeze can last.
It wants one, because detection is a regex over a terminal and so can be wrong: any pane showing the words is a candidate, including one showing a diff of `pq` itself, and one that goes idle rather than resuming can never prove it recovered.
Releasing the freeze there costs a single worktree if the wall was real - the next agent walls, is detected, and the freeze comes back - which is the right way round, since a misread pane should cost a worktree rather than a night.

#### Tearing a task down

Once a `done` task's pull request has genuinely merged into its repo's default branch - checked against the forge, the same predicate blockers use, not `wt gc --merged`'s looser "state == MERGED" - `pq` tears it down: the worktree, its database, its port, its redis index, its puma-dev entry, and the Herdr workspace holding its agent's pane.
That is the same `wt rm` you would have run by hand, driven unattended.

`pq` never touches a worktree it did not create.
A task whose PR closed without merging is left exactly as `wt rm` would have found it - the work never shipped, so what to do with it stays your call.

Two things hold a teardown off, both checked only once the merge is confirmed:

- the agent is still going - Herdr reports `working` or `blocked` for its pane
- `pq` is itself running inside that task's own Herdr workspace, where closing it would kill the pane mid-teardown

`pq ls` shows a held task as `held agent`, `held here`, or `held nobase` (its repo's default branch could not be resolved), and a closed-without-merging one as `closed`.
A task with nothing left to reclaim shows `-`, the same as any other task that needs nothing from you.
There is no off switch, for the same reason `pq` has none for dispatch-hours or the usage gate: one mechanism, not two.

Once its verdict is in - merged and torn down, or closed without merging - a done task is exactly what the next tick's archive pass files away; see below.

#### Archiving history

`done/` is never pruned on its own, so every task `pq` has ever finished stays there, crowding out what is still live or still needs a decision.
Once a done task is **terminal** - its PR merged and the worktree is gone, or every PR for it closed without merging - `pq tick` moves it to `archive/`, the same `mv` every other transition uses.
A task with no verdict yet, one held on `PQ_REAP_HELD`, or one reaped with no verdict at all stays in `done/` - each of those still wants something.

A blocker survives this by construction: it is a resolved `(label, repo, branch)` triple, not a task reference, so a dependent still resolves it correctly once its blocker has archived - see "Blockers" above.

The newest `PQ_DONE_KEEP` (default 3) archivable tasks are kept behind in `done/`, so `pq ls` still answers "did last night's batch ship?" at a glance.
`pq ls` hides `archive/` by default and reports how many rows it is hiding; `pq ls --all` shows everything, and `--json` composes with either.

`pq archive <task>` files a done task away by hand - the escape hatch for anything `pq` cannot prove either way itself.
It is restricted to `done`: a queued or running task still holds a slot or a worktree, so `pq hold` and `pq rm` are the right tools there instead.

Nothing in `archive/` is ever deleted or swept up again by a later tick - it is where settled history lives, not a queue for cleanup.

### Reclaiming resources

Herdr has no worktree-removal hook, so removing a worktree through Herdr's own UI (rather than `wt rm`) would otherwise leak its database, port, and redis db.
`wt gc` reconciles this: it checks each recorded worktree and, for any whose directory no longer exists, runs the profile's teardown and frees the reservation.
`wt new` runs it automatically, so orphans are always reclaimed on the next task - run `wt gc` yourself any time to clean up immediately.

`wt gc --merged` goes further and reclaims worktrees whose PR has merged, the case the orphan pass structurally cannot see since a shipped worktree is still a perfectly valid git worktree.
It lists what it intends to take before taking it, and skips a repo whose PR state it could not read.

`wt gc --sweep` reclaims project-owned resources (databases, puma-dev entries) whose worktree is gone entirely, so no state file points at them any more.
It previews what it would reclaim first, since - unlike the other two passes - it deletes on a naming pattern rather than on a recorded fact.

## Requirements

Neovim 0.12+, plus a few CLI tools the config shells out to. Install with Homebrew:

```sh
brew install neovim ghostty tree-sitter-cli ripgrep fd asdf
```

- `neovim` — editor.
- `ghostty` — terminal.
- `tree-sitter-cli` — required by `nvim-treesitter` (main branch) to build parsers. The plain `tree-sitter` formula is the library only.
- `ripgrep`, `fd` — used by Telescope for find/grep.
- `asdf` — manages Ruby and Node runtimes; Mason needs both to install LSP servers.

### asdf: set user-level defaults

Mason installs LSP servers via `gem` (Ruby) and `npm` (Node). If asdf has no active version, installs fail. Set user defaults once:

```sh
asdf install ruby 3.4.6
asdf install nodejs 22.17.0
asdf set -u ruby 3.4.6
asdf set -u nodejs 22.17.0
```

## Install

Sync this repo into `~/.config` and install fonts:

```sh
./install.sh
```

`install.sh` rsyncs each `.config/<name>` into `~/.config/<name>`, installs the executables under `.local/bin` into `~/.local/bin` (file-by-file, so unmanaged binaries there are left alone), and copies fonts into `~/Library/Fonts` (macOS) or `~/.local/share/fonts` (Linux).

## First-time Neovim setup

On first launch, lazy.nvim bootstraps itself and pulls plugins. After that:

1. `:Lazy sync` — install/update all plugins.
2. `:TSUpdate` — build Treesitter parsers.
3. `:Mason` — verify LSP servers installed (`lua_ls`, `ruby_lsp`, `stimulus_ls`, `herb_ls`, `tailwindcss`). Check `:MasonLog` if anything fails.

## Pulling local changes back into the repo

`import.sh` does the reverse of `install.sh` - pulls configs from `~/.config`, executables from `~/.local/bin`, and fonts back into the repo, but only for the files already tracked here (it never expands the managed set).

```sh
./import.sh
```
