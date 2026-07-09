local renderer = require("auto-finder.neotree.ui.renderer")
local utils = require("auto-finder.neotree.utils")
local file_items = require("auto-finder.neotree.sources.common.file-items")
local log = require("auto-finder.neotree.log")

local M = {}

---Get a table of all open buffers, along with all parent paths of those buffers.
---The paths are the keys of the table, and all the values are 'true'.
M.get_opened_buffers = function(state)
  if state.loading then
    return
  end
  state.loading = true
  local context = file_items.create_context()
  context.state = state
  -- Create root folder
  local root = file_items.create_item(context, state.path, "directory") --[[@as neotree.FileItem.Directory]]
  root.name = vim.fn.fnamemodify(root.path, ":~")
  root.loaded = true
  root.search_pattern = state.search_pattern
  context.folders[root.path] = root
  local terminals = {}

  -- AUTO-FINDER EXTENSION (v0.2.14):
  -- Out-of-root buffers are bucketed by their "natural external root"
  -- and rendered as ADDITIONAL top-level groups (like Terminals).
  -- Without this, anything opened from $HOME but outside cwd — KB
  -- pages under ~/.config, scratch files under ~/Documents, etc. —
  -- silently disappeared from the buffers panel because the upstream
  -- `is_subpath(state.path, path)` check dropped them on the floor.
  --
  -- Bucketing strategy: first path segment after $HOME (e.g.
  -- ~/.config, ~/Documents); if outside $HOME, first absolute
  -- segment (e.g. /tmp, /etc, /opt). Inside each bucket, full
  -- subdir nesting is preserved — file_items.create_item walks
  -- parents up to the bucket root we pre-register in context.folders.
  --
  -- The cwd root keeps its existing behavior (everything under cwd
  -- nests there); externals become sibling groups.
  local externals = {}  -- bucket_path -> { { bufnr, path } }

  local home_dir = vim.fn.expand("~")
  local home_prefix = home_dir .. "/"

  local function bucket_for_external(path)
    if vim.startswith(path, home_prefix) then
      local rest = path:sub(#home_prefix + 1)
      local first = rest:match("^([^/]+)")
      if first then return home_dir .. "/" .. first end
    end
    -- Outside $HOME — use the first absolute path component.
    local first = path:match("^/([^/]+)")
    if first then return "/" .. first end
    return nil
  end

  local function add_buffer(bufnr, path)
    local is_loaded = vim.api.nvim_buf_is_loaded(bufnr)
    if is_loaded or state.show_unloaded then
      local is_listed = vim.fn.buflisted(bufnr)
      if is_listed == 1 then
        if path == "" then
          path = "[No Name]"
        end
        local success, item = pcall(file_items.create_item, context, path, "file", bufnr)
        if success then
          item.extra = {
            bufnr = bufnr,
            is_listed = is_listed,
          }
        else
          log.error("Error creating item for " .. path .. ": " .. item)
        end
      end
    end
  end

  local bufs = vim.api.nvim_list_bufs()
  for _, b in ipairs(bufs) do
    local path = vim.api.nvim_buf_get_name(b)
    if vim.startswith(path, "term://") then
      local name = path:match("term://(.*)//.*")
      local abs_path = vim.fn.fnamemodify(name, ":p")
      local has_title, title = pcall(vim.api.nvim_buf_get_var, b, "term_title")
      local item = {
        name = has_title and title or name,
        ext = "terminal",
        path = abs_path,
        id = path,
        type = "terminal",
        loaded = true,
        extra = {
          bufnr = b,
          is_listed = true,
        },
      }
      if utils.is_subpath(state.path, abs_path) then
        table.insert(terminals, item)
      end
    elseif path == "" then
      add_buffer(b, path)
    else
      if #state.path > 1 then
        if utils.is_subpath(state.path, path) then
          -- In-cwd: existing behavior, nests under the cwd root.
          add_buffer(b, path)
        else
          -- AUTO-FINDER EXTENSION: out-of-cwd → bucket for grouping.
          local bucket = bucket_for_external(path)
          if bucket then
            externals[bucket] = externals[bucket] or {}
            table.insert(externals[bucket], { bufnr = b, path = path })
          end
        end
      else
        add_buffer(b, path)
      end
    end
  end

  local root_folders = { root }

  if #terminals > 0 then
    local terminal_root = {
      name = "Terminals",
      id = "Terminals",
      ext = "terminal",
      type = "terminal",
      children = terminals,
      loaded = true,
      search_pattern = state.search_pattern,
    }
    context.folders["Terminals"] = terminal_root
    if state.terminals_first then
      table.insert(root_folders, 1, terminal_root)
    else
      table.insert(root_folders, terminal_root)
    end
  end

  -- AUTO-FINDER EXTENSION (v0.2.14): emit external buckets as
  -- sibling root folders. Each bucket gets its own header
  -- (`OPEN BUFFERS in <bucket>`) and proper subdir nesting beneath.
  local external_keys = {}
  for k in pairs(externals) do external_keys[#external_keys + 1] = k end
  table.sort(external_keys)
  -- Track ids already promoted to top-level so a bucket root can't
  -- collide with the cwd root or another bucket (ADR-0050). nui
  -- hard-errors on a duplicate node id, aborting the whole render;
  -- the renderer has a defensive dedup too, but skip the obvious
  -- collision here so we don't drop a legitimately-distinct subtree.
  local root_ids = { [root.path] = true }
  for _, bucket_path in ipairs(external_keys) do
    if root_ids[bucket_path] then
      -- Bucket path coincides with the cwd root or an earlier bucket;
      -- its buffers already nest under that existing root folder
      -- (create_item deduped them there). Nothing more to add.
      goto continue_bucket
    end
    local bucket_root = file_items.create_item(
      context, bucket_path, "directory")
      --[[@as neotree.FileItem.Directory]]
    root_ids[bucket_path] = true
    bucket_root.name = vim.fn.fnamemodify(bucket_path, ":~")
    bucket_root.loaded = true
    bucket_root.search_pattern = state.search_pattern
    context.folders[bucket_path] = bucket_root
    for _, e in ipairs(externals[bucket_path]) do
      local is_loaded = vim.api.nvim_buf_is_loaded(e.bufnr)
      if is_loaded or state.show_unloaded then
        local is_listed = vim.fn.buflisted(e.bufnr)
        if is_listed == 1 then
          local ok, item = pcall(file_items.create_item,
            context, e.path, "file", e.bufnr)
          if ok then
            item.extra = { bufnr = e.bufnr, is_listed = is_listed }
          else
            log.error("Error creating item for " .. e.path .. ": " .. item)
          end
        end
      end
    end
    -- Same sort cadence the cwd root uses below — keeps each
    -- bucket's children dirs-first / name-sorted.
    if bucket_root.children then
      file_items.advanced_sort(bucket_root.children, state)
    end
    table.insert(root_folders, bucket_root)
    ::continue_bucket::
  end
  -- Detach every top-level root from any parent folder it was linked
  -- into. create_item → set_parents builds the FULL ancestor chain for
  -- each item (cwd root included), so when a bucket path is an ancestor
  -- of the cwd root (cwd ~/Source/Projects/X + external buffer under
  -- ~/Source ⇒ bucket ~/Source), the cached bucket folder already
  -- contains the cwd root in its subtree — rendering it as a sibling
  -- duplicates every node under cwd (the renderer.create_nodes
  -- duplicate-id WARN storm). Siblings must be disjoint subtrees.
  for _, top in ipairs(root_folders) do
    local parent = top.parent_path and context.folders[top.parent_path]
    if parent and parent.children then
      for i, child in ipairs(parent.children) do
        if child.id == top.id then
          table.remove(parent.children, i)
          break
        end
      end
    end
  end
  -- Prune directories emptied by the detach above (a detached cwd
  -- root can leave its old parent chain — e.g. an empty "Projects"
  -- dir — dangling inside a bucket). Dirs in this panel exist only to
  -- host buffers, so an empty one is always dead weight.
  local function prune_empty_dirs(dir)
    if not dir.children then
      return
    end
    for i = #dir.children, 1, -1 do
      local child = dir.children[i]
      if child.type == "directory" then
        prune_empty_dirs(child)
        if not child.children or #child.children == 0 then
          table.remove(dir.children, i)
        end
      end
    end
  end
  for _, top in ipairs(root_folders) do
    prune_empty_dirs(top)
  end
  state.default_expanded_nodes = {}
  for id, _ in pairs(context.folders) do
    table.insert(state.default_expanded_nodes, id)
  end
  file_items.advanced_sort(root.children, state)
  renderer.show_nodes(root_folders, state)
  state.loading = false
end

return M
