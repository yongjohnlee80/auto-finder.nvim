---Section — dbase (nvim-dbee drawer).
---
---Phase 0a proved that `dbee.api.ui.drawer_show(panel_winid)` survives
---auto-finder's `winfixwidth` + `winfixbuf` panel contract when the
---mount is wrapped in `host.with_unfixed_buf(...)`. This module is the
---surviving section; ownership of one-shot `dbee.setup` lives in
---[[auto-finder.views.dbase.setup]].
---
---Boundary (from the synthesized preferred method, §8 of
---`kb/agents/white-vision/tasks/2026-05-16-dbase-section-feasibility-analysis.md`):
---  - dbee owns DB core + tile internals
---  - auto-core owns the window, lifecycle, `winfixbuf`/`winfixwidth`
---  - the section wraps every tile-render in
---    `host.with_unfixed_buf(...)` — the same dance the neo-tree fork
---    embedded into its renderer at v0.2.11.
---ADR 0026 Phase 2: moved from `auto-finder.sections.dbase` (+
---underscore-prefixed sibling files) to `auto-finder.views.dbase.*`.
---The original section path remains valid via the
---`sections/dbase.lua` facade.
---@module 'auto-finder.views.dbase'

local host = require("auto-finder.panel.host")
local logger = require("auto-finder.log")
local setup_mod = require("auto-finder.views.dbase.setup")
local events_mod = require("auto-finder.views.dbase.events")
local layout_mod = require("auto-finder.views.dbase.layout")

local M = {
  name = "dbase",
  description = "nvim-dbee drawer",
  _bufnr = nil,
  -- ADR 0026 Phase 7 placeholder mount state.
  _generation  = 0,
  _owned_bufs  = {},
}

---ADR 0026 Phase 7: five-guard `_still_current` predicate. Same
---contract as shared/neotree.lua's: returns false if the panel
---state has moved on since the deferred dbee mount was scheduled.
---Local to dbase because the view doesn't go through
---`build_section`'s generic wrapper.
local function _still_current(gen, panel_winid, placeholder_bufnr)
  if gen ~= M._generation then return false end
  if not vim.api.nvim_win_is_valid(panel_winid) then return false end
  local window_mod = require("auto-finder.shared.window")
  if not window_mod.is_auto_finder_panel(panel_winid) then return false end
  local views_mod = require("auto-finder.views")
  if type(views_mod.active) == "function" then
    local active = views_mod.active()
    if active and active ~= M.name then return false end
  end
  local current_buf = vim.api.nvim_win_get_buf(panel_winid)
  local loading = require("auto-finder.shared.loading")
  if loading.matches(current_buf, M.name, gen) then return true end
  if M._owned_bufs[current_buf] == gen then return true end
  return false
end

---Render a small placeholder buffer in the panel when dbee is not
---available. Keeps the section selectable so the user can see *why*
---it didn't mount instead of getting a silent no-op.
---@param panel_winid integer
---@return integer bufnr
local function placeholder_buffer(panel_winid, reason)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.api.nvim_buf_set_name(bufnr, "auto-finder-dbase://placeholder")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "  dbase section (Phase 0a spike)",
    "",
    "  dbee unavailable: " .. (reason or "unknown reason"),
    "",
    "  Install nvim-dbee and rerun :AutoFinderFocus dbase.",
  })
  vim.bo[bufnr].modifiable = false
  host.with_unfixed_buf(panel_winid, function()
    if vim.api.nvim_win_is_valid(panel_winid) then
      vim.api.nvim_win_set_buf(panel_winid, bufnr)
    end
  end)
  return bufnr
end

---Mount dbee's drawer into the auto-finder panel window.
---
---The load-bearing call is `drawer_show(panel_winid)` — dbee's
---`DrawerUI:show(winid)` does `nvim_win_set_buf(winid, self.bufnr)` +
---`configure_window_options(...)` + `:refresh()`. The buffer swap is
---the part that collides with `winfixbuf=true` on the panel, so the
---whole call is wrapped in `host.with_unfixed_buf`.
---@param panel_winid integer
---@return integer|nil bufnr
local function mount_drawer(panel_winid)
  if not vim.api.nvim_win_is_valid(panel_winid) then return nil end

  -- Focus the panel first so any window-current dbee internals see
  -- the right target. Matches the _neotree mount pattern.
  pcall(vim.api.nvim_set_current_win, panel_winid)

  local dbee = require("dbee")
  local exec_ok, err = host.with_unfixed_buf(panel_winid, function()
    return dbee.api.ui.drawer_show(panel_winid)
  end)
  if not exec_ok then
    logger.error("dbase", "drawer_show failed: " .. tostring(err))
    return nil
  end

  -- Brief settle for any async refresh queued by drawer:refresh().
  vim.wait(150, function()
    if not vim.api.nvim_win_is_valid(panel_winid) then return false end
    local b = vim.api.nvim_win_get_buf(panel_winid)
    return vim.api.nvim_buf_is_valid(b)
  end, 5)

  local bufnr = vim.api.nvim_win_get_buf(panel_winid)

  -- Override dbee's drawer <CR> mapping. dbee's default <CR> calls
  -- action_1 directly, which for notes hits `editor:set_current_note`
  -- — and that function silently no-ops if editor.winid is not yet
  -- bound to a window (see `nvim-dbee/lua/dbee/ui/editor/init.lua:431`).
  -- Our override mounts editor + result in the main editor area
  -- BEFORE delegating to dbee, so action_1 finds a valid editor
  -- window when it goes to render a note. Buffer-local so it doesn't
  -- pollute the other panel sections.
  --
  -- Set AFTER `drawer_show` (which installs dbee's mappings via
  -- `common.configure_buffer_mappings`) so our binding wins last-
  -- write. Idempotent on subsequent get_buffer calls because
  -- `vim.keymap.set` overwrites.
  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.keymap.set, "n", "<CR>", function()
      -- Mount the companion panes (no-op if already mounted).
      layout_mod.ensure_editor()
      layout_mod.ensure_result()
      -- Now fire dbee's drawer action_1. Wrap in pcall — some nodes
      -- have no action_1 defined; dbee's dispatcher raises in that
      -- case and we shouldn't surface a stack trace to the user.
      pcall(function()
        require("dbee").api.ui.drawer_do_action("action_1")
      end)
    end, {
      buffer = bufnr,
      silent = true,
      nowait = true,
      desc = "auto-finder.dbase: mount companions then dbee drawer action_1",
    })
  end

  return bufnr
end

---ADR 0026 Phase 7: two-phase mount per ADR §2.3 + §A16.
---
---Phase A (get_buffer): if a previous mount already produced a
---valid dbee drawer buffer, reuse it (re-focus stays
---instantaneous). Otherwise bump the generation and return a
---shared.loading placeholder so the user sees
---"Loading dbase…" while dbee.setup + drawer_show run.
---
---Phase B (on_focus): deferred via vim.schedule. Five-guard
---`_still_current` check before each side-effect; if the user
---focused another view between phase A and the callback, exit
---without touching the panel. Otherwise run the dbase mount in
---this order:
---
---  1. dbee.setup (idempotent — first-run sets up sources;
---     subsequent calls short-circuit on the cached singleton)
---  2. event bridge attach (idempotent)
---  3. drawer_show — the load-bearing call that swaps the
---     buffer in the panel window; wrapped in
---     `host.with_unfixed_buf` because dbee internally calls
---     nvim_win_set_buf which would otherwise be blocked by
---     winfixbuf=true on the panel.
---  4. Companion windows (editor / result / call_log) are NOT
---     opened here — they mount on demand via the `<CR>`
---     keymap dbee's drawer carries; the A16 acceptance is
---     that we don't ACCIDENTALLY duplicate them via the
---     mount path.
---@param panel_winid integer
---@return integer|nil bufnr
function M.get_buffer(panel_winid)
  ---@diagnostic disable-next-line: unused-local
  local _ = panel_winid  -- consumed in on_focus's deferred mount
  if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
    return M._bufnr
  end
  M._generation = M._generation + 1
  return require("auto-finder.shared.loading").buffer({
    view = M.name,
    generation = M._generation,
    message = "Loading " .. M.name .. "…",
  })
end

---ADR 0026 Phase 7 (§A16): the actual dbase mount happens here,
---deferred behind vim.schedule + the five-guard `_still_current`
---check. On stale state the callback exits silently — the panel
---keeps showing the placeholder (or whatever the new active view
---swapped in) and we don't waste a dbee.setup call.
---@param panel_winid integer
---@param bufnr integer  -- placeholder bufnr created by get_buffer
function M.on_focus(panel_winid, bufnr)
  -- Re-focus on an already-mounted drawer? No setup needed.
  if bufnr and M._owned_bufs[bufnr] then return end

  local gen = M._generation
  vim.schedule(function()
    if not _still_current(gen, panel_winid, bufnr) then
      logger.debug("dbase",
        "stale on_focus callback dropped (gen=" .. tostring(gen) .. ")")
      return
    end

    -- dbee setup. Singleton; cached error path returns the
    -- placeholder permanently so the user can see WHY the view
    -- didn't mount.
    local ok, err = setup_mod.ensure_setup(M._setup_opts)
    if not ok then
      local pb = placeholder_buffer(panel_winid,
        err or "dbee.setup failed")
      M._bufnr = pb
      M._owned_bufs[pb] = gen
      return
    end

    -- Event bridge — idempotent across re-mounts.
    local ev_ok, ev_err = events_mod.attach()
    if not ev_ok then
      logger.warn("dbase",
        "event bridge attach failed: " .. tostring(ev_err))
    end

    -- Re-check still_current right before the drawer swap. The
    -- setup + bridge calls above can run for a few ms each
    -- (first-time only); the user might have focused away by now.
    if not _still_current(gen, panel_winid, bufnr) then
      logger.debug("dbase",
        "post-setup stale: aborting drawer swap (gen=" ..
        tostring(gen) .. ")")
      return
    end

    local b = mount_drawer(panel_winid)
    if b then
      M._bufnr = b
      M._owned_bufs[b] = gen
    else
      local pb = placeholder_buffer(panel_winid,
        "drawer_show returned nil")
      M._bufnr = pb
      M._owned_bufs[pb] = gen
    end
  end)
end

---Allow auto-finder.setup() to pass section-scoped opts through to
---the underlying `dbee.setup` (sources, etc.) without forcing the
---section to live-import config. Called from the section registry's
---per-section config-forwarding path; safe to call before the panel
---has opened. No-op if `opts` is nil/empty.
---@param opts AutoFinderDbaseSetupOpts?
function M.configure(opts)
  M._setup_opts = opts
end

---Drop the cached bufnr so the next focus remounts cleanly, AND
---tear down any companion editor / result / call_log windows the
---section opened. Matches the _neotree on_close contract — without
---the bufnr clear, dbee's drawer buffer could be wiped externally
---between panel-close and reopen and the section would attempt to
---restore a stale bufnr. Without the companion teardown (lector
---review should-fix §1), editor/result/call_log windows would
---orphan in the editor area after the user closes the panel,
---producing UX rough edges.
function M.on_close()
  M._bufnr = nil
  M._owned_bufs = {}
  pcall(layout_mod.close_all)
end

return M
