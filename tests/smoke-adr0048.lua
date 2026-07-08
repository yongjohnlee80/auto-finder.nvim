-- ADR-0048 standalone smoke — sections [46] (views.tests), [47]
-- (views.debug), and [48] (r5 Env section, this file only — the
-- section postdates smoke.lua's [41b] truncation and has no
-- smoke.lua counterpart). Run with:
--   nvim --headless -u NONE -l tests/smoke-adr0048.lua
--
-- Exits 0 on PASS, 1 on FAIL. Each test prints its own line.
--
-- WHY THIS FILE EXISTS: tests/smoke.lua aborts at section [41] with
-- the pre-existing [41b] grid.c assertion crash (grid_line_flush:
-- `grid_line_clear_to <= grid_line_maxcol`, tracked in the KB todo
-- `2026-06-13-bug-auto-finder-smoke-suite-silently-truncates-at-41b-…`),
-- so under the canonical `-u NONE -l` invocation sections [42]–[47]
-- NEVER execute. Until that crash is fixed, this runner is the only
-- in-tree way the ADR-0048 Phase 3 sections actually run. It carries
-- the same rtp prelude + section-[1] bootstrap as tests/smoke.lua
-- (duplicated minimally — the repo's other suites duplicate their
-- preludes the same way) and then sections [46]+[47] VERBATIM.
-- Keep the section bodies in sync with tests/smoke.lua: they are the
-- canonical copies; this file re-executes them, it does not fork them.
-- Wired into tests/run-all.sh as the fourth suite ("adr0048").

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
  LAZY .. "/nui.nvim",
  LAZY .. "/plenary.nvim",
  -- Real nvim-dap for the debug-view breakpoint sections ([47]) — the
  -- §8.3 delete paths run against the actual dap.breakpoints
  -- get/set/remove surface, not a stub.
  LAZY .. "/nvim-dap",
  plugins_root .. "/auto-core.nvim/main",
  -- auto-run sibling (soft dep of the tests/debug views). Same
  -- sibling-worktree resolution as auto-core above.
  plugins_root .. "/auto-run.nvim/main",
}) do
  if vim.fn.isdirectory(p) == 1 then
    vim.opt.runtimepath:prepend(p)
  end
end
-- Auto-finder ships its own forked neo-tree at lua/auto-finder/neotree.
-- Upstream `neo-tree.nvim` is intentionally NOT on the runtimepath.

vim.o.columns = 200
vim.o.lines = 60
vim.o.swapfile = false
vim.o.hidden = true

-- Isolate from the user's real nvim state (and from tests/smoke.lua's
-- own isolation dirs, so the two suites can't clobber each other).
vim.fn.delete("/tmp/auto-finder-adr0048-config", "rf")
vim.env.XDG_CONFIG_HOME = "/tmp/auto-finder-adr0048-config"
vim.fn.delete("/tmp/auto-finder-adr0048-state", "rf")
vim.env.XDG_STATE_HOME = "/tmp/auto-finder-adr0048-state"

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

-- Same neo-tree pre-setup as tests/smoke.lua's prelude: auto-finder's
-- setup() re-calls it via cfg.neo_tree; pre-calling confirms the
-- merge_config path caches correctly.
require("auto-finder.neotree").setup({
  window = { auto_expand_width = true },
  filesystem = { hijack_netrw_behavior = "disabled" },
})

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
  neo_tree = {
    window = { auto_expand_width = true },
    filesystem = { hijack_netrw_behavior = "disabled" },
  },
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

  -- ── §8.3 row `d`: IMMEDIATE delete from live dap AND the store ─
  local bp3 = find_row(function(r)
    return r.kind == "breakpoint" and r.bp.lnum == 3
  end)
  ok("p47: typed breakpoint row present (lnum 3)", bp3 ~= nil)
  vim.api.nvim_win_set_cursor(w, { bp3.lnum, 0 })
  seen_maps["d"].callback()
  local live_after = dap_bps.get(src_buf)[src_buf] or {}
  local live_l3 = false
  for _, bp in ipairs(live_after) do
    if bp.line == 3 then live_l3 = true end
  end
  ok("p47: `d` removed the breakpoint from nvim-dap's LIVE registry",
    not live_l3, vim.inspect(live_after))
  local recs = ar_bps.read()
  local stored_l3 = false
  for _, rec in ipairs(recs) do
    if rec.lnum == 3 then stored_l3 = true end
  end
  ok("p47: `d` removed the breakpoint from the PERSISTED store (one action)",
    not stored_l3, vim.inspect(recs))
  ok("p47: the sibling breakpoint (lnum 5) survives the targeted delete",
    #recs == 1 and recs[1].lnum == 5, vim.inspect(recs))

  -- ── §8.3 file-header `d`: clear that file's breakpoints ────────
  dap_bps.set({}, src_buf, 7)   -- second bp so the file group has two
  ar_bps.reconcile()
  debug_view.on_focus(w, b)
  local file_hdr = find_row(function(r) return r.kind == "bp-file-header" end)
  ok("p47: file group header row present", file_hdr ~= nil)
  vim.api.nvim_win_set_cursor(w, { file_hdr.lnum, 0 })
  seen_maps["d"].callback()
  local live_map = dap_bps.get(src_buf)[src_buf] or {}
  ok("p47: file-header `d` cleared the file's LIVE breakpoints",
    #live_map == 0, vim.inspect(live_map))
  ok("p47: file-header `d` cleared the file's PERSISTED records",
    #ar_bps.read() == 0, vim.inspect(ar_bps.read()))

  -- ── §8.3 section-header `d`: clear ALL, with confirm ───────────
  dap_bps.set({}, src_buf, 2)
  dap_bps.set({}, src_buf, 4)
  ar_bps.reconcile()
  debug_view.on_focus(w, b)
  local bp_hdr = find_row(function(r)
    return r.kind == "bucket-header" and r.section == "breakpoints"
  end)
  ok("p47: Breakpoints section header row present", bp_hdr ~= nil)
  local orig_confirm = debug_view._confirm
  local confirm_calls = 0
  -- Declined confirm → nothing is cleared.
  debug_view._confirm = function(...)
    confirm_calls = confirm_calls + 1
    return 2
  end
  vim.api.nvim_win_set_cursor(w, { bp_hdr.lnum, 0 })
  seen_maps["d"].callback()
  ok("p47: section-header `d` PROMPTS before bulk clear",
    confirm_calls == 1, "calls=" .. confirm_calls)
  ok("p47: declined confirm clears nothing",
    #ar_bps.read() == 2, vim.inspect(ar_bps.read()))
  -- Accepted confirm → live registry + store both empty.
  debug_view._confirm = function(...)
    confirm_calls = confirm_calls + 1
    return 1
  end
  vim.api.nvim_win_set_cursor(w, { bp_hdr.lnum, 0 })
  seen_maps["d"].callback()
  ok("p47: accepted confirm clears ALL persisted records",
    #ar_bps.read() == 0, vim.inspect(ar_bps.read()))
  local live_all = dap_bps.get()
  local any_live = false
  for _, bps in pairs(live_all) do
    if #bps > 0 then any_live = true end
  end
  ok("p47: accepted confirm clears the LIVE registry too", not any_live)
  debug_view._confirm = orig_confirm

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
  -- `d`-to-clean affordance works on the orphan too.
  vim.api.nvim_win_set_cursor(w, { orphan_row.lnum, 0 })
  seen_maps["d"].callback()
  ok("p47: `d` cleans the orphaned persisted record",
    #ar_bps.read() == 0, vim.inspect(ar_bps.read()))

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

-- ───────────────────────── summary ────────────────────────
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
