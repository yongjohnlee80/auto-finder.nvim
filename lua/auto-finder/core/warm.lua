---auto-finder.core.warm — async cache warmer (ADR §2.3).
---
---Drives a chunked walk of the project's top-level entries so
---the cold-snapshot path doesn't block a Neovim tick. Phase 4
---batches 8 entries per scheduled tick (tuneable via
---`cfg.core.warm.batch_size` in later phases); kicked off from
---`core.ensure_started` and runs until the cache reaches
---`'ready'` (top-level populated) or `'partial'` (max_handles
---degradation per ADR §2.6).
---
---Acceptance constraint A15 (Phase 4 smoke): no single tick of
---the warmer may exceed 5 ms. `_tick_durations` (ring buffer,
---last 100 ticks) is exposed for the smoke assertion.
---
---Subtree expansion is **on-demand** per ADR §2.3 — Phase 4
---warms only the cwd's top level. Deeper directories populate
---when the user expands them (via render path) or when fs.watch
---events arrive for known paths.
---
---@module 'auto-finder.core.warm'

local M = {}

M._status = "cold"

-- Cancellation flag. `M.stop()` flips this; the next-scheduled
-- batch checks it and bails. Necessary because once `process_batch`
-- has been vim.schedule'd we can't un-schedule it; we can only
-- make it a no-op on entry.
M._cancel = false

-- Per-tick durations in ms. Ring-buffer; capped at 100 entries
-- so a long-running session doesn't accumulate unbounded memory.
-- Smoke section [32] reads this to assert A15 (≤ 5 ms / tick).
M._tick_durations = {}
local MAX_TICK_DURATIONS = 100

local DEFAULT_BATCH_SIZE = 8

---Begin a chunked warm of `cwd`'s top level. Idempotent —
---calling while already warming returns without restarting.
---Calling after a previous warm completed re-runs against the
---current cwd (useful on `core.reload`).
---@param cwd string
---@param opts { batch_size?: integer }?
function M.start(cwd, opts)
  opts = opts or {}
  local batch_size = opts.batch_size or DEFAULT_BATCH_SIZE

  if M._status == "warming" then return end
  M._status = "warming"
  M._cancel = false
  M._tick_durations = {}

  local files_mod = require("auto-finder.core.files")
  local events_mod = require("auto-finder.core.events")

  files_mod._set_readiness("warming")

  -- Seed the cwd directory entry so the parent-child wiring in
  -- files.upsert has a target to attach children to.
  files_mod.upsert(cwd, { kind = "directory" })

  local handle = vim.uv.fs_scandir(cwd)
  if not handle then
    -- Can't open the dir — flip to ready (empty) so consumers
    -- don't hang on snapshot_async forever.
    M._status = "ready"
    files_mod._set_readiness("ready")
    events_mod.publish("auto-finder.core.ready",
      { areas = { files = "ready" } })
    return
  end

  local function record_tick(elapsed_ms)
    if #M._tick_durations >= MAX_TICK_DURATIONS then
      table.remove(M._tick_durations, 1)
    end
    M._tick_durations[#M._tick_durations + 1] = elapsed_ms
  end

  local function process_batch()
    if M._cancel then
      M._status = "cold"
      files_mod._set_readiness("cold")
      return
    end
    local start_ns = (vim.uv or vim.loop).hrtime()

    local processed = 0
    while processed < batch_size do
      local name, t = vim.uv.fs_scandir_next(handle)
      if not name then
        -- Top level walk complete. Promote the cwd directory's
        -- children_state from 'cold' to 'known' so future renders
        -- know the listing is authoritative.
        files_mod._mark_known(cwd)
        files_mod._set_readiness("ready")
        M._status = "ready"
        local elapsed = ((vim.uv or vim.loop).hrtime() - start_ns) / 1e6
        record_tick(elapsed)
        events_mod.publish("auto-finder.core.ready",
          { areas = { files = "ready" } })
        return
      end
      -- Skip very common ignored entries to keep the cache lean.
      -- The list mirrors auto-core.fs.watch's DEFAULT_IGNORE
      -- semantics — there's no point caching paths the watcher
      -- ignores. (.git is the canonical case; ADR 0025 documents
      -- the rationale.)
      if name ~= ".git" then
        local entry_path = cwd .. "/" .. name
        files_mod.upsert(entry_path,
          { kind = t == "directory" and "directory" or "file" })
      end
      processed = processed + 1
    end

    local elapsed = ((vim.uv or vim.loop).hrtime() - start_ns) / 1e6
    record_tick(elapsed)

    -- Yield to the main loop. vim.schedule fires the callback on
    -- the next available tick; this is what keeps per-tick budget
    -- low (vs. blocking the whole walk synchronously).
    vim.schedule(process_batch)
  end

  vim.schedule(process_batch)
end

---Cancel an in-progress warm. Used by `core.stop`.
function M.stop()
  M._cancel = true
  M._status = "cold"
end

---@return 'cold'|'warming'|'ready'|'partial'
function M.status()
  return M._status
end

---@return number[]  copy of recorded per-tick durations (ms)
function M.tick_durations()
  return vim.deepcopy(M._tick_durations)
end

---Test-only: reset internal state without affecting the files
---cache. Production code never calls this.
function M._reset_for_tests()
  M._status = "cold"
  M._cancel = false
  M._tick_durations = {}
end

return M
