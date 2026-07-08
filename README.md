# dotfiles

## About

Personal dotfiles for macOS. Manages:

- `~/.config/nvim` - Neovim config.
- `~/.config/ghostty` - Ghostty terminal config.
- `~/.config/tmux` - tmux config (Rose Pine theme; splits inherit the pane's directory).
- `~/.config/herdr` - Herdr config: the theme and the `prefix+t` worktree keybinding. Only `config.toml` is tracked; Herdr's sockets, logs, and session state are excluded from sync.
- `~/.local/bin/wt` - worktree workflow backend: creates an isolated worktree (its own database, redis db, url and port) through Herdr, provisions it, and starts the dev server + Claude on it. Project-agnostic; the per-project steps live in profiles.
- `~/.config/wt/profiles/<repo>.sh` - per-project provisioning + dev-server steps for `wt` (e.g. `supercast.sh`).
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
A profile declares which resources to allocate and defines `wt_provision`, `wt_dev`, and `wt_teardown`.
A repo with no profile still gets a worktree + Claude - it just has no dev server.

For `supercast` (`~/.config/wt/profiles/supercast.sh`) each worktree gets:

- its own postgres database - a logical copy of `supercast-web_development`, so migrations and data changes never touch the shared dev db or the other worktrees;
- its own redis db index, so Sidekiq queues don't collide;
- its own puma-dev url `https://<name>.test` on its own port.

So `wt new premier-video` and `wt new spotify-reconcile` can run side by side, each serving its own url against its own database, with no handoff between them.
The app needs no changes for this: its `database.yml`, `sidekiq.rb`, and `development.rb`/`session_store.rb` already honor `DATABASE_URL` / `REDIS_URL` / `LOCAL_DOMAIN`, and `config.hosts.clear` allows any `*.test` host.
The profile injects the port by generating a per-worktree Procfile (the tracked `Procfile.dev` pins the web port to 3000), written outside the repo so the checkout stays clean.

Commands:

```
wt new [name]        create/open an isolated worktree, provision, start dev + Claude
wt dev  <path>       run a worktree's dev server (this is the dev pane's command)
wt provision <path>  re-run provisioning for a worktree (idempotent)
wt rm  [name]        tear a worktree down (drop db, free port, remove worktree)
wt ls                list worktrees with their allocated port / redis / url / db
wt gc                reclaim resources from worktrees removed outside wt rm
```

Herdr has no worktree-removal hook, so removing a worktree through Herdr's own UI (rather than `wt rm`) would otherwise leak its database, port, and redis db.
`wt gc` reconciles this: it checks each recorded worktree and, for any whose directory no longer exists, runs the profile's teardown and frees the reservation.
`wt new` runs it automatically, so orphans are always reclaimed on the next task - run `wt gc` yourself any time to clean up immediately.

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
