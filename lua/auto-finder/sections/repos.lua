---Section 2 — repos (registered repos × git worktrees).
---
---Drives neo-tree to mount the `auto-finder-repos` source (a custom
---neo-tree source ported from Bryan Cua's `neo-tree-workspace`) into
---the panel window via `position = "current"`. Mount plumbing is
---shared with the files section in `auto-finder.sections._neotree`.
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
---@module 'auto-finder.sections.repos'

return require("auto-finder.sections._neotree").build_section({
  name = "repos",
  description = "registered repos × git worktrees",
  source = "auto-finder-repos",
})
