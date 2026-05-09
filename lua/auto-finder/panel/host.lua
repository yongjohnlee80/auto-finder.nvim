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

---Cache the panel width on state, mirror it into neo-tree's runtime
---config so a subsequent standalone `:Neotree` invocation lines up
---with the panel, AND invalidate the per-state `win_width` cache on
---every live neo-tree state for the panel window so right-aligned
---components re-position against the actual width on next render.
---@param state table
---@param width integer
local function set_panel_width(state, width)
  state.panel_width = width
  local ok, neo = pcall(require, "auto-finder.neotree")
  if ok and type(neo.config) == "table" and type(neo.config.window) == "table" then
    neo.config.window.width = width
  end
  -- Cross-source: invalidate every state attached to the panel
  -- window so right-aligned icons (modified / diagnostics /
  -- git_status) realign on next render. Without this, neo-tree
  -- positions them against a stale state.win_width that was set
  -- when auto_expand_width grew the window above auto-finder's
  -- pin.
  local ok_mgr, manager = pcall(require, "auto-finder.neotree.sources.manager")
  if ok_mgr and type(manager._for_each_state) == "function"
      and state.panel_winid and vim.api.nvim_win_is_valid(state.panel_winid) then
    pcall(manager._for_each_state, nil, function(s)
      if s.winid == state.panel_winid then
        s.win_width = width
        s.longest_node = nil  -- forces a fresh pre-render so the
                              -- container's truncation math runs
                              -- against the new width
      end
    end)
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
  -- would arrive carrying a buffer with `filetype = "auto-finder.neotree"` and a
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
-- forced it off — captured lazily on the first toggle so reset_width
-- can restore the user's actual default rather than hard-coding `true`.
local original_auto_expand = nil

local function snapshot_auto_expand_default()
  if original_auto_expand ~= nil then return end
  local ok, neo = pcall(require, "auto-finder.neotree")
  if not ok then
    original_auto_expand = false  -- neo-tree's own default (defaults.lua:391)
    return
  end
  -- neo-tree's config is lazy: setup() only stages user_config; M.config
  -- is populated by the first ensure_config() call. Force materialization
  -- so we read the post-merge value, otherwise we'd snapshot the bare
  -- defaults and a `panel reset` would restore to false even when the
  -- consumer configured `auto_expand_width = true`.
  if type(neo.ensure_config) == "function" then
    pcall(neo.ensure_config)
  end
  if type(neo.config) ~= "table" or type(neo.config.window) ~= "table" then
    original_auto_expand = false
    return
  end
  local cur = neo.config.window.auto_expand_width
  original_auto_expand = (cur == nil) and false or cur
end

---Toggle neo-tree's filesystem `auto_expand_width` globally for the
---session. Without this, render_tree keeps calling nvim_win_set_width
---to expand the panel to fit the longest node — fighting our pin in a
---ping-pong with WinResized's enforce_pin clamp. The previous
---per-window approach only worked when the panel currently held a
---neo-tree buffer; toggling from the config REPL was a silent no-op
---because the lookup failed against the REPL buffer. So we now mutate
---both the live config (so newly-created states inherit the value)
---*and* every existing filesystem state, which catches the case where
---the user pins from one section and then switches to files.
---@param enabled boolean
local function set_neotree_auto_expand(enabled)
  snapshot_auto_expand_default()
  -- 1. Update the global config so future state creations inherit it.
  local ok_neo, neo = pcall(require, "auto-finder.neotree")
  if ok_neo and type(neo.ensure_config) == "function" then
    pcall(neo.ensure_config)
  end
  if ok_neo and type(neo.config) == "table" and type(neo.config.window) == "table" then
    neo.config.window.auto_expand_width = enabled
  end
  -- 2. Mutate every live filesystem state so the next render — even
  -- one already mid-flight from neo-tree's setup pipeline — picks up
  -- the new value. This is what actually breaks the ping-pong.
  local ok_mgr, manager = pcall(require, "auto-finder.neotree.sources.manager")
  if ok_mgr and type(manager._for_each_state) == "function" then
    pcall(manager._for_each_state, "filesystem", function(state)
      if type(state.window) == "table" then
        state.window.auto_expand_width = enabled
      end
    end)
  end
end

---Public: restore neo-tree's auto_expand_width to the value it held
---before we first forced it off. Used by reset_width and by the files
---section mount when no pin is active.
function M._restore_neotree_auto_expand()
  snapshot_auto_expand_default()
  set_neotree_auto_expand(original_auto_expand)
end

---Public: sync neo-tree's auto_expand_width to whatever the current
---pin state demands. Called from sections/files.lua right after
---mount_neotree so a freshly-created filesystem state can't race
---ahead of the pin.
---@param state table  -- M.state from auto-finder
function M._sync_neotree_auto_expand(state)
  if state.user_width and state.user_width > 0 then
    set_neotree_auto_expand(false)
  else
    M._restore_neotree_auto_expand()
  end
end

---Pin the panel width to N columns. Survives :VimResized. Also
---disables neo-tree's auto_expand_width on the live state so it
---can't fight the pin in a ping-pong.
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
  set_neotree_auto_expand(false)
  if panel_is_open(state) then
    pcall(vim.api.nvim_win_set_width, state.panel_winid, n)
    set_panel_width(state, n)
    M.refresh_winbar(state)
  end
  -- Persist so the pin survives nvim restart.
  require("auto-finder.store").update({ panel = { user_width = n } })
end

---Clear the user-pinned width. Width reverts to the configured
---default and neo-tree's auto_expand_width is re-enabled so the
---panel can grow to fit longer filenames again. Aliased as
---`panel dynamic` in the admin DSL.
---@param cfg AutoFinderConfig
---@param state table
function M.reset_width(cfg, state)
  state.user_width = nil
  M._restore_neotree_auto_expand()
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

---WinResized callback: re-clamp the panel back to the user pin when
---an external resize (e.g. neo-tree's `auto_expand_width`) bypassed
---our cached value. **Only fires when a pin is set** — without a pin
---we deliberately let neo-tree grow the panel dynamically (that's
---the whole point of `panel dynamic`). Pair this with
---`set_neotree_auto_expand(false)` from `M.resize` so we don't
---ping-pong with neo-tree's renderer.
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
