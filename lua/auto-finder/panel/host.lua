---Panel host — owns the single vsplit window that auto-finder lives in
---and exposes a small surface for opening, closing, focusing sections,
---and resizing.
---
---State (cached on require("auto-finder").state):
---   panel_winid : the active vsplit's winid (nil when closed)
---   panel_width : the column count the window currently sits at
---   user_width  : sticky pin set by `panel resize N`; cleared by `panel reset`
---   section     : numeric index of the currently-displayed section
---@module 'auto-finder.panel.host'

local M = {}

---@param state table
---@return boolean
local function panel_is_open(state)
  return state.panel_winid ~= nil
    and vim.api.nvim_win_is_valid(state.panel_winid)
end

---Run `fn` with the panel's `winfixbuf` temporarily disabled so our
---own legitimate buffer swaps (section mount, scratch swap on open)
---aren't blocked by the same option that protects the panel from
---external `:edit` / `:buffer` / bufferline-click hijacks. Restores
---the prior winfixbuf state before returning.
---@param winid integer|nil
---@param fn fun(): any
---@return boolean ok, any result_or_err
local function with_unfixed_buf(winid, fn)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return pcall(fn)
  end
  local was = vim.wo[winid].winfixbuf
  if was then vim.wo[winid].winfixbuf = false end
  local ok, result = pcall(fn)
  if was and vim.api.nvim_win_is_valid(winid) then
    vim.wo[winid].winfixbuf = true
  end
  return ok, result
end

---Resolve the column count we should render the panel at. Honours
---the user pin if one is set; otherwise uses the percentage path.
---@param cfg AutoFinderConfig
---@param state table
---@return integer
local function resolve_width(cfg, state)
  if state.user_width and state.user_width > 0 then
    return state.user_width
  end
  return require("auto-finder.config").resolve_width(cfg, vim.o.columns)
end

---Cache the panel width on state and mirror it into neo-tree's
---runtime config so any path that reads `neo.config.window.width`
---(e.g. an external `:Neotree` invocation) lines up with the panel.
---
---Phase 3b note: previously this also invalidated `state.win_width`
---on every live neo-tree state so right-aligned components would
---re-position. That work is now obsolete — `auto-finder.neotree`'s
---`renderer.lua:439` always reads the live window width via
---`nvim_win_get_width`, so there's no cache to invalidate.
---@param state table
---@param width integer
local function set_panel_width(state, width)
  state.panel_width = width
  local ok, neo = pcall(require, "auto-finder.neotree")
  if ok and type(neo.config) == "table" and type(neo.config.window) == "table" then
    neo.config.window.width = width
  end
end

---Apply our buffer-local section-switch keymap (0..9 in normal mode)
---to a buffer. Idempotent: safe to call repeatedly on the same buffer.
---@param bufnr integer
local function apply_section_keymap(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  for i = 0, 9 do
    pcall(vim.keymap.set, "n", tostring(i), function()
      require("auto-finder").focus(i)
    end, {
      buffer = bufnr,
      silent = true,
      nowait = true,
      desc = "auto-finder: focus section " .. i,
    })
  end
end

---Open the panel window if not already open. Returns its winid.
---@param cfg AutoFinderConfig
---@param state table
---@param force boolean?
---@return integer|nil
function M.ensure_open(cfg, state, force)
  if panel_is_open(state) then return state.panel_winid end

  local cols = vim.o.columns
  if not force and cols < cfg.width.min + 20 then
    vim.notify(
      "auto-finder: terminal width " .. cols .. " too narrow; use :AutoFinder! to force",
      vim.log.levels.WARN)
    return nil
  end

  local width = resolve_width(cfg, state)
  -- Panel is left-anchored by design (the side option was removed in
  -- v0.1.x — the right slot belongs to auto-agents and the <F5>
  -- terminal). Hard-code `topleft`.
  local placement = "topleft"
  -- The new vsplit inherits the source window's buffer. If we were sitting
  -- in a neo-tree window (e.g. the autostart from `nvim .`), the panel
  -- would arrive carrying a buffer with `filetype = "neo-tree"` and a
  -- `neo_tree_position` buffer var. neo-tree's command override
  -- (command/init.lua:155) then rewrites any subsequent
  -- `position = "current"` to whatever the inherited buffer says — and
  -- our mount goes to the wrong window.
  --
  -- Suppress autocmds during the split so the inherited buffer doesn't
  -- fire its own BufWinEnter handlers (notably bufferline / neo-tree
  -- redirect logic) inside our half-built panel, then immediately swap
  -- in a private scratch buffer to break inheritance.
  local saved_eventignore = vim.o.eventignore
  vim.o.eventignore = "all"
  local ok_cmd, err_cmd = pcall(vim.cmd, placement .. " " .. width .. "vsplit")
  local winid = vim.api.nvim_get_current_win()
  if ok_cmd then
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.bo[scratch].bufhidden = "wipe"
    vim.bo[scratch].buftype = "nofile"
    vim.bo[scratch].swapfile = false
    pcall(vim.api.nvim_win_set_buf, winid, scratch)
  end
  vim.o.eventignore = saved_eventignore
  if not ok_cmd then
    vim.notify("auto-finder: failed to open panel: " .. tostring(err_cmd),
      vim.log.levels.ERROR)
    return nil
  end
  state.panel_winid = winid
  set_panel_width(state, width)

  -- Window-local appearance: drop signs/numbers/foldcolumn — the
  -- explorer doesn't benefit from any of them.
  vim.api.nvim_set_option_value("number", false, { win = winid })
  vim.api.nvim_set_option_value("relativenumber", false, { win = winid })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = winid })
  vim.api.nvim_set_option_value("foldcolumn", "0", { win = winid })

  -- Lock the panel width so :wincmd = (equalize) and similar layout
  -- ops don't squash us. Direct nvim_win_set_width still works.
  vim.api.nvim_set_option_value("winfixwidth", true, { win = winid })

  -- Lock the panel BUFFER too — winfixbuf makes vim refuse to
  -- replace this window's buffer via :edit / :buffer / b#. neo-tree
  -- sees the resulting E1513 and falls back to a sibling window
  -- (utils/init.lua:861 — winfixbuf-aware fallback). Bufferline
  -- tab-clicks while focused on the panel will surface E1513 to the
  -- user, which is the correct signal that the panel doesn't host
  -- arbitrary buffers. Our own section-mount swaps temporarily
  -- disable winfixbuf via with_unfixed_buf in M.focus.
  vim.api.nvim_set_option_value("winfixbuf", true, { win = winid })

  return winid
end

---Expose the unfix helper for callers that need to swap the panel
---buffer outside the focus path (e.g. files.lua's mount_neotree
---which drives neo-tree's command surface).
---@param winid integer|nil
---@param fn fun(): any
---@return boolean ok, any result_or_err
function M.with_unfixed_buf(winid, fn)
  return with_unfixed_buf(winid, fn)
end

---Close the panel window. Sections get an `on_close` hook to clean
---up any external state that would otherwise crash on reopen
---(notably: the files section deletes its cached neo-tree buffer
---so neo-tree's win_enter_event redirect doesn't fire on a stale
---`state.tree = nil`).
---@param state table
function M.close(state)
  -- Fire on_close for every section that has cached state — not just
  -- the focused one, because all of them may have hooked external
  -- resources (neo-tree state per winid, terminals, etc.) and the
  -- panel window is going away.
  local sections = require("auto-finder.sections").enabled()
  for _, section in ipairs(sections) do
    if type(section.on_close) == "function" then
      pcall(section.on_close)
    end
  end
  state.section_buffers = {}
  if panel_is_open(state) then
    pcall(vim.api.nvim_win_close, state.panel_winid, true)
  end
  state.panel_winid = nil
end

---Re-render the winbar tab-strip. No-op when the panel isn't open.
---@param state table
function M.refresh_winbar(state)
  if not panel_is_open(state) then return end
  local winbar = require("auto-finder.panel.winbar")
  winbar.ensure_highlights()
  local sections = require("auto-finder.sections").enabled()
  local w = vim.api.nvim_win_get_width(state.panel_winid)
  pcall(vim.api.nvim_set_option_value, "winbar",
    winbar.render(state.section or 0, sections, w),
    { win = state.panel_winid })
end

---Switch the panel to a section by numeric index or name.
---@param cfg AutoFinderConfig
---@param state table
---@param key integer|string
---@return boolean ok
---@return string|nil err
function M.focus(cfg, state, key)
  local sections = require("auto-finder.sections")
  local section = sections.resolve(key)
  if not section then
    return false, "no such section '" .. tostring(key) .. "'"
  end

  local winid = M.ensure_open(cfg, state, false)
  if not winid then return false, "panel could not be opened" end

  -- Section modules (notably files/neo-tree) drive neo-tree's command
  -- surface inside get_buffer, which calls :edit-style ops in the
  -- panel. Disable winfixbuf for the duration of the mount; the
  -- buffer locks back when we return.
  local ok_section, bufnr_or_err = with_unfixed_buf(winid, function()
    return section.get_buffer(winid)
  end)
  if not ok_section then
    return false, "section '" .. section.name .. "' get_buffer error: " .. tostring(bufnr_or_err)
  end
  local bufnr = bufnr_or_err
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false, "section '" .. section.name .. "' returned no buffer"
  end

  -- Place the buffer in the panel window, focus it, and let the
  -- section run its on_focus hook (cursor placement, mode switch,
  -- per-focus keymaps, etc). nvim_win_set_buf respects winfixbuf, so
  -- wrap the swap in with_unfixed_buf.
  with_unfixed_buf(winid, function()
    pcall(vim.api.nvim_win_set_buf, winid, bufnr)
  end)
  pcall(vim.api.nvim_set_current_win, winid)
  state.section = section.number
  state.section_buffers = state.section_buffers or {}
  state.section_buffers[section.number] = bufnr

  -- Persist the active section so the next `nvim` session reopens
  -- on the same slot. Best-effort — store.update wraps its own I/O
  -- in pcalls and notifies on failure, so we never block focus.
  pcall(function()
    require("auto-finder.store").update({ panel = { last_section = section.number } })
  end)

  -- Section-switch keymap is buffer-local; reapply each focus so
  -- buffers that get clobbered by their owner (e.g. neo-tree
  -- recreating its buffer) keep our 0..N hotkeys.
  apply_section_keymap(bufnr)

  if type(section.on_focus) == "function" then
    with_unfixed_buf(winid, function()
      pcall(section.on_focus, winid, bufnr)
    end)
  end

  M.refresh_winbar(state)
  return true, nil
end

-- Snapshot of neo-tree's auto_expand_width as it was before we first
-- Phase 3c note: the v0.1.x wrapper-side auto-expand machinery used
-- to live here — `original_auto_expand` snapshot,
-- `snapshot_auto_expand_default()`, `set_neotree_auto_expand()`,
-- `M._restore_neotree_auto_expand()`, `M._sync_neotree_auto_expand()`,
-- the `manager._for_each_state` iteration that toggled
-- `state.window.auto_expand_width` on every live filesystem state.
--
-- All gone. The forked renderer (`auto-finder.neotree.ui.renderer`'s
-- `render_tree`) reads `auto-finder.state.user_width` directly each
-- render and skips the auto-expand branch when a pin is set. The
-- consumer's `state.window.auto_expand_width` is honored as-is when
-- not pinned, so dynamic mode still grows on long filenames. The
-- ~100 lines of wrapper indirection that used to sit here are no
-- longer needed.

---Pin the panel width to N columns. Survives :VimResized.
---
---Phase 3c note: the previous version called
---`set_neotree_auto_expand(false)` here to disable auto-expand on
---every live filesystem state. That's no longer needed — the
---forked `render_tree` reads `auto-finder.state.user_width`
---directly each render and skips the auto-expand branch when a pin
---is set. Setting `state.user_width` is enough.
---@param cfg AutoFinderConfig
---@param state table
---@param n integer
function M.resize(cfg, state, n)
  if type(n) ~= "number" or n < 1 then
    vim.notify("auto-finder: resize N must be a positive integer", vim.log.levels.ERROR)
    return
  end
  local w = cfg.width
  if w and (n < (w.min or 1) or n > (w.max or math.huge)) then
    vim.notify(
      string.format("auto-finder: resize %d out of range [%d..%d]", n, w.min, w.max),
      vim.log.levels.ERROR)
    return
  end
  state.user_width = n
  if panel_is_open(state) then
    pcall(vim.api.nvim_win_set_width, state.panel_winid, n)
    set_panel_width(state, n)
    M.refresh_winbar(state)
  end
  -- Persist so the pin survives nvim restart.
  require("auto-finder.store").update({ panel = { user_width = n } })
end

---Clear the user-pinned width. Width reverts to the configured
---default; auto_expand_width re-engages on the next render because
---the forked renderer's pin-check sees `state.user_width = nil`.
---Aliased as `panel dynamic` in the admin DSL.
---@param cfg AutoFinderConfig
---@param state table
function M.reset_width(cfg, state)
  state.user_width = nil
  if panel_is_open(state) then
    local w = resolve_width(cfg, state)
    pcall(vim.api.nvim_win_set_width, state.panel_winid, w)
    set_panel_width(state, w)
    M.refresh_winbar(state)
  end
  -- Persist nil so a future restart starts in dynamic mode again.
  require("auto-finder.store").update({ panel = { user_width = vim.NIL } })
end

---Refresh the panel width from cfg + cols. Honours the user pin —
---only the percentage-derived default reflows on terminal resize.
---@param cfg AutoFinderConfig
---@param state table
function M.refresh_width(cfg, state)
  if not panel_is_open(state) then return end
  local w = resolve_width(cfg, state)
  pcall(vim.api.nvim_win_set_width, state.panel_winid, w)
  set_panel_width(state, w)
  M.refresh_winbar(state)
end

---WinResized callback: re-clamp the panel back to the user pin
---when an external resize (window-equalize, etc.) grew it past the
---pin. **Only fires when a pin is set** — without a pin we
---deliberately let the renderer grow the panel dynamically (that's
---the whole point of `panel dynamic`). Pairs with the renderer-
---side pin check in `auto-finder.neotree.ui.renderer.render_tree`
---which prevents auto-expand from firing under a pin in the first
---place — this autocmd handles the rarer "non-renderer resized us"
---path.
---@param cfg AutoFinderConfig
---@param state table
function M.enforce_pin(cfg, state)
  if not panel_is_open(state) then return end
  if not (state.user_width and state.user_width > 0) then
    -- Dynamic mode — don't fight neo-tree.
    return
  end
  local live = vim.api.nvim_win_get_width(state.panel_winid)
  if live == state.user_width then return end
  pcall(vim.api.nvim_win_set_width, state.panel_winid, state.user_width)
  set_panel_width(state, state.user_width)
  M.refresh_winbar(state)
end

return M
