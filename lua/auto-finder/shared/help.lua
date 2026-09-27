---auto-finder.shared.help — the `?` keymap overlay every view shares (ADR-0200 §4.9).
---
---Moved unchanged from the retired shared/neotree.lua, where it lived although it never depended on
---neo-tree: the overlay lists the view buffer's actual normal-mode mappings (nvim_buf_get_keymap), so it
---shows whatever the view and any consumer override wired, and prefers auto-core.ui.float.help_overlay,
---falling back to a plain float.
---
---Every view sets a `desc` on each mapping, so no entry renders blank (the fork left descriptions empty for
---mappings bound to Lua functions).
---@module 'auto-finder.shared.help'

local M = {}

---Collect `{ key, desc }` for every normal-mode mapping on `bufnr`, sorted by key.
---@param bufnr integer
---@return { key: string, desc: string }[]
function M.collect_keymaps(bufnr)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if type(m.lhs) == "string" and m.lhs ~= "" then
      local desc = m.desc
      if (desc == nil or desc == "") and type(m.rhs) == "string" then desc = m.rhs end
      out[#out + 1] = { key = m.lhs, desc = desc or "" }
    end
  end
  table.sort(out, function(a, b) return a.key < b.key end)
  return out
end

---Open the help overlay for `bufnr`.
---@param section_name string
---@param bufnr integer
function M.show_help(section_name, bufnr)
  local entries = M.collect_keymaps(bufnr)
  if #entries == 0 then
    require("auto-finder.log").notify("no keymaps found for '" .. section_name .. "'",
      { level = "info", component = "shared.help" })
    return
  end
  local widest = 0
  for _, e in ipairs(entries) do
    if #e.key > widest then widest = #e.key end
  end
  local lines = { ("auto-finder · %s · keymaps"):format(section_name), "" }
  for _, e in ipairs(entries) do
    lines[#lines + 1] = string.format(" %-" .. widest .. "s   %s", e.key, e.desc)
  end

  local ok, core = pcall(require, "auto-core")
  if ok and type(core) == "table" and type(core.ui) == "table" and type(core.ui.float) == "table"
      and type(core.ui.float.help_overlay) == "function" then
    pcall(core.ui.float.help_overlay, lines, { title = (" %s "):format(section_name) })
    return
  end

  local hbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(hbuf, 0, -1, false, lines)
  vim.bo[hbuf].modifiable = false
  vim.bo[hbuf].filetype = "auto-finder-help"
  local width = math.min(vim.o.columns - 4, 80)
  local height = math.min(vim.o.lines - 4, #lines + 2)
  local hwin = vim.api.nvim_open_win(hbuf, true, {
    relative = "editor", width = width, height = height,
    row = math.floor((vim.o.lines - height) / 2), col = math.floor((vim.o.columns - width) / 2),
    style = "minimal", border = "rounded", title = (" %s "):format(section_name),
  })
  for _, lhs in ipairs({ "q", "<esc>", "<cr>" }) do
    vim.keymap.set("n", lhs, function()
      if vim.api.nvim_win_is_valid(hwin) then vim.api.nvim_win_close(hwin, true) end
    end, { buffer = hbuf, nowait = true, silent = true })
  end
end

---Install the buffer-local `?` mapping. Idempotent.
---@param section_name string
---@param bufnr integer
function M.install_help_keymap(section_name, bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.keymap.set("n", "?", function() M.show_help(section_name, bufnr) end,
    { buffer = bufnr, nowait = true, silent = true, desc = "auto-finder: show section keymaps" })
end

return M
