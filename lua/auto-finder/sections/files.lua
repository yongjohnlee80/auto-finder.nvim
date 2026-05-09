---Section 1 — files (neo-tree filesystem wrapper).
---
---Drives neo-tree to mount its filesystem source into the panel
---window via `position = "current"`. All the mount plumbing
---(neo-tree command surface, buffer-swap wait, auto_expand_width
---sync, on_close cleanup) lives in `auto-finder.sections._neotree`
---— this module is just the section descriptor.
---@module 'auto-finder.sections.files'

return require("auto-finder.sections._neotree").build_section({
  name = "files",
  description = "filesystem (neo-tree wrapper)",
  source = "filesystem",
  -- Subscribe to auto-core.fs.watch (Phase 4b) so the file tree
  -- auto-refreshes when the filesystem changes underneath. Soft-dep:
  -- if auto-core isn't installed, this flag is a no-op and the
  -- section behaves as it did pre-integration.
  live_refresh = true,
})
