---Section — dbase (autodb).
---
---A thin facade over **autodb's** drawer, which lives in autodb since
---ADR-0078: the renderer reads only `autodb.session`, so autodb owns it,
---and moving it there is what lets autodb show a drawer when installed
---without auto-finder. This file keeps everything that is auto-finder's:
---the availability gate, the placeholder screen, owned-buffer accounting
---and unconditional teardown.
---
---**This section does not construct the view.** It registers a host
---PROVIDER with autodb's drawer host registry and mounts the instance
---the registry hands to `mount` (ADR-0078 §3.3): the registry is the
---sole constructor and sole disposer, which is what makes "at most one
---mounted drawer" enforceable in one place rather than trusted to every
---host. Teardown here therefore calls the `release` it was given rather
---than disposing the view itself — without that, autodb would still
---believe the drawer was mounted and the next open would focus a dead
---surface.
---
---The `view_modules` hook is deliberately NOT how this is wired: it
---replaces the whole module for a section, which would bypass this
---facade's placeholder and teardown.
---
---nvim-dbee was retired here in AutoVim v0.4.0 (ADR-0063 / autodb roadmap M8).
---It is **not a fallback** and is not maintained. Do not reintroduce a
---second backend here without restoring the ownership latch that went
---with it (ADR-0060 r1 MF6 / r2 #3).
---
---@module 'auto-finder.views.dbase'

local host = require("auto-finder.panel.host")

local PROVIDER_ID = "auto-finder"
-- Above autodb's self-host (priority 0): when auto-finder is present and
-- the dbase section is enabled, this is where the drawer belongs.
local PRIORITY = 100

---autodb's drawer module, or nil when autodb is not installed.
local function _drawer()
  local ok, d = pcall(require, "autodb.views.drawer")
  if ok then return d end
  return nil
end

---The availability-GATED probe, which decides whether we mount at all.
---A drawer module with no session module behind it is not usable.
local function _available()
  if not pcall(require, "autodb.session") then return false end
  return _drawer() ~= nil
end

local M = {
  name = "dbase",
  description = "autodb explorer",
  _bufnr = nil,
  _owned_bufs = {},
  -- The instance the host registry handed us, and the release that ends
  -- our ownership of it. Never constructed here.
  _view = nil,
  _release = nil,
}

---A small screen shown in the panel when no database backend is
---available, so the section stays selectable and explains itself
---instead of silently no-op'ing.
---
---It names **autodb**, not dbee: dbee is deliberately gone, so pointing
---the user at it would send them to a dependency AutoVim removed on
---purpose.
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
  vim.b[bufnr].auto_finder_view = "dbase"
  vim.api.nvim_buf_set_name(bufnr, "auto-finder-dbase://placeholder")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "  dbase section",
    "",
    "  no database backend available: " .. (reason or "autodb is not installed"),
    "",
    "  Install autodb and rerun :AutoFinderFocus dbase.",
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
---exists. It reproduces exactly what this section produced before the
---move — the smoke suite asserts all three, and that is the regression
---gate on the whole change.
M.profile = {
  filetype      = "auto-finder",
  buf_var       = "auto_finder_view",
  buf_var_value = "dbase",
  buf_name      = "auto-finder://dbase",
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
    local ok = pcall(function() require("auto-finder").focus("dbase") end)
    if not ok then return nil end
    local p = require("auto-core").ui.panel.get(PROVIDER_ID)
    return p and p.winid or nil
  end,

  ---@return integer? winid
  focus = function()
    local ok = pcall(function() require("auto-finder").focus("dbase") end)
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

---register wires this section into autodb's drawer host registry.
---Safe to call repeatedly: same-id registration replaces.
---
---Called when the section is CONFIGURED (setup, or a slot add), not when
---it is first focused. Registering on focus meant `drawer_open` before
---anyone had visited the section chose autodb's fallback panel even
---though auto-finder was right there to host it (lector impl-r0 MF1).
function M.register()
  local d = _drawer()
  if not d then return false end
  local ok = d.register_host(M.provider)
  return ok and true or false
end

---is_registered asks AUTODB whether this provider is advertised.
---
---The registry is the single source of truth; keeping a boolean here (or
---in auto-finder.init) is a second copy that goes stale the moment any
---other entry point registers — which is exactly what the late-load
---safety net in get_buffer does (lector impl-r2 MF1).
---@return boolean
function M.is_registered()
  local d = _drawer()
  if not d or type(d.has_host) ~= "function" then return false end
  return d.has_host(PROVIDER_ID) == true
end

---unregister withdraws this section as a drawer host.
---
---Called when the section is REMOVED from the panel (a slot remove or a
---workspace change), never on an ordinary panel close: closing the panel
---releases the mount but auto-finder is still a perfectly good host for
---the next open. Without this, a removed section stayed a candidate and
---the next `drawer_open` failed against a section that no longer exists
---instead of falling back to autodb (lector impl-r0 MF1).
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
  -- Focused directly (`:AutoFinderFocus dbase`) rather than through
  -- `drawer_open`: ask the registry to mount here, which resolves to
  -- this provider and hands us a view. Registration normally happens at
  -- setup/slot-add (see M.register); this is the safety net for a
  -- consumer driving views without going through auto-finder.setup.
  if not M._view and _available() then
    M.register()
    pcall(function() _drawer().open() end)
  end
  if M._view then
    M._bufnr = M._view:get_buffer(panel_winid)
    return M._bufnr
  end
  M._bufnr = placeholder_buffer(panel_winid, "autodb is not installed")
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

---Retained for the section registry's per-section config-forwarding path.
---autodb owns its own `setup()` (called from AutoVim's `lua/plugins/autodb.lua`),
---so there is nothing to forward today; kept so the registry contract does not
---change and a future option has somewhere to land.
---@param opts table?
function M.configure(opts)
  M._setup_opts = opts
end

---Drop the cached bufnr and RELEASE the drawer.
---
---Teardown must not depend on whether the backend is still MOUNTABLE:
---this section may have mounted autodb earlier in the session and must
---let go even after autodb stops advertising itself (ADR-0060 r2 #3).
---`release()` is what tells autodb's host registry the surface is gone,
---so it disposes the view and drops its owner pointer; without it the
---next open would focus a dead surface (ADR-0078 §3.5).
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
