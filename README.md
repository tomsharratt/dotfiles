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
- its own **test** database, so `wt test bundle exec rspec` never shares `supercast-web_test` with another worktree - see "Running tests in a worktree" below;
- its own redis db index, so Sidekiq queues don't collide;
- its own puma-dev url `https://<name>.test` on its own port.

So `wt new premier-video` and `wt new spotify-reconcile` can run side by side, each serving its own url against its own database, with no handoff between them.
The app needs no changes for this: its `database.yml`, `sidekiq.rb`, and `development.rb`/`session_store.rb` already honor `DATABASE_URL` / `REDIS_URL` / `LOCAL_DOMAIN`, and `config.hosts.clear` allows any `*.test` host.
The profile injects the port by generating a per-worktree Procfile (the tracked `Procfile.dev` pins the web port to 3000), written outside the repo so the checkout stays clean.
Provisioning also restarts puma-dev whenever a slug's port actually moves, because puma-dev reads `~/.puma-dev/<slug>` only once per hostname and then caches that proxy for the life of the daemon - nothing short of a restart evicts it, so a moved port otherwise leaves the url 502ing against a dead port while the dev server runs happily on the new one.

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
wt test [cmd...]     the same, with RAILS_ENV=test, so the command gets the
                     worktree's own test database rather than its dev copy
wt open [name]       open the worktree's dev url in the browser, starting the
                     dev server first if nothing is serving it yet, or hand the
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

#### Running tests in a worktree

`wt test <cmd>` is `wt run` with `RAILS_ENV=test`, and it exists because that one variable decides which database a spec run destroys.

`supercast/config/database.yml`'s `test:` entry carries both `url:` (reading `DATABASE_URL`) and an explicit `database: supercast-web_test`, and ActiveRecord merges the url *on top of* the yaml - so `DATABASE_URL` wins in every environment, not just development.
That left two wrong answers and no right one.
`wt run bundle exec rspec` handed the suite the worktree's **dev** database, so it loaded schema over the data that worktree's own dev server was serving.
A bare `bundle exec rspec` set nothing at all and fell through to the single machine-wide `supercast-web_test` - which is where `PG::ObjectInUse`, `PendingMigrationError` re-appearing seconds after migrations applied cleanly, and truncation deadlocks in specs belonging to a completely different branch all came from.

So each worktree now provisions a second database, and `wt test` is what points `DATABASE_URL` at it.
Use `wt test` for anything running under `RAILS_ENV=test`, and plain `wt run` for everything else - `bin/rails console`, `runner`, `db:migrate` - which still wants the dev copy.

Two things it does not fix.
A bare `bundle exec rspec` that bypasses `wt` entirely still lands on the shared `supercast-web_test`; making *that* safe would need `database.yml` to name a variable only worktrees set.
And the test **redis** index is still shared, because `config/initializers/redis.rb` hardcodes db 15 in test with no override - so Redis-backed specs can still race a concurrent run even though the databases no longer do.

`wt new` layers three things on top of "prepare a worktree", and each can be dropped so the command can be driven by a script rather than by `prefix+t`:

```
--no-agent   don't start Claude in the root pane
--no-dev     provision, but don't boot the dev server
--no-focus   leave focus where it is
--json       print the worktree's facts (path, pane ids, port, url) to stdout
```

Human-facing output always goes to stderr, so `--json` leaves stdout clean for a caller to parse.
`--no-dev` deliberately still provisions: the dev server is four long-running foreman processes, while provisioning is the one-off that creates the isolated database - skip that too and `wt run bin/rails test` inside the worktree fails confusingly.

`pq` dispatches with the dev server on.
It used to pass `--no-dev`, because a batch running overnight would otherwise hold a foreman stack per task behind agents that never opened a browser - but batches no longer run overnight, most of the work is visual, and the delivery contract (see "Delivering a reviewable pull request" below) has every implementer verify each screen it touches in the browser and screenshot it.
An agent with no running app cannot do that, so the server is part of what dispatch provides.
`wt open`'s own autostart stays, for a server that has died by the time you come to look: it starts the server itself when nothing is serving that port, waits for it to bind, and then opens the browser.

It declines in every case where starting one would be wrong: outside Herdr there is no pane to start it in, a profile with no `wt_dev` has no server, and a profile that allocates no port gives nothing to probe (which is what leaves the two mobile profiles alone).
The gate that matters most is an existing `dev` tab, because "nothing is listening" stays true for the whole time a foreman stack is binding.
Without it a second `wt open` inside the boot window would start a second stack: two `yarn build --watch` writing one output directory, and two sidekiq on one redis index.
That window is easy to land in, since `wt new` makes the tab and opens no browser of its own, so `wt open` is the natural next keystroke.
So an existing tab is waited for rather than warned about, on the same bounded budget: a tab still binding and a tab whose server died look identical from outside, and waiting is the only way to tell them apart.
Either way the browser opens at the end, and a server that never came up is named against the tab holding the error rather than allowed to fail the command.

### Plan queue (`pq`)

`pq` is a queue of Claude Code plans waiting to be run as implementer sessions, built on top of `wt` but separable from it.
The split it exists to make: one long-lived session, in plan mode, does the thinking and produces a plan that has already answered every question; `pq` then runs those plans later, unattended, several at a time, as cheap implementer sessions that only have to execute.

A task is a directory, and the directory it sits in is its state - `queue/`, `running/`, `done/`, `archive/` under `~/.local/state/pq`.
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
pq add                   pick a plan and add it to the queue
pq add --urgent          allocate from a reserved range, ahead of every real date
pq add --after T         repeatable, at add time: don't dispatch until T's PR has merged
pq add --design PATH     repeatable: a design file the implementer builds to (auto-detected from the plan too)
pq add --repo PATH       repeatable, only with --split/--split-dir: name the repos a split may use
pq add --split           queue a plan that lays out several pull requests as one task each, wired with --after
pq add --split-dir D     queue an already-split directory, skipping the split step
pq after <task>          list a task's blockers and what each is waiting on
pq after <task> T...     add blockers to a task still in queue/
pq after <task> --clear  drop them all
pq base <task> [B]       what branch it forks from and aims its PR at; B retargets it
pq ls [--all] [--json]   every task, its state, and what it is waiting on
pq tick [--cap N]        free finished slots, then fill them from the queue
pq run [--interval S]    tick on an interval until you stop it
pq cap [N]               how many may run at once; 0 pauses
pq rm <task>             drop a task (never touches a worktree or a branch)
pq evidence [task]       publish a task's screenshots to the pq-evidence branch; prints the markdown to paste
```

The fourteen-digit prefix on a task directory is a UTC timestamp and nothing else, and a task's directory is renamed as it moves between states, so commands take the task's slug, or any unique prefix of it.

#### Picking a plan

`pq add` at a terminal shows the ten most recently touched plans in `~/.claude/plans`, each with its age and its title - the first `# H1` in the file, since Claude Code names the file itself from your opening prompt and that name is rarely what the plan is actually about.
"Most recently touched" means whichever is newer, mtime or birth time, so a plan edited this morning outranks one merely created today, and a plan restored by `cp -p`, `rsync -a`, or a git checkout doesn't fall to the bottom on a stale mtime.

Ten is a page, not a limit.
`n` pages back to older plans and `p` pages forward again, and the header says where you are - `11-20 of 47 (page 2/5)`.
The keys are offered only when there is more than one page, and paging past either end says so rather than doing nothing.
`PQ_PICK_LIMIT` sets the page size.

Row numbers are absolute: row 11 is the eleventh-newest plan whichever page you are looking at, so a number always means the same plan and any listed row can be picked from any page.
Pick a number - Enter takes the top row of the page you are on, which is the most recent plan on page one - and it previews the plan before asking `use this plan? [y/N]`; answering `n` returns to the number prompt, on the page you were reading, rather than aborting the whole command.
That `n` is "no", not "next page" - the two prompts read the key differently, and each one's hint says which is in force.
Once you confirm, it asks the things that actually shape how a task runs: which model should run it and which of the tasks already queued or running it should wait on - and, first, for a plan that lays out several pull requests of its own, whether to queue one task per pull request.
The model question offers `sonnet`, `opus` and `fable`, and Enter takes `PQ_DEFAULT_MODEL` (`sonnet` unless you have overridden it); an initial and any case will do.
Only what is typed at the prompt is held to those three - `--model` itself still takes any id `claude --model` accepts.
`--effort` stays a flag, with no question of its own.

Passing a flag the wizard would otherwise ask about skips just that one question and leaves the rest standing - `pq add --split` skips the split question, `pq add --model opus` skips the model question, `pq add --after some-task` skips the blocker question, and any combination of them skips exactly the questions it has already answered.

There is no unattended add: with no terminal to ask at, `pq add` stops rather than guessing which plan you meant.

#### Delivering a reviewable pull request

Two things about a `pq` pull request used to cost the most time to review.
It arrived as one blob - a thousand changed lines in a single commit, with a description that summarised rather than guided - so GitHub's commit-by-commit view was useless against it.
And visual work drifted from the design it had been planned against, because the implementer had only ever seen the plan's prose about that design.

So every task now carries a *delivery contract*, `<task>/contract.md`, and the dispatch prompt is reduced to a pointer: read the plan, read the contract, follow it to the letter, and never wait for input.
The contract is `pq`'s own template, written per task at dispatch rather than at add - so an improvement to it reaches every task still queued, while a running agent never sees its own contract change - and parameterised with the task's paths, its dev url and its design files.
Every path it hands out is the task's *stable* one, `$PQ_HOME/tasks/<name>`: a task's real directory moves from `running/` to `done/` the moment its pull request is reconciled, while the agent is still saving screenshots into it, and the first task run this way recreated the old path as a phantom task that `pq` then tried to resume.
The link follows the task through every transition, and it is the only path anything outside `pq` is ever told.
The repository's own conventions still apply on top; the contract says so.

It asks for four things.
**Commits are the unit of review**: one coherent, self-contained step per commit, in the order a reader should meet them, each message saying what and why; a mechanical change is its own commit and says so; a non-mechanical commit over about 300 lines is split; never one squashed commit at the end.
History may be rewritten only while the pull request is a draft.
**Verification in the browser**: the app is served at the worktree's own url from its `dev` tab, and the implementer walks every path the change touches, captures each screen before and after with `chrome-devtools-axi`, and is told to fix anything that looks off even when the plan did not name it.
**Design fidelity**, when the task carries design files: open each in the browser, screenshot the target artboard at its native width, build to it, then screenshot the implementation at the same width and state and compare side by side - layout, spacing, sizes, colour, type, radius, icons, copy, and every state the artboard shows - until nothing differs or a difference is deliberate and recorded.
**A draft pull request with a guide**: `pq evidence` publishes the screenshots, the pull request opens as a draft with the intent line first, a `## Review guide` (the commits in reading order, where the risk is, what is mechanical) and a `## Visual evidence` section - plus, for a design task, a `## Design fidelity` table and the deliberate deviations.

The pull request stays a draft until the review gate below has run and the implementer has answered it.
An agent that gets stuck, or finds the plan does not fit, commits what it has and opens a draft whose title begins with `STUCK:` - the gate leaves those alone, and `pq ls` reads the chain behind one as stalled.

#### Designs travel with the task

A plan written from a Claude Design file describes the design in prose, and an implementer that only ever sees the prose builds to its memory of a picture it never saw - one pull request's own description admitted as much.
So the file travels with the task.
`pq add --design PATH` attaches one (repeatable), and every absolute or `~`-prefixed path to a `.dc.html`, `.html`, `.png`, `.jpg`, `.jpeg` or `.pdf` that the plan's text mentions is picked up on its own; a mention that does not exist on disk is warned about by name, and a `.html.erb` or a `claude.ai` url is never mistaken for one.
The rule in `AGENTS.md` closes the loop from the planning side: a plan built from a Claude Design file saves that file to `~/.claude/plans/designs/` and cites the absolute path on its own line, so `pq add` finds it.

The files are copied into `<task>/design/` inside the same staging step that writes `plan.md`, so a task lands with its design or not at all, and the `design:` header lists them - absent, like `base:`, when there are none.
A plan that reads as built from a design (it cites `claude.ai/design` or a `.dc.html`) with no file found gets one question at the wizard - the path, or Enter to go without, loudly.
On a split, each part carries the design files it names by filename (the splitter is told to cite them), and a file no part names goes to every part with a warning rather than to none.
The contract then tells the implementer exactly what to do with them.

#### Evidence

Screenshots are what let a pull request be judged without checking it out, and a description can only show an image that has a url.
`pq evidence <task>` (or bare, from inside the task's worktree) publishes `<task>/evidence/*.{png,jpg,jpeg,gif,webp}` to one shared branch, `pq-evidence`, in the task's own repository under `<slug>/`, and prints one `![file](https://github.com/<owner>/<repo>/raw/pq-evidence/<slug>/<file>)` line per file on stdout - everything human goes to stderr, so the output pastes straight into the description.

It is all git plumbing against a temporary index in the worktree: nothing is checked out, the worktree's own index and tree are never touched, and the implementer's uncommitted work is not in the way.
Re-running replaces the slug's files rather than appending, so a second pass after a fix is idempotent, and a push rejected because another task published first is rebuilt on top of theirs, three times at most.

One branch for every task rather than one per task, so nothing accumulates in the branch list, and it is never deleted: a merged pull request's description keeps pointing at it, and a per-task branch reaped with its worktree would break the images in every merged pull request.
Neither the reap pass nor `wt rm` touches it.

#### Order

The queue is add-order, oldest first - a task's position is exactly when it was added, nothing more.
`--urgent` allocates from a reserved range below any real date, so an urgent task always sorts ahead of every ordinary one.
Two urgent tasks are still ordered oldest first between themselves, by the order they were added.
`--urgent` is the only move there is, and it is declared when the task is queued rather than applied afterwards.
There is no number to slot between two tasks, and nothing to promote or demote one later, because plans are added in the order they should run - so there was never anything to insert between them, or any position to correct.
The fourteen-digit prefix is a fixed-width UTC timestamp, which is what makes bash's own glob order agree with numeric order - `pq ls` and the queue's actual dispatch order are the same order, as long as every task directory carries that prefix.
A lingering directory from before this scheme won't - that is what the one-time migration is for.

#### Blockers

Some work is several pull requests where the second cannot start until the first has shipped - a client change waiting on the endpoint it calls, say.
The wizard's blocker question, `pq add --after A`, or `pq after B A` once both are queued, says exactly that: B is not eligible for dispatch until A's PR has merged into A's repo's default branch.

Blocked is derived, not stored - a blocked task sits in `queue/` like any other and fill just skips it, the same way the cap is soft arithmetic rather than a drain state.
A task's blockers live in a third file, `after`, alongside `plan.md` and `state.env`: one blocker per line, `label<TAB>repo<TAB>branch`.
A blocker is a resolved `(label, repo, branch)` triple, not a task reference - it is captured at the moment you type it, so it survives `pq rm A`, survives A ageing out of `done/`, and survives a slug being reused.
That is also what makes a cross-repo blocker work for free, and lets a blocker name a branch that was never added to `pq` at all.

Merge state comes from the forge, never from git ancestry: a squash-merged branch's tip is not an ancestor of its default branch, so `git branch --merged` misses every real merge.
`pq` asks `gh` instead, and only trusts a `MERGED` pull request whose base is genuinely the repo's default branch - merged into some other branch does not count.

`pq after <task>` answers "why has this not started": per blocker, both the state of the task that owns the branch and the state of its pull request, since either one can be the reason and the fix differs.
A blocker that has already merged is fine to add - `pq` says so rather than refusing.
Self-reference and cycles are rejected at the moment you try to create them.

Three situations short-circuit the ordinary wait and warn once, because they read as healthy waiting until you look closer: a **dead** blocker (every pull request for it is closed), an **orphan** (nothing owns that branch, so nothing will ever open one), and a **stalled** chain (the owning task already reached `done` with only a draft PR open *and* its review gate settled - a stuck agent, not a chain in review).
That last qualification matters now that every pull request opens as a draft: a draft during the review gate is the gate working, and only a draft still open once the gate is over is a stalled chain.
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
It governs the tasks whose PR is still open or in draft; a task whose PR has *settled* - merged or closed - gets torn down by the reap pass as soon as its agent stops, and a torn-down task releases its slot at once with no grace at all.
A settled task still holds its slot until then, exactly as an open one does: the teardown is waiting on that agent, so handing the slot away on the verdict alone would start a second agent beside one still running.
The grace applies to `idle` and to herdr's `done` alike, because both are per-turn rather than per-task: an agent that opens a PR and then goes back in to fix CI passes through them between every turn, and releasing on the first sighting would be the same bug in a subtler form.
A `blocked` agent - a permission prompt, a quota wall - holds its slot too, the same trade `running/` already makes, since it will resume rather than having finished.
That row reads as **permission** or **quota 8:30pm** rather than "wrapping up", and a permission prompt counts into "needs you": it is holding a slot until you answer it.
A quota wall does not, because `pq` answers that one itself, on a `done/` pane as readily as on a running one.
Note that a dismissed wall reads as `idle` to herdr - dismissing the dialog is what stops the spinner - so `pq`'s own verdict is what holds that slot, or the grace below would hand it away while the agent waits for its window and then take it back on the tick the agent resumes.
An exited agent or a vanished workspace releases immediately, with no grace at all, and while herdr is unreachable the slot is held rather than guessed at.
A task whose review gate is in flight - waiting for the reviewer, or for the follow-up to be delivered - holds its slot with no clock at all, for the same reason a blocked one does: the implementer is idle because it is waiting, and it is about to be handed more work.
That hold is bounded by the gate's own bounds (see "The review gate" below), and ends the moment the follow-up is delivered, after which the ordinary grace applies.
Setting `PQ_WRAPUP_GRACE=0` restores the old release-on-PR behaviour for a task the gate does not apply to; for a gated task it means release once the gate is through, not on the pull request.

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

#### Plans that lay out several pull requests

A big change is one pull request: the implementer commits it as a series of small, self-contained steps, and the commits are how it is reviewed.
Cutting it into several pull requests on top of that only buys a waterfall - each piece waits on the merge of the one before it, and so does its review - so `pq` never proposes dividing a plan just because it is big.
Some plans do lay out several pull requests of their own, though: a "PR 1" and a "PR 2" the plan names, or work in more than one repository, which one pull request cannot span.
`pq add --split` is for those: one Opus session reads the plan and writes each of its pull requests up as a standalone plan of its own, plus a dependency graph - then queues every part through the ordinary `pq add` path, with `--after` already wired from the graph.
It follows the plan's own boundaries and never draws its own: no pull request is divided further or merged with another, and a plan that lays out one pull request in one repository comes back as a single part.
The order the plan gives its pull requests in is not a dependency - only real ones are wired (an endpoint, a schema, a helper one part introduces and another uses, or two parts that would edit the same code), so parts that do not depend on each other run side by side.

You do not have to notice that by yourself.
The Haiku call that names every task also returns an outline: the pull requests the plan itself lays out, in its order, one title each - and a single entry for any plan that does not, however large it is.
When the outline has more than one entry the wizard lists it and asks whether to queue one task per pull request, with Enter meaning yes; a plan with a one-entry outline is not asked at all.
The outline is shown to you, not fed to the splitter, which reads the plan's pull requests off the plan itself and still shows its table for confirmation before anything is queued, so a split that comes out differently from the outline is visible before it costs anything.
`--split` is still the way in when Haiku has missed a plan that lays out several.

The load-bearing constraint is that parts wait for merges, never for branches - no part is ever built on top of a sibling's branch.
Each part starts from the default branch with its declared dependencies already merged, and every part is written for an agent that sees only that one file: it never mentions another part, its filename, or its branch.
`pq` validates this before anything is queued - full coverage of the original plan, no missing or forgotten parts, no cycles, and no part referencing a sibling by name - and refuses to queue anything if a check fails.

The split artifacts land in `$PQ_HOME/splits/<plan>-<stamp>-<pid>/`: the source plan, one `NN-short-slug.md` per part, and `graph.tsv` recording which parts must merge before which others.
Before queueing anything, `pq` shows a table of the parts, their wave (how many merges deep they are), their branch, and what each waits on, then asks to confirm.
Declining leaves the split directory on disk and costs nothing: `pq add --split-dir <dir>` resumes from it later, without paying for the Opus session again, which is what makes hand-editing a part before it ships a first-class path.

`--after` on the split itself only applies to the root parts - the ones with no dependency inside the split - since `pq after`'s own reporting already surfaces the rest of the chain to anyone asking why a downstream part hasn't started.

A plan that names more than one checkout - a mobile feature spanning the Rails monolith and the iOS app, say - gets its parts assigned across repositories instead of forced into one.
The splitter is shown every git checkout sitting alongside the primary, or under `PQ_REPOS_DIR` if you'd rather point it somewhere else, and told to use the primary unless the plan clearly places some of the work elsewhere - it never assigns a part to a repository the plan doesn't talk about.
A part belongs to exactly one repository, because a part is one pull request; work that genuinely spans two repositories is two parts, wired with an ordinary `--after` the same way an intra-repo dependency is - a client part waiting on the server part it needs is just that edge crossing a repo boundary.
`--repo PATH` is repeatable and is the escape hatch for the discovery, not the normal path: passing it once still lets the scan contribute, which is how you fix a wrong cwd without silently turning multi-repo splitting off, and only passing it two or more times narrows the set to exactly those repos.
The repo assignment is yours to check at the confirmation: the table grows a `REPO` column once a split actually spans more than one repository.

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
Either can arrive wrapped, because the pane is only so wide and the wall line that turns up most nights is a background agent's failure with the whole API error quoted inside it.
Claude Code breaks on word boundaries, and almost every break point is harmless, but one is not: a break straight after `resets` puts the time on a row that no longer looks like the wall and leaves a wall row trimmed back to end at `resets` with nothing after it, so a pane showing the reset in plain sight reads as having none.
Those two rows are rejoined before anything looks at them, and the lines are then tried in order - the wall's own, newest first, then everyone else's - until one yields a hint that actually parses, rather than a single unreadable line hiding a good one below it.
Two habits of Claude Code's formatter are worth knowing, since both will catch out anything that assumes otherwise: minutes are dropped when they are zero, so it reads `8pm` rather than `8:00pm`, and no date is printed for a reset less than 24 hours out, so a bare `1am` seen at 11pm means tomorrow.
Beyond 24 hours it becomes `Jul 28, 8:30pm`, gaining a year only when the year differs.
What is *stored* is the epoch, and `pq ls` formats it back on the way out - state files are read by sourcing them, so a value like `3pm (PDT)` is a syntax error that silently truncates everything written after it.

A hint that cannot be read is not a failure: ten-minute polling is the fallback, and it also takes over if the knock at the named time turns out to be too early.
The one outcome ruled out is waiting on a guess, because that strands a task silently, where an early knock costs a single instantly-failing call.

Nor is it final, which matters more than it sounds.
What walls a task is usually a background agent, and its failure reaches the transcript seconds before the session's own next request fails and puts the same time in the statusline - so the tick that catches the wall can honestly have nothing to read, on a pane that names the time plainly a moment later.
`pq` keeps looking, and takes the first reset the screen offers.
Only until the first knock, though, because a knock is precisely what demoted it to polling - the named time came and went with the wall still up - while the line that named it stays in the scrollback for ever.
Re-reading that line afterwards would not even give back a stale time: a bare clock time is read as the next time the clock comes round to it, so `resets 4:20pm` read at 4:30 is tomorrow, and a ten-minute cycle would quietly become a day-long one.
The same rollover is why a second look never accepts a reset further out than `pq` would keep knocking for anyway - a hint that has rolled sits a clear day away, well past a bound that a five-hour window's reset is nowhere near.

The wall is the only thing `pq` ever answers.
A permission prompt is recorded as `permission` and deliberately left alone - that is the trade for running everything in auto mode - so `pq ls` separates the agents waiting on the clock from the ones waiting on you.
One appearing where a wall was is taken as recovery, because a session asking for something is a session running again, and the alternative is a knock sending Escape at the prompt - refusing it - every ten minutes.
After forty unanswered knocks a task is marked `walled` and left, rather than knocking all night - and at that point it stops freezing dispatch, which is the only bound on how long a freeze can last.
It wants one, because detection is a regex over a terminal and so can be wrong: any pane showing the words is a candidate, including one showing a diff of `pq` itself, and one that goes idle rather than resuming can never prove it recovered.
Releasing the freeze there costs a single worktree if the wall was real - the next agent walls, is detected, and the freeze comes back - which is the right way round, since a misread pane should cost a worktree rather than a night.

#### The review gate

Every pull request a task opens gets one independent review before the implementer may call it ready - run by `pq`, not asked of the agent.
The agent cannot run `/code-review` itself: the skill is reserved for a human typing it, and every agent that was once asked to answered that it could not.
But in `claude -p` the prompt *is* the human, so `pq` runs `claude -p "/code-review <level> --comment N"` itself, in the task's worktree, with the task's own directory opened to it so it can read the plan and the design files, and the skill posts its findings as inline review comments on the pull request.
`PQ_REVIEWER_MODEL` (default `opus`) and `PQ_REVIEW_EFFORT` (default `xhigh`) are what it runs at, the second passed both as the session's `--effort` and as the skill's own level argument.
The order of that prompt is load-bearing, and was wrong for the gate's first few runs.
The skill reads the first non-flag token as the level and everything after it as the target, so sending the pull request first (`/code-review N <level> --comment`) meant the level was ignored - silently falling back to `codeReviewLastEffort` in `~/.claude.json`, the level last typed at an interactive prompt, which is what "Reusing xhigh effort (the level you typed last)" at the top of those transcripts was reporting - and the target became the string `N <level>` rather than the pull request number.
It read as harmless only because the level last typed on this machine happened to be `xhigh` as well.
Then `pq` prompts the implementer, through herdr's agent API, to read every comment and resolve each - fix it and push, or reply on the thread with the reasoning for leaving it - and to mark the draft ready with `gh pr ready`.
Nobody reviews the review.
The point is that a second pair of eyes has been over the diff, and the first pair has had to answer them, before you read either.

It is a state ladder on the task, one step per tick, so a tick never blocks on it: `pending` once reconcile has seen the pull request, `running` while the reviewer is a background process of its own, `posted` when it has finished, `prompted` once the follow-up is with the implementer, and `ready` when the pull request stops being a draft.
The reviewer waits for the agent to go quiet first, and probes the pull request once before launching: a title beginning `STUCK:` is skipped outright (telling an agent that stopped for a reason to mark its work ready is the wrong instruction), and a single commit over `PQ_REVIEW_SPLIT_LINES` changed lines earns an extra clause in the follow-up asking for the branch to be restructured into small logical commits before it is marked ready.
`pq ls` reads `review due`, `reviewing 7m`, `reviewed`, `resolving`, then falls back to `wrapping up`, and the tick summary counts `N reviewing` - see "The security review" below for the words it adds.

The reviewer runs in the background rather than shielded, because a tick must never block for up to an hour: everything needed to collect it is on disk, so a `pq run` stopped with Ctrl-C leaves the reviewer alone and a later tick, from any `pq` process, finishes the job.
Liveness is the process group, not the pid, so a recycled pid is neither counted alive nor killed.
A pull request that settles mid-review has its reviewer killed before the reap pass closes the workspace it runs in, and `pq rm` kills one too.

Failure is loud, once, and falls back rather than blocking.
A reviewer that errors or runs past `PQ_REVIEW_TIMEOUT` is retried after `PQ_REVIEW_RETRY`, up to `PQ_REVIEW_MAX_TRIES` launches, and then given up on; the implementer is then told the review did not happen and to review its own diff as a stranger would, fix, push, and mark the pull request ready anyway, and `pq ls` reads `review failed` until it does.
A reviewer that was refused `gh` and posted nothing is `denied` and never retried, since it cannot succeed until `PQ_REVIEW_TOOLS` changes - and it is reported the same way, on the first task it happens to.
There is no off switch; `PQ_REVIEW_MAX_TRIES=0` is the honest degraded mode, which skips every reviewer and sends every task straight to the self-review fallback.

A gate that nobody is going to close is `lapsed`: the agent has exited, or has sat idle past the wrap-up grace with the draft still open.
That is warned about once, counts into "needs you", and reads `review lapsed` in `pq ls` - the comments are there, and resolving them is yours.

#### The security review

Some plans ask for a security review as well - "run `/security-review` as well as `/code-review`", with what it should look at - and those get one, run by `pq` the same way.
The same Haiku call that names a task at add time reads whether its plan asks for one, and a plan that does gets a `security: yes` header (absent, like `base:` and `design:`, when it does not) and says `review: code and security` as it is queued.
It has to be read rather than matched: plans name the skill as often to waive it as to ask for it - "`/security-review` is not warranted" - so a pattern cannot tell the two apart, and a yes stands only when the plan's text mentions a security review at all.
The wording was checked against ten real plans, four runs each, and came back right all forty times, including one that asks for it inside an aside about CSRF and `pq`'s own plan, which names it only as follow-up work.
A split carries the ask into the parts it is about, and each part gets a verdict of its own.

The implementer's contract says `pq` runs the review, and not to run one itself.
Once the draft is open, `pq` runs `claude -p "/security-review"` in the task's worktree beside the code reviewer, launched on the same tick, on the same `PQ_REVIEWER_MODEL`, `PQ_REVIEW_EFFORT`, `PQ_REVIEW_TIMEOUT`, `PQ_REVIEW_MAX_TRIES` and `PQ_REVIEW_RETRY`, and under the same read-only deny rules, with `gh` denied outright.
The skill takes no target and posts nothing: it reviews `git diff origin/HEAD...` of wherever it runs and replies with a markdown report.
So its brief names the diff to go by - `git diff origin/<base>...HEAD`, since `origin/HEAD` is the default branch whatever the pull request is aimed at - and points it at the plan, which says why it asked and what to look at.
Then `pq` delivers the report itself: it is saved as `<task>/security.md` and posted on the pull request as one comment, next to the code review's inline ones.

The two reviews meet at one point: the follow-up waits until both have finished, so the implementer is told once, about both - answer every inline comment and every finding in the security report, by fixing it or saying why it stands - and the slot stays held until then.
`pq ls` reads `security review 4m` while the gate waits on it, and `security review failed` if it did not happen.
A security review that fails is retried and then given up on exactly like the code review, and the follow-up then asks the implementer to check its own diff for the risks the plan names.
A report that could not be posted is not a failed review: the follow-up asks the implementer to post it from `security.md`.
The security reviewer never probes the pull request itself - it launches only once the code reviewer's probe has passed - so a `STUCK:` title or a settled pull request stops both, and one that settles mid-review has both killed.
The one exception is an agent that has gone: a security review already under way is let finish, so its report still reaches the pull request, and then the gate lapses as it would have.

It was verified before it shipped, in scratch repositories, with the exact command `pq` runs.
A change with a SQL injection and two cross-tenant reads came back with all three, at confidence 9 or 10, in under three minutes for about a dollar.
A clean change came back with none.
A change forked from an integration branch that carried a command injection of its own was shown the whole integration branch by the skill, went by the brief's diff instead, and left the base's injection out of scope.

#### Tearing a task down

Once a `done` task's pull request has **settled**, `pq` tears it down: the worktree, its database, its port, its redis index, its puma-dev entry, and the Herdr workspace holding its agent's pane.
That is the same `wt rm` you would have run by hand, driven unattended.

Settled means either of two things:

- **merged** into the base it was aimed at - checked against the forge, the same predicate blockers use, not `wt gc --settled`'s looser "state == MERGED"
- **closed** without merging, every pull request for the branch - closing one is a decision that the work is finished, so it settles the task exactly as a merge does

Closing a pull request is how you say you are done with a piece of work, and there is nothing left for its agent to come back to either way.
So a closed PR reclaims exactly as much as a merged one: the same teardown, the same holds, the same archive.
The asymmetry that used to live here - a merged task torn down, a closed one left sitting on a database and a port until you remembered it - only ever cost you the reclaim.

`pq` never touches a worktree it did not create, and never merges or closes a pull request itself.
What it leaves alone is a task with no verdict at all: no pull request, or one still open, because nobody has decided anything yet.

A pull request you reopen before its teardown runs stops being settled, and `pr_all_closed` needs *every* row closed - so closing one alongside a fresh one is not a verdict either.
But once the teardown has happened it is not undone; that is the point of saying you are done with it.

Two things hold a teardown off, both checked only once the verdict is in:

- the agent is still going - Herdr reports `working` or `blocked` for its pane
- `pq` is itself running inside that task's own Herdr workspace, where closing it would kill the pane mid-teardown

`pq ls` shows a held task as `held agent`, `held here`, or `held nobase` (its repo's default branch could not be resolved).
A task with nothing left to reclaim shows `-`, the same as any other task that needs nothing from you - a closed one included, since its teardown is automatic now and the `PR` column already reads `#N closed`.
There is no off switch, for the same reason `pq` has none for dispatch-hours or the usage gate: one mechanism, not two.

Once its verdict is in *and* the teardown has run, a done task is exactly what the next tick's archive pass files away; see below.

#### Archiving history

`done/` is never pruned on its own, so every task `pq` has ever finished stays there, crowding out what is still live or still needs a decision.
Once a done task is **terminal** - its PR settled, merged or closed, *and* its worktree gone - `pq tick` moves it to `archive/`, the same `mv` every other transition uses.
Both halves are required: `archive/` is not walked on the hot path, so filing a task away on the verdict alone would strand its worktree, database and port where nothing would ever reclaim them.
A task with no verdict yet, one held on `PQ_REAP_HELD`, and one reaped with no verdict at all all stay in `done/` - each of those still wants something.

A blocker survives this by construction: it is a resolved `(label, repo, branch)` triple, not a task reference, so a dependent still resolves it correctly once its blocker has archived - see "Blockers" above.

The newest `PQ_DONE_KEEP` (default 3) archivable tasks are kept behind in `done/`, so `pq ls` still answers "did last night's batch ship?" at a glance.
`pq ls` hides `archive/` by default and reports how many rows it is hiding; `pq ls --all` shows everything, and `--json` composes with either.

Archiving is entirely automatic - there is no manual form.
A `done` task that `pq` cannot settle either way simply stays in `done/`, where `pq ls` keeps showing it, which is the right outcome for the one case that needs a human to look.

Nothing in `archive/` is ever deleted or swept up again by a later tick - it is where settled history lives, not a queue for cleanup.

### Reclaiming resources

Herdr has no worktree-removal hook, so removing a worktree through Herdr's own UI (rather than `wt rm`) would otherwise leak its database, port, and redis db.
`wt gc` reconciles this: it checks each recorded worktree and, for any whose directory no longer exists, runs the profile's teardown and frees the reservation.
`wt new` runs it automatically, so orphans are always reclaimed on the next task - run `wt gc` yourself any time to clean up immediately.

`wt gc --settled` goes further and reclaims worktrees whose pull request has stopped moving - merged or closed - the case the orphan pass structurally cannot see, since a finished worktree is still a perfectly valid git worktree.
Only `open` is still live: one branch shipped and the other was abandoned, and neither has anything left to come back to.
It lists what it intends to take, and which verdict each row is, before taking any of it, and skips a repo whose PR state it could not read.

`wt gc --sweep` reclaims project-owned resources (databases, puma-dev entries) whose worktree is gone entirely, so no state file points at them any more.
It previews what it would reclaim first, since - unlike the other two passes - it deletes on a naming pattern rather than on a recorded fact.

## Requirements

Neovim 0.12+, plus a few CLI tools the config shells out to. Install with Homebrew:

```sh
brew install neovim ghostty tree-sitter-cli ripgrep fd asdf
```

- `neovim` - editor.
- `ghostty` - terminal.
- `tree-sitter-cli` - required by `nvim-treesitter` (main branch) to build parsers. The plain `tree-sitter` formula is the library only.
- `ripgrep`, `fd` - used by Telescope for find/grep.
- `asdf` - manages Ruby and Node runtimes; Mason needs both to install LSP servers.

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

1. `:Lazy sync` - install/update all plugins.
2. `:TSUpdate` - build Treesitter parsers.
3. `:Mason` - verify LSP servers installed (`lua_ls`, `ruby_lsp`, `stimulus_ls`, `herb_ls`, `tailwindcss`). Check `:MasonLog` if anything fails.

## Pulling local changes back into the repo

`import.sh` does the reverse of `install.sh` - pulls configs from `~/.config`, executables from `~/.local/bin`, and fonts back into the repo, but only for the files already tracked here (it never expands the managed set).

```sh
./import.sh
```
