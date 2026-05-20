---auto-finder.core.git — denormalized git status view (ADR §2.7).
---
---Layered on top of `auto-core.git.status` (the auth cache per
---[[0006-auto-core-shared-library]]). Converts auto-core's
---per-repo `entries[]` (each `{ path, status_x, status_y }`)
---into the path-keyed shape views render against.
---
---Public surface:
---
---  git.snapshot_now(cwd?)        → { repo_root, branch?, by_path, readiness }
---  git.snapshot_async(cwd?, cb)  → callback when ready
---  git.get(abs_path)             → { x, y, code } | nil   single-path lookup
---  git.invalidate(cwd?)          — drop the auto-core cache for one repo
---
---**Phase 5 status: backed by auto-core.git.status.** Phase 4
---shipped this module as a placeholder returning empty data.
---Phase 5 wires the real auto-core query path. Cache invalidation
---on `core.git.state:changed` is already wired in auto-core itself
---(per `auto-core/git/status.lua:105-110`); Phase 5 doesn't need
---to invalidate explicitly — the next snapshot_now / get triggers
---a fresh shell-out automatically.
---
---Branch / ahead / behind / dirty metadata is **not** populated
---in Phase 5 — `auto-core.git.status` only exposes porcelain
---entries today. Adding repo-level metadata would be a separate
---auto-core surface; left as Phase 6+ refinement.
---
---@module 'auto-finder.core.git'

local M = {}

M._readiness = "cold"

---@return table|nil  auto-core.git.status module, or nil if absent
local function _git_status_mod()
  local ok, core = pcall(require, "auto-core")
  if not ok or type(core) ~= "table"
      or type(core.git) ~= "table"
      or type(core.git.status) ~= "table"
      or type(core.git.status.get) ~= "function" then
    return nil
  end
  return core.git.status
end

---Build the path-keyed view from auto-core.git.status entries.
---Each entry is `{ path, status_x, status_y }`; we expose them as
---`by_path[abs_path] = { x = "M", y = " ", code = "M " }`. The
---`code` field is the concatenated `x..y` porcelain code — handy
---for direct equality checks against constants like "M ", " M",
---"??", etc.
---@param repo_root string
---@param entries any[]
---@return table<string, { x: string, y: string, code: string }>
local function _denormalize(repo_root, entries)
  local by_path = {}
  if type(entries) ~= "table" then return by_path end
  -- Normalize the repo_root so the joined absolute paths come out
  -- right. auto-core already normalizes its cache keys, but our
  -- caller may have passed an unnormalized cwd.
  local prefix = repo_root
  if prefix:sub(-1) ~= "/" then prefix = prefix .. "/" end
  for _, e in ipairs(entries) do
    if type(e) == "table" and type(e.path) == "string" then
      local x = e.status_x or " "
      local y = e.status_y or " "
      by_path[prefix .. e.path] = {
        x = x,
        y = y,
        code = x .. y,
      }
    end
  end
  return by_path
end

---@param cwd string?  defaults to vim.fn.getcwd()
---@return { repo_root: string?, branch: string?, by_path: table, readiness: 'cold'|'ready'|'partial', cached_at_ms: integer? }
function M.snapshot_now(cwd)
  cwd = cwd or vim.fn.getcwd()
  local gs = _git_status_mod()
  if not gs then
    -- auto-core absent → return an empty-but-valid shape. Views
    -- treat by_path={} as "no decorators" and render plain.
    return {
      repo_root  = nil,
      branch     = nil,
      by_path    = {},
      readiness  = "partial",
      cached_at_ms = nil,
    }
  end

  -- auto-core.git.status resolves cwd → repo_root internally. On
  -- cache miss it shells out to `git status --porcelain=v1` and
  -- caches the result; on hit it returns `(entries, cached_at_ms)`.
  local entries, cached_at_or_err = gs.get(cwd)
  if not entries then
    -- The "err" path covers "not in a git repo" and any shell
    -- failures. Either way, render plain.
    M._readiness = "partial"
    return {
      repo_root    = nil,
      branch       = nil,
      by_path      = {},
      readiness    = "partial",
      cached_at_ms = nil,
    }
  end

  -- entries are relative paths to the repo_root. We need the
  -- repo_root to build absolute paths for the path-keyed view.
  -- auto-core doesn't expose resolve_root publicly, but is_cached
  -- normalizes its arg the same way as get's resolve_root — so a
  -- subsequent is_cached(cwd) returns true after a successful get
  -- (the cache stores under the normalized root, which the next
  -- get-with-same-cwd hits without I/O).
  --
  -- For repo_root resolution, walk up cwd until we hit a dir
  -- containing `.git`. Mirrors auto-core's internal resolver
  -- without coupling us to its private surface.
  local repo_root = cwd
  while repo_root ~= "/" and repo_root ~= "" do
    if vim.uv.fs_stat(repo_root .. "/.git") then break end
    local parent = vim.fn.fnamemodify(repo_root, ":h")
    if parent == repo_root then break end
    repo_root = parent
  end
  if not vim.uv.fs_stat(repo_root .. "/.git") then
    -- Walked off the top without finding .git. auto-core returned
    -- entries somehow despite that — unusual; fall back to cwd as
    -- repo_root to keep by_path absolute paths usable.
    repo_root = cwd
  end

  M._readiness = "ready"
  return {
    repo_root    = repo_root,
    branch       = nil,  -- Phase 6+ refinement; auto-core doesn't expose yet
    by_path      = _denormalize(repo_root, entries),
    readiness    = "ready",
    cached_at_ms = (type(cached_at_or_err) == "number")
      and cached_at_or_err or nil,
  }
end

---@param cwd string?
---@param cb fun(snapshot: table)
function M.snapshot_async(cwd, cb)
  if M._readiness == "ready" or M._readiness == "partial" then
    vim.schedule(function() cb(M.snapshot_now(cwd)) end)
    return
  end
  -- Wait for the next auto-finder.core.git:changed event, then
  -- fire. (Phase 4's `auto-finder.core.ready` topic is for files;
  -- git readiness has no equivalent "global ready" signal — it's
  -- per-repo and populates on first query.)
  local events_mod = require("auto-finder.core.events")
  local handle
  handle = events_mod.subscribe("auto-finder.core.git:changed", function()
    events_mod.unsubscribe(handle)
    cb(M.snapshot_now(cwd))
  end)
  -- And trigger one query now so snapshot_now's first call doesn't
  -- block waiting forever on a never-firing event.
  vim.schedule(function() M.snapshot_now(cwd) end)
end

---Single-path lookup. Resolves the repo_root containing `abs_path`
---and queries auto-core.git.status. Returns nil if the path isn't
---tracked or isn't in a git repo.
---@param abs_path string
---@return { x: string, y: string, code: string }|nil
function M.get(abs_path)
  if type(abs_path) ~= "string" or abs_path == "" then return nil end
  -- Walk up from abs_path to find the repo. Use the parent dir if
  -- abs_path is itself a file.
  local probe = abs_path
  if not vim.uv.fs_stat(probe .. "/.git") then
    probe = vim.fn.fnamemodify(abs_path, ":h")
    while probe ~= "/" and probe ~= "" do
      if vim.uv.fs_stat(probe .. "/.git") then break end
      local parent = vim.fn.fnamemodify(probe, ":h")
      if parent == probe then break end
      probe = parent
    end
  end
  if not vim.uv.fs_stat(probe .. "/.git") then return nil end
  local snap = M.snapshot_now(probe)
  return snap.by_path[abs_path]
end

---Drop the auto-core cache for `cwd`'s repo. The next snapshot_now
---triggers a fresh shell-out. Soft-fails if auto-core is absent.
---@param cwd string?
function M.invalidate(cwd)
  local gs = _git_status_mod()
  if not gs or type(gs.invalidate) ~= "function" then return end
  if cwd then
    gs.invalidate(cwd)
  else
    gs.invalidate()
  end
end

---Set the area readiness. Called by core's translator on
---`core.git.state:changed` (drops to 'cold' so the next snapshot
---triggers a re-query).
---@param r 'cold'|'ready'|'partial'
function M._set_readiness(r)
  M._readiness = r
end

---Test-only: reset internal state. Does NOT touch the
---auto-core.git.status cache (use `M.invalidate()` for that).
function M._reset_for_tests()
  M._readiness = "cold"
end

return M
