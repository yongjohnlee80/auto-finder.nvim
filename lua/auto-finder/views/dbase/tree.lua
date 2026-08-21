---View — autodb explorer tree (ADR-0058 §3.3).
---
---Flat scratch-buffer view on the `todos`/`tests` pattern, replacing the
---nvim-dbee wrapper. A pure renderer over autodb's Lua surface: every
---byte of data arrives through `autodb.session`, and this view never
---dials a daemon, holds a token, or re-derives which connection is
---active ([[auto-family-state-ownership]], [[shared-resolver-single-source-of-truth]]).
---
---Layout:
---
---  workspace
---    connection                  ← `*` marks the active one
---      Tables
---        schema.table
---
---`workspace.list` already embeds each workspace's connections, so the
---top two levels cost ONE request rather than 1+N. Notes are NOT here:
---they are client-side files under the configured notes directory, not
---an RPC surface, and belong with the commands that open them.
---
---Keymaps follow auto-finder's vocabulary rather than the TUI's, because
---`h`/`l` are ordinary cursor motions in a scratch buffer here and the
---other slots have already taught the user this shape:
---
---  <CR>  toggle a container; on a NOTE file, open it in the editor
---        area so plain `:w` saves it
---  o     columns of the table under the cursor (as `todos` uses `o`)
---  i     info modal — connection details, table metadata
---  R     reload the node under the cursor
---  ?     help
---
---**Staleness.** Every async load is stamped with `session.epoch()` and
---dropped if the epoch moved while it was in flight: a reply describing
---a server we are no longer talking to must never paint (ADR-0058 MF3).
---Loads are also stamped per node, so a slow reply for a node the user
---has since collapsed is discarded rather than re-expanding it.
---@module 'auto-finder.views.dbase.tree'

local logger = require("auto-finder.log")

local M = {
  _bufnr = nil,
  _rows = nil,
  _subs = nil,
}

local FILETYPE = "auto-finder"
local NS = vim.api.nvim_create_namespace("auto-finder.dbase.hl")

local HL = {
  workspace  = "AutoFinderDbaseWorkspace",
  connection = "AutoFinderDbaseConnection",
  active     = "AutoFinderDbaseActive",
  group      = "AutoFinderDbaseGroup",
  item       = "AutoFinderDbaseItem",
  dim        = "AutoFinderDbaseDim",
  error      = "AutoFinderDbaseError",
}

local function _apply_default_highlights()
  local defs = {
    [HL.workspace]  = { link = "Title",      default = true },
    [HL.connection] = { link = "Directory",  default = true },
    [HL.active]     = { link = "Special",    default = true },
    [HL.group]      = { link = "Statement",  default = true },
    [HL.item]       = { link = "Normal",     default = true },
    [HL.dim]        = { link = "Comment",    default = true },
    [HL.error]      = { link = "ErrorMsg",   default = true },
  }
  for name, spec in pairs(defs) do
    pcall(vim.api.nvim_set_hl, 0, name, vim.deepcopy(spec))
  end
end

-- ─── autodb access (optional dependency) ──────────────────────

---_session returns autodb's session module, or nil when autodb is not
---installed. Nil is a normal state, not an error: the panel renders an
---explanation instead of failing to mount.
local function _session()
  local ok, s = pcall(require, "autodb.session")
  if ok then return s end
  return nil
end

-- ─── tree state ───────────────────────────────────────────────

---@type table<string, boolean> node id -> expanded
M._expanded = {}

---@type table<string, table> node id -> { loading, error, items, seq }
M._cache = {}

local _seq = 0
local function _next_seq()
  _seq = _seq + 1
  return _seq
end

local function _cache(id)
  M._cache[id] = M._cache[id] or {}
  return M._cache[id]
end

---_invalidate drops loaded children so the next expand refetches.
---@param id string?  nil clears everything
function M.invalidate(id)
  if id then
    M._cache[id] = nil
  else
    M._cache = {}
  end
end

-- ─── loading ──────────────────────────────────────────────────

local _rerender  -- forward declaration; defined after _render

---_load fetches a node's children exactly once per (node, epoch).
---
---Three guards, each for a failure this view has to survive:
---  * `entry.seq` — one in-flight request per node, so a repeated
---    expand does not stack duplicate loads.
---  * `session.guarded` — the epoch check; a reply from a previous
---    server never paints.
---  * `entry.seq ~= seq` on arrival — the node was collapsed or
---    invalidated while the reply was in flight, so the result is stale
---    even though the epoch still matches.
local function _load(id, method, params, project)
  local s = _session()
  if not s then return end
  local entry = _cache(id)
  if entry.items or entry.loading then return end

  local seq = _next_seq()
  entry.loading, entry.seq, entry.error = true, seq, nil

  s.authed(method, params, s.guarded(function(result, err)
    local e = M._cache[id]
    if not e or e.seq ~= seq then return end   -- superseded
    e.loading = false
    if err then
      e.error = err.message or "error"
      e.items = nil
    else
      e.items = project and project(result) or result or {}
    end
    _rerender()
  end))
end

-- ─── row model ────────────────────────────────────────────────
--
-- Rows are built in one pass and kept in M._rows, parallel to the
-- buffer lines, so the cursor position maps to a node without
-- re-parsing text.

local function _row(rows, lines, hls, opts)
  lines[#lines + 1] = opts.text
  rows[#rows + 1] = opts
  if opts.hl then
    hls[#hls + 1] = { lnum = #lines - 1, hl = opts.hl }
  end
  return #lines
end

local function _chevron(expanded)
  return expanded and "" or ""
end

---_render paints the whole tree. Idempotent.
local function _render(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return end
  _apply_default_highlights()

  local lines, rows, hls = {}, {}, {}
  local s = _session()

  if not s then
    _row(rows, lines, hls, { kind = "message", hl = HL.dim,
      text = "  autodb is not installed." })
    _row(rows, lines, hls, { kind = "message", hl = HL.dim,
      text = "  Install yongjohnlee80/autodb to use this panel." })
  elseif not s.is_ready() then
    _row(rows, lines, hls, { kind = "message", hl = HL.dim,
      text = "  Not connected." })
    _row(rows, lines, hls, { kind = "message", hl = HL.dim,
      text = "  <leader>Dw workspace · <leader>Dc connection · <leader>Dl sign in · ? help" })
  else
    local active_conn = s.connection()

    -- Workspaces are the root. They are loaded once per epoch.
    local root = _cache("root")
    if not root.items and not root.loading then
      -- workspace.list embeds each workspace's connections, so the top
      -- two levels of the tree cost ONE round trip rather than 1+N.
      _load("root", "workspace.list", {}, function(r)
        return type(r) == "table" and r or {}
      end)
    end

    if root.loading then
      _row(rows, lines, hls, { kind = "message", hl = HL.dim, text = "  loading…" })
    elseif root.error then
      _row(rows, lines, hls, { kind = "message", hl = HL.error,
        text = "  " .. tostring(root.error) })
    else
      for _, ws in ipairs(root.items or {}) do
        local ws_id = "ws:" .. tostring(ws.id)
        local ws_open = M._expanded[ws_id] == true
        _row(rows, lines, hls, {
          kind = "workspace", id = ws_id, workspace = ws, hl = HL.workspace,
          text = string.format("%s %s", _chevron(ws_open), ws.name or ws.id),
        })
        if not ws_open then goto next_ws end

        do
          -- Already in hand from workspace.list; no second request.
          local ws_conns = ws.connections or {}
          if #ws_conns == 0 then
            _row(rows, lines, hls, { kind = "message", hl = HL.dim,
              text = "    (no connections)" })
          else
            for _, conn in ipairs(ws_conns) do
              local c_id = "conn:" .. tostring(conn.id)
              local c_open = M._expanded[c_id] == true
              local is_active = active_conn and active_conn.id == conn.id
              _row(rows, lines, hls, {
                kind = "connection", id = c_id, workspace = ws, connection = conn,
                hl = is_active and HL.active or HL.connection,
                text = string.format("  %s %s%s", _chevron(c_open),
                  is_active and "* " or "", conn.name or conn.id),
              })
              if not c_open then goto next_conn end

              do
                -- Two fixed groups under a connection, matching the TUI.
                for _, group in ipairs({ { key = "tables", label = "Tables" } }) do
                  local g_id = c_id .. ":" .. group.key
                  local g_open = M._expanded[g_id] == true
                  _row(rows, lines, hls, {
                    kind = "group", id = g_id, group = group.key,
                    workspace = ws, connection = conn, hl = HL.group,
                    text = string.format("    %s %s", _chevron(g_open), group.label),
                  })
                  if not g_open then goto next_group end

                  do
                    local g = _cache(g_id)
                    if not g.items and not g.loading then
                      -- schema.tables is per SCHEMA; "" asks the server
                      -- for the connection's default.
                      _load(g_id, "schema.tables", { conn.id, "" }, function(r)
                        return type(r) == "table" and r or {}
                      end)
                    end
                    if g.loading then
                      _row(rows, lines, hls, { kind = "message", hl = HL.dim,
                        text = "      loading…" })
                    elseif g.error then
                      _row(rows, lines, hls, { kind = "message", hl = HL.error,
                        text = "      " .. tostring(g.error) })
                    elseif #(g.items or {}) == 0 then
                      _row(rows, lines, hls, { kind = "message", hl = HL.dim,
                        text = "      (empty)" })
                    else
                      for _, item in ipairs(g.items or {}) do
                        local label = item.name or item.path or tostring(item)
                        if group.key == "tables" and item.schema then
                          label = item.schema .. "." .. label
                        end
                        _row(rows, lines, hls, {
                          kind = group.key == "tables" and "table" or "note",
                          id = g_id .. ":" .. tostring(label),
                          workspace = ws, connection = conn, item = item,
                          hl = HL.item,
                          text = "      " .. label,
                        })
                      end
                    end
                  end
                  ::next_group::
                end
              end
              ::next_conn::
            end
          end
        end
        ::next_ws::
      end
    end
  end

  if #lines == 0 then
    _row(rows, lines, hls, { kind = "message", hl = HL.workspace,
      text = "  No workspaces yet." })
    _row(rows, lines, hls, { kind = "message", hl = HL.dim,
      text = "  <leader>Dw to create one · ? for help" })
  end

  -- Restore the cursor line across repaints so a background refresh
  -- does not move the user (the no-hijack invariant).
  local win = vim.fn.bufwinid(bufnr)
  local cursor = win ~= -1 and vim.api.nvim_win_get_cursor(win) or nil

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  for _, h in ipairs(hls) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, h.lnum, 0,
      { end_line = h.lnum + 1, hl_group = h.hl })
  end
  vim.bo[bufnr].modifiable = false

  if cursor and win ~= -1 then
    local lnum = math.min(cursor[1], math.max(#lines, 1))
    pcall(vim.api.nvim_win_set_cursor, win, { lnum, cursor[2] })
  end

  M._rows = rows
end

_rerender = function()
  if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
    _render(M._bufnr)
  end
end

---_row_under_cursor maps the cursor to its row entry.
local function _row_under_cursor(panel_winid)
  if not (M._rows and panel_winid and vim.api.nvim_win_is_valid(panel_winid)) then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(panel_winid)[1]
  return M._rows[lnum]
end

-- ─── actions ──────────────────────────────────────────────────

---_toggle expands or collapses a container.
---
---Collapsing INVALIDATES the node, so re-expanding refetches rather
---than showing a tree that may have changed on the server since.
local function _toggle(row)
  if not row or not row.id then return end
  if row.kind ~= "workspace" and row.kind ~= "connection" and row.kind ~= "group" then
    return false
  end
  if M._expanded[row.id] then
    M._expanded[row.id] = nil
    M.invalidate(row.id)
  else
    M._expanded[row.id] = true
  end
  _rerender()
  return true
end

---_open_note opens a note file in the EDITOR area, not the panel.
---
---Requirement 5: once it is a real buffer on a real path, plain `:w`
---saves it where autodb expects, with no bespoke save command.
local function _open_note(row)
  local path = row and row.item and (row.item.path or row.item.file)
  if not path then return end
  local af = require("auto-finder")
  local target = af._editor_target_winid and af._editor_target_winid() or nil
  if target then
    pcall(vim.api.nvim_set_current_win, target)
    pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
  else
    -- No editor window: make one rather than replacing a panel.
    pcall(vim.cmd, "botright vsplit " .. vim.fn.fnameescape(path))
  end
end

---_activate is `<CR>`: toggle a container, open a note, select a
---connection.
local function _activate(row)
  if not row then return end
  if _toggle(row) then return end
  if row.kind == "note" then return _open_note(row) end
  if row.kind == "table" then return end
  if row.kind == "connection" then
    local s = _session()
    if s then
      s.select_workspace(row.workspace)
      s.select_connection(row.connection)
      _rerender()
    end
  end
end

---_columns is `o`: the columns of the table under the cursor.
local function _columns(row)
  if not row or row.kind ~= "table" then return end
  local s = _session()
  if not s then return end
  local id = row.id .. ":cols"
  if M._expanded[id] then
    M._expanded[id] = nil
    M.invalidate(id)
    return _rerender()
  end
  M._expanded[id] = true
  _load(id, "schema.columns",
    { row.connection.id, row.item.schema or "", row.item.name })
  _rerender()
end

---_info is `i`: what this node actually is, in a float.
local function _info(row)
  if not row then return end
  local lines
  if row.kind == "connection" then
    local c = row.connection
    lines = {
      "Connection: " .. tostring(c.name or c.id),
      "  id:        " .. tostring(c.id),
      "  driver:    " .. tostring(c.driver or c.type or "?"),
      "  workspace: " .. tostring(row.workspace and row.workspace.name or "?"),
      "",
      "The DSN is held server-side, encrypted under the master key,",
      "and is never sent to the frontend.",
    }
  elseif row.kind == "table" then
    lines = {
      "Table: " .. tostring(row.item.schema and (row.item.schema .. ".") or "")
        .. tostring(row.item.name),
      "  connection: " .. tostring(row.connection.name or row.connection.id),
      "",
      "o — columns",
    }
  elseif row.kind == "note" then
    lines = {
      "Note: " .. tostring(row.item.name or row.item.path),
      "  path: " .. tostring(row.item.path or "?"),
      "",
      "<CR> opens it in the editor; :w saves it in place.",
    }
  else
    return
  end

  local ok, float = pcall(require, "auto-core.ui.float")
  if ok and float and float.help_overlay then
    pcall(float.help_overlay, lines, { title = "dbase" })
  else
    logger.notify(table.concat(lines, "\n"), { level = vim.log.levels.INFO })
  end
end

---_reload drops the node's children and repaints.
local function _reload(row)
  if row and row.id then
    M.invalidate(row.id)
  else
    M.invalidate(nil)
  end
  _rerender()
end

local HELP = {
  "auto-finder dbase — autodb explorer",
  "",
  "  <CR>  toggle · open a note in the editor · select a connection",
  "  o     columns of the table under the cursor",
  "  i     info about the node under the cursor",
  "  R     reload the node under the cursor (all with no node)",
  "  ?     this help",
  "",
  "  <leader>Dw  choose / create a workspace",
  "  <leader>Dc  choose a connection      <leader>Dr  run the buffer",
  "  <leader>Dh  history                  <leader>DR  run the selection",
  "  <leader>Dl  sign in (retry / switch)",
}

local function _help()
  local ok, float = pcall(require, "auto-core.ui.float")
  if ok and float and float.help_overlay then
    -- help_overlay(lines, opts) — lines is positional. Passing one packed
    -- {title, lines} table made `lines` a hash with no array part, so the
    -- overlay rendered "(no help entries)" and `?` looked dead.
    pcall(float.help_overlay, HELP, { title = "dbase" })
  else
    logger.notify(table.concat(HELP, "\n"), { level = vim.log.levels.INFO })
  end
end

-- ─── keymaps and subscriptions ────────────────────────────────

local function _apply_keymaps(bufnr, panel_winid)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local set = function(lhs, fn, desc)
    pcall(vim.keymap.set, "n", lhs, fn, {
      buffer = bufnr, silent = true, nowait = true, desc = desc,
    })
  end
  set("<CR>", function() _activate(_row_under_cursor(panel_winid)) end,
    "auto-finder.dbase: toggle / open note in the editor / select connection")
  set("o", function() _columns(_row_under_cursor(panel_winid)) end,
    "auto-finder.dbase: columns of the table under the cursor")
  set("i", function() _info(_row_under_cursor(panel_winid)) end,
    "auto-finder.dbase: info about the node under the cursor")
  set("R", function() _reload(_row_under_cursor(panel_winid)) end,
    "auto-finder.dbase: reload the node under the cursor")
  set("?", _help, "auto-finder.dbase: help")
end

---_ensure_subscriptions keeps exactly one handler per topic.
---
---`view_subs:replace` rather than a `_subscribed` boolean: the boolean
---form silently survives a bus reset and the view then stops updating
---with no sign anything is wrong ([[view-subs-over-subscribe-flags]]).
local function _ensure_subscriptions()
  local ok_vs, vs = pcall(require, "auto-finder.shared.view_subs")
  if not ok_vs then return end
  M._subs = M._subs or vs.new()

  local s = _session()
  if not s then return end

  -- autodb publishes to auto-core topics, so these go through the same
  -- view_subs machinery as every other subscription in this plugin:
  -- one handle per slot, replaced rather than accumulated on refocus,
  -- and released together in on_close.
  M._subs:replace("autodb-connected", s.TOPIC_CONNECTED, function()
    M.invalidate(nil)
    vim.schedule(_rerender)
  end)
  M._subs:replace("autodb-disconnected", s.TOPIC_DISCONNECTED, function()
    M.invalidate(nil)
    vim.schedule(_rerender)
  end)
  M._subs:replace("autodb-selection", s.TOPIC_SELECTION, function()
    vim.schedule(_rerender)
  end)
  if s.TOPIC_WORKSPACES then
    M._subs:replace("autodb-workspaces", s.TOPIC_WORKSPACES, function()
      M.invalidate("root")
      vim.schedule(_rerender)
    end)
  end
end

local function _dispose_subscriptions()
  if M._subs and M._subs.dispose_all then pcall(function() M._subs:dispose_all() end) end
  M._subs = nil
end

-- ─── public — view lifecycle contract ─────────────────────────

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
  vim.b[b].auto_finder_view = "dbase"
  pcall(vim.api.nvim_buf_set_name, b, "auto-finder://dbase")
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
  M._rows = nil
end

-- Test-only — production code never calls this.
function M._reset_for_tests()
  M.on_close()
  M._expanded = {}
  M._cache = {}
  _seq = 0
end

M._HL = HL
M._NS = NS
M._row_under_cursor = _row_under_cursor
M._render_for_tests = _render
M._activate_for_tests = _activate
M._toggle_for_tests = _toggle

return M
