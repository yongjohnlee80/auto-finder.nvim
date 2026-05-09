---Component overrides for the auto-finder-repos source.
---
---Two overrides: `name` (highlights workspaces as roots, worktrees
---as untracked-style accents, dirty files in their git-status color)
---and `icon` (replaces the default folder glyph with a repository
---glyph for workspace nodes and a branch glyph for worktree nodes;
---directories underneath fall through to the common folder icons,
---and files use the regular file-icon provider).
---
---Originally contributed by Bryan Cua as `neo-tree-workspace.components`;
---ported into auto-finder for the v0.1.2 repos section, icon
---overrides added in v0.1.3.
---@module 'auto-finder-repos.components'

local highlights = require("auto-finder.neotree.ui.highlights")
local common = require("auto-finder.neotree.sources.common.components")

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

-- Nerd-font glyphs for the two top-tier node types.
--   workspace: nf-cod-repo (U+EA62, the codespace "repo" icon)
--   worktree:  nf-fa-code_branch (U+F126, the git branch icon)
-- Both ship in the default nerd-font glyph set; consumers without
-- a nerd font see a codepoint tofu and should switch to a glyph in
-- their own font (override via cfg.repos somehow — TODO config
-- knob; not in v0.1.3 scope). Trailing space matches common.icon's
-- `<glyph> ` shape so subsequent components don't need extra
-- padding logic.
--
-- Written with Lua's `\u{XXXX}` escape because the raw UTF-8 bytes
-- got eaten somewhere in our authoring pipeline at one point —
-- explicit codepoints are immune to copy-paste corruption.
local WORKSPACE_GLYPH = "\u{ea62} "
local WORKTREE_GLYPH = "\u{f126} "

M.icon = function(config, node, state)
  local extra = node.extra or {}
  if extra.is_workspace then
    return { text = WORKSPACE_GLYPH, highlight = highlights.ROOT_NAME }
  end
  if extra.is_worktree then
    return { text = WORKTREE_GLYPH, highlight = highlights.GIT_UNTRACKED }
  end
  -- Anything else (subdirectories under a worktree, files within
  -- those directories) falls through to the standard icon provider
  -- so the user gets the same folder-vs-file glyphs they're used to
  -- in the files panel.
  return common.icon(config, node, state)
end

return vim.tbl_deep_extend("force", common, M)
