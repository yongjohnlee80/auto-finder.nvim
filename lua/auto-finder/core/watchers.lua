---auto-finder.core.watchers — every libuv watcher auto-finder holds (ADR-0026 A2).
---
---Two kinds, both owned here so no view opens a handle itself:
---
---  * per-DIRECTORY watches for the files slot (ADR-0200 §4.4): one non-recursive
---    `fs.watch` per directory the view has expanded, only while it is shown. Owner-
---    scoped: a directory stays watched while any owner still wants it.
---      watchers.watch_dir(path, owner) / unwatch_dir(path, owner) / unwatch_owner(owner)
---      watchers.is_dir_watched(path) / dir_watch_count(owner?)
---  * per-WORKTREE watches for the repos panel (ADR-0060 §2.3): one `git.watch` for
---    commits/checkouts and one recursive working-tree `fs.watch` for the UNCOMMITTED
---    row, for each worktree in worktree.nvim's watch registry.
---      watchers.reconcile_watched()
---
---  watchers.close_all()           — full teardown (core.stop)
---@module 'auto-finder.core.watchers'

local M = {}

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

-- ── per-DIRECTORY watches (files slot, ADR-0200 §4.4) ──────────────────────────
M._dirs = {}  -- { [path] = { handle = <fs.watch handle>, owners = { [owner] = true } } }

---Watch `path` (non-recursive) on behalf of `owner`. Idempotent per (path, owner).
---@param path string
---@param owner any
---@return boolean ok
function M.watch_dir(path, owner)
  local d = M._dirs[path]
  if d then
    d.owners[owner] = true
    return true
  end
  local fs_watch = _fs_watch_mod()
  if not fs_watch then return false end
  -- ignore = {}: fs.watch's default list (/build/, /dist/, /target/, …) matches the FULL path, so an
  -- expanded build/ — or any cwd below such a directory — would never update. One non-recursive watch
  -- reports only direct children, and `.git` is never listed, so there is nothing here to filter.
  local h = fs_watch.start(path, { recursive = false, self_extend = false, ignore = {} })
  if not h then return false end
  M._dirs[path] = { handle = h, owners = { [owner] = true } }
  return true
end

---Stop watching `path` for `owner`; the handle closes when no owner is left.
function M.unwatch_dir(path, owner)
  local d = M._dirs[path]
  if not d then return end
  d.owners[owner] = nil
  if next(d.owners) == nil then
    local fs_watch = _fs_watch_mod()
    if fs_watch then pcall(fs_watch.stop, d.handle) end
    M._dirs[path] = nil
  end
end

---Release every directory `owner` holds.
function M.unwatch_owner(owner)
  local paths = {}
  for path, d in pairs(M._dirs) do if d.owners[owner] then paths[#paths + 1] = path end end
  for _, path in ipairs(paths) do M.unwatch_dir(path, owner) end
end

---@param path string
---@return boolean
function M.is_dir_watched(path) return M._dirs[path] ~= nil end

---Number of directory watches, all or those `owner` holds.
function M.dir_watch_count(owner)
  local n = 0
  for _, d in pairs(M._dirs) do
    if owner == nil or d.owners[owner] then n = n + 1 end
  end
  return n
end

-- ── per-REPO git watches (git.watch: `.git/HEAD` + index), refcounted by owner ─────────────────────
-- The files slot holds one for each repo whose colours it shows, so a commit / add / checkout run from a
-- terminal (no working-tree event) still recolours; the repos slot holds one per watched worktree
-- (`_repo_git` below). A path watched by both shares one handle.
M._gits = {}  -- { [path] = { handle = <git.watch handle>, owners = { [owner] = true } } }

---@param path string  repo / worktree root
---@param owner any
---@return boolean ok
function M.watch_git(path, owner)
  local g = M._gits[path]
  if g then
    g.owners[owner] = true
    return true
  end
  local git_watch = _git_watch_mod()
  if not git_watch then return false end
  local h = git_watch.start(path)   -- resolves the per-worktree git_dir
  if not h then return false end
  M._gits[path] = { handle = h, owners = { [owner] = true } }
  return true
end

function M.unwatch_git(path, owner)
  local g = M._gits[path]
  if not g then return end
  g.owners[owner] = nil
  if next(g.owners) == nil then
    local git_watch = _git_watch_mod()
    if git_watch then pcall(git_watch.stop, g.handle) end
    M._gits[path] = nil
  end
end

function M.unwatch_git_owner(owner)
  local paths = {}
  for path, g in pairs(M._gits) do if g.owners[owner] then paths[#paths + 1] = path end end
  for _, path in ipairs(paths) do M.unwatch_git(path, owner) end
end

---Number of git watches, all or those `owner` holds.
function M.git_watch_count(owner)
  local n = 0
  for _, g in pairs(M._gits) do
    if owner == nil or g.owners[owner] then n = n + 1 end
  end
  return n
end

---Stop every watcher this module opened. Used by `core.stop` at session teardown.
function M.close_all()
  local fs_watch = _fs_watch_mod()
  for path, d in pairs(M._dirs) do
    if fs_watch then pcall(fs_watch.stop, d.handle) end
    M._dirs[path] = nil
  end
  M.close_watched()
  local git_watch = _git_watch_mod()
  for path, g in pairs(M._gits) do
    if git_watch then pcall(git_watch.stop, g.handle) end
    M._gits[path] = nil
  end
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
-- handles plus one recursive working-tree `fs.watch`.
--
-- Repos-owned handle maps, keyed by absolute worktree PATH:
M._repo_git = {}  -- { [path] = <git.watch handle> } — the repos owner's entries in `_gits`
local REPOS = "repos.watched"
M._repo_fs  = {}  -- { [path] = <fs.watch handle> }

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
---working-tree watch can make that row appear on its own. Every watched
---worktree gets one; the files slot no longer walks the cwd (ADR-0200), so
---nothing else covers it.
function M.reconcile_watched()
  local git_watch = _git_watch_mod()
  local fs_watch  = _fs_watch_mod()
  local want = _watched_set()

  -- git.watch: arm the newly-wanted, stop the no-longer-wanted (shared with the files slot's holds).
  if git_watch then
    for path in pairs(want) do
      if not M._repo_git[path] and M.watch_git(path, REPOS) then M._repo_git[path] = M._gits[path].handle end
    end
    for path in pairs(M._repo_git) do
      if not want[path] then
        M.unwatch_git(path, REPOS)
        M._repo_git[path] = nil
      end
    end
  end

  -- Working-tree fs.watch: exactly one handle per watched path.
  if fs_watch then
    for path in pairs(want) do
      if not M._repo_fs[path] then
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
---@return boolean  is a working-tree fs.watch live for `path`
function M.has_worktree_fs_watch(path)
  return M._repo_fs[path] ~= nil
end

---Stop every per-worktree watcher (git + working-tree). Folded into
---`close_all` so `core.stop` tears the whole set down.
function M.close_watched()
  local fs_watch  = _fs_watch_mod()
  for path in pairs(M._repo_git) do
    M.unwatch_git(path, REPOS)   -- the handle survives while the files slot still holds it
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
  M._dirs = {}
  M._gits = {}
  M._repo_git = {}
  M._repo_fs = {}
end

return M
