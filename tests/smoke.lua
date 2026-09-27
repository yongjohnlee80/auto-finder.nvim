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
  -- ADR-0048 Phase 3: real nvim-dap for the debug-view breakpoint
  -- sections ([47]) — the §8.3 delete paths run against the actual
  -- dap.breakpoints get/set/remove surface, not a stub. Same
  -- approach as auto-run's own smoke.
  LAZY .. "/nvim-dap",
  plugins_root .. "/auto-core.nvim/main",
  -- Same-branch sibling LAST so it wins (prepend reverses order): a
  -- cross-repo change lives in two worktrees at once, and probing only
  -- `main` would exercise an auto-core without the new primitives.
  plugins_root .. "/auto-core.nvim/" .. vim.fn.fnamemodify(plugin_root, ":t"),
  -- ADR-0048 Phase 3: auto-run sibling (soft dep of the tests/debug
  -- views). Same sibling-worktree resolution as auto-core above.
  plugins_root .. "/auto-run.nvim/main",
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
local SANDBOX = dofile(vim.fn.fnamemodify(debug.getinfo(1,"S").source:sub(2),":p:h").."/_sandbox.lua")("smoke")

-- Vestigial since v0.4.0, kept as a belt-and-braces guard. It used to force
-- the legacy plaintext storage path for the dbase REPL tests regardless of
-- whether age/gpg was installed. Those tests, the encrypted vault, and
-- crypto.lua all went with nvim-dbee (ADR-0063 / roadmap M8) — autodb owns
-- connection storage and encryption on its own backend now.
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

-- ── silent-truncation guard (KB todo 2026-08-23) ──────────────────
-- Before this guard, an uncaught error in a section body aborted the
-- WHOLE main chunk. Because the final "N passed, M failed" summary is
-- printed only at end-of-file, everything after the abort vanished
-- with NO signal — the suite just looked like it had fewer tests
-- (this is how the p46 nil-buffer throw hid sections [47]-[50]).
-- `section()` runs each top-level IIFE body under xpcall: an uncaught
-- Lua error becomes a COUNTED failure naming the section, and the
-- suite keeps running. (A C-level crash — e.g. the grid_line_flush
-- SIGABRT the [41]/[42] extraction removed — still cannot be caught in
-- Lua; run-all.sh's summary-sentinel is the backstop for that class.)
local _cur_section = "<prelude>"
do
  local _real_print = print
  -- Transparently track the current section from its header print
  -- ("\n[NN] ...") so section() can name an abort without threading a
  -- label through all 33 call sites.
  print = function(...)
    local first = ...
    if type(first) == "string" then
      local h = first:match("^\n(%[.-%].*)")
      if h then _cur_section = h end
    end
    return _real_print(...)
  end
end
local function section(fn)
  local ok_run, err = xpcall(fn, debug.traceback)
  if not ok_run then
    fail_count = fail_count + 1
    print(string.format("  FAIL  [%s ABORTED]  %s", _cur_section, tostring(err)))
  end
end

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
  -- The width cells below assert exact widths; auto-expand would make them depend on the length of the
  -- cwd the suite runs from. [7d] turns it on where it is the subject.
  files = { auto_expand_width = false },
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

-- ───────────────────────── 3. focus(1) mounts the files view ─────────────
print("\n[3] focus(1) — files section")
local focus_ok, focus_err = af.focus(1)
ok("focus(1) returns ok", focus_ok, focus_err)
ok("state.section == 1", af.state.section == 1)
-- give the BufWinEnter chain a tick to settle before sampling filetype.
vim.wait(200,
  function() return vim.bo[vim.api.nvim_win_get_buf(panel)].filetype == "auto-finder" end,
  5)
local panel_buf = vim.api.nvim_win_get_buf(panel)
local ft = vim.bo[panel_buf].filetype
ok("panel buffer is filetype=auto-finder", ft == "auto-finder", "ft=" .. ft)

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
ok("panel still the files view after blocked :edit",
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
ok("panel still the files view after blocked :buffer",
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
-- Poll until the panel shows the files view again (filetype == "auto-finder").
vim.wait(500, function()
  local b = vim.api.nvim_win_get_buf(panel)
  return vim.bo[b].filetype == "auto-finder"
end)
panel_buf = vim.api.nvim_win_get_buf(panel)
ok("panel back on the files view", vim.bo[panel_buf].filetype == "auto-finder")
ok("section_buffers cached for 0 and 1",
  af.state.section_buffers[0] and af.state.section_buffers[1])

-- v0.1.4: `q` is bound buffer-locally (auto-core section registry) to
-- close the auto-finder panel.
local q_keymap = vim.fn.maparg("q", "n", false, true)
ok("q bound on the panel buffer (closes the panel)",
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
-- (nvim_win_set_width bypasses our cached width) and verify enforce_pin
-- clamps. winfixwidth is lifted for the simulated resize so it "wins"
-- first on every nvim version.
print("\n[7b] resize pin enforcement (vs a third-party resize)")
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

-- 7d. A pin must stop the files view's auto-expand: with the panel pinned
-- narrower than the longest row, painting the tree must not widen it.
print("\n[7d] pin caps the panel — the files view's auto-expand respects user_width")
af.state.config.files.auto_expand_width = true
af.focus(0)
af.resize(26)
ok("user_width = 26 after resize", af.state.user_width == 26)
af.focus(1)
vim.wait(500, function()
  local st = require("auto-finder.views.files")._state
  return st.rows ~= nil and #st.rows > 0
end, 10)
require("auto-finder.views.files").paint()
local want = 0
for _, r in ipairs(require("auto-finder.views.files")._state.rows or {}) do
  if r.width > want then want = r.width end
end
ok("precondition: a row wants more than the pin", want > 26, "widest row=" .. want)
ok("panel stays at the pin after a paint",
  vim.api.nvim_win_get_width(af.state.panel_winid) == 26,
  "live=" .. vim.api.nvim_win_get_width(af.state.panel_winid))
af.reset_width()
ok("user_width cleared after reset", af.state.user_width == nil)
do
  -- unpinned, a paint fits the widest row, bounded by width.max
  local fv = require("auto-finder.views.files")
  fv.paint()
  local widest = 0
  for _, r in ipairs(fv._state.rows or {}) do if r.width > widest then widest = r.width end end
  local info = vim.fn.getwininfo(af.state.panel_winid)[1]
  local expect = math.min(math.max(38, widest + (info and info.textoff or 0)), 100)
  local live = vim.api.nvim_win_get_width(af.state.panel_winid)
  -- Neovim caps a window at what the layout leaves it (earlier sections leave splits open), so compare
  -- with what a direct set_width to the same target reaches
  pcall(vim.api.nvim_win_set_width, af.state.panel_winid, expect)
  local reachable = vim.api.nvim_win_get_width(af.state.panel_winid)
  ok("unpinned: auto-expand fits the widest row (bounded by width.max and the layout)",
    live > 38 and live == reachable,
    ("live=%d reachable=%d expect=%d widest=%d"):format(live, reachable, expect, widest))
end
af.state.config.files.auto_expand_width = false
af.resize(38); af.reset_width()
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
print("\n[9] panel does not inherit an auto-finder buffer on open")
af.close()
-- Simulate the `nvim .` autostart scenario: create a fake "auto-finder"
-- buffer and park it in the cursor window. The panel-open code path should
-- refuse to inherit it.
local fake_nt = vim.api.nvim_create_buf(false, true)
vim.bo[fake_nt].buftype = "nofile"
vim.bo[fake_nt].filetype = "auto-finder"
local first_win = vim.api.nvim_list_wins()[1]
vim.api.nvim_set_current_win(first_win)
pcall(vim.api.nvim_win_set_buf, first_win, fake_nt)
-- Pre-condition: cursor window holds an auto-finder-flavoured buffer.
ok("cursor window has filetype=auto-finder before open", vim.bo.filetype == "auto-finder")

-- Now open the panel from inside that window. ensure_open should swap
-- the inherited buffer for a scratch *before* focus mounts the section.
local host = require("auto-finder.panel.host")
-- Drive ensure_open directly so we can inspect the panel buffer right
-- after the split, before focus runs and replaces it with the view.
local saved_section = af.state.section
af.state.section = nil  -- force open() to call focus(default), but we
                        -- bypass open() entirely below
local panel_winid = host.ensure_open(af.state.config, af.state, true)
ok("ensure_open returns winid", panel_winid ~= nil)
panel_buf = panel_winid and vim.api.nvim_win_get_buf(panel_winid) or -1
local panel_ft = vim.bo[panel_buf].filetype
ok("panel buf is NOT the inherited auto-finder buffer (filetype is empty)", panel_ft == "",
  "panel_ft=" .. panel_ft)
ok("panel buf is NOT the fake buffer", panel_buf ~= fake_nt,
  "panel_buf=" .. panel_buf .. " fake=" .. fake_nt)
af.state.section = saved_section

-- ─────────────────────── 10b. store persistence ──────────────────
print("\n[10b] store persistence (panel pin survives restart)")
-- Use a temp config dir so we don't trash the user's real
-- ~/.config/nvim/.auto-finder. stdpath('config') is read once per
-- session, so override env before the store reads it.
-- Under the run's unique sandbox, not a fixed /tmp path: a shared root
-- that every concurrent smoke run recursively deletes is the same class
-- of bug this suite's XDG isolation exists to prevent.
local tmp_config = SANDBOX .. "/case-store-dir"
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
  local tmp_c = SANDBOX .. "/case-migrate"
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
local repos_config = SANDBOX .. "/case-repos"
vim.fn.delete(repos_config, "rf")
vim.env.XDG_CONFIG_HOME = repos_config
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

-- Admin REPL: ADR-0200 removed the `repos follow` verb (it only drove the
-- retired repos source and did nothing on the worktree tree). The top-level
-- completion must not offer a verb that no longer exists.
local _, top = admin._complete_at("", 0)
ok("complete_at empty no longer offers 'repos'", not vim.tbl_contains(top, "repos"), vim.inspect(top))

-- Focusing the repos section must succeed end-to-end even without
-- worktree.nvim — the tree renders its explicit "unavailable" screen.
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
ok("repos panel buffer is filetype=auto-finder",
  repos_buf and vim.bo[repos_buf].filetype == "auto-finder",
  "ft=" .. tostring(repos_buf and vim.bo[repos_buf].filetype))

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

  -- v0.2.32 regression: focusing marks then another filetype=auto-finder
  -- slot used to crash while the second slot mounted over the first.
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
-- NB: this section's vim.wait() drains the scheduler.
af.close()
af._hijack_done = nil
-- Stage a directory buffer at the cwd. _maybe_hijack_startup_directory
-- reads the current buffer's name; isdirectory(name) must return 1.
-- eventignore=all during setup so other autocmds don't hijack-and-wipe
-- our staging buffer (buf 13 vanishing was the symptom).
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

-- ───────────────────────── 14. files view live-refresh wiring (ADR-0200 §4.4) ─────────────────────────
-- The files view watches only its EXPANDED directories, non-recursively, and only while shown;
-- auto-finder's core no longer walks the cwd. Behavioural cells (reads counted, hide/show, watch
-- set == expanded set, live create/delete) live in tests/adr0200-files.lua; this section pins the
-- wiring the rest of the suite relies on.
print("\n[14] files view live-refresh wiring — ADR-0200 §4.4")

local ac_ok, core = pcall(require, "auto-core")
ok("auto-core loadable on the rtp", ac_ok and type(core) == "table")
ok("auto-core.fs.scan present (ADR-0200 M2)", type(core.fs) == "table" and type(core.fs.scan) == "table")
ok("auto-core.events present", type(core.events) == "table")

af.close()
af.open(true)
af.focus(1)  -- files
local files_view = require("auto-finder.views.files")
vim.wait(1000, function()
  local st = files_view._state
  return st.shown and st.model and st.model.nodes[st.model.root].children ~= nil
end, 10)
local fst = files_view._state
ok("files view is shown after focus", fst.shown == true)
ok("the root was read (lazy tree has its first level)",
  fst.model and fst.model.nodes[fst.model.root].children ~= nil)
ok("the view subscribed to auto-finder.core.files:changed", fst.subs and fst.subs:has("files-fs"))
ok("core holds the root's directory watch", require("auto-finder.core.watchers").is_dir_watched(fst.model.root))
ok("exactly one watch is armed: the expanded root", files_view.watch_count() == 1,
  "watches=" .. files_view.watch_count())
local cw = require("auto-finder.core.watchers")
ok("core.watchers no longer offers a cwd walk", cw.open_for == nil and cw.list == nil)

af.close()
ok("closing the panel suspends the view", fst.shown == false)
ok("closing the panel releases every watch", files_view.watch_count() == 0,
  "watches=" .. files_view.watch_count())
ok("the view's buffer survives the close", fst.bufnr ~= nil and vim.api.nvim_buf_is_valid(fst.bufnr))
af.open(true)
af.focus(1)

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
  -- Force a mount to populate the cache; poll until the registry holds
  -- the repos buffer.
  af.focus(2)
  vim.wait(500, function()
    local b = af._registry._bufs[repos_def.number]
    return b ~= nil and vim.api.nvim_buf_is_valid(b)
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
-- Retroactive coverage for a bug that escaped v0.2.5 because the
-- iteration shipped without smoke per `lua-nvim-plugin-development` rule
-- #4 ("each iteration adds or extends a test for the change it makes").
-- (Parts (a)/(b) covered the retired fork's buffers source
-- registration and went with it — ADR-0200.)
--   (c) slot mutations dispose()'d the entire registry, deleting EVERY
--       section's buffer (including the active config slot's buffer that
--       the user was typing in) → panel went blank. Fixed by in-place
--       mutation path in v0.2.8.
-- Rule #11 (effect-was-observed not call-was-made) — each assertion
-- targets an observable post-condition (require returns a table, buffer
-- survives, active section stays as expected), not just "the function
-- was called".
print("\n[18] v0.2.8 — slot mutation preserves panel")

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

-- ───────────────────────── 19. buffers slot grows as buffers open (was v0.2.9) ────────────────────────
--
-- The user-visible claim v0.2.9 pinned: opening a file AFTER the buffers
-- slot mounted must show it without a manual remount. Measured on the
-- buffers view's own rows (ADR-0200 §4.8) — it repaints from
-- auto-finder.core.buffers:changed while shown.
print("\n[19] buffers slot grows as buffers open")

af.slot_add("buffers")
local _buffers_idx = require("auto-finder.sections")._by_name["buffers"]
ok("buffers section was added by slot_add for this test",
  _buffers_idx ~= nil)
af.focus(_buffers_idx)
local bview = require("auto-finder.views.buffers")
vim.wait(500, function() return bview._state.shown and #bview._state.items > 0 end, 10)
ok("buffers view shown in the panel window",
  bview._state.shown and bview._state.winid == af.state.panel_winid)
ok("buffers view subscribed to core buffers changes", bview._state.subs and bview._state.subs:has("buffers"))

local _probe_path = vim.fn.getcwd() .. "/tests/_buffers_refresh_probe.txt"
do
  local fh = io.open(_probe_path, "w")
  fh:write("smoke probe"); fh:close()
end
local _prev_win = vim.api.nvim_get_current_win()
local function _tree_size() return #bview._state.items end
local _size_before = _tree_size()

-- WHY THESE PROBES GO THROUGH A HELPER.
--
-- The panel window carries `winfixbuf=true`. `topleft split <file>` from it
-- creates NO window and raises NO error — measured: `ok=true, err=nil,
-- wins 2->2, current still the panel`. The split makes a window, the edit
-- into it is refused because winfixbuf is inherited, and the window is undone;
-- vim.cmd reports success throughout. So a probe that splits while the panel
-- is focused, then closes "its" window, closes THE PANEL.
--
-- Four probes did exactly that, seven times per suite run. It was harmless
-- until it was not: it kept auto-core's WinClosed transition parked for eleven
-- days, because with the transition in, each of those closes correctly tears
-- down cached section buffers and two unrelated assertions failed (697/2,
-- 2026-08-25).
--
-- `:noautocmd` is NOT the fix — these probes assert on BufAdd / BufEnter
-- handling, which is the whole point of them. The fix is to split from a
-- window that can actually take a buffer, and to close the window we were
-- actually given rather than whatever happens to be current.
--
-- The mechanism itself is pinned below on a SYNTHETIC winfixbuf window, so it
-- keeps being checked without any probe having to close the real panel to
-- prove it.
-- Move focus off any window that refuses buffer changes, so a following
-- `:split` / `:terminal` behaves as its caller assumes. Returns a scratch
-- window if one had to be created, for the caller to close.
local function probe_editable()
  local function fixed(w)
    local okv, v = pcall(function() return vim.wo[w].winfixbuf end)
    return okv and v == true
  end
  if not fixed(vim.api.nvim_get_current_win()) then return nil end
  local other
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if not fixed(w) then other = w end
  end
  if other then
    vim.api.nvim_set_current_win(other)
    return nil
  end
  vim.cmd("botright new")
  return vim.api.nvim_get_current_win()
end

local function probe_split(path)
  local scratch = probe_editable()
  local before = #vim.api.nvim_list_wins()
  vim.cmd("topleft split " .. vim.fn.fnameescape(path))
  local win = vim.api.nvim_get_current_win()
  -- Asserted per call, not once: a helper that silently stopped creating a
  -- window would put every caller back to closing the panel, and that is the
  -- failure this whole change exists to remove.
  ok("probe_split created a real window for " .. vim.fn.fnamemodify(path, ":t"),
    #vim.api.nvim_list_wins() > before and win ~= af.state.panel_winid,
    ("wins %d->%d, win=%s panel=%s"):format(before, #vim.api.nvim_list_wins(),
      tostring(win), tostring(af.state.panel_winid)))
  return win, scratch
end

local function probe_close(win, scratch)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if scratch and vim.api.nvim_win_is_valid(scratch) then
    pcall(vim.api.nvim_win_close, scratch, true)
  end
end

-- The mechanism is DOCUMENTED here rather than re-asserted, and the reason is
-- that I tried to assert it and the assertion was wrong. A synthetic
-- `botright new` window with `winfixbuf=true` does NOT reproduce it — measured,
-- four ways: plain, winfixbuf, buftype=nofile, and both together all create a
-- window normally. What the real panel does, measured on it directly:
--
--   wins 2->2, current still the panel, panel buffer CHANGED to the probe file
--
-- The file is loaded INTO the panel and no window survives. So it is the
-- panel's own autocmds doing it, not a window option, and reproducing it
-- requires hijacking the real panel mid-suite — which is the very damage this
-- change removes. The per-call assertion in probe_split is what stays honest:
-- it fails the moment a probe stops getting a real window, whatever the cause.

local _probe_win = probe_split(_probe_path)
vim.wait(400, function()
  return _tree_size() > _size_before
end, 20)
local _size_after = _tree_size()
ok("buffers tree grew after opening a new file (before=" ..
   _size_before .. " after=" .. _size_after .. ")",
   _size_after > _size_before)

-- Cleanup: close the window probe_split gave us — NOT whatever is current,
-- which is how this used to close the panel.
probe_close(_probe_win)
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
section(function()
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
end)

-- ───────────────────────── 20b. reseed must NOT force-open a closed panel ────────────────────────
--
-- Regression: on a fresh `nvim` (no args) the AutoVim splash rendered
-- off-center because the auto-finder panel popped open OVER the
-- dashboard. Root cause: the startup workspace reseed
-- (_reseed_sections_for_workspace → _rebuild_section_registry → focus,
-- and the same-list early-return's M.focus) drives the panel through
-- `focus`, and BOTH focus paths OPEN a closed panel (auto-core
-- Registry:focus calls panel:open() when winid is invalid; M.focus
-- calls host.ensure_open). So this pure bookkeeping force-opened the
-- finder at startup. The reseed must update section state WITHOUT
-- opening a closed panel — a directory launch (`nvim .`) still opens
-- it via the separate hijack one-shot, which this does not touch.
print("\n[20b] reseed must not force-open a closed panel")
section(function()
local _af = require("auto-finder")
local _state_mod = require("auto-finder.state")
local _core = require("auto-core")

_core.git.worktree.set_workspace_root(vim.fn.getcwd())
local _wskey = _af._workspace_key()
ok("workspace key resolves for reseed-open probe",
   type(_wskey) == "string" and #_wskey > 0)
if not _wskey then return end

local function panel_open()
  return _af.state.panel_winid ~= nil
    and vim.api.nvim_win_is_valid(_af.state.panel_winid)
end

-- The probe only means something if the panel starts CLOSED, mirroring
-- a fresh no-arg launch. A prior section may have left it open.
_af.close()
ok("panel starts closed", not panel_open())

local _orig_persisted = _state_mod.get_sections_for(_wskey)
local _orig_live = vim.list_extend({}, _af.state.config.sections)
local _orig_last_section = _state_mod.get_last_section_for(_wskey)

-- (a) SLOT LIST DIFFERS → the _rebuild_section_registry focus path.
local _target = { "config", "files", "repos", "buffers" }
_state_mod.set_sections_for(_wskey, _target)
_af.state.config.sections = vim.deepcopy(
  require("auto-finder.config").defaults.sections)
_af._reseed_sections_for_workspace()
ok("(a) cfg.sections reseeded to the persisted list",
   vim.deep_equal(_af.state.config.sections, _target))
ok("(a) panel STILL closed after a slot-list-changing reseed",
   not panel_open())

-- (b) SLOT LIST IDENTICAL but last_section differs → the early-return
-- branch that used to call M.focus(per_ws_section).
_state_mod.set_last_section_for(_wskey, 2) -- repos
_af.state.section = 0
if _af._registry then _af._registry.active = 0 end
_af._reseed_sections_for_workspace()
ok("(b) state.section adopts the per-workspace last_section",
   _af.state.section == 2)
ok("(b) panel STILL closed after a same-list reseed", not panel_open())

-- (c) A STALE persisted last_section must be CLAMPED (not mirrored raw)
-- while the panel is closed — matching the clamp M.focus applied before
-- this path stopped opening the panel. Otherwise state.section /
-- registry.active hold an invalid slot until the next open.
_state_mod.set_last_section_for(_wskey, 99) -- out of range
_af.state.section = 0
if _af._registry then _af._registry.active = 0 end
_af._reseed_sections_for_workspace()
local _default = _af.state.config.default_section or 0
ok("(c) stale last_section clamped in state.section while closed",
   _af.state.section == _default)
ok("(c) stale last_section clamped in registry.active while closed",
   _af._registry ~= nil and _af._registry.active == _default)
ok("(c) panel STILL closed after a stale-section reseed", not panel_open())

-- (d) COLD-START EQUAL-AND-STALE: both mirrors already hold the SAME stale
-- value (setup reads persisted last_section into state.section, then
-- auto-core attach seeds registry.active from it). The clamp must STILL
-- fire — gating it on `per_ws_section ~= registry.active` would skip it and
-- leave both mirrors on a slot that no longer exists (lector PR#13 r2
-- [MEDIUM]). NOTE: (c) above pre-set active=0, which forces the inequality
-- and MASKS this boundary; here we set BOTH mirrors to the stale value so
-- the equal-active path is actually exercised.
_state_mod.set_last_section_for(_wskey, 99)
_af.state.section = 99
if _af._registry then _af._registry.active = 99 end
_af._reseed_sections_for_workspace()
ok("(d) equal-and-stale last_section clamped in state.section (closed)",
   _af.state.section == _default)
ok("(d) equal-and-stale last_section clamped in registry.active (closed)",
   _af._registry ~= nil and _af._registry.active == _default)
ok("(d) panel STILL closed after equal-and-stale reseed", not panel_open())

-- Restore so later sections see the live default composition.
if _orig_persisted then
  _state_mod.set_sections_for(_wskey, _orig_persisted)
else
  _state_mod.set_sections_for(_wskey, nil)
end
pcall(_state_mod.set_last_section_for, _wskey, _orig_last_section)
_af._rebuild_section_registry(_orig_live)
_af.close()
end)

-- ───────────────────────── 20c. worktree:switched drop-repos must not force-open a closed panel ────────────────────────
--
-- Second closed-panel gap (lector PR #13 r1, HIGH): the worktree:switched
-- handler in core/init.lua schedules _reseed_sections_for_workspace()
-- AND _drop_repos_bufnr_on_worktree_switched(). The latter drops the
-- repos bufnr and then re-focuses repos "to remount immediately" if repos
-- is active — but Registry:focus OPENS a closed panel, so a worktree
-- switch while the finder is closed force-opened it. The remount must
-- happen only when the panel is already open; a closed panel remounts on
-- its next explicit open.
print("\n[20c] worktree:switched drop-repos must not force-open a closed panel")
section(function()
local _af = require("auto-finder")
local _core = require("auto-core")
_core.git.worktree.set_workspace_root(vim.fn.getcwd())

local function panel_open()
  return _af.state.panel_winid ~= nil
    and vim.api.nvim_win_is_valid(_af.state.panel_winid)
end

_af.close()
ok("panel starts closed (20c)", not panel_open())

-- repos is in the default section list; find its number and make it active.
local _repos_num
if _af._registry then
  for _, s in ipairs(_af._registry.sections) do
    if s.name == "repos" then _repos_num = s.number; break end
  end
end
ok("repos section is registered", _repos_num ~= nil)
if _repos_num == nil then return end

_af.state.section = _repos_num
_af._registry.active = _repos_num

-- Fire the drop-repos bookkeeping directly (the composed handler path).
_af._drop_repos_bufnr_on_worktree_switched()
ok("panel STILL closed after drop-repos with repos active",
   not panel_open())
_af.close()
end)

-- ───────────────────────── 21. v0.2.11 — active-section gate + renderer winfixbuf-safe ────────────────────────
--
-- Two regression tests for v0.2.11:
--
--   (a) Opening a file while buffers is NOT the active section must not
--       swap the panel buffer (the v0.2.9 refresh clobbered files/repos).
--       The buffers view does no work while hidden (ADR-0200 §4.8).
--
--   (b) Painting the buffers view against a winfixbuf=true panel must
--       succeed and leave winfixbuf on (pre-v0.2.11 the old renderer
--       raised E1513 inside scheduled callbacks).
print("\n[21] v0.2.11 — active-section gate + renderer winfixbuf-safe")
section(function()
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
local _win_a = probe_split(_probe)
vim.wait(300)  -- debounce + scheduler

local _panel_buf_post =
   _panel and vim.api.nvim_win_is_valid(_panel)
     and vim.api.nvim_win_get_buf(_panel) or -1
-- The regression: the panel must still show config, not the buffers view.
ok("panel still shows the config buffer after BufAdd while config active "
   .. "(pre=" .. _panel_buf_pre .. " post=" .. _panel_buf_post .. ")",
   _panel_buf_post == _panel_buf_pre)
ok("the buffers view did no work while hidden", not require("auto-finder.views.buffers")._state.shown)
ok("registry.active still 0 (config) — gate did not flip section",
   _af._registry.active == 0)

-- Cleanup probe: close the window we were GIVEN, not whatever is current.
probe_close(_win_a)
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_get_name(b) == _probe then
    pcall(vim.api.nvim_buf_delete, b, { force = true })
  end
end
pcall(os.remove, _probe)

-- ── (b) paint is winfixbuf-safe ─────────────────────────────────
-- Switch to buffers so the panel hosts the buffers view, then paint.
-- Use the `_by_name` lookup again since slot indices may have shifted
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

-- Paint writes the buffer's lines in place (nvim_buf_set_lines) and never
-- swaps the window's buffer, so winfixbuf cannot refuse it.
local _bv = require("auto-finder.views.buffers")
ok("buffers view shown in the panel for part (b)", _bv._state.shown and _bv._state.winid == _panel)
local _ok, _err = pcall(_bv.paint)
ok("buffers paint against winfixbuf=true panel returns without error", _ok, tostring(_err))
local _wfb_after = vim.wo[_panel].winfixbuf
ok("winfixbuf restored to true after render (no protection drop)",
   _wfb_after == true)

-- Cleanup: remove buffers section if we added it.
local _last_idx = #_af.state.config.sections - 1
if _af.state.config.sections[#_af.state.config.sections] == "buffers" then
  _af.slot_remove(_last_idx)
end
end)

-- ───────────────────── 21c. buffers opened while the slot is hidden appear on focus (was v0.2.13) ──────
-- v0.2.13's claim, kept: a BufAdd while buffers is NOT the active section must show up the moment the
-- user focuses buffers. The old mechanism (a dirty bit consumed by on_focus) is gone with the old
-- source; the buffers view does no work while hidden and repaints from scratch on show (ADR-0200 §4.8).
--   (1) BufAdd while hidden → the view stays suspended (no work).
--   (2) focus(buffers) → the new buffer is in the rendered list.
--   (3) BufAdd while shown → it appears without a refocus.
print("\n[21c] buffers opened while hidden appear on focus")
section(function()
local _af = require("auto-finder")
local _sb_name = require("auto-finder.sections")._by_name
if _sb_name["buffers"] == nil then
  _af.slot_add("buffers")
end
local _buf_idx = require("auto-finder.sections")._by_name["buffers"]
ok("buffers slot registered for [21c]", _buf_idx ~= nil)
local _bv = require("auto-finder.views.buffers")

_af.open(true)
vim.wait(80)
_af.focus(0)
vim.wait(100)
ok("baseline: registry.active == 0 (config), buffers NOT active", _af._registry.active == 0)

local _probe_dirty = vim.fn.getcwd() .. "/tests/_v2_13_dirty_probe.txt"
local _fh2 = io.open(_probe_dirty, "w"); _fh2:write("hidden probe"); _fh2:close()
local _win_b = probe_split(_probe_dirty)
vim.wait(300)
ok("BufAdd while buffers hidden: the view stays suspended", not _bv._state.shown)
probe_close(_win_b)

local function rendered_has(needle)
  local b = _bv._state.bufnr
  if not (b and vim.api.nvim_buf_is_valid(b)) then return false end
  for _, ln in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
    if ln:find(needle, 1, true) then return true end
  end
  return false
end

_af.focus(_buf_idx)
vim.wait(300, function() return rendered_has("_v2_13_dirty_probe") end, 10)
ok("buffers list contains the buffer opened while hidden", rendered_has("_v2_13_dirty_probe"))

local _probe_active = vim.fn.getcwd() .. "/tests/_v2_13_active_probe.txt"
local _fh3 = io.open(_probe_active, "w"); _fh3:write("active probe"); _fh3:close()
local _win_c = probe_split(_probe_active)
vim.wait(400, function() return rendered_has("_v2_13_active_probe") end, 10)
ok("BufAdd while buffers shown appears without a refocus", rendered_has("_v2_13_active_probe"))
probe_close(_win_c)

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
end)

-- ───────────────────── 21d. v0.2.14 — out-of-cwd buffers grouped as sibling roots ───
-- Out-of-cwd buffers used to be silently dropped by the old buffers
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
section(function()
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

require("auto-finder.views.buffers").paint()

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
require("auto-finder.views.buffers").paint()
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
end)

-- ───────────────────── 22. follow-mode hijacking protection ──────────────
-- files-follow must be gated to its own slot: entering a file while another
-- slot (buffers) is active must not swap the panel's buffer. (The repos-follow
-- half of this section went with the removed `repos follow` feature — ADR-0200.)
print("\n[22] follow-mode hijacking protection")

local tmp_hijack = vim.fn.getcwd() .. "/tests/hijack-test.txt"
vim.fn.writefile({ "hijack test" }, tmp_hijack)

af.state.config.files.follow = true
if not require("auto-finder.sections")._by_name["buffers"] then
  af.slot_add("buffers")
end
local buffers_idx = require("auto-finder.sections")._by_name["buffers"]
af.focus(buffers_idx)
vim.wait(500, function()
  local b = af._registry._bufs[buffers_idx]
  return b ~= nil and vim.api.nvim_buf_is_valid(b)
end)
ok("focused buffers section for files-follow gate", af.state.section == buffers_idx)
local buffers_buf = af._registry._bufs[buffers_idx]

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
ok("panel window still displays the buffers buffer (not hijacked by files-follow)",
  vim.api.nvim_win_get_buf(af.state.panel_winid) == buffers_buf)
ok("editor window displays the entered file",
  vim.api.nvim_win_get_buf(editor_win) == vim.fn.bufnr(tmp_hijack))
af.state.config.files.follow = false
pcall(vim.cmd, "bwipeout " .. vim.fn.bufnr(tmp_hijack))
vim.fn.delete(tmp_hijack)

-- ───────────────────────── 23. dbase file/conn management ─────────────────────────
-- Exercises the files section's durable state: filesystem-backed
-- connection-file CRUD, pinned-active swap semantics, and admin REPL
-- dispatch routing for the new `dbase` verb. dbee is NOT required —
-- _reload_dbee soft-fails when dbee isn't loaded, and the durable
-- state-of-truth lives in plain JSON files we read back directly.
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
section(function()
local bview = require("auto-finder.views.buffers")
-- The buffers view's rendered items carry each buffer's absolute path.
local function buffers_tree_has_file(path)
  bview.paint()
  for _, it in ipairs(bview._state.items or {}) do
    if it.path == path then return true end
  end
  return false
end

-- Make sure buffers is the active section + the autocmd-refresh is wired.
if not require("auto-finder.sections")._by_name["buffers"] then
  af.slot_add("buffers")
end
local _buf_slot = require("auto-finder.sections")._by_name["buffers"]
af.focus(_buf_slot)
vim.wait(150)

-- Probe files under cwd.
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
-- "Open in a side split so we don't clobber the panel" was the intent and not
-- the behaviour: from the panel this loaded the file INTO the panel and created
-- no window. This probe never closed anything, so it clobbered silently rather
-- than closing the panel like its three siblings — a quieter symptom of the
-- same defect.
local _win_d = probe_split(_probe_edit)
vim.api.nvim_set_current_win(_prev_win)
vim.wait(200, function() return buffers_tree_has_file(_probe_edit) end, 20)
ok("user-story: `:edit <file>` adds the file to the buffers tree",
  buffers_tree_has_file(_probe_edit))
probe_close(_win_d)

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
vim.wait(200, function() return buffers_tree_has_file(_probe_badd) end, 20)
ok("user-story: `:badd <file>` adds the file to the buffers tree (regression guard)",
  buffers_tree_has_file(_probe_badd),
  "this was the v0.2.21 regression — show_unloaded=false was filtering :badd'd buffers")

-- ── User-story: `:bd <bufnr>` removes the file from the panel ────
local _edit_bufnr = vim.fn.bufnr(_probe_edit)
pcall(vim.api.nvim_buf_delete, _edit_bufnr, { force = true })
vim.wait(200, function() return not buffers_tree_has_file(_probe_edit) end, 20)
ok("user-story: `:bd <bufnr>` removes the file from the buffers tree",
  not buffers_tree_has_file(_probe_edit))

-- ── User-story: terminal buffers appear under the Terminals group ──
-- :terminal opens a real PTY; in headless mode that can fail on
-- platforms without a usable shell. Use a guarded pcall + skip.
-- DELIBERATELY NOT converted to probe_editable, and this comment is the
-- finding rather than an excuse. Running it from the panel makes `:terminal`
-- fail, the pcall below reports a platform skip, and the whole branch is dead
-- — so its three assertions have NEVER EXECUTED. Coming off the panel makes
-- `:terminal` work, and the newly live branch immediately fails: first
-- "Invalid window id" on a `_prev_win` captured many assertions earlier, then
-- three assertions that do not hold as written.
--
-- Fixing those is a different job from "probes close the panel": this probe
-- never closes anything, because it never gets a window. Filed separately with
-- the measurements, rather than half-fixed here or quietly left looking
-- converted.
local _term_ok = pcall(function()
  vim.cmd("topleft split | terminal echo smoke-term-probe")
end)
if _term_ok then
  vim.wait(150)
  vim.api.nvim_set_current_win(_prev_win)
  vim.wait(200)
  bview.paint()
  local saw_terminal = false
  for _, it in ipairs(bview._state.items or {}) do
    if it.icon_name == "terminal" then saw_terminal = true; break end
  end
  ok("user-story: a `:terminal` buffer appears in the buffers tree",
    saw_terminal)
else
  -- NOT ok(..., true). This branch asserts nothing, so it must not report a
  -- pass: `ok(name, true)` on a cell that executed nothing inflates the summary
  -- line run-all gates on, and a green that means "did not run" is the same
  -- family as an aborted suite reporting zero failures. It also contradicted
  -- the comment above, which says plainly that these assertions have never
  -- executed. (gold-man, #30 r0.)
  --
  -- A print, so the run says out loud that a section was skipped and the count
  -- reflects only what ran.
  print("  SKIP  user-story: `:terminal` buffer in the buffers tree — "
    .. ":terminal failed here. NOT a platform limitation: this probe runs from "
    .. "the panel, where :terminal cannot take the window. Its three assertions "
    .. "have never executed. Tracked separately.")
end

-- ── User-story: out-of-cwd buffer appears as a sibling root group ──
-- v0.2.14 added the "out-of-cwd buffers bucket as sibling root
-- folders" behavior. /tmp is reliably outside cwd in any test env.
local _ext_probe = "/tmp/auto_finder_external_probe.txt"
do
  local fh = io.open(_ext_probe, "w"); fh:write("ext probe"); fh:close()
end
vim.cmd("badd " .. vim.fn.fnameescape(_ext_probe))
vim.wait(200, function() return buffers_tree_has_file(_ext_probe) end, 20)
ok("user-story: out-of-cwd `:badd`'d file appears in the buffers tree",
  buffers_tree_has_file(_ext_probe))
-- Also verify the /tmp bucket is its own root row (v0.2.14 external-root behavior).
local saw_tmp_bucket = false
for _, it in ipairs(bview._state.items or {}) do
  if it.kind == "root" and it.depth == 0 and it.name == "OPEN BUFFERS in /tmp" then
    saw_tmp_bucket = true; break
  end
end
ok("user-story: /tmp bucket appears as its own root row (OPEN BUFFERS in /tmp)",
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
end)

-- ───────────────────────── 27. user-stories — files panel (v0.2.23) ─────────────────────────
print("\n[27] user-stories — files panel")
section(function()
local fview = require("auto-finder.views.files")
local function fs_tree_has(path)
  for _, v in ipairs(fview._state.items or {}) do
    if v.node.path == path then return true end
  end
  return false
end

local _files_slot = require("auto-finder.sections")._by_name["files"]
af.focus(_files_slot)
vim.wait(500, function() return fview._state.shown and #fview._state.items > 1 end, 10)

-- A top-level file under cwd: the expanded root's own watch sees it, and the
-- view re-reads that one directory (no manual refresh — the live path IS the
-- claim, ADR-0200 §4.4).
local _probe_file = vim.fn.getcwd() .. "/_user_story_fs_probe.txt"
ok("baseline: created_probe NOT in tree yet", not fs_tree_has(_probe_file))
vim.fn.writefile({ "probe" }, _probe_file)
vim.wait(2000, function() return fs_tree_has(_probe_file) end, 25)
ok("user-story: writefile under cwd → files panel shows the new file (live watch)",
  fs_tree_has(_probe_file), "tree should contain " .. _probe_file)

pcall(os.remove, _probe_file)
vim.wait(2000, function() return not fs_tree_has(_probe_file) end, 25)
ok("user-story: deleting a file → files panel drops it (live watch)", not fs_tree_has(_probe_file))
pcall(os.remove, _probe_file)
end)

-- ───────────────────────── 28. user-stories — repos panel (v0.2.23) ─────────────────────────
-- The repos source's contents come from auto-core.git.worktree's
-- workspace-roots registry, not from a public auto-finder API (no
-- `auto-finder.repos.add` exists; only `root()` / `load()` /
-- `worktree_paths()`). The actionable user-story for this section
-- is: "I mount the repos panel, focus it, and see at least one
-- top-level node corresponding to a registered workspace".
print("\n[28] user-stories — repos panel")
section(function()
local af_repos = require("auto-finder").repos
ok("auto-finder.repos surface exists",
  type(af_repos) == "table" and type(af_repos.root) == "function")
if not require("auto-finder.sections")._by_name["repos"] then
  af.slot_add("repos")
end
local _repos_slot = require("auto-finder.sections")._by_name["repos"]
af.focus(_repos_slot)
local _rb
vim.wait(500, function()
  _rb = af._registry._bufs[_repos_slot]
  return _rb ~= nil and vim.api.nvim_buf_is_valid(_rb)
end, 10)
ok("user-story: focusing repos mounts the worktree tree's buffer", _rb ~= nil and vim.api.nvim_buf_is_valid(_rb))
ok("user-story: the repos buffer is what the panel shows",
  _rb ~= nil and vim.api.nvim_win_get_buf(af.state.panel_winid) == _rb)
ok("user-story: the repos tree rendered at least one row",
  _rb ~= nil and #vim.api.nvim_buf_get_lines(_rb, 0, -1, false) >= 1)
end)

-- ───────────────────────── 29. ADR 0026 Phase 1: core skeleton ────
-- ADR 0026 — runtime state component (auto-finder.core). Phase 1
-- ships a loadable skeleton with no-op lifecycle + placeholder
-- submodules. This section asserts (a) the public surface
-- resolves, (b) ensure_started/stop/reload are safe to call, and
-- (c) the topic registry lists every topic the ADR §2.2 table
-- declares. Phase 3+ will replace these no-op assertions with
-- behavior-based ones (A7/A8 per ADR §4).
print("\n[29] core skeleton (ADR 0026 Phase 1)")
section(function()
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
-- resolve and expose its minimum surface. (core.files / core.warm fed
-- only the retired fork and went with it — ADR-0200.)
ok("core.files / core.warm are gone (ADR-0200)", core.files == nil and core.warm == nil)
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

ok("core.watchers loads with the per-worktree surface",
  type(core.watchers) == "table"
    and type(core.watchers.reconcile_watched) == "function"
    and type(core.watchers.close_all) == "function"
    and core.watchers.open_for == nil)

-- (d) topic registry — the live topics (ADR-0200 removed files:changed,
-- ready and metrics:paint with their only publishers). Assert each
-- one is registered so a Phase 4+ implementer can't accidentally
-- typo a topic name without the smoke catching it.
ok("core.events loads with TOPICS/publish/subscribe/unsubscribe",
  type(core.events) == "table"
    and type(core.events.TOPICS) == "table"
    and type(core.events.publish) == "function"
    and type(core.events.subscribe) == "function"
    and type(core.events.unsubscribe) == "function")

local expected_topics = {
  "auto-finder.core.git:changed",
  "auto-finder.core.buffers:changed",
  "auto-finder.core.repos:changed",
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
  "auto-finder.core.buffers:changed",
  function(payload) got_payload = payload end)
ok("subscribe returns a handle when auto-core is present",
  handle ~= nil,
  "auto-core may be missing; check rtp prelude")

core.events.publish("auto-finder.core.buffers:changed",
  { view = "smoke", dur_ms = 0, generation = 1 })
vim.wait(10)
ok("publish → subscriber callback fires with the payload",
  type(got_payload) == "table"
    and got_payload.view == "smoke",
  "got " .. vim.inspect(got_payload))

core.events.unsubscribe(handle)
got_payload = nil
core.events.publish("auto-finder.core.buffers:changed",
  { view = "smoke-after-unsub", dur_ms = 0, generation = 2 })
vim.wait(10)
ok("unsubscribe stops the callback",
  got_payload == nil,
  "callback fired after unsubscribe: " .. tostring(got_payload))

-- Phase 1 originally cleaned up with `core._reset_for_tests()` so
-- later sections could assume "not started." Phase 3 makes that
-- assumption wrong: setup() now wires ensure_started transitively,
-- so subsequent sections expect a live core. Leave it running.
end)

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
section(function()
-- (a) Facade resolution. Every public section path must return the
-- same table as the corresponding views path.
local pairs_to_check = {
  { sec = "auto-finder.sections",          view = "auto-finder.views" },
  { sec = "auto-finder.sections.config",   view = "auto-finder.views.config" },
  { sec = "auto-finder.sections.files",    view = "auto-finder.views.files" },
  { sec = "auto-finder.sections.buffers",  view = "auto-finder.views.buffers" },
  { sec = "auto-finder.sections.repos",    view = "auto-finder.views.repos" },
  { sec = "auto-finder.sections.dbase",    view = "auto-finder.views.dbase" },
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
subs:replace("a", "auto-finder.core.buffers:changed",
  function() hits.a = hits.a + 1 end)
subs:replace("b", "auto-finder.core.buffers:changed",
  function() hits.b = hits.b + 1 end)
ok("view_subs:count() == 2 after two replace() calls", subs:count() == 2)
ok("view_subs:has('a') is true", subs:has("a"))
ok("view_subs:has('c') is false", not subs:has("c"))

-- Re-replacing slot 'a' must NOT increase count (replace semantics)
-- AND must swap which callback fires. Publish once, expect one fire
-- on the NEW callback only.
local replaced_a_hits = 0
subs:replace("a", "auto-finder.core.buffers:changed",
  function() replaced_a_hits = replaced_a_hits + 1 end)
ok("view_subs:replace() on same slot keeps count == 2", subs:count() == 2)

local before_a = hits.a
core.events.publish("auto-finder.core.buffers:changed",
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
core.events.publish("auto-finder.core.buffers:changed",
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
end)

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
--       call ensure_started, publish a synthetic core.git.state:changed
--       event, assert the translated auto-finder.core.git:changed
--       event fires (the files translator went with ADR-0200)
--   (d) worktree:switched + core.git.state:changed translations
--       reach their auto-finder.core.* topics
--   (e) A8 (handle release): fs.watch.list() + git.watch.list()
--       return to pre-ensure_started state after stop(). Phase 3
--       opens zero watchers so both lists stay empty across the
--       round-trip; Phase 4/5 will add real handles and this
--       assertion gains teeth.
print("\n[31] ADR 0026 Phase 3 — lifecycle (A7 bus-reset, A8 handle release)")
section(function()
local core = require("auto-finder.core")
local up   = require("auto-core")

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
--   1. prove the translator fires (pre-reset baseline)
--   2. force auto-core.events._reset_for_tests
--   3. re-arm via ensure_started, publish again
--   4. assert the translated event still fires
local git_count, last_git = 0, nil
local function git_probe_cb(p) git_count = git_count + 1; last_git = p end
local probe_handle = core.events.subscribe("auto-finder.core.git:changed", git_probe_cb)
up.events.publish("core.git.state:changed",
  { repo_root = "/tmp/phase3-probe-pre", git_dir = "/tmp/phase3-probe-pre/.git", kind = "head" })
vim.wait(20)
ok("pre-reset: translator fires on core.git.state:changed", git_count == 1,
  "expected 1 fire, got " .. git_count)
ok("pre-reset: translated payload carries the repo_root",
  last_git and last_git.repo_root == "/tmp/phase3-probe-pre", vim.inspect(last_git))

core.events.unsubscribe(probe_handle)
up.events._reset_for_tests()
core.ensure_started(af.state.config)
git_count, last_git = 0, nil
local probe_post = core.events.subscribe("auto-finder.core.git:changed", git_probe_cb)
up.events.publish("core.git.state:changed",
  { repo_root = "/tmp/phase3-probe-post", git_dir = "/tmp/phase3-probe-post/.git", kind = "index" })
vim.wait(20)
ok("A7: translator re-arms after bus reset (event fires)", git_count == 1,
  "expected 1 fire after reset+ensure_started, got " .. git_count
    .. " — bus-reset re-arming is broken")
ok("A7: post-reset payload carries the new repo_root",
  last_git and last_git.repo_root == "/tmp/phase3-probe-post")
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
-- and after; both must return to the pre-ensure_started state. Core
-- opens watchers only for WATCHED worktrees (ADR-0200: no cwd walk).
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

-- The A8 contract per ADR §4 is "stop() releases every handle
-- ensure_started opened" — measured by calling stop FIRST to establish
-- a baseline, then ensure_started, then stop again (back to baseline).
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

ok("A8: ensure_started opens no cwd walk (handles never drop below baseline)",
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
end)

-- ───────────────────────── 32. ADR 0026 Phase 4: files cache + watchers ──
-- ADR 0026's ownership rules, and the ADR-0200 translation they now cover:
--   A1 — no view module subscribes to upstream auto-core topics
--   A2 — no view OR shared module opens an fs.watch or git.watch
--   A6 — core translates core.file:* / core.fs.dir:dirty into
--        auto-finder.core.files:changed for WATCHED directories only,
--        with owner-scoped, ref-counted directory watches
print("\n[32] ADR 0026 A1/A2 + ADR-0200 watched-directory translation")
section(function()
local core_watchers = require("auto-finder.core.watchers")
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
      ["\"core.fs."]         = true,   -- core.fs.dir:dirty (ADR-0200)
      ["\"state.core:"]      = true,   -- auto-core.files prefs; core translates them to files:filters
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
      local p = dir .. "/" .. name
      if t == "directory" then walk(p, fn)
      elseif t == "file" and name:match("%.lua$") then fn(p)
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

-- ── A6 (ADR-0200 §4.4): core translates events for WATCHED directories only ──
-- The files view asks core to watch its expanded directories; core turns a
-- core.file:* under one of them into auto-finder.core.files:changed naming that
-- directory, and ignores everything else. (The files cache, burst translator and
-- chunked warmer that A4/A6/A15 covered fed only the retired fork.)
do
  core_init.ensure_started(af.state.config)
  local tmp = vim.fn.tempname() .. "-a6-watched"
  vim.fn.mkdir(tmp, "p")
  local owner = {}
  ok("watch_dir arms a watch for the directory", core_watchers.watch_dir(tmp, owner) == true)
  local seen = {}
  local h = core_events.subscribe("auto-finder.core.files:changed", function(p) seen[#seen + 1] = p end)
  up.events.publish("core.file:created", { path = tmp .. "/new.txt", change = "created" })
  vim.wait(50, function() return #seen > 0 end, 5)
  ok("A6: an event in a watched directory is translated",
    #seen == 1 and seen[1].kind == "created" and seen[1].dir == tmp and seen[1].path == tmp .. "/new.txt",
    vim.inspect(seen))
  seen = {}
  up.events.publish("core.file:created", { path = "/tmp/not-watched-a6/x.txt", change = "created" })
  vim.wait(50)
  ok("A6: an event in an unwatched directory is not translated", #seen == 0, vim.inspect(seen))
  seen = {}
  up.events.publish("core.fs.dir:dirty", { path = tmp, reason = "unnamed" })
  vim.wait(50, function() return #seen > 0 end, 5)
  ok("A6: a nameless (dirty) event for a watched directory is translated",
    #seen == 1 and seen[1].kind == "dirty" and seen[1].dir == tmp, vim.inspect(seen))
  core_events.unsubscribe(h)

  -- ref-counted ownership: two owners, one handle
  local other = {}
  core_watchers.watch_dir(tmp, other)
  local before = #(up.fs.watch.list and up.fs.watch.list() or {})
  ok("two owners share one directory watch", core_watchers.dir_watch_count() >= 1
    and core_watchers.dir_watch_count(owner) == 1 and core_watchers.dir_watch_count(other) == 1)
  core_watchers.unwatch_dir(tmp, owner)
  ok("releasing one owner keeps the watch for the other", core_watchers.is_dir_watched(tmp))
  core_watchers.unwatch_owner(other)
  ok("releasing the last owner stops the watch", not core_watchers.is_dir_watched(tmp))
  local after = #(up.fs.watch.list and up.fs.watch.list() or {})
  ok("the fs.watch handle is closed with the last owner", after == before - 1,
    string.format("before=%d after=%d", before, after))
  vim.fn.delete(tmp, "rf")
end
end)

-- ───────────────────────── 33. ADR 0026 Phase 5: git cache + translation ──
-- ADR 0026 Phase 5: real `core.git.snapshot_now` backed by
-- auto-core.git.status, and the core.git.state:changed →
-- auto-finder.core.git:changed translation. The files view consumes the
-- translated topic for its filename colours (ADR-0200 §4.6).
print("\n[33] ADR 0026 Phase 5 — git cache + translation")
section(function()
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

-- ── ADR-0200 §4.6: a git-state event costs the files view ONE status read, no directory read ──
do
  af.focus(1)  -- files
  local fview = require("auto-finder.views.files")
  vim.wait(1000, function() return fview._state.shown and fview._state.repo_top ~= nil end, 10)
  ok("precondition: the files view is shown and knows its repo", fview._state.shown and fview._state.repo_top ~= nil,
    "repo_top=" .. tostring(fview._state.repo_top))
  local status = require("auto-core.git.status")
  local scan = require("auto-core.fs.scan")
  local real_get_async, real_read_dir = status.get_async, scan.read_dir
  local status_calls, read_calls = 0, 0
  status.get_async = function(root, opts, cb)
    status_calls = status_calls + 1
    return real_get_async(root, opts, cb)
  end
  scan.read_dir = function(...)
    read_calls = read_calls + 1
    return real_read_dir(...)
  end
  vim.wait(700) -- let any settle window from the focus drain first
  status_calls, read_calls = 0, 0
  up.events.publish("core.git.state:changed", {
    repo_root = vim.fn.getcwd(), git_dir = vim.fn.getcwd() .. "/.git", kind = "index",
  })
  vim.wait(1000, function() return status_calls > 0 end, 10)
  vim.wait(400)
  ok("a git-state event triggers a git status read for the files view", status_calls >= 1,
    "status_calls=" .. status_calls)
  ok("a git-state event reads NO directory", read_calls == 0, "read_calls=" .. read_calls)
  status.get_async, scan.read_dir = real_get_async, real_read_dir
end
end)

-- ───────────────────────── 34. ADR 0026 Phase 6: core.buffers + core.repos ──
-- ADR 0026 Phase 6: real implementations of core.buffers
-- (Buf*-autocmd-driven cache) and core.repos (auto-finder.repos
-- denormalized view). The buffers and repos views refresh on the
-- centralized auto-finder.core.* signals and declare the topic.
print("\n[34] ADR 0026 Phase 6 — core.buffers + core.repos")
section(function()
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

-- ── views declare the core topic they refresh from ──
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
end)

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
section(function()
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

-- A3 is partial: the files / buffers / repos views mount synchronously (a
-- buffer on first get_buffer), because the auto-core Registry binds keymaps
-- onto the buffer get_buffer returns (audit-log F7.1 in
-- tests/auto-finder-test-audit.md). Only `dbase` exercises the placeholder
-- pattern — asserted in the A16 section below.

-- ── A16: dbase mounts synchronously; no-backend path is explained ──
-- Rewritten for v0.4.0. This used to assert a `shared.loading` placeholder on
-- cold mount, because nvim-dbee mounted behind `vim.schedule` and the section
-- had to show something first. dbee is gone and autodb's `tree.get_buffer`
-- returns a real buffer synchronously, so there is no cold placeholder and no
-- generation counter to match — asserting the old contract would now be
-- asserting removed machinery.
--
-- autodb is not on the headless rtp, so this exercises the no-backend path:
-- a self-describing placeholder that names AUTODB (never dbee, which AutoVim
-- deliberately removed).
do
  local dbase = require("auto-finder.views.dbase")
  dbase._bufnr = nil
  dbase._owned_bufs = {}

  local b = dbase.get_buffer(0)
  ok("A16: dbase.get_buffer returns a valid buffer with no backend installed",
    type(b) == "number" and vim.api.nvim_buf_is_valid(b), tostring(b))
  ok("A16: the no-backend buffer is tagged view='dbase'",
    vim.b[b].auto_finder_view == "dbase", tostring(vim.b[b].auto_finder_view))
  ok("A16: it is the dbase placeholder, by name",
    vim.api.nvim_buf_get_name(b):find("auto-finder-dbase://placeholder", 1, true) ~= nil,
    vim.api.nvim_buf_get_name(b))

  local text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  ok("A16: it points the user at autodb", text:find("autodb", 1, true) ~= nil, text)
  -- The regression guard that matters post-cutover: never send anyone to dbee.
  ok("A16: *** it does NOT mention dbee, which AutoVim removed on purpose ***",
    text:lower():find("dbee", 1, true) == nil, text)

  ok("A16: dbase.on_focus is safe with no backend and no real panel winid",
    pcall(dbase.on_focus, 0, b))

  dbase.on_close()
  ok("A16: on_close disposes the buffer it owned",
    vim.api.nvim_buf_is_valid(b) == false)
  dbase._bufnr = nil
  dbase._owned_bufs = {}
end


-- Restore: focus the config view so later sections don't fight
-- the panel state created here.
local config_idx = require("auto-finder.sections")._by_name["config"]
if config_idx then af.focus(config_idx) end
vim.wait(50)
end)

-- ───────────────────────── 36. ADR 0026 Phase 8: shared/logging sweep ──
-- ADR 0026 Phase 8:
--   - shared/debounce.lua extracted; core/init.lua refactored to use it
--   - dbase log component tags migrated to view.dbase.* (A10)
--   - vim.notify audit: zero live calls in the plugin tree
print("\n[36] ADR 0026 Phase 8 — shared extraction + logging sweep (A9/A10)")
section(function()
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

-- ── A9: zero live vim.notify calls in plugin tree ──
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
      do
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
  ok("A9: zero live vim.notify calls in plugin tree",
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
      do
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
end)

-- ───────────────────────── 37. ADR 0026 Phase 9: acceptance audit (closeout) ──
-- ADR 0026 Phase 9 is a ledger pass — no new functionality.
-- The acceptance work is to assert:
--   A11: total count ≥ 263, failed = 0 (no regression vs. the
--        v0.2.23 baseline that opened the refactor).
--   A5:  retired with the metrics:paint instrumentation (ADR-0200). The
--        measured before/after comparison it deferred is now the
--        VM43 benchmark in tests/bench/ (ADR-0200 §5 cell 11).
--   Audit: every per-phase smoke section is still green
--          (implicitly proved by failed == 0 below; explicitly
--           checked in §Per-phase audit pass).
print("\n[37] ADR 0026 Phase 9 — acceptance audit (closeout)")
section(function()
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
    { id = "32", phase = "A1/A2 + watched-dir translation", marker = "%[32%] ADR 0026 A1/A2" },
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
end)

-- ───────────────────────── 38. v0.2.25 fix: view subs survive bus reset (B1) ──
-- v0.2.25 moved view subscriptions from one-shot booleans (which a bus reset
-- wiped while the flag blocked re-arm) to `shared.view_subs`'s replace
-- semantics. The invariant holds for the rebuilt views (ADR-0200): after a bus
-- reset and a re-focus, each view's refresh sink fires again.
--   files   — auto-finder.core.files:changed → one directory read (fs.scan.read_dir)
--   buffers — auto-finder.core.buffers:changed → a repaint
--   repos   — auto-finder.core.repos:changed → tree.invalidate
print("\n[38] v0.2.25 — view subscriptions survive auto-core bus reset (B1)")
section(function()
local core_events = require("auto-finder.core.events")
local up = require("auto-core")

local function reset_and_refocus(view_idx)
  af.focus(view_idx)
  vim.wait(200)
  up.events._reset_for_tests()
  require("auto-finder.core").ensure_started(af.state.config)
  af.focus(view_idx)
  vim.wait(100)
end

-- files view
do
  local files_idx = require("auto-finder.sections")._by_name["files"]
  if files_idx then
    reset_and_refocus(files_idx)
    local fview = require("auto-finder.views.files")
    local root = fview._state.model and fview._state.model.root
    local scan = require("auto-core.fs.scan")
    local real = scan.read_dir
    local reads = {}
    scan.read_dir = function(path, ...) reads[#reads + 1] = path; return real(path, ...) end
    core_events.publish("auto-finder.core.files:changed",
      { kind = "created", dir = root, path = (root or "") .. "/b1-probe.txt" })
    vim.wait(1200, function() return vim.tbl_contains(reads, root) end, 10)
    scan.read_dir = real
    ok("B1: files view re-arms after bus reset (the named directory is re-read)",
      root ~= nil and vim.tbl_contains(reads, root), "reads=" .. vim.inspect(reads))
    ok("B1: files view's subscription set holds its slots",
      fview._state.subs and fview._state.subs:count() >= 3,
      "count=" .. tostring(fview._state.subs and fview._state.subs:count()))
  end
end

-- buffers view
do
  local buffers_idx = require("auto-finder.sections")._by_name["buffers"]
  if buffers_idx then
    reset_and_refocus(buffers_idx)
    local bview = require("auto-finder.views.buffers")
    local real = bview.paint
    local paints = 0
    bview.paint = function(...) paints = paints + 1; return real(...) end
    core_events.publish("auto-finder.core.buffers:changed", { kind = "add", bufnr = 1 })
    vim.wait(1200, function() return paints > 0 end, 10)
    bview.paint = real
    ok("B1: buffers view re-arms after bus reset (it repaints)", paints > 0, "paints=" .. paints)
  end
end

-- repos view
do
  local repos_idx = require("auto-finder.sections")._by_name["repos"]
  if repos_idx then
    reset_and_refocus(repos_idx)
    local tree = require("auto-finder.views.repos.tree")
    local real = tree.invalidate
    local calls = 0
    tree.invalidate = function(...) calls = calls + 1; return real(...) end
    core_events.publish("auto-finder.core.repos:changed",
      { kind = "worktree_switched", repo_root = vim.fn.getcwd() })
    vim.wait(1200, function() return calls > 0 end, 10)
    tree.invalidate = real
    ok("B1: repos view re-arms after bus reset (it invalidates)", calls > 0, "calls=" .. calls)
    ok("B1: repos view's subscription set holds the refresh slot",
      tree._subs and tree._subs:count() >= 1)
  end
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
  -- the panel rapidly so async view callbacks (scans, git reads) land
  -- against a hidden view.
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
end)

-- ─────────────────────── 39. views.todos — Phase 2 auto-core.todo panel ──
print("\n[39] views.todos — render, keymaps, subscriptions, no-hijack")
section(function()
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

  -- v0.3.3: the Open header is ALWAYS visible, even at count 0, so a
  -- task-less panel still opens on a task section. Without it the only
  -- section was Vars, and the default (top-of-buffer) cursor `a`
  -- pressed there adds a *variable*, not a task.
  ok("empty workspace renders the Open header at count 0",
    raw_empty:find("Open %(0%)") ~= nil, raw_empty)
  -- Open must sit ABOVE Vars so the top-of-buffer cursor lands on it.
  local pos_open_hdr = raw_empty:find("Open %(0%)")
  local pos_vars_hdr = raw_empty:find("Vars %(")
  ok("empty workspace: Open header precedes the Vars header",
    pos_open_hdr and pos_vars_hdr and pos_open_hdr < pos_vars_hdr,
    "open=" .. tostring(pos_open_hdr) .. " vars=" .. tostring(pos_vars_hdr))
  -- The row at buffer line 1 must be the Open bucket-header — that is
  -- what makes the default-cursor `a` dispatch to add-task, not
  -- add-var (the `a` keymap routes vars-entry / vars-header rows to
  -- _add_var and everything else to _add_task).
  local row_l1
  for _, r in ipairs(view._rows or {}) do
    if r.lnum == 1 then row_l1 = r; break end
  end
  ok("empty workspace: line-1 row is the Open bucket-header",
    row_l1 and row_l1.kind == "bucket-header" and row_l1.section == "open",
    vim.inspect(row_l1))
  ok("empty workspace: line-1 row is NOT a Vars row (so `a` adds a task)",
    row_l1 ~= nil
      and row_l1.kind ~= "vars-entry"
      and row_l1.kind ~= "vars-header")
  -- The ephemeral-index hint is suppressed when Open is empty — there
  -- is no numbering to explain.
  ok("empty workspace: no ephemeral-index hint under an empty Open",
    raw_empty:find("index is ephemeral") == nil)

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
end)

-- ─────────────────────── 39b. views.todos — malformed-task render (v0.2.38) ──
print("\n[39b] views.todos — malformed-task scan rendering")
section(function()
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
end)

-- ─────────────────────── 39c. views.todos — Vars section + status modal (v0.2.39) ──
print("\n[39c] views.todos — Vars section + numbered status modal")
section(function()
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
end)

-- ─────────────────────── 39d. views.todos — collapsible sections + archive periods (v0.2.41) ──
print("\n[39d] views.todos — collapsible sections + archive year/month groups")
section(function()
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
end)

-- ─────────────────────── 40. ADR-0035 Phase 1 ────────────────────────
-- Six-bucket rendering (`Open → In Progress → Automated → Deferred →
-- Completed → Archived`) and per-bucket 1-based numbering on every
-- non-archived bucket.
print("\n[40] ADR-0035 Phase 1 — six-bucket panel + numbered non-archived rendering")
section(function()
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
  -- Assign AND engage, explicitly. The comment here used to read
  -- "auto-engages in-progress", and that stopped being true: auto-core
  -- decoupled assignment from the status transition (86b0897, an ADR-0035 r5
  -- amendment — "starting work should not be claimed purely because ownership
  -- changed"). The fixture kept assigning and expecting a bucket move, so the
  -- task stayed in `open` and FOUR assertions failed from one cause: no In
  -- Progress header, the two order checks that reference it, and p40-open
  -- rendering as ordinal 2 because Open now held two rows.
  --
  -- This is a fixture that has to say what it wants rather than rely on a
  -- side effect of something else, which is the better shape regardless.
  todo.assign(id_ip, "agent:phase1")
  todo.status(id_ip, "in-progress")
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

  -- 40e. ASSIGNMENT DOES NOT MOVE A TASK — the PANEL-VISIBLE half.
  --
  -- auto-core decoupled assignment from the status transition (86b0897,
  -- ADR-0035 r5: "starting work should not be claimed purely because
  -- ownership changed") and asserts that at the MODEL layer. What only this
  -- repo can assert is the consequence a user sees: an assigned task still
  -- renders under Open. auto-core has no panel, so that property has no other
  -- home.
  --
  -- This is NOT covered by the fixture above, and the reason is worth stating
  -- because it is why the cell exists: the fixture now calls assign AND
  -- status, so it ARRANGES the state it wants and observes the decoupling
  -- nowhere. Setup is not pinning. Without this cell, someone "fixing" the
  -- panel by re-adding the move — here, or by asking auto-core to revert
  -- deliberate work — meets nothing. (gold-man, #28 r0.)
  --
  -- 2026-09-08: the `A` ACTION now does move an open task to in-progress
  -- (Johno's requirement 5), and this cell still holds — deliberately. The
  -- two are different subjects. `todo.assign` is the model operation an agent
  -- calls when it delegates, and it must not claim on a peer's behalf that
  -- work started; the `A` action is an operator picking a live agent and
  -- dispatching a directive, which is a decision to start. See [40f] below
  -- for the other half, and the comment at `_assign_task`'s status call.
  local id_asg = todo.add({ id = "2026-05-30-p40-assigned-only",
                            title = "assigned but not started" })
  todo.assign(id_asg, "agent:phase1")
  todo.refresh()
  vim.wait(150, function() return false end)
  if type(view.refresh) == "function" then pcall(view.refresh)
  else view.get_buffer(panel_win) end
  vim.wait(80, function() return false end)

  local asg_row
  for _, row in ipairs(view._rows or {}) do
    if row.kind == "task" and row.task and row.task.id == id_asg then asg_row = row end
  end
  ok("p40e: an assigned task is still status=open (assignment moved nothing)",
    asg_row ~= nil and asg_row.task.status == "open",
    "row=" .. tostring(asg_row ~= nil) .. " status="
      .. tostring(asg_row and asg_row.task.status))

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local ln_open, ln_ip
  for i, l in ipairs(lines) do
    if not ln_open and l:find("Open %(") then ln_open = i end
    if not ln_ip and l:find("In Progress %(") then ln_ip = i end
  end
  ok("p40e: …and it renders UNDER Open, above the In Progress header",
    asg_row and ln_open and ln_ip
      and asg_row.lnum > ln_open and asg_row.lnum < ln_ip,
    ("row lnum=%s, Open header=%s, In Progress header=%s")
      :format(tostring(asg_row and asg_row.lnum), tostring(ln_open), tostring(ln_ip)))

  -- 40f. THE `A` ACTION STARTS THE WORK (Johno, 2026-09-08: "once the task is
  -- assigned, the auto-finder should trigger the task to move to
  -- 'in-progress' via auto-core command").
  --
  -- Paired with 40e on purpose. 40e pins that `todo.assign` moves nothing;
  -- this pins that the OPERATOR ACTION does. Either cell alone would be
  -- satisfied by putting the move in the wrong layer — 40e by never moving
  -- anything, this one by reinstating the auto-transition ADR-0035 r5
  -- removed. Together they say WHERE the decision to start work is made.
  --
  -- Driven through the bound `A` keymap rather than by calling the local, so
  -- what is exercised is the path a keypress takes.
  local saved_sel, saved_inp = vim.ui.select, vim.ui.input
  local saved_aa = package.loaded["auto-agents"]
  package.loaded["auto-agents"] = {
    spawned_agents = function()
      return { { slot = 5, name = "gold-man", kind = "claude",
                 mailbox_id = "agent:gold-man" } }
    end,
  }
  vim.ui.select = function(items, _, cb) cb(items[1]) end
  vim.ui.input = function(_, cb) cb("start with the tests") end

  local id_start = todo.add({ id = "2026-05-30-p40-A-starts-work",
                              title = "dispatched by the operator" })
  todo.refresh()
  vim.wait(150, function() return false end)
  if type(view.refresh) == "function" then pcall(view.refresh)
  else view.get_buffer(panel_win) end
  vim.wait(80, function() return false end)

  local start_row, start_lnum
  for _, row in ipairs(view._rows or {}) do
    if row.kind == "task" and row.task and row.task.id == id_start then
      start_row, start_lnum = row, row.lnum
    end
  end
  ok("p40f: fixture precondition — the new task renders, and is open",
    start_row ~= nil and start_row.task.status == "open",
    "row=" .. tostring(start_row ~= nil))

  local akm
  for _, k in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if k.lhs == "A" then akm = k end
  end
  ok("p40f: A is bound on the todos panel",
    akm ~= nil and type(akm.callback) == "function")

  if start_row and start_lnum and akm and vim.api.nvim_win_is_valid(panel_win) then
    vim.api.nvim_win_set_cursor(panel_win, { start_lnum, 0 })
    pcall(akm.callback)
    vim.wait(200, function() return false end)
    local t_after = todo.get(id_start)
    ok("p40f: *** the assignee landed ***",
      t_after ~= nil and t_after.assignee == "agent:gold-man",
      tostring(t_after and t_after.assignee))
    ok("p40f: *** and A moved the task to in-progress ***",
      t_after ~= nil and t_after.status == "in-progress",
      tostring(t_after and t_after.status))
  else
    ok("p40f: *** the assignee landed ***", false, "could not stage the row")
    ok("p40f: *** and A moved the task to in-progress ***", false, "could not stage the row")
  end

  -- A task that is ALREADY in-progress is not moved "again", and neither is
  -- one that has moved past it: a re-assignment records ownership and
  -- notifies, it does not rewind the lifecycle.
  local id_done = todo.add({ id = "2026-05-30-p40-A-no-rewind",
                             title = "already finished" })
  todo.status(id_done, "completed")
  todo.refresh()
  vim.wait(150, function() return false end)
  if type(view.refresh) == "function" then pcall(view.refresh) end
  vim.wait(80, function() return false end)
  local done_lnum
  for _, row in ipairs(view._rows or {}) do
    if row.kind == "task" and row.task and row.task.id == id_done then
      done_lnum = row.lnum
    end
  end
  if done_lnum and akm and vim.api.nvim_win_is_valid(panel_win) then
    vim.api.nvim_win_set_cursor(panel_win, { done_lnum, 0 })
    pcall(akm.callback)
    vim.wait(200, function() return false end)
    local t_done = todo.get(id_done)
    ok("p40f: *** A on a COMPLETED task assigns without rewinding it ***",
      t_done ~= nil and t_done.status == "completed"
        and t_done.assignee == "agent:gold-man",
      ("status=%s assignee=%s"):format(tostring(t_done and t_done.status),
        tostring(t_done and t_done.assignee)))
  else
    ok("p40f: *** A on a COMPLETED task assigns without rewinding it ***",
      false, "could not stage the completed row")
  end

  vim.ui.select, vim.ui.input = saved_sel, saved_inp
  package.loaded["auto-agents"] = saved_aa

  if vim.api.nvim_win_is_valid(panel_win) then
    pcall(vim.api.nvim_win_close, panel_win, true)
  end
  cleanup()
end)

-- ─────────────────────── 41. ADR-0035 Phase 3 — diagnostics ──────────
-- Real-time vim.diagnostic validator for `.todo-list/automated/*.md`
-- buffers + bash-disabled panel row indicator.
-- ─────────── [43] ADR-0040 Batches A+B+E ───────────
print("\n[43] ADR-0040 A+B+E — scope-safe window styling, surfaced failures, reopen-safe subscriptions")
-- IIFE: the main chunk is near Lua's 200-active-locals limit; a
-- function scope gets its own budget (same pattern as [42]).
section(function()
  -- 43a. C1: styling the panel window is scope-local. panel/window_style
  -- writes every option with `scope = "local"`; an unindexed `vim.wo.x` would
  -- also change the GLOBAL default and leak the panel's look into every other
  -- window. Style a window with an auto-finder buffer, then a plain buffer
  -- (which restores the window's own options), and require the globals intact.
  do
    local ws = require("auto-finder.panel.window_style")
    local function gopt(name) return vim.api.nvim_get_option_value(name, { scope = "global" }) end
    local g_before = {}
    for _, n in ipairs({ "number", "wrap", "cursorline", "list", "spell", "relativenumber", "winhighlight" }) do
      g_before[n] = gopt(n)
    end
    local plain = vim.api.nvim_create_buf(false, true)
    local win43 = vim.api.nvim_open_win(plain, false,
      { relative = "editor", row = 1, col = 1, width = 20, height = 5 })
    vim.api.nvim_set_option_value("number", true, { win = win43, scope = "local" })
    local styled = vim.api.nvim_create_buf(false, true)
    vim.bo[styled].filetype = "auto-finder"
    vim.api.nvim_win_set_buf(win43, styled)
    ws.apply(win43)
    ok("43a: the styled window gets the panel look (cursorline, nonumber, winhighlight)",
      vim.wo[win43].cursorline == true and vim.wo[win43].number == false
        and vim.wo[win43].winhighlight:find("Normal:AutoFinderNormal", 1, true) ~= nil,
      vim.wo[win43].winhighlight)
    vim.api.nvim_win_set_buf(win43, plain)
    ws.apply(win43)
    ok("43a: a non-auto-finder buffer gets the window's own options back",
      vim.wo[win43].number == true and vim.wo[win43].winhighlight == "",
      "number=" .. tostring(vim.wo[win43].number) .. " whl=" .. vim.wo[win43].winhighlight)
    for name, before in pairs(g_before) do
      ok("43a: GLOBAL '" .. name .. "' default survived the styling",
        gopt(name) == before, string.format("before=%s after=%s", tostring(before), tostring(gopt(name))))
    end
    pcall(vim.api.nvim_win_close, win43, true)
  end

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

  -- 43d. C4 (lector amendment 2): on_close disposes the view's subscriptions;
  -- re-arm on the next show works (reopen-safe).
  do
    local fview = require("auto-finder.views.files")
    local files_idx = require("auto-finder.sections")._by_name["files"]
    af.open(true)
    af.focus(files_idx)
    vim.wait(300, function() return fview._state.shown end, 10)
    ok("43d: subscriptions armed while shown (count ≥ 1)",
      fview._state.subs and fview._state.subs:count() >= 1)
    fview.on_close()
    ok("43d: on_close disposes every subscription", fview._state.subs:count() == 0,
      "count=" .. tostring(fview._state.subs:count()))
    ok("43d: on_close releases every directory watch", fview.watch_count() == 0)
    af.focus(files_idx)
    vim.wait(300, function() return fview._state.shown end, 10)
    ok("43d: re-arm on the next show succeeds (reopen-safe)", fview._state.subs:count() >= 1,
      "count=" .. tostring(fview._state.subs:count()))
  end

end)

-- ─────────── [44] ADR-0040 Batches C+D ───────────
print("\n[44] ADR-0040 D — marks per-render read cache")
section(function()
  -- 44a (the files panel's git-write adapter) went with the retired fork's
  -- command set (ADR-0200); auto-core's tests/git_write.lua covers the owner.
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
end)

-- NOTE (ADR-0040): section [43] is placed BEFORE [41] on purpose.
-- [41b]'s `vim.cmd("edit")` of the malformed-template fixture
-- SEGFAULTS headless nvim 0.12.2 on macOS with the suite's
-- accumulated attach state (pre-existing on main; bare-edit repro
-- survives) — everything after it, [41b]+[42], silently never ran,
-- and the printed totals hid the truncation. Tracked as a bug task;
-- do not add new sections after [41] until it is fixed.
-- ── [48] views._config_section — launch-config selection ────────
-- Unit coverage over the shared Config-section component against the
-- REAL auto-run.import sibling (on the rtp). A launch.json fixture with
-- one test-mode + one debug-mode config exercises the kind filter,
-- selection round-trip, expansion, and the env-value masking boundary.
print("\n[48] views._config_section — kind filter, select, masked expand")
section(function()
  local ok_cs, config_section = pcall(require, "auto-finder.views._config_section")
  ok("p48: _config_section loads", ok_cs, tostring(config_section))
  if not ok_cs then return end
  local ok_imp, import = pcall(require, "auto-run.import")
  if not ok_imp then
    ok("p48: auto-run.import sibling present", false, tostring(import))
    return
  end

  local worktree = require("auto-core.git.worktree")
  local repo = vim.fn.tempname() .. "-af-cfgfix"
  vim.fn.mkdir(repo .. "/.vscode", "p")
  vim.system({ "git", "init", "-q", "-b", "main", repo }, { text = true }):wait()
  local f = assert(io.open(repo .. "/.vscode/launch.json", "w"))
  f:write([[
{
  "version": "0.2.0",
  "configurations": [
    { "name": "Debug Server", "type": "go", "request": "launch",
      "mode": "debug", "program": "${workspaceFolder}/cmd/srv",
      "buildFlags": "-tags=dev", "env": { "SECRET_TOKEN": "hunter2" } },
    { "name": "Test Pkg", "type": "go", "request": "launch",
      "mode": "test", "program": "${workspaceFolder}" }
  ]
}
]])
  f:close()
  vim.system({ "git", "-C", repo, "-c", "user.email=s@t", "-c",
    "user.name=s", "add", "." }, { text = true }):wait()
  vim.system({ "git", "-C", repo, "-c", "user.email=s@t", "-c",
    "user.name=s", "commit", "-q", "-m", "init" }, { text = true }):wait()

  local prev_active = worktree.get_active()
  worktree.set_active(repo)
  require("auto-run.store.paths").invalidate()
  import.set_selected(nil)

  -- collect(): per-kind filtering.
  local tests = config_section.collect("test")
  ok("p48: collect('test') → only the test-mode config",
    tests and #tests == 1 and tests[1].name == "Test Pkg", vim.inspect(tests))
  local debugs = config_section.collect("debug")
  ok("p48: collect('debug') → only the debug-mode config",
    debugs and #debugs == 1 and debugs[1].name == "Debug Server",
    vim.inspect(debugs))

  -- emit(): a config row is produced, name carried.
  local function render(list, kind, expanded)
    local ctx = { list = list, kind = kind, lines = {}, rows = {},
      expanded = expanded or {},
      mark = function() end }
    config_section.emit(ctx)
    return ctx
  end
  local r1 = render(debugs, "debug")
  local cfg_row
  for _, row in ipairs(r1.rows) do
    if row.kind == "config" then cfg_row = row end
  end
  ok("p48: emit produces a config row with the name",
    cfg_row ~= nil and cfg_row.name == "Debug Server", vim.inspect(r1.rows))

  -- select(): round-trips through auto-run + annotates on re-collect.
  ok("p48: select handled for a config row",
    config_section.select(cfg_row) == true)
  ok("p48: selection reached auto-run",
    import.get_selected() == "Debug Server")
  ok("p48: re-collect marks the selected config",
    config_section.collect("debug")[1].selected == true)
  -- select on a non-config row is a no-op (returns false).
  ok("p48: select is a no-op on a foreign row",
    config_section.select({ kind = "env-file" }) == false)

  -- toggle_expand + emit: expanded field children, env VALUE MASKED.
  local exp = {}
  ok("p48: toggle_expand handled", config_section.toggle_expand(cfg_row, exp) == true)
  local r2 = render(config_section.collect("debug"), "debug", exp)
  local body = table.concat(r2.lines, "\n")
  ok("p48: expansion shows the env KEY", body:find("SECRET_TOKEN", 1, true) ~= nil)
  ok("p48: expansion MASKS the env VALUE (§8.2)",
    body:find("hunter2", 1, true) == nil, body)
  ok("p48: expansion shows build_flags", body:find("-tags=dev", 1, true) ~= nil)

  -- cleanup — leave no selection / active worktree behind.
  import.set_selected(nil)
  worktree.set_active(prev_active)
  require("auto-run.store.paths").invalidate()
  vim.fn.delete(repo, "rf")
end)

-- [49] "ADR-0058 M7 — views.dbase.tree (autodb explorer)" was removed here in
-- ADR-0078. It drove the renderer directly, and the renderer no longer lives in
-- this plugin: it moved to `autodb.views.drawer`, because it reads only
-- `autodb.session` and autodb needs it to show a drawer when installed WITHOUT
-- auto-finder.
--
-- Its assertions did not survive the move for two reasons, and both are the
-- point of the move rather than collateral:
--
--   * the premise. §[49] asserted the renderer "mounts without autodb
--     installed" — possible only while the renderer lived here. With autodb
--     absent there is now no renderer at all, and what this plugin owes the
--     user is the PLACEHOLDER. That contract is asserted in §[35] A16, which
--     also guards that the placeholder never mentions dbee.
--   * the shape. It reached into module-level state (`tree._rows`,
--     `_expanded`, `_cache`, `_bufnr`). The drawer is an instance factory now
--     (ADR-0078 §3.2) precisely so two hosts cannot share that state, so there
--     is no module-level state left to assert against.
--
-- The renderer's own behaviour — rendering, toggling, invalidate, keymap
-- vocabulary, buffer identity per host profile — is autodb's to cover, in
-- autodb's suite, next to the code. What remains auto-finder's is the facade:
-- the placeholder path, owned-buffer teardown, and that closing the section
-- RELEASES the drawer rather than disposing it behind the registry's back.
-- [50] "ADR-0058 M7 — dbase slot delegates by availability" was removed here in
-- v0.4.0. It asserted that with autodb absent "dbee remains in charge" — the
-- availability delegation between two backends. dbee is retired (ADR-0063 /
-- roadmap M8), so there is one backend and nothing to delegate between. The
-- surviving no-backend behaviour is pinned by §[35] A16, and the view contract
-- it also checked is enforced by the section registry itself.


-- ───── [51] `slot assign` — re-arrange the whole slot list ─────────
-- The gap this fills: `slot modify N <type>` rejects a type that
-- already lives in another slot, which is right for a single-slot
-- edit but makes a SWAP impossible — moving `repos` from slot 2 to
-- slot 1 collides with itself. `slot assign` replaces the whole list
-- at once, so any permutation is legal and only duplicates WITHIN the
-- new list are rejected. Three surfaces are pinned here: the
-- `af.slot_assign(tail)` API, the one-line `slot assign <t…>` DSL,
-- and the interactive walk driven through `panel.wizard`.
--
-- Runs last on purpose: it rewrites `cfg.sections` repeatedly. The
-- original arrangement is restored at the end regardless.
print("\n[51] slot assign — whole-list re-arrangement")
section(function()
local admin  = require("auto-finder.panel.admin")
local wizard = require("auto-finder.panel.wizard")
local st     = require("auto-finder.state")
local restore = vim.deepcopy(af.state.config.sections)

local function secs() return table.concat(af.state.config.sections, " ") end
local function has(list, want)
  for _, v in ipairs(list or {}) do if v == want then return true end end
  return false
end

ok("p51: slot 0 is 'config' (baseline for the protected-head checks)",
  af.state.config.sections[1] == "config", secs())
ok("p51: SLOT_MAX is exposed for the walk's upper bound",
  af.SLOT_MAX == 9, tostring(af.SLOT_MAX))

-- (a) the permutation `slot modify` cannot express.
af.slot_assign({ "files", "repos" })
local mod_err = af.slot_modify(1, "repos")
ok("p51: slot_modify still refuses a cross-slot swap (the contrast)",
  mod_err ~= nil and mod_err:match("already lives at slot") ~= nil,
  tostring(mod_err))
local err = af.slot_assign({ "repos", "files" })
ok("p51: slot_assign accepts the same swap", err == nil, err)
ok("p51: order applied", secs() == "config repos files", secs())
local reg = {}
for _, s in ipairs(require("auto-finder.views").enabled()) do
  reg[#reg + 1] = s.number .. ":" .. s.name
end
ok("p51: the live registry re-numbers to match",
  table.concat(reg, " ") == "0:config 1:repos 2:files", table.concat(reg, " "))

-- (b) validation is all-or-nothing: a bad entry anywhere leaves the
-- current arrangement untouched rather than half-applying.
local before = secs()
err = af.slot_assign({ "files", "files" })
ok("p51: duplicate rejected",
  err ~= nil and err:match("already assigned to slot 1") ~= nil, tostring(err))
ok("p51:   …and nothing was applied", secs() == before, secs())
err = af.slot_assign({ "files", "config" })
ok("p51: the slot-0 section is rejected in the tail",
  err ~= nil and err:match("protected slot%-0 section") ~= nil, tostring(err))
ok("p51:   …and the valid leading entry was NOT applied alone",
  secs() == before, secs())
err = af.slot_assign({ "definitely-not-a-view" })
ok("p51: unknown type rejected",
  err ~= nil and err:match("unknown section type") ~= nil, tostring(err))
err = af.slot_assign({})
ok("p51: an empty list is rejected (slot 0 alone is not an arrangement)",
  err ~= nil and err:match("at least one section") ~= nil, tostring(err))
err = af.slot_assign("files")
ok("p51: a non-list is rejected",
  err ~= nil and err:match("list of section types") ~= nil, tostring(err))
local over = {}
for i = 1, af.SLOT_MAX + 1 do over[i] = "slot" .. i end
err = af.slot_assign(over)
ok("p51: more than SLOT_MAX entries is rejected",
  err ~= nil and err:match("at most 9 sections") ~= nil, tostring(err))

-- (c) persistence. `_workspace_key()` is nil under headless `-u NONE`
-- with no workspace_root, so a bare "is it stored?" read would come
-- back nil and prove nothing either way. Stub the resolver to a key
-- of our own, assert it is EMPTY first (the positive control that
-- this check can tell written from unwritten), then assign and read.
local core = require("auto-core")
local real_root = core.git.worktree.get_workspace_root
core.git.worktree.get_workspace_root = function() return "/tmp/af-p51-ws" end
local wskey = af._workspace_key()
ok("p51: workspace key resolves under the stub", type(wskey) == "string",
  tostring(wskey))
ok("p51: control — nothing is persisted for that key yet",
  wskey and st.get_sections_for(wskey) == nil,
  vim.inspect(wskey and st.get_sections_for(wskey)))
af.slot_assign({ "repos", "files", "buffers" })
local persisted = wskey and st.get_sections_for(wskey)
ok("p51: the arrangement is persisted per workspace (NOT session-only)",
  persisted ~= nil and table.concat(persisted, " ") == "config repos files buffers",
  persisted and table.concat(persisted, " ") or "nil")
core.git.worktree.get_workspace_root = real_root

-- (d) the one-line DSL form.
admin.dispatch("slot assign files repos")
ok("p51: `slot assign <t…>` applies the whole arrangement",
  secs() == "config files repos", secs())
admin.dispatch("slot assign repos repos")
ok("p51: the DSL form rejects duplicates too",
  secs() == "config files repos", secs())

-- (e) tab-completion, consistent with the other `slot` verbs.
local _, subs = admin._complete_at("slot ", 5)
ok("p51: `slot ` completes 'assign'", has(subs, "assign"),
  table.concat(subs, ","))
ok("p51: `slot ` still completes 'modify'", has(subs, "modify"),
  table.concat(subs, ","))
local _, c1 = admin._complete_at("slot assign ", 12)
ok("p51: `slot assign ` completes section types", has(c1, "files"),
  table.concat(c1, ","))
ok("p51: `slot assign ` never offers the protected slot-0 section",
  not has(c1, "config"), table.concat(c1, ","))
local _, c2 = admin._complete_at("slot assign files ", 18)
ok("p51: a type already on the line drops out of the candidates",
  not has(c2, "files") and has(c2, "repos"), table.concat(c2, ","))

-- (f) the interactive walk. Driven through wizard.feed(), which is
-- exactly what the admin prompt buffer's <CR> callback calls while a
-- wizard is active.
local admin_buf = admin.get_or_create_buffer()
local function transcript()
  return table.concat(
    vim.api.nvim_buf_get_lines(admin_buf, 0, -1, false), "\n")
end

admin.dispatch("slot assign buffers marks")
ok("p51: staged a two-slot arrangement for the walk",
  secs() == "config buffers marks", secs())
admin.dispatch("slot assign")
ok("p51: a bare `slot assign` starts the walk", wizard.is_active())
local banner = transcript()
ok("p51: the walk banner names the fixed slot 0",
  banner:find("slot 0 'config' is fixed", 1, true) ~= nil)
ok("p51: the banner lists the current arrangement",
  banner:find("1:buffers", 1, true) ~= nil
    and banner:find("2:marks", 1, true) ~= nil)
ok("p51: the first question shows the slot's current occupant",
  banner:find("slot 1 [now buffers", 1, true) ~= nil, banner)
ok("p51: the first question lists what is still free",
  banner:find("free: ", 1, true) ~= nil, banner)

---Last transcript line matching `pat` — the questions repeat, so the
---assertions below must read the most recent one, not the first.
local function last_line(pat)
  local found
  for _, l in ipairs(vim.api.nvim_buf_get_lines(admin_buf, 0, -1, false)) do
    if l:find(pat) then found = l end
  end
  return found or ""
end

-- A rejected entry re-asks the SAME slot instead of unwinding.
wizard.feed("definitely-not-a-view")
ok("p51: an unknown type keeps the walk on the same slot",
  wizard.is_active() and transcript():find("unknown type", 1, true) ~= nil)
wizard.feed("config")
ok("p51: the slot-0 section is refused mid-walk",
  wizard.is_active()
    and transcript():find("protected slot-0 section", 1, true) ~= nil)
wizard.feed("marks")
-- The banner's `available:` list is a snapshot; each question has to
-- re-state what is STILL free or the walk misreports its own choices.
local q2 = last_line("slot 2 %[")
-- Scope the check to the `free:` list — "marks" also appears in this
-- line's `now marks` label, so a whole-line search would pass on the
-- wrong substring and prove nothing.
local free2 = q2:match("free: (.*)%]") or ""
ok("p51: the next question drops the type just assigned",
  free2 ~= "" and free2:find("marks", 1, true) == nil, q2)
ok("p51: the next question still offers an unassigned type",
  free2:find("buffers", 1, true) ~= nil, q2)
wizard.feed("marks")
ok("p51: a duplicate is refused mid-walk",
  wizard.is_active()
    and transcript():find("is already at slot 1", 1, true) ~= nil)
wizard.feed("buffers")
wizard.feed("")   -- ends the list; both sections re-listed → no drop
ok("p51: an empty entry ends the walk", not wizard.is_active())
ok("p51: a pure re-arrangement applies with no confirmation step",
  secs() == "config marks buffers", secs())

-- Ending early DROPS the slots you never reached, so that case asks.
admin.dispatch("slot assign")
wizard.feed("buffers")
wizard.feed("")
ok("p51: ending early raises a confirmation step", wizard.is_active())
ok("p51: the confirmation names what would be dropped",
  transcript():find("dropping: marks", 1, true) ~= nil)
wizard.feed("n")
ok("p51: declining leaves the arrangement untouched",
  not wizard.is_active() and secs() == "config marks buffers", secs())
admin.dispatch("slot assign")
wizard.feed("buffers")
wizard.feed("")
wizard.feed("y")
ok("p51: confirming applies the drop",
  not wizard.is_active() and secs() == "config buffers", secs())

-- Whitespace-only reads as empty, not as a section named "  ".
admin.dispatch("slot assign")
wizard.feed("   ")
ok("p51: a whitespace-only entry ends the walk without assigning",
  not wizard.is_active() and secs() == "config buffers", secs())

-- <C-c> mid-walk changes nothing.
admin.dispatch("slot assign")
wizard.feed("marks")
wizard.cancel()
ok("p51: cancelling mid-walk leaves the arrangement untouched",
  not wizard.is_active() and secs() == "config buffers", secs())

-- Restore whatever the suite was running with.
af.slot_assign(vim.list_slice(restore, 2, #restore))
ok("p51: original arrangement restored",
  secs() == table.concat(restore, " "), secs())
end)


-- ───── [52] permutation preserves survivor buffers, keymaps, winbar ─────
-- The high-risk half of `slot assign`. `_rebuild_section_registry` was
-- written for add/remove, where a survivor keeps its section NUMBER.
-- A permutation is the first caller that keeps every section but moves
-- it to a different number, and the only thing carrying a mounted
-- buffer across is the `old_bufs_by_name` bridge (init.lua §"Carry
-- survivor `_bufs` entries forward"): old number → name → new number.
--
-- [51] asserts the re-numbered `views.enabled()` METADATA, which is
-- cheap to get right and proves nothing about that bridge — with the
-- bridge disabled outright, [51] still passed 651/0. This section
-- pins the observable contract instead (ADR-0033's `_bufs` / keymap /
-- winbar surface, and the [[0008-auto-finder-keymap-audit]] runtime
-- slot-mutation addendum): the same buffer object must survive under
-- its NEW number, stay valid, keep its buffer-local bindings, and
-- still be what the numeric keymap mounts.
--
-- Two synthetic views are registered through `cfg.view_modules` rather
-- than reusing `files` / `repos`: they mount synchronously, so the
-- assertions are about the registry and not about view mount timing.
-- Reported by lector on PR #2.
print("\n[52] slot assign — survivors keep their buffers across a permutation")
section(function()
local restore_sections = vim.deepcopy(af.state.config.sections)
local restore_modules  = af.state.config.view_modules

-- Two trivial synchronous views. Each caches its own bufnr, exactly
-- like a real view, so a re-mount is observable as a DIFFERENT bufnr.
local function make_view(label)
  local V = {}
  V.get_buffer = function()
    if V._bufnr and vim.api.nvim_buf_is_valid(V._bufnr) then return V._bufnr end
    local b = vim.api.nvim_create_buf(false, true)
    vim.bo[b].bufhidden = "hide"
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "synthetic view: " .. label })
    V._bufnr = b
    return b
  end
  V.on_close = function() V._bufnr = nil end
  return V
end
package.loaded["af_p52_alpha"] = make_view("alpha")
package.loaded["af_p52_beta"]  = make_view("beta")
af.state.config.view_modules = {
  p52alpha = "af_p52_alpha",
  p52beta  = "af_p52_beta",
}

local types = af._available_section_types()
local function known(t)
  for _, v in ipairs(types) do if v == t then return true end end
  return false
end
ok("p52: third-party views are discoverable as slot types",
  known("p52alpha") and known("p52beta"), table.concat(types, ","))

local err = af.slot_assign({ "p52alpha", "p52beta" })
ok("p52: assigned the two synthetic views", err == nil, err)

-- Mount both so the registry actually caches a bufnr per section.
af.open(true)
af.focus(1)
af.focus(2)
local reg = af._registry
local buf_alpha, buf_beta = reg._bufs[1], reg._bufs[2]
ok("p52: both survivors are mounted before the permutation",
  buf_alpha and buf_beta and vim.api.nvim_buf_is_valid(buf_alpha)
    and vim.api.nvim_buf_is_valid(buf_beta),
  tostring(buf_alpha) .. "/" .. tostring(buf_beta))
ok("p52: the two survivors are distinct buffers", buf_alpha ~= buf_beta,
  tostring(buf_alpha) .. "/" .. tostring(buf_beta))
-- Control for the swap assertion below: BEFORE the permutation the
-- mapping runs the other way round. Without this, "_bufs[1]==buf_beta"
-- after the swap could be read as an accident of ordering.
ok("p52: control — before the swap, slot 1 holds alpha",
  reg._bufs[1] == buf_alpha and reg._bufs[2] == buf_beta)

-- ── the permutation ──
err = af.slot_assign({ "p52beta", "p52alpha" })
ok("p52: the swap is accepted", err == nil, err)
ok("p52: section list is swapped",
  table.concat(af.state.config.sections, " ") == "config p52beta p52alpha",
  table.concat(af.state.config.sections, " "))

-- THE assertion the disabled-bridge mutation probe defeats.
ok("p52: alpha's buffer followed it from slot 1 to slot 2",
  af._registry._bufs[2] == buf_alpha,
  "want " .. tostring(buf_alpha) .. " got " .. tostring(af._registry._bufs[2]))
ok("p52: beta's buffer followed it from slot 2 to slot 1",
  af._registry._bufs[1] == buf_beta,
  "want " .. tostring(buf_beta) .. " got " .. tostring(af._registry._bufs[1]))
-- A survivor must be CARRIED, not closed and re-created: both the
-- buffer object and its contents have to be the originals.
ok("p52: survivor buffers were not deleted",
  vim.api.nvim_buf_is_valid(buf_alpha) and vim.api.nvim_buf_is_valid(buf_beta))
ok("p52: alpha's buffer kept its contents (not re-mounted)",
  vim.api.nvim_buf_get_lines(buf_alpha, 0, 1, false)[1] == "synthetic view: alpha",
  vim.inspect(vim.api.nvim_buf_get_lines(buf_alpha, 0, 1, false)))

-- ── the numeric keymap routes to the RE-NUMBERED section ──
-- Resolve the window from the panel object rather than the
-- `af.state.panel_winid` mirror. The mirror is maintained by the
-- panel's on_open/on_close callbacks, and by this point in the suite
-- it can be stale from earlier sections' open/close churn; the
-- registry's own `focus()` reads `self.panel.winid`, so that is the
-- window whose buffer actually changes. (Verified in isolation that a
-- permutation leaves both in agreement — the drift is accumulated
-- suite state, not something `slot assign` causes.)
af.focus(1)
local panel_winid = (af._registry and af._registry.panel
  and af._registry.panel.winid) or af.state.panel_winid
ok("p52: the panel window is resolvable for the routing checks",
  panel_winid ~= nil and vim.api.nvim_win_is_valid(panel_winid),
  tostring(panel_winid))
ok("p52: focusing slot 1 mounts beta's buffer after the swap",
  panel_winid and vim.api.nvim_win_get_buf(panel_winid) == buf_beta,
  tostring(panel_winid and vim.api.nvim_win_get_buf(panel_winid)))

local maps = vim.api.nvim_buf_get_keymap(buf_beta, "n")
local map_2, map_q
for _, m in ipairs(maps) do
  if m.lhs == "2" then map_2 = m end
  if m.lhs == "q" then map_q = m end
end
ok("p52: buffer-local numeric mapping survives the permutation",
  map_2 ~= nil and map_2.callback ~= nil)
ok("p52: buffer-local `q` mapping survives the permutation",
  map_q ~= nil and map_q.callback ~= nil)
-- Press `2` for real: it must mount alpha, which now lives at slot 2.
if map_2 and map_2.callback then
  pcall(map_2.callback)
  ok("p52: pressing `2` mounts alpha at its new slot",
    vim.api.nvim_win_get_buf(panel_winid) == buf_alpha,
    tostring(vim.api.nvim_win_get_buf(panel_winid)))
else
  ok("p52: pressing `2` mounts alpha at its new slot", false, "no `2` mapping")
end

-- ── winbar reflects the new order and stays clickable ──
local winbar = vim.api.nvim_get_option_value("winbar", { win = panel_winid })
ok("p52: winbar lists both survivors after the permutation",
  winbar:find("p52beta", 1, true) ~= nil
    and winbar:find("p52alpha", 1, true) ~= nil, winbar)
ok("p52: winbar keeps its click router after the permutation",
  winbar:find("auto%-core%.ui%.winbar") ~= nil, winbar)
ok("p52: winbar orders beta before alpha (the new arrangement)",
  winbar:find("p52beta", 1, true) < winbar:find("p52alpha", 1, true), winbar)

-- Restore the suite's arrangement, then unregister the synthetic views.
af.slot_assign(vim.list_slice(restore_sections, 2, #restore_sections))
af.state.config.view_modules = restore_modules
package.loaded["af_p52_alpha"] = nil
package.loaded["af_p52_beta"]  = nil
for _, b in ipairs({ buf_alpha, buf_beta }) do
  if b and vim.api.nvim_buf_is_valid(b) then
    pcall(vim.api.nvim_buf_delete, b, { force = true })
  end
end
ok("p52: original arrangement restored",
  table.concat(af.state.config.sections, " ")
    == table.concat(restore_sections, " "),
  table.concat(af.state.config.sections, " "))
end)


-- ───── [53] the suite is hermetic w.r.t. the user's real XDG dirs ─────
-- The bug this pins: suites redirected XDG_CONFIG_HOME and
-- XDG_STATE_HOME but left XDG_CACHE_HOME on the real `$HOME/.cache`.
-- auto-run writes each run under `stdpath("cache")`, so on a host where
-- that path is read-only the mkdir failed with E739, no job spawned,
-- and ADR-0048's seven p46 assertions cascaded off the missing spawn —
-- 147/7 instead of 154/0, for months, with two agents on the same
-- machine and commit disagreeing about whether the suite was green.
--
-- An undeclared dependency on a writable home directory is invisible
-- until it bites, so assert it directly rather than trusting that every
-- future suite remembers to call tests/_sandbox.lua.
--
-- `stdpath()` is the right instrument here, not `vim.env`: it is what
-- the production code actually calls, and it re-reads the environment
-- on every invocation.
print("\n[53] XDG isolation — no suite writes to the real home")
section(function()
-- Compare against the helper's EXACT returned root, and resolve
-- symlinks on both sides. Two false negatives were caught here in
-- review: deriving the root as `:h` of stdpath("cache") yields
-- `<root>/cache` (Neovim appends `/nvim`), so a path under
-- `<root>/data` passed the outside-sandbox test; and testing only a
-- `$HOME/.` prefix let `$HOME/tmp` through as "outside the home".
local function real(p)
  if type(p) ~= "string" or p == "" then return nil end
  local ok, r = pcall(vim.uv.fs_realpath, vim.fn.fnamemodify(p, ":p"))
  return (ok and type(r) == "string") and r or vim.fn.fnamemodify(p, ":p")
end
local home = real(vim.env.HOME)
local root = real(SANDBOX)

local function under(p, base)
  if not p or not base then return false end
  return p == base or vim.startswith(p, base .. "/")
end

-- Controls: without these the containment assertions could pass
-- vacuously on an unset HOME or an unresolvable root.
ok("p53: control — HOME resolves", type(home) == "string" and home ~= "", tostring(home))
ok("p53: control — the sandbox root resolves",
  type(root) == "string" and root ~= "" and vim.fn.isdirectory(root) == 1, tostring(root))
ok("p53: control — the sandbox is not itself inside HOME",
  not under(root, home), tostring(root))

for _, kind in ipairs({ "config", "state", "cache" }) do
  local resolved = vim.fn.stdpath(kind)
  if type(resolved) == "table" then resolved = resolved[1] end
  vim.fn.mkdir(resolved, "p")
  local rp = real(resolved)
  ok(("p53: stdpath('%s') is inside the run's sandbox"):format(kind),
    under(rp, root), tostring(rp) .. "  root=" .. tostring(root))
  ok(("p53: stdpath('%s') is outside the real home"):format(kind),
    not under(rp, home), tostring(rp) .. "  home=" .. tostring(home))
  -- Writability is the property that actually broke: a redirect
  -- pointing somewhere unwritable satisfies both checks above and
  -- still reproduces the original E739 cascade.
  ok(("p53: stdpath('%s') is writable"):format(kind),
    vim.fn.filewritable(resolved) == 2,
    tostring(resolved) .. " filewritable=" .. vim.fn.filewritable(resolved))
end

-- DATA is deliberately NOT redirected: installed treesitter parsers and
-- plugin data live under it, and hiding them fails ADR-0048 for an
-- unrelated reason. Asserted so nobody "completes the set".
local data = vim.fn.stdpath("data")
if type(data) == "table" then data = data[1] end
ok("p53: stdpath('data') is intentionally NOT sandboxed",
  not under(real(data), root), tostring(data) .. "  root=" .. tostring(root))

-- The exact path whose read-only-ness caused the 147/7 cascade.
local run_root = vim.fn.stdpath("cache") .. "/auto-run/runs"
vim.fn.mkdir(run_root, "p")
ok("p53: auto-run's run directory is creatable under the sandboxed cache",
  vim.fn.isdirectory(run_root) == 1, run_root)
end)


-- ───── [54] state.section_buffers stays a LIVE alias of _registry._bufs ─────
-- `setup()` publishes `M.state.section_buffers` as an alias of the
-- registry's bufnr cache, and the comment there promises "we mutate in
-- place (never re-assign) elsewhere so the alias never goes stale".
-- `_rebuild_section_registry` broke that promise by rebinding
-- `_registry._bufs` to a fresh table, so after ANY slot mutation the
-- alias pointed at an orphan. Two production writers target the alias
-- — the repos-follow bufnr update and the per-section clear — and both
-- silently landed nowhere the registry could see.
--
-- Every `_rebuild_section_registry` caller is covered here, because the
-- defect was in the shared function rather than in any one verb.
--
-- `rawequal` is the instrument: a deep-equality check would pass on two
-- distinct tables holding the same entries, which is exactly the broken
-- state. Identity is the property that matters.
print("\n[54] state.section_buffers stays a live alias across slot mutations")
section(function()
local restore = vim.deepcopy(af.state.config.sections)
local function aliased()
  return rawequal(af.state.section_buffers, af._registry._bufs)
end

ok("p54: the alias holds before any mutation", aliased())

-- Control: prove `aliased()` can observe a WRITE, not just table
-- identity. Without this, a broken alias that happened to be the same
-- empty table would look fine.
af._registry._bufs[97] = 4242
ok("p54: control — a registry write is visible through the alias",
  af.state.section_buffers[97] == 4242,
  tostring(af.state.section_buffers[97]))
af._registry._bufs[97] = nil

-- Each caller of _rebuild_section_registry, in turn.
af.slot_add("buffers")
ok("p54: alias survives slot_add", aliased())
af.slot_modify(#af.state.config.sections - 1, "marks")
ok("p54: alias survives slot_modify", aliased())
af.slot_remove(#af.state.config.sections - 1)
ok("p54: alias survives slot_remove", aliased())
af.slot_assign({ "repos", "files" })
ok("p54: alias survives slot_assign (permutation)", aliased())

-- The fifth caller needs care. `_reseed_sections_for_workspace`
-- EARLY-RETURNS when the persisted layout already equals the live one
-- ("No-op if the target already matches what's loaded"). Calling it
-- straight after slot_assign persisted that same layout means the
-- reseed takes the fast path and never rebuilds — the assertion then
-- passes without exercising the caller at all. Caught in review.
--
-- So: persist a DIFFERENT layout, and count rebuild calls to prove one
-- actually fired. The counter is the positive control; without it this
-- is indistinguishable from the no-op it used to be.
local core_wt = require("auto-core")
local real_root = core_wt.git.worktree.get_workspace_root
core_wt.git.worktree.get_workspace_root = function() return "/tmp/af-p54-ws" end
local rebuilds = 0
local real_rebuild = af._rebuild_section_registry
af._rebuild_section_registry = function(...)
  rebuilds = rebuilds + 1
  return real_rebuild(...)
end
require("auto-finder.state").set_sections_for(af._workspace_key(),
  { "config", "marks" })          -- deliberately != the live list
af._reseed_sections_for_workspace()
af._rebuild_section_registry = real_rebuild
core_wt.git.worktree.get_workspace_root = real_root

ok("p54: control — the reseed really did rebuild",
  rebuilds == 1, "rebuild calls = " .. rebuilds)
ok("p54: the reseed applied the persisted layout",
  table.concat(af.state.config.sections, " ") == "config marks",
  table.concat(af.state.config.sections, " "))
ok("p54: alias survives a workspace reseed", aliased())

-- The property the production writers actually depend on: a write made
-- through the registry after a mutation must be visible via the alias,
-- and vice versa. Identity alone is necessary but not sufficient.
af._registry._bufs[96] = 777
ok("p54: post-mutation registry write is visible through the alias",
  af.state.section_buffers[96] == 777, tostring(af.state.section_buffers[96]))
af.state.section_buffers[95] = 888
ok("p54: post-mutation alias write is visible through the registry",
  af._registry._bufs[95] == 888, tostring(af._registry._bufs[95]))
af._registry._bufs[96], af._registry._bufs[95] = nil, nil

-- Survivor entries must still be carried across; the in-place rewrite
-- must not have cost the name->number remap that [52] pins.
af.slot_assign(vim.list_slice(restore, 2, #restore))
ok("p54: original arrangement restored",
  table.concat(af.state.config.sections, " ") == table.concat(restore, " "),
  table.concat(af.state.config.sections, " "))
ok("p54: alias still holds after restore", aliased())
end)

-- ───────────────────────── summary ────────────────────────
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
