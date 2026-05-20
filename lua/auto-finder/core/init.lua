---auto-finder.core — runtime state component (ADR 0026).
---
---Single source of truth for the file tree, git status, buffer
---list, repo registry, and worktree state. Subscribes to
---auto-core events on `ensure_started`; publishes auto-finder-
---private topics that views consume.
---
---**Phase 3 status: re-armable lifecycle wired.** Phase 1 shipped
---the loadable surface; Phase 3 implements the actual subscribe
---+ translate logic. The caches in `core.files` / `core.git` /
---`core.buffers` / `core.repos` are still placeholders (Phase 4–6
---fills them); what Phase 3 ships is the EVENT WIRING — every
---upstream auto-core topic is captured, every auto-finder.core.*
---translation fires, and the lifecycle survives a bus reset by
---unconditionally dispose-first-then-resubscribe (the contract
---per Lector's review §9 r3 #1).
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
---@module 'auto-finder.core'

local M = {}

-- ── lifecycle ───────────────────────────────────────────────

-- Captured handles for the upstream subscriptions ensure_started
-- opens. Keyed by stable slot name so dispose can look each one up.
-- Phase 3: files, git, worktree, workspace, user_width, last_section.
M._handles = {}

-- Tracks whether the last ensure_started call completed.
M._started = false

-- Set by the future `core.events:bus_reset` subscriber (Open
-- Question #1). Until auto-core publishes that topic this flag
-- stays false; the probe always returns false; ensure_started
-- always takes the dispose+resub path. Same correctness; no skip.
M._invalidated = false

---@return table|nil
local function require_upstream()
  local ok, core = pcall(require, "auto-core")
  if not ok or type(core) ~= "table"
      or type(core.events) ~= "table"
      or type(core.events.subscribe) ~= "function" then
    return nil
  end
  return core
end

---Dispose every captured handle. Safe to call on a fresh / dead
---auto-core — `events.unsubscribe` is a soft-fail wrapper.
function M._dispose_handles()
  local events = require("auto-finder.core.events")
  for slot, handle in pairs(M._handles) do
    events.unsubscribe(handle)
    M._handles[slot] = nil
  end
end

---Future enhancement: probe whether prior handles are still
---registered with auto-core.events. Today this is unconditionally
---false — the dispose-first-then-resubscribe path is always
---taken. When auto-core ships the `core.events:bus_reset` topic
---(Open Question #1) the probe upgrades to a real check.
---@return boolean
function M._handles_still_valid()
  return false
end

---Subscribe to a single auto-core topic, capture the handle under
---`slot` in `M._handles`. Internal helper used by `ensure_started`.
---Soft-fails if auto-core is absent.
---@param slot string
---@param topic string
---@param cb fun(payload: any, topic: string)
local function _sub(slot, topic, cb)
  local up = require_upstream()
  if not up then return end
  M._handles[slot] = up.events.subscribe(topic, cb)
end

-- ── file-event coalescing + burst detection (ADR §2.5) ──
--
-- Phase 4 adds a debounce window over `core.file:*` events so a
-- burst (e.g. 100 file writes in a single tick, or a branch
-- switch that touches hundreds of files) collapses into a single
-- `auto-finder.core.files:changed` emit. Within the window, if
-- > BURST_THRESHOLD events accumulate against the same parent
-- directory, the parent is invalidated wholesale (`kind =
-- 'subtree_stale'`) rather than reassembled from N file events —
-- per ADR §2.5 the upstream `fs.watch` can't supply paired
-- rename events, so directory-scoped operations are unsafe to
-- reconstruct file-by-file.
--
-- Cache mutation happens IMMEDIATELY on each event (so `get(path)`
-- reflects reality even during the debounce window); only the
-- EMIT is deferred.
local FILES_DEBOUNCE_MS = 100
local BURST_THRESHOLD   = 50  -- events per parent within window
local _file_buf = {}            -- { { path, kind } }
local _file_buf_timer = nil

local function _flush_file_events()
  _file_buf_timer = nil
  if #_file_buf == 0 then return end

  local buf = _file_buf
  _file_buf = {}

  -- Group by parent dir for burst detection.
  local by_parent = {}
  for _, ev in ipairs(buf) do
    local parent = vim.fn.fnamemodify(ev.path, ":h")
    by_parent[parent] = by_parent[parent] or { upsert = {}, delete = {}, count = 0 }
    by_parent[parent].count = by_parent[parent].count + 1
    if ev.kind == "delete" then
      table.insert(by_parent[parent].delete, ev.path)
    else
      table.insert(by_parent[parent].upsert, ev.path)
    end
  end

  -- Walk parents. A parent above the burst threshold collapses
  -- into a single subtree_stale event for that dir; everything
  -- else accumulates into the upsert / delete lists.
  local stale_parents = {}
  local upsert_paths  = {}
  local delete_paths  = {}
  local files_mod = require("auto-finder.core.files")
  for parent, group in pairs(by_parent) do
    if group.count > BURST_THRESHOLD then
      files_mod.invalidate_subtree(parent)
      stale_parents[#stale_parents + 1] = parent
    else
      for _, p in ipairs(group.upsert) do
        upsert_paths[#upsert_paths + 1] = p
      end
      for _, p in ipairs(group.delete) do
        delete_paths[#delete_paths + 1] = p
      end
    end
  end

  -- Emit. Each kind gets its own event so subscribers can filter
  -- on payload.kind; the alternative ("one event with mixed kind
  -- inside paths[]") would complicate every consumer.
  local events_mod = require("auto-finder.core.events")
  local cwd = vim.fn.getcwd()
  if #stale_parents > 0 then
    events_mod.publish("auto-finder.core.files:changed", {
      cwd     = cwd,
      kind    = "subtree_stale",
      paths   = stale_parents,
      parents = stale_parents,
    })
  end
  if #upsert_paths > 0 then
    events_mod.publish("auto-finder.core.files:changed", {
      cwd   = cwd,
      kind  = "upsert",
      paths = upsert_paths,
    })
  end
  if #delete_paths > 0 then
    events_mod.publish("auto-finder.core.files:changed", {
      cwd   = cwd,
      kind  = "delete",
      paths = delete_paths,
    })
  end
end

local function _enqueue_file_event(path, kind)
  -- Mutate the cache immediately so `get` reflects reality even
  -- mid-debounce. Only the emit is debounced.
  local files_mod = require("auto-finder.core.files")
  if kind == "delete" then
    files_mod.delete(path)
  else
    files_mod.upsert(path)
  end
  _file_buf[#_file_buf + 1] = { path = path, kind = kind }
  -- (Re)arm the flush timer. vim.defer_fn returns a timer that
  -- vim.fn.timer_stop can cancel; stopping + re-firing each event
  -- keeps the window sliding.
  if _file_buf_timer then
    pcall(vim.fn.timer_stop, _file_buf_timer)
  end
  _file_buf_timer = vim.defer_fn(_flush_file_events, FILES_DEBOUNCE_MS)
end

---Test-only: flush the file-event buffer immediately and clear
---the timer. Used by Phase 4 smoke to assert on debounced output
---without waiting on real time.
function M._flush_file_events_for_tests()
  if _file_buf_timer then
    pcall(vim.fn.timer_stop, _file_buf_timer)
    _file_buf_timer = nil
  end
  _flush_file_events()
end

---Test-only: read the current file-event buffer length.
function M._file_buf_len_for_tests()
  return #_file_buf
end

---Idempotent re-armable lifecycle entry point (ADR §2.2).
---
---Contract: regardless of whether prior handles can be proven
---valid, this function must leave core subscribed to every
---upstream topic it cares about. Default impl is dispose-first-
---then-resubscribe.
---@param cfg AutoFinderConfig?
function M.ensure_started(cfg)
  ---@diagnostic disable-next-line: unused-local
  local _ = cfg  -- consumed by Phase 4+ (warm batch size etc.); Phase 3 wires events only
  -- Optimization fast-path: if the probe says handles are still
  -- valid AND we're started, skip the work. Phase 3 the probe is
  -- always false so this branch never fires; left in place for
  -- the future bus_reset signal.
  if M._started and M._handles_still_valid() then
    return
  end

  -- Always dispose first. A handle whose underlying subscription
  -- was wiped (bus reset, _reset_for_tests, :Lazy reload) is a
  -- no-op on unsubscribe. A handle that's still live gets cleanly
  -- removed before re-subscribe. Result: at most one subscription
  -- per slot, guaranteed.
  M._dispose_handles()

  -- ── upstream → auto-finder.core.* translation ──
  --
  -- core.file:* → auto-finder.core.files:changed
  -- Phase 4 adds debounce + burst-detection per ADR §2.5: cache
  -- mutation happens immediately on each event (so `get(path)`
  -- reflects reality), but the EMIT is deferred 100 ms and
  -- coalesces multiple events into a single
  -- `auto-finder.core.files:changed` (or `subtree_stale` if
  -- > 50 events accumulate against one parent within the window).
  -- See `_enqueue_file_event` / `_flush_file_events` above.
  _sub("upstream_file", "core.file:*", function(payload, topic)
    if type(payload) ~= "table" or type(payload.path) ~= "string" then
      return
    end
    local kind = (topic == "core.file:deleted") and "delete" or "upsert"
    _enqueue_file_event(payload.path, kind)
  end)

  -- core.git.state:changed → auto-finder.core.git:changed
  _sub("upstream_git", "core.git.state:changed", function(payload)
    if type(payload) ~= "table" then return end
    require("auto-finder.core.events").publish(
      "auto-finder.core.git:changed", {
        repo_root = payload.repo_root,
        kind      = payload.kind,
      })
  end)

  -- worktree:switched →
  --   - publish auto-finder.core.repos:changed { kind = 'worktree_switched' }
  --   - invoke init.lua's existing reseed handler (was at
  --     init.lua:612-621 before Phase 3 swept it here)
  --   - invoke init.lua's existing repos-bufnr-drop handler (was at
  --     init.lua:357-378)
  _sub("upstream_worktree", "worktree:switched", function(payload)
    local repo_root = (type(payload) == "table" and payload.new_root) or ""
    require("auto-finder.core.events").publish(
      "auto-finder.core.repos:changed", {
        kind      = "worktree_switched",
        repo_root = repo_root,
      })
    -- Trigger the auto-finder-side handlers via vim.schedule so
    -- they run after the current event tick completes. Soft-deps:
    -- auto-finder may not be fully loaded when this fires (e.g.
    -- during test isolation); pcall + type checks guard.
    vim.schedule(function()
      local ok, af = pcall(require, "auto-finder")
      if not ok then return end
      if type(af._reseed_sections_for_workspace) == "function" then
        af._reseed_sections_for_workspace()
      end
      if type(af._drop_repos_bufnr_on_worktree_switched) == "function" then
        af._drop_repos_bufnr_on_worktree_switched()
      end
    end)
  end)

  -- core.workspace_root:changed → reseed only. This was the second
  -- subscriber in the original init.lua:612-621 pair. Reseed is
  -- idempotent so firing on both topics is safe.
  _sub("upstream_workspace", "core.workspace_root:changed", function()
    vim.schedule(function()
      local ok, af = pcall(require, "auto-finder")
      if ok and type(af._reseed_sections_for_workspace) == "function" then
        af._reseed_sections_for_workspace()
      end
    end)
  end)

  -- ── state.namespace watchers (UI state) ──
  --
  -- These were at init.lua:336-349 before Phase 3 swept them here.
  -- They subscribe to `state.auto-finder:<key>:changed` topics
  -- under the hood (via auto-core.state.namespace's :watch). Same
  -- re-armable shape as everything else.
  do
    local ok_state, state_mod = pcall(require, "auto-finder.state")
    if ok_state and type(state_mod.watch_user_width) == "function" then
      M._handles.state_user_width = state_mod.watch_user_width(function(payload)
        local ok_af, af = pcall(require, "auto-finder")
        if not ok_af then return end
        af.state.user_width = payload.new
        if af._panel then
          if payload.new then
            af._panel:resize(payload.new)
          else
            af._panel:reset_width()
          end
        end
        pcall(function()
          require("auto-finder.panel.host")._refresh_after_resize(af.state)
        end)
      end)
    end
    if ok_state and type(state_mod.watch_last_section) == "function" then
      M._handles.state_last_section = state_mod.watch_last_section(function(payload)
        local ok_af, af = pcall(require, "auto-finder")
        if ok_af then af.state.section = payload.new end
      end)
    end
  end

  -- ── Phase 4: fs.watch handle + chunked cache warm ──
  --
  -- Open the working-tree fs.watch via core.watchers and kick off
  -- the chunked warmer against the cwd's top level. Both are
  -- idempotent on a re-arm: watchers.open_for returns the existing
  -- handle bundle for an already-watched cwd; warm.start no-ops
  -- if a warm is already in progress.
  --
  -- max_handles_exceeded degradation (§2.6): watchers logs warn +
  -- publishes auto-finder.core.ready with payload areas.files =
  -- 'partial'. The warmer doesn't gate on that — its own walk
  -- still completes and publishes its own auto-finder.core.ready
  -- with files = 'ready' on success.
  local cwd = vim.fn.getcwd()
  pcall(function()
    require("auto-finder.core.watchers").open_for(cwd)
  end)
  pcall(function()
    require("auto-finder.core.warm").start(cwd)
  end)

  M._started = true
  M._invalidated = false

  -- Log the (re)arm so it's discoverable in :AutoCoreLog when the
  -- next "my view stopped refreshing" report arrives. Soft-fail:
  -- the wrapper may not be loaded during very early init.
  pcall(function()
    require("auto-finder.log").info("core",
      "ensure_started: " .. tostring(vim.tbl_count(M._handles)) .. " handles armed")
  end)
end

---Tear-down counterpart to ensure_started. Disposes every captured
---handle, closes every fs.watch handle, stops the in-progress
---warm. Resets the `_started` flag. Phase 5 will also dispose
---git.watch handles via core.watchers.close_all.
function M.stop()
  M._dispose_handles()
  -- Cancel any pending file-event flush + drop the buffer so the
  -- next ensure_started starts from a clean slate.
  if _file_buf_timer then
    pcall(vim.fn.timer_stop, _file_buf_timer)
    _file_buf_timer = nil
  end
  _file_buf = {}
  local ok_warm, warm = pcall(require, "auto-finder.core.warm")
  if ok_warm and type(warm.stop) == "function" then
    warm.stop()
  end
  local ok_w, watchers = pcall(require, "auto-finder.core.watchers")
  if ok_w and type(watchers.close_all) == "function" then
    watchers.close_all()
  end
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
-- shipped placeholder modules so require paths resolve; Phase 4+
-- fills in the real cache + topic translation logic.
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

---Test-only: dispose every captured handle and flip _started
---back to false. Production code never calls this.
function M._reset_for_tests()
  M._dispose_handles()
  M._started = false
  M._invalidated = false
end

return M
