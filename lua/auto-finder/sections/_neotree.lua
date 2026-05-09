---Shared helper for sections that mount a neo-tree source into the
---auto-finder panel window via `position = "current"`. Used by the
---`files` section (filesystem source) and the `repos` section
---(auto-finder-repos source). Centralizes:
---
---  - the get-current-window dance neo-tree's "current" path requires
---  - the cmd.execute call + error reporting
---  - the post-mount filetype-wait (neo-tree's command path schedules
---    part of the mount; we'd cache a scratch bufnr otherwise)
---  - the auto_expand_width re-sync against the current pin state
---  - the section-bufnr cache + on_focus revive logic
---
---Each section is a thin wrapper around `M.build_section(opts)` —
---specifying its name, neo-tree source, and any extra render options.
---@module 'auto-finder.sections._neotree'

local M = {}

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
    vim.notify(
      "auto-finder: neo-tree is not installed; the '" .. section_label ..
      "' section requires nvim-neo-tree/neo-tree.nvim",
      vim.log.levels.ERROR)
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
    vim.notify(
      "auto-finder: neo-tree.execute failed for source '" .. source .. "': " .. tostring(err),
      vim.log.levels.ERROR)
    return nil
  end
  -- Wait briefly for neo-tree's async mount to settle. The buffer-
  -- swap into our panel is synchronous, but on the very first mount
  -- the buffer may not yet have filetype="auto-finder.neotree" at this exact
  -- tick — caching the scratch bufnr in that case would let the
  -- bounce-back guard restore the wrong thing later.
  vim.wait(200, function()
    if not vim.api.nvim_win_is_valid(panel_winid) then return false end
    local b = vim.api.nvim_win_get_buf(panel_winid)
    return vim.bo[b].filetype == "auto-finder.neotree"
  end, 5)

  -- Re-sync neo-tree's auto_expand_width to whatever the current pin
  -- state demands. A fresh neo-tree state was just created (or
  -- revived) and inherits the global config; if a pin is active we
  -- want auto_expand off, if dynamic, on. Catches both first mounts
  -- and remounts after on_close().
  pcall(function()
    local af = require("auto-finder")
    require("auto-finder.panel.host")._sync_neotree_auto_expand(af.state)
  end)

  return vim.api.nvim_win_get_buf(panel_winid)
end

---Build a section module that mounts the given neo-tree `source` into
---the panel. Returns a section table with `get_buffer`, `on_focus`,
---and `on_close` already wired. Callers add `name`, `description`,
---and any extra fields they want to expose.
---
---Example:
---```lua
---local _neotree = require("auto-finder.sections._neotree")
---return _neotree.build_section({
---  name = "files",
---  description = "filesystem (neo-tree wrapper)",
---  source = "filesystem",
---})
---```
---@param opts { name: string, description: string?, source: string }
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
    if b then section._bufnr = b end
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
      end
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

  return section
end

return M
