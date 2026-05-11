# Changelog

All notable changes to `auto-finder.nvim` are documented here.

## [v0.2.11] — 2026-05-11 — buffers refresh stops clobbering active section + renderer winfixbuf-safe

Two bug fixes triggered by the same v0.2.9 work. User reported: "I'm
on files panel but the content is buffers" — opening any file flipped
the panel's displayed tree from filesystem to buffers. The trace also
showed a recurring `E1513: Cannot switch buffer. 'winfixbuf' is
enabled` inside a `vim.schedule` callback during `fs_scan`.

### Fixed

- **Buffers refresh no longer clobbers the active section.** The
  v0.2.9 `M._install_buffers_refresh_autocmd` fired
  `items.get_opened_buffers(state)` on every BufAdd / BufDelete /
  BufFilePost / TermOpen regardless of which section was currently
  displayed in the panel. `get_opened_buffers` ends with
  `renderer.show_nodes(...)` which unconditionally calls
  `nvim_win_set_buf(panel, state.bufnr)` — swapping the panel's
  displayed tree to the buffers tree even when the user has files
  or repos active.

  Now gated on `state.bufnr == vim.api.nvim_win_get_buf(panel_winid)`
  — only fires when the buffers source is the currently-displayed
  section. Re-mount-on-focus already covers the inactive case: the
  next time the user focuses buffers, a fresh `navigate()` runs and
  the tree reflects the current buffer set.

- **`renderer.show_nodes` is now winfixbuf-safe at line 1230.** The
  `state.current_position == "current"` branch calls
  `nvim_win_set_buf(state.winid, state.bufnr)` to swap the freshly-
  built tree buffer into the panel window. The auto-core.ui.panel
  singleton sets `winfixbuf = true` on the panel to block external
  `:edit` / `:buffer` / bufferline-click hijacks — and that
  protection was raising E1513 against our own legitimate render.
  CRITICALLY this branch is reachable from a `vim.schedule`
  callback (filesystem fs_scan's deferred `render_context`), so a
  consumer-side `with_unfixed_buf` wrap around the calling code
  doesn't cover it.

  Patched the renderer with the same winfixbuf-unset-restore dance
  the close-path already uses (lines 122-145). Pattern: probe
  `vim.wo[winid].winfixbuf`, unset if true, swap, restore. Both the
  buffers and filesystem (follow-mode) render paths now succeed
  without manifesting E1513 in scheduled-callback context.

### Added

- Smoke section [21] (4 assertions): (a) panel on files section,
  fire the buffers refresh, assert panel still displays the
  filesystem buffer; (b) winfixbuf=true on panel, call
  `renderer.show_nodes` against a state — assert it doesn't error
  and the buffer was swapped; (c) winfixbuf restored to true after
  the swap; (d) on re-focus to buffers, the tree reflects the
  current buffer list.

## [v0.2.10] — 2026-05-11 — sections load-timing fix (persisted slot additions survive restart)

Bug fix. User-reported regression: `slot add buffers` correctly wrote
the new section list to
`<state>/auto-core/auto-finder.json:sections[<wskey>]`, but after an
nvim restart the panel came back with the default sections — the
addition appeared lost.

### Fixed

- **Initial-startup load race**. `M.setup` reads `M._workspace_key()`
  synchronously, which depends on
  `auto-core.git.worktree.get_workspace_root()` being populated. With
  worktree.nvim lazy-loaded AFTER auto-finder, the workspace root
  isn't captured yet when setup runs — `wskey = nil`, the seed-from-
  persisted branch is skipped, and `cfg.sections` keeps its default
  baseline. The v0.2.5-era `worktree:switched` subscription only
  fires on real worktree switches, so the reseed never happens on a
  normal session start.

  Now subscribes to **`core.workspace_root:changed`** too (the topic
  worktree.nvim publishes exactly once on first capture). Both
  `worktree:switched` and `core.workspace_root:changed` route to
  `M._reseed_sections_for_workspace` — different triggers, same
  reseed body.

  Adds a `vim.v.vim_did_enter == 1` immediate-retry inside setup
  for the case where workspace_root was captured BEFORE auto-finder
  subscribed (lazy-load order flip — the subscriber misses the
  already-fired event). Matches the auto-core-maintenance
  §"lazy-load VimEnter fallback" convention.

### Added

- Smoke section [20] (4 assertions) — sets a persisted sections
  record for a fake workspace key, simulates the load race
  (setup runs with workspace_root unset), then publishes
  `core.workspace_root:changed` and asserts `cfg.sections` reseeds
  to the persisted list within the debounce window.

## [v0.2.9] — 2026-05-11 — buffers-refresh against panel win-keyed state + winfixbuf-wrap

Bug fix. With the `buffers` section mounted via the v0.2.5 slot DSL,
opening a new file in an editor window (or deleting one with `:bd`)
left the panel's tree stale until a manual remount or section
switch. Two root causes chained:

### Fixed

- **Stub-state refresh on `BufAdd`/`BufDelete`.** The bundled fork's
  `auto-finder/neotree/sources/buffers/init.lua` subscribes to
  `VIM_BUFFER_ADDED` / `VIM_BUFFER_DELETED` and calls
  `buffers_changed_internal`, which resolves state via
  `manager.get_state(name, tabid)`. For our `position = "current"`
  mounts the rendered state lives under `state_by_win[panel_winid]`,
  not `state_by_tab[tabid]` — so the fork's call returns the tab-
  keyed STUB (no path, no winid, no tree) and the refresh silently
  no-ops. Same shape as the v0.2.1 → v0.2.3 files-follow mishap;
  the fix follows the same pattern.

  Installed a new `M._install_buffers_refresh_autocmd(group)` that
  subscribes to `BufAdd` / `BufDelete` / `BufFilePost` / `TermOpen`
  at the consumer layer in `auto-finder/init.lua`. Debounced 80ms,
  fires `items.get_opened_buffers(state)` against the win-keyed
  buffers state bound to `M.state.panel_winid` — same body the fork
  intends to run, against the right state. Installed unconditionally
  so `slot add buffers` after setup still gets covered.

- **`renderer.show_nodes` raised `E1513` against the panel's
  `winfixbuf`.** `lua/auto-finder/neotree/ui/renderer.lua:1230`'s
  `position = "current"` branch swaps the freshly-built tree buffer
  into `state.winid` via `nvim_win_set_buf` — which is exactly what
  the auto-core panel singleton's `winfixbuf = true` exists to block.
  The fork's own subscriber never reached this branch because it
  bailed earlier on the stub-state path check; our direct-against-
  the-real-state call did. Result: `state.loading` got stuck `true`
  (set on entry, never reset because the error fired before the
  reset), and every subsequent refresh early-returned.

  Wrapped the call in `M._panel:with_unfixed_buf(...)` (same shape
  auto-agents uses for slot terminal placement). Also force-clears
  `state.loading` defensively before the call so any prior stuck-
  loading state (from a previous unwrapped run, plugin reload,
  etc.) doesn't permanently brick subsequent refreshes.

### Added

- `M._install_buffers_refresh_autocmd(group)` on the public API.
- Smoke section [19] (5 assertions) exercises the new descriptor,
  end-to-end tree growth on `:split <new_file>`, and the
  state-keying invariants (panel-winid match, cwd match). All 151
  assertions green.

## [v0.2.8] — 2026-05-11 — port `buffers` source + in-place slot mutation + retroactive smoke (rule #4 catch-up)

Three bugs that escaped v0.2.5 because the iteration shipped
without smoke coverage for the new surface — exactly what
[[lua-nvim-plugin-development]] rule #4 forbids. Retroactive
test addition under section [18] of `tests/smoke.lua` now binds
all three so they can't regress.

### Fixed

- **`buffers` source module is now in the fork.** Ported from
  upstream `neo-tree.nvim/lua/neo-tree/sources/buffers/` to
  `lua/auto-finder/neotree/sources/buffers/` (init.lua,
  commands.lua, components.lua, lib/items.lua) with
  `require("neo-tree.…")` → `require("auto-finder.neotree.…")`
  rewrites and `vim.bo.filetype == "neo-tree"` →
  `"auto-finder"` rewrites. v0.2.7 added `"buffers"` to
  `cfg.neo_tree.sources` but the module didn't exist —
  neo-tree's source-loader logged "Source module not found
  buffers" and the mount asserted at `manager.lua:124`.

- **Slot mutation no longer disposes the entire registry.**
  v0.2.5's `_rebuild_section_registry` called
  `Registry:dispose()` which walks every section and runs
  `nvim_buf_delete(buf, { force = true })` on the cached bufnr
  — INCLUDING the config slot's buffer (where the user was
  typing). The panel window's bufnr then pointed at a deleted
  buffer and went blank. v0.2.8 replaces dispose + re-attach
  with surgical in-place mutation:

  * compute `removed = old_names \ new_names`;
  * close + delete buffers only for the removed sections;
  * carry surviving sections' bufnrs forward into the new
    `_bufs` table (keyed by section number);
  * mutate `registry.sections` + `registry._bufs` in place
    (the click router's closure captures the registry by
    reference, so it stays valid).

  No buffer destruction except for slots actually being removed.

- **`slot add` / `slot remove` pin focus to the config slot (0).**
  Both are invoked from the admin REPL — jumping the user away
  from the prompt is jarring AND hides the next prompt. Per
  user direction 2026-05-11. `slot modify N` still focuses N
  (the slot whose type just changed).

### Added

- **Smoke section [18]** — retroactive coverage for the v0.2.5
  surface. Asserts (a) the ported buffers source module loads,
  (b) `_register_bundled_neotree_sources` populates `buffers`
  + `filesystem` + is idempotent, (c) the config slot's buffer
  survives `slot_add` / `slot_remove`, (d) active section stays
  on 0 after mutations. Suite: 133 → 146 (+13 new).

### Lesson codified

Smoke gap was the root cause for all three bugs. Rule #4 of
`lua-nvim-plugin-development` mandates a test per iteration;
rule #11 mandates asserting observable effects. v0.2.5 honored
neither for the buffers section and slot DSL paths. Memory
entry `feedback_nvim_plugin_kb_first.md` saved so this isn't
repeated.

## [v0.2.7] — 2026-05-11 — register `buffers` source so `slot add buffers` mounts

Hotfix for v0.2.5's buffers section. The fork's
`lua/auto-finder/neotree/defaults.lua` declares
`sources = { "filesystem" }`, so neotree's setup pipeline only
builds `default_configs["filesystem"]`. Adding the buffers
section (at startup via `cfg.sections` or at runtime via
`slot add buffers`) trips the assertion at `manager.lua:124`
(`assert(default_configs[sd.name])`) — the panel goes blank
with three "neo-tree.execute failed for source 'buffers'"
errors per mount attempt.

### Fixed

- `M._register_bundled_neotree_sources(cfg)` appends every
  bundled neo-tree source we ship a section module for
  (`filesystem` + `buffers`) to `cfg.neo_tree.sources` before
  the neo-tree setup call. `default_configs` is now populated
  for each at section-mount time.
- Idempotent: skips names already present in
  `cfg.neo_tree.sources` (respects consumer ordering); only
  APPENDS missing bundled names.
- Custom sources (today: `auto-finder-repos` for the `repos`
  section) keep going through their own explicit registration
  helper (`M._register_neotree_workspace_source`); they don't
  need to be in `cfg.neo_tree.sources` because the helper
  registers their default_config directly.

## [v0.2.6] — 2026-05-11 — `slot add` (no args) lists available types

Tiny UX follow-up. v0.2.5 made `slot add <type>` reject a bare
invocation with "section type required". Bare `slot add` is now
more useful as discovery: it prints the available types
(excluding any already in use) AND the currently-in-use list, so
the user can pick without consulting `slot types` separately.

```
auto-finder> slot add
slot add <type> — pick one:
  available: buffers
  in use:    config files repos
```

When every available type is already in use, prints a different
message ("every available type is already in use" + both lists).

## [v0.2.5] — 2026-05-11 — `buffers` section + `slot add/remove/modify` DSL + per-project sections

Three additive features. Extends ADR 0008 with the slot-DSL
addendum.

### Added

- **`buffers` section** — new section module at
  `lua/auto-finder/sections/buffers.lua` wrapping neo-tree's
  bundled `buffers` source. Lists currently-open nvim buffers
  in the panel; `<cr>` / `S` / `s` / `t` route through the v0.2.4
  editor-window resolver so opens land in a real editor window,
  not the panel column. Discoverable via `slot types`.

- **Slot DSL** (admin REPL):

  ```text
  slot add <type>          append a section of <type> at the end
  slot remove <N>          remove section at slot N (N >= 1)
  slot modify <N> <type>   replace section at slot N with <type>
  slot types               list all available section types
  ```

  Available `<type>` is the union of bundled section modules
  under `lua/auto-finder/sections/*.lua` (excluding leading-
  underscore helpers + `init.lua`) and keys in
  `cfg.section_modules` (the v0.2.1 third-party registry). Tab
  completion + topical help (`help slot`) updated.

  Slot 0 (config) is protected; `remove`/`modify` reject it.
  Duplicate types are rejected (a section can only live in one
  slot at a time). `<type>` is required for `slot add` — there
  is no default type.

  Implementation: `M._rebuild_section_registry(new_sections)`
  disposes the live auto-core section registry, re-runs
  `auto-finder.sections.setup`, attaches a fresh registry, and
  re-applies the auto-finder focus-wrapper that mirrors
  `state.section` / persists `last_section` / pumps the catch-up
  neo-tree redraw.

- **Per-project section composition.** `cfg.sections` is now
  loaded from `auto-finder.state.get_sections_for(workspace_key)`
  at setup time and on every `worktree:switched` event. The
  workspace key is `sha256(core.workspace_root):sub(1,16)` —
  same shape md-harpoon uses for per-project pin scoping. Fresh
  / unknown projects start with the new
  `{ "config", "files", "repos" }` baseline (was
  `{ "config", "files" }`). Slot mutations write through to the
  per-project record automatically.

  Motivation: different projects want different section mixes —
  a Go service might prefer `config + files + buffers`, a
  database-ops project will want a `dbase` section (planned), a
  remote-VPS workflow will want a `remote` section (planned).
  The v0.2.1 `cfg.section_modules` registry lets third parties
  ship those types; v0.2.5 persists which projects use which.

### Changed

- **Default `cfg.sections`** is now `{ "config", "files", "repos" }`
  (was `{ "config", "files" }`). Fresh / unknown projects pick
  this up; projects with a persisted record keep theirs.

- **Keymap audit** (ADR 0008) extended to `buffers` section
  mappings — `<cr>` / `S` / `s` / `t` route through the editor-
  window resolver; `e`/`<`/`>`/`.`/`<esc>` are unbound. `H`
  (toggle_hidden) is filesystem-only and not injected on
  buffers (the source doesn't display hidden gitignored files).

### Migration

Fully additive. Existing consumers who didn't override
`cfg.sections` get the new `{ config, files, repos }` default
(one extra section). Slot DSL is opt-in via the admin REPL.
Persisted state lives in `auto-finder.state.namespace`'s new
`sections` map — older state files just don't have it; the
fallback to `cfg.sections` keeps everything working.

## [v0.2.4] — 2026-05-11 — files-panel keymap audit (ADR 0008)

Inherited neo-tree keymaps were never audited against our
`position = "current"` mount mode. Several were silently broken
(splits landing inside the panel column, opens racing
`winfixbuf`), several conflicted with auto-core's models (width
pin, workspace_root, sections), and `H` (toggle_hidden) bypassed
the canonical `auto-core.files` preference. Full rationale in
ADR 0008 (auto-agents KB `shared/adrs/0008-auto-finder-keymap-audit.md`).

### Changed — routed to a real editor window

`<cr>` · `<2-LeftMouse>` · `S` (split) · `s` (vsplit) · `t` (tabnew)
now resolve a usable editor window via
`M._editor_target_winid()` (walks `nvim_list_wins()` skipping
panels / floats / winfixbuf / non-editor buftypes), set it as
current, then run the open command there. Falls back to a fresh
`rightbelow vsplit` when no editor window exists. Directories
still toggle inline (no editor routing) — same as upstream's
open-on-directory.

### Changed — `H` rewired to the canonical preference

`H` (toggle_hidden) now calls
`auto-core.files.set_show_hidden(not get_show_hidden())` and
refreshes the filesystem source. Replaces the upstream-native
toggle that mutated only neo-tree's local state and could drift
from `auto-core.files` (which the admin DSL's `files show/hide
hidden` writes to). Single source of truth.

### Removed — keys irrelevant to our model

Bound to neo-tree's `"none"` (unbind sentinel) via the consumer-
side override layer; the forked `defaults.lua` is unchanged so a
future upstream rebase doesn't conflict on the audit.

| Key | What it was | Why removed |
|---|---|---|
| `e` | `toggle_auto_expand_width` | Fights `auto-core.ui.panel`'s pin/dynamic model — `panel resize` / `panel reset` own this. |
| `<` | `prev_source` | We use auto-core sections (winbar 0/1/2 + buffer-local 0..9). Neo-tree's source-switching is unused. |
| `>` | `next_source` | same |
| `.` | `set_root` | Conflicts with `core.workspace_root` (auto-core canonical). |
| `<esc>` | `cancel` | Redundant against `q` (panel close) and the help-overlay's own close. |

### Notes for consumers

- Override-friendly: the v0.2.4 injection in
  `auto-finder/init.lua:M._inject_keymap_overrides` only sets a
  key when it isn't already set in
  `cfg.neo_tree.filesystem.window.mappings`. Your custom
  bindings for `<cr>` / `S` / `H` / etc. still win.
- `?` help-overlay (v0.2.1) reads live nmaps, so the help list
  reflects whatever's actually bound on the buffer — including
  your overrides and after this audit.

## [v0.2.3] — 2026-05-11 — direct files-follow + worktree:switched re-anchor without duplicate mount

Hotfix for two issues against v0.2.2:

### Fixed

- **`<leader>gw` was opening a duplicate panel inside the editor.**
  v0.2.2's `worktree:switched` re-anchor called
  `cmd.execute({ position = "current" })`, which mounts neo-tree
  in the CURRENTLY-FOCUSED window. If the user was in an editor
  when the topic fired, the auto-finder fork mounted into the
  editor (surfacing as a duplicate "neo-tree" panel). v0.2.3
  mutates `state.path` on every win-keyed filesystem state for
  our source and calls `manager.refresh` — no re-mount, no focus
  change.

- **Files-follow was not visibly revealing the active buffer in
  the tree.** v0.2.1 / v0.2.2 relied on the forked neo-tree's
  internal subscription
  (`manager.subscribe(events.VIM_BUFFER_ENTER, …)`) installed
  inside `M.navigate()`. Even when the subscription wired up, the
  reveal path silently no-op'd because
  `filesystem.follow_internal` resolves state via
  `manager.get_state(name, tabid)` (no winid), which returns the
  TAB-keyed stub with `path = nil` — failing the early-return
  guard `if not state.path then return false end`. The actual
  rendered state lives under `state_by_win[panel_winid]` for
  `position = "current"` mounts.

  v0.2.3 installs an explicit BufEnter autocmd
  (`M._install_files_follow_autocmd` in `auto-finder/init.lua`)
  that drives the reveal directly against the panel's WIN-keyed
  state: walks `manager._get_all_states()` for the filesystem
  state bound to `M.state.panel_winid`, verifies the buffer's
  path is under `state.path`, then calls `fs_scan.get_items` +
  `renderer.focus_node` (the same body `follow_internal` runs,
  but with the right state). Respects the live `cfg.files.follow`
  flag at fire time, so admin-DSL toggles take effect instantly.

### Notes

The forked neo-tree's `follow_current_file` plumbing is untouched —
we just stopped depending on it. Consumers passing
`cfg.neo_tree.filesystem.follow_current_file` get the same
upstream-flavored behavior; the new autocmd is additive.

## [v0.2.2] — 2026-05-11 — admin-DSL toggles for follow mode + worktree:switched re-anchor

Follow-up to v0.2.1. The follow flags were consumable as setup()
opts but the in-panel admin REPL didn't expose them. Three changes:

### Added

- **Admin DSL commands** for runtime toggle:

  ```text
  files follow on|off|toggle    reveal the active buffer in the files tree on BufEnter
  repos follow on|off|toggle    reveal the active buffer's repo in the repos panel
  ```

  `status` output now includes a `follow  files: <state>  repos: <state>`
  line. Tab completion + topical help (`help files`, `help repos`)
  updated to surface the new verbs.

- **Files-follow runtime mutability.** `files follow on|off|toggle`
  mutates `neo.config.filesystem.follow_current_file.enabled` live
  AND `af.state.config.files.follow`, then reloads the section.
  No setup() re-run needed.

- **Repos-follow runtime mutability.** The BufEnter autocmd is now
  installed unconditionally (whenever the repos section exists)
  and reads `af.state.config.repos.follow` at fire time, so
  `repos follow on|off|toggle` takes effect instantly.

- **`worktree:switched` re-anchor.** Sections with `live_refresh =
  true` (today: the files section) now subscribe to the
  `worktree:switched` topic and, on fire, stop+restart the fs.watch
  at the new cwd AND re-mount the neo-tree source via
  `cmd.execute({ action = "show", position = "current" })`. Combined
  with files-follow, `<leader>gw` into a new worktree now refreshes
  the files panel to the new tree AND reveals the active buffer.

  Subscribed to `worktree:switched` only — NOT `core.cwd:changed`.
  A plain `:cd` is too aggressive a trigger to justify re-anchoring
  the panel; the semantic worktree-switch is the right boundary.

### Migration

Fully additive. No config-shape changes; v0.2.1's
`cfg.files.follow = true` / `cfg.repos.follow = false` defaults stay.

## [v0.2.1] — 2026-05-11 — follow mode + section_modules + custom `?` help

### Added

- **Follow mode (per-section).**
  - `cfg.files.follow = true` (default **on**) — maps to neo-tree's
    native `filesystem.follow_current_file = { enabled = true }`. The
    files tree reveals the active buffer on every BufEnter.
  - `cfg.repos.follow = true` (default **off**) — installs a
    debounced BufEnter autocmd that walks up from the active buffer's
    path to find a direct child of `core.workspace_root` (resolved
    via auto-core), then reveals it in the repos section's neo-tree
    via `cmd.execute({ source = "auto-finder-repos", reveal = true,
    reveal_file = … })`. No-op when auto-core isn't installed or
    workspace_root hasn't been captured yet.

- **`cfg.section_modules`** — name → require-path registry that lets
  third-party plugins ship sections without writing into
  `lua/auto-finder/sections/`. When a name in `cfg.sections` is not
  resolvable against the bundled namespace, the registry is consulted
  for an explicit module path.

  ```lua
  require("auto-finder").setup({
    sections = { "config", "files", "repos", "tasks" },
    section_modules = { tasks = "myplugin.afsection.tasks" },
  })
  ```

  Bundled section names (`config`, `files`, `repos`) keep working
  unchanged — the registry is consulted first; missing entries fall
  back to `auto-finder.sections.<name>`.

- **`?` keymap → custom help overlay.** Replaces neo-tree's default
  `show_help` popup with a centered float listing the section's
  effective keymaps (read live from `vim.api.nvim_buf_get_keymap`,
  so consumer overrides surface). Uses
  `auto-core.ui.float.help_overlay` when available; falls back to a
  plain managed float otherwise. Installed as a buffer-local nmap in
  `build_section`'s `get_buffer` / `on_focus` paths so it survives
  neo-tree's re-renders.

### Fixed

- Smoke harness no longer hard-codes Linux paths
  (`/home/johno/Source/Projects/...`). `plugin_root` is now derived
  from `debug.getinfo(1, "S").source`, and the per-host `rtp` prepends
  are guarded with `vim.fn.isdirectory(p) == 1`. Suite runs unchanged
  on Mac and Linux.

### Migration

Fully additive. Consumers who don't touch `cfg.files.follow`,
`cfg.repos.follow`, or `cfg.section_modules` see one behavior change
only: files-follow becomes on by default. Override with
`cfg.files = { follow = false }` to restore prior behavior.

## [v0.2.0] — 2026-05-10 — auto-core consumer

First release on top of [`auto-core.nvim`](https://github.com/yongjohnlee80/auto-core.nvim)
(`^0.1.0`). Per ADR 0006, the cross-cutting plumbing — log, state,
panel, and section registry — moves into `auto-core` so the AutoVim
family observes auto-finder transitions through one canonical
surface.

### Added

- **Hard dependency on `auto-core ^0.1.0`** — installed as a sibling
  via lazy.nvim. All four migration steps live behind it.
- **`auto-finder.logger`** — thin compatibility shim over
  `auto-core.log`. Component-prefixed `auto-finder.<comp>` with format
  `[AutoCore] [auto-finder.X] [LEVEL] msg`. ERROR/WARN still mirror to
  `vim.notify` so user UX is preserved. 14 internal `vim.notify` call
  sites across 5 files refactored to use the shim.
- **`auto-finder.state`** — wrapper over
  `auto-core.state.namespace("auto-finder", { persist = "json" })`.
  Typed setters + watchers for `panel.user_width` (resize pin) and
  `panel.last_section` (last-focused section). State persists to
  `<state>/auto-core/auto-finder.json` instead of
  `<config>/.auto-finder/config.json`.

### Changed

- **Panel host → `auto-core.ui.panel` singleton.** `M._panel = panel_mod.new(…)`
  owns the vsplit lifecycle (open / close / toggle / focus / resize /
  pin / winfixwidth / winfixbuf / orphan adoption / scratch placement /
  `VimResized` + `WinResized`). Marker `auto_finder_panel` derives
  identically from auto-core's `[^%w_]` → `_` rule (compat preserved);
  also stamps the universal `w:auto_core_panel_name` for the winbar
  click router.
- **`panel/host.lua` shrank from 445 → 297 lines** (~33% smaller). The
  remaining functions are thin facades over `M._panel`.
- **`panel/winbar.lua` (98 lines) DELETED** — `auto-core.ui.panel`'s
  `Panel:set_winbar(sections, focused)` covers the same 3-mode
  adaptive renderer + click router. Highlight group renamed
  `AutoFinderSectionActive` → `AutoCoreSectionActive`.
- **Sections → `auto-core.ui.section` registry + `worktree:switched`
  event.** Sections register against the canonical registry; the
  panel auto-invalidates the repos cache when worktree changes.
- **File-filter prefs (`show_hidden` / `show_dotfiles`) → global
  `auto-core.files`.** Filter toggles now stay in sync across the
  family (auto-finder + md-harpoon).
- **Migration: legacy `<config>/.auto-finder/config.json`** auto-seeds
  `panel.user_width` / `panel.last_section` into the namespace on
  first run after upgrade, then `store.save()` strips them so legacy
  values drain on next mutation.

### Fixed

- **Live-refresh broken** when fs.watch fired: `cmd.execute({ action =
  "refresh" })` had no `refresh` branch and fell through to
  `do_show_or_focus`. Routed through `manager.refresh(source)`
  directly. Codified as the "Stub the sink, not the dispatcher"
  pattern in the auto-agents kb.
- **Panel-buffer hijack** via `:vert sb` while `winfixbuf` is set:
  the universal `b:auto_core_panel_owner` marker plus auto-core's
  leak guard now closes the stray window outright (upgraded from
  scratch-bounce per user feedback during live-test).

### Migration notes

- Update your lazy.nvim spec to depend on `auto-core.nvim`:
  ```lua
  {
    "yongjohnlee80/auto-finder.nvim",
    dependencies = {
      "yongjohnlee80/auto-core.nvim",
      "nvim-lua/plenary.nvim",
    },
  }
  ```
- No public API renames. Existing `require("auto-finder").setup({...})`,
  panel verbs, repos surface, and the bundled neotree fork all keep
  their shape.
- Legacy `<config>/.auto-finder/config.json` keeps loading on first
  open so the persisted resize pin and last-section are carried into
  the new namespace, then drained on next save.

## [v0.1.4] — Pre-auto-core fix-ups

- Window-marker counterpart for auto-agents editor-floor.
- `q` (close window) handles E1513 gracefully.
- `M.open` deferred via `vim.schedule` to fix E242 during BufEnter
  hijack.
- Files section live-refresh wired to `auto-core.fs.watch` (soft dep).

## [v0.1.3] — Phase 7

Redraw on resize + winbar prefix tuning.

## [v0.1.2] — Phases 4–7

- Repos section icon overrides (repo + branch glyphs).
- Right-icons clamp + `cfg.neo_tree` wiring.
- Pin check moved into renderer (~100 lines deleted).
- Renderer reads live window width.
- Bundled neo-tree fork rewired (`require("neo-tree")` →
  `require("auto-finder.neotree")`).
- BufEnter hijack + filetype rename — full severance from
  user-installed neo-tree.

## [v0.1.0] — Initial release

Multi-section file explorer panel.
