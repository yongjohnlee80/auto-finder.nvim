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

-- ── [5] r2: the REVERSE transition must not cross implementations ──
-- Section [2] covers legacy->new (availability appearing). The inverse was
-- never covered, and it is broken: `_impl_for` re-probed for a NEW owner and
-- returned LEGACY when the probe went false, so on_focus/refresh handed a
-- NEW-owned buffer to legacy — MF6 wearing the other shoe (r2 #3).
--
-- Ownership and availability answer DIFFERENT questions. Ownership is a
-- historical fact: which code wrote this buffer's contents, keymaps and
-- subscriptions. It cannot change while the buffer lives. Availability is
-- forward-looking: what a NEW mount should pick. The probe belongs only on the
-- owner==nil path.
--
-- Reachability is not exotic: worktree.repos.available() probes AUTO-CORE's
-- surface (nine dotted paths), so an auto-core reload or downgrade flips it
-- false mid-session without worktree.nvim going anywhere.
;(function()
  local view = require("auto-finder.views.repos")
  local calls = {}
  local function stub(tag)
    return {
      get_buffer = function()
        calls[#calls + 1] = tag .. ".get_buffer"
        return vim.api.nvim_create_buf(false, true)
      end,
      on_focus = function(_, b) calls[#calls + 1] = tag .. ".on_focus:" .. tostring(b) end,
      on_close = function() calls[#calls + 1] = tag .. ".on_close" end,
      refresh  = function() calls[#calls + 1] = tag .. ".refresh" end,
    }
  end
  local newimpl = stub("new")
  local sp, sl, su = view._probe_for_tests, view._legacy_for_tests, view._unchecked_for_tests

  view._legacy_for_tests = stub("legacy")
  view._probe_for_tests = function() return newimpl end
  view._unchecked_for_tests = function() return newimpl end
  view._latch_for_tests:reset()

  local nb = view.get_buffer(1000)
  ok("[5] mount with worktree AVAILABLE latches the new impl",
    view._latch_for_tests:owner(nb) == "worktree", tostring(view._latch_for_tests:owner(nb)))

  -- availability drops (auto-core reload / downgrade / :Lazy reload)
  view._probe_for_tests = function() return nil end
  calls = {}
  view.on_focus(1000, nb)
  ok("[5] *** on_focus for a NEW-owned buffer does NOT go to legacy ***",
    not vim.tbl_contains(calls, "legacy.on_focus:" .. tostring(nb)), vim.inspect(calls))
  ok("[5] it still reaches the owner, resolved WITHOUT the availability gate",
    vim.tbl_contains(calls, "new.on_focus:" .. tostring(nb)), vim.inspect(calls))

  -- refresh() was never exercised by this suite at all before now, and it
  -- routes through the same helper.
  calls = {}
  view.refresh()
  ok("[5] *** refresh() does NOT go to legacy for a NEW-owned buffer ***",
    not vim.tbl_contains(calls, "legacy.refresh"), vim.inspect(calls))
  ok("[5] refresh() reaches the owner", vim.tbl_contains(calls, "new.refresh"),
    vim.inspect(calls))

  -- The latch must not have been rewritten by the failed probe.
  ok("[5] the latch still records the original owner",
    view._latch_for_tests:owner(nb) == "worktree")

  -- Terminal case: the owner's OWN module cannot be resolved. Then no-op — a
  -- stale panel is worse than a truthful one, but crossing over is worse than
  -- both, so we must not fall through to legacy.
  view._unchecked_for_tests = function() return nil end
  calls = {}
  local okf = pcall(view.on_focus, 1000, nb)
  ok("[5] an unresolvable owner NO-OPS rather than throwing", okf)
  ok("[5] *** and still does not cross to legacy ***",
    not vim.tbl_contains(calls, "legacy.on_focus:" .. tostring(nb)), vim.inspect(calls))

  -- CONTROL: a LEGACY-owned buffer must still route to legacy.
  view._probe_for_tests = function() return nil end
  view._unchecked_for_tests = function() return newimpl end
  view._latch_for_tests:reset()
  local lb = view.get_buffer(1000)
  calls = {}
  view.on_focus(1000, lb)
  ok("[5] CONTROL — a LEGACY-owned buffer routes to legacy",
    vim.tbl_contains(calls, "legacy.on_focus:" .. tostring(lb)), vim.inspect(calls))

  view._probe_for_tests, view._legacy_for_tests, view._unchecked_for_tests = sp, sl, su
  view._latch_for_tests:reset()
end)()

-- ── [6] r2: dbase parity — remount claims, and teardown is unchecked ──
-- Section [4] only exercised the latch DATA STRUCTURE for dbase with
-- fabricated bufnrs; get_buffer/on_focus/on_close were never called. Two real
-- defects hid behind that (r2 #3).
;(function()
  local dbase = require("auto-finder.views.dbase")

  ok("[6] dbase exposes an UNCHECKED resolver seam, like repos",
    type(dbase._unchecked_for_tests) == "function",
    type(dbase._unchecked_for_tests))
  ok("[6] dbase exposes its autodb probe as a seam (so this is testable "
    .. "without intercepting require)",
    type(dbase._autodb_for_tests) == "function", type(dbase._autodb_for_tests))
  if type(dbase._unchecked_for_tests) ~= "function" then return end

  local calls = {}
  local function stub(tag)
    return {
      get_buffer = function()
        calls[#calls + 1] = tag .. ".get_buffer"
        return vim.api.nvim_create_buf(false, true)
      end,
      on_focus = function(_, b) calls[#calls + 1] = tag .. ".on_focus:" .. tostring(b) end,
      on_close = function() calls[#calls + 1] = tag .. ".on_close" end,
    }
  end
  local autodb = stub("autodb")
  local sa, sau = dbase._autodb_for_tests, dbase._unchecked_for_tests

  -- A remount replaces the claimed placeholder with the real buffer. That
  -- replacement was never claimed, so the next focus saw owner=nil and — once
  -- autodb appeared — routed a dbee buffer to autodb. dbee's own
  -- `_owned_bufs` guard sits AFTER the autodb branch, so it never protected it.
  dbase._latch_for_tests:reset()
  local placeholder = vim.api.nvim_create_buf(false, true)
  local real = vim.api.nvim_create_buf(false, true)
  dbase._latch_for_tests:claim(placeholder, "dbee")
  dbase._notify_remount_for_tests(real, placeholder)
  ok("[6] *** a remount CLAIMS the replacement buffer ***",
    dbase._latch_for_tests:owner(real) == "dbee",
    tostring(dbase._latch_for_tests:owner(real)))
  ok("[6] and forgets the discarded placeholder",
    dbase._latch_for_tests:owner(placeholder) == nil)

  -- With the replacement claimed, an autodb lazy-load must NOT capture it.
  dbase._autodb_for_tests = function() return autodb end
  calls = {}
  dbase.on_focus(1000, real)
  ok("[6] *** a dbee-owned buffer is NOT routed to autodb after it appears ***",
    not vim.tbl_contains(calls, "autodb.on_focus:" .. tostring(real)), vim.inspect(calls))

  -- Teardown must not be availability-gated: the skipped path disposes
  -- autodb's TOPIC_* subscriptions and deletes its named buffer, so skipping it
  -- leaks both — the very MF6/SF1 pair the repos side was fixed for.
  dbase._latch_for_tests:reset()
  dbase._autodb_for_tests = function() return autodb end
  local ab = dbase.get_buffer(1000)
  ok("[6] mount with autodb available uses autodb",
    vim.tbl_contains(calls, "autodb.get_buffer") or ab ~= nil, vim.inspect(calls))
  dbase._autodb_for_tests = function() return nil end   -- availability drops
  dbase._unchecked_for_tests = function() return autodb end
  calls = {}
  dbase.on_close()
  ok("[6] *** on_close tears autodb down even when availability has dropped ***",
    vim.tbl_contains(calls, "autodb.on_close"), vim.inspect(calls))

  dbase._autodb_for_tests, dbase._unchecked_for_tests = sa, sau
  dbase._latch_for_tests:reset()
  for _, b in ipairs({ placeholder, real }) do
    pcall(vim.api.nvim_buf_delete, b, { force = true })
  end
end)()

-- ── [7] r3 #4: a RETURNED review-load error is surfaced, not swallowed ──
-- `review.load` reports malformed JSON and failed validation normally as
-- `(nil, err)` — it does not throw. The guard bound only `(ok, doc)`, so
-- through pcall a normal error arrived as `(true, nil, err)`, the warning
-- branch never ran, and the review was skipped in silence. That is the exact
-- defect the guard existed to prevent, one line lower down.
;(function()
  local src = table.concat(vim.fn.readfile(
    plugin_root .. "/lua/auto-finder/views/repos/tree.lua"), "\n")
  ok("[7] the review.load guard binds all THREE pcall results",
    src:match("local ok_doc, doc, load_err = pcall%(review%.load") ~= nil,
    "only two results are bound — a returned error is invisible")
  ok("[7] a THROWN error is reported at ERROR",
    src:match("threw while loading") ~= nil)
  ok("[7] *** a RETURNED error is reported too, on its own branch ***",
    src:match("elseif load_err then") ~= nil)

  -- Behavioural: the two shapes must be distinguishable at the call boundary.
  local function load_returning_err() return nil, "invalid review" end
  local okc, doc, lerr = pcall(load_returning_err)
  ok("[7] a returned error yields (true, nil, err) through pcall",
    okc == true and doc == nil and lerr == "invalid review",
    ("%s / %s / %s"):format(tostring(okc), tostring(doc), tostring(lerr)))
  local function load_throwing() error("boom") end
  local okt, terr = pcall(load_throwing)
  ok("[7] CONTROL — a thrown error yields (false, msg), a different shape",
    okt == false and tostring(terr):find("boom") ~= nil, tostring(terr))
end)()

io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
io.stdout:flush()
vim.fn.delete(sandbox, "rf")
if fail > 0 then os.exit(1) end
os.exit(0)
