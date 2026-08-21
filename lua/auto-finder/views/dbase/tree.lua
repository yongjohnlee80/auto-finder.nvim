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
---_list_notes reads a workspace's note files. Notes are client-side
---files (never an RPC surface); autodb reports the root over its
---handshake, so both frontends and this panel read the same folder.
function M._list_notes(ws_id)
  local s = _session()
  if not (s and s.notes_dir) then return {} end
  local root = s.notes_dir()
  if type(root) ~= "string" or root == "" then return {} end
  local dir = root .. "/ws-" .. tostring(ws_id)
  local fs = vim.uv or vim.loop
  local handle = fs.fs_scandir(dir)
  if not handle then return {} end
  local out = {}
  while true do
    local name, typ = fs.fs_scandir_next(handle)
    if not name then break end
    if typ ~= "directory" and name:match("%.sql$") then
      out[#out + 1] = { name = name, path = dir .. "/" .. name }
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

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
      -- One recursive-ish pass, no gotos. Containers ask _expanded
      -- whether to descend; every lazy level loads through _load and
      -- settles to loading / error / empty / items.
      local active_conn = active_conn
      local IND = "  "
      local function msg(depth, text, hl)
        _row(rows, lines, hls, { kind = "message", hl = hl or HL.dim,
          text = string.rep(IND, depth) .. text })
      end
      -- container renders a chevron row and returns whether it is open.
      local function container(depth, opts)
        local open = M._expanded[opts.id] == true
        _row(rows, lines, hls, {
          kind = opts.kind, id = opts.id, expandable = true,
          workspace = opts.workspace, connection = opts.connection,
          group = opts.group, item = opts.item, hl = opts.hl,
          text = string.rep(IND, depth) .. _chevron(open)
            .. " " .. (opts.marker or "") .. opts.label,
        })
        return open
      end
      -- children lazily loads id via method/params, then hands the
      -- settled items to draw (or renders loading/error/empty first).
      local function children(id, method, params, project, depth, empty, draw)
        local g = _cache(id)
        if not g.items and not g.loading then _load(id, method, params, project) end
        if g.loading then return msg(depth, "loading…") end
        if g.error then return msg(depth, tostring(g.error), HL.error) end
        if #(g.items or {}) == 0 then return msg(depth, empty) end
        draw(g.items)
      end

      -- table / view → its columns (schema.columns). Also what o toggles.
      local function draw_relation(depth, ws, conn, item, kind)
        local label = item.name or tostring(item)
        if item.schema and item.schema ~= "" then label = item.schema .. "." .. label end
        local id = string.format("%s:%d:%s", kind, conn.id, label)
        local open = container(depth, {
          kind = kind, id = id, workspace = ws, connection = conn,
          item = item, hl = HL.item, label = label,
        })
        if not open then return end
        children(id .. ":cols", "schema.columns",
          { conn.id, item.schema or "", item.name },
          function(r) return type(r) == "table" and r or {} end,
          depth + 1, "(no columns)", function(cols)
            for _, c in ipairs(cols) do
              local badge = c.type or ""
              if c.pk then badge = badge .. " pk" end
              if c.nullable == false then badge = badge .. " not null" end
              _row(rows, lines, hls, { kind = "column", hl = HL.dim,
                text = string.rep(IND, depth + 1) .. (c.name or "?")
                  .. (badge ~= "" and ("  " .. badge) or "") })
            end
          end)
      end

      -- the tables / views / functions sections under a connection.
      local function draw_sections(depth, ws, conn)
        for _, sec in ipairs({
          { key = "tables", label = "tables", kind = "table" },
          { key = "views", label = "views", kind = "view" },
          { key = "functions", label = "functions" },
        }) do
          local sid = string.format("sec:%d:%s", conn.id, sec.key)
          local open = container(depth, {
            kind = "group", id = sid, group = sec.key,
            workspace = ws, connection = conn, hl = HL.group, label = sec.label,
          })
          if not open then goto next_sec end
          if sec.key == "functions" then
            children(sid, "schema.routines", { conn.id, "" },
              function(r) return type(r) == "table" and r.routines or {} end,
              depth + 1, "(none — engine has no stored routines)", function(items)
                for _, r in ipairs(items) do
                  _row(rows, lines, hls, { kind = "routine", hl = HL.item,
                    text = string.rep(IND, depth + 1) .. (r.name or "?")
                      .. (r.signature and r.signature ~= "" and ("  " .. r.signature) or "") })
                end
              end)
          else
            local want = sec.kind
            children(sid, "schema.tables", { conn.id, "" },
              function(r)
                local out = {}
                for _, x in ipairs(type(r) == "table" and r or {}) do
                  if (x.kind or "table") == want then out[#out + 1] = x end
                end
                return out
              end,
              depth + 1, "(none)", function(items)
                for _, item in ipairs(items) do
                  draw_relation(depth + 1, ws, conn, item, sec.kind)
                end
              end)
          end
          ::next_sec::
        end
      end

      for _, ws in ipairs(root.items or {}) do
        local ws_id = "ws:" .. tostring(ws.id)
        if not container(0, { kind = "workspace", id = ws_id, workspace = ws,
          hl = HL.workspace, label = ws.name or ws.id }) then goto next_ws end

        -- connections/
        local conns_open = container(1, { kind = "group", id = "conns:" .. tostring(ws.id),
          group = "connections", workspace = ws, hl = HL.group, label = "connections" })
        if conns_open then
          local ws_conns = ws.connections or {}   -- already in hand from workspace.list
          if #ws_conns == 0 then
            msg(2, "(no connections — <leader>Dc to add one)")
          else
            for _, conn in ipairs(ws_conns) do
              local is_active = active_conn and active_conn.id == conn.id
              local c_open = container(2, {
                kind = "connection", id = "conn:" .. tostring(conn.id),
                workspace = ws, connection = conn,
                hl = is_active and HL.active or HL.connection,
                marker = is_active and "* " or "", label = conn.name or conn.id,
              })
              if c_open then draw_sections(3, ws, conn) end
            end
          end
        end

        -- notes/
        local notes_open = container(1, { kind = "group", id = "notes:" .. tostring(ws.id),
          group = "notes", workspace = ws, hl = HL.group, label = "notes" })
        if notes_open then
          local nid = "notes:" .. tostring(ws.id)
          local g = _cache(nid)
          if not g.items and not g.loading then
            g.items = M._list_notes(ws.id)   -- client-side files; synchronous
          end
          if #(g.items or {}) == 0 then
            msg(2, "(no notes)")
          else
            for _, note in ipairs(g.items) do
              _row(rows, lines, hls, { kind = "note", hl = HL.item,
                workspace = ws, item = note,
                text = string.rep(IND, 2) .. (note.name or note.path) })
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
  if not row or not row.id or not row.expandable then return false end
  if M._expanded[row.id] then
    M._expanded[row.id] = nil
    M.invalidate(row.id)
    M.invalidate(row.id .. ":cols")   -- table/view columns live here
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
  if row.kind == "note" then return _open_note(row) end
  if row.kind == "connection" then
    -- Entering a connection makes it the active one AND expands it: you
    -- came here to work with it.
    local s = _session()
    if s then
      s.select_workspace(row.workspace)
      s.select_connection(row.connection)
    end
    _toggle(row)
    return
  end
  -- Containers (workspace, groups, tables, views) toggle; leaves
  -- (columns, routines) have nothing to open — `i` describes them.
  _toggle(row)
end

---_columns is `o`: the columns of the table under the cursor.
local function _columns(row)
  -- Columns hang off a table/view as its children; o reveals them, the
  -- same expansion <CR> toggles. A no-op elsewhere.
  if not row or (row.kind ~= "table" and row.kind ~= "view") then return end
  _toggle(row)
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
  "  workspace → connections · notes",
  "  connection → tables · views · functions → columns",
  "",
  "  <CR>  expand / collapse · open a note · enter a connection",
  "  o     expand a table/view into its columns",
  "  i     info about the node under the cursor",
  "  R     reload the node under the cursor (all with no node)",
  "  ?     this help",
  "",
  "  <leader>Dw  choose / create a workspace",
  "  <leader>Dc  choose / create a connection",
  "  <leader>Dr  run the buffer            <leader>DR  run the selection",
  "  <leader>Dh  history",
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
