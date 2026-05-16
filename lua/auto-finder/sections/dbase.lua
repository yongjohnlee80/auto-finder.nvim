---Section — dbase (nvim-dbee drawer).
---
---**Phase 0a SPIKE — throwaway.** Sole question this answers:
---*"Does `dbee.api.ui.drawer_show(panel_winid)` survive auto-finder's
---`winfixwidth` + `winfixbuf` panel contract?"*
---
---Approach (per the synthesized preferred method, see
---`kb/agents/white-vision/tasks/2026-05-16-dbase-section-feasibility-analysis.md`
---§8):
---  - dbee owns DB core + tile internals
---  - auto-core owns the window, lifecycle, `winfixbuf`/`winfixwidth`
---  - the section wraps every tile-render into the panel in
---    `host.with_unfixed_buf(...)` (same dance the neo-tree fork
---    embedded into its renderer at v0.2.11)
---
---If Phase 0a goes green, this becomes the seed for the real section.
---If red, this file is deleted and we drop to Path C (sidecar).
---@module 'auto-finder.sections.dbase'

local host = require("auto-finder.panel.host")
local logger = require("auto-finder.logger")

local M = {
  name = "dbase",
  description = "nvim-dbee drawer (spike)",
  _bufnr = nil,
  _setup_done = false,
}

---One-shot dbee.setup with a minimal in-memory source. Returns true
---if dbee is loadable and setup succeeded (or had already run).
---Returns false (with a logged reason) otherwise so the section can
---degrade to a scratch placeholder rather than crashing `M.setup`.
---@return boolean ok
local function ensure_dbee_setup()
  if M._setup_done then return true end

  local ok_dbee, dbee = pcall(require, "dbee")
  if not ok_dbee then
    logger.error("dbase", "nvim-dbee is not on the runtimepath")
    return false
  end
  local ok_src, dbee_sources = pcall(require, "dbee.sources")
  if not ok_src then
    logger.error("dbase", "dbee.sources require failed: " .. tostring(dbee_sources))
    return false
  end

  -- Minimal memory source with zero connections. Sufficient to bring
  -- the drawer up; we are testing window contract, not query exec.
  local empty_source = dbee_sources.MemorySource:new({}, "dbase-spike")

  local ok_setup, err = pcall(dbee.setup, {
    sources = { empty_source },
  })
  if not ok_setup then
    logger.error("dbase", "dbee.setup failed: " .. tostring(err))
    return false
  end
  M._setup_done = true
  return true
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

  return vim.api.nvim_win_get_buf(panel_winid)
end

---@param panel_winid integer
---@return integer|nil bufnr
function M.get_buffer(panel_winid)
  if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
    return M._bufnr
  end
  if not ensure_dbee_setup() then
    M._bufnr = placeholder_buffer(panel_winid, "dbee.setup failed or unavailable")
    return M._bufnr
  end
  local b = mount_drawer(panel_winid)
  if b then
    M._bufnr = b
  else
    M._bufnr = placeholder_buffer(panel_winid, "drawer_show returned nil")
  end
  return M._bufnr
end

---Drop the cached bufnr so the next focus remounts cleanly. Matches
---the _neotree on_close contract — without this, dbee's drawer
---buffer could be wiped externally between panel-close and reopen
---and the section would attempt to restore a stale bufnr.
function M.on_close()
  M._bufnr = nil
end

return M
