# dotfiles

Personal dotfiles for macOS. Manages `~/.config/nvim`, `~/.config/ghostty`, and Hack Nerd Font.

## Repository Layout

Each directory under `.config/` mirrors the same path under `$HOME`, so `.config/<name>` maps to `~/.config/<name>`.
Fonts are the exception: `install.sh` copies each `.config/<name>` into `~/.config/<name>`, and `.local/share/fonts` into the OS font directory (`~/Library/Fonts` on macOS).

```
.
├── .config/                          App configs, synced into ~/.config
│   ├── ghostty/
│   │   └── config
│   └── nvim/
│       ├── init.lua
│       ├── lazy-lock.json
│       └── lua/
│           └── plugins/              One Lua file per plugin topic
├── .local/
│   └── share/
│       └── fonts/                    Bundled fonts, installed to the OS font dir
│           └── HackNerdFont-Regular.ttf
├── install.sh                        Sync repo configs into the environment
├── import.sh                         Pull environment configs back into the repo
└── README.md
```

### Config directories

| Directory | Purpose |
| --- | --- |
| `.config/ghostty/` | Ghostty terminal emulator. The single `config` file sets the font, window padding, background opacity, one keybinding, and the duskfox color palette. Edit it to change how the terminal looks or behaves. |
| `.config/nvim/` | Neovim, managed by lazy.nvim. `init.lua` holds core options, remaps, and the lazy.nvim bootstrap; `lazy-lock.json` pins plugin versions; `lua/plugins/` has one spec file per topic (a file may bundle several related plugins, as `lsp.lua` does). Edit these to change editor behavior or add and remove plugins. |
| `.local/share/fonts/` | Fonts bundled with the repo. Currently just `HackNerdFont-Regular.ttf`, used by both the terminal and Neovim. Edit only to add or update a font. |

The `lua/plugins/` specs cover Claude Code (`claudecode.lua`), git (`fugitive.lua`), file navigation (`harpoon.lua`), LSP and Mason (`lsp.lua`), quality-of-life helpers (`snacks.lua`), fuzzy finding (`telescope.lua`), the colorscheme (`theme.lua`), and Treesitter (`treesitter.lua`).

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

`install.sh` rsyncs each `.config/<name>` into `~/.config/<name>` and copies fonts into `~/Library/Fonts` (macOS) or `~/.local/share/fonts` (Linux).

## First-time Neovim setup

On first launch, lazy.nvim bootstraps itself and pulls plugins. After that:

1. `:Lazy sync` — install/update all plugins.
2. `:TSUpdate` — build Treesitter parsers.
3. `:Mason` — verify LSP servers installed (`lua_ls`, `ruby_lsp`, `stimulus_ls`, `herb_ls`, `tailwindcss`). Check `:MasonLog` if anything fails.

## Pulling local changes back into the repo

`import.sh` does the reverse of `install.sh` — pulls configs from `~/.config` back into the repo for anything already tracked here.

```sh
./import.sh
```
