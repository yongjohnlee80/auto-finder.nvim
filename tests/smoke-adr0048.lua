-- ADR-0048 standalone smoke — sections [46] (views.tests), [47]
-- (views.debug), and [48] (r5 Env section). Run with:
--   nvim --headless -u NONE -l tests/smoke-adr0048.lua
--
-- Exits 0 on PASS, 1 on FAIL. Each test prints its own line.
--
-- WHY THIS FILE EXISTS: [46]/[47] assert against a MATERIALISED panel
-- window (af.state.panel_winid must be a real window). Inside
-- tests/smoke.lua that only holds early in the run; late — after ~45
-- sections of accumulated window state — the panel does not
-- materialise headlessly and the same code logs env failures + the
-- p46 nil-buffer abort. In a FRESH nvim process (this file) the panel
-- materialises under plain `nvim --headless` (no pty). So on
-- 2026-08-23 [46]/[47] were CONSOLIDATED here — this file is now their
-- SOLE canonical home (they were removed from smoke.lua, which carries
-- a pointer marker). [48]'s r5 Env section has always lived only here.
-- Prelude + section-[1] bootstrap are duplicated from smoke.lua the
-- same way the repo's other standalone suites duplicate theirs.
-- Wired into tests/run-all.sh as the "adr0048" suite. (Background: the
-- crash that historically truncated smoke.lua's tail is the
-- grid_line_flush / [41b] class, KB todo
-- 2026-06-13-...; the [41]/[42] extraction on 2026-08-23 removed it
-- from smoke.lua's hot path — see tests/auto-finder-coverage.md.)

-- Derive plugin_root from the smoke script's own path so the driver
-- runs unmodified on any machine (Mac, Linux, bare-repo worktree,
-- plain clone). `tests/smoke-adr0048.lua` is two levels below the
-- plugin root.
local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")

local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
-- Same rtp ordering rationale as tests/smoke.lua: each
-- `rtp:prepend(p)` pushes p to the FRONT, so the LAST entry in this
-- list wins `require`; LAZY fallbacks first, sibling worktrees after.
local plugins_root = vim.fn.fnamemodify(plugin_root, ":h:h")
for _, p in ipairs({
  plugin_root,
  LAZY .. "/auto-core.nvim",
  -- Real nvim-dap for the debug-view breakpoint sections ([47]) — the
  -- §8.3 delete paths run against the actual dap.breakpoints
  -- get/set/remove surface, not a stub.
  LAZY .. "/nvim-dap",
  plugins_root .. "/auto-core.nvim/main",
  -- Same-branch sibling after `main`, so it wins (prepend reverses order): the files slot needs
  -- auto-core.fs.scan, and a cross-repo change lives in two same-named worktrees until it merges.
  plugins_root .. "/auto-core.nvim/" .. vim.fn.fnamemodify(plugin_root, ":t"),
  -- auto-run sibling (soft dep of the tests/debug views). Same
  -- sibling-worktree resolution as auto-core above.
  plugins_root .. "/auto-run.nvim/main",
}) do
  if vim.fn.isdirectory(p) == 1 then
    vim.opt.runtimepath:prepend(p)
  end
end

vim.o.columns = 200
vim.o.lines = 60
vim.o.swapfile = false
vim.o.hidden = true

-- Isolate from the user's real nvim state (and from every other
-- suite's). CACHE matters as much as CONFIG/STATE here: auto-run writes
-- runs under `stdpath("cache")`, and this suite's p46 section spawns
-- real jobs — see tests/_sandbox.lua for why leaving it on the real
-- home cost 147/7 on read-only hosts.
dofile(vim.fn.fnamemodify(debug.getinfo(1,"S").source:sub(2),":p:h").."/_sandbox.lua")("adr0048")

vim.env.AUTO_FINDER_DBASE_DISABLE_CRYPTO = "1"

local fail_count = 0
local pass_count = 0
local function ok(name, cond, detail)
  if cond then
    pass_count = pass_count + 1
    print(string.format("  PASS  %s", name))
  else
    fail_count = fail_count + 1
    print(string.format("  FAIL  %s  %s", name, tostring(detail or "")))
  end
end


-- ───────────────────────── [1] setup() — shared bootstrap ─────────────────────────
-- Duplicated from tests/smoke.lua section [1]: [46] drives the panel
-- through `af` (slot_add / focus / _editor_target_winid), so the
-- plugin must be set up exactly as the canonical suite does it.
print("\n[1] setup()")
local af = require("auto-finder")
local setup_ok, err = pcall(af.setup, {
  side = "left",
  width = { default = 38, min = 25, max = 100 },
  default_section = 1,
  sections = { "config", "files" },
})
ok("setup returns without error", setup_ok, err)
ok("state.config populated", af.state.config ~= nil)
ok("sections registered", #require("auto-finder.sections").enabled() == 2)
local sec = require("auto-finder.sections")
ok("section 0 = config", sec.resolve(0) and sec.resolve(0).name == "config")
ok("section 1 = files", sec.resolve(1) and sec.resolve(1).name == "files")

-- ───────────────────────── [46] ADR-0048 Phase 3 — views.tests ─────────────────────────
--
-- The auto-finder half of ADR-0048 Phase 3 (§8.1): the tests view as
-- a pure renderer over auto-run's public discovery surface. Coverage
-- per the Phase 3 todo: registration + slot add, rendering from a
-- REAL auto-run discovery tree (go fixture repo, treesitter parse,
-- bounded scan), typed-row dispatch (`r` → discovery.run_position
-- with the exec job layer stubbed), status-glyph update on
-- run.results:changed, `o` details expansion + persisted folder
-- collapse, the no-hijack invariant (ADR-0009), the broad
-- second-panel exclusion probe (auto-core-panel-ownership), and the
-- auto-run-absent no-op hint (dbase-without-dbee precedent).
print("\n[46] ADR-0048 Phase 3 — views.tests (auto-run discovery consumer)")
;(function()
  local _ev46 = require("auto-core.events")
  local ok_v, tests_view = pcall(require, "auto-finder.views.tests")
  ok("p46: auto-finder.views.tests loads", ok_v, tostring(tests_view))
  if not ok_v then return end

  -- State isolation for the auto-run.ui namespace + auto-run store.
  local state_tmp = vim.fn.tempname()
  vim.fn.mkdir(state_tmp, "p")
  require("auto-core.state").configure({ persist_dir = state_tmp })

  -- ── (a) auto-run-absent no-op hint — BEFORE anything loads auto-run.
  -- Hide every auto-run module from require via error-raising
  -- package.preload stubs (rtp still carries the plugin, so clearing
  -- package.loaded alone would not simulate absence).
  tests_view._reset_for_tests()
  local BLOCK = {
    "auto-run", "auto-run.discovery", "auto-run.store",
    "auto-run.store.paths", "auto-run.exec", "auto-run.exec.job",
    "auto-run.dap", "auto-run.dap.breakpoints", "auto-run.adapters",
  }
  local saved_loaded = {}
  for _, m in ipairs(BLOCK) do
    saved_loaded[m] = package.loaded[m]
    package.loaded[m] = nil
    package.preload[m] = function()
      error(m .. " hidden for the absent-probe")
    end
  end
  local b_absent = tests_view.get_buffer(nil)
  local absent_txt = table.concat(
    vim.api.nvim_buf_get_lines(b_absent, 0, -1, false), "\n")
  ok("p46: auto-run absent → one-line hint rendered",
    absent_txt:find("auto%-run%.nvim not installed") ~= nil,
    "got:\n" .. absent_txt)
  ok("p46: auto-run absent → no tree rows",
    absent_txt:find("Tests —") == nil)
  tests_view.on_close()
  for _, m in ipairs(BLOCK) do
    package.preload[m] = nil
    package.loaded[m] = saved_loaded[m]
  end

  -- ── (b) registration + slot add for BOTH Phase 3 views ────────
  local types = af._available_section_types()
  local has_tests, has_debug = false, false
  for _, t in ipairs(types) do
    if t == "tests" then has_tests = true end
    if t == "debug" then has_debug = true end
  end
  ok("p46: 'tests' is in _available_section_types", has_tests,
    "got: " .. table.concat(types, ", "))
  ok("p46: 'debug' is in _available_section_types", has_debug,
    "got: " .. table.concat(types, ", "))

  -- ── (c) go fixture repo + REAL auto-run discovery ──────────────
  local worktree = require("auto-core.git.worktree")
  local gofix = vim.fn.tempname() .. "-af-gofix"
  vim.fn.mkdir(gofix .. "/calc", "p")
  local function wf(path, text)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
  end
  local function git(...)
    local res = vim.system({ "git", "-C", gofix,
      "-c", "user.email=smoke@test", "-c", "user.name=smoke", ... },
      { text = true }):wait()
    return res.code == 0
  end
  vim.system({ "git", "init", "-q", "-b", "main", gofix },
    { text = true }):wait()
  wf(gofix .. "/go.mod", "module example.com/afgofix\n\ngo 1.21\n")
  wf(gofix .. "/calc/calc.go",
    "package calc\n\nfunc Add(a, b int) int { return a + b }\n")
  local calc_test = gofix .. "/calc/calc_test.go"
  wf(calc_test, [[
package calc

import "testing"

func TestAdd(t *testing.T) {
	t.Run("sub one", func(t *testing.T) {
		if Add(1, 2) != 3 {
			t.Fatal("nope")
		}
	})
}

func TestFail(t *testing.T) {
	t.Fatal("boom")
}
]])
  ok("p46: go fixture committed",
    git("add", ".") and git("commit", "-q", "-m", "init"))

  local prev_active = worktree.get_active()
  worktree.set_active(gofix)

  local ok_ar, auto_run = pcall(require, "auto-run")
  ok("p46: sibling auto-run.nvim loads", ok_ar, tostring(auto_run))
  if not ok_ar then
    worktree.set_active(prev_active)
    return
  end
  local setup_ok = auto_run.setup()
  ok("p46: auto-run.setup() succeeds against sibling auto-core",
    setup_ok == true)
  local discovery = require("auto-run.discovery")
  discovery._reset_for_tests()
  require("auto-run.adapters.go")._reset_for_tests()
  require("auto-run.store.paths").invalidate()

  local report
  discovery.scan(nil, function(r) report = r end)
  vim.wait(5000, function() return report ~= nil end, 10)
  ok("p46: auto-run scan completes on the fixture",
    report ~= nil and report.status == "complete", vim.inspect(report))

  -- Mount via slot add (the config-REPL surface).
  af.setup({
    width = { default = 38, min = 25, max = 100 },
    default_section = 0,
    sections = { "config", "files" },
  })
  af.open(true)
  local add_err_tests = af.slot_add("tests")
  ok("p46: slot_add('tests') succeeds", add_err_tests == nil,
    tostring(add_err_tests))
  local add_err_debug = af.slot_add("debug")
  ok("p46: slot_add('debug') succeeds", add_err_debug == nil,
    tostring(add_err_debug))
  local views_reg = require("auto-finder.views")
  ok("p46: tests view registered after slot_add",
    views_reg.resolve("tests") ~= nil
      and views_reg.resolve("tests").name == "tests")
  ok("p46: debug view registered after slot_add",
    views_reg.resolve("debug") ~= nil
      and views_reg.resolve("debug").name == "debug")

  local tests_idx = views_reg._by_name["tests"]
  af.focus(tests_idx)
  ok("p46: focused tests slot", af.state.section == tests_idx,
    "got " .. tostring(af.state.section))
  local panel = af.state.panel_winid
  local b = panel and vim.api.nvim_win_get_buf(panel)
  ok("p46: panel holds the tests buffer",
    b ~= nil and vim.b[b].auto_finder_view == "tests",
    "view tag=" .. tostring(b and vim.b[b].auto_finder_view))
  ok("p46: tests buffer filetype is auto-finder (panel-class)",
    b ~= nil and vim.bo[b].filetype == "auto-finder")

  -- Rendering from the real discovery tree.
  local function buf_text()
    -- Guard the panel-not-materialised case: if `b` is nil the caller's
    -- own `ok(... b ~= nil ...)` assertions already FAIL visibly above,
    -- so return "" here instead of throwing an uncaught E5113 that would
    -- abort the whole suite (this is exactly how the p46 nil-buffer throw
    -- silently truncated smoke.lua's tail — KB todo 2026-08-23).
    if not b then return "" end
    return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  end
  local txt = buf_text()
  ok("p46: header line shows the root + counts",
    txt:find("Tests — ") ~= nil and txt:find("positions%)") ~= nil,
    "got:\n" .. txt)
  ok("p46: dir row rendered (calc/)", txt:find("calc/", 1, true) ~= nil)
  ok("p46: file row rendered (calc_test.go)",
    txt:find("calc_test.go", 1, true) ~= nil)
  ok("p46: test row rendered (TestAdd)",
    txt:find("TestAdd", 1, true) ~= nil)
  ok("p46: subtest row rendered (sub one)",
    txt:find("sub one", 1, true) ~= nil)

  -- Typed rows populated.
  local test_row
  for _, r in ipairs(tests_view._rows or {}) do
    if r.kind == "position" and r.node
        and r.node.id == calc_test .. "::TestAdd" then
      test_row = r
      break
    end
  end
  ok("p46: M._rows carries a typed position row for TestAdd",
    test_row ~= nil and test_row.node.type == "test")

  -- Keymaps registered with desc strings.
  local seen_maps = {}
  for _, k in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do
    seen_maps[k.lhs] = k
  end
  for _, lhs in ipairs({ "<CR>", "r", "R", "d", "o", "i", "S", "x", "?" }) do
    ok("p46: keymap registered: " .. lhs, seen_maps[lhs] ~= nil)
  end

  -- ── (d) typed-row dispatch: `r` on a test row → run_position
  --        with the exec JOB layer stubbed ──────────────────────
  local job = require("auto-run.exec.job")
  local orig_spawn = job.spawn
  local spawned = {}
  job.spawn = function(spec)
    spawned[#spawned + 1] = spec
    return { id = spec.id, config = spec.config, strategy = "run" }, nil
  end

  vim.api.nvim_win_set_cursor(panel, { test_row.lnum, 0 })
  seen_maps["r"].callback()
  ok("p46: `r` on the TestAdd row spawned exactly one job",
    #spawned == 1, "spawned=" .. tostring(#spawned))
  local argv = spawned[1] and spawned[1].cmd or {}
  ok("p46: spawned argv is a go-test -json invocation",
    argv[1] == "go" and argv[2] == "test" and argv[3] == "-json",
    vim.inspect(argv))
  ok("p46: spawn config carries the test: prefix",
    spawned[1] and spawned[1].config == "test:go",
    tostring(spawned[1] and spawned[1].config))
  ok("p46: M._last_position recorded for `R` re-run",
    tests_view._last_position == calc_test .. "::TestAdd")

  -- run_position marked the scope running + published
  -- run.results:changed → the event-driven re-render must paint ●.
  vim.wait(100, function() return false end)
  ok("p46: running glyph ● painted after run.results:changed",
    buf_text():find("●", 1, true) ~= nil, "got:\n" .. buf_text())

  -- `R` re-runs the same position.
  seen_maps["R"].callback()
  ok("p46: `R` re-ran the last position (second spawn)",
    #spawned == 2, "spawned=" .. tostring(#spawned))
  job.spawn = orig_spawn

  -- ── (e) status glyph update on run.results:changed ────────────
  -- Feed a passed result through the view's public data seam
  -- (discovery.results) and publish the event the view subscribes
  -- to — asserting the subscription + glyph mapping, not auto-run's
  -- own parse pipeline (covered by auto-run's suite).
  local orig_results = discovery.results
  discovery.results = function()
    return {
      [calc_test .. "::TestAdd"] = { status = "passed", duration_ms = 12 },
      [calc_test .. "::TestFail"] = { status = "failed" },
    }
  end
  _ev46.publish("run.results:changed", {
    root = gofix, positions = {},
  })
  vim.wait(100, function() return false end)
  txt = buf_text()
  ok("p46: ✓ glyph painted for the passed test", txt:find("✓", 1, true) ~= nil,
    "got:\n" .. txt)
  ok("p46: ✗ glyph painted for the failed test", txt:find("✗", 1, true) ~= nil)
  ok("p46: duration annotation rendered", txt:find("(12ms)", 1, true) ~= nil)

  -- ── no-hijack probe: event fires → focus unchanged, panel buffer
  --    not swapped (ADR-0009) ────────────────────────────────────
  vim.cmd("botright vsplit")
  local editor_win = vim.api.nvim_get_current_win()
  vim.wo[editor_win].winfixbuf = false
  local editor_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(editor_win, editor_buf)
  vim.api.nvim_set_current_win(editor_win)
  _ev46.publish("run.results:changed", { root = gofix, positions = {} })
  vim.wait(100, function() return false end)
  ok("p46: no-hijack — current window unchanged after event render",
    vim.api.nvim_get_current_win() == editor_win,
    "expected " .. editor_win .. ", got " .. vim.api.nvim_get_current_win())
  ok("p46: no-hijack — editor window still holds its own buffer",
    vim.api.nvim_win_get_buf(editor_win) == editor_buf)
  ok("p46: no-hijack — panel window still holds the tests buffer",
    vim.api.nvim_win_get_buf(panel) == b)

  -- Hidden-buffer gate: swap another slot into the panel (another
  -- slot active) → events must NOT repaint the hidden tests buffer.
  af.focus(0)  -- config slot takes the panel
  ok("p46: tests buffer hidden after switching slots",
    #vim.fn.win_findbuf(b) == 0)
  local hidden_before = buf_text()
  discovery.results = function()
    return { [calc_test .. "::TestAdd"] = { status = "failed" } }
  end
  _ev46.publish("run.results:changed", { root = gofix, positions = {} })
  vim.wait(100, function() return false end)
  ok("p46: hidden-gate — buffer content unchanged while another slot is active",
    buf_text() == hidden_before)
  discovery.results = orig_results
  af.focus(tests_idx)
  b = vim.api.nvim_win_get_buf(panel)

  -- ── (f) `o` details expansion + persisted folder collapse ─────
  discovery.results = function()
    return { [calc_test .. "::TestAdd"] = { status = "passed", duration_ms = 12 } }
  end
  tests_view.on_focus(panel, b)
  seen_maps = {}
  for _, k in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do
    seen_maps[k.lhs] = k
  end
  local row_lnum
  for _, r in ipairs(tests_view._rows or {}) do
    if r.kind == "position" and r.node.id == calc_test .. "::TestAdd" then
      row_lnum = r.lnum
      break
    end
  end
  vim.api.nvim_win_set_cursor(panel, { row_lnum, 0 })
  seen_maps["o"].callback()
  local detail_fields, output_detail = {}, nil
  for _, r in ipairs(tests_view._rows or {}) do
    if r.kind == "detail" and r.node and r.node.id == calc_test .. "::TestAdd" then
      detail_fields[r.field] = r
      if r.field == "output" then output_detail = r end
    end
  end
  ok("p46: `o` expands status/duration/output detail rows",
    detail_fields.status ~= nil and detail_fields.duration ~= nil
      and detail_fields.output ~= nil,
    vim.inspect(vim.tbl_keys(detail_fields)))
  ok("p46: output detail row carries the run's stdout filepath",
    output_detail ~= nil and type(output_detail.filepath) == "string"
      and output_detail.filepath:find("/stdout$") ~= nil,
    tostring(output_detail and output_detail.filepath))
  seen_maps["o"].callback()  -- collapse again
  local still_expanded = false
  for _, r in ipairs(tests_view._rows or {}) do
    if r.kind == "detail" then still_expanded = true end
  end
  ok("p46: second `o` collapses the detail rows", not still_expanded)
  discovery.results = orig_results

  -- Folder collapse persists via state.namespace('auto-run.ui').
  local dir_row
  for _, r in ipairs(tests_view._rows or {}) do
    if r.kind == "position" and r.node.type == "dir"
        and r.node.name == "calc" then
      dir_row = r
      break
    end
  end
  ok("p46: dir row present for collapse test", dir_row ~= nil)
  vim.api.nvim_win_set_cursor(panel, { dir_row.lnum, 0 })
  seen_maps["o"].callback()
  ok("p46: collapsed folder hides its children",
    buf_text():find("TestAdd", 1, true) == nil, "got:\n" .. buf_text())
  local ui_ns = require("auto-core.state").namespace("auto-run.ui",
    { persist = "json" })
  local persisted = ui_ns:get("tests_collapsed")
  ok("p46: folder collapse persisted under auto-run.ui/tests_collapsed",
    type(persisted) == "table" and persisted[dir_row.node.id] == true,
    vim.inspect(persisted))
  -- Toggle back (and the persisted key drops — default is expanded).
  vim.api.nvim_win_set_cursor(panel, { dir_row.lnum, 0 })
  seen_maps["o"].callback()
  persisted = ui_ns:get("tests_collapsed")
  ok("p46: re-expanding drops the persisted collapse key",
    type(persisted) ~= "table" or persisted[dir_row.node.id] == nil,
    vim.inspect(persisted))

  -- ── capped-scan header: the structured cap report renders ─────
  -- (no-silent-caps rule — §7). Seed the view's scan state with a
  -- capped report shaped like AutoRunScanReport and re-render.
  tests_view._scan = { running = false, report = {
    status = "capped", cap = "files", seen = 5001, limit = 5000,
    hint = "scope narrowed?",
  } }
  tests_view.on_focus(panel, b)
  local cap_txt = buf_text()
  ok("p46: capped scan renders the structured cap report",
    cap_txt:find("scan capped: files 5001 ≥ 5000", 1, true) ~= nil
      and cap_txt:find("scope narrowed?", 1, true) ~= nil,
    "got:\n" .. cap_txt)
  ok("p46: cap report carries the actionable raise-or-narrow hint",
    cap_txt:find("discovery.max_files", 1, true) ~= nil)
  tests_view._scan = nil
  tests_view.on_focus(panel, b)

  -- ── (g) SECOND-PANEL EXCLUSION probe (auto-core-panel-ownership) ─
  -- A window stamped w:auto_core_panel_name="auto-agents" (any
  -- non-empty value = some family plugin's panel) must never be
  -- picked as the editor-routing target, even when its buffer would
  -- pass every buftype/filetype check.
  vim.cmd("topleft vnew")
  local stub_win = vim.api.nvim_get_current_win()
  vim.wo[stub_win].winfixbuf = false
  local stub_buf = vim.api.nvim_win_get_buf(stub_win)
  vim.bo[stub_buf].buftype = ""
  -- Non-vacuous half: before stamping, the leftmost plain window IS
  -- the natural first pick.
  local pick_before = af._editor_target_winid()
  ok("p46: exclusion probe is non-vacuous (unstamped window is picked)",
    pick_before == stub_win,
    "picked " .. tostring(pick_before) .. ", stub " .. tostring(stub_win))
  vim.w[stub_win].auto_core_panel_name = "auto-agents"  -- tests-only write
  local pick_after = af._editor_target_winid()
  ok("p46: broad exclusion — stamped second panel is never picked",
    pick_after ~= stub_win,
    "picked " .. tostring(pick_after))
  pcall(vim.api.nvim_win_close, stub_win, true)
  pcall(vim.api.nvim_win_close, editor_win, true)

  -- ── cleanup ────────────────────────────────────────────────────
  tests_view.on_close()
  ok("p46: on_close clears M._subs", tests_view._subs == nil)
  discovery._reset_for_tests()
  worktree.set_active(prev_active)
  require("auto-run.store.paths").invalidate()
  vim.fn.delete(gofix, "rf")
end)()

-- ───────────────────────── [47] ADR-0048 Phase 3 — views.debug ─────────────────────────
--
-- The §8.2 debug view: Entry Points / Active Sessions / Breakpoints
-- as a pure renderer over auto-run's store + breakpoint surfaces
-- and live nvim-dap state. Coverage: three-section render with
-- provenance annotations, `o` resolved-config expansion with env
-- VALUES MASKED (secret literals never reach the buffer), the §8.3
-- marks-parity clearing matrix (row `d` = immediate live+store
-- delete; file-header `d` = clear file; section-header `d` = clear
-- ALL with confirm), orphaned-persisted rendering, and the
-- auto-run-absent hint.
print("\n[47] ADR-0048 Phase 3 — views.debug (entry points / sessions / breakpoints)")
;(function()
  local ok_v, debug_view = pcall(require, "auto-finder.views.debug")
  ok("p47: auto-finder.views.debug loads", ok_v, tostring(debug_view))
  if not ok_v then return end
  local ok_dap = pcall(require, "dap")
  ok("p47: real nvim-dap on rtp", ok_dap)

  -- ── auto-run-absent hint ───────────────────────────────────────
  debug_view._reset_for_tests()
  do
    local BLOCK = { "auto-run", "auto-run.store" }
    local saved = {}
    for _, m in ipairs(BLOCK) do
      saved[m] = package.loaded[m]
      package.loaded[m] = nil
      package.preload[m] = function()
        error(m .. " hidden for the absent-probe")
      end
    end
    local b0 = debug_view.get_buffer(nil)
    local t0 = table.concat(vim.api.nvim_buf_get_lines(b0, 0, -1, false), "\n")
    ok("p47: auto-run absent → one-line hint rendered",
      t0:find("auto%-run%.nvim not installed") ~= nil, "got:\n" .. t0)
    debug_view.on_close()
    for _, m in ipairs(BLOCK) do
      package.preload[m] = nil
      package.loaded[m] = saved[m]
    end
  end

  -- ── fixture repo + store configs ───────────────────────────────
  local worktree = require("auto-core.git.worktree")
  local repo = vim.fn.tempname() .. "-af-debugfix"
  vim.fn.mkdir(repo, "p")
  vim.system({ "git", "init", "-q", "-b", "main", repo }, { text = true }):wait()
  vim.system({ "git", "-C", repo, "-c", "user.email=s@t", "-c", "user.name=s",
    "commit", "-q", "--allow-empty", "-m", "init" }, { text = true }):wait()

  local prev_active = worktree.get_active()
  worktree.set_active(repo)
  local store = require("auto-run.store")
  require("auto-run.store.paths").invalidate()

  local p1, e1 = store.add({
    name = "dbg-app", kind = "debug", runtime = "go",
    program = "${worktree}/cmd/app",
    env = {
      SECRET_TOKEN = "supersecret123",       -- literal → MUST be masked
      HOME_REF     = "${HOME}",              -- pure ref → shown verbatim
    },
  })
  ok("p47: kind=debug config added", p1 ~= nil, tostring(e1))

  -- The cross-plugin contract the debug view's `e` keymap rides on. The view
  -- capability-probes `store.config_file` and returns nil when it is absent,
  -- so a silently-missing API degrades to "no editable store file" with no
  -- error — exactly the failure a contract assertion has to catch here rather
  -- than at a user's keystroke (ADR-0048 P3 follow-up).
  ok("p47: auto-run exposes store.config_file (the `e` keymap's resolver)",
    type(store.config_file) == "function", type(store.config_file))
  if type(store.config_file) == "function" then
    ok("p47: config_file resolves to the file add() wrote",
      store.config_file("dbg-app") == p1,
      tostring(store.config_file("dbg-app")) .. " vs " .. tostring(p1))
    ok("p47: config_file is nil for a name with no store file (shim/absent)",
      store.config_file("not-a-real-config") == nil)
  end
  local p2, e2 = store.add({
    name = "run-app", kind = "run", program = "sh",
    args = { "-c", "true" },
  })
  ok("p47: kind=run config added", p2 ~= nil, tostring(e2))

  -- ── breakpoint fixture (real nvim-dap) ─────────────────────────
  local src = repo .. "/app.lua"
  do
    local flines = {}
    for i = 1, 10 do flines[i] = ("local l%d = %d"):format(i, i) end
    vim.fn.writefile(flines, src)
  end
  -- :edit from a guaranteed non-winfixbuf window (the current window
  -- may still be the panel after [46]'s cleanup).
  vim.cmd("botright vsplit")
  local src_win = vim.api.nvim_get_current_win()
  vim.wo[src_win].winfixbuf = false
  vim.cmd("edit " .. vim.fn.fnameescape(src))
  local src_buf = vim.api.nvim_get_current_buf()
  local dap_bps = require("dap.breakpoints")
  dap_bps.set({}, src_buf, 3)
  dap_bps.set({ condition = "x > 1" }, src_buf, 5)
  local ar_bps = require("auto-run.dap.breakpoints")
  ar_bps.reconcile()
  ok("p47: two breakpoints persisted through auto-run's reconcile",
    #ar_bps.read() == 2, vim.inspect(ar_bps.read()))

  -- ── three sections render ──────────────────────────────────────
  vim.cmd("topleft 45vnew")
  local w = vim.api.nvim_get_current_win()
  vim.wo[w].winfixbuf = false
  local b = debug_view.get_buffer(w)
  vim.api.nvim_win_set_buf(w, b)
  debug_view.on_focus(w, b)
  local function buf_text()
    return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  end
  local txt = buf_text()
  ok("p47: Entry Points section renders with count",
    txt:find("Entry Points %(2%)") ~= nil, "got:\n" .. txt)
  ok("p47: Active Sessions section renders (empty)",
    txt:find("Active Sessions %(0%)") ~= nil)
  ok("p47: Breakpoints section renders with count",
    txt:find("Breakpoints %(2%)") ~= nil)
  ok("p47: entries grouped by kind (debug sub-label)",
    txt:find("\n  debug\n") ~= nil)
  ok("p47: entries grouped by kind (run sub-label)",
    txt:find("\n  run\n") ~= nil)
  ok("p47: entry rows annotated with provenance/tier",
    txt:find("dbg%-app  %[") ~= nil, "got:\n" .. txt)
  ok("p47: breakpoint rows render filename:lnum",
    txt:find("app.lua:3", 1, true) ~= nil
      and txt:find("app.lua:5", 1, true) ~= nil)
  ok("p47: conditional breakpoint carries the [cond] marker",
    txt:find("app.lua:5  [cond]", 1, true) ~= nil)

  local seen_maps = {}
  for _, k in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do
    seen_maps[k.lhs] = k
  end
  for _, lhs in ipairs({ "<CR>", "o", "d", "e", "a", "x", "p", "i", "R", "?" }) do
    ok("p47: keymap registered: " .. lhs, seen_maps[lhs] ~= nil)
  end

  local function find_row(pred)
    for _, r in ipairs(debug_view._rows or {}) do
      if pred(r) then return r end
    end
    return nil
  end

  -- ── `o` on an entry: resolved config, env VALUES MASKED ────────
  local entry_row = find_row(function(r)
    return r.kind == "entry" and r.name == "dbg-app"
  end)
  ok("p47: typed entry row present", entry_row ~= nil)
  vim.api.nvim_win_set_cursor(w, { entry_row.lnum, 0 })
  seen_maps["o"].callback()
  txt = buf_text()
  ok("p47: entry expansion lists env KEYS",
    txt:find("env.SECRET_TOKEN", 1, true) ~= nil, "got:\n" .. txt)
  ok("p47: secret env VALUE never reaches the buffer",
    txt:find("supersecret123", 1, true) == nil, "got:\n" .. txt)
  ok("p47: masked placeholder rendered for the literal value",
    txt:find("(masked)", 1, true) ~= nil)
  ok("p47: pure substitution ref shown verbatim (a ref, not a secret)",
    txt:find("${HOME}", 1, true) ~= nil)
  ok("p47: expansion annotates the resolved program",
    txt:find("cmd/app", 1, true) ~= nil)
  -- Collapse the expansion again for the breakpoint tests below.
  vim.api.nvim_win_set_cursor(w, { entry_row.lnum, 0 })
  seen_maps["o"].callback()

  -- ── breakpoint rows render (typed rows, file + section headers) ──
  -- PRUNE (2026-08-23): the `d` = DELETE surface these tests were
  -- written against was removed in 73b2293 ("views.debug: … drop
  -- delete surface"). `d` now means DEBUG (dap, any kind); breakpoints
  -- are managed via nvim-dap directly, config files via the files
  -- panel. The 10 delete-ACTION assertions (row `d`, file-header `d`,
  -- section-header `d` + confirm, orphan `d`-clean) were pruned — the
  -- feature they defended is gone, so they defend nothing. The
  -- breakpoint RENDERING invariants below are still real and kept.
  local bp3 = find_row(function(r)
    return r.kind == "breakpoint" and r.bp.lnum == 3
  end)
  ok("p47: typed breakpoint row present (lnum 3)", bp3 ~= nil)

  -- file group header renders once a file carries breakpoints.
  dap_bps.set({}, src_buf, 7)   -- second bp so the file group has two
  ar_bps.reconcile()
  debug_view.on_focus(w, b)
  local file_hdr = find_row(function(r) return r.kind == "bp-file-header" end)
  ok("p47: file group header row present", file_hdr ~= nil)

  -- Breakpoints section (bucket) header renders.
  dap_bps.set({}, src_buf, 2)
  dap_bps.set({}, src_buf, 4)
  ar_bps.reconcile()
  debug_view.on_focus(w, b)
  local bp_hdr = find_row(function(r)
    return r.kind == "bucket-header" and r.section == "breakpoints"
  end)
  ok("p47: Breakpoints section header row present", bp_hdr ~= nil)

  -- ── orphaned persisted entry renders dimmed with (orphaned) ────
  dap_bps.set({}, src_buf, 6)
  ar_bps.reconcile()                 -- persist it …
  dap_bps.remove(src_buf, 6)         -- … then drop live WITHOUT reconcile
  debug_view.on_focus(w, b)
  txt = buf_text()
  ok("p47: orphaned persisted-vs-live entry rendered with the (orphaned) marker",
    txt:find("app.lua:6  (orphaned)", 1, true) ~= nil, "got:\n" .. txt)
  local orphan_row = find_row(function(r)
    return r.kind == "breakpoint" and r.bp.lnum == 6
  end)
  ok("p47: orphaned row typed with orphaned=true",
    orphan_row ~= nil and orphan_row.bp.orphaned == true
      and orphan_row.bp.live == false)

  -- ── cleanup ────────────────────────────────────────────────────
  debug_view.on_close()
  ok("p47: on_close clears M._subs", debug_view._subs == nil)
  pcall(vim.api.nvim_win_close, w, true)
  pcall(vim.api.nvim_win_close, src_win, true)
  pcall(vim.api.nvim_buf_delete, src_buf, { force = true })
  worktree.set_active(prev_active)
  require("auto-run.store.paths").invalidate()
  vim.fn.delete(repo, "rf")
end)()

-- ───────────────────────── [48] ADR-0048 r5 — Env section (both views) ─────────────────────────
--
-- The §8.4 Env section: candidate env files with the `*` selection
-- marker in BOTH the debug view (new "Env" bucket) and the tests
-- view (header section above the position tree), rendered by the
-- shared views/_env_section.lua helper. Coverage: rendering from a
-- REAL env-file fixture (comments, quoting styles, a parse error),
-- `s` select/deselect round-trip through auto-run + marker movement
-- on run.env:changed, `o` inline KEY=VALUE expansion (values are
-- interactive display — §4.2 r5 boundary) + parse-error child rows
-- + sticky expansion across event re-renders, `e` edit round-trip
-- (vim.ui.input prefill, quote style + comments preserved
-- byte-for-byte), `a` add flow incl. the already_exists→overwrite
-- confirm branch, `<CR>` editor-routing (file for env-file rows,
-- file:lnum for env-var rows), the synthetic unreferenced-selected
-- row, the no-hijack probe for run.env:changed, the tests-view
-- collapse persistence, and the env-API-absent hints.
print("\n[48] ADR-0048 r5 — Env section (tests + debug views)")
;(function()
  local ev = require("auto-core.events")
  local debug_view = require("auto-finder.views.debug")
  local tests_view = require("auto-finder.views.tests")
  local env_section = require("auto-finder.views._env_section")
  debug_view._reset_for_tests()
  tests_view._reset_for_tests()

  -- ── fixture repo + env files ───────────────────────────────────
  local worktree = require("auto-core.git.worktree")
  local repo = vim.fn.tempname() .. "-af-envfix"
  vim.fn.mkdir(repo, "p")
  vim.system({ "git", "init", "-q", "-b", "main", repo }, { text = true }):wait()
  vim.system({ "git", "-C", repo, "-c", "user.email=s@t", "-c", "user.name=s",
    "commit", "-q", "--allow-empty", "-m", "init" }, { text = true }):wait()
  local prev_active = worktree.get_active()
  worktree.set_active(repo)
  require("auto-run.store.paths").invalidate()

  local lm = repo .. "/lm-test.env"
  local LM_LINES = {
    "# lm test env — top comment",   -- 1
    "FOO=bar",                        -- 2
    'QUOTED="hello world"',           -- 3
    "SINGLE='sq value'",              -- 4
    "",                               -- 5
    "# section comment",              -- 6
    "THIS IS NOT PARSEABLE",          -- 7 → parse-error row
    "BAZ=qux",                        -- 8
  }
  vim.fn.writefile(LM_LINES, lm)
  vim.fn.writefile({ "PORT=8080" }, repo .. "/.env")

  -- A config referencing lm-test.env → source "config:api".
  local store = require("auto-run.store")
  local pa, ea = store.add({
    name = "api", kind = "run", program = "sh",
    env_files = { "${worktree}/lm-test.env" },
  })
  ok("p48: config with env_files added", pa ~= nil, tostring(ea))
  local env = require("auto-run.env")

  -- ── debug view: Env bucket renders from files_list ─────────────
  vim.cmd("topleft 60vnew")
  local w = vim.api.nvim_get_current_win()
  vim.wo[w].winfixbuf = false
  local b = debug_view.get_buffer(w)
  vim.api.nvim_win_set_buf(w, b)
  debug_view.on_focus(w, b)
  local function buf_text()
    return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  end
  local txt = buf_text()
  ok("p48: Env bucket renders with count (referenced + discovered)",
    txt:find("Env (2)", 1, true) ~= nil, "got:\n" .. txt)
  ok("p48: referenced file row annotated with its config source",
    txt:find("lm-test.env  [config:api]", 1, true) ~= nil, "got:\n" .. txt)
  ok("p48: discovered file row annotated [discovered]",
    txt:find(".env  [discovered]", 1, true) ~= nil)
  ok("p48: no selection marker before any `s`",
    txt:find("%* lm%-test%.env") == nil and txt:find("%* %.env") == nil)

  -- ── row labels disambiguate same-basename env files (r5 carry-forward) ──
  -- Drives the real labeller, both sides: the NEGATIVE control (distinct
  -- basenames must stay bare) is what stops a labeller that simply always
  -- returns the full path from passing the positive one.
  do
    local L = env_section._labels_for_tests
    local bare = L({ { path = "/w/.env" }, { path = "/w/local.env" } })
    ok("p48: CONTROL — distinct basenames stay bare (no gratuitous paths)",
      bare["/w/.env"] == ".env" and bare["/w/local.env"] == "local.env",
      vim.inspect(bare))

    local clash = L({ { path = "/w/svc-a/.env" }, { path = "/w/svc-b/.env" },
                      { path = "/w/prod.env" } })
    ok("p48: colliding basenames widen to a unique parent-qualified label",
      clash["/w/svc-a/.env"] == "svc-a/.env"
        and clash["/w/svc-b/.env"] == "svc-b/.env", vim.inspect(clash))
    ok("p48: a non-colliding sibling in the same list is NOT widened",
      clash["/w/prod.env"] == "prod.env", vim.inspect(clash))

    local deep = L({ { path = "/w/a/cfg/.env" }, { path = "/w/b/cfg/.env" } })
    ok("p48: widening goes as deep as uniqueness needs, no deeper",
      deep["/w/a/cfg/.env"] == "a/cfg/.env"
        and deep["/w/b/cfg/.env"] == "b/cfg/.env", vim.inspect(deep))

    -- The unresolvable case must terminate rather than widen forever.
    local dup = L({ { path = "/w/.env" }, { path = "/w/.env" } })
    ok("p48: an identical path listed twice terminates at the cap",
      type(dup["/w/.env"]) == "string", vim.inspect(dup))
  end

  local seen_maps = {}
  for _, k in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do
    seen_maps[k.lhs] = k
  end
  ok("p48: debug view registers the `s` env keymap", seen_maps["s"] ~= nil)

  local function find_row(view, pred)
    for _, r in ipairs(view._rows or {}) do
      if pred(r) then return r end
    end
    return nil
  end

  -- ── `s`: select round-trip through auto-run + marker on event ──
  local lm_row = find_row(debug_view, function(r)
    return r.kind == "env-file" and r.path == lm
  end)
  ok("p48: typed env-file row present for lm-test.env", lm_row ~= nil,
    vim.inspect(debug_view._rows))
  vim.api.nvim_win_set_cursor(w, { lm_row.lnum, 0 })
  seen_maps["s"].callback()
  vim.wait(100, function() return false end)
  ok("p48: `s` round-trips the selection through auto-run",
    env.get_selected() == lm, tostring(env.get_selected()))
  txt = buf_text()
  ok("p48: `*` marker painted on the selected row (event re-render)",
    txt:find("* lm-test.env", 1, true) ~= nil, "got:\n" .. txt)

  -- ── `o`: inline expansion — entries + parse-error child rows ───
  lm_row = find_row(debug_view, function(r)
    return r.kind == "env-file" and r.path == lm
  end)
  vim.api.nvim_win_set_cursor(w, { lm_row.lnum, 0 })
  seen_maps["o"].callback()
  txt = buf_text()
  ok("p48: expansion shows bare entry", txt:find("FOO=bar", 1, true) ~= nil,
    "got:\n" .. txt)
  ok("p48: expansion shows double-quoted entry (quotes stripped)",
    txt:find("QUOTED=hello world", 1, true) ~= nil)
  ok("p48: expansion shows single-quoted entry (quotes stripped)",
    txt:find("SINGLE=sq value", 1, true) ~= nil)
  ok("p48: parse-error child row rendered with its lnum",
    txt:find("! line 7: unparseable entry", 1, true) ~= nil)
  local var_row = find_row(debug_view, function(r)
    return r.kind == "env-var" and r.key == "QUOTED"
  end)
  ok("p48: typed env-var row carries the file lnum",
    var_row ~= nil and var_row.file_lnum == 3 and var_row.path == lm,
    vim.inspect(var_row))
  -- Sticky across an event-driven re-render.
  ev.publish("run.env:changed", { action = "selected", path = lm })
  vim.wait(100, function() return false end)
  ok("p48: expansion sticky across the event re-render",
    buf_text():find("FOO=bar", 1, true) ~= nil)

  -- ── `e`: edit round-trip (stubbed vim.ui.input) + byte checks ──
  local orig_input = vim.ui.input
  local seen_prefill
  vim.ui.input = function(opts, cb)
    seen_prefill = opts and opts.default
    cb("brave new world")
  end
  var_row = find_row(debug_view, function(r)
    return r.kind == "env-var" and r.key == "QUOTED"
  end)
  vim.api.nvim_win_set_cursor(w, { var_row.lnum, 0 })
  seen_maps["e"].callback()
  vim.ui.input = orig_input
  ok("p48: `e` prefills the CURRENT value",
    seen_prefill == "hello world", tostring(seen_prefill))
  local after = vim.fn.readfile(lm)
  ok("p48: update preserved the entry's double-quote style in place",
    after[3] == 'QUOTED="brave new world"', tostring(after[3]))
  ok("p48: comments + blank + unparseable lines preserved byte-for-byte",
    after[1] == LM_LINES[1] and after[5] == LM_LINES[5]
      and after[6] == LM_LINES[6] and after[7] == LM_LINES[7],
    vim.inspect(after))
  ok("p48: sibling entries untouched by the edit",
    after[2] == "FOO=bar" and after[8] == "BAZ=qux")
  vim.wait(100, function() return false end)
  ok("p48: edited value repainted via run.env:changed",
    buf_text():find("QUOTED=brave new world", 1, true) ~= nil)

  -- ── `a`: add flow + already_exists → overwrite branch ──────────
  local function stub_inputs(seq)
    local i = 0
    vim.ui.input = function(_, cb)
      i = i + 1
      cb(seq[i])
    end
  end
  lm_row = find_row(debug_view, function(r)
    return r.kind == "env-file" and r.path == lm
  end)
  stub_inputs({ "NEWKEY", "addval" })
  vim.api.nvim_win_set_cursor(w, { lm_row.lnum, 0 })
  seen_maps["a"].callback()
  vim.ui.input = orig_input
  after = vim.fn.readfile(lm)
  ok("p48: `a` appended the new entry",
    after[#after] == "NEWKEY=addval", vim.inspect(after))

  local orig_confirm = env_section._confirm
  local confirm_calls = 0
  env_section._confirm = function() confirm_calls = confirm_calls + 1; return 1 end
  stub_inputs({ "FOO", "overwritten" })
  lm_row = find_row(debug_view, function(r)
    return r.kind == "env-file" and r.path == lm
  end)
  vim.api.nvim_win_set_cursor(w, { lm_row.lnum, 0 })
  seen_maps["a"].callback()
  vim.ui.input = orig_input
  after = vim.fn.readfile(lm)
  ok("p48: already_exists prompts for overwrite (confirm called)",
    confirm_calls == 1, "calls=" .. confirm_calls)
  ok("p48: accepted overwrite updates the EXISTING entry in place",
    after[2] == "FOO=overwritten", tostring(after[2]))
  -- Declined overwrite → file untouched.
  env_section._confirm = function() confirm_calls = confirm_calls + 1; return 2 end
  stub_inputs({ "BAZ", "nope" })
  vim.api.nvim_win_set_cursor(w, { lm_row.lnum, 0 })
  seen_maps["a"].callback()
  vim.ui.input = orig_input
  env_section._confirm = orig_confirm
  after = vim.fn.readfile(lm)
  ok("p48: declined overwrite leaves the entry untouched",
    after[8] == "BAZ=qux", tostring(after[8]))

  -- ── `<CR>`: editor-routed open, var rows jump to their lnum ────
  vim.cmd("botright vsplit")
  local editor_win = vim.api.nvim_get_current_win()
  vim.wo[editor_win].winfixbuf = false
  vim.api.nvim_win_set_buf(editor_win, vim.api.nvim_create_buf(true, false))
  vim.api.nvim_set_current_win(w)
  debug_view.on_focus(w, b)
  local baz_row = find_row(debug_view, function(r)
    return r.kind == "env-var" and r.key == "BAZ"
  end)
  ok("p48: BAZ env-var row present for the CR probe", baz_row ~= nil)
  vim.api.nvim_win_set_cursor(w, { baz_row.lnum, 0 })
  seen_maps["<CR>"].callback()
  local routed_win
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local wb = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_get_name(wb):find("lm%-test%.env$") then
      routed_win = win
      break
    end
  end
  ok("p48: `<CR>` on a var row opened the env file in an editor window",
    routed_win ~= nil and routed_win ~= w)
  ok("p48: `<CR>` jumped to the entry's lnum",
    routed_win ~= nil
      and vim.api.nvim_win_get_cursor(routed_win)[1] == baz_row.file_lnum,
    routed_win and vim.inspect(vim.api.nvim_win_get_cursor(routed_win)))

  -- ── synthetic unreferenced-selected row (deviation #3) ─────────
  local outside = vim.fn.tempname() .. "-outside.env"
  vim.fn.mkdir(vim.fn.fnamemodify(outside, ":h"), "p")
  vim.fn.writefile({ "X=1" }, outside)
  env.set_selected(outside)
  vim.wait(100, function() return false end)
  txt = buf_text()
  ok("p48: unlisted selection renders the synthetic row",
    txt:find("(selected — unreferenced)", 1, true) ~= nil, "got:\n" .. txt)
  local ghost_row = find_row(debug_view, function(r)
    return r.kind == "env-file" and r.synthetic == true
  end)
  ok("p48: synthetic row typed + marked selected",
    ghost_row ~= nil and ghost_row.selected == true
      and ghost_row.path == outside, vim.inspect(ghost_row))
  -- `s` on the synthetic row deselects.
  vim.api.nvim_set_current_win(w)
  vim.api.nvim_win_set_cursor(w, { ghost_row.lnum, 0 })
  seen_maps["s"].callback()
  vim.wait(100, function() return false end)
  ok("p48: `s` on the synthetic row deselects through auto-run",
    env.get_selected() == nil, tostring(env.get_selected()))
  ok("p48: synthetic row gone after deselect",
    buf_text():find("(selected — unreferenced)", 1, true) == nil)

  -- ── no-hijack probe for run.env:changed (ADR-0009) ─────────────
  local editor_buf = vim.api.nvim_win_get_buf(editor_win)
  vim.api.nvim_set_current_win(editor_win)
  ev.publish("run.env:changed", { action = "selected", path = nil })
  vim.wait(100, function() return false end)
  ok("p48: no-hijack — current window unchanged after run.env:changed",
    vim.api.nvim_get_current_win() == editor_win)
  ok("p48: no-hijack — editor window still holds its own buffer",
    vim.api.nvim_win_get_buf(editor_win) == editor_buf)
  ok("p48: no-hijack — panel window still holds the debug buffer",
    vim.api.nvim_win_get_buf(w) == b)

  -- ── tests view: same section via the shared helper ─────────────
  vim.cmd("topleft 45vnew")
  local w2 = vim.api.nvim_get_current_win()
  vim.wo[w2].winfixbuf = false
  local b2 = tests_view.get_buffer(w2)
  vim.api.nvim_win_set_buf(w2, b2)
  tests_view.on_focus(w2, b2)
  local function buf2_text()
    return table.concat(vim.api.nvim_buf_get_lines(b2, 0, -1, false), "\n")
  end
  local t2 = buf2_text()
  ok("p48: tests view renders the Env header section",
    t2:find("Env (2)", 1, true) ~= nil, "got:\n" .. t2)
  ok("p48: tests view renders the env file rows",
    t2:find("lm-test.env  [config:api]", 1, true) ~= nil)
  ok("p48: env section sits ABOVE the position tree area",
    (t2:find("Env (2)", 1, true) or math.huge)
      > (t2:find("Tests —", 1, true) or 0))
  local maps2 = {}
  for _, k in ipairs(vim.api.nvim_buf_get_keymap(b2, "n")) do
    maps2[k.lhs] = k
  end
  for _, lhs in ipairs({ "s", "e", "a" }) do
    ok("p48: tests view env keymap registered: " .. lhs, maps2[lhs] ~= nil)
  end

  -- `o` expansion works through the tests view's dispatcher too.
  local lm_row2 = find_row(tests_view, function(r)
    return r.kind == "env-file" and r.path == lm
  end)
  ok("p48: tests view carries typed env-file rows", lm_row2 ~= nil)
  vim.api.nvim_set_current_win(w2)
  vim.api.nvim_win_set_cursor(w2, { lm_row2.lnum, 0 })
  maps2["o"].callback()
  ok("p48: tests view `o` expands KEY=VALUE child rows",
    buf2_text():find("FOO=overwritten", 1, true) ~= nil,
    "got:\n" .. buf2_text())

  -- Env-header collapse persists via tests_collapsed (dir mechanism).
  local hdr2 = find_row(tests_view, function(r) return r.kind == "env-header" end)
  ok("p48: tests view env-header row typed", hdr2 ~= nil)
  vim.api.nvim_win_set_cursor(w2, { hdr2.lnum, 0 })
  maps2["o"].callback()
  t2 = buf2_text()
  ok("p48: collapsed env section hides its rows",
    t2:find("lm-test.env", 1, true) == nil and t2:find("▶ Env (2)", 1, true) ~= nil,
    "got:\n" .. t2)
  local ui_ns = require("auto-core.state").namespace("auto-run.ui",
    { persist = "json" })
  local persisted = ui_ns:get("tests_collapsed")
  ok("p48: env-section collapse persisted under tests_collapsed",
    type(persisted) == "table"
      and persisted[tests_view._ENV_SECTION_ID] == true,
    vim.inspect(persisted))
  hdr2 = find_row(tests_view, function(r) return r.kind == "env-header" end)
  vim.api.nvim_win_set_cursor(w2, { hdr2.lnum, 0 })
  maps2["o"].callback()
  persisted = ui_ns:get("tests_collapsed")
  ok("p48: re-expanding drops the persisted env-collapse key",
    type(persisted) ~= "table"
      or persisted[tests_view._ENV_SECTION_ID] == nil,
    vim.inspect(persisted))

  -- ── env API absent — section hint; plugin absent — view hint ───
  do
    -- Partial skew: facade present, env module missing → the section
    -- renders its own one-line hint.
    local saved_env = package.loaded["auto-run.env"]
    package.loaded["auto-run.env"] = nil
    package.preload["auto-run.env"] = function()
      error("auto-run.env hidden for the API-absent probe")
    end
    debug_view.on_focus(w, b)
    txt = buf_text()
    ok("p48: env API unavailable → one-line section hint",
      txt:find("Env (0)", 1, true) ~= nil
        and txt:find("env API unavailable", 1, true) ~= nil,
      "got:\n" .. txt)
    package.preload["auto-run.env"] = nil
    package.loaded["auto-run.env"] = saved_env

    -- Full absence: the whole view is the standard hint (no Env
    -- section at all) — same shape [46]/[47] assert.
    local BLOCK = { "auto-run", "auto-run.store", "auto-run.env" }
    local saved = {}
    for _, m in ipairs(BLOCK) do
      saved[m] = package.loaded[m]
      package.loaded[m] = nil
      package.preload[m] = function()
        error(m .. " hidden for the absent-probe")
      end
    end
    debug_view.on_focus(w, b)
    txt = buf_text()
    ok("p48: auto-run absent → view hint, no Env section",
      txt:find("auto%-run%.nvim not installed") ~= nil
        and txt:find("Env (", 1, true) == nil, "got:\n" .. txt)
    for _, m in ipairs(BLOCK) do
      package.preload[m] = nil
      package.loaded[m] = saved[m]
    end
  end

  -- ── cleanup ────────────────────────────────────────────────────
  debug_view.on_close()
  tests_view.on_close()
  pcall(vim.api.nvim_win_close, w2, true)
  pcall(vim.api.nvim_win_close, editor_win, true)
  pcall(vim.api.nvim_win_close, w, true)
  worktree.set_active(prev_active)
  require("auto-run.store.paths").invalidate()
  vim.fn.delete(outside)
  vim.fn.delete(repo, "rf")
end)()

-- ── [49] ADR 0199 §5.2 — the state header at the top of both panes ──
-- A selection used to be visible only while its section was expanded, neither
-- pane stated what would run, and a switch of active worktree left the panes
-- showing the old one. Every header row must state its value OR its absence,
-- read only auto-run.context (the owner execution reads), and re-render when
-- that state changes. Each row's key must open that row's chooser.
print("\n[49] ADR 0199 §5.2 — state header (tests + debug panes)")
;(function()
  local tests_view = require("auto-finder.views.tests")
  local debug_view = require("auto-finder.views.debug")
  -- Guarded: an unguarded require raises and ABORTS the suite, hiding every
  -- later cell. A missing header must read as red, not as silence.
  local ok_hdr, header = pcall(require, "auto-finder.views._state_header")
  ok("p49: auto-finder.views._state_header loads", ok_hdr, tostring(header))
  if not ok_hdr then return end
  local ok_ctx, ctxm = pcall(require, "auto-run.context")
  ok("p49: this auto-run.nvim ships auto-run.context", ok_ctx, tostring(ctxm))
  if not ok_ctx then return end
  local cfgm = require("auto-run.adapters.config")
  local store = require("auto-run.store")
  local env = require("auto-run.env")
  local import = require("auto-run.import")
  local exec = require("auto-run.exec")
  local discovery = require("auto-run.discovery")
  local worktree = require("auto-core.git.worktree")
  tests_view._reset_for_tests()
  debug_view._reset_for_tests()

  local function wf(path, text)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local f = assert(io.open(path, "w")); f:write(text); f:close()
  end
  local function make_repo(dir)
    vim.fn.mkdir(dir, "p")
    vim.system({ "git", "init", "-q", "-b", "main", dir }, { text = true }):wait()
    vim.system({ "git", "-C", dir, "-c", "user.email=s@t", "-c", "user.name=s",
      "commit", "-q", "--allow-empty", "-m", "init" }, { text = true }):wait()
  end
  local repo = vim.fn.tempname() .. "-af-hdr"
  make_repo(repo)
  wf(repo .. "/go.mod", "module example.com/afhdr\n\ngo 1.21\n")
  local calc_test = repo .. "/calc_test.go"
  wf(calc_test, "package afhdr\n\nimport \"testing\"\n\nfunc TestAdd(t *testing.T) {}\n")
  wf(repo .. "/.vscode/launch.json", vim.json.encode({ version = "0.2.0", configurations = {
    { name = "HdrBase", type = "go", request = "launch", mode = "debug", program = "${workspaceFolder}" } } }))
  wf(repo .. "/hdr.env", "HDR=1\n")
  local repo2 = vim.fn.tempname() .. "-af-hdr-other"
  make_repo(repo2)

  local prev_active = worktree.get_active()
  worktree.set_active(repo)
  require("auto-run.store.paths").invalidate()
  discovery._reset_for_tests()
  exec.clear_pick(nil)
  env.set_selected(nil)
  import.set_selected(nil)

  vim.cmd("topleft 70vnew")
  local w = vim.api.nvim_get_current_win()
  vim.wo[w].winfixbuf = false
  local b = tests_view.get_buffer(w)
  vim.api.nvim_win_set_buf(w, b)
  tests_view.on_focus(w, b)

  local function text_of(buf)
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end
  local function row_line(view, buf, kind)
    for _, r in ipairs(view._rows or {}) do
      if r.kind == kind then
        return vim.api.nvim_buf_get_lines(buf, r.lnum - 1, r.lnum, false)[1], r
      end
    end
  end
  -- Let every render already queued via vim.schedule run BEFORE an action
  -- whose own event is under test; otherwise a leftover render picks up the
  -- new state and passes the cell with the subscription deleted (measured).
  local function settle() vim.wait(300, function() return false end) end
  local function wait_for(view, buf, kind, needle)
    vim.wait(1000, function()
      local l = row_line(view, buf, kind)
      return l ~= nil and l:find(needle, 1, true) ~= nil
    end, 10)
    return (row_line(view, buf, kind))
  end

  -- ── rows present, in order, with every ABSENCE stated ────────────
  local order = { "state-worktree", "state-env", "state-base", "state-test-config" }
  local lnums = {}
  for i, k in ipairs(order) do
    local _, r = row_line(tests_view, b, k)
    lnums[i] = r and r.lnum or -1
  end
  ok("p49: tests header has Active worktree / Env / Base / Test config rows, in order",
    lnums[1] > 0 and lnums[2] == lnums[1] + 1 and lnums[3] == lnums[2] + 1
      and lnums[4] == lnums[3] + 1, vim.inspect(lnums) .. "\n" .. text_of(b))
  local wt = row_line(tests_view, b, "state-worktree") or ""
  ok("p49: Active worktree names the active worktree",
    wt:find(vim.fn.fnamemodify(repo, ":t"), 1, true) ~= nil, wt)
  ok("p49: no env selected → Env states '(process env only)'",
    (row_line(tests_view, b, "state-env") or ""):find("(process env only)", 1, true) ~= nil,
    tostring(row_line(tests_view, b, "state-env")))
  ok("p49: no base → Base states '(none)'",
    (row_line(tests_view, b, "state-base") or ""):find("(none)", 1, true) ~= nil,
    tostring(row_line(tests_view, b, "state-base")))
  ok("p49: nothing discovered → the Test config row is still there, stating why",
    (row_line(tests_view, b, "state-test-config") or ""):find("no test positions discovered yet", 1, true) ~= nil,
    tostring(row_line(tests_view, b, "state-test-config")))

  -- ── values follow the owner, and re-render on its events ─────────
  discovery.parse_file(calc_test, require("auto-run.adapters").get("go"))
  for _, n in ipairs({ "hdr-a", "hdr-b" }) do
    store.add({ name = n, kind = "test", runtime = "go" }, { tier = "tracked" })
  end
  tests_view.on_focus(w, b)
  local first = cfgm.test_config_name("go")
  local other = first == "hdr-a" and "hdr-b" or "hdr-a"
  local tc = row_line(tests_view, b, "state-test-config") or ""
  ok("p49: Test config shows the resolver's answer and its source (first)",
    tc:find("go: " .. first .. " (first)", 1, true) ~= nil, tc)

  settle()
  cfgm.pick("go", other)
  tc = wait_for(tests_view, b, "state-test-config", "(picked)") or ""
  ok("p49: a pick re-renders the row (run.config:changed) and says (picked)",
    tc:find("go: " .. other .. " (picked)", 1, true) ~= nil, tc)

  cfgm.pick("go", nil)
  exec.remember_pick("test", other)
  tests_view.on_focus(w, b)
  tc = row_line(tests_view, b, "state-test-config") or ""
  ok("p49: the shared per-kind pick is labelled (shared pick), not (picked)",
    tc:find("go: " .. other .. " (shared pick)", 1, true) ~= nil, tc)

  local st = store.read_state()
  st.test_picks = { go = "hdr-gone" }
  store.write_state(st)
  tests_view.on_focus(w, b)
  tc = row_line(tests_view, b, "state-test-config") or ""
  ok("p49: a stale runtime pick is SHOWN behind the shared pick, not hidden",
    tc:find("(shared pick)", 1, true) ~= nil
      and tc:find("pick 'hdr-gone' does not apply to go", 1, true) ~= nil, tc)
  st = store.read_state(); st.test_picks = nil; store.write_state(st)
  exec.clear_pick(nil)

  settle()
  env.set_selected(repo .. "/hdr.env")
  local el = wait_for(tests_view, b, "state-env", "hdr.env") or ""
  ok("p49: selecting an env file re-renders Env (run.env:changed) with its path",
    el:find("hdr.env", 1, true) ~= nil and el:find("MISSING", 1, true) == nil, el)
  os.remove(repo .. "/hdr.env")
  tests_view.on_focus(w, b)
  el = row_line(tests_view, b, "state-env") or ""
  ok("p49: a selected env file that vanished is shown as MISSING",
    el:find("hdr.env — MISSING", 1, true) ~= nil, el)
  env.set_selected(nil)
  wf(repo .. "/hdr.env", "HDR=1\n")

  settle()
  import.set_selected("HdrBase")
  local bl = wait_for(tests_view, b, "state-base", "HdrBase") or ""
  ok("p49: selecting a base re-renders Base with its name",
    bl:find("HdrBase", 1, true) ~= nil, bl)
  import.set_selected(nil)

  -- ── keys: each header row's key opens THAT row's chooser ─────────
  local real_select = vim.ui.select
  local seen
  local function stub_select(choose)
    seen = {}
    vim.ui.select = function(items, opts, cb)
      seen[#seen + 1] = { items = items, prompt = opts and opts.prompt }
      local idx = choose(items)
      cb(idx and items[idx] or nil, idx)
    end
  end
  local function index_of(items, needle)
    for i, it in ipairs(items) do
      if tostring(it):find(needle, 1, true) then return i end
    end
  end
  -- A missing key must read as a red cell, not raise on a nil callback and
  -- abort the suite (measured: it did), so absent keys become no-ops.
  local function keymap_table(buf)
    local t = {}
    for _, k in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do t[k.lhs] = k end
    return setmetatable(t, { __index = function() return { callback = function() end } end })
  end
  local maps = keymap_table(b)
  ok("p49: tests pane maps s, b and c", rawget(maps, "s") and rawget(maps, "b") and rawget(maps, "c"))

  tests_view.on_focus(w, b)
  local _, wrow = row_line(tests_view, b, "state-worktree")
  vim.api.nvim_win_set_cursor(w, { wrow.lnum, 0 })
  stub_select(function(items) return index_of(items, "hdr.env") end)
  maps.s.callback()
  ok("p49: `s` off a Config/Env row opens the env chooser and applies the choice",
    #seen == 1 and env.get_selected() == repo .. "/hdr.env",
    vim.inspect(seen) .. " selected=" .. tostring(env.get_selected()))
  env.set_selected(nil)

  stub_select(function(items) return index_of(items, "HdrBase") end)
  maps.b.callback()
  ok("p49: `b` opens the base chooser and applies the choice",
    #seen == 1 and import.get_selected() == "HdrBase", vim.inspect(seen))
  import.set_selected(nil)

  exec.remember_pick("test", other)
  cfgm.pick("go", first)
  stub_select(function(items) return 1 end)
  maps.c.callback()
  ok("p49: `c`'s clear option names where clearing lands (the shared pick)",
    #seen == 1 and tostring(seen[1].items[1]):find("use shared pick '" .. other .. "'", 1, true) ~= nil,
    vim.inspect(seen))
  local cn, cs = cfgm.test_config_name("go")
  ok("p49: …and choosing it lands exactly there", cn == other and cs == "shared",
    tostring(cn) .. " (" .. tostring(cs) .. ")")
  exec.clear_pick(nil)
  stub_select(function(items) return index_of(items, other) end)
  maps.c.callback()
  cn, cs = cfgm.test_config_name("go")
  ok("p49: `c` writes the runtime's pick", cn == other and cs == "picked",
    tostring(cn) .. " (" .. tostring(cs) .. ")")
  cfgm.pick("go", nil)
  vim.ui.select = real_select

  -- ── debug pane: the same header, minus Test config ───────────────
  vim.cmd("topleft 70vnew")
  local w2 = vim.api.nvim_get_current_win()
  vim.wo[w2].winfixbuf = false
  local b2 = debug_view.get_buffer(w2)
  vim.api.nvim_win_set_buf(w2, b2)
  debug_view.on_focus(w2, b2)
  local have = {}
  for _, k in ipairs(order) do have[k] = row_line(debug_view, b2, k) ~= nil end
  ok("p49: debug header has Active worktree / Env / Base rows",
    have["state-worktree"] and have["state-env"] and have["state-base"], text_of(b2))
  ok("p49: debug header has NO Test config row (entries own their config)",
    not have["state-test-config"], text_of(b2))
  ok("p49: the empty Entry Points hint names what actually creates a config",
    text_of(b2):find("`a` scaffolds one", 1, true) == nil
      and text_of(b2):find("<leader>rc scaffolds one", 1, true) ~= nil, text_of(b2))
  local dmaps = keymap_table(b2)
  ok("p49: debug pane maps s and b", rawget(dmaps, "s") and rawget(dmaps, "b"))
  local _, dwrow = row_line(debug_view, b2, "state-worktree")
  vim.api.nvim_win_set_cursor(w2, { dwrow.lnum, 0 })
  stub_select(function(items) return index_of(items, "hdr.env") end)
  dmaps.s.callback()
  ok("p49: debug `s` off a Config/Env row opens the env chooser",
    #seen == 1 and env.get_selected() == repo .. "/hdr.env", vim.inspect(seen))
  env.set_selected(nil)
  stub_select(function(items) return index_of(items, "HdrBase") end)
  dmaps.b.callback()
  ok("p49: debug `b` opens the base chooser", #seen == 1 and import.get_selected() == "HdrBase",
    vim.inspect(seen))
  import.set_selected(nil)
  vim.ui.select = real_select

  -- ── a worktree switch re-renders BOTH panes on its own event ─────
  -- Nothing else is rendered by the cell: the only trigger is auto-core's
  -- core.active_worktree:changed. DRAIN first: the cells above queue renders
  -- via vim.schedule, and measured on VM43 thirteen of them were still pending
  -- here — they flushed after the switch and turned this cell green with the
  -- subscription deleted. Draining, then asserting the panes still show the
  -- OLD worktree, leaves the switch's own event as the only way to pass.
  settle()
  local label2 = vim.fn.fnamemodify(repo2, ":t")
  ok("p49: precondition — both headers still show the previous worktree",
    not (row_line(tests_view, b, "state-worktree") or ""):find(label2, 1, true)
      and not (row_line(debug_view, b2, "state-worktree") or ""):find(label2, 1, true))
  worktree.set_active(repo2)
  local t1 = wait_for(tests_view, b, "state-worktree", label2) or ""
  local t2 = wait_for(debug_view, b2, "state-worktree", label2) or ""
  ok("p49: switching the active worktree re-renders the tests header",
    t1:find(label2, 1, true) ~= nil, t1)
  ok("p49: switching the active worktree re-renders the debug header",
    t2:find(label2, 1, true) ~= nil, t2)
  worktree.set_active(repo)

  -- ── `w`: choose the Active worktree (ADR 0199 §7.2, M4) ──────────
  -- Lists every worktree under the workspace as `<repo> (<branch>) —
  -- <relative path>`, marks the current one, and sets auto-core's active
  -- worktree — the one owner — without changing the cwd.
  do
    local ws = vim.fn.tempname() .. "-af-ws"
    vim.fn.mkdir(ws, "p")
    make_repo(ws .. "/alpha")
    vim.fn.mkdir(ws .. "/beta", "p")
    vim.system({ "git", "clone", "-q", "--bare", ws .. "/alpha", ws .. "/beta/.git" }, { text = true }):wait()
    vim.system({ "git", "-C", ws .. "/beta", "worktree", "add", "-q", "-b", "feat", ws .. "/beta/feat" },
      { text = true }):wait()
    local prev_ws = worktree.get_workspace_root()
    worktree.set_workspace_root(ws)
    worktree.set_active(ws .. "/alpha")
    local cwd_before = vim.fn.getcwd()

    tests_view.on_focus(w, b)
    local wl = row_line(tests_view, b, "state-worktree") or ""
    ok("p49w: the Active worktree row names its key [w]", wl:find("[w]", 1, true) ~= nil, wl)
    maps = keymap_table(b)
    ok("p49w: tests pane maps w", rawget(maps, "w") ~= nil)
    local offered
    stub_select(function(items)
      offered = items
      return index_of(items, "beta/feat")
    end)
    maps.w.callback()
    local labels = vim.tbl_map(tostring, offered or {})
    ok("p49w: w lists every worktree under the workspace as <repo> (<branch>) — <path>",
      index_of(labels, "alpha (main) — alpha") ~= nil
        and index_of(labels, "beta (feat) — beta/feat") ~= nil, vim.inspect(labels))
    ok("p49w: …and marks the current one",
      index_of(labels, "* alpha (main)") ~= nil, vim.inspect(labels))
    ok("p49w: choosing sets auto-core's active worktree",
      worktree.get_active() == require("auto-core.fs.path").normalize(ws .. "/beta/feat"),
      tostring(worktree.get_active()))
    ok("p49w: …and never changes the cwd", vim.fn.getcwd() == cwd_before, vim.fn.getcwd())
    dmaps = keymap_table(b2)
    ok("p49w: debug pane maps w", rawget(dmaps, "w") ~= nil)
    vim.ui.select = real_select

    -- A non-repository anchor says what to do about it.
    local v2 = header.values({ worktree = { is_repo = false, label = "nvim-plugins", source = "cwd" },
      env = {}, base = {}, runtimes = {}, tests = {} })
    ok("p49w: a non-repository row says `w` chooses one", v2.worktree.text:find("w to choose one", 1, true) ~= nil,
      v2.worktree.text)

    worktree.set_workspace_root(prev_ws)
    worktree.set_active(repo)
    vim.fn.delete(ws, "rf")
  end

  -- ── chooser errors read as messages; missing env files are labelled ──
  -- (Lector M3b notes.) A structured error was stringified as a table
  -- address, and a referenced env file that does not exist was offered like
  -- any other and then failed when chosen.
  do
    local logm = require("auto-finder.log")
    local real_notify, said = logm.notify, {}
    logm.notify = function(msg) said[#said + 1] = tostring(msg) end
    local real_set = env.set_selected
    env.set_selected = function() return nil, { code = "boom", message = "injected: cannot select" } end
    stub_select(function(items) return index_of(items, "hdr.env") end)
    header.choose_env()
    env.set_selected = real_set
    ok("p49e: a structured chooser error shows its message, not a table address",
      #said == 1 and said[1]:find("injected: cannot select", 1, true) ~= nil
        and said[1]:find("table: 0x", 1, true) == nil, vim.inspect(said))

    local pm, pe = store.add({ name = "hdr-missing-ref", kind = "run", program = "sh",
      env_files = { "${worktree}/nowhere.env" } }, { tier = "tracked" })
    ok("p49e: fixture config referencing a missing env file", pm ~= nil, tostring(pe))
    said = {}
    local offered
    stub_select(function(items) offered = items; return index_of(items, "nowhere.env") end)
    header.choose_env()
    local ml = offered and offered[index_of(offered, "nowhere.env") or 0] or ""
    ok("p49e: a missing env file is labelled missing in the chooser",
      tostring(ml):find("missing", 1, true) ~= nil, vim.inspect(offered))
    ok("p49e: …and choosing it explains why instead of trying",
      env.get_selected() == nil and #said == 1 and said[1]:find("does not exist", 1, true) ~= nil,
      vim.inspect(said) .. " selected=" .. tostring(env.get_selected()))
    store.remove("hdr-missing-ref", { tier = "tracked" })
    logm.notify = real_notify
    vim.ui.select = real_select
  end

  -- ── degrade: an auto-run without auto-run.context ────────────────
  local saved = package.loaded["auto-run.context"]
  package.loaded["auto-run.context"] = nil
  package.preload["auto-run.context"] = function() error("hidden for the degrade probe") end
  -- pcall: a header that raises here would otherwise abort the suite
  -- (measured) instead of failing this cell.
  local okr, rerr = pcall(tests_view.on_focus, w, b)
  local dt = text_of(b)
  ok("p49: without auto-run.context the header says so and the pane still renders",
    okr and dt:find("cannot report run state", 1, true) ~= nil and dt:find("Tests —", 1, true) ~= nil,
    tostring(rerr) .. "\n" .. dt)
  package.preload["auto-run.context"] = nil
  package.loaded["auto-run.context"] = saved

  -- ── the value table itself: non-repo ─────────────────────────────
  local v = header.values({ worktree = { is_repo = false, label = "nvim-plugins", source = "cwd" },
    env = {}, base = {}, runtimes = {}, tests = {} })
  ok("p49: a non-repository worktree is stated, with where it came from",
    v.worktree.text:find("not a repository", 1, true) ~= nil
      and v.worktree.text:find("from cwd", 1, true) ~= nil and v.worktree.tone == "warn",
    vim.inspect(v.worktree))

  -- ── cleanup ──────────────────────────────────────────────────────
  for _, n in ipairs({ "hdr-a", "hdr-b" }) do store.remove(n, { tier = "tracked" }) end
  debug_view.on_close()
  tests_view.on_close()
  pcall(vim.api.nvim_win_close, w2, true)
  pcall(vim.api.nvim_win_close, w, true)
  discovery._reset_for_tests()
  worktree.set_active(prev_active)
  require("auto-run.store.paths").invalidate()
  vim.fn.delete(repo, "rf")
  vim.fn.delete(repo2, "rf")
end)()

-- ── [50] ADR 0199 §6.2 — manage entry points from the debug pane ──────
-- One store-backed Entry Points list, edited in place: `e` on a property
-- row edits it (env values stay masked), `a` adds an entry point through
-- auto-run's one scaffold API, `E` exports to launch.json (it was `a`), `I`
-- imports from launch.json. The launch.json Config section is gone: the
-- header's `b` chooses the base it duplicated.
print("\n[50] ADR 0199 §6.2 — debug pane entry-point management")
;(function()
  local debug_view = require("auto-finder.views.debug")
  local okr = pcall(require, "auto-run.adapters")
  local reg = okr and require("auto-run.adapters") or {}
  ok("p50: this auto-run.nvim has adapters.scaffold", type(reg.scaffold) == "function")
  if type(reg.scaffold) ~= "function" then return end
  local store = require("auto-run.store")
  local import = require("auto-run.import")
  local worktree = require("auto-core.git.worktree")
  debug_view._reset_for_tests()

  local repo = vim.fn.tempname() .. "-af-m5"
  vim.fn.mkdir(repo .. "/.vscode", "p")
  vim.system({ "git", "init", "-q", "-b", "main", repo }, { text = true }):wait()
  vim.system({ "git", "-C", repo, "-c", "user.email=s@t", "-c", "user.name=s",
    "commit", "-q", "--allow-empty", "-m", "init" }, { text = true }):wait()
  local f = assert(io.open(repo .. "/.vscode/launch.json", "w"))
  f:write(vim.json.encode({ version = "0.2.0", configurations = {
    { name = "LJ One", type = "go", request = "launch", mode = "debug", program = "${workspaceFolder}/cmd/one" } } }))
  f:close()
  local prev_active = worktree.get_active()
  worktree.set_active(repo)
  require("auto-run.store.paths").invalidate()
  local pa, ea = store.add({ name = "m5-api", kind = "run", runtime = "go", program = "sh",
    args = { "-c", "true" }, env = { SECRET_TOKEN = "hunter2" } })
  ok("p50: fixture entry point", pa ~= nil, tostring(ea))

  vim.cmd("topleft 70vnew")
  local w = vim.api.nvim_get_current_win()
  vim.wo[w].winfixbuf = false
  local b = debug_view.get_buffer(w)
  vim.api.nvim_win_set_buf(w, b)
  debug_view.on_focus(w, b)
  local function text() return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n") end
  local function find(pred)
    for _, r in ipairs(debug_view._rows or {}) do if pred(r) then return r end end
  end
  local function keys()
    local t = {}
    for _, k in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do t[k.lhs] = k end
    return setmetatable(t, { __index = function() return { callback = function() end } end })
  end
  local function settle() vim.wait(300, function() return false end) end
  local real_input, real_select = vim.ui.input, vim.ui.select
  local logm = require("auto-finder.log")
  local real_notify, said = logm.notify, {}
  logm.notify = function(msg) said[#said + 1] = tostring(msg) end
  local real_warn = logm.warn
  logm.warn = function(_, msg) said[#said + 1] = tostring(msg) end

  ok("p50: the launch.json Config section is gone (the header's b chooses the base)",
    not text():find("Config (", 1, true) and find(function(r) return r.kind == "state-base" end) ~= nil,
    text())

  -- `o` fans out, `e` edits a property in place.
  local k = keys()
  local entry = find(function(r) return r.kind == "entry" and r.name == "m5-api" end)
  vim.api.nvim_win_set_cursor(w, { entry.lnum, 0 })
  k.o.callback()
  debug_view.on_focus(w, b)
  local function detail(field)
    return find(function(r) return r.kind == "detail" and r.field == field
      and r.parent and r.parent.name == "m5-api" end)
  end
  ok("p50: o fans the entry point out into property rows",
    detail("program") ~= nil and detail("args") ~= nil and detail("env.SECRET_TOKEN") ~= nil, text())

  local prompts = {}
  local function stub_input(answer)
    vim.ui.input = function(opts, cb) prompts[#prompts + 1] = opts; cb(answer) end
  end
  local function edit(field, answer)
    debug_view.on_focus(w, b)
    local r = detail(field)
    if not r then return false end
    vim.api.nvim_win_set_cursor(w, { r.lnum, 0 })
    prompts = {}
    stub_input(answer)
    keys().e.callback()
    return true
  end

  edit("program", "bash")
  ok("p50: e on program edits it in place, prefilled with the current value",
    store.get("m5-api").program == "bash" and prompts[1] and prompts[1].default == "sh",
    vim.inspect(prompts) .. vim.inspect(store.get("m5-api").program))
  edit("args", [[-c "echo hi"]])
  ok("p50: e on args edits the list as one shell-split line",
    vim.deep_equal(store.get("m5-api").args, { "-c", "echo hi" }), vim.inspect(store.get("m5-api").args))
  edit("env.SECRET_TOKEN", "SECRET_TOKEN=rotated")
  ok("p50: e on an env row never shows the value — the prompt is prefilled with KEY= only",
    prompts[1] and prompts[1].default == "SECRET_TOKEN=", vim.inspect(prompts))
  ok("p50: …and writes KEY=VALUE through the store", store.get("m5-api").env.SECRET_TOKEN == "rotated",
    vim.inspect(store.get("m5-api").env))
  settle()
  ok("p50: …and the value never reaches the buffer",
    not text():find("rotated", 1, true) and not text():find("hunter2", 1, true), text())
  -- Set first, so clearing is observable: the fixture has no cwd, and a
  -- clear of an absent field would pass with the edit doing nothing.
  edit("cwd", repo)
  ok("p50: e on cwd sets it", store.get("m5-api").cwd == repo, vim.inspect(store.get("m5-api").cwd))
  edit("cwd", "")
  ok("p50: an empty answer clears the field", store.get("m5-api").cwd == nil, vim.inspect(store.get("m5-api").cwd))
  said = {}
  edit("program", nil)
  ok("p50: a cancelled prompt changes nothing", store.get("m5-api").program == "bash")

  -- `a` adds an entry point through auto-run's scaffold API.
  debug_view.on_focus(w, b)
  entry = find(function(r) return r.kind == "entry" and r.name == "m5-api" end)
  vim.api.nvim_win_set_cursor(w, { entry.lnum, 0 })
  local asked = {}
  vim.ui.select = function(items, opts, cb)
    asked[#asked + 1] = { prompt = opts and opts.prompt, items = items }
    local want = #asked == 1 and "debug" or "go"
    for i, it in ipairs(items) do if tostring(it) == want then return cb(it, i) end end
    cb(nil, nil)
  end
  stub_input("m5-new")
  keys().a.callback()
  local new = store.get("m5-new")
  ok("p50: a asks kind, runtime and name, then scaffolds through auto-run",
    new and new.kind == "debug" and new.runtime == "go" and #asked == 2, vim.inspect(asked) .. vim.inspect(new))
  settle()
  ok("p50: …and the new entry point appears", find(function(r) return r.kind == "entry" and r.name == "m5-new" end) ~= nil,
    text())

  -- `E` exports (moved from `a`).
  local exported
  local real_export = import.export
  import.export = function(name) exported = name; return repo .. "/.vscode/launch.json", nil end
  debug_view.on_focus(w, b)
  entry = find(function(r) return r.kind == "entry" and r.name == "m5-api" end)
  vim.api.nvim_win_set_cursor(w, { entry.lnum, 0 })
  keys().E.callback()
  import.export = real_export
  ok("p50: E exports the entry point under the cursor to launch.json", exported == "m5-api", tostring(exported))

  -- `I` imports from launch.json.
  said = {}
  vim.ui.select = function(items, _, cb)
    for i, it in ipairs(items) do if tostring(it):find("LJ One", 1, true) then return cb(it, i) end end
    cb(nil, nil)
  end
  keys().I.callback()
  local lj = store.get("LJ One")
  ok("p50: I imports the chosen launch.json entry into the store",
    lj and lj.origin == "launch.json" and store.config_file("LJ One") ~= nil,
    vim.inspect(lj) .. " file=" .. tostring(store.config_file("LJ One")))
  ok("p50: …and says what it did", #said >= 1 and said[#said]:find("imported", 1, true) ~= nil, vim.inspect(said))

  vim.ui.input, vim.ui.select = real_input, real_select
  logm.notify, logm.warn = real_notify, real_warn
  for _, n in ipairs({ "m5-api", "m5-new", "LJ One" }) do pcall(store.remove, n) end
  debug_view.on_close()
  pcall(vim.api.nvim_win_close, w, true)
  worktree.set_active(prev_active)
  require("auto-run.store.paths").invalidate()
  vim.fn.delete(repo, "rf")
end)()

-- ── [51] ADR 0199 §6.2 — the tests pane's Test configs section ───────
-- The tests pane's Config section listed launch.json configs to use as the
-- base — the header's `b` does that now. What the pane lacked was the test
-- CONFIG: the kind=test store configs, which one applies to each runtime and
-- why, and a way to pick, clear and create one. The shared per-kind pick
-- (ADR 0199 r3 §3.2) lives here as its own row, clearable.
print("\n[51] ADR 0199 §6.2 — tests pane Test configs section")
;(function()
  local tests_view = require("auto-finder.views.tests")
  local okc, cfgm = pcall(require, "auto-run.adapters.config")
  ok("p51: this auto-run.nvim has per-runtime test picks", okc and type(cfgm.pick) == "function")
  if not (okc and type(cfgm.pick) == "function") then return end
  local store = require("auto-run.store")
  local exec = require("auto-run.exec")
  local discovery = require("auto-run.discovery")
  local worktree = require("auto-core.git.worktree")
  tests_view._reset_for_tests()

  local repo = vim.fn.tempname() .. "-af-m5b"
  vim.fn.mkdir(repo, "p")
  vim.system({ "git", "init", "-q", "-b", "main", repo }, { text = true }):wait()
  vim.system({ "git", "-C", repo, "-c", "user.email=s@t", "-c", "user.name=s",
    "commit", "-q", "--allow-empty", "-m", "init" }, { text = true }):wait()
  local f = assert(io.open(repo .. "/go.mod", "w")); f:write("module example.com/m5b\n\ngo 1.21\n"); f:close()
  local t = repo .. "/calc_test.go"
  f = assert(io.open(t, "w")); f:write("package m5b\n\nimport \"testing\"\n\nfunc TestA(t *testing.T) {}\n"); f:close()
  local prev_active = worktree.get_active()
  worktree.set_active(repo)
  require("auto-run.store.paths").invalidate()
  discovery._reset_for_tests()
  exec.clear_pick(nil)

  vim.cmd("topleft 70vnew")
  local w = vim.api.nvim_get_current_win()
  vim.wo[w].winfixbuf = false
  local b = tests_view.get_buffer(w)
  vim.api.nvim_win_set_buf(w, b)
  tests_view.on_focus(w, b)
  local function text() return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n") end
  local function find(pred)
    for _, r in ipairs(tests_view._rows or {}) do if pred(r) then return r end end
  end
  local function line_of(r) return r and vim.api.nvim_buf_get_lines(b, r.lnum - 1, r.lnum, false)[1] or "" end
  local function keys()
    local k = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do k[m.lhs] = m end
    return setmetatable(k, { __index = function() return { callback = function() end } end })
  end
  local function press(key, row)
    tests_view.on_focus(w, b)
    if row then vim.api.nvim_win_set_cursor(w, { row.lnum, 0 }) end
    keys()[key].callback()
    tests_view.on_focus(w, b)
  end
  local function trow(name)
    tests_view.on_focus(w, b)
    return find(function(r) return r.kind == "test-config" and r.name == name end)
  end
  local real_input, real_select = vim.ui.input, vim.ui.select
  -- No real prompt may ever open in the suite: when `s` falls through to a
  -- chooser (the red state did), a live vim.ui.select waits on stdin.
  local stray = 0
  vim.ui.select = function(_, _, cb) stray = stray + 1; cb(nil, nil) end
  vim.ui.input = function(_, cb) stray = stray + 1; cb(nil) end

  ok("p51: the launch.json Config section is gone from the tests pane",
    not text():find("Config (", 1, true), text())
  local hdr = find(function(r) return r.kind == "test-configs-header" end)
  ok("p51: a Test configs section is present, and states that there are none",
    hdr ~= nil and line_of(hdr):find("Test configs (0)", 1, true) ~= nil
      and text():find("no test configs", 1, true) ~= nil, text())

  discovery.parse_file(t, require("auto-run.adapters").get("go"))
  store.add({ name = "tc-unit", kind = "test", runtime = "go" }, { tier = "tracked" })
  store.add({ name = "tc-int", kind = "test", runtime = "go" }, { tier = "tracked" })
  store.add({ name = "tc-any", kind = "test" }, { tier = "tracked" })
  store.add({ name = "tc-run", kind = "run", runtime = "go", program = "sh" }, { tier = "tracked" })
  tests_view.on_focus(w, b)
  local first = cfgm.test_config_name("go")
  local other = first == "tc-unit" and "tc-int" or "tc-unit"
  ok("p51: the section lists the kind=test configs only",
    trow("tc-unit") and trow("tc-int") and trow("tc-any") and not trow("tc-run"), text())
  ok("p51: the config that applies is marked, with the resolver's reason",
    line_of(trow(first)):find("applies to go (first)", 1, true) ~= nil
      and not line_of(trow(other)):find("applies to", 1, true), line_of(trow(first)) .. " | " .. line_of(trow(other)))
  ok("p51: a generic config says it serves any runtime",
    line_of(trow("tc-any")):find("any runtime", 1, true) ~= nil, line_of(trow("tc-any")))

  press("s", trow(other))
  local n1, s1 = cfgm.test_config_name("go")
  ok("p51: s on a config picks it for its runtime", n1 == other and s1 == "picked", tostring(n1) .. " " .. tostring(s1))
  ok("p51: …and the mark moves", line_of(trow(other)):find("applies to go (picked)", 1, true) ~= nil, line_of(trow(other)))
  press("s", trow(other))
  local n2, s2 = cfgm.test_config_name("go")
  ok("p51: s on the runtime's own pick clears it", n2 == first and s2 == "first", tostring(n2) .. " " .. tostring(s2))

  press("s", trow("tc-any"))
  local n3, s3 = cfgm.test_config_name("go")
  ok("p51: s on a generic config picks it for the one discovered runtime", n3 == "tc-any" and s3 == "picked",
    tostring(n3) .. " " .. tostring(s3))
  cfgm.pick("go", nil)

  ok("p51: s on a test config opens no chooser", stray == 0, "stray prompts: " .. stray)

  exec.remember_pick("test", other)
  tests_view.on_focus(w, b)
  local sp = find(function(r) return r.kind == "test-shared-pick" end)
  ok("p51: the shared per-kind pick has its own row", sp ~= nil and line_of(sp):find(other, 1, true) ~= nil, text())
  press("s", sp)
  ok("p51: s on the shared-pick row clears it",
    (exec.picks() or {}).test == nil and cfgm.test_config_name("go") == first, vim.inspect(exec.picks()))
  ok("p51: …and the row goes", find(function(r) return r.kind == "test-shared-pick" end) == nil, text())

  -- `a` in the section creates a test config through auto-run's scaffold API.
  vim.ui.select = function(items, _, cb)
    for i, it in ipairs(items) do if tostring(it) == "go" then return cb(it, i) end end
    cb(nil, nil)
  end
  vim.ui.input = function(_, cb) cb("tc-new") end
  press("a", find(function(r) return r.kind == "test-configs-header" end))
  local nw = store.get("tc-new")
  ok("p51: a on the section creates a test config for the chosen runtime",
    nw and nw.kind == "test" and nw.runtime == "go", vim.inspect(nw))
  vim.ui.input, vim.ui.select = real_input, real_select

  for _, n in ipairs({ "tc-unit", "tc-int", "tc-any", "tc-run", "tc-new" }) do pcall(store.remove, n) end
  exec.clear_pick(nil)
  tests_view.on_close()
  pcall(vim.api.nvim_win_close, w, true)
  discovery._reset_for_tests()
  worktree.set_active(prev_active)
  require("auto-run.store.paths").invalidate()
  vim.fn.delete(repo, "rf")
end)()

-- ───────────────────────── summary ────────────────────────
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
