# Changelog

All notable changes to `auto-finder.nvim` are documented here.

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
