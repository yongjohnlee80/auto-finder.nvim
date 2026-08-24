-- ADR-0044 standalone smoke — section [45] (worktree:switched must
-- not displace a non-panel editor window; filesystem state re-anchors
-- to the new cwd). Run with:
--   nvim --headless -u NONE -l tests/smoke-adr0044.lua
--
-- Exits 0 on PASS, 1 on FAIL. Each test prints its own line.
--
-- WHY THIS FILE EXISTS: [45] asserts against a MATERIALISED panel
-- window (af.state.panel_winid must be a real window carrying the
-- tree buffer). Inside tests/smoke.lua that assertion runs after ~45
-- sections of accumulated window churn, and the panel does not
-- materialise headlessly in that state — winid=nil, ft=<invalid> —
-- so [45] logged 5 permanent env failures there. In a FRESH nvim
-- process (this file) the panel materialises under plain
-- `nvim --headless` (no pty needed), and all 7 assertions pass. The
-- fix for the panel-materialisation class is process isolation, not a
-- real UI: see tests/auto-finder-coverage.md. Same prelude-duplication
-- rationale as tests/smoke-adr0048.lua.
--
-- Keep the section body in sync with tests/smoke.lua's marker — this
-- file is now the canonical home for [45]. Wired into tests/run-all.sh
-- as the "smoke_adr0044" suite.

-- Derive plugin_root from this script's own path so the driver runs
-- unmodified on any machine. `tests/smoke-adr0044.lua` is two levels
-- below the plugin root.
local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")

local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
local plugins_root = vim.fn.fnamemodify(plugin_root, ":h:h")
for _, p in ipairs({
  plugin_root,
  LAZY .. "/auto-core.nvim",
  LAZY .. "/nui.nvim",
  LAZY .. "/plenary.nvim",
  plugins_root .. "/auto-core.nvim/main",
}) do
  if vim.fn.isdirectory(p) == 1 then
    vim.opt.runtimepath:prepend(p)
  end
end
-- Auto-finder ships its own forked neo-tree at lua/auto-finder/neotree.

vim.o.columns = 200
vim.o.lines = 60
vim.o.swapfile = false
vim.o.hidden = true

-- Isolate from the user's real nvim state and from the other smoke
-- suites' isolation dirs.
dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
  .. "/_sandbox.lua")("adr0044")

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

require("auto-finder.neotree").setup({
  window = { auto_expand_width = true },
  filesystem = { hijack_netrw_behavior = "disabled" },
})

-- ═══════════════════════════════════════════════════════════════════
-- Section [45] below is VERBATIM from tests/smoke.lua (which now
-- points here). Keep in sync.
-- ═══════════════════════════════════════════════════════════════════

print("\n[45] ADR-0044 — worktree:switched does not displace a non-panel editor window")
;(function()
  local _af   = require("auto-finder")
  local _core = require("auto-core")
  local _mgr  = require("auto-finder.neotree.sources.manager")

  -- Fresh setup → clean panel carrying the default sections. setup()
  -- configures; open(true) actually mounts + focuses the panel window.
  _af.setup({ sections = { "config", "files", "repos" } })
  _af.open(true)
  local panel = _af.state.panel_winid
  ok("p45: panel open + carries w:auto_finder_panel",
    panel ~= nil and vim.api.nvim_win_is_valid(panel)
      and vim.w[panel].auto_finder_panel == 1)

  -- Focus files (filesystem). on_focus arms the worktree:switched →
  -- reanchor_to_cwd subscription (files is built live_refresh=true) and
  -- mounts synchronously, so section._bufnr is valid → the reanchor guard
  -- passes.
  local _files_idx = require("auto-finder.sections")._by_name["files"]
  _af.focus(_files_idx)

  -- The panel-bound filesystem state (winid == panel) is what reanchor
  -- retargets; reanchor only touches filesystem states that carry a winid.
  local function _fs_state()
    for _, s in ipairs(_mgr._get_all_states()) do
      if s.name == "filesystem" and s.winid == panel then return s end
    end
    return nil
  end
  local _old_cwd = vim.fn.getcwd()
  vim.wait(500, function()
    local s = _fs_state(); return s ~= nil and s.path == _old_cwd
  end, 20)
  local _fs = _fs_state()
  ok("p45: filesystem state bound to panel, anchored at cwd (pre-switch)",
    _fs ~= nil and _fs.winid == panel and _fs.path == _old_cwd,
    string.format("fs=%s winid=%s path=%s cwd=%s",
      tostring(_fs ~= nil), tostring(_fs and _fs.winid),
      tostring(_fs and _fs.path), _old_cwd))

  -- Load a real file into a FOCUSED non-panel editor window — the exact
  -- scenario the old position="current" re-anchor displaced (it would mount
  -- the tree into the focused editor window). After af.open the panel (a left
  -- vsplit) coexists with a normal editor window; reuse it (or make one) and
  -- leave focus there before the switch fires. Probe lives under cwd/tests so
  -- it's a real path the filesystem source can resolve.
  local _probe = _old_cwd .. "/tests/_adr0044_reanchor_probe.txt"
  do local fh = io.open(_probe, "w"); if fh then fh:write("adr-0044 probe"); fh:close() end end
  local function _nonpanel_win()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if w ~= panel and vim.w[w].auto_finder_panel ~= 1 then return w end
    end
    return nil
  end
  local _editor_win = _nonpanel_win()
  if not _editor_win then
    vim.cmd("botright vsplit")
    _editor_win = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_set_current_win(_editor_win)
  vim.cmd("edit " .. vim.fn.fnameescape(_probe))
  local _editor_buf = vim.api.nvim_win_get_buf(_editor_win)
  ok("p45: probe loaded into a focused non-panel editor window",
    _editor_win ~= panel
      and vim.w[_editor_win].auto_finder_panel ~= 1
      and vim.api.nvim_buf_get_name(_editor_buf) == _probe,
    string.format("editor_win=%s panel=%s name=%s",
      tostring(_editor_win), tostring(panel),
      vim.api.nvim_buf_get_name(_editor_buf)))

  -- Simulate the worktree switch faithfully: worktree.switch_to :cd's to the
  -- new root, THEN fires `worktree:switched`. reanchor_to_cwd reads
  -- vim.fn.getcwd(), so we cd first. Use a fresh real tempdir as the new
  -- root (re-read getcwd() for the canonical form — handles macOS /private).
  local _new_cwd = vim.fn.tempname()
  vim.fn.mkdir(_new_cwd, "p")
  vim.cmd("cd " .. vim.fn.fnameescape(_new_cwd))
  _new_cwd = vim.fn.getcwd()
  _core.events.publish("worktree:switched", { from = _old_cwd, to = _new_cwd })

  -- reanchor is vim.schedule'd off the subscription; wait until the fs
  -- state.path re-anchors to the new cwd (the observable EFFECT).
  vim.wait(500, function()
    local s = _fs_state(); return s ~= nil and s.path == _new_cwd
  end, 20)
  local _fs_after = _fs_state()

  -- A — EFFECT: reanchor actually ran (state.path moved to the new cwd).
  -- Proves the worktree:switched handler fired; guards against a vacuous
  -- "nothing happened, so nothing was displaced" pass.
  ok("p45: filesystem state re-anchored to new cwd after worktree:switched",
    _fs_after ~= nil and _fs_after.path == _new_cwd,
    string.format("path=%s new_cwd=%s",
      tostring(_fs_after and _fs_after.path), _new_cwd))

  -- B — SAFETY (the regression this pins): the non-panel editor split STILL
  -- holds the probe buffer; the tree did NOT mount into it.
  ok("p45: editor split NOT displaced (still holds the probe buffer)",
    vim.api.nvim_win_is_valid(_editor_win)
      and vim.api.nvim_win_get_buf(_editor_win) == _editor_buf,
    string.format("valid=%s buf=%s expected=%s",
      tostring(vim.api.nvim_win_is_valid(_editor_win)),
      tostring(vim.api.nvim_win_is_valid(_editor_win)
        and vim.api.nvim_win_get_buf(_editor_win)), tostring(_editor_buf)))

  -- C — RENDER TARGET: the panel remained the tree's home (an auto-finder
  -- buffer) — the refresh stayed in the panel.
  local _panel_buf = (panel and vim.api.nvim_win_is_valid(panel)
    and vim.api.nvim_win_get_buf(panel)) or -1
  ok("p45: panel still holds an auto-finder tree buffer",
    _panel_buf ~= -1 and vim.bo[_panel_buf].filetype:match("^auto.finder") ~= nil,
    "panel ft=" .. (_panel_buf ~= -1 and vim.bo[_panel_buf].filetype or "<invalid>"))

  -- Cleanup: restore cwd, close the editor split, delete probe buffer + file,
  -- remove the temp dir.
  pcall(vim.cmd, "cd " .. vim.fn.fnameescape(_old_cwd))
  if vim.api.nvim_win_is_valid(_editor_win) then
    pcall(vim.api.nvim_win_close, _editor_win, true)
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == _probe then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  pcall(os.remove, _probe)
  pcall(vim.fn.delete, _new_cwd, "rf")
end)()

-- ───────────────────────── summary ────────────────────────
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
