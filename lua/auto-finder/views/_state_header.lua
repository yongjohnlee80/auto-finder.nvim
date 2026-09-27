---auto-finder.views._state_header — the state header at the top of the tests
---and debug panes (ADR 0199 §5.2).
---
---What it fixes: a selection used to be visible only while its section was
---expanded (the `* ` marker lives inside section bodies the panes skip when
---collapsed), neither pane had a line stating what would run, and a pane
---pointed at a directory that is not a repository showed zeros with no
---explanation.
---
---Rules this module keeps:
---  • It is ALWAYS rendered and never collapsible.
---  • Every row states its value OR states that there is none — an absence is
---    shown, never omitted.
---  • It reads ONLY `auto-run.context`, which takes every value from the owner
---    execution reads. It never derives an answer of its own, so the header
---    cannot disagree with what runs.
---  • Rows are typed (`state-*`) so the pane's keys can act on them.
---@module 'auto-finder.views._state_header'

local M = {}

local LABEL_W = 17  -- "Active worktree  "

---Display a path relative to `root` when it lives under it, else `~`-relative.
---@param path string
---@param root string?
---@return string
local function display_path(path, root)
  if root and path:sub(1, #root + 1) == root .. "/" then
    return path:sub(#root + 2)
  end
  return vim.fn.fnamemodify(path, ":~")
end

---The value string for each row, plus which highlight it deserves.
---@param st table   auto-run.context.resolve()
---@return table<string, { text: string, tone: "value"|"null"|"warn" }>
function M.values(st)
  local out = {}

  local w = st.worktree or {}
  do
    local text
    if w.is_repo then
      text = tostring(w.label) .. (w.branch and ("  (" .. w.branch .. ")") or "")
    else
      text = tostring(w.label) .. " — not a repository"
    end
    if w.source and w.source ~= "active" then
      text = text .. "  · from " .. w.source
    end
    out.worktree = { text = text, tone = w.is_repo and "value" or "warn" }
  end

  local e = st.env or {}
  if not e.path then
    out.env = { text = "(process env only)", tone = "null" }
  elseif not e.exists then
    out.env = { text = display_path(e.path, w.root) .. " — MISSING", tone = "warn" }
  else
    out.env = { text = display_path(e.path, w.root), tone = "value" }
  end

  local b = st.base or {}
  if b.name then
    out.base = { text = b.name .. "  — applies to every run, debug and test", tone = "value" }
  else
    out.base = { text = "(none)", tone = "null" }
  end

  local rts = st.runtimes or {}
  if #rts == 0 then
    out.test_config = { text = "(no test positions discovered yet)", tone = "null" }
  else
    local parts, warn = {}, false
    for _, rt in ipairs(rts) do
      local t = (st.tests or {})[rt] or {}
      local p
      if not t.name then
        p = rt .. ": (none)"
      elseif t.source == "picked" then
        p = rt .. ": " .. t.name .. " (picked)"
      elseif t.source == "shared" then
        -- The per-kind pick every runtime falls back to — not this runtime's
        -- own choice, so it is not labelled as one.
        p = rt .. ": " .. t.name .. " (shared pick)"
      else
        p = rt .. ": " .. t.name .. " (first)"
      end
      if t.ignored_pick then
        -- Shown, not hidden: displaying the fallback as if it were the choice
        -- is exactly the misrepresentation §5.2 forbids.
        p = p .. " — pick '" .. t.ignored_pick .. "' does not apply to " .. rt
        warn = true
      end
      parts[#parts + 1] = p
    end
    out.test_config = { text = table.concat(parts, " · "), tone = warn and "warn" or "value" }
  end

  return out
end

---Emit the header into a pane's render buffers.
---@param opts { lines: string[], rows: table[], mark: fun(l0:integer,c0:integer,c1:integer,hl:string), hl: { label: string, value: string, null: string, warn: string }, pane: "tests"|"debug" }
function M.emit(opts)
  local lines, rows, mark, hl = opts.lines, opts.rows, opts.mark, opts.hl

  local function push(kind, label, value, tone, key)
    local lab = label .. string.rep(" ", math.max(1, LABEL_W - #label))
    local keytxt = key and ("  [" .. key .. "]") or ""
    local line = lab .. value .. keytxt
    lines[#lines + 1] = line
    local l0 = #lines - 1
    mark(l0, 0, #label, hl.label)
    local hv = (tone == "warn" and hl.warn) or (tone == "null" and hl.null) or hl.value
    mark(l0, #lab, #lab + #value, hv)
    if key then mark(l0, #lab + #value, #line, hl.null) end
    rows[#rows + 1] = { kind = kind, lnum = #lines }
  end

  local okc, ctxm = pcall(require, "auto-run.context")
  if not okc or type(ctxm) ~= "table" or type(ctxm.resolve) ~= "function" then
    local l = "(this auto-run.nvim cannot report run state — update it to see the state header)"
    lines[#lines + 1] = l
    mark(#lines - 1, 0, #l, hl.null)
    rows[#rows + 1] = { kind = "state-unavailable", lnum = #lines }
  else
    local oks, st = pcall(ctxm.resolve)
    if not oks or type(st) ~= "table" then
      local l = "(could not read run state: " .. tostring(st) .. ")"
      lines[#lines + 1] = l
      mark(#lines - 1, 0, #l, hl.warn)
      rows[#rows + 1] = { kind = "state-unavailable", lnum = #lines }
    else
      local v = M.values(st)
      push("state-worktree", "Active worktree", v.worktree.text, v.worktree.tone, nil)
      push("state-env", "Env", v.env.text, v.env.tone, "s")
      push("state-base", "Base", v.base.text, v.base.tone, "b")
      if opts.pane == "tests" then
        push("state-test-config", "Test config", v.test_config.text, v.test_config.tone, "c")
      end
    end
  end

  -- No trailing blank: the debug pane's section headers already open with one,
  -- and the tests pane's counts line reads as the start of the tree.
  local rule = string.rep("─", 48)
  lines[#lines + 1] = rule
  mark(#lines - 1, 0, #rule, hl.null)
end

-- ─── choosers (the keys on the header rows) ─────────────────────────

-- Through auto-finder.log, never a bare vim.notify: the toast must also land
-- in the auto-core ring for :AutoCoreLog triage (smoke A9).
local function notify(msg, level)
  require("auto-finder.log").notify(msg, { component = "view.state-header", level = level or "info", notify = true })
end

---`s` — choose the env file applied to every run, debug and test.
function M.choose_env()
  local oke, env = pcall(require, "auto-run.env")
  if not oke or type(env.files_list) ~= "function" then
    return notify("this auto-run.nvim has no env selection API", "warn")
  end
  local ok, cands = pcall(env.files_list)
  local items, labels = { false }, { "(process env only)" }
  for _, c in ipairs(ok and cands or {}) do
    items[#items + 1] = c.path
    labels[#labels + 1] = vim.fn.fnamemodify(c.path, ":~")
  end
  vim.ui.select(labels, { prompt = "Env file for every run, debug and test" }, function(_, idx)
    if not idx then return end
    local path = items[idx] or nil
    local okset, err = env.set_selected(path)
    if not okset then notify(tostring(err), "error") end
  end)
end

---`b` — choose (or clear) the shared base, merged under every launch.
function M.choose_base()
  local oki, import = pcall(require, "auto-run.import")
  if not oki or type(import.configs_list) ~= "function" then
    return notify("this auto-run.nvim has no launch-config API", "warn")
  end
  local ok, list = pcall(import.configs_list)
  local items, labels = { false }, { "(none)" }
  for _, c in ipairs(ok and list or {}) do
    items[#items + 1] = c.name
    labels[#labels + 1] = c.name .. "  [" .. tostring(c.kind) .. "]"
  end
  if #items == 1 then
    return notify("no launch.json configs to use as a base")
  end
  vim.ui.select(labels, { prompt = "Base — applies to every run, debug and test" }, function(_, idx)
    if not idx then return end
    local okset, err = import.set_selected(items[idx] or nil)
    if not okset then notify(tostring(err and err.message or err), "error") end
  end)
end

---`c` — choose the test config for ONE runtime (asks which, when several).
function M.choose_test_config()
  local okc, ctxm = pcall(require, "auto-run.context")
  local okf, cfg = pcall(require, "auto-run.adapters.config")
  if not (okc and okf) or type(cfg.pick) ~= "function" then
    return notify("this auto-run.nvim cannot choose a test config", "warn")
  end
  local rts = ctxm.test_runtimes()
  if #rts == 0 then return notify("no test positions discovered yet") end

  local function choose_for(rt)
    local okl, list = pcall(require("auto-run.store").list)
    -- "Clear" does not always mean "use the first": with a shared per-kind
    -- pick it reveals that pick. Ask the resolver what clearing lands on, so
    -- the option says what it will do (ADR 0199 §5.2).
    local clear = "(clear pick — use the first)"
    if type(cfg.fallback_config_name) == "function" then
      local okf2, fb, fsrc = pcall(cfg.fallback_config_name, rt)
      if okf2 and fb and fsrc == "shared" then
        clear = "(clear " .. rt .. " pick — use shared pick '" .. fb .. "')"
      elseif okf2 and fb then
        clear = "(clear " .. rt .. " pick — use the first, '" .. fb .. "')"
      end
    end
    local items, labels = { false }, { clear }
    for _, c in ipairs(okl and list or {}) do
      if not c.error and c.kind == "test" and (c.runtime == nil or c.runtime == rt) then
        items[#items + 1] = c.name
        labels[#labels + 1] = c.name
      end
    end
    if #items == 1 then return notify("no test configs for " .. rt .. " — create one first") end
    vim.ui.select(labels, { prompt = "Test config for " .. rt }, function(_, idx)
      if not idx then return end
      local okset, err = cfg.pick(rt, items[idx] or nil)
      if not okset then notify(tostring(err), "error") end
    end)
  end

  if #rts == 1 then return choose_for(rts[1]) end
  vim.ui.select(rts, { prompt = "Test config for which runtime?" }, function(rt)
    if rt then choose_for(rt) end
  end)
end

return M
