---Section 1 — files (neo-tree filesystem wrapper).
---
---On first focus, this section drives `neo-tree.command.execute` with
---`position = "current"` so neo-tree mounts its filesystem buffer in
---our existing panel window. Subsequent focuses reuse the cached
---bufnr and just place it back in the panel window.
---@module 'auto-finder.sections.files'

local M = {
  name = "files",
  description = "filesystem (neo-tree wrapper)",
}

---@type integer|nil
M._bufnr = nil

local function buf_valid()
  return M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr)
end

---Drive neo-tree to render the filesystem source into the panel window.
---Returns the bufnr neo-tree mounted there.
---@param panel_winid integer
---@return integer|nil
local function mount_neotree(panel_winid)
  if not vim.api.nvim_win_is_valid(panel_winid) then return nil end
  -- Make sure we're in the panel window before driving neo-tree's
  -- `position = "current"` codepath — it operates on the current win.
  pcall(vim.api.nvim_set_current_win, panel_winid)

  local ok, cmd = pcall(require, "neo-tree.command")
  if not ok then
    vim.notify(
      "auto-finder: neo-tree is not installed; the 'files' section requires nvim-neo-tree/neo-tree.nvim",
      vim.log.levels.ERROR)
    return nil
  end

  -- `action = "show"` renders without grabbing focus from a different
  -- window — but since we already moved focus to the panel above, the
  -- buffer lands here regardless. `reveal = false` keeps the tree at
  -- its last cwd rather than chasing the user's previously-focused
  -- buffer (which would feel jumpy when switching sections).
  local exec_ok, err = pcall(cmd.execute, {
    source = "filesystem",
    action = "show",
    position = "current",
    reveal = false,
  })
  if not exec_ok then
    vim.notify("auto-finder: neo-tree.execute failed: " .. tostring(err), vim.log.levels.ERROR)
    return nil
  end
  -- neo-tree's command path schedules part of the mount (cwd resolve,
  -- async fs_scan). The buffer-swap into our panel is synchronous, but
  -- on the very first mount of a session the buffer may not yet have
  -- filetype="neo-tree" at this exact tick — we'd cache the scratch
  -- bufnr in state.section_buffers and the bounce-back guard would
  -- restore the wrong thing later. Wait briefly for the swap.
  vim.wait(200, function()
    if not vim.api.nvim_win_is_valid(panel_winid) then return false end
    local b = vim.api.nvim_win_get_buf(panel_winid)
    return vim.bo[b].filetype == "neo-tree"
  end, 5)
  -- Re-sync neo-tree's auto_expand_width with the current pin state.
  -- A fresh neo-tree state was just created (or revived), so it
  -- inherits whatever the global config currently says. If a pin is
  -- active we want auto_expand off; if dynamic, on. Calling here
  -- catches both first mounts and remounts after on_close().
  pcall(function()
    local af = require("auto-finder")
    require("auto-finder.panel.host")._sync_neotree_auto_expand(af.state)
  end)
  return vim.api.nvim_win_get_buf(panel_winid)
end

function M.get_buffer(panel_winid)
  if buf_valid() then return M._bufnr end
  local b = mount_neotree(panel_winid)
  if b then M._bufnr = b end
  return b
end

function M.on_focus(panel_winid, bufnr)
  -- If neo-tree's buffer was wiped (e.g. user :bd'd it), remount fresh.
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    M._bufnr = nil
    local b = mount_neotree(panel_winid)
    if b then
      M._bufnr = b
      vim.api.nvim_win_set_buf(panel_winid, b)
    end
  end
end

---Called by host.close() when the panel window is going away. We
---delete the cached neo-tree buffer so a subsequent reopen re-mounts
---fresh — without this, neo-tree's setup/init.lua:297-310 win_enter
---redirect would fire with a stale `old_state.tree = nil` and crash
---(`attempt to index local 'tree' (a nil value)`).
function M.on_close()
  if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
    pcall(vim.api.nvim_buf_delete, M._bufnr, { force = true })
  end
  M._bufnr = nil
end

---Defensive monkey-patch: neo-tree's `renderer.get_expanded_nodes`
---indexes `tree:get_nodes(...)` without checking that `tree` is
---non-nil. The win_enter_event redirect calls it with
---`old_state.tree`, which is nil when the original neo-tree window
---was closed before its tree finished rendering. Patch once at
---module load so any caller of `get_expanded_nodes(nil)` gets back
---an empty list instead of crashing.
local function patch_neotree_renderer_nil_tree()
  local ok, renderer = pcall(require, "neo-tree.ui.renderer")
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
patch_neotree_renderer_nil_tree()

return M