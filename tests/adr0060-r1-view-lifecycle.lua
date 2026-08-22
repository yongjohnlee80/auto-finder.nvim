-- tests/adr0060-r1-view-lifecycle.lua — ADR-0060 r1 MF6 + SF1.
--
-- Run:  nvim --headless -u NONE -l tests/adr0060-r1-view-lifecycle.lua
--
-- WHY A STANDALONE SUITE, NOT A smoke.lua SECTION
-- smoke.lua aborts at p46 (nil-buffer throw in buf_text), so anything appended
-- after that point reports nothing and protects nothing. That truncation is its
-- own tracked task; these pins live where they actually execute. Same reasoning
-- as tests/v0267-loop-guard.lua.
--
-- MF6 — the repos view probed worktree.nvim's availability PER HOOK, while
-- auto-core's section registry caches the first valid buffer and does not call
-- get_buffer again. So a mid-session lazy-load of worktree.nvim sent the NEW
-- tree's on_focus the CACHED LEGACY buffer: it rendered into a foreign buffer
-- while its own _bufnr stayed nil, which hard-gates _rerender — freezing the
-- tree entirely, expand/collapse included. Reachable by construction in this
-- release: the installed worktree.nvim has no repos.lua, so every user mounts
-- legacy first, and the tag that adds repos.lua flips availability with no
-- restart.
--
-- SF1 — the new repos buffer was created with bufhidden=hide and on_close only
-- cleared the Lua pointer, so every close/reopen leaked a named buffer. Six
-- sibling views delete theirs; this one was a copy of dbase/tree.lua with the
-- delete dropped.

local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
local plugins = vim.fn.fnamemodify(plugin_root, ":h:h")
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
-- ORDER MATTERS. `prepend` pushes to the front, so the LAST entry here wins the
-- lookup. Installed copies are listed FIRST and the development worktrees LAST,
-- so this suite tests the code in this checkout. Getting this backwards made
-- `require("worktree.repos")` resolve against the INSTALLED v0.4.10 — which has
-- no repos.lua — and silently skipped section [3] entirely.
for _, p in ipairs({
  LAZY .. "/nui.nvim", LAZY .. "/plenary.nvim",
  LAZY .. "/auto-core.nvim", LAZY .. "/worktree.nvim",
  plugins .. "/auto-core.nvim/main",
  plugins .. "/worktree.nvim/main",
  plugin_root,
}) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end
vim.o.swapfile = false
local sandbox = vim.fn.tempname() .. "-r1life"
vim.env.XDG_CONFIG_HOME = sandbox .. "/cfg"
vim.env.XDG_STATE_HOME = sandbox .. "/state"

local pass, fail = 0, 0
---Writes with an explicit newline and flush rather than `print`.
---
---`print` under `nvim -l` can coalesce two records onto one line, and
---tests/run-all.sh counts `^  PASS` LINES — so a coalesced pair is counted once
---and the runner's total silently disagrees with the suite's own summary. One
---assertion, one line, always.
local function ok(name, cond, detail)
  local line
  if cond then
    pass = pass + 1
    line = "  PASS  " .. name
  else
    fail = fail + 1
    line = "  FAIL  " .. name .. (detail and ("  — " .. tostring(detail)) or "")
  end
  io.stdout:write(line:gsub("[\r\n]+", " "), "\n")
  io.stdout:flush()
end

io.stdout:write("ADR-0060 r1 — view lifecycle (MF6 implementation latch, SF1 buffer leak)\n")
io.stdout:flush()

-- ── [1] the shared latch primitive ──
;(function()
  local okm, latch = pcall(require, "auto-finder.shared.impl_latch")
  ok("[1] shared.impl_latch loads", okm, tostring(latch))
  if not okm then return end

  local L = latch.new("probe")
  local b1, b2 = 101, 202
  L:claim(b1, "legacy")
  L:claim(b2, "new")
  ok("[1] a claimed buffer reports its owner", L:owner(b1) == "legacy")
  ok("[1] a second buffer keeps its own owner", L:owner(b2) == "new")
  ok("[1] an unknown buffer has no owner", L:owner(999) == nil)
  L:forget(b1)
  ok("[1] forget() drops just that entry",
    L:owner(b1) == nil and L:owner(b2) == "new")
  L:reset()
  ok("[1] reset() clears everything", L:owner(b2) == nil)
  ok("[1] claim(nil) is ignored rather than throwing",
    (pcall(function() L:claim(nil, "x") end)))
end)()

-- ── [2] MF6: the implementation is latched to the buffer it produced ──
-- Drives the REAL wrapper. `_probe_for_tests` is swapped so availability can be
-- flipped the way a lazy load would, without needing worktree.nvim absent.
;(function()
  local view = require("auto-finder.views.repos")
  ok("[2] the wrapper exposes a latch for tests",
    type(view._latch_for_tests) == "table", type(view._latch_for_tests))

  local calls = {}
  local function stub(tag)
    return {
      get_buffer = function()
        calls[#calls + 1] = tag .. ".get_buffer"
        local b = vim.api.nvim_create_buf(false, true)
        return b
      end,
      on_focus = function(_, bufnr) calls[#calls + 1] = tag .. ".on_focus:" .. tostring(bufnr) end,
      on_close = function() calls[#calls + 1] = tag .. ".on_close" end,
      refresh  = function() calls[#calls + 1] = tag .. ".refresh" end,
    }
  end
  local newimpl = stub("new")
  local saved_probe, saved_legacy = view._probe_for_tests, view._legacy_for_tests
  local saved_unchecked = view._unchecked_for_tests

  view._legacy_for_tests = stub("legacy")
  view._probe_for_tests = function() return nil end     -- worktree NOT available
  view._unchecked_for_tests = function() return newimpl end
  view._latch_for_tests:reset()

  local bufnr = view.get_buffer(1000)
  ok("[2] mount with worktree unavailable uses the legacy path",
    calls[1] == "legacy.get_buffer", vim.inspect(calls))
  ok("[2] and the latch records legacy as that buffer's owner",
    view._latch_for_tests:owner(bufnr) == "legacy",
    tostring(view._latch_for_tests:owner(bufnr)))

  -- worktree.nvim lazy-loads: availability flips mid-session.
  view._probe_for_tests = function() return newimpl end
  calls = {}
  view.on_focus(1000, bufnr)
  ok("[2] *** on_focus for the LEGACY buffer still routes to LEGACY ***",
    calls[1] == "legacy.on_focus:" .. tostring(bufnr), vim.inspect(calls))
  ok("[2] *** the new tree is NOT handed a buffer it did not create ***",
    not vim.tbl_contains(calls, "new.on_focus:" .. tostring(bufnr)), vim.inspect(calls))

  -- A fresh mount (registry cache cleared, e.g. after a panel close) SHOULD
  -- pick the new implementation — the latch must not pin the choice forever.
  calls = {}
  local nb = view.get_buffer(1000)
  ok("[2] CONTROL — a NEW mount does select the new implementation",
    calls[1] == "new.get_buffer", vim.inspect(calls))
  ok("[2] CONTROL — and the latch records the new owner",
    view._latch_for_tests:owner(nb) == "worktree",
    tostring(view._latch_for_tests:owner(nb)))
  calls = {}
  view.on_focus(1000, nb)
  ok("[2] CONTROL — on_focus for the new buffer routes to the NEW impl",
    calls[1] == "new.on_focus:" .. tostring(nb), vim.inspect(calls))

  -- MF6 corollary: on_close was ALSO probe-gated, so on the reverse transition
  -- the inactive implementation's on_close never ran and its buffer plus its
  -- event subscriptions leaked permanently.
  calls = {}
  view._probe_for_tests = function() return nil end   -- worktree gone again
  -- ...but the unchecked resolver still finds it: teardown of something we
  -- mounted must not be gated on it still being MOUNTABLE.
  view.on_close()
  ok("[2] *** on_close closes BOTH implementations regardless of the probe ***",
    vim.tbl_contains(calls, "new.on_close") and vim.tbl_contains(calls, "legacy.on_close"),
    vim.inspect(calls))
  ok("[2] and the latch is cleared so a remount re-decides",
    view._latch_for_tests:owner(nb) == nil)

  view._probe_for_tests, view._legacy_for_tests = saved_probe, saved_legacy
  view._unchecked_for_tests = saved_unchecked
  view._latch_for_tests:reset()
end)()

-- ── [3] SF1: the repos buffer does not leak on close ──
;(function()
  -- A skip that cannot be told apart from a pass is how coverage disappears.
  -- If this checkout HAS repos.lua then availability is mandatory, and anything
  -- else is a broken harness that must fail loudly rather than skip.
  local dev_repos = plugins .. "/worktree.nvim/main/lua/worktree/repos.lua"
  local have_dev = vim.fn.filereadable(dev_repos) == 1
  local okw, wrepos = pcall(require, "worktree.repos")
  local avail = okw and type(wrepos.available) == "function" and wrepos.available()
  if have_dev then
    ok("[3] the DEV worktree.nvim is the one under test (not the installed copy)",
      avail == true,
      "repos.lua exists at " .. dev_repos .. " but available()="
        .. tostring(avail) .. " — runtimepath order is wrong")
  end
  if not avail then
    ok("[3] SKIPPED — no worktree.nvim with repos.lua on this machine", not have_dev,
      "the dev tree exists, so this must NOT be skipped")
    return
  end
  local tree = require("auto-finder.views.repos.tree")

  local function live_repos_bufs()
    local n = 0
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b)
        and vim.api.nvim_buf_get_name(b):match("auto%-finder://repos") then n = n + 1 end
    end
    return n
  end

  local before = live_repos_bufs()
  local b = tree.get_buffer(vim.api.nvim_get_current_win())
  ok("[3] get_buffer creates a named scratch buffer",
    b ~= nil and vim.api.nvim_buf_is_valid(b))
  ok("[3] and it is bufhidden=hide (wipe would die on a section switch)",
    vim.bo[b].bufhidden == "hide", vim.bo[b].bufhidden)
  tree.on_close()
  ok("[3] on_close clears the module pointer", tree._bufnr == nil)
  ok("[3] *** and DELETES the buffer (SF1: it used to survive) ***",
    not vim.api.nvim_buf_is_valid(b))

  -- Unbounded growth was the real symptom: one leaked buffer per cycle, each
  -- named, so they pile up in :ls and the bufferline too.
  for _ = 1, 6 do
    local bb = tree.get_buffer(vim.api.nvim_get_current_win())
    if bb then tree.on_close() end
  end
  ok("[3] *** six close/reopen cycles leak NOTHING ***",
    live_repos_bufs() == before,
    "before=" .. before .. " after=" .. live_repos_bufs())

  -- CONTROL: the checker can actually see a live repos buffer, so the zero
  -- above is a measurement and not a blind instrument.
  local held = tree.get_buffer(vim.api.nvim_get_current_win())
  ok("[3] CONTROL — the leak checker DOES observe a live repos buffer",
    live_repos_bufs() == before + 1,
    "before=" .. before .. " with_one=" .. live_repos_bufs())
  tree.on_close()
  ok("[3] CONTROL — and it returns to baseline after close",
    live_repos_bufs() == before)
  local _ = held
end)()

-- ── [4] the dbase slot carries the SAME latch (r1 MF6, already shipped) ──
-- The identical per-hook-probe structure went out in v0.3.4 and is latent only
-- because autodb.session happens to be installed, so that probe is true from
-- the first call and never transitions. Pinned here so it cannot rot back, and
-- so the mechanism stays shared rather than becoming a third copy.
;(function()
  local dbase = require("auto-finder.views.dbase")
  ok("[4] dbase exposes the same latch type as repos",
    type(dbase._latch_for_tests) == "table", type(dbase._latch_for_tests))
  ok("[4] and it is a DISTINCT instance from the repos slot's",
    dbase._latch_for_tests ~= require("auto-finder.views.repos")._latch_for_tests)

  dbase._latch_for_tests:reset()
  dbase._latch_for_tests:claim(7001, "dbee")
  ok("[4] a dbee-owned buffer reports dbee", dbase._latch_for_tests:owner(7001) == "dbee")
  dbase._latch_for_tests:claim(7002, "autodb")
  ok("[4] an autodb-owned buffer reports autodb",
    dbase._latch_for_tests:owner(7002) == "autodb")
  dbase._latch_for_tests:reset()

  -- Neither the latch nor the key constants may leak as globals — the
  -- local-vs-global scoping trap that has bitten this project before.
  ok("[4] no `_latch` global leaked from dbase", rawget(_G, "_latch") == nil)
  ok("[4] no key-constant globals leaked",
    rawget(_G, "DBEE") == nil and rawget(_G, "AUTODB") == nil
      and rawget(_G, "NEW") == nil and rawget(_G, "LEGACY") == nil)

  -- prune() must drop dead buffers so a long session cannot grow the map, and
  -- a recycled bufnr cannot inherit a stale owner.
  local real = vim.api.nvim_create_buf(false, true)
  dbase._latch_for_tests:claim(real, "dbee")
  vim.api.nvim_buf_delete(real, { force = true })
  dbase._latch_for_tests:prune()
  ok("[4] prune() forgets buffers nvim has destroyed",
    dbase._latch_for_tests:owner(real) == nil)
  -- CONTROL: prune must not drop a LIVE claim.
  local alive = vim.api.nvim_create_buf(false, true)
  dbase._latch_for_tests:claim(alive, "dbee")
  dbase._latch_for_tests:prune()
  ok("[4] CONTROL — prune() keeps a live claim",
    dbase._latch_for_tests:owner(alive) == "dbee")
  vim.api.nvim_buf_delete(alive, { force = true })
  dbase._latch_for_tests:reset()
end)()

io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
io.stdout:flush()
vim.fn.delete(sandbox, "rf")
if fail > 0 then os.exit(1) end
os.exit(0)
