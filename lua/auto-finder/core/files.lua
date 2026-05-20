---auto-finder.core.files — file-tree state cache (ADR §2.5).
---
---Owns a sparse, path-keyed cache of file and directory entries.
---Subscribes (via core.ensure_started, not module-load) to
---auto-core's `core.file:*` topics; translates each event into
---an upsert/delete/subtree_stale on the cache; publishes
---`auto-finder.core.files:changed` for views.
---
---Entry shapes (Phase 1 only declares; Phase 4 fills):
---
---  -- file entry
---  { kind = 'file', path, stat, git_status, gitignored, generation }
---
---  -- directory entry
---  { kind = 'directory', path, stat,
---    children = { [name] = true, … } | nil,
---    children_state = 'cold' | 'known' | 'stale',
---    generation }
---
---**Phase 1 status: placeholder.** snapshot_now returns an empty
---tree with readiness='cold'; snapshot_async fires the callback
---immediately with the same empty tree; get returns nil. Phase 4
---wires the real cache + watcher integration.
---
---@module 'auto-finder.core.files'

local M = {}

-- The cache itself — path-keyed table of entries. Phase 4 grows
-- this on watcher events and on render-driven get() calls.
M._cache = {}

-- Per-area readiness state. `cold` → never warmed; `warming` →
-- async warmer is mid-walk; `ready` → fully populated for the
-- known set of paths; `partial` → max_handles exhausted, live
-- refresh is best-effort.
M._readiness = "cold"

---@param cwd string?  defaults to vim.fn.getcwd()
---@return { tree: table, readiness: 'cold'|'warming'|'ready'|'partial' }
function M.snapshot_now(cwd)
  -- Phase 4 returns the actual cache view. Phase 1 returns an
  -- empty tree so views can wire the call without crashing.
  return { tree = {}, readiness = M._readiness }
end

---@param cwd string?
---@param cb fun({ tree: table, readiness: string })
function M.snapshot_async(cwd, cb)
  -- Phase 4 will queue the callback until readiness flips to
  -- 'ready' / 'partial'. Phase 1 fires immediately with whatever
  -- snapshot_now returns.
  vim.schedule(function() cb(M.snapshot_now(cwd)) end)
end

---@param path string
---@return table|nil
function M.get(path)
  -- Phase 4 returns the cache entry (and may trigger a bounded
  -- single-directory rescan if children_state is cold/stale).
  -- Phase 1 just returns whatever's in the cache, which is nil.
  return M._cache[path]
end

return M
