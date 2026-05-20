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
  local git_watch = _git_watch_mod()
  if git_watch then
    local git_handle, git_err = git_watch.start(cwd)
    if git_handle then
      bundle.git = git_handle
    else
      pcall(function()
        require("auto-finder.log").debug("core.watchers",
          "git.watch start failed at " .. cwd .. ": " .. tostring(git_err))
      end)
    end
  end

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
end

---@return string[]  list of cwds currently being watched
function M.list()
  local out = {}
  for cwd in pairs(M._handles) do out[#out + 1] = cwd end
  return out
end

---Test-only: clear the handle map without stopping (used to
---simulate auto-core bus reset taking the underlying handles).
function M._reset_for_tests()
  M._handles = {}
end

return M
