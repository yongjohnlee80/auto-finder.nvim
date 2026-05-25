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

-- ─── render (task 22 lands the full implementation) ───────────

---Render placeholder body. The full bucket renderer lands in task 22.
---@param bufnr integer
local function _render(bufnr)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "auto-finder.todos — scaffold (task 21).",
    "Full render lands in task 22.",
  })
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified   = false
  M._rows = {}
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
