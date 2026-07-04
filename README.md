# dotfiles

## About

Personal dotfiles for macOS. Manages:

- `~/.config/nvim` - Neovim config.
- `~/.config/ghostty` - Ghostty terminal config.
- `~/.config/tmux` - tmux config (Rose Pine theme, the worktree workflow keybindings, and the Claude session status glyphs in the window list).
- `~/.local/bin/wt` - worktree workflow backend driven by the tmux keybindings.
- `~/.local/bin/claude-tmux-signal` - Claude Code hook target that sets the tmux `@claude` window flag (working / waiting / done / clear) driving the status-bar glyph.
- `~/.local/bin/claude-tmux-spinner` - animates the ✻ "working" pulse in the tmux status bar while a Claude session is busy.
- `~/.claude/settings.json` - Claude Code settings; the `hooks` block wires the two scripts above (UserPromptSubmit → working, Notification → waiting, Stop → done, SessionEnd → clear). Git-tracked for reference but applied manually - `install.sh` does not touch `~/.claude`.
- Hack Nerd Font.

This repo keeps my personal configuration files - shell, editor, and tool configs - under version control, so the setup can be tracked over time and reused across machines.

### Claude Code tmux status

The tmux window list shows what each Claude session is doing, so background agents are visible at a glance:

- ✻ iris (animated pulse) - Claude is working.
- ● red - Claude needs your input.
- ● gold - Claude finished its turn; clears when you focus the window.
- no glyph - idle.

State lives per-window in the `@claude` tmux option.
`claude-tmux-signal` (run from the Claude Code hooks in `~/.claude/settings.json`) sets it on UserPromptSubmit/Notification/Stop/SessionEnd.
`claude-tmux-spinner` animates the ✻ frame while any window is working.
A `pane-focus-in` hook in `tmux.conf` clears the "done" dot when you look at the window, while "waiting" persists until you reply or exit Claude.

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
