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
  dbee_event_bus.trigger("current_connection_changed",
    { conn_id = "test-connection-spike" })
  dbee_event_bus.trigger("call_state_changed", {
    id = "call-id-1",
    state = "executing",
    query = "SELECT 1",
    time_taken_us = 0,
  })
  dbee_event_bus.trigger("call_state_changed", {
    id = "call-id-1",
    state = "archived",
    query = "SELECT 1",
    time_taken_us = 1234,
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
    id = "call-id-2",
    state = "executing_failed",
    query = "SELECT bogus",
    error = "syntax near 'bogus'",
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
