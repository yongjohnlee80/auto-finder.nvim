-- Headless smoke tests for auto-finder.nvim. Run with:
--   nvim --headless -u NONE -l /tmp/auto-finder-smoke.lua
--
-- Exits 0 on PASS, 1 on FAIL. Each test prints its own line.

-- Derive plugin_root from the smoke script's own path so the driver
-- runs unmodified on any machine (Mac, Linux, bare-repo worktree,
-- plain clone). `tests/smoke.lua` is two levels below the plugin root.
local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")

local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
-- `plugin_root` is `…/nvim-plugins/auto-finder.nvim/<worktree>`. The
-- sibling auto-core checkouts live two `:h` levels up at
-- `…/nvim-plugins/auto-core.nvim/<worktree>`. The old code used a
-- single `:h` which landed on `auto-finder.nvim/auto-core.nvim/…`
-- (a path that doesn't exist), so neither sibling rtp entry was
-- ever picked up.
local plugins_root = vim.fn.fnamemodify(plugin_root, ":h:h")
for _, p in ipairs({
  plugin_root,
  -- auto-core soft-dep: when present, enables Phase 4b live-refresh
  -- in the files section AND the help-overlay path. We list both
  -- candidate worktrees so the smoke exercises whichever auto-core
  -- branch is currently active. `comms-1` is listed LAST so that —
  -- when it exists — its runtimepath prepend wins over `main`,
  -- letting the suite validate ADR 0021 Phase 1's surface
  -- (`core_log.events`, `notify`, `notifyIf`) against the wrapper.
  plugins_root .. "/auto-core.nvim/main",
  LAZY .. "/auto-core.nvim",
  LAZY .. "/nui.nvim",
  LAZY .. "/plenary.nvim",
  plugins_root .. "/auto-core.nvim/comms-1",
}) do
  if vim.fn.isdirectory(p) == 1 then
    vim.opt.runtimepath:prepend(p)
  end
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
-- v0.2.0 step 2: also isolate XDG_STATE_HOME so auto-core.state's
-- namespace persist (which writes under `<state>/auto-core/`) doesn't
-- leak into the user's real state directory and corrupt their pin
-- across sessions.
vim.fn.delete("/tmp/auto-finder-smoke-config-default", "rf")
vim.env.XDG_CONFIG_HOME = "/tmp/auto-finder-smoke-config-default"
vim.fn.delete("/tmp/auto-finder-smoke-state-default", "rf")
vim.env.XDG_STATE_HOME = "/tmp/auto-finder-smoke-state-default"

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

-- v0.1.3+: the forked neo-tree's setup is invoked by
-- `auto-finder.setup()` via `cfg.neo_tree`. We pre-call it here just
-- to confirm idempotency — auto-finder's setup() will re-call with
-- whatever's in `cfg.neo_tree` and the merge_config path caches
-- correctly. `window.auto_expand_width = true` mirrors AutoVim's
-- consumer configuration so test [7d] can verify pin/auto-expand
-- interaction.
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
  -- v0.1.3+: cfg.neo_tree forwards to auto-finder.neotree.setup().
  -- Carrying the same opts the smoke prelude staged so test [7d]'s
  -- pin/auto-expand assertion remains valid after auto-finder's
  -- setup() re-applies neo-tree config.
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
-- v0.1.4: `w:auto_finder_panel` marker so sibling plugins (notably
-- auto-agents's editor-floor invariant) can identify the panel
-- without depending on filetype, which churns across our sections.
ok("panel carries w:auto_finder_panel = 1",
  panel and vim.w[panel].auto_finder_panel == 1)
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
  function() return vim.bo[vim.api.nvim_win_get_buf(panel)].filetype == "auto-finder" end,
  5)
local panel_buf = vim.api.nvim_win_get_buf(panel)
local ft = vim.bo[panel_buf].filetype
ok("panel buffer is filetype=neo-tree", ft == "auto-finder", "ft=" .. ft)

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
  vim.bo[panel_buf].filetype == "auto-finder",
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
  vim.bo[panel_buf].filetype == "auto-finder")

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
ok("panel back on neo-tree", vim.bo[panel_buf].filetype == "auto-finder")
ok("section_buffers cached for 0 and 1",
  af.state.section_buffers[0] and af.state.section_buffers[1])

-- v0.1.4: `q` is bound buffer-locally to close the auto-finder panel
-- — overrides neo-tree's default `q = close_window` which would
-- otherwise trigger `nvim_win_set_buf` against winfixbuf and crash
-- with E1513.
local q_keymap = vim.fn.maparg("q", "n", false, true)
ok("q bound on the panel buffer (overrides neo-tree close_window)",
  type(q_keymap) == "table" and q_keymap.buffer == 1
    and (q_keymap.desc or ""):find("close panel") ~= nil,
  vim.inspect(q_keymap))

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

-- 7d. Pin must prevent the renderer from auto-expanding the panel.
-- v0.1.x worked around this by mutating
-- `state.window.auto_expand_width = false` on every live filesystem
-- state from outside; the v0.1.3 fork moves the check into the
-- renderer, which reads `auto-finder.state.user_width` directly per
-- render. So the assertion is observable behavior — does the panel
-- stay at the pin when we resize wider with auto_expand_width still
-- nominally enabled?
print("\n[7d] pin caps the panel — renderer respects user_width")
af.focus(0)  -- in config REPL; panel buffer is not neo-tree
ok("focused config section", af.state.section == 0)
af.resize(50)
ok("user_width = 50 after resize", af.state.user_width == 50)
ok("panel locked at 50 after resize",
  vim.api.nvim_win_get_width(af.state.panel_winid) == 50,
  "live=" .. vim.api.nvim_win_get_width(af.state.panel_winid))

-- The fork's render_tree (renderer.lua near line 1353) reads
-- `auto-finder.state.user_width` and skips the auto-expand branch
-- when a pin is set. The on-state `state.window.auto_expand_width`
-- can stay `true` — the renderer ignores it under a pin.
local neo = require("auto-finder.neotree")
ok("neo.config.window.auto_expand_width unchanged by pin (still true)",
  neo.config.window.auto_expand_width == true,
  "got " .. tostring(neo.config.window.auto_expand_width))

af.reset_width()
ok("user_width cleared after reset", af.state.user_width == nil)
af.focus(1)  -- back to files for the rest of the suite

-- ─── 7e. right-aligned-icons regression guard ─────────────────────
-- Bug from the v0.1.x wrapper era + Phase 4 manual testing: the
-- forked renderer inherited upstream's clamp at `position == "current"`
-- that capped `remaining_cols` at `longest_node + 4`. Right-aligned
-- components (modified marker, diagnostics, git_status, file_size)
-- positioned against THAT cap, leaving the right portion of any
-- panel wider than the longest filename empty.
--
-- Removed the clamp in v0.1.3 (renderer.lua line ~462). This test
-- guards the source structure: if anyone re-introduces the clamp
-- via an upstream sync, this fails with a clear pointer.
--
-- A behavioral test (mount, render, inspect rendered line widths)
-- was tried first but was timing-dependent on neo-tree's async
-- mount and unreliable in headless. The source-grep is structurally
-- reliable and unambiguous about the bug it's guarding.
print("\n[7e] regression: position=current no longer clamps to longest+4")

local renderer_path = plugin_root .. "/lua/auto-finder/neotree/ui/renderer.lua"
local renderer_src = vim.fn.readfile(renderer_path)
local clamp_line, clamp_lineno
for i, line in ipairs(renderer_src) do
  -- Match the pattern `math.min(remaining_cols, …, longest_node + 4)`
  -- in any form. Comment-only references are fine — those are the
  -- "we removed this on purpose" notes.
  if not line:match("^%s*%-%-")
      and (line:match("math%.min%s*%(%s*remaining_cols.*longest")
        or (line:match("remaining_cols%s*=%s*math%.min")
            and line:match("longest"))) then
    clamp_line = line
    clamp_lineno = i
    break
  end
end
ok("forked renderer does NOT clamp remaining_cols to longest_node+4",
  clamp_line == nil,
  clamp_line and ("found clamp at renderer.lua:" .. clamp_lineno .. " → " .. clamp_line) or "")

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
-- internals: create a fake "auto-finder" buffer and park it in the cursor
-- window. The panel-open code path should refuse to inherit it.
local fake_nt = vim.api.nvim_create_buf(false, true)
vim.bo[fake_nt].buftype = "nofile"
vim.bo[fake_nt].filetype = "auto-finder"
pcall(vim.api.nvim_buf_set_var, fake_nt, "neo_tree_position", "left")
local first_win = vim.api.nvim_list_wins()[1]
vim.api.nvim_set_current_win(first_win)
pcall(vim.api.nvim_win_set_buf, first_win, fake_nt)
-- Pre-condition: cursor window holds a neo-tree-flavored buffer.
ok("cursor window has filetype=neo-tree before open", vim.bo.filetype == "auto-finder")

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

-- v0.2.0 step 2: store.save STRIPS panel.user_width / panel.last_section
-- (those keys live in auto-core.state.namespace("auto-finder") now —
-- see test [16]). Only files.* survives the save sanitization here.
store.save({
  version = 1,
  panel = { user_width = 67, side = "right" },
  files = { hide_dotfiles = true, hide_gitignored = false },
})
local loaded = store.load()
ok("save strips panel.user_width (migrated to state.namespace)",
  (loaded.panel or {}).user_width == nil,
  vim.inspect(loaded))
ok("save strips panel.side (legacy)",
  (loaded.panel or {}).side == nil)
ok("loaded hide_dotfiles round-trips", (loaded.files or {}).hide_dotfiles == true)
ok("loaded hide_gitignored round-trips", (loaded.files or {}).hide_gitignored == false)

-- update() merges shallow + persists; panel keys still get stripped.
store.update({ files = { hide_dotfiles = false } })
local after_update = store.load()
ok("update overrides files field",
  (after_update.files or {}).hide_dotfiles == false)
ok("update preserves untouched files field",
  (after_update.files or {}).hide_gitignored == false)

-- Missing file → empty table, no throw.
vim.fn.delete(tmp_config, "rf")
local missing = store.load()
ok("load on missing file returns empty table",
  type(missing) == "table" and next(missing) == nil)

-- ─────────────────────── 10. winbar + completion ──────────────────
print("\n[10] winbar clickable regions + admin tab-completion")
-- v0.2.0 step 3: lua/auto-finder/panel/winbar.lua removed; auto-core's
-- ui.winbar primitive now renders the tab strip via the panel
-- singleton's `set_winbar(sections, focused)`. We open the panel,
-- focus a section, then read the winbar option to verify the click
-- regions land. Click router moves to `auto-core.ui.winbar.click`.
af.open(true)
af.focus(1)
local sections = require("auto-finder.sections").enabled()
local panel_winid = af.state.panel_winid
local rendered = vim.api.nvim_get_option_value("winbar",
  { win = panel_winid })
ok("winbar contains click region for section 0",
  rendered:find("@v:lua%.require'auto%-core%.ui%.winbar'%.click@") ~= nil,
  rendered)
ok("winbar uses auto-core.ui.winbar router",
  rendered:find("auto%-core%.ui%.winbar") ~= nil)
-- Compact mode is exercised on narrow widths; auto-core's primitive
-- has the same 3-mode adaptive renderer.
af.focus(0)  -- back to config so subsequent tests start fresh.

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

-- Admin REPL: as of v0.2.2, `repos` IS a top-level verb (carries the
-- new `repos follow on|off|toggle` toggle). Discovery is still
-- automatic via worktree.nvim — repos has no registry to manage —
-- but the follow-mode toggle is a legitimate per-section setting,
-- so the verb belongs in the completion surface.
local _, top = admin._complete_at("", 0)
ok("complete_at empty offers 'repos' (for `repos follow`)",
  vim.tbl_contains(top, "repos"))
local _, repos_subs = admin._complete_at("repos ", 6)
ok("complete_at 'repos ' offers 'follow'",
  vim.tbl_contains(repos_subs, "follow"))
local _, follow_args = admin._complete_at("repos follow ", 13)
ok("complete_at 'repos follow ' offers 'on'/'off'/'toggle'",
  vim.tbl_contains(follow_args, "on")
    and vim.tbl_contains(follow_args, "off")
    and vim.tbl_contains(follow_args, "toggle"))

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
  return vim.bo[b].filetype == "auto-finder"
end, 10)
local repos_buf = af.state.panel_winid and vim.api.nvim_win_get_buf(af.state.panel_winid)
ok("repos panel buffer is neo-tree filetype",
  repos_buf and vim.bo[repos_buf].filetype == "auto-finder",
  "ft=" .. tostring(repos_buf and vim.bo[repos_buf].filetype))

-- ─────────────────────── 11b. repos icon overrides ──────────────────
print("\n[11b] repos section icon overrides (workspace + worktree glyphs)")
local repos_components = require("auto-finder-repos.components")
local repos_highlights = require("auto-finder.neotree.ui.highlights")
local fake_state = {}
local workspace_node = { type = "directory", extra = { is_workspace = true } }
local worktree_node = { type = "directory", extra = { is_worktree = true } }
local subdir_node = {
  type = "directory",
  extra = {},
  loaded = true,
  is_expanded = function() return false end,
  has_children = function() return true end,
}

local ws_icon = repos_components.icon({}, workspace_node, fake_state)
ok("workspace icon glyph is the repository codepoint",
  ws_icon and ws_icon.text and ws_icon.text:find("\u{ea62}", 1, true) ~= nil,
  "got text=" .. vim.inspect(ws_icon and ws_icon.text))
ok("workspace icon uses ROOT_NAME highlight",
  ws_icon and ws_icon.highlight == repos_highlights.ROOT_NAME,
  "hl=" .. tostring(ws_icon and ws_icon.highlight))

local wt_icon = repos_components.icon({}, worktree_node, fake_state)
ok("worktree icon glyph is the branch codepoint",
  wt_icon and wt_icon.text and wt_icon.text:find("\u{f126}", 1, true) ~= nil,
  "got text=" .. vim.inspect(wt_icon and wt_icon.text))
ok("worktree icon uses GIT_UNTRACKED highlight",
  wt_icon and wt_icon.highlight == repos_highlights.GIT_UNTRACKED,
  "hl=" .. tostring(wt_icon and wt_icon.highlight))

-- Subdirectories under a worktree (no is_workspace/is_worktree
-- flag) must fall through to the common icon component — the
-- workspace/worktree glyphs MUST NOT appear there.
local sub_icon = repos_components.icon({}, subdir_node, fake_state)
ok("subdirectory icon does NOT use the workspace glyph",
  sub_icon and sub_icon.text
    and sub_icon.text:find("\u{ea62}", 1, true) == nil
    and sub_icon.text:find("\u{f126}", 1, true) == nil,
  "got text=" .. vim.inspect(sub_icon and sub_icon.text))

-- ─────────────────────── 12. last_section persistence ──────────────────
print("\n[12] last_section persists across setup")
-- v0.2.0 step 2: last_section moved from auto-finder/store.lua's
-- config.json to auto-core.state.namespace("auto-finder"); read
-- through the typed getter rather than store.load().
af.open(true)
af.focus(1)  -- files
ok("focused files (section 1)", af.state.section == 1)
ok("namespace.last_section == 1 after focus(1)",
  require("auto-finder.state").get_last_section() == 1)
af.focus(0)  -- config
ok("focused config (section 0)", af.state.section == 0)
ok("namespace.last_section == 0 after focus(0)",
  require("auto-finder.state").get_last_section() == 0)

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

-- ───────────────────────── 13. directory-hijack defers M.open ─────────────────────────
-- Regression: E242 "Can't split a window while closing another" on
-- `nvim .` when the hijack called M.open synchronously. nvim_buf_delete
-- with force=true unwinds BufDelete/BufWipeout autocmds and may leave
-- nvim in a window-closing state; a synchronous vsplit then fails.
-- Fix: vim.schedule() the open so the close chain drains first.
print("\n[13] directory-hijack defers M.open")
-- NB: this section's vim.wait() drains the scheduler, so any neo-tree
-- async-render callbacks from [11] that were still queued may now
-- fire and complain about the closed panel window from [11]/[12]
-- (stale winid). Those stderr warnings are harmless and not a
-- regression from this fix — the assertions below are what matter.
af.close()
af._hijack_done = nil
-- Stage a directory buffer at the cwd. _maybe_hijack_startup_directory
-- reads the current buffer's name; isdirectory(name) must return 1.
-- eventignore=all during setup so neo-tree / other autocmds don't
-- hijack-and-wipe our staging buffer (buf 13 vanishing was the
-- symptom).
local dir = vim.fn.getcwd()
local saved_ei = vim.o.eventignore
vim.o.eventignore = "all"
local dir_buf = vim.api.nvim_create_buf(true, false)
vim.bo[dir_buf].buftype = "nofile"
vim.api.nvim_buf_set_name(dir_buf, dir)
vim.api.nvim_set_current_buf(dir_buf)
vim.o.eventignore = saved_ei
ok("directory buffer staged + valid",
  vim.api.nvim_buf_is_valid(dir_buf)
    and vim.fn.isdirectory(vim.api.nvim_buf_get_name(dir_buf)) == 1,
  "buf=" .. tostring(dir_buf) ..
    " valid=" .. tostring(vim.api.nvim_buf_is_valid(dir_buf)))

af._maybe_hijack_startup_directory()
ok("_hijack_done flagged after hijack call", af._hijack_done == true)
ok("panel NOT open synchronously inside hijack",
  af.state.panel_winid == nil
    or not vim.api.nvim_win_is_valid(af.state.panel_winid),
  "expected nil/invalid right after hijack, got winid=" ..
    tostring(af.state.panel_winid))

vim.wait(500, function()
  return af.state.panel_winid ~= nil
    and vim.api.nvim_win_is_valid(af.state.panel_winid)
end)
ok("panel opens after scheduled tick drains",
  af.state.panel_winid ~= nil
    and vim.api.nvim_win_is_valid(af.state.panel_winid),
  "panel_winid=" .. tostring(af.state.panel_winid))

-- ───────────────────────── 14. auto-core fs.watch live-refresh wiring ─────────────────────────
-- v0.1.4 integration: auto-finder/sections/files.lua sets
-- `live_refresh = true` so the files section subscribes to
-- core.file:* and triggers a debounced neo-tree refresh on changes.
-- Soft-dep: when auto-core is on the runtimepath (it IS for these
-- tests — added at the rtp prelude), the wiring is active.
print("\n[14] auto-core fs.watch live-refresh wiring (files section)")

local ac_ok, core = pcall(require, "auto-core")
ok("auto-core loadable on the rtp", ac_ok and type(core) == "table")
ok("auto-core.fs.watch present",
  type(core.fs) == "table" and type(core.fs.watch) == "table")
ok("auto-core.events present", type(core.events) == "table")

-- Reset state and refocus the files section so the watcher is fresh.
af.close()
vim.wait(50)  -- drain any pending neo-tree async callbacks
af.open(true)
af.focus(1)  -- files

local files_section = require("auto-finder.sections").resolve(1)
ok("files section resolves",
  files_section ~= nil and files_section.name == "files")
ok("files section has _ensure_fs_watch (live_refresh wired)",
  type(files_section._ensure_fs_watch) == "function")
ok("files section has _stop_fs_watch",
  type(files_section._stop_fs_watch) == "function")

ok("watcher handle present after focus(files)",
  files_section._fs_watch_handle ~= nil,
  "handle=" .. tostring(files_section._fs_watch_handle))
ok("watcher root matches getcwd",
  files_section._fs_watch_root == vim.fn.getcwd(),
  string.format("root=%s cwd=%s",
    tostring(files_section._fs_watch_root), vim.fn.getcwd()))

-- Stub neo-tree's manager.refresh to capture refresh calls.
-- Publishing a core.file:* event under cwd should land a
-- `manager.refresh("filesystem")` after the 150 ms debounce window.
-- (Earlier versions stubbed `cmd.execute` — but that path doesn't
-- actually trigger an fs rescan; cmd.execute has no "refresh"
-- action and silently falls through to show/focus. The fix routes
-- through `manager.refresh` directly, the same path R is bound to.)
local manager_mod = require("auto-finder.neotree.sources.manager")
local orig_refresh = manager_mod.refresh
local refresh_calls = {}
manager_mod.refresh = function(source_name, callback)
  refresh_calls[#refresh_calls + 1] = source_name
  -- Don't actually drive neo-tree on the synthetic event — we'd be
  -- asking it to rescan against a path that may not have a live
  -- state attached.
  if callback then pcall(callback) end
end

core.events.publish("core.file:modified", {
  path   = vim.fn.getcwd() .. "/some-synthetic-event-path.txt",
  change = "modified",
})
vim.wait(400, function()
  for _, src in ipairs(refresh_calls) do
    if src == "filesystem" then return true end
  end
  return false
end)
local saw_refresh = false
for _, src in ipairs(refresh_calls) do
  if src == "filesystem" then saw_refresh = true; break end
end
ok("file-event under cwd triggers neo-tree manager.refresh after debounce",
  saw_refresh,
  "refresh_calls=" .. vim.inspect(refresh_calls))

-- Events for paths OUTSIDE the watched root should NOT refresh.
refresh_calls = {}
core.events.publish("core.file:modified", {
  path   = "/tmp/some-other-place/x.txt",
  change = "modified",
})
vim.wait(250)
local saw_outside_refresh = false
for _, src in ipairs(refresh_calls) do
  if src == "filesystem" then saw_outside_refresh = true end
end
ok("out-of-root event does NOT trigger refresh", not saw_outside_refresh,
  "refresh_calls=" .. vim.inspect(refresh_calls))

manager_mod.refresh = orig_refresh

-- Tear-down.
files_section._stop_fs_watch()
ok("_stop_fs_watch clears watcher handle",
  files_section._fs_watch_handle == nil)
ok("_stop_fs_watch clears watcher root",
  files_section._fs_watch_root == nil)

-- ─────────── 15. auto-finder.log — wrapper over auto-core.log ──────────
print("\n[15] auto-finder.log wrapper")
local log = require("auto-finder.log")
ok("log module loads", type(log) == "table")
ok("log exposes level functions",
  type(log.error) == "function"
    and type(log.warn) == "function"
    and type(log.info) == "function"
    and type(log.debug) == "function"
    and type(log.trace) == "function")
ok("log.levels exposed", type(log.levels) == "table"
  and log.levels.ERROR ~= nil and log.levels.WARN ~= nil)

-- ADR 0021 §6 — wrapper convention surface check.
ok("log exposes notify / notifyIf / register_events",
  type(log.notify) == "function"
    and type(log.notifyIf) == "function"
    and type(log.register_events) == "function")

-- Drive the wrapper and inspect the auto-core.log ring buffer to verify
-- the namespace prefix lands as `auto-finder.<component>`.
local core_log = require("auto-core").log
core_log.clear()
-- WARN mirrors to vim.notify which would surface in the test output;
-- silence it for this assertion via configure({ notify = false }).
local prev_notify = (core_log.inspect and core_log.inspect().notify)
core_log.configure({ notify = false, level = "trace" })

log.warn("smoke", "wrapper wiring probe")
log.error("panel.host", "another component")
log.debug("smoke", "trace-level too")
local entries = core_log.recent(10)
ok("warn entry recorded with auto-finder.smoke component",
  vim.tbl_contains(vim.tbl_map(function(e) return e.component end, entries),
    "auto-finder.smoke"))
ok("error entry recorded with auto-finder.panel.host component",
  vim.tbl_contains(vim.tbl_map(function(e) return e.component end, entries),
    "auto-finder.panel.host"))
ok("debug entry body strips legacy 'auto-finder: ' prefix",
  (function()
    for _, e in ipairs(entries) do
      if e.level_name == "DEBUG" then
        return e.message:find("[auto-finder.smoke]", 1, true) ~= nil
          and e.message:find("trace-level too", 1, true) ~= nil
          and e.message:find("auto-finder: trace-level", 1, true) == nil
      end
    end
    return false
  end)())

-- Already-prefixed component name passes through (idempotent ns()).
log.warn("auto-finder.preprefixed", "no double prefix")
local last = core_log.recent(1)[1]
ok("idempotent namespace prefix",
  last and last.component == "auto-finder.preprefixed")

-- ADR 0021 Phase 2: register_events / notifyIf round trip via the
-- wrapper. Bare names auto-prefix; subscribing through the registry
-- gates the toast.
core_log.clear()
core_log._reset_for_tests()
core_log.configure({ notify = false, level = "trace" })
log.register_events({ "scan.started", "scan.completed.slow" })
local registered = core_log.events.list("auto-finder")
ok("register_events fully-qualifies bare names under auto-finder.*",
  #registered >= 2
    and vim.tbl_contains(vim.tbl_map(function(r) return r.event end, registered),
        "auto-finder.scan.started")
    and vim.tbl_contains(vim.tbl_map(function(r) return r.event end, registered),
        "auto-finder.scan.completed.slow"))

-- notifyIf with a bare event name auto-prefixes inside the wrapper.
core_log.clear()
log.notifyIf("scan.started", "test message", { component = "scan" })
local nf = core_log.recent(1)[1]
ok("notifyIf auto-prefixes bare event name in the ring entry",
  nf and nf.event_type == "auto-finder.scan.started"
    and nf.component == "auto-finder.scan")

-- notify with bare component auto-prefixes too.
core_log.clear()
log.notify("hello", { component = "scan", level = "info" })
local nn = core_log.recent(1)[1]
ok("notify auto-prefixes bare opts.component",
  nn and nn.component == "auto-finder.scan")

-- Restore notify mirroring so subsequent test runs (and real usage)
-- aren't silenced.
core_log.configure({ notify = prev_notify ~= false })

-- ───── 16. state.namespace migration (state.lua) ──────────
print("\n[16] state.namespace migration")
local state_mod = require("auto-finder.state")
local ns = state_mod.namespace()
ok("namespace handle returned", type(ns) == "table"
  and type(ns.get) == "function" and type(ns.set) == "function")

-- Round-trip via the typed setters.
state_mod.set_user_width(42)
ok("set_user_width(42) round-trips", state_mod.get_user_width() == 42)
state_mod.set_user_width(nil)
ok("set_user_width(nil) clears the pin",
  state_mod.get_user_width() == nil)
state_mod.set_last_section(2)
ok("set_last_section(2) round-trips", state_mod.get_last_section() == 2)

-- Type validation: non-integer fails (false, err) without mutating.
state_mod.set_user_width(50)
local ok_bad, err_bad = state_mod.set_user_width("not-a-number")
ok("set_user_width rejects non-numbers",
  ok_bad == false and type(err_bad) == "string")
ok("rejected set leaves prior value intact",
  state_mod.get_user_width() == 50)

-- Watcher mirrors namespace → M.state.user_width / M.state.section.
-- The real watchers are installed in auto-finder's setup() (which ran
-- in test [1]); confirm their effect by mutating via the typed setter
-- and reading the runtime mirror.
local af = require("auto-finder")
state_mod.set_user_width(73)
vim.wait(20)  -- subscribers fire synchronously, but be safe.
ok("watcher mirrors user_width to M.state.user_width",
  af.state.user_width == 73,
  "M.state.user_width=" .. tostring(af.state.user_width))
state_mod.set_user_width(nil)
vim.wait(20)
ok("watcher mirrors nil to M.state.user_width",
  af.state.user_width == nil)

state_mod.set_last_section(1)
vim.wait(20)
ok("watcher mirrors last_section to M.state.section",
  af.state.section == 1)

-- Persist round-trip: set value, force a flush, read the on-disk
-- JSON, verify the persisted shape.
state_mod.set_user_width(81)
ns:persist_now()
local persist_path = vim.fn.stdpath("state") .. "/auto-core/auto-finder.json"
local ok_read = vim.fn.filereadable(persist_path) == 1
ok("namespace persisted to <state>/auto-core/auto-finder.json",
  ok_read, persist_path)
if ok_read then
  local raw = table.concat(vim.fn.readfile(persist_path), "\n")
  local decoded = vim.fn.json_decode(raw)
  ok("on-disk JSON contains user_width=81",
    type(decoded) == "table" and decoded.user_width == 81,
    raw)
end

-- ───── 17. section registry migration (auto-core.ui.section) ──────
print("\n[17] section registry migration + worktree:switched")
ok("M._registry attached", type(af._registry) == "table"
  and type(af._registry.focus) == "function"
  and type(af._registry.sections) == "table")
ok("registry has same section count as enabled()",
  #af._registry.sections == #require("auto-finder.sections").enabled())

-- The legacy state.section_buffers field is now a live alias of the
-- registry's bufnr cache. Writes via the registry should be visible
-- through the legacy field, and vice versa.
ok("state.section_buffers aliases registry._bufs",
  af.state.section_buffers == af._registry._bufs)

-- Drive a focus through the wrapped focus path: M._registry:focus
-- routes through the wrapper which mirrors active/persist/redraw.
af.focus(0)  -- config section
ok("registry.active updated to 0", af._registry.active == 0)
ok("M.state.section mirror updated to 0", af.state.section == 0)
ok("namespace last_section persisted to 0 (via wrapped focus)",
  require("auto-finder.state").get_last_section() == 0)

af.focus(1)  -- files section
ok("registry.active updated to 1", af._registry.active == 1)

-- worktree:switched handler — invalidate repos bufnr if cached.
-- First make sure repos has been mounted at least once. Then publish
-- the event and assert the cache entry was dropped.
local repos_def
for _, s in ipairs(af._registry.sections) do
  if s.name == "repos" then repos_def = s; break end
end
if repos_def then
  -- Force a mount to populate the cache.
  af.focus(2)
  vim.wait(100)
  local before_buf = af._registry._bufs[repos_def.number]
  ok("repos bufnr cached pre-event",
    before_buf ~= nil and vim.api.nvim_buf_is_valid(before_buf))

  require("auto-core").events.publish("worktree:switched",
    { from = "/tmp/from", to = "/tmp/to" })
  vim.wait(50)
  -- After the event, repos cache is dropped; if repos was active,
  -- the handler also re-focuses (which re-mounts). So the bufnr may
  -- be different from before (re-mounted) OR nil (if remount
  -- deferred to next focus).
  local after_buf = af._registry._bufs[repos_def.number]
  ok("worktree:switched handler invalidated repos cache",
    after_buf ~= before_buf or after_buf == nil,
    string.format("before=%s after=%s",
      tostring(before_buf), tostring(after_buf)))
end

-- ───────────────────────── 18. v0.2.8 — buffers source + slot mutation ─────
-- Retroactive coverage for three bugs that escaped v0.2.5 because the
-- iteration shipped without smoke per `lua-nvim-plugin-development` rule
-- #4 ("each iteration adds or extends a test for the change it makes"):
--   (a) `buffers` source module was missing from the fork (port added v0.2.8).
--   (b) cfg.neo_tree.sources didn't include "buffers" so default_configs
--       wasn't populated (helper added v0.2.7 / fixed v0.2.8).
--   (c) slot mutations dispose()'d the entire registry, deleting EVERY
--       section's buffer (including the active config slot's buffer that
--       the user was typing in) → panel went blank. Fixed by in-place
--       mutation path in v0.2.8.
-- Rule #11 (effect-was-observed not call-was-made) — each assertion
-- targets an observable post-condition (require returns a table, buffer
-- survives, active section stays as expected), not just "the function
-- was called".
print("\n[18] v0.2.8 — buffers source + slot mutation preserves panel")

-- (a) Fork ships the buffers source module after the v0.2.8 port.
local ok_buf_src = pcall(require, "auto-finder.neotree.sources.buffers")
ok("auto-finder.neotree.sources.buffers loads (ported v0.2.8)",
  ok_buf_src)

-- (b) auto-finder's _register_bundled_neotree_sources adds "buffers"
-- (alongside "filesystem") to cfg.neo_tree.sources so neo-tree's
-- default_config build covers it.
local cfg_probe = { neo_tree = {} }
af._register_bundled_neotree_sources(cfg_probe)
ok("_register_bundled_neotree_sources adds 'buffers'",
  vim.tbl_contains(cfg_probe.neo_tree.sources, "buffers"))
ok("_register_bundled_neotree_sources adds 'filesystem'",
  vim.tbl_contains(cfg_probe.neo_tree.sources, "filesystem"))
af._register_bundled_neotree_sources(cfg_probe)  -- idempotency check
local count_buffers = 0
for _, s in ipairs(cfg_probe.neo_tree.sources) do
  if s == "buffers" then count_buffers = count_buffers + 1 end
end
ok("_register_bundled_neotree_sources is idempotent (no duplicate 'buffers')",
  count_buffers == 1)

-- (c) Slot mutation preserves the config slot's buffer. The previous
-- dispose-and-reattach path deleted every section's bufnr — including
-- the active config slot — which made the panel window's bufnr point at
-- a dead buffer. The v0.2.8 in-place mutation keeps survivors intact.
af.focus(0)
vim.wait(50)
local config_buf_before = af._registry._bufs[0]
ok("config slot buffer exists pre-mutation",
  config_buf_before ~= nil and vim.api.nvim_buf_is_valid(config_buf_before))

local add_err = af.slot_add("buffers")
ok("slot_add('buffers') succeeded",
  add_err == nil, tostring(add_err))
ok("buffers section registered after slot_add",
  require("auto-finder.sections")._by_name["buffers"] ~= nil)
local config_buf_after_add = af._registry._bufs[0]
ok("config slot buffer survives slot_add (in-place mutation)",
  config_buf_after_add == config_buf_before
    and vim.api.nvim_buf_is_valid(config_buf_after_add))
ok("active section stays on config slot (0) after slot_add",
  af._registry.active == 0)

local rm_err = af.slot_remove(#af.state.config.sections - 1)
ok("slot_remove(<last>) succeeded",
  rm_err == nil, tostring(rm_err))
ok("buffers section deregistered after slot_remove",
  require("auto-finder.sections")._by_name["buffers"] == nil)
local config_buf_after_remove = af._registry._bufs[0]
ok("config slot buffer survives slot_remove (in-place mutation)",
  config_buf_after_remove == config_buf_before
    and vim.api.nvim_buf_is_valid(config_buf_after_remove))
ok("active section stays on config slot (0) after slot_remove",
  af._registry.active == 0)

-- ───────────────────────── 19. v0.2.9 — buffers-refresh against panel win-keyed state ────────────────────────
--
-- Regression test for the v0.2.9 fix. The forked buffers source's
-- internal BufAdd/BufDelete subscriber resolves state via
-- `manager.get_state(name, tabid)` — which returns a `state_by_tab`
-- stub (no path/winid/tree) for `position = "current"` mounts. The
-- result was that opening a buffer AFTER the panel mounted left the
-- tree empty until a manual remount. The fix installs our own
-- BufAdd autocmd that walks `_get_all_states()` for the win-keyed
-- buffers state bound to `M.state.panel_winid` and calls
-- `items.get_opened_buffers(state)` directly — same body, right
-- state. Assert the effect: opening a fresh file with the buffers
-- panel active grows the tree's `state.tree.nodes.by_id` set.
print("\n[19] v0.2.9 — buffers-refresh against panel win-keyed state")

-- (a) The wiring function exists on the public API.
ok("M._install_buffers_refresh_autocmd is a function",
  type(af._install_buffers_refresh_autocmd) == "function")

-- (b) Setup installed an autocmd in the AutoFinderPanel group with
--   our descriptor — single-call assertion that the audit landed
--   regardless of whether buffers is the live section. The desc is
--   the contract-level identifier; matching on it is a stable check.
local _refresh_autos = vim.api.nvim_get_autocmds({ event = "BufAdd" })
local _refresh_found = false
for _, a in ipairs(_refresh_autos) do
  if (a.desc or ""):find(
       "auto-finder: buffers-refresh against panel win-keyed state", 1, true) then
    _refresh_found = true; break
  end
end
ok("BufAdd autocmd installed with buffers-refresh descriptor",
  _refresh_found)

-- (c) Switch to the buffers section (via slot_add since the default
--   config in this smoke driver doesn't have it). Open a probe file
--   in an editor split outside the panel; assert the tree grew.
af.slot_add("buffers")
local _buffers_idx = require("auto-finder.sections")._by_name["buffers"]
ok("buffers section was added by slot_add for this test",
  _buffers_idx ~= nil)
af.focus(_buffers_idx)
vim.wait(120)  -- mount + first render

-- Probe file: a real file under cwd (state.path resolves to cwd) so
-- `is_subpath(state.path, file_path)` matches. tempname() lives under
-- $TMPDIR — outside cwd — so we can't just create a temp file; use
-- the repo's tests/ dir which definitely IS within cwd.
local _probe_path = vim.fn.getcwd() .. "/tests/_buffers_refresh_probe.txt"
do
  local fh = io.open(_probe_path, "w")
  fh:write("smoke probe"); fh:close()
end
local _prev_win = vim.api.nvim_get_current_win()

local _mgr = require("auto-finder.neotree.sources.manager")
local function _tree_info()
  for _, s in ipairs(_mgr._get_all_states()) do
    if s.name == "buffers" and s.tree then
      local n = 0
      for _ in pairs(s.tree.nodes.by_id or {}) do n = n + 1 end
      return n, s.path or "<nil>", s.winid or -1
    end
  end
  return -1, "<no state>", -1
end
local _tree_size = function() local n = _tree_info(); return n end
local _size_before, _state_path, _state_winid = _tree_info()
ok("buffers state visible to autocmd (path matches cwd, winid matches panel)",
   _state_path == vim.fn.getcwd() and _state_winid == af.state.panel_winid)

-- Open the file in a side split (so we don't replace the panel buffer).
vim.cmd("topleft split " .. vim.fn.fnameescape(_probe_path))
-- Debounce is 80ms; wait long enough for fire() to land plus a poll cycle.
vim.wait(400, function()
  return _tree_size() > _size_before
end, 20)
local _size_after = _tree_size()
ok("buffers tree grew after opening a new file (before=" ..
   _size_before .. " after=" .. _size_after .. ")",
   _size_after > _size_before)

-- Cleanup: close the probe window, delete the buffer + the file on disk.
pcall(vim.api.nvim_win_close, vim.api.nvim_get_current_win(), true)
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_get_name(b) == _probe_path then
    pcall(vim.api.nvim_buf_delete, b, { force = true })
  end
end
pcall(os.remove, _probe_path)
pcall(vim.api.nvim_set_current_win, _prev_win)

-- ───────────────────────── 20. v0.2.10 — sections load-timing fix ────────────────────────
--
-- Regression test for the v0.2.10 fix. Slot additions persist to
-- the namespace JSON, but when auto-finder.setup() runs BEFORE
-- worktree.nvim captures workspace_root the seed read returns nil
-- and `cfg.sections` keeps its default. The pre-fix subscription
-- only listened to `worktree:switched` — which doesn't fire on
-- initial capture — so the reseed never ran. v0.2.10 adds a
-- `core.workspace_root:changed` subscription + a vim_did_enter
-- immediate-retry inside setup.
--
-- Test strategy: pre-populate the namespace with a non-default
-- sections list for the current workspace key, force cfg.sections
-- back to the default to simulate "setup missed it", then publish
-- `core.workspace_root:changed` and assert the reseed fires.
print("\n[20] v0.2.10 — sections load-timing fix (core.workspace_root:changed reseed)")
;(function()
local _af = require("auto-finder")
local _state_mod = require("auto-finder.state")
local _core = require("auto-core")

-- Smoke runs without worktree.nvim, so workspace_root isn't captured
-- by default — exactly the race the v0.2.10 fix exists to handle.
-- Set it explicitly so M._workspace_key() returns a stable value for
-- our assertions; the publish call below replays the same signal
-- worktree.nvim emits on real session-start capture.
_core.git.worktree.set_workspace_root(vim.fn.getcwd())
local _wskey = _af._workspace_key()
ok("workspace key resolves after set_workspace_root",
   type(_wskey) == "string" and #_wskey > 0)
if not _wskey then return end

-- Snapshot original state so we can restore at the end.
local _orig_persisted = _state_mod.get_sections_for(_wskey)
local _orig_live = vim.list_extend({}, _af.state.config.sections)

-- Persist a NON-default sections list under our key. Use the
-- baseline + an extra "buffers" slot so the comparison is
-- unambiguous against the default `{ "config", "files", "repos" }`.
local _target = { "config", "files", "repos", "buffers" }
_state_mod.set_sections_for(_wskey, _target)
ok("set_sections_for round-trips into the namespace",
   vim.deep_equal(_state_mod.get_sections_for(_wskey), _target))

-- Force cfg.sections back to the default — simulate the post-
-- setup state where the seed-from-persisted branch missed.
_af.state.config.sections = vim.deepcopy(
  require("auto-finder.config").defaults.sections)
ok("cfg.sections forced back to default for the race simulation",
   #_af.state.config.sections == 3
     and _af.state.config.sections[#_af.state.config.sections] ~= "buffers")

-- Publish the topic worktree.nvim emits on first capture. The
-- v0.2.10 subscriber should pick this up and call
-- M._reseed_sections_for_workspace via vim.schedule.
_core.events.publish("core.workspace_root:changed", {
  from = nil, to = vim.fn.getcwd(),
})
-- Reseed schedules itself; wait until cfg.sections grows to target.
vim.wait(400, function()
  return #_af.state.config.sections == #_target
end, 20)
ok("cfg.sections reseeded to the persisted list after core.workspace_root:changed",
   vim.deep_equal(_af.state.config.sections, _target))

-- Restore: drop the persisted record (or replace with the prior
-- snapshot) and rebuild the registry back to the live default so
-- later sections don't see the leftover 'buffers' slot.
if _orig_persisted then
  _state_mod.set_sections_for(_wskey, _orig_persisted)
else
  _state_mod.set_sections_for(_wskey, nil)
end
_af._rebuild_section_registry(_orig_live)
end)()

-- ───────────────────────── 21. v0.2.11 — active-section gate + renderer winfixbuf-safe ────────────────────────
--
-- Two regression tests for v0.2.11:
--
--   (a) The buffers-refresh autocmd must NOT swap the panel buffer
--       when buffers isn't the active section. The v0.2.9 install
--       fired unconditionally and clobbered files/repos when the user
--       opened a file. The v0.2.11 gate checks
--       state.bufnr == nvim_win_get_buf(panel_winid).
--
--   (b) renderer.show_nodes' position=current branch must succeed
--       against a winfixbuf=true panel. Pre-v0.2.11 it raised E1513
--       inside scheduled callbacks (fs_scan's render_context).
print("\n[21] v0.2.11 — active-section gate + renderer winfixbuf-safe")
;(function()
local _af = require("auto-finder")

-- ── (a) active-section gate ─────────────────────────────────────
-- Ensure 'buffers' is registered; focus the CONFIG section (slot 0)
-- so buffers isn't active. Trigger a BufAdd. The v0.2.11 gate must
-- skip the refresh so the panel keeps showing config.
local _sections_by_name = require("auto-finder.sections")._by_name
if _sections_by_name["buffers"] == nil then
  _af.slot_add("buffers")
end
_af.open(true)
vim.wait(80)
local _focus_ok = _af.focus(0)  -- focus config; buffers is NOT active
vim.wait(200)
ok("focus(0) succeeded", _focus_ok)

local _panel = _af.state.panel_winid
local _panel_buf_pre = (_panel and vim.api.nvim_win_is_valid(_panel))
   and vim.api.nvim_win_get_buf(_panel) or -1
ok("panel shows config (active=" .. tostring(_af._registry.active) ..
   " ft=" .. tostring(_panel_buf_pre > 0 and vim.bo[_panel_buf_pre].filetype) .. ")",
   _af._registry.active == 0
     and _panel_buf_pre > 0
     and vim.bo[_panel_buf_pre].filetype == "auto-finder-config")

-- Open a probe file to trigger BufAdd. Pre-v0.2.11 this would swap
-- the panel to the buffers tree. The fix's gate must skip the
-- refresh so the panel keeps showing config.
local _probe = vim.fn.getcwd() .. "/tests/_v2_11_gate_probe.txt"
local _fh = io.open(_probe, "w"); _fh:write("x"); _fh:close()
vim.cmd("topleft split " .. vim.fn.fnameescape(_probe))
vim.wait(300)  -- debounce + scheduler

local _panel_buf_post =
   _panel and vim.api.nvim_win_is_valid(_panel)
     and vim.api.nvim_win_get_buf(_panel) or -1
-- The core regression we're fixing: panel shouldn't be swapped to
-- the BUFFERS source tree. The smoke env's leak guard may trigger
-- unrelated buffer movement during `:split`, but we specifically
-- assert the panel buf is NOT the buffers source's state.bufnr.
local _mgr_check = require("auto-finder.neotree.sources.manager")
local _buffers_state_bufnr = nil
for _, s in ipairs(_mgr_check._get_all_states()) do
  if s.name == "buffers" and s.winid == _panel then
    _buffers_state_bufnr = s.bufnr; break
  end
end
ok("panel did NOT swap to buffers source tree after BufAdd while config active "
   .. "(post=" .. _panel_buf_post .. " buffers-state-bufnr="
   .. tostring(_buffers_state_bufnr) .. " active="
   .. tostring(_af._registry.active) .. ")",
   _panel_buf_post ~= _buffers_state_bufnr)
ok("registry.active still 0 (config) — gate did not flip section",
   _af._registry.active == 0)

-- Cleanup probe.
pcall(vim.api.nvim_win_close, vim.api.nvim_get_current_win(), true)
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_get_name(b) == _probe then
    pcall(vim.api.nvim_buf_delete, b, { force = true })
  end
end
pcall(os.remove, _probe)

-- ── (b) renderer winfixbuf-safe ─────────────────────────────────
-- Build a minimal state with current_position="current", point it at
-- the panel window, and call renderer.show_nodes. Assert no error
-- and that winfixbuf is restored to true afterwards.
local _renderer = require("auto-finder.neotree.ui.renderer")
local _ok_renderer = type(_renderer) == "table"
   and type(_renderer.show_nodes) == "function"
ok("renderer.show_nodes accessible", _ok_renderer)

-- Switch to buffers so the panel hosts the buffers tree; show_nodes
-- is what the buffers-refresh path also calls. Use the
-- `_by_name` lookup again since slot indices may have shifted
-- across earlier sections' mutations.
local _buf_idx = require("auto-finder.sections")._by_name["buffers"]
ok("buffers slot still registered for part (b)", _buf_idx ~= nil)
if _buf_idx then
  _af.open(true)
  vim.wait(50)
  _af.focus(_buf_idx)
  vim.wait(200)
end
-- Re-read the panel winid — the prior `:topleft split` + leak guard
-- dance may have invalidated the earlier capture.
_panel = _af.state.panel_winid
local _panel_valid = _panel and vim.api.nvim_win_is_valid(_panel)
ok("panel winid valid for part (b) (panel=" .. tostring(_panel) .. ")",
   _panel_valid)
if not _panel_valid then return end
-- Panel currently has winfixbuf=true (set by auto-core.ui.panel).
local _wfb_before = vim.wo[_panel].winfixbuf
ok("winfixbuf=true on panel pre-render", _wfb_before == true)

-- Trigger a fresh render via the buffers items module — the call
-- pre-v0.2.11 raised E1513 because state.loading got stuck and/or
-- the swap was blocked. With the renderer patch (line 1230 winfixbuf
-- guard), it must complete cleanly.
local _items = require("auto-finder.neotree.sources.buffers.lib.items")
local _mgr = require("auto-finder.neotree.sources.manager")
local _live
for _, s in ipairs(_mgr._get_all_states()) do
  if s.name == "buffers" and s.winid == _panel then _live = s; break end
end
ok("buffers state found bound to panel winid for part (b)",
   _live ~= nil)
if _live then
  _live.loading = false
  local _ok, _err = pcall(_items.get_opened_buffers, _live)
  ok("get_opened_buffers against winfixbuf=true panel returns without error",
     _ok, tostring(_err))
end
local _wfb_after = vim.wo[_panel].winfixbuf
ok("winfixbuf restored to true after render (no protection drop)",
   _wfb_after == true)

-- Cleanup: remove buffers section if we added it.
local _last_idx = #_af.state.config.sections - 1
if _af.state.config.sections[#_af.state.config.sections] == "buffers" then
  _af.slot_remove(_last_idx)
end
end)()

-- ───────────────────── 21c. v0.2.13 — gate-skip dirty-bit round-trip ──────
-- v0.2.11's gate (covered in [21] above) correctly stops a BufAdd-
-- triggered refresh from clobbering an inactive panel section. But
-- its assumption that "next focus to buffers re-mounts fresh" was
-- wrong: section.get_buffer caches the section's bufnr across
-- focuses, so the buffers tree silently stays stale after a skipped
-- refresh.
--
-- v0.2.13 fix: gate-skip path sets `_af._buffers_dirty = true`; the
-- buffers section's `on_focus` hook (in `sections/buffers.lua`)
-- consumes the flag and runs `_refresh_buffers_now(panel_winid)`
-- inline so the just-refocused tree reflects every BufAdd that
-- happened while buffers was inactive.
--
-- Contract this section asserts:
--   (1) BufAdd-while-inactive sets the dirty bit.
--   (2) focus(buffers) clears the dirty bit AND the new buf appears
--       in the rendered tree.
--   (3) BufAdd-while-buffers-active clears (doesn't accumulate) the
--       dirty bit.
print("\n[21c] v0.2.13 — buffers-dirty-bit round-trip after gate-skip")
;(function()
local _af = require("auto-finder")

-- Need a buffers slot for this section.
local _sb_name = require("auto-finder.sections")._by_name
if _sb_name["buffers"] == nil then
  _af.slot_add("buffers")
end
local _buf_idx = require("auto-finder.sections")._by_name["buffers"]
ok("buffers slot registered for [21c]", _buf_idx ~= nil)

_af.open(true)
vim.wait(80)

-- Clean baseline: focus config (buffers NOT active).
_af.focus(0)
vim.wait(100)
ok("baseline: registry.active == 0 (config), buffers NOT active",
   _af._registry.active == 0)
-- Clean any prior dirty marker from earlier sections.
_af._buffers_dirty = false

-- (1) Open a probe file while buffers is INACTIVE. The autocmd-fire
-- gate must skip → `_buffers_dirty` should flip to true.
local _probe_dirty = vim.fn.getcwd() .. "/tests/_v2_13_dirty_probe.txt"
local _fh2 = io.open(_probe_dirty, "w"); _fh2:write("dirty-bit probe"); _fh2:close()
vim.cmd("topleft split " .. vim.fn.fnameescape(_probe_dirty))
vim.wait(300)  -- > 80ms debounce + scheduler
ok("BufAdd while buffers inactive flipped _buffers_dirty=true",
   _af._buffers_dirty == true,
   "got " .. tostring(_af._buffers_dirty))

-- Close the split so focus returns somewhere sensible; the probe
-- buffer remains in the buffer list with `buflisted=true`.
pcall(vim.api.nvim_win_close, vim.api.nvim_get_current_win(), true)

-- (2) Switch to buffers. The on_focus consumer must clear the flag
-- AND repopulate the tree with the probe buffer.
_af.focus(_buf_idx)
vim.wait(250)  -- focus + on_focus + refresh
ok("after focus(buffers): _buffers_dirty cleared",
   _af._buffers_dirty == false,
   "got " .. tostring(_af._buffers_dirty))

-- Verify the probe buffer is rendered in the buffers tree. The
-- rendered buffer is the section's cached bufnr; read its lines
-- and grep for the basename.
local _panel = _af.state.panel_winid
local _panel_buf_v213 =
   _panel and vim.api.nvim_win_is_valid(_panel)
     and vim.api.nvim_win_get_buf(_panel) or -1
local _lines = (_panel_buf_v213 > 0)
   and vim.api.nvim_buf_get_lines(_panel_buf_v213, 0, -1, false) or {}
local _saw_probe = false
for _, ln in ipairs(_lines) do
  if ln:find("_v2_13_dirty_probe", 1, true) then _saw_probe = true; break end
end
ok("buffers tree now contains the probe buf (regression: stale tree after gate-skip)",
   _saw_probe,
   "panel_buf=" .. tostring(_panel_buf_v213) .. " lines=" .. #_lines)

-- (3) Trigger another BufAdd while buffers IS active. The fire path
-- should refresh inline AND ensure the dirty bit stays cleared.
local _probe_active = vim.fn.getcwd() .. "/tests/_v2_13_active_probe.txt"
local _fh3 = io.open(_probe_active, "w"); _fh3:write("active probe"); _fh3:close()
vim.cmd("topleft split " .. vim.fn.fnameescape(_probe_active))
vim.wait(300)
ok("BufAdd while buffers active keeps _buffers_dirty=false (handled inline)",
   _af._buffers_dirty == false,
   "got " .. tostring(_af._buffers_dirty))
-- Close the split.
pcall(vim.api.nvim_win_close, vim.api.nvim_get_current_win(), true)

-- Cleanup probes.
for _, p in ipairs({ _probe_dirty, _probe_active }) do
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == p then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  pcall(os.remove, p)
end

-- Cleanup: remove the buffers section if we added it.
local _last_idx_v213 = #_af.state.config.sections - 1
if _af.state.config.sections[#_af.state.config.sections] == "buffers" then
  _af.slot_remove(_last_idx_v213)
end
end)()

-- ───────────────────── 21d. v0.2.14 — out-of-cwd buffers grouped as sibling roots ───
-- Out-of-cwd buffers used to be silently dropped by the buffers
-- source's `is_subpath(state.path, path)` check. v0.2.14 buckets
-- them by their natural external root (first segment after $HOME,
-- or first absolute segment) and renders each bucket as a sibling
-- top-level group (analogous to how TERMINALS already worked).
--
-- Contract:
--   (1) Open the buffers panel at cwd = ~/Source/Projects/...
--   (2) Load a buffer OUTSIDE cwd (e.g. /tmp/external-probe.md).
--   (3) Rendered panel contains a SECOND root header for the
--       external bucket (e.g. "/tmp") AND lists the probe file
--       under it.
--   (4) In-cwd behavior is unchanged: a cwd-relative buffer still
--       appears under the cwd root.
print("\n[21d] v0.2.14 — out-of-cwd buffers grouped as sibling roots")
;(function()
local _af = require("auto-finder")

-- Ensure a buffers section exists for this test.
local _sb_name = require("auto-finder.sections")._by_name
if _sb_name["buffers"] == nil then
  _af.slot_add("buffers")
end
local _buf_idx = require("auto-finder.sections")._by_name["buffers"]
ok("buffers slot registered for [21d]", _buf_idx ~= nil)

_af.open(true)
vim.wait(80)
_af.focus(_buf_idx)
vim.wait(200)

-- Load an EXTERNAL probe under /tmp (definitely outside cwd).
local _external_probe = "/tmp/_v2_14_external_probe.md"
local _fh4 = io.open(_external_probe, "w")
_fh4:write("# external probe\n"); _fh4:close()
vim.cmd("badd " .. vim.fn.fnameescape(_external_probe))
-- :badd doesn't load by default — force load so the
-- `is_loaded or show_unloaded` filter passes.
local _ext_bufnr = vim.fn.bufnr(_external_probe)
vim.fn.bufload(_ext_bufnr)
vim.wait(300)  -- BufAdd debounce + dirty-bit consumer

-- Force a refresh to make sure the latest state is rendered (the
-- panel may still be showing the pre-:badd snapshot if the autocmd
-- debounce hadn't elapsed yet under the test harness).
if type(_af._refresh_buffers_now) == "function" then
  _af._refresh_buffers_now(_af.state.panel_winid)
  vim.wait(100)
end

-- Inspect the rendered tree: must contain a SECOND root header
-- corresponding to the external bucket, AND the probe filename
-- under it.
local _panel = _af.state.panel_winid
local _panel_buf = (_panel and vim.api.nvim_win_is_valid(_panel))
  and vim.api.nvim_win_get_buf(_panel) or -1
local _lines = (_panel_buf > 0)
  and vim.api.nvim_buf_get_lines(_panel_buf, 0, -1, false) or {}

local _saw_external_header = false
local _saw_external_probe = false
for _, ln in ipairs(_lines) do
  -- Bucket header for /tmp would render as "/tmp" via
  -- fnamemodify(..., ":~"). The base render adds icons/decorations
  -- around it; the literal "/tmp" substring is the stable marker.
  if ln:find("/tmp", 1, true) then _saw_external_header = true end
  if ln:find("_v2_14_external_probe", 1, true) then
    _saw_external_probe = true
  end
end
ok("rendered tree includes the external bucket root (/tmp)",
   _saw_external_header,
   "panel_lines=" .. #_lines .. " sample=" .. vim.inspect(_lines))
ok("rendered tree includes the external probe file under its bucket",
   _saw_external_probe,
   "panel_lines=" .. #_lines)

-- The in-cwd path is also still working: drop a cwd-relative
-- probe and assert it appears too (regression guard for the
-- existing behavior).
local _cwd_probe = vim.fn.getcwd() .. "/tests/_v2_14_cwd_probe.txt"
local _fh5 = io.open(_cwd_probe, "w"); _fh5:write("cwd probe"); _fh5:close()
vim.cmd("badd " .. vim.fn.fnameescape(_cwd_probe))
vim.fn.bufload(vim.fn.bufnr(_cwd_probe))
vim.wait(300)
if type(_af._refresh_buffers_now) == "function" then
  _af._refresh_buffers_now(_af.state.panel_winid)
  vim.wait(100)
end
_panel_buf = (_panel and vim.api.nvim_win_is_valid(_panel))
  and vim.api.nvim_win_get_buf(_panel) or -1
_lines = (_panel_buf > 0)
  and vim.api.nvim_buf_get_lines(_panel_buf, 0, -1, false) or {}
local _saw_cwd_probe = false
for _, ln in ipairs(_lines) do
  if ln:find("_v2_14_cwd_probe", 1, true) then _saw_cwd_probe = true; break end
end
ok("regression: in-cwd buffer still appears under the cwd root",
   _saw_cwd_probe)

-- Cleanup.
for _, p in ipairs({ _external_probe, _cwd_probe }) do
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == p then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  pcall(os.remove, p)
end
local _last_idx_v214 = #_af.state.config.sections - 1
if _af.state.config.sections[#_af.state.config.sections] == "buffers" then
  _af.slot_remove(_last_idx_v214)
end
end)()

-- ───────────────────── 22. follow-mode hijacking protection ──────────────
-- Regression coverage for files-follow and repos-follow:
-- reveals must be gated to their active section, and repos-follow
-- must reveal the containing repo without replacing the editor window.
print("\n[22] follow-mode hijacking protection")

local tmp_hijack = vim.fn.getcwd() .. "/tests/hijack-test.txt"
vim.fn.writefile({ "hijack test" }, tmp_hijack)

local function assert_no_hijack(section_name, section_idx)
  local section = require("auto-finder.sections")._by_number[section_idx]
  ok(string.format("panel window still displays %s buffer (not hijacked)", section_name),
    vim.api.nvim_win_get_buf(af.state.panel_winid) == section._bufnr)
end

af.state.config.files.follow = true
if not require("auto-finder.sections")._by_name["buffers"] then
  af.slot_add("buffers")
end
local buffers_idx = require("auto-finder.sections")._by_name["buffers"]
af.focus(buffers_idx)
ok("focused buffers section for files-follow gate", af.state.section == buffers_idx)

local editor_win = nil
for _, w in ipairs(vim.api.nvim_list_wins()) do
  if w ~= af.state.panel_winid then
    editor_win = w
    break
  end
end
if not editor_win then
  vim.cmd("vsplit")
  editor_win = vim.api.nvim_get_current_win()
end
vim.api.nvim_set_current_win(editor_win)
vim.cmd("edit " .. vim.fn.fnameescape(tmp_hijack))
vim.wait(200)
assert_no_hijack("buffers", buffers_idx)
af.state.config.files.follow = false

af.state.config.repos.follow = true
af.focus(buffers_idx)
vim.api.nvim_set_current_win(editor_win)
vim.cmd("edit " .. vim.fn.fnameescape(tmp_hijack))
vim.wait(200)
assert_no_hijack("buffers", buffers_idx)

local core = require("auto-core")
local workspace_root = vim.fn.fnamemodify(vim.fn.getcwd(), ":h")
core.git.worktree.set_workspace_root(workspace_root)
local repos_mod = require("auto-finder.repos")
local orig_repos_load = repos_mod.load
repos_mod.load = function() return { vim.fn.getcwd() } end

local repos_idx = require("auto-finder.sections")._by_name["repos"]
local repos_section = require("auto-finder.sections")._by_number[repos_idx]
repos_section._bufnr = nil
af.state.section_buffers[repos_idx] = nil
af.focus(repos_idx)
ok("focused repos section for repos-follow reveal", af.state.section == repos_idx)

vim.api.nvim_set_current_win(editor_win)
ok("current window is an editor for repos-follow reveal",
  vim.api.nvim_get_current_win() ~= af.state.panel_winid)
vim.cmd("edit " .. vim.fn.fnameescape(tmp_hijack))
vim.wait(200)

ok("editor window still displays the test file (not hijacked by repos tree)",
  vim.api.nvim_win_get_buf(editor_win) == vim.fn.bufnr(tmp_hijack))
ok("panel window still displays repos buffer",
  vim.api.nvim_win_get_buf(af.state.panel_winid) == repos_section._bufnr)

local expected_repo_node = "auto-finder-repos://" .. vim.fn.getcwd()
local focused_repo_node = nil
do
  local mgr = require("auto-finder.neotree.sources.manager")
  for _, s in ipairs(mgr._get_all_states()) do
    if s.name == "auto-finder-repos" and s.winid == af.state.panel_winid then
      local node = s.tree and s.tree:get_node()
      focused_repo_node = node and node:get_id() or nil
      break
    end
  end
end
ok("repos-follow focused containing repo node",
  focused_repo_node == expected_repo_node,
  "expected " .. expected_repo_node .. ", got " .. tostring(focused_repo_node))

af.state.config.repos.follow = false
repos_mod.load = orig_repos_load
pcall(vim.cmd, "bwipeout " .. vim.fn.bufnr(tmp_hijack))
vim.fn.delete(tmp_hijack)

-- ───────────────────────── 23. dbase file/conn management ─────────────────────────
-- Exercises lua/auto-finder/sections/_dbase_files.lua: filesystem-backed
-- connection-file CRUD, pinned-active swap semantics, and admin REPL
-- dispatch routing for the new `dbase` verb. dbee is NOT required —
-- _reload_dbee soft-fails when dbee isn't loaded, and the durable
-- state-of-truth lives in plain JSON files we read back directly.
print("\n[23] dbase file/conn management")

-- XDG_STATE_HOME was overridden at the top of the driver, so
-- stdpath("state") points into our isolated tmpdir. Clean any
-- artifacts from earlier test sections that may have touched it
-- so [23a] sees a pristine dir.
local _dbase_state_dir = vim.fn.stdpath("state") .. "/auto-finder/dbase"
vim.fn.delete(_dbase_state_dir, "rf")

local files = require("auto-finder.sections._dbase_files")

-- [23a] state dir is created on first access; _active.json is
-- materialized as an empty JSON array.
ok("state_dir created on first call",
  vim.fn.isdirectory(files.state_dir()) == 1,
  "expected " .. _dbase_state_dir)
local active_p = files.active_path()
ok("active_path created _active.json on first call",
  vim.fn.filereadable(active_p) == 1, "expected file at " .. active_p)
ok("_active.json starts as a JSON array",
  (function()
    local f = io.open(active_p, "r")
    if not f then return false end
    local c = f:read("*a") or ""
    f:close()
    return c:match("^%s*%[%s*%]%s*$") ~= nil
  end)(), "expected '[]'")

-- [23b] new / list round-trip. `.json` is auto-appended; the
-- pinned _active.json is excluded from `list()`.
local _, new_err = files.new("work")
ok("dbase new 'work' creates work.json", new_err == nil, new_err)
local _, new_err2 = files.new("personal.json")
ok("dbase new 'personal.json' tolerates explicit .json suffix",
  new_err2 == nil, new_err2)
local listed = files.list()
local has_work, has_personal, has_active = false, false, false
for _, n in ipairs(listed) do
  if n == "work" then has_work = true end
  if n == "personal" then has_personal = true end
  if n == "_active" then has_active = true end
end
ok("list() contains 'work'", has_work)
ok("list() contains 'personal'", has_personal)
ok("list() excludes the pinned _active.json", not has_active)

-- [23c] `new` rejects duplicates so an accidental re-create doesn't
-- clobber a populated file.
local _, dup_err = files.new("work")
ok("dbase new rejects duplicate name",
  dup_err ~= nil and dup_err:match("already exists") ~= nil,
  tostring(dup_err))

-- [23d] normalize_name rejects path separators (security: don't let
-- `dbase new ../etc/passwd` escape the state dir).
local _, traverse_err = files.new("../escape")
ok("dbase new rejects path separators",
  traverse_err ~= nil and traverse_err:match("path separators") ~= nil,
  tostring(traverse_err))

-- [23e] load swaps _active.json content + persists current().
-- Pre-populate work.json with a real connection so the swap is
-- observable.
do
  local p = files.state_dir() .. "/work.json"
  local f = assert(io.open(p, "w+"))
  f:write('[{"name":"local-pg","type":"postgres","url":"postgres://u:p@h/db"}]')
  f:close()
end
local loaded, load_err = files.load("work")
ok("dbase load 'work' returns the basename",
  loaded == "work.json", "got " .. tostring(loaded))
ok("dbase load reports no error", load_err == nil, load_err)
ok("current() == 'work' after load", files.current() == "work")
local active_conns = files.connections()
ok("connections() returns work.json contents",
  #active_conns == 1 and active_conns[1].name == "local-pg",
  "got " .. vim.inspect(active_conns))

-- [23f] conn add appends to active + mirrors back into the named
-- file so the change is durable across future loads.
local add_ok, add_err = files.conn_add({
  name = "prod-pg", type = "postgres",
  url = "postgres://ro:x@prod/db",
})
ok("conn_add returns true", add_ok, add_err)
local after_add = files.connections()
ok("active file now has 2 connections", #after_add == 2,
  "got " .. tostring(#after_add))
do
  local f = assert(io.open(files.state_dir() .. "/work.json", "r"))
  local c = f:read("*a"); f:close()
  ok("conn_add mirrored into work.json",
    c:find("prod%-pg", 1, false) ~= nil, "work.json: " .. c)
end

-- [23g] conn add rejects duplicate name.
local _, dup_conn_err = files.conn_add({
  name = "prod-pg", type = "postgres", url = "postgres://u:p@h/db",
})
ok("conn_add rejects duplicate name",
  dup_conn_err ~= nil and dup_conn_err:match("already exists") ~= nil,
  tostring(dup_conn_err))

-- [23h] conn add validates required fields.
local _, no_url_err = files.conn_add({ name = "missing-url", type = "postgres" })
ok("conn_add requires url",
  no_url_err ~= nil and no_url_err:match("url") ~= nil,
  tostring(no_url_err))

-- [23i] conn rm removes by name from active + mirror.
local rm_ok, rm_err = files.conn_remove("prod-pg")
ok("conn_remove returns true", rm_ok, rm_err)
local after_rm = files.connections()
ok("active file is back to 1 connection after rm",
  #after_rm == 1, "got " .. tostring(#after_rm))
local _, rm_miss_err = files.conn_remove("does-not-exist")
ok("conn_remove rejects unknown name",
  rm_miss_err ~= nil and rm_miss_err:match("no such") ~= nil,
  tostring(rm_miss_err))

-- [23j] load can swap between files; _active.json reflects the new
-- file's contents and previous-file connections drop from the
-- drawer's view.
do
  local p = files.state_dir() .. "/personal.json"
  local f = assert(io.open(p, "w+"))
  f:write('[{"name":"home-sqlite","type":"sqlite","url":"/tmp/home.db"}]')
  f:close()
end
local _, swap_err = files.load("personal")
ok("load 'personal' succeeds", swap_err == nil, swap_err)
ok("current() == 'personal' after swap", files.current() == "personal")
local swapped = files.connections()
ok("active connections came from personal.json",
  #swapped == 1 and swapped[1].name == "home-sqlite",
  "got " .. vim.inspect(swapped))

-- [23k] remove() of the active file clears active marker + resets
-- _active.json to empty so the drawer doesn't keep stale entries.
local rm_active_ok, rm_active_err = files.remove("personal")
ok("remove() of active file succeeds", rm_active_ok, rm_active_err)
ok("current() is nil after removing the active file",
  files.current() == nil)
ok("_active.json reset to empty after removing active",
  #files.connections() == 0)

-- [23l] admin REPL dispatch routes the new verb without error.
-- We're not asserting the emit() output text — that's UX surface,
-- not contract. We assert that dispatch doesn't raise and that
-- side-effects on the filesystem match.
local admin = require("auto-finder.panel.admin")
admin.get_or_create_buffer()  -- materialize the prompt buffer
-- new via REPL
admin.dispatch("dbase new repl-created")
ok("`dbase new repl-created` produced repl-created.json on disk",
  vim.fn.filereadable(files.state_dir() .. "/repl-created.json") == 1)
-- ls via REPL — just exercise the code path.
local ls_ok = pcall(admin.dispatch, "dbase ls")
ok("`dbase ls` dispatches without raising", ls_ok)
-- rm via REPL
admin.dispatch("dbase rm repl-created")
ok("`dbase rm repl-created` removed the file",
  vim.fn.filereadable(files.state_dir() .. "/repl-created.json") == 0)
-- invalid subcommand emits an error line but does NOT raise.
local bad_ok = pcall(admin.dispatch, "dbase bogus")
ok("`dbase bogus` is rejected without raising", bad_ok)

-- [23m] completion candidates include `dbase` at the top level + the
-- expected sub-verbs.
local _, top_cands = admin._complete_at("", 0)
local has_dbase = false
for _, c in ipairs(top_cands) do
  if c == "dbase" then has_dbase = true; break end
end
ok("completion at root includes 'dbase'", has_dbase,
  "got " .. table.concat(top_cands, ", "))
local _, dbase_cands = admin._complete_at("dbase ", 6)
local sub_set = {}
for _, c in ipairs(dbase_cands) do sub_set[c] = true end
ok("completion after 'dbase ' includes new/ls/rm/load/conn",
  sub_set.new and sub_set.ls and sub_set.rm and sub_set.load and sub_set.conn,
  "got " .. table.concat(dbase_cands, ", "))
local _, conn_cands = admin._complete_at("dbase conn ", 11)
local conn_set = {}
for _, c in ipairs(conn_cands) do conn_set[c] = true end
ok("completion after 'dbase conn ' includes add/ls/rm",
  conn_set.add and conn_set.ls and conn_set.rm,
  "got " .. table.concat(conn_cands, ", "))

-- ───────────────────────── summary ────────────────────────
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
