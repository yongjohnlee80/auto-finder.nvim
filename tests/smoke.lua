-- Headless smoke tests for auto-finder.nvim. Run with:
--   nvim --headless -u NONE -l /tmp/auto-finder-smoke.lua
--
-- Exits 0 on PASS, 1 on FAIL. Each test prints its own line.

local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
for _, p in ipairs({
  "/home/johno/Source/Projects/nvim-plugins/auto-finder.nvim",
  LAZY .. "/nui.nvim",
  LAZY .. "/plenary.nvim",
}) do
  vim.opt.runtimepath:prepend(p)
end
-- Auto-finder ships its own forked neo-tree at lua/auto-finder/neotree.
-- Upstream `neo-tree.nvim` is intentionally NOT on the runtimepath
-- here so the test exercises the actual fork rather than the
-- bundled-in-lazy upstream copy.

vim.o.columns = 200
vim.o.lines = 60
vim.o.swapfile = false
vim.o.hidden = true

-- Isolate from the user's real nvim state. Without this, test [2]
-- loads `~/.config/nvim/.auto-finder/config.json` (the user's actual
-- pinned width from real sessions) and the "panel width = default
-- (38)" assertion fails as soon as the user has ever pinned a width.
vim.fn.delete("/tmp/auto-finder-smoke-config-default", "rf")
vim.env.XDG_CONFIG_HOME = "/tmp/auto-finder-smoke-config-default"

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

local function eq(a, b) return a == b, string.format("expected %s, got %s", tostring(b), tostring(a)) end

-- The forked neo-tree (auto-finder.neotree) needs a setup call
-- before we drive its command surface. `window.auto_expand_width =
-- true` mirrors AutoVim's consumer configuration so test [7d] can
-- verify that auto-finder snapshots that value at setup and restores
-- it on `panel reset` after a pin toggle.
--
-- The shim at `lua/neo-tree.lua` re-exports auto-finder.neotree, so
-- `require("neo-tree")` and `require("auto-finder.neotree")` resolve
-- to the same module. We use the fork's namespace explicitly here
-- so the test reads as "set up the fork", not "set up upstream".
require("auto-finder.neotree").setup({
  window = { auto_expand_width = true },
  filesystem = { hijack_netrw_behavior = "disabled" },
})

-- ───────────────────────── 1. setup() ─────────────────────────
print("\n[1] setup()")
local af = require("auto-finder")
local setup_ok, err = pcall(af.setup, {
  -- `side = "left"` is intentionally passed here as a back-compat
  -- check: the option was removed, but old configs may still set it
  -- and validate() must silently accept and ignore it.
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

-- (Directory-hijack test removed — the BufEnter-based hijack was
-- pulled in v0.1.1+1 because it caused multi-panel regressions
-- under `<leader>e` repeats. Re-add when a VimEnter-based one-shot
-- hijack lands.)

-- ───────────────────────── 2. open + width ─────────────────────────
print("\n[2] open + resolve_width")
local cfg_mod = require("auto-finder.config")
local resolved = cfg_mod.resolve_width(af.state.config, 200)
ok("resolve_width(cols=200) returns the configured default",
  select(1, eq(resolved, 38)))
ok("resolve_width(cols=600) returns same default (no percentage)",
  select(1, eq(cfg_mod.resolve_width(af.state.config, 600), 38)))

af.open(true)
local panel = af.state.panel_winid
ok("panel_winid set", panel ~= nil and vim.api.nvim_win_is_valid(panel))
local live_w = panel and vim.api.nvim_win_get_width(panel) or -1
-- `af.open(true)` opens AND focuses the default section (files). Mounting
-- the filesystem source can fire auto_expand_width which grows the panel
-- past the resting default. So we assert ≥ default rather than equality
-- here. Pin enforcement is verified end-to-end in test [7] / [7b].
ok("panel width >= default (38)", live_w >= 38, "live=" .. live_w)
ok("winfixwidth set", panel and vim.wo[panel].winfixwidth == true)

-- ───────────────────────── 3. focus(1) mounts neo-tree ─────────────
print("\n[3] focus(1) — files section")
local focus_ok, focus_err = af.focus(1)
ok("focus(1) returns ok", focus_ok, focus_err)
ok("state.section == 1", af.state.section == 1)
-- neo-tree's command path has internal scheduling; give the BufWinEnter
-- chain a tick to settle before sampling filetype.
vim.wait(200,
  function() return vim.bo[vim.api.nvim_win_get_buf(panel)].filetype == "neo-tree" end,
  5)
local panel_buf = vim.api.nvim_win_get_buf(panel)
local ft = vim.bo[panel_buf].filetype
ok("panel buffer is filetype=neo-tree", ft == "neo-tree", "ft=" .. ft)

-- ───────────────────────── 4. winfixbuf blocks :edit ───────────────
print("\n[4] winfixbuf blocks external :edit from inside panel")
vim.api.nvim_set_current_win(panel)
ok("winfixbuf set on panel", vim.wo[panel].winfixbuf == true)

local tmp = "/tmp/auto-finder-smoke-target.txt"
vim.fn.writefile({ "hello" }, tmp)
local edit_ok, edit_err = pcall(vim.cmd, "edit " .. tmp)
ok(":edit errored with E1513 (winfixbuf)",
  not edit_ok and tostring(edit_err):find("winfixbuf"),
  "ok=" .. tostring(edit_ok) .. " err=" .. tostring(edit_err))
panel_buf = vim.api.nvim_win_get_buf(panel)
ok("panel still neo-tree after blocked :edit",
  vim.bo[panel_buf].filetype == "neo-tree",
  "ft=" .. vim.bo[panel_buf].filetype)

-- ───────────────────────── 5. winfixbuf blocks :buffer ─────────────
print("\n[5] winfixbuf blocks :buffer N (bufferline-click sim)")
vim.api.nvim_set_current_win(panel)
local another = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(another, "/tmp/auto-finder-smoke-other.txt")
local buf_ok, buf_err = pcall(vim.cmd, "buffer " .. another)
ok(":buffer errored with E1513 (winfixbuf)",
  not buf_ok and tostring(buf_err):find("winfixbuf"))
panel_buf = vim.api.nvim_win_get_buf(panel)
ok("panel still neo-tree after blocked :buffer",
  vim.bo[panel_buf].filetype == "neo-tree")

-- ───────────────────────── 6. section switch ───────────────────────
print("\n[6] section switching 1 → 0 → 1")
af.focus(0)
ok("state.section == 0", af.state.section == 0)
panel_buf = vim.api.nvim_win_get_buf(panel)
ok("panel ft = auto-finder-config", vim.bo[panel_buf].filetype == "auto-finder-config",
  "ft=" .. vim.bo[panel_buf].filetype)
af.focus(1)
ok("state.section == 1 again", af.state.section == 1)
panel_buf = vim.api.nvim_win_get_buf(panel)
ok("panel back on neo-tree", vim.bo[panel_buf].filetype == "neo-tree")
ok("section_buffers cached for 0 and 1",
  af.state.section_buffers[0] and af.state.section_buffers[1])

-- ───────────────────────── 7. resize / reset ───────────────────────
print("\n[7] resize / reset")
af.resize(60)
ok("user_width = 60", af.state.user_width == 60)
ok("live width = 60", vim.api.nvim_win_get_width(panel) == 60,
  "live=" .. vim.api.nvim_win_get_width(panel))

-- 7b. The pin must be a HARD CAP — simulate a third-party resize
-- (e.g. neo-tree's auto_expand_width) and verify enforce_pin clamps.
-- neo-tree bypasses winfixwidth via nvim_win_set_width on some
-- nvim versions; on others nvim_win_set_width respects winfixwidth.
-- Either way we want enforce_pin to clamp, so for the test we
-- temporarily lift winfixwidth to guarantee the simulated resize
-- "wins" first.
print("\n[7b] resize pin enforcement (vs neo-tree auto-expand)")
local host = require("auto-finder.panel.host")
vim.wo[panel].winfixwidth = false
pcall(vim.api.nvim_win_set_width, panel, 90)
vim.wo[panel].winfixwidth = true
-- nvim may clamp the requested width by other window constraints;
-- the assertion is just that the panel grew BEYOND the pin (60).
local after_resize = vim.api.nvim_win_get_width(panel)
ok("third-party resize grew panel beyond pin", after_resize > 60,
  "live=" .. after_resize)
host.enforce_pin(af.state.config, af.state)
ok("enforce_pin clamped back to 60",
  vim.api.nvim_win_get_width(panel) == 60,
  "live=" .. vim.api.nvim_win_get_width(panel))

af.reset_width()
ok("user_width cleared", af.state.user_width == nil)
ok("live width back to default (38)", vim.api.nvim_win_get_width(panel) == 38,
  "live=" .. vim.api.nvim_win_get_width(panel))

-- 7d. Pin must propagate auto_expand_width=false to neo-tree's
-- filesystem state and the global config — even when set from a
-- non-files section. This is the regression fix for "panel resize N
-- shows pinned at N but live still expands".
print("\n[7d] pin disables neo-tree auto_expand_width across sections")
local neo = require("neo-tree")
af.focus(0)  -- switch to config (REPL) section: panel buffer is no longer neo-tree
ok("focused config section", af.state.section == 0)
af.resize(50)
ok("global neo.config.window.auto_expand_width = false after pin",
  neo.config.window.auto_expand_width == false,
  tostring(neo.config.window.auto_expand_width))
local mgr = require("neo-tree.sources.manager")
local fs_states = {}
mgr._for_each_state("filesystem", function(s) table.insert(fs_states, s) end)
ok("at least one filesystem state exists", #fs_states > 0)
local all_off = true
for _, s in ipairs(fs_states) do
  if s.window and s.window.auto_expand_width ~= false then all_off = false end
end
ok("every filesystem state has auto_expand_width=false while pinned", all_off)
af.reset_width()
ok("global auto_expand_width restored to true after reset",
  neo.config.window.auto_expand_width == true,
  tostring(neo.config.window.auto_expand_width))
af.focus(1)  -- back to files for the rest of the suite

-- 7c. New panel verbs: dynamic alias and panel show
print("\n[7c] panel dynamic + panel show")
local admin_mod = require("auto-finder.panel.admin")
af.resize(50)
ok("after resize 50, user_width=50", af.state.user_width == 50)
admin_mod.dispatch("panel dynamic")
vim.wait(50, function() return af.state.user_width == nil end, 5)
ok("`panel dynamic` clears the pin (alias for reset)",
  af.state.user_width == nil)
local show = admin_mod._panel_show_lines()
local joined = table.concat(show, "\n")
ok("panel show contains 'mode'", joined:find("mode:") ~= nil, joined)
ok("panel show contains 'range'", joined:find("range:") ~= nil)
ok("panel show contains 'live'", joined:find("live:") ~= nil)
af.resize(50)
local show_pinned = table.concat(admin_mod._panel_show_lines(), "\n")
ok("panel show after pin includes 'pinned at 50'",
  show_pinned:find("pinned at 50") ~= nil, show_pinned)
af.reset_width()

-- ───────────────────────── 8. close + reopen ───────────────────────
print("\n[8] close + reopen")
af.close()
ok("panel_winid cleared after close", af.state.panel_winid == nil)
af.open(true)
ok("panel reopens", af.state.panel_winid ~= nil and vim.api.nvim_win_is_valid(af.state.panel_winid))

-- ───────────────────────── 9. inheritance fix sim ───────────────────
print("\n[9] panel does not inherit neo-tree filetype on open")
af.close()
-- Simulate the `nvim .` autostart scenario without depending on neo-tree
-- internals: create a fake "neo-tree" buffer and park it in the cursor
-- window. The panel-open code path should refuse to inherit it.
local fake_nt = vim.api.nvim_create_buf(false, true)
vim.bo[fake_nt].buftype = "nofile"
vim.bo[fake_nt].filetype = "neo-tree"
pcall(vim.api.nvim_buf_set_var, fake_nt, "neo_tree_position", "left")
local first_win = vim.api.nvim_list_wins()[1]
vim.api.nvim_set_current_win(first_win)
pcall(vim.api.nvim_win_set_buf, first_win, fake_nt)
-- Pre-condition: cursor window holds a neo-tree-flavored buffer.
ok("cursor window has filetype=neo-tree before open", vim.bo.filetype == "neo-tree")

-- Now open the panel from inside that window. ensure_open should swap
-- the inherited buffer for a scratch *before* focus mounts the section
-- so neo-tree's command override doesn't redirect us.
local host = require("auto-finder.panel.host")
-- Drive ensure_open directly so we can inspect the panel buffer right
-- after the split, before focus runs and replaces it with the real
-- neo-tree mount.
local saved_section = af.state.section
af.state.section = nil  -- force open() to call focus(default), but we
                        -- bypass open() entirely below
local panel_winid = host.ensure_open(af.state.config, af.state, true)
ok("ensure_open returns winid", panel_winid ~= nil)
panel_buf = panel_winid and vim.api.nvim_win_get_buf(panel_winid) or -1
local panel_ft = vim.bo[panel_buf].filetype
ok("panel buf is NOT inherited neo-tree (filetype is empty)", panel_ft == "",
  "panel_ft=" .. panel_ft)
ok("panel buf is NOT the fake neo-tree buffer", panel_buf ~= fake_nt,
  "panel_buf=" .. panel_buf .. " fake=" .. fake_nt)
af.state.section = saved_section

-- ─────────────────────── 10b. store persistence ──────────────────
print("\n[10b] store persistence (panel pin survives restart)")
-- Use a temp config dir so we don't trash the user's real
-- ~/.config/nvim/.auto-finder. stdpath('config') is read once per
-- session, so override env before the store reads it.
local tmp_config = "/tmp/auto-finder-smoke-config"
vim.fn.delete(tmp_config, "rf")
vim.env.XDG_CONFIG_HOME = tmp_config
-- stdpath caches; force-clear by re-reading.
-- (vim.fn.stdpath reads from XDG_CONFIG_HOME each call.)

local store = require("auto-finder.store")
ok("store dir resolves under XDG_CONFIG_HOME",
  store._dir():find(tmp_config, 1, true) ~= nil,
  store._dir())

-- Round-trip: save → load.
store.save({
  version = 1,
  panel = { user_width = 67, side = "right" },
  files = { hide_dotfiles = true, hide_gitignored = false },
})
local loaded = store.load()
ok("loaded user_width round-trips",
  (loaded.panel or {}).user_width == 67,
  vim.inspect(loaded))
ok("loaded side round-trips", (loaded.panel or {}).side == "right")
ok("loaded hide_dotfiles round-trips", (loaded.files or {}).hide_dotfiles == true)

-- update() merges shallow + persists.
store.update({ panel = { user_width = 42 } })
local after_update = store.load()
ok("update preserves untouched fields",
  (after_update.panel or {}).side == "right")
ok("update overrides specified field",
  (after_update.panel or {}).user_width == 42)

-- Missing file → empty table, no throw.
vim.fn.delete(tmp_config, "rf")
local missing = store.load()
ok("load on missing file returns empty table",
  type(missing) == "table" and next(missing) == nil)

-- ─────────────────────── 10. winbar + completion ──────────────────
print("\n[10] winbar clickable regions + admin tab-completion")
local winbar = require("auto-finder.panel.winbar")
local sections = require("auto-finder.sections").enabled()
local rendered = winbar.render(1, sections, 50)
ok("winbar contains click region for section 0",
  rendered:find("%%0@v:lua%.require'auto%-finder%.panel%.winbar'%.click@") ~= nil,
  rendered)
ok("winbar contains click region for section 1",
  rendered:find("%%1@v:lua%.require'auto%-finder%.panel%.winbar'%.click@") ~= nil)

-- Compact mode (very narrow): focused gets [N: name], unfocused get just N.
local narrow = winbar.render(1, sections, 12)
ok("narrow winbar drops unfocused labels",
  narrow:find("config") == nil,
  narrow)

local admin = require("auto-finder.panel.admin")
-- complete_at on an empty prompt → top-level verbs.
local _, top_cands = admin._complete_at("", 0)
ok("complete_at empty prompt returns 'help'",
  vim.tbl_contains(top_cands, "help"))
ok("complete_at empty prompt returns 'files'",
  vim.tbl_contains(top_cands, "files"))
ok("complete_at empty prompt returns 'panel'",
  vim.tbl_contains(top_cands, "panel"))

-- complete_at on `panel ` → resize / reset / dynamic / show. The
-- `side` candidate was removed — the panel is left-anchored only.
local _, panel_cands = admin._complete_at("panel ", 6)
ok("complete_at after 'panel ' offers 'resize'",
  vim.tbl_contains(panel_cands, "resize"))
ok("complete_at after 'panel ' offers 'show'",
  vim.tbl_contains(panel_cands, "show"))
ok("complete_at after 'panel ' does NOT offer 'side'",
  not vim.tbl_contains(panel_cands, "side"))

-- complete_at on `files show ` → hidden / dotfiles.
local _, files_cands = admin._complete_at("files show ", 11)
ok("complete_at after 'files show ' offers 'hidden'",
  vim.tbl_contains(files_cands, "hidden"))
ok("complete_at after 'files show ' offers 'dotfiles'",
  vim.tbl_contains(files_cands, "dotfiles"))

-- complete_at with a partial token filters.
local _, partial = admin._complete_at("p", 1)
ok("complete_at on 'p' filters to verbs starting with p",
  #partial > 0 and vim.tbl_contains(partial, "panel"),
  "got=" .. table.concat(partial, ","))

-- ─────────────────────── 11. repos section ──────────────────────
print("\n[11] repos section (worktree.nvim facade)")
-- Re-setup with the repos section enabled. Idempotent — re-applies opts
-- and rebuilds the section registry. Use a temp config dir so any
-- per-config persistence is isolated from the user's real one.
vim.fn.delete("/tmp/auto-finder-smoke-config-repos", "rf")
vim.env.XDG_CONFIG_HOME = "/tmp/auto-finder-smoke-config-repos"
af.setup({
  width = { default = 38, min = 25, max = 100 },
  default_section = 1,
  sections = { "config", "files", "repos" },
})
ok("repos section registered", require("auto-finder.sections")._by_name["repos"] ~= nil)
local repos_sec = require("auto-finder.sections").resolve("repos")
ok("repos section resolves by name", repos_sec ~= nil)
ok("repos section gets index 2", repos_sec and repos_sec.number == 2)

-- worktree.nvim isn't on the test runtimepath. The repos module
-- should degrade gracefully — every accessor returns empty / nil
-- instead of throwing, and the section can still be focused (the
-- tree just renders the empty-state placeholder).
local repos_mod = require("auto-finder.repos")
ok("repos.root() returns nil when worktree.nvim absent",
  repos_mod.root() == nil)
ok("repos.load() returns empty when worktree.nvim absent",
  type(repos_mod.load()) == "table" and #repos_mod.load() == 0)
ok("repos.worktree_paths() returns empty when worktree.nvim absent",
  type(repos_mod.worktree_paths()) == "table" and #repos_mod.worktree_paths() == 0)

-- Admin REPL: the verb / completion surface for `repos` is
-- intentionally absent — discovery is fully automatic via
-- worktree.nvim, no admin commands operate on the registry (there
-- is no registry).
local _, top = admin._complete_at("", 0)
ok("complete_at empty does NOT offer 'repos'",
  not vim.tbl_contains(top, "repos"))

-- Focusing the repos section must succeed end-to-end even with an
-- empty discovery — the empty-state placeholder is rendered as a
-- single message-type node and the panel buffer is still neo-tree.
af.open(true)
local repos_focus_ok, repos_focus_err = af.focus("repos")
ok("focus('repos') succeeds", repos_focus_ok, repos_focus_err)
ok("state.section == 2 after focus repos", af.state.section == 2)
vim.wait(300, function()
  if not af.state.panel_winid or not vim.api.nvim_win_is_valid(af.state.panel_winid) then
    return false
  end
  local b = vim.api.nvim_win_get_buf(af.state.panel_winid)
  return vim.bo[b].filetype == "neo-tree"
end, 10)
local repos_buf = af.state.panel_winid and vim.api.nvim_win_get_buf(af.state.panel_winid)
ok("repos panel buffer is neo-tree filetype",
  repos_buf and vim.bo[repos_buf].filetype == "neo-tree",
  "ft=" .. tostring(repos_buf and vim.bo[repos_buf].filetype))

-- ─────────────────────── 12. last_section persistence ──────────────────
print("\n[12] last_section persists across setup")
af.open(true)
af.focus(1)  -- files
ok("focused files (section 1)", af.state.section == 1)
local persisted_after_focus = require("auto-finder.store").load()
ok("store.last_section == 1 after focus(1)",
  (persisted_after_focus.panel or {}).last_section == 1,
  vim.inspect(persisted_after_focus))
af.focus(0)  -- config
ok("focused config (section 0)", af.state.section == 0)
local persisted_after_config = require("auto-finder.store").load()
ok("store.last_section == 0 after focus(0)",
  (persisted_after_config.panel or {}).last_section == 0)

-- Restart sim: clear state, re-setup, verify state.section restored.
af.close()
af.state.section = nil
af.setup({
  width = { default = 38, min = 25, max = 100 },
  default_section = 1,
  sections = { "config", "files", "repos" },
})
ok("setup restored last_section into state.section",
  af.state.section == 0,
  "state.section=" .. tostring(af.state.section))

-- ───────────────────────── summary ────────────────────────
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
