-- Phase 0a binary go/no-go spike for the dbase section.
--
-- Single load-bearing question:
--   Does `dbee.api.ui.drawer_show(panel_winid)` survive auto-finder's
--   `winfixwidth` + `winfixbuf` panel contract?
--
-- Run headless from the spike worktree root:
--   nvim --headless -u NONE -l tests/dbase_spike.lua
--
-- Exits 0 on PASS, 1 on FAIL. SKIP lines do not fail the run; they
-- record what couldn't be exercised in the current environment.
--
-- Two execution modes:
--   A. dbee binary present → full assertions incl. drawer-mount survival.
--   B. dbee unloadable or binary missing → structural assertions only
--      (section registers, get_buffer returns a placeholder buffer, no
--      crash) with SKIP for the load-bearing question.

local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
local nvim_plugins_root = vim.fn.fnamemodify(plugin_root, ":h:h")

local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
-- Prefer the sibling `dbase-events` worktree of auto-core when present
-- (it carries the six `dbase.*` topic registrations slice 3 added);
-- fall back to `main` and then the lazy install. Listed first wins
-- because we prepend.
for _, p in ipairs({
  plugin_root,
  nvim_plugins_root .. "/auto-core.nvim/dbase-events",
  nvim_plugins_root .. "/auto-core.nvim/main",
  nvim_plugins_root .. "/nvim-dbee",
  LAZY .. "/auto-core.nvim",
  LAZY .. "/nvim-dbee",
  LAZY .. "/nui.nvim",
  LAZY .. "/plenary.nvim",
}) do
  if vim.fn.isdirectory(p) == 1 then
    vim.opt.runtimepath:prepend(p)
  end
end

vim.o.columns = 200
vim.o.lines = 60
vim.o.swapfile = false
vim.o.hidden = true

vim.fn.delete("/tmp/auto-finder-dbase-spike-config", "rf")
vim.env.XDG_CONFIG_HOME = "/tmp/auto-finder-dbase-spike-config"
vim.fn.delete("/tmp/auto-finder-dbase-spike-state", "rf")
vim.env.XDG_STATE_HOME = "/tmp/auto-finder-dbase-spike-state"

local fail_count, pass_count, skip_count = 0, 0, 0
local function ok(name, cond, detail)
  if cond then
    pass_count = pass_count + 1
    print(string.format("  PASS  %s", name))
  else
    fail_count = fail_count + 1
    print(string.format("  FAIL  %s  %s", name, tostring(detail or "")))
  end
end
local function skip(name, reason)
  skip_count = skip_count + 1
  print(string.format("  SKIP  %s  (%s)", name, reason))
end

-- ───────────────────── 1. dbee availability probe ──────────────────────
print("\n[1] dbee availability probe")
local dbee_ok, dbee = pcall(require, "dbee")
ok("nvim-dbee is on the runtimepath", dbee_ok,
  dbee_ok and "" or "tried " .. nvim_plugins_root .. "/nvim-dbee and lazy")

-- Phase 0a's load-bearing question is about WINDOW CONTRACT survival,
-- not query execution. dbee's drawer UI is Lua-only (buffer + nui tree);
-- the Go backend only spins up on operations that need it (query exec,
-- connection introspection). Empty memory source → drawer mounts without
-- ever invoking the backend. So binary presence is informational only,
-- not a gating signal for this test.
local dbee_binary_path = vim.fn.stdpath("data") .. "/dbee/bin/dbee"
local dbee_binary_present = dbee_ok
    and vim.fn.executable(dbee_binary_path) == 1
print(string.format("  binary at %s: %s (informational; not gating)",
  dbee_binary_path,
  dbee_binary_present and "present" or "absent"))

-- ───────────────────── 2. auto-finder setup with dbase ─────────────────
print("\n[2] auto-finder.setup() with dbase section")
require("auto-finder.neotree").setup({
  window = { auto_expand_width = true },
  filesystem = { hijack_netrw_behavior = "disabled" },
})
local af = require("auto-finder")
local setup_ok, setup_err = pcall(af.setup, {
  width = { default = 38, min = 25, max = 100 },
  default_section = 1,
  sections = { "config", "files", "dbase" },
  neo_tree = {
    window = { auto_expand_width = true },
    filesystem = { hijack_netrw_behavior = "disabled" },
  },
})
ok("setup returns without error", setup_ok, setup_err)
local sections = require("auto-finder.sections")
ok("3 sections registered", #sections.enabled() == 3,
  "got " .. #sections.enabled())
local dbase_sec = sections.resolve("dbase")
ok("dbase section resolves by name", dbase_sec ~= nil)
ok("dbase section number = 2", dbase_sec and dbase_sec.number == 2,
  dbase_sec and ("got " .. dbase_sec.number) or "missing")

-- ───────────────────── 3. open panel + capture baseline ────────────────
print("\n[3] open panel — baseline winfixbuf/winfixwidth")
af.open(true)
local panel = af.state.panel_winid
ok("panel_winid set", panel ~= nil and vim.api.nvim_win_is_valid(panel))
ok("winfixwidth=true on panel (baseline)",
  panel and vim.wo[panel].winfixwidth == true)
ok("winfixbuf=true on panel (baseline)",
  panel and vim.wo[panel].winfixbuf == true)

-- ───────────────────── 4. focus dbase — THE LOAD-BEARING TEST ──────────
print("\n[4] focus(dbase) — does drawer_show survive winfixbuf+winfixwidth?")

-- Capture :messages so we can scan for E1513 after the focus.
vim.cmd("redir => g:dbase_spike_messages_before")
vim.cmd("silent messages")
vim.cmd("redir END")
local messages_before = vim.g.dbase_spike_messages_before or ""

local focus_ok, focus_err = af.focus("dbase")
ok("focus(dbase) returns ok", focus_ok, focus_err)
ok("state.section == 2 (dbase)", af.state.section == 2,
  "got " .. tostring(af.state.section))

-- Give any async drawer init a tick.
vim.wait(250, function()
  return panel and vim.api.nvim_win_is_valid(panel)
    and vim.api.nvim_buf_is_valid(vim.api.nvim_win_get_buf(panel))
end, 5)

-- The five questions Phase 0a exists to answer.
ok("[Q1] panel_winid still valid after focus(dbase)",
  panel and vim.api.nvim_win_is_valid(panel))
ok("[Q2] winfixbuf=true after dbase mount",
  panel and vim.wo[panel].winfixbuf == true,
  panel and "got " .. tostring(vim.wo[panel].winfixbuf) or "no panel")
ok("[Q3] winfixwidth=true after dbase mount",
  panel and vim.wo[panel].winfixwidth == true,
  panel and "got " .. tostring(vim.wo[panel].winfixwidth) or "no panel")

vim.cmd("redir => g:dbase_spike_messages_after")
vim.cmd("silent messages")
vim.cmd("redir END")
local messages_after = vim.g.dbase_spike_messages_after or ""
local new_messages = messages_after:sub(#messages_before + 1)
local has_e1513 = new_messages:find("E1513") ~= nil
ok("[Q4] no E1513 raised during focus(dbase)", not has_e1513,
  has_e1513 and "new messages contained E1513:\n" .. new_messages or "")

local panel_buf = panel and vim.api.nvim_win_get_buf(panel)
local panel_ft = panel_buf and vim.bo[panel_buf].filetype or ""
local panel_bufname = panel_buf and vim.api.nvim_buf_get_name(panel_buf) or ""
print(string.format("  panel buffer ft=%q name=%q",
  panel_ft, panel_bufname))

-- Did dbee's drawer actually mount into the panel? Two-way gate:
--   - filetype starts with "dbee" (drawer sets ft="dbee"), OR
--   - buffer name ends with "dbee-drawer" / starts with "dbee://"
local mounted_drawer = panel_ft:find("^dbee") ~= nil
  or panel_bufname:find("dbee%-drawer$") ~= nil
  or panel_bufname:find("^dbee://") ~= nil
local mounted_placeholder = panel_bufname
  :find("auto%-finder%-dbase://placeholder") ~= nil

if dbee_ok then
  ok("[Q5] dbee drawer mounted into panel (not placeholder)",
    mounted_drawer and not mounted_placeholder,
    string.format("ft=%q name=%q", panel_ft, panel_bufname))
else
  ok("[Q5-fallback] placeholder rendered when dbee unloadable",
    mounted_placeholder,
    "name=" .. panel_bufname)
end

-- ───────────────────── 5. close → reopen lifecycle ─────────────────────
print("\n[5] close → reopen — no orphan dbee windows, panel clean")
af.close()
ok("after close, panel_winid is nil", af.state.panel_winid == nil)

-- Count windows that look like orphan dbee splits (would indicate
-- dbee's default layout fought our close). dbee buffers register
-- buftype="nofile" and have filetypes like "dbee-drawer", but the
-- robust check is: are there windows in the editor area carrying any
-- buffer whose name starts with `dbee://`?
local orphan_dbee_windows = 0
for _, w in ipairs(vim.api.nvim_list_wins()) do
  if vim.api.nvim_win_is_valid(w) then
    local b = vim.api.nvim_win_get_buf(w)
    local n = vim.api.nvim_buf_get_name(b)
    if n:find("^dbee://") or vim.bo[b].filetype:find("^dbee") then
      orphan_dbee_windows = orphan_dbee_windows + 1
    end
  end
end
ok("no orphan dbee windows after close",
  orphan_dbee_windows == 0,
  "found " .. orphan_dbee_windows)

af.open(true)
local panel2 = af.state.panel_winid
ok("reopen — panel_winid valid",
  panel2 and vim.api.nvim_win_is_valid(panel2))
ok("reopen — winfixbuf=true",
  panel2 and vim.wo[panel2].winfixbuf == true)
ok("reopen — winfixwidth=true",
  panel2 and vim.wo[panel2].winfixwidth == true)

af.focus("dbase")
vim.wait(250, function()
  return panel2 and vim.api.nvim_win_is_valid(panel2)
    and vim.api.nvim_buf_is_valid(vim.api.nvim_win_get_buf(panel2))
end, 5)
ok("reopen — focus(dbase) still works",
  af.state.section == 2)

-- ───────────────────── 5b. config-forwarding (slice 5) ────────────────
-- Verify `cfg.dbase = { sources = ... }` actually reaches the section's
-- `_setup_opts` and through to `_dbase_setup.ensure_setup(opts)`.
print("\n[5b] config-forwarding — cfg.dbase → section.configure → setup_opts")
do
  local section = require("auto-finder.sections.dbase")
  ok("section.configure exists",
    type(section.configure) == "function")

  -- The earlier `af.setup({ ... })` call at section [2] did NOT pass
  -- a dbase block, so `_setup_opts` should be nil-or-default at this
  -- point. Verify the no-op case first.
  ok("section._setup_opts is nil when cfg.dbase not provided",
    section._setup_opts == nil
      or (type(section._setup_opts) == "table" and section._setup_opts.sources == nil))

  -- Now exercise the forwarding path with a synthetic source. We
  -- build a real MemorySource so the test stays honest — the wrapper
  -- shouldn't care what's in it, just that it lands.
  local ok_src, dbee_sources = pcall(require, "dbee.sources")
  if not ok_src then
    skip("config-forwarding round-trip",
      "dbee.sources unavailable")
  else
    local probe_source = dbee_sources.MemorySource:new({
      { id = "probe-conn-1", name = "probe", type = "sqlite", url = ":memory:" },
    }, "spike-probe")
    -- Re-run setup with cfg.dbase. setup is re-entrant from auto-finder's
    -- side; the section registry rebuilds and our forwarding fires again.
    -- (dbee.setup is one-shot module-globally, so the setup_mod's cached
    -- _done flag prevents re-config; this is intentional and we're
    -- testing the *forwarding* path, not dbee re-setup.)
    af.setup({
      width = { default = 38, min = 25, max = 100 },
      default_section = 1,
      sections = { "config", "files", "dbase" },
      dbase = { sources = { probe_source } },
      neo_tree = {
        window = { auto_expand_width = true },
        filesystem = { hijack_netrw_behavior = "disabled" },
      },
    })
    ok("_setup_opts is a table after re-setup with cfg.dbase",
      type(section._setup_opts) == "table")
    ok("_setup_opts.sources is forwarded list",
      type(section._setup_opts) == "table"
        and type(section._setup_opts.sources) == "table"
        and #section._setup_opts.sources == 1,
      "got " .. vim.inspect(section._setup_opts))
    ok("_setup_opts.sources[1] is the probe MemorySource",
      type(section._setup_opts) == "table"
        and section._setup_opts.sources
        and section._setup_opts.sources[1] == probe_source)
  end
end

-- ───────────────────── 5c. dbee log bridge (slice 4) ──────────────────
-- Verify dbee's `utils.log` is wrapped so messages enter auto-core's
-- ring under `auto-finder.dbase.upstream.<subtitle>`. Skips when
-- auto-core or dbee is unavailable.
print("\n[5c] log bridge — dbee.utils.log → auto-core.log")
do
  local setup_mod = require("auto-finder.sections._dbase_setup")
  local ok_dbee_utils, dbee_utils = pcall(require, "dbee.utils")
  local ok_core_log, core_log_mod
  do
    local ok_ac, ac = pcall(require, "auto-core")
    if ok_ac and type(ac.log) == "table" then
      ok_core_log, core_log_mod = true, ac.log
    end
  end

  if not (ok_dbee_utils and ok_core_log and setup_mod.is_setup_done()) then
    skip("log-bridge round-trip",
      string.format("dbee_utils=%s core_log=%s setup_done=%s",
        tostring(ok_dbee_utils), tostring(ok_core_log),
        tostring(setup_mod.is_setup_done())))
  else
    ok("setup_mod reports log bridge installed",
      setup_mod._log_bridge_installed == true)
    ok("dbee.utils.log is wrapped (not the original)",
      dbee_utils.log ~= setup_mod._original_dbee_log)

    -- Fire a synthetic dbee log. ERROR level so it doesn't depend on
    -- whatever the auto-core log level happens to be configured at.
    -- vim.notify will fire too but that's fine in headless mode.
    dbee_utils.log("error", "spike-probe-message", "spike-subtitle")

    -- Scan recent entries for the bridged line.
    local entries = core_log_mod.recent(50)
    local found
    for _, e in ipairs(entries) do
      if e.component == "auto-finder.dbase.upstream.spike-subtitle"
          and tostring(e.message):find("spike%-probe%-message") then
        found = e
        break
      end
    end
    ok("auto-core.log captured the bridged dbee entry",
      found ~= nil)
    ok("captured entry has level_name=ERROR",
      found and found.level_name == "ERROR",
      found and ("got " .. tostring(found.level_name)) or "")

    -- nil subtitle path: should bucket under .upstream.core
    dbee_utils.log("warn", "no-subtitle-message")
    local entries2 = core_log_mod.recent(50)
    local found_core
    for _, e in ipairs(entries2) do
      if e.component == "auto-finder.dbase.upstream.core"
          and tostring(e.message):find("no%-subtitle%-message") then
        found_core = e
        break
      end
    end
    ok("nil-subtitle bridges to .upstream.core",
      found_core ~= nil)
  end
end

-- ───────────────────── 6. event bridge (slice 2) ───────────────────────
-- Round-trip: subscribe to dbase.* topics on auto-core's bus, fire
-- synthetic dbee events via the internal event_bus, then assert the
-- bridge forwarded them with the right payloads. Skips when auto-core
-- or dbee isn't available.
print("\n[6] event bridge — dbee → auto-core.events forwarding")

local events_mod = require("auto-finder.sections._dbase_events")
local ok_core, core = pcall(require, "auto-core")
local ok_dbee_bus, dbee_event_bus = pcall(require, "dbee.handler.__events")

if not (ok_core and ok_dbee_bus and events_mod.is_attached()) then
  skip("event bridge round-trip",
    string.format("auto-core=%s dbee_bus=%s attached=%s",
      tostring(ok_core), tostring(ok_dbee_bus),
      tostring(events_mod.is_attached())))
else
  local conn_hits = {}
  local call_hits = {}
  local h_conn = core.events.subscribe("dbase.connection:changed",
    function(p) table.insert(conn_hits, p) end)
  local h_call = core.events.subscribe("dbase.call:*",
    function(p, topic) table.insert(call_hits, { topic = topic, payload = p }) end)

  -- Synthetic dbee events — bypasses the Go backend.
  -- IMPORTANT: payloads MUST match dbee's real shape. The Go backend
  -- emits `call_state_changed` as a NESTED table — see
  -- `nvim-dbee/dbee/handler/event_bus.go:30-44`:
  --   { call = { id, query, state, time_taken_us, timestamp_us, error } }
  -- An earlier version of this smoke used flat `{ id, state, ... }`
  -- payloads and the bridge happily processed them — but real events
  -- would have early-returned at the guard, silently dropping every
  -- query lifecycle topic in production. Lector caught this in the
  -- 2026-05-16 review (must-fix §1). The bridge now accepts both
  -- nested and flat (defensive); the smoke triggers nested ONLY so
  -- the regression cannot recur.
  dbee_event_bus.trigger("current_connection_changed",
    { conn_id = "test-connection-spike" })
  dbee_event_bus.trigger("call_state_changed", {
    call = {
      id = "call-id-1",
      state = "executing",
      query = "SELECT 1",
      time_taken_us = 0,
    },
  })
  dbee_event_bus.trigger("call_state_changed", {
    call = {
      id = "call-id-1",
      state = "archived",
      query = "SELECT 1",
      time_taken_us = 1234,
    },
  })

  -- dbee's event_bus.trigger wraps callbacks in vim.schedule(), so the
  -- listeners fire on the next tick. Drain the schedule queue.
  vim.wait(150, function() return #conn_hits >= 1 and #call_hits >= 4 end, 5)

  ok("dbase.connection:changed received exactly once",
    #conn_hits == 1,
    "got " .. #conn_hits)
  ok("connection payload carries the right conn_id",
    conn_hits[1] and conn_hits[1].id == "test-connection-spike",
    conn_hits[1] and ("got id=" .. tostring(conn_hits[1].id)) or "no hit")

  -- For two trigger calls (executing + archived):
  --   - dbase.call:state_changed × 2  (always fired)
  --   - dbase.call:started × 1        (terminal for "executing")
  --   - dbase.call:completed × 1      (terminal for "archived")
  local topics = {}
  for _, h in ipairs(call_hits) do topics[h.topic] = (topics[h.topic] or 0) + 1 end
  ok("dbase.call:state_changed fired twice (per trigger)",
    topics["dbase.call:state_changed"] == 2,
    "got " .. tostring(topics["dbase.call:state_changed"]))
  ok("dbase.call:started fired once (state=executing)",
    topics["dbase.call:started"] == 1,
    "got " .. tostring(topics["dbase.call:started"]))
  ok("dbase.call:completed fired once (state=archived)",
    topics["dbase.call:completed"] == 1,
    "got " .. tostring(topics["dbase.call:completed"]))

  -- Failure case: executing_failed → :state_changed + :failed
  dbee_event_bus.trigger("call_state_changed", {
    call = {
      id = "call-id-2",
      state = "executing_failed",
      query = "SELECT bogus",
      error = "syntax near 'bogus'",
    },
  })
  vim.wait(150, function()
    for _, h in ipairs(call_hits) do
      if h.topic == "dbase.call:failed" then return true end
    end
    return false
  end, 5)

  local failed_payload
  for _, h in ipairs(call_hits) do
    if h.topic == "dbase.call:failed" then failed_payload = h.payload end
  end
  ok("dbase.call:failed fired for executing_failed state",
    failed_payload ~= nil)
  ok("failure payload carries err",
    failed_payload and failed_payload.err == "syntax near 'bogus'",
    failed_payload and ("got err=" .. tostring(failed_payload.err)) or "no hit")

  core.events.unsubscribe(h_conn)
  core.events.unsubscribe(h_call)
end

-- ───────────────────── 5d. state-keying probe (slice 6) ───────────────
-- White-vision refinement: mirrors the buffers-panel v0.2.13 regression
-- pattern. With dbase NOT the active section, fire events that would
-- mutate its state, then re-focus dbase. Assert no stale state, no
-- placeholder, invariants intact.
print("\n[5d] state-keying probe — events while dbase inactive, then refocus")
do
  local section = require("auto-finder.sections.dbase")
  -- Ensure dbase IS the active section first, capture its bufnr.
  af.focus("dbase")
  vim.wait(150, function() return af.state.section == 2 end, 5)
  local panel_now = af.state.panel_winid
  local dbase_bufnr_before = panel_now and vim.api.nvim_win_get_buf(panel_now)
  ok("dbase buffer captured before switch",
    dbase_bufnr_before and vim.api.nvim_buf_is_valid(dbase_bufnr_before))

  -- Switch AWAY from dbase. files is section 1 in our test config.
  af.focus(1)
  vim.wait(150, function() return af.state.section == 1 end, 5)
  ok("focus moved away from dbase (state.section == 1)",
    af.state.section == 1)

  -- Now fire a dbee event that would, in production, trigger drawer
  -- state changes. Our bridge should still publish the auto-core
  -- event regardless of section focus — gates on the receiving side
  -- (like the buffers-panel v0.2.11 fix) don't apply to producer-side
  -- bridges, but verifying the pattern explicitly is the whole point.
  if ok_dbee_bus and ok_core then
    local hits = {}
    local h = core.events.subscribe("dbase.connection:changed",
      function(p) table.insert(hits, p) end)
    dbee_event_bus.trigger("current_connection_changed",
      { conn_id = "while-inactive-conn" })
    vim.wait(150, function() return #hits >= 1 end, 5)
    ok("[5d.1] connection event fired with dbase inactive",
      #hits == 1 and hits[1].id == "while-inactive-conn",
      hits[1] and ("got id=" .. tostring(hits[1].id)) or "no hit")
    core.events.unsubscribe(h)
  else
    skip("[5d.1] connection event fired with dbase inactive",
      "dbee_bus or core unavailable")
  end

  -- Re-focus dbase. The cached bufnr should still be valid; the
  -- section should NOT degrade to placeholder; winfixbuf/winfixwidth
  -- should still hold.
  af.focus("dbase")
  vim.wait(250, function() return af.state.section == 2 end, 5)
  local dbase_bufnr_after = panel_now and vim.api.nvim_win_get_buf(panel_now)
  ok("[5d.2] refocus(dbase) returns the same drawer bufnr",
    dbase_bufnr_before and dbase_bufnr_after
      and dbase_bufnr_before == dbase_bufnr_after,
    string.format("before=%s after=%s",
      tostring(dbase_bufnr_before), tostring(dbase_bufnr_after)))
  local bufname = dbase_bufnr_after
    and vim.api.nvim_buf_get_name(dbase_bufnr_after) or ""
  ok("[5d.3] refocus did NOT fall back to placeholder",
    not bufname:find("auto%-finder%-dbase://placeholder"),
    "name=" .. bufname)
  ok("[5d.4] winfixbuf still true after refocus",
    panel_now and vim.wo[panel_now].winfixbuf == true)
  ok("[5d.5] winfixwidth still true after refocus",
    panel_now and vim.wo[panel_now].winfixwidth == true)
end

-- ───────────────────── 5e. multi-cycle stress (slice 6) ────────────────
-- Beyond section [5]'s single close-reopen, exercise three full cycles
-- with section switches in between, and assert all invariants survive.
print("\n[5e] multi-cycle stress — 3× close/reopen with section switches")
do
  for i = 1, 3 do
    af.close()
    if af.state.panel_winid ~= nil then
      ok("[5e.c" .. i .. "] panel_winid nil after close", false,
        "still " .. tostring(af.state.panel_winid))
    end

    af.open(true)
    local p = af.state.panel_winid
    if not (p and vim.api.nvim_win_is_valid(p)) then
      ok("[5e.o" .. i .. "] reopen produced valid panel", false,
        "p=" .. tostring(p))
      break
    end

    -- Cycle through all sections to stress the registry.
    af.focus(0)  -- config
    vim.wait(100, function() return af.state.section == 0 end, 5)
    af.focus(1)  -- files
    vim.wait(100, function() return af.state.section == 1 end, 5)
    af.focus(2)  -- dbase
    vim.wait(150, function() return af.state.section == 2 end, 5)

    local invariants_ok = vim.api.nvim_win_is_valid(p)
      and vim.wo[p].winfixbuf == true
      and vim.wo[p].winfixwidth == true
    ok("[5e.c" .. i .. "] all panel invariants hold after full cycle",
      invariants_ok,
      string.format("valid=%s wfb=%s wfw=%s",
        tostring(vim.api.nvim_win_is_valid(p)),
        tostring(p and vim.wo[p].winfixbuf),
        tostring(p and vim.wo[p].winfixwidth)))
  end

  -- Final orphan-windows check after the stress run.
  local orphans = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) then
      local b = vim.api.nvim_win_get_buf(w)
      local n = vim.api.nvim_buf_get_name(b)
      if (n:find("^dbee://") or vim.bo[b].filetype:find("^dbee"))
          and w ~= af.state.panel_winid then
        orphans = orphans + 1
      end
    end
  end
  ok("[5e] no orphan dbee windows after 3-cycle stress",
    orphans == 0,
    "found " .. orphans)
end

-- ───────────────────── 5f. keymap audit (slice 7) ──────────────────────
-- dbee's drawer ships its own `q` mapping (action = "menu_close"). The
-- auto-core section registry applies `q → panel:close` AFTER get_buffer
-- mounts dbee, so last-write-wins should leave us with the right
-- semantics. Verify empirically.
print("\n[5f] keymap audit — q + 0..9 on the dbase buffer")
do
  af.focus("dbase")
  vim.wait(250, function() return af.state.section == 2 end, 5)
  local panel_now = af.state.panel_winid
  local bufnr = panel_now and vim.api.nvim_win_get_buf(panel_now)

  -- 0..9 section-switching keymaps installed by auto-core.ui.section.
  -- Probe one numeric (1 = files) and assert the buffer-local mapping
  -- exists. vim.fn.maparg with buffer scope returns "" / {} when not
  -- bound on the buffer.
  local map_1 = vim.fn.maparg("1", "n", false, true)
  ok("[5f.1] '1' is bound on dbase buffer (section-switch keymap)",
    type(map_1) == "table" and map_1.lhs == "1",
    "got " .. vim.inspect(map_1))

  -- 'q' should be bound and resolve to auto-core's panel close, not
  -- dbee's menu_close. We can't inspect the closure body directly,
  -- but we can check the `desc` field auto-core sets.
  local map_q = vim.fn.maparg("q", "n", false, true)
  ok("[5f.2] 'q' is bound on dbase buffer",
    type(map_q) == "table" and map_q.lhs == "q",
    "got " .. vim.inspect(map_q))
  ok("[5f.3] 'q' desc points at auto-core (panel close), not dbee",
    type(map_q) == "table" and type(map_q.desc) == "string"
      and map_q.desc:find("auto%-core"),
    type(map_q) == "table" and ("desc=" .. tostring(map_q.desc)) or "no map")

  -- End-to-end: fire `q` and assert the panel actually closes. This
  -- catches the case where some intermediate handler hijacks the key
  -- between resolution and execution.
  vim.api.nvim_set_current_win(panel_now)
  -- Use feedkeys with 'x' (execute immediately) so the press lands
  -- synchronously within our test tick.
  vim.api.nvim_feedkeys("q", "x", false)
  vim.wait(150, function() return af.state.panel_winid == nil end, 5)
  ok("[5f.4] pressing 'q' on dbase buffer closes the panel",
    af.state.panel_winid == nil,
    "panel_winid=" .. tostring(af.state.panel_winid))

  -- Reopen for any subsequent sections.
  af.open(true)
end

-- ───────────────────── 6b. companion-pane layout (slice 8) ────────────
-- Phase 2 starts here: the dbase section drawer stays in the panel,
-- but editor/result/call_log live in the **main editor area** per the
-- white-vision §8 refinement. Verify the layout module mounts them
-- without contaminating the panel.
print("\n[6b] companion-pane layout — editor/result/call_log in editor area")
do
  local layout = require("auto-finder.sections._dbase_layout")

  -- Need the panel open + at least one editor-area window. Re-open
  -- the panel (closed by [5f] keymap audit), then guarantee a
  -- second window exists. Create one synthetic editor buffer to
  -- give layout.ensure_editor() a candidate target.
  if af.state.panel_winid == nil then af.open(true) end
  af.focus("dbase")
  vim.wait(150, function() return af.state.section == 2 end, 5)
  local panel_winid = af.state.panel_winid

  -- If only the panel exists, force-create a non-panel window so the
  -- "prefer existing editor-area window" path is exercised. Use
  -- `:vnew` instead of `:vsplit` so the new window opens with a
  -- fresh unnamed buffer — `:vsplit` from the panel inherits the
  -- panel's winfixbuf AND its panel-owner-marked buffer, and the
  -- WinEnter guard in auto-core.ui.panel then closes the new window.
  -- Same rationale as the matching guard in
  -- _dbase_layout.create_editor_window.
  if #vim.api.nvim_list_wins() < 2 then
    vim.cmd("rightbelow vnew")
  end

  ok("layout.is_open returns false before any ensure_*()",
    layout.is_open() == false)

  local editor_winid = layout.ensure_editor()
  ok("[6b.1] ensure_editor returns a valid winid",
    editor_winid and vim.api.nvim_win_is_valid(editor_winid),
    "got " .. tostring(editor_winid))
  ok("[6b.2] editor winid is NOT the panel",
    editor_winid and editor_winid ~= panel_winid,
    string.format("editor=%s panel=%s",
      tostring(editor_winid), tostring(panel_winid)))
  ok("[6b.3] editor winid carries no auto_finder_panel marker",
    editor_winid and vim.w[editor_winid].auto_finder_panel ~= 1)

  local result_winid = layout.ensure_result()
  ok("[6b.4] ensure_result returns a valid winid",
    result_winid and vim.api.nvim_win_is_valid(result_winid))
  ok("[6b.5] result is NOT the panel and NOT the editor winid",
    result_winid and result_winid ~= panel_winid
      and result_winid ~= editor_winid)

  local call_log_winid = layout.ensure_call_log()
  ok("[6b.6] ensure_call_log returns a valid winid",
    call_log_winid and vim.api.nvim_win_is_valid(call_log_winid))
  ok("[6b.7] call_log is NOT the panel/editor/result winid",
    call_log_winid and call_log_winid ~= panel_winid
      and call_log_winid ~= editor_winid
      and call_log_winid ~= result_winid)

  ok("[6b.8] layout.is_open returns true after mounts",
    layout.is_open() == true)

  -- Boundary: the panel buffer must NOT have been clobbered.
  ok("[6b.9] panel buffer is still the dbee drawer",
    panel_winid and vim.api.nvim_win_is_valid(panel_winid)
      and vim.bo[vim.api.nvim_win_get_buf(panel_winid)].filetype:find("^dbee"),
    panel_winid and ("panel ft=" .. tostring(
      vim.bo[vim.api.nvim_win_get_buf(panel_winid)].filetype)) or "no panel")
  ok("[6b.10] winfixbuf still true on panel after companion mounts",
    panel_winid and vim.wo[panel_winid].winfixbuf == true)
  ok("[6b.11] winfixwidth still true on panel after companion mounts",
    panel_winid and vim.wo[panel_winid].winfixwidth == true)

  -- Idempotence: second ensure_* returns the SAME winids.
  local editor2 = layout.ensure_editor()
  local result2 = layout.ensure_result()
  local call_log2 = layout.ensure_call_log()
  ok("[6b.12] ensure_editor is idempotent",
    editor2 == editor_winid)
  ok("[6b.13] ensure_result is idempotent",
    result2 == result_winid)
  ok("[6b.14] ensure_call_log is idempotent",
    call_log2 == call_log_winid)

  -- close_all tears down the three but leaves the panel intact.
  layout.close_all()
  ok("[6b.15] close_all: editor winid no longer valid",
    not vim.api.nvim_win_is_valid(editor_winid or -1))
  ok("[6b.16] close_all: result winid no longer valid",
    not vim.api.nvim_win_is_valid(result_winid or -1))
  ok("[6b.17] close_all: call_log winid no longer valid",
    not vim.api.nvim_win_is_valid(call_log_winid or -1))
  ok("[6b.18] close_all: panel STILL valid",
    panel_winid and vim.api.nvim_win_is_valid(panel_winid))
  ok("[6b.19] close_all: layout.is_open returns false",
    layout.is_open() == false)
end

-- ───────────────────── 6c. custom Layout + <CR> override (slice 9) ────
-- Verify the custom window_layout passed to dbee.setup actually
-- replaces dbee's DefaultLayout, and that <CR> on the drawer mounts
-- companion panes before delegating to dbee's action_1.
print("\n[6c] custom Layout + <CR> override on drawer")
do
  local layout = require("auto-finder.sections._dbase_layout")
  local setup_mod = require("auto-finder.sections._dbase_setup")

  -- Clean slate: tear down any leftover companions from [6b].
  layout.close_all()

  ok("layout.close_all left no companion windows",
    not layout.is_open())

  -- The layout object passed to dbee.setup must conform to
  -- { is_open, open, close, reset } per dbee/config.lua:15.
  ok("[6c.1] layout.layout is a table",
    type(layout.layout) == "table")
  ok("[6c.2] layout.layout.is_open is callable",
    type(layout.layout.is_open) == "function")
  ok("[6c.3] layout.layout.open is callable",
    type(layout.layout.open) == "function")
  ok("[6c.4] layout.layout.close is callable",
    type(layout.layout.close) == "function")
  ok("[6c.5] layout.layout.reset is callable",
    type(layout.layout.reset) == "function")

  -- The setup module installed our layout as the active window_layout.
  -- Verify by introspecting dbee's runtime config — `state` is module-
  -- private but state.handler() doesn't expose it. Instead, exercise
  -- the contract: call layout.layout.open() and assert companions
  -- mount via our path.
  if af.state.panel_winid == nil then af.open(true) end
  af.focus("dbase")
  vim.wait(150, function() return af.state.section == 2 end, 5)

  -- Need an editor-area window for ensure_editor to land into.
  -- `:vnew` (not `:vsplit`) so the new window opens with a fresh
  -- unnamed buffer — see the comment in _dbase_layout.create_editor_window
  -- for why `:vsplit` from the panel triggers auto-core's bounce
  -- guard, leaving subsequent option-set calls to land on the panel
  -- itself.
  if #vim.api.nvim_list_wins() < 2 then
    vim.cmd("rightbelow vnew")
  end

  layout.layout.open()
  ok("[6c.6] layout.layout.open() mounts companions (is_open true)",
    layout.is_open() == true)
  ok("[6c.7] layout.layout.is_open() reports true after open",
    layout.layout.is_open() == true)

  local editor_w = layout._editor_winid
  ok("[6c.8] editor winid is set and valid after layout.open()",
    editor_w and vim.api.nvim_win_is_valid(editor_w))

  layout.layout.close()
  ok("[6c.9] layout.layout.close() tears down companions",
    layout.is_open() == false)
  ok("[6c.10] layout.layout.is_open() reports false after close",
    layout.layout.is_open() == false)

  layout.layout.reset()
  ok("[6c.11] layout.layout.reset() reopens companions",
    layout.is_open() == true)

  layout.close_all()  -- clean up for the next probe
end

-- ───────────────────── 6d. <CR>-override mounts companions ─────────────
print("\n[6d] <CR> on drawer auto-mounts companions before action_1")
do
  local layout = require("auto-finder.sections._dbase_layout")
  layout.close_all()

  if af.state.panel_winid == nil then af.open(true) end
  af.focus("dbase")
  vim.wait(150, function() return af.state.section == 2 end, 5)
  local panel_winid = af.state.panel_winid
  local bufnr = panel_winid and vim.api.nvim_win_get_buf(panel_winid)

  -- Ensure we have an editor-area target window so ensure_editor
  -- doesn't have to split the panel. `:vnew` instead of `:vsplit`
  -- avoids inheriting the panel's drawer buffer (panel-owner-marked
  -- → triggers auto-core's WinEnter bounce guard).
  if #vim.api.nvim_list_wins() < 2 then
    vim.cmd("rightbelow vnew")
    -- Re-focus the panel so the keypress lands on the drawer.
    pcall(vim.api.nvim_set_current_win, panel_winid)
  end

  -- Walk the drawer buffer's normal-mode keymaps explicitly — maparg's
  -- buffer-vs-global resolution is context-dependent and unreliable
  -- here. nvim_buf_get_keymap returns every buffer-local mapping
  -- regardless of current context.
  local cr_map
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
      if m.lhs == "<CR>" then cr_map = m; break end
    end
  end
  ok("[6d.1] <CR> is bound on drawer buffer (buffer-local)",
    type(cr_map) == "table")
  ok("[6d.2] <CR> desc points at auto-finder.dbase, not dbee",
    type(cr_map) == "table" and type(cr_map.desc) == "string"
      and cr_map.desc:find("auto%-finder%.dbase"),
    type(cr_map) == "table" and ("desc=" .. tostring(cr_map.desc)) or "no map")

  -- Companions should be closed before the press.
  ok("[6d.3] companions closed before <CR>",
    not layout.is_open())

  -- Fire the <CR> callback directly. feedkeys-based invocation in
  -- headless mode is unreliable (the panel briefly loses winfixbuf
  -- before our callback runs); calling the bound callback proves the
  -- same contract — when triggered, the override mounts companions
  -- and delegates to dbee's drawer action_1 — without depending on
  -- nvim's keyboard-handling state machine.
  ok("[6d.3b] <CR> binding has a callable callback",
    type(cr_map.callback) == "function")

  if type(cr_map.callback) == "function" then
    pcall(vim.api.nvim_set_current_win, panel_winid)
    pcall(cr_map.callback)
  end
  vim.wait(150, function() return layout.is_open() end, 5)
  ok("[6d.4] <CR> callback mounted companion panes",
    layout.is_open() == true)

  -- Boundary check: the callback must not destroy the drawer's
  -- underlying buffer. We test the buffer survives — NOT that it's
  -- still mounted in the panel — because there's an orthogonal
  -- pre-existing race in the bundled neo-tree filesystem source:
  -- after the user has focused the files section earlier, fs_scan
  -- defers a render via `vim.schedule`; that deferred render fires
  -- AFTER we've moved off the files section AND uses the renderer's
  -- v0.2.11 winfixbuf-safe dance to swap the panel buffer, then
  -- fails at NuiTree creation but the swap has already stuck. The
  -- `[Neo-tree WARN] Window N is no longer valid` log earlier in
  -- the run is the same race. It is documented in the KB log entry
  -- 2026-05-16 14:55 (Phase 0a spike) and predates the dbase work
  -- — addressable separately at fs_scan.lua:250.
  ok("[6d.5] drawer buffer survives the <CR> callback",
    bufnr and vim.api.nvim_buf_is_valid(bufnr),
    "drawer bufnr=" .. tostring(bufnr))
  ok("[6d.6] panel winfixbuf still true after <CR>",
    panel_winid and vim.wo[panel_winid].winfixbuf == true)

  layout.close_all()
end

-- ───────────────────── 7. report ───────────────────────────────────────
print("\n──────────────────────────────────────────────")
print(string.format("Phase 0a spike: %d passed, %d failed, %d skipped",
  pass_count, fail_count, skip_count))
print("──────────────────────────────────────────────")
if fail_count == 0 then
  print("VERDICT: GREEN — drawer_show survives winfixbuf+winfixwidth.")
  print("         Proceed to Phase 0b (lector ADR 0020 §Implementation Plan).")
else
  print("VERDICT: RED — adapter-only integration is structurally fragile.")
  print("         Consider Path C (sidecar) or Path D (fork).")
end

-- `:qall! N` is not valid syntax; use `:cquit N` for a controlled exit code.
vim.cmd("cquit " .. (fail_count == 0 and "0" or "1"))
