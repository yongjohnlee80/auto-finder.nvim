---Panel host — thin delegation over `auto-core.ui.panel`.
---
---v0.2.0 step 3 of the auto-finder migration. The singleton vsplit
---window's lifecycle (open / close / toggle / focus / resize / pin /
---winfixwidth / winfixbuf / orphan adoption / scratch placement) moves
---to auto-core. The panel singleton itself lives at
---`require("auto-finder")._panel`, claimed in `auto-finder.setup()`.
---
---This module keeps the small set of auto-finder-specific
---responsibilities:
---
---  - section on_close fanout when the panel closes (every cached
---    section gets a chance to tear down external resources)
---  - `apply_section_keymap` (0..9 / q per buffer; auto-core's section
---    primitive provides this but section.attach migration is step 4)
---  - `reflow_views` catch-up repaint of the files / buffers views after a
---    resize so right-aligned components reflow to the new column count
---  - `set_panel_width` cache
---  - `refresh_winbar` wrapper that delegates to
---    `M._panel:set_winbar(sections, focused)` (auto-core's winbar
---    primitive replaced the local `panel/winbar.lua` in this step)
---  - the auto-finder-specific min-width preflight (`cfg.width.min + 20`
---    is stricter than auto-core's `min + 10` — keeps editor breathing
---    room)
---
---State (cached on `require("auto-finder").state`):
---   panel_winid : the active vsplit's winid (mirrored via on_open/
---                 on_close from the auto-core panel)
---   panel_width : the column count the window currently sits at
---   user_width  : sticky pin (lives in auto-core state.namespace —
---                 see `auto-finder.state`; mirrored here via watcher)
---   section     : numeric index of the currently-displayed section
---@module 'auto-finder.panel.host'

local M = {}

---@param state table
---@return boolean
local function panel_is_open(state)
  return state.panel_winid ~= nil
    and vim.api.nvim_win_is_valid(state.panel_winid)
end

local function panel()
  return require("auto-finder")._panel
end

---Cache the panel width on state.
---@param state table
---@param width integer
local function set_panel_width(state, width)
  state.panel_width = width
end

---Repaint the files / buffers views when shown so their right-aligned
---diagnostic signs reflow to the new column count after a resize. Each
---view's paint writes only the lines that changed, and a hidden view is
---skipped (a hidden pane does no work).
local function reflow_views()
  for _, name in ipairs({ "auto-finder.views.files", "auto-finder.views.buffers" }) do
    local ok, view = pcall(require, name)
    if ok and view._state and view._state.shown and type(view.paint) == "function" then
      pcall(view.paint)
    end
  end
end

---Open the panel window if not already open. Returns its winid.
---@param cfg AutoFinderConfig
---@param state table
---@param force boolean?
---@return integer|nil
function M.ensure_open(cfg, state, force)
  -- auto-finder-specific min-width preflight (stricter than
  -- auto-core's `min + 10`). Run before delegating so the warning
  -- references our specific UX expectation.
  local cols = vim.o.columns
  if not force and cols < cfg.width.min + 20 then
    require("auto-finder.log").warn("panel.host",
      "terminal width " .. cols .. " too narrow; use :AutoFinder! to force")
    return nil
  end
  local p = panel()
  if not p then
    require("auto-finder.log").error("panel.host",
      "panel singleton not initialized — setup() must run first")
    return nil
  end
  local winid = p:open(force)
  if winid then
    set_panel_width(state, vim.api.nvim_win_get_width(winid))
  end
  return winid
end

---Expose the unfix helper for callers that need to swap the panel
---buffer outside the focus path.
---The winid arg is now informational (auto-core panel has its own
---`self.winid`); kept for source-level compat with v0.1.x callers.
---@param _winid integer|nil
---@param fn fun(): any
---@return boolean ok, any result_or_err
function M.with_unfixed_buf(_winid, fn)
  local p = panel()
  if not p then return pcall(fn) end
  return p:with_unfixed_buf(fn)
end

---Close the panel window. The section on_close fanout (cleanup of
---external section state — notably the files and buffers views
---stopping their watches and subscriptions) fires automatically via the panel's
---`on_close` callback wired in init.lua's setup() — that path runs
---for both the keymap-q close AND a direct `:AutoFinder` toggle, so
---this wrapper just delegates.
---@param state table
function M.close(state)
  local p = panel()
  if p then p:close() end
end

---Re-render the winbar tab-strip via auto-core's primitive. No-op
---when the panel isn't open. The local `panel/winbar.lua` was
---removed in v0.2.0 step 3 — auto-core's `Panel:set_winbar(sections,
---focused)` covers the same 3-mode adaptive renderer + click router.
---Highlight group renamed `AutoFinderSectionActive` →
---`AutoCoreSectionActive` (link to `Title` by default; theme
---overrides on the old name silently lose effect — call out in
---CHANGELOG when v0.2.0 ships).
---@param state table
function M.refresh_winbar(state)
  if not panel_is_open(state) then return end
  local p = panel()
  if not p then return end
  local sections = require("auto-finder.sections").enabled()
  p:set_winbar(sections, state.section or 0)
end

-- v0.2.0 step 4: M.focus(cfg, state, key) removed — the section
-- registry attached in init.lua setup() owns focus lifecycle now.
-- Callers go through `auto-finder.M.focus(key)` (init.lua), which
-- runs the auto-finder-specific min-width preflight via
-- `M.ensure_open` above and then delegates to
-- `M._registry:focus(key)`. apply_section_keymap moved to
-- auto-core.ui.section's apply_keymap (same 0..9 + q surface).

---Pin the panel width to N columns. Survives :VimResized.
---
---v0.2.0 step 3: writes through `state.namespace` (which persists
---automatically); the user_width watcher in setup() drives
---`M._panel:resize(n)` and the post-resize side-effects via
---`_refresh_after_resize`.
---@param cfg AutoFinderConfig
---@param state table
---@param n integer
function M.resize(cfg, state, n)
  local logger = require("auto-finder.log")
  if type(n) ~= "number" or n < 1 then
    logger.error("panel.host", "resize N must be a positive integer")
    return
  end
  local w = cfg.width
  if w and (n < (w.min or 1) or n > (w.max or math.huge)) then
    logger.error("panel.host",
      string.format("resize %d out of range [%d..%d]", n, w.min, w.max))
    return
  end
  require("auto-finder.state").set_user_width(n)
end

---Clear the user-pinned width. Width reverts to the configured
---default; auto_expand_width re-engages on the next render because
---the forked renderer's pin-check sees `state.user_width = nil`.
---Aliased as `panel dynamic` in the admin DSL.
---@param cfg AutoFinderConfig
---@param state table
function M.reset_width(cfg, state)
  require("auto-finder.state").set_user_width(nil)
end

---Refresh the panel width from cfg + cols. Honours the user pin —
---only the percentage-derived default reflows on terminal resize.
---@param cfg AutoFinderConfig
---@param state table
function M.refresh_width(cfg, state)
  if not panel_is_open(state) then return end
  local p = panel()
  if not p then return end
  p:refresh_width()
  set_panel_width(state, vim.api.nvim_win_get_width(state.panel_winid))
  M.refresh_winbar(state)
  reflow_views()
end

---WinResized callback: re-clamp the panel back to the user pin when
---an external resize grew it past the pin. **Only acts when a pin
---is set** — without a pin we deliberately let the renderer grow
---the panel dynamically (that's the whole point of `panel dynamic`).
---@param cfg AutoFinderConfig
---@param state table
function M.enforce_pin(cfg, state)
  if not panel_is_open(state) then return end
  local p = panel()
  if not p then return end
  if not (state.user_width and state.user_width > 0) then
    -- Dynamic mode — don't fight the auto-expand, but still reflow
    -- right-aligned components when the panel was resized by the user
    -- dragging the window border.
    reflow_views()
    return
  end
  p:enforce_pin()
  set_panel_width(state, vim.api.nvim_win_get_width(state.panel_winid))
  M.refresh_winbar(state)
  reflow_views()
end

---Shared post-resize side-effects. Public so the user_width watcher
---installed in init.lua's setup() can invoke it without a circular
---require. No-op when the panel isn't open.
---@param state table
function M._refresh_after_resize(state)
  if not panel_is_open(state) then return end
  set_panel_width(state, vim.api.nvim_win_get_width(state.panel_winid))
  M.refresh_winbar(state)
  reflow_views()
end

return M
