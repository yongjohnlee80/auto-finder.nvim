---auto-finder.core.buffers — buffer-list state cache (ADR §2.7).
---
---Mirrors the nvim buffer list (`:ls`-shaped, including
---unloaded). Subscribes via `core.ensure_started` to BufAdd /
---BufDelete / BufEnter / BufWritePost autocmds; translates them
---into `auto-finder.core.buffers:changed` events for views.
---
---Public surface:
---
---  buffers.snapshot_now()        → { list, readiness }
---  buffers.snapshot_async(cb)    → callback when populated
---  buffers.get(bufnr)            → entry | nil
---  buffers._arm_autocmds()       — (re)create the augroup; idempotent
---  buffers._disarm_autocmds()    — clear the augroup
---
---Entry shape:
---
---  { bufnr, name, listed, loaded, modified, filetype, buftype }
---
---**Phase 6 status: real impl.** Phase 1 shipped this as a
---placeholder. Phase 6 wires the autocmd subscriptions through
---`core.ensure_started` so the cache stays current across panel
---switches, and publishes the translated topic so view modules
---can subscribe via the new `core_refresh_topic` opt on
---`shared.neotree.build_section`.
---
---@module 'auto-finder.core.buffers'

local M = {}

M._cache = {}  -- { [bufnr] = entry }
M._readiness = "cold"

local AUGROUP_NAME = "auto-finder.core.buffers"
local _augroup_id = nil

---Build the entry table for a bufnr by reading vim's buffer
---state. Returns nil if the buffer isn't valid.
---@param bufnr integer
---@return table|nil
local function _build_entry(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return nil end
  local name = vim.api.nvim_buf_get_name(bufnr)
  return {
    bufnr    = bufnr,
    name     = name,
    listed   = vim.bo[bufnr].buflisted and true or false,
    loaded   = vim.api.nvim_buf_is_loaded(bufnr),
    modified = vim.bo[bufnr].modified and true or false,
    filetype = vim.bo[bufnr].filetype,
    buftype  = vim.bo[bufnr].buftype,
  }
end

---v0.2.67: only user-visible buffers belong in the cache — the
---buffers view renders listed buffers plus terminals and nothing
---else (`neotree/sources/buffers/lib/items.lua` filters on
---`buflisted`). Tracking every buffer meant every scratch/`nofile`
---buffer — notifier toasts, cursor-trail floats, picker previews —
---published a `buffers:changed` event on create/delete/enter. That
---event spam was the transport of the notification→refresh feedback
---loop (each slow-scan toast's buffer teardown re-triggered a
---refresh) and churned the buffers panel for buffers it never shows.
---@param bufnr integer
---@return boolean
local function _user_visible(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return false end
  if vim.bo[bufnr].buflisted then return true end
  return vim.bo[bufnr].buftype == "terminal"
end

---Populate the cache from `nvim_list_bufs()`. Used at
---`_arm_autocmds` time so the cache reflects reality immediately,
---not just from the next autocmd onward.
local function _refresh_all()
  M._cache = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if _user_visible(bufnr) then
      local e = _build_entry(bufnr)
      if e then M._cache[bufnr] = e end
    end
  end
  M._readiness = "ready"
end

---Update one entry and publish auto-finder.core.buffers:changed.
---Buffers that were never user-visible (see `_user_visible`) are
---ignored entirely — no cache entry, no event. A cached buffer that
---turns non-visible (e.g. `setlocal nobuflisted`) is downgraded to a
---`remove` so subscribers converge with the panel's rendering.
---@param bufnr integer
---@param kind 'add'|'remove'|'enter'|'modify'
local function _mutate(bufnr, kind)
  if kind == "remove" then
    if M._cache[bufnr] == nil then return end  -- never tracked → silent
    M._cache[bufnr] = nil
  elseif not _user_visible(bufnr) then
    if M._cache[bufnr] == nil then return end  -- scratch/notif → silent
    M._cache[bufnr] = nil
    kind = "remove"
  else
    local e = _build_entry(bufnr)
    if e then M._cache[bufnr] = e end
  end
  -- Publish via the events wrapper. Soft-fail if auto-core isn't
  -- present; the cache mutation already happened, only the event
  -- fan-out is lost.
  pcall(function()
    require("auto-finder.core.events").publish(
      "auto-finder.core.buffers:changed",
      { kind = kind, bufnr = bufnr })
  end)
end

---@return { list: table[], readiness: 'cold'|'ready' }
function M.snapshot_now()
  local list = {}
  for _, e in pairs(M._cache) do
    list[#list + 1] = e
  end
  -- Sort by bufnr so consumers get a stable order. neo-tree's
  -- bundled buffers source orders by bufnr too.
  table.sort(list, function(a, b) return a.bufnr < b.bufnr end)
  return { list = list, readiness = M._readiness }
end

---@param cb fun(snapshot: table)
function M.snapshot_async(cb)
  if M._readiness == "ready" then
    vim.schedule(function() cb(M.snapshot_now()) end)
    return
  end
  -- Wait for the next buffers:changed and then fire. Also kick a
  -- refresh so the callback isn't stranded on a quiet session.
  -- v0.2.67: the scheduled refresh now resolves the callback
  -- DIRECTLY once the cache is warm. Previously the callback relied
  -- on the next autocmd-driven event — near-instant when every
  -- scratch buffer published, but with `_user_visible` filtering a
  -- quiet session could strand it indefinitely.
  local events_mod = require("auto-finder.core.events")
  local done = false
  local handle
  local function finish()
    if done then return end
    done = true
    if handle then events_mod.unsubscribe(handle) end
    cb(M.snapshot_now())
  end
  handle = events_mod.subscribe("auto-finder.core.buffers:changed", finish)
  vim.schedule(function()
    _refresh_all()
    finish()
  end)
end

---@param bufnr integer
---@return table|nil
function M.get(bufnr)
  return M._cache[bufnr]
end

---Arm the buffer-tracking augroup. Idempotent — clears any
---existing autocmds under the augroup name first, so re-calling
---from `core.ensure_started` on a bus-reset path leaves a single
---live group.
function M._arm_autocmds()
  _augroup_id = vim.api.nvim_create_augroup(AUGROUP_NAME, { clear = true })

  -- Pre-populate the cache from the current buffer list so
  -- snapshot_now is meaningful from the first call. Without this
  -- the cache would only grow as new events arrived, missing
  -- every pre-existing buffer.
  _refresh_all()

  vim.api.nvim_create_autocmd("BufAdd", {
    group = _augroup_id,
    callback = function(args) _mutate(args.buf, "add") end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = _augroup_id,
    callback = function(args) _mutate(args.buf, "remove") end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = _augroup_id,
    callback = function(args) _mutate(args.buf, "enter") end,
  })
  vim.api.nvim_create_autocmd({ "BufWritePost", "BufModifiedSet" }, {
    group = _augroup_id,
    callback = function(args) _mutate(args.buf, "modify") end,
  })
end

---Clear the augroup. Used by `core.stop`. Idempotent.
function M._disarm_autocmds()
  if _augroup_id then
    pcall(vim.api.nvim_del_augroup_by_id, _augroup_id)
    _augroup_id = nil
  end
  M._readiness = "cold"
  M._cache = {}
end

---Test-only: reset cache + readiness without touching the
---augroup (the augroup survives smoke runs).
function M._reset_for_tests()
  M._cache = {}
  M._readiness = "cold"
end

return M
