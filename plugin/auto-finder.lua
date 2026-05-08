if vim.g.loaded_auto_finder then return end
vim.g.loaded_auto_finder = true

vim.api.nvim_create_user_command("AutoFinder", function(opts)
  require("auto-finder").toggle(opts.bang)
end, {
  bang = true,
  desc = "Toggle the auto-finder panel (! bypasses the width-guard)",
})

vim.api.nvim_create_user_command("AutoFinderFocus", function(opts)
  local arg = opts.fargs[1]
  if not arg then
    vim.notify("AutoFinderFocus: argument must be a section number or name", vim.log.levels.ERROR)
    return
  end
  -- Numeric arg → coerce so resolve() can match by index directly.
  local n = tonumber(arg)
  local ok, msg = require("auto-finder").focus(n or arg)
  if not ok then
    vim.notify("AutoFinderFocus: " .. (msg or "failed"), vim.log.levels.ERROR)
  end
end, {
  nargs = 1,
  desc = "Focus an auto-finder section by number or name",
})

vim.api.nvim_create_user_command("AutoFinderResize", function(opts)
  local n = tonumber(opts.fargs[1])
  if not n then
    vim.notify("AutoFinderResize: argument must be a column count", vim.log.levels.ERROR)
    return
  end
  require("auto-finder").resize(n)
end, {
  nargs = 1,
  desc = "Pin the auto-finder panel width to N columns",
})

vim.api.nvim_create_user_command("AutoFinderReset", function()
  require("auto-finder").reset_width()
end, {
  desc = "Clear the user-pinned panel width (revert to percentage default)",
})

