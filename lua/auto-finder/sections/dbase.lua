---Section — dbase (nvim-dbee drawer).
---
---Phase 0a proved that `dbee.api.ui.drawer_show(panel_winid)` survives
---auto-finder's `winfixwidth` + `winfixbuf` panel contract when the
---mount is wrapped in `host.with_unfixed_buf(...)`. This module is the
---surviving section; ownership of one-shot `dbee.setup` lives in
---[[auto-finder.sections._dbase_setup]].
---
---Boundary (from the synthesized preferred method, §8 of
---`kb/agents/white-vision/tasks/2026-05-16-dbase-section-feasibility-analysis.md`):
---  - dbee owns DB core + tile internals
---  - auto-core owns the window, lifecycle, `winfixbuf`/`winfixwidth`
---  - the section wraps every tile-render in
---    `host.with_unfixed_buf(...)` — the same dance the neo-tree fork
---    embedded into its renderer at v0.2.11.
---@module 'auto-finder.sections.dbase'

local host = require("auto-finder.panel.host")
local logger = require("auto-finder.logger")
local setup_mod = require("auto-finder.sections._dbase_setup")
local events_mod = require("auto-finder.sections._dbase_events")
local layout_mod = require("auto-finder.sections._dbase_layout")

local M = {
  name = "dbase",
  description = "nvim-dbee drawer",
  _bufnr = nil,
}

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

---@param panel_winid integer
---@return integer|nil bufnr
function M.get_buffer(panel_winid)
  if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
    return M._bufnr
  end
  local ok, err = setup_mod.ensure_setup(M._setup_opts)
  if not ok then
    M._bufnr = placeholder_buffer(panel_winid, err or "dbee.setup failed")
    return M._bufnr
  end
  -- Event bridge attaches after setup so the dbee handler exists; it's
  -- idempotent and a no-op when auto-core.events is unavailable.
  local ev_ok, ev_err = events_mod.attach()
  if not ev_ok then
    logger.warn("dbase", "event bridge attach failed: " .. tostring(ev_err))
  end
  local b = mount_drawer(panel_winid)
  if b then
    M._bufnr = b
  else
    M._bufnr = placeholder_buffer(panel_winid, "drawer_show returned nil")
  end
  return M._bufnr
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

---Drop the cached bufnr so the next focus remounts cleanly. Matches
---the _neotree on_close contract — without this, dbee's drawer
---buffer could be wiped externally between panel-close and reopen
---and the section would attempt to restore a stale bufnr.
function M.on_close()
  M._bufnr = nil
end

return M
