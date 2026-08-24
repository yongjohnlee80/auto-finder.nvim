-- tests/v0267-loop-guard.lua — regression pins for the v0.2.67 fixes that broke
-- the notification→refresh feedback loop.
--
-- WHY THIS IS A STANDALONE SUITE, NOT A smoke.lua SECTION
-- smoke.lua ABORTS partway through: p46's `buf_text()` calls
-- nvim_buf_get_lines(b, ...) with `b == nil` when the panel does not
-- materialise headlessly, which throws and takes the rest of the file with it.
-- Every section after that point is dead code — a pin appended there would
-- report nothing and protect nothing. tests/run-all.sh already documents the
-- same truncation for sections [42]-[47] and solves it the same way, so these
-- pins live where they actually execute.
--
-- Run:  nvim --headless -u NONE -l tests/v0267-loop-guard.lua
--
-- THE LOOP THESE FIXES BROKE. A slow root scan emits a "mapped X (N.Ns)"
-- toast -> snacks renders it as a real scratch buffer -> the notifier hides it
-- -> BufWipeout -> core.buffers published `buffers:changed` for ANY buffer ->
-- the buffers view refreshed -> `manager.refresh` IGNORED its `source_name` and
-- navigated EVERY windowed state, filesystem included -> full monorepo re-scan
-- -> slower scan -> new toast -> repeat. Measured: 1 event -> 4 root scans.
-- Latent from 2026-05-20; ignited once lm scans crossed the 1s toast threshold.

local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
local plugins = vim.fn.fnamemodify(plugin_root, ":h:h")
for _, p in ipairs({ plugin_root, LAZY .. "/nui.nvim", LAZY .. "/plenary.nvim",
                     plugins .. "/auto-core.nvim/main", LAZY .. "/auto-core.nvim" }) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end
vim.o.swapfile = false
local sandbox = vim.fn.tempname() .. "-v0267"
dofile(vim.fn.fnamemodify(debug.getinfo(1,"S").source:sub(2),":p:h").."/_sandbox.lua")("v0267")

local pass_count, fail_count = 0, 0
local function ok(name, cond, detail)
  if cond then
    pass_count = pass_count + 1
    print("  PASS  " .. name)
  else
    fail_count = fail_count + 1
    print("  FAIL  " .. name .. (detail and ("  — " .. tostring(detail)) or ""))
  end
end

print("v0.2.67 loop guard — scoped refresh, buffer filter, storm detector")

-- ── fix 1: manager.refresh MUST scope to its source_name ──
-- Unscoped, ONE buffers:changed navigated every windowed state including the
-- filesystem ones. This is a source-level assertion because the failure needs
-- multiple windowed states to reproduce behaviourally, which a headless run
-- cannot reliably build — but the gate itself is exactly what regressed.
;(function()
  local f = io.open(plugin_root .. "/lua/auto-finder/neotree/sources/manager.lua", "r")
  local src = f and f:read("*a") or ""
  if f then f:close() end
  local body = src:match("M%.refresh = function%(source_name.-\nend")
  ok("[v0267] manager.refresh takes a source_name", body ~= nil)
  ok("[v0267] and GATES on it (nil still means refresh-everything, for legacy callers)",
    body ~= nil
      and body:find("source_name == nil or state%.name == source_name", 1, false) ~= nil,
    body and body:sub(1, 160))
  ok("[v0267] manager module loads",
    (pcall(require, "auto-finder.neotree.sources.manager")))
end)()

-- ── fix 2: core.buffers publishes only for user-visible buffers ──
-- A notifier toast IS a scratch buffer; its teardown was the loop's fuel.
;(function()
  local cb = require("auto-finder.core.buffers")
  local events = require("auto-finder.core.events")
  cb._reset_for_tests()
  cb._arm_autocmds()

  local fired = {}
  local h = events.subscribe("auto-finder.core.buffers:changed",
    function(p) fired[#fired + 1] = p end)

  -- exactly what snacks materialises a toast into
  local toast = vim.api.nvim_create_buf(false, true)
  vim.bo[toast].buflisted = false
  vim.api.nvim_buf_set_lines(toast, 0, -1, false, { "mapped 4212 (1.4s)" })
  vim.wait(200)
  local after_create = #fired
  vim.api.nvim_buf_delete(toast, { force = true })   -- notifier.hide -> BufWipeout
  vim.wait(250)

  ok("[v0267] a scratch/toast buffer publishes NOTHING on create or teardown",
    #fired == 0, "events=" .. #fired .. " " .. vim.inspect(fired))
  ok("[v0267] and it never enters the buffers cache", cb.get(toast) == nil)

  -- the filter must not be a mute button: a real listed buffer still publishes
  local real = vim.api.nvim_create_buf(true, false)
  pcall(vim.api.nvim_buf_set_name, real, sandbox .. "/real-v0267.txt")
  vim.wait(300)
  ok("[v0267] a LISTED buffer still publishes (the filter is not a mute button)",
    #fired > after_create, "events=" .. #fired)

  pcall(vim.api.nvim_buf_delete, real, { force = true })
  events.unsubscribe(h)
  cb._disarm_autocmds()
  cb._reset_for_tests()
end)()

-- ── fix 3: the scan-storm detector (Johno's guard) ──
-- Detection-only by design: it cannot distinguish a user-initiated scan at the
-- sink, so it reports rather than damps. Its value is that any FUTURE
-- watch/event->refresh loop self-announces with its trigger attributed — which
-- is exactly how the ADR-0059 feeder was found in one session instead of three.
;(function()
  local fs_scan = require("auto-finder.neotree.sources.filesystem.lib.fs_scan")
  ok("[v0267] the detector exposes its knobs and test hooks",
    type(fs_scan.STORM_WINDOW_MS) == "number"
      and type(fs_scan.STORM_THRESHOLD) == "number"
      and type(fs_scan._storm_record) == "function"
      and type(fs_scan._storm_reset) == "function")

  -- Timestamps must be REALISTIC. Production feeds `start_ms` from an uptime
  -- clock (uv.now() -- order 1e8), and the rate limiter compares
  -- `now_ms - storm_last_warn_ms` against the window with storm_last_warn_ms
  -- starting at 0. Tiny values like 1000 fail that gate for a reason
  -- production never encounters, and an earlier version of this test "found" a
  -- bug that was only its own toy clock. The assumption is pinned below.
  local BASE = fs_scan.STORM_WINDOW_MS * 100

  fs_scan._storm_reset()
  local warned_at
  for i = 1, fs_scan.STORM_THRESHOLD do
    if fs_scan._storm_record(BASE + i) then warned_at = warned_at or i end
  end
  ok("[v0267] warns exactly ON the threshold, not before",
    warned_at == fs_scan.STORM_THRESHOLD, tostring(warned_at))

  local extra = 0
  for i = 1, 5 do
    if fs_scan._storm_record(BASE + fs_scan.STORM_THRESHOLD + i) then extra = extra + 1 end
  end
  ok("[v0267] and at most once per window (a storm must not spam the ring)",
    extra == 0, tostring(extra))

  -- The assumption the rate limiter rests on, made explicit: the first storm
  -- can only warn once the clock has passed one window, because
  -- storm_last_warn_ms starts at 0. An uptime clock always has. If the call
  -- site is ever changed to a counter starting near zero, the FIRST storm of a
  -- session would be silent -- which is precisely the one worth hearing about.
  fs_scan._storm_reset()
  local early = false
  for i = 1, fs_scan.STORM_THRESHOLD + 2 do
    if fs_scan._storm_record(i) then early = true end
  end
  ok("[v0267] DOCUMENTED LIMIT: a clock starting near zero cannot warn in its "
    .. "first window (production uses uptime ms, so this never fires)",
    early == false)

  fs_scan._storm_reset()
  local spread = false
  for i = 1, fs_scan.STORM_THRESHOLD + 4 do
    if fs_scan._storm_record(i * (fs_scan.STORM_WINDOW_MS + 1)) then spread = true end
  end
  ok("[v0267] slow, spread-out scans are NOT a storm (no false positive)",
    spread == false)

  fs_scan._storm_reset()
  for i = 1, fs_scan.STORM_THRESHOLD do fs_scan._storm_record(1000 + i) end
  local later = false
  local base = 1000 + fs_scan.STORM_WINDOW_MS * 3
  for i = 1, fs_scan.STORM_THRESHOLD do
    if fs_scan._storm_record(base + i) then later = true end
  end
  ok("[v0267] a NEW burst after the window warns again (the guard re-arms)", later)
  fs_scan._storm_reset()
end)()

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
vim.fn.delete(sandbox, "rf")
if fail_count > 0 then os.exit(1) end
os.exit(0)
