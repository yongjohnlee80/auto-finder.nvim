---auto-finder.log — single-file logging surface for the plugin.
---
---Per ADR 0021 §6 (the "wrapper rule"), every auto-family plugin
---owns exactly one `lua/<plugin>/log.lua` that delegates to
---`auto-core.log`. Feature code in auto-finder calls THIS module;
---feature code MUST NOT `require("auto-core").log` directly. The
---single insertion point is what makes a future migration (different
---sink, OTLP exporter, distributed aggregation) a one-file change
---per plugin instead of an N-call-site sweep.
---
---Renamed from `auto-finder.logger` in this commit. The previous
---module was a name-prefixing shim that only covered the level
---functions; this version adds:
---
---  - M.notify / M.notifyIf    — single-emission toast sugar
---                                that also writes the ring
---  - M.register_events        — declares this plugin's event-type
---                                catalog at setup time
---
---Log lines render as
---
---    [AutoCore] [auto-finder.panel.host] [WARN] message…
---
---@module 'auto-finder.log'

local core_log = require("auto-core").log

local NS = "auto-finder"

local M = {}

-- Re-export the level table so callers doing `if log.levels.DEBUG
-- <= … then` keep working.
M.levels = core_log.levels

---Prefix `component` with `auto-finder.` so logs are namespaced
---under the family root. Idempotent — already-prefixed strings pass
---through unchanged.
---@param component any
---@return string
local function ns(component)
  if type(component) ~= "string" or component == "" then
    return NS
  end
  if component:sub(1, #NS + 1) == (NS .. ".") or component == NS then
    return component
  end
  return NS .. "." .. component
end

---When the first arg isn't a string, treat it as the first message
---part and emit with the bare auto-finder namespace.
---@param level_fn fun(component: string?, ...)
---@param component any
---@param ... any
local function level_call(level_fn, component, ...)
  if type(component) ~= "string" then
    level_fn(NS, component, ...)
  else
    level_fn(ns(component), ...)
  end
end

---@param component string|any   -- component name OR first message part
function M.error(component, ...) level_call(core_log.error, component, ...) end
function M.warn(component, ...)  level_call(core_log.warn,  component, ...) end
function M.info(component, ...)  level_call(core_log.info,  component, ...) end
function M.debug(component, ...) level_call(core_log.debug, component, ...) end
function M.trace(component, ...) level_call(core_log.trace, component, ...) end

---Force-toast single emission. Writes ring + fires vim.notify
---(subject to the global level filter). Use this instead of bare
---`vim.notify(...)` so every toast lands in the auto-core ring for
---`:AutoCoreLog` triage. Default level INFO; override via
---`opts.level = "warn"` etc. If `opts.component` is a bare segment
---(e.g. `"scan"`) it is prefixed with the plugin namespace for
---consistency with the level functions.
---@param msg any
---@param opts table?
function M.notify(msg, opts)
  opts = vim.tbl_extend("force", {}, opts or {})
  if opts.component ~= nil then opts.component = ns(opts.component) end
  -- ADR 0021 §6 soft-dep: on an auto-core older than Phase 1, fall
  -- back to a ring-only emission. Visible toast is lost but the
  -- entry still lands.
  if type(core_log.notify) ~= "function" then
    local level_name = "info"
    if type(opts.level) == "string" then level_name = opts.level end
    local fn = M[level_name] or M.info
    return fn(opts.component, msg)
  end
  return core_log.notify(msg, opts)
end

---Ring write + conditional toast. The toast fires iff `event` is in
---the user's subscribed set (toggled via `:AutoCoreLogEvent notify
---<event>`). The ring entry is written regardless so incident
---triage retains the record. `event` should be fully qualified
---(`auto-finder.scan.completed.slow`); if the caller passes a bare
---segment we auto-prefix to match the plugin namespace.
---@param event string
---@param msg any
---@param opts table?
function M.notifyIf(event, msg, opts)
  opts = vim.tbl_extend("force", {}, opts or {})
  if opts.component ~= nil then opts.component = ns(opts.component) end
  local fq_event = event
  if type(event) == "string"
      and event ~= NS
      and event:sub(1, #NS + 1) ~= (NS .. ".") then
    fq_event = NS .. "." .. event
  end
  -- ADR 0021 §6 soft-dep: pre-Phase-1 auto-core has no notifyIf.
  -- Fall back to ring-only info emission so the audit trail is
  -- preserved without crashing.
  if type(core_log.notifyIf) ~= "function" then
    return M.info(opts.component, msg)
  end
  return core_log.notifyIf(fq_event, msg, opts)
end

---Declare the events this plugin emits. Bare names are auto-
---prefixed with the plugin namespace by
---`auto-core.log.events.register`. Idempotent — re-calling with
---the same set is a no-op.
---@param events string|string[]
function M.register_events(events)
  -- ADR 0021 §6 soft-dep: pre-Phase-1 auto-core has no events
  -- registry. Silently no-op; notifyIf calls degrade to ring-only
  -- emissions in that environment.
  if type(core_log.events) ~= "table"
      or type(core_log.events.register) ~= "function" then
    return
  end
  return core_log.events.register(NS, events)
end

---Mirror upstream's `is_level_enabled` predicate via auto-core.
---@param level_name string
---@return boolean
function M.is_level_enabled(level_name)
  return core_log.is_level_enabled(level_name)
end

---Optional setup hook — auto-finder's `setup()` may forward
---`cfg.log_level` to auto-core's configure. Currently no-op when no
---level is provided.
---@param plugin_config table?
function M.setup(plugin_config)
  local level = plugin_config and plugin_config.log_level
  if type(level) == "string" and core_log.levels[level:upper()] then
    core_log.configure({ level = level })
  end
end

return M