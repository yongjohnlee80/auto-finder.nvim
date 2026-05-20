---auto-finder.core.git — git status denormalized view (ADR §2.7).
---
---A denormalized view layered on top of `auto-core.git.status`
---(the auth cache per [[0006-auto-core-shared-library]]). Converts
---auto-core's per-repo snapshot into the path-keyed shape that
---views render against.
---
---**Phase 1 status: placeholder.** Returns empty snapshots.
---Phase 4 ships a delegate that calls through to the current
---neo-tree-fork git query path so decorators don't regress
---before Phase 5 replaces it with the real cache.
---
---@module 'auto-finder.core.git'

local M = {}

M._readiness = "cold"

---@param cwd string?
---@return { branch: string?, ahead: integer?, behind: integer?, dirty: boolean?, by_path: table<string, string>, readiness: string }
function M.snapshot_now(cwd)
  return {
    branch = nil, ahead = nil, behind = nil, dirty = nil,
    by_path = {},
    readiness = M._readiness,
  }
end

---@param cwd string?
---@param cb fun(snapshot: table)
function M.snapshot_async(cwd, cb)
  vim.schedule(function() cb(M.snapshot_now(cwd)) end)
end

return M
