---Component overrides for the auto-finder-repos source. Top-level
---workspaces render with the root-name highlight; worktrees render
---with the git-untracked highlight so they stand out from ordinary
---directories. Per-file git-status nodes propagate their porcelain
---status into a corresponding neo-tree highlight.
---
---Originally contributed by Bryan Cua as `neo-tree-workspace.components`;
---ported into auto-finder for the v0.1.2 repos section.
---@module 'auto-finder-repos.components'

local highlights = require("neo-tree.ui.highlights")
local common = require("neo-tree.sources.common.components")

local M = {}

local function status_highlight(status)
  local x, y = status:sub(1, 1), status:sub(2, 2)
  if     x == "?" or y == "?" then return highlights.GIT_UNTRACKED
  elseif x == "A" or y == "A" then return highlights.GIT_ADDED
  elseif x == "D" or y == "D" then return highlights.GIT_DELETED
  elseif x == "R" or y == "R" then return highlights.GIT_RENAMED
  elseif x == "C" or y == "C" then return highlights.GIT_ADDED
  elseif x == "U" or y == "U" then return highlights.GIT_CONFLICT
  end
  return highlights.GIT_MODIFIED
end

M.name = function(config, node, state)
  local result = common.name(config, node, state)
  local extra = node.extra or {}
  if extra.is_workspace then
    result.highlight = highlights.ROOT_NAME
  elseif extra.is_worktree then
    result.highlight = highlights.GIT_UNTRACKED
  elseif extra.git_status then
    result.highlight = status_highlight(extra.git_status)
  end
  return result
end

return vim.tbl_deep_extend("force", common, M)
