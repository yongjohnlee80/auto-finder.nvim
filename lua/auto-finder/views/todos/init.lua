---View — auto-core todo tasks (per-workspace `.todo-list/*.md`).
---
---Flat scratch-buffer list, NOT neo-tree-backed (same UX shape as
---`auto-finder.views.marks`). Consumes the v0.1.36+ `auto-core.todo`
---surface for data + lifecycle; the panel never edits YAML
---frontmatter directly.
---
---Layout:
---  - One section per status bucket, in fixed order:
---      open → deferred → completed → archived
---  - Inside each section, tasks with errors[] non-empty float to
---    the top of the bucket (red ⚠ badge); clean tasks follow,
---    both groups sorted lexicographically by id (= YYYY-MM-DD-…
---    so chronological).
---  - The OPEN bucket carries a 1-based index per task — that
---    index aligns with the eventual `auto-agents` admin-panel
---    numbered assignment surface (ADR-0031 §5).
---
---Buffer-local keymaps (added in task 23 — this scaffold ships the
---skeleton + render only):
---  <CR>  open the task's .md file via the editor-window resolver
---  i     floating preview (title / status / priority / assignee /
---        due / description; + errors section when non-empty)
---  a     prompt for title, add task, open file
---  d     remove task (with confirmation)
---  s     cycle status (open → completed → deferred → open)
---  R     manual refresh (auto-core.todo.refresh + re-render)
---
---Auto-refresh (task 24):
---  - on slot focus (always)
---  - on `core.todo.status:changed` published by auto-core.todo.status
---  - on `core.todo:refreshed` published by auto-core.todo.refresh
---  All event-driven re-renders are gated on the buffer being visible.
---@module 'auto-finder.views.todos'

local M = {
  name        = "todos",
  description = "auto-core todo tasks (per-workspace .todo-list/)",
}

local FILETYPE = "auto-finder"

-- Highlight groups. Same default-link strategy as marks: pick
-- groups every colorscheme is expected to ship, so the panel
-- picks up the active palette automatically. User `:hi
-- AutoFinderTodos*` overrides always win via `default = true`.
local HL = {
  empty           = "AutoFinderTodosEmpty",       -- "(no tasks)"
  help            = "AutoFinderTodosHelp",        -- "Try `a` to add ..."
  help_key        = "AutoFinderTodosHelpKey",     -- the `a` / `d` snippets
  header_open     = "AutoFinderTodosHeaderOpen",
  header_deferred = "AutoFinderTodosHeaderDeferred",
  header_completed= "AutoFinderTodosHeaderCompleted",
  header_archived = "AutoFinderTodosHeaderArchived",
  prefix_open     = "AutoFinderTodosPrefixOpen",     -- `[OPEN ]`
  prefix_deferred = "AutoFinderTodosPrefixDeferred", -- `[DEFER]`
  prefix_completed= "AutoFinderTodosPrefixCompleted",-- `[DONE ]`
  prefix_archived = "AutoFinderTodosPrefixArchived", -- `[ARCH ]`
  index           = "AutoFinderTodosIndex",      -- `1.` ordinal for OPEN
  id              = "AutoFinderTodosId",         -- the task id
  title           = "AutoFinderTodosTitle",      -- task title (rendered after the id)
  badge           = "AutoFinderTodosErrorBadge", -- the `⚠ N` errors marker
  due             = "AutoFinderTodosDue",        -- the `due:YYYY-MM-DD` annotation
  separator       = "AutoFinderTodosSeparator",  -- middle-dot between fields
}

local NS = vim.api.nvim_create_namespace("auto-finder.todos.hl")

local function _apply_default_highlights()
  -- Each link picks a near-universal group:
  --   • Title          — section headers
  --   • Directory      — task id (path-shaped)
  --   • Constant       — title text
  --   • Comment        — placeholder / help text
  --   • DiagnosticWarn — error badge + deferred status
  --   • DiagnosticOk   — completed
  --   • NonText        — archived
  --   • Number         — 1-based OPEN index
  --   • Special        — due date
  vim.api.nvim_set_hl(0, HL.empty,             { link = "Comment",        default = true })
  vim.api.nvim_set_hl(0, HL.help,              { link = "Comment",        default = true })
  vim.api.nvim_set_hl(0, HL.help_key,          { link = "Identifier",     default = true })
  vim.api.nvim_set_hl(0, HL.header_open,       { link = "Title",          default = true })
  vim.api.nvim_set_hl(0, HL.header_deferred,   { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, HL.header_completed,  { link = "DiagnosticOk",   default = true })
  vim.api.nvim_set_hl(0, HL.header_archived,   { link = "NonText",        default = true })
  vim.api.nvim_set_hl(0, HL.prefix_open,       { link = "Function",       default = true })
  vim.api.nvim_set_hl(0, HL.prefix_deferred,   { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, HL.prefix_completed,  { link = "DiagnosticOk",   default = true })
  vim.api.nvim_set_hl(0, HL.prefix_archived,   { link = "NonText",        default = true })
  vim.api.nvim_set_hl(0, HL.index,             { link = "Number",         default = true })
  vim.api.nvim_set_hl(0, HL.id,                { link = "Directory",      default = true })
  vim.api.nvim_set_hl(0, HL.title,             { link = "Constant",       default = true })
  vim.api.nvim_set_hl(0, HL.badge,             { link = "DiagnosticError",default = true })
  vim.api.nvim_set_hl(0, HL.due,               { link = "Special",        default = true })
  vim.api.nvim_set_hl(0, HL.separator,         { link = "NonText",        default = true })
end

-- Apply at module load; re-apply on ColorScheme so links survive
-- theme swaps. One-shot augroup mirrors the marks-view pattern.
_apply_default_highlights()
do
  local group = vim.api.nvim_create_augroup("auto-finder.todos.hl", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = _apply_default_highlights,
    desc = "auto-finder.todos: re-apply default highlight links",
  })
end

-- Maps the schema status enum to {prefix, header_hl, prefix_hl}.
local BUCKETS = {
  open      = { prefix = "OPEN ", header = "Open",      hl_prefix = HL.prefix_open,      hl_header = HL.header_open      },
  deferred  = { prefix = "DEFER", header = "Deferred",  hl_prefix = HL.prefix_deferred,  hl_header = HL.header_deferred  },
  completed = { prefix = "DONE ", header = "Completed", hl_prefix = HL.prefix_completed, hl_header = HL.header_completed },
  archived  = { prefix = "ARCH ", header = "Archived",  hl_prefix = HL.prefix_archived,  hl_header = HL.header_archived  },
}

-- Bucket render order — open at the top so OPEN tasks (the
-- numbered ones) are immediately visible without scrolling.
local BUCKET_ORDER = { "open", "deferred", "completed", "archived" }

-- Per-buffer row metadata: array of `{ id, status, errors_count, file_path?, lnum }`,
-- in render order. Used by the keymap layer to figure out "what
-- task is under the cursor". Populated by _render().
M._rows = nil

---Return the row metadata entry under the cursor in the panel
---window. Returns nil for the visual cursor sitting on a header,
---blank line, or any non-task row.
---@param panel_winid integer
---@return table?
local function _row_under_cursor(panel_winid)
  if not (M._rows and panel_winid and vim.api.nvim_win_is_valid(panel_winid)) then
    return nil
  end
  local pos = vim.api.nvim_win_get_cursor(panel_winid)
  local lnum = pos[1]
  for _, row in ipairs(M._rows) do
    if row.lnum == lnum then return row end
  end
  return nil
end

-- ─── render ───────────────────────────────────────────────────

-- Layout constants (kept module-local so tests + later phases can
-- pin against them).
local PREFIX_WIDTH = 7  -- `[OPEN ]`, `[DEFER]`, `[DONE ]`, `[ARCH ]`
local INDEX_WIDTH  = 4  -- `NN. ` for OPEN; `    ` (spaces) for others

---Collect tasks via the auto-core.todo public surface, grouped by
---bucket per BUCKET_ORDER. Within each bucket: tasks with non-empty
---errors[] float to the top; both groups are then sorted by id
---(lex = chronological because ids are `<YYYY-MM-DD>-<slug>`).
---@return table<string, table[]> grouped  bucket → list of tasks
local function _collect_grouped()
  local grouped = { open = {}, deferred = {}, completed = {}, archived = {} }
  local todo_ok, todo = pcall(require, "auto-core.todo")
  if not todo_ok then return grouped end
  local list_ok, tasks = pcall(todo.list)
  if not list_ok or type(tasks) ~= "table" then return grouped end

  for _, t in ipairs(tasks) do
    if type(t) == "table" and BUCKETS[t.status] then
      table.insert(grouped[t.status], t)
    end
  end

  local function sort_bucket(b)
    table.sort(b, function(a, c)
      local aerr = type(a.errors) == "table" and #a.errors > 0
      local cerr = type(c.errors) == "table" and #c.errors > 0
      if aerr ~= cerr then return aerr end          -- errors-to-top
      return (a.id or "") < (c.id or "")            -- chronological by id
    end)
  end
  for _, name in ipairs(BUCKET_ORDER) do sort_bucket(grouped[name]) end
  return grouped
end

---Set a highlight via extmark on a byte range of a single line.
---Coordinates are 0-based.
---@param bufnr integer
---@param lnum integer  0-based line number
---@param col_start integer
---@param col_end integer
---@param hl string
local function _hl(bufnr, lnum, col_start, col_end, hl)
  vim.api.nvim_buf_set_extmark(bufnr, NS, lnum, col_start, {
    end_col      = col_end,
    hl_group     = hl,
    priority     = 110,
  })
end

---Render the full body into `bufnr`. Idempotent — safe to call
---repeatedly without clearing manually. Populates M._rows with one
---entry per visible task row so the keymap layer can resolve "what
---task is under the cursor."
---@param bufnr integer
local function _render(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return end

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

  local grouped = _collect_grouped()
  local rows    = {}     -- accumulating M._rows
  local lines   = {}     -- text lines we'll buf_set after the loop
  local marks   = {}     -- deferred extmarks { lnum0, col_s, col_e, hl }

  -- Helper to add an extmark in the deferred queue.
  local function mark(lnum0, col_s, col_e, hl)
    marks[#marks + 1] = { lnum0, col_s, col_e, hl }
  end

  -- Header line: blank separator + `<Label> (<count>)`.
  local function emit_header(bucket_name, count)
    local cfg = BUCKETS[bucket_name]
    if #lines > 0 then lines[#lines + 1] = "" end       -- blank separator
    local label = cfg.header .. " (" .. count .. ")"
    lines[#lines + 1] = label
    mark(#lines - 1, 0, #label, cfg.hl_header)
  end

  -- Row line per task. `idx` is the 1-based ordinal (OPEN only; nil
  -- otherwise). Returns the new line number after appending.
  local function emit_task(bucket_name, task, idx)
    local cfg   = BUCKETS[bucket_name]
    local parts = {}

    -- 1. `[XXXXX]` status prefix (always exactly PREFIX_WIDTH chars).
    parts[#parts + 1] = "[" .. cfg.prefix .. "]"

    -- 2. Two spaces then either `NN. ` or `    ` (INDEX_WIDTH).
    parts[#parts + 1] = "  "
    if idx then
      parts[#parts + 1] = string.format("%2d. ", idx)
    else
      parts[#parts + 1] = string.rep(" ", INDEX_WIDTH)
    end

    -- 3. Title (always present — schema requires it).
    parts[#parts + 1] = tostring(task.title or "(untitled)")

    -- 4. Inline annotations (errors badge first, then due).
    local err_count = type(task.errors) == "table" and #task.errors or 0
    if err_count > 0 then
      parts[#parts + 1] = "  ⚠ " .. err_count
    end
    if type(task.due) == "string" and task.due ~= "" then
      parts[#parts + 1] = "  due:" .. task.due
    end

    -- 5. The id in parens at the end as a stable reference.
    parts[#parts + 1] = "  (" .. tostring(task.id or "?") .. ")"

    local line = table.concat(parts)
    lines[#lines + 1] = line
    local lnum0 = #lines - 1

    -- Now figure out byte spans for highlighting. Reconstruct
    -- cursor by walking `parts` in order; this is robust to any
    -- future re-ordering as long as we update the walker too.
    local cursor = 0
    -- Prefix
    do
      local len = #parts[1]
      mark(lnum0, cursor, cursor + len, cfg.hl_prefix)
      cursor = cursor + len
    end
    -- Two-space pad
    cursor = cursor + #parts[2]
    -- Index segment (only highlight for OPEN where it's content)
    do
      local len = #parts[3]
      if idx then
        mark(lnum0, cursor, cursor + len, HL.index)
      end
      cursor = cursor + len
    end
    -- Title
    do
      local len = #parts[4]
      mark(lnum0, cursor, cursor + len, HL.title)
      cursor = cursor + len
    end
    -- Optional badge / due / id annotations (walked dynamically)
    local i = 5
    if err_count > 0 then
      local len = #parts[i]
      mark(lnum0, cursor, cursor + len, HL.badge)
      cursor = cursor + len
      i = i + 1
    end
    if type(task.due) == "string" and task.due ~= "" then
      local len = #parts[i]
      mark(lnum0, cursor, cursor + len, HL.due)
      cursor = cursor + len
      i = i + 1
    end
    -- The trailing `  (<id>)` — the id portion in Directory color.
    do
      local segment = parts[i]
      -- Highlight just the id inside the parens (skip the `  (` and the trailing `)`).
      local inner_start = cursor + 3                  -- after "  ("
      local inner_end   = cursor + #segment - 1       -- before the trailing ")"
      mark(lnum0, inner_start, inner_end, HL.id)
      cursor = cursor + #segment
    end

    rows[#rows + 1] = {
      id           = task.id,
      status       = task.status,
      errors_count = err_count,
      lnum         = lnum0 + 1,    -- 1-based for cursor comparison
      task         = task,
    }
  end

  -- Walk buckets in display order. The 1-based index is OPEN-only
  -- (matches the auto-agents numbered surface per ADR-0031 §5).
  local total = 0
  for _, name in ipairs(BUCKET_ORDER) do
    local bucket = grouped[name] or {}
    if #bucket > 0 then
      emit_header(name, #bucket)
      if name == "open" then
        for i, t in ipairs(bucket) do emit_task(name, t, i) end
      else
        for _, t in ipairs(bucket) do emit_task(name, t, nil) end
      end
      total = total + #bucket
    end
  end

  -- Empty-state UX: no tasks anywhere.
  if total == 0 then
    lines[#lines + 1] = "(no tasks in this workspace's .todo-list/)"
    mark(#lines - 1, 0, #lines[#lines], HL.empty)
    lines[#lines + 1] = ""
    local help = "Press `a` to add the first task."
    lines[#lines + 1] = help
    mark(#lines - 1, 0, #help, HL.help)
    -- Pick out the `a` so it's visually distinct.
    local key_col_s = help:find("`a`", 1, true)
    if key_col_s then
      mark(#lines - 1, key_col_s - 1, key_col_s + 2, HL.help_key)
    end
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  for _, mk in ipairs(marks) do
    _hl(bufnr, mk[1], mk[2], mk[3], mk[4])
  end
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified   = false
  M._rows = rows
end

-- ─── public — section descriptor lifecycle ────────────────────

function M.get_buffer(panel_winid)
  if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
    return M._bufnr
  end
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = "hide"
  vim.bo[b].buftype   = "nofile"
  vim.bo[b].swapfile  = false
  vim.bo[b].filetype  = FILETYPE
  vim.b[b].auto_finder_view = "todos"
  pcall(vim.api.nvim_buf_set_name, b, "auto-finder://todos")
  _render(b)
  M._bufnr = b
  return b
end

function M.on_focus(panel_winid, bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  _render(bufnr)
end

function M.on_close()
  if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
    pcall(vim.api.nvim_buf_delete, M._bufnr, { force = true })
  end
  M._bufnr = nil
  M._rows  = nil
end

-- Test-only — production code never calls this.
function M._reset_for_tests()
  M.on_close()
end

-- Module-private constants exposed for tests + later phase layers
-- (keymaps, subscriptions) without re-exporting the entire surface.
M._HL           = HL
M._NS           = NS
M._BUCKETS      = BUCKETS
M._BUCKET_ORDER = BUCKET_ORDER
M._row_under_cursor = _row_under_cursor

return M
