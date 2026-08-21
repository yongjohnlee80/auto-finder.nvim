-- tests/adr0059-e2e.lua -- ADR-0059 end-to-end regression harness.
--
-- The `[50]` pins in tests/smoke.lua stub the tree, so they cover the
-- CLASSIFICATION only. This suite is the one that exercises the real
-- pipeline: a genuine file write -> auto-core fs.watch -> the
-- auto-finder translator -> a really-mounted panel, counting actual
-- root scans at the fs_scan chokepoint (where the storm detector sits).
--
-- Run:
--   nvim --headless -u NONE -l tests/adr0059-e2e.lua
-- A/B against main:
--   AF=../main AC=../../auto-core.nvim/main nvim --headless -u NONE -l tests/adr0059-e2e.lua
--
-- Exits 0 when every expectation holds, non-zero otherwise.
-- through the real translator into a real mounted panel and counts
-- actual ROOT SCANS at the fs_scan chokepoint (the same place the
-- storm detector sits).
--
-- Run with AF=<auto-finder worktree> AC=<auto-core worktree> so the
-- same script can measure patched vs unpatched.
-- Resolves its own plugin root (two levels up from tests/), so it runs
-- unmodified from any worktree. `AF` / `AC` env overrides exist so the
-- same script can measure a patched worktree against `main` -- that A/B
-- is how the fix was verified, and how a regression would be caught.
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
local sandbox = vim.fn.tempname() .. "-adr0059"
vim.env.XDG_CONFIG_HOME = sandbox .. "/cfg"
vim.env.XDG_STATE_HOME  = sandbox .. "/state"
vim.env.AUTO_FINDER_DBASE_DISABLE_CRYPTO = "1"

-- ── the tree under test ──────────────────────────────────────────
local root = sandbox .. "/root"
vim.fn.mkdir(root .. "/collapsed/deep", "p")
vim.fn.mkdir(root .. "/.auto-agents/mailbox/inst/agent/outbox", "p")
vim.fn.writefile({ "one" }, root .. "/existing.txt")
vim.fn.writefile({ "x" }, root .. "/collapsed/pre.txt")
vim.cmd("cd " .. vim.fn.fnameescape(root))

local af = require("auto-finder")
assert(pcall(af.setup, {
  width = { default = 38, min = 25, max = 100 },
  default_section = 1,
  sections = { "config", "files" },
  neo_tree = {
    filesystem = {
      hijack_netrw_behavior = "disabled",
      filtered_items = {
        visible = true, hide_dotfiles = false, hide_gitignored = false,
        never_show = { ".git", "node_modules" },   -- shipped autovim config
        ignore_files = {},
      },
    },
  },
}))
af.open(true)
af.focus(1)
local files_section = require("auto-finder.sections").resolve(1)
vim.wait(1500, function()
  return files_section and files_section._bufnr ~= nil
    and vim.api.nvim_buf_is_valid(files_section._bufnr)
end)
vim.wait(600) -- let the initial mount scan + watcher start settle

-- ── count real root scans at the chokepoint ──────────────────────
local fs_scan = require("auto-finder.neotree.sources.filesystem.lib.fs_scan")
local orig_get_items = fs_scan.get_items
local root_scans = 0
fs_scan.get_items = function(state, parent_id, ...)
  if parent_id == nil then root_scans = root_scans + 1 end
  return orig_get_items(state, parent_id, ...)
end

-- Settle window must exceed SETTLE_QUIET_MS (1500) + throttle (800)
-- so a held scan is counted rather than missed.
local function measure(label, body, expect_zero)
  root_scans = 0
  body()
  vim.wait(3200)
  local got = root_scans
  local pass
  if expect_zero then pass = (got == 0) else pass = (got >= 1) end
  print(string.format("  %s  %-58s root_scans=%d",
    pass and "PASS" or "FAIL", label, got))
  return pass, got
end

local all_pass = true
local function track(p) all_pass = all_pass and p end

print("\nADR-0059 end-to-end — real fs.watch → translator → panel")
print("AF=" .. vim.fn.fnamemodify(AF, ":t") .. "  AC=" .. vim.fn.fnamemodify(AC, ":t"))

-- (a) §3.1 content-only write to an already-rendered file.
track((measure("a) write to an EXISTING visible file", function()
  vim.fn.writefile({ "one", "two" }, root .. "/existing.txt")
end, true)))

-- (b) §3.2 new file inside a COLLAPSED directory.
track((measure("b) new file inside a COLLAPSED dir", function()
  vim.fn.writefile({ "x" }, root .. "/collapsed/new.txt")
end, true)))

-- (c) §3.2/§3.3 the actual storm repro: bulk churn, collapsed target.
track((measure("c) BULK 200 files into a COLLAPSED dir (storm repro)", function()
  for i = 1, 200 do
    vim.fn.writefile({ "x" }, root .. "/collapsed/deep/f" .. i .. ".txt")
  end
end, true)))

-- (d) Agent mailbox traffic costs no root scan. NOTE this does not
-- isolate the auto-core ignore: `.auto-agents/` is collapsed, so the
-- auto-finder visibility gate alone already suppresses it (verified --
-- this passes with auto-core `main` on the rtp). The event-level
-- assertion that fs.watch never PUBLISHES for the mailbox path lives
-- in auto-core's own smoke, in the self-extension section.
track((measure("d) agent mailbox write (no root scan)", function()
  for i = 1, 20 do
    vim.fn.writefile({ "{}" },
      root .. "/.auto-agents/mailbox/inst/agent/outbox/m" .. i .. ".json")
  end
end, true)))

-- (e) CONTROL: a new file in the VISIBLE root must still rescan.
track((measure("e) CONTROL new file in the VISIBLE root", function()
  vim.fn.writefile({ "x" }, root .. "/appeared.txt")
end, false)))

fs_scan.get_items = orig_get_items
print(all_pass and "\nRESULT: all expectations met" or "\nRESULT: expectations NOT met")
vim.fn.delete(sandbox, "rf")
vim.cmd(all_pass and "qa!" or "cq")
