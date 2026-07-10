---Shared Config-section helper for the tests + debug views — the
---launch-config companion to `_env_section.lua`. Module-PRIVATE to
---auto-finder's views (leading underscore keeps it out of the view
---registry's `_available_section_types` scan, same as `_env_section`
---and `_neotree`).
---
---Surfaces the VSCode `launch.json` configs auto-run parses
---(`auto-run.import.configs_list`), lets the user **select** one as the
---active base for every subsequent launch (`s`, persisted by auto-run),
---and expand its resolved fields inline (`o`). The tests view passes
---`kind = "test"`, the debug view `kind = "debug"` — one selection slot
---is shared across both (like env's single selected file).
---
---Masking boundary (ADR-0048 §8.2): the `o` expansion is the MASKED
---config-details surface. Env VALUES never render — `auto-run.import`
---`read_config` returns env KEY names only. Unlike the Env section
---(whose `o` deliberately shows values), nothing here exposes a value.
---@module 'auto-finder.views._config_section'

local M = {}

-- ─── highlights (default-link strategy, shared with the views) ──

local HL = {
  marker   = "AutoFinderConfigSelected",  -- the `*` on the selected row
  name     = "AutoFinderConfigName",      -- config name
  source   = "AutoFinderConfigSource",    -- [runtime] / [origin] annotation
  key      = "AutoFinderConfigKey",       -- field label in an expanded child
  value    = "AutoFinderConfigValue",     -- field value (non-secret) in a child
  err      = "AutoFinderConfigError",     -- error child rows
  empty    = "AutoFinderConfigEmpty",     -- empty/hint copy
}
M._HL = HL

local function _apply_default_highlights()
  local set = function(name, link)
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
  end
  set(HL.marker, "DiagnosticOk")
  set(HL.name,   "Constant")
  set(HL.source, "Comment")
  set(HL.key,    "Identifier")
  set(HL.value,  "Normal")
  set(HL.err,    "DiagnosticWarn")
  set(HL.empty,  "Comment")
end

_apply_default_highlights()
do
  local group = vim.api.nvim_create_augroup("auto-finder.config-section.hl",
    { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = _apply_default_highlights,
    desc = "auto-finder.config-section: re-apply default highlight links",
  })
end

-- ─── soft deps ────────────────────────────────────────────────

---auto-run's import API, or nil (re-checked per call — never cached,
---same rationale as the views' `_auto_run()`).
---@return table?
local function _import()
  local ok, import = pcall(require, "auto-run.import")
  if not ok or type(import) ~= "table"
      or type(import.configs_list) ~= "function" then
    return nil
  end
  return import
end

local log = function() return require("auto-finder.log") end

-- ─── data ─────────────────────────────────────────────────────

---Candidate rows for the section: auto-run's `configs_list(kind)`.
---Returns `list` (nil when the import API is unavailable) plus a
---`reason` string when the list is empty (no launch.json vs no configs
---of this kind), which drives the empty-hint line.
---@param kind string?  "test" | "debug" | nil
---@return table[]? list, string? reason
function M.collect(kind)
  local import = _import()
  if not import then return nil, nil end
  local ok, list, reason = pcall(import.configs_list, kind)
  if not ok or type(list) ~= "table" then return {}, "unavailable" end
  return list, reason
end

-- ─── render ───────────────────────────────────────────────────

local INDENT       = "  "     -- config rows (under the section header)
local CHILD_INDENT = "      " -- expanded field child rows

---The `_expanded` key for a config's inline expansion. Prefixed so it
---can share the host view's `M._expanded` table without colliding with
---position ids / env keys.
---@param name string
---@return string
function M.expand_key(name)
  return "config:" .. name
end

---Ordered, masked field child-lines for an expanded config.
---@param view table  auto-run.import.read_config result
---@return { label: string, value: string }[]
local function _detail_lines(view)
  local out = {}
  local function add(label, value)
    if value ~= nil and value ~= "" then
      out[#out + 1] = { label = label, value = value }
    end
  end
  add("program", view.program)
  if type(view.args) == "table" and #view.args > 0 then
    add("args", table.concat(view.args, " "))
  end
  add("build_flags", view.build_flags)
  add("cwd", view.cwd)
  if type(view.env_files) == "table" and #view.env_files > 0 then
    add("env_files", table.concat(view.env_files, ", "))
  end
  if type(view.env_keys) == "table" and #view.env_keys > 0 then
    -- KEY names only — values masked (§8.2).
    add("env", table.concat(view.env_keys, ", ") .. "  (values hidden)")
  end
  if type(view.param_ids) == "table" and #view.param_ids > 0 then
    add("params", table.concat(view.param_ids, ", "))
  end
  return out
end

---Emit the section body (config rows + expanded children) into the
---host view's render arrays. The host has already emitted its own
---section header and decided the section is not collapsed.
---@param ctx { list: table[]?, reason: string?, kind: string?, lines: string[], mark: fun(lnum0: integer, c0: integer, c1: integer, hl: string), rows: table[], expanded: table<string, boolean> }
function M.emit(ctx)
  local lines, mark, rows = ctx.lines, ctx.mark, ctx.rows

  if ctx.list == nil then
    local l = INDENT .. "(auto-run import API unavailable — update auto-run.nvim)"
    lines[#lines + 1] = l
    mark(#lines - 1, 0, #l, HL.empty)
    return
  end
  if #ctx.list == 0 then
    local msg = ctx.reason == "unavailable"
        and "(auto-run import API unavailable — update auto-run.nvim)"
      or (ctx.reason and "(no launch.json found via upward walk)")
      or ("(no " .. (ctx.kind or "") .. " configs in launch.json)")
    local l = INDENT .. msg
    lines[#lines + 1] = l
    mark(#lines - 1, 0, #l, HL.empty)
    return
  end

  local import = _import()
  for _, c in ipairs(ctx.list) do
    local marker = c.selected and "* " or "  "
    local ann = "  [" .. tostring(c.runtime or c.origin or "config") .. "]"
    local line = INDENT .. marker .. c.name .. ann
    lines[#lines + 1] = line
    local lnum0 = #lines - 1
    if c.selected then
      mark(lnum0, #INDENT, #INDENT + 1, HL.marker)
    end
    local n0 = #INDENT + #marker
    mark(lnum0, n0, n0 + #c.name, HL.name)
    mark(lnum0, n0 + #c.name, n0 + #c.name + #ann, HL.source)
    rows[#rows + 1] = {
      kind     = "config",
      lnum     = lnum0 + 1,
      name     = c.name,
      runtime  = c.runtime,
      selected = c.selected,
    }

    if ctx.expanded[M.expand_key(c.name)] and import then
      local okr, view, rerr = pcall(import.read_config, c.name)
      if okr and type(view) == "table" then
        for _, d in ipairs(_detail_lines(view)) do
          local dline = CHILD_INDENT .. d.label .. ": " .. d.value
          lines[#lines + 1] = dline
          local l0 = #lines - 1
          mark(l0, #CHILD_INDENT, #CHILD_INDENT + #d.label, HL.key)
          mark(l0, #CHILD_INDENT + #d.label + 2, #dline, HL.value)
          rows[#rows + 1] = { kind = "config-detail", lnum = l0 + 1, name = c.name }
        end
      else
        local emsg = okr and view or rerr
        local eline = CHILD_INDENT .. "! " .. tostring(emsg or "cannot read config")
        lines[#lines + 1] = eline
        mark(#lines - 1, 0, #eline, HL.err)
        rows[#rows + 1] = { kind = "config-detail", lnum = #lines, name = c.name }
      end
    end
  end
end

-- ─── typed-row actions (dispatched from the host views) ───────

---`o` on a config row → toggle the inline field expansion. Mutates the
---host's `_expanded` set; the caller re-renders when true is returned.
---@param row table?
---@param expanded table<string, boolean>
---@return boolean handled
function M.toggle_expand(row, expanded)
  if not (row and row.kind == "config") then return false end
  local k = M.expand_key(row.name)
  if expanded[k] then expanded[k] = nil else expanded[k] = true end
  return true
end

---Best-effort 1-based line of a config's `"name"` entry in launch.json.
---@param path string
---@param name string
---@return integer lnum
local function _entry_lnum(path, name)
  local ok, fh = pcall(io.open, path, "r")
  if not ok or not fh then return 1 end
  local needle = '"' .. name .. '"'
  local lnum, found = 0, 1
  for line in fh:lines() do
    lnum = lnum + 1
    if line:find('"name"', 1, true) and line:find(needle, 1, true) then
      found = lnum
      break
    end
  end
  fh:close()
  return found
end

---`<CR>` — open the launch.json file, jumping to the config's entry.
---@param row table?
---@param open_file fun(path: string, lnum: integer?)
---@return boolean handled
function M.open(row, open_file)
  if not (row and (row.kind == "config" or row.kind == "config-detail")) then
    return false
  end
  local import = _import()
  if not import or type(import.find_launch_json) ~= "function" then return true end
  local path = import.find_launch_json()
  if type(path) ~= "string" or path == "" then
    log().info("view.config", "no launch.json found to open")
    return true
  end
  open_file(path, _entry_lnum(path, row.name))
  return true
end

---`s` — select the config (deselect when it already IS the selection).
---No local re-render: `set_selected` publishes `run.config:changed` and
---the marker moves on that event's re-render.
---@param row table?
---@return boolean handled
function M.select(row)
  if not (row and row.kind == "config") then return false end
  local import = _import()
  if not import then return true end
  local target
  if not row.selected then target = row.name end
  local ok, err = import.set_selected(target)
  if not ok and err then
    log().warn("view.config",
      "select failed: " .. tostring(err.message or err.code))
  end
  return true
end

return M
