---View — auto-run test discovery tree (ADR-0048 §8.1).
---
---Flat scratch-buffer view, NOT neo-tree-backed (same UX shape as
---`auto-finder.views.todos` / `.marks`). A pure renderer over
---auto-run.nvim's public discovery surface: the position tree
---(`dir → file → namespace → test`), the last-results map, and the
---bounded full scan. All data flows through `require("auto-run")`
---— this view never reads auto-run's store files directly and
---never re-derives shared state ([[auto-family-state-ownership]]).
---
---Layout:
---  - Header line with the discovery root + file/position counts,
---    plus the live scan state (`scanning…` / structured cap
---    report when a bounded scan aborts — no-silent-caps rule).
---  - A "Config" section above Env: the `kind=test` VSCode
---    `launch.json` configs auto-run parses, with a `*` marker on the
---    per-repo selected config. Selecting one makes it the active base
---    merged into every subsequent launch (env/build_flags/etc.).
---    Shared renderer/actions in `views/_config_section.lua` (debug
---    view shows `kind=debug`). `o` expands resolved fields with env
---    VALUES masked (§8.2).
---  - An "Env" section (§8.4, r5) above the position tree: candidate
---    env files with a `*` marker on the per-repo selection, rows
---    dimmed when the file is missing. Shared renderer/actions in
---    `views/_env_section.lua` (debug view parity). Collapse
---    persists via the same tests_collapsed mechanism as folders.
---  - The position tree, indented per depth, with collapse
---    chevrons on containers. Folder (dir) collapse state persists
---    across sessions via `auto-core.state.namespace("auto-run.ui")`;
---    file/namespace collapse is session-local.
---  - Per-row status glyphs from the last run's results:
---    ✓ passed · ✗ failed · ○ skipped · ● running. Containers show
---    auto-run's upward aggregation. Updated on `run.results:changed`.
---
---Buffer-local keymaps:
---  <CR>  jump to the position (editor-routed via
---        auto-finder._editor_target_winid); on a container row,
---        toggle collapse; on an expanded output-path detail row,
---        open the run's output file; on a config row, open
---        launch.json at that entry; on an env file, open it; on
---        an env var, open the file at that entry's line.
---  r     run the position under the cursor (test / namespace /
---        file / folder = suite) via discovery.run_position
---  R     re-run the last position run from this panel
---  d     debug the test under the cursor (dap strategy,
---        discovery.debug_position)
---  o     toggle — details expansion on a test row (last result
---        status, duration, run-output path — emit_frontmatter
---        style child rows), collapse on a container row; on an
---        env file, inline KEY=VALUE expansion (user-owned file —
---        interactive display, §4.2 r5 boundary)
---  s     config row → select/deselect it (active base merged into
---        every subsequent launch); env file → select/deselect it
---        (highest-precedence env_files entry for every launch, §4.2)
---  e     env var → edit the value (vim.ui.input, prefilled)
---  a     env file row / Env header → add KEY=VALUE (two prompts;
---        already-exists offers overwrite)
---  i     output float — the run's full terminal output (what
---        `go test` printed), via auto-run's discovery.run_output.
---        (`o` shows result METADATA; `i` shows the logs.)
---  S     full worktree scan (bounded + cancelable — a second `S`
---        while scanning cancels)
---  x     stop running test jobs started from this panel's runs
---  ?     help overlay listing every keymap on this buffer
---
---Soft dependency: auto-run.nvim. When absent the view renders a
---one-line hint and every action no-ops (the dbase-without-dbee
---precedent) — the rest of the panel is unaffected.
---
---Event-driven refresh honors the no-hijack invariant (ADR-0009):
---re-render only when the buffer is visible, via vim.schedule,
---never touching window focus or non-owned buffers.
---@module 'auto-finder.views.tests'

local M = {
  name        = "tests",
  description = "auto-run test discovery tree (run / debug / results)",
}

local FILETYPE = "auto-finder"

-- Highlight groups — default-link strategy shared with marks/todos:
-- near-universal groups so the panel picks up the active palette;
-- user `:hi AutoFinderTests*` overrides always win (`default = true`).
local HL = {
  header       = "AutoFinderTestsHeader",      -- top status line
  config_header = "AutoFinderTestsConfigHeader", -- Config section header
  env_header  = "AutoFinderTestsEnvHeader",   -- Env section header (§8.4)
  scan_state  = "AutoFinderTestsScanState",   -- scanning… / cap report
  scan_capped = "AutoFinderTestsScanCapped",  -- the cap warning lines
  chevron     = "AutoFinderTestsChevron",     -- ▼ / ▶
  dir         = "AutoFinderTestsDir",         -- folder rows
  file        = "AutoFinderTestsFile",        -- file rows
  namespace   = "AutoFinderTestsNamespace",   -- namespace rows
  test        = "AutoFinderTestsTest",        -- test rows
  glyph_pass  = "AutoFinderTestsPass",        -- ✓
  glyph_fail  = "AutoFinderTestsFail",        -- ✗
  glyph_skip  = "AutoFinderTestsSkip",        -- ○
  glyph_run   = "AutoFinderTestsRunning",     -- ●
  duration    = "AutoFinderTestsDuration",    -- (12ms) annotation
  empty       = "AutoFinderTestsEmpty",       -- "(no tests discovered)"
  help        = "AutoFinderTestsHelp",        -- hint copy
  help_key    = "AutoFinderTestsHelpKey",     -- `S` snippet accent
  fm_label    = "AutoFinderTestsFmLabel",     -- detail-row field label
  fm_value    = "AutoFinderTestsFmValue",     -- detail-row value
  fm_path     = "AutoFinderTestsFmPath",      -- path-shaped detail value
  fm_null     = "AutoFinderTestsFmNull",      -- (none) placeholder
}

local NS = vim.api.nvim_create_namespace("auto-finder.tests.hl")

local function _apply_default_highlights()
  local set = function(name, link)
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
  end
  set(HL.header,      "Title")
  set(HL.config_header, "Type")
  set(HL.env_header,  "Type")
  set(HL.scan_state,  "Comment")
  set(HL.scan_capped, "DiagnosticWarn")
  set(HL.chevron,     "NonText")
  set(HL.dir,         "Directory")
  -- File rows get an explicit orange to distinguish them from test-case
  -- rows (which stay Normal). `default = true` lets `:hi` overrides win.
  vim.api.nvim_set_hl(0, HL.file, { default = true, fg = "#e0965e", bold = true })
  set(HL.namespace,   "Identifier")
  set(HL.test,        "Normal")
  set(HL.glyph_pass,  "DiagnosticOk")
  set(HL.glyph_fail,  "DiagnosticError")
  set(HL.glyph_skip,  "NonText")
  set(HL.glyph_run,   "DiagnosticWarn")
  set(HL.duration,    "Comment")
  set(HL.empty,       "Comment")
  set(HL.help,        "Comment")
  set(HL.help_key,    "Special")
  set(HL.fm_label,    "Identifier")
  set(HL.fm_value,    "Normal")
  set(HL.fm_path,     "Directory")
  set(HL.fm_null,     "Comment")
end

_apply_default_highlights()
do
  local group = vim.api.nvim_create_augroup("auto-finder.tests.hl", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = _apply_default_highlights,
    desc = "auto-finder.tests: re-apply default highlight links",
  })
end

-- Status → glyph (ADR-0048 §8.1).
local STATUS_GLYPH = {
  passed  = { "✓", HL.glyph_pass },
  failed  = { "✗", HL.glyph_fail },
  skipped = { "○", HL.glyph_skip },
  running = { "●", HL.glyph_run },
}

-- ─── module state ─────────────────────────────────────────────

-- Cached scratch bufnr — survives view-switch like the other views.
M._bufnr = nil

-- Per-buffer row metadata, in render order. Shapes:
--   { kind="header",       lnum }
--   { kind="config-header", lnum }          -- Config section header
--   { kind="config",        lnum, name, runtime, selected }
--   { kind="config-detail", lnum, name }    -- expanded field child
--   { kind="env-header", lnum }             -- Env section header (§8.4)
--   { kind="env-file",   lnum, path, source, exists, selected, synthetic? }
--   { kind="env-var",    lnum, path, key, file_lnum }
--   { kind="env-error",  lnum, path, file_lnum }
--   { kind="position",   lnum, node }       -- node from auto-run's tree
--   { kind="detail",     lnum, node, field, filepath? }
--   { kind="empty",      lnum }
-- The keymap layer reads `kind` (and node.type) to decide what
-- action `<CR>` / `r` / `d` / `o` take — the todos typed-row
-- dispatch pattern. (env-* rows are emitted by
-- views/_env_section.lua — §8.4 r5.)
M._rows = nil

-- Collapse state keyed by position id. Dir entries persist via
-- auto-core.state (key `tests_collapsed`); file/namespace entries
-- are session-local (test ids are content-addressed and would
-- bloat the persisted json for no setup-once value).
M._collapsed = {}

-- Per-test details expansion (the `o` toggle). Sticky across
-- re-renders so an event-driven refresh doesn't collapse what the
-- user just expanded.
M._expanded = {}

-- Live scan state for the header: nil (idle) or
-- { running = boolean, report = AutoRunScanReport? }.
M._scan = nil

-- position id → last run info from this panel's `r`/`R` launches:
-- { run_id, adapter }. Feeds the details expansion's output path.
M._runs = {}

-- The last position id run from this panel (the `R` re-run target).
M._last_position = nil

-- Event-subscription handles (dispose on close — todos pattern).
M._subs = nil

-- ─── auto-run soft dependency ─────────────────────────────────

---The auto-run facade, or nil when the plugin isn't installed.
---Re-checked per call (never cached) so the absent-probe and a
---late `:Lazy load auto-run.nvim` both behave.
---@return table?
local function _auto_run()
  local ok, ar = pcall(require, "auto-run.discovery")
  if not ok or type(ar) ~= "table" then return nil end
  local okf, facade = pcall(require, "auto-run")
  if not okf or type(facade) ~= "table" then return nil end
  return facade
end

-- Shared Env-section renderer/actions (§8.4 r5) — module-private to
-- the views; the debug view consumes the same helper.
local env_section = require("auto-finder.views._env_section")

-- Shared Config-section renderer/actions (launch-config selection) —
-- the tests view passes kind="test"; the debug view kind="debug".
local config_section = require("auto-finder.views._config_section")

-- Pseudo position-id keying the Env section's collapse state inside
-- M._collapsed / the persisted `tests_collapsed` table. Real position
-- ids are absolute paths (optionally `::`-suffixed), so a `::`-prefixed
-- key can never collide with one.
local ENV_SECTION_ID = "::env-section"
-- Same mechanism for the Config section's collapse state.
local CONFIG_SECTION_ID = "::config-section"

-- ─── persisted collapse state (dirs only) ─────────────────────

---Lazy state-namespace handle (`auto-run.ui` per ADR-0048 §8.1).
---Soft-fail when auto-core.state isn't available — collapse state
---then behaves as in-memory only.
local _ui_state = nil
local function _get_ui_state()
  if _ui_state ~= nil then return _ui_state or nil end
  local ok, mod = pcall(require, "auto-core.state")
  if not ok or type(mod) ~= "table" or type(mod.namespace) ~= "function" then
    _ui_state = false
    return nil
  end
  _ui_state = mod.namespace("auto-run.ui", { persist = "json" })
  return _ui_state
end

---Hydrate M._collapsed from persisted dir-collapse preferences.
---Idempotent; in-memory values win against disk.
local function _hydrate_collapsed()
  local s = _get_ui_state()
  local stored = s and s:get("tests_collapsed") or {}
  if type(stored) ~= "table" then stored = {} end
  for id, v in pairs(stored) do
    if type(id) == "string" and M._collapsed[id] == nil then
      M._collapsed[id] = v == true
    end
  end
end

---Toggle collapse for a container node; persist for dirs only.
---@param node table  auto-run tree node
local function _toggle_collapsed(node)
  if not (node and node.id) then return end
  M._collapsed[node.id] = not M._collapsed[node.id]
  if node.type == "dir" then
    local s = _get_ui_state()
    if s then
      local stored = s:get("tests_collapsed") or {}
      if type(stored) ~= "table" then stored = {} end
      -- Store only true (collapsed) — the default is expanded, so
      -- dropping the key keeps the persisted table minimal.
      stored[node.id] = M._collapsed[node.id] and true or nil
      s:set("tests_collapsed", stored)
    end
  end
end

-- ─── row lookup ───────────────────────────────────────────────

---The row metadata entry under the cursor in the panel window.
---@param panel_winid integer?
---@return table?
local function _row_under_cursor(panel_winid)
  if not (M._rows and panel_winid and vim.api.nvim_win_is_valid(panel_winid)) then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(panel_winid)[1]
  for _, row in ipairs(M._rows) do
    if row.lnum == lnum then return row end
  end
  return nil
end

-- ─── run-info helpers ─────────────────────────────────────────

---The recorded run covering a position id: an exact match, or the
---nearest recorded ancestor (dir/file/namespace runs cover their
---descendants — ids nest by prefix: `path`, then `path::ns::name`).
---@param id string
---@return { run_id: string, adapter: string }?
local function _run_for(id)
  if type(id) ~= "string" then return nil end
  local best, best_len
  for pos, info in pairs(M._runs) do
    if id == pos or id:sub(1, #pos + 2) == pos .. "::"
        or id:sub(1, #pos + 1) == pos .. "/" then
      if best_len == nil or #pos > best_len then
        best, best_len = info, #pos
      end
    end
  end
  return best
end

---Absolute stdout path for a recorded run, or nil.
---@param info { run_id: string }?
---@return string?
local function _run_output_path(info)
  if not (info and info.run_id) then return nil end
  local ar = _auto_run()
  if not ar then return nil end
  local ok, dir = pcall(function() return ar.exec.job.run_dir(info.run_id) end)
  if not ok or type(dir) ~= "string" then return nil end
  return dir .. "/stdout"
end

-- ─── render ───────────────────────────────────────────────────

local function _fmt_duration(ms)
  if type(ms) ~= "number" then return nil end
  if ms >= 1000 then return string.format("%.2fs", ms / 1000) end
  return string.format("%dms", math.floor(ms + 0.5))
end

---Render the full body into `bufnr`. Idempotent. Populates M._rows.
---Buffer-scoped mutations only — never window focus (no-hijack).
---@param bufnr integer
local function _render(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return end

  -- Cursor preservation across re-renders (todos v0.2.37 pattern).
  local cursor_saves = {}
  for _, w in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(w) then
      cursor_saves[w] = vim.api.nvim_win_get_cursor(w)
    end
  end

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

  local rows, lines, marks = {}, {}, {}
  local function mark(lnum0, c0, c1, hl)
    marks[#marks + 1] = { lnum0, c0, c1, hl }
  end

  local ar = _auto_run()
  if not ar then
    -- Soft-dep absent: one-line hint, no data access (the
    -- dbase-without-dbee precedent).
    local hint = "(auto-run.nvim not installed — tests view unavailable)"
    lines[1] = hint
    mark(0, 0, #hint, HL.empty)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    for _, mk in ipairs(marks) do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, mk[1], mk[2],
        { end_col = mk[3], hl_group = mk[4], priority = 110 })
    end
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].modified = false
    M._rows = rows
    return
  end

  local okt, tree = pcall(ar.discovery.tree)
  local results = {}
  do
    local okr, res = pcall(ar.discovery.results)
    if okr and type(res) == "table" then results = res end
  end

  -- ── header: root + counts + scan state ────────────────────────
  do
    local root = okt and tree.root.path or "?"
    local tail = root:match("([^/]+)$") or root
    local counts = { files = 0, positions = 0 }
    if okt then
      local okc, c = pcall(function() return tree:counts() end)
      if okc and type(c) == "table" then counts = c end
    end
    local label = string.format("Tests — %s", tail)
    local info = string.format("  (%d files · %d positions)",
      counts.files, counts.positions)
    lines[#lines + 1] = label .. info
    mark(#lines - 1, 0, #label, HL.header)
    mark(#lines - 1, #label, #label + #info, HL.scan_state)
    rows[#rows + 1] = { kind = "header", lnum = #lines }

    if M._scan and M._scan.running then
      local l = "  scanning… (press S again to cancel)"
      lines[#lines + 1] = l
      mark(#lines - 1, 0, #l, HL.scan_state)
    elseif M._scan and M._scan.report and M._scan.report.status == "capped" then
      -- Structured cap report (no-silent-caps rule): which cap,
      -- the limit, and the actionable hint.
      local r = M._scan.report
      local l1 = string.format("  scan capped: %s %d ≥ %d — %s",
        tostring(r.cap), tonumber(r.seen) or 0, tonumber(r.limit) or 0,
        tostring(r.hint or "scope narrowed?"))
      local l2 = string.format("  (raise discovery.max_%s in auto-run's config, or scan a subtree)",
        tostring(r.cap))
      lines[#lines + 1] = l1
      mark(#lines - 1, 0, #l1, HL.scan_capped)
      lines[#lines + 1] = l2
      mark(#lines - 1, 0, #l2, HL.scan_state)
    elseif M._scan and M._scan.report and M._scan.report.status == "complete" then
      local r = M._scan.report
      local l = string.format("  last scan: %d parsed · %d cached · %d removed",
        r.parsed or 0, r.cached or 0, r.removed or 0)
      lines[#lines + 1] = l
      mark(#lines - 1, 0, #l, HL.scan_state)
    end
    lines[#lines + 1] = ""
  end

  -- ── Config section (launch-config selection) — above Env ─────
  do
    local cfg_list, cfg_reason = config_section.collect("test")
    local collapsed = M._collapsed[CONFIG_SECTION_ID] == true
    local chevron = collapsed and "▶ " or "▼ "
    local label = string.format("Config (%d)", cfg_list and #cfg_list or 0)
    lines[#lines + 1] = chevron .. label
    local lnum0 = #lines - 1
    mark(lnum0, 0, #chevron, HL.chevron)
    mark(lnum0, #chevron, #chevron + #label, HL.config_header)
    rows[#rows + 1] = { kind = "config-header", lnum = lnum0 + 1 }
    if not collapsed then
      config_section.emit({
        list     = cfg_list,
        reason   = cfg_reason,
        kind     = "test",
        lines    = lines,
        mark     = mark,
        rows     = rows,
        expanded = M._expanded,
      })
    end
    lines[#lines + 1] = ""
  end

  -- ── Env section (§8.4, r5) — above the position tree ──────────
  do
    local env_list = env_section.collect()
    local collapsed = M._collapsed[ENV_SECTION_ID] == true
    local chevron = collapsed and "▶ " or "▼ "
    local label = string.format("Env (%d)", env_list and #env_list or 0)
    lines[#lines + 1] = chevron .. label
    local lnum0 = #lines - 1
    mark(lnum0, 0, #chevron, HL.chevron)
    mark(lnum0, #chevron, #chevron + #label, HL.env_header)
    rows[#rows + 1] = { kind = "env-header", lnum = lnum0 + 1 }
    if not collapsed then
      env_section.emit({
        list     = env_list,
        lines    = lines,
        mark     = mark,
        rows     = rows,
        expanded = M._expanded,
      })
    end
    lines[#lines + 1] = ""
  end

  -- ── detail (o-expansion) emission — todos emit_frontmatter style ──
  local FM_INDENT  = string.rep(" ", 8)
  local FM_LABEL_W = 12

  local function emit_detail(node, label, raw_value, opts)
    opts = opts or {}
    local is_null = raw_value == nil or raw_value == ""
    local v_text = is_null and "(none)" or tostring(raw_value)
    local line = FM_INDENT
      .. string.format("%-" .. FM_LABEL_W .. "s", label .. ":") .. v_text
    lines[#lines + 1] = line
    local lnum0 = #lines - 1
    mark(lnum0, #FM_INDENT, #FM_INDENT + #label + 1, HL.fm_label)
    local v_col = #FM_INDENT + FM_LABEL_W
    mark(lnum0, v_col, v_col + #v_text,
      is_null and HL.fm_null or (opts.filepath and HL.fm_path or HL.fm_value))
    rows[#rows + 1] = {
      kind     = "detail",
      lnum     = lnum0 + 1,
      node     = node,
      field    = label,
      filepath = opts.filepath,
    }
  end

  local function emit_details(node)
    local r = results[node.id]
    emit_detail(node, "status", r and r.status or nil)
    emit_detail(node, "duration", r and _fmt_duration(r.duration_ms) or nil)
    local info = _run_for(node.id)
    local out_path = _run_output_path(info)
    emit_detail(node, "output", out_path, { filepath = out_path })
  end

  -- ── tree walk ─────────────────────────────────────────────────
  local total_rows = 0

  local function emit_node(node, depth)
    total_rows = total_rows + 1
    local indent = string.rep("  ", depth)
    local has_children = type(node.children) == "table" and #node.children > 0
    local collapsible = node.type ~= "test" or has_children
    local collapsed = M._collapsed[node.id] == true

    local chevron = ""
    if collapsible and has_children then
      chevron = (collapsed and "▶ " or "▼ ")
    elseif node.type ~= "test" then
      -- Childless container (rare) — keep the column aligned.
      chevron = "  "
    end

    local r = results[node.id]
    local glyph, glyph_hl = " ", nil
    if r and STATUS_GLYPH[r.status] then
      glyph, glyph_hl = STATUS_GLYPH[r.status][1], STATUS_GLYPH[r.status][2]
    end

    local name = tostring(node.name or "?")
    if node.type == "dir" then name = name .. "/" end
    local dur = (node.type == "test" and r) and _fmt_duration(r.duration_ms) or nil
    local suffix = dur and ("  (" .. dur .. ")") or ""

    local line = indent .. chevron .. glyph .. " " .. name .. suffix
    lines[#lines + 1] = line
    local lnum0 = #lines - 1

    local c = #indent
    if #chevron > 0 then
      mark(lnum0, c, c + #chevron, HL.chevron)
      c = c + #chevron
    end
    if glyph_hl then mark(lnum0, c, c + #glyph, glyph_hl) end
    c = c + #glyph + 1
    local name_hl = node.type == "dir" and HL.dir
      or node.type == "file" and HL.file
      or node.type == "namespace" and HL.namespace
      or HL.test
    mark(lnum0, c, c + #name, name_hl)
    if #suffix > 0 then
      mark(lnum0, c + #name, c + #name + #suffix, HL.duration)
    end

    rows[#rows + 1] = { kind = "position", lnum = lnum0 + 1, node = node }

    if node.type == "test" and M._expanded[node.id] then
      emit_details(node)
    end
    if has_children and not collapsed then
      for _, child in ipairs(node.children) do
        emit_node(child, depth + 1)
      end
    end
  end

  if okt then
    for _, child in ipairs(tree.root.children or {}) do
      emit_node(child, 0)
    end
  end

  if total_rows == 0 then
    local l = "(no tests discovered)"
    lines[#lines + 1] = l
    mark(#lines - 1, 0, #l, HL.empty)
    rows[#rows + 1] = { kind = "empty", lnum = #lines }
    lines[#lines + 1] = ""
    local help = "Press `S` to scan the worktree; open test files index automatically."
    lines[#lines + 1] = help
    mark(#lines - 1, 0, #help, HL.help)
    local s0 = help:find("`S`", 1, true)
    if s0 then mark(#lines - 1, s0 - 1, s0 + 2, HL.help_key) end
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  for _, mk in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, mk[1], mk[2], {
      end_col = mk[3], hl_group = mk[4], priority = 110,
    })
  end
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified   = false
  M._rows = rows

  -- Restore cursors (clamped) — window-local cursor on our own
  -- buffer's windows only, which the no-hijack invariant permits.
  local total = vim.api.nvim_buf_line_count(bufnr)
  for w, pos in pairs(cursor_saves) do
    if vim.api.nvim_win_is_valid(w)
        and vim.api.nvim_win_get_buf(w) == bufnr then
      local lnum = math.max(1, math.min(pos[1], total))
      pcall(vim.api.nvim_win_set_cursor, w, { lnum, pos[2] or 0 })
    end
  end
end

local function _rerender()
  if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
    _render(M._bufnr)
  end
end

-- ─── actions ──────────────────────────────────────────────────

local log = function() return require("auto-finder.log") end

---Editor-routed open helper (the todos/debug `_open_file` pattern).
---@param path string?
---@param lnum integer?
local function _open_file(path, lnum)
  if not path or path == "" then return end
  local af = require("auto-finder")
  local target = af._editor_target_winid()
  if not target then
    pcall(vim.cmd, "rightbelow vsplit " .. vim.fn.fnameescape(path))
    target = vim.api.nvim_get_current_win()
  else
    pcall(vim.api.nvim_set_current_win, target)
    pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
  end
  if lnum and lnum > 0 and target and vim.api.nvim_win_is_valid(target) then
    pcall(vim.api.nvim_win_set_cursor, target, { lnum, 0 })
  end
end

---`<CR>`: context-aware open in the editor-target window.
---Containers toggle collapse; positions jump to path:lnum; detail
---rows with a filepath open that file; env files open (env vars at
---their entry's line); the Env header toggles collapse.
---@param row table?
local function _open(row)
  if not row then return end

  if row.kind == "config-header" then
    _toggle_collapsed({ id = CONFIG_SECTION_ID, type = "dir" })
    _rerender()
    return
  end
  if config_section.open(row, _open_file) then return end
  if row.kind == "env-header" then
    -- Persisted via the same dir mechanism as folder collapse.
    _toggle_collapsed({ id = ENV_SECTION_ID, type = "dir" })
    _rerender()
    return
  end
  if env_section.open(row, _open_file) then return end

  local path, lnum
  if row.kind == "detail" then
    if not row.filepath then return end
    path = row.filepath
  elseif row.kind == "position" then
    local node = row.node
    local has_children = type(node.children) == "table" and #node.children > 0
    if node.type ~= "test" and has_children then
      _toggle_collapsed(node)
      _rerender()
      return
    end
    path, lnum = node.path, node.lnum
  else
    return
  end
  _open_file(path, lnum)
end

---Run a position (shared by `r` and `R`). Records the launched runs
---for the details expansion / `x` stop.
---@param id string
local function _run(id)
  local ar = _auto_run()
  if not ar then
    log().warn("view.tests", "auto-run.nvim is not installed")
    return
  end
  local launched, err = ar.discovery.run_position(id)
  if not launched then
    log().error("view.tests", "run failed: " .. tostring(err))
    return
  end
  M._last_position = id
  for _, run in ipairs(launched.runs or {}) do
    M._runs[run.position] = { run_id = run.id, adapter = run.adapter }
  end
  -- The running-glyph render arrives via run.results:changed.
end

---`r`: run the position under the cursor (test / namespace / file /
---folder = suite).
---@param row table?
local function _run_under_cursor(row)
  if not (row and row.kind == "position") then return end
  _run(row.node.id)
end

---`R`: re-run the last position run from this panel.
local function _rerun_last()
  if not M._last_position then
    log().info("view.tests", "nothing to re-run yet — run a position with `r` first")
    return
  end
  _run(M._last_position)
end

---`d`: debug the test under the cursor (dap strategy).
---Routes through the editor-target window first so that auto-run's
---`debug_position` (which does `vim.cmd.edit` + `nvim_win_set_cursor(0, …)`)
---operates in the editor pane, not the panel. dap-go then picks up the
---test function under the cursor in the correct buffer.
---
---When no DAP breakpoint exists within the test function's line range
---(node.lnum..node.end_lnum), one is auto-injected at the first line
---of the function body (lnum + 1) so the debugger always stops inside
---the function without requiring the user to manually set a breakpoint.
---@param row table?
local function _debug(row)
  if not (row and row.kind == "position") then return end
  if row.node.type ~= "test" then
    log().info("view.tests", "debug needs a test row (got " .. tostring(row.node.type) .. ")")
    return
  end
  local ar = _auto_run()
  if not ar then
    log().warn("view.tests", "auto-run.nvim is not installed")
    return
  end
  -- Switch to the editor-target window so debug_position's edit/cursor
  -- land in the editor pane (not the panel scratch buffer).
  local af = require("auto-finder")
  local target = af._editor_target_winid()
  if target and vim.api.nvim_win_is_valid(target) then
    vim.api.nvim_set_current_win(target)
  else
    -- No suitable editor window — open a split, same as _open_file.
    pcall(vim.cmd, "rightbelow vsplit")
  end

  -- ── auto-inject breakpoint if none in the function range ──────
  -- The injected breakpoint is ephemeral: a one-shot DAP listener
  -- removes it when the debug session terminates / exits.
  local node = row.node
  local ok_bp, dap_bps = pcall(require, "dap.breakpoints")
  local ok_dap, dap = pcall(require, "dap")
  local injected_bufnr, injected_line  -- track for teardown
  if ok_bp and ok_dap and node.path and node.lnum then
    -- Open the file so we have a loaded buffer to inspect.
    pcall(vim.cmd, "edit " .. vim.fn.fnameescape(node.path))
    local bufnr = vim.fn.bufnr(node.path)
    if bufnr and bufnr > 0 then
      local fn_start = node.lnum
      local fn_end   = node.end_lnum or fn_start
      local bps = dap_bps.get(bufnr) or {}
      local has_bp = false
      for _, bp in ipairs(bps) do
        local line = bp.line
        if line and line >= fn_start and line <= fn_end then
          has_bp = true
          break
        end
      end
      if not has_bp then
        -- Inject at the first line of the function body (lnum + 1).
        local bp_line = fn_start + 1
        local total = vim.api.nvim_buf_line_count(bufnr)
        if bp_line <= total then
          pcall(vim.api.nvim_win_set_cursor, 0, { bp_line, 0 })
          pcall(dap.set_breakpoint)
          injected_bufnr = bufnr
          injected_line  = bp_line
          log().info("view.tests",
            "auto-set breakpoint at " .. node.path .. ":" .. bp_line
            .. " (will remove on session end)")
        end
      end
    end
  end

  -- ── register one-shot cleanup for the injected breakpoint ─────
  if injected_bufnr and injected_line and ok_dap then
    local LISTENER_KEY = "auto-finder-tests-ephemeral-bp"
    local function cleanup()
      -- Remove only the specific injected breakpoint, not user ones.
      -- dap.breakpoints.remove(bufnr, lnum) is cursor-independent.
      if vim.api.nvim_buf_is_valid(injected_bufnr) then
        pcall(dap_bps.remove, injected_bufnr, injected_line)
        log().info("view.tests",
          "removed ephemeral breakpoint at line " .. injected_line)
      end
      -- De-register ourselves (one-shot).
      dap.listeners.after.event_terminated[LISTENER_KEY] = nil
      dap.listeners.after.event_exited[LISTENER_KEY]     = nil
    end
    dap.listeners.after.event_terminated[LISTENER_KEY] = cleanup
    dap.listeners.after.event_exited[LISTENER_KEY]     = cleanup
  end

  local ok, err = ar.discovery.debug_position(row.node.id)
  if not ok then
    log().error("view.tests", "debug failed: " .. tostring(err))
  end
end

---`o`: details expansion on a test row; collapse toggle on a
---container row (universal "open/close the thing under the cursor");
---inline KEY=VALUE expansion on an env file (§8.4 r5).
---@param row table?
local function _toggle_expand(row)
  if not row then return end
  if row.kind == "config-header" then
    _toggle_collapsed({ id = CONFIG_SECTION_ID, type = "dir" })
    _rerender()
    return
  end
  if config_section.toggle_expand(row, M._expanded) then
    _rerender()
    return
  end
  if row.kind == "env-header" then
    _toggle_collapsed({ id = ENV_SECTION_ID, type = "dir" })
    _rerender()
    return
  end
  if env_section.toggle_expand(row, M._expanded) then
    _rerender()
    return
  end
  local node = row.kind == "position" and row.node
    or row.kind == "detail" and row.node
    or nil
  if not node then return end
  if node.type ~= "test"
      and type(node.children) == "table" and #node.children > 0 then
    _toggle_collapsed(node)
    _rerender()
    return
  end
  if node.type ~= "test" then return end
  if M._expanded[node.id] then
    M._expanded[node.id] = nil
  else
    M._expanded[node.id] = true
  end
  _rerender()
end

---`i`: output float for the position under the cursor — the run's
---human/terminal output (what `go test` printed), fetched from
---auto-run's `discovery.run_output`. Distinct from `o`, which expands
---the result METADATA (status / duration / output path) inline.
---@param row table?
local function _preview(row)
  if not (row and (row.kind == "position" or row.kind == "detail")) then return end
  local node = row.node
  local ar = _auto_run()
  local info = _run_for(node.id)

  local lines
  if not ar then
    lines = { "auto-run.nvim is not installed" }
  elseif not (info and info.run_id) then
    lines = {
      "No run recorded for this position yet.",
      "Press `r` to run it, then `i` to view its output.",
    }
  elseif type(ar.discovery.run_output) ~= "function" then
    lines = { "auto-run is too old for the output view — update to v0.1.6+." }
  else
    local text, err = ar.discovery.run_output(info.run_id, info.adapter)
    if type(text) == "string" and text ~= "" then
      -- Split on newlines; the terminating newline yields a trailing
      -- "" which we drop so the float has no blank tail.
      lines = vim.split(text, "\n", { plain = true })
      if lines[#lines] == "" then lines[#lines] = nil end
    else
      lines = { "(no output — " .. tostring(err or "the run produced none") .. ")" }
    end
  end
  if #lines == 0 then lines = { "(no output)" } end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].swapfile  = false
  vim.bo[buf].filetype  = "auto-finder-tests-output"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local max_w = 0
  for _, l in ipairs(lines) do if #l > max_w then max_w = #l end end
  local width  = math.min(max_w + 2, math.max(80, vim.o.columns - 8))
  local height = math.min(#lines, math.max(10, vim.o.lines - 6))
  local name = node.name or vim.fn.fnamemodify(tostring(node.id):gsub("::.*", ""), ":t")
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor", row = 1, col = 0,
    width = width, height = height,
    style = "minimal", border = "rounded",
    title = " test output: " .. tostring(name) .. "  (q/<Esc> to close) ",
    title_pos = "left",
  })
  vim.wo[win].wrap = false
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, key in ipairs({ "q", "<Esc>" }) do
    pcall(vim.keymap.set, "n", key, close, {
      buffer = buf, silent = true, nowait = true,
      desc = "auto-finder.tests: dismiss preview",
    })
  end
end

---`S`: bounded full scan; a second `S` while one is in flight
---cancels it (ADR-0048 §7 cancelable-scan contract).
local function _scan()
  local ar = _auto_run()
  if not ar then
    log().warn("view.tests", "auto-run.nvim is not installed")
    return
  end
  if M._scan and M._scan.running then
    pcall(ar.discovery.cancel, "tests panel: user cancel")
    M._scan = { running = false, report = M._scan.report }
    _rerender()
    return
  end
  M._scan = { running = true }
  _rerender()
  ar.discovery.scan(nil, function(report)
    M._scan = { running = false, report = report }
    -- run.discovery:changed drives the tree refresh; this schedule
    -- covers the header (canceled/capped states publish no event).
    vim.schedule(function()
      if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr)
          and #vim.fn.win_findbuf(M._bufnr) > 0 then
        pcall(_render, M._bufnr)
      end
    end)
  end)
end

---`x`: stop running test jobs launched through discovery (config
---prefix `test:` — the exec engine only ever stops jobs auto-run
---itself started).
local function _stop()
  local ar = _auto_run()
  if not ar then return end
  local stopped = 0
  local ok, active = pcall(function()
    return ar.exec.list({ active_only = true })
  end)
  if ok and type(active) == "table" then
    for _, rec in ipairs(active) do
      if type(rec.config) == "string" and rec.config:sub(1, 5) == "test:" then
        local oks = pcall(function() return ar.exec.stop(rec.id) end)
        if oks then stopped = stopped + 1 end
      end
    end
  end
  if stopped > 0 then
    log().info("view.tests", "stopped " .. stopped .. " test job(s)")
  else
    log().info("view.tests", "no running test jobs")
  end
end

-- ─── keymaps ──────────────────────────────────────────────────

---Apply buffer-local keymaps — all `nowait`, all with desc strings
---(the `?` help overlay renders from them).
---@param bufnr integer
---@param panel_winid integer?
local function _apply_keymaps(bufnr, panel_winid)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local set = function(lhs, fn, desc)
    pcall(vim.keymap.set, "n", lhs, fn, {
      buffer = bufnr, silent = true, nowait = true, desc = desc,
    })
  end
  set("<CR>", function() _open(_row_under_cursor(panel_winid)) end,
    "auto-finder.tests: jump to position (editor-routed); toggle collapse on a folder; open output on a detail path row")
  set("r", function() _run_under_cursor(_row_under_cursor(panel_winid)) end,
    "auto-finder.tests: run position under cursor (test / file / namespace / folder = suite)")
  set("R", function() _rerun_last() end,
    "auto-finder.tests: re-run the last position run from this panel")
  set("d", function() _debug(_row_under_cursor(panel_winid)) end,
    "auto-finder.tests: debug the test under cursor (dap strategy)")
  set("o", function() _toggle_expand(_row_under_cursor(panel_winid)) end,
    "auto-finder.tests: toggle — details on a test row (status / duration / output path), collapse on a container")
  set("i", function() _preview(_row_under_cursor(panel_winid)) end,
    "auto-finder.tests: output float — the run's full terminal output (go test logs)")
  set("S", function() _scan() end,
    "auto-finder.tests: full worktree scan (bounded; press again to cancel)")
  set("x", function() _stop() end,
    "auto-finder.tests: stop running test jobs")
  set("s", function()
      local row = _row_under_cursor(panel_winid)
      if config_section.select(row) then return end
      env_section.select(row)
    end,
    "auto-finder.tests: select/deselect the config or env file under cursor (applied to every launch)")
  set("e", function() env_section.edit_var(_row_under_cursor(panel_winid)) end,
    "auto-finder.tests: edit the env var's value under cursor (vim.ui.input, prefilled)")
  set("a", function()
    local row = _row_under_cursor(panel_winid)
    if row and (row.kind == "env-file" or row.kind == "env-header") then
      env_section.add(row.kind == "env-file" and row or nil)
    end
  end,
    "auto-finder.tests: add KEY=VALUE to the env file under cursor (Env header targets the selected file)")

  local ok_help, neotree_shared = pcall(require, "auto-finder.shared.neotree")
  if ok_help and type(neotree_shared.install_help_keymap) == "function" then
    neotree_shared.install_help_keymap("tests", bufnr)
  end
end

-- ─── auto-refresh subscriptions ───────────────────────────────

---Re-render iff the panel buffer is currently visible somewhere.
---
---**No-hijack invariant (ADR-0009):** this handler MUST NOT change
---window focus, swap any window's buffer, open windows, or move
---the cursor outside our own panel buffer. `_render` mutates only
---`M._bufnr` via buffer-scoped APIs.
local function _on_event()
  if not (M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr)) then return end
  if #vim.fn.win_findbuf(M._bufnr) == 0 then return end
  vim.schedule(function()
    if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
      pcall(_render, M._bufnr)
    end
  end)
end

---Subscribe to the auto-run event surface. Idempotent (todos
---direct pattern with dispose-on-close).
local function _ensure_subscriptions()
  if M._subs then return end
  local ok_ev, ev = pcall(require, "auto-core.events")
  if not (ok_ev and ev and type(ev.subscribe) == "function") then return end
  M._subs = {
    ev.subscribe("run.discovery:changed", _on_event),
    ev.subscribe("run.results:changed",   _on_event),
    ev.subscribe("run.env:changed",       _on_event),
    ev.subscribe("run.config:changed",    _on_event),
  }
end

local function _dispose_subscriptions()
  if not M._subs then return end
  local ok_ev, ev = pcall(require, "auto-core.events")
  if ok_ev and ev and type(ev.unsubscribe) == "function" then
    for _, h in ipairs(M._subs) do pcall(ev.unsubscribe, h) end
  end
  M._subs = nil
end

-- ─── public — view lifecycle contract ─────────────────────────

function M.get_buffer(panel_winid)
  _hydrate_collapsed()
  if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
    _apply_keymaps(M._bufnr, panel_winid)
    _ensure_subscriptions()
    return M._bufnr
  end
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = "hide"
  vim.bo[b].buftype   = "nofile"
  vim.bo[b].swapfile  = false
  vim.bo[b].filetype  = FILETYPE
  vim.b[b].auto_finder_view = "tests"
  pcall(vim.api.nvim_buf_set_name, b, "auto-finder://tests")
  -- User-initiated mount: index open test buffers so the first
  -- paint isn't empty in a session that already has tests open.
  local ar = _auto_run()
  if ar then pcall(ar.discovery.refresh_open_buffers) end
  _render(b)
  _apply_keymaps(b, panel_winid)
  M._bufnr = b
  _ensure_subscriptions()
  return b
end

function M.on_focus(panel_winid, bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local ar = _auto_run()
  if ar then pcall(ar.discovery.refresh_open_buffers) end
  _render(bufnr)
  _apply_keymaps(bufnr, panel_winid)
  _ensure_subscriptions()
end

function M.on_close()
  _dispose_subscriptions()
  if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
    pcall(vim.api.nvim_buf_delete, M._bufnr, { force = true })
  end
  M._bufnr = nil
  M._rows  = nil
end

-- Test-only — production code never calls this.
function M._reset_for_tests()
  M.on_close()
  M._collapsed = {}
  M._expanded = {}
  M._scan = nil
  M._runs = {}
  M._last_position = nil
  _ui_state = nil
end

-- Module-private hooks exposed for tests (todos convention).
M._HL = HL
M._NS = NS
M._ENV_SECTION_ID = ENV_SECTION_ID
M._row_under_cursor = _row_under_cursor
M._render_for_tests = _render

return M
