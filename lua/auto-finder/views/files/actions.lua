---auto-finder.views.files.actions — the files slot's file operations (ADR-0200 §4.7).
---
---Kept from the retired fork, with its semantics: add (a trailing "/" makes a directory, missing parents
---are created), add directory, delete (confirmed; refuses the root; wipes the deleted files' buffers),
---rename and move (open buffers follow the file, a modified one is offered a save under the new name; a
---directory cannot move into itself), copy/cut marks and paste into the directory under the cursor
---(re-prompting on a name clash), and the `i` details float.
---
---Every operation is user-initiated and touches one path, so the libuv calls here are synchronous. Callers
---re-read the affected directories through the model afterwards (never the root).
---@module 'auto-finder.views.files.actions'

local M = {}

local uv = vim.uv

local function notify(msg, level)
  require("auto-finder.log").notify(msg, { level = level or "info", component = "files.actions" })
end

local function exists(p) return uv.fs_lstat(p) ~= nil end

local function mkdir_p(dir)
  if exists(dir) then return true end
  local parent = vim.fs.dirname(dir)
  if parent and parent ~= dir and not exists(parent) then
    local ok, err = mkdir_p(parent)
    if not ok then return false, err end
  end
  local ok, err = uv.fs_mkdir(dir, 493) -- 0755
  if not ok and not exists(dir) then return false, err end
  return true
end

local function is_under(path, dir) return path == dir or path:sub(1, #dir + 1) == dir .. "/" end

---Buffers showing `old` (or a file under it, when `old` is a directory) follow it to `new`. A modified
---buffer keeps its lines and is offered a save under the new name, as the fork did.
local function rename_buffers(old, new)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      local target
      if name == old then target = new
      elseif is_under(name, old) then target = new .. name:sub(#old + 1) end
      if target then
        local nb = vim.fn.bufadd(target)
        vim.fn.bufload(nb)
        vim.bo[nb].buflisted = true
        for _, w in ipairs(vim.fn.win_findbuf(buf)) do
          pcall(vim.api.nvim_win_set_buf, w, nb)
        end
        if vim.bo[buf].buftype == "" and vim.bo[buf].modified then
          vim.api.nvim_buf_set_lines(nb, 0, -1, false, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
          local choice = vim.fn.confirm(name .. " has been modified. Save under new name?", "&Yes\n&No", 2)
          if choice == 1 then vim.api.nvim_buf_call(nb, function() vim.cmd("silent! write!") end) end
        end
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end
end

---Wipe buffers of `path` (and of files under it), moving their windows to an alternate buffer first.
local function wipe_buffers(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and is_under(vim.api.nvim_buf_get_name(buf), path) then
      for _, w in ipairs(vim.fn.win_findbuf(buf)) do
        pcall(vim.api.nvim_win_call, w, function() vim.cmd("silent! bprevious") end)
        if vim.api.nvim_win_get_buf(w) == buf then
          pcall(vim.api.nvim_win_set_buf, w, vim.api.nvim_create_buf(true, false))
        end
      end
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

local function copy_tree(src, dst)
  local st = uv.fs_lstat(src)
  if not st then return false, "missing " .. src end
  if st.type == "directory" then
    local ok, err = mkdir_p(dst)
    if not ok then return false, err end
    for name in vim.fs.dir(src) do
      local ok2, err2 = copy_tree(src .. "/" .. name, dst .. "/" .. name)
      if not ok2 then return false, err2 end
    end
    return true
  elseif st.type == "link" then
    return uv.fs_symlink(uv.fs_readlink(src), dst)
  end
  return uv.fs_copyfile(src, dst)
end

local function move_path(src, dst)
  local ok, err = uv.fs_rename(src, dst)
  if ok then return true end
  if tostring(err):match("EXDEV") then -- across filesystems: copy, then remove
    local okc, errc = copy_tree(src, dst)
    if not okc then return false, errc end
    vim.fs.rm(src, { recursive = true, force = true })
    return true
  end
  return false, err
end

---Ask for a free name inside `dir`, starting from `name` (re-prompts while the name is taken).
local function free_name(dir, name, prompt, cb)
  if not exists(dir .. "/" .. name) then return cb(name) end
  vim.ui.input({ prompt = prompt .. " (exists) ", default = name }, function(input)
    if not input or input == "" then return end
    free_name(dir, input, prompt, cb)
  end)
end

---@class AutoFinderFilesActionCtx
---@field root string
---@field node AutoFinderFilesNode           -- node under the cursor
---@field dir string                         -- directory an add/paste targets (the node, or its parent)
---@field done fun(dirs: string[], focus: string?)  -- re-read these dirs, then put the cursor on `focus`

---`a`: add a file, or a directory when the input ends with "/".
function M.add(ctx)
  vim.ui.input({ prompt = "Enter name for new file or directory (dirs end with a \"/\"): " }, function(input)
    if not input or input == "" then return end
    local target = input:sub(1, 1) == "/" and input or (ctx.dir .. "/" .. input)
    local is_dir = target:sub(-1) == "/"
    target = target:gsub("/+$", "")
    if exists(target) then return notify("already exists: " .. target, "warn") end
    local ok, err = mkdir_p(is_dir and target or vim.fs.dirname(target))
    if ok and not is_dir then
      local fd
      fd, err = uv.fs_open(target, "w", 420) -- 0644
      ok = fd ~= nil
      if fd then uv.fs_close(fd) end
    end
    if not ok then return notify("could not create " .. target .. ": " .. tostring(err), "error") end
    ctx.done({ vim.fs.dirname(target) }, target)
  end)
end

---`A`: add a directory.
function M.add_directory(ctx)
  vim.ui.input({ prompt = "Enter name for new directory: " }, function(input)
    if not input or input == "" then return end
    local target = (input:sub(1, 1) == "/" and input or (ctx.dir .. "/" .. input)):gsub("/+$", "")
    if exists(target) then return notify("already exists: " .. target, "warn") end
    local ok, err = mkdir_p(target)
    if not ok then return notify("could not create " .. target .. ": " .. tostring(err), "error") end
    ctx.done({ vim.fs.dirname(target) }, target)
  end)
end

---`d`: delete, after an irreversible confirm. The root cannot be deleted.
function M.delete(ctx)
  local p = ctx.node.path
  if p == ctx.root then return notify("Cannot delete the root directory", "warn") end
  local body = { p }
  if ctx.node.type == "directory" then
    local has = false
    for _ in vim.fs.dir(p) do has = true; break end
    if has then body[#body + 1] = "WARNING: the directory is not empty." end
  end
  require("auto-core.ui.modal").open({
    title = "Delete " .. vim.fn.fnamemodify(p, ":t") .. "?",
    body = body,
    reversibility = "irreversible",
    items = {
      { label = "No, keep it", value = false, role = "cancel" },
      { label = "Yes, delete", value = true, role = "confirm", mnemonic = "y" },
    },
    on_choice = function(yes)
      if not yes then return end
      local ok, err = pcall(vim.fs.rm, p, { recursive = true, force = true })
      if not ok or exists(p) then return notify("could not delete " .. p .. ": " .. tostring(err), "error") end
      wipe_buffers(p)
      ctx.done({ vim.fs.dirname(p) }, nil)
    end,
  })
end

---`r`: rename in place.
function M.rename(ctx)
  local p = ctx.node.path
  if p == ctx.root then return notify("Cannot rename the root directory", "warn") end
  local dir, name = vim.fs.dirname(p), vim.fn.fnamemodify(p, ":t")
  vim.ui.input({ prompt = "Enter new name: ", default = name }, function(input)
    if not input or input == "" or input == name then return end
    local target = dir .. "/" .. input
    -- a case-only rename on a case-insensitive filesystem reports the target as existing
    if exists(target) and target:lower() ~= p:lower() then return notify("already exists: " .. target, "warn") end
    local ok, err = uv.fs_rename(p, target)
    if not ok then return notify("could not rename: " .. tostring(err), "error") end
    rename_buffers(p, target)
    ctx.done({ dir }, target)
  end)
end

---`m`: move to a new path (relative paths resolve against the root).
function M.move(ctx)
  local p = ctx.node.path
  if p == ctx.root then return notify("Cannot move the root directory", "warn") end
  local rel = p:sub(#ctx.root + 2)
  vim.ui.input({ prompt = "Move to: ", default = rel, completion = "file" }, function(input)
    if not input or input == "" or input == rel then return end
    local target = (input:sub(1, 1) == "/" and input or (ctx.root .. "/" .. input)):gsub("/+$", "")
    if is_under(target, p) then return notify("Cannot move a directory into itself", "warn") end
    if exists(target) then return notify("already exists: " .. target, "warn") end
    local ok, err = mkdir_p(vim.fs.dirname(target))
    if ok then ok, err = move_path(p, target) end
    if not ok then return notify("could not move: " .. tostring(err), "error") end
    rename_buffers(p, target)
    ctx.done({ vim.fs.dirname(p), vim.fs.dirname(target) }, target)
  end)
end

---`p`: paste every marked item into `ctx.dir`, one at a time; clears the marks.
---@param marks table<string, "copy"|"cut">
function M.paste(ctx, marks)
  local items = {}
  for path, op in pairs(marks) do items[#items + 1] = { path = path, op = op } end
  table.sort(items, function(a, b) return a.path < b.path end)
  local touched = { [ctx.dir] = true }
  local i = 0
  local function step()
    i = i + 1
    local it = items[i]
    if not it then
      for k in pairs(marks) do marks[k] = nil end
      local dirs = {}
      for d in pairs(touched) do dirs[#dirs + 1] = d end
      return ctx.done(dirs, nil)
    end
    if it.op == "cut" and is_under(ctx.dir, it.path) then
      notify("Cannot move a directory into itself: " .. it.path, "warn")
      return step()
    end
    free_name(ctx.dir, vim.fn.fnamemodify(it.path, ":t"), "Paste as", function(name)
      local target = ctx.dir .. "/" .. name
      local ok, err
      if it.op == "cut" then
        ok, err = move_path(it.path, target)
        if ok then rename_buffers(it.path, target); touched[vim.fs.dirname(it.path)] = true end
      else
        ok, err = copy_tree(it.path, target)
      end
      if not ok then notify("could not paste " .. it.path .. ": " .. tostring(err), "error") end
      step()
    end)
  end
  step()
end

local function human_size(n)
  local units = { "B", "KB", "MB", "GB", "TB" }
  local i = 1
  while n >= 1024 and i < #units do n = n / 1024; i = i + 1 end
  if i == 1 then return string.format("%d %s", n, units[i]) end
  return string.format("%.2f %s", n, units[i])
end

---`i`: the details float (Name, Path, Type, Size, Created, Modified, Git code).
---@param git_code string?  raw status of the node, when the git read has one
function M.info(ctx, git_code)
  local node = ctx.node
  local st = uv.fs_stat(node.path)
  local rows = { { "Name", node.name }, { "Path", node.path }, { "Type", node.type } }
  if st and st.size then
    local fmt = "%Y-%m-%d %I:%M %p"
    rows[#rows + 1] = { "Size", human_size(st.size) }
    rows[#rows + 1] = { "Created", os.date(fmt, (st.birthtime and st.birthtime.sec) or st.ctime.sec) }
    rows[#rows + 1] = { "Modified", os.date(fmt, st.mtime.sec) }
  end
  if git_code then rows[#rows + 1] = { "Git code", git_code } end
  local lines = {}
  for _, r in ipairs(rows) do lines[#lines + 1] = string.format("%9s: %s", r[1], r[2]) end
  local ok, core = pcall(require, "auto-core")
  if ok and core.ui and core.ui.float and type(core.ui.float.help_overlay) == "function" then
    pcall(core.ui.float.help_overlay, lines, { title = " File Details " })
  else
    notify(table.concat(lines, "\n"))
  end
  return lines
end

return M
