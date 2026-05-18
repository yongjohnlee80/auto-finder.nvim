---Step-by-step wizard runner inside the admin prompt buffer.
---
---Mirrors auto-agents.nvim's `panel/wizard` surface so multi-step
---prompts stay inside the admin REPL (no `vim.fn.input()` popping
---a separate cmdline at the bottom of the editor).
---
---Used by:
---  dbase conn add  (name / type / url)
---  dbase load      (interactive pick when name omitted)
---
---Lifecycle:
---  start(spec, emit)   render banner + first prompt
---  feed(input)         admin dispatch routes here while is_active()
---  cancel()            abort; clears state
---  is_active()         admin checks this before normal dispatch
---
---@module 'auto-finder.panel.wizard'

local M = {}

---@class AutoFinderWizardStep
---@field field string
---@field prompt string
---@field default? any              -- string, or function(values) -> string
---@field choices? string[]
---@field placeholder? string
---@field validate? function        -- (value, values) -> ok, err?
---@field parse? function           -- (raw) -> parsed value (throws on bad input)
---@field skip? function            -- (values) -> bool

---@class AutoFinderWizardSpec
---@field name string
---@field banner? any               -- string or string[] (one or more intro lines)
---@field steps AutoFinderWizardStep[]
---@field on_complete function      -- (values, emit) called after the last step
---@field on_cancel? function

local _state = {
  active = false,
  spec = nil,
  index = 0,
  values = {},
  emit = nil,
}

-- Exposed for tests + admin's <C-c> binding.
M._state = _state

local function reset()
  _state.active = false
  _state.spec = nil
  _state.index = 0
  _state.values = {}
  _state.emit = nil
end

local function compose_question(step, values)
  local default = step.default
  if type(default) == "function" then default = default(values) end
  local placeholder = step.placeholder
    or (default ~= nil and default ~= "" and tostring(default) or nil)
  local hint = ""
  if step.choices and #step.choices > 0 then
    hint = " (" .. table.concat(step.choices, "|") .. ")"
  end
  local default_hint = placeholder and ("  [" .. placeholder .. "]") or ""
  return step.prompt .. hint .. default_hint .. ":"
end

local function render_step()
  local emit = _state.emit
  local step = _state.spec.steps[_state.index]
  if not step then return end
  emit({ "  " .. compose_question(step, _state.values) })
end

local function advance()
  while true do
    _state.index = _state.index + 1
    local step = _state.spec.steps[_state.index]
    if not step then
      local emit = _state.emit
      local values = _state.values
      local on_complete = _state.spec.on_complete
      reset()
      pcall(on_complete, values, emit)
      return
    end
    if step.skip and step.skip(_state.values) then
      if step.default ~= nil then
        local d = step.default
        if type(d) == "function" then d = d(_state.values) end
        _state.values[step.field] = d
      end
    else
      render_step()
      return
    end
  end
end

---@return boolean
function M.is_active() return _state.active end

---Start a wizard. While `is_active()` is true, the admin prompt
---buffer's <CR> callback should route input through `M.feed()`.
---@param spec AutoFinderWizardSpec
---@param emit fun(lines: string[])
function M.start(spec, emit)
  if _state.active then
    emit({ "wizard: a previous wizard is still active — <C-c> to cancel" })
    return
  end
  _state.active = true
  _state.spec = spec
  _state.values = {}
  _state.index = 0
  _state.emit = emit
  if spec.banner then
    local banner = type(spec.banner) == "table"
      and spec.banner
      or { spec.banner }
    local lines = { "" }
    for _, b in ipairs(banner) do lines[#lines + 1] = b end
    lines[#lines + 1] = "  <C-c> to cancel."
    emit(lines)
  end
  advance()
end

---Feed one line of user input. Validates against the current step,
---records the value (or default if blank), and renders the next step.
---@param input string
function M.feed(input)
  if not _state.active then return end
  local step = _state.spec.steps[_state.index]
  if not step then reset(); return end

  local emit = _state.emit
  local raw = input or ""

  local value
  if raw == "" then
    local d = step.default
    if type(d) == "function" then d = d(_state.values) end
    value = d
  else
    value = raw
  end

  if step.parse then
    local ok, parsed = pcall(step.parse, value)
    if not ok then
      emit({ "  ! " .. tostring(parsed) })
      render_step()
      return
    end
    value = parsed
  end

  if step.validate then
    local ok, err = step.validate(value, _state.values)
    if not ok then
      emit({ "  ! " .. (err or "invalid value") })
      render_step()
      return
    end
  end

  _state.values[step.field] = value
  advance()
end

---Cancel the active wizard. Safe to call when inactive.
function M.cancel()
  if not _state.active then return end
  local emit = _state.emit
  local on_cancel = _state.spec.on_cancel
  reset()
  if emit then emit({ "  (wizard cancelled)" }) end
  if on_cancel then pcall(on_cancel, emit) end
end

return M