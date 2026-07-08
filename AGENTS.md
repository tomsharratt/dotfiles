# Tom's agent instructions

These are common instructions for Tom's agents across all scenarios.

## General guidelines

- Never use em dash "—". Use plain dash "-" instead.
- When writing commit messages, NEVER auto-add your agent name as co-author.
- Never manually modify CHANGELOG.md files or any files that are marked as auto-generated.
- When writing or substantially editing long Markdown files, put each full sentence on its own line. 
Preserve normal Markdown structure, but avoid wrapping multiple sentences onto one physical line.
- When making technical decisions, do not give much weight to development cost.
Instead, prefer quality, simplicity, robustness, scalability, and long term maintainability.
- When doing bug fixes, always start with reproducting the bug in an E2E setting as closely aligned with how an end user would experience it as possible.
This makes sure you find the real problem so your fix will actually solve it.
- When end-to-end testing a product, be picky about the UI you see and be obsessed with pixel perfection.
If something clearly looks off, even if it is not directly related to what you are doing, try to get it fixed along the way.
- Apply that same high standard to engineering execellence: lint, test failures, and test flakiness.
If you see one, even if it is not caused by what you are working on right now, still get it fixed.

## Herdr worktrees & agent orchestration

Applies only when running inside Herdr (`$HERDR_ENV = 1`); Herdr owns worktrees, panes, and agent status.

**Isolated worktrees - use `wt`, never raw git.**
`wt new <branch>` creates a worktree through Herdr and provisions it in full isolation (own db, redis index, port, `<name>.test` url) from the repo's profile, then starts its dev server + Claude.
Never `git worktree add/remove` or remove a worktree from Herdr's UI - that leaks the db/port/redis.
Tear down with `wt rm <name>`; `wt gc` reclaims orphans; `wt ls` lists allocations.
Isolation is per-project (`<repo>/.wt/profile.sh` or `~/.config/wt/profiles/<repo>.sh`).
Usage: run `wt` with no args.

**Driving sibling agents.**
To fan work out to real parallel agents the human can also watch: `herdr agent start <name> --cwd <path> -- claude` (or `wt new` for a fully isolated worktree), then `herdr agent send <target> "<task>"`, `herdr agent wait <target> --status idle`, `herdr agent read <target>`; `herdr agent list` shows all.
Prefer built-in subagents/Task for in-process fan-out; use herdr agents only when you need isolated worktrees or live dev servers running in parallel.
Reference: `herdr <subcommand> --help`.

## Tom's opinions

When you are working on something that would benefit from being informed by Tom's viewpoints, read ~/OPINIONS.md to understand what Tom believes.

## Voice profile

WHen you are talking/posting on behalf of Tom using his identity, read ~/VOICE.md to see how Tom talks.
