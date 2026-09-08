-- ADR-0060 §2.3 — a WATCHED worktree gets a live watcher (2026-09-09).
--
-- §2.3: "An unwatched worktree costs one parse_porcelain line — no git log, no
-- git status, no watcher." The contrapositive is the contract: a WATCHED
-- worktree DOES get a watcher, so an external commit / file change refreshes
-- the repos panel without a manual unwatch/rewatch.
--
-- Measured before this suite: marking a worktree watched armed NOTHING.
-- `auto-core.git.watch` was disabled in core/watchers.lua (ADR-0060 §2.8
-- removed the files-panel watcher and named a "per-worktree opt-in" that was
-- never built), and `fs.watch` was armed only for `cwd`. So a watched worktree
-- that was not the cwd had no live watcher at all — exactly the "I have to
-- unwatch and watch again" report.
--
-- Built on a REAL bare-ish git layout; only the timing-sensitive fs_event
-- delivery is simulated (by publishing the upstream topic the armed watcher
-- would publish), so the suite asserts the WIRING deterministically rather
-- than racing libuv.
--
-- Run headless:  nvim --headless -u NONE -l tests/adr0060-repos-live-watch.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
local sib = vim.fn.fnamemodify(root, ":h:h")
local branch_dir = vim.fn.fnamemodify(root, ":t")
for _, p in ipairs({ LAZY .. "/nui.nvim", LAZY .. "/plenary.nvim" }) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end
local REQUIRED = {
  ["worktree.nvim"]  = { "lua/worktree/watch.lua", "worktree.watch:changed" },
  ["auto-core.nvim"] = { "lua/auto-core/git/watch.lua", "core.git.state:changed" },
}
for _, plugin in ipairs({ "worktree.nvim", "auto-core.nvim" }) do
  local req = REQUIRED[plugin]
  local function serves(r)
    local f = r .. "/" .. req[1]
    if vim.fn.filereadable(f) ~= 1 then return false end
    for _, line in ipairs(vim.fn.readfile(f)) do
      if line:find(req[2], 1, true) then return true end
    end
    return false
  end
  local candidates, fallback = {}, nil
  for _, r in ipairs({ LAZY .. "/" .. plugin,
                       sib .. "/" .. plugin .. "/main",
                       sib .. "/" .. plugin .. "/" .. branch_dir }) do
    if vim.fn.isdirectory(r) == 1 then
      if serves(r) then candidates[#candidates + 1] = r
      elseif not fallback then fallback = r end
    end
  end
  if #candidates == 0 and fallback then candidates[1] = fallback end
  for _, r in ipairs(candidates) do vim.opt.runtimepath:prepend(r) end
end
vim.opt.runtimepath:prepend(root)
vim.o.columns, vim.o.lines = 200, 60
local sb = vim.fn.tempname() .. "-livewatch"
dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/_sandbox.lua")("livewatch")

local pass, fail = 0, 0
local function ok(n, c, d)
  if c then pass = pass + 1; print("  PASS  " .. n)
  else fail = fail + 1; print("  FAIL  " .. n .. (d and ("  — " .. tostring(d)) or "")) end
end

-- ─── a real repo with a linked worktree, and a SECOND repo not watched ──────
local lab = sb .. "/lab"; vim.fn.mkdir(lab, "p")
local function G(dir, ...)
  local a = { "git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t",
    "-c", "init.defaultBranch=main" }
  for _, x in ipairs({ ... }) do a[#a + 1] = x end
  return vim.system(a, { text = true }):wait()
end

local proj = lab .. "/proj"; vim.fn.mkdir(proj, "p")
G(proj, "init", "-q")
vim.fn.writefile({ "base" }, proj .. "/a.txt")
G(proj, "add", "."); G(proj, "commit", "-q", "-m", "base")
G(proj, "worktree", "add", "-q", "-b", "feature", lab .. "/feature")
local fwt = lab .. "/feature"

local core_git = require("auto-core.git")
local git_watch = core_git.watch
local watch = require("worktree.watch")
watch._reset_for_tests()
require("worktree.repos")._reset_for_tests()
require("worktree").set_root(lab)

-- The git_dir of the linked worktree is the thing a watcher must cover.
local repo = require("auto-core.git.repo")
local fwt_gitdir = repo.git_dir(fwt)
ok("precondition: the worktree's git_dir resolves",
  type(fwt_gitdir) == "string" and fwt_gitdir ~= "", tostring(fwt_gitdir))

local function git_watch_covers(git_dir)
  for _, h in ipairs(git_watch.list() or {}) do
    if h.git_dir and require("auto-core.fs.path").normalize(h.git_dir)
        == require("auto-core.fs.path").normalize(git_dir) then
      return true
    end
  end
  return false
end

-- Capture the topic the repos view actually re-renders on.
local events = require("auto-core.events")
local repos_changed = 0
events.subscribe("auto-finder.core.repos:changed", function()
  repos_changed = repos_changed + 1
end)

-- Start the auto-finder core so the translator + the per-watch reconciler are
-- live. cwd is NOT the watched worktree, which is the whole point.
git_watch.stop_all()
require("auto-finder.core").ensure_started({})

-- ─── [1] watching a worktree arms a live git watcher on it ──────────────────

print("\n[1] a watched worktree gets a git.watch on its own git_dir")
do
  ok("[1] precondition: nothing is watched yet, nothing armed",
    git_watch_covers(fwt_gitdir) == false)

  -- Mark it watched exactly as the panel's `w` key does (worktree.watch.set →
  -- publishes worktree.watch:changed). Then let the scheduled reconcile run.
  watch.set(fwt, true)
  vim.wait(200, function() return git_watch_covers(fwt_gitdir) end)

  ok("[1] *** marking a worktree watched ARMS a git.watch on its git_dir ***",
    git_watch_covers(fwt_gitdir) == true,
    "handles: " .. vim.inspect(vim.tbl_map(function(h) return h.git_dir end, git_watch.list() or {})))
end

-- ─── [2] an external commit refreshes the panel, no manual re-watch ─────────

print("\n[2] the armed watcher folds through to a repos refresh")
do
  -- Simulate what the armed git.watch publishes when HEAD moves in the watched
  -- worktree. (The real fs_event is timing-sensitive; the WIRING is what the
  -- fix is about, and it is deterministic.) If arming worked, the existing
  -- translation chain must carry this to the view's topic.
  local before = repos_changed
  events.publish("core.git.state:changed", {
    repo_root = fwt, git_dir = fwt_gitdir, kind = "reflog",
    path = fwt_gitdir .. "/logs/HEAD",
  })
  vim.wait(200, function() return repos_changed > before end)
  ok("[2] *** a git-state change on the watched worktree refreshes repos ***",
    repos_changed > before,
    ("repos_changed %d -> %d"):format(before, repos_changed))

  -- End-to-end with a REAL commit, best-effort within a bounded wait: the armed
  -- fs_event should fire on its own. Tolerated to be slow (libuv), so this is
  -- informational-strong rather than the load-bearing cell.
  local before2 = repos_changed
  vim.fn.writefile({ "one" }, fwt .. "/new.txt")
  G(fwt, "add", "."); G(fwt, "commit", "-q", "-m", "external commit")
  vim.wait(1500, function() return repos_changed > before2 end)
  ok("[2] a REAL external commit refreshes repos (best-effort, libuv-timed)",
    repos_changed > before2,
    ("repos_changed %d -> %d (if this alone fails, the watcher armed but the fs_event was slow)"):format(before2, repos_changed))
end

-- ─── [3] unwatching stops the watcher ───────────────────────────────────────

print("\n[3] unwatching a worktree stops its watcher")
do
  watch.set(fwt, false)
  vim.wait(200, function() return git_watch_covers(fwt_gitdir) == false end)
  ok("[3] *** unwatch stops the git.watch on that worktree ***",
    git_watch_covers(fwt_gitdir) == false,
    "handles: " .. vim.inspect(vim.tbl_map(function(h) return h.git_dir end, git_watch.list() or {})))
end

-- ─── [4] the UNCOMMITTED row: working-tree edits under a watched worktree ───

print("\n[4] a working-tree file change under a watched worktree refreshes repos")
do
  watch.set(fwt, true)
  vim.wait(200, function() return git_watch_covers(fwt_gitdir) end)

  -- A file change UNDER the watched worktree must refresh repos (so the
  -- UNCOMMITTED row can appear/disappear on its own). A change OUTSIDE any
  -- watched worktree must NOT — the repos panel does not react to unrelated
  -- file churn (the whole point of scoped watches).
  local before = repos_changed
  events.publish("core.file:upsert", { path = fwt .. "/edited.txt", change = "upsert" })
  vim.wait(200, function() return repos_changed > before end)
  ok("[4] *** an edit under the watched worktree refreshes repos ***",
    repos_changed > before,
    ("repos_changed %d -> %d"):format(before, repos_changed))

  local before2 = repos_changed
  events.publish("core.file:upsert", { path = sb .. "/somewhere-else/x.txt", change = "upsert" })
  vim.wait(150, function() return false end)
  ok("[4] *** an edit OUTSIDE every watched worktree does NOT refresh repos ***",
    repos_changed == before2,
    ("repos_changed %d -> %d (should be unchanged)"):format(before2, repos_changed))

  -- And the working-tree watcher is actually armed on a non-cwd watched
  -- worktree (otherwise the real fs_event above could never arrive).
  local ok_w, watchers = pcall(require, "auto-finder.core.watchers")
  local fs_covered = ok_w and type(watchers.has_worktree_fs_watch) == "function"
    and watchers.has_worktree_fs_watch(fwt) == true
  ok("[4] a working-tree fs.watch is armed on the non-cwd watched worktree",
    fs_covered,
    "watched worktrees: " .. vim.inspect(ok_w and watchers.watched_worktrees() or nil))
end

-- ─── [5] a BURST of edits coalesces to a single refresh ─────────────────────

print("\n[5] a burst of working-tree edits collapses to one repos refresh")
do
  -- A `git checkout` / mass edit fires one core.file:* per file. Firing
  -- repos:changed per file would schedule a rerender each; the fold coalesces
  -- a burst to a single refresh (the render re-reads the whole worktree).
  vim.wait(150, function() return false end)  -- let any pending debounce settle
  local before = repos_changed
  for i = 1, 12 do
    events.publish("core.file:upsert",
      { path = fwt .. "/burst-" .. i .. ".txt", change = "upsert" })
  end
  -- Wait past the debounce window and assert EXACTLY one refresh, not twelve.
  vim.wait(250, function() return repos_changed > before end)
  vim.wait(120, function() return false end)  -- catch any stragglers
  ok("[5] *** twelve rapid edits produce exactly ONE refresh ***",
    repos_changed == before + 1,
    ("repos_changed %d -> %d (want +1)"):format(before, repos_changed))
end

require("auto-finder.core").stop()
vim.fn.delete(sb, "rf")
io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
