---auto-finder.nvim — multi-section file explorer.
---
---Public surface; see docs/adr/0001-auto-finder-design.md for the
---full design.
---@module 'auto-finder'

local M = {}

M.version = "0.5.2"

---Public-surface accessor for the registered-repos registry. Lazy-
---loaded so consumers can `require("auto-finder").repos.add(path)`
---directly. The underlying module owns persistence + repos
---change notification.
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

---One-time migration of the pre-v0.2.0 `panel` block out of the
---legacy `<config>/.auto-finder/config.json` store and into the
---auto-core state namespace.
---
---Two guarantees, both load-bearing for "resize pin survives restart":
---  1. **Guarded seed.** The legacy `user_width` / `last_section` are
---     adopted ONLY when the namespace has no explicit value yet
---     (genuine first boot after upgrade). On every later boot the
---     namespace — already loaded from disk by `state.setup()` — wins;
---     an unconditional re-seed would clobber the user's pin with the
---     stale legacy value on every restart.
---  2. **Drain.** After consuming the block we rewrite the legacy file
---     via `store.save()`, which strips `panel.*` (keeping only
---     `version` + `files`). This makes the migration genuinely
---     one-shot instead of waiting for a future file-filter toggle to
---     trigger the strip. Self-limiting: once drained, `persisted.panel`
---     is absent and the function no-ops.
---@param cfg AutoFinderConfig
function M._migrate_legacy_panel_store(cfg)
  local state_mod = require("auto-finder.state")
  local store = require("auto-finder.store")
  local persisted = store.load()
  if not persisted.panel then return end

  if state_mod.get_user_width() == nil
      and type(persisted.panel.user_width) == "number"
      and persisted.panel.user_width >= cfg.width.min
      and persisted.panel.user_width <= cfg.width.max then
    state_mod.set_user_width(persisted.panel.user_width)
  end
  -- Validated against the live section registry so a stored index for
  -- a now-disabled section silently falls back to default_section.
  if state_mod.get_last_section() == nil
      and type(persisted.panel.last_section) == "number"
      and require("auto-finder.views").resolve(persisted.panel.last_section) then
    state_mod.set_last_section(persisted.panel.last_section)
  end
  -- The `side` field was removed from the config — never applied; the
  -- panel is always left-anchored now. Drain the whole block.
  store.save(persisted)
end

---Initialize the plugin. Idempotent — re-calling re-applies opts.
---@param user_opts table?
function M.setup(user_opts)
  local cfg = require("auto-finder.config").apply(user_opts)
  M.state.config = cfg

  -- ADR 0021 §5: declare event types the plugin emits so users can
  -- toggle per-event notifications via `:AutoCoreLogEvent notify
  -- <event>`. Bare names auto-prefix to `auto-finder.<name>` via
  -- the wrapper. Idempotent — safe to re-call on setup re-runs.
  do
    local log = require("auto-finder.log")
    log.setup(cfg)  -- forward cfg.log_level if set
    log.register_events({
      -- dbase section (auto-finder.dbase.*) — opt-in toast events
      -- for informational dbase lifecycle. ERROR-class failures
      -- (`dbase.call.failed`, `dbase.setup.failed`) are NOT in this
      -- list because `log.error(...)` toasts by default per the
      -- auto-family-logging convention's level-semantics table
      -- (ERROR → vim.notify toast + ring). Only events the user
      -- might WANT to silence belong here; failures always toast.
      "dbase.connection.changed",
      "dbase.call.started",
      "dbase.call.completed",
    })
  end

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
  require("auto-finder.views").setup(cfg.sections, cfg.view_modules or cfg.section_modules)

  -- ADR-0035 Phase 3: install the buffer-attach diagnostic
  -- validator for `.todo-list/automated/*.md` files. The validator
  -- runs on BufRead/BufNewFile/BufEnter and revalidates on
  -- BufWritePost + TextChanged* (debounced 200ms). Does NOT require
  -- the auto-finder panel to be open — it's a buffer-level
  -- attachment, decoupled from the panel surface (same model as
  -- the cron engine itself starting on auto-agents load).
  pcall(function()
    require("auto-finder.views.todos.automation_diagnostics").install()
  end)

  -- ADR-0035 post-ship (2026-06-01): install the universal
  -- promote-to-automated default-populator. Subscribes to
  -- core.todo.status:changed (panel-independent — fires for the
  -- mailbox-verb path too, not just the panel `s` modal). When a
  -- task transitions INTO automated with no condition/execute, it
  -- populates working defaults so the new template doesn't trip
  -- auto-core's "empty condition/execute = malformed" rule. The
  -- panel `s` modal additionally appends the instructional body +
  -- opens the file; this subscriber is the frontmatter-only floor
  -- that every todo.status-driven promote gets.
  pcall(function()
    require("auto-finder.views.todos").install_automated_default_hook()
  end)

  -- v0.2.70: a follow toggle made via the admin DSL (`files follow
  -- on|off`) persists in the auto-finder state namespace and overrides
  -- the config default on the next setup. nil = never toggled →
  -- `cfg.files.follow` stands. The files view reads it live.
  do
    local st = require("auto-finder.state")
    for _, sec in ipairs({ "files" }) do
      local persisted = st.get_follow(sec)
      if persisted ~= nil and cfg[sec] then
        cfg[sec].follow = persisted
      end
    end
  end

  -- If `dbase` is enabled, forward the consumer's `cfg.dbase` (sources
  -- + extra) to the section. The section reads it lazily on the first
  -- `get_buffer` call — when `_dbase_setup.ensure_setup(opts)` runs —
  -- so we can plumb the config here without the backend having to be loaded
  -- yet. Safe to call even when dbase isn't enabled (no-op).
  if require("auto-finder.views")._by_name["dbase"] then
    local dbase_section = require("auto-finder.views.dbase")
    if type(dbase_section.configure) == "function" then
      dbase_section.configure(cfg.dbase)
    end
  end
  M._sync_dbase_host()

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
  --      so the existing reader sites (winbar status, the auto-expand
  --      pin check, M.open default-section fallback) keep working unchanged.
  --   4. Install watchers that re-mirror namespace → M.state on every
  --      mutation. Setters in panel/host.lua go through state_mod.set_*
  --      and trigger this.
  local state_mod = require("auto-finder.state")
  state_mod.setup()

  -- One-time legacy-store → namespace migration (guarded seed + drain).
  -- MUST run after state_mod.setup() so the namespace is already loaded
  -- from disk and the guard can see the authoritative persisted pin.
  M._migrate_legacy_panel_store(cfg)

  -- Read namespace values into the live runtime mirrors.
  M.state.user_width = state_mod.get_user_width()
  -- v0.2.28: prefer the per-workspace `last_section` record; fall
  -- back to the legacy global key for back-compat with pre-v0.2.28
  -- namespaces. `_workspace_key()` returns nil when auto-core
  -- hasn't captured workspace_root yet — the global fallback covers
  -- that startup window. `M.focus`'s clamp catches any stale value
  -- that slips through either path.
  local _wskey_init = M._workspace_key()
  M.state.section = (_wskey_init and state_mod.get_last_section_for(_wskey_init))
    or state_mod.get_last_section()

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
    -- with its own filetype (`auto-finder` for the views,
    -- `auto-finder-config` for the prompt section). Setting a host
    -- filetype on the scratch placeholder would conflict with the
    -- inherit-guard test ([9]).
    on_open  = function(winid)
      M.state.panel_winid = winid
      M.state.panel_width = vim.api.nvim_win_get_width(winid)
    end,
    on_close = function()
      M.state.panel_winid = nil
      -- Section on_close fanout: every cached section gets a chance
      -- to tear down external resources when the panel closes (the
      -- files and buffers views stop their watches, subscriptions and
      -- timers — a hidden pane does no work — but keep their buffer).
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
  local sections_list = require("auto-finder.views").enabled()
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
  -- mirror `state.section` and persist `last_section` to the namespace. Auto-core's `attach()`
  -- already wires the click router to call `registry:focus(N)` and
  -- its `apply_keymap` does the same, so wrapping here covers both
  -- without overrides.
  do
    local _original_focus = M._registry.focus
    local _post_focus = function(active)
      M.state.section = active
      -- v0.2.28: persist BOTH the legacy global key (back-compat
      -- with pre-v0.2.28 namespaces / a downgrade window) and the
      -- per-workspace key when wskey is available. The per-
      -- workspace key is the one consulted on next open, so
      -- different projects no longer leak their last-focused slot
      -- into each other (the original bug — project1's slot 4
      -- displayed as empty panel in project2 with only 2 slots).
      pcall(require("auto-finder.state").set_last_section, active)
      local _wskey_focus = M._workspace_key()
      if _wskey_focus then
        pcall(require("auto-finder.state").set_last_section_for,
          _wskey_focus, active)
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

  -- ADR 0026 Phase 3: the previous inline `state_mod.watch_*`
  -- subscribers are now armed inside `core.ensure_started` so
  -- they're re-armable on bus reset. See the comment block further
  -- down (immediately after the file-filter prefs hydration) for
  -- the full lifecycle context. Watchers keep M.state synced +
  -- drive panel side-effects on every namespace mutation (admin
  -- REPL, future remote API, :checkhealth probe, etc.).

  -- ADR 0026 Phase 3: the previous inline `worktree:switched`
  -- subscriber (drop repos cached bufnr + re-focus) and the inline
  -- state_mod watchers + the inline `core.workspace_root:changed`
  -- reseed handlers have ALL been swept into
  -- `core.ensure_started(cfg)` so they're re-armable on bus reset.
  --
  -- core.ensure_started subscribes to upstream auto-core topics,
  -- translates them into auto-finder.core.* topics, and invokes
  -- the per-handler functions defined as module-level methods on
  -- this module (so the auto-finder.init module reference closes
  -- over them via require, not via inline closure):
  --
  --   - core.git.state:changed → auto-finder.core.git:changed
  --   - worktree:switched → auto-finder.core.repos:changed
  --                       + M._reseed_sections_for_workspace()
  --                       + M._drop_repos_bufnr_on_worktree_switched()
  --   - core.workspace_root:changed → M._reseed_sections_for_workspace()
  --   - state.auto-finder:user_width   (via state_mod.watch_user_width)
  --   - state.auto-finder:last_section (via state_mod.watch_last_section)
  --
  -- Each is captured into `core._handles[<slot>]`; `core.stop()`
  -- disposes all; `core.ensure_started()` is idempotent and safe
  -- to re-call from M.open / M.focus / a bus-reset recovery path
  -- without growing the subscriber count.
  --
  -- Per ADR §2.2 the contract is dispose-first-then-resubscribe;
  -- the `_handles_still_valid` probe is an optimization (Open
  -- Question #1) that activates when auto-core publishes
  -- `core.events:bus_reset`.
  -- File-filter prefs. Canonical source of truth is
  -- `auto-core.files.{show_hidden,show_dotfiles}`; the files view reads
  -- and watches them itself. Legacy `persisted.files.*` from
  -- `<config>/.auto-finder/config.json` is one-shot migrated here
  -- (the legacy schema used `hide_*`, auto-core uses `show_*`).
  do
    local persisted = require("auto-finder.store").load()
    local ok_core, core = pcall(require, "auto-core")
    if ok_core and core and core.files and persisted.files then
      if persisted.files.hide_dotfiles ~= nil then
        core.files.set_show_dotfiles(not persisted.files.hide_dotfiles)
      end
      if persisted.files.hide_gitignored ~= nil then
        core.files.set_show_hidden(not persisted.files.hide_gitignored)
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
  -- (notably the files/buffers auto-expand, which calls
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

  -- The panel is protected by `winfixbuf = true` (panel/host.lua
  -- ensure_open): vim refuses to swap its buffer via :edit / :buffer /
  -- b#, and our own legitimate swaps wrap with with_unfixed_buf.

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
  -- ADR 0026 Phase 3: the previous inline subscriptions to
  -- `worktree:switched` and `core.workspace_root:changed` for the
  -- reseed path moved into `core.ensure_started` (see the comment
  -- block at the top of setup() — both events now invoke
  -- `M._reseed_sections_for_workspace` via the re-armable
  -- lifecycle hook).
  require("auto-finder.core").ensure_started(cfg)
  -- Already-fired path: if vim has finished startup AND the
  -- workspace_root happens to be set by now (lazy-load order put
  -- worktree.nvim's capture before us), the reseed below covers
  -- the case the subscriptions above would otherwise miss because
  -- the event already fired.
  if vim.v.vim_did_enter == 1 then
    vim.schedule(function() M._reseed_sections_for_workspace() end)
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
---  * isn't an auto-core panel of ANY plugin (the broad
---    `w:auto_core_panel_name` exclusion + legacy
---    `w:auto_finder_panel` — [[auto-core-panel-ownership]]),
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
    -- Broad panel exclusion (auto-core-panel-ownership convention):
    -- any window stamped with a non-empty `auto_core_panel_name` is
    -- some family plugin's panel — never an editor target — even
    -- when its buffer would otherwise pass the buftype/filetype
    -- checks below. Legacy `auto_finder_panel = 1` accepted too.
    if vim.w[w].auto_finder_panel == 1 then goto continue end
    do
      local pname = vim.w[w].auto_core_panel_name
      if type(pname) == "string" and pname ~= "" then goto continue end
    end
    local b = vim.api.nvim_win_get_buf(w)
    if not _EDITOR_BUFTYPES[vim.bo[b].buftype] then goto continue end
    if _PANEL_FILETYPES[vim.bo[b].filetype] then goto continue end
    do return w end
    ::continue::
  end
  return nil
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

---Discover the set of view types available to `slot add` /
---`slot modify`. Sources:
---  * bundled views under `lua/auto-finder/views/<name>/init.lua`
---    (each view is a directory after ADR 0026 Phase 2),
---  * legacy bundled sections under `lua/auto-finder/sections/<name>.lua`
---    (only the few not yet migrated; today the `sections/` tree
---    is all facades and contributes nothing new),
---  * keys in `cfg.view_modules` and the legacy `cfg.section_modules`
---    alias (third-party registrations from v0.2.1+).
---Both produce strings that map cleanly to the `cfg.sections` list —
---what `slot add <type>` accepts.
---
---ADR 0026 Phase 2: scan target moved from `sections/*.lua` files to
---`views/<name>/` directories. The function name retains its
---`_available_section_types` shape (called by `slot_*` paths that
---haven't been renamed); the helper is documented as the "view
---types" discoverer despite the legacy name.
---@return string[] sorted, deduped
function M._available_section_types()
  local seen, out = {}, {}

  -- Resolve the plugin lua root from this file's runtime path so the
  -- discovery is portable across install layouts.
  local this = debug.getinfo(1, "S").source:sub(2)        -- init.lua path
  local lua_root = vim.fn.fnamemodify(this, ":h")          -- lua/auto-finder

  -- Bundled views — each subdir under views/ with an init.lua is a
  -- view name. Leading-underscore subdirs (if any future internal
  -- helpers land there) are excluded.
  local views_dir = lua_root .. "/views"
  local vh = vim.uv.fs_scandir(views_dir)
  if vh then
    while true do
      local name, t = vim.uv.fs_scandir_next(vh)
      if not name then break end
      if t == "directory" and not name:match("^_") then
        -- Confirm it's actually a loadable view (has init.lua) before
        -- offering it as a registrable type.
        local init_path = views_dir .. "/" .. name .. "/init.lua"
        if vim.uv.fs_stat(init_path) then
          if not seen[name] then
            seen[name] = true
            out[#out + 1] = name
          end
        end
      end
    end
  end

  -- Legacy bundled — sections/*.lua. After ADR 0026 Phase 2 these
  -- are all facades pointing into views/, so the views/ scan above
  -- already covered them. We keep this scan for any third-party
  -- module dropped into our sections/ tree by an out-of-tree
  -- installer (rare but documented). Underscore-prefixed files
  -- (_dbase_*, _storage) and init.lua are excluded.
  local sections_dir = lua_root .. "/sections"
  local sh = vim.uv.fs_scandir(sections_dir)
  if sh then
    while true do
      local name, t = vim.uv.fs_scandir_next(sh)
      if not name then break end
      if t == "file" and name:match("%.lua$")
          and not name:match("^_")
          and name ~= "init.lua" then
        local stem = name:gsub("%.lua$", "")
        if not seen[stem] then
          seen[stem] = true
          out[#out + 1] = stem
        end
      end
    end
  end

  -- Third-party — keys in cfg.view_modules (preferred) and the
  -- legacy cfg.section_modules alias. Both forms are accepted in
  -- v0.2.x per ADR §2.8 backwards-compat; the alias drops at the
  -- next minor bump.
  local cfg = M.state and M.state.config
  if cfg then
    for _, key in ipairs({ "view_modules", "section_modules" }) do
      local modules = cfg[key]
      if type(modules) == "table" then
        for k, _ in pairs(modules) do
          if type(k) == "string" and not seen[k] then
            seen[k] = true
            out[#out + 1] = k
          end
        end
      end
    end
  end

  table.sort(out)
  return out
end

---Record the active section WITHOUT opening a closed panel.
---
---`focus` (auto-core `Registry:focus` / `M.focus`) OPENS a closed panel,
---so the startup / worktree-switch bookkeeping paths must not use it when
---the panel is closed. This mirrors what a successful focus would leave
---behind — the RESOLVED/CLAMPED section number in BOTH `state.section`
---and `registry.active` — but without materializing a window. An
---out-of-range or unknown key clamps to `default_section` (or 0), exactly
---as `M.focus` does, so a stale persisted `last_section` can't leave the
---two mirrors pointing at a slot that no longer exists.
---@param key integer|string
function M._record_active_section_closed(key)
  if not M._registry then return end
  local views = require("auto-finder.views")
  local default = (M.state.config and M.state.config.default_section) or 0
  -- Resolve `key`; clamp to default_section when it doesn't resolve, exactly
  -- as M.focus does. `num` is always a numeric section index — never the raw
  -- (possibly string) `key` — so both mirrors stay integer-typed.
  local section = views.resolve(key) or views.resolve(default)
  local num = (section and section.number) or default
  M.state.section = num
  M._registry.active = num
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
---@param opts { focus_after: integer|nil, no_force_open: boolean|nil }?
---  `no_force_open`: when the panel is CLOSED, update the active section
---  without opening the panel (used by the workspace reseed so a fresh
---  no-arg launch doesn't pop the finder over the dashboard). When the
---  panel is already open, focus happens regardless.
---_sync_dbase_host advertises (or withdraws) this plugin as a host for
---autodb's drawer, based on whether the `dbase` section is currently in
---the panel. autodb owns the drawer; auto-finder is one possible surface
---for it (ADR-0078 §3.3).
---
---**Edge-triggered, deliberately.** Re-registering an already-registered
---provider is not free: autodb's same-id rule tears the mounted owner
---down so a replacement can never inherit an instance built from the
---previous profile. Calling this on every rebuild therefore disposed and
---remounted a LIVE drawer whenever an unrelated slot changed, breaking
---the survivor-buffer guarantee this function sits inside (lector
---impl-r1). So it fires only on the transitions.
---
---**The "am I registered" half is read from autodb, never remembered.**
---A local boolean here was a second copy of a fact autodb already owns,
---and the section's own late-load safety net registers without going
---through this function — so the copy went stale, and then an unrelated
---slot add tore down a live drawer while a dbase removal left a dead
---provider behind (lector impl-r2 MF1). Asking the registry makes every
---entry point authoritative for free.
function M._sync_dbase_host()
  local ok, dbase_section = pcall(require, "auto-finder.views.dbase")
  if not ok or type(dbase_section.register) ~= "function" then return end
  local present = require("auto-finder.views")._by_name["dbase"] ~= nil
  local registered = dbase_section.is_registered()
  if present == registered then return end
  if present then
    dbase_section.register()
  else
    dbase_section.unregister()
  end
end

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

  -- Close + delete buffers ONLY for sections being removed. A removed
  -- dbase also stops being a drawer host, but that is handled by the
  -- edge-triggered _sync_dbase_host below, once the new section list is
  -- in place — doing it here too would put the edge flag out of step.
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
  require("auto-finder.views").setup(new_sections, cfg.view_modules or cfg.section_modules)
  -- A dbase that just ARRIVED (slot add / workspace change) advertises
  -- itself now, without waiting to be focused.
  M._sync_dbase_host()

  local sections_list = require("auto-finder.views").enabled()
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
  -- Mutate `_bufs` IN PLACE rather than rebinding. `M.state.section_buffers`
  -- is a LIVE ALIAS of this exact table (see the assignment at the end of
  -- `setup()`), and the comment there promises "we mutate in place (never
  -- re-assign) elsewhere so the alias never goes stale". Rebinding broke
  -- that promise for every caller of this function -- `slot_add`,
  -- `slot_remove`, `slot_modify`, `slot_assign` and the workspace reseed --
  -- leaving `state.section_buffers` pointing at an orphaned table. The
  -- repos-follow bufnr write and the per-section clear both target that
  -- alias, so after any slot mutation they landed nowhere the registry
  -- could see. Same in-place idiom as the panel `on_close` fanout above.
  local bufs = M._registry._bufs
  for k in pairs(bufs) do bufs[k] = nil end
  for k, v in pairs(new_bufs) do bufs[k] = v end

  -- Resolve the section to focus after the mutation:
  --   1. opts.focus_after (caller-supplied),
  --   2. previously-active section if still present,
  --   3. cfg.default_section,
  --   4. 0.
  local target = opts.focus_after
  if not target then
    local prev = M.state.section
    if prev ~= nil and require("auto-finder.views").resolve(prev) then
      target = prev
    else
      target = cfg.default_section or 0
    end
  end

  -- Focus drives the panel's winbar refresh too. Idempotent
  -- when target == registry.active.
  --
  -- BUT `focus` OPENS a closed panel: auto-core's Registry:focus calls
  -- panel:open() when the panel winid is invalid. When the workspace
  -- reseed runs this path at startup (it passes opts.no_force_open),
  -- the panel must NOT be forced open — a fresh `nvim` (no args) would
  -- otherwise pop the finder over the dashboard and shove the splash
  -- off-center (see smoke [20b]). So focus only when the panel is
  -- already open, OR when the caller did not opt out of opening (slot
  -- mutations pass no opts and keep their always-focus behavior). When
  -- we skip the focus, record the active section directly so the next
  -- explicit open still lands on `target`.
  local panel_open = M.state.panel_winid ~= nil
    and vim.api.nvim_win_is_valid(M.state.panel_winid)
  if M._registry.focus and (panel_open or not opts.no_force_open) then
    pcall(function() M._registry:focus(target) end)
  else
    -- Panel closed and the caller opted out of opening it: record the
    -- active section without materializing a window. Route through the
    -- helper so the resolve/clamp + both-mirror sync live in one place.
    M._record_active_section_closed(target)
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

  -- v0.2.28: re-seed `state.section` from the per-workspace
  -- `last_section_by_workspace` record BEFORE the no-op check
  -- and the rebuild. This covers two cases:
  --   1. Slot list differs → _rebuild_section_registry reads
  --      M.state.section as `prev` in its focus-target resolver,
  --      so it lands on the right per-project slot rather than
  --      whatever project the user was just on.
  --   2. Slot list identical → the early-return below otherwise
  --      leaves the active slot pinned to the previous project's
  --      pick; we explicitly re-focus when the per-workspace
  --      record differs.
  local per_ws_section = state_mod.get_last_section_for(wskey)
  if per_ws_section ~= nil then
    M.state.section = per_ws_section
  end

  -- No-op if the target already matches what's loaded.
  local current = cfg.sections or {}
  if #current == #target then
    local same = true
    for i, s in ipairs(target) do
      if current[i] ~= s then same = false; break end
    end
    if same then
      -- Slot list unchanged. Re-point to the per-workspace last_section —
      -- covers the project1 → project2 hop where both projects share the
      -- same slot composition but the user was on a different slot in each.
      -- `focus` opens a closed panel (M.focus → host.ensure_open), so the
      -- two panel states diverge:
      if per_ws_section ~= nil and M._registry then
        local panel_open = M.state.panel_winid ~= nil
          and vim.api.nvim_win_is_valid(M.state.panel_winid)
        if panel_open then
          -- Open: re-focus only if it actually differs (avoids a redundant
          -- refocus). M.focus clamps a stale record.
          if per_ws_section ~= M._registry.active then
            pcall(function() M.focus(per_ws_section) end)
          end
        else
          -- Closed: record the target WITHOUT opening, ALWAYS routing
          -- through the clamp helper — never gated on
          -- `per_ws_section ~= registry.active`. On a cold start BOTH
          -- state.section and registry.active can already hold the same
          -- STALE value (setup reads persisted last_section into
          -- state.section; attach then seeds registry.active from it), so an
          -- equality gate would skip the clamp and strand both mirrors on a
          -- slot that no longer exists (lector PR#13 r2 [MEDIUM], smoke
          -- [20b](d)). The helper resolves/clamps to default_section and is
          -- idempotent when the value is already valid.
          M._record_active_section_closed(per_ws_section)
        end
      end
      return
    end
  end

  M._rebuild_section_registry(target, { no_force_open = true })
end

---Drop the repos section's cached bufnr (firing its `on_close` so
---the view tears down) and re-focus if repos is the
---active section. Used by `core.ensure_started`'s
---`worktree:switched` subscriber — extracted from the inline
---closure that used to live at init.lua:357-378 before ADR 0026
---Phase 3 swept setup-time subscriptions into core.ensure_started.
function M._drop_repos_bufnr_on_worktree_switched()
  if not M._registry then return end
  local repos_def
  for _, s in ipairs(M._registry.sections) do
    if s.name == "repos" then repos_def = s; break end
  end
  if not repos_def then return end
  -- Drop the cached repos bufnr (fires on_close so the view
  -- tears down). Mutate `_bufs` in place so the
  -- `state.section_buffers` alias stays valid.
  local b = M._registry._bufs[repos_def.number]
  if b and vim.api.nvim_buf_is_valid(b) and repos_def.on_close then
    pcall(repos_def.on_close, b)
  end
  M._registry._bufs[repos_def.number] = nil
  -- Re-focus to remount immediately if repos is currently active — but
  -- ONLY when the panel is already open. Registry:focus opens a closed
  -- panel, and this fires on worktree:switched; a switch while the finder
  -- is closed must not force it open (same rule as the workspace reseed).
  -- The dropped cache remounts on the next explicit open.
  local panel_open = M.state.panel_winid ~= nil
    and vim.api.nvim_win_is_valid(M.state.panel_winid)
  if panel_open and M._registry.active == repos_def.number then
    pcall(function() M._registry:focus(repos_def.number) end)
  end
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

---Highest addressable panel slot number. Slot 0 is the protected
---config slot, so a full arrangement is `config` plus slots 1..9 —
---which is also the ceiling the single-digit `focus N` shorthand
---and the winbar's numbered tab strip can address.
M.SLOT_MAX = 9

---Re-arrange the entire slot list in one shot. `tail` is the ordered
---list of section types for slots 1..#tail; slot 0 keeps whatever
---occupies it today (the config slot).
---
---This is the seam `slot modify` cannot cover. `slot_modify` rejects
---a type that already lives in another slot, which is correct for a
---single-slot edit but makes a swap impossible — moving `repos` from
---slot 2 to slot 1 collides with itself. Here the whole list is
---replaced at once, so any PERMUTATION of the live sections is
---legal; only duplicates WITHIN the new list are rejected.
---
---Validation is all-or-nothing: the registry is rebuilt only once
---every entry has passed, so a bad entry late in the list leaves the
---current arrangement untouched.
---
---Persisted per workspace, like every other slot mutation —
---`_rebuild_section_registry` writes the new list through
---`state.set_sections_for(workspace_key, …)`, so the arrangement
---survives a restart.
---@param tail string[]  section types for slots 1..N (slot 0 excluded)
---@return string|nil err
function M.slot_assign(tail)
  if type(tail) ~= "table" then
    return "slot assign: a list of section types is required"
  end
  local cfg = M.state and M.state.config
  if not cfg or not cfg.sections or not cfg.sections[1] then
    return "config not initialized"
  end
  if #tail == 0 then
    return "slot assign: at least one section is required "
      .. "(slot 0 is the config slot and is not assignable)"
  end
  if #tail > M.SLOT_MAX then
    return string.format(
      "slot assign: at most %d sections (slots 1..%d), got %d",
      M.SLOT_MAX, M.SLOT_MAX, #tail)
  end

  -- Whatever sits at slot 0 today stays there. Resolved from the live
  -- list rather than hardcoded to "config" so a consumer that seeded
  -- a different head section keeps it protected too.
  local head = cfg.sections[1]

  local types = M._available_section_types()
  local known = {}
  for _, t in ipairs(types) do known[t] = true end

  local seen = {}
  for i, name in ipairs(tail) do
    if type(name) ~= "string" or name == "" then
      return string.format(
        "slot assign: slot %d — section type must be a non-empty string", i)
    end
    if name == head then
      return string.format(
        "slot assign: slot %d — '%s' is the protected slot-0 section", i, head)
    end
    if not known[name] then
      return string.format(
        "slot assign: slot %d — unknown section type '%s' (available: %s)",
        i, name, table.concat(types, ", "))
    end
    if seen[name] then
      return string.format(
        "slot assign: slot %d — '%s' is already assigned to slot %d",
        i, name, seen[name])
    end
    seen[name] = i
  end

  local new_sections = { head }
  for _, name in ipairs(tail) do
    new_sections[#new_sections + 1] = name
  end

  -- Same focus policy as `slot add` / `slot remove`: the command came
  -- from the admin REPL in slot 0, and the slot the user was on may
  -- not exist (or may hold something else) afterwards. Keep them
  -- where they are typing.
  M._rebuild_section_registry(new_sections, { focus_after = 0 })
  return nil
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
    require("auto-finder.log").error("init", "setup() must be called first")
    return
  end
  -- ADR 0026 Phase 3: re-armable lifecycle. Defensive call —
  -- idempotent if core is already started, recovers from a bus
  -- reset since the previous open.
  require("auto-finder.core").ensure_started(M.state.config)
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
  -- ADR 0026 Phase 3: re-armable lifecycle. Defensive call —
  -- focus is the other entry point that could fire after a bus
  -- reset (e.g. user hits 0..9 while the panel is still open).
  require("auto-finder.core").ensure_started(M.state.config)
  if not M._registry then
    return false, "auto-finder: registry not initialized"
  end
  -- v0.2.28: clamp out-of-range / unresolvable keys to
  -- `default_section` (or 0). Three paths land here with stale
  -- values today: (a) `M.open()` reads M.state.section which may
  -- have been re-seeded from a per-workspace record that was
  -- written before the slot list shrank; (b) the legacy global
  -- `last_section` namespace key bled across workspaces in
  -- pre-v0.2.28 namespaces and still feeds the back-compat read
  -- path on first launch after upgrade; (c) programmatic
  -- `M.focus(N)` callers may pass an N that's out of range for
  -- the current workspace. Without the clamp the underlying
  -- registry returns `false, "no such section"` AFTER the panel
  -- was already opened by ensure_open below — user-visible
  -- symptom is an empty panel.
  local views = require("auto-finder.views")
  if not views.resolve(key) then
    key = M.state.config.default_section or 0
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

---Re-render the active section. Calls the section's `on_close` hook,
---then its `reset` hook when it has one (the files view drops its
---model so a changed `never_show` applies), and re-focuses, so the
---next mount picks up any runtime config change (e.g. after
---`repos add` changed the registry).
function M.reload()
  local section = require("auto-finder.views").resolve(M.state.section or 0)
  if not section then return end
  if M.state.section_buffers then
    M.state.section_buffers[section.number] = nil
  end
  if type(section.on_close) == "function" then pcall(section.on_close) end
  if type(section.reset) == "function" then pcall(section.reset) end
  M.focus(section.number)
end

return M
