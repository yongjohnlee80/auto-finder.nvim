local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
local AF = os.getenv("AF") or "/home/johno/Source/Projects/nvim-plugins/auto-finder.nvim/main"
for _, p in ipairs({ AF, LAZY .. "/nui.nvim", LAZY .. "/plenary.nvim",
    "/home/johno/Source/Projects/nvim-plugins/auto-core.nvim/main" }) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end
vim.o.columns, vim.o.lines = 200, 60
local sb = vim.fn.tempname() .. "-gi"
vim.env.XDG_STATE_HOME = sb .. "/state"
local root = sb .. "/repo"; vim.fn.mkdir(root, "p")
local function g(...) local a={"git","-C",root,"-c","user.email=t@t","-c","user.name=t"}
  for _,x in ipairs({...}) do a[#a+1]=x end return vim.system(a,{}):wait().code end
g("init","-q","-b","main")
vim.fn.writefile({ "*.ignored" }, root .. "/.gitignore")
vim.fn.writefile({ "visible" }, root .. "/keep.txt")
vim.fn.writefile({ "hidden"  }, root .. "/junk.ignored")
g("add",".gitignore","keep.txt"); g("commit","-qm","init")
vim.fn.chdir(root)

local af = require("auto-finder"); af.setup({})
af.open(true); af.focus(1)
local sec = require("auto-finder.sections").resolve(1)
vim.wait(4000, function() return sec and sec._bufnr and vim.api.nvim_buf_is_valid(sec._bufnr) end)
vim.wait(1200)
local txt = table.concat(vim.api.nvim_buf_get_lines(sec._bufnr, 0, -1, false), "\n")
local shows_keep   = txt:find("keep.txt", 1, true) ~= nil
local shows_junk   = txt:find("junk.ignored", 1, true) ~= nil
print("AF=" .. vim.fn.fnamemodify(AF, ":h:t") .. "/" .. vim.fn.fnamemodify(AF, ":t"))
print("  tracked file visible : " .. tostring(shows_keep))
print("  IGNORED file hidden  : " .. tostring(not shows_junk))
print(("  VERDICT: hide_gitignored %s"):format(
  (shows_keep and not shows_junk) and "WORKS" or "BROKEN"))
vim.fn.delete(sb, "rf")
