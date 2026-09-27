---auto-finder.views.buffers — the buffers slot (ADR-0200 §4.8).
---
---The listed buffers as a tree under the working directory, with the retired fork's look: an
---`OPEN BUFFERS in <cwd>` root row, directory groups whose single-directory chains are merged into one
---row (`src/util`), file rows with a ` #<bufnr>` suffix and a right-aligned diagnostic sign. Terminals
---under the working directory get a `TERMINALS` root, and buffers outside it are grouped under one
---`OPEN BUFFERS in <bucket>` root per external bucket (~/<first>, else /<first>). Rows come from the
---files slot's renderer (views/files/render.lua), so both slots share one look by construction.
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

-- The core topic the view repaints from while shown (ADR 0026 Phase 6).
M._core_refresh_topic = "auto-finder.core.buffers:changed"

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

-- Out-of-cwd buffers are grouped under their "natural external root", as the retired fork's buffers
-- source did (v0.2.14): the first path segment after $HOME (~/.config, ~/Documents), else the first
-- absolute segment (/tmp, /etc). Each bucket is its own root row.
local function bucket_for_external(path)
  local home = vim.fn.expand("~")
  if vim.startswith(path, home .. "/") then
    local first = path:sub(#home + 2):match("^([^/]+)")
    if first then return home .. "/" .. first end
  end
  local first = path:match("^/([^/]+)")
  if first then return "/" .. first end
  return nil
end

local function new_group(name, path)
  return { name = name, path = path, type = "directory", children = {}, dirs = {} }
end

local function add_under(root, rel, leaf)
  local segs = vim.split(rel, "/", { plain = true, trimempty = true })
  local parent, acc = root, root.path
  for i = 1, #segs - 1 do
    acc = acc .. "/" .. segs[i]
    local d = parent.dirs[segs[i]]
    if not d then
      d = new_group(segs[i], acc)
      parent.dirs[segs[i]] = d
      table.insert(parent.children, d)
    end
    parent = d
  end
  leaf.name = leaf.name or segs[#segs]
  table.insert(parent.children, leaf)
end

-- group_empty_dirs: a group whose only child is a group becomes one "a/b" row; dirs first, then by path.
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

---Visible items: the cwd root, a TERMINALS root (terminals under cwd), then one root per external
---bucket — each followed by its groups and buffers.
function M.items()
  local cwd = vim.fn.getcwd()
  local cwd_root = new_group(vim.fn.fnamemodify(cwd, ":~"), cwd)
  local terminals = {}
  local buckets = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.bo[b].buflisted then
      local name = vim.api.nvim_buf_get_name(b)
      if vim.startswith(name, "term://") then
        local dir = vim.fn.fnamemodify(name:match("term://(.*)//.*") or "", ":p")
        if vim.startswith(dir, cwd .. "/") or dir == cwd or dir == cwd .. "/" then
          local ok_t, title = pcall(vim.api.nvim_buf_get_var, b, "term_title")
          table.insert(terminals, { name = ok_t and title or dir, path = name, type = "file", bufnr = b,
            terminal = true })
        end
      elseif vim.bo[b].buftype == "" then
        if name == "" then
          table.insert(cwd_root.children, { name = "[No Name]", path = "", type = "file", bufnr = b })
        elseif vim.startswith(name, cwd .. "/") then
          add_under(cwd_root, name:sub(#cwd + 2), { path = name, type = "file", bufnr = b })
        else
          local bucket = bucket_for_external(name)
          if bucket then
            buckets[bucket] = buckets[bucket] or new_group(vim.fn.fnamemodify(bucket, ":~"), bucket)
            add_under(buckets[bucket], name:sub(#bucket + 2), { path = name, type = "file", bufnr = b })
          end
        end
      end
    end
  end
  local roots = { { node = cwd_root, label = "OPEN BUFFERS in " .. cwd_root.name } }
  if #terminals > 0 then
    roots[#roots + 1] = { node = { children = terminals, dirs = {} }, label = "TERMINALS", terminal = true }
  end
  local keys = vim.tbl_keys(buckets)
  table.sort(keys)
  for _, k in ipairs(keys) do
    roots[#roots + 1] = { node = buckets[k], label = "OPEN BUFFERS in " .. buckets[k].name }
  end

  local diag = diag_by_buf()
  local out = {}
  local function walk(node, depth, continues)
    for i, c in ipairs(node.children) do
      local last = i == #node.children
      local it = { kind = c.type, name = c.name, depth = depth, is_last = last, continues = continues,
        expanded = true, bufnr = c.bufnr, path = c.path, name_hl = "AutoFinderFileName" }
      if c.type == "directory" then it.name_hl = "AutoFinderDirectoryName" end
      if c.terminal then it.icon_name = "terminal" end
      if c.bufnr and diag[c.bufnr] then it.diag = SEV[diag[c.bufnr]] end
      out[#out + 1] = it
      if c.type == "directory" then
        local nc = setmetatable({}, { __index = continues })
        nc[depth] = not last
        walk(c, depth + 1, nc)
      end
    end
  end
  for _, r in ipairs(roots) do
    local root_item = { kind = "root", name = r.label, depth = 0, is_last = true, continues = {} }
    if r.terminal then
      local d = select(2, pcall(require, "nvim-web-devicons"))
      local glyph, hl
      if type(d) == "table" then glyph, hl = d.get_icon("terminal") end
      root_item.icon = { glyph or "*", hl or "AutoFinderFileIcon" }
    else
      merge(r.node)
    end
    out[#out + 1] = root_item
    walk(r.node, 1, {})
  end
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
  -- replace semantics: every focus re-arms what an auto-core bus reset dropped (v0.2.25 B1)
  S.subs = S.subs or require("auto-finder.shared.view_subs").new()
  S.subs:replace("buffers", M._core_refresh_topic, schedule_paint)
  if not S.shown then
    S.shown = true
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

---Repaint now when shown (the view registry's public refresh entry).
function M.refresh() if S.shown then M.paint() end end

function M._reset_for_tests()
  M.suspend()
  if S.bufnr and vim.api.nvim_buf_is_valid(S.bufnr) then pcall(vim.api.nvim_buf_delete, S.bufnr, { force = true }) end
  S.bufnr, S.winid, S.rows, S.items, S.subs = nil, nil, nil, {}, nil
end

return M
