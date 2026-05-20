---View 1 — files (neo-tree filesystem wrapper).
---
---Drives neo-tree to mount its filesystem source into the panel
---window via `position = "current"`. All the mount plumbing
---(neo-tree command surface, buffer-swap wait, auto_expand_width
---sync, on_close cleanup) lives in `auto-finder.shared.neotree`
---— this module is just the view descriptor.
---
---ADR 0026 Phase 2: moved from `auto-finder.sections.files` to
---`auto-finder.views.files`; helper moved from
---`auto-finder.sections._neotree` to `auto-finder.shared.neotree`.
---The original section path remains valid via the
---`sections/files.lua` facade.
---@module 'auto-finder.views.files'

return require("auto-finder.shared.neotree").build_section({
  name = "files",
  description = "filesystem (neo-tree wrapper)",
  source = "filesystem",
  -- Subscribe to auto-core.fs.watch (Phase 4b) so the file tree
  -- auto-refreshes when the filesystem changes underneath. Soft-dep:
  -- if auto-core isn't installed, this flag is a no-op and the
  -- view behaves as it did pre-integration.
  live_refresh = true,
})
