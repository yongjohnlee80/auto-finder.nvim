---auto-finder.nvim — multi-section file explorer.
---
---Public surface; see docs/adr/0001-auto-finder-design.md for the
---full design.
---@module 'auto-finder'

local M = {}

M.version = "0.1.1"

---@class AutoFinderState
---@field config AutoFinderConfig|nil
---@field panel_winid integer|nil
---@field panel_width integer|nil
---@field user_width integer|nil
---@field section integer|nil
---@field section_buffers table<integer, integer>
M.state = {
  config = nil,
  panel_winid = nil,
  panel_width = nil,
  user_width = nil,
  section = nil,
  section_buffers = {},
}

---Initialize the plugin. Idempotent — re-calling re-applies opts.
---@param user_opts table?
function M.setup(user_opts)
  local cfg = require("auto-finder.config").apply(user_opts)
  M.state.config = cfg

  -- Build / rebuild the section registry.
  require("auto-finder.sections").setup(cfg.sections)

  -- Restore persisted user state (panel pin, side override, files
  -- filter prefs). Missing or malformed files fall back to defaults
  -- silently — see auto-finder.store for the schema.
  local persisted = require("auto-finder.store").load()
  if persisted.panel then
    if type(persisted.panel.user_width) == "number"
        and persisted.panel.user_width >= cfg.width.min
        and persisted.panel.user_width <= cfg.width.max then
      M.state.user_width = persisted.panel.user_width
    end
    -- The `side` field was removed from the config. We deliberately do
    -- NOT apply persisted.panel.side here — the panel is always
    -- left-anchored now. Old store files containing `side` are left
    -- intact on disk so a downgrade still finds them.
  end
  -- Sync neo-tree's auto_expand_width with whatever pin state we
  -- ended up with after the persisted load. Without this, a session
  -- that restarts with a saved pin would still create the first
  -- filesystem state with auto_expand_width=true (LazyVim consumer
  -- default), expand the panel on first files focus, and only
  -- recover after the next resize/reset call.
  require("auto-finder.panel.host")._sync_neotree_auto_expand(M.state)
  if persisted.files then
    local ok, neo = pcall(require, "neo-tree")
    if ok and type(neo.config) == "table" then
      neo.config.filesystem = neo.config.filesystem or {}
      neo.config.filesystem.filtered_items = neo.config.filesystem.filtered_items or {}
      local fi = neo.config.filesystem.filtered_items
      if persisted.files.hide_dotfiles ~= nil then
        fi.hide_dotfiles = persisted.files.hide_dotfiles
      end
      if persisted.files.hide_gitignored ~= nil then
        fi.hide_gitignored = persisted.files.hide_gitignored
      end
    end
  end

  -- VimResized keeps the panel width in sync with the terminal,
  -- but only the percentage-derived default reflows — a user pin
  -- (`panel resize N`) survives.
  local group = vim.api.nvim_create_augroup("AutoFinderPanel", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      require("auto-finder.panel.host").refresh_width(M.state.config, M.state)
    end,
  })

  -- WinResized re-clamps the panel back to the user pin if anyone
  -- (notably neo-tree's `auto_expand_width`, which calls
  -- `nvim_win_set_width` directly and bypasses both our cached width
  -- and `winfixwidth`) grew the panel beyond the pin. This is what
  -- makes `panel resize N` a hard cap as opposed to a soft default.
  -- WinResized fires for every resized window in v[].event; we only
  -- care if the panel was one of them.
  vim.api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      require("auto-finder.panel.host").enforce_pin(M.state.config, M.state)
    end,
  })

  -- (BufWinEnter/BufEnter bounce-guard removed in v0.1.1+2. We now
  -- protect the panel via `winfixbuf = true` set in panel/host.lua's
  -- ensure_open; vim itself refuses to swap the panel's buffer via
  -- :edit / :buffer / b#, neo-tree's open_file handler catches the
  -- E1513 and falls back to a sibling window, and our own legitimate
  -- swaps wrap with with_unfixed_buf. The previous bounce mechanism
  -- caused duplicate-neo-tree windows when `find_or_create_target_window`
  -- fell through to vsplit and the new window inherited the panel's
  -- neo-tree buffer.)

  -- Directory hijack — ONE-SHOT only at VimEnter (covers `nvim .`
  -- and `nvim /path/to/dir`). Per-BufEnter polling caused multi-panel
  -- regressions in v0.1.1; this one-shot fires once after startup
  -- and never again, so it can't compete with neo-tree's own buffer
  -- churn.
  if cfg.hijack_directories then
    vim.api.nvim_create_autocmd("VimEnter", {
      group = group,
      once = true,
      callback = function()
        M._maybe_hijack_startup_directory()
      end,
    })
    -- VimEnter has already fired by the time setup runs in some
    -- scenarios (notably eager `lazy = false` plugins evaluating
    -- AFTER nvim's own VimEnter). vim.fn.has("vim_starting") tells us
    -- whether we're still in startup; if not, do the check now.
    if vim.v.vim_did_enter == 1 then
      vim.schedule(function() M._maybe_hijack_startup_directory() end)
    end
  end
end

---One-shot directory hijack: if the initial buffer's name is an
---existing directory on disk, replace it with a scratch and open the
---panel. Idempotent — safe to call multiple times; only acts the
---first time it sees a directory.
function M._maybe_hijack_startup_directory()
  if M._hijack_done then return end
  local bufnr = vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return end
  if vim.fn.isdirectory(name) ~= 1 then return end
  M._hijack_done = true
  local target_dir = vim.fn.fnamemodify(name, ":p")
  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then return end
  pcall(vim.cmd, "lcd " .. vim.fn.fnameescape(target_dir))
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].bufhidden = "wipe"
  vim.bo[scratch].buftype = "nofile"
  pcall(vim.api.nvim_win_set_buf, win, scratch)
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  M.open(true)
end

-- _maybe_hijack_directory removed in v0.1.1+1. Restore via VimEnter
-- (one-shot) when re-introducing the `nvim .` flow.

---Open the panel and focus the default (or last-used) section.
---@param force boolean?
function M.open(force)
  if not M.state.config then
    vim.notify("auto-finder: setup() must be called first", vim.log.levels.ERROR)
    return
  end
  local host = require("auto-finder.panel.host")
  if not host.ensure_open(M.state.config, M.state, force) then return end
  local target = M.state.section or M.state.config.default_section
  M.focus(target)
end

---Close the panel. Section buffers survive (hidden, not wiped).
function M.close()
  require("auto-finder.panel.host").close(M.state)
end

---Toggle the panel.
---@param force boolean?
function M.toggle(force)
  if M.state.panel_winid and vim.api.nvim_win_is_valid(M.state.panel_winid) then
    M.close()
  else
    M.open(force)
  end
end

---Switch to a section by numeric index or name.
---@param key integer|string
---@return boolean ok
---@return string|nil err
function M.focus(key)
  if not M.state.config then
    return false, "auto-finder: setup() must be called first"
  end
  return require("auto-finder.panel.host").focus(M.state.config, M.state, key)
end

---Pin the panel width to N columns; survives :VimResized.
---@param n integer
function M.resize(n)
  if not M.state.config then return end
  require("auto-finder.panel.host").resize(M.state.config, M.state, n)
end

---Clear the user-pinned width.
function M.reset_width()
  if not M.state.config then return end
  require("auto-finder.panel.host").reset_width(M.state.config, M.state)
end

---Re-render the active section. For neo-tree-backed sections this
---drops the cached bufnr so neo-tree's command surface is re-driven
---with current config (e.g. after `files show/hide …` mutated
---neo-tree's filtered_items at runtime).
function M.reload()
  local section = require("auto-finder.sections").resolve(M.state.section or 0)
  if not section then return end
  -- Drop any cached buffer pointer so the section rebuilds it.
  if M.state.section_buffers then
    M.state.section_buffers[section.number] = nil
  end
  -- For the files section, also wipe the module-level bufnr cache
  -- and force neo-tree to discard its existing buffer so the next
  -- mount re-applies filtered_items.
  if section.name == "files" then
    local files = package.loaded["auto-finder.sections.files"]
    if files then
      if files._bufnr and vim.api.nvim_buf_is_valid(files._bufnr) then
        pcall(vim.api.nvim_buf_delete, files._bufnr, { force = true })
      end
      files._bufnr = nil
    end
  end
  if section.on_close then pcall(section.on_close) end
  M.focus(section.number)
end

return M
