# auto-finder.nvim

A multi-view side panel for Neovim. One window hosts purpose-built
**views** — filesystem, open buffers, git worktrees, an
nvim-dbee drawer, and a prompt-style config REPL — each reachable
with a single keystroke.

Built on top of [`auto-core.nvim`](https://github.com/yongjohnlee80/auto-core.nvim)
(panel + state + event-bus primitives) and a vendored fork of
neo-tree (filesystem rendering). The internal architecture is
documented in [`ARCHITECTURE.md`](./ARCHITECTURE.md); this README
is the user-facing surface.

## At a glance

```
┌─ auto-finder ──── [0: config] [1: files] [2: repos] [3: dbase] · ─┐
│                                                                    │
│  (active view's buffer renders here)                               │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

- One panel, many views. Numeric `0..9` in normal mode switches
  views instantly.
- The active view is **persisted across nvim restarts** — the
  panel re-opens on the view you were last on.
- The panel is left-anchored with `winfixwidth` + `winfixbuf`
  protection — external `:edit` / `:buffer` / bufferline-click
  hijacks bounce off and the panel keeps its identity.
- Width is pinnable (`panel resize N`) as a hard cap; long
  filenames truncate at the pin instead of shoving the editor
  sideways.

## What ships

Five views in the box:

| # | View | What it shows |
|--:|---|---|
| 0 | **config** | Prompt-style admin REPL. Switch views, resize, toggle file filters, manage dbase connections. Tab-completion + clickable winbar throughout. |
| 1 | **files** | Filesystem tree (neo-tree filesystem source). Live-refresh on filesystem events; git status decorations from the auto-core git layer. |
| 2 | **repos** | Auto-discovered git repos × worktrees from [`worktree.nvim`](https://github.com/yongjohnlee80/worktree.nvim). No registry, no manual add — what worktree.nvim sees is what shows up. fs_event watchers refresh on worktree mutations. |
| 3 | **buffers** | Open-buffer list (neo-tree buffers source). Mirrors `:ls`, including unloaded buffers added via `:badd` or session restore. Tracked via Buf* autocmds through the core's buffer cache. |
| 4 | **dbase** | [`nvim-dbee`](https://github.com/kndndrj/nvim-dbee) drawer mounted inside the panel. Soft dep — renders a placeholder buffer if dbee isn't installed. Connection vaults are at-rest encrypted (via `age` / `gpg`) and managed from the config REPL. |

Plus the foundations behind the views, all centralized in
`lua/auto-finder/core/`:

- **Centralized caches** for the file tree, git status, buffer
  list, and repos registry. Today views still render through
  neo-tree's `manager.refresh` path on receiving a translated
  event; the cache surface exists so a future phase can flip
  views to delta-rendering directly from `core.<area>.snapshot_now()`
  (see [`ARCHITECTURE.md`](./ARCHITECTURE.md) for the
  implemented-vs-future-work breakdown). What changes today:
  views subscribe to translated `auto-finder.core.*` topics
  rather than driving each refresh themselves.
- **Re-armable lifecycle** — every subscription survives an
  `auto-core.events` bus reset (e.g. `:Lazy reload`) via
  unconditional dispose-first-then-resubscribe on
  `core.ensure_started`.
- **Centralized `fs.watch` + `git.watch` handle ownership** —
  one set of OS-level watchers per cwd, not one set per view.
  Survives view switches and panel-close.
- **Event coalescing** — a burst of 100 file events in one
  window (build output, branch switch, `npm i`) becomes a
  single refresh call. Bursts that cluster under one parent
  directory promote to `subtree_stale` invalidation rather
  than per-file event reassembly (the upstream `fs.watch`
  can't supply paired rename events anyway).

For the full structural picture — directory layout, module
responsibilities, system + event-flow mermaid diagrams,
auto-core dependency surface, and per-event-source detection +
processing — see [`ARCHITECTURE.md`](./ARCHITECTURE.md).

## Requirements

- **Neovim ≥ 0.10**
- [`auto-core.nvim`](https://github.com/yongjohnlee80/auto-core.nvim)
  `^0.1.58` — foundation library (panel singleton, state
  namespace, event bus, `fs.watch`, `git.watch`, `git.status`,
  centralized log, and the `fs.atomic` write primitive that
  auto-finder's dbase/todos persistence delegates to as of
  v0.2.55 / ADR-0040 Batch B). **Hard dep.**
- [`MunifTanjim/nui.nvim`](https://github.com/MunifTanjim/nui.nvim),
  [`nvim-lua/plenary.nvim`](https://github.com/nvim-lua/plenary.nvim),
  [`nvim-tree/nvim-web-devicons`](https://github.com/nvim-tree/nvim-web-devicons)
  — required by the bundled neo-tree fork.
- **Do not install upstream `nvim-neo-tree/neo-tree.nvim`
  alongside** — auto-finder ships its own fork under
  `lua/auto-finder/neotree/` (since v0.1.3) and the two will
  collide on the same require path. Disable upstream
  explicitly if you had it installed: `{ "nvim-neo-tree/neo-tree.nvim", enabled = false }`.
- [`kndndrj/nvim-dbee`](https://github.com/kndndrj/nvim-dbee) —
  soft dep for the **dbase** view. When absent, the view shows
  a placeholder explaining the dependency; the rest of the
  panel is unaffected.
- [`yongjohnlee80/worktree.nvim`](https://github.com/yongjohnlee80/worktree.nvim)
  — required by the **repos** view. When absent, the repos
  view renders empty.

## Install (lazy.nvim)

```lua
{
  "yongjohnlee80/auto-finder.nvim",
  version = "^0.2.0",
  dependencies = {
    "yongjohnlee80/auto-core.nvim",       -- foundation; hard dep
    "MunifTanjim/nui.nvim",               -- bundled neo-tree fork deps
    "nvim-lua/plenary.nvim",
    "nvim-tree/nvim-web-devicons",
    -- nvim-dbee — soft dep for the dbase view. The `build` hook
    -- downloads dbee's Go binary so first launch is ready-to-run.
    -- IMPORTANT: do not add a `config = function() ... end` here;
    -- auto-finder owns dbee.setup via its internal setup module.
    {
      "kndndrj/nvim-dbee",
      build = function() require("dbee").install() end,
    },
  },
  opts = {
    -- Width spec — pick ONE of `default` or `percentage`.
    --   `default`     fixed column count for the resting panel
    --   `percentage`  fraction of vim.o.columns, clamped to [min..max]
    -- `min` / `max` also bound `panel resize N`'s hard-cap pin.
    width = { default = 38, min = 25, max = 100 },

    default_section = 1,  -- 1 = files; 0 = config; etc.

    -- Views the panel hosts, in order. The order also defines
    -- the numeric index used by `0..9` and `:AutoFinderFocus N`.
    sections = { "config", "files", "repos", "buffers", "dbase" },

    -- Open the panel for `nvim .` style directory invocations.
    hijack_directories = true,

    -- Per-view opts. Each is forwarded to the underlying neo-tree
    -- source's deep-merged config. Use this to inject custom
    -- keymaps without forking the plugin.
    files   = { window = { mappings = {} } },
    repos   = { window = { mappings = {} } },
    buffers = { window = { mappings = {} } },

    -- dbase forwards to dbee.setup. `sources` is a list of dbee
    -- Source instances; nil/empty falls back to the connection-
    -- file workflow managed by the config REPL (recommended).
    dbase = { sources = nil, extra = nil },
  },
  keys = {
    { "<leader>e",  "<cmd>AutoFinder<cr>",        desc = "auto-finder: toggle panel" },
    { "<leader>E",  "<cmd>AutoFinder!<cr>",       desc = "auto-finder: toggle (force, ignores width-guard)" },
    { "<leader>fe", "<cmd>AutoFinderFocus 1<cr>", desc = "auto-finder: focus files view" },
  },
}
```

> **Caret pin (`^0.2.0`)**: future v0.2.x releases auto-include
> without a manual bump. The plugin holds an additive-only
> minor-bump contract — v0.2.x releases never rename, remove,
> or break-shape any existing public surface. Crossing to
> v0.3.0 (when it eventually lands) requires bumping the caret
> deliberately.

## Commands

| Command                      | Effect                                                          |
|------------------------------|-----------------------------------------------------------------|
| `:AutoFinder[!]`             | Toggle the panel (`!` ignores width-guard)                      |
| `:AutoFinderFocus <N\|name>` | Switch to view N (e.g. `:AutoFinderFocus dbase`)                |
| `:AutoFinderResize <N>`      | Pin panel width to N columns (hard cap)                         |
| `:AutoFinderReset`           | Clear the pin (back to dynamic width)                           |

## Config REPL cheatsheet

Inside the panel, press `0` to focus the config view. Type
`help` for the full list, or any of these:

```
focus 1                  # jump to files (numeric or name)
focus files              # same thing
focus repos              # jump to the repos × worktrees view
focus dbase              # jump to the nvim-dbee drawer
panel resize 50          # pin width to 50 cols (hard cap)
panel reset              # release the pin (alias: panel dynamic)
panel show               # show mode / default / range / live width
files show hidden        # include .gitignored files in the tree
files hide dotfiles      # hide .* files
reload                   # re-render the active view
quit                     # close the panel (view buffers persist)

# DBase connection-file management
dbase new <name>         # create empty connections file
dbase ls                 # list available connections files
dbase rm <name>          # delete a connections file
dbase load [name]        # load file as active (prompts if name omitted)
dbase conn add           # prompt for name/type/url, append to active file
dbase conn ls            # list connections in the active file
dbase conn rm <name>     # remove a connection by name
```

(Worktree mutations are owned by `worktree.nvim` — use its
`<leader>gw` / `<leader>gA` / `<leader>gC` / `<leader>gc`
keymaps to switch / add / clone / init worktrees. The repos
view just renders whatever worktree.nvim is currently tracking.)

Tab-completion works on every verb, including numeric width
candidates inside the configured `[width.min .. width.max]`
range.

## DBase view — nvim-dbee inside the panel

The **dbase** view mounts the nvim-dbee drawer directly into
the panel. Selecting a connection sets it active across dbee:
`:Dbee` opens the editor + result panes against the same
connection, and cmp-dbee's completion in SQL scratchpads sees
the connection's schema.

### Inside the drawer

| Key      | Action                                                       |
|----------|--------------------------------------------------------------|
| `o`      | Toggle expand / collapse on the focused node                 |
| `<CR>`   | Set the connection active **and** mount the editor + result panes (auto-finder override of dbee's stock `<CR>`) |
| `cw`     | Rename / edit the focused node (dbee default)                |
| `dd`     | Delete the focused node (dbee default)                       |
| `r`      | Refresh the node (dbee default)                              |

The `<CR>` override exists because dbee's stock `<CR>` calls
`editor:set_current_note`, which silently no-ops if the editor
window hasn't been bound yet. Auto-finder mounts the companion
editor/result panes first, then forwards to dbee — so notes
always render the first time.

### Connection vaults (encrypted)

Rather than hand-authoring dbee `Source` instances in your
lazy config, the config REPL manages connection vaults for you.
**Connection URLs typically carry credentials in clear text**
(passwords baked into the URL, API tokens as `?key=…`, etc.), so
auto-finder encrypts vaults at rest.

```
0                       # focus the config view (REPL)
dbase new work          # creates work.json.enc, prompts for a vault passphrase
dbase load work         # activates the vault, decrypted only in memory
dbase conn add          # prompts for name / type / url
3                       # focus the dbase view — drawer renders the new entry
```

Vaults live under `stdpath('state') .. /auto-finder/dbase/<name>.json.enc`.
On first access per nvim session the user is prompted for the
vault passphrase via `vim.fn.inputsecret` (no echo). Plaintext
exists only as decrypted bytes inside the running nvim process —
it's never written to disk or to a log line.

**Crypto provider.** The encryption itself is delegated to an
external local tool. **`gpg` is the supported default.** Auto-finder
orchestrates the passphrase prompt and file lifecycle; it does NOT
implement cryptography. If `gpg` isn't on PATH at setup time, the
section falls back to the legacy plaintext storage (see "Migration"
below) and logs a WARN entry so you know.

`age` is also supported but opt-in only — its passphrase automation
relies on `AGE_PASSPHRASE` being honored by the local age build
(`rage` and recent age do; stock age reads `/dev/tty` only). To
prefer `age` when both are installed, set
`AUTO_FINDER_DBASE_PROVIDER_AGE=1` in your shell environment before
launching nvim. We'll revisit making age default once a real-provider
smoke proves the passphrase path on each target platform.

**Vault keymaps and verbs.**

```
dbase new <name>         # create a fresh empty encrypted vault
dbase ls                 # list available vaults (active is *-marked)
dbase rm <name>          # delete a vault
dbase load [name]        # activate a vault (passphrase prompt on first decrypt)
dbase conn add           # prompt for name/type/url, append to the active vault
dbase conn ls            # list connections in the active vault
dbase conn rm <name>     # remove a connection by name
dbase lock               # forget the cached passphrase (re-prompt on next access)
dbase status             # show storage mode + provider + active vault
```

### Migrating from plaintext (pre-v0.2.34)

Earlier auto-finder versions stored connection files as plaintext
JSON under `stdpath('state')/auto-finder/dbase/<name>.json`.
v0.2.34 keeps those files readable but stops writing them — new
operations land in the encrypted vault format. To move existing
plaintext files into encrypted vaults:

```
dbase migrate <name>     # read <name>.json, encrypt to <name>.json.enc
                         # plaintext file is LEFT IN PLACE for verification
dbase load <name>        # activate the new encrypted vault
                         # … verify your connections all work …
dbase rmlegacy <name>    # delete the plaintext file once you've verified
```

`dbase migrate` is intentionally non-destructive — the plaintext
file is preserved until you explicitly `rmlegacy` it. This lets
you read both copies side-by-side until you're confident the
migration round-tripped your connections correctly.

If you'd rather pin sources from your lazy spec (e.g. an
`EnvSource` reading `DBASE_CONNECTIONS` for secrets injected
from `pass` / `1Password`), pass them through `opts.dbase.sources`
— a non-empty list short-circuits the encrypted/legacy default
path entirely.

### Layout — full-width result strip

The dbase view splits the screen into three areas: the drawer
inside the auto-finder panel column, the SQL editor in the main
editor area, and a full-width result strip across the bottom
(spanning the width of the editor area). The bottom strip mirrors
the gobugger / nvim-dap-view "bottom panel" shape — query
results never feel squeezed regardless of how the user has split
the editor area.

The call-log tile splits below the result strip. Both tiles are
created on first `<CR>` against a connection node in the drawer.

### SQL note buffers are listed

Since v0.2.34, dbee's SQL note buffers default to `buflisted = true`
(dbee's stock default is `false`). This makes notes appear in
auto-finder's `buffers` view, in autovim's editor-area winbar,
and in any other surface that filters by `vim.fn.buflisted(b) == 1`.
Override via `opts.dbase.extra.editor.buffer_options.buflisted = false`
if you want dbee's original behavior.

## Architecture

auto-finder is layered:

- **Public API** (`lua/auto-finder/init.lua`) — `setup` /
  `open` / `close` / `toggle` / `focus` / `resize`.
- **`core/`** — runtime state component (8 modules). Owns
  every cache + watcher + subscription. Publishes
  `auto-finder.core.*` topics that views consume.
- **`views/`** — UI renderers (each a directory). Subscribe
  to translated topics; render against neo-tree.
- **`shared/`** — pure helpers (neo-tree mount, debounce,
  loading placeholder, window predicates, subscription sets).
- **`panel/`** — the window host. Implements
  `winfixwidth`/`winfixbuf` protection + the `with_unfixed_buf`
  primitive that internal swaps use.
- **`sections/`** — backwards-compat facade re-exporting
  `views/*` for any third-party caller pinned to the v0.1
  `require("auto-finder.sections.<name>")` shape.

The boundary with [`auto-core.nvim`](https://github.com/yongjohnlee80/auto-core.nvim)
is explicit and documented: auto-core owns OS-level watch
primitives, the events bus, the panel + section registry, the
log ring, and the state namespace. auto-finder layers the
domain-specific caches + views on top and never reaches into
auto-core internals.

For the full structural picture — mermaid diagrams,
per-event-source detection + processing walkthrough,
auto-core dependency surface, lifecycle, pointers for new
work — see [`ARCHITECTURE.md`](./ARCHITECTURE.md).

## Automation (`.todo-list/automated/`)

The todos view doubles as a scheduled-task engine: drop a
`status: automated` template under
`<workspace>/.todo-list/automated/<id>.md`, declare cron or
event conditions + an execute plan, and the engine clones it
into a fresh task on every condition match. Each clone goes
through the normal `open → in-progress → completed` lifecycle
so every fire leaves an audit trail.

Author templates with cron + event conditions, plain `bash` /
`bash -t=<N>` (floating-terminal-routed) / `assign agent:<name>`
execute primitives, a workspace-scoped bash trust gate, and
real-time `vim.diagnostic` validation as you type — full
how-to with examples, the cron grammar, the trust-gate flow,
debugging recipes, and the manual-fire / inspection commands
is in **[`AUTOMATION.md`](./AUTOMATION.md)**.

## Development

- Smoke suite: `nvim --headless -u NONE -l tests/smoke.lua`.
  Exits 0 with `<N> passed, 0 failed` when clean. v0.2.25 ships
  with 425 assertions across 34 sections.
- Per-phase failure / remediation audit log:
  [`tests/auto-finder-test-audit.md`](./tests/auto-finder-test-audit.md).
- Catalog of smoke sections removed during the ADR 0026
  refactor with reimplementation plans:
  [`tests/auto-finder-flaky.test.md`](./tests/auto-finder-flaky.test.md).
- Version policy: stays within the existing minor line
  (`v0.2.x`) until explicit approval to bump. See `CHANGELOG.md`
  for release-by-release notes.

## License

MIT — © 2026 Yong Sung John Lee
