---auto-finder.views.files.highlights — the panel's highlight groups (ADR-0200 §4.3, rationale §R6/§R10).
---
---NAMED EXCEPTION to forked-codebase-severance — the only file under lua/ that may name `NeoTree*`.
---Reason: colour schemes (catppuccin, tokyonight, everforest ship it) and autovim's transparency.lua style
---the file tree through the `NeoTree*` group NAMES. Johno ruled the alias bridge on 2026-09-27 (task item
---14): auto-finder paints only `AutoFinder*` groups, each default-linked to its `NeoTree*` name, so a theme's
---colours keep applying. No code, module or dependency of the retired fork is involved; these are group names.
---tests/severance.lua holds the exemption's premise (no require here) and liveness cells.
---
---When a theme does not define a `NeoTree*` group, the fallback below defines it exactly as the retired
---fork did (link to the first existing group in a priority list, else a literal colour, some faded from
---Normal), so the pane looks the same with or without the theme integration.
---@module 'auto-finder.views.files.highlights'

local M = {}

-- AutoFinder* group → the NeoTree* name it aliases. The renderer and window_style paint the left column.
M.ALIAS = {
  AutoFinderNormal         = "NeoTreeNormal",
  AutoFinderNormalNC       = "NeoTreeNormalNC",
  AutoFinderSignColumn     = "NeoTreeSignColumn",
  AutoFinderCursorLine     = "NeoTreeCursorLine",
  AutoFinderFloatBorder    = "NeoTreeFloatBorder",
  AutoFinderFloatNormal    = "NeoTreeFloatNormal",
  AutoFinderFloatTitle     = "NeoTreeFloatTitle",
  AutoFinderStatusLine     = "NeoTreeStatusLine",
  AutoFinderStatusLineNC   = "NeoTreeStatusLineNC",
  AutoFinderVertSplit      = "NeoTreeVertSplit",
  AutoFinderWinSeparator   = "NeoTreeWinSeparator",
  AutoFinderEndOfBuffer    = "NeoTreeEndOfBuffer",
  AutoFinderBufferNumber   = "NeoTreeBufferNumber",
  AutoFinderDimText        = "NeoTreeDimText",
  AutoFinderDotfile        = "NeoTreeDotfile",
  AutoFinderDirectoryName  = "NeoTreeDirectoryName",
  AutoFinderDirectoryIcon  = "NeoTreeDirectoryIcon",
  AutoFinderFileIcon       = "NeoTreeFileIcon",
  AutoFinderFileName       = "NeoTreeFileName",
  AutoFinderFilterTerm     = "NeoTreeFilterTerm",
  AutoFinderRootName       = "NeoTreeRootName",
  AutoFinderIndentMarker   = "NeoTreeIndentMarker",
  AutoFinderMessage        = "NeoTreeMessage",
  AutoFinderGitAdded       = "NeoTreeGitAdded",
  AutoFinderGitDeleted     = "NeoTreeGitDeleted",
  AutoFinderGitModified    = "NeoTreeGitModified",
  AutoFinderGitConflict    = "NeoTreeGitConflict",
  AutoFinderGitIgnored     = "NeoTreeGitIgnored",
  AutoFinderGitRenamed     = "NeoTreeGitRenamed",
  AutoFinderGitStaged      = "NeoTreeGitStaged",
  AutoFinderGitUnstaged    = "NeoTreeGitUnstaged",
  AutoFinderGitUntracked   = "NeoTreeGitUntracked",
}

-- The window-local look every filetype=auto-finder view gets (panel/window_style.lua).
M.WINHIGHLIGHT = table.concat({
  "Normal:AutoFinderNormal",
  "NormalNC:AutoFinderNormalNC",
  "SignColumn:AutoFinderSignColumn",
  "CursorLine:AutoFinderCursorLine",
  "FloatBorder:AutoFinderFloatBorder",
  "StatusLine:AutoFinderStatusLine",
  "StatusLineNC:AutoFinderStatusLineNC",
  "VertSplit:AutoFinderVertSplit",
  "EndOfBuffer:AutoFinderEndOfBuffer",
  "WinSeparator:AutoFinderWinSeparator",
}, ",")

local function exists(name) return vim.fn.hlexists(name) == 1 end

-- Resolved attributes of an existing group, in the shape the fallback math reads.
local function get(name)
  local h = vim.api.nvim_get_hl(0, { name = name, link = false })
  return { foreground = h.fg, background = h.bg, bold = h.bold, italic = h.italic,
    underline = h.underline, undercurl = h.undercurl }
end

-- Truncates, as the retired fork's `string.format("%06x", n)` on a float did under LuaJIT: the faded
-- groups (indent markers, dim text) must resolve to the same colour, not one step off.
local function hex(n, pad)
  return string.format("%0" .. (pad or 6) .. "x", math.floor(n))
end

---Define `name` unless it is already fully defined: link to the first group of `links` that exists (when
---that group has colours, or `name` brings none of its own), else define it from bg/fg/gui.
local function create(name, links, background, foreground, gui)
  local h = exists(name) and get(name) or nil
  if h and h.foreground and h.background then return h end
  for _, to in ipairs(links) do
    if exists(to) then
      local t = get(to)
      local own = background or foreground or gui
      if t.foreground or t.background or not own then
        vim.cmd("highlight default link " .. name .. " " .. to)
        return t
      end
    end
  end
  if type(background) == "number" then background = hex(background) end
  if type(foreground) == "number" then foreground = hex(foreground) end
  local cmd = "highlight default " .. name
  if background then cmd = cmd .. " guibg=#" .. background end
  cmd = cmd .. (foreground and (" guifg=#" .. foreground) or " guifg=NONE")
  if gui then cmd = cmd .. " gui=" .. gui end
  vim.cmd(cmd)
  return { background = background and tonumber(background, 16) or nil,
    foreground = foreground and tonumber(foreground, 16) or nil }
end

-- `name`'s foreground blended toward Normal's background by `pct`.
local function faded(name, pct)
  local normal = get("Normal")
  if type(normal.foreground) ~= "number" then
    normal.foreground = vim.go.background == "dark" and 0xffffff or 0x000000
  end
  if type(normal.background) ~= "number" then
    normal.background = vim.go.background == "dark" and 0x000000 or 0xffffff
  end
  local fg, bg = hex(normal.foreground), hex(normal.background)
  local g = get(name)
  if type(g.foreground) == "number" then fg = hex(g.foreground) end
  if type(g.background) == "number" then bg = hex(g.background) end
  local gui = {}
  for _, a in ipairs({ "bold", "italic", "underline", "undercurl" }) do
    if g[a] then gui[#gui + 1] = a end
  end
  local function ch(s, i) return tonumber(s:sub(i, i + 1), 16) end
  local r = ch(fg, 1) * pct + ch(bg, 1) * (1 - pct)
  local gr = ch(fg, 3) * pct + ch(bg, 3) * (1 - pct)
  local b = ch(fg, 5) * pct + ch(bg, 5) * (1 - pct)
  return { background = g.background, foreground = hex(r, 2) .. hex(gr, 2) .. hex(b, 2),
    gui = #gui > 0 and table.concat(gui, ",") or nil }
end

---(Re)define every group. Runs at setup and on ColorScheme.
function M.setup()
  local added = vim.fn.has("nvim-0.10") == 1 and "Added" or "diffAdded"
  local changed = vim.fn.has("nvim-0.10") == 1 and "Changed" or "diffChanged"
  local removed = vim.fn.has("nvim-0.10") == 1 and "Removed" or "diffRemoved"

  local normal = create("NeoTreeNormal", { "Normal" })
  local normalnc = create("NeoTreeNormalNC", { "NormalNC", "NeoTreeNormal" })
  create("NeoTreeSignColumn", { "SignColumn", "NeoTreeNormal" })
  create("NeoTreeStatusLine", { "StatusLine" })
  create("NeoTreeStatusLineNC", { "StatusLineNC" })
  create("NeoTreeVertSplit", { "VertSplit" })
  create("NeoTreeWinSeparator", { "WinSeparator" })
  create("NeoTreeEndOfBuffer", { "EndOfBuffer" })
  local border = create("NeoTreeFloatBorder", { "FloatBorder" }, normalnc.background, "444444")
  create("NeoTreeFloatNormal", { "NormalFloat", "NeoTreeNormal" })
  create("NeoTreeFloatTitle", {}, border.background, normal.foreground)

  local dim = faded("NeoTreeNormal", 0.3)
  create("NeoTreeBufferNumber", { "SpecialChar" })
  create("NeoTreeMessage", {}, nil, dim.foreground, "italic")
  create("NeoTreeDotfile", {}, nil, "626262")
  create("NeoTreeCursorLine", { "CursorLine" }, nil, nil, "bold")
  create("NeoTreeDimText", {}, nil, dim.foreground)
  create("NeoTreeDirectoryName", { "Directory" }, "NONE", "NONE")
  create("NeoTreeDirectoryIcon", { "Directory" }, nil, "73cef4")
  create("NeoTreeFileIcon", { "NeoTreeDirectoryIcon" })
  create("NeoTreeFileName", {}, "NONE", "NONE")
  create("NeoTreeFilterTerm", { "SpecialChar", "Normal" })
  create("NeoTreeRootName", {}, nil, nil, "bold,italic")
  create("NeoTreeIndentMarker", { "NeoTreeDimText" })

  create("NeoTreeGitAdded", { "GitGutterAdd", "GitSignsAdd", added }, nil, "5faf5f")
  create("NeoTreeGitDeleted", { "GitGutterDelete", "GitSignsDelete", removed }, nil, "ff5900")
  create("NeoTreeGitModified", { "GitGutterChange", "GitSignsChange", changed }, nil, "d7af5f")
  local conflict = create("NeoTreeGitConflict", {}, nil, "ff8700", "italic,bold")
  create("NeoTreeGitIgnored", { "NeoTreeDotfile" })
  create("NeoTreeGitRenamed", { "NeoTreeGitModified" })
  create("NeoTreeGitStaged", { "NeoTreeGitAdded" })
  create("NeoTreeGitUnstaged", { "NeoTreeGitConflict" })
  create("NeoTreeGitUntracked", {}, nil, conflict.foreground, "italic")

  for af, nt in pairs(M.ALIAS) do
    vim.api.nvim_set_hl(0, af, { link = nt, default = true })
  end
end

local _augroup
---Idempotent: define now and re-define on every ColorScheme.
function M.ensure()
  if _augroup then return end
  _augroup = vim.api.nvim_create_augroup("auto-finder.highlights", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = _augroup, callback = function() M.setup() end })
  M.setup()
end

return M
