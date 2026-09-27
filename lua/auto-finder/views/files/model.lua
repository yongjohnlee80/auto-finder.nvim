---auto-finder.views.files.model — the files slot's lazy tree (ADR-0200 §4.2).
---
---Nodes are keyed by absolute path. A directory's `children` exist only once it has been read, and it is
---read only when expanded (or revealed) — a collapsed directory is never read. Reads go through
---auto-core.fs.scan with `model.token` as the owner; every callback returns without touching the model
---unless `rawequal(token, model.token)` still holds, so a hide or a re-root makes in-flight work inert.
---@module 'auto-finder.views.files.model'

local M = {}

M.NEVER_SHOW = { ".git", "node_modules" }

---@class AutoFinderFilesNode
---@field path      string
---@field name      string
---@field type      "directory"|"file"
---@field is_link   boolean?
---@field parent    string?
---@field children  string[]?   -- sorted child paths; nil = never read
---@field expanded  boolean
---@field repo_root boolean?    -- held a `.git` entry (dir or gitfile) at its last read
---@field stale     boolean?    -- changed while collapsed; re-read on the next expand
---@field watch     boolean?    -- a core.watchers directory watch is held for it (expanded and shown)

---@class AutoFinderFilesModel
---@field root  string
---@field nodes table<string, AutoFinderFilesNode>
---@field token table?          -- fs.scan owner; nil while the pane is hidden
---@field never_show table<string, boolean>
---@field show_dotfiles boolean
---@field hidden table<string, boolean>?  -- paths the git read reports ignored, hidden when show_hidden=false

local function set_of(list)
  local s = {}
  for _, v in ipairs(list or {}) do s[v] = true end
  return s
end

---Sort parity with the retired fork (`sort_items`): directories before files, then byte order of the path.
local function sort_nodes(a, b)
  if a.type == b.type then return a.path < b.path end
  return a.type < b.type
end
M._sort_nodes = sort_nodes

---@param root string   absolute, normalized
---@param opts { never_show: string[]?, show_dotfiles: boolean? }?
---@return AutoFinderFilesModel
function M.new(root, opts)
  opts = opts or {}
  local model = {
    root = root,
    nodes = {},
    token = {},
    never_show = set_of(opts.never_show or M.NEVER_SHOW),
    show_dotfiles = opts.show_dotfiles ~= false,
  }
  model.nodes[root] = {
    path = root, name = vim.fn.fnamemodify(root, ":t"), type = "directory", expanded = true,
  }
  return model
end

local function visible_name(model, name)
  if model.never_show[name] then return false end
  if not model.show_dotfiles and name:sub(1, 1) == "." then return false end
  return true
end

---Merge a scan result into `dir`'s children. Existing child nodes (and their expansion) are kept; removed
---ones are dropped with their whole subtree. Returns true when the child list changed.
---@param model AutoFinderFilesModel
---@param res AutoCoreScanResult
---@return boolean changed
function M.apply_scan(model, res)
  local dir = model.nodes[res.path]
  if not dir then return false end
  local before = dir.children and table.concat(dir.children, "\0") or nil
  local kept, list = {}, {}
  dir.repo_root = false
  for _, e in ipairs(res.entries) do
    if e.name == ".git" then dir.repo_root = true end
    if visible_name(model, e.name) then
      local path = res.path .. "/" .. e.name
      local typ = e.type
      if typ == "link" then typ = e.target_type == "directory" and "directory" or "file" end
      if typ ~= "directory" then typ = "file" end
      local node = model.nodes[path]
      if not node or node.type ~= typ then
        if node then M.forget(model, path) end
        node = { path = path, name = e.name, type = typ, parent = res.path, expanded = false,
          is_link = e.type == "link" }
        model.nodes[path] = node
      end
      kept[path] = true
      list[#list + 1] = node
    end
  end
  for _, old in ipairs(dir.children or {}) do
    if not kept[old] then M.forget(model, old) end
  end
  table.sort(list, sort_nodes)
  local children = {}
  for i, n in ipairs(list) do children[i] = n.path end
  dir.children = children
  dir.stale = nil
  return before ~= table.concat(children, "\0")
end

-- The core.watchers owner the files view registers directory watches under.
M.WATCH_OWNER = "views.files"

---Drop `path` and everything under it, releasing any directory watch it held.
function M.forget(model, path)
  local node = model.nodes[path]
  if not node then return end
  for _, c in ipairs(node.children or {}) do M.forget(model, c) end
  if node.watch then
    require("auto-finder.core.watchers").unwatch_dir(node.path, M.WATCH_OWNER)
    node.watch = nil
  end
  model.nodes[path] = nil
end

---Read `path` through fs.scan and apply it, unless the model's token moved on meanwhile.
---@param model AutoFinderFilesModel
---@param path string
---@param fresh boolean
---@param cb fun(changed: boolean)?
function M.read(model, path, fresh, cb)
  local token = model.token
  if not token then return end
  require("auto-core.fs.scan").read_dir(path, token, { fresh = fresh }, function(res)
    if not rawequal(token, model.token) then return end
    local changed = res.err == nil and M.apply_scan(model, res) or false
    if cb then cb(changed) end
  end)
end

---Expand `path`, reading it first if it was never read or went stale while collapsed.
function M.expand(model, path, cb)
  local node = model.nodes[path]
  if not node or node.type ~= "directory" then return end
  node.expanded = true
  if node.children == nil or node.stale then
    M.read(model, path, node.stale == true, function() if cb then cb(true) end end)
  elseif cb then
    cb(false)
  end
end

function M.collapse(model, path)
  local node = model.nodes[path]
  if node and node.type == "directory" and path ~= model.root then node.expanded = false end
end

---Expand every ancestor of `path` below the root, root-down, one read each; `cb(found)` once it is known
---whether `path` is in the tree.
function M.reveal(model, path, cb)
  if path:sub(1, #model.root + 1) ~= model.root .. "/" then
    if cb then cb(false) end
    return
  end
  local rel = path:sub(#model.root + 2)
  local segs = vim.split(rel, "/", { plain = true })
  local i = 0
  local function step()
    i = i + 1
    if i >= #segs then
      if cb then cb(model.nodes[path] ~= nil) end
      return
    end
    local dir = model.root .. "/" .. table.concat(segs, "/", 1, i)
    local node = model.nodes[dir]
    if not node or node.type ~= "directory" then
      if cb then cb(false) end
      return
    end
    M.expand(model, dir, function() step() end)
  end
  -- the root's children must exist before the first segment can be found
  local root = model.nodes[model.root]
  if root.children == nil then
    M.read(model, model.root, false, function() step() end)
  else
    step()
  end
end

---Visible rows, depth-first over expanded directories. Examines only the expanded chain.
---@return { node: AutoFinderFilesNode, depth: integer, is_last: boolean, continues: boolean[] }[]
function M.visible(model)
  local out = {}
  local root = model.nodes[model.root]
  out[1] = { node = root, depth = 0, is_last = true, continues = {} }
  local function walk(dir, depth, continues)
    local kids = dir.children
    if not kids then return end
    local shown = {}
    for _, p in ipairs(kids) do
      local n = model.nodes[p]
      if n and not (model.hidden and model.hidden[p]) then shown[#shown + 1] = n end
    end
    for i, n in ipairs(shown) do
      local last = i == #shown
      out[#out + 1] = { node = n, depth = depth, is_last = last, continues = continues }
      if n.type == "directory" and n.expanded then
        local next_cont = setmetatable({}, { __index = continues })
        next_cont[depth] = not last
        walk(n, depth + 1, next_cont)
      end
    end
  end
  walk(root, 1, {})
  return out
end

---Paths of every expanded directory (the root included), for show-time re-reads and watch arming.
function M.expanded_dirs(model)
  local out = {}
  local function walk(path)
    local n = model.nodes[path]
    if not (n and n.type == "directory" and n.expanded) then return end
    out[#out + 1] = path
    for _, c in ipairs(n.children or {}) do walk(c) end
  end
  walk(model.root)
  return out
end

return M
