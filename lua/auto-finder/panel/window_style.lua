---auto-finder.panel.window_style — the window-local look of every filetype=auto-finder view (ADR-0200 §4.9,
---rationale §R10).
---
---Whenever a filetype=auto-finder buffer is shown in the panel window, the window gets: cursorline
---(cursorlineopt=line), nowrap, nolist, nospell, nonumber, norelativenumber, and a winhighlight that maps
---Normal/NormalNC/SignColumn/CursorLine/… to the AutoFinder* groups (which alias the NeoTree* names themes
---style). When a buffer of another filetype (the config slot's `auto-finder-config`) takes the window, the
---options the window had before the first styling are put back.
---
---Every write is `scope = "local"` — a bare `vim.wo.x = …` also sets the global default on nvim 0.10+ and
---leaks the panel's look into the user's other windows (auto-core-panel-ownership).
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

local SAVED = { "cursorline", "cursorlineopt", "foldcolumn", "wrap", "list", "spell", "number",
  "relativenumber", "winhighlight" }

-- winid → the options it had before the first styling (restored for non-auto-finder buffers)
local _saved = {}
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
  if vim.bo[buf].filetype == "auto-finder" then
    if not _saved[winid] then
      local s = {}
      for _, name in ipairs(SAVED) do s[name] = vim.api.nvim_get_option_value(name, { win = winid }) end
      _saved[winid] = s
    end
    for name, value in pairs(M.OPTIONS) do
      vim.api.nvim_set_option_value(name, value, { win = winid, scope = "local" })
    end
    vim.api.nvim_set_option_value("winhighlight", require("auto-finder.views.files.highlights").WINHIGHLIGHT,
      { win = winid, scope = "local" })
  elseif _saved[winid] then
    for name, value in pairs(_saved[winid]) do
      vim.api.nvim_set_option_value(name, value, { win = winid, scope = "local" })
    end
    _saved[winid] = nil
  end
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
  vim.api.nvim_create_autocmd("WinClosed", {
    group = _augroup,
    callback = function(ev) _saved[tonumber(ev.match)] = nil end,
  })
end

function M._reset_for_tests()
  if _augroup then pcall(vim.api.nvim_del_augroup_by_id, _augroup) end
  _augroup, _saved = nil, {}
end

return M
