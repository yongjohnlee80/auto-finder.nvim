---auto-finder.sections._neotree — facade re-exporting shared/neotree (ADR 0026 Phase 2).
---
---Moved out of sections/ because it was never a view — it's a
---shared helper that two views (files, repos) build sections from.
---Phase 7 will slim its implementation; this facade keeps the
---legacy require path valid through v0.2.x.
---@module 'auto-finder.sections._neotree'
return require("auto-finder.shared.neotree")
