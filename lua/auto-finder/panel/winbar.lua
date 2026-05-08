---Winbar tab-strip for the auto-finder panel window. Renders every
---enabled section side by side with the focused one bracketed and
---each section wrapped in a clickable region — left-click on a
---section focuses it, no keyboard required.
---@module 'auto-finder.panel.winbar'

local M = {}

---Click handler invoked by `%N@v:lua.require'…winbar'.click@…%X`
---regions. The section number is encoded in the statusline `minwid`
---field, which vim passes as the first argument.
---@param minwid integer  -- the section number
---@param _clicks integer
---@param _button string
---@param _mods string
function M.click(minwid, _clicks, _button, _mods)
  require("auto-finder").focus(minwid)
end

---Build the winbar string. Adaptive: if the full per-section labels
---wouldn't fit in `available_width`, falls back to compact `N` for
---unfocused sections. Each section is wrapped in a vim clickable
---region (`%@…@…%X`) that calls back to M.click on left-click.
---@param focused integer  -- numeric section index
---@param sections { number: integer, name: string }[]  -- in display order
---@param available_width integer|nil
---@return string
function M.render(focused, sections, available_width)
  if not sections or #sections == 0 then return "" end

  -- Three rendering modes by available width:
  --
  --   FULL    " 0: config "  " 1: files " ...   labels for everyone
  --   FOCUSED " 0 "  "[1: files]"  " 2 " ...    label only for focused
  --   COMPACT " 0 "  "[1]"  " 2 "  " 3 " ...    just numbers, focused bracketed
  --
  -- We pick the widest one that fits in `available_width`.
  local function len_full()
    local n = 0
    for _, s in ipairs(sections) do
      n = n + 4 + #tostring(s.number) + #s.name
    end
    return n + (#sections - 1)
  end
  local function len_focused_only()
    local n = 0
    for _, s in ipairs(sections) do
      if s.number == focused then
        n = n + 4 + #tostring(s.number) + #s.name
      else
        n = n + 3  -- " N "
      end
    end
    return n + (#sections - 1)
  end

  local mode = "full"
  if available_width and available_width > 0 then
    if len_full() > available_width then
      mode = (len_focused_only() <= available_width) and "focused-only" or "compact"
    end
  end

  local parts = {}
  for _, s in ipairs(sections) do
    local text
    if s.number == focused then
      if mode == "compact" then
        text = string.format("%%#AutoFinderSectionActive#[%d]%%*", s.number)
      else
        text = string.format("%%#AutoFinderSectionActive#[%d: %s]%%*", s.number, s.name)
      end
    else
      if mode == "full" then
        text = string.format(" %d: %s ", s.number, s.name)
      else
        text = string.format(" %d ", s.number)
      end
    end
    table.insert(
      parts,
      string.format("%%%d@v:lua.require'auto-finder.panel.winbar'.click@%s%%X",
        s.number, text)
    )
  end
  return table.concat(parts, " ")
end

---Ensure default highlight links exist. Idempotent.
function M.ensure_highlights()
  if vim.fn.hlexists("AutoFinderSectionActive") == 0 then
    vim.api.nvim_set_hl(0, "AutoFinderSectionActive", { link = "Title", default = true })
  end
end

return M
