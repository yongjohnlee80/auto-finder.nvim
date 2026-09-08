---auto-finder.core.watchers — fs.watch + git.watch handle owner.
---
---Owns every libuv-backed watcher auto-finder uses. Today these
---are scattered across the section modules; ADR 0026 Phase 4
---centralizes fs.watch ownership here so handles survive section
---switches and panel-close events. Phase 5 will add git.watch
---ownership alongside.
---
---Lifecycle hooks (called from `auto-finder.core.ensure_started`
---and `core.stop`):
---
---  watchers.open_for(cwd)   — start fs.watch (Phase 4)
---                              + git.watch (Phase 5, deferred)
---  watchers.close_for(cwd)  — stop the pair (used on reload)
---  watchers.close_all()     — full teardown (used on core.stop)
---  watchers.list()          — list of watched cwds
---
---Handle-cap degradation (ADR §2.6): when
---`auto-core.fs.watch.start` returns an error indicating
---max_handles exhaustion, log warn to `auto-finder.core.watchers`
---per [[auto-family-logging]] AND publish
---`auto-finder.core.ready` with payload `areas.files = 'partial'`
---so subscribers (the warmer + future views) can surface a "live
---refresh limited" badge. Manual `:AutoFinderReload` / `R` still
---works regardless.
---
---**Phase 4 status: fs.watch ownership lands.** Phase 5 adds
---git.watch. Phase 7 wires graceful degradation telemetry into
---the new view mount contract.
---
---@module 'auto-finder.core.watchers'

local M = {}

-- Per-cwd handle map. Phase 4 populates `fs`; Phase 5 adds `git`.
--   { [cwd] = { fs = <handle>, git = <handle>? }, … }
M._handles = {}

---@return table|nil  auto-core.fs.watch module, or nil if absent
local function _fs_watch_mod()
  local ok, core = pcall(require, "auto-core")
  if not ok or type(core) ~= "table"
      or type(core.fs) ~= "table"
      or type(core.fs.watch) ~= "table"
      or type(core.fs.watch.start) ~= "function" then
    return nil
  end
  return core.fs.watch
end

---@return table|nil  auto-core.git.watch module, or nil if absent
---auto-core ≥ v0.1.19 ships git.watch; older versions return nil
---here and we silently skip the .git/-plumbing watcher. The
---decorator path remains correct (git status pulls via
---neo-tree's bundled git query); it's just less responsive to
---external commits.
local function _git_watch_mod()
  local ok, core = pcall(require, "auto-core")
  if not ok or type(core) ~= "table"
      or type(core.git) ~= "table"
      or type(core.git.watch) ~= "table"
      or type(core.git.watch.start) ~= "function" then
    return nil
  end
  return core.git.watch
end

---Start fs.watch for `cwd`. Idempotent — re-call returns the
---existing handle bundle without re-opening. Soft-fails if
---auto-core's fs.watch surface isn't loadable.
---@param cwd string
---@return table|nil bundle  { fs = <handle> } or nil on failure
function M.open_for(cwd)
  if M._handles[cwd] then return M._handles[cwd] end
  local fs_watch = _fs_watch_mod()
  if not fs_watch then return nil end

  local bundle = {}

  -- Working-tree fs.watch. Recursive walk per the existing
  -- shared/neotree.lua semantics. Open first so a partial-
  -- coverage signal lands before we attempt git.watch (which
  -- doesn't have a max_handles failure mode of its own — it's
  -- the three narrow handles ADR 0025 added).
  local fs_handle, fs_err = fs_watch.start(cwd, { recursive = true })
  if fs_handle then
    bundle.fs = fs_handle
  else
    local err_str = tostring(fs_err)
    pcall(function()
      require("auto-finder.log").warn("core.watchers",
        "fs.watch start failed at " .. cwd .. ": " .. err_str)
    end)
    if err_str:match("max_handles") then
      pcall(function()
        require("auto-finder.core.files")._set_readiness("partial")
        require("auto-finder.core.events").publish(
          "auto-finder.core.ready",
          { areas = { files = "partial" } })
      end)
    end
  end

  -- `.git/`-plumbing watcher (ADR 0025). Soft-deps on
  -- auto-core ≥ v0.1.19. If cwd isn't in a git repo, the
  -- auto-core side returns nil + err; we log debug (routine,
  -- not an error) and proceed with just the working-tree
  -- watcher. The git decorator path still works via neo-tree's
  -- bundled git query — Phase 5 ships the real cache.
  -- ADR-0060 §2.8: no git.watch. It existed so the files panel could
  -- re-decorate when the index moved (ADR-0025); the panel no longer
  -- decorates by git, so the handle would fire into nothing. The repos panel
  -- watches per-worktree and opt-in instead (§2.3). `bundle.git` stays in the
  -- shape so M.list() and close_for() are unchanged for any caller that still
  -- reads it.

  -- Only register the bundle if at least one watcher came up.
  -- An entry with both handles nil is indistinguishable from
  -- "never tried" and pollutes M.list().
  if bundle.fs or bundle.git then
    M._handles[cwd] = bundle
    return bundle
  end
  return nil
end

---Stop the fs.watch + git.watch handles for `cwd`. No-op if
---`cwd` isn't being watched. Idempotent.
---@param cwd string
function M.close_for(cwd)
  local bundle = M._handles[cwd]
  if not bundle then return end
  local fs_watch  = _fs_watch_mod()
  local git_watch = _git_watch_mod()
  if fs_watch and bundle.fs and type(fs_watch.stop) == "function" then
    pcall(fs_watch.stop, bundle.fs)
  end
  if git_watch and bundle.git and type(git_watch.stop) == "function" then
    pcall(git_watch.stop, bundle.git)
  end
  M._handles[cwd] = nil
end

---Stop every fs.watch + git.watch handle this module opened.
---Used by `core.stop` at session teardown.
function M.close_all()
  local fs_watch  = _fs_watch_mod()
  local git_watch = _git_watch_mod()
  for cwd, bundle in pairs(M._handles) do
    if fs_watch and bundle.fs and type(fs_watch.stop) == "function" then
      pcall(fs_watch.stop, bundle.fs)
    end
    if git_watch and bundle.git and type(git_watch.stop) == "function" then
      pcall(git_watch.stop, bundle.git)
    end
    M._handles[cwd] = nil
  end
  -- The per-watched-worktree set too (ADR-0060 §2.3), so a session teardown
  -- leaves no live handle behind.
  M.close_watched()
end

---@return string[]  list of cwds currently being watched
function M.list()
  local out = {}
  for cwd in pairs(M._handles) do out[#out + 1] = cwd end
  return out
end

-- ── per-WATCHED-WORKTREE live watchers (ADR-0060 §2.3) ────────────────
--
-- §2.3 says an UNWATCHED worktree gets "no watcher"; the contract is that a
-- WATCHED one does. §2.8 removed the old files-panel git watcher and named a
-- "per-worktree opt-in" replacement — which was never built, so marking a
-- worktree watched armed nothing and its panel went stale on every external
-- commit / file change until a manual unwatch+rewatch (Johno, 2026-09-09).
--
-- This reconciler is that opt-in. It is bounded by design: only a few
-- worktrees are watched, and each costs `git.watch`'s two narrow `.git/`
-- handles plus — for a worktree the files panel is NOT already watching — one
-- recursive working-tree `fs.watch`. Nothing here touches the files-panel
-- `cwd` watcher in `M._handles`.
--
-- Repos-owned handle maps, keyed by absolute worktree PATH:
M._repo_git = {}  -- { [path] = <git.watch handle> }
M._repo_fs  = {}  -- { [path] = <fs.watch handle> }  (only where cwd isn't already covering it)

---The set of currently-watched worktree paths, from worktree.nvim's registry.
---Empty (not an error) when worktree.nvim is absent.
---@return table<string, boolean>
local function _watched_set()
  local set = {}
  local ok, watch = pcall(require, "worktree.watch")
  if ok and type(watch.list) == "function" then
    local okl, list = pcall(watch.list)
    if okl and type(list) == "table" then
      for _, p in ipairs(list) do
        if type(p) == "string" and p ~= "" then set[p] = true end
      end
    end
  end
  return set
end

---reconcile_watched brings the per-worktree watcher set in line with the
---registry: arm what is newly watched, stop what is no longer. Idempotent, so
---it is safe to call on startup and on every `worktree.watch:changed`.
---
---The git watcher is the primary fix — `core.git.state:changed` already
---translates to a repos refresh, so arming it is all commit / checkout / reset
---/ merge need. The working-tree fs watcher exists for the UNCOMMITTED row:
---an unstaged edit touches neither `.git/HEAD` nor the index, so only a
---working-tree watch can make that row appear on its own. It is skipped for a
---worktree the files panel is ALREADY watching (`M._handles[path]`), so `cwd`
---is never double-watched.
function M.reconcile_watched()
  local git_watch = _git_watch_mod()
  local fs_watch  = _fs_watch_mod()
  local want = _watched_set()

  -- git.watch: arm the newly-wanted, stop the no-longer-wanted.
  if git_watch then
    for path in pairs(want) do
      if not M._repo_git[path] then
        local h = git_watch.start(path)   -- resolves the per-worktree git_dir
        if h then M._repo_git[path] = h end
      end
    end
    for path, h in pairs(M._repo_git) do
      if not want[path] then
        pcall(git_watch.stop, h)
        M._repo_git[path] = nil
      end
    end
  end

  -- Working-tree fs.watch: arm only where the files panel is not already
  -- covering the path (that map is `M._handles`, keyed by the same absolute
  -- path). Skipping the overlap keeps `cwd` on a single handle and leaves the
  -- files-panel watcher's lifecycle untouched.
  if fs_watch then
    for path in pairs(want) do
      if not M._repo_fs[path] and not M._handles[path] then
        local h = fs_watch.start(path, { recursive = true })
        if h then M._repo_fs[path] = h end
      end
    end
    for path, h in pairs(M._repo_fs) do
      if not want[path] then
        pcall(fs_watch.stop, h)
        M._repo_fs[path] = nil
      end
    end
  end
end

---is_working_tree_watched reports whether `path` lies under a worktree the
---repos panel is watching — the predicate the core translator uses to decide
---whether a `core.file:*` event should refresh the repos panel. Prefix-matched
---on a normalized path, so a file deep inside a watched worktree counts and an
---unrelated edit elsewhere does not.
---@param path string
---@return boolean
function M.is_under_watched_worktree(path)
  if type(path) ~= "string" or path == "" then return false end
  local ok_p, path_mod = pcall(require, "auto-core.fs.path")
  local norm = (ok_p and type(path_mod.normalize) == "function") and path_mod.normalize
    or function(p) return p end
  local np = norm(path)
  for wt in pairs(_watched_set()) do
    local nwt = norm(wt)
    if np == nwt or np:sub(1, #nwt + 1) == nwt .. "/" then
      return true
    end
  end
  return false
end

---@return string[] worktree paths with a live per-worktree watcher (git or fs)
function M.watched_worktrees()
  local seen, out = {}, {}
  for path in pairs(M._repo_git) do if not seen[path] then seen[path] = true; out[#out + 1] = path end end
  for path in pairs(M._repo_fs) do if not seen[path] then seen[path] = true; out[#out + 1] = path end end
  return out
end

---@param path string
---@return boolean  is a working-tree fs.watch live for `path` (repos-owned OR the files-panel cwd handle)
function M.has_worktree_fs_watch(path)
  return M._repo_fs[path] ~= nil or M._handles[path] ~= nil
end

---Stop every per-worktree watcher (git + working-tree). Folded into
---`close_all` so `core.stop` tears the whole set down.
function M.close_watched()
  local git_watch = _git_watch_mod()
  local fs_watch  = _fs_watch_mod()
  for path, h in pairs(M._repo_git) do
    if git_watch then pcall(git_watch.stop, h) end
    M._repo_git[path] = nil
  end
  for path, h in pairs(M._repo_fs) do
    if fs_watch then pcall(fs_watch.stop, h) end
    M._repo_fs[path] = nil
  end
end

---Test-only: clear the handle map without stopping (used to
---simulate auto-core bus reset taking the underlying handles).
function M._reset_for_tests()
  M._handles = {}
  M._repo_git = {}
  M._repo_fs = {}
end

return M
