---Configuration defaults, validation, and width resolution for auto-finder.
---@module 'auto-finder.config'

local M = {}

---@class AutoFinderConfig
---@field width { default?: integer, percentage?: number, min: integer, max: integer }
---@field default_section integer
---@field sections string[]      -- ordered list of section names enabled this session
---@field files table            -- per-section opts forwarded to neo-tree's `filesystem` source on setup; consumer keymap overrides go in `files.window.mappings`
---@field repos table            -- per-section opts forwarded to the `auto-finder-repos` source on setup; consumer keymap overrides go in `repos.window.mappings`
---@field hijack_directories boolean  -- replace directory buffers with the panel + cwd at the dir
---
---NOTE: the `side` field was removed in v0.1.x — the panel is now
---always anchored to the left. The right slot is reserved for
---auto-agents.nvim's panel and the <F5> terminal. A `side` key in
---user_opts is silently ignored for backwards compat with older
---consumer configs; persisted `panel.side` values in the store are
---also ignored on load.
---
---Per-section config (one table per section name) is forwarded to
---the underlying neo-tree source's default config at setup time.
---Consumers can inject custom keymaps without modifying the plugin:
---```lua
---opts = {
---  sections = { "config", "files", "repos" },
---  repos = {
---    window = {
---      mappings = {
---        ["<C-x>"] = "close_node",
---        -- … any binding the auto-finder-repos source's commands
---        --   module exposes (open / open_split / open_vsplit /
---        --   open_tabnew / refresh / etc.)
---      },
---    },
---  },
---}
---```
M.defaults = {
  -- Two-shape width spec, picked by `resolve_width` in this priority:
  --   1. `default`     fixed column count (takes priority when set)
  --   2. `percentage`  fraction of `vim.o.columns` (used when default is nil)
  --
  -- Both are clamped to `[min .. max]`. Plugin baseline ships
  -- `percentage = 0.15` (no fixed default), so a consumer that
  -- supplies nothing gets a screen-aware panel out of the box.
  -- Consumers that prefer a fixed width (e.g. AutoVim) override
  -- with `default = 38` and the percentage path is bypassed.
  width = {
    percentage = 0.15,
    min = 25,
    max = 100,
  },
  default_section = 1,
  -- v0.2.5 changed default from { "config", "files" } to
  -- { "config", "files", "repos" }. The new default reflects how
  -- most users want auto-finder out of the box. Slot 0 (config)
  -- is the admin REPL and is always present; slots 1+ are
  -- per-project mutable via `slot add/remove/modify` (see
  -- ADR 0008 addendum). Live sections for a project are loaded
  -- from `auto-finder.state.get_sections_for(workspace_key)` at
  -- setup time AND on every `worktree:switched` topic; this
  -- field is only the FALLBACK when no per-project record exists.
  sections = { "config", "files", "repos" },
  -- Third-party section modules. When a name in `cfg.sections` is
  -- not found at `auto-finder.sections.<name>`, the registry checks
  -- this map for an explicit module path. Lets external plugins ship
  -- a section without writing into our `lua/auto-finder/sections/`
  -- namespace.
  --
  -- Example:
  --   cfg.section_modules = {
  --     ["tasks"] = "myplugin.afsection.tasks",
  --   }
  --   cfg.sections = { "config", "files", "repos", "tasks" }
  --
  -- The module must return a section table with the
  -- AutoFinderSection contract (see `sections/init.lua`).
  section_modules = {},
  files = {
    -- Reveal the file backing the currently focused window in the
    -- files tree on every BufEnter. Maps to neo-tree's native
    -- `filesystem.follow_current_file = { enabled = true }` when
    -- true. Default ON because users commonly expect the tree to
    -- track the active buffer (matches LazyVim defaults).
    follow = true,
  },
  -- Per-section opts for the `repos` section. Forwarded to the
  -- `auto-finder-repos` neo-tree source on setup so consumers can
  -- inject window mappings without forking the plugin.
  --
  -- Discovery (which dirs are git repos, what counts as a worktree,
  -- the bare-vs-`.git` layout detection) and the active root are
  -- delegated to worktree.nvim — no parallel options live here.
  -- Configure those via `require("worktree").setup({ root = …,
  -- bare_dir = … })` and the repos section picks them up at render
  -- time.
  repos = {
    -- Reveal the repo containing the currently focused buffer in
    -- the repos panel on every BufEnter. Implemented as a BufEnter
    -- autocmd that walks up from the buffer's path until it hits a
    -- direct child of `core.workspace_root`, then reveals it.
    -- Default OFF — the active-repo signal is noisier than the
    -- active-file signal, and many users don't switch repos
    -- mid-session.
    follow = false,
  },
  -- Per-section opts for the `dbase` section (auto-finder.nvim's
  -- nvim-dbee wrapper). Forwarded to `auto-finder.sections.dbase`
  -- via `section.configure(opts)` on setup so the consumer doesn't
  -- need to live-import the section module.
  --
  -- `sources` is a list of dbee Source instances (see
  -- `nvim-dbee/lua/dbee/sources.lua` — MemorySource / EnvSource /
  -- FileSource). When nil or empty, dbase falls back to a single
  -- empty MemorySource so the drawer renders against a benign baseline.
  --
  -- Example:
  --   local dbee_sources = require("dbee.sources")
  --   {
  --     dbase = {
  --       sources = {
  --         dbee_sources.FileSource:new(vim.fn.stdpath("config")
  --           .. "/auto-finder/dbase/connections.json"),
  --         dbee_sources.EnvSource:new("DBASE_CONNECTIONS"),
  --       },
  --     },
  --   }
  --
  -- `extra` is a passthrough table merged into `dbee.setup`'s config
  -- (under keys not already set by `sources`) — escape hatch for the
  -- per-tile dbee options (`drawer = {...}`, `editor = {...}` etc).
  -- Use sparingly; we may surface specific knobs at the top level
  -- once usage patterns settle.
  dbase = {
    sources = nil,
    extra = nil,
  },
  hijack_directories = true,
  -- Forwarded as-is to `require("auto-finder.neotree").setup()`
  -- before any section mounts. The forked neo-tree no longer needs
  -- a separate consumer plugin spec — auto-finder's `setup()` calls
  -- the fork's `setup()` with whatever you put here. Use it for
  -- `window.auto_expand_width`, `filesystem.filtered_items`,
  -- `filesystem.components`, `default_component_configs`, etc.
  --
  -- Phase 5 of the fork-neo-tree refactor (v0.1.3): consumer-side
  -- `lua/plugins/neo-tree.lua` was deleted in autovim and its opts
  -- moved here, because with both upstream `neo-tree.nvim` and
  -- auto-finder's `lua/neo-tree/` shim shipping the same require
  -- path, runtimepath ordering picked one or the other
  -- non-deterministically. Routing through `cfg.neo_tree` gets the
  -- consumer's opts to OUR fork unambiguously.
  neo_tree = {},
}

---@param cfg AutoFinderConfig
---@return string|nil error_msg
function M.validate(cfg)
  local w = cfg.width
  if type(w.min) ~= "number" or w.min < 1 then
    return "width.min must be a positive integer"
  end
  if type(w.max) ~= "number" or w.max < w.min then
    return "width.max must be >= width.min"
  end
  -- Either `default` (fixed cols) OR `percentage` (fraction of cols)
  -- must be specified. `default` wins when both are present.
  if w.default == nil and w.percentage == nil then
    return "width must define either `default` (cols) or `percentage` (fraction)"
  end
  if w.default ~= nil then
    if type(w.default) ~= "number" or w.default < 1 then
      return "width.default must be a positive integer"
    end
    if w.default < w.min or w.default > w.max then
      return string.format("width.default (%d) must be within [width.min .. width.max] (%d..%d)",
        w.default, w.min, w.max)
    end
  end
  if w.percentage ~= nil then
    if type(w.percentage) ~= "number" or w.percentage <= 0 or w.percentage >= 1 then
      return "width.percentage must be between 0 and 1 (exclusive)"
    end
  end
  if type(cfg.default_section) ~= "number" or cfg.default_section < 0 then
    return "default_section must be a non-negative integer"
  end
  if type(cfg.sections) ~= "table" or #cfg.sections == 0 then
    return "sections must be a non-empty list"
  end
  return nil
end

---@param user_opts table?
---@return AutoFinderConfig
function M.apply(user_opts)
  -- If the consumer provides `default`, drop the plugin's baseline
  -- `percentage` — the consumer chose a fixed width and we shouldn't
  -- pretend both are active. Mirroring vim.tbl_deep_extend with a
  -- pre-clean is simpler than fighting the merge semantics.
  if user_opts and user_opts.width and user_opts.width.default ~= nil then
    user_opts.width.percentage = user_opts.width.percentage  -- keep if explicit
  end
  local merged = vim.tbl_deep_extend("force", {}, M.defaults, user_opts or {})
  -- If the merged result has BOTH default and percentage and the
  -- consumer set default explicitly, drop percentage so resolve_width
  -- doesn't get a misleading value.
  if merged.width and merged.width.default and merged.width.percentage
      and user_opts and user_opts.width and user_opts.width.default
      and not (user_opts.width.percentage) then
    merged.width.percentage = nil
  end
  local err = M.validate(merged)
  if err then
    error("auto-finder.config: " .. err)
  end
  return merged
end

---Resolve the panel width when no user pin is active.
---Priority: `default` (if set) → `percentage * cols`. Both clamped
---to `[min .. max]`. Falls back to `min` if a misconfiguration leaves
---no value to use.
---@param cfg AutoFinderConfig
---@param cols integer
---@return integer
function M.resolve_width(cfg, cols)
  local w = cfg.width
  local n
  if w.default ~= nil then
    n = w.default
  elseif w.percentage ~= nil and cols and cols > 0 then
    n = math.floor(w.percentage * cols + 0.5)
  else
    n = w.min
  end
  if n < w.min then n = w.min end
  if n > w.max then n = w.max end
  -- Defensive clamp: if the terminal is too narrow to fit the panel
  -- + a usable editor area, drop further so the panel doesn't
  -- monopolize tiny splits.
  if cols and cols > 0 and n + 10 > cols then
    n = math.max(w.min, math.max(1, cols - 10))
  end
  return n
end

return M
