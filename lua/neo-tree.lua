-- Compat shim: re-exports auto-finder's bundled fork under the
-- `neo-tree.*` namespace so plugins still doing
-- `require("neo-tree")` (auto-agents, coder-claudecode, worktree.nvim,
-- LazyVim's neo-tree extra) hit our fork transparently when upstream
-- neo-tree.nvim has been dropped from the consumer's lazy-lock.
--
-- Keep this file thin. Real code lives in lua/auto-finder/neotree/.
return require("auto-finder.neotree")
