---auto-finder.core.buffers — buffer-list state cache (ADR §2.7).
---
---Mirrors the nvim buffer list (`:ls`-shaped, including
---unloaded). Subscribes via core.ensure_started to BufAdd /
---BufDelete / BufEnter / BufWritePost autocmds; translates them
---into `auto-finder.core.buffers:changed` events.
---
---**Phase 1 status: placeholder.** Returns an empty list.
---Phase 6 ships the actual buffer-list tracking.
---
---@module 'auto-finder.core.buffers'

local M = {}

M._readiness = "cold"

---@return { list: table[], readiness: string }
function M.snapshot_now()
  return { list = {}, readiness = M._readiness }
end

---@param cb fun(snapshot: table)
function M.snapshot_async(cb)
  vim.schedule(function() cb(M.snapshot_now()) end)
end

return M
