-- tests/bench-files-panel.lua -- ADR-0060 P0 files-panel performance baseline.
--
-- WHY THIS EXISTS SEPARATELY FROM adr0059-e2e.lua
-- The ADR-0059 suite is a pass/fail regression gate on ROOT SCANS. ADR-0060
-- §2.8 removes the files panel's git layers entirely, and the thing that
-- change is supposed to buy back is not scan count -- it is GIT SUBPROCESSES,
-- WATCHERS and SUBSCRIPTIONS. None of those are measured anywhere today, so a
-- "no regression" claim after the trim would have nothing to stand on
-- (ADR-0060 §2.8: capture the baseline BEFORE the trim, or there is no guard).
--
-- This harness therefore MEASURES rather than asserts. It emits one JSON
-- document so a later run can be diffed field-by-field.
--
-- Run (baseline, before the trim):
--   nvim --headless -u NONE -l tests/bench-files-panel.lua
--   BENCH_OUT=tests/.bench-files-panel.baseline.json \
--     nvim --headless -u NONE -l tests/bench-files-panel.lua
--
-- Compare (after the trim):
--   BENCH_OUT=tests/.bench-files-panel.after.json \
--     nvim --headless -u NONE -l tests/bench-files-panel.lua
--   BENCH_BASE=tests/.bench-files-panel.baseline.json \
--     BENCH_OUT=tests/.bench-files-panel.after.json \
--     nvim --headless -u NONE -l tests/bench-files-panel.lua
--
-- A/B across worktrees, same as the ADR-0059 harness:
--   AF=../main AC=../../auto-core.nvim/main nvim --headless -u NONE -l tests/bench-files-panel.lua
--
-- Exit code is 0 unless the harness could not measure (a broken instrument is
-- a failure; a slow panel is data). With BENCH_BASE set it also exits non-zero
-- on a REGRESSION -- any counted metric materially worse than the baseline.

-- ── bootstrap (mirrors tests/adr0059-e2e.lua, which is proven) ────────
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
local self_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
local plugins_root = vim.fn.fnamemodify(self_root, ":h:h")
local AF = os.getenv("AF") or self_root
local AC = os.getenv("AC")
if not AC then
  for _, cand in ipairs({
    plugins_root .. "/auto-core.nvim/main",
    LAZY .. "/auto-core.nvim",
  }) do
    if vim.fn.isdirectory(cand) == 1 then AC = cand; break end
  end
end
assert(AC, "no auto-core checkout found; set AC")
for _, p in ipairs({ AF, LAZY .. "/nui.nvim", LAZY .. "/plenary.nvim", AC }) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end

vim.o.columns, vim.o.lines = 200, 60
vim.o.swapfile, vim.o.hidden = false, true
-- Resolve output paths BEFORE the chdir below: a relative BENCH_OUT would
-- otherwise land inside the sandbox, which is deleted at the end.
local BENCH_OUT = os.getenv("BENCH_OUT")
if BENCH_OUT then BENCH_OUT = vim.fn.fnamemodify(BENCH_OUT, ":p") end
local BENCH_BASE = os.getenv("BENCH_BASE")
if BENCH_BASE then BENCH_BASE = vim.fn.fnamemodify(BENCH_BASE, ":p") end

local sandbox = vim.fn.tempname() .. "-bench0060"
vim.env.XDG_CONFIG_HOME = sandbox .. "/cfg"
vim.env.XDG_STATE_HOME  = sandbox .. "/state"
vim.env.AUTO_FINDER_DBASE_DISABLE_CRYPTO = "1"

local function die(msg)
  print("BENCH-BROKEN: " .. msg)
  vim.cmd("cq")
end

-- ── attribution state ────────────────────────────────────────────────
-- Declared HERE, above the fixture's git() helper, and not down with the
-- instruments: Lua binds `HARNESS` at compile time, so a helper defined above
-- the local would assign a GLOBAL of the same name while note_git read the
-- local -- and every harness call would be misattributed to the panel.
local HARNESS = false
local harness_seen = 0

-- ── a REAL git repo to measure against ───────────────────────────────
-- Git cost only materialises inside a repo, so the sandbox must be one.
local root = sandbox .. "/repo"
vim.fn.mkdir(root .. "/src/deep", "p")
vim.fn.mkdir(root .. "/collapsed/deep", "p")
vim.fn.mkdir(root .. "/.auto-agents/mailbox/inst/agent/outbox", "p")
for i = 1, 40 do
  vim.fn.writefile({ "line " .. i }, root .. "/src/f" .. i .. ".lua")
end
vim.fn.writefile({ "root" }, root .. "/existing.txt")
vim.fn.writefile({ "*.ignored" }, root .. "/.gitignore")
vim.fn.writefile({ "x" }, root .. "/junk.ignored")

local function git(...)
  local args = { "git", "-C", root, ... }
  HARNESS = true
  local r = vim.system(args, { text = true }):wait()
  HARNESS = false
  return r.code, (r.stdout or "") .. (r.stderr or "")
end
if vim.fn.executable("git") ~= 1 then die("git not on PATH") end
git("init", "-q")
git("config", "user.email", "bench@example.com")
git("config", "user.name", "bench")
git("add", "-A")
git("commit", "-qm", "baseline")
-- leave real dirt so status has work to do
vim.fn.writefile({ "dirty" }, root .. "/src/f1.lua")
vim.fn.writefile({ "new" }, root .. "/untracked.txt")

vim.fn.chdir(root)

-- ── instruments ──────────────────────────────────────────────────────
-- (1) git subprocesses. neotree shells git through several doors:
--     vim.fn.system / systemlist (git/init.lua:250, git/watch.lua),
--     vim.system (auto-core), and jobstart via utils.job. Count every
--     door, keyed by which one, so a later reading is comparable even if
--     the call path changes.
local git_calls = { total = 0, by_door = {}, argv = {} }
local function is_git(cmd)
  local s
  if type(cmd) == "table" then
    s = tostring(cmd[1] or "")
    if s:match("git$") or s:match("git%.exe$") then
      return true, table.concat(vim.tbl_map(tostring, cmd), " ")
    end
    s = table.concat(vim.tbl_map(tostring, cmd), " ")
  else
    s = tostring(cmd)
  end
  if s:match("^%s*git%s") or s:match("[/\\]git%s") then return true, s end
  return false, s
end
-- HARNESS is true while the harness itself shells git (building the fixture,
-- driving a scenario). Those calls are not the panel's and must not be counted
-- as its cost -- but they ARE what proves the instrument can still see git,
-- which is the positive control below.
local function note_git(door, cmd)
  local yes, s = is_git(cmd)
  if not yes then return end
  if HARNESS then harness_seen = harness_seen + 1; return end
  git_calls.by_door[door] = (git_calls.by_door[door] or 0) + 1
  -- `vim.system` is implemented OVER uv.spawn, so a single call trips both
  -- doors. Counting each would double every vim.system-originated git call, so
  -- the total counts real spawn points only; by_door still records everything
  -- for diagnosis.
  if door == "vim.system" then return end
  git_calls.total = git_calls.total + 1
  if #git_calls.argv < 60 then git_calls.argv[#git_calls.argv + 1] = s:sub(1, 120) end
end

local uv = vim.uv or vim.loop
local orig = {
  system      = vim.system,
  fn_system   = vim.fn.system,
  fn_slist    = vim.fn.systemlist,
  fn_jobstart = vim.fn.jobstart,
  uv_spawn    = uv.spawn,
}
vim.system = function(cmd, ...) note_git("vim.system", cmd); return orig.system(cmd, ...) end
vim.fn.system = function(cmd, ...) note_git("vim.fn.system", cmd); return orig.fn_system(cmd, ...) end
vim.fn.systemlist = function(cmd, ...) note_git("vim.fn.systemlist", cmd); return orig.fn_slist(cmd, ...) end
vim.fn.jobstart = function(cmd, ...) note_git("jobstart", cmd); return orig.fn_jobstart(cmd, ...) end
-- uv.spawn is THE door neotree's async git status uses (utils.job ->
-- uv.spawn at neotree/utils/init.lua:1742). Patching only the vim.* doors
-- measured 0 git calls for every file write -- a false negative that would
-- have made the post-trim comparison show no improvement. Verify the
-- instrument before trusting a negative reading.
uv.spawn = function(path, opts, on_exit)
  local argv = { path }
  for _, a in ipairs((opts or {}).args or {}) do argv[#argv + 1] = a end
  note_git("uv.spawn", argv)
  return orig.uv_spawn(path, opts, on_exit)
end

-- Positive control, fired the moment the doors are in place: one deliberate
-- git call attributed to the harness. If the patched doors do not observe
-- THIS, they observe nothing, and every measurement below is meaningless.
HARNESS = true
vim.system({ "git", "--version" }, {}):wait()
HARNESS = false

-- (2) mount the panel and time it
local ok_af, af = pcall(require, "auto-finder")
if not ok_af then die("auto-finder did not load: " .. tostring(af)) end
af.setup({})

local t0 = vim.uv.hrtime()
af.open(true)
af.focus(1)
local files_section = require("auto-finder.sections").resolve(1)
local mounted = vim.wait(4000, function()
  return files_section and files_section._bufnr ~= nil
    and vim.api.nvim_buf_is_valid(files_section._bufnr)
end)
if not mounted then die("files panel never mounted") end
vim.wait(900) -- initial scan + watcher start settle
local mount_ms = math.floor((vim.uv.hrtime() - t0) / 1e6)
local mount_git = git_calls.total
-- Instrument self-check -- a POSITIVE control, not an assumption about the
-- panel.
--
-- The original check treated "0 git at mount" as proof the instrument was
-- blind. That was right before ADR-0060 §2.8 and WRONG after it: with git
-- removed from the files panel, zero is the GOAL, and success became
-- indistinguishable from a moved spawn door. So prove the door works with a
-- call the harness makes itself -- the fixture ran git init/add/commit through
-- `git()`, attributed to HARNESS but still passing through every patched door.
-- If none were seen, the instrument is blind and no reading here means
-- anything.
if harness_seen == 0 then
  die("instrument blind: the harness ran git init/add/commit and the patched "
    .. "doors observed NONE of them. A spawn door moved -- re-check uv.spawn / "
    .. "vim.system / vim.fn.system / jobstart before trusting any reading.")
end

-- (3) root scans at the fs_scan chokepoint (same probe as ADR-0059)
local ok_fs, fs_scan = pcall(require, "auto-finder.neotree.sources.filesystem.lib.fs_scan")
if not ok_fs then die("fs_scan not reachable") end
local orig_get_items = fs_scan.get_items
local root_scans = 0
fs_scan.get_items = function(state, parent_id, ...)
  if parent_id == nil then root_scans = root_scans + 1 end
  return orig_get_items(state, parent_id, ...)
end

-- (4) how many git-flavoured subscriptions the panel is holding
local function subscription_census()
  local out = { auto_core = {}, neotree = {} }
  local ok_ev, ev = pcall(require, "auto-core.events")
  if ok_ev and type(ev.count_subscribers) == "function" then
    for _, topic in ipairs({
      "core.git.state:changed", "auto-finder.core.git:changed",
      "core.git.worktree:added", "core.git.worktree:destroyed",
      "auto-finder.core.files:changed", "worktree:switched",
    }) do
      local ok_c, n = pcall(ev.count_subscribers, topic)
      out.auto_core[topic] = ok_c and n or nil
    end
  end
  -- Reads neo-tree's REAL subscriber count. This used to reach for
  -- `rawget(nev, "subscriptions")` / `"event_handlers"`, neither of which
  -- exists — neo-tree keeps handlers in a module-local `event_queues` inside
  -- neotree/events/queue.lua. So the neo-tree census was EMPTY both before and
  -- after the ADR-0060 git-subscription removal: an artifact that looked like a
  -- measurement, sitting inside the evidence for that removal (r1 SF5).
  -- `count_subscribers` was added to the fork to make it observable.
  local ok_ne, nev = pcall(require, "auto-finder.neotree.events")
  if ok_ne and type(nev.count_subscribers) == "function" then
    for _, name in ipairs({ "GIT_EVENT", "GIT_STATUS_CHANGED", "FS_EVENT", "BEFORE_GIT_STATUS" }) do
      local id = nev[name]
      if id then out.neotree[name] = nev.count_subscribers(id) end
    end
    out.neotree_blind = false
  else
    -- Say so loudly rather than reporting an empty table that reads as zero.
    out.neotree_blind = true
  end
  return out
end

-- ── scenarios ────────────────────────────────────────────────────────
local SETTLE = 3200 -- > SETTLE_QUIET_MS(1500) + REFRESH_THROTTLE_MS(800)
local scenarios = {}
local function scenario(label, body)
  git_calls.total, root_scans = 0, 0
  local s0 = vim.uv.hrtime()
  body()
  vim.wait(SETTLE)
  local rec = {
    label = label,
    git_calls = git_calls.total,
    root_scans = root_scans,
    elapsed_ms = math.floor((vim.uv.hrtime() - s0) / 1e6),
  }
  scenarios[#scenarios + 1] = rec
  print(string.format("  %-52s git=%-4d scans=%-3d %dms",
    label, rec.git_calls, rec.root_scans, rec.elapsed_ms))
  return rec
end

print("\nADR-0060 P0 — files-panel baseline")
print("AF=" .. vim.fn.fnamemodify(AF, ":t") .. "  AC=" .. vim.fn.fnamemodify(AC, ":t"))
print(string.format("  %-52s git=%-4d          %dms", "mount (initial render)", mount_git, mount_ms))

scenario("idle (no activity)", function() end)
scenario("write an EXISTING visible file", function()
  vim.fn.writefile({ "one", "two" }, root .. "/existing.txt")
end)
scenario("write inside a COLLAPSED dir", function()
  vim.fn.writefile({ "x" }, root .. "/collapsed/new.txt")
end)
scenario("BULK 200 files into a COLLAPSED dir", function()
  for i = 1, 200 do
    vim.fn.writefile({ "x" }, root .. "/collapsed/deep/f" .. i .. ".txt")
  end
end)
scenario("agent mailbox writes (20)", function()
  for i = 1, 20 do
    vim.fn.writefile({ "{}" },
      root .. "/.auto-agents/mailbox/inst/agent/outbox/m" .. i .. ".json")
  end
end)
-- the git-specific ones: an INDEX change is what the git watchers exist for
scenario("git add (index change)", function() git("add", "-A") end)
scenario("git commit", function() git("commit", "-qm", "bench") end)
-- The files view is built with `live_refresh`, NOT `core_refresh_topic`, so
-- `section.refresh` may not exist on it (build_section only attaches that in
-- the core-refresh path). Drive neo-tree's real refresh and record which door
-- was reachable, so a 0 here is never mistaken for "refresh is free".
local refresh_door = "none"
scenario("panel refresh (manager.refresh)", function()
  if files_section and type(files_section.refresh) == "function" then
    refresh_door = "section.refresh"
    pcall(files_section.refresh)
    return
  end
  local ok_m, mgr = pcall(require, "auto-finder.neotree.sources.manager")
  if ok_m and type(mgr.refresh) == "function" then
    refresh_door = "manager.refresh"
    pcall(mgr.refresh, "filesystem")
  end
end)

-- CONTROL. At least one scenario MUST scan, else scans=0 everywhere would
-- mean the pipeline is dead rather than efficient (the same false-negative
-- class as the uv.spawn door).
local control = scenario("CONTROL new file in the VISIBLE root", function()
  vim.fn.writefile({ "x" }, root .. "/appeared.txt")
end)
if control.root_scans < 1 then
  die("instrument blind: the CONTROL new-file-in-visible-root did not scan, "
    .. "so scans=0 elsewhere proves nothing about efficiency.")
end

fs_scan.get_items = orig_get_items
vim.system, vim.fn.system, vim.fn.systemlist, vim.fn.jobstart =
  orig.system, orig.fn_system, orig.fn_slist, orig.fn_jobstart
uv.spawn = orig.uv_spawn

-- ── report ───────────────────────────────────────────────────────────
local subs = subscription_census()
local total_git = mount_git
for _, s in ipairs(scenarios) do total_git = total_git + s.git_calls end

local report = {
  schema = "auto-finder.bench.files-panel/1",
  adr = "0060",
  af = vim.fn.fnamemodify(AF, ":t"),
  ac = vim.fn.fnamemodify(AC, ":t"),
  mount = { ms = mount_ms, git_calls = mount_git },
  scenarios = scenarios,
  totals = { git_calls = total_git },
  instrument = { harness_git_seen = harness_seen },
  git_doors = git_calls.by_door,
  refresh_door = refresh_door,
  subscriptions = subs,
  sample_git_argv = git_calls.argv,
}

print(string.format("\n  instrument control: %d harness git calls seen "
  .. "(proves the doors are live)", harness_seen))
print("── census ──")
print("  total git subprocesses: " .. total_git)
for door, n in pairs(git_calls.by_door) do print(string.format("    %-18s %d", door, n)) end
print("  git-flavoured subscriptions:")
for t, n in pairs(subs.auto_core) do print(string.format("    auto-core %-34s %s", t, tostring(n))) end
for t, n in pairs(subs.neotree) do print(string.format("    neotree   %-34s %s", t, tostring(n))) end

local out_path = BENCH_OUT
if out_path then
  local fd = io.open(out_path, "w")
  if fd then
    fd:write(vim.json.encode(report)); fd:close()
    print("\n  wrote " .. out_path)
  else
    print("\n  WARN could not write " .. tostring(out_path))
  end
end

-- ── optional regression gate ─────────────────────────────────────────
local failed = false
local base_path = BENCH_BASE
if base_path and vim.fn.filereadable(base_path) == 1 then
  local ok_j, base = pcall(vim.json.decode, table.concat(vim.fn.readfile(base_path), "\n"))
  if ok_j and type(base) == "table" then
    print("\n── vs baseline (" .. base_path .. ") ──")
    local function cmp(label, now, was, tol)
      if type(was) ~= "number" then return end
      local worse = now > was + (tol or 0)
      if worse then failed = true end
      print(string.format("  %-6s %-44s %d -> %d", worse and "WORSE" or "ok", label, was, now))
    end
    cmp("total git subprocesses", total_git, base.totals and base.totals.git_calls, 0)
    cmp("mount git subprocesses", mount_git, base.mount and base.mount.git_calls, 0)
    -- mount time is wall-clock and noisy; allow 40% headroom
    local base_ms = base.mount and base.mount.ms
    if type(base_ms) == "number" then
      cmp("mount ms", mount_ms, base_ms, math.floor(base_ms * 0.4))
    end
    local by_label = {}
    for _, s in ipairs(base.scenarios or {}) do by_label[s.label] = s end
    for _, s in ipairs(scenarios) do
      local b = by_label[s.label]
      if b then
        cmp("scans: " .. s.label, s.root_scans, b.root_scans, 0)
        cmp("git:   " .. s.label, s.git_calls, b.git_calls, 0)
      end
    end
  end
end

-- ── ABSOLUTE post-P6 invariants ──────────────────────────────────────
-- The baseline comparison above pins the IMPROVEMENT; it cannot pin the
-- INVARIANT. Against the P0 baseline of 13 total / 7 at mount, a regression to
-- 5 git subprocesses still reads "ok" — and with BENCH_BASE unset there is no
-- gate at all. Post-P6 the files panel must issue ZERO git subprocesses, so
-- assert zero absolutely and unconditionally (r1 SF5).
print("\n── absolute post-P6 invariants ──")
local function must_be_zero(label, n)
  local bad = type(n) ~= "number" or n ~= 0
  if bad then failed = true end
  print(string.format("  %-6s %-44s %s", bad and "VIOLATED" or "ok", label, tostring(n)))
end
must_be_zero("total git subprocesses == 0", total_git)
must_be_zero("mount git subprocesses == 0", mount_git)
for _, s in ipairs(scenarios) do
  must_be_zero("git == 0: " .. s.label, s.git_calls)
end

-- Subscription invariants. ADR-0060 §2.8 removed exactly these three neo-tree
-- git subscriptions plus auto-finder's translated git topic.
local subs = subscription_census()
if subs.neotree_blind then
  failed = true
  print("  VIOLATED neo-tree census is BLIND — the numbers below prove nothing")
else
  for _, name in ipairs({ "GIT_EVENT", "GIT_STATUS_CHANGED", "FS_EVENT" }) do
    must_be_zero("neotree " .. name .. " subscribers == 0", subs.neotree[name] or 0)
  end
end
must_be_zero("auto-finder.core.git:changed subscribers == 0",
  subs.auto_core["auto-finder.core.git:changed"] or 0)

-- NOT zero, deliberately: `core.git.state:changed` STAYS as a direct upstream
-- subscription through v0.2.x (shared/neotree.lua's own comment), and ADR-0060
-- §2.8 never listed it. Pinned to its expected count so neither a silent
-- removal nor a new duplicate slips through — a blanket "all git subscriptions
-- are zero" assertion would have failed on day one.
do
  local n = subs.auto_core["core.git.state:changed"]
  local expected = 2
  local bad = type(n) ~= "number" or n ~= expected
  if bad then failed = true end
  print(string.format("  %-6s %-44s %s (expected %d, deliberately NOT zero)",
    bad and "VIOLATED" or "ok", "core.git.state:changed subscribers", tostring(n), expected))
end

-- POSITIVE CONTROL for the census itself: a zero above must mean "nobody is
-- subscribed", not "this instrument cannot see subscribers". Register a canary
-- on one of the very topics asserted zero and confirm the census counts it.
do
  local ok_ne, nev = pcall(require, "auto-finder.neotree.events")
  if ok_ne and type(nev.count_subscribers) == "function" then
    nev.subscribe({ event = nev.GIT_EVENT, id = "bench-census-canary",
                    handler = function() end })
    local seen = subscription_census().neotree.GIT_EVENT or 0
    nev.unsubscribe({ event = nev.GIT_EVENT, id = "bench-census-canary",
                      handler = function() end })
    if seen < 1 then
      failed = true
      print("  VIOLATED census control: a real GIT_EVENT subscriber was NOT seen"
        .. " — every zero above is meaningless")
    else
      print("  ok     census control: a real subscriber IS observed (" .. seen .. ")")
    end
  else
    failed = true
    print("  VIOLATED census control: count_subscribers is unavailable")
  end
end

vim.fn.delete(sandbox, "rf")
print(failed and "\nRESULT: REGRESSION vs baseline" or "\nRESULT: measured")
vim.cmd(failed and "cq" or "qa!")
