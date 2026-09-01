# auto-finder.nvim

A multi-view side panel for Neovim. One window hosts purpose-built
**views** — filesystem, git repos × worktrees, open buffers, an
autodb explorer, test/debug runners, and a prompt-style config REPL —
each reachable with a single keystroke.

Built on top of [`auto-core.nvim`](https://github.com/yongjohnlee80/auto-core.nvim)
(panel + state + event-bus primitives) and a vendored fork of
neo-tree (filesystem rendering). The internal architecture is
documented in [`ARCHITECTURE.md`](./ARCHITECTURE.md); this README
is the user-facing surface.

## At a glance

```
┌─ auto-finder ──── [0: config] [1: files] [2: repos] · ────────────┐
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

**Three views are in the default slot list** — the panel is useful
the moment you install it:

| # | View | What it shows |
|--:|---|---|
| 0 | **config** | Prompt-style admin REPL. Switch views, resize the panel, toggle file filters, rearrange slots. Tab-completion + clickable winbar throughout. |
| 1 | **files** | Filesystem tree (neo-tree filesystem source). Live-refresh on filesystem events; git status decorations from the auto-core git layer. |
| 2 | **repos** | Git repos × worktrees, discovered by [`worktree.nvim`](https://github.com/yongjohnlee80/worktree.nvim) — no registry, no manual add. Expands to per-worktree changes, commit history and per-commit diffs, with in-panel git actions. See [Repos view](#repos-view). |

Six more views ship in the box but aren't in the default slot
list — add them with `slot add <name>` from the config REPL (or
list them in `opts.sections`):

| View | What it shows |
|---|---|
| **buffers** | Open-buffer list (neo-tree buffers source). Mirrors `:ls`, including unloaded buffers added via `:badd` or session restore. |
| **dbase** | [`autodb`](https://github.com/yongjohnlee80/autodb)'s explorer, hosted in the panel. Soft dep — renders a "no backend" buffer when autodb is absent. See [DBase view](#dbase-view--autodb-inside-the-panel). |
| **marks** | nvim marks browser. |
| **todos** | The auto-core task store — see [Automation](#automation-todo-listautomated). |
| **tests** / **debug** | The ADR-0048 pair, consuming [`auto-run.nvim`](https://github.com/yongjohnlee80/auto-run.nvim). See [Tests & Debug views](#tests--debug-views-auto-run). |

To **re-order** the slots rather than edit one at a time, use `slot
assign` — a walk over slots 1..9 that asks for a section type per
slot, showing the current occupant and refusing duplicates; an empty
entry ends the list and `<C-c>` cancels. `slot assign <t1> <t2> …`
does the same in one line. It exists because `slot modify` refuses a
type that already lives elsewhere, so it can never swap two slots;
`assign` replaces the whole list at once, making any permutation
legal. Slot 0 (config) is fixed. Arrangements are stored per
workspace and survive a restart.

Plus the foundations behind the views, all centralized in
`lua/auto-finder/core/`:

- **Centralized caches** for the file tree, git status, buffer
  list, and repos registry. The neo-tree-backed views still render
  through neo-tree's `manager.refresh` path on receiving a
  translated event; the cache surface exists so a future phase can
  flip them to delta-rendering directly from
  `core.<area>.snapshot_now()` (see
  [`ARCHITECTURE.md`](./ARCHITECTURE.md) for the
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
  `^0.2.0` — foundation library (panel singleton, state
  namespace, event bus, `fs.watch`, `git.watch`, `git.status`,
  centralized log, and the `fs.atomic` write primitive that
  auto-finder's persistence delegates to). **Hard dep.**
- [`MunifTanjim/nui.nvim`](https://github.com/MunifTanjim/nui.nvim),
  [`nvim-lua/plenary.nvim`](https://github.com/nvim-lua/plenary.nvim),
  [`nvim-tree/nvim-web-devicons`](https://github.com/nvim-tree/nvim-web-devicons)
  — required by the bundled neo-tree fork.
- **Do not install upstream `nvim-neo-tree/neo-tree.nvim`
  alongside** — auto-finder ships its own fork under
  `lua/auto-finder/neotree/` (since v0.1.3) and the two will
  collide on the same require path. Disable upstream
  explicitly if you had it installed: `{ "nvim-neo-tree/neo-tree.nvim", enabled = false }`.
- [`yongjohnlee80/worktree.nvim`](https://github.com/yongjohnlee80/worktree.nvim)
  `^0.5.0` — powers the **repos** view. From v0.5.0 the view renders
  worktree.nvim's own explorer (commits, diffs, git actions); the
  switch is by **availability**, so an older worktree.nvim falls back
  to the bundled `auto-finder-repos` neo-tree source, and no
  worktree.nvim at all renders an empty view.
- [`yongjohnlee80/autodb`](https://github.com/yongjohnlee80/autodb) —
  soft dep for the **dbase** view. When absent, the view shows
  a placeholder explaining the dependency; the rest of the
  panel is unaffected.
- [`yongjohnlee80/auto-run.nvim`](https://github.com/yongjohnlee80/auto-run.nvim)
  `^0.1.0` — soft dep for the **tests** and **debug** views
  (ADR-0048 Phase 3). When absent, both views render a
  one-line hint; the rest of the panel is unaffected. The
  debug view's session/breakpoint sections additionally use
  [`mfussenegger/nvim-dap`](https://github.com/mfussenegger/nvim-dap)
  when it is installed.

## Install (lazy.nvim)

```lua
{
  "yongjohnlee80/auto-finder.nvim",
  version = "^0.4.0",
  dependencies = {
    "yongjohnlee80/auto-core.nvim",       -- foundation; hard dep
    "yongjohnlee80/worktree.nvim",        -- repos view
    "MunifTanjim/nui.nvim",               -- bundled neo-tree fork deps
    "nvim-lua/plenary.nvim",
    "nvim-tree/nvim-web-devicons",
    -- autodb and auto-run are NOT listed: the dbase / tests / debug views
    -- probe for them and degrade to a placeholder, so the panel works
    -- without either installed.
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
    -- This is the default; add "buffers" / "dbase" / "marks" /
    -- "todos" / "tests" / "debug" here or via `slot add`.
    sections = { "config", "files", "repos" },

    -- Open the panel for `nvim .` style directory invocations.
    hijack_directories = true,

    -- Per-view opts for the neo-tree-backed views. Each is forwarded
    -- to the underlying neo-tree source's deep-merged config. Use this
    -- to inject custom keymaps without forking the plugin.
    files   = { window = { mappings = {} } },
    buffers = { window = { mappings = {} } },
  },
  keys = {
    { "<leader>e",  "<cmd>AutoFinder<cr>",        desc = "auto-finder: toggle panel" },
    { "<leader>E",  "<cmd>AutoFinder!<cr>",       desc = "auto-finder: toggle (force, ignores width-guard)" },
    { "<leader>fe", "<cmd>AutoFinderFocus 1<cr>", desc = "auto-finder: focus files view" },
  },
}
```

> **Caret pin (`^0.4.0`)**: future v0.4.x releases auto-include
> without a manual bump. The plugin holds an additive-only
> minor-bump contract — v0.4.x releases never rename, remove,
> or break-shape any existing public surface. Crossing to
> v0.5.0 (when it eventually lands) requires bumping the caret
> deliberately.

## Commands

| Command                      | Effect                                                          |
|------------------------------|-----------------------------------------------------------------|
| `:AutoFinder[!]`             | Toggle the panel (`!` ignores width-guard)                      |
| `:AutoFinderFocus <N\|name>` | Switch to view N (e.g. `:AutoFinderFocus repos`)                |
| `:AutoFinderResize <N>`      | Pin panel width to N columns (hard cap)                         |
| `:AutoFinderReset`           | Clear the pin (back to dynamic width)                           |
| `:AutoFinderResumeDiff`      | Reopen the last repos diff at the file and line you left it on  |

## Config REPL cheatsheet

Inside the panel, press `0` to focus the config view. Type
`help` (or `?`) for the full list, or any of these:

```
focus 1                  # jump to files (numeric or name)
focus files              # same thing
focus repos              # jump to the repos × worktrees view
panel resize 50          # pin width to 50 cols (hard cap)
panel reset              # release the pin (alias: panel dynamic)
panel show               # show mode / default / range / live width
files show hidden        # include .gitignored files in the tree
files hide dotfiles      # hide .* files
files follow on          # follow the current buffer in the tree
repos follow on          # follow the current buffer's repo/worktree
slot add todos           # add a view to the slot list
slot assign files repos  # replace the whole slot list (any permutation)
status                   # panel + view state
reload                   # re-render the active view
clear                    # clear the REPL transcript
quit                     # close the panel (view buffers persist)
```

Tab-completion works on every verb, including numeric width
candidates inside the configured `[width.min .. width.max]`
range.

(Worktree *mutations* are owned by `worktree.nvim` — use its
`<leader>gw` / `<leader>gA` / `<leader>gC` / `<leader>gc`
keymaps to switch / add / clone / init worktrees. The repos
view renders what worktree.nvim tracks, and owns only the
per-row git actions listed below.)

## Repos view

With `worktree.nvim` `^0.5.0` installed, the repos view is a **pure
renderer over `worktree.repos`** — it never shells git itself, and
every node is cached, so a repaint (cursor move, watch toggle, focus
change) costs zero git subprocesses. Git is paid on first expand and
after an explicit invalidation only.

```
▾ repo
  ▾ worktree            ● watched
    ▾ UNCOMMITTED (n files)
        <changed file>
    ▾ <commit>
        <changed file>
        <review json>
  ▸ <collapsed worktree>
```

| Key    | Action                                            |
|--------|---------------------------------------------------|
| `<CR>` | Expand / open the row                             |
| `o`    | Diff this commit                                  |
| `w`    | Watch / unwatch this worktree                     |
| `m`    | Load more commits                                 |
| `i`    | Info for the row under the cursor                 |
| `R`    | Reload                                            |
| `f`    | Fetch this repository                             |
| `s`    | Stage / unstage this file                         |
| `c`    | Commit what is staged                             |
| `P`    | Push — **confirms first, naming the repository**  |
| `?`    | Help                                              |

`P` sits one key from `p` and a push is the only action here that
leaves the machine, so the confirmation names the repo it is about to
publish: a mistyped key on the wrong row cannot push.

Left the diff to go read a file? `:AutoFinderResumeDiff` reopens it at
the file and line you were on.

## DBase view — autodb inside the panel

The **dbase** view hosts [autodb](https://github.com/yongjohnlee80/autodb)'s
explorer in the panel: connections, workspaces, notes and script history, beside
your files and repos.

Since ADR-0078 the drawer itself **lives in autodb**, and this view is a thin
facade over it: auto-finder registers a host *provider* with autodb's drawer-host
registry and mounts the instance the registry hands back. The registry is the
sole constructor and sole disposer, which is what makes "at most one mounted
drawer" enforceable in one place — and it is what lets autodb show a drawer even
when auto-finder is not installed. What stays auto-finder's: the availability
gate, the placeholder screen, owned-buffer accounting, and teardown.

autodb is a **soft dependency and is not declared here**. The view probes for it
and, when it is absent, renders a short buffer saying so rather than failing —
the panel stays usable without a database backend installed.

Keymaps inside the drawer are autodb's; press `?` there for its help. Connections,
users, roles and at-rest encryption belong to autodb's own backend, so there is
nothing to configure here and no connection file to protect — the view takes no
options.

### nvim-dbee has been removed

The dbase view mounted nvim-dbee's drawer from v0.2.16 through the 0.3 line.
**v0.4.0 removed it completely** — it is not a fallback and is not maintained.
Roughly 2450 lines went with it: the connection vault, its encrypted source and
crypto provider, the drawer setup owner, the companion editor/result/call_log
layout, the event bridge, and the `dbase` admin verb that managed connections.
autodb owns all of that on its own backend, so keeping a second copy inside a
file explorer made no sense.

If you were using the dbee-backed dbase view, your connections still live in
dbee's own store; move them into autodb (`<leader>Dc` in AutoVim, or the
standalone TUI). Nothing here reads them any more, and the `dbase …` REPL verbs
that managed them are gone.

One consequence worth stating plainly: schema-aware SQL completion went with
dbee. `cmp-dbee` hard-requires `dbee` and gates on `dbee.api.core.is_loaded()`,
so it cannot outlive it, and autodb does not ship a completion source yet.

## Tests & Debug views (auto-run)

Two flat scratch-buffer views (ADR-0048 Phase 3) consuming
[`auto-run.nvim`](https://github.com/yongjohnlee80/auto-run.nvim)'s
public API — pure renderers over auto-run's discovery tree, config
store, `launch.json` parse, and breakpoint persistence, refreshed by
the `run.*` event topics. Register with `slot add tests` / `slot add
debug`.

Both views render two selection sections above their main body: a
**Config** section (the VSCode `launch.json` configs auto-run parses —
the tests view lists `mode:test`, the debug view `mode:debug`) and an
**Env** section (candidate `.env` files, discovered under the worktree
root and the bare-repo container, each at `.`, `.config/`, `.vscode/`).
A `*` marks the per-repo **selected** config / env file; the selection
feeds every subsequent launch — the config as the *active base*
(env/build_flags/etc. merged in), the env file highest-precedence.

### tests

The discovered test-position tree (`dir → file → namespace →
test`) with per-row status glyphs from the last run
(✓ passed · ✗ failed · ○ skipped · ● running), live-updated on
`run.results:changed`. Folder collapse persists across sessions.
The header shows the discovery root, counts, and the scan state —
including auto-run's structured cap report when a bounded full
scan aborts.

| Key | Action |
|---|---|
| `<CR>` | jump to position (editor-routed); config row → open `launch.json`; env file → open; toggle collapse on a folder / section header |
| `r` | run position under cursor (test / file / namespace / folder = suite) |
| `R` | re-run the last position run from this panel |
| `d` | debug the test under cursor (dap strategy) |
| `o` | toggle details on a test row / config row (env values masked) / env file (KEY=VALUE); collapse on containers |
| `O` | toggle ALL: collapse everything if anything is open, else expand everything |
| `i` | output float — the run's full terminal output (`go test` logs) |
| `s` | select / deselect the config or env file under cursor |
| `e` | edit the env var under cursor (Env section) |
| `a` | add KEY=VALUE to the env file (env row / Env header) |
| `S` | full worktree scan (bounded; `S` again cancels) |
| `x` | stop running test jobs |
| `?` | help overlay |

### debug

Sections: **Entry Points** (store configs `kind=debug|run`, grouped by
kind, provenance/tier annotated), **Config** (`mode:debug` `launch.json`
configs, selectable), **Env**, **Active Sessions** (live nvim-dap
sessions), and **Breakpoints** (the persisted per-repo store merged with
live dap state, grouped by file — orphaned persisted entries render
dimmed). `o` on an entry expands its resolved config with **env values
masked** — keys and `${VAR}` / `cmd:` refs only, literal values never
reach the buffer.

The debug panel has **no delete surface** — breakpoints are managed via
nvim-dap directly (sign column / API); config files via the files panel.

| Key | Action |
|---|---|
| `<CR>` | entry point → open its **program source**; config row → open `launch.json`; session → focus; breakpoint → jump; header → toggle collapse |
| `r` | entry point → **run** the program in an auto-agents playground terminal (prompts `term1`..`term4`) |
| `d` | entry point → **debug** (dap) |
| `o` | expand details (resolved config with env masked / session state / breakpoint condition); collapse on headers |
| `O` | toggle ALL sections open/closed |
| `e` | edit the entry point's config file; env var → edit its value |
| `a` | entry point → **export** config to `launch.json` (nearest reachable, else `$WORKSPACE/.config/launch.json`); env row / Env header → add KEY=VALUE |
| `s` | select / deselect the config or env file under cursor |
| `x` | terminate the session under cursor |
| `p` | pause / continue the session under cursor |
| `i` | info popup for the row under cursor |
| `R` | refresh |
| `?` | help overlay |

## Architecture

auto-finder is layered:

- **Public API** (`lua/auto-finder/init.lua`) — `setup` /
  `open` / `close` / `toggle` / `focus` / `resize`.
- **`core/`** — runtime state component (8 modules). Owns
  every cache + watcher + subscription. Publishes
  `auto-finder.core.*` topics that views consume.
- **`views/`** — UI renderers (each a directory). Subscribe
  to translated topics. The files and buffers views render
  against the bundled neo-tree fork; repos and dbase are pure
  renderers over `worktree.repos` and autodb's drawer.
- **`shared/`** — pure helpers (neo-tree mount, debounce,
  loading placeholder, window predicates, subscription sets).
- **`panel/`** — the window host. Implements
  `winfixwidth`/`winfixbuf` protection + the `with_unfixed_buf`
  primitive that internal swaps use, plus the config REPL's
  admin dispatcher.
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

- **Run the whole suite with `tests/run-all.sh`.** Every standalone
  suite is wired into it, and each one ends by printing a canonical
  `N passed, M failed` summary line. A suite whose output lacks that
  line did not reach the end of its file — it aborted or crashed
  mid-run — and the runner counts it as FAILED rather than parsing
  whatever partial PASS lines it emitted. That sentinel is the only
  thing that can catch a C-level crash, so **running a single suite
  by hand is not a substitute**.
- Single suite, when you are iterating on one:
  `nvim --headless -u NONE -l tests/smoke.lua`.
- Suite → surface inventory:
  [`tests/auto-finder-coverage.md`](./tests/auto-finder-coverage.md).
- Per-phase failure / remediation audit log:
  [`tests/auto-finder-test-audit.md`](./tests/auto-finder-test-audit.md).
- Catalog of smoke sections removed during the ADR 0026
  refactor with reimplementation plans:
  [`tests/auto-finder-flaky.test.md`](./tests/auto-finder-flaky.test.md).
- Version policy: stays within the existing minor line
  (`v0.4.x`) until explicit approval to bump. See `CHANGELOG.md`
  for release-by-release notes.

## License

MIT — © 2026 Yong Sung John Lee
