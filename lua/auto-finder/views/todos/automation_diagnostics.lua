---auto-finder.views.todos.automation_diagnostics
---
---ADR-0035 Phase 3 — real-time validation of `.todo-list/automated/*.md`
---files surfaced as `vim.diagnostic` entries.
---
---Two halves:
---
---  1. **install()** registers an autocmd group that attaches the
---     buffer-level validator to every buffer whose file path looks
---     like `.todo-list/automated/*.md` (resolved through
---     `vim.fn.expand("%:p")`). Idempotent — repeat calls are no-ops.
---
---  2. **attach(bufnr)** wires `BufWritePost` + `TextChanged` +
---     `TextChangedI` autocmds to run a debounced validator (200 ms
---     window via `auto-finder.shared.debounce.coalesce`) against the
---     buffer's current contents. Each malformed `condition[i]` /
---     `execute[i]` entry emits a diagnostic at the exact line of the
---     offending `- ` item — not at the field header — so the user's
---     cursor can jump straight to the broken row.
---
---The actual content validator is `auto-core.todo.automation.validate`
---— same function that drives refresh-side `errors[]` population, so
---headless callers and the live editor surface always agree.
---@module 'auto-finder.views.todos.automation_diagnostics'

local M = {}

local NS = vim.api.nvim_create_namespace("auto-finder.todos.automation")

-- Bookkeeping: per-buffer `(trigger, cancel)` pairs from
-- `shared.debounce.coalesce` so re-attach replaces the prior pair
-- cleanly. Also tracks the buffer's autocmd id for symmetric
-- detach during `uninstall()`.
local _buffer_state = {}     -- bufnr → { trigger, cancel, autocmd_ids, gen }
local _augroup = nil         -- BufReadPost/BufNewFile/BufEnter → M.attach
local _buf_augroup = nil     -- buffer-local BufWritePost/TextChanged*/BufWipeout
local _attach_gen = 0        -- per-attachment generation; bumps on every attach

-- ─── helpers ──────────────────────────────────────────────────────

local function _is_automated_todo_path(path)
  if type(path) ~= "string" or path == "" then return false end
  -- Match `<anything>/.todo-list/automated/<basename>.md`. The
  -- middle segments aren't anchored, so a workspace at
  -- `/home/.../foo` or a KB at `/home/.../kb` both light up.
  return path:match("/%.todo%-list/automated/[^/]+%.md$") ~= nil
end

---Parse the YAML frontmatter of a buffer's text. Returns
---`(task: table?, fm_line_map: table)` where `fm_line_map` maps
---structured frontmatter paths (e.g. `condition[1]`, `execute[2]`,
---`assignee`) to 1-based line numbers in the buffer.
---
---The map covers what the validator might reference — list-item
---paths, plus scalar field rows for completeness. Unknown paths
---(everything else) fall back to the buffer's first line so a
---diagnostic still has something to point at.
---@param lines string[]   buffer lines, 1-based caller convention
---@return table? task, table line_map
local function _parse_frontmatter(lines)
  if #lines == 0 then return nil, {} end
  -- Find the frontmatter open / close.
  if not lines[1] or lines[1]:gsub("%s+$", "") ~= "---" then
    return nil, {}
  end
  local close_line
  for i = 2, #lines do
    if (lines[i] or ""):gsub("%s+$", "") == "---" then
      close_line = i; break
    end
  end
  if not close_line then return nil, {} end

  -- Re-decode through auto-core.todo.md so the live validator sees
  -- the same task shape it would on disk. Build the source.
  local fm_src = table.concat({ unpack(lines, 1, close_line) }, "\n") .. "\n"
  local ok_md, md = pcall(require, "auto-core.todo.md")
  if not ok_md then return nil, {} end

  -- md.decode wants a body too. Synthesize one — the body content
  -- doesn't affect validate(), which operates on the decoded
  -- frontmatter table.
  local body = table.concat({ unpack(lines, close_line + 1) }, "\n")
  local dec_ok, dec = pcall(md.decode, fm_src .. body)
  local task = (dec_ok and dec and dec.ok and type(dec.value) == "table") and dec.value or nil

  -- Build the line map by scanning frontmatter line-by-line.
  -- We watch for `<key>:` headers to enter list contexts, then
  -- count subsequent `- ` lines.
  local line_map = {}
  local current_list_key, current_list_count = nil, 0
  for i = 2, close_line - 1 do
    local line = lines[i] or ""
    local stripped = line:gsub("^%s+", "")
    -- Scalar field row: `<word>: <value>` at the top indent. We
    -- record EVERY recognized scalar; the validator may need to
    -- point at `assignee:` or `status:` etc.
    local scalar_key = line:match("^(%w+):%s*[^%s]")
    if scalar_key then
      line_map[scalar_key] = i
      current_list_key = nil
      current_list_count = 0
    else
      -- List-header row: `<word>:` with nothing after the colon.
      local list_key = line:match("^(%w+):%s*$")
      if list_key then
        line_map[list_key] = i
        current_list_key = list_key
        current_list_count = 0
      elseif current_list_key and stripped:sub(1, 2) == "- " then
        current_list_count = current_list_count + 1
        local item_path = current_list_key .. "[" .. current_list_count .. "]"
        line_map[item_path] = i
      end
    end
  end

  -- Fallback anchor: line 1 (frontmatter `---` row).
  line_map[1] = 1

  return task, line_map
end

---Map a validator error entry's `field` (e.g. `condition[2]`) to a
---1-based line number using the parsed frontmatter map. Returns
---`(line, col)` — col stays at 1 because the diagnostic refers to
---the whole line; later refinements could compute precise byte
---offsets within the list-item value.
local function _line_col_for(field, line_map)
  if type(field) == "string" and line_map[field] then
    return line_map[field], 1
  end
  -- Strip the `[N]` indexer and try the bare key.
  local bare = field and field:match("^([^%[]+)")
  if bare and line_map[bare] then
    return line_map[bare], 1
  end
  return 1, 1
end

---Run the validator against `bufnr`'s current contents and push
---diagnostics into the auto-finder.todos.automation namespace.
---Idempotent — set() clears prior entries automatically.
local function _validate(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #lines == 0 then
    vim.diagnostic.set(NS, bufnr, {})
    return
  end

  local task, line_map = _parse_frontmatter(lines)
  if not task or task.status ~= "automated" then
    -- Not an automated template (yet). Clear stale diagnostics so
    -- a half-written file moving toward `automated` doesn't carry
    -- noise from a prior render.
    vim.diagnostic.set(NS, bufnr, {})
    return
  end

  local ok_auto, automation = pcall(require, "auto-core.todo.automation")
  if not ok_auto then
    vim.diagnostic.set(NS, bufnr, {})
    return
  end

  local entries = automation.validate(task) or {}
  local diagnostics = {}
  for _, e in ipairs(entries) do
    local lnum, col = _line_col_for(e.field, line_map)
    diagnostics[#diagnostics + 1] = {
      bufnr    = bufnr,
      lnum     = lnum - 1,        -- vim.diagnostic uses 0-based
      col      = col - 1,
      severity = vim.diagnostic.severity.ERROR,
      message  = tostring(e.message),
      source   = "auto-finder.todos.automation",
      code     = e.code,
    }
  end
  vim.diagnostic.set(NS, bufnr, diagnostics)
end

---Attach the diagnostic validator to a buffer. Wires the
---BufWritePost / TextChanged* autocmds; idempotent across repeat
---calls on the same buffer (replaces the prior debouncer).
---@param bufnr integer
function M.attach(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return end

  -- Replace any prior debouncer / autocmds for this buffer.
  if _buffer_state[bufnr] then
    if type(_buffer_state[bufnr].cancel) == "function" then
      pcall(_buffer_state[bufnr].cancel)
    end
    for _, id in ipairs(_buffer_state[bufnr].autocmd_ids or {}) do
      pcall(vim.api.nvim_del_autocmd, id)
    end
  end

  local debounce = require("auto-finder.shared.debounce")
  local trigger, cancel = debounce.coalesce(function()
    _validate(bufnr)
  end, 200)

  -- Bump the per-attachment generation so a scheduled callback from
  -- a PRIOR attachment (or after uninstall) can detect it is stale
  -- and bail. This closes the lifecycle defect where uninstall
  -- before the scheduled tick leaves the callback armed: it fires,
  -- re-creates diagnostics, but _buffer_state[bufnr] is nil →
  -- attached_buffers reports 0 while a diagnostic is visible.
  _attach_gen = _attach_gen + 1
  local my_gen = _attach_gen

  -- Schedule the initial validation so it runs on the next event-loop
  -- tick, NOT synchronously inside BufReadPost dispatch. This is a
  -- defensive candidate isolation measure for the headless crash
  -- (KB todo 2026-06-13-…): synchronous nvim_buf_get_lines on a
  -- buffer mid-BufReadPost was identified as a candidate trigger,
  -- and deferring it costs nothing perceptible to a human. NOTE:
  -- this alone does NOT resolve the crash on all runtimes (the codex
  -- sandbox still exits 139); it is retained as defensive hygiene
  -- alongside the separate augroup below. One event-loop turn is
  -- imperceptible; the debounce's TextChanged autocmds (wired below,
  -- still synchronous) catch any edit before the scheduled validate
  -- lands.
  --
  -- The generation guard ensures the callback is a no-op if the
  -- attachment was replaced (re-attach bumped the gen) or torn down
  -- (uninstall cleared _buffer_state) before the tick landed.
  vim.schedule(function()
    local st = _buffer_state[bufnr]
    if st and st.gen == my_gen then
      _validate(bufnr)
    end
  end)

  local ids = {}
  local function add_autocmd(events)
    ids[#ids + 1] = vim.api.nvim_create_autocmd(events, {
      group   = _buf_augroup,
      buffer  = bufnr,
      desc    = "auto-finder.todos.automation: revalidate diagnostics",
      callback = function() trigger() end,
    })
  end

  add_autocmd({ "BufWritePost" })
  add_autocmd({ "TextChanged", "TextChangedI" })

  -- Cleanup on BufWipeout: cancel the debouncer + clear diagnostics
  -- so we don't leak a stamp into a future buf at the same id.
  ids[#ids + 1] = vim.api.nvim_create_autocmd("BufWipeout", {
    group  = _buf_augroup,
    buffer = bufnr,
    callback = function()
      pcall(cancel)
      pcall(vim.diagnostic.reset, NS, bufnr)
      _buffer_state[bufnr] = nil
    end,
  })

  _buffer_state[bufnr] = {
    trigger      = trigger,
    cancel       = cancel,
    autocmd_ids  = ids,
    gen          = my_gen,
  }
end

---Idempotent install. Mounts the autocmd that attaches the
---validator to every buffer whose path matches the automated
---templates glob. Safe to call from auto-finder setup AND from
---smoke; second call is a no-op.
function M.install()
  if _augroup then return end
  _augroup = vim.api.nvim_create_augroup(
    "auto-finder.todos.automation", { clear = true })
  -- Separate group for buffer-local autocmds created by M.attach.
  -- Same-group mutation during BufReadPost dispatch was identified
  -- as a candidate trigger for the headless SEGFAULT / realloc()
  -- abort (KB todo 2026-06-13-…, candidate b) — creating autocmds
  -- in _augroup while it is dispatching mutates the array nvim is
  -- iterating. This is a defensive candidate isolation measure, not
  -- an established crash mechanism: the separated-group build still
  -- exits 139 on the codex runtime. A second group has its own
  -- array, so M.attach can safely add to it mid-dispatch regardless.
  _buf_augroup = vim.api.nvim_create_augroup(
    "auto-finder.todos.automation.buf", { clear = true })

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufEnter" }, {
    group = _augroup,
    desc  = "auto-finder.todos.automation: attach diagnostics validator",
    callback = function(ev)
      local path = vim.api.nvim_buf_get_name(ev.buf)
      if _is_automated_todo_path(path) then
        M.attach(ev.buf)
      end
    end,
  })
end

---Symmetric teardown — drops every attached buffer's debouncer +
---clears diagnostics. Used by smoke / re-arm scenarios.
function M.uninstall()
  if _augroup then
    pcall(vim.api.nvim_del_augroup_by_id, _augroup)
    _augroup = nil
  end
  if _buf_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, _buf_augroup)
    _buf_augroup = nil
  end
  for bufnr, state in pairs(_buffer_state) do
    if type(state.cancel) == "function" then pcall(state.cancel) end
    pcall(vim.diagnostic.reset, NS, bufnr)
  end
  _buffer_state = {}
end

---Diagnostic snapshot for smoke / admin.
function M.attached_buffers()
  local out = {}
  for bufnr, _ in pairs(_buffer_state) do out[#out + 1] = bufnr end
  table.sort(out)
  return out
end

M.NS = NS  -- exposed so smoke can call vim.diagnostic.get(bufnr, {namespace=NS})

return M