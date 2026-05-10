---auto-finder.logger — thin compatibility shim over `auto-core.log`.
---
---Migration step (auto-finder v0.2.0 → auto-core consumer, step 1/4
---per the kb's auto-core-todos migration plan): auto-finder previously
---hand-prefixed every `vim.notify(...)` call with `"auto-finder: …"` /
---`"auto-finder._storage: …"`. Routing those through `auto-core.log`
---namespaces every line under `auto-finder.<component>` and feeds the
---unified ring buffer / `:checkhealth` surface that the rest of the
---family uses.
---
---Log lines render as
---
---    [AutoCore] [auto-finder.panel.host] [WARN] message…
---
---Mirrors `auto-agents/logger.lua` (commit cba0ed9 in
---auto-agents.nvim). Kept as a separate module so a Phase 8
---family-cleanup pass can sweep call sites to
---`require("auto-core").log.namespace("auto-finder.<component>")`
---directly and delete this shim in one go.
---@module 'auto-finder.logger'

local core_log = require("auto-core").log

local M = {}

-- Re-export the level table so callers doing `if logger.levels.DEBUG
-- <= … then` keep working.
M.levels = core_log.levels

---Prefix `component` with `auto-finder.` so logs are namespaced under
---the family root. Idempotent — already-prefixed strings pass through
---unchanged.
---@param component any
---@return string
local function ns(component)
  if type(component) ~= "string" or component == "" then
    return "auto-finder"
  end
  if component:sub(1, #"auto-finder.") == "auto-finder."
      or component == "auto-finder" then
    return component
  end
  return "auto-finder." .. component
end

---When the first arg isn't a string, treat it as a message part with
---no explicit component and fall back to the default namespace.
---@param level_fn fun(component: string?, ...)
---@param component any
---@param ... any
local function level_call(level_fn, component, ...)
  if type(component) ~= "string" then
    level_fn("auto-finder", component, ...)
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

---Mirror upstream's `is_level_enabled` predicate via auto-core.
---@param level_name string
---@return boolean
function M.is_level_enabled(level_name)
  return core_log.is_level_enabled(level_name)
end

---Optional setup hook — auto-finder's `setup()` may forward
---`cfg.log_level` if/when it's introduced. Currently no-op when no
---level is provided; preserves the auto-agents shim's shape so a
---future config schema bump is a one-line change.
---@param plugin_config table?
function M.setup(plugin_config)
  local level = plugin_config and plugin_config.log_level
  if type(level) == "string" and core_log.levels[level:upper()] then
    core_log.configure({ level = level })
  end
end

return M
