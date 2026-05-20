---auto-finder.core.events — topic registry and pub/sub.
---
---Per ADR §2.2 transport decision: auto-finder-private topics
---ride on top of `auto-core.events` rather than via a local
---emitter. This module is a thin wrapper:
---
---  - TOPICS table is the authoritative list of topic names + their
---    payload shapes (for documentation and grep targeting). Adding
---    a new topic means adding it here.
---  - publish(topic, payload) and subscribe(topic, cb) delegate to
---    `auto-core.events` so the trace ring captures auto-finder
---    state mutations.
---  - If a future need for a local emitter surfaces (e.g. test
---    isolation), this is the single swap point — view code does
---    not need to change.
---
---Phase 1 status: topic constants declared; publish/subscribe
---wrappers in place. No internal subscribers wire up yet
---(that's Phase 3+).
---
---@module 'auto-finder.core.events'

local M = {}

-- ── topic registry ──────────────────────────────────────────
--
-- One entry per auto-finder-private topic. Each entry carries a
-- `doc` blurb and a `payload` shape string for human readers.
-- This is documentation, not validation — payload contract is
-- enforced by callers + smokes, not by runtime checks.

M.TOPICS = {
  ["auto-finder.core.files:changed"] = {
    doc = "Files cache mutated by a translated core.file:* event " ..
          "or by an internal directory-rescan. `kind='subtree_stale'` " ..
          "is the catch-all for directory-scoped bursts where " ..
          "file-event reassembly is unreliable.",
    payload = "{ cwd = string, kind = 'upsert'|'delete'|'subtree_stale', " ..
              "paths = string[], parents = string[]? }",
    publishers = { "auto-finder.core.files" },
  },
  ["auto-finder.core.git:changed"] = {
    doc = "Git status cache mutated by a translated " ..
          "core.git.state:changed event. Coarse-grained; " ..
          "subscribers refresh git-derived UI state.",
    payload = "{ repo_root = string, kind = string, paths = string[]? }",
    publishers = { "auto-finder.core.git" },
  },
  ["auto-finder.core.buffers:changed"] = {
    doc = "Buffer-list mutated. Translated from Buf* autocmds " ..
          "routed through core/.",
    payload = "{ kind = 'add'|'remove'|'enter'|'modify', bufnr = integer }",
    publishers = { "auto-finder.core.buffers" },
  },
  ["auto-finder.core.repos:changed"] = {
    doc = "Repos registry mutated, or worktree:switched fired.",
    payload = "{ kind = string, repo_root = string }",
    publishers = { "auto-finder.core.repos" },
  },
  ["auto-finder.core.ready"] = {
    doc = "A cache area transitioned cold/warming → ready, OR " ..
          "transitioned to a partial-coverage state due to " ..
          "max_handles exhaustion (per ADR §2.6 handle-cap " ..
          "degradation). `areas` is keyed by area name with " ..
          "value 'ready' | 'partial'.",
    payload = "{ areas = table<string, 'ready'|'partial'> }",
    publishers = { "auto-finder.core" },
  },
  ["auto-finder.core.metrics:paint"] = {
    doc = "Instrumentation — view render swap complete. " ..
          "Captured by smokes to assert A5 (branch-switch refresh " ..
          "≤ 50% pre-refactor baseline).",
    payload = "{ view = string, dur_ms = number, generation = integer, " ..
              "paths_count = integer? }",
    publishers = { "auto-finder.core", "auto-finder.view.*" },
  },
}

-- ── pub/sub wrappers ────────────────────────────────────────

local function _core()
  local ok, core = pcall(require, "auto-core")
  if not ok or type(core) ~= "table" or type(core.events) ~= "table" then
    return nil
  end
  return core
end

---Publish an auto-finder.core.* topic. Soft-fails if auto-core is
---absent — auto-finder ships with auto-core as a soft-dep per
---ADR 0006, so a missing auto-core leaves the call as a no-op
---rather than crashing the host.
---@param topic string
---@param payload any
function M.publish(topic, payload)
  local core = _core()
  if not core then return end
  core.events.publish(topic, payload)
end

---@param topic string
---@param cb fun(payload: any, topic: string)
---@return any handle  -- opaque; pass to unsubscribe()
function M.subscribe(topic, cb)
  local core = _core()
  if not core then return nil end
  return core.events.subscribe(topic, cb)
end

---@param handle any
function M.unsubscribe(handle)
  local core = _core()
  if not core or handle == nil then return end
  core.events.unsubscribe(handle)
end

return M
