---Section registry. Sections are loaded by name from
---`auto-finder.sections.<name>` and assigned numeric indices in the
---order they appear in `cfg.sections`.
---@module 'auto-finder.sections'

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

---Load a section module by name and assign it an index.
---@param name string
---@param number integer
---@return AutoFinderSection|nil
local function load_section(name, number)
  local ok, mod = pcall(require, "auto-finder.sections." .. name)
  if not ok then
    require("auto-finder.logger").error("sections",
      "failed to load section '" .. name .. "': " .. tostring(mod))
    return nil
  end
  if type(mod) ~= "table" or type(mod.get_buffer) ~= "function" then
    require("auto-finder.logger").error("sections",
      "section '" .. name .. "' missing get_buffer()")
    return nil
  end
  -- Allow the section module itself to declare a `name`; fall back to
  -- the require-key. Index is assigned by the host (caller) so every
  -- session is consistent regardless of internal order.
  mod.name = mod.name or name
  mod.number = number
  return mod
end

---Initialize the registry from a config-style list of section names.
---Resets any previously-loaded registry. Idempotent.
---@param section_names string[]
function M.setup(section_names)
  M._enabled = {}
  M._by_name = {}
  M._by_number = {}
  for i, name in ipairs(section_names) do
    -- Index 0 is reserved for the config slot, indices >= 1 for the rest.
    -- We follow auto-agents' "0 = control surface" convention: the first
    -- entry in cfg.sections gets index 0, the second gets 1, and so on.
    local number = i - 1
    local section = load_section(name, number)
    if section then
      table.insert(M._enabled, section)
      M._by_name[section.name] = number
      M._by_number[number] = section
    end
  end
end

---@return AutoFinderSection[]
function M.enabled()
  return M._enabled
end

---@param key integer|string  -- numeric index or section name
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

return M
