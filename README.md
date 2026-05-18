# auto-finder.nvim

A multi-section file explorer for Neovim. Wraps neo-tree for the
conventional filesystem view and stacks purpose-built sections
(git-worktree workspaces, SSH targets, database connections) alongside
it — all reachable from one window with a single command-driven
control surface.

> Status: **v0.2.18 — config + files + repos + dbase sections.** Remote
> section is designed in
> [`docs/adr/0001-auto-finder-design.md`](docs/adr/0001-auto-finder-design.md)
> and ships in a subsequent version.

## At a glance

```
┌─ AutoFinder ───── [0: config] [1: files] [2: repos] [3: dbase] · ─┐
│                                                                    │
│  (active section's buffer renders here)                            │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

- **Section 0 — config:** prompt-style admin REPL.
  Verbs: `focus <N|name>`, `panel resize <N>`, `panel reset`,
  `panel show`, `files show|hide hidden|dotfiles`,
  `dbase new|ls|rm|load`, `dbase conn add|ls|rm`,
  `reload`, `clear`, `quit`, `help`.
- **Section 1 — files:** vanilla neo-tree filesystem rendered into the
  panel window via `position = "current"`.
- **Section 2 — repos** *(v0.1.2+)***:** auto-discovered git repos ×
  worktrees, sourced entirely from worktree.nvim. Each repo under
  `worktree.nvim`'s `root` renders as a top-level workspace node,
  with each git worktree as a child and ordinary directories below
  that. No registry, no manual `add` — what worktree.nvim sees is
  what shows up. fs_event watchers refresh the tree automatically
  when worktrees are added/removed externally.
- **Section 3 — dbase** *(v0.2.16+)***:** nvim-dbee drawer mounted
  inside the panel window. Soft dep on `kndndrj/nvim-dbee` — section
  renders a placeholder when missing. `<CR>` on a connection node
  sets it active and mounts the companion editor/result panes;
  `o` toggles expand/collapse on the schema tree. Connection files
  are managed from the config REPL (`dbase new`, `dbase load`,
  `dbase conn add`, …) so you don't need to author dbee `Source`
  instances by hand.
- Numeric `0..9` in normal mode inside the panel switches sections.
- The active section is **persisted** across `nvim` restarts — the
  panel re-opens on the slot you were last on.
- The panel is left-anchored; the right slot is left free for sibling
  plugins (auto-agents.nvim, terminal splits, etc).

## What ships in v0.1.2

- **Repos section (slot 2)** — auto-discovered repos × git worktrees
  view, ported from Bryan Cua's `neo-tree-workspace` source.
  - **Single source of truth — worktree.nvim.** Discovery (which
    dirs are git, what counts as a worktree, the bare-vs-`.git`
    layout detection) and the active root come from worktree.nvim
    via `require("worktree").get_root()` +
    `require("worktree.git").list_child_repos(root)`. No registry,
    no manual `add` — what worktree.nvim sees, the panel shows.
  - Worktree paths exposed for consumer keymaps:
    `require("auto-finder").repos.worktree_paths()` returns the flat
    list of every non-bare worktree under worktree.nvim's root.
    Lets you wire e.g. an `<leader><leader>` files-finder that
    scopes pick queries to the active workspace.
  - When worktree.nvim isn't installed, the panel renders an
    empty-state placeholder explaining the dependency rather than
    throwing.
- **Active section persists across restarts** — the slot you last
  focused is saved in
  `<stdpath('config')>/.auto-finder/config.json` under
  `panel.last_section` and restored on next `setup()`.
- **Per-section config forwarding** — `opts.repos = { window = {
  mappings = { ... } } }` (and similarly `opts.files`) are
  deep-merged into the corresponding neo-tree source's default
  config. Consumers can inject their own keymaps without forking.

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
- [`auto-core.nvim`](https://github.com/yongjohnlee80/auto-core.nvim) `^0.1.0`
  — foundation library (panel / state / log / ui.section / fs.watch / files
  surfaces auto-finder consumes as of v0.2.0). Hard dep.
- [`MunifTanjim/nui.nvim`](https://github.com/MunifTanjim/nui.nvim),
  [`nvim-lua/plenary.nvim`](https://github.com/nvim-lua/plenary.nvim),
  [`nvim-tree/nvim-web-devicons`](https://github.com/nvim-tree/nvim-web-devicons)
  — required by the bundled neo-tree fork (auto-finder ships its own fork
  under `lua/auto-finder/neotree/` since v0.1.3; the upstream
  `nvim-neo-tree/neo-tree.nvim` plugin is **no longer required and should
  not be installed alongside** — it conflicts with the bundled fork).
- [`kndndrj/nvim-dbee`](https://github.com/kndndrj/nvim-dbee) — soft dep
  for the **dbase** section (v0.2.16+). When absent, the section renders
  a placeholder buffer explaining the dependency; the rest of the panel
  is unaffected. Consumers should wire dbee as a hard dep with a `build`
  hook so the dbee Go binary lands on `:Lazy sync` (see the install
  snippet below). Setup of dbee is owned by auto-finder's
  `_dbase_setup` module — **do not add a `config` function to the dbee
  spec** in your lazy plugin list or the two setups will collide.

## Install (lazy.nvim)

```lua
{
  "yongjohnlee80/auto-finder.nvim",
  version = "^0.2.0",  -- v0.2.0 is the auto-core consumer release
  dependencies = {
    "yongjohnlee80/auto-core.nvim",   -- foundation library; hard dep as of v0.2.0
    "MunifTanjim/nui.nvim",           -- bundled neo-tree fork's deps
    "nvim-lua/plenary.nvim",
    "nvim-tree/nvim-web-devicons",
    -- nvim-dbee for the dbase section (v0.2.16+). The `build` hook
    -- downloads dbee's Go binary so first launch is ready-to-run.
    -- IMPORTANT: do not add a `config` function — setup is owned by
    -- auto-finder.sections._dbase_setup.
    {
      "kndndrj/nvim-dbee",
      build = function()
        require("dbee").install()
      end,
    },
  },
  opts = {
    -- Width spec (pick ONE of `default` or `percentage`):
    --   `default`     fixed column count for the resting panel width
    --   `percentage`  fraction of `vim.o.columns`, clamped to [min..max]
    -- `min`/`max` bound `panel resize N` (the hard-cap pin).
    width = { default = 38, min = 25, max = 100 },
    default_section = 1,                                -- 1 = files; 0 = config; 2 = repos; 3 = dbase
    sections = { "config", "files", "repos", "dbase" }, -- order also defines the index
    hijack_directories = true,                          -- open panel for `nvim .`
    -- Per-section configs deep-merged into the underlying neo-tree
    -- source. Use this to inject custom keymaps without forking the
    -- plugin. Discovery / root / bare_dir live in worktree.nvim,
    -- not here.
    repos = {
      window = { mappings = {} },  -- e.g. ["<C-x>"] = "close_node"
    },
    files = {
      window = { mappings = {} },
    },
    -- dbase forwards directly to dbee.setup(). `sources` is a list of
    -- dbee Source instances; when nil/empty the section falls back to
    -- an empty MemorySource so the drawer renders against a benign
    -- baseline. `extra` is a passthrough merged into `dbee.setup`'s
    -- config — escape hatch for per-tile dbee options. See the
    -- DBase section below for the connection-file workflow that
    -- replaces hand-managing this from your config.
    dbase = {
      sources = nil,  -- e.g. { require("dbee.sources").FileSource:new(path) }
      extra = nil,
    },
  },
  keys = {
    { "<leader>e",  "<cmd>AutoFinder<cr>",         desc = "Explorer (auto-finder)" },
    { "<leader>E",  "<cmd>AutoFinder!<cr>",        desc = "Explorer (force, ignores width-guard)" },
    { "<leader>fe", "<cmd>AutoFinderFocus 1<cr>",  desc = "Explorer files" },
  },
}
```

> **Caret pin (`^0.2.0`)**: future v0.2.x releases auto-include without a
> manual bump. The `auto-core` family follows an additive-only minor-bump
> rule — no v0.X.Y release renames, removes, or break-shapes any existing
> public surface. Crossing to a future v0.3.0 requires bumping the caret
> deliberately.

> **Already running upstream `neo-tree.nvim`?** Disable it explicitly so it
> doesn't conflict with the bundled fork:
> ```lua
> { "nvim-neo-tree/neo-tree.nvim", enabled = false }
> ```

## Commands

| Command                     | Effect                                                         |
|-----------------------------|----------------------------------------------------------------|
| `:AutoFinder[!]`            | Toggle the panel (`!` ignores width-guard)                     |
| `:AutoFinderFocus <N\|name>`| Switch to section N (e.g. `:AutoFinderFocus dbase` — v0.2.16+) |
| `:AutoFinderResize <N>`     | Pin panel width to N columns (hard cap)                        |
| `:AutoFinderReset`          | Clear the pin (back to dynamic mode)                           |

## Usage — config REPL cheatsheet

Inside the panel, press `0` to focus the config section. Type `help`
for the full list, or any of these:

```
focus 1                 # jump to files section (numeric or name)
focus files             # same thing
focus repos             # jump to the auto-discovered repos / worktrees section
focus dbase             # jump to the nvim-dbee drawer (v0.2.16+)
panel resize 50         # pin width to 50 cols (hard cap)
panel reset             # release the pin (alias: panel dynamic)
panel show              # show mode / default / range / live width
files show hidden       # include .gitignored files in the tree
files hide dotfiles     # hide .* files
reload                  # re-render the active section
quit                    # close the panel (section buffers persist)

# DBase connection-file management (v0.2.18+)
dbase new <name>        # create empty connections file (`.json` auto-appended)
dbase ls                # list available connections files
dbase rm <name>         # delete a connections file
dbase load [name]       # load file as active (prompts if name omitted)
dbase conn add          # prompt for name/type/url, append to active file
dbase conn ls           # list connections in the active file
dbase conn rm <name>    # remove a connection by name
```

(Repo / worktree mutations are owned by worktree.nvim — use its
`<leader>gw` / `<leader>gA` / `<leader>gC` / `<leader>gc` keymaps
to switch / add / clone / init worktrees. The auto-finder repos panel
just renders whatever worktree.nvim is currently tracking.)

Tab-completion works on every verb, including numeric width
candidates inside the configured `[width.min .. width.max]` range.

## DBase section — nvim-dbee inside the panel

The **dbase** section (v0.2.16+) mounts the nvim-dbee drawer directly
into the auto-finder panel as one of the section tabs. Selecting a
connection there sets it active across dbee — `:Dbee` opens the editor
+ result panes against the same connection, and cmp-dbee's completion
in SQL scratchpads sees the connection's schema.

### Inside the drawer

| Key      | Action                                                           |
|----------|------------------------------------------------------------------|
| `o`      | Toggle expand / collapse on the focused node (schema tree)       |
| `<CR>`   | Set the connection active **and** mount the editor + result panes (auto-finder override of dbee's stock primary action) |
| `cw`     | Rename / edit the focused node (dbee default)                    |
| `dd`     | Delete the focused node (dbee default)                           |
| `r`      | Refresh the node (dbee default)                                  |

The `<CR>` override exists because dbee's stock `<CR>` calls
`editor:set_current_note`, which silently no-ops if the editor window
hasn't been bound yet. Auto-finder mounts the companion editor/result
panes first, then forwards to dbee — so notes always render the first
time.

### Connection files (v0.2.18+)

Rather than hand-authoring `dbee` Source instances in your lazy config,
the config REPL manages JSON connection files for you:

```
0                       # focus the config section (REPL)
dbase new work          # creates work.json under auto-finder's dbase dir
dbase load work         # makes work.json the active source
dbase conn add          # prompts for name / type / url, appends to work.json
3                       # focus the dbase section — drawer renders the new entry
```

Files live under `stdpath('config') .. /auto-finder/dbase/`. Each file
is loaded as a separate dbee `FileSource`. `dbase load <name>` swaps
the active source without restarting; the drawer re-renders against
the new connections automatically.

If you'd rather pin sources from your lazy spec (e.g. an `EnvSource`
that reads `DBASE_CONNECTIONS` for secrets injected from `pass` or
1Password), pass them through `opts.dbase.sources` — those are merged
with any FileSource the REPL loads.

## Roadmap

See [`docs/adr/0001-auto-finder-design.md`](docs/adr/0001-auto-finder-design.md)
for the full design rationale.

- **v0.1.0 — config + files**
- **v0.1.2 — repos** (auto-discovered repos × git worktrees view,
  ported from Bryan Cua's `neo-tree-workspace`; worktree.nvim is the
  discovery source-of-truth; active-section persistence; per-section
  config forwarding).
- **v0.2.0 — auto-core consumer migration** (panel singleton via
  `auto-core.ui.panel`, state via `auto-core.state.namespace`,
  file-filter prefs via `auto-core.files`, live-refresh via
  `auto-core.fs.watch`, sections via `auto-core.ui.section` +
  `worktree:switched`).
- **v0.2.16 — dbase** ← nvim-dbee drawer as a panel section. Soft
  dep on nvim-dbee; drawer mounts inside the panel window via
  `dbee.api.ui.drawer_show`; `<CR>` override mounts the companion
  editor/result panes first so notes render reliably.
- **v0.2.18 — dbase connection-file management** ← the config REPL
  grew `dbase new|ls|rm|load` and `dbase conn add|ls|rm` verbs so
  connections are managed without touching your lazy spec.
- **Next — remote** — SSH targets, on-demand directory listings,
  scratch-buffer edits that round-trip via `rsync` / `scp`.

## License

MIT — © 2026 Yong Sung John Lee
