---Configuration defaults, validation, and width resolution for auto-finder.
---@module 'auto-finder.config'

local M = {}

---@class AutoFinderConfig
---@field width { default?: integer, percentage?: number, min: integer, max: integer }
---@field default_section integer
---@field sections string[]      -- ordered list of section names enabled this session
---@field view_modules? table<string, string>     -- ADR 0026: third-party view registry (name → require path)
---@field section_modules? table<string, string>  -- deprecated alias for view_modules; accepted in v0.2.x
---@field files AutoFinderFilesConfig
---@field hijack_directories boolean  -- replace directory buffers with the panel + cwd at the dir
---
---NOTE: the `side` field was removed in v0.1.x — the panel is now
---always anchored to the left. The right slot is reserved for
---auto-agents.nvim's panel and the <F5> terminal. A `side` key in
---user_opts is silently ignored for backwards compat with older
---consumer configs; persisted `panel.side` values in the store are
---also ignored on load.
---
---`apply()` warns once about any option it does not recognise (see
---`M.warn_unknown`) and drops it from the merged config.

---@class AutoFinderFilesConfig
---@field follow boolean             -- reveal the entered file while the files slot is shown
---@field auto_expand_width boolean  -- widen the panel (up to width.max) to fit the longest row, unless pinned
---@field never_show string[]        -- names never listed (default { ".git", "node_modules" })
---@field mappings table<string, string|function|false>  -- lhs → files action name | function | false (unmap)
---
---Example — add a key and drop one:
---```lua
---opts = {
---  files = {
---    mappings = {
---      ["<C-s>"] = "open_split",   -- any name from views/files ACTIONS
---      ["y"] = false,              -- unmap
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
  -- Third-party view modules. When a name in `cfg.sections` is not
  -- found at `auto-finder.views.<name>`, the registry checks this
  -- map for an explicit module path. Lets external plugins ship a
  -- view without writing into our `lua/auto-finder/views/` namespace.
  --
  -- Example:
  --   cfg.view_modules = {
  --     ["tasks"] = "myplugin.afview.tasks",
  --   }
  --   cfg.sections = { "config", "files", "repos", "tasks" }
  --
  -- The module must return a view table with the AutoFinderSection
  -- contract (see `views/init.lua`).
  --
  -- ADR 0026 Phase 2: this key was renamed from `section_modules`
  -- to `view_modules`. The legacy `section_modules` key is still
  -- accepted as an alias (per ADR §2.8 backwards-compat checklist)
  -- — `apply()` merges both into `view_modules` and emits a
  -- one-time deprecation log entry if the legacy key is used. The
  -- alias drops at the next minor bump.
  view_modules = {},
  -- Deprecated alias. Consumers should switch to `view_modules`.
  -- Both keys are still accepted in v0.2.x.
  section_modules = nil,
  files = {
    -- Reveal the file backing the currently focused window in the
    -- files tree on every BufEnter while the files slot is shown.
    -- Default ON (matches LazyVim defaults).
    follow = true,
    -- Widen the panel to fit the longest row (up to `width.max`); a user
    -- pin (`:AutoFinder resize`) always wins. Default ON: autovim ran the
    -- retired files pane with its auto_expand_width on.
    auto_expand_width = true,
    -- Names never listed in the tree or in `/` search results. Nobody
    -- browses `.git/objects`, and an installed `node_modules` dwarfs
    -- the project around it.
    never_show = { ".git", "node_modules" },
    -- Extra or overriding keymaps for the files slot (see the
    -- AutoFinderFilesConfig example above).
    mappings = {},
  },
  -- Per-section opts for the `dbase` section, forwarded to
  -- `auto-finder.sections.dbase` via `section.configure(opts)` on setup so the
  -- consumer doesn't need to live-import the section module.
  --
  -- Empty since v0.4.0: autodb owns connection storage, users and encryption
  -- on its own backend, so there is nothing for this plugin to forward. Kept
  -- as a table rather than deleted so the registry's config-forwarding path
  -- and any consumer passing `dbase = {}` keep working.
  dbase = {},
  hijack_directories = true,
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

-- Top-level keys accepted beyond `M.defaults`: `side` (ignored since v0.1.x), `log_level` (forwarded
-- to the logger), `section_modules` (deprecated alias of `view_modules`).
M.ACCEPTED = { side = true, log_level = true, section_modules = true }

---Warn once about options auto-finder does not know — a typo, or a key an older release read that no
---longer exists — instead of ignoring them silently. Checks the top level and `files`.
---@param user_opts table?
function M.warn_unknown(user_opts)
  if type(user_opts) ~= "table" then return end
  local unknown = {}
  for k in pairs(user_opts) do
    if M.defaults[k] == nil and not M.ACCEPTED[k] then unknown[#unknown + 1] = tostring(k) end
  end
  if type(user_opts.files) == "table" then
    for k in pairs(user_opts.files) do
      if M.defaults.files[k] == nil then unknown[#unknown + 1] = "files." .. tostring(k) end
    end
  end
  if #unknown == 0 then return end
  table.sort(unknown)
  pcall(function()
    require("auto-finder.log").warn("config", "unknown option(s) ignored: " .. table.concat(unknown, ", "))
  end)
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
  M.warn_unknown(user_opts)
  local merged = vim.tbl_deep_extend("force", {}, M.defaults, user_opts or {})
  for k in pairs(merged) do
    if M.defaults[k] == nil and not M.ACCEPTED[k] then merged[k] = nil end
  end
  -- ADR 0026 Phase 2 backwards-compat: merge the legacy
  -- `section_modules` key into `view_modules` so the registry's
  -- single source of truth is the new name. Both keys are accepted
  -- in v0.2.x; the legacy form drops at the next minor bump.
  if type(merged.section_modules) == "table"
      and next(merged.section_modules) ~= nil then
    merged.view_modules = merged.view_modules or {}
    local migrated_keys = {}
    for k, v in pairs(merged.section_modules) do
      if merged.view_modules[k] == nil then
        merged.view_modules[k] = v
        migrated_keys[#migrated_keys + 1] = k
      end
    end
    -- One-time deprecation log. Routed through auto-finder.log so
    -- it lands in the auto-core ring AND surfaces as a toast iff
    -- the user has the corresponding event subscribed. Soft-dep:
    -- pcall so an early-init failure of the log module doesn't
    -- crash setup.
    pcall(function()
      require("auto-finder.log").warn("config",
        "cfg.section_modules is deprecated — rename to "
        .. "cfg.view_modules (alias accepted through v0.2.x). "
        .. "Migrated keys: " .. table.concat(migrated_keys, ", "))
    end)
    -- Mirror back so any reader that still looks at section_modules
    -- sees the same data (defensive, in case of out-of-tree
    -- callers reading config directly).
    merged.section_modules = vim.deepcopy(merged.view_modules)
  end
  -- If the merged result has BOTH default and percentage and the
  -- consumer set default explicitly, drop percentage so resolve_width
  -- doesn't get a misleading value.
  if merged.width and merged.width.default and merged.width.percentage
      and user_opts and user_opts.width and user_opts.width.default
      and not (user_opts.width.percentage) then
    merged.width.percentage = nil
  end
  -- A consumer's `files.never_show` replaces the default list (deep_extend
  -- would merge the two lists index by index).
  if user_opts and type(user_opts.files) == "table" and type(user_opts.files.never_show) == "table" then
    merged.files.never_show = vim.deepcopy(user_opts.files.never_show)
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
