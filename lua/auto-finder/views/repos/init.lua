---View — repos (registered repos × git worktrees × work in flight).
---
---The slot is worktree.nvim's repos explorer, rendered by
---`auto-finder.views.repos.tree` over `require("worktree.repos")`. Discovery is
---delegated to worktree.nvim (single source of truth): what it sees is what shows
---up here.
---
---worktree.nvim is a HARD requirement of this slot (ADR-0200 §4.9). There is no
---fallback implementation: when `worktree.repos` is missing or reports itself
---unavailable, the mount logs one loud error and the tree renders its explicit
---"worktree.nvim's repos surface is unavailable" screen — a truthful panel
---rather than a stale one.
---@module 'auto-finder.views.repos'

local tree = require("auto-finder.views.repos.tree")

local M = {
  name = "repos",
  description = "repos x worktrees x work in flight",
  -- The topic the tree refreshes from (core's translator publishes it on
  -- worktree:switched); declared here for the view registry's readers.
  _core_refresh_topic = tree.REFRESH_TOPIC,
}

local _reported = false
local function check_backend()
  local ok, r = pcall(require, "worktree.repos")
  local available = ok and type(r) == "table" and type(r.available) == "function" and r.available()
  if not available and not _reported then
    _reported = true
    require("auto-finder.log").error("view.repos",
      "worktree.nvim's repos surface is unavailable — the repos slot requires yongjohnlee80/worktree.nvim")
  end
  if available then _reported = false end
end

function M.get_buffer(panel_winid)
  check_backend()
  return tree.get_buffer(panel_winid)
end

function M.on_focus(panel_winid, bufnr)
  return tree.on_focus(panel_winid, bufnr)
end

function M.on_close()
  return tree.on_close()
end

function M.refresh()
  return tree.refresh()
end

return M
