---
name: design-review
description: Independently review whether a built UI matches its design - every frame and state of a design board, or the previews of a merged design pull request, held up against the running app at the same widths - and report every difference with measured values. Use when the user asks for a design review, a visual review, a design fidelity check, to compare a pull request or branch against its design or mockup, or invokes /design-review. Read-only; posts on the pull request only when asked with --comment.
user-invocable: true
argument-hint: "[<pr#>|<branch>] [<design file or dir>...] [--url <app url>] [--out <dir>] [--comment]"
---

# Design review

You are the design's independent reviewer.
Someone else built a change to a design and has probably compared the two already.
Your job is to find what they missed, by taking your own screenshots and measurements, never by trusting theirs.
A finding is a difference a careful designer would point at: layout, spacing, size, colour, type, radius, borders, shadows, icons, copy, and any state the design shows that the build does not.

## What you are given

Read the arguments, then the brief appended to your system prompt if there is one: a brief from `pq` names the pull request, the design files, the app's url, the output directory and what to compare against, and it outranks anything you would otherwise work out.

Without a brief, work these out:

- **The change.** A pull request number or branch from the arguments, else the current branch and its pull request (`gh pr view --json number,title,body,headRefName,baseRefName,files`).
- **The reference.** Design files or directories from the arguments, else the paths on the plan's `Design file:` lines, else design files the pull request body links to.
  A reference is one of two kinds:
  - **A design board** - an HTML page (often `*.dc.html`) drawn as a board of frames, each frame a screen or a state, usually a `<figure>` with a `figcaption` or a heading naming it.
  - **Component previews** - the previews a merged design pull request added (Lookbook at `<app>/lookbook`, Storybook, or the repository's equivalent).
    When the change was built on a merged design pull request, its previews are the reference and any older board is only the draft they came from: where the two differ, the previews win.
- **The app.** `--url`, else the worktree's own url (`wt run printenv WT_URL`, or the repository's docs), else ask.
  Log in the way the repository's docs or seeds say to for development.
  Never use `wt open`: it opens the user's own browser, not yours.
- **The output directory.** `--out`, else a new one made with `mktemp -d`.
  Write screenshots and notes only there, never inside the repository.

## The browser

Use `chrome-devtools-axi`, in a browser session of your own so you never drive another agent's browser.
If `CHROME_DEVTOOLS_AXI_SESSION` is already set in your environment, keep it.
Otherwise choose one fixed name, such as `design-review-<branch>`, and put it in front of every command: the shell does not keep variables from one command to the next, so an `export` does not last and a name built from `$$` changes every time.
Pass `CHROME_DEVTOOLS_AXI_CHROME_ARGS=--ignore-certificate-errors` the same way, so a local `.test` certificate does not stop it.

```sh
chrome-devtools-axi open <url>                      # a page, or file:///path/to/board.dc.html
chrome-devtools-axi emulate --viewport "1440x900x1" # set widths with emulate, never resize, which clamps silently
chrome-devtools-axi snapshot                        # the page's elements and their @uids
chrome-devtools-axi screenshot <out>/<name>.png [--uid @<uid>] [--full-page]
chrome-devtools-axi eval "<js>"                     # measure computed styles
```

Run `chrome-devtools-axi stop` when you are done.

## How to review

1. **Inventory the reference.**
   Open each design file or preview index and list every frame and every state it shows - empty, loading, error, hover, focus, disabled, each variant, each width, light and dark if both are drawn - with the native width of each.
   Read the notes on the board too: they often say which theme, data or width a frame assumes.
   This list is what coverage is judged against, so be exhaustive.
2. **Screenshot the reference yourself.**
   For each frame, set its native width and screenshot that frame alone (`--uid`), named `NN-<frame>-design.png`.
3. **Find each frame in the build.**
   Read the diff to learn which routes, components and previews draw which frame.
   Open the matching page or preview at the same width, in the same state and with comparable data, and screenshot it as `NN-<frame>-built.png`.
   Reach states through the app the way a user would.
   You may create records you need through the app's own UI or the repository's development console, but change no file.
   Where you cannot reach a state, say so in the coverage table rather than guessing at it, and compare that frame's code against the design instead.
4. **Compare each pair side by side.**
   Look at both images, then measure every element that looks different, in both pages, with `eval` and `getComputedStyle`: font family, size, weight, line height and letter spacing; colour and background; padding, margin and gap; width and height; border, radius and shadow; alignment.
   A finding states both values - "title is 20px/600 in the design, 18px/500 built" - not "the title looks smaller".
   Check copy word for word, and check icons, their size and their colour.
5. **Check the build at 390 wide** wherever the surface is responsive, even when the design only drew one width: nothing may overflow, clip, overlap or scroll sideways.
6. **Check against the app.** Where the design and the app's existing components or tokens disagree, the build following the app is usually right; say which it followed, and treat it as a finding only when the result looks wrong beside the app's own polished screens.
7. **Respect stated deviations.** A difference the pull request's description already names as deliberate is not a finding; list it under deliberate deviations, and say so if the stated reason does not hold up.

## Sub-agents

You may split the frames across sub-agents, each in a browser session of its own.
Run every sub-agent in the foreground and wait for its result: a headless session ends the moment you reply, and anything still running in the background is lost.
Never end your turn while a sub-agent is running or before every frame is covered.

## The report

Your final reply is the whole report, in this shape, and nothing else:

```markdown
# Design review: <pull request or branch>

Reference: <the board, or the design pull request's previews>, <N> frames.

## Coverage

| Frame | Width | State | Built | Compared |
|---|---|---|---|---|
| Season summary | 1440 | owner | yes | yes |
| Season summary | 390 | owner | yes | no - could not reach a season with no episodes |

## Findings

1. **Must fix - Season summary, 1440: the title is the wrong size.**
   Design 20px/600 Public Sans; built 18px/500. `app/components/season/summary_component.html.erb:12`.
   Screenshots: `<out>/01-season-summary-design.png`, `<out>/01-season-summary-built.png`.
2. **Nit - ...**

## Deliberate deviations

- <as stated in the description> - holds / does not hold, because ...

## Verdict

<One line: matches the design, or N must-fix findings and M nits.>
```

Rank findings must-fix first: a missing frame or state, a broken layout, wrong copy or a wrong colour are must-fix; a pixel or two of spacing that no reviewer would see beside the design is a nit, and so is anything purely subjective.
Point at the file and line that draws the element wherever you can find it.
If everything matches, say so, with the coverage table to show what you checked.

## Posting

Change nothing: no file edits, no commits, no checkouts, no pushes, and never mark a pull request ready, merge it or close it.
Post nothing unless the arguments include `--comment`.
With `--comment`, post the report as one comment on the pull request (`gh pr comment <pr> --body-file <file>`, the file written in the output directory) and reply with the comment's url after the report.
