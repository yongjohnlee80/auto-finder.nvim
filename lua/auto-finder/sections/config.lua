---Section 0 — config / control-surface slot.
---
---Thin wrapper around `auto-finder.panel.admin`: the admin module owns
---the prompt buffer, this module exposes it as a section.
---@module 'auto-finder.sections.config'

local admin = require("auto-finder.panel.admin")

local M = {
  name = "config",
  description = "control surface (prompt REPL)",
}

function M.get_buffer()
  return admin.get_or_create_buffer()
end

function M.on_focus(panel_winid, bufnr)
  -- Move cursor to the prompt line and enter insert mode so the user can
  -- immediately type a command. This is the one section where insert mode
  -- is the right default — it's an interactive REPL.
  if not vim.api.nvim_win_is_valid(panel_winid) then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local last = vim.api.nvim_buf_line_count(bufnr)
  pcall(vim.api.nvim_win_set_cursor, panel_winid, { last, 0 })
  vim.cmd("startinsert!")
end

return M