---Shared Env-section helper for the tests + debug views (ADR-0048
---§8.4, r5). Module-PRIVATE to auto-finder's views — not a public
---surface (leading underscore keeps it out of the view registry's
---`_available_section_types` scan, same as the `_neotree` precedent).
---
---Each host view still owns its section header, collapse
---persistence, event subscriptions, and keymap registration; this
---module owns the parts that would otherwise be duplicated: the
---candidate collection (incl. the synthetic unreferenced-selected
---row), the row/highlight emission, and the typed-row actions the
---views dispatch into (`o` expand, `<CR>` open, `s` select, `e`
---edit, `a` add).
---
---Secret boundary (§4.2 r5): env VALUES from auto-run's
---`env.read_file` are interactive display ONLY — equivalent to
---`:e`-ing the user-owned file. A value exists in exactly two
---places: the rendered panel buffer and the vim.ui.input prefill
---for `e`. Values are NEVER passed to auto-finder's log wrapper,
---events, or any other surface; the structured errors we do log
---carry the key/path only (auto-run's error messages are
---value-free by contract).
---@module 'auto-finder.views._env_section'

local M = {}

-- ─── highlights (default-link strategy, shared with the views) ──

local HL = {
  marker    = "AutoFinderEnvSelected",   -- the `*` on the selected row
  file      = "AutoFinderEnvFile",       -- env-file name
  missing   = "AutoFinderEnvMissing",    -- exists == false (dimmed row)
  source    = "AutoFinderEnvSource",     -- [config:x] / [profile:y] / [discovered]
  var_key   = "AutoFinderEnvVarKey",     -- KEY in an expanded child row
  var_value = "AutoFinderEnvVarValue",   -- VALUE (panel display only)
  err       = "AutoFinderEnvError",      -- parse-error child rows
  empty     = "AutoFinderEnvEmpty",      -- empty/hint copy
}
M._HL = HL

local function _apply_default_highlights()
  local set = function(name, link)
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
  end
  set(HL.marker,    "DiagnosticOk")
  set(HL.file,      "Normal")
  set(HL.missing,   "NonText")
  set(HL.source,    "Comment")
  set(HL.var_key,   "Identifier")
  set(HL.var_value, "String")
  set(HL.err,       "DiagnosticWarn")
  set(HL.empty,     "Comment")
end

_apply_default_highlights()
do
  local group = vim.api.nvim_create_augroup("auto-finder.env-section.hl",
    { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = _apply_default_highlights,
    desc = "auto-finder.env-section: re-apply default highlight links",
  })
end

-- ─── soft deps ────────────────────────────────────────────────

---auto-run's env API, or nil (re-checked per call — never cached,
---same rationale as the views' `_auto_run()`).
---@return table?
local function _env()
  local ok, env = pcall(require, "auto-run.env")
  if not ok or type(env) ~= "table"
      or type(env.files_list) ~= "function" then
    return nil
  end
  return env
end

local log = function() return require("auto-finder.log") end

---Confirm wrapper — module-level so tests can stub the
---already-exists→overwrite branch without monkey-patching
---vim.fn.confirm (the debug view's `M._confirm` convention).
---@param msg string
---@param choices string
---@param default integer
---@return integer
function M._confirm(msg, choices, default)
  return vim.fn.confirm(msg, choices, default)
end

-- ─── data ─────────────────────────────────────────────────────

---Candidate rows for the section: auto-run's `env.files_list()`
---plus — when a selection is persisted but absent from the
---candidate set (auto-run deviation #3: the view owns this edge) —
---one synthetic `unreferenced` row for `get_selected()` so the user
---can see and deselect it.
---@return table[]? list  nil when auto-run's env API is unavailable
function M.collect()
  local env = _env()
  if not env then return nil end
  local ok, list = pcall(env.files_list)
  if not ok or type(list) ~= "table" then list = {} end
  local has_selected = false
  for _, c in ipairs(list) do
    if c.selected then
      has_selected = true
      break
    end
  end
  if not has_selected then
    local oks, sel = pcall(env.get_selected)
    if oks and type(sel) == "string" and sel ~= "" then
      list[#list + 1] = {
        path      = sel,
        source    = "unreferenced",
        exists    = vim.uv.fs_stat(sel) ~= nil,
        selected  = true,
        synthetic = true,
      }
    end
  end
  return list
end

-- ─── render ───────────────────────────────────────────────────

local INDENT       = "  "     -- file rows (under the section header)
local CHILD_INDENT = "      " -- expanded KEY=VALUE / error child rows

---The `_expanded` key for an env file's inline expansion. Prefixed
---so it can share the host view's `M._expanded` table (todos-style
---"kind:id" keys; position ids / entry names never collide).
---@param path string
---@return string
function M.expand_key(path)
  return "env:" .. path
end

---Emit the section body (file rows + expanded children) into the
---host view's render arrays. The host has already emitted its own
---section header and decided the section is not collapsed.
---@param ctx { list: table[]?, lines: string[], mark: fun(lnum0: integer, c0: integer, c1: integer, hl: string), rows: table[], expanded: table<string, boolean> }
function M.emit(ctx)
  local lines, mark, rows = ctx.lines, ctx.mark, ctx.rows

  if ctx.list == nil then
    -- auto-run present but its env API missing (version skew) — the
    -- same one-line-hint shape the views use for the absent plugin.
    local l = INDENT .. "(auto-run env API unavailable — update auto-run.nvim)"
    lines[#lines + 1] = l
    mark(#lines - 1, 0, #l, HL.empty)
    return
  end
  if #ctx.list == 0 then
    local l = INDENT .. "(no env files — none referenced by configs or discovered)"
    lines[#lines + 1] = l
    mark(#lines - 1, 0, #l, HL.empty)
    return
  end

  local env = _env()
  for _, c in ipairs(ctx.list) do
    local marker = c.selected and "* " or "  "
    local name = vim.fn.fnamemodify(c.path, ":t")
    local ann = c.synthetic and "  (selected — unreferenced)"
      or ("  [" .. tostring(c.source) .. "]")
    local line = INDENT .. marker .. name .. ann
    lines[#lines + 1] = line
    local lnum0 = #lines - 1
    if c.selected then
      mark(lnum0, #INDENT, #INDENT + 1, HL.marker)
    end
    local n0 = #INDENT + #marker
    -- exists == false dims the whole row (marker column excluded so
    -- the selection stays visible even on a missing file).
    mark(lnum0, n0, n0 + #name, c.exists and HL.file or HL.missing)
    mark(lnum0, n0 + #name, n0 + #name + #ann,
      c.exists and HL.source or HL.missing)
    rows[#rows + 1] = {
      kind      = "env-file",
      lnum      = lnum0 + 1,
      path      = c.path,
      source    = c.source,
      exists    = c.exists,
      selected  = c.selected,
      synthetic = c.synthetic,
    }

    if ctx.expanded[M.expand_key(c.path)] and env then
      local okr, res, rerr = pcall(env.read_file, c.path)
      if okr and type(res) == "table" then
        for _, en in ipairs(res.entries or {}) do
          -- VALUE display — panel buffer only (§4.2 r5 boundary).
          local vline = CHILD_INDENT .. en.key .. "=" .. en.value
          lines[#lines + 1] = vline
          local l0 = #lines - 1
          mark(l0, #CHILD_INDENT, #CHILD_INDENT + #en.key, HL.var_key)
          if #en.value > 0 then
            mark(l0, #CHILD_INDENT + #en.key + 1, #vline, HL.var_value)
          end
          rows[#rows + 1] = {
            kind      = "env-var",
            lnum      = l0 + 1,
            path      = c.path,
            key       = en.key,
            file_lnum = en.lnum,
          }
        end
        for _, pe in ipairs(res.errors or {}) do
          local eline = CHILD_INDENT
            .. "! line " .. tostring(pe.lnum) .. ": " .. tostring(pe.message)
          lines[#lines + 1] = eline
          mark(#lines - 1, 0, #eline, HL.err)
          rows[#rows + 1] = {
            kind      = "env-error",
            lnum      = #lines,
            path      = c.path,
            file_lnum = pe.lnum,
          }
        end
      else
        local emsg = okr and (rerr and rerr.message) or res
        local eline = CHILD_INDENT .. "! " .. tostring(emsg or "cannot read file")
        lines[#lines + 1] = eline
        mark(#lines - 1, 0, #eline, HL.err)
        rows[#rows + 1] = {
          kind = "env-error", lnum = #lines, path = c.path, file_lnum = 1,
        }
      end
    end
  end
end

-- ─── typed-row actions (dispatched from the host views) ───────

---`o` on an env-file row → toggle the inline KEY=VALUE expansion.
---Mutates the host's `_expanded` set (sticky across re-renders);
---the caller re-renders when true is returned.
---@param row table?
---@param expanded table<string, boolean>
---@return boolean handled
function M.toggle_expand(row, expanded)
  if not (row and row.kind == "env-file") then return false end
  local k = M.expand_key(row.path)
  if expanded[k] then
    expanded[k] = nil
  else
    expanded[k] = true
  end
  return true
end

---`<CR>` — env-file opens the file (editor-routed by the host's
---helper); env-var / env-error opens it AND jumps to the entry's
---line.
---@param row table?
---@param open_file fun(path: string, lnum: integer?)
---@return boolean handled
function M.open(row, open_file)
  if not row then return false end
  if row.kind == "env-file" then
    open_file(row.path)
    return true
  end
  if row.kind == "env-var" or row.kind == "env-error" then
    open_file(row.path, row.file_lnum)
    return true
  end
  return false
end

---`s` — select the env file (deselect when it already IS the
---selection). No local re-render: `set_selected` publishes
---`run.env:changed` and the marker moves on that event's re-render.
---@param row table?
---@return boolean handled
function M.select(row)
  if not (row and row.kind == "env-file") then return false end
  local env = _env()
  if not env then return true end
  -- NOTE: no `cond and nil or x` here — that idiom always yields x.
  local target
  if not row.selected then target = row.path end
  local ok, err = env.set_selected(target)
  if not ok and err then
    log().warn("view.env",
      "select failed: " .. tostring(err.message or err.code))
  end
  return true
end

---`e` on an env-var row — vim.ui.input prefilled with the CURRENT
---value (re-read at prompt time, never cached in row state) →
---`env.update_var`. Structured errors go to the view log — key/path
---only, never values.
---@param row table?
---@return boolean handled
function M.edit_var(row)
  if not (row and row.kind == "env-var") then return false end
  local env = _env()
  if not env then return true end
  local current = ""
  local okr, res = pcall(env.read_file, row.path)
  if okr and type(res) == "table" then
    for _, en in ipairs(res.entries or {}) do
      -- Last occurrence wins — matches update_var's dotenv semantics.
      if en.key == row.key then current = en.value end
    end
  end
  vim.ui.input({ prompt = row.key .. " = ", default = current },
    function(value)
      if value == nil then return end   -- canceled
      local ok, err = env.update_var(row.path, row.key, value)
      if not ok and err then
        log().error("view.env",
          "update failed: " .. tostring(err.message or err.code))
      end
      -- Re-render arrives via run.env:changed.
    end)
  return true
end

---Two-prompt add flow (KEY, then VALUE) against `path` →
---`env.add_var`. `already_exists` offers an overwrite (M._confirm →
---`env.update_var`) instead of failing.
---@param path string
local function _add_var_flow(path)
  local env = _env()
  if not env then return end
  vim.ui.input({ prompt = "new env key: " }, function(key)
    if key == nil or key == "" then return end
    vim.ui.input({ prompt = key .. " = " }, function(value)
      if value == nil then return end
      local ok, err = env.add_var(path, key, value)
      if ok then return end   -- re-render via run.env:changed
      if err and err.code == "already_exists" then
        local choice = M._confirm(
          "'" .. key .. "' exists in " .. vim.fn.fnamemodify(path, ":t")
            .. " — overwrite value?", "&Yes\n&No", 2)
        if choice ~= 1 then return end
        local ok2, err2 = env.update_var(path, key, value)
        if not ok2 and err2 then
          log().error("view.env",
            "update failed: " .. tostring(err2.message or err2.code))
        end
        return
      end
      if err then
        log().error("view.env",
          "add failed: " .. tostring(err.message or err.code))
      end
    end)
  end)
end

---`a` — add a KEY=VALUE entry. On an env-file row (`row` set) the
---row's file is the target; on the section header (`row` nil) the
---SELECTED file is, with a hint when nothing is selected.
---@param row table?  an env-file row, or nil for the section header
function M.add(row)
  local env = _env()
  if not env then return end
  local path
  if row and row.kind == "env-file" then
    path = row.path
  else
    local oks, sel = pcall(env.get_selected)
    path = oks and sel or nil
    if type(path) ~= "string" or path == "" then
      log().info("view.env",
        "no env file selected — press `a` on a file row, or `s` to select one first")
      return
    end
  end
  _add_var_flow(path)
end

return M
