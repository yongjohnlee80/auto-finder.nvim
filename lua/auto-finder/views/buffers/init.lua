---auto-finder.views.buffers — the buffers slot (ADR-0200 §4.8).
---
---The listed buffers as a tree under the working directory, with the retired fork's look: an
---`OPEN BUFFERS in <cwd>` root row, directory groups whose single-directory chains are merged into one
---row (`src/util`), file rows with a ` #<bufnr>` suffix and a right-aligned diagnostic sign. Buffers outside
---the working directory group under their own absolute directory. Rows come from the files slot's
---renderer (views/files/render.lua), so both slots share one look by construction.
---
---Work happens only while the slot is shown: it repaints on `auto-finder.core.buffers:changed` and
---DiagnosticChanged, and both subscriptions are disposed when its buffer is hidden.
---@module 'auto-finder.views.buffers'

local render = require("auto-finder.views.files.render")

local M = {
  name = "buffers",
  description = "open buffers",
}

local S = { bufnr = nil, winid = nil, rows = nil, items = {}, shown = false, subs = nil, augroup = nil, timer = nil }
M._state = S

local SEV = { "Error", "Warn", "Info", "Hint" }

local function diag_by_buf()
  local out = {}
  for ns in pairs(vim.diagnostic.get_namespaces()) do
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.diagnostic.is_enabled({ bufnr = b, ns_id = ns }) then
        for sev = 1, 4 do
          if #vim.diagnostic.get(b, { namespace = ns, severity = sev }) > 0 then
            if not out[b] or sev < out[b] then out[b] = sev end
          end
        end
      end
    end
  end
  return out
end

---Visible items: root, then groups (directories) and buffers, sorted like the files tree.
function M.items()
  local cwd = vim.fn.getcwd()
  local tree = { children = {}, dirs = {} }
  local function dir_node(parent, name, path)
    local d = parent.dirs[name]
    if not d then
      d = { name = name, path = path, type = "directory", children = {}, dirs = {} }
      parent.dirs[name] = d
      table.insert(parent.children, d)
    end
    return d
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.bo[b].buflisted
        and (vim.bo[b].buftype == "" or vim.bo[b].buftype == "terminal") then
      local name = vim.api.nvim_buf_get_name(b)
      if name == "" then
        table.insert(tree.children, { name = "[No Name]", path = "", type = "file", bufnr = b })
      else
        local under = vim.startswith(name, cwd .. "/")
        local rel = under and name:sub(#cwd + 2) or name
        local segs = vim.split(rel, "/", { plain = true, trimempty = true })
        local parent, acc = tree, under and cwd or ""
        for i = 1, #segs - 1 do
          acc = acc .. "/" .. segs[i]
          parent = dir_node(parent, segs[i], acc)
        end
        table.insert(parent.children, { name = segs[#segs], path = name, type = "file", bufnr = b })
      end
    end
  end
  -- merge single-directory chains: a group whose only child is a group becomes "a/b"
  local function merge(node)
    for i, c in ipairs(node.children) do
      if c.type == "directory" then
        while #c.children == 1 and c.children[1].type == "directory" do
          local only = c.children[1]
          c = { name = c.name .. "/" .. only.name, path = only.path, type = "directory",
            children = only.children, dirs = only.dirs }
        end
        node.children[i] = c
        merge(c)
      end
    end
    table.sort(node.children, function(a, b)
      if a.type ~= b.type then return a.type < b.type end
      return (a.path ~= "" and a.path or a.name) < (b.path ~= "" and b.path or b.name)
    end)
  end
  merge(tree)
  local diag = diag_by_buf()
  local out = { { kind = "root", name = "OPEN BUFFERS in " .. vim.fn.fnamemodify(cwd, ":~"), depth = 0,
    is_last = true, continues = {} } }
  local function walk(node, depth, continues)
    for i, c in ipairs(node.children) do
      local last = i == #node.children
      local it = { kind = c.type, name = c.name, depth = depth, is_last = last, continues = continues,
        expanded = true, bufnr = c.bufnr, path = c.path }
      if c.bufnr and diag[c.bufnr] then it.diag = SEV[diag[c.bufnr]] end
      out[#out + 1] = it
      if c.type == "directory" then
        local nc = setmetatable({}, { __index = continues })
        nc[depth] = not last
        walk(c, depth + 1, nc)
      end
    end
  end
  walk(tree, 1, {})
  return out
end

function M.paint()
  if not (S.bufnr and vim.api.nvim_buf_is_valid(S.bufnr)) then return end
  local width = (S.winid and vim.api.nvim_win_is_valid(S.winid)) and vim.api.nvim_win_get_width(S.winid) or 38
  local items = M.items()
  local rows = {}
  for i, it in ipairs(items) do rows[i] = render.row(it, width) end
  render.paint(S.bufnr, S.rows, rows)
  S.rows, S.items = rows, items
  -- auto-expand, as the files slot does
  local af = require("auto-finder")
  if S.winid and vim.api.nvim_win_is_valid(S.winid) and not (af.state.user_width and af.state.user_width > 0) then
    local want = 0
    for _, r in ipairs(rows) do if r.width > want then want = r.width end end
    local c = af.state.config or {}
    local max = c.width and c.width.max or 100
    local info = vim.fn.getwininfo(S.winid)[1]
    want = math.min(want + (info and info.textoff or 0), max)
    if want > vim.api.nvim_win_get_width(S.winid) then
      pcall(vim.api.nvim_win_set_width, S.winid, want)
      local rows2 = {}
      for i, it in ipairs(items) do rows2[i] = render.row(it, vim.api.nvim_win_get_width(S.winid)) end
      render.paint(S.bufnr, S.rows, rows2)
      S.rows = rows2
    end
  end
end

local function schedule_paint()
  if not S.timer then S.timer = vim.uv.new_timer() end
  S.timer:stop()
  S.timer:start(50, 0, vim.schedule_wrap(function() if S.shown then M.paint() end end))
end

function M.suspend()
  S.shown = false
  if S.subs then pcall(function() S.subs:dispose_all() end) end
  if S.augroup then pcall(vim.api.nvim_del_augroup_by_id, S.augroup); S.augroup = nil end
  if S.timer then pcall(S.timer.stop, S.timer); pcall(S.timer.close, S.timer); S.timer = nil end
end

function M.resume(panel_winid)
  S.winid = panel_winid
  if not S.shown then
    S.shown = true
    S.subs = S.subs or require("auto-finder.shared.view_subs").new()
    S.subs:replace("buffers", "auto-finder.core.buffers:changed", schedule_paint)
    S.augroup = vim.api.nvim_create_augroup("auto-finder.buffers.view", { clear = true })
    vim.api.nvim_create_autocmd({ "DiagnosticChanged", "BufModifiedSet", "DirChanged" }, {
      group = S.augroup, callback = schedule_paint,
    })
  end
  M.paint()
end

local function buf_under_cursor()
  if not (S.winid and vim.api.nvim_win_is_valid(S.winid)) then return nil end
  local it = S.items[vim.api.nvim_win_get_cursor(S.winid)[1]]
  return it and it.bufnr and it
end

local function open(cmd)
  local it = buf_under_cursor()
  if not it then return end
  local target = require("auto-finder")._editor_target_winid()
  if target then
    pcall(vim.api.nvim_set_current_win, target)
    if cmd == "edit" then pcall(vim.api.nvim_win_set_buf, target, it.bufnr)
    else pcall(vim.cmd, cmd .. " | buffer " .. it.bufnr) end
  else
    pcall(vim.cmd, "rightbelow vsplit | buffer " .. it.bufnr)
  end
end

local function delete()
  local it = buf_under_cursor()
  if not it then return end
  local ok = pcall(vim.api.nvim_buf_delete, it.bufnr, {})
  if not ok then
    require("auto-finder.log").notify("buffer " .. it.bufnr .. " has unsaved changes",
      { level = "warn", component = "buffers" })
  end
  schedule_paint()
end

local function info()
  local it = buf_under_cursor()
  if not it or it.path == "" then return end
  require("auto-finder.views.files.actions").info({
    root = vim.fn.getcwd(), node = { path = it.path, name = it.name, type = "file" },
  }, nil)
end

local KEYS = {
  ["<cr>"] = { function() open("edit") end, "open buffer in editor" },
  ["<2-LeftMouse>"] = { function() open("edit") end, "open buffer in editor" },
  S = { function() open("split") end, "open buffer in a split" },
  s = { function() open("vsplit") end, "open buffer in a vertical split" },
  t = { function() open("tabnew") end, "open buffer in a new tab" },
  d = { delete, "delete buffer" },
  bd = { delete, "delete buffer" },
  i = { info, "file details" },
}

local function apply_keymaps(b)
  for lhs, m in pairs(KEYS) do
    vim.keymap.set("n", lhs, m[1], { buffer = b, silent = true, nowait = lhs ~= "b", desc = "auto-finder.buffers: " .. m[2] })
  end
  require("auto-finder.shared.help").install_help_keymap("buffers", b)
end

function M.get_buffer(panel_winid)
  require("auto-finder.panel.window_style").attach()
  if not (S.bufnr and vim.api.nvim_buf_is_valid(S.bufnr)) then
    local b = vim.api.nvim_create_buf(false, true)
    vim.bo[b].bufhidden = "hide"
    vim.bo[b].buftype = "nofile"
    vim.bo[b].swapfile = false
    vim.bo[b].modifiable = false
    vim.bo[b].filetype = "auto-finder"
    vim.b[b].auto_finder_view = "buffers"
    pcall(vim.api.nvim_buf_set_name, b, "auto-finder://buffers")
    vim.api.nvim_create_autocmd("BufHidden", { buffer = b, callback = function() M.suspend() end })
    S.bufnr, S.rows = b, nil
    apply_keymaps(b)
  end
  S.winid = panel_winid
  return S.bufnr
end

function M.on_focus(panel_winid, bufnr)
  if bufnr ~= S.bufnr then return end
  M.resume(panel_winid)
end

function M.on_close() M.suspend() end

function M._reset_for_tests()
  M.suspend()
  if S.bufnr and vim.api.nvim_buf_is_valid(S.bufnr) then pcall(vim.api.nvim_buf_delete, S.bufnr, { force = true }) end
  S.bufnr, S.winid, S.rows, S.items, S.subs = nil, nil, nil, {}, nil
end

return M
