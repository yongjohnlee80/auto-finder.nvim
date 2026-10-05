---Section — kb (AutoDoc).
---
---A thin facade over **AutoDoc's** KB drawer, which lives in AutoDoc
---(ADR 1791209945 §7), as the dbase section is over autodb's (ADR-0078):
---AutoDoc owns the view and its host registry; this file keeps what is
---auto-finder's: the availability gate, the placeholder screen,
---owned-buffer accounting and unconditional teardown. It mirrors
---`views/dbase/init.lua` line for line, so the two hosted drawers behave
---alike; read that file's notes for why each piece is shaped as it is.
---
---**This section does not construct the view.** It registers a host
---PROVIDER with AutoDoc's drawer host registry and mounts the instance
---the registry hands to `mount`; teardown calls the `release` it was
---given rather than disposing the view itself.
---
---@module 'auto-finder.views.kb'

local host = require("auto-finder.panel.host")

local PROVIDER_ID = "auto-finder"
-- Above AutoDoc's self-host (priority 0): when auto-finder is present and
-- the kb section is enabled, this is where the drawer belongs.
local PRIORITY = 100

---AutoDoc's drawer module, or nil when AutoDoc is not installed.
local function _drawer()
  local ok, d = pcall(require, "autodoc.views.drawer")
  if ok then return d end
  return nil
end

---The availability-GATED probe, which decides whether we mount at all.
---A drawer module with no session module behind it is not usable.
local function _available()
  if not pcall(require, "autodoc.session") then return false end
  return _drawer() ~= nil
end

local M = {
  name = "kb",
  description = "AutoDoc knowledge base",
  _bufnr = nil,
  _owned_bufs = {},
  -- The instance the host registry handed us, and the release that ends
  -- our ownership of it. Never constructed here.
  _view = nil,
  _release = nil,
}

---A small screen shown in the panel when AutoDoc is not available, so
---the section stays selectable and explains itself instead of silently
---no-op'ing.
---@param panel_winid integer
---@param reason string?
---@return integer bufnr
local function placeholder_buffer(panel_winid, reason)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  -- Canonical panel filetype so bufferline offsets reserve the column for this
  -- fallback screen too, matching every other section.
  vim.bo[bufnr].filetype = "auto-finder"
  vim.b[bufnr].auto_finder_view = "kb"
  vim.api.nvim_buf_set_name(bufnr, "auto-finder-kb://placeholder")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "  kb section",
    "",
    "  AutoDoc is not available: " .. (reason or "AutoDoc is not installed"),
    "",
    "  Install AutoDoc and rerun :AutoFinderFocus kb.",
  })
  vim.bo[bufnr].modifiable = false
  host.with_unfixed_buf(panel_winid, function()
    if vim.api.nvim_win_is_valid(panel_winid) then
      vim.api.nvim_win_set_buf(panel_winid, bufnr)
    end
  end)
  M._owned_bufs[bufnr] = true
  return bufnr
end

-- ─── the host provider (ADR-0078 §3.3) ────────────────────────

---The profile is auto-finder's identity, frozen before the buffer
---exists: the panel filetype, the view tag and the buffer name.
M.profile = {
  filetype      = "auto-finder",
  buf_var       = "auto_finder_view",
  buf_var_value = "kb",
  buf_name      = "auto-finder://kb",
  editor_target_winid = function()
    local ok, af = pcall(require, "auto-finder")
    if ok and af._editor_target_winid then return af._editor_target_winid() end
    return nil
  end,
}

M.provider = {
  id = PROVIDER_ID,
  priority = PRIORITY,
  profile = M.profile,
  available = _available,

  ---mount accepts the registry-built view and shows it in our panel.
  ---@param view any
  ---@param release fun()
  ---@return integer? winid
  mount = function(view, release)
    M._view, M._release = view, release
    local ok = pcall(function() require("auto-finder").focus("kb") end)
    if not ok then return nil end
    local p = require("auto-core").ui.panel.get(PROVIDER_ID)
    return p and p.winid or nil
  end,

  ---@return integer? winid
  focus = function()
    local ok = pcall(function() require("auto-finder").focus("kb") end)
    if not ok then return nil end
    local p = require("auto-core").ui.panel.get(PROVIDER_ID)
    return p and p.winid or nil
  end,

  ---close is OUR surface teardown. The registry disposes the view, so
  ---this must not call release back at it.
  close = function()
    M._view, M._release = nil, nil
  end,
}

---register wires this section into AutoDoc's drawer host registry.
---Safe to call repeatedly: same-id registration replaces.
---
---Called when the section is CONFIGURED (setup, or a slot add), not when
---it is first focused, so `:AutodocDrawer` finds auto-finder as its host
---before anyone has visited the section.
function M.register()
  local d = _drawer()
  if not d then return false end
  local ok = d.register_host(M.provider)
  return ok and true or false
end

---is_registered asks AutoDoc whether this provider is advertised: the
---registry is the single source of truth, never a local boolean.
---@return boolean
function M.is_registered()
  local d = _drawer()
  if not d or type(d.has_host) ~= "function" then return false end
  return d.has_host(PROVIDER_ID) == true
end

---unregister withdraws this section as a drawer host, when the section
---is REMOVED from the panel (never on an ordinary panel close), so the
---next open falls back to AutoDoc's own panel.
function M.unregister()
  local d = _drawer()
  if not d then return end
  d.unregister_host(PROVIDER_ID)
  M._view, M._release = nil, nil
end

---The section registry caches the first valid buffer and calls this ONCE.
---@param panel_winid integer
---@return integer bufnr
function M.get_buffer(panel_winid)
  -- Focused directly (`:AutoFinderFocus kb`) rather than through the
  -- drawer's open: ask the registry to mount here (the safety net for a
  -- consumer driving views without auto-finder.setup).
  if not M._view and _available() then
    M.register()
    pcall(function() _drawer().open() end)
  end
  if M._view then
    M._bufnr = M._view:get_buffer(panel_winid)
    return M._bufnr
  end
  M._bufnr = placeholder_buffer(panel_winid, "AutoDoc is not installed")
  return M._bufnr
end

---Fires on EVERY focus, unlike `get_buffer`.
---@param panel_winid integer
---@param bufnr integer
function M.on_focus(panel_winid, bufnr)
  if M._view then
    pcall(function() M._view:on_focus(panel_winid, bufnr) end)
  end
end

---The section registry's per-section config-forwarding path. AutoDoc
---owns its own setup() (AutoVim's lua/plugins/autodoc.lua), so there is
---nothing to forward today.
---@param opts table?
function M.configure(opts)
  M._setup_opts = opts
end

---Drop the cached bufnr and RELEASE the drawer, whether or not AutoDoc
---is still mountable: `release()` tells AutoDoc's host registry the
---surface is gone, so it disposes the view.
function M.on_close()
  local release = M._release
  M._view, M._release = nil, nil
  if release then pcall(release) end
  for bufnr in pairs(M._owned_bufs) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
  M._bufnr = nil
  M._owned_bufs = {}
end

---Test seams.
M._available_for_tests = _available
M._drawer_for_tests = _drawer

return M
