---auto-finder.shared.impl_latch — which implementation owns which buffer.
---
---ADR-0060 r1 MF6. Two views in this plugin choose between a preferred
---implementation and a fallback by PROBING at call time: the repos slot
---(worktree.nvim's explorer vs the legacy neo-tree source) and the dbase slot
---(autodb vs dbee). Probing per hook looks defensive — a lazily-loaded plugin
---appearing mid-session is real, and a one-shot probe would latch the wrong
---answer forever — but it is incompatible with how the panel caches buffers.
---
---`auto-core.ui.section` calls `get_buffer` ONCE and caches the result
---(`section.lua`: "called once, cached until on_close fires"), then fires
---`on_focus` on every focus. So when availability flips between the mount and
---the next focus, the hook of implementation B is handed a buffer created by
---implementation A. In the repos case B then rendered into that foreign buffer
---while its own `_bufnr` stayed nil — which hard-gates `_rerender`, freezing
---expand/collapse and every refresh path — and flipped a neo-tree buffer to
---nomodifiable on the way out.
---
---The fix is ownership, not a different probe cadence: record which
---implementation produced a buffer, and route that buffer's later hooks to its
---owner. A NEW mount re-decides, so a plugin loaded mid-session is still picked
---up on the next remount; what can no longer happen is one implementation
---driving another's buffer.
---
---This lives here rather than in either view because both need the identical
---guarantee, and a second copy of an ownership map is how the duplicated git
---shell-out (r1 SF4) happened. `shared-resolver-single-source-of-truth` applies:
---one mechanism, used twice.
---
---The two views have different shapes — repos wraps a `_legacy` section table,
---dbase inlines its fallback behind a deferred mount — so this shares the
---MECHANISM (the map) rather than forcing both into one wrapper.
---@module 'auto-finder.shared.impl_latch'

local M = {}

---@class AutoFinderImplLatch
---@field name string
---@field _owner table<integer, string>
local Latch = {}
Latch.__index = Latch

---claim records that `key` produced `bufnr`.
---
---A nil bufnr is ignored rather than an error: `get_buffer` is allowed to
---return nil (the implementation declined to mount), and the caller should not
---have to branch before recording.
---@param bufnr integer?
---@param key string
function Latch:claim(bufnr, key)
  if type(bufnr) ~= "number" or key == nil then return end
  self._owner[bufnr] = key
end

---owner reports which implementation created `bufnr`, or nil when this latch
---has never seen it (a buffer from before a reset, or one we did not create).
---@param bufnr integer?
---@return string? key
function Latch:owner(bufnr)
  if type(bufnr) ~= "number" then return nil end
  return self._owner[bufnr]
end

---forget drops one buffer's ownership — call it when the buffer is deleted, so
---a recycled bufnr cannot inherit a stale owner.
---@param bufnr integer?
function Latch:forget(bufnr)
  if type(bufnr) ~= "number" then return end
  self._owner[bufnr] = nil
end

---reset clears every claim. Used on panel close, and by tests.
function Latch:reset()
  self._owner = {}
end

---prune drops claims for buffers nvim has already destroyed, so the map cannot
---grow without bound in a long session.
function Latch:prune()
  for bufnr in pairs(self._owner) do
    if not vim.api.nvim_buf_is_valid(bufnr) then self._owner[bufnr] = nil end
  end
end

---new builds a latch. `name` is for diagnostics only.
---@param name string
---@return AutoFinderImplLatch
function M.new(name)
  return setmetatable({ name = tostring(name or "latch"), _owner = {} }, Latch)
end

return M
