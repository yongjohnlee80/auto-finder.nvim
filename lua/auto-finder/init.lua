---auto-finder.nvim — multi-section file explorer.
---
---Public surface; see docs/adr/0001-auto-finder-design.md for the
---full design.
---@module 'auto-finder'

local M = {}

M.version = "0.2.11"

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

  -- v0.2.5: per-project sections override. If we already have a
  -- workspace key (auto-core's worktree.nvim usually captures cwd
  -- at session start and we run AFTER that), seed cfg.sections
  -- from the persisted per-project record. New / unknown projects
  -- keep the `cfg.sections` baseline from config.lua
  -- (`{ "config", "files", "repos" }`). Workspace-root changes
  -- mid-session swap via a `worktree:switched` subscription
  -- installed further below in setup().
  do
    local state_mod = require("auto-finder.state")
    state_mod.setup()  -- idempotent claim before the seed read
    local wskey = M._workspace_key()
    if wskey then
      local persisted = state_mod.get_sections_for(wskey)
      if persisted then cfg.sections = persisted end
    end
  end

  -- Build / rebuild the section registry. `cfg.section_modules`
  -- (added in v0.2.1) lets third-party plugins ship sections from
  -- arbitrary require paths; see `config.lua` for the shape.
  require("auto-finder.sections").setup(cfg.sections, cfg.section_modules)

  -- Translate `cfg.files.follow` (per-section convenience flag) into
  -- neo-tree's native `filesystem.follow_current_file = { enabled }`
  -- so the filesystem source reveals the active buffer on BufEnter.
  -- Must happen BEFORE the neotree setup call below so the merged
  -- config carries the value into the source's defaults.
  if cfg.files and cfg.files.follow ~= nil then
    cfg.neo_tree = cfg.neo_tree or {}
    cfg.neo_tree.filesystem = cfg.neo_tree.filesystem or {}
    local existing = cfg.neo_tree.filesystem.follow_current_file
    if existing == nil then
      cfg.neo_tree.filesystem.follow_current_file = {
        enabled = cfg.files.follow == true,
        leave_dirs_open = false,
      }
    elseif type(existing) == "table" and existing.enabled == nil then
      -- Don't clobber a consumer's explicit shape; only seed the
      -- enabled flag they didn't set.
      existing.enabled = cfg.files.follow == true
    end
  end

  -- v0.2.4: keymap audit (ADR 0008). Inject our overrides into
  -- cfg.neo_tree.filesystem.window.mappings BEFORE the neo-tree
  -- setup call so consumer customizations merge on top of OURS,
  -- not the bare upstream defaults. Adds:
  --   * editor-routed open/split/vsplit/tabnew/<cr>/<2-LeftMouse>
  --   * H rewired through auto-core.files.set_show_hidden
  --   * removes e / < / > / . / <esc> (replaced with "none")
  -- See `M._inject_keymap_overrides` for the full table.
  M._inject_keymap_overrides(cfg)

  -- v0.2.7: register every bundled neo-tree source we ship a
  -- section module for. Our fork's `defaults.lua` declares
  -- `sources = { "filesystem" }`, so neotree's setup pipeline
  -- only builds `default_configs["filesystem"]`. A `buffers`
  -- section then trips `assert(default_configs[sd.name])` at
  -- `manager.lua:124` because the buffers default_config was
  -- never built. Append every bundled source to `cfg.neo_tree.sources`
  -- so each one's default_config exists at section-mount time —
  -- even if the corresponding section isn't currently enabled
  -- (slot DSL may add it at runtime via `slot add <type>`).
  M._register_bundled_neotree_sources(cfg)

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

  -- v0.2.0 step 2/4: panel.user_width and panel.last_section now live
  -- in auto-core.state.namespace("auto-finder") with json persist —
  -- see lua/auto-finder/state.lua. The legacy
  -- `<config>/.auto-finder/config.json` keeps the `files.*` filter
  -- prefs for now; future cleanup migrates them.
  --
  -- Sequence:
  --   1. Claim the namespace (idempotent).
  --   2. **Validated** seed from the legacy store's `panel` block —
  --      width-range against cfg.width.min/max here, section-registry
  --      against the live registry. Out-of-range values warn and fall
  --      through to namespace default. (The store save path strips
  --      panel.user_width / panel.last_section on next save, so legacy
  --      values eventually drain from the JSON file.)
  --   3. Read the namespace back into M.state.user_width / M.state.section
  --      so the existing reader sites (winbar status, neo-tree pin
  --      check, M.open default-section fallback) keep working unchanged.
  --   4. Install watchers that re-mirror namespace → M.state on every
  --      mutation. Setters in panel/host.lua go through state_mod.set_*
  --      and trigger this.
  local state_mod = require("auto-finder.state")
  state_mod.setup()

  local persisted = require("auto-finder.store").load()
  if persisted.panel then
    if type(persisted.panel.user_width) == "number"
        and persisted.panel.user_width >= cfg.width.min
        and persisted.panel.user_width <= cfg.width.max then
      state_mod.set_user_width(persisted.panel.user_width)
    end
    -- Restore the last-active section so the panel reopens on the
    -- same slot the user was on. Validated against the live section
    -- registry so a stored index for a now-disabled section silently
    -- falls back to default_section.
    if type(persisted.panel.last_section) == "number"
        and require("auto-finder.sections").resolve(persisted.panel.last_section) then
      state_mod.set_last_section(persisted.panel.last_section)
    end
    -- The `side` field was removed from the config. We deliberately do
    -- NOT apply persisted.panel.side here — the panel is always
    -- left-anchored now. Old store files containing `side` are left
    -- intact on disk so a downgrade still finds them.
  end

  -- Read namespace values into the live runtime mirrors.
  M.state.user_width = state_mod.get_user_width()
  M.state.section    = state_mod.get_last_section()

  -- v0.2.0 step 3: claim the auto-core.ui.panel singleton. The marker
  -- name "auto-finder" produces `w:auto_finder_panel` after auto-core's
  -- `[^%w_]` -> `_` substitution — identical to the prior local marker
  -- so external readers (auto-agents's editor-floor invariant +
  -- filetype-fallback) keep working without changes. Panel also stamps
  -- the canonical `w:auto_core_panel_name = "auto-finder"` in parallel
  -- (the new universal hook).
  --
  -- on_open / on_close mirror the auto-core-owned winid back into
  -- M.state.panel_winid so the existing reader sites (panel_is_open
  -- in panel/host.lua, refresh_winbar's winid lookup, etc.) keep
  -- working unchanged.
  local panel_mod = require("auto-core").ui.panel
  M._panel = panel_mod.new({
    name     = "auto-finder",
    side     = "left",  -- hard-coded; the right slot is auto-agents.
    width    = {
      default = cfg.width.default,
      min     = cfg.width.min,
      max     = cfg.width.max,
    },
    -- filetype intentionally nil: each section mounts its own buffer
    -- with its own filetype (`auto-finder` for the neo-tree mounts,
    -- `auto-finder-config` for the prompt section). Setting a host
    -- filetype on the scratch placeholder would conflict with the
    -- inherit-guard test ([9]) and confuse neo-tree's command
    -- override which keys off the source-window's filetype.
    on_open  = function(winid)
      M.state.panel_winid = winid
      M.state.panel_width = vim.api.nvim_win_get_width(winid)
    end,
    on_close = function()
      M.state.panel_winid = nil
      -- Section on_close fanout: every cached section gets a chance
      -- to tear down external resources before the panel buffers go
      -- stale (notably: the files section deletes its cached
      -- neo-tree buffer so the next reopen re-mounts fresh; without
      -- this, neo-tree's win_enter redirect crashes on
      -- `attempt to index local 'tree' (a nil value)`).
      --
      -- We mutate `_bufs` in place rather than reassigning so the
      -- `state.section_buffers` alias stays valid.
      if M._registry then
        for _, s in ipairs(M._registry.sections) do
          local b = M._registry._bufs[s.number]
          if b and vim.api.nvim_buf_is_valid(b) and s.on_close then
            pcall(s.on_close, b)
          end
        end
        for k in pairs(M._registry._bufs) do
          M._registry._bufs[k] = nil
        end
      end
    end,
  })
  -- Apply any persisted width pin so the very first open uses it.
  if M.state.user_width then M._panel:resize(M.state.user_width) end

  -- v0.2.0 step 4: attach the auto-core section registry. Each
  -- auto-finder section is adapted to auto-core's contract — the
  -- only signature delta is `panel_winid` (integer) -> `panel`
  -- (object); auto-core's `panel.winid` field is the equivalent.
  -- The registry owns: bufnr cache, buffer-local `0..9`/`q` keymaps,
  -- buffer-swap via with_unfixed_buf, winbar refresh on every focus.
  --
  -- We override the winbar click router (auto-core's `attach()`
  -- registers one that calls `registry:focus(N)` directly) so clicks
  -- go through `M.focus(N)` instead — that's the single dispatch
  -- point that ALSO mirrors `state.section` and persists
  -- `last_section` to the namespace.
  local section_mod  = require("auto-core").ui.section
  local sections_list = require("auto-finder.sections").enabled()
  local section_defs = {}
  for _, s in ipairs(sections_list) do
    section_defs[#section_defs + 1] = {
      number     = s.number,
      name       = s.name,
      get_buffer = function(panel) return s.get_buffer(panel.winid) end,
      on_focus   = s.on_focus and function(panel, bufnr)
        return s.on_focus(panel.winid, bufnr)
      end or nil,
      on_close   = s.on_close and function(_bufnr)
        return s.on_close()
      end or nil,
    }
  end
  M._registry = section_mod.attach(M._panel, section_defs, {
    default = M.state.section or cfg.default_section,
  })
  -- Wrap `registry:focus` so EVERY focus dispatch (admin REPL,
  -- winbar click, buffer-local 0..9 keymap, programmatic
  -- `M._registry:focus(N)`) runs the auto-finder-specific tail:
  -- mirror `state.section`, persist `last_section` to the namespace,
  -- and pump a catch-up neo-tree redraw. Auto-core's `attach()`
  -- already wires the click router to call `registry:focus(N)` and
  -- its `apply_keymap` does the same, so wrapping here covers both
  -- without overrides.
  do
    local _original_focus = M._registry.focus
    local _post_focus = function(active)
      M.state.section = active
      pcall(require("auto-finder.state").set_last_section, active)
      local ok_mgr, manager = pcall(require, "auto-finder.neotree.sources.manager")
      if ok_mgr and type(manager.redraw) == "function" then
        pcall(manager.redraw, nil)
      end
    end
    M._registry.focus = function(self, key)
      local ok, err = _original_focus(self, key)
      if ok then _post_focus(self.active) end
      return ok, err
    end
  end
  -- Legacy `M.state.section_buffers` becomes a live alias of the
  -- registry's bufnr cache so `M.reload()` and any external readers
  -- (e.g. consumer scripts) keep working without changes. We mutate
  -- in place (never re-assign) elsewhere so the alias never goes
  -- stale.
  M.state.section_buffers = M._registry._bufs

  -- Watchers keep M.state synced + drive panel side-effects on every
  -- namespace mutation (admin REPL, future remote API, :checkhealth
  -- probe, etc.). The panel:resize call is idempotent + cheap when
  -- the panel is closed (auto-core stores user_width on the instance
  -- and applies it at next open).
  state_mod.watch_user_width(function(payload)
    M.state.user_width = payload.new
    if M._panel then
      if payload.new then
        M._panel:resize(payload.new)
      else
        M._panel:reset_width()
      end
    end
    require("auto-finder.panel.host")._refresh_after_resize(M.state)
  end)
  state_mod.watch_last_section(function(payload)
    M.state.section = payload.new
  end)

  -- v0.2.0 step 4: subscribe to `worktree:switched` so the repos
  -- panel rebases automatically when the active worktree changes.
  -- Today the event is published only by direct `auto-core.git.
  -- worktree` callers; once worktree.nvim migrates (the next
  -- consumer in the family migration order), `<leader>gw` and
  -- friends will fire it too.
  require("auto-core").events.subscribe("worktree:switched",
    function(_payload)
      if not M._registry then return end
      -- Find the repos section if enabled.
      local repos_def
      for _, s in ipairs(M._registry.sections) do
        if s.name == "repos" then repos_def = s; break end
      end
      if not repos_def then return end
      -- Drop the cached repos bufnr (fires on_close so neo-tree's
      -- state cleanup runs). Mutate `_bufs` in place so the
      -- `state.section_buffers` alias stays valid.
      local b = M._registry._bufs[repos_def.number]
      if b and vim.api.nvim_buf_is_valid(b) and repos_def.on_close then
        pcall(repos_def.on_close, b)
      end
      M._registry._bufs[repos_def.number] = nil
      -- Re-focus to remount immediately if repos is currently active.
      if M._registry.active == repos_def.number then
        pcall(function() M._registry:focus(repos_def.number) end)
      end
    end)
  -- Phase 3c note: previously re-synced
  -- `state.window.auto_expand_width` here so a session restart with
  -- a saved pin wouldn't expand on first files focus. The forked
  -- renderer now reads `M.state.user_width` directly each render —
  -- the persisted pin is already in `M.state.user_width` by this
  -- point in setup, so the renderer sees the pin from its very
  -- first call. No manual sync needed.
  -- File-filter prefs hydration. Canonical source of truth is now
  -- `auto-core.files.{show_hidden,show_dotfiles}` (see auto-core
  -- module of the same name). Legacy `persisted.files.*` from
  -- `<config>/.auto-finder/config.json` is one-shot migrated to the
  -- canonical store on first run after upgrade — older nvims that
  -- pre-date auto-core fall through harmlessly.
  --
  -- Naming flip: the legacy schema used `hide_*` (true = hide);
  -- auto-core uses `show_*` (true = show). Negate at the boundary.
  do
    local ok_core, core = pcall(require, "auto-core")
    if ok_core and core and core.files then
      -- One-shot migration from legacy store, if values present.
      if persisted.files then
        if persisted.files.hide_dotfiles ~= nil then
          core.files.set_show_dotfiles(not persisted.files.hide_dotfiles)
        end
        if persisted.files.hide_gitignored ~= nil then
          core.files.set_show_hidden(not persisted.files.hide_gitignored)
        end
      end
      -- Apply the canonical values into neo-tree's runtime config.
      local ok_neo, neo = pcall(require, "auto-finder.neotree")
      if ok_neo and type(neo.config) == "table" then
        neo.config.filesystem = neo.config.filesystem or {}
        neo.config.filesystem.filtered_items =
          neo.config.filesystem.filtered_items or {}
        local fi = neo.config.filesystem.filtered_items
        fi.hide_dotfiles   = not core.files.get_show_dotfiles()
        fi.hide_gitignored = not core.files.get_show_hidden()
        if core.files.get_show_dotfiles() or core.files.get_show_hidden() then
          fi.visible = true
        end
      end
      -- Watch for external mutations (admin REPL, future remote
      -- API) and re-apply to neo-tree's filtered_items at runtime.
      local function _resync_filter()
        local ok_n, n = pcall(require, "auto-finder.neotree")
        if not ok_n or type(n.config) ~= "table" then return end
        n.config.filesystem = n.config.filesystem or {}
        n.config.filesystem.filtered_items =
          n.config.filesystem.filtered_items or {}
        local f = n.config.filesystem.filtered_items
        f.hide_dotfiles   = not core.files.get_show_dotfiles()
        f.hide_gitignored = not core.files.get_show_hidden()
        -- Re-render the active files section so the filter changes
        -- become visible without the user toggling sections.
        pcall(function()
          require("auto-finder.neotree.sources.manager").refresh("filesystem")
        end)
      end
      core.files.watch_show_hidden(_resync_filter)
      core.files.watch_show_dotfiles(_resync_filter)
    elseif persisted.files then
      -- auto-core not installed (legacy install) — apply directly
      -- from the old store schema.
      local ok_neo, neo = pcall(require, "auto-finder.neotree")
      if ok_neo and type(neo.config) == "table" then
        neo.config.filesystem = neo.config.filesystem or {}
        neo.config.filesystem.filtered_items =
          neo.config.filesystem.filtered_items or {}
        local fi = neo.config.filesystem.filtered_items
        if persisted.files.hide_dotfiles ~= nil then
          fi.hide_dotfiles = persisted.files.hide_dotfiles
        end
        if persisted.files.hide_gitignored ~= nil then
          fi.hide_gitignored = persisted.files.hide_gitignored
        end
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

  -- Repos-follow: BufEnter autocmd that reveals the repo containing
  -- the currently focused buffer in the repos panel. Installed
  -- unconditionally (whenever the repos section exists) so the
  -- admin-DSL toggle `repos follow on|off` can flip behavior live —
  -- the autocmd body reads `M.state.config.repos.follow` at fire
  -- time, so a false flag short-circuits cheaply.
  if require("auto-finder.sections")._by_name["repos"] then
    M._install_repos_follow_autocmd(group)
  end

  -- Files-follow: install our OWN BufEnter autocmd that calls
  -- `filesystem.follow()` directly. v0.2.1 / v0.2.2 relied on the
  -- forked neo-tree's internal event-bus subscription
  -- (`manager.subscribe(events.VIM_BUFFER_ENTER, ...)`), which is
  -- installed inside `M.navigate()` and gated on
  -- `config.follow_current_file.enabled` AT MOUNT TIME. Two
  -- failure modes followed: (1) runtime toggles never wired the
  -- subscription, and (2) the neotree event chain was silently
  -- no-op'ing for `position = "current"` mounts in some sessions.
  -- Subscribing here gives a single hot path that respects the
  -- live `cfg.files.follow` flag and works regardless of when the
  -- section was mounted.
  if require("auto-finder.sections")._by_name["files"] then
    M._install_files_follow_autocmd(group)
  end

  -- Buffers-refresh: own BufAdd/BufDelete/BufFilePost/TermOpen
  -- autocmd that re-renders the buffers source against the panel's
  -- win-keyed state. The forked buffers source's internal subscriber
  -- (`buffers/init.lua:setup` → `manager.subscribe(VIM_BUFFER_ADDED,
  -- ...)`) calls `buffers_changed_internal`, which resolves state
  -- via `manager.get_state(name, tabid)` — same stub-vs-real
  -- mismatch as files-follow had: `position = "current"` mounts
  -- key the rendered state under `state_by_win[panel_winid]`, not
  -- `state_by_tab[tabid]`, so the stub is returned and the refresh
  -- silently no-ops. Installing the autocmd here drives the same
  -- `items.get_opened_buffers(state)` body against the right state.
  --
  -- Installed UNCONDITIONALLY — slot DSL `slot add buffers` can land
  -- the section live after setup, and the fire body checks at fire
  -- time whether a real buffers state exists. The fast path is cheap
  -- (one `_get_all_states()` walk per debounce window) so the
  -- unconditional install is acceptable even when buffers isn't on.
  M._install_buffers_refresh_autocmd(group)

  -- v0.2.5: per-project section composition. Subscribe to
  -- `worktree:switched` so a worktree switch re-loads the
  -- persisted section list for that project (or falls back to
  -- the cfg defaults for a fresh / unknown project). Soft-dep on
  -- auto-core's event bus.
  --
  -- v0.2.10: also subscribe to `core.workspace_root:changed` and
  -- run an immediate-retry reseed when `vim.v.vim_did_enter == 1`
  -- so the initial-startup load order doesn't drop persisted slot
  -- additions. The original v0.2.5 seed-from-persisted block in
  -- `M.setup` reads `M._workspace_key()` synchronously, but
  -- worktree.nvim's `_ensure_root_now()` (the function that calls
  -- `auto-core.git.worktree.set_workspace_root` and unblocks the
  -- key) may run AFTER auto-finder.setup in a default lazy load
  -- order. When that happens, the seed returns nil and
  -- `cfg.sections` stays at the default — exactly the user-
  -- reported "I added `buffers`, it's gone after restart" bug
  -- where the persisted record in
  -- `<state>/auto-core/auto-finder.json:sections[<wskey>]` was
  -- correct but the live config didn't reflect it.
  --
  -- The triple-trigger keeps reseed coverage tight:
  --   * `worktree:switched` — explicit user switch via worktree.nvim
  --   * `core.workspace_root:changed` — first-time capture at session
  --     start (worktree.nvim publishes this exactly once before the
  --     first switch)
  --   * `vim_did_enter == 1` immediate-retry — covers the case where
  --     workspace_root was ALREADY captured before auto-finder
  --     subscribed (lazy-loaded plugins registering handlers for an
  --     already-fired event — see [[lua-nvim-plugin-development]]
  --     rule and the auto-core-maintenance §"lazy-load VimEnter
  --     fallback" convention).
  local ok_core, core = pcall(require, "auto-core")
  if ok_core and type(core.events) == "table"
      and type(core.events.subscribe) == "function" then
    core.events.subscribe("worktree:switched", function()
      vim.schedule(function() M._reseed_sections_for_workspace() end)
    end)
    core.events.subscribe("core.workspace_root:changed", function()
      vim.schedule(function() M._reseed_sections_for_workspace() end)
    end)
  end
  -- Already-fired path: if vim has finished startup AND the
  -- workspace_root happens to be set by now (lazy-load order put
  -- worktree.nvim's capture before us), the reseed below covers
  -- the case the subscriptions above would otherwise miss because
  -- the event already fired.
  if vim.v.vim_did_enter == 1 then
    vim.schedule(function() M._reseed_sections_for_workspace() end)
  end
end

---Install a debounced BufEnter autocmd that calls the filesystem
---source's `follow()` whenever a real file is entered. Gated on
---the live `M.state.config.files.follow` flag so admin-DSL toggles
---take effect instantly. No-op when the buffer isn't a real file
---or focus is inside one of our own panel buffers.
---@param group integer  -- AutoFinderPanel augroup
function M._install_files_follow_autocmd(group)
  local pending = false
  local DEBOUNCE_MS = 60

  local function fire()
    pending = false
    local live_cfg = M.state and M.state.config
    if not (live_cfg and live_cfg.files and live_cfg.files.follow) then
      return
    end
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].buftype ~= "" then return end  -- skip terminal/qf/help
    local ft = vim.bo[buf].filetype
    if ft == "auto-finder" or ft == "auto-finder-popup"
        or ft == "auto-finder-config" or ft == "auto-finder-help" then
      return
    end
    local path = vim.api.nvim_buf_get_name(buf)
    if path == nil or path == "" then return end

    -- Drive reveal directly against the panel's win-keyed state.
    -- Why not just call `filesystem.follow()`? Its `follow_internal`
    -- pulls state via `manager.get_state(name, tabid)` with no
    -- winid, which returns the TAB-keyed stub state (path=nil)
    -- when the panel was mounted with `position = "current"` —
    -- that path keeps the rendered state under `state_by_win[winid]`,
    -- not `state_by_tab[tabid]`. Direct-reveal walks
    -- `_get_all_states()` for the auto-finder panel's win-keyed
    -- filesystem state and drives the same reveal body (fs_scan
    -- get_items → renderer.focus_node).
    local panel_winid = M.state and M.state.panel_winid
    if not panel_winid or not vim.api.nvim_win_is_valid(panel_winid) then
      return
    end
    local ok_mgr, mgr = pcall(require, "auto-finder.neotree.sources.manager")
    if not ok_mgr or type(mgr._get_all_states) ~= "function" then return end
    local state
    for _, s in ipairs(mgr._get_all_states()) do
      if s.name == "filesystem" and s.winid == panel_winid and s.path then
        state = s
        break
      end
    end
    if not state then return end

    local path_norm = vim.fs.normalize(path)
    local root_norm = state.path:gsub("/+$", "")
    if path_norm:sub(1, #root_norm + 1) ~= root_norm .. "/" then return end

    local ok_scan, fs_scan = pcall(require,
      "auto-finder.neotree.sources.filesystem.lib.fs_scan")
    local ok_ren, renderer = pcall(require, "auto-finder.neotree.ui.renderer")
    if not (ok_scan and ok_ren) then return end
    pcall(function()
      fs_scan.get_items(state, nil, path_norm, function()
        pcall(renderer.focus_node, state, path_norm, true)
      end)
    end)
  end

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    desc = "auto-finder: files-follow direct reveal (cfg.files.follow)",
    callback = function()
      if pending then return end
      pending = true
      vim.defer_fn(fire, DEBOUNCE_MS)
    end,
  })
end

---Install a debounced BufAdd/BufDelete/BufFilePost/TermOpen autocmd
---that re-renders the buffers source against the panel's win-keyed
---state. Works around the same forked-neo-tree state-keying mismatch
---that broke files-follow in v0.2.1 — `buffers/init.lua`'s
---`buffers_changed_internal` walks `manager.get_state(name, tabid)`
---which returns a `state_by_tab` stub (no path, no winid, no tree)
---for `position = "current"` mounts. The rendered state lives under
---`state_by_win[panel_winid]` and the stub-returning refresh path
---silently no-ops, leaving the panel empty until something else
---triggers a full rebuild.
---
---This autocmd does the same job correctly: walk
---`mgr._get_all_states()` for the win-keyed buffers state bound to
---`M.state.panel_winid` and call `items.get_opened_buffers(state)`
---directly. Idempotent w.r.t. the fork's internal subscriber — both
---can fire on the same BufAdd; the fork's call hits the stub and
---no-ops, ours hits the real state and updates the tree.
---@param group integer  -- AutoFinderPanel augroup
function M._install_buffers_refresh_autocmd(group)
  local pending = false
  local DEBOUNCE_MS = 80

  local function fire()
    pending = false
    -- The buffers section's bufnr cache is the cheapest "is the panel
    -- currently showing buffers?" check. If buffers isn't the active
    -- section we still refresh the state in case the user toggles to
    -- it — but skipping when no state exists keeps the loop cheap.
    local panel_winid = M.state and M.state.panel_winid
    if not panel_winid or not vim.api.nvim_win_is_valid(panel_winid) then
      return
    end
    local ok_mgr, mgr = pcall(require, "auto-finder.neotree.sources.manager")
    if not ok_mgr or type(mgr._get_all_states) ~= "function" then return end
    local ok_items, items = pcall(require,
      "auto-finder.neotree.sources.buffers.lib.items")
    if not ok_items then return end
    -- v0.2.11 gate: only refresh when the buffers source is the
    -- currently-DISPLAYED section in the panel. Otherwise
    -- `get_opened_buffers` ends in `renderer.show_nodes` →
    -- `nvim_win_set_buf(panel, state.bufnr)`, which clobbers
    -- whichever section the user actually has up (regression
    -- introduced in v0.2.9 — user reported: "I'm on files panel
    -- but the content is buffers"). When buffers ISN'T active, we
    -- skip; the next time the user focuses buffers, the section
    -- re-mounts fresh via `section.get_buffer` and a complete
    -- navigate() runs from scratch — no stale tree.
    --
    -- Active-section probe via the auto-finder registry rather than
    -- `state.bufnr == nvim_win_get_buf(panel)`: the latter races with
    -- the renderer's buffer reassignment during show_nodes (the
    -- `position = "current"` branch reassigns state.bufnr via
    -- get_buffer(bufname, state) and then swaps the window), so a
    -- gate keyed on equality can read state.bufnr while it's
    -- transiently mid-swap. The registry's `active` slot + the
    -- section.name lookup is the contract — what the user clicked
    -- through the winbar / DSL — not a derived value.
    local registry = M._registry
    if not registry then return end
    local active_number = registry.active
    if active_number == nil then return end
    local buffers_active = false
    for _, sect in ipairs(registry.sections or {}) do
      if sect.name == "buffers" and sect.number == active_number then
        buffers_active = true; break
      end
    end
    if not buffers_active then return end
    for _, state in ipairs(mgr._get_all_states()) do
      if state.name == "buffers"
          and state.winid == panel_winid
          and state.path
          and state.tree then
        -- The renderer's "current" branch
        -- (lua/auto-finder/neotree/ui/renderer.lua:1230) swaps the
        -- freshly-built tree buffer into `state.winid` via
        -- `nvim_win_set_buf` — which raises E1513 against the
        -- auto-core.ui.panel singleton's `winfixbuf = true`. The
        -- forked source's own VIM_BUFFER_ADDED subscriber never hits
        -- this because it bails on the stub-state path check, but our
        -- direct-against-the-real-state call DOES reach the swap.
        -- Wrap with `Panel:with_unfixed_buf` (same shape auto-agents
        -- uses for slot terminal placement) so the swap goes through
        -- and `winfixbuf` is restored before we return.
        --
        -- Also force-clear a stuck `state.loading` flag. The flag
        -- gets stuck-true when a prior call errored before the
        -- function reached its `state.loading = false` reset — e.g.
        -- exactly the winfixbuf-raise this very fix addresses. Once
        -- stuck, every future `get_opened_buffers` early-returns.
        -- Clearing here is idempotent vs. concurrent runs (there's
        -- no real concurrency — the debounce serializes us).
        state.loading = false
        local panel = M._panel
        if panel and type(panel.with_unfixed_buf) == "function" then
          panel:with_unfixed_buf(function()
            pcall(items.get_opened_buffers, state)
          end)
        else
          pcall(items.get_opened_buffers, state)
        end
      end
    end
  end

  -- Three signals to react to:
  --   BufAdd       — a buffer joined the buffer list (`:edit foo.md`,
  --                  bufferline pin, etc.)
  --   BufDelete    — a buffer left the list (`:bd`, `:bw`)
  --   BufFilePost  — a buffer was renamed (`:saveas`, `:Rename`)
  --   TermOpen     — a terminal buffer was created; show up under
  --                  the "Terminals" sub-folder.
  -- We deliberately do NOT react to BufEnter — get_opened_buffers
  -- runs through every buffer + every nesting folder, and BufEnter
  -- fires ~10×/s during navigation. Debouncing alone isn't enough;
  -- the BufAdd/BufDelete pair captures all the mutations cheaply.
  local events = { "BufAdd", "BufDelete", "BufFilePost", "TermOpen" }
  for _, e in ipairs(events) do
    vim.api.nvim_create_autocmd(e, {
      group = group,
      desc = "auto-finder: buffers-refresh against panel win-keyed state",
      callback = function()
        if pending then return end
        pending = true
        vim.defer_fn(fire, DEBOUNCE_MS)
      end,
    })
  end
end

---Resolve the workspace root via auto-core when present, falling
---back to nil. Used by the repos-follow autocmd to anchor the
---walk-up-to-child computation. Returns nil if auto-core isn't
---installed OR the workspace root hasn't been captured yet (e.g.
---worktree.nvim hadn't run its launch-cwd capture for some reason).
---@return string?
function M._workspace_root()
  local ok, core = pcall(require, "auto-core")
  if not ok or type(core) ~= "table" or type(core.git) ~= "table"
      or type(core.git.worktree) ~= "table"
      or type(core.git.worktree.get_workspace_root) ~= "function" then
    return nil
  end
  local v = core.git.worktree.get_workspace_root()
  if type(v) == "string" and v ~= "" then return v end
  return nil
end

---Install a debounced BufEnter autocmd that reveals the repo
---containing the active buffer's path inside the repos section.
---Skipped silently if auto-core's workspace_root isn't available
---(repo discovery needs the workspace anchor).
---@param group integer  -- the augroup id to attach to
function M._install_repos_follow_autocmd(group)
  local last_revealed = nil
  local pending = false
  local DEBOUNCE_MS = 80

  local function reveal()
    pending = false
    -- Re-read the live flag each fire so the admin-DSL toggle
    -- (`repos follow on|off`) takes effect without re-installing
    -- the autocmd.
    local live_cfg = M.state and M.state.config
    if not (live_cfg and live_cfg.repos and live_cfg.repos.follow) then
      return
    end
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].buftype ~= "" then return end  -- skip terminals / quickfix / help
    local path = vim.api.nvim_buf_get_name(buf)
    if path == nil or path == "" then return end

    local root = M._workspace_root()
    if not root then return end
    local root_norm = vim.fs.normalize(root):gsub("/+$", "")
    local path_norm = vim.fs.normalize(path)
    if path_norm:sub(1, #root_norm + 1) ~= root_norm .. "/" then return end

    -- Compute the direct child of root that contains `path`. That's
    -- the repo the user is editing inside.
    local rel = path_norm:sub(#root_norm + 2)
    local first = rel:match("^([^/]+)")
    if not first then return end
    local repo_path = root_norm .. "/" .. first
    if repo_path == last_revealed then return end

    -- Only act if the repos section's buffer is currently live; we
    -- don't want to force a remount on every BufEnter.
    local repos = require("auto-finder.sections")._by_name["repos"]
    local section = repos and require("auto-finder.sections")._by_number[repos]
    if not section or not section._bufnr
        or not vim.api.nvim_buf_is_valid(section._bufnr) then
      return
    end

    pcall(function()
      require("auto-finder.neotree.command").execute({
        source = "auto-finder-repos",
        action = "show",
        position = "current",
        reveal = true,
        reveal_file = repo_path,
      })
    end)
    last_revealed = repo_path
  end

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    desc = "auto-finder: repos-follow reveal on BufEnter (cfg.repos.follow)",
    callback = function()
      if pending then return end
      pending = true
      vim.defer_fn(reveal, DEBOUNCE_MS)
    end,
  })
end

-- ── v0.2.4 keymap audit (ADR 0008) ─────────────────────────────

---Filetypes that mark a panel-class window (the panel buffer or a
---panel popup we'd never want to route an open-file command into).
---Single source of truth — appended here as the auto-* family
---grows; future addition: pull from `auto-core.ui.panel`'s
---registry once it exposes a filetype list.
local _PANEL_FILETYPES = {
  ["auto-finder"]        = true,
  ["auto-finder-popup"]  = true,
  ["auto-finder-config"] = true,
  ["auto-finder-help"]   = true,
  ["auto-agents"]        = true,
  ["auto-core-channel"]  = true,
}

---Buftypes that flag a window as "not an editor". Excludes
---terminal, quickfix, help, prompt, etc. Empty buftype is the
---usual file-buffer marker; `nofile`/`acwrite` cover scratch +
---write-on-cmd buffers that are still usable editor targets.
local _EDITOR_BUFTYPES = {
  [""]        = true,
  ["nofile"]  = true,
  ["acwrite"] = true,
}

---Find a window suitable for opening a file in. Walks
---`nvim_list_wins()` (in vim's natural order) and returns the
---first match that:
---  * isn't floating,
---  * isn't winfixbuf,
---  * has a buftype in `_EDITOR_BUFTYPES`,
---  * has a filetype NOT in `_PANEL_FILETYPES`.
---
---Returns nil if no such window exists in the current tab.
---@return integer?
function M._editor_target_winid()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.wo[w].winfixbuf then goto continue end
    local cfg = vim.api.nvim_win_get_config(w)
    if cfg.relative ~= nil and cfg.relative ~= "" then goto continue end
    local b = vim.api.nvim_win_get_buf(w)
    if not _EDITOR_BUFTYPES[vim.bo[b].buftype] then goto continue end
    if _PANEL_FILETYPES[vim.bo[b].filetype] then goto continue end
    do return w end
    ::continue::
  end
  return nil
end

---Build a neo-tree command callback that opens the selected node
---in a real editor window (NOT inside the panel column).
---  * file node → focus an editor window, then run
---    `:<open_cmd> <path>` there. Falls back to a fresh
---    `rightbelow vsplit <path>` when no editor window exists.
---  * directory node → defer to neo-tree's native toggle_node
---    (no editor routing — same as upstream's open-on-directory).
---
---Why this exists: `position = "current"` makes the panel the
---"current" window, so neo-tree's native open_split / open_vsplit
---commands run `:split` / `:vsplit` from INSIDE the panel column.
---See ADR 0008 for the full rationale.
---@param open_cmd "edit"|"split"|"vsplit"|"tabnew"
---@return fun(state: table)
function M._route_open_to_editor(open_cmd)
  return function(state)
    local tree = state and state.tree
    if not tree then return end
    local ok_node, node = pcall(tree.get_node, tree)
    if not ok_node or not node then return end

    -- Directory → delegate to native toggle_node (handles
    -- expand/collapse + lazy-load semantics).
    if node.type == "directory" or require("auto-finder.neotree.utils").is_expandable(node) then
      local cc = require("auto-finder.neotree.sources.common.commands")
      local fs = require("auto-finder.neotree.sources.filesystem")
      cc.toggle_node(state, require("auto-finder.neotree.utils").wrap(
        fs.toggle_directory, state))
      return
    end

    local path = node.path or node:get_id()
    if not path or path == "" then return end
    local target = M._editor_target_winid()
    if target then
      pcall(vim.api.nvim_set_current_win, target)
      pcall(vim.cmd,
        (open_cmd or "edit") .. " " .. vim.fn.fnameescape(path))
    else
      -- No editor window — create one alongside the panel.
      pcall(vim.cmd, "rightbelow vsplit " .. vim.fn.fnameescape(path))
    end
  end
end

---Toggle hidden-file visibility via auto-core.files (the canonical
---preference key the admin DSL writes to), then refresh the
---filesystem source. Single source of truth between the H keymap
---and the `files show/hide hidden` DSL command.
---@param state table  -- neo-tree state (unused — kept for the command signature)
function M._toggle_hidden_via_core(state)
  local _ = state  -- explicit unused
  local ok, core = pcall(require, "auto-core")
  if ok and type(core) == "table" and type(core.files) == "table" then
    local cur = core.files.get_show_hidden() == true
    core.files.set_show_hidden(not cur)
  end
  pcall(function()
    require("auto-finder.neotree.sources.manager").refresh("filesystem")
  end)
end

---Inject the v0.2.4 keymap overrides into the consumer's
---`cfg.neo_tree.filesystem.window.mappings` BEFORE the neo-tree
---setup call. Keeps the override at the consumer-side wiring
---layer (not inside the fork's vendored `defaults.lua`) so a
---future upstream rebase doesn't conflict on the audit. ADR 0008.
---@param cfg AutoFinderConfig
function M._inject_keymap_overrides(cfg)
  cfg.neo_tree = cfg.neo_tree or {}

  -- v0.2.5: build a per-source applier so filesystem AND buffers
  -- share the same audit. `H` (toggle_hidden) is filesystem-only —
  -- the buffers source doesn't display hidden gitignored files,
  -- just open nvim buffers, so we skip it there.
  local function apply_overrides(source_key, opts)
    cfg.neo_tree[source_key] = cfg.neo_tree[source_key] or {}
    cfg.neo_tree[source_key].window =
      cfg.neo_tree[source_key].window or {}
    cfg.neo_tree[source_key].window.mappings =
      cfg.neo_tree[source_key].window.mappings or {}

    local m = cfg.neo_tree[source_key].window.mappings

    -- Skip if the consumer already bound the key (custom intent
    -- always wins). We only fill defaults.
    local function default(key, value)
      if m[key] == nil then m[key] = value end
    end

    -- ── B: open/split family routed through editor window ──────
    default("<cr>",          M._route_open_to_editor("edit"))
    default("<2-LeftMouse>", M._route_open_to_editor("edit"))
    default("S",             M._route_open_to_editor("split"))
    default("s",             M._route_open_to_editor("vsplit"))
    default("t",             M._route_open_to_editor("tabnew"))

    -- ── H: rewire toggle_hidden through auto-core.files ────────
    if opts and opts.toggle_hidden then
      default("H", M._toggle_hidden_via_core)
    end

    -- ── C: remove keys irrelevant to our model ─────────────────
    -- neo-tree's documented unbind sentinel is the string "none".
    default("e",     "none")
    default("<",     "none")
    default(">",     "none")
    default(".",     "none")
    default("<esc>", "none")
  end

  apply_overrides("filesystem", { toggle_hidden = true })
  apply_overrides("buffers",    { toggle_hidden = false })
end

---Bundled neo-tree sources that auto-finder ships a section
---module for. Each entry maps to `lua/auto-finder/neotree/sources/<name>/`
---in the fork. Sections that mount a CUSTOM neo-tree source
---(today: `repos` → `auto-finder-repos`) go through their own
---explicit registration helper (`_register_neotree_workspace_source`)
---and aren't listed here.
local _BUNDLED_NEOTREE_SOURCES = { "filesystem", "buffers" }

---Ensure `cfg.neo_tree.sources` contains every bundled source we
---ship a section module for. Without this, neotree's setup
---pipeline only builds `default_configs` for sources listed in
---`cfg.neo_tree.sources` (or the fork's `defaults.sources` =
---`{ "filesystem" }`). A subsequent `slot add buffers` then
---asserts at `manager.lua:124` because `default_configs["buffers"]`
---was never built.
---
---Idempotent: skips entries already present. Respects the
---consumer's `cfg.neo_tree.sources` ordering — we only APPEND
---missing bundled names.
---@param cfg AutoFinderConfig
function M._register_bundled_neotree_sources(cfg)
  cfg.neo_tree = cfg.neo_tree or {}
  cfg.neo_tree.sources = cfg.neo_tree.sources or { "filesystem" }
  local present = {}
  for _, s in ipairs(cfg.neo_tree.sources) do present[s] = true end
  for _, name in ipairs(_BUNDLED_NEOTREE_SOURCES) do
    if not present[name] then
      cfg.neo_tree.sources[#cfg.neo_tree.sources + 1] = name
      present[name] = true
    end
  end
end

-- ── v0.2.5 slot DSL (ADR 0008 addendum) ───────────────────────

---Compute the per-workspace key used by per-project section
---persistence. sha256 of the current `core.workspace_root`,
---truncated to 16 hex chars — matches md-harpoon's per-project
---pin keying so a single conceptual project surfaces under the
---same key across the AutoVim family.
---
---Returns nil when auto-core isn't loaded OR workspace_root
---hasn't been captured yet. Callers treat nil as "fall back to
---the cfg.sections default — don't persist".
---@return string?
function M._workspace_key()
  local ok, core = pcall(require, "auto-core")
  if not ok or type(core) ~= "table"
      or type(core.git) ~= "table"
      or type(core.git.worktree) ~= "table"
      or type(core.git.worktree.get_workspace_root) ~= "function" then
    return nil
  end
  local root = core.git.worktree.get_workspace_root()
  if type(root) ~= "string" or root == "" then return nil end
  local ok_sha, sha = pcall(vim.fn.sha256, root)
  if not ok_sha or type(sha) ~= "string" then return nil end
  return sha:sub(1, 16)
end

---Discover the set of section types available to `slot add` /
---`slot modify`. Sources:
---  * bundled modules under `lua/auto-finder/sections/*.lua`
---    (excluding leading-underscore helpers like `_neotree`,
---    `_storage`, and the registry `init.lua`),
---  * keys in `cfg.section_modules` (third-party registrations
---    from v0.2.1).
---Both produce strings that map cleanly to the `cfg.sections`
---list — what `slot add <type>` accepts.
---@return string[] sorted, deduped
function M._available_section_types()
  local seen, out = {}, {}

  -- Bundled — scan our own lua/auto-finder/sections/ directory.
  -- Resolves the dir from this file's own runtime path so the
  -- discovery is portable across install layouts.
  local this = debug.getinfo(1, "S").source:sub(2)        -- init.lua path
  local sections_dir = vim.fn.fnamemodify(this, ":h") .. "/sections"
  local handle = vim.uv.fs_scandir(sections_dir)
  if handle then
    while true do
      local name, t = vim.uv.fs_scandir_next(handle)
      if not name then break end
      if t == "file" and name:match("%.lua$")
          and not name:match("^_")       -- _neotree, _storage helpers
          and name ~= "init.lua" then
        local stem = name:gsub("%.lua$", "")
        if not seen[stem] then
          seen[stem] = true
          out[#out + 1] = stem
        end
      end
    end
  end

  -- Third-party — keys in cfg.section_modules (v0.2.1 registry).
  local cfg_modules = M.state and M.state.config
    and M.state.config.section_modules
  if type(cfg_modules) == "table" then
    for k, _ in pairs(cfg_modules) do
      if type(k) == "string" and not seen[k] then
        seen[k] = true
        out[#out + 1] = k
      end
    end
  end

  table.sort(out)
  return out
end

---Rebuild the section registry from a new sections list. Disposes
---the existing auto-core registry, re-runs the auto-finder
---sections init, builds fresh section_defs, calls
---`section.attach` again, and re-applies the auto-finder-specific
---`focus` wrapper (mirror `state.section`, persist `last_section`,
---redraw).
---
---Refreshes the panel winbar so the new tab strip is visible. If
---the previously-active section was removed, focus falls back to
---`cfg.default_section` (config slot if available).
---@param new_sections string[]
---@param opts { focus_after: integer|nil }?
function M._rebuild_section_registry(new_sections, opts)
  opts = opts or {}
  local cfg = M.state and M.state.config
  if not cfg or not M._registry then return end

  -- v0.2.8: in-place mutation. Disposing the entire auto-core
  -- registry deletes every section's buffer (including the
  -- config slot's buffer the user is typing in), which makes
  -- the panel window's bufnr point to a deleted buffer — the
  -- panel goes blank and the user has to recover manually.
  -- Surgically update instead: figure out which sections are
  -- being removed, only close THOSE, keep survivors' buffers
  -- intact, mutate `registry.sections` in place, refresh the
  -- winbar. Click router stays valid because it closes over the
  -- (mutated) `r` instance, not the old sections array.

  -- Compute the diff between old and new section names.
  local old_set, new_set = {}, {}
  for _, s in ipairs(cfg.sections) do old_set[s] = true end
  for _, s in ipairs(new_sections) do new_set[s] = true end

  local removed_numbers = {}
  for _, s in ipairs(M._registry.sections or {}) do
    if not new_set[s.name] then
      removed_numbers[s.number] = s
    end
  end

  -- Close + delete buffers ONLY for sections being removed.
  for number, s in pairs(removed_numbers) do
    local b = M._registry._bufs and M._registry._bufs[number]
    if b and vim.api.nvim_buf_is_valid(b) then
      if s.on_close then pcall(s.on_close, b) end
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
    if M._registry._bufs then M._registry._bufs[number] = nil end
  end

  -- Refresh the auto-finder.sections registry against the new
  -- list, then build fresh section_defs. Survivors keep their
  -- section number; new entries get fresh numbers; the
  -- registry's `_bufs` keyed by number retains survivor buffers
  -- because the section module's `_bufnr` was preserved.
  cfg.sections = new_sections
  require("auto-finder.sections").setup(new_sections, cfg.section_modules)

  local sections_list = require("auto-finder.sections").enabled()
  local section_defs  = {}
  for _, s in ipairs(sections_list) do
    section_defs[#section_defs + 1] = {
      number     = s.number,
      name       = s.name,
      get_buffer = function(panel) return s.get_buffer(panel.winid) end,
      on_focus   = s.on_focus and function(panel, bufnr)
        return s.on_focus(panel.winid, bufnr)
      end or nil,
      on_close   = s.on_close and function(_bufnr)
        return s.on_close()
      end or nil,
    }
  end

  -- Carry survivor `_bufs` entries forward into a fresh table
  -- keyed by their (potentially new) section number. Use the
  -- name → bufnr map of the old registry as the bridge.
  local old_bufs_by_name = {}
  for _, s in ipairs(M._registry.sections or {}) do
    if new_set[s.name] then
      old_bufs_by_name[s.name] = M._registry._bufs
        and M._registry._bufs[s.number]
    end
  end
  local new_bufs = {}
  for _, def in ipairs(section_defs) do
    local b = old_bufs_by_name[def.name]
    if b and vim.api.nvim_buf_is_valid(b) then
      new_bufs[def.number] = b
    end
  end

  -- Mutate the existing registry in place. Click router
  -- continues to work — its closure captures the registry
  -- table by reference, and we never re-create that table.
  M._registry.sections = section_defs
  M._registry._bufs    = new_bufs

  -- Resolve the section to focus after the mutation:
  --   1. opts.focus_after (caller-supplied),
  --   2. previously-active section if still present,
  --   3. cfg.default_section,
  --   4. 0.
  local target = opts.focus_after
  if not target then
    local prev = M.state.section
    if prev ~= nil and require("auto-finder.sections").resolve(prev) then
      target = prev
    else
      target = cfg.default_section or 0
    end
  end

  -- Focus drives the panel's winbar refresh too. Idempotent
  -- when target == registry.active.
  if M._registry.focus then
    pcall(function() M._registry:focus(target) end)
  end

  -- Defensive winbar refresh in case `focus` short-circuited
  -- (target == active) but the section list changed underneath.
  if M.refresh_winbar then pcall(M.refresh_winbar) end

  -- v0.2.5: persist the new section list under the current
  -- workspace key. No-op when workspace_root isn't yet captured.
  local wskey = M._workspace_key()
  if wskey then
    pcall(require("auto-finder.state").set_sections_for,
      wskey, new_sections)
  end
end

---Re-seed sections from the persisted record for the CURRENT
---workspace key and rebuild the registry. Used by the
---`worktree:switched` subscriber so different projects show
---different slot compositions. No-op when no workspace key is
---available OR when the persisted list matches the current one.
function M._reseed_sections_for_workspace()
  local cfg = M.state and M.state.config
  if not cfg then return end
  local wskey = M._workspace_key()
  if not wskey then return end

  local state_mod = require("auto-finder.state")
  local persisted = state_mod.get_sections_for(wskey)
  -- For unknown projects, fall back to the config-file baseline
  -- (typically { "config", "files", "repos" }). We use the
  -- original cfg.defaults rather than the live cfg.sections so
  -- a project that's never been touched gets a clean slate, not
  -- the inherited shape from whatever project the user was on
  -- previously.
  local target = persisted
    or vim.deepcopy(require("auto-finder.config").defaults.sections)

  -- No-op if the target already matches what's loaded.
  local current = cfg.sections or {}
  if #current == #target then
    local same = true
    for i, s in ipairs(target) do
      if current[i] ~= s then same = false; break end
    end
    if same then return end
  end

  M._rebuild_section_registry(target)
end

---Add a section of `section_type` to the live registry. Appends
---at the end (highest section number). No-op if a section with
---that name is already enabled.
---@param section_type string
---@return string|nil err
function M.slot_add(section_type)
  if type(section_type) ~= "string" or section_type == "" then
    return "slot add: section type required (e.g. 'files', 'repos', 'buffers')"
  end
  local cfg = M.state and M.state.config
  if not cfg then return "config not initialized" end
  for _, name in ipairs(cfg.sections) do
    if name == section_type then
      return "section '" .. section_type .. "' is already in the slot list"
    end
  end
  local types = M._available_section_types()
  local valid = false
  for _, t in ipairs(types) do if t == section_type then valid = true; break end end
  if not valid then
    return "unknown section type '" .. section_type
      .. "' (available: " .. table.concat(types, ", ") .. ")"
  end
  local new_sections = vim.list_extend({}, cfg.sections)
  new_sections[#new_sections + 1] = section_type
  -- v0.2.8: pin focus to the config slot during slot mutations.
  -- Both `slot add` and `slot remove` are invoked from the admin
  -- REPL — the user is typing in slot 0; jumping them to a
  -- newly-mounted (and possibly empty) section is jarring AND
  -- hides the next prompt. Per user direction 2026-05-11.
  M._rebuild_section_registry(new_sections, { focus_after = 0 })
  return nil
end

---Remove section at index `n` (1-based, matching the winbar
---labels). Index 0 (config slot) is protected.
---@param n integer
---@return string|nil err
function M.slot_remove(n)
  if type(n) ~= "number" or n < 1 then
    return "slot remove: N must be >= 1 (slot 0 is the protected config slot)"
  end
  local cfg = M.state and M.state.config
  if not cfg then return "config not initialized" end
  -- cfg.sections is 1-indexed; section number = i - 1, so the
  -- user's `slot remove 1` removes cfg.sections[2] (index 1 in
  -- the registry, the "files" section).
  local list_idx = n + 1
  if list_idx > #cfg.sections then
    return string.format("slot remove: N=%d out of range (max %d)",
      n, #cfg.sections - 1)
  end
  local new_sections = vim.list_extend({}, cfg.sections)
  table.remove(new_sections, list_idx)
  -- Pin focus to slot 0 (config). The previously-active section
  -- may have been the one just removed (or its index shifted),
  -- and we want the user to stay in the admin REPL where they
  -- typed the command. Per user direction 2026-05-11.
  M._rebuild_section_registry(new_sections, { focus_after = 0 })
  return nil
end

---Modify section at index `n` to `new_type`. Index 0 (config)
---is protected.
---@param n integer
---@param new_type string
---@return string|nil err
function M.slot_modify(n, new_type)
  if type(n) ~= "number" or n < 1 then
    return "slot modify: N must be >= 1 (slot 0 is the protected config slot)"
  end
  if type(new_type) ~= "string" or new_type == "" then
    return "slot modify: new section type required"
  end
  local cfg = M.state and M.state.config
  if not cfg then return "config not initialized" end
  local list_idx = n + 1
  if list_idx > #cfg.sections then
    return string.format("slot modify: N=%d out of range (max %d)",
      n, #cfg.sections - 1)
  end
  -- Reject if new_type already lives in another slot — sections
  -- are unique by name in our registry.
  for i, name in ipairs(cfg.sections) do
    if i ~= list_idx and name == new_type then
      return "section '" .. new_type .. "' already lives at slot " .. (i - 1)
    end
  end
  local types = M._available_section_types()
  local valid = false
  for _, t in ipairs(types) do if t == new_type then valid = true; break end end
  if not valid then
    return "unknown section type '" .. new_type
      .. "' (available: " .. table.concat(types, ", ") .. ")"
  end
  local new_sections = vim.list_extend({}, cfg.sections)
  new_sections[list_idx] = new_type
  M._rebuild_section_registry(new_sections, { focus_after = n })
  return nil
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
    require("auto-finder.logger").error("init",
      "failed to require 'auto-finder-repos': " .. tostring(src))
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
  -- Defer the panel open: nvim_buf_delete with force=true unwinds
  -- BufDelete/BufWipeout autocmds and may leave nvim in a window-
  -- closing state. A synchronous vsplit hits E242 ("Can't split a
  -- window while closing another"). vim.schedule lets the close
  -- chain drain before we vsplit.
  vim.schedule(function() M.open(true) end)
end

-- _maybe_hijack_directory removed in v0.1.1+1. Restore via VimEnter
-- (one-shot) when re-introducing the `nvim .` flow.

---Open the panel and focus the default (or last-used) section.
---@param force boolean?
function M.open(force)
  if not M.state.config then
    require("auto-finder.logger").error("init", "setup() must be called first")
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
  if not M._registry then
    return false, "auto-finder: registry not initialized"
  end
  -- Auto-finder-specific min-width preflight (cfg.width.min + 20,
  -- stricter than auto-core's min+10). Run via the host wrapper which
  -- delegates to M._panel:open() after the check passes; the
  -- registry's own `panel:open()` call would otherwise use the
  -- looser auto-core check.
  local host = require("auto-finder.panel.host")
  if not host.ensure_open(M.state.config, M.state, false) then
    return false, "panel could not be opened"
  end
  -- Wrapped registry:focus runs the mirror/persist/redraw tail too.
  return M._registry:focus(key)
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
