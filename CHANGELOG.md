# Changelog

All notable changes to `auto-finder.nvim` are documented here.

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
