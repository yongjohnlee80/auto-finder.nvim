---Companion-pane lifecycle for the dbase section.
---
---Phase 2, slice 1 of lector ADR 0020 §Implementation Plan paired
---with the white-vision §8 refinement: dbee's editor / result /
---call_log tiles live in the **main editor area**, not in the
---auto-finder panel column. The drawer stays in the panel
---(`sections.dbase` handles that); this module owns the OTHER
---three tiles.
---
---Boundary recap:
---  - dbee owns the tile internals (buffers, rendering, content).
---  - This module owns the **windows** that host those tiles, and
---    where they land in the layout.
---  - Auto-finder's panel is OFF-LIMITS — never `ui.editor_show`,
---    `ui.result_show`, or `ui.call_log_show` into the panel winid.
---
---API:
---  ensure_editor()    → winid|nil   mount editor tile, return winid
---  ensure_result()    → winid|nil   mount result tile (split below editor)
---  ensure_call_log()  → winid|nil   mount call_log tile (split below result)
---  close_all()                      tear down anything we mounted
---  is_open()          → boolean     any companion winid still valid
---
---All ensure_*() calls are idempotent — they return the existing
---winid if still valid, otherwise re-mount.
---ADR 0026 Phase 2: moved from `auto-finder.sections._dbase_layout`.
---Original path remains valid via `sections/_dbase_layout.lua` facade.
---@module 'auto-finder.views.dbase.layout'

local logger = require("auto-finder.log")

local M = {
  _editor_winid = nil,    ---@type integer|nil
  _result_winid = nil,    ---@type integer|nil
  _call_log_winid = nil,  ---@type integer|nil
}

---Is `winid` an auto-core panel of any kind? Auto-core panels are a
---family-wide primitive — auto-finder owns its column, auto-agents
---owns the right-side terminal/admin panel, and future plugins may
---register more. Every such panel carries `w:auto_core_panel_name`
---(canonical) and may also carry the legacy `w:auto_finder_panel = 1`
---marker for the auto-finder-specific panel. dbase companion tiles
---must NEVER mount into any of these — replacing e.g. the
---auto-agents agent terminal with dbee's editor tile would break
---the panel ownership contract.
---@param winid integer
---@return boolean
local function is_panel(winid)
  if not vim.api.nvim_win_is_valid(winid) then return false end
  if vim.w[winid].auto_finder_panel == 1 then return true end
  local name = vim.w[winid].auto_core_panel_name
  return type(name) == "string" and name ~= ""
end

---Find a usable editor-area window — any window that is NOT
---an auto-core panel and isn't itself a dbee tile we already own.
---Prefers the most-recently-current matching window (vim's `#`
---alt-window) so the editor lands where the user was last working.
---Returns nil if no such window exists (only panels are open).
---@return integer|nil
local function find_editor_window()
  -- Prefer the alt-window (previous window) if it qualifies. This is
  -- the most likely "where the user was just typing" location.
  local alt = vim.fn.win_getid(vim.fn.winnr("#"))
  if alt and alt > 0 and vim.api.nvim_win_is_valid(alt)
      and not is_panel(alt)
      and alt ~= M._result_winid
      and alt ~= M._call_log_winid then
    return alt
  end

  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w)
        and not is_panel(w)
        and w ~= M._editor_winid
        and w ~= M._result_winid
        and w ~= M._call_log_winid then
      return w
    end
  end
  return nil
end

---Find the auto-finder panel specifically (not any auto-core panel).
---Used by `create_editor_window` to know which panel to split from
---when only panels are visible — the dbase drawer lives in the
---auto-finder panel, so splitting from it lands the editor in the
---editor area adjacent to the drawer.
---@return integer|nil
local function find_auto_finder_panel()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w)
        and (vim.w[w].auto_finder_panel == 1
          or vim.w[w].auto_core_panel_name == "auto-finder") then
      return w
    end
  end
  return nil
end

---Create a fresh editor-area window when none qualifies (the user
---has only the panel open, e.g. `nvim .` then closed all other
---splits). vsplit to the right of the auto-finder panel.
---@return integer winid
local function create_editor_window()
  -- Focus the auto-finder panel briefly so the split lands right of
  -- it; the vsplit then becomes the new current window, which we
  -- capture. Other auto-core panels (e.g. auto-agents) are NOT
  -- valid split anchors — the dbase drawer lives in auto-finder's
  -- panel, so the editor area should land beside that one.
  local panel = find_auto_finder_panel()
  if panel and vim.api.nvim_win_is_valid(panel) then
    pcall(vim.api.nvim_set_current_win, panel)
    -- Splitting from the panel is delicate because:
    --   1. `:vsplit` propagates `winfixbuf=true` from the source
    --      (panel) to the new window.
    --   2. `:vsplit` makes the new window INHERIT the panel's drawer
    --      buffer, and that buffer is panel-owner-marked
    --      (`b:auto_core_panel_owner = "auto-finder"`). auto-core's
    --      `WinEnter`/`BufWinEnter` leak guard *closes* any non-panel
    --      window holding a panel-owner-marked buffer.
    --   3. `:vnew` (= `:vsplit | :enew`) is NOT atomic — the leak
    --      guard fires between the two halves and can close the
    --      window we're trying to create. The `:enew` then operates
    --      against a broken context (or the wrong window).
    -- Auto-core's panel module solves the same class of problem by
    -- wrapping its own split in `eventignore = "all"`. We follow
    -- that pattern: suppress autocmds for the whole split + buffer-
    -- replace sequence, so the leak guard never observes the
    -- intermediate panel-buffer-in-non-panel-window state.
    --
    -- Restoration MUST be guaranteed (lector review should-fix §3) —
    -- any unhandled Lua error between set and restore would leave
    -- `eventignore = "all"` globally, silently breaking every
    -- autocmd-driven feature in the editor. xpcall provides the
    -- finally-equivalent: capture the error inside the protected
    -- body, restore in the outer scope unconditionally.
    local saved_eventignore = vim.o.eventignore
    vim.o.eventignore = "all"
    local newwin
    local ok, err = xpcall(function()
      vim.cmd("rightbelow vsplit")
      newwin = vim.api.nvim_get_current_win()
      if newwin ~= panel then
        vim.api.nvim_set_option_value("winfixbuf", false, { win = newwin })
        local scratch = vim.api.nvim_create_buf(false, true)
        vim.bo[scratch].buftype  = "nofile"
        vim.bo[scratch].swapfile = false
        vim.api.nvim_win_set_buf(newwin, scratch)
      end
    end, debug.traceback)
    -- Restore unconditionally — runs even if xpcall caught an error.
    vim.o.eventignore = saved_eventignore
    if not ok then
      logger.error("dbase.layout",
        "create_editor_window xpcall body errored: " .. tostring(err))
      return nil
    end
    return newwin
  end
  -- No panel either; safe to use plain :vnew (no panel-owner buffer
  -- to inherit, no leak guard to fight).
  vim.cmd("vnew")
  local newwin = vim.api.nvim_get_current_win()
  pcall(vim.api.nvim_set_option_value, "winfixbuf", false, { win = newwin })
  return newwin
end

---Mount the dbee editor tile in an editor-area window. Idempotent.
---@return integer|nil winid
function M.ensure_editor()
  if M._editor_winid and vim.api.nvim_win_is_valid(M._editor_winid) then
    return M._editor_winid
  end

  local ok, dbee = pcall(require, "dbee")
  if not ok then return nil end

  local winid = find_editor_window() or create_editor_window()
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    logger.error("dbase.layout", "could not resolve editor window")
    return nil
  end

  local show_ok, err = pcall(dbee.api.ui.editor_show, winid)
  if not show_ok then
    logger.error("dbase.layout", "editor_show failed: " .. tostring(err))
    return nil
  end
  M._editor_winid = winid
  return winid
end

---Generic helper: ensure a tile is shown in a split below `parent_winid`.
---Used for both result and call_log. Idempotent on the tracked winid.
---@param current_winid integer|nil  the cached winid (may be invalid)
---@param parent_winid integer|nil   reference window to split below
---@param show_fn fun(winid: integer)  dbee api.ui.<tile>_show
---@param label string                 for logging
---@return integer|nil winid
local function ensure_below_split(current_winid, parent_winid, show_fn, label)
  if current_winid and vim.api.nvim_win_is_valid(current_winid) then
    return current_winid
  end
  if not parent_winid or not vim.api.nvim_win_is_valid(parent_winid) then
    -- Parent gone; auto-recover by mounting the editor first.
    parent_winid = M.ensure_editor()
    if not parent_winid then
      logger.error("dbase.layout",
        label .. ": no parent winid (editor mount failed)")
      return nil
    end
  end

  pcall(vim.api.nvim_set_current_win, parent_winid)
  vim.cmd("belowright split")
  local newwin = vim.api.nvim_get_current_win()
  -- Same winfixbuf-propagation guard as create_editor_window.
  pcall(vim.api.nvim_set_option_value, "winfixbuf", false, { win = newwin })
  local scratch = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_win_set_buf, newwin, scratch)

  -- dbee's tile :show() methods do "bind buffer to window" first, then
  -- finish with `:refresh()`. The refresh leans on the Go backend
  -- (e.g. call_log → `handler:connection_get_calls`), which can error
  -- if the backend is absent or the cached connection_id is stale.
  -- That refresh failure is downstream of the window+buffer binding
  -- we actually care about — log it as a warning but DO NOT tear down
  -- the window. A subsequent legitimate refresh will recover.
  local ok, err = pcall(show_fn, newwin)
  if not ok then
    logger.warn("dbase.layout",
      label .. "_show errored mid-init (probably a refresh failure): "
        .. tostring(err))
  end
  if not vim.api.nvim_win_is_valid(newwin) then
    logger.error("dbase.layout",
      label .. "_show closed the window before we could capture it")
    return nil
  end
  return newwin
end

---@return integer|nil winid
function M.ensure_result()
  local ok, dbee = pcall(require, "dbee")
  if not ok then return nil end
  local winid = ensure_below_split(M._result_winid, M._editor_winid,
    dbee.api.ui.result_show, "result")
  M._result_winid = winid
  return winid
end

---@return integer|nil winid
function M.ensure_call_log()
  local ok, dbee = pcall(require, "dbee")
  if not ok then return nil end
  local winid = ensure_below_split(M._call_log_winid,
    M._result_winid or M._editor_winid,
    dbee.api.ui.call_log_show, "call_log")
  M._call_log_winid = winid
  return winid
end

---Close every companion window we own. Does NOT touch the panel.
---Idempotent.
function M.close_all()
  for _, key in ipairs({ "_call_log_winid", "_result_winid", "_editor_winid" }) do
    local w = M[key]
    if w and vim.api.nvim_win_is_valid(w) and not is_panel(w) then
      pcall(vim.api.nvim_win_close, w, true)
    end
    M[key] = nil
  end
end

---@return boolean
function M.is_open()
  for _, w in ipairs({ M._editor_winid, M._result_winid, M._call_log_winid }) do
    if w and vim.api.nvim_win_is_valid(w) then return true end
  end
  return false
end

---Open all three companion tiles in one call. Idempotent — each
---ensure_*() returns the existing winid if still valid.
---@return boolean ok  true if at least the editor mounted
function M.open()
  local editor = M.ensure_editor()
  if not editor then return false end
  M.ensure_result()
  M.ensure_call_log()
  return true
end

---@return boolean
local function layout_is_open()
  return M.is_open()
end

---dbee-compatible Layout object for `dbee.setup({ window_layout =
---... })`. Passing this to dbee replaces the default
---`DefaultLayout` which would otherwise snapshot the entire vim
---layout via `tools.save()` and create four exclusive windows on
---`dbee.open() / toggle() / require("dbee").open()`. Lector's
---ADR 0020 §"Window Ownership" makes the default layout forbidden
---inside the section flow.
---
---Our layout DOES NOT own the drawer (auto-finder's panel does).
---`open()` only mounts editor / result / call_log. `close()` tears
---those three down. The drawer's lifecycle is independent and
---driven by the section.
M.layout = {
  is_open = layout_is_open,
  open    = function() M.open() end,
  close   = function() M.close_all() end,
  reset   = function() M.close_all(); M.open() end,
}

---Test-only — clear cached winids without closing the windows. Useful
---when a test wants to assert auto-recovery from invalid winids.
function M._reset_state()
  M._editor_winid = nil
  M._result_winid = nil
  M._call_log_winid = nil
end

return M
