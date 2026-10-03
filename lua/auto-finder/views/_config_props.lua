---auto-finder.views._config_props — the ONE property editor for auto-run
---records shown in the panes (ADR 0199 §6.2 / §6.5): the debug pane's entry
---points, the tests pane's test configs, and env profiles. Module-PRIVATE to
---the views (leading underscore keeps it out of the view registry's scan).
---
---It moved here from the debug view so the three record kinds share one
---implementation — above all one MASKING boundary: an env value (`env.KEY`,
---a profile's `runtime_env.KEY`) never reaches the buffer, the prompt or a
---diagnostic. References (`${VAR}`, `cmd:…`) are not secrets and are shown.
---
---Rows it emits carry `prop = true`, the property `field`, and the `parent`
---row (`kind` entry | test-config | profile, `name`). The host view passes its
---own row kind, so the debug view keeps its `detail` rows and the tests view
---does not collide with its test-position details.
---
---Also here: `D` — delete a config or a profile behind a confirm that names the
---exact file(s), the tier(s) and whether git tracks them (Lector r7).
---@module 'auto-finder.views._config_props'

local M = {}

local function say(msg, level)
  require("auto-finder.log").notify(msg, { component = "view.config", level = level or "info", notify = true })
end

local function errtext(err)
  if type(err) == "table" then return tostring(err.message or err.code or vim.inspect(err)) end
  return tostring(err)
end
M._errtext = errtext

---Confirm seam (stubbed in tests), the views' `vim.fn.confirm` convention.
function M._confirm(msg, choices, default)
  return vim.fn.confirm(msg, choices, default)
end

local function store()
  local ok, s = pcall(require, "auto-run.store")
  return ok and s or nil
end

---Render an env value for display. Pure substitution refs (`${VAR}`) and
---command refs (`cmd:…`) are refs, not secrets — shown verbatim. EVERYTHING
---else (any literal, any mixed literal) is masked.
---@param v any
---@return string text, boolean masked
function M.masked_env_value(v)
  if type(v) == "string" then
    if v:match("^%${[%w_%.%-]+}$") then return v, false end
    if v:match("^cmd:") then return v, false end
  end
  return "(masked)", true
end

---Split one line the way a POSIX shell splits words: whitespace separates,
---'…' is literal, "…" and a bare backslash escape the next character.
---@param line string
---@return string[]
function M.shell_split(line)
  local out, cur, i, n, have = {}, {}, 1, #line, false
  local quote
  while i <= n do
    local ch = line:sub(i, i)
    if quote == "'" then
      if ch == "'" then quote = nil else cur[#cur + 1] = ch end
    elseif quote == '"' then
      if ch == '"' then quote = nil
      elseif ch == "\\" and i < n then i = i + 1; cur[#cur + 1] = line:sub(i, i)
      else cur[#cur + 1] = ch end
    elseif ch == "'" or ch == '"' then quote = ch; have = true
    elseif ch == "\\" and i < n then i = i + 1; cur[#cur + 1] = line:sub(i, i); have = true
    elseif ch:match("%s") then
      if have or #cur > 0 then out[#out + 1] = table.concat(cur); cur, have = {}, false end
    else cur[#cur + 1] = ch; have = true end
    i = i + 1
  end
  if have or #cur > 0 then out[#out + 1] = table.concat(cur) end
  return out
end

---Inverse of `shell_split` for a prefill: quote only what needs it.
---@param list string[]
---@return string
function M.shell_join(list)
  local parts = {}
  for _, a in ipairs(list or {}) do
    a = tostring(a)
    if a ~= "" and a:match("^[%w%._/:=@%%+,%-${}]+$") then
      parts[#parts + 1] = a
    else
      parts[#parts + 1] = "'" .. a:gsub("'", [['\'']]) .. "'"
    end
  end
  return table.concat(parts, " ")
end

-- ─── which record, which fields ─────────────────────────────────

---@param parent table  the record's row
---@return "config"|"profile"
local function record_of(parent)
  return parent and parent.kind == "profile" and "profile" or "config"
end

-- Fields `e` edits in place, per record, by shape. A map field's rows are
-- `<map>.KEY` (masked) plus a `<map>+` row to add one.
local SCALAR = {
  config  = { program = true, cwd = true, build_flags = true, runtime = true,
              cargo_package = true, cargo_target = true, cargo_target_kind = true },
  profile = {},
}

---Is `field` a plain-string field `e` edits in place? The table above, or —
---with auto-run >= 0.1.19 — any field auto-run's schema declares a plain
---string, so a new string field (node's `script`) is editable without this
---list having to learn it.
---@param rec "config"|"profile"
---@param field string
---@return boolean
local function is_scalar(rec, field)
  if SCALAR[rec][field] then return true end
  local ok, schema = pcall(require, "auto-run.store.schema")
  return ok and type(schema.field_kind) == "function" and schema.field_kind(rec, field) == "string"
end
local LIST = {
  config  = { args = true, env_files = true },
  profile = { base_env_files = true, secret_manifests = true },
}
local MAP = { config = "env", profile = "runtime_env" }
-- List fields whose store merge rule APPENDS across layers. The editor shows
-- the EFFECTIVE list, so its write must REPLACE the lower layers' entries or
-- a tracked [A] edited to [A,B] becomes [A,A,B] and an inherited entry can
-- never be dropped (Lector #59). `args` replaces whole already.
local APPENDS = { env_files = true, base_env_files = true, secret_manifests = true }

---The effective record, or nil + err.
---@param rec "config"|"profile"
---@param name string
local function get(rec, name)
  local s = store()
  if not s then return nil, "auto-run is not available" end
  if rec == "profile" then return s.get_profile(name) end
  local ok, eff, err, meta = pcall(s.get, name)
  if not ok then return nil, eff end
  return eff, err, meta
end

---The record's file (tracked tier first — the reviewable one), or nil.
---@param rec "config"|"profile"
---@param name string
---@return string?
function M.file(rec, name)
  local s = store()
  if not s or type(s.config_file) ~= "function" then return nil end
  local ok, path = pcall(s.config_file, name, rec == "profile" and { kind = "profiles" } or nil)
  return ok and path or nil
end

-- ─── field documentation (auto-run owns it) ───────────────────────

---auto-run's documentation for `field` of `rec`, or nil (older auto-run, or
---a row that is not a field). A map's add row (`env+`) documents its map.
---@param rec "config"|"profile"
---@param field string
local function field_doc(rec, field)
  local ok, schema = pcall(require, "auto-run.store.schema")
  if not ok or type(schema.field_doc) ~= "function" then return nil end
  return schema.field_doc(rec, (tostring(field):gsub("%+$", "")))
end

---The config fields that belong to `runtime` (auto-run's field docs mark
---them with `runtimes`), in a stable order; nil when auto-run is too old to
---say (the caller keeps its built-in rows).
---@param runtime string
---@return string[]?
local function runtime_fields(runtime)
  local ok, schema = pcall(require, "auto-run.store.schema")
  if not ok or type(schema.field_names) ~= "function" or type(schema.field_doc) ~= "function" then return nil end
  local order = { build_flags = 1, cargo_package = 2, cargo_target = 3, cargo_target_kind = 4 }
  local out = {}
  for _, f in ipairs(schema.field_names("config")) do
    local d = schema.field_doc("config", f)
    if d and type(d.runtimes) == "table" and vim.tbl_contains(d.runtimes, runtime) then out[#out + 1] = f end
  end
  table.sort(out, function(a, b)
    local ka, kb = order[a] or 99, order[b] or 99
    if ka ~= kb then return ka < kb end
    return a < b
  end)
  return out
end

---The hint shown beside an unset field: its help, then the allowed values, or
---that `e` chooses from a set auto-run resolves.
---@param doc table
---@return string
function M.help_text(doc)
  local t = doc.help
  if doc.values then
    t = t .. "  [" .. table.concat(doc.values, " | ") .. "]"
  elseif doc.values_from then
    t = t .. "  (e chooses)"
  end
  return t
end

-- ─── rendering ──────────────────────────────────────────────────

---Emit `parent`'s properties as rows under it.
---@param ctx { lines: string[], rows: table[], mark: fun(l0:integer,c0:integer,c1:integer,hl:string), hl: { label: string, value: string, null: string, masked: string, path: string }, parent: table, row_kind: string?, indent: integer?, label_w: integer? }
function M.emit(ctx)
  local lines, rows, mark, hl, parent = ctx.lines, ctx.rows, ctx.mark, ctx.hl, ctx.parent
  local indent = string.rep(" ", ctx.indent or 8)
  local label_w = ctx.label_w or 16
  local rec = record_of(parent)

  local function row(label, raw_value, opts)
    opts = opts or {}
    local is_null = raw_value == nil or raw_value == ""
    local v_text = is_null and "(none)" or tostring(raw_value)
    -- An unset field says what it is for and what it takes, so a fresh
    -- record shows everything it can hold (the store is strict JSON, so the
    -- file itself cannot carry comments).
    local doc = is_null and field_doc(rec, label) or nil
    if doc then v_text = v_text .. "  " .. M.help_text(doc) end
    local line = indent .. string.format("%-" .. label_w .. "s", label .. ":") .. v_text
    lines[#lines + 1] = line
    local l0 = #lines - 1
    mark(l0, #indent, #indent + #label + 1, hl.label)
    local v_col = #indent + label_w
    local v_hl = is_null and hl.null or opts.masked and hl.masked or opts.filepath and hl.path or hl.value
    mark(l0, v_col, v_col + #v_text, v_hl)
    rows[#rows + 1] = { kind = ctx.row_kind or "prop", prop = true, lnum = l0 + 1,
      parent = parent, field = label, filepath = opts.filepath }
  end
  local function list_text(v) return type(v) == "table" and #v > 0 and table.concat(v, ", ") or nil end
  local function map_rows(map_name, m)
    if type(m) == "table" then
      local keys = {}
      for k in pairs(m) do keys[#keys + 1] = k end
      table.sort(keys)
      for _, k in ipairs(keys) do
        local text, masked = M.masked_env_value(m[k])
        row(map_name .. "." .. k, text, { masked = masked })
      end
    end
    row(map_name .. "+", "(e adds KEY=VALUE)")
  end

  local eff, err, meta = get(rec, parent.name)
  if not eff then
    row("error", errtext(err))
    return
  end

  if rec == "profile" then
    row("base_env_files", list_text(eff.base_env_files))
    row("secret_manifests", list_text(eff.secret_manifests))
    map_rows("runtime_env", eff.runtime_env)
    local nce = type(eff.command_env) == "table" and #eff.command_env or 0
    row("command_env", nce > 0 and (nce .. " entr" .. (nce == 1 and "y" or "ies") .. " — e opens the file") or nil)
    local f = M.file("profile", parent.name)
    row("file", f, { filepath = f })
    return
  end

  row("kind", eff.kind)
  row("runtime", eff.runtime or "go")
  row("extends", eff.extends)
  row("program", eff.program)
  -- Shown even when unset, so `e` can fill them in place on a fresh record
  -- (Lector M5a P2).
  row("args", type(eff.args) == "table" and #eff.args > 0 and table.concat(eff.args, " ") or nil)
  row("cwd", eff.cwd)
  -- The runtime's own fields — go build flags, rust's Cargo identity, node's
  -- script, dart's SDK and device — from auto-run's field docs, so a runtime
  -- auto-run adds shows its fields without this view learning them.
  local rf = runtime_fields(eff.runtime or "go")
  if rf then
    for _, f in ipairs(rf) do row(f, eff[f]) end
  elseif eff.runtime ~= "rust" then   -- older auto-run: go build flags; rust carries Cargo identity instead
    row("build_flags", eff.build_flags)
  else
    row("cargo_package", eff.cargo_package)
    row("cargo_target", eff.cargo_target)
    row("cargo_target_kind", eff.cargo_target_kind)
  end
  row("env_files", list_text(eff.env_files))
  map_rows("env", eff.env)
  -- The PERSISTENT profile choice for this record (ADR 0199 §6.5 — the
  -- Profiles section edits profiles; choosing one is here).
  row("profile", eff.profile)
  row("origin", eff.origin)
  if meta and type(meta.layers) == "table" then
    row("layers", table.concat(meta.layers, " → "))
  end
  local f = M.file("config", parent.name)
  row("file", f, { filepath = f })
end

-- ─── editing ────────────────────────────────────────────────────

---`e` on a property row: edit it in place through `store.update`. Returns
---false when the row is not an editable property (the caller then does what
---`e` did before — open the record's file).
---@param row table?
---@return boolean handled
function M.edit(row)
  if not (row and row.prop and row.parent and row.parent.name) then return false end
  local rec = record_of(row.parent)
  local name, field = row.parent.name, row.field
  local map_name = MAP[rec]
  local map_key = type(field) == "string" and field:match("^" .. map_name .. "%.(.+)$") or nil
  local map_add = field == map_name .. "+"
  local s = store()
  if not s then return true end
  local function update(patch)
    local o = rec == "profile" and { kind = "profiles" } or {}
    local replace = {}
    for f in pairs(patch) do if APPENDS[f] then replace[#replace + 1] = f end end
    if #replace > 0 then o.replace = replace end
    local res, uerr = s.update(name, patch, next(o) and o or nil)
    if not res then
      local msg = errtext(uerr)
      if msg:find("launch.json shim", 1, true) then msg = msg .. " — press I to import it" end
      say(msg, "error")
    end
  end

  -- A config's profile: chosen from the profiles that exist.
  if rec == "config" and field == "profile" then
    local names = {}
    for _, p in ipairs(s.list_profiles()) do names[#names + 1] = p.name end
    if #names == 0 then
      say("no env profiles yet — `a` in the debug pane's Profiles section creates one")
      return true
    end
    local items = vim.list_extend({ "(none)" }, names)
    vim.ui.select(items, { prompt = name .. " · profile" }, function(choice)
      if not choice then return end
      update({ profile = choice ~= "(none)" and choice or vim.NIL })
    end)
    return true
  end

  -- A field with a fixed set (kind, cargo_target_kind) or a set auto-run
  -- resolves (runtime, extends): chosen, never typed.
  local fdoc = field_doc(rec, field)
  if fdoc and not map_key and not map_add and (fdoc.values or fdoc.values_from) then
    local items = {}
    if fdoc.values then
      items = vim.deepcopy(fdoc.values)
    elseif fdoc.values_from == "runtimes" then
      local okr, reg = pcall(require, "auto-run.adapters")
      for _, a in ipairs(okr and reg.list() or {}) do items[#items + 1] = a.name end
    elseif fdoc.values_from == "configs" then
      for _, c in ipairs(s.list()) do
        if not c.error and c.name ~= name then items[#items + 1] = c.name end
      end
    end
    local required = rec == "config" and field == "kind"
    if #items == 0 then
      say("nothing to choose for " .. field .. " yet")
      return true
    end
    if not required then table.insert(items, 1, "(none)") end
    vim.ui.select(items, { prompt = name .. " · " .. field .. " — " .. fdoc.help }, function(choice)
      if not choice then return end
      update({ [field] = choice ~= "(none)" and choice or vim.NIL })
    end)
    return true
  end

  if not (is_scalar(rec, field) or LIST[rec][field] or map_key or map_add) then
    if rec == "profile" and (field == "command_env" or field == "file") then
      local f = M.file("profile", name)
      if f then vim.cmd.edit(vim.fn.fnameescape(f)) end
      return true
    end
    return false
  end
  local eff, gerr = get(rec, name)
  if not eff then say(errtext(gerr), "error"); return true end

  local default, prompt
  if map_add then
    default = ""
    prompt = name .. " · new " .. map_name .. " var (KEY=VALUE): "
  elseif map_key then
    -- Prefill the KEY only: a secret value must never reach the prompt, the
    -- same boundary as the buffer (§8.2). References are not secrets.
    local text, masked = M.masked_env_value((eff[map_name] or {})[map_key])
    default = map_key .. "=" .. (masked and "" or text)
    prompt = name .. " · " .. map_name .. " (KEY=VALUE; empty VALUE removes it): "
  elseif LIST[rec][field] then
    default = M.shell_join(eff[field])
    prompt = name .. " · " .. field .. " (shell words; empty clears): "
  else
    default = eff[field] ~= nil and tostring(eff[field]) or ""
    prompt = name .. " · " .. field .. " (empty clears): "
  end

  vim.ui.input({ prompt = prompt, default = default }, function(answer)
    if answer == nil then return end   -- cancelled: change nothing
    if map_add and answer == "" then return end
    if map_key or map_add then
      local k, v = answer:match("^%s*([%w_%.%-]+)=(.*)$")
      -- Never echo the answer: a malformed one can still carry the secret.
      if not k then return say(map_name .. " must be KEY=VALUE — nothing was changed", "warn") end
      local patch = { [map_name] = { [k] = v ~= "" and v or vim.NIL } }
      if map_key and k ~= map_key then patch[map_name][map_key] = vim.NIL end
      return update(patch)
    end
    if LIST[rec][field] then
      local list = M.shell_split(answer)
      return update({ [field] = #list > 0 and list or vim.NIL })
    end
    update({ [field] = answer ~= "" and answer or vim.NIL })
  end)
  return true
end

-- ─── deleting (`D`) ─────────────────────────────────────────────

---Whether git tracks `path` (so a deletion is recoverable from history).
---@param path string
---@return boolean
local function git_tracks(path)
  local r = vim.system({ "git", "-C", vim.fn.fnamemodify(path, ":h"), "ls-files", "--error-unmatch", "--", path },
    { text = true }):wait()
  return r.code == 0
end

---`D` on a config row (`entry` / `test-config`) or a `profile` row: delete it
---behind a confirm naming each file, its tier and whether git tracks it. With
---both tiers present the choice is explicit — removing the local (shared)
---layer makes the tracked one apply again. A launch.json entry has no store
---file and is refused. Returns true when the row was a record row.
---@param row table?
---@return boolean handled
function M.delete(row)
  if not (row and row.name and (row.kind == "entry" or row.kind == "test-config" or row.kind == "profile")) then
    return false
  end
  local s = store()
  if not s or type(s.files) ~= "function" then
    say("this auto-run.nvim cannot delete records — update it", "warn")
    return true
  end
  local rec = record_of(row)
  local kind_opts = rec == "profile" and { kind = "profiles" } or nil
  local noun = rec == "profile" and "profile" or (row.kind == "test-config" and "test config" or "entry point")
  local files = s.files(row.name, kind_opts)
  if not files.tracked and not files.shared then
    say("'" .. row.name .. "' comes from launch.json, not the store — remove it there"
      .. " (or I imports it, and then D can delete it)", "warn")
    return true
  end

  local function describe(tier, path)
    local where = tier == "tracked" and "tracked (repo) tier" or "shared (local) tier"
    local git = git_tracks(path) and "git tracks it — recoverable from history"
      or "not tracked by git — the deletion is permanent"
    return "  " .. where .. ": " .. path .. "\n    " .. git
  end
  local lines = { "Delete " .. noun .. " '" .. row.name .. "'?" }
  if files.tracked then lines[#lines + 1] = describe("tracked", files.tracked) end
  if files.shared then lines[#lines + 1] = describe("shared", files.shared) end

  local plan
  if files.tracked and files.shared then
    lines[#lines + 1] = "Removing the local layer alone makes the tracked version apply again."
    local c = M._confirm(table.concat(lines, "\n"), "&Local layer only\n&Both layers\n&Cancel", 3)
    plan = (c == 1 and { "shared" }) or (c == 2 and { "shared", "tracked" }) or nil
  else
    local c = M._confirm(table.concat(lines, "\n"), "&Delete\n&Cancel", 2)
    plan = c == 1 and { files.tracked and "tracked" or "shared" } or nil
  end
  if not plan then return true end

  for _, tier in ipairs(plan) do
    local ok, err = s.remove(row.name, vim.tbl_extend("force", kind_opts or {}, { tier = tier }))
    if not ok then say(errtext(err), "error"); return true end
  end
  local left = s.files(row.name, kind_opts)
  if left.tracked then
    say("removed the local layer of '" .. row.name .. "' — the tracked version applies again")
  else
    say("deleted " .. noun .. " '" .. row.name .. "'")
  end
  return true
end

return M
