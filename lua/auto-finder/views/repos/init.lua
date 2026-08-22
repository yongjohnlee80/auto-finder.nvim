---View 2 — repos (registered repos × git worktrees).
---
---Drives neo-tree to mount the `auto-finder-repos` source (a custom
---neo-tree source ported from Bryan Cua's `neo-tree-workspace`) into
---the panel window via `position = "current"`. Mount plumbing is
---shared with the files view in `auto-finder.shared.neotree`.
---
---Discovery is delegated to worktree.nvim (single source of truth):
---`require("auto-finder.repos").load()` returns whatever
---`worktree.git.list_child_repos(worktree.get_root())` finds, plus
---the root itself when it's a git repo. No registry, no manual
---add — what worktree.nvim sees is what shows up here.
---
---The neo-tree source itself (worktree expansion via `git worktree
---list --porcelain`, fs_event watchers on `<gitdir>/worktrees/`,
---lazy directory expansion) lives at `lua/auto-finder-repos/init.lua`.
---
---ADR 0026 Phase 2: moved from `auto-finder.sections.repos` to
---`auto-finder.views.repos`. Original path remains valid via facade.
---@module 'auto-finder.views.repos'

-- ADR-0060 (P4): the repos slot moves from the `auto-finder-repos` neo-tree
-- source to worktree.nvim's own explorer. The switch is by AVAILABILITY rather
-- than configuration [DECISION -- Johno, 2026-08-22], exactly as the dbase slot
-- switched to autodb (ADR-0058): a worktree.nvim exposing `repos.available()`
-- IS the cutover, and until then the neo-tree path below is untouched.
--
-- Delegation rather than a rewrite in place, deliberately: a developer
-- mid-session keeps a working panel either way, and the change reverses by
-- downgrading one plugin. Hard removal of the old source may follow in a later
-- minor (ADR-0060 §6.3).
local function _worktree_view()
  local ok, r = pcall(require, "worktree.repos")
  if not ok or type(r) ~= "table" then return nil end
  if type(r.available) ~= "function" or not r.available() then return nil end
  local ok_tree, tree = pcall(require, "auto-finder.views.repos.tree")
  if ok_tree then return tree end
  return nil
end

local _legacy = require("auto-finder.shared.neotree").build_section({
  name = "repos",
  description = "registered repos × git worktrees",
  source = "auto-finder-repos",
  -- ADR 0026 Phase 6: subscribe to auto-finder.core.repos:changed
  -- (published by core's translator on worktree:switched) so the
  -- section refreshes on workspace-root changes through the
  -- centralized signal. Phase 7's mount contract will consume
  -- core.repos.snapshot_now directly.
  core_refresh_topic = "auto-finder.core.repos:changed",
})

---The view the registry sees. Each hook delegates to worktree.nvim's explorer
---when it is available, else to the legacy neo-tree section. The probe runs per
---hook rather than once at load: worktree.nvim may be lazy-loaded after this
---module is required, and a one-shot probe would latch the wrong answer.
local M = {
  name = _legacy.name,
  description = "repos x worktrees x work in flight",
  -- Re-declared, not inherited by accident: `shared.neotree.build_section`
  -- wires the legacy path's subscription from this field, and the Phase 6
  -- acceptance ledger asserts the view still declares it. Both paths refresh
  -- off the SAME translated topic.
  _core_refresh_topic = _legacy._core_refresh_topic
    or "auto-finder.core.repos:changed",
}

function M.get_buffer(panel_winid)
  local v = _worktree_view()
  if v then return v.get_buffer(panel_winid) end
  return _legacy.get_buffer(panel_winid)
end

function M.on_focus(panel_winid, bufnr)
  local v = _worktree_view()
  if v then return v.on_focus(panel_winid, bufnr) end
  if _legacy.on_focus then return _legacy.on_focus(panel_winid, bufnr) end
end

function M.on_close()
  -- Close BOTH: whichever one mounted, its resources must go. Calling the
  -- inactive one's on_close is a no-op, and that is cheaper than tracking
  -- which path was live across a plugin being loaded mid-session.
  local v = _worktree_view()
  if v then pcall(v.on_close) end
  if _legacy.on_close then pcall(_legacy.on_close) end
end

function M.refresh()
  local v = _worktree_view()
  if v and v.refresh then return v.refresh() end
  if _legacy.refresh then return _legacy.refresh() end
end

---_legacy_for_tests exposes the fallback so the smoke suite can assert BOTH
---paths rather than only whichever one this machine happens to resolve.
M._legacy_for_tests = _legacy
M._probe_for_tests = _worktree_view

return M
