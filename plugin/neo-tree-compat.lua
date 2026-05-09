-- Compat shim for the `:Neotree` user command so external plugins
-- that drive neo-tree via the command surface (worktree.nvim's
-- `:Neotree dir=<path>` refresh path is the primary case) keep
-- working when upstream neo-tree.nvim has been dropped from the
-- consumer's lazy-lock and replaced by auto-finder's bundled fork.
--
-- Mirrors upstream's `plugin/neo-tree.lua:5-11` exactly — same nargs
-- and complete spec, just dispatched into our forked command surface.
if vim.g.loaded_neo_tree == 1 or vim.g.loaded_neo_tree == true then
  return
end
vim.g.loaded_neo_tree = 1

vim.api.nvim_create_user_command("Neotree", function(ctx)
  require("auto-finder.neotree.command")._command(unpack(ctx.fargs))
end, {
  nargs = "*",
  complete = "custom,v:lua.require'auto-finder.neotree.command'.complete_args",
})
