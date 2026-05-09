---auto-finder.nvim — multi-section file explorer.
---
---Public surface; see docs/adr/0001-auto-finder-design.md for the
---full design.
---@module 'auto-finder'

local M = {}

M.version = "0.1.4"

---Public-surface accessor for the registered-repos registry. Lazy-
---loaded so consumers can `require("auto-finder").repos.add(path)`
---directly. The underlying module owns persistence + neo-tree
---source notification.
M.repos = setmetatable({}, {
  __index = function(_, k) return require("auto-finder.repos")[k] end,
})

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

  -- Forward the consumer's `cfg.neo_tree` table to our forked
  -- neo-tree's setup. Phase 5: this is what gets consumer-side
  -- `filtered_items`, `components`, `window.auto_expand_width`, etc.
  -- to the fork rather than the upstream `neo-tree.nvim` plugin —
  -- which used to lose the race because both shipped `lua/neo-tree.lua`.
  -- Calling our setup() unconditionally is idempotent (neo-tree's
  -- ensure_config caches the merge result and won't re-merge unless
  -- new_user_config was staged).
  pcall(function()
    require("auto-finder.neotree").setup(cfg.neo_tree or {})
  end)

  -- If `repos` is enabled, register the auto-finder-repos source with
  -- neo-tree so `cmd.execute({ source = "auto-finder-repos" })` works.
  -- Order: section registry first (so we know whether repos is enabled),
  -- then neo-tree setup (just above), THEN source registration before
  -- any section mount can fire.
  if require("auto-finder.sections")._by_name["repos"] then
    M._register_neotree_workspace_source(cfg.repos)
  end

  -- Restore persisted user state (panel pin, last section, files
  -- filter prefs). Missing or malformed files fall back to defaults
  -- silently — see auto-finder.store for the schema.
  local persisted = require("auto-finder.store").load()
  if persisted.panel then
    if type(persisted.panel.user_width) == "number"
        and persisted.panel.user_width >= cfg.width.min
        and persisted.panel.user_width <= cfg.width.max then
      M.state.user_width = persisted.panel.user_width
    end
    -- Restore the last-active section so the panel reopens on the
    -- same slot the user was on. Validated against the live section
    -- registry so a stored index for a now-disabled section silently
    -- falls back to default_section.
    if type(persisted.panel.last_section) == "number"
        and require("auto-finder.sections").resolve(persisted.panel.last_section) then
      M.state.section = persisted.panel.last_section
    end
    -- The `side` field was removed from the config. We deliberately do
    -- NOT apply persisted.panel.side here — the panel is always
    -- left-anchored now. Old store files containing `side` are left
    -- intact on disk so a downgrade still finds them.
  end
  -- Phase 3c note: previously re-synced
  -- `state.window.auto_expand_width` here so a session restart with
  -- a saved pin wouldn't expand on first files focus. The forked
  -- renderer now reads `M.state.user_width` directly each render —
  -- the persisted pin is already in `M.state.user_width` by this
  -- point in setup, so the renderer sees the pin from its very
  -- first call. No manual sync needed.
  if persisted.files then
    local ok, neo = pcall(require, "auto-finder.neotree")
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

  -- Directory hijack — ONE-SHOT firing as early as we can manage so
  -- we win against other directory-hijacking autocmds (LazyVim's
  -- snacks-explorer, oil.nvim's auto-detect, dirbuf, etc.) that
  -- typically fire on BufEnter.
  --
  -- We register both BufEnter (early — fires before VimEnter for the
  -- initial buffer) AND VimEnter (fallback — covers the case where
  -- the BufEnter for the initial buffer fired before our setup
  -- completed, e.g. when auto-finder is lazy-loaded VeryLazy). The
  -- `once = true` + the internal `M._hijack_done` guard make this
  -- idempotent; the first hijack wins, subsequent fires no-op.
  --
  -- v0.1.3 phase 6: pulled forward from VimEnter-only because
  -- snacks-explorer / LazyVim's Explorer otherwise grab the initial
  -- directory buffer before our VimEnter fires and we never get a
  -- chance to hijack.
  if cfg.hijack_directories then
    vim.api.nvim_create_autocmd("BufEnter", {
      group = group,
      once = true,
      desc = "auto-finder: directory hijack on first BufEnter",
      callback = function()
        M._maybe_hijack_startup_directory()
      end,
    })
    vim.api.nvim_create_autocmd("VimEnter", {
      group = group,
      once = true,
      desc = "auto-finder: directory hijack fallback at VimEnter",
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

---Register the `auto-finder-repos` neo-tree source so
---`cmd.execute({ source = "auto-finder-repos", … })` works inside the
---repos section.
---
---Neo-tree's normal setup pipeline (setup/init.lua's per-source loop
---around line 525-660) does several things our source needs:
---
---  1. Builds `nt.config[source_name]` with `components`, `commands`,
---     `renderers`, and a merged `window` block. `cmd.execute` reads
---     `nt.config[source].window.position` directly, so this entry
---     MUST exist or focus crashes with
---     `attempt to index field … (a nil value)`.
---  2. Calls `manager.setup(source_name, source_config, global_config,
---     module)` which sets the per-source default config in the source
---     data table AND stashes the module reference (used by command
---     wrappers and `manager.get_state(source_name)`).
---
---We replicate enough of that pipeline here that a `cmd.execute` call
---against `auto-finder-repos` flows through cleanly. Base config is
---deep-copied from neo-tree's filesystem source so we inherit a
---working renderers / window-mappings shape; our source's own
---`default_config` and the consumer's `cfg.repos` are layered on top.
---@param extra table?  -- consumer overrides to merge atop the source defaults
function M._register_neotree_workspace_source(extra)
  local ok_neo, neo = pcall(require, "auto-finder.neotree")
  if not ok_neo then return end
  if type(neo.ensure_config) == "function" then
    pcall(neo.ensure_config)
  end
  if type(neo.config) ~= "table" then return end

  local ok_src, src = pcall(require, "auto-finder-repos")
  if not ok_src then
    vim.notify("auto-finder: failed to require 'auto-finder-repos': " .. tostring(src),
      vim.log.levels.ERROR)
    return
  end

  -- Per-source config. Order (later wins):
  --   1. filesystem source as a base (gives renderers + working window mappings)
  --   2. our overrides (name, display_name, our components + commands)
  --   3. our source's `default_config` (own keymaps inside the panel)
  --   4. consumer's `cfg.repos` (their keymaps / overrides)
  local base = vim.deepcopy(neo.config.filesystem or {})
  local components_ok, components = pcall(require, "auto-finder-repos.components")
  local commands_ok, commands = pcall(require, "auto-finder-repos.commands")
  local source_config = vim.tbl_deep_extend("force",
    base,
    {
      name = "auto-finder-repos",
      display_name = src.display_name or " Git ",
      components = components_ok and components or nil,
      commands = commands_ok and commands or nil,
    },
    src.default_config or {},
    extra or {})

  -- Make the per-source config visible to `cmd.execute` and friends.
  neo.config["auto-finder-repos"] = source_config

  -- Add to neo.config.sources so future ensure_config / setup re-runs
  -- include us when iterating known sources.
  neo.config.sources = neo.config.sources or { "filesystem", "buffers", "git_status" }
  local already_listed = false
  for _, s in ipairs(neo.config.sources) do
    if s == "auto-finder-repos" then already_listed = true; break end
  end
  if not already_listed then
    table.insert(neo.config.sources, "auto-finder-repos")
  end

  -- Run the manager-side setup so `manager.get_state("auto-finder-repos")`
  -- can find us, and so the source's own `setup()` (no-op for us) is
  -- invoked symmetrically with neo-tree's built-in sources.
  local ok_mgr, manager = pcall(require, "auto-finder.neotree.sources.manager")
  if ok_mgr and type(manager.setup) == "function" then
    pcall(manager.setup, "auto-finder-repos", source_config, neo.config, src)
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

---Re-render the active section. Calls the section's `on_close`
---hook (which wipes any cached neo-tree buffer for neo-tree-backed
---sections) and then re-focuses, so the next mount picks up any
---runtime config change (e.g. after `files show/hide …` mutated
---neo-tree's filtered_items, or after `repos add` changed the
---registry).
function M.reload()
  local section = require("auto-finder.sections").resolve(M.state.section or 0)
  if not section then return end
  if M.state.section_buffers then
    M.state.section_buffers[section.number] = nil
  end
  if type(section.on_close) == "function" then pcall(section.on_close) end
  M.focus(section.number)
end

return M
