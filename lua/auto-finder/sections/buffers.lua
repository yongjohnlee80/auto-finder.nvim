---Section — buffers (neo-tree buffers wrapper).
---
---Drives neo-tree to mount its bundled `buffers` source into the
---panel window via `position = "current"`. Shows the list of
---currently-loaded buffers; opening one routes through the
---v0.2.4 editor-window resolver (see
---`auto-finder/init.lua:M._route_open_to_editor`).
---
---All the mount plumbing (cmd.execute, buffer-swap wait, on_close
---cleanup, live-refresh via fs.watch) lives in
---`auto-finder.sections._neotree` — this module is just the
---section descriptor.
---@module 'auto-finder.sections.buffers'

local section = require("auto-finder.sections._neotree").build_section({
  name = "buffers",
  description = "open buffers (neo-tree wrapper)",
  source = "buffers",
  -- buffers are nvim-internal; no fs.watch subscription needed.
  -- Refreshes come from neo-tree's own BufAdd / BufDelete event
  -- handlers (set up inside the bundled source's M.navigate path).
  live_refresh = false,
})

-- v0.2.13 — dirty-bit consumer for the v0.2.11 gate.
--
-- Context: v0.2.11 added a gate in `M._install_buffers_refresh_autocmd`
-- that skips the buffers refresh when buffers ISN'T the active
-- section in the panel — to prevent the refresh from clobbering
-- whichever section the user actually has up. The gate is correct,
-- but the v0.2.11 commit message asserted "the next time the user
-- focuses buffers, the section re-mounts fresh via section.get_buffer
-- and a complete navigate() runs from scratch — no stale tree." That
-- assumption is wrong: section.get_buffer caches its bufnr across
-- focuses, so refocusing buffers reuses the existing buffer + tree
-- state and shows the stale snapshot from before the skipped refresh.
--
-- Fix: when the gate skips, the autocmd-fire sets
-- `M._buffers_dirty = true`. This on_focus wrapper consumes the
-- flag — if dirty, run the refresh inline (against the just-focused
-- state) and clear the flag. The result: the buffers tree reflects
-- every BufAdd/BufDelete that happened while the user was elsewhere
-- in the panel, the moment they switch back.
--
-- The base on_focus from _neotree.build_section validates the
-- cached buffer + reasserts the help keymap; we call it first so
-- the bufnr is guaranteed valid for the refresh body.
local base_on_focus = section.on_focus
section.on_focus = function(panel_winid, bufnr)
  if base_on_focus then base_on_focus(panel_winid, bufnr) end
  local aa = require("auto-finder")
  if aa._buffers_dirty == true then
    aa._buffers_dirty = false
    if type(aa._refresh_buffers_now) == "function" then
      pcall(aa._refresh_buffers_now, panel_winid)
    end
  end
end

return section
