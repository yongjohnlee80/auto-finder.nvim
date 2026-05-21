---View — nvim marks (global A-Z + local a-z across loaded buffers).
---
---Flat scratch-buffer list, NOT neo-tree-backed. Renders all marks
---reachable from `vim.fn.getmarklist()`:
---  - Global marks (A-Z) at the top, each with a file path + line.
---  - Local marks (a-z) grouped per loaded buffer (any buffer with
---    a non-empty name).
---
---Buffer-local keymaps:
---  <CR>  jump to the mark (route via auto-finder's editor-window
---        resolver: pick the editor target, swap the buffer in,
---        place cursor at line/col).
---  d     delete the mark (matches `:delmarks`); `vim.fn.setpos`
---        to clear, then re-render. `nowait` makes the single-key
---        mapping fire immediately; the buffer is `nomodifiable`
---        anyway so nvim's `d`-operator would no-op even without
---        the nowait short-circuit.
---  R     manual refresh (re-collect + re-render).
---
---Auto-refresh surfaces (nvim has no native MarkChanged event, so
---we hook the events that most often precede or follow a mark
---mutation):
---  - on slot focus (always; primary refresh path)
---  - on `BufWritePost` for any buffer, AND
---  - on `CursorHold` (idle after `updatetime`ms),
---both gated on "the marks buffer is currently visible somewhere"
---so we don't pay the (already-cheap) render cost when the panel
---is hidden — the next `on_focus` will re-render anyway.
---
---Discoverable as a registrable type via `slot add marks` —
---`_available_section_types` scans `views/<name>/init.lua` directly.
---@module 'auto-finder.views.marks'

local M = {
  name        = "marks",
  description = "nvim marks (global A-Z + local a-z)",
}

local FILETYPE = "auto-finder-marks"

-- Cached scratch bufnr — survives view-switch like the other views.
M._bufnr = nil

-- Line-keyed lookup: `[linenr] = mark-record` (or nil for headers
-- and blank lines). Consulted by the <CR>/d keymaps to figure out
-- what's under the cursor.
M._rows = nil

-- Augroup id for the auto-refresh autocmds. Allocated in
-- `_ensure_autocmds` (called from `get_buffer`); torn down in
-- `on_close`. The `clear = true` option on creation is enough for
-- the idempotent "rebind without leaking" case.
M._augroup = nil

local function _shorten_path(path)
  if type(path) ~= "string" or path == "" then return "" end
  local cwd = vim.fn.getcwd()
  if cwd ~= "" and path:sub(1, #cwd + 1) == cwd .. "/" then
    return path:sub(#cwd + 2)
  end
  local home = vim.fn.expand("~")
  if home ~= "" and path:sub(1, #home + 1) == home .. "/" then
    return "~/" .. path:sub(#home + 2)
  end
  return path
end

-- Read line `line` (1-indexed) from `bufnr_or_file`. Prefers the
-- bufnr when valid (avoids touching the filesystem); falls back to
-- streaming the file for global marks whose buffer isn't loaded.
local function _read_line(bufnr_or_file, line)
  if type(line) ~= "number" or line < 1 then return "" end
  if type(bufnr_or_file) == "number"
      and vim.api.nvim_buf_is_valid(bufnr_or_file) then
    local ls = vim.api.nvim_buf_get_lines(bufnr_or_file, line - 1, line, false)
    return ls[1] or ""
  end
  if type(bufnr_or_file) == "string" and bufnr_or_file ~= "" then
    local f = io.open(bufnr_or_file, "r")
    if not f then return "" end
    local n, txt = 1, ""
    for l in f:lines() do
      if n == line then txt = l; break end
      n = n + 1
    end
    f:close()
    return txt
  end
  return ""
end

-- Strip leading whitespace from preview text so the column lines
-- up regardless of indent depth.
local function _trim_left(s)
  if type(s) ~= "string" then return "" end
  return (s:gsub("^%s+", ""))
end

-- Collect all (global + per-buffer local) marks into two ordered
-- lists. Local-marks-by-buffer is sorted by cwd-relative path so
-- the per-buffer sections render in a predictable order.
local function _collect()
  local globals = {}
  for _, m in ipairs(vim.fn.getmarklist()) do
    local name = m.mark:sub(2, 2)
    if name:match("[A-Z]") then
      local file = m.file or ""
      local pos = m.pos or {}
      local line, col = pos[2] or 0, pos[3] or 0
      local bufnr_hint
      if pos[1] and pos[1] > 0 and vim.api.nvim_buf_is_valid(pos[1]) then
        bufnr_hint = pos[1]
      end
      globals[#globals + 1] = {
        kind    = "global",
        mark    = name,
        bufnr   = bufnr_hint,
        file    = file,
        line    = line,
        col     = col,
        preview = _trim_left(_read_line(bufnr_hint or file, line)),
      }
    end
  end
  table.sort(globals, function(a, b) return a.mark < b.mark end)

  local locals_by_buf = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local bname = vim.api.nvim_buf_get_name(b)
      if bname ~= "" then
        local entries = {}
        for _, m in ipairs(vim.fn.getmarklist(b)) do
          local name = m.mark:sub(2, 2)
          if name:match("[a-z]") then
            local pos = m.pos or {}
            local line, col = pos[2] or 0, pos[3] or 0
            entries[#entries + 1] = {
              kind    = "local",
              mark    = name,
              bufnr   = b,
              file    = bname,
              line    = line,
              col     = col,
              preview = _trim_left(_read_line(b, line)),
            }
          end
        end
        if #entries > 0 then
          table.sort(entries, function(a, b) return a.mark < b.mark end)
          locals_by_buf[#locals_by_buf + 1] = {
            file    = bname,
            entries = entries,
          }
        end
      end
    end
  end
  table.sort(locals_by_buf, function(a, b)
    return _shorten_path(a.file) < _shorten_path(b.file)
  end)

  return globals, locals_by_buf
end

local function _render(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local globals, locals = _collect()
  local lines, lookup = {}, {}

  local function emit(text, rec)
    lines[#lines + 1] = text
    lookup[#lines] = rec
  end

  if #globals == 0 and #locals == 0 then
    emit("(no marks set)", nil)
    emit("", nil)
    emit("  Try `m<A-Z>` for a global mark or `m<a-z>` for a local one.", nil)
  else
    if #globals > 0 then
      emit("GLOBAL", nil)
      for _, r in ipairs(globals) do
        emit(string.format("  [%s] %s:%d   %s",
          r.mark, _shorten_path(r.file), r.line, r.preview or ""), r)
      end
      emit("", nil)
    end
    for _, grp in ipairs(locals) do
      emit("LOCAL — " .. _shorten_path(grp.file), nil)
      for _, r in ipairs(grp.entries) do
        emit(string.format("  [%s] :%d   %s",
          r.mark, r.line, r.preview or ""), r)
      end
      emit("", nil)
    end
  end

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  M._rows = lookup
end

local function _row_under_cursor(panel_winid)
  if not vim.api.nvim_win_is_valid(panel_winid) then return nil end
  local cur = vim.api.nvim_win_get_cursor(panel_winid)
  return M._rows and M._rows[cur[1]]
end

local function _jump(rec)
  if not rec then return end
  local af = require("auto-finder")
  local target = af._editor_target_winid()
  if not target then
    pcall(vim.cmd, "rightbelow vsplit "
      .. vim.fn.fnameescape(rec.file))
    target = vim.api.nvim_get_current_win()
  else
    pcall(vim.api.nvim_set_current_win, target)
    -- Reuse the bufnr when it's still loaded — preserves the
    -- buffer's own marks / undo state. Otherwise edit by path.
    if rec.bufnr and vim.api.nvim_buf_is_valid(rec.bufnr) then
      pcall(vim.api.nvim_set_current_buf, rec.bufnr)
    else
      pcall(vim.cmd, "edit " .. vim.fn.fnameescape(rec.file))
    end
  end
  if rec.line and rec.line > 0
      and vim.api.nvim_win_is_valid(target) then
    pcall(vim.api.nvim_win_set_cursor, target,
      { rec.line, math.max(0, (rec.col or 1) - 1) })
  end
end

local function _delete(rec, panel_winid)
  if not rec then return end
  local mark_arg = "'" .. rec.mark
  if rec.kind == "global" then
    pcall(vim.fn.setpos, mark_arg, { 0, 0, 0, 0 })
  else
    -- Local marks must be cleared in the owning buffer's context.
    if rec.bufnr and vim.api.nvim_buf_is_valid(rec.bufnr) then
      pcall(vim.api.nvim_buf_call, rec.bufnr, function()
        vim.fn.setpos(mark_arg, { rec.bufnr, 0, 0, 0 })
      end)
    end
  end
  if vim.api.nvim_win_is_valid(panel_winid) then
    local bufnr = vim.api.nvim_win_get_buf(panel_winid)
    _render(bufnr)
  end
end

-- True when our marks buffer is currently displayed in some window
-- (any window, not just the panel — the panel's winid changes over
-- the session and we'd rather not track it here).
local function _is_visible()
  if not M._bufnr or not vim.api.nvim_buf_is_valid(M._bufnr) then
    return false
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w)
        and vim.api.nvim_win_get_buf(w) == M._bufnr then
      return true
    end
  end
  return false
end

-- Install the auto-refresh autocmds. Idempotent — re-creating the
-- augroup with `clear = true` drops any prior bindings, so calling
-- this on every `get_buffer` is safe. Refresh is gated on
-- `_is_visible()` so we don't pay the render cost when the panel
-- is hidden (the next focus will re-render anyway).
local function _ensure_autocmds()
  M._augroup = vim.api.nvim_create_augroup(
    "AutoFinderMarksRefresh", { clear = true })
  vim.api.nvim_create_autocmd({ "BufWritePost", "CursorHold" }, {
    group = M._augroup,
    callback = function()
      if _is_visible() then _render(M._bufnr) end
    end,
    desc = "auto-finder.marks: refresh on BufWritePost / CursorHold "
      .. "when the marks panel is visible",
  })
end

local function _apply_keymaps(bufnr, panel_winid)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local set = function(lhs, fn, desc)
    pcall(vim.keymap.set, "n", lhs, fn, {
      buffer = bufnr, silent = true, nowait = true, desc = desc,
    })
  end
  set("<CR>", function() _jump(_row_under_cursor(panel_winid)) end,
    "auto-finder.marks: jump to mark")
  set("d", function() _delete(_row_under_cursor(panel_winid), panel_winid) end,
    "auto-finder.marks: delete mark (delmarks)")
  set("R", function() _render(bufnr) end,
    "auto-finder.marks: refresh")
end

function M.get_buffer(panel_winid)
  if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
    _apply_keymaps(M._bufnr, panel_winid)
    _ensure_autocmds()
    return M._bufnr
  end
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = "hide"
  vim.bo[b].buftype   = "nofile"
  vim.bo[b].swapfile  = false
  vim.bo[b].filetype  = FILETYPE
  pcall(vim.api.nvim_buf_set_name, b, "auto-finder://marks")
  _render(b)
  _apply_keymaps(b, panel_winid)
  M._bufnr = b
  _ensure_autocmds()
  return b
end

function M.on_focus(panel_winid, bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  _render(bufnr)
  _apply_keymaps(bufnr, panel_winid)
end

function M.on_close()
  if M._augroup then
    pcall(vim.api.nvim_del_augroup_by_id, M._augroup)
    M._augroup = nil
  end
  if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
    pcall(vim.api.nvim_buf_delete, M._bufnr, { force = true })
  end
  M._bufnr = nil
  M._rows = nil
end

-- Test-only — production code never calls this.
function M._reset_for_tests()
  M.on_close()
end

return M