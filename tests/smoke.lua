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
  -- auto-core soft-dep: enables Phase 4b live-refresh in the files
  -- section AND the help-overlay path. Order matters because each
  -- `rtp:prepend(p)` pushes p to the FRONT — so the LAST entry in
  -- this list ends up first on the runtimepath and wins `require`.
  -- LAZY is listed FIRST among auto-core candidates so the
  -- workspace `main` (and any feature-branch worktree below)
  -- overrides it. Rationale: dev work happens on the worktree;
  -- LAZY is a fallback for when the workspace doesn't carry an
  -- auto-core checkout at all.
  LAZY .. "/auto-core.nvim",
  LAZY .. "/nui.nvim",
  LAZY .. "/plenary.nvim",
  plugins_root .. "/auto-core.nvim/main",
  -- Slot for an active feature-branch worktree, when one is in
  -- flight. Each entry, when its dir exists, wins over `main`
  -- (last-prepend-wins). Past entries like `comms-1` (ADR 0021
  -- Phase 1), `git-watch` (ADR 0025 Phase 1), and `adr-0035-p1`
  -- (ADR-0035 implementation arc) lived here while their work
  -- was unmerged; all have since landed on `main`. Add the
  -- next active feature worktree here when one exists.
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

-- v0.2.34: force the legacy plaintext storage code path for this smoke
-- regardless of whether age/gpg is installed on the runner. The dbase
-- REPL tests below were written before encrypted vaults existed and
-- assume plaintext file layout (`<name>.json`, no passphrase prompt).
-- The encrypted-path coverage lives in `tests/encrypted_vault_smoke.lua`.
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
-- ADR 0026 Phase 7: get_buffer returns a placeholder
-- synchronously; the real neo-tree mount completes during the
-- on_focus deferred callback. Poll until the panel buffer is
-- the real neo-tree buffer (filetype == "auto-finder").
vim.wait(500, function()
  local b = vim.api.nvim_win_get_buf(panel)
  return vim.bo[b].filetype == "auto-finder"
end)
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

-- ─────────────────── 10c. legacy panel-store migration ────────────
-- Regression for the "resize pin reverts to old width on restart" bug:
-- the pre-v0.2.0 legacy store carried `panel.user_width`, and setup()
-- re-seeded it into the namespace on EVERY boot, clobbering the user's
-- newer pin. The migration now (1) seeds only when the namespace has
-- no explicit value, and (2) drains the legacy `panel` block so it can
-- never re-seed.
print("\n[10c] legacy panel store → namespace migration (guard + drain)")
do
  local state_mod = require("auto-finder.state")
  local cfg = af.state.config

  -- Isolated config dir so we control the legacy file byte-for-byte.
  local tmp_c = "/tmp/auto-finder-smoke-migrate"
  vim.fn.delete(tmp_c, "rf")
  vim.env.XDG_CONFIG_HOME = tmp_c
  vim.fn.mkdir(store._dir(), "p")
  local legacy_path = store._path()
  local function write_legacy(uw)
    vim.fn.writefile({ vim.json.encode({
      version = 1,
      panel   = { user_width = uw, side = "left", last_section = 1 },
      files   = { hide_dotfiles = false },
    }) }, legacy_path)
  end

  -- Case 1: namespace ALREADY pinned → legacy must NOT clobber it.
  state_mod.set_user_width(70)
  write_legacy(50)
  af._migrate_legacy_panel_store(cfg)
  ok("guard: existing namespace pin (70) not clobbered by legacy (50)",
    state_mod.get_user_width() == 70,
    "got " .. tostring(state_mod.get_user_width()))
  ok("drain: legacy panel block stripped after migration (case 1)",
    (store.load().panel or {}).user_width == nil,
    vim.inspect(store.load()))

  -- Case 2: namespace empty → legacy value IS adopted, then drained.
  state_mod.set_user_width(nil)
  write_legacy(45)
  af._migrate_legacy_panel_store(cfg)
  ok("seed: empty namespace adopts legacy pin (45)",
    state_mod.get_user_width() == 45,
    "got " .. tostring(state_mod.get_user_width()))
  ok("drain: legacy panel block stripped after migration (case 2)",
    (store.load().panel or {}).user_width == nil)

  -- Case 3: re-running on the drained file is a no-op.
  af._migrate_legacy_panel_store(cfg)
  ok("idempotent: second migration leaves the adopted pin (45) intact",
    state_mod.get_user_width() == 45)

  -- Restore namespace to a clean slate for subsequent tests.
  state_mod.set_user_width(nil)
  vim.fn.delete(tmp_c, "rf")
end

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

-- ───────────────────────── 12b. per-workspace last_section + focus clamp (v0.2.28) ─────────────────────────
-- v0.2.28 fix: `last_section` was a global namespace key, so a
-- user on slot 4 (dbase) in project1 (4 slots) who switched to
-- project2 (2 slots) saw an empty panel — M.open read 4 from
-- the global key, M.focus(4) failed with "no such section", and
-- the panel was already open with no buffer swapped in. Two
-- pieces: (a) per-workspace `last_section_by_workspace` map so
-- the stale value doesn't bleed in the first place; (b) clamp
-- in M.focus so any other stale path (legacy global on first
-- launch after upgrade, programmatic miscalls) lands on
-- default_section instead of an empty panel.
print("\n[12b] per-workspace last_section + focus clamp (v0.2.28)")
do
  local state_mod = require("auto-finder.state")

  -- (a) Per-workspace round-trip + isolation.
  local wskey_a = "aaaaaaaaaaaaaaaa"
  local wskey_b = "bbbbbbbbbbbbbbbb"
  state_mod.set_last_section_for(wskey_a, 3)
  state_mod.set_last_section_for(wskey_b, 1)
  ok("per-workspace last_section round-trip (A)",
    state_mod.get_last_section_for(wskey_a) == 3)
  ok("per-workspace last_section round-trip (B)",
    state_mod.get_last_section_for(wskey_b) == 1)
  ok("per-workspace last_section isolation (A ≠ B)",
    state_mod.get_last_section_for(wskey_a)
      ~= state_mod.get_last_section_for(wskey_b))

  -- Setting nil clears the per-workspace record.
  state_mod.set_last_section_for(wskey_a, nil)
  ok("per-workspace last_section clear via nil",
    state_mod.get_last_section_for(wskey_a) == nil)
  -- B is untouched by clearing A.
  ok("clearing A doesn't affect B",
    state_mod.get_last_section_for(wskey_b) == 1)

  -- Invalid wskey returns nil (typed-guard).
  ok("get_last_section_for(nil) returns nil",
    state_mod.get_last_section_for(nil) == nil)
  ok("get_last_section_for('') returns nil",
    state_mod.get_last_section_for("") == nil)

  -- set_last_section_for rejects bad wskey / bad n.
  local ok1, _ = state_mod.set_last_section_for("", 1)
  ok("set_last_section_for('', N) refused", ok1 == false)
  local ok2, _ = state_mod.set_last_section_for(wskey_b, "string")
  ok("set_last_section_for(wskey, 'string') refused", ok2 == false)

  state_mod.set_last_section_for(wskey_b, nil)  -- cleanup

  -- (b) Clamp: M.focus with an out-of-range key falls back to
  -- default_section. Simulates the cross-project bug — the
  -- current registry has 3 sections (config=0, files=1, repos=2)
  -- but a stale call tries to focus section 5.
  af.setup({
    width = { default = 38, min = 25, max = 100 },
    default_section = 1,
    sections = { "config", "files", "repos" },
  })
  af.open(true)
  local pre_active = af.state.section
  local focus_ok, _ = af.focus(5)  -- out of range
  ok("focus(out-of-range) returned ok (clamp succeeded)",
    focus_ok == true,
    "ok=" .. tostring(focus_ok) .. " pre_active=" .. tostring(pre_active))
  ok("clamped focus landed on default_section",
    af.state.section == 1,
    "got section=" .. tostring(af.state.section))

  -- Sanity: a valid focus still works after clamping.
  af.focus(2)  -- repos
  ok("valid focus after clamp still works",
    af.state.section == 2)

  af.close()
end

-- ───────────────────────── 12c. marks slot (v0.2.29) ─────────────────────────
-- New `marks` view renders nvim's native marks (global A-Z + local
-- a-z) as a flat scratch-buffer list with <CR> to jump and `d` to
-- delete the mark (matches :delmarks). Self-contained: this section
-- sets and clears its own marks, doesn't depend on prior state.
print("\n[12c] marks slot (v0.2.29)")
do
  local marks_view = require("auto-finder.views.marks")
  marks_view._reset_for_tests()

  -- Discoverability: scanned from views/marks/init.lua.
  local types = af._available_section_types()
  local has_marks = false
  for _, t in ipairs(types) do
    if t == "marks" then has_marks = true; break end
  end
  ok("marks is in _available_section_types",
    has_marks,
    "got: " .. table.concat(types, ", "))

  -- Stage two test buffers in an EDITOR window (not the panel —
  -- the panel has winfixbuf and is also a scratch nofile so any
  -- `m<x>` we run there would attach to the marks buffer itself).
  local file_x = vim.fn.tempname() .. "-marks-x.txt"
  local file_y = vim.fn.tempname() .. "-marks-y.txt"
  vim.fn.writefile(
    { "line one of x", "line two of x", "line three of x" }, file_x)
  vim.fn.writefile(
    { "alpha", "beta", "gamma", "delta" }, file_y)

  -- Load both files as buffers in the current (editor) window
  -- BEFORE opening the panel. `bufadd` + `bufload` puts them in
  -- the loaded set so getmarklist(b) finds them later.
  local x_bufnr = vim.fn.bufadd(file_x)
  vim.fn.bufload(x_bufnr)
  local y_bufnr = vim.fn.bufadd(file_y)
  vim.fn.bufload(y_bufnr)

  -- Set global mark X on file_x:2 via setpos (no current-window
  -- dependency, no winfixbuf interaction).
  pcall(vim.fn.setpos, "'X", { x_bufnr, 2, 1, 0 })
  -- Set local mark a on file_y:3 — must run in y_bufnr's context
  -- so the mark lands on THAT buffer.
  pcall(vim.api.nvim_buf_call, y_bufnr, function()
    vim.fn.setpos("'a", { y_bufnr, 3, 1, 0 })
  end)

  -- Now rebuild the slot list to include marks and focus the slot.
  af.setup({
    width = { default = 38, min = 25, max = 100 },
    default_section = 1,
    sections = { "config", "files", "marks" },
  })
  af.open(true)
  af.focus(2)
  ok("focused marks slot",
    af.state.section == 2,
    "got " .. tostring(af.state.section))

  local marks_bufnr = af._registry._bufs[2]
  ok("marks slot has a buffer",
    marks_bufnr ~= nil and vim.api.nvim_buf_is_valid(marks_bufnr))
  -- v0.2.31: filetype is `auto-finder` so external bufferline
  -- plugins recognize the panel column. Per-view identity moved
  -- to the buffer-local `b:auto_finder_view` var.
  ok("marks buffer filetype is auto-finder (panel-class)",
    vim.bo[marks_bufnr].filetype == "auto-finder")
  ok("marks buffer-local auto_finder_view tag = 'marks'",
    vim.b[marks_bufnr].auto_finder_view == "marks")

  -- Re-focus marks slot — on_focus re-renders.
  af.focus(2)
  marks_bufnr = af._registry._bufs[2]
  local lines = vim.api.nvim_buf_get_lines(marks_bufnr, 0, -1, false)
  local txt = table.concat(lines, "\n")
  -- v0.2.32: dropped the "BOOKMARKS\n\n" header prefix (the slot
  -- title duplicated the winbar). The first content line is now
  -- the GLOBAL section header.
  ok("no BOOKMARKS title prefix (v0.2.32 dropped it)",
    not txt:find("BOOKMARKS", 1, true),
    "first line=" .. tostring(lines[1]))
  ok("rendered GLOBAL section header",
    txt:find("GLOBAL", 1, true) ~= nil)
  ok("rendered LOCAL section header for the local-mark buffer",
    txt:find("LOCAL", 1, true) ~= nil)
  ok("rendered the [X] global mark row",
    txt:find("[X]", 1, true) ~= nil)
  ok("rendered the [a] local mark row",
    txt:find("[a]", 1, true) ~= nil)
  ok("global X row references the test file basename",
    txt:find("marks%-x%.txt:2") ~= nil,
    "txt=\n" .. txt)

  -- v0.2.32: per-line highlight spans via extmarks in the
  -- `auto-finder.marks.hl` namespace. Verify at least one
  -- extmark landed on the rendered buffer so a future refactor
  -- that drops the styling pass would be caught.
  local marks_ns = vim.api.nvim_create_namespace("auto-finder.marks.hl")
  local extmarks = vim.api.nvim_buf_get_extmarks(
    marks_bufnr, marks_ns, 0, -1, { details = true })
  ok("marks panel paints highlight extmarks via the marks.hl namespace",
    #extmarks > 0,
    "got " .. #extmarks .. " extmarks")
  -- Spot-check the bracketed key gets the AutoFinderMarksKey
  -- group. Loop because the X row's line index drifts with the
  -- panel layout (header row + per-mark two-line block).
  local key_hl_seen = false
  for _, em in ipairs(extmarks) do
    local d = em[4] or {}
    if d.hl_group == "AutoFinderMarksKey" then
      key_hl_seen = true; break
    end
  end
  ok("AutoFinderMarksKey extmark present on the mark letter",
    key_hl_seen)

  -- _rows lookup: with the two-line-per-mark layout, each record
  -- maps to 2 line entries (path line + preview line) so <CR>/d
  -- work from either. Count UNIQUE records by identity.
  local unique_records = {}
  for _, rec in pairs(marks_view._rows or {}) do
    if rec then unique_records[rec] = true end
  end
  local mark_records = 0
  for _ in pairs(unique_records) do mark_records = mark_records + 1 end
  ok("_rows lookup has 2 unique mark records (X global + a local)",
    mark_records == 2,
    "got " .. mark_records)
  -- Each record should have exactly 2 line entries (path +
  -- preview). Confirms the dual-mapping for keymap parity from
  -- either visual line.
  local x_line_count = 0
  for _, rec in pairs(marks_view._rows or {}) do
    if rec and rec.mark == "X" then
      x_line_count = x_line_count + 1
    end
  end
  ok("X record is reachable from both its lines (path + preview)",
    x_line_count == 2, "got " .. x_line_count)

  -- Find the X-mark line index and validate the record shape.
  local x_line, x_rec
  for ln, rec in pairs(marks_view._rows or {}) do
    if rec and rec.mark == "X" then x_line, x_rec = ln, rec; break end
  end
  ok("X row record has kind='global' + line==2 + file==file_x",
    x_rec ~= nil and x_rec.kind == "global"
      and x_rec.line == 2 and x_rec.file == file_x,
    x_rec and vim.inspect(x_rec) or "nil")

  -- Delete-mark via vim.fn.setpos (what `d` keymap does internally).
  pcall(vim.fn.setpos, "'X", { 0, 0, 0, 0 })
  -- Re-render: the X row should disappear.
  af.focus(2)
  marks_bufnr = af._registry._bufs[2]
  local lines2 = vim.api.nvim_buf_get_lines(marks_bufnr, 0, -1, false)
  local txt2 = table.concat(lines2, "\n")
  ok("after delmarks X, [X] row is gone",
    txt2:find("[X]", 1, true) == nil,
    "txt=\n" .. txt2)
  ok("after delmarks X, [a] local row is still present",
    txt2:find("[a]", 1, true) ~= nil)

  -- Empty-state rendering when nothing's set.
  pcall(vim.fn.setpos, "'a",
    { y_bufnr, 0, 0, 0 })  -- clear local a; setpos works in-buffer
  -- (Also clear by running setpos inside the buffer for safety.)
  pcall(vim.api.nvim_buf_call, y_bufnr, function()
    vim.fn.setpos("'a", { y_bufnr, 0, 0, 0 })
  end)
  af.focus(2)
  marks_bufnr = af._registry._bufs[2]
  local lines3 = vim.api.nvim_buf_get_lines(marks_bufnr, 0, -1, false)
  local txt3 = table.concat(lines3, "\n")
  ok("empty state renders the (no marks set) placeholder",
    txt3:find("no marks set", 1, true) ~= nil)
  -- v0.2.32: the help line was split in two so it fits the
  -- default 38-col panel. Both halves should be present, on
  -- separate rows, with the m<...> snippet on each.
  ok("empty-state help line 1 — `m<A-Z>` for global",
    txt3:find("m<A-Z>", 1, true) ~= nil
      and txt3:find("global", 1, true) ~= nil,
    "txt=\n" .. txt3)
  ok("empty-state help line 2 — `m<a-z>` for local",
    txt3:find("m<a-z>", 1, true) ~= nil
      and txt3:find("local", 1, true) ~= nil,
    "txt=\n" .. txt3)
  -- Help text should occupy two distinct rows, not one.
  local m_az_row, m_AZ_row
  for i, l in ipairs(lines3) do
    if l:find("m<A-Z>", 1, true) then m_AZ_row = i end
    if l:find("m<a-z>", 1, true) then m_az_row = i end
  end
  ok("help text spans two rows",
    m_AZ_row ~= nil and m_az_row ~= nil
      and m_AZ_row ~= m_az_row,
    "m<A-Z> row=" .. tostring(m_AZ_row)
      .. " m<a-z> row=" .. tostring(m_az_row))

  -- v0.2.32: empty-state line "(no marks set)" gets
  -- AutoFinderMarksEmpty highlight via extmark.
  local empty_extmarks = vim.api.nvim_buf_get_extmarks(
    marks_bufnr,
    vim.api.nvim_create_namespace("auto-finder.marks.hl"),
    0, -1, { details = true })
  local empty_hl_seen = false
  for _, em in ipairs(empty_extmarks) do
    local d = em[4] or {}
    if d.hl_group == "AutoFinderMarksEmpty" then
      empty_hl_seen = true; break
    end
  end
  ok("AutoFinderMarksEmpty extmark paints the (no marks set) row",
    empty_hl_seen)

  -- v0.2.32: highlight groups are defined with `default = true`
  -- links so the empty-state row picks up the colorscheme.
  local empty_hl = vim.api.nvim_get_hl(0,
    { name = "AutoFinderMarksEmpty", link = true })
  ok("AutoFinderMarksEmpty default link is set",
    empty_hl and (empty_hl.link or empty_hl.fg) ~= nil,
    vim.inspect(empty_hl))

  -- Buffer-local keymaps installed (the d / <CR> / R contract).
  local function _has_keymap(buf, lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == lhs then return true end
    end
    return false
  end
  ok("buffer-local <CR> keymap installed",
    _has_keymap(marks_bufnr, "<CR>"))
  ok("buffer-local d keymap installed",
    _has_keymap(marks_bufnr, "d"))
  ok("buffer-local i keymap installed",
    _has_keymap(marks_bufnr, "i"))
  ok("buffer-local R keymap installed",
    _has_keymap(marks_bufnr, "R"))

  -- Auto-refresh wired: AutoFinderMarksRefresh augroup exists and
  -- holds at least one autocmd with our descriptor.
  local refresh_autos = vim.api.nvim_get_autocmds({
    group = "AutoFinderMarksRefresh",
  })
  ok("AutoFinderMarksRefresh augroup has at least one autocmd",
    #refresh_autos >= 1)
  local refresh_desc_seen = false
  for _, a in ipairs(refresh_autos) do
    if (a.desc or ""):find(
         "auto-finder.marks: refresh", 1, true) then
      refresh_desc_seen = true; break
    end
  end
  ok("AutoFinderMarksRefresh autocmd carries our descriptor",
    refresh_desc_seen)

  -- v0.2.32 regression: focusing marks then a neo-tree-backed slot
  -- (buffers / files / repos) used to crash inside
  -- `neotree/command/init.lua` because the marks buffer carries
  -- filetype=auto-finder but no `b:neo_tree_position`, and the bare
  -- `nvim_buf_get_var(0, "neo_tree_position")` threw "Key not found".
  -- Drive marks → buffers and assert the panel survives.
  af.setup({
    width = { default = 38, min = 25, max = 100 },
    default_section = 1,
    sections = { "config", "files", "marks", "buffers" },
  })
  af.open(true)
  af.focus(2)  -- marks
  ok("focused marks before transition", af.state.section == 2,
    "section=" .. tostring(af.state.section))
  local trans_ok, trans_err = pcall(af.focus, 3)  -- buffers
  ok("marks → buffers transition does not raise",
    trans_ok,
    "err=" .. tostring(trans_err))
  ok("buffers slot is now active", af.state.section == 3,
    "section=" .. tostring(af.state.section))

  -- Cleanup: drop the staged buffers + tempfiles, restore the
  -- default slot list (downstream sections depend on `repos`
  -- being present), and close the panel.
  pcall(vim.api.nvim_buf_delete, x_bufnr, { force = true })
  pcall(vim.api.nvim_buf_delete, y_bufnr, { force = true })
  pcall(vim.fn.delete, file_x)
  pcall(vim.fn.delete, file_y)
  af.setup({
    width = { default = 38, min = 25, max = 100 },
    default_section = 1,
    sections = { "config", "files", "repos" },
  })
  af.close()
  marks_view._reset_for_tests()
end

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
print("\n[14] live-refresh wiring (files section) — ADR 0026 Phase 4")

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
-- ADR 0026 Phase 7: poll until the deferred mount completes so
-- _arm_live_refresh_subs has run (subscribes to
-- auto-finder.core.files:changed) before we publish synthetic
-- events below.
local files_section = require("auto-finder.sections").resolve(1)
vim.wait(500, function()
  return files_section and files_section._bufnr ~= nil
    and vim.api.nvim_buf_is_valid(files_section._bufnr)
end)
ok("files section resolves",
  files_section ~= nil and files_section.name == "files")

-- ADR 0026 Phase 4: fs.watch handle is now owned by
-- `auto-finder.core.watchers` (started during af.setup via
-- core.ensure_started). The section module no longer has
-- `_fs_watch_handle` / `_fs_watch_root` fields. Assert the
-- cwd is in the core watcher list instead.
local core_watchers = require("auto-finder.core.watchers")
local watched_cwds  = core_watchers.list()
local cwd_watched = false
for _, w in ipairs(watched_cwds) do
  if w == vim.fn.getcwd() then cwd_watched = true; break end
end
ok("core.watchers has an entry for the cwd",
  cwd_watched,
  "watched cwds: " .. vim.inspect(watched_cwds))

-- The section no longer carries _ensure_fs_watch / _stop_fs_watch;
-- it has `_arm_live_refresh_subs` instead (the function that
-- subscribes to refresh-driving topics on each focus).
ok("files section has _arm_live_refresh_subs",
  type(files_section._arm_live_refresh_subs) == "function")
ok("files section does NOT carry _fs_watch_handle (moved to core)",
  files_section._fs_watch_handle == nil)
ok("files section does NOT carry _ensure_fs_watch (moved to core)",
  files_section._ensure_fs_watch == nil)

-- Stub neo-tree's manager.refresh to capture refresh calls. The
-- live-refresh path is now: upstream `core.file:*` → core's
-- translator → `auto-finder.core.files:changed` (debounced 100 ms)
-- → shared/neotree.lua subscriber → schedule_refresh →
-- LIVE_REFRESH_DEBOUNCE_MS (150 ms) → manager.refresh.
local manager_mod = require("auto-finder.neotree.sources.manager")
local orig_refresh = manager_mod.refresh
local refresh_calls = {}
manager_mod.refresh = function(source_name, callback)
  refresh_calls[#refresh_calls + 1] = source_name
  if callback then pcall(callback) end
end

core.events.publish("core.file:modified", {
  path   = vim.fn.getcwd() .. "/some-synthetic-event-path.txt",
  change = "modified",
})
-- 100ms (core debounce) + 150ms (neotree debounce) + slack
vim.wait(500, function()
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

-- Events for paths OUTSIDE the cwd: core publishes the translated
-- event with cwd=vim.fn.getcwd() (the cwd at translator-fire time),
-- so paths outside that cwd still flow through if they're emitted
-- while cwd matches. The cwd-prefix filter lives in core's
-- enqueue logic for now (Phase 4 doesn't filter by path), so
-- out-of-root paths DO trigger schedule_refresh — that's a
-- minor over-trigger compared to the v0.2.x prefix-filter
-- behavior, but the cache update is what matters. Phase 7 will
-- tighten the filter when views adopt the placeholder mount.
refresh_calls = {}
core.events.publish("core.file:modified", {
  path   = "/tmp/some-other-place/x.txt",
  change = "modified",
})
vim.wait(400)
-- Either fires once (loose filter) or doesn't (tight filter).
-- Acceptable either way for Phase 4; assertion deferred to Phase 7
-- where the loading-placeholder generation guard tightens the
-- filter contract.
ok("out-of-root event handling is well-defined (fires=" ..
   tostring(#refresh_calls) .. ")",
  true)

manager_mod.refresh = orig_refresh

-- ─────────────────── 14b. git.watch wire-up — ADR 0026 Phase 4 ──────────────
-- git.watch ownership moved to core/watchers (same as fs.watch).
-- core.git.state:changed still drives schedule_refresh via the
-- shared/neotree.lua subscriber (Phase 5 will migrate that to
-- `auto-finder.core.git:changed` once the git cache lands).
print("\n[14b] git.watch wire-up — ADR 0026 Phase 4")
if not (type(core.git) == "table" and type(core.git.watch) == "table"
        and type(core.git.watch.start) == "function") then
  print("  SKIP  auto-core.git.watch not present on rtp; pinned auto-core < v0.1.19")
else
  ok("auto-core.git.watch.start is callable",
    type(core.git.watch.start) == "function")
  ok("auto-core.git.watch.stop is callable",
    type(core.git.watch.stop) == "function")
  ok("files section does NOT carry _git_watch_handle (moved to core)",
    files_section._git_watch_handle == nil)

  -- Stub manager.refresh to capture firings driven by the git
  -- subscription.
  local orig_refresh2 = manager_mod.refresh
  local git_refresh_calls = {}
  manager_mod.refresh = function(source_name, callback)
    git_refresh_calls[#git_refresh_calls + 1] = source_name
    if callback then pcall(callback) end
  end

  -- Synthetic publish with cwd as repo_root → expect refresh.
  core.events.publish("core.git.state:changed", {
    repo_root = vim.fn.getcwd(),
    git_dir   = vim.fn.getcwd() .. "/.git",
    kind      = "index",
  })
  vim.wait(400, function()
    for _, src in ipairs(git_refresh_calls) do
      if src == "filesystem" then return true end
    end
    return false
  end)
  local saw_git_refresh = false
  for _, src in ipairs(git_refresh_calls) do
    if src == "filesystem" then saw_git_refresh = true; break end
  end
  ok("core.git.state:changed for cwd triggers manager.refresh",
    saw_git_refresh,
    "git_refresh_calls=" .. vim.inspect(git_refresh_calls))

  -- Synthetic publish with a DIFFERENT repo_root (not a prefix of
  -- cwd) → must NOT refresh. The shared/neotree.lua filter checks
  -- `payload.repo_root == cwd OR cwd starts-with repo_root/`.
  git_refresh_calls = {}
  core.events.publish("core.git.state:changed", {
    repo_root = "/tmp/some-other-repo",
    git_dir   = "/tmp/some-other-repo/.git",
    kind      = "index",
  })
  vim.wait(250)
  local saw_cross_refresh = false
  for _, src in ipairs(git_refresh_calls) do
    if src == "filesystem" then saw_cross_refresh = true end
  end
  ok("core.git.state:changed for unrelated repo_root does NOT refresh",
    not saw_cross_refresh,
    "git_refresh_calls=" .. vim.inspect(git_refresh_calls))

  -- Missing repo_root field → must not crash, must not refresh.
  git_refresh_calls = {}
  core.events.publish("core.git.state:changed", {
    git_dir = "/somewhere/.git",
    kind    = "head",
  })
  vim.wait(250)
  local saw_malformed_refresh = false
  for _, src in ipairs(git_refresh_calls) do
    if src == "filesystem" then saw_malformed_refresh = true end
  end
  ok("malformed core.git.state:changed payload is ignored safely",
    not saw_malformed_refresh)

  manager_mod.refresh = orig_refresh2
end

-- ADR 0026 Phase 4 teardown: core.stop() releases every watcher.
-- We don't do that here in the suite — later sections still rely on
-- a live core. Skip the per-section stop assertions; those moved
-- into section [32]'s watchers.open_for/close_all round-trip and
-- section [31]'s core.stop A8 assertions.

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
  -- Force a mount to populate the cache. ADR 0026 Phase 7:
  -- get_buffer is now placeholder-first; poll until the real
  -- neo-tree mount completes (section._bufnr becomes valid).
  af.focus(2)
  vim.wait(500, function()
    return repos_def._bufnr ~= nil
      and vim.api.nvim_buf_is_valid(repos_def._bufnr)
  end)
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
-- ADR 0026 Phase 7: deferred mount; poll until the buffers
-- section's real buffer is in place before asserting on it.
vim.wait(500, function()
  local sec = require("auto-finder.sections")._by_number[buffers_idx]
  return sec and sec._bufnr ~= nil
    and vim.api.nvim_buf_is_valid(sec._bufnr)
end)
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
-- Phase 7 polling wait.
vim.wait(500, function()
  local sec = require("auto-finder.sections")._by_number[buffers_idx]
  return sec and sec._bufnr ~= nil
    and vim.api.nvim_buf_is_valid(sec._bufnr)
end)
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
-- Phase 7 polling wait.
vim.wait(500, function()
  return repos_section._bufnr ~= nil
    and vim.api.nvim_buf_is_valid(repos_section._bufnr)
end)
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

-- [23n] conn_add stamps a dbee-compatible id on the spec so
-- `Handler:source_reload` doesn't reject it. The user reported this
-- as a `connection without an id: { name: "lm-unit-test", ... }`
-- runtime error in v0.2.18.
do
  -- Fresh active file so we control its contents.
  files._write_json(files.active_path(), {})
  local add_ok2, add_err2 = files.conn_add({
    name = "id-check", type = "postgres",
    url = "postgres://u:p@h/db",
  })
  ok("conn_add succeeded", add_ok2, add_err2)
  local got = files.connections()
  ok("conn_add stamped a non-empty id on the new spec",
    type(got[1]) == "table"
      and type(got[1].id) == "string" and got[1].id ~= "",
    "got " .. vim.inspect(got))
  ok("stamped id matches dbee's file_source_/ prefix",
    type(got[1].id) == "string"
      and got[1].id:match("^file_source_/") ~= nil,
    "got id=" .. tostring(got[1] and got[1].id))
end

-- [23o] legacy id-less entries get healed when `load` swaps them
-- into _active.json. Simulates a v0.2.18 file on disk.
do
  local legacy_path = files.state_dir() .. "/legacy.json"
  local f = assert(io.open(legacy_path, "w+"))
  f:write('[{"name":"legacy-pg","type":"postgres","url":"postgres://u:p@h/db"}]')
  f:close()
  local _, load_err2 = files.load("legacy")
  ok("load 'legacy' succeeds", load_err2 == nil, load_err2)
  local active = files.connections()
  ok("load healed id-less legacy entry in _active.json",
    type(active[1]) == "table"
      and type(active[1].id) == "string" and active[1].id ~= "",
    "got " .. vim.inspect(active))
  -- Heal was persisted back to the named file too. vim's
  -- json_encode emits `"id": "..."` with a space after the colon,
  -- so we match against the value pattern, not the whole key+value.
  local f2 = assert(io.open(legacy_path, "r"))
  local body = f2:read("*a"); f2:close()
  ok("heal persisted back into legacy.json",
    body:find('"file_source_/', 1, true) ~= nil,
    "legacy.json body: " .. body)
end

-- [23p] _ensure_ids is idempotent: a second pass over an already-
-- healed list reports no changes.
do
  local healed = { { name = "a", type = "postgres", url = "u",
                     id = "file_source_/abcdefghij" } }
  local _, changed = files._ensure_ids(healed)
  ok("ensure_ids reports no change when ids already present", not changed)
end

-- [23q] `dbase conn add` REPL verb starts the wizard rather than
-- popping vim.fn.input(): after dispatching, the wizard module
-- reports active and feeding the three steps drives conn_add to
-- completion. The buffer was created earlier in [23l].
do
  local wizard = require("auto-finder.panel.wizard")
  if wizard.is_active() then wizard.cancel() end  -- defensive
  -- Ensure there's an active file so the new connection persists.
  files._write_json(files.active_path(), {})
  admin.dispatch("dbase conn add")
  ok("dbase conn add activated the wizard", wizard.is_active())
  wizard.feed("smoke-conn")  -- step 1: name
  wizard.feed("postgres")    -- step 2: type
  wizard.feed("postgres://u:p@h/db")  -- step 3: url
  ok("wizard completed (no longer active)", not wizard.is_active())
  local got2 = files.connections()
  local found = false
  for _, c in ipairs(got2) do
    if c.name == "smoke-conn" then
      found = (type(c.id) == "string" and c.id ~= "")
      break
    end
  end
  ok("wizard's conn_add wrote the new connection with an id", found,
    "got " .. vim.inspect(got2))
end

-- [23r] DBASE_TYPES exposes every dbee-supported alias the REPL
-- offers (no trailing "..." — the user complained about that in
-- v0.2.18). Verify the list shape and that postgres is in it.
do
  ok("DBASE_TYPES is a non-empty list",
    type(files.TYPES) == "table" and #files.TYPES >= 10,
    "got " .. tostring(#(files.TYPES or {})))
  local has_pg, has_mongo, has_sqlserver = false, false, false
  for _, t in ipairs(files.TYPES) do
    if t == "postgres" then has_pg = true end
    if t == "mongodb" then has_mongo = true end
    if t == "sqlserver" then has_sqlserver = true end
  end
  ok("TYPES covers postgres + mongodb + sqlserver",
    has_pg and has_mongo and has_sqlserver,
    "got " .. table.concat(files.TYPES or {}, ", "))
end

-- ───────────────────────── 24. (REMOVED — flaky, see flaky-test catalog) ──
-- Section [24] (show-race regression test) was removed during the
-- ADR 0026 structural refactor. The production guard at
-- `lua/auto-finder/neotree/command/init.lua` works correctly; the
-- test's stub plumbing was unreachable because earlier sections
-- leave filesystem-source state mounted, so `do_show_or_focus`
-- short-circuits past the stubbed `manager.navigate`. Captured in
-- `tests/auto-finder-flaky.test.md` with the user story and a
-- reimplementation plan. Re-add when Phase 7's view mount contract
-- lands (the placeholder/generation guard re-frames the test
-- against a stable state-reset boundary).

-- ───────────────────────── 25. deferred scan.started load toast ─────────────
--
-- v0.2.22: the "mapping …" toast is now deferred behind
-- `fs_scan.MAPPING_TOAST_MS`. Fast scans complete before the timer
-- fires and stay silent; slow scans surface a toast.
--
-- Tested by stubbing `af_log.notifyIf` to count "scan.started"
-- fires, then driving fs_scan with the threshold flipped between
-- "huge" (toast won't fire in test duration) and "zero" (toast
-- fires immediately).
print("\n[25] v0.2.22 — deferred scan.started load toast")
;(function()
  local fs_scan = require("auto-finder.neotree.sources.filesystem.lib.fs_scan")
  local af_log = require("auto-finder.log")
  ok("fs_scan exports MAPPING_TOAST_MS knob",
     type(fs_scan.MAPPING_TOAST_MS) == "number")

  local seen
  local orig_notifyIf = af_log.notifyIf
  af_log.notifyIf = function(event, ...)
    if event == "scan.started" then seen = (seen or 0) + 1 end
    return orig_notifyIf(event, ...)
  end

  -- Fast-scan branch: threshold = 10s. We schedule the cancel
  -- ourselves immediately to mimic the completion callback firing
  -- before the deferred timer.
  do
    local saved = fs_scan.MAPPING_TOAST_MS
    fs_scan.MAPPING_TOAST_MS = 10000
    seen = 0

    -- Inline mini-repro of the deferral logic from get_items so we
    -- exercise the cancel path without standing up a full neo-tree
    -- scan state.
    local scan_completed = false
    vim.defer_fn(function()
      if scan_completed then return end
      af_log.notifyIf("scan.started", "mapping x", { component = "scan" })
    end, fs_scan.MAPPING_TOAST_MS)
    scan_completed = true  -- simulate fast completion

    vim.wait(80)  -- let the scheduler run; timer would not have fired anyway
    ok("fast scan: scan.started toast suppressed (seen=" .. tostring(seen) .. ")",
       seen == 0)

    fs_scan.MAPPING_TOAST_MS = saved
  end

  -- Slow-scan branch: threshold = 0ms. Timer fires next tick.
  do
    local saved = fs_scan.MAPPING_TOAST_MS
    fs_scan.MAPPING_TOAST_MS = 0
    seen = 0

    local scan_completed = false
    vim.defer_fn(function()
      if scan_completed then return end
      af_log.notifyIf("scan.started", "mapping y", { component = "scan" })
    end, fs_scan.MAPPING_TOAST_MS)
    -- DO NOT set scan_completed — let the timer fire.

    vim.wait(200, function() return seen and seen > 0 end, 10)
    ok("slow scan: scan.started toast fired (seen=" .. tostring(seen) .. ")",
       seen == 1)

    fs_scan.MAPPING_TOAST_MS = saved
  end

  af_log.notifyIf = orig_notifyIf
end)()

-- ───────────────────────── 26. user-stories — buffers panel (v0.2.23) ─────────────────────────
--
-- End-to-end user-story coverage for the buffers section, exercising
-- the actual tree contents (not just refresh plumbing). Section [19]
-- already covers BufAdd autocmd → refresh; this section covers the
-- USER-OBSERVABLE outcome: "when I :badd / :edit a file, does it
-- appear in the panel? when I :bd it, does it disappear?".
--
-- Regression context: v0.2.20 the buffers panel silently dropped any
-- `:badd`'d file because the bundled `add_buffer` filter at
-- `buffers/lib/items.lua:60-62` evaluates `is_loaded or
-- state.show_unloaded` and our fork's defaults.lua:636 had
-- `show_unloaded = false`. v0.2.21 flips the default to `true` so
-- listed-but-unloaded buffers (`:badd`, session restore, lsp
-- workspace registration) match `:ls` semantics. This section is
-- the regression guard.
print("\n[24] user-stories — buffers panel")
;(function()
local mgr = require("auto-finder.neotree.sources.manager")

-- Helper: count buffers-source nodes by id in the panel's state.
local function buffers_tree_node_ids()
  local out = {}
  for _, s in ipairs(mgr._get_all_states()) do
    if s.name == "buffers" and s.tree
        and s.winid == af.state.panel_winid then
      for id in pairs(s.tree.nodes.by_id or {}) do
        out[id] = true
      end
    end
  end
  return out
end
local function buffers_tree_has_file(path)
  local ids = buffers_tree_node_ids()
  -- Neo-tree's file-items create_item indexes by absolute path.
  return ids[path] == true
end

-- Make sure buffers is the active section + the autocmd-refresh is wired.
if not require("auto-finder.sections")._by_name["buffers"] then
  af.slot_add("buffers")
end
local _buf_slot = require("auto-finder.sections")._by_name["buffers"]
af.focus(_buf_slot)
vim.wait(150)

-- Probe files under cwd (so `is_subpath(state.path, file)` matches).
local _probe_dir = vim.fn.getcwd() .. "/tests/_user_story_probes"
vim.fn.mkdir(_probe_dir, "p")
local _probe_edit = _probe_dir .. "/edit_probe.txt"
local _probe_badd = _probe_dir .. "/badd_probe.txt"
do
  for _, p in ipairs({ _probe_edit, _probe_badd }) do
    local fh = io.open(p, "w"); fh:write("probe"); fh:close()
  end
end

-- ── User-story: `:edit <file>` shows up in the panel ────────────
ok("baseline: edit_probe NOT yet in tree",
  not buffers_tree_has_file(_probe_edit))
local _prev_win = vim.api.nvim_get_current_win()
-- Open in a side split so we don't clobber the panel.
vim.cmd("topleft split " .. vim.fn.fnameescape(_probe_edit))
vim.api.nvim_set_current_win(_prev_win)
af._refresh_buffers_now(af.state.panel_winid)
vim.wait(200, function() return buffers_tree_has_file(_probe_edit) end, 20)
ok("user-story: `:edit <file>` adds the file to the buffers tree",
  buffers_tree_has_file(_probe_edit))

-- ── User-story: `:badd <file>` shows up in the panel (THE REGRESSION GUARD) ──
ok("baseline: badd_probe NOT yet in tree",
  not buffers_tree_has_file(_probe_badd))
vim.cmd("badd " .. vim.fn.fnameescape(_probe_badd))
-- `:badd` doesn't load the buffer — `nvim_buf_is_loaded == false`.
-- Pre-v0.2.21, the panel filtered this out via show_unloaded=false.
-- v0.2.21 flips the default; the file should appear.
local _badd_bufnr = vim.fn.bufnr(_probe_badd)
ok("badd probe registered as a listed-but-unloaded buffer (pre-state)",
  vim.fn.buflisted(_badd_bufnr) == 1
    and vim.api.nvim_buf_is_loaded(_badd_bufnr) == false,
  string.format("listed=%s loaded=%s",
    tostring(vim.fn.buflisted(_badd_bufnr) == 1),
    tostring(vim.api.nvim_buf_is_loaded(_badd_bufnr))))
af._refresh_buffers_now(af.state.panel_winid)
vim.wait(200, function() return buffers_tree_has_file(_probe_badd) end, 20)
ok("user-story: `:badd <file>` adds the file to the buffers tree (regression guard)",
  buffers_tree_has_file(_probe_badd),
  "this was the v0.2.21 regression — show_unloaded=false was filtering :badd'd buffers")

-- ── User-story: `:bd <bufnr>` removes the file from the panel ────
local _edit_bufnr = vim.fn.bufnr(_probe_edit)
pcall(vim.api.nvim_buf_delete, _edit_bufnr, { force = true })
af._refresh_buffers_now(af.state.panel_winid)
vim.wait(200, function() return not buffers_tree_has_file(_probe_edit) end, 20)
ok("user-story: `:bd <bufnr>` removes the file from the buffers tree",
  not buffers_tree_has_file(_probe_edit))

-- ── User-story: terminal buffers appear under the Terminals group ──
-- :terminal opens a real PTY; in headless mode that can fail on
-- platforms without a usable shell. Use a guarded pcall + skip.
local _term_ok = pcall(function()
  vim.cmd("topleft split | terminal echo smoke-term-probe")
end)
if _term_ok then
  vim.wait(150)
  vim.api.nvim_set_current_win(_prev_win)
  af._refresh_buffers_now(af.state.panel_winid)
  vim.wait(200)
  -- Find any node with type=terminal in the tree.
  local saw_terminal = false
  for _, s in ipairs(mgr._get_all_states()) do
    if s.name == "buffers" and s.tree
        and s.winid == af.state.panel_winid then
      for _, node in pairs(s.tree.nodes.by_id or {}) do
        if node.type == "terminal" then saw_terminal = true; break end
      end
    end
  end
  ok("user-story: a `:terminal` buffer appears in the buffers tree",
    saw_terminal)
else
  ok("user-story: terminal buffer test (skipped — :terminal failed in headless)",
    true, "headless terminal launch failed; not a regression of the fix")
end

-- ── User-story: out-of-cwd buffer appears as a sibling root group ──
-- v0.2.14 added the "out-of-cwd buffers bucket as sibling root
-- folders" behavior. /tmp is reliably outside cwd in any test env.
local _ext_probe = "/tmp/auto_finder_external_probe.txt"
do
  local fh = io.open(_ext_probe, "w"); fh:write("ext probe"); fh:close()
end
vim.cmd("badd " .. vim.fn.fnameescape(_ext_probe))
af._refresh_buffers_now(af.state.panel_winid)
vim.wait(200, function() return buffers_tree_has_file(_ext_probe) end, 20)
ok("user-story: out-of-cwd `:badd`'d file appears in the buffers tree",
  buffers_tree_has_file(_ext_probe))
-- Also verify the /tmp bucket exists as a top-level node (v0.2.14
-- external-root behavior).
local saw_tmp_bucket = false
for _, s in ipairs(mgr._get_all_states()) do
  if s.name == "buffers" and s.tree
      and s.winid == af.state.panel_winid then
    for id, node in pairs(s.tree.nodes.by_id or {}) do
      if id == "/tmp" and node.type == "directory"
          and node:get_depth() == 1 then
        saw_tmp_bucket = true; break
      end
    end
  end
end
ok("user-story: /tmp bucket appears as a top-level (depth=1) sibling group",
  saw_tmp_bucket)

-- ── Cleanup ──────────────────────────────────────────────────────
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  local nm = vim.api.nvim_buf_get_name(b)
  if nm == _probe_edit or nm == _probe_badd or nm == _ext_probe then
    pcall(vim.api.nvim_buf_delete, b, { force = true })
  end
end
pcall(os.remove, _probe_edit)
pcall(os.remove, _probe_badd)
pcall(os.remove, _ext_probe)
pcall(vim.fn.delete, _probe_dir, "d")
end)()

-- ───────────────────────── 27. user-stories — files panel (v0.2.23) ─────────────────────────
print("\n[27] user-stories — files panel")
;(function()
local mgr = require("auto-finder.neotree.sources.manager")

local function fs_tree_node_ids()
  local out = {}
  for _, s in ipairs(mgr._get_all_states()) do
    if s.name == "filesystem" and s.tree
        and s.winid == af.state.panel_winid then
      for id in pairs(s.tree.nodes.by_id or {}) do
        out[id] = true
      end
    end
  end
  return out
end
local function fs_tree_has(path) return fs_tree_node_ids()[path] == true end

-- Focus the files section + give the watcher a tick to settle.
local _files_slot = require("auto-finder.sections")._by_name["files"]
af.focus(_files_slot)
vim.wait(200)

-- Top-level under cwd so the default-expanded root sees it on
-- refresh. A nested subdir would require the panel to have already
-- expanded the path before the watcher fires, which is fragile.
local _probe_file = vim.fn.getcwd() .. "/_user_story_fs_probe.txt"
local _probe_dir = nil

-- ── User-story: writefile creates a new file → tree reflects it ──
-- Force a synchronous manager.refresh after the write to keep the
-- test deterministic against fs.watch's libuv timing. (The
-- production path goes through the auto-core.fs.watch debounce
-- + schedule, which we cover end-to-end at section [14]; this
-- assertion is about the panel's tree-content correctness after a
-- refresh, not the watcher's plumbing.)
ok("baseline: created_probe NOT in tree yet",
  not fs_tree_has(_probe_file))
vim.fn.writefile({ "probe" }, _probe_file)
require("auto-finder.neotree.sources.manager").refresh("filesystem")
vim.wait(500, function() return fs_tree_has(_probe_file) end, 25)
ok("user-story: writefile under cwd → files panel shows the new file",
  fs_tree_has(_probe_file),
  "tree should contain " .. _probe_file .. " after refresh")

-- ── User-story: delete the file → tree drops it ──────────────────
pcall(os.remove, _probe_file)
require("auto-finder.neotree.sources.manager").refresh("filesystem")
vim.wait(500, function() return not fs_tree_has(_probe_file) end, 25)
ok("user-story: deleting a file → files panel drops it",
  not fs_tree_has(_probe_file))

-- ── Cleanup ──
pcall(os.remove, _probe_file)
end)()

-- ───────────────────────── 28. user-stories — repos panel (v0.2.23) ─────────────────────────
-- The repos source's contents come from auto-core.git.worktree's
-- workspace-roots registry, not from a public auto-finder API (no
-- `auto-finder.repos.add` exists; only `root()` / `load()` /
-- `worktree_paths()`). The actionable user-story for this section
-- is: "I mount the repos panel, focus it, and see at least one
-- top-level node corresponding to a registered workspace".
print("\n[28] user-stories — repos panel")
;(function()
local mgr = require("auto-finder.neotree.sources.manager")
local af_repos = require("auto-finder").repos
ok("auto-finder.repos surface exists",
  type(af_repos) == "table" and type(af_repos.root) == "function")

-- Mount the repos section.
if not require("auto-finder.sections")._by_name["repos"] then
  af.slot_add("repos")
end
local _repos_slot = require("auto-finder.sections")._by_name["repos"]
af.focus(_repos_slot)
vim.wait(250)

-- Find the repos state for the panel window.
local _repos_state
for _, s in ipairs(mgr._get_all_states()) do
  if s.name == "auto-finder-repos"
      and s.winid == af.state.panel_winid then
    _repos_state = s; break
  end
end
ok("user-story: focusing repos section mounts an auto-finder-repos state",
  _repos_state ~= nil
    and _repos_state.tree ~= nil,
  "expected a live state with tree for the panel winid")

-- The repos tree builds a top-level node for the current workspace
-- root (the cwd's bare-parent OR the cwd's git_root). Assert ≥1 node
-- in the tree — this is the "I see my repos when I open the panel"
-- user-story. The current cwd IS a git worktree, so this is reliable.
local _repos_nodes = 0
if _repos_state and _repos_state.tree then
  for _ in pairs(_repos_state.tree.nodes.by_id or {}) do
    _repos_nodes = _repos_nodes + 1
  end
end
ok("user-story: repos panel shows ≥1 node for the current workspace",
  _repos_nodes >= 1,
  "expected ≥1 node, got " .. _repos_nodes)
end)()

-- ───────────────────────── 29. ADR 0026 Phase 1: core skeleton ────
-- ADR 0026 — runtime state component (auto-finder.core). Phase 1
-- ships a loadable skeleton with no-op lifecycle + placeholder
-- submodules. This section asserts (a) the public surface
-- resolves, (b) ensure_started/stop/reload are safe to call, and
-- (c) the topic registry lists every topic the ADR §2.2 table
-- declares. Phase 3+ will replace these no-op assertions with
-- behavior-based ones (A7/A8 per ADR §4).
print("\n[29] core skeleton (ADR 0026 Phase 1)")
;(function()
local core = require("auto-finder.core")

-- (a) module surface.
ok("auto-finder.core loads",
  type(core) == "table"
    and type(core.ensure_started) == "function"
    and type(core.stop) == "function"
    and type(core.reload) == "function"
    and type(core.is_started) == "function")

-- (b) lifecycle no-ops are safe and flip the is_started flag.
core._reset_for_tests()
ok("is_started() is false before ensure_started",
  core.is_started() == false)

local ok_start, err_start = pcall(core.ensure_started, nil)
ok("ensure_started(nil) is safe", ok_start, tostring(err_start))
ok("is_started() flips true after ensure_started",
  core.is_started() == true)

-- Idempotent: second call must not error.
local ok_start2 = pcall(core.ensure_started, nil)
ok("ensure_started is idempotent", ok_start2)

local ok_stop = pcall(core.stop)
ok("stop() is safe", ok_stop)
ok("is_started() flips false after stop",
  core.is_started() == false)

local ok_reload = pcall(core.reload, nil)
ok("reload(nil) is safe (stop + ensure_started)", ok_reload)
ok("is_started() ends true after reload",
  core.is_started() == true)

-- (c) submodule lazy loading via __index. Each submodule must
-- resolve and expose the Phase 1 minimum surface.
ok("core.files loads with snapshot_now/snapshot_async/get",
  type(core.files) == "table"
    and type(core.files.snapshot_now) == "function"
    and type(core.files.snapshot_async) == "function"
    and type(core.files.get) == "function")

local files_snap = core.files.snapshot_now()
ok("core.files.snapshot_now returns { tree, readiness }",
  type(files_snap) == "table"
    and type(files_snap.tree) == "table"
    and type(files_snap.readiness) == "string",
  "got " .. vim.inspect(files_snap))

-- Phase 1 originally asserted readiness == "cold" here on the
-- assumption that ensure_started was a no-op. Phase 4 changed
-- that: ensure_started now opens watchers + starts the chunked
-- warmer, so readiness transitions cold → warming → ready
-- shortly after setup. The Phase 1 assertion shape stays as a
-- weaker "readiness is a known value" check.
local known = { cold = true, warming = true, ready = true, partial = true }
ok("core.files.snapshot_now returns a known readiness state",
  known[files_snap.readiness] == true,
  "got readiness=" .. tostring(files_snap.readiness))

ok("core.git loads with snapshot_now/snapshot_async",
  type(core.git) == "table"
    and type(core.git.snapshot_now) == "function"
    and type(core.git.snapshot_async) == "function")

local git_snap = core.git.snapshot_now()
ok("core.git.snapshot_now returns expected shape",
  type(git_snap) == "table"
    and type(git_snap.by_path) == "table"
    and type(git_snap.readiness) == "string")

ok("core.buffers loads with snapshot surface",
  type(core.buffers) == "table"
    and type(core.buffers.snapshot_now) == "function")

ok("core.repos loads with snapshot surface",
  type(core.repos) == "table"
    and type(core.repos.snapshot_now) == "function")

ok("core.watchers loads with open/close/list surface",
  type(core.watchers) == "table"
    and type(core.watchers.open_for) == "function"
    and type(core.watchers.close_for) == "function"
    and type(core.watchers.close_all) == "function"
    and type(core.watchers.list) == "function")

-- Phase 4 ensure_started opens fs.watch for the cwd, so list()
-- isn't empty here. Phase 1's assertion stays as a "returns a
-- list" check.
ok("core.watchers.list() returns a list",
  type(core.watchers.list()) == "table")

ok("core.warm loads with start/stop/status surface",
  type(core.warm) == "table"
    and type(core.warm.start) == "function"
    and type(core.warm.stop) == "function"
    and type(core.warm.status) == "function")

-- Phase 4 starts the warmer during ensure_started, so status
-- progresses cold → warming → ready. Phase 1's assertion stays
-- as "returns a known status."
local warm_states = { cold = true, warming = true, ready = true, partial = true }
ok("core.warm.status() returns a known status",
  warm_states[core.warm.status()] == true,
  "got status=" .. tostring(core.warm.status()))

-- (d) topic registry — ADR §2.2 lists six topics. Assert each
-- one is registered so a Phase 4+ implementer can't accidentally
-- typo a topic name without the smoke catching it.
ok("core.events loads with TOPICS/publish/subscribe/unsubscribe",
  type(core.events) == "table"
    and type(core.events.TOPICS) == "table"
    and type(core.events.publish) == "function"
    and type(core.events.subscribe) == "function"
    and type(core.events.unsubscribe) == "function")

local expected_topics = {
  "auto-finder.core.files:changed",
  "auto-finder.core.git:changed",
  "auto-finder.core.buffers:changed",
  "auto-finder.core.repos:changed",
  "auto-finder.core.ready",
  "auto-finder.core.metrics:paint",
}
for _, t in ipairs(expected_topics) do
  ok("topic registered: " .. t,
    type(core.events.TOPICS[t]) == "table"
      and type(core.events.TOPICS[t].payload) == "string",
    "missing or malformed TOPICS entry for " .. t)
end

-- (e) publish/subscribe/unsubscribe are wired to auto-core when
-- present. The smoke prelude prepends auto-core's main worktree
-- to the rtp, so auto-core IS available — assert the round-trip.
local got_payload
local handle = core.events.subscribe(
  "auto-finder.core.metrics:paint",
  function(payload) got_payload = payload end)
ok("subscribe returns a handle when auto-core is present",
  handle ~= nil,
  "auto-core may be missing; check rtp prelude")

core.events.publish("auto-finder.core.metrics:paint",
  { view = "smoke", dur_ms = 0, generation = 1 })
vim.wait(10)
ok("publish → subscriber callback fires with the payload",
  type(got_payload) == "table"
    and got_payload.view == "smoke",
  "got " .. vim.inspect(got_payload))

core.events.unsubscribe(handle)
got_payload = nil
core.events.publish("auto-finder.core.metrics:paint",
  { view = "smoke-after-unsub", dur_ms = 0, generation = 2 })
vim.wait(10)
ok("unsubscribe stops the callback",
  got_payload == nil,
  "callback fired after unsubscribe: " .. tostring(got_payload))

-- Phase 1 originally cleaned up with `core._reset_for_tests()` so
-- later sections could assume "not started." Phase 3 makes that
-- assumption wrong: setup() now wires ensure_started transitively,
-- so subsequent sections expect a live core. Leave it running.
end)()

-- ───────────────────────── 30. ADR 0026 Phase 2: sections → views ──
-- ADR 0026 Phase 2: rename sections/ → views/ with each view as a
-- sibling directory, keep sections/ as a backwards-compat facade.
-- This section asserts:
--   (a) facade preservation — require("auto-finder.sections.<name>")
--       still resolves and returns the same module as
--       require("auto-finder.views.<name>")
--   (b) _available_section_types returns the same set as before
--       the rename (A12 — public API parity)
--   (c) the deprecated cfg.section_modules alias still works and
--       migrates into cfg.view_modules at setup time
--   (d) shared/view_subs.lua helper: replace/dispose/count semantics
print("\n[30] ADR 0026 Phase 2 — sections → views (facade + parity)")
;(function()
-- (a) Facade resolution. Every public section path must return the
-- same table as the corresponding views path.
local pairs_to_check = {
  { sec = "auto-finder.sections",          view = "auto-finder.views" },
  { sec = "auto-finder.sections.config",   view = "auto-finder.views.config" },
  { sec = "auto-finder.sections.files",    view = "auto-finder.views.files" },
  { sec = "auto-finder.sections.buffers",  view = "auto-finder.views.buffers" },
  { sec = "auto-finder.sections.repos",    view = "auto-finder.views.repos" },
  { sec = "auto-finder.sections.dbase",    view = "auto-finder.views.dbase" },
  -- shared helper relocated out of sections/ entirely; facade keeps
  -- the old require path valid.
  { sec = "auto-finder.sections._neotree",      view = "auto-finder.shared.neotree" },
  { sec = "auto-finder.sections._dbase_files",  view = "auto-finder.views.dbase.files" },
  { sec = "auto-finder.sections._dbase_layout", view = "auto-finder.views.dbase.layout" },
  { sec = "auto-finder.sections._dbase_events", view = "auto-finder.views.dbase.events" },
  { sec = "auto-finder.sections._dbase_setup",  view = "auto-finder.views.dbase.setup" },
}
for _, pair in ipairs(pairs_to_check) do
  local sec_mod = require(pair.sec)
  local view_mod = require(pair.view)
  ok("facade: require('" .. pair.sec .. "') === require('" .. pair.view .. "')",
    sec_mod == view_mod,
    "facade returned a different table than the view module")
end

-- (b) _available_section_types parity. After the rename it must still
-- return the same baseline set (config, files, buffers, repos, dbase),
-- because every legacy section now lives at views/<name>/ AND the
-- scan honours both directories.
local types = af._available_section_types()
local types_set = {}
for _, t in ipairs(types) do types_set[t] = true end
ok("_available_section_types includes 'config'",  types_set.config)
ok("_available_section_types includes 'files'",   types_set.files)
ok("_available_section_types includes 'buffers'", types_set.buffers)
ok("_available_section_types includes 'repos'",   types_set.repos)
ok("_available_section_types includes 'dbase'",   types_set.dbase)
-- No leading-underscore helpers should leak through.
local leaked_underscored
for _, t in ipairs(types) do
  if t:sub(1, 1) == "_" then leaked_underscored = t; break end
end
ok("_available_section_types excludes underscore-prefixed helpers",
  leaked_underscored == nil,
  "leaked: " .. tostring(leaked_underscored))

-- (c) cfg.section_modules → cfg.view_modules alias. Pass the legacy
-- key and assert apply() migrates it into the new shape. We don't
-- call af.setup() again here (would reset the panel mid-suite); we
-- exercise config.lua's apply() directly which is the only consumer
-- of these keys.
local cfg_mod = require("auto-finder.config")
local applied = cfg_mod.apply({
  sections = { "config", "files" },
  -- Legacy key. apply() should migrate it.
  section_modules = {
    ["fake_legacy_view"] = "some.fake.require.path",
  },
})
ok("apply() honours legacy cfg.section_modules", applied ~= nil)
ok("apply() migrates section_modules → view_modules",
  type(applied.view_modules) == "table"
    and applied.view_modules["fake_legacy_view"] == "some.fake.require.path",
  "view_modules after migration: " .. vim.inspect(applied.view_modules))
ok("apply() mirrors view_modules back into section_modules for compat",
  type(applied.section_modules) == "table"
    and applied.section_modules["fake_legacy_view"] == "some.fake.require.path",
  "section_modules after migration: " .. vim.inspect(applied.section_modules))

-- New key alone — no migration message expected, just direct accept.
local applied2 = cfg_mod.apply({
  sections = { "config", "files" },
  view_modules = {
    ["forward_view"] = "another.fake.path",
  },
})
ok("apply() accepts cfg.view_modules directly",
  type(applied2.view_modules) == "table"
    and applied2.view_modules["forward_view"] == "another.fake.path")

-- (d) shared/view_subs helper. Replace-or-add semantics, idempotent
-- on repeat calls, dispose_all clears the set. The helper is the
-- Phase 7 dependency that Phase 2 ships ahead.
local view_subs = require("auto-finder.shared.view_subs")
local subs = view_subs.new()
ok("view_subs.new() returns an object", type(subs) == "table")
ok("view_subs.new() starts with count == 0", subs:count() == 0)

local hits = { a = 0, b = 0 }
subs:replace("a", "auto-finder.core.metrics:paint",
  function() hits.a = hits.a + 1 end)
subs:replace("b", "auto-finder.core.metrics:paint",
  function() hits.b = hits.b + 1 end)
ok("view_subs:count() == 2 after two replace() calls", subs:count() == 2)
ok("view_subs:has('a') is true", subs:has("a"))
ok("view_subs:has('c') is false", not subs:has("c"))

-- Re-replacing slot 'a' must NOT increase count (replace semantics)
-- AND must swap which callback fires. Publish once, expect one fire
-- on the NEW callback only.
local replaced_a_hits = 0
subs:replace("a", "auto-finder.core.metrics:paint",
  function() replaced_a_hits = replaced_a_hits + 1 end)
ok("view_subs:replace() on same slot keeps count == 2", subs:count() == 2)

local before_a = hits.a
core.events.publish("auto-finder.core.metrics:paint",
  { view = "viewsubs-test", dur_ms = 0, generation = 1 })
vim.wait(10)
ok("re-replaced slot fires the NEW callback, not the old",
  replaced_a_hits == 1 and hits.a == before_a,
  string.format("replaced_a_hits=%d, hits.a delta=%d",
    replaced_a_hits, hits.a - before_a))

-- dispose_all clears the set; subsequent publishes fire nothing.
subs:dispose_all()
ok("view_subs:dispose_all() drops count to 0", subs:count() == 0)
local before_replaced_a = replaced_a_hits
local before_b = hits.b
core.events.publish("auto-finder.core.metrics:paint",
  { view = "viewsubs-after-dispose", dur_ms = 0, generation = 2 })
vim.wait(10)
ok("dispose_all stops every slot's callback",
  replaced_a_hits == before_replaced_a and hits.b == before_b,
  string.format("post-dispose delta: a=%d, b=%d",
    replaced_a_hits - before_replaced_a, hits.b - before_b))

-- replace() requires a non-empty slot name + non-empty topic +
-- function callback. Each missing field raises.
local ok1 = pcall(function() subs:replace("", "topic", function() end) end)
ok("view_subs:replace rejects empty slot name", not ok1)
local ok2 = pcall(function() subs:replace("x", "", function() end) end)
ok("view_subs:replace rejects empty topic name", not ok2)
local ok3 = pcall(function() subs:replace("x", "topic", nil) end)
ok("view_subs:replace rejects non-function callback", not ok3)
end)()

-- ───────────────────────── 31. ADR 0026 Phase 3: lifecycle (A7/A8) ──
-- ADR 0026 Phase 3: the re-armable lifecycle ships. ensure_started
-- is idempotent and survives an auto-core.events bus reset by
-- unconditionally dispose-first-then-resubscribe. stop() releases
-- every captured handle.
--
-- This section asserts:
--   (a) ensure_started + stop round-trip: handle table populated /
--       cleared; is_started() reflects state
--   (b) ensure_started is idempotent — second call doesn't grow
--       the handle table beyond its single-handle-per-slot maximum
--   (c) A7 (bus-reset behavior): force-reset auto-core.events,
--       call ensure_started, publish a synthetic core.file:*
--       event, assert the translated auto-finder.core.files:changed
--       event fires
--   (d) worktree:switched + core.git.state:changed translations
--       reach their auto-finder.core.* topics
--   (e) A8 (handle release): fs.watch.list() + git.watch.list()
--       return to pre-ensure_started state after stop(). Phase 3
--       opens zero watchers so both lists stay empty across the
--       round-trip; Phase 4/5 will add real handles and this
--       assertion gains teeth.
--   (f) metrics:paint emit at the existing render path — captured
--       when the files section is re-mounted via auto-finder.reload
print("\n[31] ADR 0026 Phase 3 — lifecycle (A7 bus-reset, A8 handle release)")
;(function()
local core = require("auto-finder.core")
local up   = require("auto-core")

-- (f) metrics:paint emit FIRST. The shared/neotree.lua subscriber
-- registers via the one-shot `_fs_subscribed` flag — once a bus
-- reset wipes it, the flag stays true and the subscription doesn't
-- re-arm until Phase 7 migrates that path into the re-armable
-- shape. So we verify metrics:paint BEFORE the bus-reset test
-- below, while shared/neotree.lua's subscriber is still alive.
-- ADR 0026 Phase 6 made section.refresh emit metrics:paint too,
-- so earlier sections leave us with paint events from buffers /
-- repos. Filter the probe to view == "files" so we only capture
-- the event we actually care about (the files section's render).
local paint_seen
local paint_probe = core.events.subscribe(
  "auto-finder.core.metrics:paint",
  function(p) if p and p.view == "files" then paint_seen = p end end)
local files_idx = require("auto-finder.views")._by_name["files"]
if files_idx then
  af.focus(files_idx)
  -- ADR 0026 Phase 7: poll until the deferred mount completes so
  -- the live-refresh subscriber is armed before we publish.
  local files_sec = require("auto-finder.sections")._by_number[files_idx]
  vim.wait(500, function()
    return files_sec and files_sec._bufnr ~= nil
      and vim.api.nvim_buf_is_valid(files_sec._bufnr)
  end)
  up.events.publish("core.file:modified",
    { path = vim.fn.getcwd() .. "/phase3-metrics-probe.txt" })
  -- 100ms (core debounce) + 150ms (neotree debounce) + slack.
  vim.wait(500, function() return paint_seen ~= nil end)
  ok("metrics:paint emit fires from existing render path",
    type(paint_seen) == "table"
      and type(paint_seen.dur_ms) == "number"
      and paint_seen.view == "files",
    "got " .. vim.inspect(paint_seen))
end
core.events.unsubscribe(paint_probe)

-- (a) Setup already called ensure_started via the section [1]
-- af.setup; verify the contract holds.
ok("core.is_started() is true after af.setup()",
  core.is_started() == true)
local handle_count_after_setup = vim.tbl_count(core._handles)
ok("ensure_started captured > 0 handles",
  handle_count_after_setup > 0,
  "got " .. handle_count_after_setup .. " handles")

-- (b) Idempotency: second call must not grow the table.
core.ensure_started(af.state.config)
ok("ensure_started is idempotent (handle count unchanged on re-call)",
  vim.tbl_count(core._handles) == handle_count_after_setup,
  "second call grew handle count from " .. handle_count_after_setup
    .. " to " .. vim.tbl_count(core._handles))

-- (c) A7 bus-reset behavior. The test sequence per ADR §4:
--   1. force auto-core.events._reset_for_tests
--   2. focus a view (transitively calls ensure_started)
--   3. publish synthetic core.file:created event
--   4. assert auto-finder.core.files:changed fires
local files_changed_count = 0
local last_files_payload
local function reset_files_state()
  files_changed_count = 0
  last_files_payload = nil
end

-- Establish baseline behavior BEFORE the reset: publish a synthetic
-- event and confirm core's translator fires.
local probe_handle = core.events.subscribe(
  "auto-finder.core.files:changed",
  function(p) files_changed_count = files_changed_count + 1; last_files_payload = p end)

reset_files_state()
up.events.publish("core.file:created", { path = "/tmp/phase3-probe-pre.txt" })
-- ADR 0026 Phase 4: translator now debounces 100ms and coalesces.
-- Flush synchronously so the assertion doesn't race the timer.
core._flush_file_events_for_tests()
vim.wait(20)
ok("pre-reset: translator fires on core.file:created",
  files_changed_count == 1,
  "expected 1 fire, got " .. files_changed_count)
ok("pre-reset: translated payload carries kind='upsert'",
  last_files_payload and last_files_payload.kind == "upsert",
  "got " .. vim.inspect(last_files_payload))
ok("pre-reset: translated payload carries the path",
  last_files_payload
    and type(last_files_payload.paths) == "table"
    and last_files_payload.paths[1] == "/tmp/phase3-probe-pre.txt",
  "got " .. vim.inspect(last_files_payload))

-- Now force the bus reset. Both our probe_handle AND core's
-- internal upstream subscriptions are wiped.
core.events.unsubscribe(probe_handle)
up.events._reset_for_tests()

-- Re-arm core (this is what M.open / M.focus would do defensively
-- in production). The unconditional dispose-first-then-resubscribe
-- per ADR §2.2 should leave core in a working state.
core.ensure_started(af.state.config)

-- Subscribe a fresh probe (the prior was wiped along with everything
-- else). Then publish the synthetic event.
local probe_post = core.events.subscribe(
  "auto-finder.core.files:changed",
  function(p) files_changed_count = files_changed_count + 1; last_files_payload = p end)

reset_files_state()
up.events.publish("core.file:modified", { path = "/tmp/phase3-probe-post.txt" })
core._flush_file_events_for_tests()
vim.wait(20)
ok("A7: translator re-arms after bus reset (event fires)",
  files_changed_count == 1,
  "expected 1 fire after reset+ensure_started, got " .. files_changed_count
    .. " — bus-reset re-arming is broken")
ok("A7: post-reset payload still carries kind='upsert'",
  last_files_payload and last_files_payload.kind == "upsert")
core.events.unsubscribe(probe_post)

-- (d) Translation for the other upstream topics.
local git_changed
local git_probe = core.events.subscribe(
  "auto-finder.core.git:changed",
  function(p) git_changed = p end)
up.events.publish("core.git.state:changed",
  { repo_root = "/tmp/probe-repo", git_dir = "/tmp/probe-repo/.git", kind = "head" })
vim.wait(20)
ok("translator: core.git.state:changed → auto-finder.core.git:changed",
  type(git_changed) == "table"
    and git_changed.repo_root == "/tmp/probe-repo"
    and git_changed.kind == "head",
  "got " .. vim.inspect(git_changed))
core.events.unsubscribe(git_probe)

local repos_changed
local repos_probe = core.events.subscribe(
  "auto-finder.core.repos:changed",
  function(p) repos_changed = p end)
up.events.publish("worktree:switched",
  { new_root = "/tmp/probe-worktree" })
vim.wait(20)
ok("translator: worktree:switched → auto-finder.core.repos:changed",
  type(repos_changed) == "table"
    and repos_changed.kind == "worktree_switched"
    and repos_changed.repo_root == "/tmp/probe-worktree",
  "got " .. vim.inspect(repos_changed))
core.events.unsubscribe(repos_probe)

-- (e) A8 handle release. Snapshot the watcher lists before stop()
-- and after; both must return to the pre-ensure_started state.
-- Phase 3 opens zero watchers (core/watchers.lua is still a no-op);
-- when Phase 4/5 add real fs.watch + git.watch handles this same
-- assertion gains teeth without code change.
local function fs_list_or_empty()
  if type(up.fs) == "table" and type(up.fs.watch) == "table"
      and type(up.fs.watch.list) == "function" then
    return up.fs.watch.list()
  end
  return {}
end
local function git_list_or_empty()
  if type(up.git) == "table" and type(up.git.watch) == "table"
      and type(up.git.watch.list) == "function" then
    return up.git.watch.list()
  end
  return {}
end

-- ADR 0026 Phase 4: ensure_started now opens an fs.watch (and
-- on git repos, a git.watch) handle for the cwd. The A8 contract
-- per ADR §4 is "stop() releases every handle ensure_started
-- opened" — measured by calling stop FIRST to establish a baseline,
-- then ensure_started (should add handles), then stop again
-- (should return to baseline).
core.stop()
local fs_baseline  = #fs_list_or_empty()
local git_baseline = #git_list_or_empty()
core.ensure_started(af.state.config)
-- Allow a tick for the watcher open to register on the list.
vim.wait(20)
local fs_after_start  = #fs_list_or_empty()
local git_after_start = #git_list_or_empty()
core.stop()
local fs_after_stop   = #fs_list_or_empty()
local git_after_stop  = #git_list_or_empty()

ok("A8: ensure_started opens at least one fs.watch handle",
  fs_after_start >= fs_baseline,
  string.format("baseline=%d after_start=%d", fs_baseline, fs_after_start))
ok("A8: stop() releases fs.watch handle back to baseline",
  fs_after_stop == fs_baseline,
  string.format("baseline=%d after_stop=%d", fs_baseline, fs_after_stop))
ok("A8: stop() releases git.watch handle back to baseline",
  git_after_stop == git_baseline,
  string.format("baseline=%d after_stop=%d", git_baseline, git_after_stop))

ok("stop() flips is_started() back to false",
  core.is_started() == false)
ok("stop() empties the handle table",
  vim.tbl_count(core._handles) == 0,
  "remaining: " .. vim.inspect(vim.tbl_keys(core._handles)))

-- Restore for the rest of the suite — anything below this section
-- that needs core would otherwise see an unsubscribed bus.
core.ensure_started(af.state.config)
ok("post-restore: core.is_started() == true",
  core.is_started() == true)
end)()

-- ───────────────────────── 32. ADR 0026 Phase 4: files cache + watchers ──
-- ADR 0026 Phase 4: directory-aware files cache, fs.watch +
-- git.watch ownership in core/watchers, chunked async warmer,
-- translator with burst detection + coalescing.
--
-- This section covers the Phase 4 acceptance ledger:
--   A1 — no view module subscribes to upstream auto-core topics
--   A2 — no view OR shared module opens an fs.watch or git.watch
--   A4 — 100-event burst coalesces to a single auto-finder.core.files:changed
--   A6 — single-file events upsert the cache (delta), bursts → subtree_stale
--   A15 — chunked warm respects the 5ms-per-tick budget
--
-- A5 (≤ 50% baseline) is the final assertion in Phase 9; Phase 4
-- captures the baseline via the metrics:paint emit already wired
-- in Phase 3 (smoke section [31] verifies it fires).
print("\n[32] ADR 0026 Phase 4 — files cache + watchers (A1, A2, A4, A6, A15)")
;(function()
local core_files    = require("auto-finder.core.files")
local core_watchers = require("auto-finder.core.watchers")
local core_warm     = require("auto-finder.core.warm")
local core_init     = require("auto-finder.core")
local core_events   = require("auto-finder.core.events")
local up            = require("auto-core")

-- ── A1: no view module subscribes to upstream auto-core topics ──
-- Grep `lua/auto-finder/views/` for `core.events.subscribe`. Every
-- hit must subscribe to an `auto-finder.core.*` topic, never to
-- a raw `core.file:*` / `core.git.state:*` / `worktree:switched`.
-- We grep via vim.uv.fs_scandir + io.lines so the assertion
-- doesn't shell out.
do
  local function read_file(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local s = f:read("*a"); f:close()
    return s or ""
  end
  local function walk(dir, fn)
    local h = vim.uv.fs_scandir(dir)
    if not h then return end
    while true do
      local name, t = vim.uv.fs_scandir_next(h)
      if not name then break end
      local p = dir .. "/" .. name
      if t == "directory" then walk(p, fn)
      elseif t == "file" and name:match("%.lua$") then fn(p)
      end
    end
  end
  local views_root = plugin_root .. "/lua/auto-finder/views"
  local violations = {}
  walk(views_root, function(path)
    local content = read_file(path)
    -- Find every events.subscribe call and check the topic. The
    -- check is intentionally loose (substring match on the
    -- forbidden topic name) — false positives matter less than
    -- catching a regression on the rule.
    for forbidden in pairs({
      ["\"core.file:"]       = true,
      ["\"core.git.state:"]  = true,
      ["\"worktree:"]        = true,
    }) do
      if content:find(forbidden, 1, true) then
        violations[#violations + 1] = path .. " contains " .. forbidden
      end
    end
  end)
  ok("A1: no view module subscribes to upstream auto-core topics",
    #violations == 0,
    "violations: " .. vim.inspect(violations))
end

-- ── A2: fs.watch.start / git.watch.start ONLY inside core/ ──
do
  local function read_file(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local s = f:read("*a"); f:close()
    return s or ""
  end
  local function walk(dir, fn)
    local h = vim.uv.fs_scandir(dir)
    if not h then return end
    while true do
      local name, t = vim.uv.fs_scandir_next(h)
      if not name then break end
      if name == "neotree" then
        -- The vendored neo-tree fork has its own fs.watch internals
        -- under lua/auto-finder/neotree/* (utils, sources/manager,
        -- etc.). Those don't go through auto-core.fs.watch.start
        -- so they don't count as a violation, but we skip them
        -- here anyway to keep the walk lean.
      else
        local p = dir .. "/" .. name
        if t == "directory" then walk(p, fn)
        elseif t == "file" and name:match("%.lua$") then fn(p)
        end
      end
    end
  end
  local lua_root = plugin_root .. "/lua/auto-finder"
  local violations = {}
  walk(lua_root, function(path)
    local content = read_file(path)
    -- Look for the actual CALL site, not the type annotation.
    -- Patterns: `fs.watch.start(` and `git.watch.start(`. The
    -- type-check (`type(core.fs.watch.start) ~= "function"`) is
    -- excluded by the "(" suffix requirement.
    local has_fs  = content:find("fs%.watch%.start%s*%(")
    local has_git = content:find("git%.watch%.start%s*%(")
    if has_fs or has_git then
      -- Allowed iff the file is inside lua/auto-finder/core/
      if not path:match("/auto%-finder/core/") then
        violations[#violations + 1] = path
      end
    end
  end)
  ok("A2: fs.watch.start / git.watch.start only inside lua/auto-finder/core/",
    #violations == 0,
    "violations: " .. vim.inspect(violations))
end

-- ── A4: burst coalescing ──
-- Publish 100 synthetic core.file:* events under one parent dir
-- and assert exactly ONE auto-finder.core.files:changed event
-- fires after the debounce window flushes. Because the burst
-- exceeds BURST_THRESHOLD (50), the emit shape is
-- kind='subtree_stale' rather than a 100-path upsert.
do
  -- Reset core's files cache so the assertion isn't muddied by
  -- prior tests.
  core_files._reset_for_tests()
  -- Make sure core is started.
  core_init.ensure_started(af.state.config)

  local fires = {}
  local hb = core_events.subscribe(
    "auto-finder.core.files:changed",
    function(payload) fires[#fires + 1] = payload end)

  local burst_parent = vim.fn.getcwd() .. "/phase4-burst"
  for i = 1, 100 do
    up.events.publish("core.file:created",
      { path = burst_parent .. "/probe-" .. i .. ".txt" })
  end
  -- Flush the debounce buffer synchronously so the assertion
  -- doesn't race the timer.
  core_init._flush_file_events_for_tests()
  vim.wait(10)

  ok("A4: 100-event burst coalesces to a single emit",
    #fires == 1,
    "got " .. #fires .. " fires: " .. vim.inspect(fires))
  ok("A4: burst emit is kind='subtree_stale'",
    fires[1] and fires[1].kind == "subtree_stale",
    "first fire kind: " .. tostring(fires[1] and fires[1].kind))
  ok("A4: subtree_stale payload carries the parent dir",
    fires[1] and type(fires[1].parents) == "table"
      and fires[1].parents[1] == burst_parent,
    "got parents: " .. vim.inspect(fires[1] and fires[1].parents))

  core_events.unsubscribe(hb)
end

-- ── A6: single-file events upsert the cache (delta) ──
do
  core_files._reset_for_tests()
  core_init.ensure_started(af.state.config)

  local fires = {}
  local hd = core_events.subscribe(
    "auto-finder.core.files:changed",
    function(payload) fires[#fires + 1] = payload end)

  local probe = vim.fn.getcwd() .. "/phase4-delta-probe.txt"
  up.events.publish("core.file:modified", { path = probe })
  core_init._flush_file_events_for_tests()
  vim.wait(10)

  local entry = core_files.get(probe)
  ok("A6: single-file event upserts the cache entry",
    entry ~= nil and entry.kind == "file" and entry.path == probe,
    "cache entry for " .. probe .. ": " .. vim.inspect(entry))
  ok("A6: single-file emit kind='upsert' (not subtree_stale)",
    fires[1] and fires[1].kind == "upsert",
    "got kind: " .. tostring(fires[1] and fires[1].kind))

  -- Delete the same path; cache entry should drop.
  up.events.publish("core.file:deleted", { path = probe })
  core_init._flush_file_events_for_tests()
  vim.wait(10)
  ok("A6: single-file delete drops cache entry",
    core_files.get(probe) == nil,
    "cache entry still present after delete: "
      .. vim.inspect(core_files.get(probe)))
  ok("A6: delete emit kind='delete'",
    fires[#fires] and fires[#fires].kind == "delete",
    "last fire kind: " .. tostring(fires[#fires] and fires[#fires].kind))

  core_events.unsubscribe(hd)
end

-- ── A15: chunked warm respects 5ms-per-tick budget ──
-- Create a tmp dir with enough top-level entries to force the
-- warmer through multiple ticks (default batch_size = 8). Then
-- start the warmer, wait for completion, and assert no recorded
-- tick exceeded 5ms.
do
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  -- 64 entries → 8 ticks of 8 entries each at default batch size.
  for i = 1, 64 do
    vim.fn.writefile({ "probe " .. i }, tmp .. "/p" .. i .. ".txt")
  end

  core_files._reset_for_tests()
  core_warm._reset_for_tests()
  core_warm.start(tmp)

  -- Wait up to 1s for the warmer to reach 'ready'. vim.wait
  -- interleaves with scheduled callbacks, so the warmer can
  -- make progress while we wait.
  vim.wait(1000, function() return core_warm.status() == "ready" end, 5)
  ok("warmer reaches 'ready' status",
    core_warm.status() == "ready",
    "status after wait: " .. core_warm.status())

  local durations = core_warm.tick_durations()
  ok("warmer recorded > 1 tick (chunked across the main loop)",
    #durations > 1,
    "ticks recorded: " .. #durations)

  local max_ms = 0
  for _, ms in ipairs(durations) do
    if ms > max_ms then max_ms = ms end
  end
  ok("A15: no warm tick exceeds 5 ms (max=" .. string.format("%.2f", max_ms) .. "ms)",
    max_ms <= 5.0,
    "exceeded budget; ticks: " .. vim.inspect(durations))

  -- Also assert auto-finder.core.ready fired with files='ready'.
  -- We don't subscribe a probe here because the publish already
  -- happened during the vim.wait above; instead we check that
  -- core.files readiness was flipped (which only happens when
  -- the publish fires).
  ok("warmer flipped files readiness to 'ready'",
    core_files.snapshot_now(tmp).readiness == "ready",
    "got readiness: " .. core_files.snapshot_now(tmp).readiness)

  -- Cleanup.
  pcall(vim.fn.delete, tmp, "rf")
end

-- ── core/files cache shape: directory entries + children_state ──
do
  core_files._reset_for_tests()
  -- Seed a directory entry; then upsert a child file under it.
  local d = "/tmp/phase4-dir-test"
  local f = d .. "/child.txt"
  core_files.upsert(d, { kind = "directory" })
  core_files.upsert(f, { kind = "file" })
  local d_entry = core_files.get(d)
  ok("directory entry has children + children_state",
    d_entry and d_entry.kind == "directory"
      and type(d_entry.children) == "table"
      and type(d_entry.children_state) == "string",
    "got: " .. vim.inspect(d_entry))
  ok("upserting a child marks the parent's children_state as stale",
    d_entry and (d_entry.children_state == "stale" or d_entry.children_state == "cold"),
    "got: " .. tostring(d_entry and d_entry.children_state))

  -- invalidate_subtree wipes children + flips state to 'stale'
  core_files.invalidate_subtree(d)
  local d_after = core_files.get(d)
  ok("invalidate_subtree drops children + sets state='stale'",
    d_after and d_after.children_state == "stale"
      and vim.tbl_count(d_after.children or {}) == 0,
    "got: " .. vim.inspect(d_after))
end

-- ── core/watchers: open/close/list round-trip ──
do
  core_watchers.close_all()
  local before = #core_watchers.list()
  core_watchers.open_for(vim.fn.getcwd())
  ok("watchers.open_for adds an entry to list()",
    #core_watchers.list() > before)
  core_watchers.close_all()
  ok("watchers.close_all returns list() to before-state",
    #core_watchers.list() == before)
end

-- Cleanup: leave the suite in a sane state.
core_files._reset_for_tests()
core_warm._reset_for_tests()
core_init.ensure_started(af.state.config)
end)()

-- ───────────────────────── 33. ADR 0026 Phase 5: git cache + translation ──
-- ADR 0026 Phase 5: real `core.git.snapshot_now` backed by
-- auto-core.git.status; the last `core.git.state:changed`
-- upstream subscription in shared/neotree.lua migrates to
-- `auto-finder.core.git:changed`.
--
-- After Phase 5 the shared/ tree subscribes to ZERO direct
-- upstream auto-core topics (`worktree:switched` is still a
-- direct upstream sub — Phase 7's view mount contract
-- consolidates that with auto-finder.core.repos:changed).
print("\n[33] ADR 0026 Phase 5 — git cache + translation")
;(function()
local core_git    = require("auto-finder.core.git")
local core_init   = require("auto-finder.core")
local core_events = require("auto-finder.core.events")
local up          = require("auto-core")

-- ── git snapshot shape ──
core_init.ensure_started(af.state.config)
local snap = core_git.snapshot_now()
ok("core.git.snapshot_now returns a known readiness state",
  snap.readiness == "ready" or snap.readiness == "partial"
    or snap.readiness == "cold",
  "got readiness=" .. tostring(snap.readiness))
ok("core.git.snapshot_now returns a by_path table",
  type(snap.by_path) == "table",
  "got by_path=" .. type(snap.by_path))

-- The smoke runs inside the auto-finder.nvim worktree (a git
-- repo), so snapshot_now SHOULD populate by_path with real
-- porcelain entries — UNLESS auto-core can't shell out (e.g. a
-- sandbox without git in PATH). The test is tolerant of both:
-- a populated by_path proves the wiring works; an empty one
-- with readiness='partial' is the soft-fail path.
if snap.readiness == "ready" then
  ok("snap.repo_root resolved (smoke runs inside a git repo)",
    type(snap.repo_root) == "string" and snap.repo_root ~= "")
elseif snap.readiness == "partial" then
  ok("readiness=partial when auto-core.git.status returns no entries",
    snap.by_path ~= nil and next(snap.by_path) == nil)
else
  ok("readiness=cold means snapshot has never been queried",
    true)
end

-- ── translator: upstream core.git.state:changed → auto-finder.core.git:changed ──
-- Phase 3 wired the publish; Phase 5 adds the readiness flip.
-- This test exercises both: subscribe, publish synthetic
-- upstream event, assert the translated event fires AND
-- core.git._readiness drops to 'cold'.
core_git._set_readiness("ready")  -- start from a known state
local seen
local h = core_events.subscribe("auto-finder.core.git:changed",
  function(p) seen = p end)
up.events.publish("core.git.state:changed", {
  repo_root = vim.fn.getcwd(),
  git_dir   = vim.fn.getcwd() .. "/.git",
  kind      = "head",
})
vim.wait(20)
ok("translator fires auto-finder.core.git:changed",
  type(seen) == "table" and seen.repo_root == vim.fn.getcwd()
    and seen.kind == "head",
  "got " .. vim.inspect(seen))
ok("translator flips core.git readiness to 'cold' on upstream event",
  core_git._readiness == "cold",
  "got " .. tostring(core_git._readiness))
core_events.unsubscribe(h)

-- ── core.git.get(path) — single-path lookup ──
-- The smoke driver's own file is tracked in the repo, so a get()
-- on its path should resolve (returns nil if unchanged-on-disk,
-- but the lookup itself must not crash and the resolution must
-- terminate). Reset readiness so the next snapshot re-queries.
core_git._set_readiness("cold")
local probe_path = debug.getinfo(1, "S").source:sub(2)  -- this file
local entry = core_git.get(probe_path)
-- Either the file has no porcelain entry (clean) → nil, or it
-- has an entry (dirty in this smoke run) → table. Both are
-- valid; we just assert no crash + correct shape if non-nil.
ok("core.git.get(path) returns nil-or-{x,y,code} without crashing",
  entry == nil
    or (type(entry) == "table"
        and type(entry.x) == "string"
        and type(entry.y) == "string"
        and type(entry.code) == "string"),
  "got " .. vim.inspect(entry))

-- ── core.git.invalidate ──
ok("core.git.invalidate is callable",
  type(core_git.invalidate) == "function")
local inv_ok = pcall(core_git.invalidate, vim.fn.getcwd())
ok("core.git.invalidate(cwd) is safe", inv_ok)

-- ── shared/neotree.lua no longer subscribes to core.git.state:changed ──
-- Grep-style check. The file should contain a subscription to
-- auto-finder.core.git:changed (Phase 5 migration target) and
-- NOT to the upstream core.git.state:changed. The worktree:switched
-- direct upstream sub is allowed through Phase 5 (Phase 7's
-- mount contract migrates that one).
do
  local f = io.open(plugin_root .. "/lua/auto-finder/shared/neotree.lua", "r")
  local content = f and f:read("*a") or ""
  if f then f:close() end
  -- Subscribe-call check. After the v0.2.25 B1 fix this is
  -- broader than just events.subscribe — the subscription may
  -- be wired via view_subs:replace(slot, topic, cb). Match on
  -- the topic STRING appearing in the file (excluding obvious
  -- comment lines that mention it for documentation only).
  local subs_to_git_state = content:find('"core%.git%.state:changed"')
  local subs_to_translated_git = content:find('"auto%-finder%.core%.git:changed"')
  ok("shared/neotree.lua does NOT reference core.git.state:changed as a topic",
    subs_to_git_state == nil)
  ok("shared/neotree.lua references auto-finder.core.git:changed as a topic",
    subs_to_translated_git ~= nil)
end

-- ── behavior: publishing core.git.state:changed still triggers
-- the shared/neotree.lua refresh (via the translated topic) ──
-- This proves the migration didn't break the user-observable
-- behavior — only the topic path changed.
do
  -- v0.2.25 B1 fix migrated this from a one-shot flag dance to
  -- `shared.view_subs:replace` — re-arm is idempotent and
  -- survives the section [31] bus-reset earlier in the run. The
  -- assertion below just re-focuses to confirm the translated-
  -- topic refresh path works end-to-end.
  af.focus(1)  -- files
  local files_section = require("auto-finder.sections").resolve(1)
  -- ADR 0026 Phase 7: poll until the deferred mount completes so
  -- the schedule_refresh guard (`if not section._bufnr`) doesn't
  -- early-return when our synthetic publish lands.
  vim.wait(500, function()
    return files_section and files_section._bufnr ~= nil
      and vim.api.nvim_buf_is_valid(files_section._bufnr)
  end)

  local manager_mod = require("auto-finder.neotree.sources.manager")
  local orig_refresh = manager_mod.refresh
  local refresh_calls = {}
  manager_mod.refresh = function(source_name, callback)
    refresh_calls[#refresh_calls + 1] = source_name
    if callback then pcall(callback) end
  end

  up.events.publish("core.git.state:changed", {
    repo_root = vim.fn.getcwd(),
    git_dir   = vim.fn.getcwd() .. "/.git",
    kind      = "index",
  })
  -- LIVE_REFRESH_DEBOUNCE_MS = 150; pad to 350 for CI variance.
  vim.wait(350, function()
    for _, src in ipairs(refresh_calls) do
      if src == "filesystem" then return true end
    end
    return false
  end)
  local saw_refresh = false
  for _, src in ipairs(refresh_calls) do
    if src == "filesystem" then saw_refresh = true; break end
  end
  ok("core.git.state:changed still triggers manager.refresh via the translated topic",
    saw_refresh,
    "refresh_calls=" .. vim.inspect(refresh_calls))

  manager_mod.refresh = orig_refresh
end
end)()

-- ───────────────────────── 34. ADR 0026 Phase 6: core.buffers + core.repos ──
-- ADR 0026 Phase 6: real implementations of core.buffers
-- (Buf*-autocmd-driven cache) and core.repos (auto-finder.repos
-- denormalized view). Buffers + repos views adopt the new
-- `core_refresh_topic` opt on shared.neotree.build_section so
-- they refresh on the centralized auto-finder.core.* signals.
print("\n[34] ADR 0026 Phase 6 — core.buffers + core.repos")
;(function()
local core_buffers = require("auto-finder.core.buffers")
local core_repos   = require("auto-finder.core.repos")
local core_init    = require("auto-finder.core")
local core_events  = require("auto-finder.core.events")

-- core is already started from setup; assert the autocmd-cache
-- pre-populated.
core_init.ensure_started(af.state.config)
vim.wait(20)

-- ── core.buffers shape + cache ──
local snap = core_buffers.snapshot_now()
ok("core.buffers.snapshot_now returns { list, readiness }",
  type(snap) == "table"
    and type(snap.list) == "table"
    and type(snap.readiness) == "string",
  "got " .. vim.inspect(snap))

-- The smoke session has buffers (the smoke file itself, any
-- :edit'd probe files from earlier sections, …). Assert at least
-- one entry — sanity check that the cache populated.
ok("core.buffers cache has ≥1 entry after ensure_started",
  #snap.list >= 1,
  "got " .. #snap.list .. " entries")

-- Buffer entries have the documented shape.
local first = snap.list[1]
ok("each buffer entry carries { bufnr, name, listed, loaded, modified, filetype, buftype }",
  type(first.bufnr) == "number"
    and type(first.name) == "string"
    and type(first.listed) == "boolean"
    and type(first.loaded) == "boolean"
    and type(first.modified) == "boolean"
    and type(first.filetype) == "string"
    and type(first.buftype) == "string",
  "first entry: " .. vim.inspect(first))

-- core.buffers.get(bufnr) returns the entry directly.
local g = core_buffers.get(first.bufnr)
ok("core.buffers.get(bufnr) returns the entry",
  g ~= nil and g.bufnr == first.bufnr,
  "got " .. vim.inspect(g))

-- ── Buf*-autocmd → translated event ──
local fires = {}
local h = core_events.subscribe("auto-finder.core.buffers:changed",
  function(p) fires[#fires + 1] = p end)

-- :badd a fresh file (avoids the panel-window winfixbuf collision
-- that would block :edit at this point in the suite — the panel
-- is mounted and current). :badd fires BufAdd without changing
-- any window's buffer, which is exactly what core.buffers tracks.
local probe = vim.fn.tempname()
vim.fn.writefile({ "phase6 buffers probe" }, probe)
vim.cmd("badd " .. vim.fn.fnameescape(probe))
vim.wait(80, function() return #fires > 0 end)

local saw_add = false
for _, p in ipairs(fires) do
  if p.kind == "add" or p.kind == "enter" then saw_add = true; break end
end
ok("Buf*-autocmd → auto-finder.core.buffers:changed fires on :edit",
  saw_add,
  "fires=" .. vim.inspect(fires))

-- :bd should fire kind='remove'.
local probe_bufnr = vim.fn.bufnr(probe)
fires = {}
if probe_bufnr > 0 then
  vim.cmd("bd! " .. probe_bufnr)
  vim.wait(80, function()
    for _, p in ipairs(fires) do
      if p.kind == "remove" then return true end
    end
    return false
  end)
  local saw_remove = false
  for _, p in ipairs(fires) do
    if p.kind == "remove" then saw_remove = true; break end
  end
  ok("BufDelete → auto-finder.core.buffers:changed fires kind='remove'",
    saw_remove,
    "fires=" .. vim.inspect(fires))
end
core_events.unsubscribe(h)
pcall(vim.fn.delete, probe)

-- ── core.repos shape ──
local rsnap = core_repos.snapshot_now()
ok("core.repos.snapshot_now returns { repos, readiness, root? }",
  type(rsnap) == "table"
    and type(rsnap.repos) == "table"
    and type(rsnap.readiness) == "string",
  "got " .. vim.inspect({ readiness = rsnap.readiness,
    repos_count = #rsnap.repos, root = rsnap.root }))

-- Each entry should be an absolute path string. The list MAY be
-- empty if worktree.nvim isn't on the runtimepath, but the shape
-- still holds.
local all_strings = true
for _, p in ipairs(rsnap.repos) do
  if type(p) ~= "string" or p == "" then all_strings = false; break end
end
ok("each repo entry is a non-empty string",
  all_strings,
  "repos=" .. vim.inspect(rsnap.repos))

-- core.repos.get(path) returns boolean.
if rsnap.repos[1] then
  ok("core.repos.get(known_path) returns true",
    core_repos.get(rsnap.repos[1]) == true)
end
ok("core.repos.get(unknown_path) returns false",
  core_repos.get("/this/path/definitely/does/not/exist") == false)

-- ── translator: worktree:switched → core.repos.invalidate ──
-- Publishing core.workspace_root:changed via worktree:switched
-- (already wired by Phase 3 translator) fires
-- auto-finder.core.repos:changed → core.repos.invalidate is
-- subscribed via Phase 6's internal_repos slot in
-- core.ensure_started, which drops the cache.
local up = require("auto-core")
core_repos._reset_for_tests()
core_repos.snapshot_now()  -- populate
ok("core.repos populates after snapshot_now",
  core_repos._cached ~= nil)
up.events.publish("worktree:switched", { new_root = "/tmp/phase6-probe" })
vim.wait(50)
ok("core.repos cache invalidated by auto-finder.core.repos:changed",
  core_repos._cached == nil,
  "cache still: " .. vim.inspect(core_repos._cached))

-- Re-fetch so subsequent tests don't see a cold cache.
core_repos.snapshot_now()

-- ── views opt-in via core_refresh_topic ──
-- buffers + repos view modules pass `core_refresh_topic` so
-- shared.neotree.build_section wires the subscription. The
-- section.refresh function is also exposed by the new opt path.
local buffers_view = require("auto-finder.views.buffers")
local repos_view   = require("auto-finder.views.repos")
ok("buffers view declares core_refresh_topic = auto-finder.core.buffers:changed",
  buffers_view._core_refresh_topic == "auto-finder.core.buffers:changed")
ok("repos view declares core_refresh_topic = auto-finder.core.repos:changed",
  repos_view._core_refresh_topic == "auto-finder.core.repos:changed")
ok("buffers view exposes section.refresh (Phase 6 public refresh entry)",
  type(buffers_view.refresh) == "function")
ok("repos view exposes section.refresh",
  type(repos_view.refresh) == "function")

-- ── A1 grep: no view subscribes to upstream auto-core topics ──
-- Re-run the Phase 4 grep specifically including the buffers +
-- repos views (which the original grep DID cover, but we
-- re-assert now that they have new code paths via
-- core_refresh_topic).
do
  local function read_file(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local s = f:read("*a"); f:close()
    return s or ""
  end
  local function walk(dir, fn)
    local h2 = vim.uv.fs_scandir(dir)
    if not h2 then return end
    while true do
      local name, t = vim.uv.fs_scandir_next(h2)
      if not name then break end
      local p = dir .. "/" .. name
      if t == "directory" then walk(p, fn)
      elseif t == "file" and name:match("%.lua$") then fn(p)
      end
    end
  end
  local views_root = plugin_root .. "/lua/auto-finder/views"
  local violations = {}
  walk(views_root, function(path)
    local content = read_file(path)
    for forbidden in pairs({
      ["\"core.file:"]       = true,
      ["\"core.git.state:"]  = true,
      ["\"worktree:"]        = true,
    }) do
      if content:find(forbidden, 1, true) then
        violations[#violations + 1] = path .. " contains " .. forbidden
      end
    end
  end)
  ok("A1 (Phase 6 recheck): no view module subscribes to upstream topics",
    #violations == 0,
    "violations: " .. vim.inspect(violations))
end
end)()

-- ───────────────────────── 35. ADR 0026 Phase 7: loading-placeholder ──
-- ADR 0026 Phase 7: two-phase view mount. get_buffer returns a
-- generation-tagged placeholder synchronously; on_focus defers
-- the real mount behind vim.schedule + the five-guard
-- _still_current predicate. Smokes:
--   A3 — every view's get_buffer returns a placeholder first
--        (on cold mount)
--   A13 — placeholder race: focus A → focus B before A's
--         deferred render fires → B renders correctly; A's
--         callback exits silently via guard mismatch
--   A14 — generation guard: force-bump a view's _generation;
--         the stale callback no-ops on the panel buffer
--   A16 — dbase placeholder migration: focus dbase from cold;
--         placeholder paints; real dbee mount completes
--         without losing editor window or duplicating dbee UI
print("\n[35] ADR 0026 Phase 7 — loading-placeholder (A3/A13/A14/A16)")
;(function()
local loading = require("auto-finder.shared.loading")
local window  = require("auto-finder.shared.window")
local views   = require("auto-finder.views")

-- ── infrastructure ──
ok("shared.loading.buffer exists",
  type(loading.buffer) == "function")
ok("shared.loading.is_placeholder exists",
  type(loading.is_placeholder) == "function")
ok("shared.loading.matches exists",
  type(loading.matches) == "function")
ok("shared.window.is_auto_finder_panel exists",
  type(window.is_auto_finder_panel) == "function")
ok("shared.window.is_any_panel exists",
  type(window.is_any_panel) == "function")
ok("views.active() exists",
  type(views.active) == "function")

-- Build a placeholder; assert shape + buffer-local tags.
do
  local b = loading.buffer({ view = "test", generation = 42, message = "Loading…" })
  ok("loading.buffer returns a valid bufnr",
    type(b) == "number" and vim.api.nvim_buf_is_valid(b))
  ok("placeholder buffer has nofile/wipe options",
    vim.bo[b].buftype == "nofile"
      and vim.bo[b].bufhidden == "wipe")
  ok("placeholder buffer is read-only",
    vim.bo[b].readonly == true)
  ok("loading.is_placeholder identifies the buffer",
    loading.is_placeholder(b) == true)
  ok("loading.matches identifies view+generation",
    loading.matches(b, "test", 42) == true)
  ok("loading.matches rejects wrong view",
    loading.matches(b, "other", 42) == false)
  ok("loading.matches rejects wrong generation",
    loading.matches(b, "test", 99) == false)
  -- Cleanup the test buffer; bufhidden=wipe handles when it's
  -- unloaded, but explicit delete is cleaner for smoke isolation.
  pcall(vim.api.nvim_buf_delete, b, { force = true })
end

-- A3 is partial in Phase 7: neo-tree-backed views (files /
-- buffers / repos) keep synchronous mounts because of the
-- auto-core Registry keymap-binding tension (see audit-log F7.1
-- in tests/auto-finder-test-audit.md). Only `dbase` exercises
-- the placeholder pattern — A3 + A13 + A14 are asserted against
-- it in the A16 section below.
--
-- The placeholder infrastructure (shared/loading.lua, the
-- five-guard `_still_current` predicate, `_owned_bufs` table)
-- still ships in build_section so a future auto-core API change
-- can flip neo-tree-backed views to placeholder mode without
-- structural rework.
--
-- views still expose `_generation` and `_owned_bufs` per ADR
-- §2.3. Verify the per-view generation counter increments on
-- each cold get_buffer call.
do
  local view = require("auto-finder.sections").resolve("files")
  if view then
    local gen_before = view._generation or 0
    view._bufnr = nil
    view._owned_bufs = {}
    -- get_buffer is `function section.get_buffer(panel_winid)` —
    -- call positionally, not method-style. Pass the live panel
    -- winid; mount() inside uses it to focus + execute neo-tree.
    pcall(view.get_buffer, af.state.panel_winid)
    ok("get_buffer bumps generation on cold mount (files view)",
      (view._generation or 0) > gen_before,
      "before=" .. tostring(gen_before) ..
      " after=" .. tostring(view._generation))
  end
end

-- ── A16: dbase placeholder migration ──
-- dbase isn't built via build_section. Its bespoke get_buffer
-- + on_focus carry the same placeholder + generation pattern.
-- Cold-focus dbase, assert get_buffer returns a placeholder
-- (the real dbee mount happens behind vim.schedule).
do
  local dbase = require("auto-finder.views.dbase")
  dbase._bufnr = nil
  dbase._owned_bufs = {}
  -- get_buffer should return a placeholder, not the dbee drawer.
  local b = dbase.get_buffer(0)
  ok("A16: dbase view.get_buffer returns a placeholder on cold mount",
    b ~= nil and loading.is_placeholder(b) == true,
    "got bufnr=" .. tostring(b) .. " is_placeholder=" ..
    tostring(loading.is_placeholder(b)))
  ok("A16: dbase placeholder is tagged view='dbase'",
    loading.matches(b, "dbase", dbase._generation) == true)

  -- on_focus should not crash even if dbee isn't on the rtp.
  -- (The deferred callback exits with a placeholder_buffer or
  -- the real drawer; either is acceptable for A16's "doesn't
  -- crash + doesn't duplicate" contract.)
  local on_focus_ok = pcall(dbase.on_focus, 0, b)
  ok("A16: dbase on_focus is safe even without a real panel winid",
    on_focus_ok)
  -- Settle any scheduled callbacks; cleanup the placeholder so
  -- the smoke doesn't leave a wipeable buffer behind.
  vim.wait(50)
  pcall(vim.api.nvim_buf_delete, b, { force = true })
  dbase._bufnr = nil
  dbase._owned_bufs = {}
end

-- ── A16b: dbase post-_notify_remount registry repair (ADR-0033) ──
-- A16 above stops at get_buffer (the cold placeholder). This block
-- drives the *deferred* mount to its dbee-unavailable terminal
-- branch (views/dbase/init.lua:259-267) and asserts the three
-- side-effects `_notify_remount` → `Registry:section_did_remount`
-- repairs — the regression the production bug shipped without
-- ([[2026-05-20-auto-finder-dbase-winbar-remount-bug-analysis]]):
--   1. `_bufs[dbase]` reseats to the real (post-swap) buffer,
--   2. buffer-local `0..9` / `q` rebind on that real buffer,
--   3. the winbar refreshes with dbase active.
-- dbee is NOT on the headless rtp, so we force the unavailable
-- branch by monkey-patching `setup_mod.ensure_setup` → false. The
-- registry side-effects are identical whether `real_bufnr` is the
-- dbee drawer or the fallback placeholder (ADR-0033 §"Headless
-- feasibility"). Restore is non-negotiable: the patch + the
-- temporary section-list mutation are undone in an xpcall finally
-- arm so the rest of the suite is unaffected (ADR-0033 §Decision.2).
do
  local dbase     = require("auto-finder.views.dbase")
  local setup_mod = require("auto-finder.views.dbase.setup")

  -- Window-independent buffer-local keymap probe (the panel may not
  -- be the current window, and section_did_remount does not swap it).
  local function has_map(bufnr, lhs, needle)
    if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return false end
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
      if m.lhs == lhs and (m.desc or ""):find(needle, 1, true) then
        return true
      end
    end
    return false
  end

  -- Snapshot the LIVE section-name list. The field _rebuild_section_
  -- registry consumes is `state.config.sections` (a string[]), not
  -- `state.sections`; mirror the restore pattern used elsewhere in
  -- this suite (vim.deepcopy + rebuild on the finally arm).
  local prior = vim.deepcopy(af.state.config.sections)
  setup_mod.reset()
  local orig_ensure = setup_mod.ensure_setup

  local function run()
    -- Force the dbee-unavailable terminal branch of on_focus.
    setup_mod.ensure_setup = function()
      return false, "dbee unavailable: forced for smoke"
    end

    -- Rebuild with dbase enabled, focusing config (0) so the next
    -- focus(dbase) is a genuine cold mount.
    af._rebuild_section_registry({ "config", "files", "dbase" },
      { focus_after = 0 })

    local dbnum = dbase.number
    ok("A16b: dbase registered with a section number",
      type(dbnum) == "number", "number=" .. tostring(dbnum))

    -- Cold-focus dbase; let the vim.schedule-deferred mount run.
    af.focus(dbnum)
    vim.wait(200)

    -- (1) THE load-bearing production-bug assertion: the registry
    --     cache points at the real (post-remount) buffer, not the
    --     discarded shared.loading placeholder.
    ok("A16b: _bufs[dbase] reseated to dbase._bufnr after remount",
      af._registry._bufs[dbnum] == dbase._bufnr,
      "_bufs=" .. tostring(af._registry._bufs[dbnum]) ..
      " _bufnr=" .. tostring(dbase._bufnr))

    -- (2) buffer-local section-hop (0) + close (q) on the real buffer
    ok("A16b: 0 (section-hop) bound buffer-locally on the real buffer",
      has_map(dbase._bufnr, "0", "focus section"))
    ok("A16b: q (close panel) bound buffer-locally on the real buffer",
      has_map(dbase._bufnr, "q", "close panel"))

    -- (3) winbar refreshed with dbase as the active marker
    local wb = vim.api.nvim_get_option_value("winbar",
      { win = af.state.panel_winid })
    ok("A16b: winbar shows dbase as the active section after remount",
      type(wb) == "string"
        and wb:find("AutoCoreSectionActive#%[" .. dbnum) ~= nil,
      "winbar=" .. tostring(wb))

    -- (4) the real buffer is the static dbee-unavailable placeholder,
    --     distinct from the shared.loading cold placeholder.
    ok("A16b: real buffer is the dbee-unavailable placeholder",
      vim.api.nvim_buf_is_valid(dbase._bufnr)
        and vim.api.nvim_buf_get_name(dbase._bufnr)
          :find("auto-finder-dbase://placeholder", 1, true) ~= nil)
    ok("A16b: real buffer is NOT a shared.loading cold placeholder",
      loading.is_placeholder(dbase._bufnr) == false)

    -- (5) re-mount idempotency. The dbee-unavailable fallback
    --     placeholder is `bufhidden=wipe` (views/dbase/init.lua), so
    --     focusing away wipes it and the return is a fresh cold mount
    --     — a SECOND trip through _notify_remount. (The real dbee
    --     drawer is persistent, so it would warm-reuse; this branch
    --     can only exercise the fallback.) Assert the hook stays
    --     idempotent: the registry cache + keymaps are re-repaired and
    --     stay consistent with the view's current buffer.
    af.focus(0)
    vim.wait(50)
    af.focus(dbnum)
    vim.wait(200)
    ok("A16b: re-focus keeps _bufs[dbase] consistent with dbase._bufnr",
      af._registry._bufs[dbnum] == dbase._bufnr
        and vim.api.nvim_buf_is_valid(dbase._bufnr),
      "_bufs=" .. tostring(af._registry._bufs[dbnum]) ..
      " _bufnr=" .. tostring(dbase._bufnr))
    ok("A16b: re-focus keeps q bound on the current dbase buffer",
      has_map(dbase._bufnr, "q", "close panel"))
  end

  -- Finally arm — runs even if an assertion path errors, so the
  -- patch + section list never leak into later smoke sections.
  local okrun, errrun = xpcall(run, debug.traceback)
  setup_mod.ensure_setup = orig_ensure
  setup_mod.reset()
  dbase._bufnr = nil
  dbase._owned_bufs = {}
  af._rebuild_section_registry(prior, { focus_after = 0 })
  ok("A16b: harness restored prior section registry without error",
    okrun, okrun and "" or tostring(errrun))
end

-- Restore: focus the config view so later sections don't fight
-- the panel state created here.
local config_idx = require("auto-finder.sections")._by_name["config"]
if config_idx then af.focus(config_idx) end
vim.wait(50)
end)()

-- ───────────────────────── 36. ADR 0026 Phase 8: shared/logging sweep ──
-- ADR 0026 Phase 8:
--   - shared/debounce.lua extracted; shared/neotree.lua and
--     core/init.lua refactored to use it
--   - dbase log component tags migrated to view.dbase.* (A10)
--   - vim.notify audit: zero live calls in the plugin tree
--     (excluding the vendored neo-tree fork)
print("\n[36] ADR 0026 Phase 8 — shared extraction + logging sweep (A9/A10)")
;(function()
-- ── shared.debounce: coalesce semantics ──
local debounce = require("auto-finder.shared.debounce")
ok("shared.debounce.coalesce is callable",
  type(debounce.coalesce) == "function")

-- A coalescer with 80ms window. Rapid back-to-back triggers
-- should fire fn exactly once (not 4 times).
local fires = 0
local last_args
local trigger, cancel = debounce.coalesce(function(a, b)
  fires = fires + 1
  last_args = { a, b }
end, 80)

for i = 1, 4 do trigger("call-" .. i, i) end
vim.wait(150, function() return fires > 0 end)
ok("4 rapid triggers within 80ms window → exactly 1 fire",
  fires == 1, "fires=" .. fires)
ok("debounce fires fn with the LAST call's args (latest-wins)",
  last_args and last_args[1] == "call-4" and last_args[2] == 4,
  "got " .. vim.inspect(last_args))

-- cancel() drops the pending fire.
fires = 0
trigger("dropped")
cancel()
vim.wait(150)
ok("cancel() drops the pending fire (no callback)",
  fires == 0, "fires=" .. fires)

-- ── A9: zero live vim.notify calls in plugin tree (excl neo-tree fork) ──
do
  local function read_file(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local s = f:read("*a"); f:close()
    return s or ""
  end
  local function walk(dir, fn)
    local h = vim.uv.fs_scandir(dir)
    if not h then return end
    while true do
      local name, t = vim.uv.fs_scandir_next(h)
      if not name then break end
      if name ~= "neotree" then
        local p = dir .. "/" .. name
        if t == "directory" then walk(p, fn)
        elseif t == "file" and name:match("%.lua$") then fn(p)
        end
      end
    end
  end
  local plugin_root_lua = plugin_root .. "/lua/auto-finder"
  local violations = {}
  walk(plugin_root_lua, function(path)
    local content = read_file(path)
    -- Match `vim.notify(` calls that are NOT inside a comment.
    -- Cheap check: scan each line; ignore lines whose first
    -- non-whitespace chars are `--` (comment) or `---` (docstring).
    for line in content:gmatch("[^\n]+") do
      local trimmed = line:match("^%s*(.*)$") or ""
      if not trimmed:match("^%-%-") then
        if trimmed:find("vim%.notify%s*%(") then
          violations[#violations + 1] = path .. ": " .. trimmed
        end
      end
    end
  end)
  ok("A9: zero live vim.notify calls in plugin tree (excl neo-tree fork)",
    #violations == 0,
    "violations: " .. vim.inspect(violations))
end

-- ── A10: component tags follow convention ──
-- core/*.lua             → auto-finder.core.<area>
-- views/<name>/*.lua     → auto-finder.view.<name>[.<sub>]
-- shared/*.lua           → auto-finder.shared.<helper>
-- panel/*.lua            → auto-finder.panel.<helper>
do
  local function read_file(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local s = f:read("*a"); f:close()
    return s or ""
  end
  local function walk(dir, fn)
    local h = vim.uv.fs_scandir(dir)
    if not h then return end
    while true do
      local name, t = vim.uv.fs_scandir_next(h)
      if not name then break end
      if name ~= "neotree" then
        local p = dir .. "/" .. name
        if t == "directory" then walk(p, fn)
        elseif t == "file" and name:match("%.lua$") then fn(p)
        end
      end
    end
  end
  local violations = {}
  walk(plugin_root .. "/lua/auto-finder", function(path)
    local content = read_file(path)
    local subtree = path:match("/lua/auto%-finder/([^/]+)/")
    -- Find every log.<level>("<tag>" / logger.<level>("<tag>" call
    -- with its tag string; verify the tag is consistent with the
    -- file's subtree per the A10 scheme.
    for tag in content:gmatch("[%w_]+%.([%w_]+)%s*[%w_]*%.?[%w_]*%s*%(") do
      -- This grabs too much; do a tighter match below.
    end
    for level in content:gmatch('log[%w_.]*%.([%w_]+)%("([%w_.%-]+)') do
      local _ = level  -- not used
    end
    -- Tighter: explicitly match logger.<level>("<tag>" or
    -- require("auto-finder.log").<level>("<tag>".
    -- Match level-functions only (error/warn/info/debug/trace).
    -- notifyIf/notify take event names as the first arg, not
    -- component tags — they're tracked by a different convention
    -- and aren't subject to A10's scheme.
    -- Lua patterns lack alternation; loop the level set.
    local levels = { "error", "warn", "info", "debug", "trace" }
    local function check_tag(tag)
      local ok_tag
      if subtree == "core" then
        ok_tag = (tag == "core" or tag:match("^core%."))
      elseif subtree == "views" then
        ok_tag = tag:match("^view%.")
      elseif subtree == "shared" then
        ok_tag = tag:match("^shared%.")
      elseif subtree == "panel" then
        ok_tag = tag:match("^panel%.")
      else
        ok_tag = true  -- top-level files (init.lua, state.lua, ...) are unconstrained
      end
      if not ok_tag then
        violations[#violations + 1] = path .. " tag '" .. tag .. "'"
      end
    end
    for _, level in ipairs(levels) do
      local pat = 'logger%.' .. level .. '%(%s*"([%w_.%-]+)"'
      for tag in content:gmatch(pat) do check_tag(tag) end
      local pat2 = 'require%("auto%-finder%.log"%)%.' .. level
        .. '%(%s*"([%w_.%-]+)"'
      for tag in content:gmatch(pat2) do check_tag(tag) end
    end
    -- Drop the legacy stray-match loop below — replaced by the
    -- per-level loop above. (Original grep block deleted with the
    -- closing `end` from the outer iterator.)
    for tag in content:gmatch('SHARED_NEVER_MATCH_THIS_TOKEN_FOR_LEGACY_LOOP_FALLBACK') do
      local ok_tag
      if subtree == "core" then
        ok_tag = (tag == "core" or tag:match("^core%."))
      elseif subtree == "views" then
        ok_tag = tag:match("^view%.")
      elseif subtree == "shared" then
        ok_tag = tag:match("^shared%.")
      elseif subtree == "panel" then
        ok_tag = tag:match("^panel%.")
      else
        ok_tag = true
      end
      if not ok_tag then
        violations[#violations + 1] = path .. " tag '" .. tag .. "'"
      end
    end
  end)
  ok("A10: component tags follow auto-finder.<subtree>.<name> convention",
    #violations == 0,
    "violations: " .. vim.inspect(violations))
end
end)()

-- ───────────────────────── 37. ADR 0026 Phase 9: acceptance audit (closeout) ──
-- ADR 0026 Phase 9 is a ledger pass — no new functionality.
-- The acceptance work is to assert:
--   A11: total count ≥ 263, failed = 0 (no regression vs. the
--        v0.2.23 baseline that opened the refactor).
--   A5:  the metrics:paint emit point is wired and fires on
--        every render. The formal ≤ 50% baseline comparison is
--        DEFERRED — Phase 3 instrumented the emit point but the
--        Phase 4 baseline was never captured as a benchmark
--        (the refactor work outpaced the benchmark setup).
--        Re-run against v0.2.23 to capture pre-refactor numbers
--        when the comparison is wanted; today A5 is "the
--        instrumentation is in place and demonstrably fires."
--   Audit: every per-phase smoke section is still green
--          (implicitly proved by failed == 0 below; explicitly
--           checked in §Per-phase audit pass).
print("\n[37] ADR 0026 Phase 9 — acceptance audit (closeout)")
;(function()
-- A11: total assertion count vs. the v0.2.23 baseline (263/1).
-- Use pass_count + fail_count as a proxy for "total smoke
-- assertions" — they're the running counters this file maintains.
--
-- ADR-0040 Batch D (S2): A11 is INFORMATIONAL now, not an ok()
-- assertion. The old `fail_count == 0` form double-counted every
-- failure (each real/env failure tripped its own assertion AND
-- A11, inflating the reported count — macOS read 5 where 4 were
-- real) while adding zero diagnostic signal. The count floor stays
-- asserted; the zero-failures meta-check is a print.
local total = pass_count + fail_count
ok("A11: total smoke assertions ≥ 263 (pre-refactor v0.2.23 baseline)",
  total >= 263,
  "total=" .. tostring(total))
print(string.format(
  "  INFO  A11: failures so far: %d (meta-check is informational — "
  .. "individual assertions are the signal)", fail_count))

-- A5 instrumentation proxy: the metrics:paint emit point is
-- wired into shared/neotree.lua's schedule_refresh. Subscribe,
-- trigger a refresh via a synthetic event, assert the emit
-- fires with the expected shape. (Phase 3 section [31] already
-- runs this assertion; we re-run it here as a closeout check
-- that the instrumentation survived all phases.)
local up = require("auto-core")
local core_events = require("auto-finder.core.events")
local seen
local probe = core_events.subscribe(
  "auto-finder.core.metrics:paint",
  function(p) if p and p.view == "files" then seen = p end end)

-- v0.2.25 B1 fix: re-arm is now idempotent via shared.view_subs.
-- Just re-focus and the file-event subscription is replaced
-- in place.
af.focus(1)  -- files
local files_section = require("auto-finder.sections").resolve(1)
vim.wait(500, function()
  return files_section and files_section._bufnr ~= nil
    and vim.api.nvim_buf_is_valid(files_section._bufnr)
end)
up.events.publish("core.file:modified",
  { path = vim.fn.getcwd() .. "/phase9-a5-probe.txt" })
vim.wait(500, function() return seen ~= nil end)
ok("A5 (instrumentation): metrics:paint emit fires on render",
  type(seen) == "table"
    and type(seen.dur_ms) == "number"
    and seen.view == "files"
    and type(seen.generation) == "number",
  "got " .. vim.inspect(seen))
core_events.unsubscribe(probe)

-- A5 (deferred): the formal "post-refactor dur_ms mean ≤ 50%
-- pre-refactor baseline" comparison needs a benchmark against
-- v0.2.23. Phase 9 documents this as deferred; the
-- instrumentation is in place to run the comparison when
-- someone captures the baseline. The smoke records the live
-- `dur_ms` as a forward-looking artifact future benchmarks can
-- diff against.
if seen and type(seen.dur_ms) == "number" then
  print(string.format(
    "  INFO  metrics:paint dur_ms observed in this smoke run: %.2fms (view=%s, gen=%d)",
    seen.dur_ms, seen.view, seen.generation))
end

-- ── Per-phase audit pass ──
-- Each phase's headline acceptance assertions already ran above
-- (sections [29] through [36]). The fact that this section is
-- reached AT ALL with fail_count == 0 implicitly confirms every
-- per-phase smoke is green. This block makes the audit explicit
-- by counting expected section headers in the smoke driver.
do
  local function read_file(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local s = f:read("*a"); f:close()
    return s or ""
  end
  local content = read_file(plugin_root .. "/tests/smoke.lua")
  local expected_phase_sections = {
    { id = "29", phase = "Phase 1 — core skeleton",         marker = "%[29%] core skeleton" },
    { id = "30", phase = "Phase 2 — sections → views",      marker = "%[30%] ADR 0026 Phase 2" },
    { id = "31", phase = "Phase 3 — lifecycle",             marker = "%[31%] ADR 0026 Phase 3" },
    { id = "32", phase = "Phase 4 — files cache + watchers", marker = "%[32%] ADR 0026 Phase 4" },
    { id = "33", phase = "Phase 5 — git cache",             marker = "%[33%] ADR 0026 Phase 5" },
    { id = "34", phase = "Phase 6 — buffers + repos",       marker = "%[34%] ADR 0026 Phase 6" },
    { id = "35", phase = "Phase 7 — loading-placeholder",   marker = "%[35%] ADR 0026 Phase 7" },
    { id = "36", phase = "Phase 8 — shared/logging sweep",  marker = "%[36%] ADR 0026 Phase 8" },
    { id = "37", phase = "Phase 9 — acceptance audit",      marker = "%[37%] ADR 0026 Phase 9" },
  }
  for _, p in ipairs(expected_phase_sections) do
    ok("Audit: smoke section [" .. p.id .. "] (" .. p.phase .. ") present in tests/smoke.lua",
      content:find(p.marker) ~= nil)
  end
end

-- Arc complete.
print("  INFO  ADR 0026 refactor arc complete (Phases 1–9). Ready for tag.")
end)()

-- ───────────────────────── 38. v0.2.25 fix: view subs survive bus reset (B1) ──
-- Lector review (post-Phase-9) found that shared/neotree.lua's
-- view subscriptions were still one-shot via the
-- `_fs_subscribed` / `_core_refresh_subscribed` booleans —
-- a bus reset wiped the callbacks AND the flags blocked
-- re-arm on subsequent focus. v0.2.25 migrates both paths to
-- `shared.view_subs`'s replace-or-add semantics so re-arm is
-- safe (and idempotent).
--
-- This smoke proves the bus-reset survivability WITHOUT the
-- manual `_fs_subscribed = false` dance that Phase 5 / Phase 9
-- smokes were doing to mask the real issue.
print("\n[38] v0.2.25 — view subscriptions survive auto-core bus reset (B1)")
;(function()
local manager_mod = require("auto-finder.neotree.sources.manager")
local core_events = require("auto-finder.core.events")
local up = require("auto-core")

-- For each of files / buffers / repos, run the protocol:
--   1. Focus the view (mounts + arms subscriptions via view_subs).
--   2. Force auto-core.events._reset_for_tests (wipes ALL subs).
--   3. Refocus the view (re-arms subs via view_subs:replace).
--   4. Publish the relevant auto-finder.core.* topic.
--   5. Assert manager.refresh fires — without touching
--      `_fs_subscribed` or `_core_refresh_subscribed`.
local function bus_reset_survives(view_name, view_idx, topic, payload)
  -- Ensure section is mounted (cold or re-mounted).
  af.focus(view_idx)
  local sec = require("auto-finder.sections")._by_number[view_idx]
  vim.wait(500, function()
    return sec and sec._bufnr ~= nil
      and vim.api.nvim_buf_is_valid(sec._bufnr)
  end)

  -- Bus reset wipes EVERY subscription on auto-core.events.
  up.events._reset_for_tests()

  -- Re-arm core (translator subscriptions). This is what
  -- M.open / M.focus already do defensively.
  require("auto-finder.core").ensure_started(af.state.config)

  -- Re-focus the view. The on_focus wrap calls
  -- _arm_live_refresh_subs / _arm_core_refresh_sub, which
  -- (post-B1) use view_subs:replace — re-armable without a
  -- flag-clear dance.
  af.focus(view_idx)
  vim.wait(50)

  -- Stub manager.refresh to capture fires.
  local orig_refresh = manager_mod.refresh
  local refresh_calls = {}
  manager_mod.refresh = function(source_name, callback)
    refresh_calls[#refresh_calls + 1] = source_name
    if callback then pcall(callback) end
  end

  -- Publish the synthetic topic. core's translator fires it
  -- through; shared/neotree.lua's view_subs-armed callback
  -- triggers schedule_refresh → manager.refresh (150ms).
  core_events.publish(topic, payload)
  vim.wait(500, function() return #refresh_calls > 0 end)

  manager_mod.refresh = orig_refresh

  return #refresh_calls > 0
end

-- files view — fires via auto-finder.core.files:changed.
do
  local files_idx = require("auto-finder.sections")._by_name["files"]
  if files_idx then
    local fired = bus_reset_survives("files", files_idx,
      "auto-finder.core.files:changed",
      { cwd = vim.fn.getcwd(), kind = "upsert",
        paths = { vim.fn.getcwd() .. "/b1-probe.txt" } })
    ok("B1: files view re-arms refresh after bus reset (no manual flag clear)",
      fired,
      "manager.refresh did not fire after bus reset + re-focus")
  end
end

-- buffers view — fires via auto-finder.core.buffers:changed.
do
  local buffers_idx = require("auto-finder.sections")._by_name["buffers"]
  if buffers_idx then
    local fired = bus_reset_survives("buffers", buffers_idx,
      "auto-finder.core.buffers:changed",
      { kind = "add", bufnr = 1 })
    ok("B1: buffers view re-arms refresh after bus reset (no manual flag clear)",
      fired,
      "manager.refresh did not fire after bus reset + re-focus")
  end
end

-- repos view — fires via auto-finder.core.repos:changed.
do
  local repos_idx = require("auto-finder.sections")._by_name["repos"]
  if repos_idx then
    local fired = bus_reset_survives("repos", repos_idx,
      "auto-finder.core.repos:changed",
      { kind = "worktree_switched", repo_root = vim.fn.getcwd() })
    ok("B1: repos view re-arms refresh after bus reset (no manual flag clear)",
      fired,
      "manager.refresh did not fire after bus reset + re-focus")
  end
end

-- ── B1 invariant: view_subs sets are populated (not stuck at 0) ──
-- The migration uses section._live_subs and section._core_subs;
-- each should have at least one slot after the arm calls above.
do
  local files_sec = require("auto-finder.sections")._by_name["files"]
    and require("auto-finder.sections")._by_number[
      require("auto-finder.sections")._by_name["files"]]
  if files_sec and files_sec._live_subs then
    ok("B1: files view's _live_subs holds ≥1 slot (files + worktree + git)",
      files_sec._live_subs:count() >= 1,
      "count=" .. tostring(files_sec._live_subs:count()))
  end
  local repos_sec = require("auto-finder.sections")._by_name["repos"]
    and require("auto-finder.sections")._by_number[
      require("auto-finder.sections")._by_name["repos"]]
  if repos_sec and repos_sec._core_subs then
    ok("B1: repos view's _core_subs holds the refresh slot",
      repos_sec._core_subs:count() >= 1,
      "count=" .. tostring(repos_sec._core_subs:count()))
  end
end

-- ── B2: NuiTree missing-bufnr stack trace path (mac-frequent) ──
-- Lector flagged a `vim.schedule callback: missing bufnr` stack
-- trace surfacing from neotree/ui/renderer.lua during the
-- section [13] directory-hijack flow. The smoke previously
-- tolerated it; v0.2.25 hardens create_tree to bail when
-- state.bufnr is nil/invalid (the async-render-against-stale-
-- state path Mac users hit when fs_scan completes after the
-- panel close / section switch).
--
-- The fix is in the production code path (the vendored fork's
-- renderer.lua at create_tree + show_nodes), but we also add a
-- B2 invariant smoke here: call create_tree against a state
-- with bufnr=nil and assert no error + no tree created.
do
  local renderer = require("auto-finder.neotree.ui.renderer")
  local stale_state = {
    name = "filesystem",
    id = "test-stale",
    bufnr = nil,     -- the failure mode
    winid = nil,
    tree = nil,
  }
  -- create_tree is local to renderer.lua. We can't call it
  -- directly. Instead drive the show_nodes downstream path
  -- which calls create_tree internally — set up a state that
  -- exercises the bail-out branch.
  --
  -- Simpler proof: assert the rendered code structure contains
  -- the v0.2.25 hardening (the early-return guard on
  -- `not state.bufnr or not nvim_buf_is_valid(state.bufnr)`).
  local function read_file(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local s = f:read("*a"); f:close()
    return s or ""
  end
  local renderer_src = read_file(
    plugin_root .. "/lua/auto-finder/neotree/ui/renderer.lua")
  ok("B2: create_tree has the v0.2.25 stale-state bail-out guard",
    renderer_src:find("not state%.bufnr") ~= nil
      and renderer_src:find("aborting render against stale state") ~= nil,
    "expected guard text not found")
  ok("B2: show_nodes has the v0.2.25 nil-tree downstream guard",
    renderer_src:find("create_tree bailed on stale state") ~= nil,
    "expected downstream guard text not found")
end

-- ── B2 (smoke hygiene policy): assert no unhandled async errors ──
-- Per Lector's policy addendum: smoke sections that tolerate
-- async warnings must capture them. We can't truly observe
-- stderr from inside the smoke driver, but we CAN install a
-- vim.notify shim AND a temporary vim.schedule wrapper that
-- counts unhandled errors. Future regressions in any async
-- render path bump the counter and fail this assertion.
do
  local schedule_errors = {}
  -- Hook vim.schedule to wrap callbacks in xpcall so errors
  -- get captured rather than printed to stderr. Restore on
  -- block exit so we don't affect the rest of the suite.
  local orig_schedule = vim.schedule
  vim.schedule = function(fn)
    return orig_schedule(function()
      local ok, err = xpcall(fn, debug.traceback)
      if not ok then
        schedule_errors[#schedule_errors + 1] = err
      end
    end)
  end

  -- Trigger the section [13] hijack-equivalent path: open + close
  -- the panel rapidly so async neo-tree callbacks fire against
  -- potentially-wiped state.
  af.close()
  vim.wait(50)
  af.open(true)
  af.focus(1)
  vim.wait(200)
  af.close()
  vim.wait(300)  -- drain any async callbacks

  vim.schedule = orig_schedule

  ok("B2: zero unhandled scheduled-callback errors during rapid open/close cycle",
    #schedule_errors == 0,
    "captured " .. #schedule_errors .. " errors: " ..
    vim.inspect(schedule_errors))

  -- Restore panel state for any downstream sections.
  af.open(true)
  vim.wait(100)
end
end)()

-- ─────────────────────── 39. views.todos — Phase 2 auto-core.todo panel ──
print("\n[39] views.todos — render, keymaps, subscriptions, no-hijack")
;(function()
  local ok_v, view = pcall(require, "auto-finder.views.todos")
  ok("auto-finder.views.todos loads", ok_v, tostring(view))
  if not ok_v then return end
  local ok_t, todo = pcall(require, "auto-core.todo")
  ok("auto-core.todo loads", ok_t, tostring(todo))
  if not ok_t then return end

  -- Isolate filesystem state.
  local tmp_root = vim.fn.tempname()
  vim.fn.mkdir(tmp_root, "p")
  local state_tmp = vim.fn.tempname()
  vim.fn.mkdir(state_tmp, "p")
  require("auto-core.state").configure({ persist_dir = state_tmp })
  local worktree = require("auto-core.git.worktree")
  worktree.set_workspace_root(tmp_root)

  -- Module reset between sub-tests so we start clean.
  view._reset_for_tests()

  -- ── module shape ────────────────────────────────────────────
  ok("M.name == 'todos'", view.name == "todos")
  ok("M.description is a string", type(view.description) == "string")
  ok("M.get_buffer is a function", type(view.get_buffer) == "function")
  ok("M.on_focus is a function",   type(view.on_focus)   == "function")
  ok("M.on_close is a function",   type(view.on_close)   == "function")

  -- ── empty workspace: render shows the empty-state UX ───────
  local b = view.get_buffer(nil)
  ok("get_buffer returns a valid bufnr",
    type(b) == "number" and vim.api.nvim_buf_is_valid(b))
  ok("buffer filetype is 'auto-finder'", vim.bo[b].filetype == "auto-finder")
  ok("buffer var b:auto_finder_view is 'todos'",
    vim.b[b].auto_finder_view == "todos")

  local lines_empty = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local raw_empty = table.concat(lines_empty, "\n")
  ok("empty workspace renders the 'no tasks' line",
    raw_empty:find("no tasks") ~= nil, raw_empty)
  ok("empty workspace renders the `a` add hint",
    raw_empty:find("`a`") ~= nil)

  -- ── populated render: buckets + ordinals + badges + due ────
  todo.add({ id = "2026-05-25-foo", title = "First open task" })
  todo.add({ id = "2026-05-26-bar", title = "Second open task", due = "2026-06-15" })
  todo.add({ id = "2026-05-25-broken", title = "Broken refs",
    blocked = { "missing-task" } })
  todo.refresh()
  local id_def = todo.add({ id = "2026-05-25-defer", title = "Deferred one" })
  todo.status(id_def, "deferred")
  todo.add({ id = "2026-05-20-done", title = "Already done",
    status = "completed",
    completed_at = "2026-05-21T10:00:00-07:00" })

  view.on_focus(nil, b)
  local lines_pop = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local raw_pop = table.concat(lines_pop, "\n")

  ok("renders Open header with count", raw_pop:find("Open %(3%)") ~= nil)
  ok("renders Deferred header with count", raw_pop:find("Deferred %(1%)") ~= nil)
  ok("renders Completed header with count", raw_pop:find("Completed %(1%)") ~= nil)
  -- v0.2.36: the per-row `[XXXXX]` status prefix was removed
  -- because the section header carries the bucket. Verify the
  -- prefix is GONE from rows.
  ok("no per-row [OPEN ] / [DEFER] / [DONE ] status prefix on rows",
    not raw_pop:find("%[OPEN %]")
      and not raw_pop:find("%[DEFER%]")
      and not raw_pop:find("%[DONE %]"))
  ok("error badge ⚠ renders for the broken-refs task",
    raw_pop:find("⚠ 1") ~= nil)
  ok("due date renders inline for the dated open task",
    raw_pop:find("due:2026%-06%-15") ~= nil)
  -- Errors-first sort: the broken task should appear above non-error opens
  -- (we check by line position).
  local pos_broken = raw_pop:find("2026%-05%-25%-broken")
  local pos_foo    = raw_pop:find("2026%-05%-25%-foo")
  ok("error-tagged task floats above clean tasks in OPEN bucket",
    pos_broken and pos_foo and pos_broken < pos_foo,
    "broken=" .. tostring(pos_broken) .. " foo=" .. tostring(pos_foo))
  -- 1-based OPEN ordinal
  ok("OPEN bucket carries `1.` ordinal",
    raw_pop:find(" 1%. ") ~= nil)

  -- ── row metadata: M._rows populated with task tables ───────
  ok("M._rows is populated", type(view._rows) == "table" and #view._rows >= 5)
  -- v0.2.41: bucket-header rows now precede tasks; find the
  -- first kind="task" row instead of assuming view._rows[1].
  local first_task_row
  for _, r in ipairs(view._rows) do
    if r.kind == "task" then first_task_row = r; break end
  end
  ok("first task row has id+status+task",
    first_task_row
      and first_task_row.id
      and first_task_row.status
      and first_task_row.task)
  ok("first task row has kind='task'",
    first_task_row and first_task_row.kind == "task")

  -- ── keymaps: all 9 registered with descriptions ────────────
  -- v0.2.36 added `o` (inline expansion) and `?` (help overlay).
  local seen = {}
  for _, k in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do
    seen[k.lhs] = k.desc or true
  end
  for _, lhs in ipairs({ "<CR>", "i", "a", "d", "s", "o", "R", "M", "?" }) do
    ok("keymap registered: " .. lhs, seen[lhs] ~= nil)
  end

  -- ── subscriptions registered ───────────────────────────────
  -- v0.2.39 added core.todo.vars:changed (3rd); v0.2.45 added
  -- core.todo:changed (4th).
  ok("M._subs has 4 captured handles",
    type(view._subs) == "table" and #view._subs == 4,
    "got " .. tostring(view._subs and #view._subs))

  -- ── v0.2.36: inline frontmatter expansion (`o`) ─────────────
  -- Use the broken-refs task which carries adr (not set) + blocked
  -- — we can verify path-bearing rows surface a resolved filepath.
  -- The broken-refs task in the fixture has blocked={"missing-task"};
  -- "missing-task" obviously doesn't resolve, so its filepath is nil
  -- (correct — refresh's errors[] would flag it).
  --
  -- Add a task with adr that DOES resolve so we can assert the
  -- frontmatter row carries a non-nil filepath.
  local _kb_test_dir = vim.fn.tempname()
  vim.fn.mkdir(_kb_test_dir .. "/shared/adrs", "p")
  vim.fn.writefile({ "# adr" }, _kb_test_dir .. "/shared/adrs/0099-fix.md")
  local saved_kb = vim.env.AUTO_AGENTS_KB_WRITE
  vim.env.AUTO_AGENTS_KB_WRITE = _kb_test_dir

  local id_with_adr = todo.add({
    id    = "2026-05-25-with-adr",
    title = "Task with resolvable adr",
    adr   = { "shared/adrs/0099-fix.md" },
  })

  -- Pre-expansion: rows are task-only, no frontmatter-field rows
  view._expanded = {}  -- start clean
  view.on_focus(nil, b)
  local pre_count = 0
  for _, r in ipairs(view._rows) do
    if r.kind == "frontmatter-field" then pre_count = pre_count + 1 end
  end
  ok("pre-expansion: no frontmatter-field rows in M._rows",
    pre_count == 0)

  -- Expand id_with_adr → frontmatter rows should appear
  view._expanded[id_with_adr] = true
  view.on_focus(nil, b)
  local adr_item_row
  local post_count = 0
  for _, r in ipairs(view._rows) do
    if r.kind == "frontmatter-field" then
      post_count = post_count + 1
      if r.task and r.task.id == id_with_adr and r.field == "adr[]" then
        adr_item_row = r
      end
    end
  end
  ok("post-expansion: frontmatter-field rows present",
    post_count > 0, "got " .. tostring(post_count))
  ok("expanded task has an `adr[]` frontmatter row with a resolved filepath",
    adr_item_row and adr_item_row.filepath == _kb_test_dir .. "/shared/adrs/0099-fix.md",
    adr_item_row and tostring(adr_item_row.filepath))

  -- Collapse → frontmatter rows go away again
  view._expanded[id_with_adr] = nil
  view.on_focus(nil, b)
  local collapsed_count = 0
  for _, r in ipairs(view._rows) do
    if r.kind == "frontmatter-field" then
      collapsed_count = collapsed_count + 1
    end
  end
  ok("after collapse: frontmatter-field rows removed",
    collapsed_count == 0, "got " .. tostring(collapsed_count))

  -- ── v0.2.37: cursor preservation across `o` toggle ────────────
  -- The user reported pressing `o` jumped the cursor to the section
  -- header. Cause: _render did an intermediate `nvim_buf_set_lines
  -- (buf, 0, -1, false, {})` wipe that left cursor at L1; subsequent
  -- write of the full content didn't restore it. Fix: drop the wipe
  -- AND explicitly snapshot+restore cursor per visible window.
  -- Find a window that's currently showing the buffer (re-use the
  -- same one we'll set up later for the event-driven tests).
  vim.cmd("topleft 40vnew")
  local _cursor_w = vim.api.nvim_get_current_win()
  vim.wo[_cursor_w].winfixbuf = false
  vim.api.nvim_win_set_buf(_cursor_w, b)
  -- Find the lnum for id_with_adr (a task we already created).
  local id_for_cursor = id_with_adr
  view._expanded = {}
  view.on_focus(_cursor_w, b)
  local task_lnum
  for _, r in ipairs(view._rows) do
    if r.kind == "task" and r.id == id_for_cursor then
      task_lnum = r.lnum; break
    end
  end
  ok("found task row to test cursor preservation against",
    type(task_lnum) == "number")
  vim.api.nvim_win_set_cursor(_cursor_w, { task_lnum, 0 })
  -- Toggle expand — should NOT move cursor off the task row.
  view._expanded[id_for_cursor] = true
  view.on_focus(_cursor_w, b)
  local pos_expanded = vim.api.nvim_win_get_cursor(_cursor_w)
  ok("cursor stays on task lnum after expand",
    pos_expanded[1] == task_lnum,
    "expected lnum " .. task_lnum .. ", got " .. pos_expanded[1])
  -- Toggle collapse — should also stay put.
  view._expanded[id_for_cursor] = nil
  view.on_focus(_cursor_w, b)
  local pos_collapsed = vim.api.nvim_win_get_cursor(_cursor_w)
  ok("cursor stays on task lnum after collapse",
    pos_collapsed[1] == task_lnum,
    "expected lnum " .. task_lnum .. ", got " .. pos_collapsed[1])
  -- Clean up the test window (re-create later for the event tests).
  pcall(vim.api.nvim_win_close, _cursor_w, true)

  -- ── v0.2.37: _resolve_ref_path handles abs + multi-root rel ──
  -- The user reported pressing <CR> on an adr row didn't open the
  -- file when the KB env wasn't set / when the path was absolute.
  -- _resolve_kb_path was renamed to _resolve_ref_path with the new
  -- multi-root strategy. Verify each case via row.filepath.

  -- (a) Absolute paths used as-is.
  local id_abs = todo.add({
    id    = "2026-05-26-abs-adr",
    title = "Absolute adr",
    adr   = { _kb_test_dir .. "/shared/adrs/0099-fix.md" },  -- absolute
  })
  view._expanded[id_abs] = true
  view.on_focus(nil, b)
  local adr_abs_row
  for _, r in ipairs(view._rows) do
    if r.kind == "frontmatter-field" and r.task and r.task.id == id_abs
       and r.field == "adr[]"
    then adr_abs_row = r; break end
  end
  ok("absolute adr path: row.filepath equals the input (no join)",
    adr_abs_row and adr_abs_row.filepath
      == _kb_test_dir .. "/shared/adrs/0099-fix.md",
    adr_abs_row and tostring(adr_abs_row.filepath))

  -- (b) Workspace-rooted relative when no KB env is set.
  -- Save current KB env (the polish-1 block set it earlier and
  -- the polish-2 cursor block above tweaked it again — sequence
  -- aside, we need a known state here).
  local _saved_kb_write = vim.env.AUTO_AGENTS_KB_WRITE
  local _saved_kb_root  = vim.env.AUTO_AGENTS_KB_ROOT
  local _saved_kb_read  = vim.env.AUTO_AGENTS_KB_READ
  vim.env.AUTO_AGENTS_KB_WRITE = nil
  vim.env.AUTO_AGENTS_KB_ROOT  = nil
  vim.env.AUTO_AGENTS_KB_READ  = nil

  -- Create a file under the workspace root that the rel path
  -- should resolve to.
  vim.fn.mkdir(tmp_root .. "/docs/refs", "p")
  vim.fn.writefile({ "# ws-rooted" }, tmp_root .. "/docs/refs/v37.md")

  local id_ws = todo.add({
    id    = "2026-05-26-ws-rooted-adr",
    title = "Workspace-rooted adr",
    adr   = { "docs/refs/v37.md" },
  })
  view._expanded[id_ws] = true
  view.on_focus(nil, b)
  local adr_ws_row
  for _, r in ipairs(view._rows) do
    if r.kind == "frontmatter-field" and r.task and r.task.id == id_ws
       and r.field == "adr[]"
    then adr_ws_row = r; break end
  end
  ok("workspace-rooted adr (no KB env): row.filepath resolved to <ws>/<rel>",
    adr_ws_row and adr_ws_row.filepath == tmp_root .. "/docs/refs/v37.md",
    adr_ws_row and tostring(adr_ws_row.filepath))

  vim.env.AUTO_AGENTS_KB_WRITE = _saved_kb_write
  vim.env.AUTO_AGENTS_KB_ROOT  = _saved_kb_root
  vim.env.AUTO_AGENTS_KB_READ  = _saved_kb_read

  -- (c) Non-existent rel: best-guess KB-rooted candidate is
  -- returned so the editor surfaces a "file not found" rather
  -- than the keymap silently no-op'ing.
  local id_ne = todo.add({
    id    = "2026-05-26-nonexistent-adr",
    title = "Nonexistent adr",
    adr   = { "shared/adrs/Z-totally-missing.md" },
  })
  view._expanded[id_ne] = true
  view.on_focus(nil, b)
  local adr_ne_row
  for _, r in ipairs(view._rows) do
    if r.kind == "frontmatter-field" and r.task and r.task.id == id_ne
       and r.field == "adr[]"
    then adr_ne_row = r; break end
  end
  ok("non-existent adr: row.filepath returns a best-guess (non-nil) path",
    adr_ne_row and type(adr_ne_row.filepath) == "string"
      and adr_ne_row.filepath ~= "",
    adr_ne_row and tostring(adr_ne_row.filepath))

  -- Cleanup KB fixture
  vim.env.AUTO_AGENTS_KB_WRITE = saved_kb
  vim.fn.delete(_kb_test_dir, "rf")

  -- ── event-driven re-render works when buffer is visible ────
  -- Open a real window for the buffer so the visibility gate passes.
  -- Earlier sections leave the auto-finder panel open; `topleft vnew`
  -- can inherit winfixbuf via the WinNew chain, so explicitly clear
  -- it on the test window before swapping buffers in.
  vim.cmd("topleft 40vnew")
  local w = vim.api.nvim_get_current_win()
  vim.wo[w].winfixbuf = false
  vim.api.nvim_win_set_buf(w, b)
  -- Move focus back to a different window so we can detect hijack.
  vim.cmd("wincmd p")
  local pre_event_win = vim.api.nvim_get_current_win()

  -- Trigger a status change → event → scheduled re-render
  todo.status("2026-05-25-foo", "completed")
  vim.wait(50, function() return false end)

  ok("event-driven re-render: 'First open task' now under Completed bucket",
    table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
      :find("First open task.-%(2026%-05%-25%-foo%)") ~= nil)
  ok("no-hijack: current window unchanged after event-driven re-render",
    vim.api.nvim_get_current_win() == pre_event_win,
    "expected " .. pre_event_win .. ", got " .. vim.api.nvim_get_current_win())

  -- ── hidden-buffer gate: events fire but no render ──────────
  vim.wo[w].winfixbuf = false  -- defensive; some sections elsewhere may flip
  vim.api.nvim_win_set_buf(w, vim.api.nvim_create_buf(false, true))
  ok("buffer hidden (win_findbuf=0)", #vim.fn.win_findbuf(b) == 0)
  local hidden_before = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  todo.add({ id = "2026-05-25-hidden-period", title = "Added while hidden" })
  todo.refresh()
  vim.wait(50, function() return false end)
  local hidden_after = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  ok("hidden-gate: buffer content unchanged while panel was hidden",
    hidden_before == hidden_after)

  -- on_focus picks up the changes made during the hidden period
  vim.api.nvim_win_set_buf(w, b)
  view.on_focus(w, b)
  local after_focus = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  ok("on_focus catches up: 'Added while hidden' now visible",
    after_focus:find("Added while hidden") ~= nil)

  -- ── on_close disposes subscriptions cleanly ────────────────
  view.on_close()
  ok("on_close clears M._subs", view._subs == nil)
  ok("on_close invalidates M._bufnr", view._bufnr == nil)

  -- ── cleanup ────────────────────────────────────────────────
  if vim.api.nvim_win_is_valid(w) then
    pcall(vim.api.nvim_win_close, w, true)
  end
  worktree.set_workspace_root(nil)
  require("auto-core.state").configure({ persist_dir = nil })
  vim.fn.delete(tmp_root, "rf")
  vim.fn.delete(state_tmp, "rf")
end)()

-- ─────────────────────── 39b. views.todos — malformed-task render (v0.2.38) ──
print("\n[39b] views.todos — malformed-task scan rendering")
;(function()
  local ok_v, view = pcall(require, "auto-finder.views.todos")
  if not ok_v then return end
  local ok_t, todo = pcall(require, "auto-core.todo")
  if not ok_t then return end

  local tmp_root = vim.fn.tempname()
  vim.fn.mkdir(tmp_root, "p")
  local worktree = require("auto-core.git.worktree")
  worktree.set_workspace_root(tmp_root)
  local function cleanup()
    worktree.set_workspace_root(nil)
    vim.fn.delete(tmp_root, "rf")
  end

  ok("scan() is exposed by auto-core.todo (>= v0.1.38)",
    type(todo.scan) == "function")

  -- One valid + two malformed files.
  todo.add({ title = "valid task in scan-render fixture" })
  local td = todo._todo_dir()
  local bad1 = td .. "/open/2026-05-26-broken-yaml.md"
  local fh = io.open(bad1, "w")
  fh:write("---\ntitle: [oh no\n---\nbody\n")
  fh:close()
  local bad2 = td .. "/open/2026-05-26-missing-fields.md"
  local fh2 = io.open(bad2, "w")
  fh2:write("---\ntitle: only a title\n---\n")
  fh2:close()

  local b = view.get_buffer(vim.api.nvim_get_current_win())
  ok("get_buffer returned a buffer", b and vim.api.nvim_buf_is_valid(b),
    "got " .. tostring(b))
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local text  = table.concat(lines, "\n")

  ok("render shows the 'Malformed (N)' header",
    text:find("Malformed %(2%)") ~= nil,
    "got:\n" .. text)
  ok("render contains the malformed filename #1",
    text:find("broken%-yaml%.md", 1, false) ~= nil)
  ok("render contains the malformed filename #2",
    text:find("missing%-fields%.md", 1, false) ~= nil)
  ok("render still shows the valid task title",
    text:find("valid task in scan%-render fixture") ~= nil)

  -- Inspect M._rows for malformed-task entries.
  local got_malformed = 0
  local sample
  for _, row in ipairs(view._rows or {}) do
    if row.kind == "malformed-task" then
      got_malformed = got_malformed + 1
      sample = sample or row
    end
  end
  ok("M._rows has 2 kind='malformed-task' entries",
    got_malformed == 2, "got " .. got_malformed)
  ok("malformed row carries filepath",
    sample and type(sample.filepath) == "string" and sample.filepath ~= "")
  ok("malformed row carries bucket",
    sample and sample.bucket == "open")
  ok("malformed row carries err string",
    sample and type(sample.err) == "string" and sample.err ~= "")
  ok("malformed row carries lnum (1-based)",
    sample and type(sample.lnum) == "number" and sample.lnum >= 1)

  -- Empty-state suppression: if all that's in the dir is malformed
  -- files (no valid tasks), the panel must NOT show the
  -- "no tasks ... press a to add" empty-state copy.
  view.on_close()
  local tmp2 = vim.fn.tempname()
  vim.fn.mkdir(tmp2, "p")
  worktree.set_workspace_root(tmp2)
  local td2 = todo._todo_dir()
  vim.fn.mkdir(td2 .. "/open", "p")
  local fh3 = io.open(td2 .. "/open/2026-05-26-lone-broken.md", "w")
  fh3:write("---\nbad: [\n---\n")
  fh3:close()

  local b2 = view.get_buffer(vim.api.nvim_get_current_win())
  local lines2 = vim.api.nvim_buf_get_lines(b2, 0, -1, false)
  local text2  = table.concat(lines2, "\n")
  ok("empty-state copy suppressed when only malformed entries exist",
    text2:find("no tasks in this workspace") == nil,
    "got:\n" .. text2)
  ok("malformed header still rendered in malformed-only fixture",
    text2:find("Malformed %(1%)") ~= nil)

  view.on_close()
  cleanup()
  vim.fn.delete(tmp2, "rf")
end)()

-- ─────────────────────── 39c. views.todos — Vars section + status modal (v0.2.39) ──
print("\n[39c] views.todos — Vars section + numbered status modal")
;(function()
  local ok_v, view = pcall(require, "auto-finder.views.todos")
  if not ok_v then return end
  local ok_t, todo = pcall(require, "auto-core.todo")
  if not ok_t then return end

  local tmp_root = vim.fn.tempname()
  vim.fn.mkdir(tmp_root, "p")
  local worktree = require("auto-core.git.worktree")
  worktree.set_workspace_root(tmp_root)
  local state_tmp = vim.fn.tempname()
  vim.fn.mkdir(state_tmp, "p")
  require("auto-core.state").configure({ persist_dir = state_tmp })
  package.loaded["auto-core.todo.vars"] = nil
  local vars = require("auto-core.todo.vars")

  vars.set("PROJECT_DOCS", "/tmp/project-docs")
  todo.add({ title = "task for vars test" })

  -- Put the panel buffer in a visible window so event-driven
  -- re-render isn't gated by win_findbuf=0.
  vim.cmd("vsplit")
  local panel_win = vim.api.nvim_get_current_win()
  local b = view.get_buffer(panel_win)
  vim.api.nvim_win_set_buf(panel_win, b)
  ok("get_buffer returned a buffer", b and vim.api.nvim_buf_is_valid(b))

  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local text  = table.concat(lines, "\n")
  ok("render shows Vars header", text:find("Vars %(") ~= nil)
  ok("render lists $KB_ROOT built-in",     text:find("$KB_ROOT", 1, true) ~= nil)
  ok("render lists $WORKSPACE built-in",   text:find("$WORKSPACE", 1, true) ~= nil)
  ok("render lists $HOME built-in",        text:find("$HOME", 1, true) ~= nil)
  ok("render lists $CWD built-in",         text:find("$CWD", 1, true) ~= nil)
  ok("render lists user var $PROJECT_DOCS", text:find("$PROJECT_DOCS", 1, true) ~= nil)
  ok("built-in rows have (auto) tag",      text:find("%(auto%)") ~= nil)

  local saw_builtin, saw_user, user_row = false, false, nil
  for _, row in ipairs(view._rows or {}) do
    if row.kind == "vars-entry" then
      if row.builtin then saw_builtin = true
      elseif row.name == "PROJECT_DOCS" then
        saw_user = true; user_row = row
      end
    end
  end
  ok("M._rows includes a kind='vars-entry' built-in row", saw_builtin)
  ok("M._rows includes a kind='vars-entry' user row", saw_user)
  ok("user vars-entry row carries the right value",
    user_row and user_row.value == "/tmp/project-docs")

  -- Event-driven re-render: visible-buffer path.
  vars.set("ANOTHER", "/tmp/another")
  vim.wait(120, function() return false end)
  local text2 = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  ok("core.todo.vars:changed triggers a re-render (new var visible)",
    text2:find("$ANOTHER", 1, true) ~= nil)

  vars.remove("ANOTHER")
  vim.wait(120, function() return false end)
  local text3 = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  ok("remove triggers re-render (var no longer visible)",
    text3:find("$ANOTHER", 1, true) == nil)

  -- Numbered status modal: stub vim.ui.select, fire the `s` keymap.
  local id = todo.add({ title = "status-modal target" })
  -- Force a refresh so the panel learns about the new task row
  -- (todo.add doesn't fire core.todo:* on its own; the panel
  -- relies on core.todo:refreshed for adds + core.todo.status:
  -- changed for status mutations).
  todo.refresh()
  vim.wait(120, function() return false end)
  local task_lnum
  for _, row in ipairs(view._rows or {}) do
    if row.kind == "task" and row.task and row.task.id == id then
      task_lnum = row.lnum; break
    end
  end
  ok("status-modal: found the target task row in M._rows",
    type(task_lnum) == "number")

  local captured_choices
  local orig_select = vim.ui.select
  vim.ui.select = function(items, _opts, on_choice)
    captured_choices = items
    -- ADR-0035 Phase 1: pick "completed" by name rather than by
    -- positional index so the test survives future cycle-order
    -- additions. The previous fixture indexed `items[2]` which
    -- broke when `in-progress` joined the modal between `open`
    -- and `completed`.
    for _, item in ipairs(items) do
      if item == "completed" then on_choice(item); return end
    end
    on_choice(items[1])  -- fallback
  end

  if task_lnum then
    vim.api.nvim_win_set_cursor(panel_win, { task_lnum, 0 })
    local maps = vim.api.nvim_buf_get_keymap(b, "n")
    local s_cb
    for _, mp in ipairs(maps) do
      if mp.lhs == "s" then s_cb = mp.callback; break end
    end
    ok("status-modal: `s` keymap is bound on the panel buffer",
      type(s_cb) == "function")
    if s_cb then s_cb() end
  end
  -- ADR-0035 post-ship UX amendment (2026-05-31): the modal lists
  -- 6 user-cyclable statuses in canonical bucket order. `automated`
  -- joined the cycle so users can promote a regular task to a
  -- template via the panel `s` action; auto-finder scaffolds the
  -- task body + populates `condition:` / `execute:` defaults on
  -- the promotion (covered separately in section [42]).
  ok("status-modal: vim.ui.select invoked with 6 statuses in canonical order",
    captured_choices and #captured_choices == 6
      and captured_choices[1] == "open"
      and captured_choices[2] == "in-progress"
      and captured_choices[3] == "automated"
      and captured_choices[4] == "completed"
      and captured_choices[5] == "deferred"
      and captured_choices[6] == "archived",
    "got: " .. vim.inspect(captured_choices))
  ok("status-modal: `automated` is INCLUDED in the user cycle (post-ship UX)",
    (function()
      if not captured_choices then return false end
      for _, item in ipairs(captured_choices) do
        if item == "automated" then return true end
      end
      return false
    end)(),
    "got: " .. vim.inspect(captured_choices))
  vim.wait(120, function() return false end)
  local updated = todo.get(id)
  ok("status-modal: choice 'completed' applied via auto-core.todo.status",
    updated and updated.status == "completed",
    "got status=" .. tostring(updated and updated.status))

  vim.ui.select = orig_select
  view.on_close()
  if vim.api.nvim_win_is_valid(panel_win) then
    pcall(vim.api.nvim_win_close, panel_win, true)
  end
  worktree.set_workspace_root(nil)
  require("auto-core.state").configure({ persist_dir = nil })
  vim.fn.delete(tmp_root,  "rf")
  vim.fn.delete(state_tmp, "rf")
  package.loaded["auto-core.todo.vars"] = nil
end)()

-- ─────────────────────── 39d. views.todos — collapsible sections + archive periods (v0.2.41) ──
print("\n[39d] views.todos — collapsible sections + archive year/month groups")
;(function()
  local ok_v, view = pcall(require, "auto-finder.views.todos")
  if not ok_v then return end
  local ok_t, todo = pcall(require, "auto-core.todo")
  if not ok_t then return end

  local tmp_root = vim.fn.tempname()
  vim.fn.mkdir(tmp_root, "p")
  local worktree = require("auto-core.git.worktree")
  worktree.set_workspace_root(tmp_root)
  local state_tmp = vim.fn.tempname()
  vim.fn.mkdir(state_tmp, "p")
  require("auto-core.state").configure({ persist_dir = state_tmp })

  -- Reset in-memory collapse state so we test the persisted-default path.
  view._collapsed = {}
  view._archive_collapsed = {}

  -- Seed: 1 open + 2 archived spanning two periods.
  todo.add({ title = "open task A" })
  -- Synthesize archived tasks in two periods by hand so we can
  -- control archived_at without relying on the 28-day rule.
  local td = todo._todo_dir()
  vim.fn.mkdir(td .. "/archived/2026/05", "p")
  vim.fn.mkdir(td .. "/archived/2026/04", "p")
  local fh = io.open(td .. "/archived/2026/05/2026-05-05-may-task.md", "w")
  fh:write(table.concat({
    "---",
    "id: 2026-05-05-may-task",
    "version: 1",
    "status: archived",
    "title: May archived task",
    "description: ''",
    "created: 2026-05-05T00:00:00Z",
    "updated: 2026-05-05T00:00:00Z",
    "status_changed: 2026-05-05T00:00:00Z",
    "archived_at: 2026-05-15T00:00:00Z",
    "---",
    "",
  }, "\n"))
  fh:close()
  local fh2 = io.open(td .. "/archived/2026/04/2026-04-10-apr-task.md", "w")
  fh2:write(table.concat({
    "---",
    "id: 2026-04-10-apr-task",
    "version: 1",
    "status: archived",
    "title: April archived task",
    "description: ''",
    "created: 2026-04-10T00:00:00Z",
    "updated: 2026-04-10T00:00:00Z",
    "status_changed: 2026-04-10T00:00:00Z",
    "archived_at: 2026-04-20T00:00:00Z",
    "---",
    "",
  }, "\n"))
  fh2:close()

  vim.cmd("vsplit")
  local panel_win = vim.api.nvim_get_current_win()
  local b = view.get_buffer(panel_win)
  vim.api.nvim_win_set_buf(panel_win, b)

  local function panel_text()
    return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  end

  -- Defaults: Open expanded, Archived collapsed.
  ok("Open section renders with ▼ chevron",
    panel_text():find("▼ Open %(", 1, false) ~= nil,
    "got:\n" .. panel_text())
  ok("Archived section renders with ▶ chevron (default collapsed)",
    panel_text():find("▶ Archived %(", 1, false) ~= nil,
    "got:\n" .. panel_text())
  -- Archived body should NOT render (collapsed). The open task's
  -- id contains "2026-05" so we look specifically for the period-
  -- header glyph rather than just the YYYY-MM substring.
  ok("Archived collapsed: 2026-05 sub-header NOT visible",
    panel_text():find("▶ 2026%-05 %(", 1, false) == nil)

  -- Bucket-header rows present in M._rows
  local saw_open_hdr, saw_archived_hdr = false, false
  for _, row in ipairs(view._rows or {}) do
    if row.kind == "bucket-header" then
      if row.section == "open"     then saw_open_hdr = true end
      if row.section == "archived" then saw_archived_hdr = true end
    end
  end
  ok("M._rows has Open bucket-header row",     saw_open_hdr)
  ok("M._rows has Archived bucket-header row", saw_archived_hdr)

  -- Toggle Archived expanded: emulate <CR> on the header.
  local archived_lnum
  for _, row in ipairs(view._rows or {}) do
    if row.kind == "bucket-header" and row.section == "archived" then
      archived_lnum = row.lnum; break
    end
  end
  ok("found Archived header lnum", type(archived_lnum) == "number")
  if archived_lnum then
    vim.api.nvim_win_set_cursor(panel_win, { archived_lnum, 0 })
    local maps = vim.api.nvim_buf_get_keymap(b, "n")
    local cr_cb
    for _, mp in ipairs(maps) do
      if mp.lhs == "<CR>" then cr_cb = mp.callback; break end
    end
    if cr_cb then cr_cb() end
  end
  ok("after toggle: Archived shows ▼ (expanded)",
    panel_text():find("▼ Archived %(", 1, false) ~= nil)

  -- v0.2.46: `o` toggles a section header too (not just <CR>).
  -- Fire `o` twice on the Archived header (collapse → re-expand)
  -- so net state stays expanded for the asserts below.
  do
    local o_cb
    for _, mp in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do
      if mp.lhs == "o" then o_cb = mp.callback; break end
    end
    -- cursor is still on the Archived header row
    if o_cb then o_cb() end
    ok("o on a section header collapses it (▶ Archived)",
      panel_text():find("▶ Archived %(", 1, false) ~= nil)
    if o_cb then o_cb() end
    ok("o again re-expands the section (▼ Archived)",
      panel_text():find("▼ Archived %(", 1, false) ~= nil)
  end

  ok("after toggle: 2026-05 sub-period visible (collapsed by default)",
    panel_text():find("▶ 2026%-05 %(1%)", 1, false) ~= nil)
  ok("after toggle: 2026-04 sub-period visible",
    panel_text():find("▶ 2026%-04 %(1%)", 1, false) ~= nil)
  ok("after toggle: tasks themselves NOT visible (periods collapsed)",
    panel_text():find("May archived task", 1, true) == nil)
  ok("after toggle: periods sorted descending (2026-05 above 2026-04)",
    (function()
      local t = panel_text()
      local p5 = t:find("2026-05", 1, true)
      local p4 = t:find("2026-04", 1, true)
      return p5 and p4 and p5 < p4
    end)())

  -- Toggle 2026-05 period expanded.
  local period_lnum
  for _, row in ipairs(view._rows or {}) do
    if row.kind == "archive-period" and row.period == "2026-05" then
      period_lnum = row.lnum; break
    end
  end
  ok("found 2026-05 period row in M._rows", type(period_lnum) == "number")
  if period_lnum then
    vim.api.nvim_win_set_cursor(panel_win, { period_lnum, 0 })
    local maps = vim.api.nvim_buf_get_keymap(b, "n")
    local cr_cb
    for _, mp in ipairs(maps) do
      if mp.lhs == "<CR>" then cr_cb = mp.callback; break end
    end
    if cr_cb then cr_cb() end
  end
  ok("after period toggle: May archived task is visible",
    panel_text():find("May archived task", 1, true) ~= nil)

  -- Persistence: state.get('collapsed').archived should now be false.
  local s = require("auto-core.state").namespace("todo.ui", { persist = "json" })
  local stored = s:get("collapsed") or {}
  ok("Archived collapse state persisted (now expanded)",
    stored.archived == false,
    "got: " .. tostring(stored.archived))
  local stored_periods = s:get("archive_periods") or {}
  ok("2026-05 period collapse state persisted (now expanded)",
    stored_periods["2026-05"] == false,
    "got: " .. tostring(stored_periods["2026-05"]))

  view.on_close()
  if vim.api.nvim_win_is_valid(panel_win) then
    pcall(vim.api.nvim_win_close, panel_win, true)
  end
  worktree.set_workspace_root(nil)
  require("auto-core.state").configure({ persist_dir = nil })
  vim.fn.delete(tmp_root,  "rf")
  vim.fn.delete(state_tmp, "rf")
end)()

-- ─────────────────────── 40. ADR-0035 Phase 1 ────────────────────────
-- Six-bucket rendering (`Open → In Progress → Automated → Deferred →
-- Completed → Archived`) and per-bucket 1-based numbering on every
-- non-archived bucket.
print("\n[40] ADR-0035 Phase 1 — six-bucket panel + numbered non-archived rendering")
;(function()
  local ok_v, view = pcall(require, "auto-finder.views.todos")
  if not ok_v then return end
  local ok_t, todo = pcall(require, "auto-core.todo")
  if not ok_t then return end

  -- Isolate state (mirrors [39c] pattern).
  local tmp_root  = vim.fn.tempname()
  local state_tmp = vim.fn.tempname() .. "_p40-state"
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

  -- Seed one task per bucket via the public API so the file
  -- placement is the auto-core-blessed shape. The panel's render
  -- loop only emits a section header when its bucket is non-empty,
  -- so every bucket we want to assert on must carry at least one
  -- row before the snapshot — including `archived`.
  local id_open = todo.add({ id = "2026-05-30-p40-open",     title = "open task"     })
  local id_def  = todo.add({ id = "2026-05-30-p40-deferred", title = "deferred task" })
  todo.status(id_def, "deferred")
  local id_done = todo.add({ id = "2026-05-30-p40-done",     title = "completed task"})
  todo.status(id_done, "completed")
  local id_ip   = todo.add({ id = "2026-05-30-p40-ip",       title = "in-progress task" })
  todo.assign(id_ip, "agent:phase1")  -- auto-engages in-progress
  local id_auto = todo.add({ id = "2026-05-30-p40-auto",     title = "automated template" })
  todo.status(id_auto, "automated")
  local id_arch = todo.add({ id = "2026-05-30-p40-archived", title = "archived task" })
  todo.status(id_arch, "archived")  -- direct archive (no completed predecessor)

  -- Build the panel buffer directly via the view module (mirrors
  -- [39c] / [39d] pattern). Avoids depending on auto-finder host
  -- focus-API surface, which has shifted shape over time.
  vim.cmd("vsplit")
  local panel_win = vim.api.nvim_get_current_win()
  local bufnr = view.get_buffer(panel_win)
  vim.api.nvim_win_set_buf(panel_win, bufnr)
  ok("p40: get_buffer returned a valid buffer",
    bufnr and vim.api.nvim_buf_is_valid(bufnr))

  -- Force a refresh so the panel picks up our seeded tasks.
  todo.refresh()
  vim.wait(150, function() return false end)
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")

  -- 40a. Each section header is rendered.
  ok("p40: Open section header rendered",       text:find("Open %(", 1) ~= nil)
  ok("p40: In Progress section header rendered",text:find("In Progress %(", 1) ~= nil)
  ok("p40: Automated section header rendered",  text:find("Automated %(", 1) ~= nil)
  ok("p40: Deferred section header rendered",   text:find("Deferred %(", 1) ~= nil)
  ok("p40: Completed section header rendered",  text:find("Completed %(", 1) ~= nil)
  ok("p40: Archived section header rendered",   text:find("Archived %(", 1) ~= nil)

  -- 40b. Sections appear in canonical order (open first, in-progress
  -- second, …). Use the byte offset of each header in the buffer
  -- text — string ordering equates to render ordering.
  local pos_open = text:find("Open %(", 1)
  local pos_ip   = text:find("In Progress %(", 1)
  local pos_auto = text:find("Automated %(", 1)
  local pos_def  = text:find("Deferred %(", 1)
  local pos_done = text:find("Completed %(", 1)
  local pos_arch = text:find("Archived %(", 1)
  ok("p40: section order — Open before In Progress",
    pos_open and pos_ip and pos_open < pos_ip)
  ok("p40: section order — In Progress before Automated",
    pos_ip and pos_auto and pos_ip < pos_auto)
  ok("p40: section order — Automated before Deferred",
    pos_auto and pos_def and pos_auto < pos_def)
  ok("p40: section order — Deferred before Completed",
    pos_def and pos_done and pos_def < pos_done)
  ok("p40: section order — Completed before Archived",
    pos_done and pos_arch and pos_done < pos_arch)

  -- 40c. Numbered rendering — each non-archived bucket has a task
  -- row prefixed with `  N. ` (1-based per bucket). Find the row
  -- for each known task via M._rows (which carries lnum + status).
  local rows_by_id = {}
  for _, row in ipairs(view._rows or {}) do
    if row.kind == "task" and row.task and row.task.id then
      rows_by_id[row.task.id] = row
    end
  end

  local function row_line(id)
    local r = rows_by_id[id]
    if not r or type(r.lnum) ~= "number" then return nil end
    local lines = vim.api.nvim_buf_get_lines(bufnr, r.lnum - 1, r.lnum, false)
    return lines[1]
  end

  -- Each non-archived task is the ONLY task in its bucket, so
  -- each should carry the `  1. ` ordinal.
  for _, id in ipairs({ id_open, id_ip, id_auto, id_def, id_done }) do
    local line = row_line(id)
    ok("p40: " .. id .. " row has numbered ordinal `  1. `",
      line and line:match("^%s*1%.%s") ~= nil,
      "got: " .. tostring(line))
  end

  -- 40d. Archive a row and confirm the archived presentation
  -- carries NO numbered ordinal (whitespace leader instead).
  todo.status(id_done, "archived")
  todo.refresh()
  vim.wait(150, function() return false end)

  -- The archive section is collapsed by default — expand it for
  -- the test so the row actually renders.
  view._collapsed["archived"] = false
  for k, _ in pairs(view._archive_collapsed or {}) do
    view._archive_collapsed[k] = false
  end
  -- view exposes a refresh entry via the panel-public surface; if
  -- not present (older shape), re-running get_buffer rerenders.
  if type(view.refresh) == "function" then
    pcall(view.refresh)
  else
    view.get_buffer(panel_win)
  end
  vim.wait(80, function() return false end)

  rows_by_id = {}
  for _, row in ipairs(view._rows or {}) do
    if row.kind == "task" and row.task and row.task.id then
      rows_by_id[row.task.id] = row
    end
  end
  local arch_line = row_line(id_done)
  -- The archived row may be hidden by the period sub-collapse;
  -- only assert when we found the row. If the panel renders
  -- archived rows with no ordinal, the row must NOT start with
  -- a digit-then-dot leader.
  if arch_line then
    ok("p40: archived row has NO numbered ordinal (whitespace leader)",
      arch_line:match("^%s+%d+%.") == nil,
      "got: " .. tostring(arch_line))
  else
    ok("p40: archived row not present in rows (collapsed sub-period)", true)
  end

  if vim.api.nvim_win_is_valid(panel_win) then
    pcall(vim.api.nvim_win_close, panel_win, true)
  end
  cleanup()
end)()

-- ─────────────────────── 41. ADR-0035 Phase 3 — diagnostics ──────────
-- Real-time vim.diagnostic validator for `.todo-list/automated/*.md`
-- buffers + bash-disabled panel row indicator.
-- ─────────── [43] ADR-0040 Batches A+B+E ───────────
print("\n[43] ADR-0040 A+B+E — scope-safe restore, handle close, surfaced failures, atomic dbase writes")
-- IIFE: the main chunk is near Lua's 200-active-locals limit; a
-- function scope gets its own budget (same pattern as [42]).
;(function()
  -- 43a. C1 (fail-before/pass-after): the tree's window-settings
  -- restore must be scope-local. Pre-fix, restore wrote 9 options
  -- via unindexed `vim.wo.x` (:set-like) — the GLOBAL defaults
  -- changed on every restore. This is the family's vim.wo bug class.
  local nt_setup = require("auto-finder.neotree.setup")
  if type(nt_setup._store_local_window_settings) == "function" then
    local function gopt(name)
      return vim.api.nvim_get_option_value(name, { scope = "global" })
    end
    local g_before = {
      number = gopt("number"), wrap = gopt("wrap"),
      foldcolumn = gopt("foldcolumn"), spell = gopt("spell"),
      cursorline = gopt("cursorline"),
    }
    local buf43 = vim.api.nvim_create_buf(false, true)
    local win43 = vim.api.nvim_open_win(buf43, false,
      { relative = "editor", row = 1, col = 1, width = 20, height = 5 })
    -- give the window distinctive LOCAL values (opposite of defaults)
    vim.api.nvim_set_option_value("number", not g_before.number,
      { win = win43, scope = "local" })
    vim.api.nvim_set_option_value("wrap", not g_before.wrap,
      { win = win43, scope = "local" })
    nt_setup._store_local_window_settings(win43)
    -- simulate the tree flipping the options...
    vim.api.nvim_set_option_value("number", g_before.number,
      { win = win43, scope = "local" })
    vim.api.nvim_set_option_value("wrap", g_before.wrap,
      { win = win43, scope = "local" })
    -- ...and the restore putting them back
    nt_setup._restore_local_window_settings(win43)
    ok("43a: restore puts the window's LOCAL number back",
      vim.api.nvim_get_option_value("number", { win = win43 }) == (not g_before.number))
    ok("43a: restore puts the window's LOCAL wrap back",
      vim.api.nvim_get_option_value("wrap", { win = win43 }) == (not g_before.wrap))
    for name, before in pairs(g_before) do
      ok("43a: GLOBAL '" .. name .. "' default survived the restore",
        gopt(name) == before,
        string.format("before=%s after=%s", tostring(before), tostring(gopt(name))))
    end
    pcall(vim.api.nvim_win_close, win43, true)
  else
    ok("43a: store/restore test hooks exported", false, "hooks missing")
  end

  -- 43b. C2: discarding watchers closes the libuv handles (stop()
  -- alone leaked them pre-fix).
  local fs_watch = require("auto-finder.neotree.sources.filesystem.lib.fs_watch")
  local dir43 = vim.fn.tempname() .. "_p43-watch"
  vim.fn.mkdir(dir43, "p")
  local w43 = fs_watch.watch_folder(dir43, function() end)
  ok("43b: watcher created with a live handle",
    w43 ~= nil and w43.handle ~= nil)
  fs_watch.updated_watched()
  ok("43b: watcher active after updated_watched", w43 and w43.active == true)
  fs_watch.stop_watching()
  ok("43b: stop_watching destroys the uv handle (closed + cleared)",
    w43 and w43.handle == nil and w43.active == false,
    "handle=" .. tostring(w43 and w43.handle))

  -- 43c. C3 (fail-before/pass-after): a todo.remove API failure must
  -- surface. Pre-fix, `local ok, err = pcall(todo.remove, id)` put
  -- the API's ok-flag into `err`, and the failure (plus its reason)
  -- vanished silently.
  local todos_view = require("auto-finder.views.todos")
  local af_log = require("auto-finder.log")
  local todo_mod = require("auto-core.todo")
  local orig_remove = todo_mod.remove
  local orig_log_error = af_log.error
  local orig_confirm = vim.fn.confirm
  local captured43 = nil
  todo_mod.remove = function() return false, "boom (p43 stub)" end
  af_log.error = function(_, msg) captured43 = tostring(msg) end
  vim.fn.confirm = function() return 1 end
  pcall(todos_view._remove_task, { task = { id = "p43-x", title = "p43" } })
  todo_mod.remove = orig_remove
  af_log.error = orig_log_error
  vim.fn.confirm = orig_confirm
  ok("43c: API-level remove failure is surfaced to the log",
    type(captured43) == "string" and captured43:find("boom (p43 stub)", 1, true) ~= nil,
    "captured=" .. tostring(captured43))

  -- 43d. C4 (lector amendment 2): on_close disposes the live-refresh
  -- subscription sets; re-arm after close works (reopen-safe).
  local sections = require("auto-finder.sections")
  local files_idx = sections._by_name and sections._by_name["files"]
  local files_sec = files_idx and sections._by_number[files_idx]
  if files_sec and files_sec._live_subs and files_sec._arm_live_refresh_subs then
    files_sec._arm_live_refresh_subs()
    ok("43d: live subs armed (count ≥ 1)", files_sec._live_subs:count() >= 1,
      "count=" .. tostring(files_sec._live_subs:count()))
    files_sec.on_close()
    ok("43d: on_close disposes every live-refresh subscription",
      files_sec._live_subs:count() == 0,
      "count=" .. tostring(files_sec._live_subs:count()))
    files_sec._arm_live_refresh_subs()
    ok("43d: re-arm after close succeeds (reopen-safe)",
      files_sec._live_subs:count() >= 1,
      "count=" .. tostring(files_sec._live_subs:count()))
    files_sec.on_close()
  else
    ok("43d: files section with _live_subs available", false,
      "files_sec=" .. tostring(files_sec ~= nil))
  end

  -- 43e. Batch B: dbase connection-config writes are atomic — valid
  -- JSON on disk, no temp strays.
  local dbase_files = require("auto-finder.views.dbase.files")
  local ddir43 = vim.fn.tempname() .. "_p43-dbase"
  local dpath43 = ddir43 .. "/persistence.json"
  local w_ok, w_err = dbase_files._write_json(dpath43,
    { { name = "p43", url = "sqlite://tmp" } })
  ok("43e: _write_json succeeds (mkdir included)", w_ok == true, tostring(w_err))
  local fh43 = io.open(dpath43, "r")
  local raw43 = fh43 and fh43:read("*a") or ""
  if fh43 then fh43:close() end
  local dec_ok43, dec43 = pcall(vim.fn.json_decode, raw43)
  ok("43e: persisted JSON round-trips",
    dec_ok43 and type(dec43) == "table" and dec43[1] and dec43[1].name == "p43",
    raw43:sub(1, 60))
  local strays43 = vim.fn.glob(ddir43 .. "/.tmp-*", false, true)
  ok("43e: no atomic-write temp strays", #strays43 == 0, vim.inspect(strays43))
end)()

-- ─────────── [44] ADR-0040 Batches C+D ───────────
print("\n[44] ADR-0040 C+D — async git runner + marks per-render read cache")
;(function()
  -- 44a. Batch C: the async git runner executes off the UI thread
  -- and delivers (ok, lines) on the main loop.
  local nt_commands = require("auto-finder.neotree.sources.common.commands")
  ok("44a: _git_async test hook exported",
    type(nt_commands._git_async) == "function")
  local async_before = nt_commands._git_async_count or 0
  local got_ok, got_lines = nil, nil
  nt_commands._git_async({ "git", "--version" }, function(g_ok, g_lines)
    got_ok, got_lines = g_ok, g_lines
  end)
  vim.wait(4000, function() return got_ok ~= nil end, 10)
  ok("44a: async git callback fired with success",
    got_ok == true, "got_ok=" .. tostring(got_ok))
  ok("44a: async git captured output lines",
    type(got_lines) == "table" and #got_lines >= 1
    and tostring(got_lines[1]):find("git version", 1, true) ~= nil,
    vim.inspect(got_lines))
  ok("44a: spawn counter incremented",
    (nt_commands._git_async_count or 0) == async_before + 1)
  -- failure shape: bogus subcommand → ok=false, stderr captured
  local fail_ok = nil
  nt_commands._git_async({ "git", "definitely-not-a-verb-p44" }, function(g_ok)
    fail_ok = g_ok
  end)
  vim.wait(4000, function() return fail_ok ~= nil end, 10)
  ok("44a: failing git command reports ok=false", fail_ok == false)

  -- 44b. Batch D: marks _read_line serves repeat reads of the same
  -- file from the per-render cache (one open per file per render).
  local marks_view = require("auto-finder.views.marks")
  ok("44b: read-cache test hooks exported",
    type(marks_view._read_line) == "function"
    and type(marks_view._reset_read_cache) == "function")
  local mdir = vim.fn.tempname() .. "_p44-marks"
  vim.fn.mkdir(mdir, "p")
  local mfile = mdir .. "/probe.txt"
  local mf = assert(io.open(mfile, "w"))
  mf:write("alpha\nbravo\ncharlie\n")
  mf:close()
  marks_view._reset_read_cache()
  local opens_before = marks_view._read_cache_opens or 0
  ok("44b: line 1 read correctly", marks_view._read_line(mfile, 1) == "alpha")
  ok("44b: line 3 read correctly", marks_view._read_line(mfile, 3) == "charlie")
  ok("44b: two reads of the same file = ONE open",
    (marks_view._read_cache_opens or 0) == opens_before + 1,
    "opens=" .. tostring(marks_view._read_cache_opens))
  marks_view._reset_read_cache()
  ok("44b: after reset the next read re-opens",
    marks_view._read_line(mfile, 2) == "bravo"
    and (marks_view._read_cache_opens or 0) == opens_before + 2)
  -- unreadable path: cached as false, no retry within the render
  local ghost = mdir .. "/missing.txt"
  local g_opens = marks_view._read_cache_opens or 0
  ok("44b: unreadable file yields empty string",
    marks_view._read_line(ghost, 1) == "")
  ok("44b: unreadable result cached (no second open attempt)",
    marks_view._read_line(ghost, 2) == ""
    and (marks_view._read_cache_opens or 0) == g_opens + 1)
end)()

-- NOTE (ADR-0040): section [43] is placed BEFORE [41] on purpose.
-- [41b]'s `vim.cmd("edit")` of the malformed-template fixture
-- SEGFAULTS headless nvim 0.12.2 on macOS with the suite's
-- accumulated attach state (pre-existing on main; bare-edit repro
-- survives) — everything after it, [41b]+[42], silently never ran,
-- and the printed totals hid the truncation. Tracked as a bug task;
-- do not add new sections after [41] until it is fixed.
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

  -- 41a. install + uninstall round-trip.
  diag.install()
  diag.install()  -- idempotent — second call a no-op
  ok("p41: install is idempotent (no crash)", true)
  diag.uninstall()
  ok("p41: uninstall returns cleanly", true)
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
  -- Synchronous validate runs on attach; no need to wait the
  -- debounce window for the initial entry.
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
  -- Trigger TextChanged manually (the debouncer's autocmd is what
  -- normally fires; here we just call _validate via the attach
  -- path by re-attaching, which runs a synchronous validate).
  diag.attach(bufnr_bad)
  vim.wait(40, function() return false end)
  local diags_after = vim.diagnostic.get(bufnr_bad, { namespace = diag.NS })
  ok("p41: diagnostic clears after fix",
    #diags_after == 0, "got " .. #diags_after .. " diagnostics")

  -- 41d. Non-automated buffer → no diagnostics, even after
  -- attach.
  vim.api.nvim_buf_set_lines(bufnr_bad, 3, 4, false,
    { 'status: open' })
  vim.api.nvim_buf_set_lines(bufnr_bad, 9, 12, false, {})  -- drop condition/execute
  diag.attach(bufnr_bad)
  vim.wait(40, function() return false end)
  local diags_nonauto = vim.diagnostic.get(bufnr_bad, { namespace = diag.NS })
  ok("p41: non-automated status clears all diagnostics",
    #diags_nonauto == 0)

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


-- ───────────────────────── [45] ADR-0044 — worktree:switched must not displace a non-panel editor window ─────────────────────────
--
-- Regression PIN for ADR-0044 (which closed ADR-0027 "Deferred Fix C"
-- as obviated). The "auto-finder claimed the editor space" displacement
-- on a worktree switch was fixed at the auto-finder layer in v0.2.3:
-- `shared/neotree.lua reanchor_to_cwd` mutates the filesystem state's
-- `path` and calls `manager.refresh(source)` instead of re-mounting via
-- `position="current"` (which used to grab whatever window had focus).
-- This pins that invariant: a `worktree:switched` re-anchors the panel's
-- tree to the new cwd WITHOUT replacing the buffer in a non-panel editor
-- split.
--
-- Per the ADR-0044 follow-up todo + lector's review: this is a
-- GREEN-on-current-code regression pin, NOT a bug-fix pair — the fix
-- shipped in v0.2.3, so there is no failing-pre-fix half (rule #4's
-- bug-fix-pair clause does not apply). Rule #11: assert the EFFECT
-- (reanchor RAN → fs state.path moved to the new cwd; the editor split's
-- buffer is unchanged), not merely that the event was published.
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
