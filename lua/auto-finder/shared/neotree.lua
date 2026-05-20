---Shared helper for views that mount a neo-tree source into the
---auto-finder panel window via `position = "current"`. Used by the
---`files` view (filesystem source) and the `repos` view
---(auto-finder-repos source). Centralizes:
---
---  - the get-current-window dance neo-tree's "current" path requires
---  - the cmd.execute call + error reporting
---  - the post-mount filetype-wait (neo-tree's command path schedules
---    part of the mount; we'd cache a scratch bufnr otherwise)
---  - the auto_expand_width re-sync against the current pin state
---  - the section-bufnr cache + on_focus revive logic
---
---Each view is a thin wrapper around `M.build_section(opts)` —
---specifying its name, neo-tree source, and any extra render options.
---
---ADR 0026 Phase 2: moved from `auto-finder.sections._neotree` to
---`auto-finder.shared.neotree`. Phase 7 slims the implementation;
---this phase only relocates the file. The original path remains
---valid via the `sections/_neotree.lua` facade.
---@module 'auto-finder.shared.neotree'

local M = {}

-- ── live refresh via auto-core.fs.watch / auto-core.git.watch ──
--
-- Soft-dep on auto-core: when present, sections that opt in via
-- `opts.live_refresh = true` subscribe to refresh-driving topics
-- and trigger schedule_refresh on each fire. Auto-core absent →
-- silently skipped (auto-finder still works, just without
-- auto-refresh — the prior behavior).
--
-- ADR 0026 Phase 4: this module USED to own the fs.watch and
-- git.watch handles (per `_ensure_fs_watch` / `_stop_fs_watch`).
-- Those moved into `auto-finder.core.watchers` so a single core
-- module owns project-domain watch handles regardless of which
-- view is rendered. This module now only sets up subscriptions
-- and arms them on each focus via `section._arm_live_refresh_subs`.
--
-- The subscriptions that drive schedule_refresh are:
--   - `auto-finder.core.files:changed` (translated + debounced
--     by core's translator per ADR §2.5)
--   - `worktree:switched` (re-anchor cached state to the new cwd)
--   - `core.git.state:changed` (still a direct upstream sub through
--     v0.2.x; Phase 5 swaps for `auto-finder.core.git:changed`)
--
-- Per-section state:
--   section._fs_subscribed       events subscription wired? (one-shot
--                                 per build_section's lifetime; survives
--                                 panel close/reopen because the view
--                                 module is cached)
local LIVE_REFRESH_DEBOUNCE_MS = 150  -- collapse refresh storms

local function require_core()
  local ok, core = pcall(require, "auto-core")
  if not ok then return nil end
  if type(core) ~= "table" or type(core.fs) ~= "table"
      or type(core.fs.watch) ~= "table"
      or type(core.events) ~= "table" then
    return nil
  end
  return core
end

---Wire refresh hooks onto `section`. Mutates `section`: adds the
---`_arm_live_refresh_subs` method and a one-shot `_fs_subscribed`
---flag. No-op if auto-core isn't loadable.
---
---ADR 0026 Phase 4: fs.watch + git.watch ownership lives in
---`auto-finder.core.watchers` (started by core.ensure_started).
---This function no longer opens / closes handles — it only sets
---up the subscriptions that drive schedule_refresh.
---@param section table
---@param source string
local function setup_live_refresh(section, source)
  local core = require_core()
  if not core then return end

  local refresh_pending = false
  local function schedule_refresh()
    if refresh_pending then return end
    refresh_pending = true
    -- Mark the event-arrival timestamp so the metrics:paint emit
    -- below can report a meaningful dur_ms ("event arrival to view
    -- paint complete"). ADR 0026 §3.12 + Phase 3 instrumentation:
    -- this is the same emit point pre- and post-refactor so A5's
    -- "≤ 50% baseline" assertion compares like-for-like.
    local enqueued_ms = (vim.uv or vim.loop).hrtime() / 1e6
    vim.defer_fn(function()
      refresh_pending = false
      if not section._bufnr or not vim.api.nvim_buf_is_valid(section._bufnr) then
        return
      end
      -- Drive neo-tree's source manager directly. cmd.execute has no
      -- "refresh" action — it only handles "show", "focus", "close",
      -- and falls through to a show/focus pass for anything else,
      -- which doesn't trigger an fs rescan. The R keymap is bound to
      -- this same `manager.refresh` (per
      -- `sources/filesystem/init.lua` `handler = wrap(manager.refresh)`).
      pcall(function()
        require("auto-finder.neotree.sources.manager").refresh(source)
      end)
      -- ADR 0026 Phase 3: emit the metrics:paint event so smokes
      -- can measure refresh latency. Currently the v0.2.x render
      -- path; Phase 7 will fire the same topic from the new view
      -- mount contract so pre/post-refactor measurements compare
      -- against the same baseline emit shape. `generation` stays
      -- at 0 in Phase 3 (the per-view generation counter is added
      -- in Phase 7 with the loading-placeholder contract); views
      -- that bump generations will override.
      local dur_ms = (vim.uv or vim.loop).hrtime() / 1e6 - enqueued_ms
      pcall(function()
        require("auto-finder.core.events").publish(
          "auto-finder.core.metrics:paint", {
            view = section.name or "unknown",
            dur_ms = dur_ms,
            generation = 0,
          })
      end)
    end, LIVE_REFRESH_DEBOUNCE_MS)
  end

  -- Re-anchor the section's neo-tree state to the current cwd
  -- WITHOUT re-mounting. v0.2.2 used `cmd.execute({ position =
  -- "current" })` which mounts neo-tree in the currently-focused
  -- window — if the user was in an editor when `worktree:switched`
  -- fired, that surfaced as a duplicate "neo-tree" panel inside the
  -- editor. v0.2.3 mutates `state.path` on every registered state
  -- for our source and calls `manager.refresh`, keeping the existing
  -- panel window as the sole render target.
  local function reanchor_to_cwd()
    if not section._bufnr or not vim.api.nvim_buf_is_valid(section._bufnr) then
      return
    end
    local ok_mgr, mgr = pcall(require, "auto-finder.neotree.sources.manager")
    if not ok_mgr then return end
    local cwd = vim.fn.getcwd()
    -- _get_all_states is forked-specific (manager.lua:138 in the
    -- bundled fork). Iterate every state belonging to our source —
    -- `manager.get_state(name)` alone may return a stub state that
    -- was never navigate()'d.
    if type(mgr._get_all_states) == "function" then
      for _, state in ipairs(mgr._get_all_states()) do
        -- Scope to states bound to a window — `state_by_tab` stubs
        -- carry name+source but were never navigate()'d (path=nil)
        -- and shouldn't be retargeted: the manager.refresh below
        -- would otherwise turn the stub into a duplicate render.
        if state.name == source and state.winid then
          state.path = cwd
        end
      end
    end
    pcall(mgr.refresh, source)
  end

  -- ADR 0026 Phase 4: fs.watch + git.watch handles moved out of
  -- this module into `auto-finder.core.watchers`. The section no
  -- longer owns those handles; it just subscribes to the
  -- translated `auto-finder.core.*` topics core publishes and
  -- triggers schedule_refresh on each.
  --
  -- core.file:* used to be a direct subscription here; now it
  -- arrives via `auto-finder.core.files:changed` (debounced +
  -- burst-detected by core's translator per ADR §2.5). The
  -- payload carries `{ cwd, kind, paths, parents? }` — we filter
  -- by `payload.cwd == vim.fn.getcwd()` so a section rendering
  -- worktree A doesn't refresh when worktree B publishes events.
  --
  -- core.git.state:changed STAYS as a direct upstream subscription
  -- through v0.2.x — Phase 5 swaps it for
  -- `auto-finder.core.git:changed` once the git cache lands and
  -- the snapshot delegate path proves stable.
  --
  -- worktree:switched STAYS as a direct upstream subscription for
  -- the section-local re-anchor (drops the cached tree + re-mounts
  -- against the new cwd). Phase 7's view mount contract will
  -- consolidate this with the auto-finder.core.repos:changed
  -- topic core already publishes.
  -- Exposed as `section._arm_live_refresh_subs` so the lifecycle
  -- wrap at the bottom of `build_section` can re-arm on every
  -- focus per [[auto-core-events-subscription-lifecycle]]. The
  -- internal `_fs_subscribed` flag is still one-shot (the
  -- subscriptions are session-long and the auto-finder.core.*
  -- bus reset survives via core.ensure_started's re-arm path).
  function section._arm_live_refresh_subs()
    if section._fs_subscribed then return end
    section._fs_subscribed = true

    -- auto-finder.core.files:changed — translated + debounced
    -- + burst-detected by core's translator. One emit per
    -- 100ms debounce window.
    core.events.subscribe("auto-finder.core.files:changed", function(payload)
      if type(payload) ~= "table" then return end
      -- core publishes with the cwd at the time the event was
      -- enqueued; only refresh when that matches our section's
      -- current anchor. Worktree switches re-anchor via the
      -- `worktree:switched` subscription below.
      if payload.cwd and payload.cwd ~= vim.fn.getcwd() then
        return
      end
      schedule_refresh()
    end)

    -- Worktree switch → the panel is now showing the wrong tree.
    -- Re-anchor to the new cwd. Core has already moved its
    -- fs.watch + git.watch to the new cwd (its own
    -- worktree:switched subscriber handles that side).
    core.events.subscribe("worktree:switched", function()
      vim.schedule(function()
        reanchor_to_cwd()
      end)
    end)

    -- ADR 0025 — `.git/`-plumbing mutations published by
    -- `auto-core.git.watch`. Still a direct upstream subscription
    -- in Phase 4; Phase 5 migrates to `auto-finder.core.git:changed`
    -- once the git cache lands. Filter by repo_root prefix on cwd
    -- so sibling-worktree events don't over-trigger.
    core.events.subscribe("core.git.state:changed", function(payload, _topic)
      if type(payload) ~= "table" or type(payload.repo_root) ~= "string" then
        return
      end
      local cwd = vim.fn.getcwd()
      if payload.repo_root == cwd
          or cwd:sub(1, #payload.repo_root + 1) == payload.repo_root .. "/" then
        schedule_refresh()
      end
    end)
  end
end

-- ── `?` help overlay ──────────────────────────────────────────
--
-- v0.2.1: replace neo-tree's default `show_help` popup with our
-- own auto-core.ui.float.help_overlay invocation. The overlay
-- renders a centered float listing the section's effective
-- keymaps; closes on q / <esc> / <cr>.
--
-- Implementation strategy:
--   1. On every section focus, install a buffer-local `?` nmap
--      that calls show_help. Buffer-local so the override is
--      scoped to the section's buffer.
--   2. The overlay reads the section's effective mappings from
--      the buffer's actual nmap set (via nvim_buf_get_keymap), so
--      it reflects whatever neo-tree wired + any consumer overrides.
--   3. If auto-core isn't installed, fall back to a plain float we
--      manage ourselves — no hard dep on auto-core for `?`.

---Collect a `{ key, desc }` list of effective keymaps for `bufnr`.
---Reads vim's buffer-local nmaps so the overlay reflects whatever
---neo-tree (and any consumer override) actually wired.
---@param bufnr integer
---@return { key: string, desc: string }[]
local function collect_keymaps(bufnr)
  local out = {}
  local maps = vim.api.nvim_buf_get_keymap(bufnr, "n")
  for _, m in ipairs(maps) do
    if type(m.lhs) == "string" and m.lhs ~= "" then
      local desc = m.desc
      if (desc == nil or desc == "") and type(m.rhs) == "string" then
        desc = m.rhs
      end
      out[#out + 1] = { key = m.lhs, desc = desc or "" }
    end
  end
  table.sort(out, function(a, b) return a.key < b.key end)
  return out
end

---Render the help float for the section's bufnr.
---@param section_name string
---@param bufnr integer
local function show_help(section_name, bufnr)
  local entries = collect_keymaps(bufnr)
  if #entries == 0 then
    require("auto-finder.log").notify(
      "no keymaps found for '" .. section_name .. "'",
      { level = "info", component = "shared.neotree.help" })
    return
  end

  -- Format two columns: lhs (left-aligned, padded) | desc.
  local widest_lhs = 0
  for _, e in ipairs(entries) do
    if #e.key > widest_lhs then widest_lhs = #e.key end
  end
  local lines = { ("auto-finder · %s · keymaps"):format(section_name), "" }
  for _, e in ipairs(entries) do
    lines[#lines + 1] = string.format(" %-" .. widest_lhs .. "s   %s",
      e.key, e.desc)
  end

  -- Prefer auto-core.ui.float.help_overlay when present (it ships
  -- close-on-q/<esc> + a dimmed backdrop); otherwise roll our own.
  local ok, core = pcall(require, "auto-core")
  if ok and type(core) == "table" and type(core.ui) == "table"
      and type(core.ui.float) == "table"
      and type(core.ui.float.help_overlay) == "function" then
    pcall(core.ui.float.help_overlay, lines, {
      title = (" %s "):format(section_name),
    })
    return
  end

  -- Fallback float — q / <esc> / <cr> close.
  local hbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(hbuf, 0, -1, false, lines)
  vim.bo[hbuf].modifiable = false
  vim.bo[hbuf].filetype = "auto-finder-help"
  local width = math.min(vim.o.columns - 4, 80)
  local height = math.min(vim.o.lines - 4, #lines + 2)
  local hwin = vim.api.nvim_open_win(hbuf, true, {
    relative = "editor",
    width    = width,
    height   = height,
    row      = math.floor((vim.o.lines - height) / 2),
    col      = math.floor((vim.o.columns - width) / 2),
    style    = "minimal",
    border   = "rounded",
    title    = (" %s "):format(section_name),
  })
  for _, lhs in ipairs({ "q", "<esc>", "<cr>" }) do
    vim.keymap.set("n", lhs, function()
      if vim.api.nvim_win_is_valid(hwin) then
        vim.api.nvim_win_close(hwin, true)
      end
    end, { buffer = hbuf, nowait = true, silent = true })
  end
end

---Install the buffer-local `?` keymap that opens the help overlay.
---Idempotent (re-installation replaces the prior mapping).
---@param section_name string
---@param bufnr integer
local function install_help_keymap(section_name, bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.keymap.set("n", "?", function()
    show_help(section_name, bufnr)
  end, {
    buffer = bufnr,
    nowait = true,
    silent = true,
    desc = "auto-finder: show section keymaps",
  })
end

---Defensive monkey-patch: neo-tree's `renderer.get_expanded_nodes`
---indexes `tree:get_nodes(...)` without nil-checking, but the
---win_enter redirect can call it with `old_state.tree = nil` when a
---neo-tree window closed before its tree finished rendering. Patched
---once on first section load so any caller of `get_expanded_nodes(nil)`
---gets `{}` back instead of crashing the whole UI.
local function patch_neotree_renderer_nil_tree()
  local ok, renderer = pcall(require, "auto-finder.neotree.ui.renderer")
  if not ok or type(renderer) ~= "table" then return end
  if renderer._auto_finder_patched then return end
  local orig = renderer.get_expanded_nodes
  if type(orig) ~= "function" then return end
  renderer.get_expanded_nodes = function(tree, ...)
    if tree == nil then return {} end
    return orig(tree, ...)
  end
  renderer._auto_finder_patched = true
end

---Drive neo-tree to render `source` into `panel_winid` via the
---`position = "current"` codepath. Returns the bufnr neo-tree mounted
---there, or nil on failure.
---@param panel_winid integer
---@param source string  -- "filesystem", "auto-finder-repos", etc.
---@param section_label string  -- shown in error messages
---@return integer|nil
local function mount(panel_winid, source, section_label)
  if not vim.api.nvim_win_is_valid(panel_winid) then return nil end
  -- Neo-tree's `position = "current"` operates on the current window;
  -- focus the panel first so the buffer lands here.
  pcall(vim.api.nvim_set_current_win, panel_winid)

  local ok, cmd = pcall(require, "auto-finder.neotree.command")
  if not ok then
    require("auto-finder.log").error("shared.neotree",
      "neo-tree is not installed; the '" .. section_label ..
      "' section requires nvim-neo-tree/neo-tree.nvim")
    return nil
  end

  -- `action = "show"` renders without grabbing focus from a different
  -- window — but since we already moved focus to the panel above, the
  -- buffer lands here regardless. `reveal = false` keeps the tree at
  -- its last cwd / root rather than chasing the user's previously-
  -- focused buffer (which would feel jumpy on every section switch).
  local exec_ok, err = pcall(cmd.execute, {
    source = source,
    action = "show",
    position = "current",
    reveal = false,
  })
  if not exec_ok then
    require("auto-finder.log").error("shared.neotree",
      "neo-tree.execute failed for source '" .. source .. "': " .. tostring(err))
    return nil
  end
  -- Wait briefly for neo-tree's async mount to settle. The buffer-
  -- swap into our panel is synchronous, but on the very first mount
  -- the buffer may not yet have filetype="auto-finder" at this exact
  -- tick — caching the scratch bufnr in that case would let the
  -- bounce-back guard restore the wrong thing later.
  vim.wait(200, function()
    if not vim.api.nvim_win_is_valid(panel_winid) then return false end
    local b = vim.api.nvim_win_get_buf(panel_winid)
    return vim.bo[b].filetype == "auto-finder"
  end, 5)

  -- Phase 3c note: previously called
  -- `host._sync_neotree_auto_expand(af.state)` here so a freshly-
  -- created neo-tree state would inherit the right
  -- auto_expand_width based on pin status. The forked renderer now
  -- reads `auto-finder.state.user_width` each render, so a pin
  -- already-set on entry is honored from the very first render
  -- without needing to mutate the new state's flag from outside.
  return vim.api.nvim_win_get_buf(panel_winid)
end

---Build a section module that mounts the given neo-tree `source` into
---the panel. Returns a section table with `get_buffer`, `on_focus`,
---and `on_close` already wired. Callers add `name`, `description`,
---and any extra fields they want to expose.
---
---Example:
---```lua
---local _neotree = require("auto-finder.shared.neotree")
---return _neotree.build_section({
---  name = "files",
---  description = "filesystem (neo-tree wrapper)",
---  source = "filesystem",
---})
---```
---@param opts { name: string, description: string?, source: string, live_refresh: boolean? }
---@return AutoFinderSection
function M.build_section(opts)
  patch_neotree_renderer_nil_tree()

  local label = opts.name
  local source = opts.source
  local section = {
    name = opts.name,
    description = opts.description,
    _bufnr = nil,
  }

  local function buf_valid()
    return section._bufnr and vim.api.nvim_buf_is_valid(section._bufnr)
  end

  ---@param panel_winid integer
  ---@return integer|nil
  function section.get_buffer(panel_winid)
    if buf_valid() then return section._bufnr end
    local b = mount(panel_winid, source, label)
    if b then
      section._bufnr = b
      install_help_keymap(label, b)
    end
    return b
  end

  ---If neo-tree's buffer was wiped externally (`:bd`, plugin
  ---reload), remount on the next focus instead of restoring a stale
  ---bufnr.
  function section.on_focus(panel_winid, bufnr)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      section._bufnr = nil
      local b = mount(panel_winid, source, label)
      if b then
        section._bufnr = b
        vim.api.nvim_win_set_buf(panel_winid, b)
        install_help_keymap(label, b)
      end
    else
      -- Buffer survived; re-assert the `?` keymap defensively in
      -- case neo-tree's setup wiped buffer-local maps on re-render.
      install_help_keymap(label, bufnr)
    end
  end

  ---Called by host.close() when the panel window is going away.
  ---Delete the cached neo-tree buffer so a subsequent reopen
  ---re-mounts fresh — without this, neo-tree's win_enter redirect
  ---would fire with a stale `old_state.tree = nil` and crash on
  ---`attempt to index local 'tree' (a nil value)`.
  function section.on_close()
    if section._bufnr and vim.api.nvim_buf_is_valid(section._bufnr) then
      pcall(vim.api.nvim_buf_delete, section._bufnr, { force = true })
    end
    section._bufnr = nil
  end

  -- Wrap the lifecycle hooks for live-refresh-enabled sections.
  -- ADR 0026 Phase 4: fs.watch + git.watch ownership moved into
  -- `auto-finder.core.watchers` (started by core.ensure_started
  -- and torn down by core.stop). All this wrapper does now is
  -- arm the `auto-finder.core.files:changed` /
  -- `core.git.state:changed` / `worktree:switched` subscriptions
  -- via setup_live_refresh.ensure_subscribed on each focus, so
  -- the schedule_refresh chain stays live across section
  -- switches. The wrapper is still on_focus-gated rather than
  -- module-load to honour [[auto-core-events-subscription-lifecycle]].
  if opts.live_refresh then
    setup_live_refresh(section, source)
    local orig_on_focus = section.on_focus
    section.on_focus = function(panel_winid, bufnr)
      if orig_on_focus then orig_on_focus(panel_winid, bufnr) end
      if section._arm_live_refresh_subs then
        section._arm_live_refresh_subs()
      end
    end
  end

  return section
end

return M
