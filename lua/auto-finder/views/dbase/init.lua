---Section — dbase (autodb).
---
---A thin delegation to `auto-finder.views.dbase.tree`, autodb's renderer.
---
---nvim-dbee was retired here in AutoVim v0.4.0 (ADR-0063 / autodb roadmap M8).
---It is **not a fallback** and is not maintained: AutoVim no longer declares,
---installs or updates it, and every dbee module under this directory
---(`setup`, `layout`, `events`, `files`, `vault`, `encrypted_source`, `crypto`)
---was deleted with it. Do not reintroduce a second backend here without
---restoring the ownership latch that went with it — see the note below.
---
---What went away, and why this file is now ~1/3 its former size: dbee mounted
---asynchronously (`dbee.setup` + `drawer_show` behind a deferred schedule), so
---this section needed a placeholder buffer, a generation guard against a stale
---deferred mount, a remount notification to auto-core's section registry, a
---keymap override to fix dbee's `<CR>`, and an implementation-ownership latch
---so a dbee-built buffer could never be handed to autodb (ADR-0060 r1 MF6 /
---r2 #3). autodb's `tree.get_buffer` returns a real buffer synchronously, so
---none of that is needed. `impl_latch` itself survives — the repos slot still
---has two implementations and uses it.
---
---@module 'auto-finder.views.dbase'

local host = require("auto-finder.panel.host")

---autodb's renderer WITHOUT the availability gate.
---
---Teardown must not depend on whether the backend is still MOUNTABLE: this
---section may have mounted autodb earlier in the session and must dispose its
---subscriptions and named buffer even after it stops advertising itself
---(ADR-0060 r2 #3). That asymmetry is the only reason two probes remain.
local function _autodb_view_unchecked()
  local ok, tree = pcall(require, "auto-finder.views.dbase.tree")
  if ok then
    return tree
  end
  return nil
end

---The availability-GATED probe, which decides whether we mount at all.
local function _autodb_view()
  if not pcall(require, "autodb.session") then
    return nil
  end
  return _autodb_view_unchecked()
end

local M = {
  name = "dbase",
  description = "autodb explorer",
  _bufnr = nil,
  _owned_bufs = {},
}

---A small screen shown in the panel when no database backend is available,
---so the section stays selectable and explains itself instead of silently
---no-op'ing.
---
---It names **autodb**, not dbee: dbee is deliberately gone, so pointing the
---user at it would send them to a dependency AutoVim removed on purpose.
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

---The section registry caches the first valid buffer and calls this ONCE.
---@param panel_winid integer
---@return integer bufnr
function M.get_buffer(panel_winid)
  local autodb_view = M._autodb_for_tests()
  if autodb_view then
    M._bufnr = autodb_view.get_buffer(panel_winid)
    return M._bufnr
  end
  M._bufnr = placeholder_buffer(panel_winid, "autodb is not installed")
  return M._bufnr
end

---Fires on EVERY focus, unlike `get_buffer`.
---@param panel_winid integer
---@param bufnr integer
function M.on_focus(panel_winid, bufnr)
  local autodb_view = M._autodb_for_tests()
  if autodb_view and autodb_view.on_focus then
    pcall(autodb_view.on_focus, panel_winid, bufnr)
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

---Drop the cached bufnr so the next focus remounts cleanly, and tear down the
---backend UNCONDITIONALLY — see `_autodb_view_unchecked`.
function M.on_close()
  local autodb_view = M._unchecked_for_tests()
  if autodb_view and autodb_view.on_close then
    pcall(autodb_view.on_close)
  end
  for bufnr in pairs(M._owned_bufs) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
  M._bufnr = nil
  M._owned_bufs = {}
end

---Test seams. `_autodb_for_tests` is the availability-GATED probe that decides
---MOUNTS; `_unchecked_for_tests` drives TEARDOWN. Kept separate so a test can
---prove that distinction without monkey-patching `require` (ADR-0060 r2 #3).
M._autodb_for_tests = _autodb_view
M._unchecked_for_tests = _autodb_view_unchecked

return M
