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
This makes sure you find the real problem so your fix will actually solve it. You can use Claude in Chrome if enabled to do this.
- When end-to-end testing a product, be picky about the UI you see and be obsessed with pixel perfection.
If something clearly looks off, even if it is not directly related to what you are doing, try to get it fixed along the way.
- Apply that same high standard to engineering execellence: lint, test failures, and test flakiness.
If you see one, even if it is not caused by what you are working on right now, still get it fixed.
- When a plan has screens to build and no design exists for them, design them yourself during planning, as an Artifact - never ask Tom for a design file.
Ask the questions that shape the screens first, then start the design in a background fork and keep interviewing while it draws, so the design and the rest of the interview happen at the same time.
Have it ground the design in the app's real screens, components and classes, write it to `~/.claude/plans/designs/<Name>.dc.html`, and publish it privately from that path, so the file stays the artifact's source and every republish keeps the same link.
Show Tom the link as soon as it is published, so Tom can react to it while answering the rest.
Pass any later answer that changes a screen to the fork with SendMessage while it is still drawing, and once it has finished, edit the file and republish it yourself.
Writing that file and publishing it are allowed in plan mode; if the fork reports either was blocked, write and publish its draft yourself.
Do not present the plan for approval until the design is published and the plan cites both on their own lines, in every plan file of a series that touches those screens: `Design file: /Users/...` and `Design artifact: https://claude.ai/artifact/...`.
A plan that only describes a design in prose leaves the implementer with nothing to compare against; `pq` hands the file to the implementer and the link to whoever reviews the pull request.
- When work needs several pull requests, plan them as a series in a single line: one plan file per pull request, each building only on the one before it.
Never plan a pull request that builds on two others, or two that build on the same one - GitHub stacked pull requests, which `pq` uses for a series, only form a single line, so independent pieces go one after another.
Each plan file is all its implementer sees, so repeat the shared context, evidence and decisions in every file of the series.

## Tom's opinions

When you are working on something that would benefit from being informed by Tom's viewpoints, read ~/OPINIONS.md to understand what Tom believes.

## Voice profile

WHen you are talking/posting on behalf of Tom using his identity, read ~/VOICE.md to see how Tom talks.
