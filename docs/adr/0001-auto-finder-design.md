# ADR 0001 — auto-finder.nvim design

- **Status:** Proposed (v0.1.0 implements §1–§4 + §7.0/§7.1)
- **Date:** 2026-05-07
- **Author:** Yong Sung John Lee
- **Context repo:** `nvim-plugins/auto-finder.nvim`

## 1. Context

Neo-tree is the de-facto file explorer in our autovim setup. It is excellent for the
plain "browse-the-cwd" use case but stops short of two things we keep wanting:

1. A unified, **multi-section** explorer where the file tree is one of several
   browsable surfaces (registered repos × git worktrees, remote / SSH targets,
   database connections), all reachable from the same window without learning a
   different plugin per surface.
2. A **command-driven control surface** (in the spirit of the auto-agents.nvim
   admin slot 0) for resizing, focusing, and configuring the explorer without
   touching `:set` lines or remembering plugin-specific keymaps.

`auto-finder.nvim` is that wrapper. It hosts neo-tree for the conventional
"files" surface and adds purpose-built sections alongside it.

## 2. Decision

Build a single Neovim plugin, `auto-finder`, that:

- Owns one **panel window** — a `winfixwidth=true` vsplit anchored to the left,
  width resolved from a clamped percentage of `vim.o.columns` and overridable
  by the user with a sticky pin.
- Hosts **N sections**, each a self-contained module that produces a buffer.
  Switching sections swaps the buffer in the panel window via
  `nvim_win_set_buf`. Section `0` is **config** (a prompt-style REPL).
- Exposes a single `setup(opts)` entry point and a small set of user commands.
- Treats neo-tree as a **runtime dependency** for the `files` (and later
  `repos`) sections: we drive `require("neo-tree.command").execute({ position
  = "current", … })` against our own panel window, so the buffer neo-tree
  creates lives inside our explorer rather than spawning its own split.

The model follows auto-agents.nvim's panel + admin pattern closely enough to
keep cognitive load low for users of both plugins, but stays focused on
read-mostly browsing rather than agent orchestration.

## 3. Layout

```
┌─ AutoFinder ────────── [0: config] [1: files] · ─┐
│                                                   │
│  (active section's buffer renders here)           │
│                                                   │
│                                                   │
└───────────────────────────────────────────────────┘
```

- The winbar tab-strip mirrors auto-agents' winbar: focused section is
  bracketed, others are `[N: name]`. Adaptive: collapses to compact form
  (`[0: config] 1 2 3 4`) when the panel narrows.
- Switching sections is **non-destructive**: each section's buffer survives
  in the background and is reused on next focus.

## 4. Public surface

### 4.1 Lua API

```lua
require("auto-finder").setup({
  -- The panel is anchored to the left; `side` was removed in v0.1.x.
  width = {
    percentage = 0.20,            -- of vim.o.columns
    min        = 30,
    max        = 60,
  },
  default_section = 1,            -- 0=config, 1=files (default), …
  sections = { "config", "files" }, -- v0.1; v0.2 adds "repos","remote","db"
  files = {                       -- forwarded as-is to neo-tree filesystem
    -- e.g. filtered_items = { hide_dotfiles = false }, …
  },
})

require("auto-finder").toggle()        -- open/close panel
require("auto-finder").open()          -- ensure open, focus default section
require("auto-finder").close()         -- close window (state preserved)
require("auto-finder").focus(N|name)   -- switch section
require("auto-finder").resize(N)       -- pin user width
require("auto-finder").reset_width()   -- drop the pin
```

### 4.2 User commands

| Command                    | Effect                                      |
|----------------------------|---------------------------------------------|
| `:AutoFinder[!]`           | Toggle the panel (`!` bypasses width-guard) |
| `:AutoFinderFocus <N\|name>`| Switch to section N (or by name)           |
| `:AutoFinderResize <N>`    | Pin panel width to N columns                |
| `:AutoFinderReset`         | Clear the user-pinned width                 |

> The `:AutoFinderSide` command and the `side` config field were
> removed in v0.1.x. The panel is anchored to the left; the right
> slot is reserved for sibling plugins (auto-agents, &lt;F5&gt; terminal).

### 4.3 Default keymaps

Plugin ships **none**. Consumers wire whatever they like (e.g. `<leader>e`
in autovim's `lua/plugins/auto-finder.lua`).

## 5. Width pinning

Two-mode width resolution:

```
panel_width = state.user_width or  resolve_from_percentage(cfg, vim.o.columns)
```

- `resolve_from_percentage(cfg, cols) = clamp(floor(cols × cfg.width.percentage), cfg.width.min, cfg.width.max)`
- `panel resize N` sets `state.user_width = N` and resizes the window. The pin
  survives `:VimResized` events — the user explicitly chose this number.
- `panel reset` clears the pin; the next render goes back to percentage-based.
- The pin is **session-scoped** (not persisted to disk). v0.1 ships it that
  way; persistence is a v0.2 candidate.

## 6. Section architecture

Each section is a Lua module under `lua/auto-finder/sections/<name>.lua`,
implementing a small interface:

```lua
return {
  name        = "files",     -- short display name
  number      = 1,           -- stable section index used for `<N>` keymap
  description = "filesystem (neo-tree wrapper)",

  -- Build (or reuse) the buffer that should be displayed in the panel
  -- window when this section is focused. Implementations may cache.
  --
  -- @param panel_winid integer  -- the panel window the section will live in
  -- @return integer bufnr
  get_buffer = function(panel_winid) … end,

  -- Optional. Called immediately after the panel switches to this section,
  -- AFTER the buffer is in the window. Use this for one-time per-focus
  -- setup (e.g. neo-tree's command.execute call, normal-mode keymaps).
  on_focus   = function(panel_winid, bufnr) … end,

  -- Optional. Called when the panel is closing or the section is being
  -- evicted. Sections that own external resources (file watchers, SSH
  -- handles, DB conns) clean up here.
  on_close   = function() … end,
}
```

The host (`lua/auto-finder/panel/host.lua`) owns the panel window and the
section registry; sections own their buffer lifecycle and any external state.

## 7. Sections

### 7.0 `config` (slot 0) — v0.1

A `buftype = "prompt"` REPL, lifted from auto-agents' admin slot.

Initial verb set:

```
help, ?, :h                 show this help
focus <N|name>              switch section (e.g. focus 1, focus files)
panel resize <N>            pin panel width to N columns
panel reset                 clear the user-pinned width
panel show                  display mode/default/range/live width
reload                      re-render the active section
clear                       wipe history above the prompt
quit                        close the panel
```

- `<CR>` on the prompt line dispatches the entered command.
- Buffer-local normal-mode `0..9` → focus that section (matches auto-agents'
  admin slot UX).
- Tab completion (v0.2) for verb / section names.
- Banner shows current section, current width, `(pinned)` flag if applicable.

### 7.1 `files` (slot 1) — v0.1

A neo-tree filesystem source rendered into the panel window via
`position = "current"`.

- On focus, calls `require("neo-tree.command").execute({ source = "filesystem",
  action = "show", position = "current", reveal = false })` against the panel
  window so neo-tree mounts its buffer in our window.
- User opts under `cfg.files` are passed through to neo-tree's filesystem
  source on `setup` (so existing tweaks — `hide_dotfiles`, dotfile highlights —
  keep working).
- After mount, we register our buffer-local `0..9` keymap on the neo-tree
  buffer via a `FileType neo-tree` autocmd scoped to the panel window's
  buffer, so section switching works without leaving the explorer.

### 7.2 `repos` (slot 2) — v0.2 (deferred)

A reimplementation of Bryan's `neo-tree-workspace` source as a first-class
section.

- **Top level:** user-registered repos from a JSON registry at
  `stdpath("data")/auto-finder/repos.json`.
- **Second level:** non-bare worktrees from `git worktree list --porcelain`,
  main worktree pinned as `base`, others sorted alphabetically with
  `(branch)` annotation.
- **Below worktree level:** lazy-loaded via `vim.uv.fs_scandir` with
  per-worktree git-status colours.
- **Auto-refresh:** `vim.uv.fs_event` watchers on each repo's
  `<gitdir>/worktrees/` dir, debounced ~150ms.
- Registry maintained via the config slot's verbs (preferred) and user
  commands (`:AutoFinderRepoAdd [path]`, `:AutoFinderRepoRemove <path>`,
  `:AutoFinderRepoList`).
- Optionally re-exposes a `worktree_paths()` helper for
  `<leader><leader>` fuzzy-find scoping (matching Bryan's commit
  `cba8f67`).

### 7.3 `remote` (slot 3) — v0.3 (deferred)

A browsable list of registered SSH targets. Each remote behaves like a
two-pane explorer: top level is the registry, expanding a remote spawns a
controlled `ssh <target> ls -1AF <path>` (or `sftp`) walk and lazy-loads
children.

- **Registry:** `stdpath("data")/auto-finder/remotes.json`. Each entry:
  `{ name, host, user?, port?, default_path?, identity_file? }`. The plugin
  does **not** parse `~/.ssh/config` — it points at a host, ssh handles the
  rest.
- **Connection model:** **on-demand**, not held open. Each child-fetch issues
  one `ssh` invocation; a small LRU cache of recent listings (`name × path →
  entries`, TTL 30s) avoids hammering the host on repeated expansions of the
  same dir.
- **Open file action:** `<CR>` on a file fetches it via `scp`/`sftp` into a
  scratch buffer with `buftype = "acwrite"` and an autocmd that rsyncs back
  on `:w`. This is the same shape as `remote-sync.nvim` and may end up
  delegating to it.
- **Errors:** treated as user-facing — the section renders an inline
  `(connection failed: <msg>)` line under the offending remote rather than
  popping a `vim.notify` storm.

### 7.4 `db` (slot 4) — v0.4 (deferred)

A browsable list of registered database connections (Postgres, MySQL, SQLite,
…). Each connection lazy-expands to schemas → tables → columns. Optional
peek action runs a bounded `SELECT * LIMIT 50` and renders the result in a
side scratch buffer.

- **Registry:** `stdpath("data")/auto-finder/dbs.json`. Each entry:
  `{ name, driver, dsn?, dsn_cmd? }`. `dsn_cmd` lets users keep credentials
  out of the JSON by shelling out to `pass`/`age`/`vault` at access time.
- **Driver shim:** initially via the `lazysql` config integration (see
  `~/.config/lazysql/config.toml`) since the user already maintains
  connections there. Direct driver access (psql/sqlite3/mysql CLIs) is a
  fallback when lazysql is absent.
- **Read-only by default.** Mutations go through lazysql or a SQL editor;
  this section is a browser, not an admin tool.

## 8. State & persistence

| What                       | Where                                                       | Lifetime  |
|----------------------------|-------------------------------------------------------------|-----------|
| Active section             | `state.section` (in-memory)                                 | Session   |
| User-pinned width          | `state.user_width` (in-memory, v0.1)                        | Session   |
| Repos registry             | `stdpath("data")/auto-finder/repos.json`                    | Persistent |
| Remotes registry           | `stdpath("data")/auto-finder/remotes.json`                  | Persistent |
| DBs registry               | `stdpath("data")/auto-finder/dbs.json`                      | Persistent |
| Per-section preferred width| `state.section_widths[N]` (in-memory, v0.2 candidate)       | Session   |

## 9. User stories

### 9.1 Cross-section (config + section navigation)

1. As a user, when I press my AutoFinder open keymap, the explorer opens in
   the section I last used so my context persists across sessions.
2. As a user, I can type `focus files` (or `1`) in the config section to
   switch to the filesystem view, and `focus repos` (or `2`) to switch to the
   registered-repos view — without leaving the explorer window.
3. As a user, I can press a single keystroke from any section (`0..9`) to
   jump between sections without going through the config buffer first.
4. As a user, if I run `:AutoFinderFocus 7` and section 7 doesn't exist, I
   get a tidy `auto-finder: no such section 7` message — no broken state.

### 9.2 Sizing & layout

5. As a user, I can run `panel resize 60` from the config section to widen
   the explorer for repos with long paths, and the new width persists for the
   session.
6. As a user, when the terminal resizes, my pinned width is honoured — only
   the unpinned (percentage-based) default reflows.
7. As a user, I can run `panel reset` to clear the pin and go back to the
   default percentage-based width.
8. _(Withdrawn — `panel side` was removed in v0.1.x. The panel is
   left-anchored by design; the right slot is reserved for sibling
   plugins.)_

### 9.3 Files section (vanilla neo-tree)

9. As a user, the files section behaves exactly like stock neo-tree
   filesystem rooted at cwd — same keymaps, same git-status colours, same
   dotfile / gitignore behaviour.
10. As a user, opening a file from any section opens it in the previously
    focused editor split, never replacing the explorer.
11. As a user, my existing neo-tree opts (e.g. dotfile highlights) keep
    working when forwarded via `cfg.files`.

### 9.4 Repos section (v0.2)

12. As a user, the repos section lists every registered repo with its
    non-bare worktrees under it, the main worktree pinned as `base`, and the
    rest sorted alphabetically with `(branch)` annotation.
13. As a user, when I run `git worktree add` in any external terminal, the
    repos section updates within ~150ms without me touching the explorer.
14. As a user, files under a worktree show their git-status colour (modified
    / added / untracked / deleted) — including dirs that contain modified
    descendants.
15. As a user, two repos with the same basename (e.g. `api/` in
    `Source/Projects/api` and `Source/Side/api`) are disambiguated as `api`
    and `api-2` so I can tell them apart.
16. As a user, I can run `repos add` from the config section while cwd is
    inside a git repo and have that repo registered without leaving nvim.
17. As a user, I can hit a keymap (e.g. `+`) on a workspace node in the
    repos section to register the cwd, and `-` on a workspace node to
    unregister that one.
18. As a user, the `<leader><leader>` fuzzy file finder is automatically
    scoped to **only** registered repos' worktrees, matching what the repos
    section shows.

### 9.5 Remote / SSH section (v0.3)

19. As a user, I can run `remote add prod-db user@10.0.0.5` in the config
    section and have it appear at the top of the remote section the next
    time I focus it.
20. As a user, expanding a remote in the section issues a single
    `ssh <target> ls -1AF <path>` call and renders the result; subsequent
    expansions of the same directory within ~30s reuse the cached listing.
21. As a user, opening a remote file pulls it into a scratch buffer; saving
    that buffer (`:w`) syncs the change back to the remote — and a failure
    keeps the buffer modified rather than silently swallowing the error.
22. As a user, when an SSH connection fails, the failure shows as an inline
    `(connection failed: <msg>)` line under the offending remote, not as a
    flood of `vim.notify` calls.
23. As a user, I can `remote remove prod-db` and the registry entry is
    deleted with no in-flight connection cleanup needed (we don't hold
    persistent sessions in v0.3).
24. As a user, my SSH key passphrase prompts surface in the editor's command
    line area, not as a silent timeout — so `ssh-add` flows still work.

### 9.6 DB section (v0.4)

25. As a user, I can run `db add lm-prod tagus.lm.toml` in the config section
    and have a Postgres connection appear in the db section, expanding to its
    schemas → tables → columns.
26. As a user, `db add` accepts either an inline DSN (`db add foo
    postgres://...`) or a credential resolver command (`db add foo --cmd 'pass
    show lm/prod'`) so secrets stay out of the JSON registry.
27. As a user, I can hit a keymap (e.g. `p`) on a table to peek the first 50
    rows in a side scratch buffer — and the section never lets me run an
    unbounded query by accident.
28. As a user, the db section is **read-only by default**; I can't issue an
    `UPDATE` or `DROP` from it. Mutations go through lazysql or a separate
    SQL editor.
29. As a user, when a connection fails (server down, bad creds, SSL cert),
    the failure is rendered as an inline `(error: <msg>)` line under the
    offending entry — not popped as a notify.

### 9.7 Discoverability & failure modes

30. As a user, the config section's banner always shows the current section,
    current width, and whether the width is pinned — so I never lose track
    of state.
31. As a user, typing `help` (or `?`) in the config section shows every
    available command and its current keymap binding.
32. As a user, if I open the explorer with no registered repos / remotes /
    dbs, those sections show a friendly empty-state pointing me to the
    relevant `<kind> add` verb.
33. As a user, if a registered repo / remote / db is moved, deleted, or
    unreachable, the relevant section shows it greyed out with a
    `(missing)` / `(unreachable)` tag instead of erroring, and the config
    section offers a one-shot `<kind> prune` to remove dead entries.

## 10. Out of scope (explicitly)

- **No** persistent SSH master sessions in v0.3 — every fetch is its own
  `ssh` invocation. (Persistent control sockets are a v0.4 candidate if
  latency becomes a problem.)
- **No** write-side database operations from the db section. Browse only.
- **No** custom theme / iconset — we link into existing neo-tree highlight
  groups so the user's colorscheme governs.
- **No** persistence of UI state (active section, pinned width) across
  sessions in v0.1. Add in v0.2 if it proves missed.
- **No** default keymaps shipped by the plugin — wiring is the consumer's
  responsibility.

## 11. Versioning

Following the autovim plugin policy, this repo stays within `v0.1.x` until
explicit user approval to move the minor line. The autovim consumer config
pins `version = "^0.1.0"`.

## 12. Open questions

1. **Width persistence** — should the user-pinned width survive nvim
   restarts? v0.1 says no; revisit if the user finds themselves resizing
   every session.
2. **Per-section preferred width** — repos rows are wider than file rows.
   Should each section remember its own preferred width and have the panel
   resize automatically on focus? v0.2 candidate.
3. **Reveal-current-file** — neo-tree has `reveal_file = …` for opening
   the tree at the file under the cursor. We may want a `reveal` action
   in the config slot.
4. **MCP for remote/db** — the `remote` and `db` sections look like ideal
   candidates for an MCP server bridging the registry into agent tools.
   Out of scope for v0.x but worth keeping in mind in the section
   interface.
