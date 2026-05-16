---Centralized one-shot wrapper around `dbee.setup`.
---
---dbee's setup is module-global and cannot be re-run safely. Section
---mounts (re)called many times across a session must not reconfigure
---dbee. This module owns the "have we set up yet?" decision and the
---error state if setup ever fails — section code just asks
---`ensure_setup(opts)` and trusts the answer.
---
---Lector's ADR 0020 §Phase 1 calls out: *"Add a DBee setup wrapper
---with explicit single-shot behavior."* The synthesized preferred
---method (§8 of the white-vision feasibility doc) ratifies this and
---adds that source registration should accept all three dbee source
---types — memory, env, and file — at the wrapper level.
---@module 'auto-finder.sections._dbase_setup'

local logger = require("auto-finder.logger")

local M = {
  _done = false,    ---@type boolean        — setup ran AND returned ok
  _err  = nil,      ---@type string|nil     — last failure, retained until reset
}

---@class AutoFinderDbaseSetupOpts
---@field sources? table[]   list of dbee Source instances; defaults to a single empty MemorySource
---@field extra? table       passthrough — merged into the dbee.setup config under the user's responsibility

---Default source set: a single empty memory source so the drawer has
---something to render against. Production consumers should pass their
---own `sources = { … }` covering env / file / project-level
---connection inventories.
---@return table[]
local function default_sources()
  local ok, dbee_sources = pcall(require, "dbee.sources")
  if not ok then return {} end
  return { dbee_sources.MemorySource:new({}, "dbase-default") }
end

---Run dbee.setup exactly once for this nvim session. Subsequent calls
---short-circuit on the cached result — including the cached error,
---so a broken setup isn't retried implicitly on every section focus
---(which would surface the same error to the user repeatedly).
---
---Call `M.reset()` from tests to break the singleton.
---@param opts AutoFinderDbaseSetupOpts?
---@return boolean ok, string|nil err
function M.ensure_setup(opts)
  if M._done then return true, nil end
  if M._err then return false, M._err end

  local ok_dbee, dbee = pcall(require, "dbee")
  if not ok_dbee then
    M._err = "nvim-dbee is not on the runtimepath"
    logger.error("dbase.setup", M._err)
    return false, M._err
  end

  opts = opts or {}
  local cfg = { sources = opts.sources or default_sources() }
  if type(opts.extra) == "table" then
    for k, v in pairs(opts.extra) do
      if cfg[k] == nil then cfg[k] = v end
    end
  end

  local ok_setup, err = pcall(dbee.setup, cfg)
  if not ok_setup then
    M._err = "dbee.setup failed: " .. tostring(err)
    logger.error("dbase.setup", M._err)
    return false, M._err
  end

  M._done = true
  return true, nil
end

---Test-only: break the singleton so a fresh `ensure_setup` can run.
---Production callers must not touch this — dbee state is module-global
---and re-running setup mid-session produces undefined behavior.
function M.reset()
  M._done = false
  M._err = nil
end

---@return boolean
function M.is_setup_done()
  return M._done
end

---@return string|nil
function M.last_error()
  return M._err
end

return M
