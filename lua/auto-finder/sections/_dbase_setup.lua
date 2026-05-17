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

local logger = require("auto-finder.log")

local M = {
  _done = false,    ---@type boolean        — setup ran AND returned ok
  _err  = nil,      ---@type string|nil     — last failure, retained until reset
  _log_bridge_installed = false,
  _original_dbee_log = nil,
}

---Install a wrap around `dbee.utils.log` so dbee-originated messages
---also enter the auto-core ring buffer under `auto-finder.dbase.upstream.*`.
---
---dbee calls `vim.notify(...)` directly from its `lua/dbee/utils.lua`
---(signature: `M.log(level, message, subtitle)` — see
---`nvim-dbee/lua/dbee/utils.lua:46`). That bypasses
---`auto-core.log` and the family-wide [[auto-family-logging]]
---convention's "no direct vim.notify" rule (which is binding on us,
---not on upstream).
---
---Bridge strategy: keep dbee's original `vim.notify` behavior so any
---existing dbee UI that reads `:messages` still works, AND emit a
---parallel `auto-core.log` entry under
---`auto-finder.dbase.upstream.<subtitle>` so a unified `:AutoCoreLog`
---viewer surfaces dbee messages alongside ours.
---
---Idempotent (second call no-ops). Reversed by `M.reset()` for
---tests. Sensitive to upstream dbee changing the `M.log` signature —
---if `level`/`message`/`subtitle` ever shift, the bridge silently
---degrades to a pass-through (original is always called via pcall).
local function install_dbee_log_bridge()
  if M._log_bridge_installed then return end
  local ok, dbee_utils = pcall(require, "dbee.utils")
  if not ok or type(dbee_utils) ~= "table" or type(dbee_utils.log) ~= "function" then
    return
  end
  M._original_dbee_log = dbee_utils.log
  dbee_utils.log = function(level, message, subtitle)
    -- Emit to auto-core.log first. If our logger errors for any
    -- reason, we still want dbee's original log to fire — never
    -- shadow upstream behavior.
    pcall(function()
      local ns = "dbase.upstream." .. (type(subtitle) == "string" and subtitle ~= ""
        and subtitle or "core")
      local fn = logger[level] or logger.info
      fn(ns, tostring(message or ""))
    end)
    -- Preserve original behavior (vim.notify with title="nvim-dbee").
    return M._original_dbee_log(level, message, subtitle)
  end
  M._log_bridge_installed = true
end

---@class AutoFinderDbaseSetupOpts
---@field sources? table[]   list of dbee Source instances; defaults to a single empty MemorySource
---@field extra? table       passthrough — merged into the dbee.setup config under the user's responsibility

---Default source set: a single FileSource pinned at
---`<state>/auto-finder/dbase/_active.json`. The user manages a
---library of named connection files via the `dbase` REPL commands
---(`dbase new`, `dbase load`, `dbase conn add`, …); those commands
---swap the contents of `_active.json` and call
---`dbee.api.core.source_reload("_active.json")` so the drawer
---reflects the change without re-running dbee.setup. Consumers that
---want to bypass this and pass their own `sources = { ... }`
---explicitly still can — the user-supplied list short-circuits
---this default path entirely.
---@return table[]
local function default_sources()
  local ok, dbee_sources = pcall(require, "dbee.sources")
  if not ok then return {} end
  local ok_files, files = pcall(require, "auto-finder.sections._dbase_files")
  if not ok_files then
    -- Defensive fallback: this module ships alongside _dbase_files
    -- so the require should always succeed, but if it doesn't, an
    -- empty MemorySource is a less-destructive default than crashing
    -- setup.
    return { dbee_sources.MemorySource:new({}, "dbase-default") }
  end
  return { dbee_sources.FileSource:new(files.active_path()) }
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
    -- INFO not ERROR: nvim-dbee is an optional dep. The placeholder
    -- buffer rendered by the section IS the user-visible signal that
    -- the section isn't wired up; toasting on top of it (which
    -- logger.error would do per auto-family-logging) would be noise.
    -- Mirrors the soft-dep shape used in _dbase_events.lua for the
    -- auto-core.events probe.
    logger.info("dbase.setup", M._err)
    return false, M._err
  end

  opts = opts or {}
  -- Treat an EMPTY sources list the same as nil — fall through to the
  -- default MemorySource so the drawer always renders against
  -- something. Without this, `cfg.dbase = { sources = {} }` (legal
  -- per the config schema) would hand dbee zero sources and produce
  -- a "No sources :(" drawer. Lector review should-fix §2.
  local user_sources = opts.sources
  if type(user_sources) == "table" and #user_sources == 0 then
    user_sources = nil
  end
  local cfg = { sources = user_sources or default_sources() }

  -- Forbid dbee's `DefaultLayout` (which would snapshot the entire vim
  -- layout via tools.save() and create four exclusive windows). The
  -- dbase section mounts the drawer into auto-finder's panel
  -- explicitly; editor/result/call_log get mounted in the main editor
  -- area by `_dbase_layout` on demand. Any stray `dbee.open()` /
  -- `dbee.toggle()` call goes through OUR layout, which only mounts
  -- the three companion tiles (drawer stays under the section's
  -- ownership).
  local layout_mod = require("auto-finder.sections._dbase_layout")
  cfg.window_layout = layout_mod.layout

  if type(opts.extra) == "table" then
    for k, v in pairs(opts.extra) do
      if cfg[k] == nil then cfg[k] = v end
    end
  end

  local ok_setup, err = pcall(dbee.setup, cfg)
  if not ok_setup then
    M._err = "dbee.setup failed: " .. tostring(err)
    -- ERROR level toasts unconditionally per the auto-family-logging
    -- convention. Setup failure means the section can't function;
    -- the user needs to see this. Tag with `event` so the entry is
    -- discoverable as a `dbase.setup.failed` record in the ring and
    -- carry the raw err in `fields` for triage.
    -- Fully-qualified event name because the wrapper's level
    -- functions don't auto-prefix opts.event (only notifyIf does).
    logger.error("dbase.setup", M._err,
      { event  = "auto-finder.dbase.setup.failed",
        fields = { err = tostring(err) } })
    return false, M._err
  end

  -- Bridge dbee's own logging into auto-core.log. Done AFTER setup so
  -- the wrap doesn't interfere with dbee's internal init. Idempotent.
  install_dbee_log_bridge()

  M._done = true
  return true, nil
end

---Test-only: break the singleton so a fresh `ensure_setup` can run.
---Production callers must not touch this — dbee state is module-global
---and re-running setup mid-session produces undefined behavior. Also
---restores dbee.utils.log to its pre-bridge function so a clean test
---reproduces the wrap from scratch.
function M.reset()
  M._done = false
  M._err = nil
  if M._log_bridge_installed and M._original_dbee_log then
    local ok, dbee_utils = pcall(require, "dbee.utils")
    if ok and type(dbee_utils) == "table" then
      dbee_utils.log = M._original_dbee_log
    end
  end
  M._log_bridge_installed = false
  M._original_dbee_log = nil
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
