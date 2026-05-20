---auto-finder.core — runtime state component (ADR 0026).
---
---Single source of truth for the file tree, git status, buffer
---list, repo registry, and worktree state. Subscribes to
---auto-core events on `ensure_started`; publishes auto-finder-
---private topics that views consume.
---
---**Phase 1 status: skeleton.** Public surface is declared here
---so consumers can begin migrating their require paths, but every
---method is a no-op or returns a safe default. Behavior wires up
---across phases 2–8 per ADR §6.
---
---Lifecycle contract (ADR §2.2 — re-armable):
---
---  core.ensure_started(cfg)  — idempotent; safe to call from
---                              auto-finder.setup, M.open, M.focus,
---                              and any code path that crosses the
---                              "is core actually subscribed?"
---                              boundary. Default impl is dispose-
---                              first-then-resubscribe (the
---                              `_handles_still_valid` probe is an
---                              optimization for later, not the
---                              contract).
---  core.stop()               — unsubscribe, close watchers, clear caches.
---  core.reload(cfg)          — stop + ensure_started.
---  core.is_started()         — boolean; did the last ensure_started
---                              succeed?
---
---Snapshot contract (ADR §2.3 — async):
---
---  core.files.snapshot_now(cwd?)        — cheap, returns
---                                          { tree, readiness =
---                                          'cold'|'warming'|'ready' }
---  core.files.snapshot_async(cwd?, cb)  — callback when ready.
---  core.files.get(path)                 — single-entry getter.
---  (analogous for git/buffers/repos).
---
---Subscription contract:
---
---  core.events.subscribe(topic, cb)  — returns handle
---  core.events.unsubscribe(handle)
---
---@module 'auto-finder.core'

local M = {}

-- ── lifecycle ───────────────────────────────────────────────

-- Captured handles for the upstream subscriptions ensure_started
-- opens. Phase 3 fills this; Phase 1 leaves it empty so dispose
-- is a no-op.
M._handles = {}

-- Tracks whether the last ensure_started call completed. Phase 1
-- sets this to true on a no-op call so M.is_started() reflects
-- reality.
M._started = false

-- Set by the future `core.events:bus_reset` subscriber (ADR §2.2,
-- Open Question #1). Until auto-core publishes that topic this
-- flag stays false; the probe always returns false; ensure_started
-- always takes the dispose+resub path (same correctness, just no
-- skip).
M._invalidated = false

---Idempotent re-armable lifecycle entry point (ADR §2.2).
---
---Contract: regardless of whether prior handles can be proven
---valid, this function must leave core subscribed to every
---upstream topic it cares about. Default impl is dispose-first-
---then-resubscribe.
---
---Phase 1: no upstream subscriptions are opened yet; this is a
---safe no-op that just flips `_started = true`. The `cfg` arg is
---preserved on the surface for forward-compat — Phase 3 will
---read `cfg.core.*` (warm batch size + other tunables) on its
---first read.
---@param cfg AutoFinderConfig?
function M.ensure_started(cfg)
  ---@diagnostic disable-next-line: unused-local
  local _ = cfg  -- consumed by Phase 3+; Phase 1 is a no-op
  -- Phase 3 will add: dispose any prior handles, then resubscribe
  -- to core.file:*, core.git.state:changed, worktree:switched,
  -- and the BufAdd/BufDelete/BufEnter autocmds routed through
  -- core/. For Phase 1 we just flip the flag so callers can
  -- assert is_started() after setup.
  M._started = true
  M._invalidated = false
end

---Tear-down counterpart to ensure_started. Phase 1 no-op.
function M.stop()
  -- Phase 3 will dispose handles + close watchers + clear caches.
  -- Phase 1: just flip the flag.
  M._handles = {}
  M._started = false
end

---stop + ensure_started. Used on cwd change or manual reload.
---@param cfg AutoFinderConfig?
function M.reload(cfg)
  M.stop()
  M.ensure_started(cfg)
end

---@return boolean
function M.is_started()
  return M._started
end

-- ── area submodules ─────────────────────────────────────────
--
-- Each area (files / git / buffers / repos) is its own submodule
-- with a snapshot_now / snapshot_async / get surface. Phase 1
-- ships placeholder modules so require paths resolve; later
-- phases fill in the real cache + topic translation logic.
--
-- We lazy-load via __index so a require("auto-finder.core") at
-- setup time doesn't pay the cost of pulling in every submodule
-- (and so individual submodules can be reloaded in isolation
-- during development without affecting siblings).

local _submodules = {
  files    = "auto-finder.core.files",
  git      = "auto-finder.core.git",
  buffers  = "auto-finder.core.buffers",
  repos    = "auto-finder.core.repos",
  watchers = "auto-finder.core.watchers",
  warm     = "auto-finder.core.warm",
  events   = "auto-finder.core.events",
}

setmetatable(M, {
  __index = function(_, k)
    local path = _submodules[k]
    if path then
      local mod = require(path)
      rawset(M, k, mod)
      return mod
    end
    return nil
  end,
})

-- ── test-only ───────────────────────────────────────────────

---Test-only: reset every cache + flip _started back to false.
---Production code never calls this.
function M._reset_for_tests()
  M._handles = {}
  M._started = false
  M._invalidated = false
end

return M
