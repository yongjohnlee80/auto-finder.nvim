-- tests/bench/files-panel.lua — the files slot's cost, before and after ADR-0200 (§5 item 11).
--
-- One driver for both implementations. It counts what the pane costs at the libuv boundary, so the retired
-- neo-tree fork and the rebuilt slot are measured by the same instrument:
--   dir_opens   uv.fs_scandir + uv.fs_opendir calls          (directory reads started)
--   entries     uv.fs_scandir_next names + uv.fs_readdir entries (directory entries examined)
--   watches     live fs_event handles at the end of the scenario (uv.walk)
--   git         git subprocesses spawned (vim.system / vim.fn.jobstart / vim.fn.system* / uv.spawn)
--   ms          wall time from the scenario's first action until the counters stop moving
-- Each scenario settles (no counter moves for QUIET_MS, capped at CAP_MS) before the next starts.
--
-- Run on VM43 (tests/bench/run.sh stages both trees and runs this under each):
--   AF_BENCH_PLUGIN=<auto-finder tree> AF_BENCH_AUTO_CORE=<auto-core tree> AF_BENCH_MODE=before|after \
--   AF_BENCH_TREE=<fixture root> AF_BENCH_OUT=<json> nvim --headless -u NONE -l tests/bench/files-panel.lua

local uv = vim.uv
local PLUGIN, AUTO_CORE = assert(vim.env.AF_BENCH_PLUGIN), assert(vim.env.AF_BENCH_AUTO_CORE)
local MODE, TREE, OUT = assert(vim.env.AF_BENCH_MODE), assert(vim.env.AF_BENCH_TREE), assert(vim.env.AF_BENCH_OUT)
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
local QUIET_MS, CAP_MS = 500, 15000

-- ── sandbox (never the developer's environment) ────────────────────────────────────────────────────
local SANDBOX = vim.fn.tempname() .. "-af-bench"
for _, k in ipairs({ "CONFIG", "STATE", "CACHE" }) do
  vim.fn.mkdir(SANDBOX .. "/" .. k:lower(), "p")
  vim.env["XDG_" .. k .. "_HOME"] = SANDBOX .. "/" .. k:lower()
end

-- ── instruments, installed before any plugin loads ──────────────────────────────────────────────────
local C = { dir_opens = 0, entries = 0, git = 0, fs_event_created = 0, git_cmds = {} }
local function wrap(tbl, name, fn) local real = tbl[name]; tbl[name] = function(...) return fn(real, ...) end end
wrap(uv, "fs_scandir", function(real, ...) C.dir_opens = C.dir_opens + 1; return real(...) end)
wrap(uv, "fs_opendir", function(real, ...) C.dir_opens = C.dir_opens + 1; return real(...) end)
wrap(uv, "fs_scandir_next", function(real, ...)
  local name, t = real(...)
  if name then C.entries = C.entries + 1 end
  return name, t
end)
wrap(uv, "fs_readdir", function(real, dir, cb)
  if cb then
    return real(dir, function(err, ents)
      if ents then C.entries = C.entries + #ents end
      return cb(err, ents)
    end)
  end
  local ents = real(dir)
  if type(ents) == "table" then C.entries = C.entries + #ents end
  return ents
end)
wrap(uv, "new_fs_event", function(real, ...) C.fs_event_created = C.fs_event_created + 1; return real(...) end)
local function is_git(cmd)
  local yes, sub
  if type(cmd) == "table" then
    yes = cmd[1] == "git"
    for i = 2, #cmd do -- the subcommand: the first bare word that is not -C's path
      local a = cmd[i]
      if type(a) == "string" and not a:match("^%-") and cmd[i - 1] ~= "-C" then sub = a; break end
    end
  else
    yes = type(cmd) == "string" and cmd:match("^%s*git%s") ~= nil
    sub = yes and cmd:match("^%s*git%s+([%w-]+)") or nil
  end
  if yes then C.git_cmds[sub or "?"] = (C.git_cmds[sub or "?"] or 0) + 1 end
  return yes
end
-- vim.system spawns through uv.spawn: count at the outermost entry only
local depth = 0
local function counted(real, cmd, ...)
  if depth == 0 and is_git(cmd) then C.git = C.git + 1 end
  depth = depth + 1
  local r = { pcall(real, cmd, ...) }
  depth = depth - 1
  if not r[1] then error(r[2], 0) end
  return unpack(r, 2, table.maxn(r))
end
wrap(vim, "system", counted)
wrap(uv, "spawn", function(real, file, opts, ...)
  if depth == 0 and file == "git" then
    C.git = C.git + 1
    is_git(vim.list_extend({ "git" }, (opts and opts.args) or {}))
  end
  return real(file, opts, ...)
end)
for _, f in ipairs({ "jobstart", "system", "systemlist" }) do
  local real = vim.fn[f]
  rawset(vim.fn, f, function(cmd, ...) return counted(real, cmd, ...) end)
end
local function live_watches()
  local n = 0
  uv.walk(function(h) if h:get_type() == "fs_event" and not h:is_closing() then n = n + 1 end end)
  return n
end

-- ── runtimepath ─────────────────────────────────────────────────────────────────────────────────────
for _, p in ipairs({
  LAZY .. "/plenary.nvim", LAZY .. "/nui.nvim", -- only the retired fork loads these
  LAZY .. "/worktree.nvim",
  AUTO_CORE,
  PLUGIN,
}) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end
vim.o.columns, vim.o.lines, vim.o.swapfile, vim.o.hidden = 200, 60, false, true
vim.cmd.cd(TREE)

-- autovim's own spec, before and after (lua/plugins/auto-finder.lua)
local OPTS = {
  width = { default = 38, min = 25, max = 100 },
  default_section = 1,
  sections = { "config", "files" },
}
if MODE == "before" then
  OPTS.files = { follow = true }
  OPTS.neo_tree = {
    window = { auto_expand_width = true },
    filesystem = {
      hijack_netrw_behavior = "disabled",
      filtered_items = { visible = true, hide_dotfiles = false, hide_gitignored = false,
        never_show = { ".git", "node_modules" }, ignore_files = {} },
      check_gitignore_in_search = false,
    },
  }
else
  OPTS.files = { follow = true, never_show = { ".git", "node_modules" }, auto_expand_width = true }
end

-- ── scenario runner ─────────────────────────────────────────────────────────────────────────────────
local results = { mode = MODE, tree = TREE, scenarios = {} }
local function snapshot() return { C.dir_opens, C.entries, C.git, C.fs_event_created } end
local function settle(t0)
  local last, last_change = snapshot(), uv.now()
  local stop = uv.now() + CAP_MS
  while uv.now() < stop do
    vim.wait(50)
    local s = snapshot()
    if not vim.deep_equal(s, last) then last, last_change = s, uv.now() end
    if uv.now() - last_change >= QUIET_MS then break end
  end
  return last_change - t0
end
local function scenario(name, fn)
  vim.wait(QUIET_MS)
  local before = vim.deepcopy(C)
  local t0 = uv.now()
  C.git_cmds = {}
  local okr, err = pcall(fn)
  local ms = settle(t0)
  local r = {
    dir_opens = C.dir_opens - before.dir_opens,
    entries = C.entries - before.entries,
    git = C.git - before.git,
    watches_created = C.fs_event_created - before.fs_event_created,
    watches = live_watches(),
    git_cmds = vim.deepcopy(C.git_cmds),
    ms = ms,
    error = (not okr) and tostring(err) or nil,
  }
  results.scenarios[#results.scenarios + 1] = { name = name, r = r }
  print(("%-28s opens=%-6d entries=%-8d git=%-4d watches=%-6d (+%d) %6d ms %s%s"):format(name, r.dir_opens,
    r.entries, r.git, r.watches, r.watches_created, r.ms, vim.inspect(r.git_cmds, { newline = "", indent = "" }),
    r.error and ("  ERROR " .. r.error) or ""))
end

local af = require("auto-finder")
local function editor_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if w ~= af.state.panel_winid and vim.api.nvim_win_get_config(w).relative == "" then return w end
  end
end
local DEEP = TREE .. "/repo1/d1/d1_1/d1_1_1/f1.txt" -- three directory levels below a repo
local WRITE = TREE .. "/repo1/d1/d1_1/d1_1_1/f2.txt"
local BULK = TREE .. "/repo2/d3/d3_4"               -- never expanded

-- setup is measured too: the fork armed its recursive cwd watch (a synchronous walk of every directory) here
scenario("setup", function() af.setup(OPTS) end)
scenario("mount", function() af.open(true); af.focus(1) end)
scenario("follow a deep file", function()
  vim.api.nvim_set_current_win(editor_win())
  vim.cmd("edit " .. vim.fn.fnameescape(DEEP))
end)
scenario("toggle x20", function()
  for _ = 1, 20 do af.close(); vim.wait(40); af.open(true); af.focus(1); vim.wait(40) end
end)
scenario(":w x20", function()
  vim.api.nvim_set_current_win(editor_win())
  vim.cmd("edit " .. vim.fn.fnameescape(WRITE))
  for i = 1, 20 do
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "write " .. i })
    vim.cmd("silent write")
    vim.wait(50)
  end
end)
scenario("5000 creates, collapsed dir", function()
  for i = 1, 5000 do
    local fd = uv.fs_open(BULK .. "/bulk" .. i .. ".txt", "w", 420)
    if fd then uv.fs_close(fd) end
  end
end)
scenario("git add + commit", function()
  -- the fixture's own git (not counted: it runs before the counters are read back)
  local g0 = C.git
  vim.system({ "git", "-C", TREE .. "/repo1", "add", "-A" }):wait()
  vim.system({ "git", "-C", TREE .. "/repo1", "commit", "-qm", "bench" }):wait()
  C.git = g0
end)
scenario("hidden: 200 writes", function()
  af.close()
  for i = 1, 200 do vim.fn.writefile({ "x" }, TREE .. "/repo1/d1/d1_1/d1_1_1/hidden" .. i .. ".txt") end
end)

local f = assert(io.open(OUT, "w"))
f:write(vim.json.encode(results))
f:close()
vim.fn.delete(SANDBOX, "rf")
os.exit(0)
