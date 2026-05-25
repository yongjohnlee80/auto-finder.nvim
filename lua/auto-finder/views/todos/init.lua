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
---Buffer-local keymaps:
---  <CR>  open the task's .md file via the editor-window resolver
---  i     floating preview (title / status / priority / assignee /
---        due / description; + errors section when non-empty)
---  a     prompt for title, add task, open file
---  d     remove task (with confirmation)
---  s     cycle status (open → completed → deferred → open)
---  R     manual refresh (auto-core.todo.refresh + re-render)
---  M     migrate `.todo-list/` to a new location (filesystem
---        rename + update auto-core's per-workspace dir override)
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

-- Maps the schema status enum to {header label, header highlight}.
-- v0.2.36 (Phase 2 polish): per-row `[XXXXX]` status prefix was
-- removed because the section header already groups tasks by status.
local BUCKETS = {
  open      = { header = "Open",      hl_header = HL.header_open      },
  deferred  = { header = "Deferred",  hl_header = HL.header_deferred  },
  completed = { header = "Completed", hl_header = HL.header_completed },
  archived  = { header = "Archived",  hl_header = HL.header_archived  },
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
-- pin against them). The status prefix that used to be `[XXXXX]`
-- was removed in v0.2.36 — bucket headers carry the status.
local LEADER_WIDTH  = 6  -- `  NN. ` for OPEN; `      ` (6 spaces) for others
                        -- — both put the title's first char at column 7.

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
    local parts = {}

    -- 1. Leader: either `  NN. ` (OPEN ordinal) or 6 spaces
    --    (non-OPEN buckets). Both put the title at column 7.
    if idx then
      parts[#parts + 1] = string.format("  %2d. ", idx)
    else
      parts[#parts + 1] = string.rep(" ", LEADER_WIDTH)
    end

    -- 2. Title (always present — schema requires it).
    parts[#parts + 1] = tostring(task.title or "(untitled)")

    -- 3. Inline annotations (errors badge first, then due).
    local err_count = type(task.errors) == "table" and #task.errors or 0
    if err_count > 0 then
      parts[#parts + 1] = "  ⚠ " .. err_count
    end
    if type(task.due) == "string" and task.due ~= "" then
      parts[#parts + 1] = "  due:" .. task.due
    end

    -- 4. The id in parens at the end as a stable reference.
    parts[#parts + 1] = "  (" .. tostring(task.id or "?") .. ")"

    local line = table.concat(parts)
    lines[#lines + 1] = line
    local lnum0 = #lines - 1

    -- Highlight byte spans. Walk `parts` in order so any future
    -- reorder stays in sync with the cursor advance.
    local cursor = 0
    -- Leader: highlight just the `NN.` part for OPEN; non-OPEN
    -- leader is pure whitespace so no highlight needed.
    do
      local len = #parts[1]
      if idx then
        -- Skip leading 2 spaces, mark `NN.`, skip trailing space.
        mark(lnum0, cursor + 2, cursor + len - 1, HL.index)
      end
      cursor = cursor + len
    end
    -- Title
    do
      local len = #parts[2]
      mark(lnum0, cursor, cursor + len, HL.title)
      cursor = cursor + len
    end
    -- Optional badge / due / id annotations (walked dynamically)
    local i = 3
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
      local inner_start = cursor + 3              -- after "  ("
      local inner_end   = cursor + #segment - 1   -- before trailing ")"
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

-- ─── keymap helpers ───────────────────────────────────────────

---Resolve the absolute filesystem path for a task. Uses
---auto-core.todo.paths + the task's status / archived_at so the
---path is correct for any bucket including archived/YYYY/MM/.
---@param task table
---@return string?
local function _task_file_path(task)
  local ok_paths, paths = pcall(require, "auto-core.todo.paths")
  local ok_todo,  todo  = pcall(require, "auto-core.todo")
  if not (ok_paths and ok_todo and task and task.id and task.status) then
    return nil
  end
  local td = todo.get_todo_dir()
  return paths.task_file_path(td, task.id, task.status, task.archived_at)
end

---`<CR>` action: open the task file in the editor target window
---(NOT the panel itself). Mirrors the marks-view `_jump` pattern.
---@param row table?    M._rows entry under the cursor
local function _open_task(row)
  if not row then return end
  local path = _task_file_path(row.task)
  if not path then return end
  local af = require("auto-finder")
  local target = af._editor_target_winid()
  if not target then
    pcall(vim.cmd, "rightbelow vsplit " .. vim.fn.fnameescape(path))
    target = vim.api.nvim_get_current_win()
  else
    pcall(vim.api.nvim_set_current_win, target)
    pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
  end
end

---`i` action: floating preview modal showing the task's structured
---fields + description body + errors (if any). `q` / `<Esc>` close.
---@param row table?
local function _preview_task(row)
  if not row or not row.task then return end
  local t = row.task

  local lines = {}
  local function add(label, value)
    lines[#lines + 1] = string.format("  %-12s %s", label, value)
  end
  add("Title",    t.title or "(untitled)")
  add("Status",   t.status or "?")
  add("Id",       t.id or "?")
  if t.priority then add("Priority", t.priority) end
  if t.assignee then add("Assignee", t.assignee) end
  if t.due      then add("Due",      t.due)      end
  if t.completed_at then add("Completed", t.completed_at) end
  if t.archived_at  then add("Archived",  t.archived_at)  end
  if type(t.tags) == "table" and #t.tags > 0 then
    add("Tags", table.concat(t.tags, ", "))
  end

  if type(t.description) == "string" and t.description ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  Description"
    for line in (t.description .. "\n"):gmatch("([^\n]*)\n") do
      lines[#lines + 1] = "    " .. line
    end
  end

  if type(t.errors) == "table" and #t.errors > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  Errors"
    for i, e in ipairs(t.errors) do
      lines[#lines + 1] = string.format("    [%d] %s — %s (%s, detected %s)",
        i, e.field or "?", e.message or "?", e.code or "?", e.detected or "?")
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "  (q / <Esc> to close)"

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].swapfile  = false
  vim.bo[buf].filetype  = "auto-finder-todos-info"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local max_w = 0
  for _, l in ipairs(lines) do if #l > max_w then max_w = #l end end
  local width  = math.min(max_w + 2, math.max(80, vim.o.columns - 8))
  local height = math.min(#lines, math.max(10, vim.o.lines - 6))

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "cursor",
    row       = 1,
    col       = 0,
    width     = width,
    height    = height,
    style     = "minimal",
    border    = "rounded",
    title     = " task info ",
    title_pos = "left",
  })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, key in ipairs({ "q", "<Esc>" }) do
    pcall(vim.keymap.set, "n", key, close, {
      buffer = buf, silent = true, nowait = true,
      desc = "auto-finder.todos: dismiss preview",
    })
  end
end

---`a` action: prompt for a title; on non-empty, create a task via
---auto-core.todo.add and open its file in the editor target.
local function _add_task()
  local ok_todo, todo = pcall(require, "auto-core.todo")
  if not ok_todo then return end
  vim.ui.input({ prompt = "New todo title: " }, function(input)
    if not input or input == "" then return end
    local ok, id_or_err = pcall(todo.add, { title = input })
    if not ok then
      -- log.error auto-toasts at ERROR level + writes the ring entry
    -- (auto-core.log dispatch routes ERROR/WARN through should_toast
    -- by default). One call, both surfaces.
    require("auto-finder.log").error("view.todos",
        "add failed: " .. tostring(id_or_err))
      return
    end
    -- Open the new file via the editor-window resolver. Build a
    -- synthetic row for _open_task.
    local task = todo.get(id_or_err)
    if task then
      _open_task({ task = task })
    end
    -- Re-render the panel buffer (we own M._bufnr).
    if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
      _render(M._bufnr)
    end
  end)
end

---`d` action: confirm + remove the task under the cursor.
---@param row table?
local function _remove_task(row)
  if not row or not row.task then return end
  local ok_todo, todo = pcall(require, "auto-core.todo")
  if not ok_todo then return end
  local choice = vim.fn.confirm(
    "Remove task '" .. (row.task.title or row.task.id or "?") .. "'?",
    "&Yes\n&No", 2)
  if choice ~= 1 then return end
  local ok, err = pcall(todo.remove, row.task.id)
  if not ok or not err then
    if err and err ~= true then
      require("auto-finder.log").error("view.todos",
        "remove failed: " .. tostring(err))
    end
  end
  if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
    _render(M._bufnr)
  end
end

-- Status cycle for the `s` key. Skips archived because it's a
-- terminal-ish state — explicit archive lives behind the auto-core
-- API for the rare manual case.
local STATUS_CYCLE = {
  open      = "completed",
  completed = "deferred",
  deferred  = "open",
  archived  = "open",  -- archived → open re-opens the task
}

---`s` action: cycle status via auto-core.todo.status (the API path
---that fires side-effect events).
---@param row table?
local function _cycle_status(row)
  if not row or not row.task then return end
  local ok_todo, todo = pcall(require, "auto-core.todo")
  if not ok_todo then return end
  local next_status = STATUS_CYCLE[row.task.status] or "open"
  local ok, err = pcall(todo.status, row.task.id, next_status)
  if not ok then
    require("auto-finder.log").error("view.todos",
      "status failed: " .. tostring(err))
    return
  end
  if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
    _render(M._bufnr)
  end
end

---`R` action: full refresh via auto-core.todo.refresh, then
---re-render the panel.
---@param bufnr integer
local function _refresh(bufnr)
  local ok_todo, todo = pcall(require, "auto-core.todo")
  if ok_todo then pcall(todo.refresh) end
  _render(bufnr)
end

---`M` action: migrate the `.todo-list/` directory to a new location
---and re-point auto-core's per-workspace override at it. Atomic at
---the filesystem level (uses `vim.uv.fs_rename`) — refuses to
---clobber an existing target. When the current todo dir doesn't
---exist on disk yet (no tasks created), the migration is just a
---`set_todo_dir` — no filesystem move needed.
local function _migrate_dir()
  local ok_todo, todo = pcall(require, "auto-core.todo")
  if not ok_todo then return end
  local ok_path, fs_path = pcall(require, "auto-core.fs.path")
  if not ok_path then return end

  local current = todo.get_todo_dir()
  vim.ui.input({
    prompt     = "Migrate .todo-list/ to: ",
    default    = current,
    completion = "dir",
  }, function(input)
    if not input or input == "" then return end
    -- Expand `~`, normalize trailing slash.
    local new_path = vim.fn.fnamemodify(vim.fn.expand(input), ":p")
      :gsub("/+$", "")
    if new_path == "" or new_path == current then return end

    local current_exists = fs_path.is_dir(current)
    local target_exists  = fs_path.exists(new_path)

    -- Refuse to clobber an existing target — the user can
    -- consolidate manually then re-run, or pick a fresh path.
    if target_exists and current_exists then
      require("auto-finder.log").error("view.todos",
        "migrate: target '" .. new_path .. "' already exists — "
        .. "refusing to overwrite. Move/merge manually then `M` again.")
      return
    end

    local choice = vim.fn.confirm(
      string.format(
        current_exists
          and "Move\n   %s\n → %s\n\nThe per-workspace override will be updated."
          or  "No tasks to move (%s does not exist).\nSet the per-workspace override to:\n   %s",
        current, new_path),
      "&Yes\n&No", 2)
    if choice ~= 1 then return end

    -- Ensure target's parent dir exists so fs_rename can place it.
    local parent = fs_path.parent(new_path)
    if not fs_path.is_dir(parent) then
      local mkok, mkerr = pcall(vim.fn.mkdir, parent, "p")
      if not mkok then
        require("auto-finder.log").error("view.todos",
          "migrate: could not create parent '" .. parent
          .. "': " .. tostring(mkerr))
        return
      end
    end

    -- Move the directory atomically. Skipped when there's nothing
    -- to move (current dir doesn't exist on disk yet).
    if current_exists then
      local ok, err = vim.uv.fs_rename(current, new_path)
      if not ok then
        require("auto-finder.log").error("view.todos",
          "migrate: rename failed: " .. tostring(err)
          .. "\n(cross-filesystem moves need a manual copy+delete)")
        return
      end
    end

    -- Update auto-core's per-workspace override so future calls
    -- resolve to the new location.
    todo.set_todo_dir(new_path)

    -- Success path — INFO toast (notify=true so it always toasts;
    -- INFO normally wouldn't per the default should_toast rule, but
    -- the user explicitly invoked `M` and deserves visible confirmation).
    require("auto-finder.log").notify(
      "auto-finder.todos: migrated to " .. new_path,
      { component = "view.todos", level = "info", notify = true })
    if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
      _render(M._bufnr)
    end
  end)
end

---Apply buffer-local keymaps. All `nowait` so single-key bindings
---fire immediately even when nvim would otherwise wait for a
---potential multi-key sequence.
---@param bufnr integer
---@param panel_winid integer
local function _apply_keymaps(bufnr, panel_winid)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local set = function(lhs, fn, desc)
    pcall(vim.keymap.set, "n", lhs, fn, {
      buffer = bufnr, silent = true, nowait = true, desc = desc,
    })
  end
  set("<CR>", function() _open_task(_row_under_cursor(panel_winid)) end,
    "auto-finder.todos: open task .md file")
  set("i", function() _preview_task(_row_under_cursor(panel_winid)) end,
    "auto-finder.todos: preview (popup)")
  set("a", _add_task,
    "auto-finder.todos: add new task (prompt for title)")
  set("d", function() _remove_task(_row_under_cursor(panel_winid)) end,
    "auto-finder.todos: remove task (with confirmation)")
  set("s", function() _cycle_status(_row_under_cursor(panel_winid)) end,
    "auto-finder.todos: cycle status (open → completed → deferred → open)")
  set("R", function() _refresh(bufnr) end,
    "auto-finder.todos: refresh (auto-core.todo.refresh + re-render)")
  set("M", _migrate_dir,
    "auto-finder.todos: migrate .todo-list/ to a new location")

  -- `?` opens the help overlay listing every keymap on this buffer
  -- (auto-finder.shared.neotree.install_help_keymap walks the
  -- buffer's keymaps via nvim_buf_get_keymap and floats them in the
  -- canonical auto-finder help overlay — same UX as the files /
  -- buffers / repos views).
  local ok_help, neotree_shared = pcall(require, "auto-finder.shared.neotree")
  if ok_help and type(neotree_shared.install_help_keymap) == "function" then
    neotree_shared.install_help_keymap("todos", bufnr)
  end
end

-- ─── auto-refresh subscriptions ───────────────────────────────

-- Captured auto-core.events handles for our two subscriptions:
--   core.todo.status:changed
--   core.todo:refreshed
-- Singleton — set on first get_buffer / on_focus, cleared on
-- on_close. The dedup is so a slot that re-focuses N times
-- doesn't accumulate N callbacks per topic.
M._subs = nil

---Re-render iff the panel buffer is currently visible in some
---window. Hidden-panel renders are wasted work — `on_focus` will
---refresh us when the slot becomes active again.
---
---**No-hijack invariant (important):** this handler MUST NOT
---change window focus, switch the current buffer in any window,
---open a floating/split window, or move the cursor in a window
---outside our own panel buffer. `_render` only mutates `M._bufnr`
---via `nvim_buf_set_lines` + `nvim_buf_set_extmark` + buffer
---options on the SAME buffer — all buffer-scoped, no window-
---scoped side effects. The user's current window stays exactly
---where it is regardless of what other panel is active.
---
---User-initiated paths (`<CR>` open / `a` add / `M` migrate) DO
---change focus, but those are keymap-driven, not event-driven.
---@param reason string
local function _on_event(reason)
  if not (M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr)) then return end
  local wins = vim.fn.win_findbuf(M._bufnr)
  if #wins == 0 then return end
  -- Re-render on the next tick. Event publishers are often inside
  -- atomic write paths; defer so the render observes the final
  -- on-disk state and doesn't recurse into the publish chain.
  vim.schedule(function()
    if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
      pcall(_render, M._bufnr)
    end
  end)
end

---Subscribe to auto-core.todo lifecycle events. Idempotent — when
---subscriptions already exist this is a no-op so re-focusing the
---slot doesn't duplicate callbacks.
local function _ensure_subscriptions()
  if M._subs then return end
  local ok_ev, ev = pcall(require, "auto-core.events")
  if not (ok_ev and ev and type(ev.subscribe) == "function") then return end
  M._subs = {
    ev.subscribe("core.todo:refreshed",      function() _on_event("refresh") end),
    ev.subscribe("core.todo.status:changed", function() _on_event("status")  end),
  }
end

---Tear down subscriptions. Called from on_close so the next mount
---starts with a fresh handle set.
local function _dispose_subscriptions()
  if not M._subs then return end
  local ok_ev, ev = pcall(require, "auto-core.events")
  if ok_ev and ev and type(ev.unsubscribe) == "function" then
    for _, h in ipairs(M._subs) do pcall(ev.unsubscribe, h) end
  end
  M._subs = nil
end

-- ─── public — section descriptor lifecycle ────────────────────

function M.get_buffer(panel_winid)
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
  vim.b[b].auto_finder_view = "todos"
  pcall(vim.api.nvim_buf_set_name, b, "auto-finder://todos")
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
end

-- Module-private constants exposed for tests + later phase layers
-- (keymaps, subscriptions) without re-exporting the entire surface.
M._HL           = HL
M._NS           = NS
M._BUCKETS      = BUCKETS
M._BUCKET_ORDER = BUCKET_ORDER
M._row_under_cursor = _row_under_cursor

return M
