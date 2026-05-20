---auto-finder.core.repos — registered-repos + worktree state cache (ADR §2.7).
---
---Thin denormalized view on top of `auto-finder.repos` (which is
---itself a thin facade over `worktree.nvim` — see
---`lua/auto-finder/repos.lua` for the discovery contract). This
---module exists so views can call a single, namespace-correct
---`core.repos.snapshot_now()` instead of importing `auto-finder.repos`
---directly. The translator already publishes
---`auto-finder.core.repos:changed` on `worktree:switched` (Phase 3
---sweep — `core/init.lua`); Phase 6 lands the snapshot surface so
---views can actually consume the data.
---
---Public surface:
---
---  repos.snapshot_now()       → { repos, readiness, root }
---  repos.snapshot_async(cb)   → callback when populated
---  repos.get(repo_path)       → boolean   (is this repo in the list?)
---
---Entry shape (consumers see absolute paths today; worktree
---enumeration per-repo lives in `M.worktree_paths` on
---auto-finder.repos for now — Phase 7+ may expand the snapshot to
---a nested `{ repo_root → { worktrees[] } }` shape if views need
---per-repo worktree state):
---
---  repos = { "/abs/path/to/repo-1", "/abs/path/to/repo-2", … }
---
---@module 'auto-finder.core.repos'

local M = {}

M._cached  = nil   -- last snapshot (lazy-fetched on first call)
M._readiness = "cold"

---@return table|nil  the auto-finder.repos module, or nil if absent
local function _repos_mod()
  local ok, mod = pcall(require, "auto-finder.repos")
  if not ok then return nil end
  return mod
end

---Refresh the cache by querying auto-finder.repos. Called lazily
---on snapshot_now and also driven by the translator's
---`auto-finder.core.repos:changed` publish (which fires on
---`worktree:switched` per Phase 3 — see core/init.lua).
local function _refresh()
  local repos_mod = _repos_mod()
  if not repos_mod or type(repos_mod.load) ~= "function" then
    M._cached = { root = nil, repos = {} }
    M._readiness = "partial"
    return
  end
  local root = (type(repos_mod.root) == "function") and repos_mod.root() or nil
  local list = repos_mod.load() or {}
  M._cached = { root = root, repos = list }
  M._readiness = "ready"
end

---@return { repos: string[], readiness: 'cold'|'ready'|'partial', root: string? }
function M.snapshot_now()
  if M._readiness == "cold" then _refresh() end
  -- Defensive copy of the list so consumers can't mutate the cache.
  local repos = {}
  for i, p in ipairs(M._cached.repos or {}) do repos[i] = p end
  return {
    repos     = repos,
    readiness = M._readiness,
    root      = M._cached.root,
  }
end

---@param cb fun(snapshot: table)
function M.snapshot_async(cb)
  if M._readiness == "ready" or M._readiness == "partial" then
    vim.schedule(function() cb(M.snapshot_now()) end)
    return
  end
  -- Fire one query now, then deliver. Subsequent
  -- `auto-finder.core.repos:changed` events from the translator
  -- will refresh `M._cached` on the next snapshot_now call.
  vim.schedule(function() cb(M.snapshot_now()) end)
end

---@param repo_path string
---@return boolean
function M.get(repo_path)
  if type(repo_path) ~= "string" or repo_path == "" then return false end
  local snap = M.snapshot_now()
  for _, p in ipairs(snap.repos) do
    if p == repo_path then return true end
  end
  return false
end

---Invalidate the cache. Called by the translator on
---`auto-finder.core.repos:changed` so the next snapshot_now
---fetches fresh data from auto-finder.repos / worktree.nvim.
function M.invalidate()
  M._cached = nil
  M._readiness = "cold"
end

---Test-only: reset to a true cold state without invalidating
---auto-finder.repos / worktree.nvim's caches.
function M._reset_for_tests()
  M._cached = nil
  M._readiness = "cold"
end

return M
