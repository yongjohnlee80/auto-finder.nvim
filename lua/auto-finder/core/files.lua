---auto-finder.core.files — directory-aware file-tree cache (ADR §2.5).
---
---Owns a sparse, path-keyed cache of file and directory entries.
---Subscribes (via core.ensure_started, not module-load) to
---auto-core's `core.file:*` topics; translates each event into
---an upsert/delete/subtree_stale on the cache; publishes
---`auto-finder.core.files:changed` for views.
---
---Entry shapes (ADR §2.5):
---
---  -- file entry
---  { kind = 'file', path, stat?, git_status?, gitignored?, generation }
---
---  -- directory entry
---  { kind = 'directory', path, stat?,
---    children = { [name] = true, … },
---    children_state = 'cold' | 'known' | 'stale',
---    generation }
---
---**Phase 4 status: cache implementation lands.** snapshot_now is
---non-blocking (returns whatever's in cache). snapshot_async waits
---for the `auto-finder.core.ready` signal that Phase 4's chunked
---warmer publishes on completion. `git_status` / `gitignored` are
---placeholder fields filled in by Phase 5's git cache.
---
---@module 'auto-finder.core.files'

local M = {}

-- The cache itself — path-keyed table of entries.
M._cache = {}

-- Per-area readiness state. `cold` → never warmed; `warming` →
-- the chunked warmer is mid-walk; `ready` → warmer completed for
-- the cwd's top level; `partial` → max_handles exhausted (per
-- ADR §2.6 graceful degradation, set by core.watchers when
-- fs.watch.start returns max_handles_exceeded).
M._readiness = "cold"

-- Monotonic generation counter. Every mutation bumps it; entries
-- store the value at their last update so smoke tests can prove
-- the cache mutated without re-walking the tree.
local _generation = 0
local function _next_gen()
  _generation = _generation + 1
  return _generation
end

---Test-visible getter for the live generation counter.
---@return integer
function M.current_generation()
  return _generation
end

---Resolve the parent directory of `path`. Returns `path` itself
---if it has no parent (the filesystem root).
---@param path string
---@return string
local function _parent(path)
  local p = vim.fn.fnamemodify(path, ":h")
  -- vim.fn.fnamemodify returns "." for relative-only paths; normalize.
  if p == "" then return path end
  return p
end

---Mark a directory's children as stale (will be rescanned on
---next render/get). No-op if the parent isn't a known directory
---entry — we don't fabricate parent entries during invalidation,
---only on warm or explicit upsert.
---@param path string
local function _mark_parent_stale(path)
  local parent = _parent(path)
  if parent == path then return end
  local entry = M._cache[parent]
  if entry and entry.kind == "directory" and entry.children_state == "known" then
    entry.children_state = "stale"
    entry.generation = _next_gen()
  end
end

---@param cwd string?  defaults to vim.fn.getcwd()
---@return { tree: table, readiness: 'cold'|'warming'|'ready'|'partial', cwd: string }
function M.snapshot_now(cwd)
  cwd = cwd or vim.fn.getcwd()
  return {
    tree = M._cache,
    readiness = M._readiness,
    cwd = cwd,
  }
end

---@param cwd string?
---@param cb fun({ tree: table, readiness: string, cwd: string })
function M.snapshot_async(cwd, cb)
  if M._readiness == "ready" or M._readiness == "partial" then
    vim.schedule(function() cb(M.snapshot_now(cwd)) end)
    return
  end
  -- Wait for the warmer to publish 'ready' / 'partial' and then
  -- invoke the callback. The subscription is one-shot.
  local events_mod = require("auto-finder.core.events")
  local handle
  handle = events_mod.subscribe("auto-finder.core.ready", function(payload)
    if type(payload) ~= "table" or type(payload.areas) ~= "table" then return end
    if payload.areas.files == "ready" or payload.areas.files == "partial" then
      events_mod.unsubscribe(handle)
      cb(M.snapshot_now(cwd))
    end
  end)
end

---Single-entry getter. Returns the cached entry for `path` (or
---nil if cold). Phase 4 does NOT trigger a bounded rescan on
---cold/stale directory entries — that refinement lands when
---views actually request the missing data (Phase 7+).
---@param path string
---@return table|nil
function M.get(path)
  return M._cache[path]
end

---Upsert a cache entry for `path`. Creates a fresh entry if none
---exists; updates `stat` / bumps generation otherwise. The parent
---directory is marked `stale` (if it was `known`) so a later
---rescan picks up the new child.
---
---For directory entries, the children map and children_state are
---only initialized on FIRST upsert — re-upserting an existing
---directory does not wipe its children. This matters because the
---warmer upserts a dir entry (with empty children, state='cold')
---then proceeds to upsert each child (which sets the parent's
---children_state='stale'); on the warmer's final tick we flip
---the dir's state to 'known' once children are populated.
---@param path string
---@param opts { kind?: 'file'|'directory', stat?: table, git_status?: string, gitignored?: boolean }?
---@return table entry
function M.upsert(path, opts)
  opts = opts or {}
  local existing = M._cache[path]
  local entry
  if existing then
    -- Preserve kind; allow stat / git_status / gitignored updates.
    if opts.stat ~= nil then existing.stat = opts.stat end
    if opts.git_status ~= nil then existing.git_status = opts.git_status end
    if opts.gitignored ~= nil then existing.gitignored = opts.gitignored end
    existing.generation = _next_gen()
    entry = existing
  else
    local kind = opts.kind or "file"
    entry = {
      kind = kind,
      path = path,
      stat = opts.stat,
      git_status = opts.git_status,
      gitignored = opts.gitignored,
      generation = _next_gen(),
    }
    if kind == "directory" then
      entry.children = {}
      entry.children_state = "cold"
    end
    M._cache[path] = entry
  end

  -- Register this entry as a child of its parent (if the parent
  -- is in the cache).
  local parent_path = _parent(path)
  if parent_path ~= path then
    local parent_entry = M._cache[parent_path]
    if parent_entry and parent_entry.kind == "directory" then
      parent_entry.children = parent_entry.children or {}
      parent_entry.children[vim.fn.fnamemodify(path, ":t")] = true
    end
  end

  _mark_parent_stale(path)
  return entry
end

---Drop the cache entry for `path` and remove it from its parent's
---children map. Marks the parent as `stale` if it was `known`.
---@param path string
function M.delete(path)
  local existing = M._cache[path]
  if not existing then return end
  M._cache[path] = nil
  local parent_entry = M._cache[_parent(path)]
  if parent_entry and parent_entry.kind == "directory" and parent_entry.children then
    parent_entry.children[vim.fn.fnamemodify(path, ":t")] = nil
  end
  _mark_parent_stale(path)
end

---Invalidate a directory's child listing. Drops the children
---table and sets `children_state='stale'` so the next render
---triggers a bounded single-directory rescan. Used by the
---burst-detection path in core's translator when many file
---events arrive under the same parent within the burst window
---(per ADR §2.5 table — file-event reassembly is unreliable for
---directory-scoped operations like `mv dir1 dir2`).
---
---If `dir` isn't in the cache yet, creates a placeholder
---directory entry with state='stale'. The parent's children-list
---also gets the dir added.
---@param dir string
function M.invalidate_subtree(dir)
  local existing = M._cache[dir]
  if existing and existing.kind == "directory" then
    existing.children = {}
    existing.children_state = "stale"
    existing.generation = _next_gen()
    return
  end
  -- No entry (or wrong kind) → seed a stale placeholder so the
  -- next render notices the directory wants a rescan.
  M._cache[dir] = {
    kind = "directory",
    path = dir,
    children = {},
    children_state = "stale",
    generation = _next_gen(),
  }
  -- Wire into parent.
  local parent_path = _parent(dir)
  if parent_path ~= dir then
    local parent_entry = M._cache[parent_path]
    if parent_entry and parent_entry.kind == "directory" then
      parent_entry.children = parent_entry.children or {}
      parent_entry.children[vim.fn.fnamemodify(dir, ":t")] = true
    end
  end
end

---Promote a directory entry's children_state from 'cold' to 'known'
---once the warmer has populated its children. Idempotent.
---@param dir string
function M._mark_known(dir)
  local entry = M._cache[dir]
  if entry and entry.kind == "directory" then
    entry.children_state = "known"
    entry.generation = _next_gen()
  end
end

---Set the area readiness. Called by `core.warm` on completion
---and by `core.watchers` on max_handles_exhausted.
---@param r 'cold'|'warming'|'ready'|'partial'
function M._set_readiness(r)
  M._readiness = r
end

---Test-only: clear every entry + reset readiness + reset
---generation. Production code never calls this.
function M._reset_for_tests()
  M._cache = {}
  M._readiness = "cold"
  _generation = 0
end

---Test-only: live cache reference (avoids deep-copies in smokes).
function M._raw_cache()
  return M._cache
end

return M
