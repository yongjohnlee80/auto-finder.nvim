-- ADR-0035 automation standalone smoke — sections [41] (automation
-- diagnostics + bash-disabled indicator) and [42] (scaffold on
-- `automated` promotion via the `s` modal). Run with:
--   nvim --headless -u NONE -l tests/smoke-automation.lua
--
-- Exits 0 on PASS, 1 on FAIL. Each test prints its own line.
--
-- WHY THIS FILE EXISTS: section [41] opens the malformed automated
-- template with `vim.cmd("edit")` to exercise the buffer-attach
-- diagnostic path. Inside tests/smoke.lua that edit fires AFTER the
-- suite has accumulated ~45 sections of window/attach/grid state, and
-- neovim's core `grid_line_flush` assertion (grid.c:595,
-- `grid_line_clear_to <= grid_line_maxcol`) aborts the process — the
-- same crash class as the macOS [41b] SEGFAULT tracked in the KB todo
-- `2026-06-13-bug-auto-finder-smoke-suite-silently-truncates-at-41b-…`.
-- The abort truncated smoke.lua's whole tail ([42], [45]–[50])
-- SILENTLY. Extracting [41]/[42] into their own fresh-nvim process
-- (low accumulated state → no crash) lets smoke.lua run to its
-- summary AND keeps this coverage live. Same pattern, and same
-- prelude-duplication, as tests/smoke-adr0048.lua.
--
-- Keep the section bodies in sync with tests/smoke.lua's canonical
-- copies — this file re-executes them, it does not fork them.
-- Wired into tests/run-all.sh as the "smoke_automation" suite.

-- Derive plugin_root from this script's own path so the driver runs
-- unmodified on any machine (Mac, Linux, bare-repo worktree, plain
-- clone). `tests/smoke-automation.lua` is two levels below the root.
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
  plugins_root .. "/auto-core.nvim/main",
  -- auto-run sibling (soft dep of the todos/automation views). Same
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

-- Isolate from the user's real nvim state (and from the other smoke
-- suites' isolation dirs, so they can't clobber each other).
dofile(vim.fn.fnamemodify(debug.getinfo(1,"S").source:sub(2),":p:h").."/_sandbox.lua")("automation")

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
-- Duplicated from tests/smoke.lua section [1]: the todos view drives
-- the panel through `af`, so the suite needs auto-finder configured
-- before the sections run.
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

-- ═══════════════════════════════════════════════════════════════════
-- Sections [41]+[42] below are VERBATIM from tests/smoke.lua. Keep in
-- sync; smoke.lua points here (see its [41]-extracted marker).
-- ═══════════════════════════════════════════════════════════════════

print("\n[41] ADR-0035 Phase 3 — automation diagnostics + bash-disabled indicator")
;(function()
  local ok_diag, diag = pcall(require, "auto-finder.views.todos.automation_diagnostics")
  if not ok_diag then
    ok("p41: automation_diagnostics module loads", false,
      "load failed: " .. tostring(diag))
    return
  end
  local ok_t, todo = pcall(require, "auto-core.todo")
  if not ok_t then return end
  local ok_a, automation = pcall(require, "auto-core.todo.automation")
  if not ok_a then return end

  -- Isolate workspace + state.
  local tmp_root  = vim.fn.tempname()
  local state_tmp = vim.fn.tempname() .. "_p41-state"
  vim.fn.mkdir(tmp_root, "p")
  vim.fn.mkdir(state_tmp, "p")
  require("auto-core.state").configure({ persist_dir = state_tmp })
  local worktree = require("auto-core.git.worktree")
  worktree.set_workspace_root(tmp_root)
  local function cleanup()
    diag.uninstall()
    worktree.set_workspace_root(nil)
    require("auto-core.state").configure({ persist_dir = nil })
    vim.fn.delete(tmp_root, "rf")
    vim.fn.delete(state_tmp, "rf")
  end

  -- 41a. install / uninstall round-trip.
  --
  -- These were two `ok(..., true)` calls: assertions that cannot fail.
  -- Worse, BOTH install() calls were no-ops -- `M.install()` opens with
  -- `if _augroup then return end`, and `af.setup()` has already created
  -- the group by the time this section runs -- so the pair exercised
  -- nothing at all and would have passed with the idempotency guard
  -- deleted outright. Measured: zero augroups were created across both
  -- calls.
  --
  -- Note what does NOT discriminate here, both measured rather than
  -- assumed:
  --   * the augroup ID is UNCHANGED by a `clear = true` re-create;
  --   * the autocmd count returns to the same value, because install()
  --     re-registers exactly what the clear wiped.
  -- The only observable that separates idempotent from not is whether a
  -- second create happens at all, so count the API calls.
  local GROUP = "auto-finder.todos.automation"
  local BUF_GROUP = "auto-finder.todos.automation.buf"
  local function group_present(name)
    return (pcall(vim.api.nvim_get_autocmds, { group = name })) and true or false
  end

  -- Start from a known-absent state so the first install() below is a
  -- REAL create rather than a short-circuit on setup()'s group.
  diag.uninstall()
  ok("p41: uninstall removes both augroups",
    not group_present(GROUP) and not group_present(BUF_GROUP))

  local creates = 0
  local real_create = vim.api.nvim_create_augroup
  vim.api.nvim_create_augroup = function(...)
    creates = creates + 1
    return real_create(...)
  end
  diag.install()
  local after_first = creates
  local present_after_first = group_present(GROUP)
  local buf_present_after_first = group_present(BUF_GROUP)
  diag.install()                      -- must be a no-op
  local after_second = creates
  vim.api.nvim_create_augroup = real_create

  ok("p41: install creates both augroups",
    after_first == 2 and present_after_first and buf_present_after_first,
    "creates=" .. after_first .. " main=" .. tostring(present_after_first)
      .. " buf=" .. tostring(buf_present_after_first))
  ok("p41: install is idempotent — a second call does not re-create it",
    after_second == after_first,
    "creates went " .. after_first .. " -> " .. after_second)

  diag.uninstall()
  ok("p41: uninstall returns cleanly and both groups are gone",
    not group_present(GROUP) and not group_present(BUF_GROUP))
  diag.install()

  -- 41b. Open a malformed automated file → buffer-attach emits a
  -- diagnostic entry pointing at the offending condition[i] line.
  --
  -- Use `vim.cmd("edit")` so the autocmd path fires the same way
  -- it would in real use.
  local todo_dir = tmp_root .. "/.todo-list/automated"
  vim.fn.mkdir(todo_dir, "p")
  local bad_path = todo_dir .. "/2026-05-30-p41-malformed.md"
  local bad_src = table.concat({
    "---",
    'id: "2026-05-30-p41-malformed"',
    "version: 1",
    'status: automated',
    'title: malformed cron test',
    "description: test fixture",
    "created: \"2026-05-30T00:00:00Z\"",
    "updated: \"2026-05-30T00:00:00Z\"",
    "status_changed: \"2026-05-30T00:00:00Z\"",
    "condition:",
    "  - this is not a cron expression",
    "execute:",
    "  - assign agent:lector",
    "---",
    "",
    "body",
  }, "\n")
  local f = io.open(bad_path, "w"); f:write(bad_src); f:close()

  vim.cmd("edit " .. vim.fn.fnameescape(bad_path))
  local bufnr_bad = vim.api.nvim_get_current_buf()
  -- M.attach is called from BufReadPost; the initial _validate is
  -- vim.schedule'd (defensive fix for the headless SEGFAULT, KB todo
  -- 2026-06-13-…), so wait one tick for it to land before sampling.
  vim.wait(80, function() return false end)
  local diags = vim.diagnostic.get(bufnr_bad, { namespace = diag.NS })
  ok("p41: malformed cron emits a diagnostic",
    #diags >= 1, "got " .. #diags .. " diagnostics")
  local saw_cron_code = false
  for _, d in ipairs(diags) do
    if d.code == "automation-condition-malformed" then saw_cron_code = true end
  end
  ok("p41: diagnostic carries code automation-condition-malformed",
    saw_cron_code)
  -- The diagnostic's lnum should point at the line WITH the
  -- offending entry (`  - this is not a cron expression`). That's
  -- 0-based line index 10 (1-indexed line 11 in the source above).
  local at_offending_line = false
  for _, d in ipairs(diags) do
    if d.code == "automation-condition-malformed" then
      at_offending_line = d.lnum == 10
    end
  end
  ok("p41: diagnostic points at the offending `- this is not a cron...` line",
    at_offending_line,
    "got diags: " .. vim.inspect(diags))

  -- 41c. Fix the buffer in place → debounced revalidate clears
  -- the diagnostic.
  vim.api.nvim_buf_set_lines(bufnr_bad, 10, 11, false,
    { "  - 0 8 * * *" })  -- valid cron now
  -- Trigger a revalidate by re-attaching. The initial validate is
  -- scheduled (defensive fix for the headless SEGFAULT, KB todo
  -- 2026-06-13-…), so poll for the expected condition rather than
  -- assuming a synchronous result.
  diag.attach(bufnr_bad)
  vim.wait(200, function()
    return #vim.diagnostic.get(bufnr_bad, { namespace = diag.NS }) == 0
  end)
  local diags_after = vim.diagnostic.get(bufnr_bad, { namespace = diag.NS })
  ok("p41: diagnostic clears after fix",
    #diags_after == 0, "got " .. #diags_after .. " diagnostics")

  -- 41d. Non-automated buffer → no diagnostics, even after
  -- attach.
  vim.api.nvim_buf_set_lines(bufnr_bad, 3, 4, false,
    { 'status: open' })
  vim.api.nvim_buf_set_lines(bufnr_bad, 9, 12, false, {})  -- drop condition/execute
  diag.attach(bufnr_bad)
  vim.wait(200, function()
    return #vim.diagnostic.get(bufnr_bad, { namespace = diag.NS }) == 0
  end)
  local diags_nonauto = vim.diagnostic.get(bufnr_bad, { namespace = diag.NS })
  ok("p41: non-automated status clears all diagnostics",
    #diags_nonauto == 0)

  -- 41d-regression-A: uninstall before the scheduled validate tick
  -- must NOT leave a queued callback that re-creates diagnostics
  -- after teardown. The generation guard in M.attach makes the
  -- scheduled _validate a no-op when _buffer_state[bufnr] is nil.
  -- Without the guard, the callback fires after uninstall, calls
  -- vim.diagnostic.set on the now-untracked buffer, and
  -- attached_buffers() reports 0 while a diagnostic is visible.
  do
    local reg_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(reg_buf, 0, -1, false, {
      "---",
      'id: "2026-05-30-p41-reg-uninstall"',
      "version: 1",
      'status: automated',
      "title: uninstall-before-tick regression",
      "description: test fixture",
      'created: "2026-05-30T00:00:00Z"',
      'updated: "2026-05-30T00:00:00Z"',
      'status_changed: "2026-05-30T00:00:00Z"',
      "condition:",
      "  - this is not a cron expression",
      "execute:",
      "  - do-something",
      "---",
      "",
      "body",
    })
    vim.api.nvim_buf_set_name(reg_buf, todo_dir .. "/2026-05-30-p41-reg-uninstall.md")
    -- Attach: schedules a _validate on the next tick.
    diag.attach(reg_buf)
    -- Uninstall BEFORE the tick lands: clears _buffer_state, drops
    -- both augroups, resets diagnostics on every tracked buffer.
    diag.uninstall()
    -- Now let the event loop run so any queued scheduled callback
    -- fires. If the generation guard is missing, the callback runs
    -- _validate which calls vim.diagnostic.set → orphans a diagnostic.
    vim.wait(50, function() return false end)
    local diags_after_uninstall = vim.diagnostic.get(reg_buf, { namespace = diag.NS })
    ok("p41: uninstall-before-first-tick leaves NO orphan diagnostics",
      #diags_after_uninstall == 0,
      "got " .. #diags_after_uninstall .. " diagnostics after uninstall+tick")
    ok("p41: attached_buffers is empty after uninstall-before-tick",
      #diag.attached_buffers() == 0,
      "got " .. #diag.attached_buffers() .. " attached buffers")
    -- Re-install for the downstream sections that expect it.
    diag.install()
    pcall(vim.api.nvim_buf_delete, reg_buf, { force = true })
  end

  -- 41d-regression-B: stale-callback-after-reattach. A rapid
  -- attach → attach (same buffer, before the first scheduled tick)
  -- must reject the FIRST attachment's scheduled callback so only
  -- the LATEST attachment's validate fires. Without the generation
  -- guard, both callbacks run _validate — the stale one can write
  -- diagnostics reflecting outdated buffer state. Assert exactly
  -- one vim.diagnostic.set call from the scheduled callbacks by
  -- counting via a thin wrapper.
  do
    local reg_buf2 = vim.api.nvim_create_buf(false, true)
    local automated_lines = {
      "---",
      'id: "2026-05-30-p41-reg-reattach"',
      "version: 1",
      'status: automated',
      "title: stale-reattach regression",
      "description: test fixture",
      'created: "2026-05-30T00:00:00Z"',
      'updated: "2026-05-30T00:00:00Z"',
      'status_changed: "2026-05-30T00:00:00Z"',
      "condition:",
      "  - this is not a cron expression",
      "execute:",
      "  - do-something",
      "---",
      "",
      "body",
    }
    vim.api.nvim_buf_set_lines(reg_buf2, 0, -1, false, automated_lines)
    vim.api.nvim_buf_set_name(reg_buf2, todo_dir .. "/2026-05-30-p41-reg-reattach.md")

    -- Wrap vim.diagnostic.set to count calls for this buffer.
    local set_count = 0
    local orig_set = vim.diagnostic.set
    local function counting_set(ns, buf, diags, opts)
      if buf == reg_buf2 and ns == diag.NS then
        set_count = set_count + 1
      end
      return orig_set(ns, buf, diags, opts)
    end
    vim.diagnostic.set = counting_set

    -- First attach: schedules callback with gen=N.
    diag.attach(reg_buf2)
    -- Immediately re-attach: bumps gen to N+1, replaces the prior
    -- debouncer, schedules a NEW callback with gen=N+1.
    diag.attach(reg_buf2)
    -- Let the event loop run: both scheduled callbacks fire. The
    -- gen guard must reject the first (stale gen=N), so only the
    -- second (gen=N+1) runs _validate → exactly one diagnostic.set.
    vim.wait(100, function() return set_count >= 1 end)
    vim.diagnostic.set = orig_set

    ok("p41: stale-reattach rejects old-gen callback (exactly one diagnostic.set)",
      set_count == 1,
      "got " .. set_count .. " diagnostic.set calls for reg_buf2")
    local diags_reattach = vim.diagnostic.get(reg_buf2, { namespace = diag.NS })
    ok("p41: stale-reattach leaves correct diagnostics (from latest attachment only)",
      #diags_reattach >= 1,
      "got " .. #diags_reattach .. " diagnostics")
    pcall(vim.api.nvim_buf_delete, reg_buf2, { force = true })
  end

  -- 41e. Refresh-side wiring (Phase 3 wires automation.validate
  -- into compute_errors). Create a malformed automated template
  -- via direct file write, call todo.refresh, assert the task's
  -- errors[] now carries the validator entry.
  local refresh_path = todo_dir .. "/2026-05-30-p41-refresh-test.md"
  local refresh_src = table.concat({
    "---",
    'id: "2026-05-30-p41-refresh-test"',
    "version: 1",
    'status: automated',
    'title: refresh-side validation',
    "description: test fixture",
    "created: \"2026-05-30T00:00:00Z\"",
    "updated: \"2026-05-30T00:00:00Z\"",
    "status_changed: \"2026-05-30T00:00:00Z\"",
    "condition:",
    "  - 0 0 * * *",
    "execute:",
    "  - do-magic now",  -- no built-in / hook / executor matches
    "---",
    "",
    "body",
  }, "\n")
  local g = io.open(refresh_path, "w"); g:write(refresh_src); g:close()

  todo.refresh()
  local task = todo.get("2026-05-30-p41-refresh-test")
  ok("p41: refresh-side errors[] populated for malformed automated template",
    task and type(task.errors) == "table" and #task.errors >= 1,
    "got errors: " .. vim.inspect(task and task.errors))
  local has_exec_err = false
  for _, e in ipairs((task or {}).errors or {}) do
    if e.code == "automation-execute-malformed" then has_exec_err = true end
  end
  ok("p41: refresh-side error carries automation-execute-malformed code",
    has_exec_err)

  -- 41f. Bash-disabled panel indicator. Create an automated
  -- template with a bash step, render the panel, assert the
  -- panel buffer contains the `[bash:disabled]` marker.
  local bash_tpl = todo.add({
    id          = "2026-05-30-p41-bash-template",
    title       = "bash template",
    description = "uses bash",
  })
  todo.status(bash_tpl, "automated")
  -- Patch condition/execute via direct file mutation (same
  -- pattern Phase 2 smoke uses).
  local paths_p41 = require("auto-core.todo.paths")
  local md_p41    = require("auto-core.todo.md")
  local bash_tpl_path = paths_p41.task_file_path(
    paths_p41.resolve_todo_dir(), bash_tpl, "automated", nil)
  do
    local h = io.open(bash_tpl_path, "r"); local txt = h:read("*a"); h:close()
    local dec = md_p41.decode(txt)
    dec.value.condition = { "0 8 * * *" }
    dec.value.execute   = { "bash echo hi" }
    local enc = md_p41.encode(dec.value)
    local i = io.open(bash_tpl_path .. ".tmp", "w"); i:write(enc); i:close()
    os.rename(bash_tpl_path .. ".tmp", bash_tpl_path)
  end

  -- Reset trust state to default (bash_enabled=false).
  local state = require("auto-core.state")
  local ns_p41 = state.namespace("auto-core.todo.automation")
  ns_p41:set("bash_enabled", false)
  ns_p41:set("bash_first_run_acknowledged", false)

  vim.cmd("vsplit")
  local panel_win = vim.api.nvim_get_current_win()
  local view = require("auto-finder.views.todos")
  local b = view.get_buffer(panel_win)
  vim.api.nvim_win_set_buf(panel_win, b)
  todo.refresh()
  vim.wait(150, function() return false end)
  local panel_text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  ok("p41: [bash:disabled] indicator visible when bash_enabled=false",
    panel_text:find("[bash:disabled]", 1, true) ~= nil)

  -- Enable bash → indicator disappears on re-render.
  automation.acknowledge_first_run()
  automation.set_trust({ bash_enabled = true })
  -- view.get_buffer is cached after first render; force a fresh
  -- render via on_focus (also the path BufEnter takes when the
  -- user navigates back to the panel).
  view.on_focus(panel_win, b)
  vim.wait(80, function() return false end)
  local panel_text2 = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  ok("p41: [bash:disabled] indicator absent when bash_enabled=true",
    panel_text2:find("[bash:disabled]", 1, true) == nil)

  -- Reset trust for downstream tests.
  ns_p41:set("bash_enabled", false)

  if vim.api.nvim_win_is_valid(panel_win) then
    pcall(vim.api.nvim_win_close, panel_win, true)
  end
  pcall(vim.api.nvim_buf_delete, bufnr_bad, { force = true })
  cleanup()
end)()

-- ─────────────────── 42. ADR-0035 post-ship: scaffold-on-promote ────
-- When the user selects `automated` from the panel `s` modal on
-- a non-automated task, auto-finder appends a usage-instructions
-- section to the body AND populates `condition:` / `execute:`
-- with working defaults (daily-at-midnight cron + a CAPTURED
-- `bash echo hello world` step — 2026-06-01, switched from the
-- terminal-routed `bash -t=1` default so a fresh template records
-- an exit_code and auto-completes on success). Idempotent:
-- re-cycling automated → open → automated doesn't double-append.
print("\n[42] ADR-0035 post-ship — scaffold on `automated` promotion via `s` modal")
;(function()
  local ok_v, view = pcall(require, "auto-finder.views.todos")
  if not ok_v then return end
  local ok_t, todo = pcall(require, "auto-core.todo")
  if not ok_t then return end

  -- Isolate workspace + state.
  local tmp_root  = vim.fn.tempname()
  local state_tmp = vim.fn.tempname() .. "_p42-state"
  vim.fn.mkdir(tmp_root, "p")
  vim.fn.mkdir(state_tmp, "p")
  require("auto-core.state").configure({ persist_dir = state_tmp })
  local worktree = require("auto-core.git.worktree")
  worktree.set_workspace_root(tmp_root)
  local function cleanup()
    worktree.set_workspace_root(nil)
    require("auto-core.state").configure({ persist_dir = nil })
    vim.fn.delete(tmp_root,  "rf")
    vim.fn.delete(state_tmp, "rf")
  end

  -- Build the panel via the view module (mirrors [39c] / [40]
  -- pattern). The `s` modal callback is exercised through the
  -- buffer's keymap.
  --
  -- IMPORTANT: invalidate view._bufnr / _rows from any prior
  -- section ([41]'s buffer outlives its cleanup since it was a
  -- nofile/hide buffer, not :bw'd). get_buffer's cache returns
  -- the stale buffer otherwise, which still carries [41]'s row
  -- list, and our task_id lookup fails.
  view._bufnr = nil
  view._rows  = nil
  local id = todo.add({ id = "2026-05-31-p42-promote-target",
    title = "to promote", description = "starting body" })
  todo.refresh()
  vim.cmd("vsplit")
  local panel_win = vim.api.nvim_get_current_win()
  -- Scaffolding-robustness fix vs. the old smoke.lua copy: `:vsplit`
  -- copies window-local options, so when the current window is a panel
  -- (as it is here, right after [41] leaves a winfixbuf'd todos buffer
  -- in the last window), the new split inherits winfixbuf=true and the
  -- set_buf below raises E1513. smoke.lua's [39c]/[40]/[42] never hit
  -- this only because their ordering happened to leave a normal editor
  -- window current. Clear it so the scaffolding is self-sufficient —
  -- winfixbuf ENFORCEMENT is covered by sections [4]/[5], not here.
  vim.wo[panel_win].winfixbuf = false
  local bufnr = view.get_buffer(panel_win)
  vim.api.nvim_win_set_buf(panel_win, bufnr)

  -- Find the row + cursor onto it.
  local task_lnum
  for _, row in ipairs(view._rows or {}) do
    if row.kind == "task" and row.task and row.task.id == id then
      task_lnum = row.lnum; break
    end
  end
  ok("p42: task row found in panel rows", type(task_lnum) == "number")
  vim.api.nvim_win_set_cursor(panel_win, { task_lnum, 0 })

  -- Stub vim.ui.select to pick "automated" by name (matches the
  -- [39c] pattern that picks by string match). Don't stub
  -- vim.cmd — the scaffold helper's `edit` call is fine to run
  -- in headless (it loads the buffer; we don't care about the
  -- side effect for this assertion).
  local captured_choices
  local orig_select = vim.ui.select
  vim.ui.select = function(items, _opts, on_choice)
    captured_choices = items
    for _, item in ipairs(items) do
      if item == "automated" then on_choice(item); return end
    end
    on_choice(items[1])
  end

  -- Fire the `s` keymap.
  local maps = vim.api.nvim_buf_get_keymap(bufnr, "n")
  local s_cb
  for _, mp in ipairs(maps) do
    if mp.lhs == "s" then s_cb = mp.callback; break end
  end
  if s_cb then s_cb() end
  vim.wait(150, function() return false end)

  ok("p42: modal listed 6 statuses including `automated`",
    captured_choices and #captured_choices == 6
      and (function()
        for _, item in ipairs(captured_choices) do
          if item == "automated" then return true end
        end
        return false
      end)())

  local promoted = todo.get(id)
  ok("p42: task status flipped to automated",
    promoted and promoted.status == "automated",
    "got: " .. tostring(promoted and promoted.status))

  -- Defaults populated.
  ok("p42: condition defaulted to daily-at-midnight cron",
    promoted and type(promoted.condition) == "table"
      and #promoted.condition == 1
      and promoted.condition[1] == "0 0 * * *",
    "got: " .. vim.inspect(promoted and promoted.condition))
  ok("p42: execute defaulted to captured-bash `bash echo hello world`",
    promoted and type(promoted.execute) == "table"
      and #promoted.execute == 1
      and promoted.execute[1] == "bash echo hello world",
    "got: " .. vim.inspect(promoted and promoted.execute))

  -- Body scaffold appended.
  ok("p42: body carries the `## How to author this template` scaffold",
    promoted and type(promoted.description) == "string"
      and promoted.description:find("How to author this template", 1, true) ~= nil)
  ok("p42: prior body content preserved (not clobbered)",
    promoted and promoted.description:find("starting body", 1, true) ~= nil)

  -- The scaffold schedules an `edit <file>` via vim.schedule —
  -- assert the file ends up loaded into a buffer (a vim.wait gives
  -- the scheduled callback a chance to run). We don't assert it's
  -- the CURRENT buffer because the panel render also schedules
  -- focus restoration that may run after the edit.
  vim.wait(200, function()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(b)
      if name and name:find(id, 1, true) then return true end
    end
    return false
  end)
  local loaded_into_buffer = false
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if name and name:find(id, 1, true) then loaded_into_buffer = true; break end
  end
  ok("p42: scaffold opened the task file in a buffer (scheduled edit)",
    loaded_into_buffer)

  -- Validator does NOT flag the empty-list rule (the scaffold
  -- populated working defaults). The default is now a plain
  -- captured `bash echo hello world` step (a built-in primitive),
  -- so unlike the old `bash -t=1` default it doesn't even need the
  -- auto-agents executor registered — no `automation-bash-t-no-resolver`
  -- here. The assertion specifically guards against the
  -- empty-condition / empty-execute case the scaffold prevents.
  local automation = require("auto-core.todo.automation")
  local errs = automation.validate(promoted)
  local has_empty_err = false
  for _, e in ipairs(errs) do
    if (e.field == "condition" or e.field == "execute")
        and type(e.message) == "string"
        and e.message:find("empty or missing", 1, true)
    then
      has_empty_err = true; break
    end
  end
  ok("p42: scaffolded template does NOT trigger empty-list validator errors",
    not has_empty_err,
    "got: " .. vim.inspect(errs))

  -- Demote round-trip: ADR-0035 post-ship Lector blocker. The
  -- modal lists `automated` AS a destination AND lets the user
  -- pick `open` / `deferred` / etc. when the task is currently
  -- automated. auto-core's M.status clears condition / execute /
  -- last_fired_at on transitions away from automated so the
  -- "non-automated rejects these fields" validator rule doesn't
  -- reject the demote write.
  local demoted, derr = todo.status(id, "open")
  ok("p42: demote automated → open succeeds",
    demoted ~= nil and derr == nil,
    "got err: " .. tostring(derr))
  ok("p42: demote cleared condition (post-ship Lector blocker)",
    demoted and demoted.condition == nil,
    "got: " .. vim.inspect(demoted and demoted.condition))
  ok("p42: demote cleared execute",
    demoted and demoted.execute == nil)
  ok("p42: demote cleared last_fired_at",
    demoted and demoted.last_fired_at == nil)

  -- Re-promote via direct todo.status (NOT the modal — the modal
  -- callback fires through _set_status which we already tested
  -- on first promotion above; testing it twice in the same panel
  -- session is fragile and adds no new coverage. The demote +
  -- re-promote round-trip semantics are covered exhaustively in
  -- auto-core smoke [72]). Here we just confirm the re-promote
  -- succeeds at all (the auto-core M.status fix unlocks it).
  local re_promoted, rp_err = todo.status(id, "automated")
  ok("p42: re-promote open → automated succeeds (auto-core M.status fix)",
    re_promoted and re_promoted.status == "automated" and rp_err == nil,
    "got: " .. tostring(re_promoted and re_promoted.status)
      .. " err: " .. tostring(rp_err))
  -- The body retains exactly ONE scaffold section (the marker
  -- guard inside `_scaffold_automated_template` would prevent
  -- re-appending IF the panel modal were used; this direct
  -- todo.status path doesn't trigger the scaffold helper at all,
  -- so the body is unchanged from the first promotion).
  local _, count = (re_promoted.description or ""):gsub(
    "## How to author this template", "")
  ok("p42: scaffold body present exactly once after round-trip",
    count == 1, "got " .. count .. " scaffold sections")

  -- Restore + cleanup.
  vim.ui.select = orig_select
  if vim.api.nvim_win_is_valid(panel_win) then
    pcall(vim.api.nvim_win_close, panel_win, true)
  end
  cleanup()
end)()

-- ───────────────────────── summary ────────────────────────
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
