---auto-finder.shared.loading — generation-tagged placeholder
---buffer factory for the two-phase view mount (ADR §2.3).
---
---Every view's `get_buffer` returns a placeholder via this
---helper, then `on_focus` schedules the real mount + swap. The
---placeholder makes the wait visible ("Loading files…") and
---carries the per-view generation tag so the deferred mount
---callback can detect a stale focus (race detection per §2.3
---five-guard `_still_current`).
---
---Public surface:
---
---  loading.buffer({ view, generation, message })  → bufnr
---
---@module 'auto-finder.shared.loading'

local M = {}

---Build the placeholder lines shown in the panel during the
---loading phase. Default uses `Loading <view>…`; consumers can
---pass an explicit `message`.
---@param opts { view: string, message: string? }
---@return string[]
local function _lines(opts)
  local msg = opts.message or ("Loading " .. tostring(opts.view) .. "…")
  return {
    "",
    "  " .. msg,
    "",
    "  (auto-finder is mounting the view)",
  }
end

---Create a scratch buffer that the panel mounts during the
---placeholder phase. The buffer is tagged with `view` and
---`generation` via buffer-local vars so the deferred render
---callback can recognize it (see ADR §2.3 guard #5 —
---`_view_owns_buf` reads `auto_finder_placeholder_gen`).
---
---The buffer is `nofile` + `bufhidden=wipe` so it doesn't
---persist after the panel swaps to the real buffer — leaking
---placeholder buffers would inflate `:ls` for no reason.
---@param opts { view: string, generation: integer, message: string? }
---@return integer bufnr
function M.buffer(opts)
  if type(opts) ~= "table" then
    error("shared.loading.buffer requires an opts table")
  end
  if type(opts.view) ~= "string" or opts.view == "" then
    error("shared.loading.buffer requires opts.view (non-empty string)")
  end
  if type(opts.generation) ~= "number" then
    error("shared.loading.buffer requires opts.generation (integer)")
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype   = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile  = false
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_name(bufnr, "auto-finder://loading/" .. opts.view
    .. "/" .. opts.generation)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, _lines(opts))
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly   = true
  -- Buffer-local tags so smokes (and any future inspector tooling)
  -- can identify a placeholder + its origin view + generation.
  -- _still_current's guard #5 uses these via the `_view_owns_buf`
  -- check in build_section.
  vim.b[bufnr].auto_finder_placeholder = true
  vim.b[bufnr].auto_finder_placeholder_view = opts.view
  vim.b[bufnr].auto_finder_placeholder_gen  = opts.generation
  return bufnr
end

---Predicate: is `bufnr` a loading-placeholder buffer? Cheap
---buffer-var read; safe on any bufnr including invalid ones.
---@param bufnr integer
---@return boolean
function M.is_placeholder(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return false end
  return vim.b[bufnr].auto_finder_placeholder == true
end

---Predicate: is `bufnr` a placeholder for `view` at `generation`?
---Used by the five-guard `_still_current` predicate to confirm
---the panel still holds OUR placeholder (not one a sibling view
---swapped in between get_buffer and on_focus).
---@param bufnr integer
---@param view string
---@param generation integer
---@return boolean
function M.matches(bufnr, view, generation)
  if not M.is_placeholder(bufnr) then return false end
  return vim.b[bufnr].auto_finder_placeholder_view == view
     and vim.b[bufnr].auto_finder_placeholder_gen  == generation
end

return M
