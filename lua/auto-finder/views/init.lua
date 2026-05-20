---View registry. Views are loaded by name from
---`auto-finder.views.<name>` and assigned numeric indices in the
---order they appear in `cfg.sections` (or, in a future minor bump,
---`cfg.views`).
---
---ADR 0026 Phase 2: moved from `auto-finder.sections` to
---`auto-finder.views`. The `auto-finder.sections` namespace is
---preserved as a facade for v0.2.x backwards-compat — see
---`sections/init.lua`.
---
---Public consumers may call `cfg.section_modules` to register a
---third-party view at a custom require path. Both `section_modules`
---and the forward-looking `view_modules` are accepted (alias). The
---next minor bump drops `section_modules`.
---@module 'auto-finder.views'

local M = {}

---@class AutoFinderSection
---@field name string
---@field number integer
---@field description? string
---@field get_buffer fun(panel_winid: integer): integer
---@field on_focus? fun(panel_winid: integer, bufnr: integer)
---@field on_close? fun()

---@type AutoFinderSection[]
M._enabled = {}

---@type table<string, integer>
M._by_name = {}

---@type table<integer, AutoFinderSection>
M._by_number = {}

---Load a view module by name and assign it an index. Consults
---the optional `view_modules`/`section_modules` registry first so
---third-party plugins can ship a view without writing into our
---`lua/auto-finder/views/` namespace; falls back to the bundled
---`auto-finder.views.<name>` path.
---
---Two-step bundled-path resolution preserves a Phase 2 backwards-
---compat surface: if `auto-finder.views.<name>` doesn't resolve
---(e.g. a third-party section module that's still installed under
---the old layout in someone's `lua/auto-finder/sections/`), we fall
---back to `auto-finder.sections.<name>` so the registry doesn't
---fail on the rename alone. This is a temporary bridge — when the
---facade is removed at the next minor bump, the bundled-path
---resolution narrows back to `views/` only.
---@param name string
---@param number integer
---@param view_modules table<string, string>?  -- name → require path
---@return AutoFinderSection|nil
local function load_view(name, number, view_modules)
  local module_path
  if view_modules and type(view_modules[name]) == "string" then
    module_path = view_modules[name]
  else
    module_path = "auto-finder.views." .. name
  end
  local ok, mod = pcall(require, module_path)
  if not ok then
    -- Phase 2 backwards-compat: a third-party section module
    -- installed under the legacy `auto-finder.sections.<name>` path
    -- still resolves through this fallback. Removed at the next
    -- minor bump.
    if not view_modules or not view_modules[name] then
      local legacy_path = "auto-finder.sections." .. name
      local ok2, mod2 = pcall(require, legacy_path)
      if ok2 then
        ok, mod = ok2, mod2
      end
    end
  end
  if not ok then
    require("auto-finder.log").error("views",
      "failed to load view '" .. name .. "' from '" .. module_path
        .. "': " .. tostring(mod))
    return nil
  end
  if type(mod) ~= "table" or type(mod.get_buffer) ~= "function" then
    require("auto-finder.log").error("views",
      "view '" .. name .. "' missing get_buffer()")
    return nil
  end
  -- Allow the view module itself to declare a `name`; fall back to
  -- the require-key. Index is assigned by the host (caller) so every
  -- session is consistent regardless of internal order.
  mod.name = mod.name or name
  mod.number = number
  return mod
end

---Initialize the registry from a config-style list of view names.
---Resets any previously-loaded registry. Idempotent.
---@param view_names string[]
---@param view_modules table<string, string>?  -- name → require path overrides
function M.setup(view_names, view_modules)
  M._enabled = {}
  M._by_name = {}
  M._by_number = {}
  for i, name in ipairs(view_names) do
    -- Index 0 is reserved for the config slot, indices >= 1 for the rest.
    -- We follow auto-agents' "0 = control surface" convention: the first
    -- entry in cfg.sections gets index 0, the second gets 1, and so on.
    local number = i - 1
    local view = load_view(name, number, view_modules)
    if view then
      table.insert(M._enabled, view)
      M._by_name[view.name] = number
      M._by_number[number] = view
    end
  end
end

---@return AutoFinderSection[]
function M.enabled()
  return M._enabled
end

---@param key integer|string  -- numeric index or view name
---@return AutoFinderSection|nil
function M.resolve(key)
  if type(key) == "number" then
    return M._by_number[key]
  end
  local n = tonumber(key)
  if n then return M._by_number[n] end
  local idx = M._by_name[key]
  if idx then return M._by_number[idx] end
  return nil
end

---Name of the currently-active view (the one mounted in the
---panel right now), or nil if no view is active. Reads
---`auto-finder.state.section` — the section/view number the
---host module tracks — and resolves it to the view name via
---the registry. Used by the five-guard `_still_current`
---predicate in `shared/neotree.lua` (ADR §2.3 — guard #4:
---"did the user switch view between the placeholder mount and
---our deferred callback?").
---@return string|nil
function M.active()
  local ok, af = pcall(require, "auto-finder")
  if not ok then return nil end
  if not af.state or type(af.state.section) ~= "number" then return nil end
  local view = M._by_number[af.state.section]
  return view and view.name or nil
end

return M
