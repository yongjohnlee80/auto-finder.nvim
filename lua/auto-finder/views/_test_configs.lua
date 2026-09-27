---auto-finder.views._test_configs — the tests pane's Test configs section
---(ADR 0199 §6.2). Module-PRIVATE to the views (leading underscore keeps it
---out of the view registry's scan, like `_env_section`).
---
---Lists the auto-run store's `kind=test` configs, marks the one that applies
---to each runtime with the resolver's own reason, and shows the shared
---per-kind pick — every runtime's fallback (ADR 0199 r3 §3.2) — as its own
---row. It replaced a Config section that listed launch.json configs to use as
---the base; the state header's `b` chooses the base now.
---
---Every "which config applies" answer comes from `auto-run.context`, the
---resolver a test run itself calls — never re-derived here, so the section
---cannot disagree with what runs.
---
---Keys (routed from the tests view):
---  `s` on a config   pick it for its runtime; on the runtime's own pick, clear it
---  `s` on the shared-pick row   clear the shared pick
---  `a` on the section           create a test config (auto-run's scaffold API)
---  `<CR>` / `e` on a config     open its config file
---@module 'auto-finder.views._test_configs'

local M = {}

local function say(msg, level)
  require("auto-finder.log").notify(msg, { component = "view.tests", level = level or "info", notify = true })
end

local function errtext(err)
  if type(err) == "table" then return tostring(err.message or err.code or vim.inspect(err)) end
  return tostring(err)
end

---auto-run's surfaces this section needs, or nil when this auto-run predates
---per-runtime test picks (the section then renders a one-line notice).
---@return { store: table, cfg: table, ctx: table, exec: table }?
local function deps()
  local oks, store = pcall(require, "auto-run.store")
  local okf, cfg = pcall(require, "auto-run.adapters.config")
  local okc, ctx = pcall(require, "auto-run.context")
  local oke, exec = pcall(require, "auto-run.exec")
  if not (oks and okf and okc and oke) or type(cfg.pick) ~= "function"
      or type(ctx.resolve) ~= "function" then
    return nil
  end
  return { store = store, cfg = cfg, ctx = ctx, exec = exec }
end

---Runtimes a generic (runtime-less) config could be picked for: the ones with
---test positions, else every adapter that scaffolds.
---@param d table
---@return string[]
local function candidate_runtimes(d)
  local rts = d.ctx.test_runtimes()
  if #rts > 0 then return rts end
  local okr, reg = pcall(require, "auto-run.adapters")
  return okr and type(reg.scaffold_runtimes) == "function" and reg.scaffold_runtimes() or {}
end

---Emit the section into the tests view's render buffers.
---@param opts { lines: string[], rows: table[], mark: fun(l0:integer,c0:integer,c1:integer,hl:string), collapsed: boolean, hl: { chevron: string, header: string, name: string, marker: string, note: string, empty: string } }
function M.emit(opts)
  local lines, rows, mark, hl = opts.lines, opts.rows, opts.mark, opts.hl
  local d = deps()
  local configs, st, shared = {}, nil, nil
  if d then
    for _, c in ipairs(d.store.list()) do
      if not c.error and c.kind == "test" then configs[#configs + 1] = c end
    end
    local oks, res = pcall(d.ctx.resolve)
    st = oks and res or nil
    local okp, picks = pcall(d.exec.picks)
    shared = okp and type(picks) == "table" and picks.test or nil
  end

  local chevron = opts.collapsed and "▶ " or "▼ "
  local label = string.format("Test configs (%d)", #configs)
  lines[#lines + 1] = chevron .. label
  mark(#lines - 1, 0, #chevron, hl.chevron)
  mark(#lines - 1, #chevron, #chevron + #label, hl.header)
  rows[#rows + 1] = { kind = "test-configs-header", lnum = #lines }
  if opts.collapsed then return end

  if not d then
    local l = "  (this auto-run.nvim has no per-runtime test picks — update it)"
    lines[#lines + 1] = l
    mark(#lines - 1, 0, #l, hl.empty)
    return
  end
  if #configs == 0 then
    local l = "  (no test configs — `a` creates one; tests run with no config)"
    lines[#lines + 1] = l
    mark(#lines - 1, 0, #l, hl.empty)
  end

  -- Which runtimes each config applies to, from the resolver's answer.
  local applies = {}
  for rt, t in pairs(st and st.tests or {}) do
    if t.name then
      applies[t.name] = applies[t.name] or {}
      table.insert(applies[t.name], { rt = rt, source = t.source })
    end
  end
  local SOURCE = { picked = "picked", shared = "shared pick", first = "first" }

  for _, c in ipairs(configs) do
    local on = applies[c.name]
    if on then table.sort(on, function(a, b) return a.rt < b.rt end) end
    local prefix = on and "  * " or "    "
    local name = tostring(c.name)
    local ann = "  [" .. (c.runtime or "any runtime") .. "]"
    local note = ""
    if on then
      local parts = {}
      for _, a in ipairs(on) do
        parts[#parts + 1] = a.rt .. " (" .. (SOURCE[a.source] or tostring(a.source)) .. ")"
      end
      note = " — applies to " .. table.concat(parts, ", ")
    end
    local line = prefix .. name .. ann .. note
    lines[#lines + 1] = line
    local l0 = #lines - 1
    if on then mark(l0, 2, 3, hl.marker) end
    mark(l0, #prefix, #prefix + #name, hl.name)
    mark(l0, #prefix + #name, #line, hl.note)
    rows[#rows + 1] = { kind = "test-config", lnum = #lines, name = c.name, runtime = c.runtime }
  end

  if shared then
    local l = "    shared pick: " .. tostring(shared) .. " — every runtime's fallback (s clears)"
    lines[#lines + 1] = l
    mark(#lines - 1, 0, #l, hl.note)
    rows[#rows + 1] = { kind = "test-shared-pick", lnum = #lines, name = shared }
  end
end

---`s` on a section row. Returns true when the row was this section's.
---@param row table?
---@return boolean handled
function M.select(row)
  if not row or (row.kind ~= "test-config" and row.kind ~= "test-shared-pick") then return false end
  local d = deps()
  if not d then return true end

  if row.kind == "test-shared-pick" then
    -- auto-run announces the change (run.config:changed), which re-renders
    -- the panes; nothing is published from here on auto-run's behalf.
    d.exec.clear_pick("test")
    say("cleared the shared test pick '" .. tostring(row.name) .. "'")
    return true
  end

  local function toggle(rt)
    local current, source = d.cfg.test_config_name(rt)
    -- Explicit if/else, NOT `(cond) and nil or row.name`: with nil as the
    -- "true" branch Lua's and/or falls through to row.name, so the clear
    -- never happened (caught by [51]).
    local target = row.name
    if current == row.name and source == "picked" then target = nil end
    local ok, err = d.cfg.pick(rt, target)
    if not ok then return say(errtext(err), "error") end
    if target == nil then say("cleared the " .. rt .. " test pick") end
  end

  if row.runtime then toggle(row.runtime); return true end
  local rts = candidate_runtimes(d)
  if #rts == 0 then
    say("no runtime to pick '" .. tostring(row.name) .. "' for — no test positions discovered", "warn")
  elseif #rts == 1 then
    toggle(rts[1])
  else
    vim.ui.select(rts, { prompt = "Pick '" .. tostring(row.name) .. "' for which runtime?" }, function(rt)
      if rt then toggle(rt) end
    end)
  end
  return true
end

---`a` on the section: create a test config through auto-run's scaffold API.
---Returns true when the row was this section's.
---@param row table?
---@return boolean handled
function M.add(row)
  if not row or (row.kind ~= "test-configs-header" and row.kind ~= "test-config"
      and row.kind ~= "test-shared-pick") then
    return false
  end
  local okr, reg = pcall(require, "auto-run.adapters")
  if not okr or type(reg.scaffold) ~= "function" then
    say("this auto-run.nvim cannot scaffold configs — update it", "warn")
    return true
  end
  vim.ui.select(reg.scaffold_runtimes(), { prompt = "New test config — runtime" }, function(rt)
    if not rt then return end
    vim.ui.input({ prompt = "Name: " }, function(name)
      if not name or name == "" then return end
      local path, err = reg.scaffold("test", name, rt)
      if not path then return say(errtext(err), "error") end
      say("created test config '" .. name .. "' (" .. rt .. ") — s picks it")
    end)
  end)
  return true
end

---`<CR>` / `e` on a config row: open its config file. Returns true when the
---row was this section's.
---@param row table?
---@param open_file fun(path: string)
---@return boolean handled
function M.open(row, open_file)
  if not row or row.kind ~= "test-config" then return false end
  local oks, store = pcall(require, "auto-run.store")
  local path = oks and type(store.config_file) == "function" and store.config_file(row.name) or nil
  if not path then
    say("'" .. tostring(row.name) .. "' has no editable store file", "warn")
    return true
  end
  open_file(path)
  return true
end

return M
