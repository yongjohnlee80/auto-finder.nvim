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

return require("auto-finder.shared.neotree").build_section({
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
