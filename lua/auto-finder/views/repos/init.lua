---View 2 — repos (registered repos × git worktrees).
---
---Drives neo-tree to mount the `auto-finder-repos` source (a custom
---neo-tree source ported from Bryan Cua's `neo-tree-workspace`) into
---the panel window via `position = "current"`. Mount plumbing is
---shared with the files view in `auto-finder.shared.neotree`.
---
---Discovery is delegated to worktree.nvim (single source of truth):
---`require("auto-finder.repos").load()` returns whatever
---`worktree.git.list_child_repos(worktree.get_root())` finds, plus
---the root itself when it's a git repo. No registry, no manual
---add — what worktree.nvim sees is what shows up here.
---
---The neo-tree source itself (worktree expansion via `git worktree
---list --porcelain`, fs_event watchers on `<gitdir>/worktrees/`,
---lazy directory expansion) lives at `lua/auto-finder-repos/init.lua`.
---
---ADR 0026 Phase 2: moved from `auto-finder.sections.repos` to
---`auto-finder.views.repos`. Original path remains valid via facade.
---@module 'auto-finder.views.repos'

-- ADR-0060 (P4): the repos slot moves from the `auto-finder-repos` neo-tree
-- source to worktree.nvim's own explorer. The switch is by AVAILABILITY rather
-- than configuration [DECISION -- Johno, 2026-08-22], exactly as the dbase slot
-- switched to autodb (ADR-0058): a worktree.nvim exposing `repos.available()`
-- IS the cutover, and until then the neo-tree path below is untouched.
--
-- Delegation rather than a rewrite in place, deliberately: a developer
-- mid-session keeps a working panel either way, and the change reverses by
-- downgrading one plugin. Hard removal of the old source may follow in a later
-- minor (ADR-0060 §6.3).
local function _worktree_view()
  local ok, r = pcall(require, "worktree.repos")
  if not ok or type(r) ~= "table" then return nil end
  if type(r.available) ~= "function" or not r.available() then return nil end
  local ok_tree, tree = pcall(require, "auto-finder.views.repos.tree")
  if ok_tree then return tree end
  return nil
end

---_worktree_view_unchecked resolves the new tree WITHOUT the availability gate.
---
---Teardown must not depend on whether the implementation is currently
---MOUNTABLE. If worktree.nvim was available at mount and is not at close (a
---downgrade, a `:Lazy reload`), gating `on_close` on availability skips the
---teardown of something we really did mount — which is how the new tree's
---buffer and its event subscriptions leaked permanently (ADR-0060 r1 MF6).
local function _worktree_view_unchecked()
  local ok_tree, tree = pcall(require, "auto-finder.views.repos.tree")
  if ok_tree then return tree end
  return nil
end

local _legacy = require("auto-finder.shared.neotree").build_section({
  name = "repos",
  description = "registered repos × git worktrees",
  source = "auto-finder-repos",
  -- ADR 0026 Phase 6: subscribe to auto-finder.core.repos:changed
  -- (published by core's translator on worktree:switched) so the
  -- section refreshes on workspace-root changes through the
  -- centralized signal. Phase 7's mount contract will consume
  -- core.repos.snapshot_now directly.
  core_refresh_topic = "auto-finder.core.repos:changed",
})

---The view the registry sees. `get_buffer` delegates to worktree.nvim's
---explorer when it is available, else to the legacy neo-tree section — and the
---choice is then LATCHED to the buffer it produced.
---
---The probe still runs fresh on every MOUNT, because worktree.nvim may be
---lazy-loaded after this module is required and a one-shot probe would pin the
---wrong answer forever. What it must not do is run per hook: the section
---registry caches the first valid buffer and never calls `get_buffer` again, so
---a probe that flipped between the mount and the next focus handed the NEW
---tree the CACHED LEGACY buffer (ADR-0060 r1 MF6). The new tree then rendered
---into a foreign buffer with its own `_bufnr` still nil, which hard-gates
---`_rerender` and freezes the tree — expand/collapse included.
local _latch = require("auto-finder.shared.impl_latch").new("views.repos")

local NEW, LEGACY = "worktree", "legacy"

-- Forward-declared so the helpers below close over the LOCAL `M`, not a global
-- of the same name. Declaring it after them would silently create a global and
-- leave the helpers reading nil.
local M

---_impl_for resolves the implementation that owns `bufnr`, falling back to a
---fresh probe only when this buffer is unknown (a first mount, or after a
---reset). Indirects through `M._probe_for_tests` / `M._unchecked_for_tests` /
---`M._legacy_for_tests` rather than the upvalues, so the suite can substitute
---any side and exercise every path on a machine that only resolves one.
---
---Ownership and availability answer DIFFERENT questions, and only one of them
---belongs here. Ownership is a historical fact — which implementation wrote
---this buffer's contents, keymaps and subscriptions — and it cannot change
---while the buffer lives. Availability is forward-looking: what a NEW mount
---should pick. So the probe runs ONLY on the `owner == nil` path.
---
---An earlier version re-probed for a NEW owner and fell back to legacy when
---availability dropped, which was MF6 wearing the other shoe: `on_focus` and
---`refresh` handed a new-owned buffer to legacy, which then installed its
---keymaps over the owner's and armed subscriptions against a buffer it will
---never tear down, while the owner's own `_bufnr`-gated render never ran — a
---silently frozen panel (r2 #3). The justifying comment claimed it "let the
---legacy path handle teardown", but this helper is not on the teardown path at
---all: `on_close` resolves unchecked. The rationale was transplanted from the
---wrong hook.
---
---Crossing over is never the graceful option. The new tree already renders an
---explicit "worktree.nvim's repos surface is unavailable" screen when its
---backend is gone, so owner-routing yields a truthful panel where crossing
---yields a stale one.
---@param bufnr integer?
---@return table? impl, string? key   nil impl = route nowhere, deliberately
local function _impl_for(bufnr)
  local owner = _latch:owner(bufnr)
  if owner == LEGACY then return M._legacy_for_tests, LEGACY end
  if owner == NEW then
    -- Resolved UNCHECKED: this buffer belongs to the new tree whether or not
    -- the backend is currently advertising itself.
    local v = M._unchecked_for_tests()
    if v then return v, NEW end
    -- The owner's OWN module cannot be loaded — auto-finder itself is broken.
    -- No-op rather than hand the buffer to the other implementation.
    return nil, nil
  end
  -- owner == nil: a first mount (or post-reset). This is the one place the
  -- availability probe decides anything.
  local v = M._probe_for_tests()
  if v then return v, NEW end
  return M._legacy_for_tests, LEGACY
end

M = {
  name = _legacy.name,
  description = "repos x worktrees x work in flight",
  -- Re-declared, not inherited by accident: `shared.neotree.build_section`
  -- wires the legacy path's subscription from this field, and the Phase 6
  -- acceptance ledger asserts the view still declares it. Both paths refresh
  -- off the SAME translated topic.
  _core_refresh_topic = _legacy._core_refresh_topic
    or "auto-finder.core.repos:changed",
}

---A MOUNT re-decides which implementation serves the slot, then latches it to
---the buffer produced, so every later hook for that buffer reaches its creator.
function M.get_buffer(panel_winid)
  _latch:prune()
  local impl, key = _impl_for(nil)
  -- A mount always resolves: the legacy section is a hard require. A nil here
  -- would mean auto-finder's own module tree is broken, so fail loudly.
  if not impl then return nil end
  local bufnr = impl.get_buffer(panel_winid)
  _latch:claim(bufnr, key)
  M._mounted_bufnr = bufnr
  return bufnr
end

function M.on_focus(panel_winid, bufnr)
  if type(bufnr) == "number" then M._mounted_bufnr = bufnr end
  local impl = _impl_for(bufnr)
  -- nil means the owner cannot be resolved; routing to the other
  -- implementation would corrupt the buffer, so do nothing.
  if impl and impl.on_focus then return impl.on_focus(panel_winid, bufnr) end
end

function M.on_close()
  -- Close BOTH, UNCONDITIONALLY. This used to gate each branch behind the same
  -- per-call probe, so on the reverse transition (worktree.nvim becoming
  -- unavailable) the new tree's on_close never ran at all — leaking its buffer
  -- AND its event subscriptions permanently. The old comment claimed calling
  -- the inactive one was "a no-op"; in fact it was never called (r1 MF6).
  -- Resolved UNCHECKED: a slot we mounted must be torn down even if its
  -- implementation is no longer advertising availability.
  local v = M._unchecked_for_tests()
  if v and v.on_close then pcall(v.on_close) end
  local legacy = M._legacy_for_tests
  if legacy and legacy.on_close then pcall(legacy.on_close) end
  _latch:reset()
  M._mounted_bufnr = nil
end

function M.refresh()
  -- Refresh follows the CURRENTLY MOUNTED buffer's owner where we know it;
  -- the registry owns the buffer, so ask the latch for anything it has claimed
  -- before falling back to a probe.
  local impl = _impl_for(M._mounted_bufnr)
  if impl and impl.refresh then return impl.refresh() end
end

---_legacy_for_tests exposes the fallback so the smoke suite can assert BOTH
---paths rather than only whichever one this machine happens to resolve.
---These are the LIVE indirection points, not copies: `_impl_for` reads them, so
---substituting either one exercises the real routing logic.
M._legacy_for_tests = _legacy
M._probe_for_tests = _worktree_view
---The availability-gated probe decides MOUNTS; the unchecked one drives
---TEARDOWN. Kept as separate seams so a test can prove that distinction.
M._unchecked_for_tests = _worktree_view_unchecked
M._latch_for_tests = _latch
---The buffer the registry most recently mounted or focused for this slot, used
---to route `refresh()` to the implementation that actually owns the panel.
M._mounted_bufnr = nil

return M
