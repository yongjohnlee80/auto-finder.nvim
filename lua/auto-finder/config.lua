---Configuration defaults, validation, and width resolution for auto-finder.
---@module 'auto-finder.config'

local M = {}

---@class AutoFinderConfig
---@field width { default?: integer, percentage?: number, min: integer, max: integer }
---@field default_section integer
---@field sections string[]      -- ordered list of section names enabled this session
---@field files table            -- reserved; currently a no-op (defer to neo-tree's own setup)
---@field hijack_directories boolean  -- replace directory buffers with the panel + cwd at the dir
---
---NOTE: the `side` field was removed in v0.1.x — the panel is now
---always anchored to the left. The right slot is reserved for
---auto-agents.nvim's panel and the <F5> terminal. A `side` key in
---user_opts is silently ignored for backwards compat with older
---consumer configs; persisted `panel.side` values in the store are
---also ignored on load.
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
  sections = { "config", "files" },
  files = {},
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
