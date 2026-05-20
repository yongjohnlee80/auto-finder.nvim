---auto-finder.shared.view_subs — per-view subscription set helper.
---
---Pulled out of `views/<name>/init.lua` so every view manages its
---`auto-finder.core.*` subscriptions with the same shape. Solves
---two problems Lector's ADR 0026 review flagged:
---
---  1. **Duplicate subscriptions on repeat `on_focus`.** If
---     `M._subs = {}` is reset and `events.subscribe(...)` re-runs
---     on every focus, a view that re-focuses N times accrues N
---     callbacks for the same topic. `replace(slot, topic, cb)`
---     swaps the prior handle (if any) before subscribing the new
---     one, so the per-slot count stays at exactly 1.
---  2. **Forgotten unsubscribes on close.** `dispose_all()` walks
---     every captured handle and unsubscribes. Views call it from
---     `on_close`; the set is then empty, ready for the next mount.
---
---Phase 2 ships the helper; views adopt it in Phase 7
---(loading-placeholder) along with the generation-guarded mount
---contract. Smoke section [30] asserts the helper's behaviour
---independent of any view consumer so the contract is locked
---before Phase 7 callers materialise.
---
---@module 'auto-finder.shared.view_subs'

local core_events = require("auto-finder.core.events")

local ViewSubs = {}
ViewSubs.__index = ViewSubs

---Create a fresh, empty subscription set.
---@return AutoFinderViewSubs
local function new()
  local self = setmetatable({}, ViewSubs)
  -- Map from slot name (caller-supplied) to the captured handle.
  -- One handle per slot — `replace` enforces uniqueness.
  self._handles = {}
  return self
end

---Subscribe `cb` to `topic` under the named slot. If the slot
---already holds a handle, it is unsubscribed before the new
---subscription is registered. Idempotent for `(slot, topic, cb)`
---callers that re-run on every `on_focus`.
---@param slot string  caller-chosen slot name (e.g. "files", "git")
---@param topic string
---@param cb fun(payload: any, topic: string)
---@return any handle  the new auto-core.events handle (also stored internally)
function ViewSubs:replace(slot, topic, cb)
  if type(slot) ~= "string" or slot == "" then
    error("view_subs:replace requires a non-empty slot name")
  end
  if type(topic) ~= "string" or topic == "" then
    error("view_subs:replace requires a non-empty topic name")
  end
  if type(cb) ~= "function" then
    error("view_subs:replace requires a function callback")
  end
  local prior = self._handles[slot]
  if prior ~= nil then
    core_events.unsubscribe(prior)
    self._handles[slot] = nil
  end
  local handle = core_events.subscribe(topic, cb)
  self._handles[slot] = handle
  return handle
end

---Unsubscribe every slot in the set. Idempotent — safe to call
---multiple times.
function ViewSubs:dispose_all()
  for slot, handle in pairs(self._handles) do
    core_events.unsubscribe(handle)
    self._handles[slot] = nil
  end
end

---Number of active subscriptions in the set. Used by smoke
---assertions; views typically don't need this.
---@return integer
function ViewSubs:count()
  local n = 0
  for _ in pairs(self._handles) do n = n + 1 end
  return n
end

---@return boolean
function ViewSubs:has(slot)
  return self._handles[slot] ~= nil
end

---@class AutoFinderViewSubs
---@field replace fun(self: AutoFinderViewSubs, slot: string, topic: string, cb: fun(payload: any, topic: string)): any
---@field dispose_all fun(self: AutoFinderViewSubs)
---@field count fun(self: AutoFinderViewSubs): integer
---@field has fun(self: AutoFinderViewSubs, slot: string): boolean

return {
  new = new,
}
