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

return require("auto-finder.sections._neotree").build_section({
  name = "buffers",
  description = "open buffers (neo-tree wrapper)",
  source = "buffers",
  -- buffers are nvim-internal; no fs.watch subscription needed.
  -- Refreshes come from neo-tree's own BufAdd / BufDelete event
  -- handlers (set up inside the bundled source's M.navigate path).
  live_refresh = false,
})
