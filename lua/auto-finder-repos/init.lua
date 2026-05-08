---auto-finder-repos — neo-tree source rendering auto-discovered git
---repos and their worktrees as a tree. Originally contributed by
---Bryan Cua as `neo-tree-workspace` in the autovim consumer; ported
---into auto-finder for the v0.1.2 repos section (slot 2).
---
---Discovery is delegated to worktree.nvim — `auto-finder.repos`
---queries `worktree.list_child_repos(worktree.get_root())` so the
---panel and worktree.nvim's own pick/home commands always agree on
---what counts as a repo and where the active root is.
---
---Top level: each discovered repo becomes a workspace node.
---Children: each worktree the repo exposes (`base` = main worktree,
---others labeled by their on-disk basename + branch name). Below
---that: ordinary directories, lazy-loaded via `vim.uv.fs_scandir`
---when expanded.
---
---Auto-refresh: a `vim.uv.fs_event` watcher on each repo's
---`<gitdir>/worktrees/` directory fires a debounced re-render so the
---tree picks up worktrees added/removed externally. Press `R` in
---the panel to force a full refresh (re-runs discovery via
---worktree.nvim).
---@module 'auto-finder-repos'

local renderer = require("neo-tree.ui.renderer")

local M = {
  name = "auto-finder-repos",
  display_name = " Repos ",
}

local uv = vim.uv or vim.loop

---Resolve the consumer-configured bare-dir name. Falls back to
---`.bare` (worktree.nvim's default) when setup() hasn't run yet.
---@return string
local function bare_dir_name()
  local ok, af = pcall(require, "auto-finder")
  if ok and af.state and af.state.config and af.state.config.git
      and type(af.state.config.git.bare_dir) == "string"
      and af.state.config.git.bare_dir ~= "" then
    return af.state.config.git.bare_dir
  end
  return ".bare"
end

---Run `git worktree list --porcelain` against a repo path, with a
---fallback that explicitly targets the configured bare dir for setups
---where `git -C <path>` doesn't resolve the bare repo on its own.
---@param repo_path string
---@return string[] lines
local function git_worktree_list(repo_path)
  local out = vim.fn.systemlist({
    "git", "-C", repo_path, "worktree", "list", "--porcelain",
  })
  if vim.v.shell_error == 0 then return out end
  -- Try the configured bare dir, then the legacy hard-coded `.git`
  -- bare-layout fallback for repos cloned with `git clone --bare …
  -- .git` (the consumer's existing convention).
  for _, candidate in ipairs({ bare_dir_name(), ".git" }) do
    if vim.fn.isdirectory(repo_path .. "/" .. candidate) == 1 then
      out = vim.fn.systemlist({
        "git", "--git-dir=" .. repo_path .. "/" .. candidate, "worktree", "list", "--porcelain",
      })
      if vim.v.shell_error == 0 then return out end
    end
  end
  return {}
end

---Parse `git worktree list --porcelain` output.
---@param repo_path string
---@return table[]  -- { {path, branch, detached, bare}, ... }
local function list_worktrees(repo_path)
  local out = git_worktree_list(repo_path)
  if #out == 0 then return {} end
  local trees, current = {}, nil
  local function flush()
    if current then table.insert(trees, current); current = nil end
  end
  for _, line in ipairs(out) do
    if line:sub(1, 9) == "worktree " then
      flush()
      current = { path = line:sub(10) }
    elseif line == "" then
      flush()
    elseif current and line:sub(1, 7) == "branch " then
      current.branch = line:sub(8):gsub("^refs/heads/", "")
    elseif current and line == "detached" then
      current.detached = true
    elseif current and line == "bare" then
      current.bare = true
    end
  end
  flush()
  return trees
end

---Per-worktree git-status cache, cleared every navigate().
local git_status_cache = {}

local function load_git_status(worktree_path)
  if git_status_cache[worktree_path] then
    return git_status_cache[worktree_path]
  end
  local statuses = {}
  local out = vim.fn.systemlist({
    "git", "-C", worktree_path, "status", "--porcelain",
  })
  if vim.v.shell_error == 0 then
    for _, line in ipairs(out) do
      if #line > 3 then
        local status = line:sub(1, 2)
        local file = line:sub(4)
        local arrow = file:find(" %-> ", 1, false)
        if arrow then file = file:sub(arrow + 4) end
        if file:sub(1, 1) == '"' and file:sub(-1) == '"' then
          file = file:sub(2, -2)
        end
        statuses[worktree_path .. "/" .. file] = status
      end
    end
  end
  git_status_cache[worktree_path] = statuses
  return statuses
end

local function git_status_for(worktree_path, abs_path, is_dir)
  if not worktree_path then return nil end
  local statuses = load_git_status(worktree_path)
  if not is_dir then return statuses[abs_path] end
  local prefix = abs_path .. "/"
  local plen = #prefix
  for file in pairs(statuses) do
    if file:sub(1, plen) == prefix then return "  " end
  end
  return nil
end

local function scan_dir(path, worktree_path)
  local items = {}
  local handle = uv.fs_scandir(path)
  if not handle then return items end
  while true do
    local name, entry_type = uv.fs_scandir_next(handle)
    if not name then break end
    local full = path .. "/" .. name
    if entry_type == "link" then
      local stat = uv.fs_stat(full)
      entry_type = stat and stat.type or "file"
    end
    local is_dir = entry_type == "directory"
    local item = {
      id = full,
      name = name,
      type = is_dir and "directory" or "file",
      path = full,
      extra = {
        worktree_path = worktree_path,
        git_status = git_status_for(worktree_path, full, is_dir),
      },
    }
    if is_dir then
      item.loaded = false
      item.children = {}
    end
    table.insert(items, item)
  end
  table.sort(items, function(a, b)
    if (a.type == "directory") ~= (b.type == "directory") then
      return a.type == "directory"
    end
    return a.name:lower() < b.name:lower()
  end)
  return items
end

---Build the worktree-level children for a single repo. Main worktree
---renders as `base`; linked worktrees keep their on-disk basename.
local function build_worktree_nodes(repo_path)
  local nodes = {}
  for _, wt in ipairs(list_worktrees(repo_path)) do
    if not wt.bare then
      local basename = (wt.path == repo_path) and "base" or vim.fn.fnamemodify(wt.path, ":t")
      local label = basename
      if wt.branch then
        label = basename .. "  (" .. wt.branch .. ")"
      elseif wt.detached then
        label = basename .. "  (detached)"
      end
      table.insert(nodes, {
        id = wt.path,
        name = label,
        type = "directory",
        path = wt.path,
        loaded = false,
        children = {},
        extra = { is_worktree = true, branch = wt.branch },
      })
    end
  end
  table.sort(nodes, function(a, b)
    -- `base` first, then alphabetical by display name.
    if a.path == nil or b.path == nil then return false end
    local an, bn = a.name, b.name
    if an:sub(1, 4) == "base" and bn:sub(1, 4) ~= "base" then return true end
    if bn:sub(1, 4) == "base" and an:sub(1, 4) ~= "base" then return false end
    return an:lower() < bn:lower()
  end)
  return nodes
end

local function build_workspace_nodes()
  local repos = require("auto-finder.repos").load()
  local nodes = {}
  -- De-dupe display names: two repos with the same basename get -2, -3, …
  local taken = {}
  local function unique(name)
    if not taken[name] then taken[name] = true; return name end
    local i = 2
    while taken[name .. "-" .. i] do i = i + 1 end
    local n = name .. "-" .. i
    taken[n] = true
    return n
  end
  for _, repo in ipairs(repos) do
    local path = vim.fn.expand(repo)
    local name = unique(vim.fn.fnamemodify(path, ":t"))
    table.insert(nodes, {
      id = "auto-finder-repos://" .. path,
      name = name,
      type = "directory",
      path = path,
      loaded = true,
      children = build_worktree_nodes(path),
      extra = { is_workspace = true },
    })
  end
  -- Empty-state placeholder so the panel doesn't render as a blank
  -- void when no repos were discovered. Uses neo-tree's built-in
  -- `type = "message"` renderer (NeoTreeMessage highlight).
  if #nodes == 0 then
    local hint
    local ok_root, root = pcall(function()
      return require("auto-finder.repos").root()
    end)
    if not ok_root or not root then
      hint = "worktree.nvim not installed or no root configured"
    else
      hint = "no repos under " .. root
    end
    table.insert(nodes, {
      id = "auto-finder-repos://__empty__",
      name = "(" .. hint .. ")",
      type = "message",
      path = "",
      extra = { is_placeholder = true },
    })
  end
  return nodes
end

-- Filesystem watchers: one per registered repo's <gitdir>/worktrees dir.
local watchers = {} -- [path] = uv handle
local debounce_timer

local function git_common_dir(repo)
  local out = vim.fn.systemlist({ "git", "-C", repo, "rev-parse", "--git-common-dir" })
  if vim.v.shell_error ~= 0 or not out[1] or out[1] == "" then
    -- Same fallback as list_worktrees: try the configured bare dir,
    -- then `.git`. Lets the watchers function for repos where
    -- `git -C <path>` can't resolve the gitdir on its own.
    for _, candidate in ipairs({ bare_dir_name(), ".git" }) do
      if vim.fn.isdirectory(repo .. "/" .. candidate) == 1 then
        out = vim.fn.systemlist({
          "git", "--git-dir=" .. repo .. "/" .. candidate, "rev-parse", "--git-common-dir",
        })
        if vim.v.shell_error == 0 and out[1] and out[1] ~= "" then break end
      end
    end
    if vim.v.shell_error ~= 0 or not out[1] or out[1] == "" then return nil end
  end
  local p = out[1]
  if p:sub(1, 1) ~= "/" then p = repo .. "/" .. p end
  return vim.fn.fnamemodify(p, ":p"):gsub("/$", "")
end

local function refresh_open_window()
  local mgr_ok, manager = pcall(require, "neo-tree.sources.manager")
  if not mgr_ok then return end
  local state = manager.get_state and manager.get_state(M.name)
  if state and state.winid and vim.api.nvim_win_is_valid(state.winid) then
    M.navigate(state)
  end
end

local function debounced_refresh()
  if debounce_timer then debounce_timer:stop(); debounce_timer:close() end
  debounce_timer = uv.new_timer()
  debounce_timer:start(150, 0, vim.schedule_wrap(function()
    if debounce_timer then debounce_timer:close(); debounce_timer = nil end
    refresh_open_window()
  end))
end

local function stop_watchers()
  for path, h in pairs(watchers) do
    if h and not h:is_closing() then h:stop(); h:close() end
    watchers[path] = nil
  end
end

local function start_watchers()
  stop_watchers()
  for _, repo in ipairs(require("auto-finder.repos").load()) do
    local gitdir = git_common_dir(repo)
    if gitdir then
      local wt_dir = gitdir .. "/worktrees"
      if vim.fn.isdirectory(wt_dir) == 0 then vim.fn.mkdir(wt_dir, "p") end
      local h = uv.new_fs_event()
      local ok = pcall(function()
        h:start(wt_dir, {}, function(err)
          if err then return end
          debounced_refresh()
        end)
      end)
      if ok then watchers[wt_dir] = h end
    end
  end
end

---Called by neo-tree to populate the tree.
M.navigate = function(state, _, _, callback, _)
  state.path = "auto-finder-repos://"
  git_status_cache = {}
  local items = build_workspace_nodes()
  state.default_expanded_nodes = state.force_open_folders or {}
  for _, n in ipairs(items) do
    table.insert(state.default_expanded_nodes, n.id)
  end
  renderer.show_nodes(items, state)
  start_watchers()
  if type(callback) == "function" then
    vim.schedule(callback)
  end
end

---Lazy-load directory children when the user expands a directory.
M.toggle_directory = function(state, node, path_to_reveal, skip_redraw, _, callback)
  local tree = state.tree
  if not node then node = assert(tree:get_node()) end
  if node.type ~= "directory" then return end
  state.explicitly_opened_nodes = state.explicitly_opened_nodes or {}
  local id = node:get_id()
  if node.loaded == false then
    state.explicitly_opened_nodes[id] = true
    local extra = node.extra or {}
    local wt = extra.is_worktree and node.path or extra.worktree_path
    local children = scan_dir(node.path, wt)
    node.loaded = true
    renderer.show_nodes(children, state, id, callback)
  elseif node:has_children() then
    local updated
    if node:is_expanded() then
      updated = node:collapse()
      state.explicitly_opened_nodes[id] = false
    else
      updated = node:expand()
      state.explicitly_opened_nodes[id] = true
    end
    if updated and not skip_redraw then renderer.redraw(state) end
    if path_to_reveal then renderer.focus_node(state, path_to_reveal) end
  end
  if type(callback) == "function" then callback() end
end

M.default_config = {
  window = {
    mappings = {
      ["<cr>"] = "open",
      ["<2-LeftMouse>"] = "open",
      ["o"] = "open",
      ["s"] = "open_split",
      ["v"] = "open_vsplit",
      ["t"] = "open_tabnew",
      ["C"] = "close_node",
      ["z"] = "close_all_nodes",
      ["R"] = "refresh",
    },
  },
}

M.setup = function() end

-- Tear down watchers on exit so we don't leak fd handles.
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function() stop_watchers() end,
})

return M