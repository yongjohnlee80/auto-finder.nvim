---Event bridge: dbee handler events → auto-core.events topics.
---
---Phase 1, slice 2 of lector ADR 0020 §Implementation Plan:
---*"Add an auto-core event bridge for connection and call-state events."*
---
---dbee's `Handler:register_event_listener` is append-only (the
---underlying `handler.__events` module has no unregister surface).
---That is OK for our purposes: we are the **producer-side** of the
---bridge — we feed dbee events outward into `auto-core.events.publish`
---— so there is no inbound subscription to lifecycle-manage on this
---side. The lifecycle convention
---([[auto-core-events-subscription-lifecycle]]) applies to plugins
---that *subscribe* to `dbase.*`; our `attach()` only needs to be
---idempotent and avoid double-publishing.
---
---Soft dep on `auto-core.events`: if auto-core isn't installed, the
---module no-ops cleanly and the dbase section keeps working as a
---pure UI surface.
---
---Event mapping (per `nvim-dbee/lua/dbee/doc.lua:103-107` core_event_name):
---
---  dbee `current_connection_changed { conn_id }`
---    → publish `dbase.connection:changed { id = conn_id }`
---
---  dbee `call_state_changed { CallDetails }`
---    → publish `dbase.call:state_changed { call_id, to }` (always)
---    → publish `dbase.call:started`    when state = "executing"
---    → publish `dbase.call:completed`  when state = "archived"
---    → publish `dbase.call:failed`     when state ∈
---       { "executing_failed", "retrieving_failed",
---         "archive_failed", "canceled" }
---
---`dbase.result:shown` is registered in auto-core.events.topics but
---not yet produced here — dbee's result UI does not currently emit a
---first-class event we can forward. A future slice may add it via
---tile-level instrumentation or, if upstream is willing, an event
---registration. The topic stays reserved so subscribers can rely on
---the namespace once it lands.
---ADR 0026 Phase 2: moved from `auto-finder.sections._dbase_events`.
---Original path remains valid via `sections/_dbase_events.lua` facade.
---@module 'auto-finder.views.dbase.events'

local logger = require("auto-finder.log")

local M = {
  _attached = false,
}

---@return table|nil events  auto-core.events module, or nil if unavailable
local function get_events()
  local ok, core = pcall(require, "auto-core")
  if not ok or type(core) ~= "table" or type(core.events) ~= "table" then
    return nil
  end
  return core.events
end

---Resolve which discrete terminal topic to publish (if any) for a
---given call_state. Returns nil for non-terminal / informational
---states — the always-fired `dbase.call:state_changed` covers those.
---@param state string
---@return string|nil topic
local function terminal_topic_for_state(state)
  if state == "executing" then return "dbase.call:started" end
  if state == "archived"  then return "dbase.call:completed" end
  if state == "executing_failed"
    or state == "retrieving_failed"
    or state == "archive_failed"
    or state == "canceled"
  then
    return "dbase.call:failed"
  end
  return nil
end

---Attach the bridge to dbee's handler events. Idempotent — second
---and subsequent calls return without re-registering, so a section
---remount or repeated focus does not duplicate publishes.
---
---Requires `dbee.setup()` to have run; the dbase section calls this
---only after `_dbase_setup.ensure_setup()` returns ok.
---@return boolean ok, string|nil err
function M.attach()
  if M._attached then return true, nil end

  local events = get_events()
  if not events then
    -- Soft-dep: auto-core not installed. Section keeps working as a
    -- UI-only surface; no bridge available.
    logger.info("view.dbase.events", "auto-core.events not available; event bridge inactive")
    return true, nil
  end

  local ok_dbee, dbee = pcall(require, "dbee")
  if not ok_dbee then
    return false, "nvim-dbee not on the runtimepath"
  end

  -- ── current_connection_changed → dbase.connection:changed ───────
  dbee.api.core.register_event_listener("current_connection_changed", function(data)
    local id = type(data) == "table" and data.conn_id or nil
    if not id then return end
    events.publish("dbase.connection:changed", { id = id })

    -- Also log to the auto-core ring + maybe-toast (gated). The pub/sub
    -- topic is for inter-plugin coupling; the log entry is for the
    -- audit trail + user-facing toast routing. Two different surfaces;
    -- both worth firing.
    logger.notifyIf("dbase.connection.changed",
      ("dbase: active connection → %s"):format(id),
      { component = "dbase.events",
        fields    = { conn_id = id } })
  end)

  -- ── call_state_changed → dbase.call:state_changed (+ terminal) ──
  -- dbee's Go backend emits this event as a NESTED table:
  --   { call = { id, query, state, time_taken_us, timestamp_us, error } }
  -- (see `nvim-dbee/dbee/handler/event_bus.go:30-44`). dbee's own
  -- result UI destructures `local call = data.call` at
  -- `nvim-dbee/lua/dbee/ui/result/init.lua:75-77`.
  --
  -- We accept `data.call or data` so the bridge is robust to both
  -- the real nested shape AND any future flattening (or a test
  -- harness that ergonomically passes flat payloads).
  --
  -- CallDetails has no `conn_id` field (see `dbee/doc.lua:51-58`),
  -- so conn_id is best-effort enrichment via `get_current_connection()`.
  -- If a call belongs to a connection that's no longer current (rare
  -- but possible for archived calls fired late), conn_id will be
  -- the live one rather than the call's original. This is documented
  -- as optional in the topic registry on the auto-core side.
  dbee.api.core.register_event_listener("call_state_changed", function(data)
    if type(data) ~= "table" then return end
    local call = data.call or data
    if type(call) ~= "table" or not call.id or not call.state then return end

    local call_id = call.id
    local to_state = call.state
    local conn_id
    do
      local ok, conn = pcall(dbee.api.core.get_current_connection)
      if ok and type(conn) == "table" then conn_id = conn.id end
    end

    -- Fine-grained always-fired event.
    events.publish("dbase.call:state_changed", {
      call_id = call_id,
      conn_id = conn_id,
      to = to_state,
    })

    -- Terminal-state derived events. Each fires BOTH:
    --   1. `events.publish(...)` — auto-core pub/sub topic for
    --      inter-plugin coupling (subscribers see the structured
    --      payload).
    --   2. `logger.notifyIf(...)` — auto-core log ring entry +
    --      user-gated toast. The ring captures every terminal call
    --      event for audit/debug; the toast fires iff the user has
    --      enabled it via `:AutoFinderLogEvent notify
    --      dbase.call.<event>`. `dbase.call.failed` is the strong
    --      candidate for default-on once a sensible default policy
    --      surfaces.
    --
    -- Toast messages truncate `query` / `err` to ~80 chars so the
    -- toast stays readable; the structured `fields` table carries
    -- the full untruncated values for the ring entry.
    local function truncate(s, n)
      if type(s) ~= "string" or #s <= n then return s end
      return s:sub(1, n - 1) .. "…"
    end

    local terminal = terminal_topic_for_state(to_state)
    if terminal == "dbase.call:started" then
      local query = call.query or ""
      events.publish(terminal, {
        call_id = call_id,
        conn_id = conn_id,
        query   = query,
      })
      logger.notifyIf("dbase.call.started",
        ("dbase: query started — %s"):format(truncate(query, 80)),
        { component = "dbase.events",
          fields    = { call_id = call_id, conn_id = conn_id, query = query } })
    elseif terminal == "dbase.call:completed" then
      local duration_ms = type(call.time_taken_us) == "number"
        and math.floor(call.time_taken_us / 1000) or nil
      events.publish(terminal, {
        call_id     = call_id,
        conn_id     = conn_id,
        duration_ms = duration_ms,
      })
      logger.notifyIf("dbase.call.completed",
        duration_ms
          and ("dbase: query completed in %dms"):format(duration_ms)
          or  "dbase: query completed",
        { component = "dbase.events",
          fields    = { call_id = call_id, conn_id = conn_id, duration_ms = duration_ms } })
    elseif terminal == "dbase.call:failed" then
      local err = call.error or to_state
      events.publish(terminal, {
        call_id = call_id,
        conn_id = conn_id,
        err     = err,
      })
      -- ERROR level toasts unconditionally per the auto-family-logging
      -- convention. No notifyIf gating here — a failed query is
      -- something the user needs to see, not an opt-in event.
      --
      -- `event` is passed FULLY-QUALIFIED here because `auto-finder.log`
      -- only auto-prefixes via the notifyIf path; the level functions
      -- forward opts straight through. (Worth surfacing as a wrapper
      -- consistency follow-up — auto-prefixing on level functions
      -- would let callers stay namespace-aware everywhere.)
      logger.error("view.dbase.events",
        ("dbase: query failed — %s"):format(truncate(tostring(err), 80)),
        { event  = "auto-finder.dbase.call.failed",
          fields = { call_id = call_id, conn_id = conn_id, err = err } })
    end
  end)

  M._attached = true
  return true, nil
end

---@return boolean
function M.is_attached()
  return M._attached
end

---Test-only: clear the attached flag so a fresh `attach()` re-registers
---under a recreated dbee handler. Does NOT detach from dbee's bus
---(no unregister API); calling `attach()` after a `reset()` against
---the same dbee handler instance will produce duplicate listeners.
---For test isolation, pair with `_dbase_setup.reset()`.
function M.reset()
  M._attached = false
end

return M
