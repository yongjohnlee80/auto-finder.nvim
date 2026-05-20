---auto-finder.core.watchers — fs.watch + git.watch handle owner.
---
---Owns every libuv-backed watcher auto-finder uses. Today these
---are scattered across the section modules
---(`sections/_neotree.lua` opens fs.watch + git.watch per-section,
---per-mount); ADR 0026 centralizes them here so the handles
---survive section switches and panel-close events.
---
---Lifecycle hooks (called from `auto-finder.core.ensure_started`
---and `core.stop`):
---
---  watchers.open_for(cwd)   — start fs.watch + git.watch (Phase 4/5)
---  watchers.close_for(cwd)  — stop the pair (used on reload)
---  watchers.close_all()     — full teardown (used on core.stop)
---
---Handle-cap degradation (ADR §2.6): when `auto-core.fs.watch.start`
---returns an error indicating max_handles exhaustion, log warn
---to `auto-finder.core.watchers` and surface partial coverage via
---the `auto-finder.core.ready` event payload's `areas.files =
---'partial'`. Manual `:AutoFinderReload` still works.
---
---**Phase 1 status: placeholder.** Methods are no-ops. Phase 4
---wires fs.watch; Phase 5 wires git.watch.
---
---@module 'auto-finder.core.watchers'

local M = {}

-- Per-cwd handle map. Phase 4/5 populate as
--   { [cwd] = { fs = <handle>, git = <handle> }, … }
M._handles = {}

---@param cwd string
function M.open_for(cwd)
  -- Phase 4 starts auto-core.fs.watch; Phase 5 starts
  -- auto-core.git.watch. Phase 1 is a no-op so test wiring can
  -- call into this surface without errors.
end

---@param cwd string
function M.close_for(cwd)
  M._handles[cwd] = nil
end

function M.close_all()
  M._handles = {}
end

---@return string[]  list of cwds currently being watched
function M.list()
  local out = {}
  for cwd in pairs(M._handles) do out[#out + 1] = cwd end
  return out
end

return M
