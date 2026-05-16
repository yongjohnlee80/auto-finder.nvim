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
for _, p in ipairs({
  plugin_root,
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

-- ───────────────────── 6. report ───────────────────────────────────────
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
