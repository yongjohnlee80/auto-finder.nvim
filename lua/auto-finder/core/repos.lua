---auto-finder.core.repos — repos registry + worktree state cache.
---
---Tracks the registered-repos JSON registry (existing
---`stdpath('data')/auto-finder/repos.json`) plus each repo's
---worktree state. Subscribes via core.ensure_started to
---registry mutations and to `worktree:switched`; publishes
---`auto-finder.core.repos:changed` events.
---
---**Phase 1 status: placeholder.** Returns empty state.
---Phase 6 ships the actual repos tracking, which will reuse the
---existing `auto-finder.repos` module's persistence layer.
---
---@module 'auto-finder.core.repos'

local M = {}

M._readiness = "cold"

---@return { repos: table[], readiness: string }
function M.snapshot_now()
  return { repos = {}, readiness = M._readiness }
end

---@param cb fun(snapshot: table)
function M.snapshot_async(cb)
  vim.schedule(function() cb(M.snapshot_now()) end)
end

return M
