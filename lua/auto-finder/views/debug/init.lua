---View — auto-run debug surface (ADR-0048 §8.2 / §8.3).
---
---Flat scratch-buffer view on the todos BUCKETS pattern. Three
---sections, fixed order:
---
---  Entry Points   auto-run store configs (`kind = debug | run`),
---                 grouped by kind, provenance/tier annotated
---                 (merge layers + origin from `store.list()`).
---  Active Sessions  live nvim-dap sessions (id · config · state),
---                 state kept fresh by `run.session:changed`.
---  Breakpoints    the persisted per-repo store merged with live
---                 nvim-dap state, grouped by file. Live wins;
---                 orphaned persisted entries (file loaded, no
---                 live counterpart) render dimmed with a
---                 `d`-to-clean affordance (ADR-0048 §9).
---
---A pure renderer over auto-run's public API — store access goes
---through `auto-run.store` / `auto-run.dap.breakpoints`, never
---direct file reads ([[auto-family-state-ownership]]).
---
---Buffer-local keymaps:
---  <CR>  entry point → launch (kind-appropriate strategy via
---        exec.start); session → focus (dap.set_session + dap-view);
---        breakpoint → jump to file:line (editor-routed);
---        header → toggle collapse; detail path row → open file
---  o     expand details — entry point: resolved config fields with
---        env VALUES MASKED (keys + `${...}`/`cmd:` refs only,
---        never literal values); session: state detail;
---        breakpoint: condition/hit/log detail; header: collapse
---  d     §8.3 marks-parity clearing —
---          breakpoint row    delete IMMEDIATELY (no confirm):
---                            removed from nvim-dap's live registry
---                            AND the persisted store in one action
---          file group header clear that file's breakpoints
---          Breakpoints section header
---                            clear ALL (confirm — bulk destructive)
---  e     edit the entry point's config file (editor-routed)
---  a     scaffold a new config (auto-run store.add flow —
---        gobugger `new_*` parity)
---  x     terminate the session under the cursor
---  p     pause / continue the session under the cursor
---  i     info popup for the row under the cursor
---  R     manual refresh
---  ?     help overlay listing every keymap on this buffer
---
---Soft dependency: auto-run.nvim. When absent the view renders a
---one-line hint and every action no-ops (dbase-without-dbee
---precedent). nvim-dap absence degrades the Sessions/Breakpoints
---sections to empty — the Entry Points section still works.
---
---Event-driven refresh honors the no-hijack invariant (ADR-0009).
---@module 'auto-finder.views.debug'

local M = {
  name        = "debug",
  description = "auto-run debug surface (entry points / sessions / breakpoints)",
}

local FILETYPE = "auto-finder"

local HL = {
  header_entries     = "AutoFinderDebugHeaderEntries",
  header_sessions    = "AutoFinderDebugHeaderSessions",
  header_breakpoints = "AutoFinderDebugHeaderBreakpoints",
  chevron      = "AutoFinderDebugChevron",
  kind_label   = "AutoFinderDebugKindLabel",    -- debug / run sub-group
  entry_name   = "AutoFinderDebugEntryName",
  annotation   = "AutoFinderDebugAnnotation",   -- provenance/tier + markers
  session_id   = "AutoFinderDebugSessionId",
  session_state = "AutoFinderDebugSessionState",
  bp_file      = "AutoFinderDebugBpFile",       -- file group header
  bp_lnum      = "AutoFinderDebugBpLnum",
  bp_marker    = "AutoFinderDebugBpMarker",     -- [cond] / [log] / [hit]
  orphaned     = "AutoFinderDebugOrphaned",     -- dimmed persisted-only rows
  empty        = "AutoFinderDebugEmpty",
  fm_label     = "AutoFinderDebugFmLabel",
  fm_value     = "AutoFinderDebugFmValue",
  fm_path      = "AutoFinderDebugFmPath",
  fm_null      = "AutoFinderDebugFmNull",
  fm_masked    = "AutoFinderDebugFmMasked",     -- (masked) env values
}

local NS = vim.api.nvim_create_namespace("auto-finder.debug.hl")

local function _apply_default_highlights()
  local set = function(name, link)
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
  end
  set(HL.header_entries,     "Title")
  set(HL.header_sessions,    "Statement")
  set(HL.header_breakpoints, "DiagnosticWarn")
  set(HL.chevron,      "NonText")
  set(HL.kind_label,   "Special")
  set(HL.entry_name,   "Constant")
  set(HL.annotation,   "Comment")
  set(HL.session_id,   "Identifier")
  set(HL.session_state, "DiagnosticOk")
  set(HL.bp_file,      "Directory")
  set(HL.bp_lnum,      "LineNr")
  set(HL.bp_marker,    "Special")
  set(HL.orphaned,     "NonText")
  set(HL.empty,        "Comment")
  set(HL.fm_label,     "Identifier")
  set(HL.fm_value,     "Normal")
  set(HL.fm_path,      "Directory")
  set(HL.fm_null,      "Comment")
  set(HL.fm_masked,    "Comment")
end

_apply_default_highlights()
do
  local group = vim.api.nvim_create_augroup("auto-finder.debug.hl", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = _apply_default_highlights,
    desc = "auto-finder.debug: re-apply default highlight links",
  })
end

-- Section buckets (todos BUCKETS/BUCKET_ORDER model).
local BUCKETS = {
  entries     = { header = "Entry Points",    hl_header = HL.header_entries     },
  sessions    = { header = "Active Sessions", hl_header = HL.header_sessions    },
  breakpoints = { header = "Breakpoints",     hl_header = HL.header_breakpoints },
}
local BUCKET_ORDER = { "entries", "sessions", "breakpoints" }

-- ─── module state ─────────────────────────────────────────────

M._bufnr = nil

-- Row metadata shapes (typed-row dispatch):
--   { kind="bucket-header",  lnum, section }
--   { kind="kind-header",    lnum, cfg_kind }
--   { kind="entry",          lnum, name, cfg }
--   { kind="session",        lnum, session, state }
--   { kind="bp-file-header", lnum, path, abs, bps }
--   { kind="breakpoint",     lnum, bp }
--   { kind="detail",         lnum, parent, field, filepath? }
M._rows = nil

-- Per-section collapse, persisted (setup-once preference) via
-- state.namespace("auto-run.ui") key `debug_collapsed`.
M._collapsed = {}

-- Per-row details expansion (`o`), keyed "entry:<name>" /
-- "session:<id>" / "bp:<path>:<lnum>". Session-local.
M._expanded = {}

-- session id → last state seen on run.session:changed.
M._session_states = {}

M._subs = nil

-- ─── soft deps ────────────────────────────────────────────────

---auto-run facade or nil (re-checked per call — never cached).
---@return table?
local function _auto_run()
  local ok = pcall(require, "auto-run.store")
  if not ok then return nil end
  local okf, facade = pcall(require, "auto-run")
  if not okf or type(facade) ~= "table" then return nil end
  return facade
end

local log = function() return require("auto-finder.log") end

---Confirm wrapper — module-level so tests can stub bulk-destructive
---confirmation without monkey-patching vim.fn.
---@param msg string
---@param choices string
---@param default integer
---@return integer
function M._confirm(msg, choices, default)
  return vim.fn.confirm(msg, choices, default)
end

-- ─── persisted collapse state ─────────────────────────────────

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

local function _hydrate_collapsed()
  local s = _get_ui_state()
  local stored = s and s:get("debug_collapsed") or {}
  if type(stored) ~= "table" then stored = {} end
  for _, name in ipairs(BUCKET_ORDER) do
    if stored[name] ~= nil and M._collapsed[name] == nil then
      M._collapsed[name] = stored[name] == true
    end
  end
end

local function _toggle_collapsed(section)
  if type(section) ~= "string" or section == "" then return end
  M._collapsed[section] = not M._collapsed[section]
  local s = _get_ui_state()
  if s then
    local stored = s:get("debug_collapsed") or {}
    if type(stored) ~= "table" then stored = {} end
    stored[section] = M._collapsed[section]
    s:set("debug_collapsed", stored)
  end
end

-- ─── row lookup ───────────────────────────────────────────────

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

-- ─── data collection ──────────────────────────────────────────

---Entry-point configs, grouped by kind (debug first, then run).
---@param ar table
---@return table<string, table[]> by_kind, string[] kind_order
local function _collect_entries(ar)
  local by_kind = { debug = {}, run = {} }
  local ok, list = pcall(ar.store.list)
  if ok and type(list) == "table" then
    for _, c in ipairs(list) do
      if (c.kind == "debug" or c.kind == "run") and by_kind[c.kind] then
        table.insert(by_kind[c.kind], c)
      end
    end
  end
  for _, group in pairs(by_kind) do
    table.sort(group, function(a, b) return (a.name or "") < (b.name or "") end)
  end
  return by_kind, { "debug", "run" }
end

---Live dap sessions with a display state (event-tracked state wins
---over the point-in-time stopped_thread_id inference).
---@return { session: table, id: string, config: string?, state: string }[]
local function _collect_sessions()
  local out = {}
  local okd, dap = pcall(require, "dap")
  if not okd then return out end
  local oks, sessions = pcall(dap.sessions)
  if not oks or type(sessions) ~= "table" then return out end
  for _, s in pairs(sessions) do
    local id = tostring(s.id or "?")
    local state = M._session_states[id]
      or (s.stopped_thread_id and "stopped" or "running")
    out[#out + 1] = {
      session = s,
      id      = id,
      config  = type(s.config) == "table" and s.config.name or nil,
      state   = state,
    }
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

---The worktree root auto-run anchors breakpoint paths at.
---@param ar table
---@return string?
local function _bp_root(ar)
  local ok, dirs = pcall(ar.store.resolve_run_dirs)
  if not ok or type(dirs) ~= "table" then return nil end
  return dirs.root or dirs.anchor
end

local function _to_abs(rel, root)
  if type(rel) ~= "string" then return rel end
  if rel:sub(1, 1) == "/" then return rel end
  if not root then return rel end
  return root:gsub("/+$", "") .. "/" .. rel
end

---Merged breakpoint groups: persisted store (via auto-run's public
---read()) merged with live nvim-dap state. Live wins; a persisted
---entry whose file IS loaded but has no live counterpart is
---`orphaned` (renders dimmed, §9).
---@param ar table
---@return { path: string, abs: string, bps: table[] }[] groups
local function _collect_breakpoints(ar)
  local root = _bp_root(ar)
  local by_path = {}      -- rel path → { [lnum] = bp }
  local order = {}

  local function slot(rel)
    if not by_path[rel] then
      by_path[rel] = {}
      order[#order + 1] = rel
    end
    return by_path[rel]
  end

  -- Live registry first (live wins).
  local loaded_rel = {}
  local okb, dap_bps = pcall(require, "dap.breakpoints")
  if okb then
    local okg, live = pcall(dap_bps.get)
    if okg and type(live) == "table" then
      for bufnr, bps in pairs(live) do
        local bname = vim.api.nvim_buf_get_name(bufnr)
        if bname ~= "" and not bname:match("^%w+://") then
          local abs = vim.fn.fnamemodify(bname, ":p")
          local rel = abs
          if root and abs:sub(1, #root + 1) == (root .. "/") then
            rel = abs:sub(#root + 2)
          end
          for _, bp in ipairs(bps) do
            slot(rel)[bp.line] = {
              path          = rel,
              abs           = abs,
              lnum          = bp.line,
              condition     = bp.condition,
              hit_condition = bp.hitCondition,
              log_message   = bp.logMessage,
              live          = true,
              orphaned      = false,
              bufnr         = bufnr,
            }
          end
        end
      end
    end
  end

  -- Which store paths have a loaded buffer (the orphan predicate)?
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local bname = vim.api.nvim_buf_get_name(bufnr)
      if bname ~= "" and not bname:match("^%w+://") then
        local abs = vim.fn.fnamemodify(bname, ":p")
        local rel = abs
        if root and abs:sub(1, #root + 1) == (root .. "/") then
          rel = abs:sub(#root + 2)
        end
        loaded_rel[rel] = true
      end
    end
  end

  -- Persisted store (public API — never a direct file read here).
  local okr, records = pcall(function() return ar.breakpoints.read() end)
  if okr and type(records) == "table" then
    for _, rec in ipairs(records) do
      if type(rec.path) == "string" and type(rec.lnum) == "number" then
        local group = slot(rec.path)
        if group[rec.lnum] == nil then
          group[rec.lnum] = {
            path          = rec.path,
            abs           = _to_abs(rec.path, root),
            lnum          = rec.lnum,
            condition     = (rec.condition ~= vim.NIL) and rec.condition or nil,
            hit_condition = (rec.hit_condition ~= vim.NIL) and rec.hit_condition or nil,
            log_message   = (rec.log_message ~= vim.NIL) and rec.log_message or nil,
            live          = false,
            -- File loaded but no live bp at this line → the record
            -- is out of sync with live state (orphaned, dimmed).
            orphaned      = loaded_rel[rec.path] == true,
          }
        end
      end
    end
  end

  table.sort(order)
  local groups = {}
  for _, rel in ipairs(order) do
    local bps = {}
    for _, bp in pairs(by_path[rel]) do bps[#bps + 1] = bp end
    table.sort(bps, function(a, b) return a.lnum < b.lnum end)
    groups[#groups + 1] = { path = rel, abs = bps[1] and bps[1].abs
      or _to_abs(rel, root), bps = bps }
  end
  return groups
end

-- ─── env masking (ADR-0048 §8.2 / §11 secret hygiene) ─────────

---Render an env value for display. Pure substitution refs
---(`${VAR}`) and command refs (`cmd:...`) are refs, not secrets —
---shown verbatim. EVERYTHING else (any literal, any mixed literal)
---is masked. Values never reach the buffer, logs, or events.
---@param v any
---@return string text, boolean masked
local function _masked_env_value(v)
  if type(v) == "string" then
    if v:match("^%${[%w_%.%-]+}$") then return v, false end
    if v:match("^cmd:") then return v, false end
  end
  return "(masked)", true
end

-- ─── config file resolution (for `e`) ─────────────────────────

---Best-effort path of the config's backing json file: tracked tier
---first (the reviewable one), then shared. nil for launch.json
---shims (edit those via `:AutoRun import`).
---@param name string
---@return string?
local function _config_file(name)
  local ok, paths = pcall(require, "auto-run.store.paths")
  if not ok then return nil end
  local okd, dirs = pcall(paths.resolve_run_dirs)
  if not okd or type(dirs) ~= "table" then return nil end
  for _, tier_dir in ipairs({ dirs.tracked, dirs.shared }) do
    if type(tier_dir) == "string" then
      local candidate = paths.configs_dir(tier_dir) .. "/" .. name .. ".json"
      if vim.fn.filereadable(candidate) == 1 then return candidate end
    end
  end
  return nil
end

-- ─── render ───────────────────────────────────────────────────

local function _render(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return end

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

  local function flush()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    for _, mk in ipairs(marks) do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, mk[1], mk[2], {
        end_col = mk[3], hl_group = mk[4], priority = 110,
      })
    end
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].modified   = false
    M._rows = rows
    local total = vim.api.nvim_buf_line_count(bufnr)
    for w, pos in pairs(cursor_saves) do
      if vim.api.nvim_win_is_valid(w)
          and vim.api.nvim_win_get_buf(w) == bufnr then
        local lnum = math.max(1, math.min(pos[1], total))
        pcall(vim.api.nvim_win_set_cursor, w, { lnum, pos[2] or 0 })
      end
    end
  end

  local ar = _auto_run()
  if not ar then
    local hint = "(auto-run.nvim not installed — debug view unavailable)"
    lines[1] = hint
    mark(0, 0, #hint, HL.empty)
    flush()
    return
  end

  local by_kind, kind_order = _collect_entries(ar)
  local sessions = _collect_sessions()
  local bp_groups = _collect_breakpoints(ar)

  local function emit_bucket_header(section, count)
    local cfg = BUCKETS[section]
    if #lines > 0 then lines[#lines + 1] = "" end
    local collapsed = M._collapsed[section] == true
    local chevron = collapsed and "▶ " or "▼ "
    local label = cfg.header .. " (" .. count .. ")"
    lines[#lines + 1] = chevron .. label
    local lnum0 = #lines - 1
    mark(lnum0, 0, #chevron, HL.chevron)
    mark(lnum0, #chevron, #chevron + #label, cfg.hl_header)
    rows[#rows + 1] = { kind = "bucket-header", lnum = lnum0 + 1, section = section }
  end

  -- Detail-row emission (todos emit_frontmatter style).
  local FM_INDENT  = string.rep(" ", 8)
  local FM_LABEL_W = 14

  local function emit_detail(parent, label, raw_value, opts)
    opts = opts or {}
    local is_null = raw_value == nil or raw_value == ""
    local v_text = is_null and "(none)" or tostring(raw_value)
    local line = FM_INDENT
      .. string.format("%-" .. FM_LABEL_W .. "s", label .. ":") .. v_text
    lines[#lines + 1] = line
    local lnum0 = #lines - 1
    mark(lnum0, #FM_INDENT, #FM_INDENT + #label + 1, HL.fm_label)
    local v_col = #FM_INDENT + FM_LABEL_W
    local v_hl = is_null and HL.fm_null
      or opts.masked and HL.fm_masked
      or opts.filepath and HL.fm_path
      or HL.fm_value
    mark(lnum0, v_col, v_col + #v_text, v_hl)
    rows[#rows + 1] = {
      kind     = "detail",
      lnum     = lnum0 + 1,
      parent   = parent,
      field    = label,
      filepath = opts.filepath,
    }
  end

  ---Resolved-config expansion for an entry point. Env values are
  ---MASKED — keys + refs only, never literal values (§8.2).
  local function emit_entry_details(row_parent, name)
    local eff, err, meta = nil, nil, nil
    local okg, geff, gerr, gmeta = pcall(ar.store.get, name)
    if okg then eff, err, meta = geff, gerr, gmeta end
    if not eff then
      emit_detail(row_parent, "error", tostring(err))
      return
    end
    emit_detail(row_parent, "kind",    eff.kind)
    emit_detail(row_parent, "runtime", eff.runtime or "go")
    emit_detail(row_parent, "program", eff.program)
    if type(eff.args) == "table" and #eff.args > 0 then
      emit_detail(row_parent, "args", table.concat(eff.args, " "))
    end
    emit_detail(row_parent, "cwd", eff.cwd)
    if type(eff.build_flags) == "string" and eff.build_flags ~= "" then
      emit_detail(row_parent, "build_flags", eff.build_flags)
    end
    if type(eff.env_files) == "table" and #eff.env_files > 0 then
      emit_detail(row_parent, "env_files", table.concat(eff.env_files, ", "))
    end
    if type(eff.env) == "table" and next(eff.env) ~= nil then
      local keys = {}
      for k in pairs(eff.env) do keys[#keys + 1] = k end
      table.sort(keys)
      for _, k in ipairs(keys) do
        local text, masked = _masked_env_value(eff.env[k])
        emit_detail(row_parent, "env." .. k, text, { masked = masked })
      end
    end
    emit_detail(row_parent, "origin", eff.origin)
    if meta and type(meta.layers) == "table" then
      emit_detail(row_parent, "layers", table.concat(meta.layers, " → "))
    end
    local cfg_file = _config_file(name)
    emit_detail(row_parent, "file", cfg_file, { filepath = cfg_file })
  end

  -- ── Entry Points ──────────────────────────────────────────────
  do
    local count = #by_kind.debug + #by_kind.run
    emit_bucket_header("entries", count)
    if not M._collapsed.entries then
      if count == 0 then
        local l = "  (no debug/run configs — `a` scaffolds one)"
        lines[#lines + 1] = l
        mark(#lines - 1, 0, #l, HL.empty)
      end
      for _, cfg_kind in ipairs(kind_order) do
        local group = by_kind[cfg_kind]
        if #group > 0 then
          local kl = "  " .. cfg_kind
          lines[#lines + 1] = kl
          mark(#lines - 1, 2, #kl, HL.kind_label)
          rows[#rows + 1] = { kind = "kind-header", lnum = #lines, cfg_kind = cfg_kind }
          for _, c in ipairs(group) do
            local prov = {}
            if type(c.layers) == "table" and #c.layers > 0 then
              prov[#prov + 1] = table.concat(c.layers, "+")
            end
            if c.origin then prov[#prov + 1] = c.origin end
            if c.error then prov[#prov + 1] = "error" end
            local ann = #prov > 0 and ("  [" .. table.concat(prov, " · ") .. "]") or ""
            local name = tostring(c.name or "?")
            local line = "    " .. name .. ann
            lines[#lines + 1] = line
            local lnum0 = #lines - 1
            mark(lnum0, 4, 4 + #name, HL.entry_name)
            if #ann > 0 then
              mark(lnum0, 4 + #name, 4 + #name + #ann, HL.annotation)
            end
            local row = { kind = "entry", lnum = lnum0 + 1, name = c.name, cfg = c }
            rows[#rows + 1] = row
            if M._expanded["entry:" .. name] then
              emit_entry_details(row, name)
            end
          end
        end
      end
    end
  end

  -- ── Active Sessions ──────────────────────────────────────────
  do
    emit_bucket_header("sessions", #sessions)
    if not M._collapsed.sessions then
      if #sessions == 0 then
        local l = "  (no active dap sessions)"
        lines[#lines + 1] = l
        mark(#lines - 1, 0, #l, HL.empty)
      end
      for _, s in ipairs(sessions) do
        local id_part = "#" .. s.id
        local name_part = "  " .. (s.config or "(no config)")
        local state_part = "  [" .. s.state .. "]"
        local line = "  " .. id_part .. name_part .. state_part
        lines[#lines + 1] = line
        local lnum0 = #lines - 1
        local c = 2
        mark(lnum0, c, c + #id_part, HL.session_id)
        c = c + #id_part + #name_part
        mark(lnum0, c, c + #state_part, HL.session_state)
        local row = { kind = "session", lnum = lnum0 + 1,
          session = s.session, session_id = s.id, state = s.state }
        rows[#rows + 1] = row
        if M._expanded["session:" .. s.id] then
          emit_detail(row, "id",     s.id)
          emit_detail(row, "config", s.config)
          emit_detail(row, "state",  s.state)
          emit_detail(row, "stopped_thread",
            s.session.stopped_thread_id and tostring(s.session.stopped_thread_id) or nil)
        end
      end
    end
  end

  -- ── Breakpoints ──────────────────────────────────────────────
  do
    local bp_count = 0
    for _, g in ipairs(bp_groups) do bp_count = bp_count + #g.bps end
    emit_bucket_header("breakpoints", bp_count)
    if not M._collapsed.breakpoints then
      if bp_count == 0 then
        local l = "  (no breakpoints)"
        lines[#lines + 1] = l
        mark(#lines - 1, 0, #l, HL.empty)
      end
      for _, g in ipairs(bp_groups) do
        local fl = "  " .. g.path
        lines[#lines + 1] = fl
        mark(#lines - 1, 2, #fl, HL.bp_file)
        rows[#rows + 1] = { kind = "bp-file-header", lnum = #lines,
          path = g.path, abs = g.abs, bps = g.bps }
        for _, bp in ipairs(g.bps) do
          local fname = g.path:match("([^/]+)$") or g.path
          local base = fname .. ":" .. bp.lnum
          local markers = {}
          if bp.condition and bp.condition ~= "" then markers[#markers + 1] = "[cond]" end
          if bp.hit_condition and bp.hit_condition ~= "" then markers[#markers + 1] = "[hit]" end
          if bp.log_message and bp.log_message ~= "" then markers[#markers + 1] = "[log]" end
          if bp.orphaned then markers[#markers + 1] = "(orphaned)" end
          local mtext = #markers > 0 and ("  " .. table.concat(markers, " ")) or ""
          local line = "    " .. base .. mtext
          lines[#lines + 1] = line
          local lnum0 = #lines - 1
          if bp.orphaned then
            -- §9: orphaned persisted entries render dimmed whole-row.
            mark(lnum0, 0, #line, HL.orphaned)
          else
            local colon = 4 + #fname
            mark(lnum0, 4, colon, HL.bp_file)
            mark(lnum0, colon, 4 + #base, HL.bp_lnum)
            if #mtext > 0 then
              mark(lnum0, 4 + #base, 4 + #base + #mtext, HL.bp_marker)
            end
          end
          local row = { kind = "breakpoint", lnum = lnum0 + 1, bp = bp }
          rows[#rows + 1] = row
          if M._expanded["bp:" .. bp.path .. ":" .. bp.lnum] then
            emit_detail(row, "file",      bp.abs, { filepath = bp.abs })
            emit_detail(row, "line",      bp.lnum)
            emit_detail(row, "condition", bp.condition)
            emit_detail(row, "hit",       bp.hit_condition)
            emit_detail(row, "log",       bp.log_message)
            emit_detail(row, "state",
              bp.live and "live" or (bp.orphaned and "orphaned (persisted, no live match)"
                or "persisted (file not loaded)"))
          end
        end
      end
    end
  end

  flush()
end

local function _rerender()
  if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
    _render(M._bufnr)
  end
end

-- ─── §8.3 breakpoint clearing (marks parity) ──────────────────

---Delete ONE breakpoint — removed from nvim-dap's live registry
---AND the persisted store in one action, no confirmation
---(views/marks `d` parity, ADR-0048 §8.3).
---
---Sequence matters: the buffer is loaded FIRST (so auto-run's
---BufReadPost restore fires before, not after, the removal), the
---live registry entry is removed, live sessions are notified, and
---the persisted record leaves via auto-run's reconcile (live wins
---for loaded paths — the §9 public sync surface; the store file
---is never touched directly here).
---@param bp table
---@return boolean ok
local function _delete_breakpoint(bp)
  local ar = _auto_run()
  if not ar then return false end
  local okb, dap_bps = pcall(require, "dap.breakpoints")
  if not okb then
    log().warn("view.debug", "nvim-dap is not installed")
    return false
  end

  -- 1. Ensure the file is a loaded buffer: puts the path inside the
  --    reconcile diff scope AND flushes the restore path first.
  local bufnr = vim.fn.bufadd(bp.abs)
  pcall(vim.fn.bufload, bufnr)

  -- 2. Live registry removal.
  pcall(dap_bps.remove, bufnr, bp.lnum)

  -- 3. Notify running sessions (mirror dap.toggle_breakpoint's push).
  local okd, dap = pcall(require, "dap")
  if okd then
    local oks, sessions = pcall(dap.sessions)
    if oks and type(sessions) == "table" then
      for _, s in pairs(sessions) do
        pcall(function()
          local okg, remaining = pcall(dap_bps.get, bufnr)
          s:set_breakpoints(okg and remaining or { [bufnr] = {} })
        end)
      end
    end
  end

  -- 4. Persisted store, via the public reconcile (§9).
  pcall(function() ar.breakpoints.reconcile() end)
  return true
end

---`d` typed-row dispatch (§8.3):
---  breakpoint row     → delete immediately (live + store, no confirm)
---  file group header  → clear that file's breakpoints
---  Breakpoints header → clear ALL, with confirm (bulk destructive)
---@param row table?
local function _delete(row)
  if not row then return end

  if row.kind == "breakpoint" then
    if _delete_breakpoint(row.bp) then _rerender() end
    return
  end

  if row.kind == "bp-file-header" then
    local any = false
    for _, bp in ipairs(row.bps or {}) do
      any = _delete_breakpoint(bp) or any
    end
    if any then _rerender() end
    return
  end

  if row.kind == "bucket-header" and row.section == "breakpoints" then
    local choice = M._confirm(
      "Clear ALL breakpoints (live registry + persisted store)?",
      "&Yes\n&No", 2)
    if choice ~= 1 then return end
    local ar = _auto_run()
    if not ar then return end
    local ok, err = pcall(function() return ar.breakpoints.clear_all() end)
    if not ok then
      log().error("view.debug", "clear-all failed: " .. tostring(err))
    end
    _rerender()
    return
  end
  -- Everything else: no-op (predictable — `d` is breakpoint-scoped).
end

-- ─── actions ──────────────────────────────────────────────────

---Editor-routed open helper (todos `_open` pattern).
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

---`<CR>` typed-row dispatch.
---@param row table?
local function _open(row)
  if not row then return end

  if row.kind == "bucket-header" then
    _toggle_collapsed(row.section)
    _rerender()
    return
  end

  if row.kind == "entry" then
    local ar = _auto_run()
    if not ar then return end
    -- Kind-appropriate strategy: exec.start resolves debug → dap,
    -- run → background job (§6 defaults).
    local launched, err = ar.exec.start(row.name)
    if not launched then
      log().error("view.debug", "launch failed: " .. tostring(err))
    end
    return
  end

  if row.kind == "session" then
    local okd, dap = pcall(require, "dap")
    if okd and row.session then
      pcall(dap.set_session, row.session)
      local okv, dv = pcall(require, "dap-view")
      if okv then pcall(dv.open) end
    end
    return
  end

  if row.kind == "bp-file-header" then
    _open_file(row.abs)
    return
  end

  if row.kind == "breakpoint" then
    _open_file(row.bp.abs, row.bp.lnum)
    return
  end

  if row.kind == "detail" then
    if row.filepath then _open_file(row.filepath) end
    return
  end
end

---`o`: details expansion (entry / session / breakpoint), collapse
---toggle on section headers.
---@param row table?
local function _toggle_expand(row)
  if not row then return end
  if row.kind == "bucket-header" then
    _toggle_collapsed(row.section)
    _rerender()
    return
  end
  local key
  if row.kind == "entry" then
    key = "entry:" .. tostring(row.name)
  elseif row.kind == "session" then
    key = "session:" .. tostring(row.session_id)
  elseif row.kind == "breakpoint" then
    key = "bp:" .. row.bp.path .. ":" .. row.bp.lnum
  else
    return
  end
  if M._expanded[key] then
    M._expanded[key] = nil
  else
    M._expanded[key] = true
  end
  _rerender()
end

---`e`: edit the entry point's config file (editor-routed).
---@param row table?
local function _edit_config(row)
  if not row then return end
  local name = row.kind == "entry" and row.name
    or (row.kind == "detail" and row.parent and row.parent.kind == "entry"
        and row.parent.name)
  if not name then return end
  local path = _config_file(name)
  if not path then
    log().warn("view.debug",
      "'" .. tostring(name) .. "' has no editable store file "
        .. "(launch.json shim? import it with :AutoRun import)")
    return
  end
  _open_file(path)
end

---`a`: scaffold a new config via auto-run's store.add flow
---(gobugger `new_*` parity — mirrors auto-run's `<leader>rc`).
local function _scaffold()
  local ar = _auto_run()
  if not ar then
    log().warn("view.debug", "auto-run.nvim is not installed")
    return
  end
  vim.ui.select({ "run", "test", "debug" },
    { prompt = "auto-run: config kind" }, function(kind)
      if not kind then return end
      vim.ui.input({ prompt = "config name: " }, function(name)
        if not name or name == "" then return end
        local path, err = ar.store.add({
          name    = name,
          kind    = kind,
          runtime = "go",
          program = kind == "test" and "${worktree}"
            or "${worktree}/cmd/" .. name,
        })
        if not path then
          log().error("view.debug", "scaffold failed: " .. tostring(err))
          return
        end
        _open_file(path)
        _rerender()
      end)
    end)
end

---`x`: terminate the session under the cursor.
---@param row table?
local function _terminate(row)
  if not (row and row.kind == "session") then return end
  local okd, dap = pcall(require, "dap")
  if not okd then return end
  pcall(dap.set_session, row.session)
  local ok, err = pcall(dap.terminate)
  if not ok then
    log().error("view.debug", "terminate failed: " .. tostring(err))
  end
end

---`p`: pause / continue the session under the cursor (stopped →
---continue; running → pause).
---@param row table?
local function _pause_continue(row)
  if not (row and row.kind == "session") then return end
  local okd, dap = pcall(require, "dap")
  if not okd then return end
  pcall(dap.set_session, row.session)
  if row.session and row.session.stopped_thread_id then
    pcall(dap.continue)
  else
    pcall(dap.pause)
  end
end

---`i`: info popup for the row under the cursor.
---@param row table?
local function _preview(row)
  if not row then return end
  local lines = {}
  local function add(label, value)
    lines[#lines + 1] = string.format("  %-12s %s", label, tostring(value))
  end

  if row.kind == "entry" then
    add("Entry point", row.name)
    add("Kind",        row.cfg.kind or "?")
    add("Runtime",     row.cfg.runtime or "go")
    if type(row.cfg.layers) == "table" and #row.cfg.layers > 0 then
      add("Layers", table.concat(row.cfg.layers, " → "))
    end
    if row.cfg.origin then add("Origin", row.cfg.origin) end
    if row.cfg.error then add("Error", row.cfg.error) end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  (o expands the resolved config inline; env values stay masked)"
  elseif row.kind == "session" then
    add("Session", "#" .. row.session_id)
    add("Config",  type(row.session.config) == "table"
      and row.session.config.name or "(none)")
    add("State",   row.state)
  elseif row.kind == "breakpoint" then
    add("Breakpoint", row.bp.path .. ":" .. row.bp.lnum)
    add("Condition",  row.bp.condition or "(none)")
    add("Hit",        row.bp.hit_condition or "(none)")
    add("Log",        row.bp.log_message or "(none)")
    add("State", row.bp.live and "live"
      or (row.bp.orphaned and "orphaned (persisted, no live match)"
        or "persisted (file not loaded)"))
  else
    return
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  (q / <Esc> to close)"

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].swapfile  = false
  vim.bo[buf].filetype  = "auto-finder-debug-info"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local max_w = 0
  for _, l in ipairs(lines) do if #l > max_w then max_w = #l end end
  local width  = math.min(max_w + 2, math.max(60, vim.o.columns - 8))
  local height = math.min(#lines, math.max(8, vim.o.lines - 6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor", row = 1, col = 0,
    width = width, height = height,
    style = "minimal", border = "rounded",
    title = " debug info ", title_pos = "left",
  })
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, key in ipairs({ "q", "<Esc>" }) do
    pcall(vim.keymap.set, "n", key, close, {
      buffer = buf, silent = true, nowait = true,
      desc = "auto-finder.debug: dismiss preview",
    })
  end
end

-- ─── keymaps ──────────────────────────────────────────────────

local function _apply_keymaps(bufnr, panel_winid)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local set = function(lhs, fn, desc)
    pcall(vim.keymap.set, "n", lhs, fn, {
      buffer = bufnr, silent = true, nowait = true, desc = desc,
    })
  end
  set("<CR>", function() _open(_row_under_cursor(panel_winid)) end,
    "auto-finder.debug: launch entry point / focus session / jump to breakpoint / toggle section")
  set("o", function() _toggle_expand(_row_under_cursor(panel_winid)) end,
    "auto-finder.debug: expand details (resolved config with env masked / session state / breakpoint condition)")
  set("d", function() _delete(_row_under_cursor(panel_winid)) end,
    "auto-finder.debug: delete breakpoint (immediate, live+store); file header clears file; section header clears ALL (confirm)")
  set("e", function() _edit_config(_row_under_cursor(panel_winid)) end,
    "auto-finder.debug: edit the entry point's config file")
  set("a", function() _scaffold() end,
    "auto-finder.debug: scaffold a new run/test/debug config (store.add flow)")
  set("x", function() _terminate(_row_under_cursor(panel_winid)) end,
    "auto-finder.debug: terminate the session under cursor")
  set("p", function() _pause_continue(_row_under_cursor(panel_winid)) end,
    "auto-finder.debug: pause / continue the session under cursor")
  set("i", function() _preview(_row_under_cursor(panel_winid)) end,
    "auto-finder.debug: info popup (entry / session / breakpoint)")
  set("R", function() _render(bufnr) end,
    "auto-finder.debug: refresh")

  local ok_help, neotree_shared = pcall(require, "auto-finder.shared.neotree")
  if ok_help and type(neotree_shared.install_help_keymap) == "function" then
    neotree_shared.install_help_keymap("debug", bufnr)
  end
end

-- ─── auto-refresh subscriptions ───────────────────────────────

---**No-hijack invariant (ADR-0009):** re-render only when visible,
---via vim.schedule, buffer-scoped mutations only.
local function _on_event()
  if not (M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr)) then return end
  if #vim.fn.win_findbuf(M._bufnr) == 0 then return end
  vim.schedule(function()
    if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
      pcall(_render, M._bufnr)
    end
  end)
end

local function _ensure_subscriptions()
  if M._subs then return end
  local ok_ev, ev = pcall(require, "auto-core.events")
  if not (ok_ev and ev and type(ev.subscribe) == "function") then return end
  M._subs = {
    ev.subscribe("run.session:changed", function(payload)
      if type(payload) == "table" and payload.id then
        if payload.state == "terminated" or payload.state == "exited" then
          M._session_states[tostring(payload.id)] = nil
        else
          M._session_states[tostring(payload.id)] = payload.state
        end
      end
      _on_event()
    end),
    ev.subscribe("run.breakpoints:changed", _on_event),
    ev.subscribe("run.config:changed",      _on_event),
    ev.subscribe("run.job:started",         _on_event),
    ev.subscribe("run.job:exited",          _on_event),
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
  vim.b[b].auto_finder_view = "debug"
  pcall(vim.api.nvim_buf_set_name, b, "auto-finder://debug")
  _render(b)
  _apply_keymaps(b, panel_winid)
  M._bufnr = b
  _ensure_subscriptions()
  return b
end

function M.on_focus(panel_winid, bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
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
  M._session_states = {}
  _ui_state = nil
end

-- Module-private hooks exposed for tests (todos convention).
M._HL = HL
M._NS = NS
M._BUCKETS = BUCKETS
M._BUCKET_ORDER = BUCKET_ORDER
M._row_under_cursor = _row_under_cursor
M._masked_env_value = _masked_env_value
M._delete_breakpoint = _delete_breakpoint

return M
