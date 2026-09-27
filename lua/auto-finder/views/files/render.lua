---auto-finder.views.files.render — rows and incremental painting for the files and buffers slots
---(ADR-0200 §4.3).
---
---`row` is pure: one item in, its line and highlight spans out. It reproduces the retired fork's look
---for the components the panel keeps (indent markers, icon, name, clipboard mark, buffer number,
---right-aligned diagnostic sign) — the parity goldens in tests/fixtures/parity are its oracle.
---
---`paint` diffs the new rows against the rows already in the buffer and rewrites only the changed range,
---re-setting extmarks for exactly those lines, so an event costs what it changes, not the tree's size.
---@module 'auto-finder.views.files.render'

local M = {}

M.NS = vim.api.nvim_create_namespace("auto-finder.files")

M.ICON = {
  folder_closed = "",
  folder_open = "",
  folder_empty = "󰉖",
  folder_empty_open = "󰷏",
  default = "*",
}

M.HL = {
  indent = "AutoFinderIndentMarker",
  dir_icon = "AutoFinderDirectoryIcon",
  file_icon = "AutoFinderFileIcon",
  dir_name = "AutoFinderDirectoryName",
  file_name = "AutoFinderFileName",
  dotfile = "AutoFinderDotfile",
  root = "AutoFinderRootName",
  dim = "AutoFinderDimText",
  bufnr = "AutoFinderBufferNumber",
}

-- git code (views/files/git.lua) → name highlight
M.GIT_HL = {
  added = "AutoFinderGitAdded",
  deleted = "AutoFinderGitDeleted",
  modified = "AutoFinderGitModified",
  renamed = "AutoFinderGitRenamed",
  conflict = "AutoFinderGitConflict",
  untracked = "AutoFinderGitUntracked",
  ignored = "AutoFinderGitIgnored",
}

-- nvim-web-devicons, memoized: a FAILED require is never cached by Lua, so without it every row would
-- re-search the runtimepath. `false` = confirmed absent. mini.icons' mock answers the same call.
local _devicons
local function devicons()
  if _devicons == nil then
    local ok, mod = pcall(require, "nvim-web-devicons")
    _devicons = ok and mod or false
  end
  return _devicons or nil
end
function M._reset_icon_cache() _devicons = nil end

---@class AutoFinderRowItem
---@field kind "root"|"directory"|"file"
---@field name string          -- display name (root: its label)
---@field depth integer        -- root = 0
---@field is_last boolean      -- last among its siblings
---@field continues boolean[]  -- continues[L] = the ancestor at depth L has a later sibling (L = 2..depth-1)
---@field expanded boolean?
---@field empty boolean?       -- a directory that was read and has no visible children
---@field git string?          -- code from views/files/git.lua
---@field diag string?         -- "Error"|"Warn"|"Info"|"Hint" (already filtered by the caller's rules)
---@field mark "cut"|"copy"|nil
---@field bufnr integer?       -- buffers slot: shown as " #N"

---@class AutoFinderRow
---@field text string
---@field spans { [1]: integer, [2]: integer, [3]: string }[]   -- byte col start, end, group
---@field width integer          -- display width the row wants (auto-expand input)

-- Sign for a diagnostic severity, as the retired fork resolved it: the configured sign text (padded to two
-- cells) with DiagnosticSign<Sev>, else the severity's first letter with Diagnostic<Sev>.
function M.diag_sign(severity)
  local signs = vim.diagnostic.config().signs
  if type(signs) == "function" then
    local ns = next(vim.diagnostic.get_namespaces())
    if ns then signs = signs(ns, 0) end
  end
  local text
  if type(signs) == "table" then
    local id = severity:sub(1, 1)
    if id == "H" then id = "N" end
    text = (signs.text or {})[vim.diagnostic.severity[id]]
  end
  if text and text ~= "" then
    if vim.fn.strchars(text) == 1 then text = text .. " " end
    return text, "DiagnosticSign" .. severity
  end
  return severity:sub(1, 1), "Diagnostic" .. severity
end

local function icon_for(item)
  if item.kind == "root" then return M.ICON.folder_open, M.HL.dir_icon end
  if item.kind == "directory" then
    if item.empty then
      return item.expanded and M.ICON.folder_empty_open or M.ICON.folder_empty, M.HL.dir_icon
    end
    return item.expanded and M.ICON.folder_open or M.ICON.folder_closed, M.HL.dir_icon
  end
  local d = devicons()
  if d then
    local glyph, hl = d.get_icon(item.name)
    if glyph then return glyph, hl or M.HL.file_icon end
  end
  return M.ICON.default, M.HL.file_icon
end

local function name_hl(item)
  if item.kind == "root" then return M.HL.root end
  if item.kind == "file" and item.name:sub(1, 1) == "." then return M.HL.dotfile end
  if item.git and M.GIT_HL[item.git] then return M.GIT_HL[item.git] end
  return item.kind == "directory" and M.HL.dir_name or M.HL.file_name
end

---One item → its line. `win_width` positions the right-aligned diagnostic sign.
---@param item AutoFinderRowItem
---@param win_width integer
---@return AutoFinderRow
function M.row(item, win_width)
  local parts, spans = { " " }, {}
  local col = 1
  local function put(text, hl)
    parts[#parts + 1] = text
    if hl then spans[#spans + 1] = { col, col + #text, hl } end
    col = col + #text
  end
  if item.depth >= 1 then put("  ") end
  for level = 2, item.depth do
    if level == item.depth then
      put(item.is_last and "└ " or "│ ", M.HL.indent)
    elseif item.continues[level] then
      put("│ ", M.HL.indent)
    else
      put("  ")
    end
  end
  local glyph, ihl = icon_for(item)
  put(glyph .. " ", ihl)
  put(item.name, name_hl(item))
  if item.mark then put(" (" .. item.mark .. ")", M.HL.dim) end
  if item.bufnr then put(" #" .. item.bufnr, M.HL.bufnr) end

  local text = table.concat(parts)
  local left = vim.fn.strdisplaywidth(text)
  local want = left
  if item.diag then
    local sign, shl = M.diag_sign(item.diag)
    local sw = vim.fn.strdisplaywidth(sign)
    want = left + 1 + sw
    local pad = math.max(1, win_width - left - sw)
    text = text .. string.rep(" ", pad)
    spans[#spans + 1] = { #text, #text + #sign, shl }
    text = text .. sign
  end
  return { text = text, spans = spans, width = want }
end

local function same(a, b)
  if a.text ~= b.text or #a.spans ~= #b.spans then return false end
  for i, s in ipairs(a.spans) do
    local t = b.spans[i]
    if s[1] ~= t[1] or s[2] ~= t[2] or s[3] ~= t[3] then return false end
  end
  return true
end

---Paint `rows` into `bufnr`, touching only the lines that differ from `prev` (the rows painted last time,
---or nil for a first paint). Returns the 0-based [first, last] row range written, or nil when nothing
---changed — tests assert on it.
---@param bufnr integer
---@param prev AutoFinderRow[]?
---@param rows AutoFinderRow[]
---@return integer? first, integer? last
function M.paint(bufnr, prev, rows)
  prev = prev or {}
  local n_old, n_new = #prev, #rows
  local first = 1
  while first <= n_old and first <= n_new and same(prev[first], rows[first]) do first = first + 1 end
  if first > n_old and first > n_new then return nil end
  -- common suffix, never overlapping the prefix
  local tail = 0
  while tail < (n_old - first + 1) and tail < (n_new - first + 1)
      and same(prev[n_old - tail], rows[n_new - tail]) do
    tail = tail + 1
  end
  local old_last, new_last = n_old - tail, n_new - tail
  local lines = {}
  for i = first, new_last do lines[#lines + 1] = rows[i].text end

  vim.bo[bufnr].modifiable = true
  -- extmarks of the replaced lines go with them; the replacement's are set below
  vim.api.nvim_buf_clear_namespace(bufnr, M.NS, first - 1, math.max(old_last, first - 1) + 0)
  if n_old == 0 then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  else
    vim.api.nvim_buf_set_lines(bufnr, first - 1, old_last, false, lines)
  end
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified = false
  for i = first, new_last do
    for _, s in ipairs(rows[i].spans) do
      vim.api.nvim_buf_set_extmark(bufnr, M.NS, i - 1, s[1], { end_col = s[2], hl_group = s[3], priority = 4096 })
    end
  end
  return first - 1, new_last - 1
end

return M
