---Commands for the auto-finder-repos source. Wraps neo-tree's
---common open/split/etc. commands with our `toggle_directory` so the
---tree can lazy-load worktree contents on expansion.
---
---Originally contributed by Bryan Cua as `neo-tree-workspace.commands`;
---ported into auto-finder for the v0.1.2 repos section.
---@module 'auto-finder-repos.commands'

local cc = require("neo-tree.sources.common.commands")
local source = require("auto-finder-repos")
local utils = require("neo-tree.utils")

local M = {}

local function td(state) return utils.wrap(source.toggle_directory, state) end

M.open               = function(state) cc.open(state, td(state)) end
M.open_split         = function(state) cc.open_split(state, td(state)) end
M.open_vsplit        = function(state) cc.open_vsplit(state, td(state)) end
M.open_tabnew        = function(state) cc.open_tabnew(state, td(state)) end
M.open_rightbelow_vs = function(state) cc.open_rightbelow_vs(state, td(state)) end
M.open_leftabove_vs  = function(state) cc.open_leftabove_vs(state, td(state)) end
M.open_drop          = function(state) cc.open_drop(state, td(state)) end
M.open_tab_drop      = function(state) cc.open_tab_drop(state, td(state)) end

M.toggle_node        = function(state) cc.toggle_node(state, td(state)) end
M.toggle_directory   = function(state) cc.toggle_directory(state, td(state)) end

M.refresh = function(state)
  source.navigate(state, nil, nil, nil, false)
end

cc._add_common_commands(M)

return M
