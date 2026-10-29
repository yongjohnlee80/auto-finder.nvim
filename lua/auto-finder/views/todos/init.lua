---View — auto-core todo tasks (per-workspace `.todo-list/*.md`).
---
---Flat scratch-buffer list with its own renderer (same UX shape as
---`auto-finder.views.marks`). The panel never edits YAML frontmatter
---directly, and it writes nothing under a `.todo-list/`: AutoDoc's daemon owns
---the store and every write (ADR 1791532020). The panel calls its `todos.*`
---verbs itself, through autodoc.nvim (`views/todos/store.lua`); auto-core only
---says where this project's store is (auto-core.todo.where). Without AutoDoc
---the panel says "AutoDoc required": there is no Lua fallback.
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
---  <CR>  open the task's .md file (or, on an expanded frontmatter
---        path row, the referenced adr/review/blocked file)
---  i     floating preview (title / status / priority / assignee /
---        due / description; + errors section when non-empty)
---  a     prompt for title, add task, open file
---  d     remove task (with confirmation); on a malformed row, ask AutoDoc
---        to delete the file (todos.remove_malformed)
---  s     set status (open / in-progress / completed / deferred / archived)
---  o     toggle — task frontmatter expansion, or section/period
---        collapse when on a header (same as <CR> on a header)
---  R     manual refresh (todos.refresh + re-render)
---  M     migrate `.todo-list/` to a new location (AutoDoc moves the
---        store: todos.move_store; or switch only: todos.set_dir)
---  ?     help overlay listing every keymap on this buffer
---
---Auto-refresh (task 24):
---  - on slot focus (always)
---  - on `core.todo.status:changed`, `core.todo:changed` and
---    `core.todo:refreshed` (published by the panel's own writes, by
---    auto-agents' todos.* verbs and by auto-core's notifier)
---  A write names the `rev` the panel read: a task changed since (by an
---  agent, by hand) is refused as todos.stale and the panel reloads.
---  All event-driven re-renders are gated on the buffer being visible.
---@module 'auto-finder.views.todos'

local M = {
  name        = "todos",
  description = "auto-core todo tasks (per-workspace .todo-list/)",
}

local store = require("auto-finder.views.todos.store")

-- What the panel says when auto-core predates the todo cutover: it never
-- falls back to writing a task file itself (ADR 1791532020 §3 step 3).
M.NEEDS_AUTOCORE = "auto-finder.todos: " .. store.NEEDS_AUTOCORE

local FILETYPE = "auto-finder"

-- Highlight groups. Same default-link strategy as marks: pick
-- groups every colorscheme is expected to ship, so the panel
-- picks up the active palette automatically. User `:hi
-- AutoFinderTodos*` overrides always win via `default = true`.
local HL = {
  empty           = "AutoFinderTodosEmpty",       -- "(no tasks)"
  help            = "AutoFinderTodosHelp",        -- "Try `a` to add ..."
  help_key        = "AutoFinderTodosHelpKey",     -- the `a` / `d` snippets
  header_open        = "AutoFinderTodosHeaderOpen",
  header_in_progress = "AutoFinderTodosHeaderInProgress", -- ADR-0035 Phase 1
  header_deferred    = "AutoFinderTodosHeaderDeferred",
  header_completed   = "AutoFinderTodosHeaderCompleted",
  header_archived    = "AutoFinderTodosHeaderArchived",
  header_malformed   = "AutoFinderTodosHeaderMalformed", -- v0.2.38: malformed section
  malformed_filename = "AutoFinderTodosMalformedFilename",
  malformed_err      = "AutoFinderTodosMalformedErr",
  -- v0.2.39: Vars section
  header_vars        = "AutoFinderTodosHeaderVars",
  vars_name          = "AutoFinderTodosVarsName",
  vars_value         = "AutoFinderTodosVarsValue",
  vars_builtin_tag   = "AutoFinderTodosVarsBuiltinTag",
  vars_unset         = "AutoFinderTodosVarsUnset",
  -- v0.2.41: collapsible section UI
  chevron            = "AutoFinderTodosChevron",       -- the ▼/▶ glyph
  archive_period     = "AutoFinderTodosArchivePeriod", -- YYYY-MM sub-headers
  index           = "AutoFinderTodosIndex",      -- `1.` ordinal for OPEN
  id              = "AutoFinderTodosId",         -- the task id
  title           = "AutoFinderTodosTitle",      -- task title (rendered after the id)
  badge           = "AutoFinderTodosErrorBadge", -- the `⚠ N` errors marker
  due             = "AutoFinderTodosDue",        -- the `due:YYYY-MM-DD` annotation
  separator       = "AutoFinderTodosSeparator",  -- middle-dot between fields

  -- v0.2.36: inline frontmatter expansion (`o` toggle)
  fm_label        = "AutoFinderTodosFmLabel",    -- `priority:` field label
  fm_value        = "AutoFinderTodosFmValue",    -- the value
  fm_bullet       = "AutoFinderTodosFmBullet",   -- `·` for list items
  fm_path         = "AutoFinderTodosFmPath",     -- path-shaped values (adr/review/blocked target)
  fm_null         = "AutoFinderTodosFmNull",     -- `null` / `(none)` placeholders
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
  vim.api.nvim_set_hl(0, HL.header_open,         { link = "Title",          default = true })
  -- ADR-0035 Phase 1: in-progress reads as "active work" — `Statement`
  -- pulls a high-contrast accent color in most themes (kanagawa/tokyonight
  -- /catppuccin/everforest) without colliding with the OK/Warn/Error
  -- semantic palette the other buckets use.
  vim.api.nvim_set_hl(0, HL.header_in_progress,  { link = "Statement",      default = true })
  vim.api.nvim_set_hl(0, HL.header_deferred,     { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, HL.header_completed,    { link = "DiagnosticOk",   default = true })
  vim.api.nvim_set_hl(0, HL.header_archived,     { link = "NonText",        default = true })
  vim.api.nvim_set_hl(0, HL.header_malformed,  { link = "DiagnosticError",default = true })
  vim.api.nvim_set_hl(0, HL.malformed_filename,{ link = "Directory",      default = true })
  vim.api.nvim_set_hl(0, HL.malformed_err,     { link = "Comment",        default = true })
  vim.api.nvim_set_hl(0, HL.header_vars,       { link = "Title",          default = true })
  vim.api.nvim_set_hl(0, HL.vars_name,         { link = "Identifier",     default = true })
  vim.api.nvim_set_hl(0, HL.vars_value,        { link = "Directory",      default = true })
  vim.api.nvim_set_hl(0, HL.vars_builtin_tag,  { link = "Comment",        default = true })
  vim.api.nvim_set_hl(0, HL.vars_unset,        { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, HL.chevron,           { link = "NonText",        default = true })
  vim.api.nvim_set_hl(0, HL.archive_period,    { link = "Comment",        default = true })
  vim.api.nvim_set_hl(0, HL.index,             { link = "Number",         default = true })
  vim.api.nvim_set_hl(0, HL.id,                { link = "Directory",      default = true })
  vim.api.nvim_set_hl(0, HL.title,             { link = "Constant",       default = true })
  vim.api.nvim_set_hl(0, HL.badge,             { link = "DiagnosticError",default = true })
  vim.api.nvim_set_hl(0, HL.due,               { link = "Special",        default = true })
  vim.api.nvim_set_hl(0, HL.separator,         { link = "NonText",        default = true })
  vim.api.nvim_set_hl(0, HL.fm_label,          { link = "Identifier",     default = true })
  vim.api.nvim_set_hl(0, HL.fm_value,          { link = "Normal",         default = true })
  vim.api.nvim_set_hl(0, HL.fm_bullet,         { link = "NonText",        default = true })
  vim.api.nvim_set_hl(0, HL.fm_path,           { link = "Directory",      default = true })
  vim.api.nvim_set_hl(0, HL.fm_null,           { link = "Comment",        default = true })
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
-- ADR-0035 Phase 1: `in-progress` joins the enum. `automated` went with
-- automation (ADR 1791532020): AutoDoc lists a file that still uses it as
-- malformed.
local BUCKETS = {
  open            = { header = "Open",        hl_header = HL.header_open         },
  ["in-progress"] = { header = "In Progress", hl_header = HL.header_in_progress  },
  deferred        = { header = "Deferred",    hl_header = HL.header_deferred     },
  completed       = { header = "Completed",   hl_header = HL.header_completed    },
  archived        = { header = "Archived",    hl_header = HL.header_archived     },
}

-- Bucket render order — open at the top so OPEN tasks (the
-- numbered ones) are immediately visible without scrolling.
-- ADR-0035 §9: `In Progress` directly below `Open`, then the
-- deferred/completed/archived tail.
local BUCKET_ORDER = { "open", "in-progress", "deferred", "completed", "archived" }

-- Per-buffer row metadata: array of one of these shapes, in render order:
--   { kind="task",              id, status, errors_count, lnum, task }
--   { kind="frontmatter-field", lnum, task, field, filepath? }
--   { kind="malformed-task",    lnum, filepath, bucket, err }
--   { kind="vars-header",       lnum }                          -- v0.2.39
--   { kind="vars-entry",        lnum, name, value, builtin, doc, is_unset? }
--   { kind="bucket-header",     lnum, section }                 -- v0.2.41
--   { kind="archive-period",    lnum, period }   -- v0.2.41 "YYYY-MM" sub-header
-- The keymap layer reads `kind` to decide what action to take —
-- e.g. `<CR>` on a task row opens the task file; on a frontmatter-
-- field row WITH a filepath, opens that file instead; on a
-- malformed-task row, opens the broken file so the user can repair
-- the frontmatter. `s` / `o` / `d` no-op on malformed rows because
-- there is no validated task to mutate; `i` shows the parse error.
-- A bucket-header row carries `section` ∈ { "open", "deferred",
-- "completed", "archived", "malformed", "vars" }; `<CR>` on it
-- toggles the section's collapsed state.
M._rows = nil

-- Per-task expand state for the `o` toggle: M._expanded[task_id]
-- = true when the frontmatter is currently inlined under the task
-- row. Persists across re-renders (sticky expansion) so an event-
-- driven refresh doesn't collapse what the user just expanded.
M._expanded = {}

-- v0.2.41: per-section collapse state. Persisted via
-- `auto-core.state.namespace('todo.ui', {persist='json'})` under
-- the key `collapsed.<section>` so it survives nvim restarts —
-- "keep archived hidden" is a setup-once preference, not a
-- per-session toggle.
--
-- Default policy: Archived starts collapsed (rarely-needed by
-- design — completed-then-aged-out items live there). All other
-- sections start expanded. Users adjust by pressing <CR> on the
-- header; the next state.set persists immediately.
M._collapsed = {}

-- v0.2.41: archive year/month sub-sections. The archived bucket
-- groups its tasks by `archived_at[1..7]` (YYYY-MM) so users with
-- hundreds of archived tasks can navigate to a specific period
-- instead of scrolling a flat list. Each period is itself
-- collapsible — `M._archive_collapsed["2026-05"] = true/false`.
-- Default: all archive periods start COLLAPSED (Archived is a
-- searchable archive, not browsable by default).
M._archive_collapsed = {}
local DEFAULT_ARCHIVE_PERIOD_COLLAPSED = true

local DEFAULT_COLLAPSED = {
  open            = false,
  ["in-progress"] = false,  -- ADR-0035: active work — keep visible
  deferred        = false,
  completed       = false,
  archived        = true,   -- collapsed by default — see policy note above
  malformed       = false,  -- broken files should be impossible to miss
  vars            = false,
}

---Lazy state-namespace handle for the panel's collapse state.
---Soft-fail when auto-core.state isn't available (e.g. headless
---test runs without the plugin loaded) — collapse state then
---behaves as in-memory only.
local _ui_state = nil
local function _get_ui_state()
  if _ui_state ~= nil then return _ui_state end
  local ok, mod = pcall(require, "auto-core.state")
  if not ok or type(mod) ~= "table" or type(mod.namespace) ~= "function" then
    _ui_state = false
    return nil
  end
  _ui_state = mod.namespace("todo.ui", { persist = "json" })
  return _ui_state
end

---Hydrate M._collapsed + M._archive_collapsed from persistent
---state (idempotent). Called from get_buffer so the first
---render sees the user's persisted preferences.
local function _hydrate_collapsed()
  local s = _get_ui_state()
  -- Section-level (top-level buckets + vars + malformed)
  local stored = s and s:get("collapsed") or {}
  if type(stored) ~= "table" then stored = {} end
  for k, v in pairs(DEFAULT_COLLAPSED) do
    if stored[k] ~= nil then
      M._collapsed[k] = stored[k] == true
    elseif M._collapsed[k] == nil then
      M._collapsed[k] = v
    end
  end
  -- Archive-period state (nested under archived)
  local periods = s and s:get("archive_periods") or {}
  if type(periods) ~= "table" then periods = {} end
  for k, v in pairs(periods) do
    if type(k) == "string" and v ~= nil then
      M._archive_collapsed[k] = v == true
    end
  end
end

---Toggle the collapsed state of a section and persist.
---@param section string
local function _toggle_collapsed(section)
  if type(section) ~= "string" or section == "" then return end
  M._collapsed[section] = not M._collapsed[section]
  local s = _get_ui_state()
  if s then
    local stored = s:get("collapsed") or {}
    if type(stored) ~= "table" then stored = {} end
    stored[section] = M._collapsed[section]
    s:set("collapsed", stored)
  end
end

---Toggle the collapsed state of an archive period and persist.
---@param period string  YYYY-MM
local function _toggle_archive_period(period)
  if type(period) ~= "string" or period == "" then return end
  local current = M._archive_collapsed[period]
  if current == nil then current = DEFAULT_ARCHIVE_PERIOD_COLLAPSED end
  M._archive_collapsed[period] = not current
  local s = _get_ui_state()
  if s then
    local stored = s:get("archive_periods") or {}
    if type(stored) ~= "table" then stored = {} end
    stored[period] = M._archive_collapsed[period]
    s:set("archive_periods", stored)
  end
end

---Return whether an archive period is currently collapsed,
---honoring the default-collapsed policy when no explicit
---preference is recorded.
---@param period string
---@return boolean
local function _archive_period_collapsed(period)
  local v = M._archive_collapsed[period]
  if v == nil then return DEFAULT_ARCHIVE_PERIOD_COLLAPSED end
  return v == true
end

---Return the row metadata entry under the cursor in the panel
---window. Returns nil for the visual cursor sitting on a header,
---blank line, or any non-task row.
---@param panel_winid integer
---@return table?
local function _row_under_cursor(panel_winid)
  if not (M._rows and panel_winid and vim.api.nvim_win_is_valid(panel_winid)) then
    return nil
  end
  if M._rows_dir ~= store.dir() then return nil end
  local pos = vim.api.nvim_win_get_cursor(panel_winid)
  local lnum = pos[1]
  for _, row in ipairs(M._rows) do
    if row.lnum == lnum then return row end
  end
  return nil
end

-- ─── path resolvers (used by the inline-expansion + <CR>) ──────

---The `{ from = path }` auto-core's variables are read with (auto-core v0.5.0, ADR 1792132105
---§2.5): the variables of the workspace that owns path, which the daemon names. Only the Vars
---section passes one, the store's directory, to name that workspace: everything else here reads
---the session store's table, the same one, as the panel shows only the session's store and every
---task of it shares its owner. nil reads the session store's (auto-core before v0.5.0 ignores it).
---@param path string?
---@return table?
local function _from(path)
  if type(path) ~= "string" or path == "" then return nil end
  return { from = path }
end

---The directory of the store the panel last loaded, whose owning workspace the Vars section
---names. nil before a load.
---@return string?
local function _store_dir()
  local s = M._snapshot
  return s and s.ctx and s.ctx.store or nil
end

-- where a variable's value comes from (a row's source, AutoDoc's workspace.vars): the short tag a
-- Vars row carries, and the preview's words. "store" is "kb" on a session below protocol 24.
local _VAR_TAG = { machine = "machine", kb = "kb", store = "kb", global = "global", env = "env" }
local _VAR_FROM = {
  machine = "this machine's value",
  kb      = "the KB's .autodoc-vars.toml (relative to the KB root, carried by git)",
  store   = "the KB's .autodoc-vars.toml (relative to the KB root, carried by git)",
  global  = "AutoDoc's global variables",
  env     = "the environment",
  derived = "derived for this workspace on this machine",
}

---Resolve the KB root for KB-relative reference fields (adr / review),
---through auto-core's one resolver (`$KB_ROOT`, which is `auto-core.kb`'s
---root from auto-core v0.3.0), so the panel computes the same path the
---validator does. A private copy here read the env vars in another order
---(WRITE first, the order auto-core dropped for producing `shared/shared`
---paths) and could disagree with it.
---@return string?  absolute KB root, or nil when none resolves
local function _kb_root()
  local ok, vars = pcall(require, "auto-core.todo.vars")
  if not ok then return nil end
  local okv, root = pcall(vars.get, "KB_ROOT")
  if not okv or type(root) ~= "string" or root == "" then return nil end
  return (vim.fn.fnamemodify(vim.fn.expand(root), ":p"):gsub("/$", ""))
end

---The absolute path of the task a `blocked[i]` id names, from the tasks the
---panel last loaded (every bucket, the archive included). nil when no such task
---is loaded: the daemon flags that case in the task's `errors[]`.
---@param blocked_id string
---@return string?
local function _blocked_task_path(blocked_id)
  if type(blocked_id) ~= "string" or blocked_id == "" then return nil end
  local t = M._by_id and M._by_id[blocked_id]
  return t and t.file_path or nil
end

---Resolve a reference string (an `adr:` / `review:` value) into an
---absolute filesystem path:
---
---  1. `$VAR/...` — auto-core.todo.vars substitutes it. An unresolved
---     variable comes back as its literal text, so the open fails
---     visibly naming the variable rather than guessing a path.
---  2. Absolute (`/…` or `~/…`) — expanded and used as is.
---  3. Relative — the store's KB root, `<KB_ROOT>/<rel>`, only (D2,
---     ADR 1791532020 §2.3: one rule, the one the daemon's validator
---     uses). The old KB → workspace → cwd fallback is gone: a path the
---     daemon flags as not-found must not open some other file here.
---@param ref string
---@return string?  absolute path, or nil for invalid input or no KB root
local function _resolve_ref_path(ref)
  if type(ref) ~= "string" or ref == "" then return nil end

  local ok_vars, vars = pcall(require, "auto-core.todo.vars")
  if ok_vars and type(vars.resolve_path) == "function" then
    local r = vars.resolve_path(ref)
    if r.unresolved then
      return r.path  -- the literal $VAR/... so the editor surfaces a clear error
    end
    if r.ok and r.path and (r.var_name or r.path:sub(1, 1) == "/") then
      return r.path
    end
  end

  if ref:sub(1, 1) == "/" or ref:sub(1, 1) == "~" then
    return vim.fn.expand(ref)
  end

  local kb = _kb_root()
  if not kb then return nil end
  return kb:gsub("/+$", "") .. "/" .. ref:gsub("^/+", "")
end

-- ─── render ───────────────────────────────────────────────────

-- Layout constants (kept module-local so tests + later phases can
-- pin against them). The status prefix that used to be `[XXXXX]`
-- was removed in v0.2.36 — bucket headers carry the status.
local LEADER_WIDTH  = 6  -- `  NN. ` for OPEN; `      ` (6 spaces) for others
                        -- — both put the title's first char at column 7.

---Group the loaded tasks by bucket per BUCKET_ORDER. Within each bucket: tasks
---with non-empty errors[] float to the top; both groups are then sorted by id
---(lex = chronological because ids are `<YYYY-MM-DD>-<slug>`).
---
---The tasks come from the panel's last load (`store.load`, the daemon's
---`todos.list`). Rendering never asks the daemon: a toggle or an expansion
---re-renders what was loaded. Malformed files arrive as the daemon lists them,
---`{path, reason}` with path store-relative, and are mapped to the rows' shape.
---@param snapshot table? { ctx, tasks, malformed }; nil renders nothing
---@return table<string, table[]> grouped  bucket → list of tasks
---@return table[] malformed                list of { file_path, relpath, bucket, filename, err }
local function _collect_grouped(snapshot)
  -- Keep the initializer aligned with BUCKETS / BUCKET_ORDER so a
  -- future bucket addition only requires updating one source of truth.
  local grouped   = {}
  for name, _ in pairs(BUCKETS) do grouped[name] = {} end
  local malformed = {}
  if type(snapshot) ~= "table" then return grouped, malformed end

  local dir = snapshot.ctx and snapshot.ctx.store or ""
  for _, m in ipairs(snapshot.malformed or {}) do
    if type(m) == "table" then
      local rel = tostring(m.path or "")
      malformed[#malformed + 1] = {
        file_path = dir .. "/" .. rel,
        relpath   = rel,
        bucket    = rel:match("^([^/]+)/") or "",
        filename  = vim.fn.fnamemodify(rel, ":t"),
        err       = tostring(m.reason or "malformed"),
      }
    end
  end

  for _, t in ipairs(snapshot.tasks or {}) do
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

  -- Stable malformed order: sort by (bucket, filename) so the panel
  -- doesn't reshuffle entries across renders.
  table.sort(malformed, function(a, b)
    if (a.bucket or "") ~= (b.bucket or "") then
      return (a.bucket or "") < (b.bucket or "")
    end
    return (a.filename or "") < (b.filename or "")
  end)

  return grouped, malformed
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
local function _render(bufnr, snapshot)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return end

  -- v0.2.37: preserve cursor across re-renders. Pre-render, snapshot
  -- the cursor of every window currently showing this buffer; post-
  -- render, restore it (clamped to the new line count). Without this,
  -- nvim_buf_set_lines's replace-all-lines call can shift the cursor
  -- — most visibly when `o` expands a task and the user's cursor was
  -- on the task row: even though the task row's lnum is stable, the
  -- buffer mutation can land the cursor on the previous bucket
  -- header. The save/restore pin makes the toggle feel like a
  -- treeview expand (cursor stays put).
  local cursor_saves = {}
  for _, w in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(w) then
      cursor_saves[w] = vim.api.nvim_win_get_cursor(w)
    end
  end

  -- A load hands its snapshot in; every other render (a toggle, an
  -- expansion) re-renders the last one, and never asks the daemon.
  if snapshot then
    M._snapshot = snapshot
    M._by_id = {}
    for _, t in ipairs(snapshot.tasks or {}) do
      if type(t) == "table" and type(t.id) == "string" then M._by_id[t.id] = t end
    end
  else
    snapshot = M._snapshot
  end
  local grouped, malformed = _collect_grouped(snapshot)
  local rows    = {}     -- accumulating M._rows
  local lines   = {}     -- text lines we'll buf_set after the loop
  local marks   = {}     -- deferred extmarks { lnum0, col_s, col_e, hl }

  -- Helper to add an extmark in the deferred queue.
  local function mark(lnum0, col_s, col_e, hl)
    marks[#marks + 1] = { lnum0, col_s, col_e, hl }
  end

  -- Header line: blank separator + `<Label> (<count>)`.
  -- v0.2.41: emit a top-level section header with a collapse
  -- chevron. Pushes a kind="bucket-header" row so <CR> can toggle.
  local function emit_header(bucket_name, count)
    local cfg = BUCKETS[bucket_name]
    if #lines > 0 then lines[#lines + 1] = "" end       -- blank separator
    local collapsed = M._collapsed[bucket_name] == true
    local chevron   = collapsed and "▶ " or "▼ "
    local label     = cfg.header .. " (" .. count .. ")"
    local line      = chevron .. label
    lines[#lines + 1] = line
    local lnum0 = #lines - 1
    mark(lnum0, 0, #chevron, HL.chevron)
    mark(lnum0, #chevron, #chevron + #label, cfg.hl_header)
    rows[#rows + 1] = {
      kind    = "bucket-header",
      lnum    = lnum0 + 1,
      section = bucket_name,
    }
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
      kind         = "task",
      id           = task.id,
      status       = task.status,
      errors_count = err_count,
      lnum         = lnum0 + 1,    -- 1-based for cursor comparison
      task         = task,
    }
  end

  -- Frontmatter-field row emission (used when `M._expanded[task.id]`
  -- is set — typically via the `o` keymap toggle).
  --
  -- Indent layout:
  --   `<8 sp><label-col-16><value>`        scalar field
  --   `<8 sp><label>:`                    list-field header
  --   `<10 sp>· <item>`                    list-field bulleted item
  --
  -- Each emitted row goes into M._rows with kind="frontmatter-field"
  -- so `<CR>` can dispatch on path-bearing fields (adr/review/
  -- blocked) without re-parsing the buffer.
  local FM_INDENT  = string.rep(" ", 8)
  local FM_LABEL_W = 16
  local FM_BULLET  = "          · "  -- 10 spaces + `· ` (2 bytes for `·` UTF-8 + space)

  local function emit_fm_scalar(task, label, raw_value, opts)
    opts = opts or {}
    local hl     = opts.hl or HL.fm_value
    local is_null = raw_value == nil or raw_value == ""
    local v_text = is_null and "(none)" or tostring(raw_value)
    local line   = FM_INDENT .. string.format("%-" .. FM_LABEL_W .. "s", label .. ":") .. v_text
    lines[#lines + 1] = line
    local lnum0 = #lines - 1
    -- Label highlight.
    mark(lnum0, #FM_INDENT, #FM_INDENT + #label + 1, HL.fm_label)
    -- Value highlight (skip when null — use the null group).
    local v_col = #FM_INDENT + FM_LABEL_W
    mark(lnum0, v_col, v_col + #v_text, is_null and HL.fm_null or hl)
    rows[#rows + 1] = {
      kind     = "frontmatter-field",
      lnum     = lnum0 + 1,
      task     = task,
      field    = label,
      filepath = opts.filepath,
    }
  end

  local function emit_fm_list_header(task, label)
    local line = FM_INDENT .. label .. ":"
    lines[#lines + 1] = line
    local lnum0 = #lines - 1
    mark(lnum0, #FM_INDENT, #FM_INDENT + #label + 1, HL.fm_label)
    rows[#rows + 1] = {
      kind  = "frontmatter-field",
      lnum  = lnum0 + 1,
      task  = task,
      field = label,
    }
  end

  local function emit_fm_list_item(task, label, value, opts)
    opts = opts or {}
    local v_text = tostring(value)
    local line = FM_BULLET .. v_text
    lines[#lines + 1] = line
    local lnum0 = #lines - 1
    -- Highlight the bullet glyph (variable byte width — match by
    -- finding the literal bullet position).
    local bullet_b = line:find("·", 1, true)
    if bullet_b then
      -- `·` is 2 bytes; mark from bullet through trailing space.
      mark(lnum0, bullet_b - 1, bullet_b + 2, HL.fm_bullet)
    end
    -- Value highlight (path-shaped if a filepath resolves).
    local v_col = #FM_BULLET
    mark(lnum0, v_col, v_col + #v_text,
      opts.filepath and HL.fm_path or HL.fm_value)
    rows[#rows + 1] = {
      kind     = "frontmatter-field",
      lnum     = lnum0 + 1,
      task     = task,
      field    = label,
      filepath = opts.filepath,
    }
  end

  local function emit_frontmatter(task)
    -- Identity + status
    emit_fm_scalar(task, "id",       task.id)
    emit_fm_scalar(task, "version",  task.version)
    emit_fm_scalar(task, "status",   task.status)
    emit_fm_scalar(task, "title",    task.title)
    emit_fm_scalar(task, "due",      task.due)
    emit_fm_scalar(task, "priority", task.priority)
    emit_fm_scalar(task, "assignee", task.assignee)

    -- tags as a single comma-joined line (compact).
    if type(task.tags) == "table" and #task.tags > 0 then
      emit_fm_scalar(task, "tags", table.concat(task.tags, ", "))
    end

    -- adr — list of KB-relative paths.
    if type(task.adr) == "table" and #task.adr > 0 then
      emit_fm_list_header(task, "adr")
      for _, rel in ipairs(task.adr) do
        emit_fm_list_item(task, "adr[]", rel, { filepath = _resolve_ref_path(rel) })
      end
    end

    -- review — list of KB-relative paths. Back-compat: a bare string
    -- from a not-yet-rewritten file renders as a single scalar entry.
    if type(task.review) == "table" and #task.review > 0 then
      emit_fm_list_header(task, "review")
      for _, rel in ipairs(task.review) do
        emit_fm_list_item(task, "review[]", rel, { filepath = _resolve_ref_path(rel) })
      end
    elseif type(task.review) == "string" and task.review ~= "" then
      emit_fm_scalar(task, "review", task.review,
        { hl = HL.fm_path, filepath = _resolve_ref_path(task.review) })
    end

    -- blocked — list of task ids; each resolves to a task file path.
    if type(task.blocked) == "table" and #task.blocked > 0 then
      emit_fm_list_header(task, "blocked")
      for _, ref in ipairs(task.blocked) do
        emit_fm_list_item(task, "blocked[]", ref,
          { filepath = _blocked_task_path(ref) })
      end
    end

    -- Lifecycle timestamps last (less commonly-needed at a glance).
    emit_fm_scalar(task, "created",        task.created)
    emit_fm_scalar(task, "updated",        task.updated)
    emit_fm_scalar(task, "status_changed", task.status_changed)
    emit_fm_scalar(task, "completed_at",   task.completed_at)
    emit_fm_scalar(task, "archived_at",    task.archived_at)

    -- errors — list of {field, code, message, detected}.
    if type(task.errors) == "table" and #task.errors > 0 then
      emit_fm_list_header(task, "errors")
      for i, e in ipairs(task.errors) do
        local summary = string.format("[%d] %s — %s (%s, detected %s)",
          i, tostring(e.field), tostring(e.message),
          tostring(e.code), tostring(e.detected))
        emit_fm_list_item(task, "errors[]", summary)
      end
    end
  end

  -- v0.2.38: emit the synthetic "Malformed" section at the top
  -- when scan() surfaced any files that failed to parse or
  -- validate. The user's first impression of the panel should be
  -- "there's something broken — fix this" rather than the broken
  -- task silently vanishing from a normal bucket.
  -- v0.2.41: malformed header with chevron + kind="bucket-header"
  -- row so <CR> toggles collapse via the same dispatch.
  local function emit_malformed_header(count)
    if #lines > 0 then lines[#lines + 1] = "" end
    local collapsed = M._collapsed["malformed"] == true
    local chevron   = collapsed and "▶ " or "▼ "
    local label     = "Malformed (" .. count .. ")"
    local line      = chevron .. label
    lines[#lines + 1] = line
    local lnum0 = #lines - 1
    mark(lnum0, 0, #chevron, HL.chevron)
    mark(lnum0, #chevron, #chevron + #label, HL.header_malformed)
    rows[#rows + 1] = {
      kind    = "bucket-header",
      lnum    = lnum0 + 1,
      section = "malformed",
    }
  end

  local function emit_malformed_row(m)
    local fname = tostring(m.filename or m.file_path or "?")
    local err   = tostring(m.err or "?")
    -- One-line summary; the `i` preview shows the full error.
    -- Layout: `  ⚠ <filename>  (<bucket>)  — <short-err>`
    local short_err = err:gsub("\n.*$", "")
    if #short_err > 80 then short_err = short_err:sub(1, 77) .. "..." end
    local prefix = "  ⚠ "
    local mid    = "  (" .. tostring(m.bucket or "?") .. ")  — "
    local line   = prefix .. fname .. mid .. short_err
    lines[#lines + 1] = line
    local lnum0 = #lines - 1
    -- Highlight: ⚠ as error badge, filename as Directory, err tail as Comment.
    local c = 0
    mark(lnum0, c, c + #prefix, HL.badge)
    c = c + #prefix
    mark(lnum0, c, c + #fname, HL.malformed_filename)
    c = c + #fname
    -- mid is dim NonText-ish; skip explicit highlight (uses Normal)
    c = c + #mid
    mark(lnum0, c, c + #short_err, HL.malformed_err)

    rows[#rows + 1] = {
      kind     = "malformed-task",
      lnum     = lnum0 + 1,
      filepath = m.file_path,
      relpath  = m.relpath,
      bucket   = m.bucket,
      err      = err,
    }
  end

  if type(malformed) == "table" and #malformed > 0 then
    emit_malformed_header(#malformed)
    -- v0.2.41: skip body when section is collapsed
    if not (M._collapsed["malformed"] == true) then
      for _, m in ipairs(malformed) do emit_malformed_row(m) end
    end
  end

  -- v0.2.41: emit a YYYY-MM sub-header inside the archived bucket.
  -- Indented 2 cols under the Archived header. Pushes a row of
  -- kind="archive-period" so <CR> can toggle this specific period.
  local function emit_archive_period_header(period, count)
    local collapsed = _archive_period_collapsed(period)
    local chevron   = collapsed and "▶ " or "▼ "
    local label     = period .. " (" .. count .. ")"
    local line      = "  " .. chevron .. label
    lines[#lines + 1] = line
    local lnum0 = #lines - 1
    mark(lnum0, 2, 2 + #chevron, HL.chevron)
    mark(lnum0, 2 + #chevron, 2 + #chevron + #label, HL.archive_period)
    rows[#rows + 1] = {
      kind   = "archive-period",
      lnum   = lnum0 + 1,
      period = period,
    }
  end

  -- Group archived tasks by YYYY-MM (sourced from archived_at; falls
  -- back to created when archived_at is missing for any reason).
  -- Sorted descending so newest periods float to the top.
  local function group_archived_by_period(tasks)
    local periods = {}
    for _, t in ipairs(tasks) do
      local ts = t.archived_at or t.created or ""
      local period = ts:sub(1, 7)  -- "YYYY-MM"
      if period == "" then period = "unknown" end
      if not periods[period] then periods[period] = {} end
      table.insert(periods[period], t)
    end
    local keys = {}
    for k in pairs(periods) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return a > b end)  -- desc
    return keys, periods
  end

  -- Walk buckets in display order. The 1-based index is OPEN-only
  -- (matches the auto-agents numbered surface per ADR-0031 §5).
  -- After each task row, if M._expanded[task.id] is set, the
  -- frontmatter is inlined immediately below it (treeview-style).
  local total = 0
  for _, name in ipairs(BUCKET_ORDER) do
    local bucket = grouped[name] or {}
    -- v0.3.3: the Open header is ALWAYS emitted, even at count 0, so a
    -- freshly-created (task-less) panel still opens with the cursor on
    -- a task section. Pressing `a` there adds a task; before this fix
    -- the only section on an empty panel was Vars, and `a` on a Vars
    -- row adds a *variable* (the friction this closes). The other
    -- buckets stay hidden until they actually hold tasks.
    if #bucket > 0 or name == "open" or (name == "archived" and M._loading) then
      emit_header(name, name == "archived" and M._loading and "loading…" or #bucket)
      local collapsed = M._collapsed[name] == true
      if not collapsed then
        if name == "archived" then
          -- v0.2.41: archived is rendered as a 2-level tree —
          -- year/month sub-periods, then tasks inside each
          -- expanded period.
          local keys, periods = group_archived_by_period(bucket)
          for _, period in ipairs(keys) do
            local period_tasks = periods[period]
            emit_archive_period_header(period, #period_tasks)
            if not _archive_period_collapsed(period) then
              for _, t in ipairs(period_tasks) do
                emit_task(name, t, nil)
                if M._expanded[t.id] then
                  emit_frontmatter(t)
                end
              end
            end
          end
        else
          -- v0.2.42: render a one-line "(index is ephemeral —
          -- refer by id)" hint right under the Open header so
          -- users (and agents calling `todos.list`) know the
          -- 1-based numbers reorder on every refresh and aren't
          -- a stable address. ADR-0031 §5 / Phase 3.2.
          --
          -- ADR-0035 Phase 1: the numbering now applies to every
          -- non-archived bucket (each bucket counts fresh from 1),
          -- not just OPEN. The hint stays scoped to the Open
          -- section so we surface it exactly once — once the user
          -- has read it under Open, the same rule transparently
          -- applies to the buckets below.
          -- v0.3.3: only surface the ephemeral-index hint when there
          -- is at least one open task — an empty Open header (count 0)
          -- has no numbering to explain.
          if name == "open" and #bucket > 0 then
            local hint = "    (index is ephemeral — refer by id for anything persistent)"
            lines[#lines + 1] = hint
            mark(#lines - 1, 0, #hint, HL.empty)  -- reuse the dim Comment link
          end
          for i, t in ipairs(bucket) do
            -- ADR-0035 Phase 1: every non-archived bucket renders a
            -- 1-based per-bucket index. The `name == "archived"`
            -- branch above never reaches here (handled separately
            -- with no idx), so passing `i` unconditionally is safe.
            emit_task(name, t, i)
            if M._expanded[t.id] then
              emit_frontmatter(t)
            end
          end
        end
      end
      total = total + #bucket
    end
  end

  -- v0.2.39: Vars section. Renders BELOW the bucket list so the
  -- task panel keeps its visual centre of gravity on tasks. The
  -- section is always emitted (built-ins are always available),
  -- so users have a discoverable place to look up "what's
  -- $KB_ROOT currently resolving to?" without leaving the panel.
  do
    local ok_vars, vars = pcall(require, "auto-core.todo.vars")
    if ok_vars and type(vars.list) == "function" then
      -- the variables of the workspace that owns the store (auto-core v0.5.0), named after the count
      local from    = _from(_store_dir())
      local entries = vars.list(from) or {}
      local ws      = type(vars.workspace) == "function" and vars.workspace(from) or nil

      -- Header with chevron (v0.2.41).
      if #lines > 0 then lines[#lines + 1] = "" end
      local vars_collapsed = M._collapsed["vars"] == true
      local vars_chevron   = vars_collapsed and "▶ " or "▼ "
      local header         = "Vars (" .. #entries .. ")" .. (ws and (" · " .. ws) or "")
      local header_line    = vars_chevron .. header
      lines[#lines + 1] = header_line
      local lnum0 = #lines - 1
      mark(lnum0, 0, #vars_chevron, HL.chevron)
      mark(lnum0, #vars_chevron, #vars_chevron + #header, HL.header_vars)
      -- v0.2.41: the Vars header now doubles as a collapsible
      -- bucket header. The original `kind="vars-header"` value
      -- is preserved here ONLY for the `a` keymap's "add var"
      -- dispatch path; the `<CR>` toggle path looks for
      -- `section == "vars"`, so we tag it as a bucket-header
      -- too. _row_under_cursor returns the FIRST matching row,
      -- so we emit a single combined entry.
      rows[#rows + 1] = {
        kind    = "vars-header",  -- preserved for `a` dispatch
        lnum    = lnum0 + 1,
        section = "vars",         -- new — <CR> toggle dispatch
      }

      if vars_collapsed then
        -- Skip body when collapsed.
      elseif #entries == 0 then
        -- Vacuously empty — built-ins should always provide at
        -- least HOME/CWD; if the user really sees zero rows here
        -- it means vars.list() returned an empty table (which
        -- only happens if BUILTINS was misconfigured). Show a
        -- diagnostic line.
        local line = "  (no variables)"
        lines[#lines + 1] = line
        mark(#lines - 1, 0, #line, HL.empty)
      else
        for _, e in ipairs(entries) do
          -- Layout: `  $NAME = <value>  (<where>[, machine-only])`, where is `auto` for a
          -- derived built-in, else where the value comes from (_VAR_TAG); `(unset)` for a
          -- name with no value here, `(conflict)` for one a pending migration holds
          local prefix     = "  "
          local name_chunk = "$" .. tostring(e.name)
          local eq_chunk   = " = "
          local is_unset   = e.value == nil or e.value == ""
          local val_chunk  = e.conflict and "(conflict)" or is_unset and "(unset)" or tostring(e.value)
          local tags = {}
          if e.builtin and (e.source == nil or e.source == "derived") then
            tags[#tags + 1] = "auto"
          elseif not is_unset and _VAR_TAG[e.source] then
            tags[#tags + 1] = _VAR_TAG[e.source]
          end
          if e.machine then tags[#tags + 1] = "machine-only" end
          local tag_chunk  = #tags > 0 and ("  (" .. table.concat(tags, ", ") .. ")") or ""
          local line = prefix .. name_chunk .. eq_chunk .. val_chunk .. tag_chunk
          lines[#lines + 1] = line
          local lnum0 = #lines - 1

          -- Highlight spans
          local c = #prefix
          mark(lnum0, c, c + #name_chunk, HL.vars_name)
          c = c + #name_chunk + #eq_chunk
          mark(lnum0, c, c + #val_chunk,
            (is_unset or e.conflict) and HL.vars_unset or HL.vars_value)
          if #tag_chunk > 0 then
            c = c + #val_chunk
            mark(lnum0, c, c + #tag_chunk, HL.vars_builtin_tag)
          end

          rows[#rows + 1] = {
            kind     = "vars-entry",
            lnum     = lnum0 + 1,
            name     = e.name,
            value    = e.value,
            builtin  = e.builtin == true,
            doc      = e.doc,
            is_unset = is_unset,
            source    = e.source,
            machine   = e.machine == true,
            conflict  = e.conflict == true,
            workspace = ws,
          }
        end
      end
    end
  end

  -- Empty-state UX: no tasks anywhere. (Only shown when there are
  -- no malformed entries either — a panel with broken files is
  -- categorically NOT empty.)
  if total == 0 and (type(malformed) ~= "table" or #malformed == 0) then
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

  -- Writable only for the write itself.
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  for _, mk in ipairs(marks) do
    _hl(bufnr, mk[1], mk[2], mk[3], mk[4])
  end
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified   = false
  M._rows = rows
  M._rows_dir = store.dir()

  -- Restore cursors (clamped to the new line count). Skip lnum 0 to
  -- satisfy nvim_win_set_cursor's 1-based contract.
  local total = vim.api.nvim_buf_line_count(bufnr)
  for w, pos in pairs(cursor_saves) do
    if vim.api.nvim_win_is_valid(w)
       and vim.api.nvim_win_get_buf(w) == bufnr
    then
      local lnum = math.max(1, math.min(pos[1], total))
      pcall(vim.api.nvim_win_set_cursor, w, { lnum, pos[2] or 0 })
    end
  end
end

-- ─── keymap helpers ───────────────────────────────────────────

-- The panel reloads from the daemon after its own writes (defined with the
-- load machinery below).
local _reload

---_failed reports a write the daemon refused. A stale row (todos.stale: the
---task changed since the panel read it, by an agent or by hand) reloads the
---panel, so the next try works on what is there now; nothing is retried.
---@param what string
---@param err string
---@param raw any the daemon's error, when there was one
local function _failed(what, err, raw)
  if store.is(raw, store.STALE) then
    require("auto-finder.log").error("view.todos", what .. ": the task changed since the panel "
      .. "read it; reloaded. Check it and try again. (" .. tostring(err) .. ")")
    _reload()
    return
  end
  require("auto-finder.log").error("view.todos", what .. " failed: " .. tostring(err))
end

---The absolute filesystem path of a task: the daemon's store-relative `path`
---under the store it was listed from (`store.load` adds it as `file_path`).
---@param task table
---@return string?
local function _task_file_path(task)
  return type(task) == "table" and task.file_path or nil
end

---`<CR>` action: context-aware open in the editor-target window.
---  • On a task row → opens the task's own .md file.
---  • On an expanded frontmatter-field row that pre-resolved a
---    filepath (adr / review / blocked items) → opens THAT file.
---  • On a frontmatter-field row without a filepath (e.g. cursor
---    on `status:` or `tags:`) → no-op. Predictable: cursor on a
---    non-clickable field doesn't yank you away from the panel.
---@param row table?    M._rows entry under the cursor
local function _open(row)
  if not row then return end

  local path
  if row.kind == "frontmatter-field" then
    -- Path-bearing frontmatter rows (adr / review / blocked) carry
    -- a pre-resolved abs filepath from the render pass. No fallback
    -- to the parent task — predictable behavior on non-path rows.
    path = row.filepath
  elseif row.kind == "malformed-task" then
    -- Malformed file row: open the broken file so the user can
    -- repair the frontmatter. (`d` deletes it; `i` previews the
    -- parse error.)
    path = row.filepath
  elseif row.kind == "vars-entry" then
    -- v0.2.39: vars row. <CR> opens the value as a filesystem path
    -- when it looks like one (file or directory exists). Otherwise
    -- no-op (use `e` to edit user vars, `i` to preview).
    if not row.is_unset and type(row.value) == "string" and row.value ~= "" then
      local v = vim.fn.expand(row.value)
      if vim.fn.filereadable(v) == 1 or vim.fn.isdirectory(v) == 1 then
        path = v
      end
    end
  elseif row.kind == "vars-header" then
    -- v0.2.41: <CR> on the Vars header toggles its collapse state
    -- (the row also carries section="vars"). `a` is still the
    -- "add new variable" action when the cursor is on this row;
    -- the two keymaps are disambiguated by which key was pressed.
    if row.section then
      _toggle_collapsed(row.section)
      if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
        _render(M._bufnr)
      end
    end
    return
  elseif row.kind == "bucket-header" then
    -- v0.2.41: toggle the section's collapsed state and re-render.
    _toggle_collapsed(row.section)
    if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
      _render(M._bufnr)
    end
    return
  elseif row.kind == "archive-period" then
    -- v0.2.41: toggle a specific archive YYYY-MM period.
    _toggle_archive_period(row.period)
    if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
      _render(M._bufnr)
    end
    return
  else
    -- Task row (kind="task" or — for backwards-tolerance — any row
    -- with a task table and no kind tag).
    path = _task_file_path(row.task)
  end
  if not path or path == "" then return end

  -- v0.2.40: refuse to "open" a literal `$VAR/...` path that
  -- couldn't be resolved. Pre-v0.2.40, calling `:edit $KB_ROOT/...`
  -- created a junk buffer NAMED `$KB_ROOT/...` because nvim
  -- happily edits any string as a file path. Toast the underlying
  -- problem so the user knows what to do (set the variable in
  -- the Vars section, or set the env var and restart).
  if path:sub(1, 1) == "$" then
    local var_name = path:match("^%$([A-Za-z_][A-Za-z0-9_]*)")
      or path:match("^%${([A-Za-z_][A-Za-z0-9_]*)}")
      or "?"
    require("auto-finder.log").error("view.todos",
      "Cannot open '" .. path .. "' — variable $" .. var_name
        .. " is not defined on this machine. Set it in the Vars "
        .. "section or via the matching environment variable.")
    return
  end

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
  if not row then return end

  -- v0.2.38: malformed-task rows have no validated `task` — show
  -- the file path + the full parse/validate error instead.
  if row.kind == "malformed-task" then
    local lines = {}
    lines[#lines + 1] = "  Malformed todo file"
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("  %-12s %s", "Bucket", tostring(row.bucket or "?"))
    lines[#lines + 1] = string.format("  %-12s %s", "Path",   tostring(row.filepath or "?"))
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  Error"
    for line in (tostring(row.err or "") .. "\n"):gmatch("([^\n]*)\n") do
      lines[#lines + 1] = "    " .. line
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  (q / <Esc> to close; <CR> to open the file)"

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
      relative = "cursor", row = 1, col = 0,
      width = width, height = height,
      style = "minimal", border = "rounded",
      title = " malformed todo ", title_pos = "left",
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
    return
  end

  -- v0.2.39: vars-entry preview shows the var's name, resolved
  -- value, source (built-in resolver or user-defined), and doc.
  if row.kind == "vars-entry" then
    local lines = {}
    lines[#lines + 1] = "  Variable"
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("  %-12s $%s", "Name",
      tostring(row.name or "?"))
    lines[#lines + 1] = string.format("  %-12s %s", "Value",
      row.is_unset and "(unset)" or tostring(row.value or ""))
    lines[#lines + 1] = string.format("  %-12s %s", "Source",
      row.builtin and "built-in (auto-resolved, read-only)" or "user-defined")
    if row.workspace then
      lines[#lines + 1] = string.format("  %-12s %s", "Workspace", row.workspace)
    end
    if row.conflict then
      lines[#lines + 1] = string.format("  %-12s %s", "Conflict",
        "held by a pending migration: unresolved until this machine sets it (e)")
    elseif not row.is_unset and _VAR_FROM[row.source] then
      lines[#lines + 1] = string.format("  %-12s %s", "From", _VAR_FROM[row.source])
    end
    if row.machine then
      lines[#lines + 1] = string.format("  %-12s %s", "Machine-only",
        "declared by the KB's file: each machine sets its own value")
    end
    if row.doc and row.doc ~= "" then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "  Doc"
      for line in (tostring(row.doc) .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = "    " .. line
      end
    end
    lines[#lines + 1] = ""
    if row.builtin then
      lines[#lines + 1] = "  (q / <Esc> to close)"
    else
      lines[#lines + 1] = "  (q / <Esc> to close; e to edit; d to delete)"
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].buftype   = "nofile"
    vim.bo[buf].swapfile  = false
    vim.bo[buf].filetype  = "auto-finder-todos-info"
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
      title = " variable ", title_pos = "left",
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
    return
  end

  if not row.task then return end
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

---v0.2.39: prompt for a new user-defined variable. Two-step
---prompt (name, then value) so the user sees the typed name
---before committing the value. Both prompts must produce non-
---empty inputs; either escape cancels the operation. Re-render
---is driven by `core.todo.vars:changed`.
local function _add_var()
  local ok_vars, vars = pcall(require, "auto-core.todo.vars")
  if not ok_vars then return end
  vim.ui.input({ prompt = "New variable name (no `$`): " }, function(name)
    if not name or name == "" then return end
    name = name:gsub("^%$+", "")  -- tolerate `$NAME` input
    vim.ui.input({ prompt = "Value for $" .. name .. ": " }, function(value)
      if not value or value == "" then return end
      local ok, err = vars.set(name, value)
      if not ok then
        require("auto-finder.log").error("view.todos",
          "var set failed: " .. tostring(err))
      end
    end)
  end)
end

---v0.2.39: prompt to edit the value of an existing user-defined
---variable. Built-ins refuse the edit (they auto-resolve).
---@param row table?
local function _edit_var(row)
  if not row or row.kind ~= "vars-entry" then return end
  if row.builtin then
    require("auto-finder.log").warn("view.todos",
      "$" .. tostring(row.name) .. " is a built-in variable (auto-resolved, read-only)")
    return
  end
  local ok_vars, vars = pcall(require, "auto-core.todo.vars")
  if not ok_vars then return end
  vim.ui.input({
    prompt  = "Edit $" .. tostring(row.name) .. ": ",
    default = tostring(row.value or ""),
  }, function(input)
    if input == nil then return end  -- cancelled
    local ok, err = vars.set(row.name, input)
    if not ok then
      require("auto-finder.log").error("view.todos",
        "var set failed: " .. tostring(err))
    end
  end)
end

---`a` action: prompt for a title; on non-empty, create the task (todos.add,
---which scaffolds a new project's store first) and open its file in the
---editor target.
local function _add_task()
  local directory = store.dir()
  vim.ui.input({ prompt = "New todo title: " }, function(input)
    if not input or input == "" or store.dir() ~= directory then return end
    store.add({ title = input }, function(task, err)
      if not task then
        require("auto-finder.log").error("view.todos", "add failed: " .. tostring(err))
        return
      end
      store.publish("core.todo:changed", { kind = "add", id = task.id })
      _open({ kind = "task", task = task })
      _reload()
    end)
  end)
end

---`d` action: confirm + remove the task under the cursor.
---@param row table?
local function _remove_task(row)
  if not row then return end

  -- v0.2.39: vars-entry rows route to vars.remove (user vars only).
  if row.kind == "vars-entry" then
    if row.builtin then
      require("auto-finder.log").warn("view.todos",
        "$" .. tostring(row.name) .. " is a built-in variable and cannot be removed")
      return
    end
    local ok_vars, vars = pcall(require, "auto-core.todo.vars")
    if not ok_vars then return end
    local choice = vim.fn.confirm(
      "Delete user variable '$" .. tostring(row.name) .. "'?",
      "&Yes\n&No", 2)
    if choice ~= 1 then return end
    local ok, err = vars.remove(row.name)
    if not ok then
      require("auto-finder.log").error("view.todos",
        "var remove failed: " .. tostring(err))
    end
    -- Re-render driven by core.todo.vars:changed event.
    return
  end

  -- A malformed row has no validated task to remove: AutoDoc deletes the
  -- broken file (todos.remove_malformed, ADR 1791532020 §2.3), by its
  -- store-relative path. The panel never unlinks under a .todo-list itself.
  if row.kind == "malformed-task" then
    if not row.relpath then return end
    local directory = store.dir()
    local choice = vim.fn.confirm(
      "Delete malformed file?\n   " .. tostring(row.filepath),
      "&Yes\n&No", 2)
    if choice ~= 1 or store.dir() ~= directory then return end
    store.remove_malformed(row.relpath, function(ok, err)
      if not ok then
        require("auto-finder.log").error("view.todos", "delete failed: " .. tostring(err))
        return
      end
      store.publish("core.todo:changed", { kind = "remove_malformed", path = row.filepath })
      _reload()
    end)
    return
  end

  if not row.task then return end
  local directory = store.dir()
  local choice = vim.fn.confirm(
    "Remove task '" .. (row.task.title or row.task.id or "?") .. "'?",
    "&Yes\n&No", 2)
  if choice ~= 1 or store.dir() ~= directory then return end
  store.mutate("remove", row.task, {}, function(_, err, raw)
    if err then return _failed("remove", err, raw) end
    store.publish("core.todo:changed", { kind = "remove", id = row.task.id })
    _reload()
  end)
end

-- v0.2.39: status changes are now driven by a vim.ui.select
-- numbered modal instead of the v0.2.38 hardcoded cycle. The cycle
-- forced users to think through "what's my current status, what's
-- the next state in the rotation, do I need to press `s` twice or
-- thrice to land on `deferred`?" — the modal eliminates that
-- mental tax: the user always sees the destinations and picks one.
--
-- The statuses AutoDoc accepts (ADR 1791532020 §2.2): `automated` went
-- with automation. Order mirrors the panel's bucket order.
local STATUS_CHOICES = { "open", "in-progress", "completed", "deferred", "archived" }

---`s` action: open a numbered-options modal listing the statuses; on
---selection, AutoDoc moves the task (todos.status, at the row's rev). Open
---buffers follow the file into its new bucket.
---@param row table?
local function _set_status(row)
  if not row or not row.task then return end
  local directory = store.dir()

  local current = row.task.status
  vim.ui.select(STATUS_CHOICES, {
    prompt = "Set status for '"
      .. tostring(row.task.title or row.task.id or "?") .. "':",
    format_item = function(item)
      if item == current then return item .. "  (current)" end
      return item
    end,
  }, function(choice)
    if not choice or choice == current or store.dir() ~= directory then return end
    store.mutate("status", row.task, { choice }, function(task, err, raw)
      if not task then return _failed("status", err, raw) end
      store.follow(row.task, task)
      store.publish("core.todo.status:changed", {
        id = task.id, from = row.task.status, to = task.status,
        at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      })
      _reload()
    end)
  end)
end

---v0.2.43: `A` action — assign the task under the cursor to a
---live spawned agent, with an optional one-line directive
---explaining how the recipient should address it (e.g. "create
---ADR", "open a PR", "investigate then come back to me").
---
---Flow:
---  1. Pull the spawned-agent roster from
---     `auto-agents.spawned_agents()` (only currently-alive
---     bootstrap slots). Falls back to `auto-core.mailbox.
---     registry.list()` when auto-agents isn't loaded.
---  2. Show a `vim.ui.select` picker of agent names.
---  3. After selection, prompt for an optional one-line directive
---     via `vim.ui.input`. `<Esc>` (nil) cancels — the task is left
---     untouched. An empty line + `<CR>` ("") proceeds, falling back
---     to a default "Task assigned to you." reason so an
---     instruction-less assignment still pings the recipient with a
---     meaningful message.
---  4. AutoDoc assigns it (todos.assign, at the row's rev), and
---     assigning an `open` task makes it `in-progress` in the same write
---     (D1, ADR 1791532020 §2.3). auto-core's notifier sends the
---     recipient its mailbox message (title, id, file path, and the
---     notes as `Reason:`); the panel asks it to poll at once.
---
---No-op on non-task rows (vars / malformed / headers).
---@param row table?
local function _assign_task(row)
  if not row or not row.task or not row.task.id then return end
  local directory = store.dir()

  -- Try the auto-agents Lua API first; it returns only ALIVE
  -- bootstrap slots, which is the natural "agents available right
  -- now" surface the user expects.
  local agents = {}
  local ok_aa, aa = pcall(require, "auto-agents")
  if ok_aa and type(aa.spawned_agents) == "function" then
    local list = aa.spawned_agents() or {}
    for _, entry in ipairs(list) do
      agents[#agents + 1] = {
        label      = string.format("%d: %s%s",
          entry.slot or 0,
          tostring(entry.name or "?"),
          entry.kind and (" (" .. entry.kind .. ")") or ""),
        name       = entry.name,
        mailbox_id = entry.mailbox_id or ("agent:" .. tostring(entry.name)),
      }
    end
  end

  if #agents == 0 then
    require("auto-finder.log").error("view.todos",
      "no spawned agents found — start at least one slot via :AutoAgents or panel")
    return
  end

  vim.ui.select(agents, {
    prompt = "Assign '" .. tostring(row.task.title or row.task.id) .. "' to:",
    format_item = function(item) return item.label end,
  }, function(choice)
    if not choice then return end
    vim.ui.input({
      -- ADR-0045: terse, shared label (the auto-agents `<leader>ab`
      -- buffer-send picker uses the same "Instructions:" prompt).
      prompt = "Instructions: ",
    }, function(notes)
      -- Cancel vs. empty-submit are distinct here and treated
      -- differently on purpose:
      --   `<Esc>`         → notes == nil → abort the assignment.
      --   empty line + CR → notes == ""  → proceed with a DEFAULT
      --                                     directive.
      -- snacks (the active `vim.ui.input` backend) delivers `nil` only
      -- on cancel and `""` on an empty confirm, so an instruction-less
      -- ENTER still lands the open → in-progress move AND pings the
      -- recipient with a meaningful message, while ESC backs out
      -- cleanly without touching the task. (The earlier variant that
      -- `return`ed on BOTH nil and "" made an instruction-less
      -- assignment a silent no-op — no bucket move, no notification.)
      if notes == nil then return end  -- ESC / cancel — leave task untouched
      local instruction = (vim.trim(notes) ~= "") and notes or nil
      local reason = instruction or "Task assigned to you."
      if store.dir() ~= directory then return end
      -- The task file names the agent only, never an instance (Johno, 2026-10-29: "the full
      -- address is only temp"). With this project's scope, the bare `agent:<name>` is delivered in
      -- this project only (ADR 1791532020 §2.5a). With no project scope set, the full mailbox id is
      -- given to auto-core, which keeps the name and routes this one delivery to the instance
      -- (scope.route_of). An auto-core without either still gets the name alone.
      local name = "agent:" .. tostring(choice.name)
      local ok_sc, sc = pcall(require, "auto-core.todo.scope")
      local params
      if ok_sc and sc.scoped() and sc.get() then
        params = sc.assign_params(name, reason)
      elseif ok_sc and sc.scoped() and sc.route_of then
        params = sc.assign_params(choice.mailbox_id, reason)
      else
        params = { name, reason }
      end
      store.mutate("assign", row.task, params, function(assigned, err, raw)
        if not assigned then return _failed("assign", err, raw) end

        -- ASSIGNING STARTS THE WORK (Johno, 2026-09-08), now from every
        -- surface: AutoDoc moves an `open` task to `in-progress` in the same
        -- write as the assignment (D1, ADR 1791532020 §2.3). The panel makes
        -- no second, separate status call.
        local moved = row.task.status == "open" and assigned.status == "in-progress"
        store.follow(row.task, assigned)
        if moved then
          store.publish("core.todo.status:changed", {
            id = assigned.id, from = row.task.status, to = assigned.status,
            at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
          })
        end
        store.publish("core.todo:changed", { kind = "assign", id = assigned.id })
        store.poke_notifier()

        require("auto-finder.log").notify(
          string.format("assigned '%s' to %s%s%s",
            row.task.title or row.task.id,
            choice.name,
            instruction and (" — " .. instruction) or "",
            moved and " (→ in-progress)" or ""),
          { component = "view.todos", level = "info", notify = true })
        _reload()
      end)
    end)
  end)
end

---`o` action: context-aware toggle.
---  • On a task row → toggle inline frontmatter expansion.
---  • On a bucket/vars header → toggle the section collapse
---    (v0.2.46: same as `<CR>` on a header, so `o` works as a
---    universal "open/close the thing under the cursor" key).
---  • On an archive YYYY-MM period header → toggle that period.
---When the cursor is on a frontmatter child row, the toggle still
---targets the parent task (so `o` collapses from anywhere inside
---the expansion).
---@param row table?
local function _toggle_expand(row)
  if not row then return end

  -- v0.2.46: section headers fold/unfold like the task tree, so
  -- `o` and `<CR>` behave identically on a header. Mirrors the
  -- dispatch in `_open`.
  if row.kind == "bucket-header" or row.kind == "vars-header" then
    if row.section then
      _toggle_collapsed(row.section)
      if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
        _render(M._bufnr)
      end
    end
    return
  elseif row.kind == "archive-period" then
    _toggle_archive_period(row.period)
    if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
      _render(M._bufnr)
    end
    return
  end

  if not row.task or not row.task.id then return end
  local id = row.task.id
  if M._expanded[id] then
    M._expanded[id] = nil
  else
    M._expanded[id] = true
  end
  if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
    _render(M._bufnr)
  end
end

---`R` action: AutoDoc reconciles the store (todos.refresh), then the panel
---reloads. Also the retry after "AutoDoc required" or a failed load.
---@param bufnr integer
local function _refresh(bufnr)
  if not store.available() then return _reload(bufnr) end
  store.refresh(function(summary, err)
    if not summary then
      require("auto-finder.log").error("view.todos", "refresh failed: " .. tostring(err))
    else
      store.publish("core.todo:refreshed", { summary = summary, at = os.date("!%Y-%m-%dT%H:%M:%SZ") })
    end
    _reload(bufnr)
  end)
end

---`M` action: migrate the `.todo-list/` directory to a new location.
---AutoDoc does the filesystem work (ADR 1791532020 §2.3): a move is
---`todos.move_store`, which refuses an existing target and keeps the
---store's claim, change log and cursors; "switch only" is `todos.set_dir`
---for this project's root, which needs an existing directory. The
---panel never renames, creates or deletes a directory itself: a missing
---parent (or, for a switch, a missing target) is refused with a message
---(jarvis, 2026-10-13).
local function _migrate_dir()
  local available, why = store.available()
  if not available then
    require("auto-finder.log").error("view.todos", "migrate: " .. tostring(why))
    return
  end
  local ok_path, fs_path = pcall(require, "auto-core.fs.path")
  if not ok_path then return end

  local current = store.dir()
  vim.ui.input({
    prompt     = "Migrate .todo-list/ to: ",
    default    = current,
    completion = "dir",
  }, function(input)
    if not input or input == "" then return end

    -- v0.2.40: resolve `$VAR/...` substitutions before computing
    -- the absolute path. Lets the user type e.g.
    -- `$KB_ROOT/personal/.todo-list` and have it land at the
    -- correct location across machines.
    local resolved_input = input
    local ok_vars, vars = pcall(require, "auto-core.todo.vars")
    if ok_vars and type(vars.resolve_path) == "function" then
      local r = vars.resolve_path(input)
      if r.unresolved then
        require("auto-finder.log").error("view.todos",
          "migrate: variable $" .. tostring(r.var_name)
            .. " is not defined on this machine — set it in the "
            .. "Vars section or via the matching environment "
            .. "variable, then try again.")
        return
      end
      if r.ok and r.path then resolved_input = r.path end
    end

    -- Expand `~`, normalize trailing slash.
    local new_path = vim.fn.fnamemodify(vim.fn.expand(resolved_input), ":p")
      :gsub("/+$", "")
    if new_path == "" or new_path == current then return end

    local current_exists = fs_path.is_dir(current)
    local target_exists  = fs_path.exists(new_path)

    -- Three shapes, decided up front:
    --   * both exist          → switch only (a move would clobber)
    --   * only current exists → move + switch (AutoDoc moves it)
    --   * only target exists  → switch only
    --   * neither exists      → refused: switch needs an existing
    --                           directory, and the panel creates none
    local action  -- "move_switch" | "switch_only"

    if current_exists and target_exists then
      local choice = vim.fn.confirm(
        string.format(
          "Both directories exist:\n   from: %s\n   to:   %s\n\n"
            .. "(M)ove would clobber the target — pick (S)witch only "
            .. "to just re-point the override. Local files at the "
            .. "current path will remain on disk but become invisible "
            .. "in the panel until you switch back.",
          current, new_path),
        "&Switch only\n&Cancel", 2)
      if choice ~= 1 then return end
      action = "switch_only"

    elseif current_exists then
      local parent = fs_path.parent(new_path)
      if not fs_path.is_dir(parent) then
        require("auto-finder.log").error("view.todos",
          "migrate: the parent directory " .. parent .. " does not exist; "
            .. "create it first (the panel creates no directories)")
        return
      end
      local choice = vim.fn.confirm(
        string.format(
          "Move\n   %s\n → %s\n\nAutoDoc moves the store; the per-workspace override will be updated.",
          current, new_path),
        "&Yes\n&No", 2)
      if choice ~= 1 then return end
      action = "move_switch"

    elseif target_exists then
      local choice = vim.fn.confirm(
        string.format(
          "Switch the per-workspace override to:\n   %s\n\n(target already exists; no files will be moved)",
          new_path),
        "&Yes\n&No", 2)
      if choice ~= 1 then return end
      action = "switch_only"

    else
      require("auto-finder.log").error("view.todos",
        "migrate: neither " .. current .. " nor " .. new_path .. " exists; "
          .. "create " .. new_path .. " first (the panel creates no directories)")
      return
    end

    if store.dir() ~= current then return end -- the project changed under the prompt
    local function done(ok, err)
      if not ok then
        require("auto-finder.log").error("view.todos", "migrate failed: " .. tostring(err))
        return
      end
      -- Success path — INFO toast (notify=true so it always toasts;
      -- INFO normally wouldn't per the default should_toast rule, but
      -- the user explicitly invoked `M` and deserves visible confirmation).
      require("auto-finder.log").notify(
        action == "move_switch"
          and ("auto-finder.todos: migrated to " .. new_path)
          or  ("auto-finder.todos: override switched to " .. new_path
                .. " (no files moved)"),
        { component = "view.todos", level = "info", notify = true })
      if action == "move_switch" then
        store.publish("core.todo:changed", { kind = "move_store", dir = new_path })
      end
      _reload()
    end
    if action == "move_switch" then
      store.move_store(new_path, function(moved, err) done(moved ~= nil, err) end)
    else
      store.set_dir(new_path, done)
    end
  end)
end

---Apply buffer-local keymaps. All `nowait` so single-key bindings
---fire immediately even when nvim would otherwise wait for a
---potential multi-key sequence.
---@param bufnr integer
---@param panel_winid integer
---`O`: toggle ALL open/closed. If any bucket is open (or any tracked
---archive period is explicitly expanded), collapse everything; only when
---nothing is open does it expand everything (short-circuits on the first
---open item). Section/period structure only — never the per-task `o`
---frontmatter expansions. Archive periods default collapsed, so
---expand-all reveals the buckets and any period the user had opened.
local function _toggle_all()
  local any_open = false
  for _, name in ipairs(BUCKET_ORDER) do
    if M._collapsed[name] ~= true then any_open = true break end
  end
  if not any_open then
    for _, v in pairs(M._archive_collapsed) do
      if v == false then any_open = true break end
    end
  end
  local collapse = any_open   -- any open → collapse all, else expand all

  local s = _get_ui_state()
  local cstored = s and s:get("collapsed") or nil
  if type(cstored) ~= "table" then cstored = s and {} or nil end
  for _, name in ipairs(BUCKET_ORDER) do
    M._collapsed[name] = collapse
    if cstored then cstored[name] = collapse end
  end
  if s and cstored then s:set("collapsed", cstored) end

  local astored = s and s:get("archive_periods") or nil
  if type(astored) ~= "table" then astored = s and {} or nil end
  for period in pairs(M._archive_collapsed) do
    M._archive_collapsed[period] = collapse
    if astored then astored[period] = collapse end
  end
  if s and astored then s:set("archive_periods", astored) end

  _render(M._bufnr)
end

local function _apply_keymaps(bufnr, panel_winid)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local set = function(lhs, fn, desc)
    pcall(vim.keymap.set, "n", lhs, fn, {
      buffer = bufnr, silent = true, nowait = true, desc = desc,
    })
  end
  set("<CR>", function() _open(_row_under_cursor(panel_winid)) end,
    "auto-finder.todos: open task .md file (or referenced doc on a frontmatter path row, or value path on a Vars row)")
  set("i", function() _preview_task(_row_under_cursor(panel_winid)) end,
    "auto-finder.todos: preview (popup) — task / malformed / variable")
  -- v0.2.39: `a` dispatches based on what section the cursor is
  -- in. On a Vars row or the Vars header → add a new variable;
  -- everywhere else → add a new task. This avoids splitting the
  -- keymap surface across `a` (add task) vs. some-other-key (add
  -- var) and keeps the "add something here" intent intuitive.
  set("a", function()
    local row = _row_under_cursor(panel_winid)
    if row and (row.kind == "vars-entry" or row.kind == "vars-header") then
      _add_var()
    else
      _add_task()
    end
  end, "auto-finder.todos: add (new task by default; new variable when cursor is in the Vars section)")
  set("e", function() _edit_var(_row_under_cursor(panel_winid)) end,
    "auto-finder.todos: edit (user-defined variable under cursor; no-op elsewhere)")
  set("d", function() _remove_task(_row_under_cursor(panel_winid)) end,
    "auto-finder.todos: remove (task / malformed file / user variable, with confirmation)")
  -- v0.2.39: `s` now opens a numbered modal listing the four
  -- statuses instead of cycling. Picking the current status is a
  -- no-op.
  set("s", function() _set_status(_row_under_cursor(panel_winid)) end,
    "auto-finder.todos: set status (numbered modal: open / in-progress / completed / deferred / archived)")
  -- v0.2.43: `A` (capital — distinct from `a` add) assigns the
  -- task under the cursor to a spawned agent with optional
  -- direction notes. AutoDoc assigns it (todos.assign) and logs
  -- the assignment and auto-core's notifier tells the agent.
  set("A", function() _assign_task(_row_under_cursor(panel_winid)) end,
    "auto-finder.todos: assign task to a spawned agent (picker + notes prompt)")
  set("o", function() _toggle_expand(_row_under_cursor(panel_winid)) end,
    "auto-finder.todos: toggle — task frontmatter expansion, or section/period collapse on a header")
  set("O", function() _toggle_all() end,
    "auto-finder.todos: toggle ALL sections — collapse everything if anything is open, else expand everything")
  set("R", function() _refresh(bufnr) end,
    "auto-finder.todos: refresh (todos.refresh + re-render)")
  set("M", _migrate_dir,
    "auto-finder.todos: migrate .todo-list/ to a new location")

  -- `?` opens the help overlay listing every keymap on this buffer
  -- (auto-finder.shared.help walks the buffer's keymaps via
  -- nvim_buf_get_keymap and floats them in the canonical auto-finder
  -- help overlay — same UX as the files / buffers / repos views).
  require("auto-finder.shared.help").install_help_keymap("todos", bufnr)
end

-- ─── auto-refresh subscriptions ───────────────────────────────

local _load_generation = 0
local _cancel_load
local _event_pending = false

local function _cancel_pending_load()
  _load_generation = _load_generation + 1
  if _cancel_load then _cancel_load() end
  _cancel_load = nil
  M._loading = false
  M._loading_dir = nil
end

---_show_message replaces the panel's body with a few lines and no rows (a
---load that failed, or AutoDoc missing).
---@param bufnr integer
---@param lines string[]
local function _show_message(bufnr, lines)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified = false
  M._rows = {}
  M._rows_dir = store.dir()
end

---The panel without AutoDoc: what is missing, and how to come back. There is no
---Lua fallback (ADR 1791532020 §4), as the kb section has none.
M.REQUIRED_LINES = function(why)
  return {
    "  todos section",
    "",
    "  AutoDoc is not available: " .. tostring(why or store.REQUIRED),
    "",
    "  AutoDoc required: install AutoDoc (or start its daemon), then press R.",
  }
end

local function _load(bufnr)
  _cancel_pending_load()
  local generation = _load_generation
  local available, why = store.available()
  if not available then
    _show_message(bufnr, M.REQUIRED_LINES(why))
    return
  end
  M._loading = true
  local directory = store.dir()
  M._loading_dir = directory
  if M._rows_dir ~= directory then
    M._rows = {}
    M._snapshot, M._by_id = nil, nil
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Loading todos…" })
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].modified = false
  end
  local function current()
    return generation == _load_generation and M._bufnr == bufnr
      and vim.api.nvim_buf_is_valid(bufnr)
      and store.dir() == directory
  end
  local function finish(result, done, err)
    if not current() then
      if generation == _load_generation then
        _cancel_pending_load()
        if M._bufnr == bufnr and vim.api.nvim_buf_is_valid(bufnr)
            and #vim.fn.win_findbuf(bufnr) > 0 then _load(bufnr) end
      end
      return
    end
    if done then M._loading = false; _cancel_load = nil end
    if not err then
      local rendered, render_err = pcall(_render, bufnr, result)
      if rendered then return end
      err = render_err
    end
    _cancel_pending_load()
    if tostring(err):find("AutoDoc required", 1, true) then
      _show_message(bufnr, M.REQUIRED_LINES(err))
      return
    end
    require("auto-finder.log").error("view.todos", "load failed: " .. tostring(err))
    _show_message(bufnr, { "Todos loading failed — press R to retry", "", "  " .. tostring(err) })
  end
  _cancel_load = store.load(finish)
end

_reload = function(bufnr)
  bufnr = bufnr or M._bufnr
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then _load(bufnr) end
end

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
  if _event_pending then return end
  _event_pending = true
  -- Re-render on the next tick. Event publishers are often inside
  -- atomic write paths; defer so the render observes the final
  -- on-disk state and doesn't recurse into the publish chain.
  vim.schedule(function()
    _event_pending = false
    if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr)
        and #vim.fn.win_findbuf(M._bufnr) > 0 then
      _load(M._bufnr)
    end
  end)
end

---Subscribe to the core.todo:* lifecycle events. Idempotent — when
---subscriptions already exist this is a no-op so re-focusing the
---slot doesn't duplicate callbacks.
local function _ensure_subscriptions()
  if M._subs then return end
  local ok_ev, ev = pcall(require, "auto-core.events")
  if not (ok_ev and ev and type(ev.subscribe) == "function") then return end
  M._subs = {
    ev.subscribe("core.todo:refreshed",      function() _on_event("refresh") end),
    ev.subscribe("core.todo.status:changed", function() _on_event("status")  end),
    ev.subscribe("core.todo.vars:changed",   function() _on_event("vars")    end),
    -- v0.2.45: re-render on add / update / remove (auto-core
    -- v0.1.46+ fires core.todo:changed). Closes the stale-panel
    -- gap when an agent creates a task via `todos.add` — the
    -- panel now updates without waiting for a manual R / refresh.
    ev.subscribe("core.todo:changed",        function() _on_event("changed") end),
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
  -- v0.2.41: hydrate per-section collapse state from persisted
  -- preferences on every get_buffer entry. Idempotent — already-
  -- set in-memory values win against defaults; this only fills
  -- gaps from disk on first access.
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
  vim.b[b].auto_finder_view = "todos"
  pcall(vim.api.nvim_buf_set_name, b, "auto-finder://todos")
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "Loading todos…" })
  vim.bo[b].modifiable = false
  M._rows = {}
  _apply_keymaps(b, panel_winid)
  M._bufnr = b
  _ensure_subscriptions()
  _load(b)
  return b
end

function M.on_focus(panel_winid, bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  if not M._loading or M._loading_dir ~= store.dir() then
    _load(bufnr)
  end
  _apply_keymaps(bufnr, panel_winid)
  _ensure_subscriptions()
end

function M.on_close()
  _cancel_pending_load()
  _dispose_subscriptions()
  if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
    pcall(vim.api.nvim_buf_delete, M._bufnr, { force = true })
  end
  M._bufnr = nil
  M._rows  = nil
  M._rows_dir = nil
  M._snapshot, M._by_id = nil, nil
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
M._remove_task  = _remove_task  -- ADR-0040 C3 smoke hook

return M
