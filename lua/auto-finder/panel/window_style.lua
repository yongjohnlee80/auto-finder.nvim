---auto-finder.panel.window_style — the window-local look of every filetype=auto-finder view (ADR-0200 §4.9,
---rationale §R10).
---
---Whenever a filetype=auto-finder buffer is shown in the panel window, the window gets: cursorline
---(cursorlineopt=line), nowrap, nolist, nospell, nonumber, norelativenumber, and a winhighlight that maps
---Normal/NormalNC/SignColumn/CursorLine/… to the AutoFinder* groups (which alias the names colour schemes
---style — views/files/highlights.lua).
---
---Every write is `scope = "local"`: Neovim keeps a local window option per (window, buffer) pair, so the look
---stays with the auto-finder buffer — a buffer of another filetype (the config slot's `auto-finder-config`)
---gets its own remembered values back, or the window's untouched global values if it is new there. Nothing
---is saved or restored here; doing so would overwrite what Neovim just restored. A bare `vim.wo.x = …` also
---sets the global default on nvim 0.10+ and leaks the panel's look into the user's other windows
---(auto-core-panel-ownership).
---@module 'auto-finder.panel.window_style'

local M = {}

M.OPTIONS = {
  cursorline = true,
  cursorlineopt = "line",
  wrap = false,
  list = false,
  spell = false,
  number = false,
  relativenumber = false,
}

local _augroup

local function panel_winid()
  local ok, af = pcall(require, "auto-finder")
  local w = ok and af.state and af.state.panel_winid
  if w and vim.api.nvim_win_is_valid(w) then return w end
end

---Style `winid` for the buffer it now shows.
---@param winid integer
function M.apply(winid)
  if not (winid and vim.api.nvim_win_is_valid(winid)) then return end
  local buf = vim.api.nvim_win_get_buf(winid)
  if vim.bo[buf].filetype ~= "auto-finder" then return end
  for name, value in pairs(M.OPTIONS) do
    vim.api.nvim_set_option_value(name, value, { win = winid, scope = "local" })
  end
  vim.api.nvim_set_option_value("winhighlight", require("auto-finder.views.files.highlights").WINHIGHLIGHT,
    { win = winid, scope = "local" })
end

---Idempotent. Installs the BufEnter/BufWinEnter hook for the panel window.
function M.attach()
  if _augroup then return end
  require("auto-finder.views.files.highlights").ensure()
  _augroup = vim.api.nvim_create_augroup("auto-finder.window_style", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "FileType" }, {
    group = _augroup,
    callback = function()
      local w = panel_winid()
      if w then M.apply(w) end
    end,
  })
end

function M._reset_for_tests()
  if _augroup then pcall(vim.api.nvim_del_augroup_by_id, _augroup) end
  _augroup = nil
end

return M
