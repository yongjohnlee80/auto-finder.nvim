# auto-finder.nvim

A multi-section file explorer for Neovim. Wraps neo-tree for the
conventional filesystem view and stacks purpose-built sections
(git-worktree workspaces, SSH targets, database connections) alongside
it — all reachable from one window with a single command-driven
control surface.

> Status: **v0.1.0 — config + files sections.** Repos / remote / db
> sections are designed in
> [`docs/adr/0001-auto-finder-design.md`](docs/adr/0001-auto-finder-design.md)
> and ship in subsequent versions.

## At a glance

```
┌─ AutoFinder ────────── [0: config] [1: files] · ─┐
│                                                   │
│  (active section's buffer renders here)           │
│                                                   │
└───────────────────────────────────────────────────┘
```

- **Section 0 — config:** prompt-style admin REPL.
  Verbs: `focus <N|name>`, `panel resize <N>`, `panel reset`,
  `panel show`, `files show|hide hidden|dotfiles`, `reload`, `clear`,
  `quit`, `help`.
- **Section 1 — files:** vanilla neo-tree filesystem rendered into the
  panel window via `position = "current"`.
- Numeric `0..9` in normal mode inside the panel switches sections.
- The panel is left-anchored; the right slot is left free for sibling
  plugins (auto-agents.nvim, terminal splits, etc).

## What ships in v0.1.0

- **Single-window panel** with `winfixwidth` + `winfixbuf` protection
  so external `:edit` / `:buffer` / bufferline-click hijacks bounce
  off; the panel keeps its identity.
- **Width pinning with hard cap.** `panel resize N` pins the panel to
  N columns and forces neo-tree's `auto_expand_width` off on the live
  filesystem state — long filenames truncate at the pin instead of
  shoving the editor sideways. `panel reset` (alias `panel dynamic`)
  re-enables expansion.
- **Persistent state across restarts** — pin width and per-session
  filesystem filter prefs are stored under
  `stdpath('config')/.auto-finder/` and re-applied on the next setup.
- **Directory hijack on `nvim .`** — opens the panel at the requested
  cwd via a one-shot `VimEnter` hook (no autostart neo-tree window to
  fight with).
- **Tab-completion + clickable winbar** in the config REPL, including
  numeric width suggestions inside `[width.min .. width.max]`.
- **Files filter at runtime** — `files show hidden`, `files hide
  dotfiles` etc. mutate neo-tree's `filtered_items` and re-mount the
  section so the change is immediately visible.

## Requirements

- Neovim ≥ 0.10
- [`nvim-neo-tree/neo-tree.nvim`](https://github.com/nvim-neo-tree/neo-tree.nvim)

## Install (lazy.nvim)

```lua
{
  "yongjohnlee80/auto-finder.nvim",
  version = "^0.1.0",
  dependencies = { "nvim-neo-tree/neo-tree.nvim" },
  opts = {
    -- Width spec (pick ONE of `default` or `percentage`):
    --   `default`     fixed column count for the resting panel width
    --   `percentage`  fraction of `vim.o.columns`, clamped to [min..max]
    -- `min`/`max` bound `panel resize N` (the hard-cap pin).
    width = { default = 38, min = 25, max = 100 },
    default_section = 1,             -- 1 = files; 0 = the config REPL
    sections = { "config", "files" }, -- order also defines the index
    hijack_directories = true,       -- open panel for `nvim .`
  },
  keys = {
    { "<leader>e",  "<cmd>AutoFinder<cr>",         desc = "Explorer (auto-finder)" },
    { "<leader>E",  "<cmd>AutoFinder!<cr>",        desc = "Explorer (force, ignores width-guard)" },
    { "<leader>fe", "<cmd>AutoFinderFocus 1<cr>",  desc = "Explorer files" },
  },
}
```

## Commands

| Command                     | Effect                                     |
|-----------------------------|--------------------------------------------|
| `:AutoFinder[!]`            | Toggle the panel (`!` ignores width-guard) |
| `:AutoFinderFocus <N\|name>`| Switch to section N (or by name)           |
| `:AutoFinderResize <N>`     | Pin panel width to N columns (hard cap)    |
| `:AutoFinderReset`          | Clear the pin (back to dynamic mode)       |

## Usage — config REPL cheatsheet

Inside the panel, press `0` to focus the config section. Type `help`
for the full list, or any of these:

```
focus 1                 # jump to files section (numeric or name)
focus files             # same thing
panel resize 50         # pin width to 50 cols (hard cap)
panel reset             # release the pin (alias: panel dynamic)
panel show              # show mode / default / range / live width
files show hidden       # include .gitignored files in the tree
files hide dotfiles     # hide .* files
reload                  # re-render the active section
quit                    # close the panel (section buffers persist)
```

Tab-completion works on every verb, including numeric width
candidates inside the configured `[width.min .. width.max]` range.

## Roadmap

See [`docs/adr/0001-auto-finder-design.md`](docs/adr/0001-auto-finder-design.md)
for the full design rationale.

- **v0.1 — config + files** ← this release
- **v0.2 — repos** — registered repos × git worktrees, à la Bryan's
  `neo-tree-workspace`. Switch between worktrees from the panel
  without leaving nvim.
- **v0.3 — remote** — SSH targets, on-demand directory listings,
  scratch-buffer edits that round-trip via `rsync` / `scp`.
- **v0.4 — db** — read-only browser over registered database
  connections (LazySQL-compatible).

## License

MIT — © 2026 Yong Sung John Lee
