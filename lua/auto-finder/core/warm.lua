---auto-finder.core.warm — async cache warmer (ADR §2.3).
---
---Drives a chunked walk of the project tree so the cold-snapshot
---path doesn't block a Neovim tick. Default batch size is 8
---directory entries per scheduled tick (tuneable via
---`cfg.core.warm.batch_size` in later phases); the walker is
---kicked off from `core.ensure_started` and runs until the cache
---reaches `'ready'` or `'partial'` (the latter on max_handles
---exhaustion).
---
---Acceptance constraint A15 (Phase 4 smoke): no single tick of
---the warmer may exceed 5 ms even on a 5,000-entry tree.
---
---**Phase 1 status: placeholder.** start/stop are no-ops; status
---returns 'cold'. Phase 4 ships the real `vim.uv.fs_scandir`-
---backed walker.
---
---@module 'auto-finder.core.warm'

local M = {}

M._status = "cold"

---@param cwd string
---@param opts table?  { batch_size = integer? }
function M.start(cwd, opts)
  ---@diagnostic disable-next-line: unused-local
  local _cwd, _opts = cwd, opts  -- consumed by Phase 4; no-op here
  -- Phase 4 will:
  --   - open vim.uv.fs_scandir on cwd
  --   - schedule_wrap a batch handler that pulls batch_size
  --     entries per tick and recurses into child directories
  --   - update the files cache via core.files inserts
  --   - on completion, set _status = 'ready' and publish
  --     auto-finder.core.ready with areas.files = 'ready'
  -- Phase 1 is a no-op.
end

function M.stop()
  M._status = "cold"
end

---@return 'cold'|'warming'|'ready'|'partial'
function M.status()
  return M._status
end

return M
