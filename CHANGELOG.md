# Changelog

All notable changes to `auto-finder.nvim` are documented here.

## [v0.2.30] — 2026-05-20 — `marks` slot: path crop, two-line layout, `i` info popup

Display polish + a new info keymap on the v0.2.29 marks slot.
Long paths now collapse to `parent/basename` (with a leading
`.../` when the source path was deeper); previews drop to an
indented continuation line so long content doesn't get truncated
by the panel width. New `i` keymap opens a small bordered float
with the mark's full details — same role as neo-tree's
`show_file_details_popup`.

### Changed

- **`lua/auto-finder/views/marks/init.lua`** path shortening
  switched from cwd/home-relative to `<parent_dir>/<basename>` —
  much shorter for global marks pointing outside the current
  project tree. When the source path is DEEPER than
  `parent/basename`, a leading `.../` signals the crop. Edge
  cases handled: a root-level file returns its basename only.

  ```
  /foo.lua                 → foo.lua
  /foo/bar.lua             → foo/bar.lua
  /foo/bar/baz.lua         → .../bar/baz.lua
  /a/b/c/d/e.lua           → .../d/e.lua
  ```

- **Two-line render layout per mark.** Bracket + path + line on
  the first line, preview indented under the bracket on the
  second. Removes the previous "preview gets eaten by the panel
  width" problem without depending on window-level wrap. The
  `_rows` lookup maps BOTH lines to the same record so `<CR>` /
  `d` / `i` work from either visual line.

### Added

- **`i` keymap** opens an info popup for the mark under the
  cursor: bordered float (rounded), wraps long fields, shows
  `Mark`, `File` (full path, not cropped), `Line`/`Col`,
  `Buffer` (loaded state + bufnr), `Size`, `Mtime`, and the full
  `Preview`. Dismissable with `q` / `<Esc>`. `nowait = true`
  intercepts before nvim's insert-mode trigger (the buffer is
  `nomodifiable` either way).

### Verified

- Smoke section `[12c]` updated for the new layout: assertions
  now count UNIQUE records (each maps to 2 line entries), confirm
  the X record is reachable from both its lines, and check that
  the `i` keymap is installed alongside `<CR>` / `d` / `R`.
  Suite green at **458 passed / 0 failed** (was 456/0).

### Consumer impact

Strictly additive. No setup-config changes. The new `i` keymap
is buffer-local on the marks slot only — does not collide with
existing nvim insert-mode usage outside the panel. Users picking
up v0.2.30 from `^0.2.0` get the polish automatically; no
`slot remove marks; slot add marks` cycle needed.

## [v0.2.29] — 2026-05-20 — `marks` slot (nvim native marks panel)

New top-level view rendering nvim's native marks as a flat list:
global A-Z marks at the top, local a-z marks grouped per loaded
buffer. Discoverable via `slot add marks` from the config REPL.

### Added

- **`lua/auto-finder/views/marks/init.lua`** — new view module.
  Scratch buffer (not neo-tree-backed), filetype
  `auto-finder-marks`. Renders all marks reachable from
  `vim.fn.getmarklist()` (globals) and `vim.fn.getmarklist(b)`
  (locals, one call per loaded buffer with a non-empty name).
  Each row shows the mark letter, the file (cwd- or home-relative
  when possible), the line number, and the line preview.

  Buffer-local keymaps:
  - `<CR>` — jump to mark. Routes via the existing
    `M._editor_target_winid()` to land in an editor window (not
    the panel), reuses the bufnr when the mark's buffer is still
    loaded, falls back to `:edit <path>` otherwise. Places the
    cursor at the recorded line/col.
  - `d` — delete the mark (matches `:delmarks`). Globals cleared
    via `vim.fn.setpos("'X", {0,0,0,0})`. Locals cleared inside
    the owning buffer's context via `vim.api.nvim_buf_call`.
    Re-renders after deletion. `nowait = true` makes the single-
    key mapping fire immediately; the buffer is `nomodifiable`
    anyway so nvim's `d`-operator would no-op even without it.
  - `R` — manual refresh.

  Auto-refresh wiring (nvim has no native `MarkChanged` event):
  refresh fires on slot focus (always), and on `BufWritePost` /
  `CursorHold` when the marks buffer is currently visible in
  some window. The `_is_visible()` gate avoids paying the render
  cost when the slot is hidden — the next focus will re-render
  anyway. Augroup `AutoFinderMarksRefresh` is allocated on
  `get_buffer` and torn down on `on_close`.

- **Discovery** — `_available_section_types()` already scans
  `views/<name>/init.lua` for bundled views, so `marks` appears
  in the `slot add` / `slot modify` tab-completion automatically.
  No registry hook required.

### Verified

- `tests/smoke.lua` section `[12c]` adds 19 assertions covering:
  discoverability, slot focus + buffer creation + filetype, the
  render output (GLOBAL / LOCAL headers + `[X]` / `[a]` rows +
  cwd-relative file path), the `_rows` lookup shape (kind/line/
  file fields on each record), delete-mark behavior (X removed,
  unrelated `a` survives), empty-state placeholder, buffer-local
  keymap installation (`<CR>` / `d` / `R`), and the
  `AutoFinderMarksRefresh` autocmd registration. Suite green at
  **456 passed / 0 failed** (was 437/0).

### Consumer impact

Strictly additive. No setup-config changes. No new auto-core
requirement (uses the existing `_editor_target_winid()` and
`views/<name>` discovery surface). Users opt in by typing
`slot add marks` in the config slot.

## [v0.2.28] — 2026-05-20 — per-workspace `last_section` + clamp on focus

Fixes a cross-project staleness bug where the last-focused section
bled from project1 into project2 and produced an empty panel. Two
complementary fixes: (a) `last_section` becomes per-workspace so the
stale value never leaks in the first place; (b) `M.focus` clamps
unresolvable section keys to `default_section` so any other stale
path (legacy global on first launch after upgrade, programmatic
miscalls, future per-workspace records written before a slot list
shrank) also lands safely.

### The bug

Concrete repro: project1 has 4 slots (`config`, `files`, `repos`,
`buffers`, `dbase`). User focuses dbase (slot 4) and closes nvim.
Opens nvim in project2 which only has 2 slots (`config`, `files`,
`repos`). The panel opens — empty. No buffer visible, winbar
incomplete.

Why: pre-v0.2.28 `last_section` was a single global namespace key
(`auto-core.state.namespace("auto-finder"):get("last_section")`), not
keyed by workspace. `M.open` read `4` from that key, called
`M.focus(4)`, which `auto-core.ui.section.Registry:focus` rejected
with `false, "no such section: 4"`. The panel had already been
opened by `host.ensure_open` above, but no buffer ever got swapped
in. The pcall around the registry call swallowed the error.

### Fixed

- **`lua/auto-finder/state.lua`** — new
  `last_section_by_workspace` namespace key (default `{}`), keyed
  by `sha256(workspace_root):sub(1,16)` (same shape as the existing
  `sections` per-workspace map). New helpers
  `get_last_section_for(wskey)` / `set_last_section_for(wskey, n?)`
  mirror the `get_sections_for` / `set_sections_for` pattern. Type
  validation, defensive deep-copy on write, nil-clears a record.

- **`lua/auto-finder/init.lua`** initial seed at setup reads per-
  workspace first, falls back to the legacy global key for back-
  compat with pre-v0.2.28 namespaces:

  ```lua
  local _wskey_init = M._workspace_key()
  M.state.section = (_wskey_init and state_mod.get_last_section_for(_wskey_init))
    or state_mod.get_last_section()
  ```

- **`lua/auto-finder/init.lua`** `_post_focus` (the wrapper around
  `M._registry.focus`) now persists to BOTH the legacy global key
  and the per-workspace key when `wskey` is available. Writing
  both keeps a downgrade window functional — pre-v0.2.28 still
  finds a sensible (if cross-workspace) value.

- **`lua/auto-finder/init.lua`** `_reseed_sections_for_workspace`
  re-seeds `M.state.section` from the per-workspace record BEFORE
  the slot-list diff check. Covers two cases: (1) slot list differs
  → `_rebuild_section_registry` picks up `M.state.section` as
  `prev` in its focus-target resolver; (2) slot list identical →
  the early-return path now explicitly re-focuses when the per-
  workspace `last_section` differs from the currently-active slot.

- **`lua/auto-finder/init.lua`** `M.focus` gains a clamp: if
  `views.resolve(key)` returns nil, the key is replaced with
  `cfg.default_section or 0`. Single chokepoint covers all entry
  points (`M.open` reading stale state, programmatic
  `M.focus(N)`, legacy persisted values during the migration
  window).

### Migration

Strictly additive. No setup config changes. No API removals.

- Existing users keep using their global `last_section` until the
  first focus after upgrade — that focus writes both the global key
  and the new per-workspace key. From then on, per-project tracking
  takes over.
- The legacy `state.get_last_section()` / `set_last_section()`
  helpers stay public (no deprecation). Writers update both keys so
  a downgrade to v0.2.27 still finds a value.

### Verified

- `tests/smoke.lua` section `[12b]` adds 12 new assertions covering
  per-workspace round-trip, cross-workspace isolation, nil-clear
  semantics, typed-guard rejection of bad wskey / bad n, and the
  M.focus clamp landing on `default_section` when called with an
  out-of-range section number. Suite green at **437 passed / 0
  failed** (was 425 pre-fix).

### Consumer impact

Strictly additive. No required auto-core version bump (uses
existing `auto-core.state.namespace` surface). Consumers pinning
`version = "^0.2.0"` pick up via `:Lazy update`.

## [v0.2.27] — 2026-05-20 — dbase: rebind keymaps + refresh winbar after deferred drawer mount

ADR 0026 Phase 7 ships the dbase view through the
placeholder-pattern: `get_buffer()` returns a `shared.loading`
placeholder and the real dbee drawer is swapped in by a
`vim.schedule`-deferred mount inside `on_focus()`. That two-buffer
transition was invisible to `auto-core.ui.section.Registry`, which
binds the panel's buffer-local `0..9`/`q` keymaps and refreshes
the winbar once per `Registry:focus()` — against the placeholder
bufnr that `get_buffer()` returned, NOT against the dbee drawer
that landed in the panel a few milliseconds later.

User-visible symptom: navigating to dbase for the first time hid
the panel winbar and broke numeric section-hop on the drawer
buffer. Triggering any later `_refresh_winbar` path (`<leader>e`
toggle, auto-agents `<F5>` open, etc.) healed both because the
re-toggle re-ran `Registry:focus()` against the now-cached real
bufnr (`Registry:focus` re-binds keymaps + winbar on every call).

KB: `shared/synthesis/2026-05-20-auto-finder-dbase-winbar-remount-bug-analysis.md`,
`shared/synthesis/auto-core-registry-keymap-rebind-hook.md`.

### Fixed

- **`views/dbase/init.lua`** — after each terminal branch of the
  deferred mount sets `M._bufnr`, the new
  `_notify_remount(real_bufnr)` helper calls
  `auto-core.ui.section.Registry:section_did_remount(M.number,
  real_bufnr)`. The registry repairs three things: updates its
  `_bufs[N]` cache so subsequent `focus(dbase)` reuses the real
  buffer, re-runs `apply_keymap` so `0..9` and `q` work on the
  drawer, and refreshes the winbar so the active-section
  highlight returns. Fires on all three terminal branches —
  dbee-unavailable placeholder, drawer_show success, and
  drawer_show-returned-nil placeholder.

### Required auto-core

- **Hard prereq: `auto-core@v0.1.25+`** for the
  `Registry:section_did_remount` public hook. On older auto-core
  `_notify_remount` logs a DEBUG entry and falls through silently
  (the bug persists until consumers update; we don't error).
- Recommend consumers re-pin both via
  `:Lazy update auto-core.nvim auto-finder.nvim` together.

### Verified

- Live: pointed `~/.config/nvim/lua/plugins/auto-{core,finder}.lua`
  at the `registry-rebind-hook` + `dbase-rebind-on-remount`
  worktrees via `dir=`; cold-focused dbase via
  `:AutoFinderFocus dbase` from a fresh session. Pre-fix: winbar
  empty, `0..9` no-op on the drawer. Post-fix: winbar populated
  with the active dbase highlight; `0..9` switches views; `q`
  closes the panel.

### Compatibility

- Public API unchanged for direct consumers of
  `require("auto-finder")`. New `Registry:section_did_remount`
  dependency is internal to the dbase view; other views
  (config / files / repos / buffers) don't go through the
  placeholder pattern yet, so they're unaffected.

## [v0.2.26] — 2026-05-20 — Post-v0.2.25-approval cleanup (Lector follow-ups)

Lector approved v0.2.25's B1 + B2 fixes (`approved_with_amendments`,
0 blockers, verified smoke 425/0 against `ae453d3`) and called out
three non-blocking follow-ups. v0.2.26 ships those. v0.2.25's
release SHA stays at `ae453d3` so Lector's review record stays
anchored; v0.2.26 lands on top.

### Cleaned

- **Stale `_fs_subscribed` references** removed from
  `shared/neotree.lua` (file-header comments at lines 39-50 +
  the docstring at line 65) and `tests/smoke.lua` (sections
  [31] and [37] no longer carry the manual
  `_fs_subscribed = false` workaround). The field stopped
  existing in v0.2.25's B1 fix; the references existed only
  because the smoke had been using them as workarounds.
- Updated comments to describe the actual implementation:
  `section._live_subs` + `section._core_subs` via
  `shared.view_subs:replace`.

### Hardened

- **`renderer.show_nodes` parentId entry guard.** Lector's
  residual-stale-state class: if a lazy-load callback arrives
  with `parentId` set but `state.tree` is still nil (e.g.
  fs_scan completes after panel close in a path that doesn't
  call `create_tree` first), the inner
  `pcall(state.tree.get_node, …)` would throw before the
  existing post-`create_tree` nil-tree guard runs. v0.2.26
  adds an entry guard that exits silently when
  `parentId ~= nil and not state.tree`. This is a defensive
  hardening against a class of failures Lector noted is
  possible but he didn't observe in production; the explicit
  guard closes it.

### Documentation

- **README.md** softened the "single source of truth" framing
  so it doesn't imply view-level delta-rendering already
  works. ARCHITECTURE.md and CHANGELOG were correct already;
  README now matches. View modules still render through
  neo-tree's `manager.refresh` path on receiving translated
  events; the cache surface exists so a future phase can
  flip to delta-rendering.

### Suite

- v0.2.25: 425 passed / 0 failed (34 sections).
- v0.2.26: **same — 425/0**. Cleanup commit; no new asserts.
  Existing smokes continue to prove behavior; the stale
  workarounds are gone.

### Compatibility

- Public API unchanged.
- No new auto-core surface required.
- autovim caret `^0.2.0` auto-picks-up.

## [v0.2.25] — 2026-05-20 — Post-Lector-review fixes (B1 + B2)

Follow-up to v0.2.24. Lector's review of the ADR 0026 arc
flagged two release blockers and three documentation gaps; this
release ships the fixes.

### Fixed

- **B1 — View subscriptions now survive an auto-core bus reset.**
  `shared/neotree.lua`'s `_arm_live_refresh_subs` and
  `_arm_core_refresh_sub` previously used one-shot booleans
  (`_fs_subscribed`, `_core_refresh_subscribed`) which masked
  the production failure: after a bus reset wiped the
  subscriber tables, the flags stayed `true` and re-focus
  never re-armed. v0.2.25 migrates both arm paths to
  `shared.view_subs:replace(slot, topic, cb)` which
  unsubscribes the prior handle before subscribing fresh —
  safe and idempotent. New smoke section [38] proves
  bus-reset survival for files / buffers / repos views
  WITHOUT the manual `_fs_subscribed = false` dance that
  earlier smokes used to mask the issue.

- **B2 — `vim.schedule callback: missing bufnr` stack trace
  eliminated (frequently observed on macOS).** The vendored
  neo-tree fork's `renderer.create_tree` calls
  `NuiTree({ bufnr = state.bufnr, … })`; when `state.bufnr`
  was nil (the async-render-against-stale-state path: fs_scan
  completes after the panel was closed or section switched),
  NuiTree.init threw "missing bufnr" and surfaced as a
  scheduled-callback stack trace in the user's session.
  v0.2.25 adds a guard in `create_tree` that bails when
  `state.bufnr` is nil or invalid + a downstream guard in
  `show_nodes` that exits silently if `state.tree` is still
  nil. New smoke section [38] asserts no unhandled scheduled-
  callback errors during a rapid open/close cycle.

### Changed (documentation)

- **`ARCHITECTURE.md` cache-rescan claim corrected.** The
  doc previously said directories marked `stale` re-scan on
  next render via `vim.uv.fs_scandir`. That is aspirational;
  the actual translator coalesces events and publishes
  `auto-finder.core.files:changed`, but the consumer in
  `shared/neotree.lua` still calls `manager.refresh(source)`
  (full neo-tree rewalk). The text now clearly distinguishes
  implemented event coalescing from future delta-render work.
  Subdirectory lazy-warm on `core.files.get(path)` is
  similarly clarified as future work.

- **`tests/auto-finder-flaky.test.md` reimplementation plan
  updated** for the removed section [24]. The original plan
  pegged it to Phase 7's loading-placeholder pattern; Phase
  7 narrowed scope to dbase only (per F7.1), so the
  reimplementation is now deferred until auto-core exposes a
  public `Registry:rebind_keymaps(bufnr)` hook.

### Performance claim correction

The v0.2.24 entry was lightly overstated. Restated here:

- The user-facing payoff is **event coalescing reduces refresh
  call frequency** — a 100-event burst becomes one
  `manager.refresh` call instead of N.
- The cost of each individual refresh is **unchanged** — the
  render path still triggers a full neo-tree rewalk at the
  renderer layer. True delta-rendering from the cache is
  future work; the architectural surface is now ready for it.
- A5 instrumentation is in place; the formal ≤ 50% comparison
  benchmark remains deferred.

### Suite

- v0.2.24: 417 passed / 0 failed (33 sections).
- v0.2.25: **425 passed / 0 failed (34 sections).**
- New: section [38] covers B1 (3 bus-reset survival asserts +
  2 view_subs invariant asserts) and B2 (2 guard-presence
  asserts + 1 async-error-capture assert).

### Audit log update

- New "Phase 10" entries: F10.1 (B1 fix), F10.2 (B2 fix),
  F10.3 (smoke grep broadening after the view_subs migration).
- New forward-policy rule per Lector's review: smoke sections
  that tolerate stderr / scheduled-callback errors must
  either capture and assert the exact tolerated warning, or
  fail. The B2 async-error-capture assert is the reference
  implementation.

### Compatibility

- Public API unchanged.
- No new auto-core surface required (B1 fix uses the existing
  `shared.view_subs` helper; B2 fix is internal to the
  vendored neo-tree fork).
- autovim consumer caret `^0.2.0` covers this release.

## [v0.2.24] — 2026-05-20 — ADR 0026 refactor: runtime state ↔ UI separation (9-phase arc)

Cumulative release of the ADR 0026 refactor arc — all nine
phases land at once per the user-set "tag once everything is on
the remote" cadence. The architecture is now split between a
runtime state component (`lua/auto-finder/core/`) that owns
every cache + watcher + auto-core subscription, and UI views
(`lua/auto-finder/views/`) that subscribe to the translated
`auto-finder.core.*` topics. See `ARCHITECTURE.md` for the
post-refactor map.

The user-facing symptom that opened the arc — "files panel
hijacks CPU on busy operations" — is mitigated by the
translator-side burst coalescing: 100 file events in a window
now produce a single render call instead of 100. A formal
≤50% benchmark is deferred (the Phase 4 baseline capture step
was not executed during the arc; see audit log
`tests/auto-finder-test-audit.md` for the procedure to capture
it later).

### Added (architecture)

- `lua/auto-finder/core/` — runtime state component (8 modules):
  - `init.lua` — re-armable lifecycle (`ensure_started` /
    `stop` / `reload` / `is_started`). Subscribes upstream
    `auto-core.*` topics + Buf* autocmds; publishes the
    `auto-finder.core.*` topic family. Owns the file-event
    debounce coalescer (100 ms window) with burst detection
    (>50 events on one parent → `kind='subtree_stale'`).
  - `events.lua` — topic registry + thin pub/sub wrappers over
    `auto-core.events`. Six published topics:
    `auto-finder.core.files:changed`, `auto-finder.core.git:changed`,
    `auto-finder.core.buffers:changed`, `auto-finder.core.repos:changed`,
    `auto-finder.core.ready`, `auto-finder.core.metrics:paint`.
  - `files.lua` — directory-aware sparse cache. File + directory
    entries with `children_state = 'cold' | 'known' | 'stale'`.
    Surgical updates from file events; bounded per-directory
    rescan from `subtree_stale`.
  - `git.lua` — denormalized view over `auto-core.git.status`.
    Path-keyed `by_path[abs] = { x, y, code }` from porcelain
    entries.
  - `buffers.lua` — Buf*-autocmd-driven cache (`:ls` shape;
    listed + unloaded). Augroup re-armed on every
    `ensure_started`.
  - `repos.lua` — denormalized view over `auto-finder.repos`
    (which is itself a `worktree.nvim` facade).
  - `watchers.lua` — `fs.watch` + `git.watch` handle owner.
    Graceful `max_handles` degradation (warn + readiness flip).
  - `warm.lua` — chunked top-level walker (8 entries / tick;
    no tick exceeds 5 ms per A15).

- `lua/auto-finder/shared/` — pure helpers (5 modules):
  - `neotree.lua` — relocated + slimmed `_neotree.lua`. Now
    owns the neo-tree mount + the `_arm_live_refresh_subs`
    subscription wire.
  - `loading.lua` — generation-tagged placeholder buffer
    factory (`nofile` + `bufhidden=wipe` + read-only). Used by
    the dbase view's two-phase mount.
  - `window.lua` — `is_any_panel` / `is_auto_finder_panel`
    predicates per the panel-ownership convention.
  - `view_subs.lua` — per-view subscription set with
    replace-or-add semantics.
  - `debounce.lua` — generation-counter coalesce helper.
    Replaces two inline `vim.defer_fn` coalescers that were
    silently broken (the `vim.fn.timer_stop(prior)` cancel was
    no-op'ing because `vim.defer_fn` returns nil; audit log
    F8.1 captured the pre-existing bug).

- `lua/auto-finder/views/` — UI view modules (each is a
  directory). Renamed from `sections/` (which is preserved as a
  one-line facade for v0.2.x backwards-compat). dbase view
  adopts the placeholder + five-guard mount (ADR §A16);
  neo-tree-backed views keep synchronous mount due to F7.1
  (auto-core Registry keymap-binding tension).

- `ARCHITECTURE.md` — post-refactor plugin map. Includes two
  mermaid diagrams (system architecture flowchart + event flow
  sequence) and a deep "Event detection + processing" section
  covering all seven event categories.

- `tests/auto-finder-test-audit.md` — per-phase failure +
  remediation log for the refactor arc.

- `tests/auto-finder-flaky.test.md` — catalog of smoke
  sections removed during the refactor with reimplementation
  plans. First entry: section [24] show-race (removed Phase 4
  cleanup; reimplementation planned against Phase 7's eventual
  placeholder pattern).

### Changed

- `cfg.section_modules` accepted as backwards-compat alias for
  the new `cfg.view_modules` (one-time deprecation warn at
  startup). Alias drops at next minor.
- All `vim.notify(...)` call sites in the plugin tree now route
  through `auto-finder.log` per
  [[auto-family-logging]] (A9). Component-tag scheme follows
  `auto-finder.<subtree>.<name>` (A10).
- The dbase view's log component tags migrated to
  `view.dbase.*`.

### Fixed

- Pre-existing `vim.defer_fn` cancellation bug (F8.1). The
  `pcall(vim.fn.timer_stop, _file_buf_timer)` pattern in the
  pre-Phase-8 translator and `schedule_refresh` coalescers
  silently no-op'd; both worked by accident through "already
  drained" guards. `shared/debounce.coalesce` fixes both
  callsites by using a generation counter instead of timer
  cancellation.

### Deferred (not in this release)

- **A5 formal benchmark** — `auto-finder.core.metrics:paint`
  is instrumented and verified; the ≤50% comparison against
  the v0.2.23 baseline needs someone to capture pre-refactor
  numbers via a local patch on the v0.2.23 tag.
- **ADR §A3 revision-4 amendment** — soften "every view
  returns a placeholder" to "views with async mount paths
  (dbase) only" until auto-core ships a public keymap-rebind
  hook (F7.1).
- **macOS FSEvents reliability** — owned by auto-core. The
  user-visible rename/delete-needs-`R` bug is tracked at
  `[[auto-core-fs-event-macos-reliability]]` in the project
  KB. auto-finder is correctly written; upstream event stream
  is incomplete on darwin.

### Suite

- v0.2.23 baseline: 263 passed / 1 failed (the section [24]
  flake, removed during Phase 4 cleanup).
- v0.2.24 HEAD: **417 passed / 0 failed** across 37 sections.
  +154 net new assertions across the arc; -1 structurally-
  removed section.
- 31 initial-development failures across the 9 phases; every
  one resolved before its phase landed. Root causes +
  remediations in `tests/auto-finder-test-audit.md`.

### Compatibility

- Public API unchanged. `require("auto-finder").setup/open/close/toggle/focus/resize`
  signatures match v0.2.23. User commands unchanged.
- Internal module paths changed (`sections/` → `views/`);
  facade re-exports preserve `require("auto-finder.sections.<name>")`
  for any third-party consumer through v0.2.x. Facade removed
  at next minor.
- autovim consumer caret `^0.2.0` covers this release; no
  consumer-side change required beyond `:Lazy update`.

## [v0.2.23] — 2026-05-18 — Buffers panel: `:badd`'d files now visible + user-story smoke

> Note on numbering: v0.2.21 and v0.2.22 shipped between my branch-out
> and tag time (`guard nvim_set_current_win against closed window` and
> `defer scan.started toast behind MAPPING_TOAST_MS` respectively).
> Both are tagged on origin but don't have CHANGELOG entries here —
> the maintainer can add them retrospectively if desired. This commit
> linearly descends from v0.2.22 and bumps to v0.2.23 to preserve a
> monotonic tag sequence for lazy.nvim caret consumers.


Fixes a latent bug where files added to the buffer list via `:badd`
(or any path that leaves a buffer `listed=true, loaded=false` —
session restore, LSP workspace registration, scripted buffer adds)
were silently dropped from the auto-finder buffers panel despite
showing up in `:ls`. Surfaced this session via `:badd`'ing five
random files; the panel rendered only the legitimate terminal
buffers, with the file buffers nowhere to be found.

### Fixed

- **`lua/auto-finder/neotree/defaults.lua` — `buffers.show_unloaded`
  default flipped from `false` → `true`.** The bundled `add_buffer`
  filter at `buffers/lib/items.lua:60-62` short-circuits on
  `is_loaded or state.show_unloaded`. With `show_unloaded = false`
  (the upstream default we inherited), listed-but-unloaded buffers
  were excluded. The auto-finder panel's expected role is "every
  buffer my session knows about", not "every buffer I've actually
  visited" — flipping the default brings the panel's contents in
  line with `:ls` semantics. Consumers who want the upstream-strict
  behavior can opt back in via
  `cfg.neo_tree.buffers.show_unloaded = false`.

### Added

- **Section [24] `tests/smoke.lua` — user-story coverage for the
  buffers panel.** Seven assertions: `:edit` shows up, **`:badd`
  shows up (regression guard)**, `:bd` removes, terminal buffers
  group, out-of-cwd buffer appears, `/tmp` bucket as a depth=1
  sibling group.
- **Section [25] — user-story coverage for the files panel.** Two
  assertions: writefile-creates-new-file → tree shows it; delete →
  tree drops it.
- **Section [26] — user-story coverage for the repos panel.** Two
  assertions: focus mounts a live state; tree has ≥1 node for the
  current workspace.

### Versioning

Patch within v0.2.x. Linear descendant of v0.2.20. Suite green at
**259 passed, 0 failed** (was 244 → +15). Autovim consumer caret
`^0.2.0` already covers.

## [v0.2.20] — 2026-05-17 — Files panel refreshes on external git state (ADR 0025 Phase 3)

Closes the long-standing bug where the `files` section's git
decorators (`M` / `A` / `??` / staged column) stayed stale after any
git mutation performed outside nvim — terminal `git add` /
`git commit` / `git checkout` / `git reset`. Root cause was a
refresh-trigger gap on the panel side; the auto-core side of the fix
shipped in `auto-core@v0.1.19` (ADR 0025 Phase 1, new
`auto-core.git.watch` module + `core.git.state:changed` topic). This
release lands the consumer-side wire-up.

### Changed

- **`lua/auto-finder/sections/_neotree.lua` — `setup_live_refresh`**
  now opens an `auto-core.git.watch` handle on the cwd's `.git/`
  plumbing alongside the existing `fs.watch` working-tree handle,
  and adds a third `events.subscribe("core.git.state:changed", …)`
  filtered by exact `repo_root` match against the section's watched
  root. Calls the same `schedule_refresh()` coalescer the existing
  subscriptions use. Handles are stopped+restarted by the existing
  `worktree:switched` cycle through `_stop_fs_watch` /
  `_ensure_fs_watch` — no new lifecycle concept.

### Soft-dep contract

Gated on `auto-core ≥ v0.1.19` via a capability probe
(`type(core.git.watch.start) == "function"`). Older auto-core pins
get the existing working-tree refresh + worktree-switch behavior
unchanged; only the `.git/`-side refresh requires the new surface.

### Tests

Section [14b] of `tests/smoke.lua` adds 9 assertions: capability
probe, handle present after focus, normalized-root match, synthetic
`core.git.state:changed` for the watched repo triggers
`manager.refresh`, unrelated `repo_root` does NOT refresh, malformed
payload (missing `repo_root`) is ignored safely, and
`_stop_fs_watch` clears both handles. The smoke harness also got a
small precedence fix so the workspace `main` and active feature-
branch worktrees of `auto-core.nvim` win the rtp race over the
LAZY-installed copy — necessary for the new wire-up to exercise the
just-shipped auto-core surface. Suite green at 232 passed / 0 failed.

### Versioning

Patch within `v0.2.x` per `auto-core-maintenance`-style additive-only
discipline. Linear descendant of `v0.2.19` after that branch
(`feat/dbase-conn`) was merged into `main` ahead of this release —
satisfies `git merge-base --is-ancestor v0.2.19 v0.2.20` so
`lazy.nvim` consumers on `version = "^0.2.0"` upgrade without
losing v0.2.19's `dbase` work. Autovim consumer caret `^0.2.0`
already covers.

## [v0.2.19] — 2026-05-17 — `dbase`: in-panel wizard prompts, full type list, and connection-id healing

### Fixed

- **`dbase conn add` now stamps a dbee-compatible `id` on every new
  connection.** v0.2.18 wrote specs without `id`, which made dbee's
  `Handler:source_reload` error with `connection without an id: { name:
  "...", type: ..., url: ... }` the next time the FileSource was
  reloaded. The new id format (`file_source_/<10-char>`) matches what
  dbee's own `FileSource:create()` writes, so files round-trip
  cleanly between the REPL and dbee's interactive create path.
- **Legacy id-less entries are healed automatically.** `dbase load`
  assigns ids when swapping a named file's contents into
  `_active.json` AND writes the heal back into the named file, so it
  persists across future loads. `_reload_dbee` also heals
  `_active.json` just-in-time before calling `source_reload`, so a
  user upgrading from v0.2.18 with an already-broken `_active.json`
  recovers without any manual cleanup.

### Changed

- **`dbase conn add` and `dbase load` (without a name argument) now
  prompt inside the admin REPL via a new wizard.** Previously these
  verbs called `vim.fn.input()`, which popped a separate prompt at
  the bottom of the editor — outside the config-section panel. The
  new flow mirrors auto-agents.nvim's `panel.wizard`: the multi-step
  prompts (`connection name` → `type` → `url`, or `file name` for
  load) render in-place above the auto-finder prompt line, and
  `<C-c>` cancels at any step.
- **`dbase conn add`'s type picker lists every dbee adapter alias**
  (`postgres | mysql | sqlite | bigquery | redis | mongodb |
  clickhouse | databricks | duckdb | oracle | redshift | sqlserver`)
  instead of `postgres|mysql|sqlite|bigquery|redis|mongodb|...` —
  the `...` was unhelpful when the whole point of the prompt is to
  remind the user which backends are available. The wizard's
  validator rejects values outside this list before
  `dbee.api.core.source_reload` would.

### Added

- **`lua/auto-finder/panel/wizard.lua`** — step-by-step prompt runner
  inside the admin prompt buffer. Self-contained (no auto-agents
  dep). Tracks active state so the admin's `prompt_setcallback`
  routes input through `wizard.feed()` while a wizard is running,
  and `<C-c>` cancels.
- **`_dbase_files.TYPES`** — canonical list of dbee adapter aliases
  the REPL surfaces. Hand-mirrored from
  `nvim-dbee/dbee/adapters/*.go` (the registry lives in the Go
  binary, not in dbee's Lua surface).

### Tests

- Five new smoke-test assertions in section 23 cover (a) `conn_add`
  stamps a `file_source_/<id>` on every new spec, (b) `load` heals
  legacy id-less entries in both `_active.json` and the named file,
  (c) `_ensure_ids` is idempotent on already-healed input, (d)
  `dbase conn add` activates the wizard and drives `conn_add` to
  completion when fed the three steps programmatically, and (e)
  `TYPES` covers the headline backends without a `...` placeholder.

## [v0.2.18] — 2026-05-17 — `dbase`: connection-file management from the config-section REPL

### Added

- **Filesystem-backed dbase connection inventory** under
  `~/.local/state/nvim/auto-finder/dbase/`. The user maintains a
  library of named `<name>.json` files (the durable record) and a
  single pinned `_active.json` (what dbee's `FileSource` reads).
  Swap semantics happen at the filesystem layer — never via
  dbee's no-op `remove_source`.
- **New config-section REPL verbs** (driven by the new module
  `lua/auto-finder/sections/_dbase_files.lua`):
  - `dbase new <name>` — create an empty connections file
    (`.json` auto-appended, path separators rejected).
  - `dbase ls` — list available files; `*` marks the active one.
  - `dbase rm <name>` — delete a file (resets `_active.json` if
    the active one is removed).
  - `dbase load [name]` — activate a file (prompts when name is
    omitted). Calls `dbee.api.core.source_reload("_active.json")`
    so the drawer reflects the swap without re-running
    `dbee.setup`.
  - `dbase conn add` — prompt for name/type/url and append to the
    active file (validates required fields, rejects duplicates).
  - `dbase conn ls` — list connections in the active file.
  - `dbase conn rm <name>` — remove a connection by name.
- **Autocomplete wired at every depth** in the config-section
  REPL: `dbase` at the root, `new|ls|rm|load|conn` after `dbase `,
  `add|ls|rm` after `dbase conn `, dynamic file-name completion
  for `dbase rm` / `dbase load`, and dynamic connection-name
  completion for `dbase conn rm` (live from the active file).
  `dbase` also joins the `help <topic>` completion set.
- **`help dbase` topic rewritten** to cover the new file/conn
  workflow and clarify that `cfg.dbase.sources = { ... }` at setup
  bypasses the new file management entirely.

### Changed

- **`_dbase_setup` default source** flipped from an empty
  `MemorySource` to a `FileSource` pinned at
  `files.active_path()`. The empty `MemorySource` remains as a
  defensive fallback only if `_dbase_files` somehow fails to load.

### Tests

- New `tests/smoke.lua` section 23 (35 assertions) covers
  state-dir creation, list/new round-trips, duplicate + path-
  traversal rejection, load-swap semantics, conn add/ls/rm,
  active-file removal recovery, REPL dispatch routing, and the
  three new autocomplete depths.

## [v0.2.17] — 2026-05-17 — `dbase`: soft-dep tone fix for missing nvim-dbee

### Fixed

- **`dbase` section is now a clean soft-dep on nvim-dbee.** When
  `require("dbee")` fails because nvim-dbee isn't installed, the
  setup probe logs at `INFO` instead of `ERROR`. The user-visible
  signal stays the placeholder buffer rendered into the panel
  ("dbee unavailable: nvim-dbee is not on the runtimepath — install
  nvim-dbee and rerun :AutoFinderFocus dbase"); the ERROR-level
  toast that used to fire on top of it was double-noise. Setup
  failures with nvim-dbee actually present (i.e. `dbee.setup()`
  raising) stay at `ERROR` — that's a real broken state.
- **Test coverage.** `tests/dbase_spike.lua` path B (dbee
  unloadable) now asserts no `ERROR` toast is emitted for the
  missing-dep case, locking the soft-dep contract in place.

Mirrors the soft-dep pattern already used by the auto-core.events
probe in `_dbase_events.lua`.

## [v0.2.16] — 2026-05-17 — `dbase` section (ADR 0020)

A new bundled panel section that wraps [nvim-dbee] as a database
UI inside auto-finder. Connection drawer renders in the panel
column (the section's home), while dbee's editor / result /
call_log tiles live in companion windows in the **main editor
area**. Powered by a custom `Layout` object passed to
`dbee.setup({ window_layout = ... })` so dbee never snapshots or
restores the global layout under us.

[nvim-dbee]: https://github.com/kndndrj/nvim-dbee

### Added — bundled `dbase` section

- **`slot add dbase`** registers the section. Auto-discoverable
  via the existing directory scan (`lua/auto-finder/sections/*.lua`),
  so tab-completion for `slot add` / `slot modify` picks it up
  without further wiring.
- **`cfg.dbase`** configuration namespace forwarded to
  `auto-finder.sections.dbase.configure(opts)`:
  - `sources` — list of dbee `Source` instances (`MemorySource`,
    `EnvSource`, `FileSource` — see `nvim-dbee/lua/dbee/sources.lua`).
    Falls back to a single empty `MemorySource` when nil/empty so
    the drawer renders against a benign baseline.
  - `extra` — passthrough table merged into `dbee.setup`'s config
    under keys not already set by `sources`; escape hatch for
    per-tile dbee options (`drawer = {...}`, `editor = {...}`, …).
- **`help dbase`** topic in the config admin panel covers the
  config shape, lifecycle, and emitted events.
- **`help slot`** topic is now dynamic — the bundled-types list
  resolves via `_available_section_types()` at call time instead
  of hardcoding `"config, files, repos, buffers."`.

### Added — event surface

The dbase section bridges dbee's internal handler events onto
auto-core's event bus (requires `auto-core ^0.1.14`). All six
topics are owned by `auto-finder.nvim`:

- `dbase.connection:changed`
- `dbase.call:started`
- `dbase.call:state_changed`
- `dbase.call:completed`
- `dbase.call:failed`
- `dbase.result:shown`

Subscribe with `:AutoCoreLogEvent notify <topic>`. Setup and call
failures additionally route through `log.error`, which always
toasts — no subscription required.

### Notes

- **Wrap, don't fork.** dbee stays an external dep; auto-finder
  owns only the section + companion-window plumbing. See ADR 0020
  for the wrap-vs-fork analysis.
- **Panel ownership.** `find_editor_window()` treats any window
  marked with `w:auto_core_panel_name` (auto-finder, auto-agents,
  any future panel) as off-limits for companion-tile placement.
  Companion tiles always land in the main editor area.
- **Companion lifecycle.** `dbase.on_close()` tears down the
  editor / result / call_log windows on panel close, auto-finder
  reload, or section removal — plain focus changes between
  sections leave companions mounted.

### Compatibility

Additive — no removals, no break-shape. Patch within the v0.2.x
line per the global plugin version policy. Consumers pinned to
`version = "^0.2.0"` pick this up automatically.

Requires `auto-core ^0.1.14` for the new `dbase.*` event-topic
registrations. Older auto-core versions silently drop publishes
to unknown topics; the section still functions but subscribers
will not receive events.

## [v0.2.15] — 2026-05-16 — ADR 0021 Phase 2 wrapper + scan toasts + `<space>` released

Three user-visible changes plus the ADR 0021 Phase 2 internal
wiring all rolled into one bundle.

### Added — `auto-finder.scan.started` / `scan.completed.slow` events

Large-tree scans (`<leader>e` on a 50k-file project, the `R`
keymap inside the filesystem section, worktree-switched re-anchor
of the panel) used to block the editor with no visible signal that
auto-finder was working. v0.2.15 fires a toast at scan start so
the user knows the freeze is auto-finder and not a hung editor.

Two registered events, toggled via `:AutoCoreLogEvent notify
<event>`:

- `auto-finder.scan.started` — fires every time `fs_scan.get_items`
  enters the root-level path. Ring entry always lands; toast only
  if the user has opted in.
- `auto-finder.scan.completed.slow` — fires only when the scan
  elapsed `≥ 1000ms`. Ring entry always lands; toast only if the
  user has opted in.

Default subscription state: both silent. Opt in via
`:AutoCoreLogEvent notify auto-finder.scan.completed.slow` for
the recommended "tell me when scans are taking forever" UX.

A timing record (`log.info("scan", "mapping completed",
{ fields = { path, elapsed_ms } })`) writes the ring on every scan
for triage. With `auto-core v0.1.12+` (echo OFF by default) this
is invisible in `:messages`; older auto-core users see it as an
nvim_echo line and can re-silence via `log.configure({ echo =
false })` if the noise bothers them.

### Changed — `<space>` no longer toggles folders in the panel

`<space>` was a buffer-local mapping inside the panel sections
(files / repos / buffers) that toggled folder open/close. `<cr>`
already covers that action. The buffer-local bind shadowed nvim's
global `<leader>` (default `<space>`), so leader chords typed
inside the panel would silently do nothing or activate the wrong
action. Removed via the neo-tree fork's `"none"` sentinel; the
key now falls through to the user's global leader handler.

### Changed — wrapper convention: `auto-finder.log`

Per ADR 0021 §6, every auto-family plugin owns one
`lua/<plugin>/log.lua` that delegates to `auto-core.log`. Feature
code in auto-finder now calls `require("auto-finder.log")`
exclusively; `auto-core.log` is reachable only through the
wrapper. The old `logger.lua` shim is gone (replaced by the
broader `log.lua`); call sites that imported it were swept (one
direct `vim.notify` site in `sections/_neotree.lua` plus the
fs_scan instrumentation).

The wrapper exposes:

```lua
local log = require("auto-finder.log")

log.error / .warn / .info / .debug / .trace   -- with auto-finder.* component prefix
log.notify(msg, opts?)                         -- force-toast single emission
log.notifyIf(event, msg, opts?)                -- toast iff event subscribed
log.register_events(events)                    -- declare at setup
log.is_level_enabled(name)                     -- predicate
log.setup(cfg)                                 -- forward cfg.log_level
```

Soft-dep tolerant: when running against an auto-core older than
v0.1.11 (no `notify` / `notifyIf` / `events.register`), the
wrapper degrades to ring-only emissions instead of crashing.

### Changed — `tests/smoke.lua` rtp prelude fixed

Latent bug surfaced by the Phase 2 work: the prelude used
`vim.fn.fnamemodify(plugin_root, ":h")` (single `:h`) which
produced a path that didn't exist
(`auto-finder.nvim/auto-core.nvim/...`), so the `isdirectory`
gate silently failed and the suite had been running against
whichever `~/.local/share/nvim/lazy/auto-core.nvim` happened to
be installed for its entire history. Now uses `:h:h` to land on
the family workspace dir and lists candidate auto-core worktrees
last so they win the prepend. Issued + codified as
`lua-nvim-plugin-development.md` rule 2 in the auto-agents kb.

### Tests

`tests/smoke.lua` 188 passed, 0 failed (was 184 — four new
assertions covering the wrapper surface).

### Migration

Soft. Consumers pin via `version = "^0.2.0"` and auto-update.
`require("auto-finder.logger")` callers — none in the family —
should switch to `require("auto-finder.log")`. The wrapper
soft-deps against pre-Phase-1 auto-core so consumers can stage
the upgrade in any order.

## [v0.2.14] — 2026-05-14 — buffers panel: group out-of-cwd buffers as sibling root folders

### Added

- **Out-of-cwd buffers are no longer dropped from the buffers panel.**
  Before v0.2.14 the bundled buffers source filtered listed buffers
  through `is_subpath(state.path, path)` and silently discarded
  anything that didn't live under the panel's cwd — so opening a
  KB page from `~/.config/...`, a scratch file under
  `~/Documents/...`, or `/tmp/foo.md` would not appear in the
  panel even though the buffer was loaded and listed.
- v0.2.14 buckets out-of-cwd buffers by their "natural external
  root" and emits each bucket as an additional top-level group —
  same shape as the existing `Terminals` group. The cwd root keeps
  its original behavior; in-cwd buffers still nest there.
- **Bucketing strategy:** paths under `$HOME` group by the first
  segment after home (e.g. `~/.config`, `~/Documents`); paths
  outside `$HOME` group by the first absolute segment (e.g. `/tmp`,
  `/etc`, `/opt`). Inside each bucket, full subdirectory nesting is
  preserved via `file_items.create_item`, and children are sorted
  with `advanced_sort` to match the cwd root's ordering.

### Changed

- `lua/auto-finder/neotree/sources/buffers/lib/items.lua` — buffer
  loop now diverts out-of-cwd file buffers into a per-bucket
  `externals` table; after `Terminals`, sorted bucket roots are
  appended to `root_folders` in lexicographic order so the panel
  layout is stable across redraws.

### Tests

- `tests/smoke.lua` `[21d]` — new section exercising the round
  trip: load `/tmp/_v2_14_external_probe.md`, assert the rendered
  tree contains both the `/tmp` bucket header and the probe file,
  then load an in-cwd probe under `tests/` and assert the cwd root
  still receives in-cwd buffers (regression guard).

## [v0.2.13] — 2026-05-14 — buffers panel: dirty-bit consumer for the v0.2.11 gate-skip

### Fixed

- **Buffers panel showed a stale tree after gate-skipped refreshes.**
  v0.2.11 added a gate in `M._install_buffers_refresh_autocmd` that
  skips the buffers refresh when the buffers source isn't the active
  section in the panel — to prevent the refresh from clobbering
  whichever section the user actually has up. The gate was correct,
  but the commit's assumption ("the next time the user focuses
  buffers, the section re-mounts fresh via `section.get_buffer` and
  a complete `navigate()` runs from scratch") was wrong:
  `section.get_buffer` caches the section's bufnr across focuses,
  so refocusing buffers reuses the existing buffer + tree state and
  shows the stale snapshot from before the skipped refresh.

  Concrete failure mode: user has files / repos / config section
  active. A `:badd` (or `:edit`, or any BufAdd-triggering command)
  adds a buffer to the buffer list. The autocmd-fire gate skips the
  refresh (correct — no panel clobber). User then switches to the
  buffers section. The tree shows the buffers from BEFORE the
  `:badd`, not the new buffer.

  **Fix:** when the gate skips, the autocmd-fire path now sets
  `M._buffers_dirty = true`. The buffers section's `on_focus` hook
  (in `sections/buffers.lua`) checks the flag and, if dirty, runs
  `M._refresh_buffers_now(panel_winid)` inline before clearing the
  flag. The refresh body itself was extracted from the autocmd-fire
  function so both the inline (active-section, autocmd-fire) and the
  deferred (gate-skipped, on_focus) paths share the same winfixbuf-
  wrap + stuck-loading-reset logic.

  The flag is cleared on every successful refresh (both inline and
  deferred), so it can't accumulate or get stuck.

### Smoke

New section [21c] in `tests/smoke.lua` (6 assertions) — the
contract this regression should have been caught by. Drives the
round-trip explicitly:

1. Open panel on config section (buffers inactive).
2. `:badd` a probe file → assert `_buffers_dirty == true` (gate
   set the flag).
3. Focus buffers → assert `_buffers_dirty == false` (consumer
   cleared it).
4. Read the rendered tree → assert the probe file's basename
   appears in the buffer lines (the regression: stale tree would
   not contain it).
5. `:badd` another probe while buffers IS active → assert the flag
   stays cleared (the inline refresh path handles it; the flag
   doesn't accumulate).

Section [21] (the original v0.2.11 gate test) covered the gate's
NEGATIVE contract — that the panel doesn't get clobbered while
inactive. It did NOT cover the POSITIVE contract — that the
buffers source eventually does become current on next focus. The
new [21c] closes the loop.

### Lesson

**Any gate on a pub/sub-triggered refresh must be paired with a
dirty-bit or invalidation so the next user-initiated read sees the
correct state; the smoke test for that gate must assert both halves
(the over-eager case doesn't fire AND the gated state still becomes
correct on next read).** See the [[auto-core-events-subscription-lifecycle]]
convention in the auto-agents kb for the broader rule against
silently-fragile pub/sub patterns.

## [v0.2.12] — 2026-05-12 — prevent follow-mode hijacking

### Fixed

- **Gated follow-mode reveals to active panel.** Both files-follow
  and repos-follow now verify that their respective section is the
  one currently active in the panel before triggering a reveal. This
  prevents the explorer from switching sections automatically when
  navigating files. (ADR 0011)

- **Repos-follow is now panel-bound.** When the repos section is
  active, the reveal command is driven directly against the panel's
  state, preventing it from hijacking the editor window where the
  BufEnter event originated. The reveal target is the repos source's
  synthetic `auto-finder-repos://<repo-path>` node id, so the
  containing repo is focused after the panel redraw.

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
