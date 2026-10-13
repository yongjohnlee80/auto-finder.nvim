-- tests/todos-cutover.lua — the todos panel writes nothing under a .todo-list
-- (ADR 1791532020 §3 step 3). Every change goes through auto-core.todo (v0.3.4,
-- the forwarding shim) to a REAL AutoDoc daemon of this suite's own.
--
-- Each action runs under a write spy: vim.uv.fs_unlink / fs_rename / fs_open
-- (for writing) / fs_mkdir, vim.fn.mkdir / writefile / delete, io.open (for
-- writing), os.rename / os.remove and auto-core.fs.atomic.write. A call whose
-- path is under the store's tree fails the cell: the daemon writes in its own
-- process, so the panel's Lua must make none.
--
-- nvim --headless -u NONE -l tests/todos-cutover.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local family = vim.fn.fnamemodify(root, ":h:h")
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(family .. "/auto-core.nvim/main")
local sandbox = dofile(root .. "/tests/_sandbox.lua")("todos-cutover")
local passed, failed = 0, 0
local function check(name, condition, detail)
  if condition then passed = passed + 1 else failed = failed + 1 end
  -- A headless log line has no trailing newline: start on a line of our own,
  -- or run-all's "^  FAIL" count would miss a failure printed after one.
  local line = (condition and "  PASS  " or "  FAIL  ") .. name
  if not condition and detail ~= nil then line = line .. "  — " .. tostring(detail) end
  io.stdout:write("\n", (line:gsub("[\r\n]+", " ")), "\n")
end
local function section(t) io.stdout:write("\n", t, "\n") end
local function exists(p) return vim.uv.fs_stat(p) ~= nil end

local autodoc_ok, autodoc_why = dofile(root .. "/tests/_autodoc.lua")(sandbox, "cutover")
check("AutoDoc is set up", autodoc_ok, autodoc_why)

local todo = require("auto-core.todo")
local daemon = require("auto-core.todo.daemon")
local view = require("auto-finder.views.todos")

local proj = vim.uv.fs_realpath(sandbox) .. "/proj"
vim.fn.mkdir(proj, "p")
require("auto-core.git.worktree").set_workspace_root(proj)
local store = proj .. "/.todo-list"

-- ── the spies ──────────────────────────────────────────────────
local sent = {}  -- daemon verbs, in order
daemon._set_transport(function(method, params, cb)
  sent[#sent + 1] = method
  daemon._real_request(method, params, cb)
end)
local function sent_count(verb)
  local n = 0
  for _, m in ipairs(sent) do if m == verb then n = n + 1 end end
  return n
end

local writes = {} -- direct writes under the sandbox's projects, with the call
local function under(p)
  if type(p) ~= "string" then return false end
  p = vim.fn.fnamemodify(p, ":p")
  return p:sub(1, #proj) == proj or p:sub(1, #sandbox) == sandbox and p:find("/moved", 1, true) ~= nil
end
local spied = {}
local function spy(tbl, key, name, path_of, is_write)
  local orig = tbl[key]
  spied[#spied + 1] = { tbl, key, orig }
  tbl[key] = function(...)
    local p = path_of(...)
    if under(p) and (not is_write or is_write(...)) then writes[#writes + 1] = name .. " " .. tostring(p) end
    return orig(...)
  end
end
local function first(a) return a end
local function second(_, b) return b end
local function install_spies()
  writes = {}
  spy(vim.uv, "fs_unlink", "uv.fs_unlink", first)
  spy(vim.uv, "fs_rename", "uv.fs_rename", first)
  spy(vim.uv, "fs_mkdir", "uv.fs_mkdir", first)
  spy(vim.uv, "fs_rmdir", "uv.fs_rmdir", first)
  spy(vim.uv, "fs_open", "uv.fs_open(w)", first, function(_, flags)
    return type(flags) == "string" and flags:find("[wa+]") ~= nil
  end)
  spy(vim.fn, "mkdir", "fn.mkdir", first)
  spy(vim.fn, "writefile", "fn.writefile", second)
  spy(vim.fn, "delete", "fn.delete", first)
  spy(io, "open", "io.open(w)", first, function(_, mode)
    return type(mode) == "string" and mode:find("[wa+]") ~= nil
  end)
  spy(os, "rename", "os.rename", first)
  spy(os, "remove", "os.remove", first)
  local atomic = require("auto-core.fs.atomic")
  spy(atomic, "write", "fs.atomic.write", first)
end
local function remove_spies()
  for i = #spied, 1, -1 do
    local s = spied[i]
    s[1][s[2]] = s[3]
  end
  spied = {}
end

-- ── the panel ──────────────────────────────────────────────────
local errors, notes = {}, {}
local log = require("auto-finder.log")
local real_error = log.error
log.error = function(component, msg, ...)
  errors[#errors + 1] = tostring(msg)
  return real_error(component, msg, ...)
end

local b = view.get_buffer(0)
vim.api.nvim_win_set_buf(0, b)
local function loaded()
  return vim.wait(5000, function() return not view._loading end, 10)
end
local function reload()
  view.on_focus(0, b)
  return loaded()
end
local function press(key)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do
    if map.lhs == key then map.callback(); return true end
  end
  error("missing keymap " .. key)
end
local function cursor_on(pred)
  for _, row in ipairs(view._rows or {}) do
    if pred(row) then
      vim.api.nvim_win_set_cursor(0, { row.lnum, 0 })
      return row
    end
  end
end
local confirm, input = vim.fn.confirm, vim.ui.input
local function answers(confirm_choice, input_text)
  vim.fn.confirm = function() return confirm_choice end
  vim.ui.input = function(_, cb) cb(input_text) end
end
local function restore_ui() vim.fn.confirm, vim.ui.input = confirm, input end

-- ── fixture ────────────────────────────────────────────────────
local keep = assert(todo.add({ title = "Keep me" }))
local broken = store .. "/open/2026-10-01-broken.md"
local f = assert(io.open(broken, "w")); f:write("---\nid: [unclosed\n---\n# Broken\n"); f:close()
local auto_file = store .. "/open/2026-10-01-automated.md"
local t = vim.deepcopy(assert(todo.get(keep)))
local text = assert(io.open(t.file_path, "r")):read("*a")
f = assert(io.open(auto_file, "w"))
f:write((text:gsub("\nid: [^\n]+\n", "\nid: 2026-10-01-automated\n", 1)
  :gsub("\nstatus: open\n", "\nstatus: open\ncondition:\n  - \"0 0 * * *\"\n", 1)))
f:close()
check("the panel loads the store", reload())

-- ─────────────────────────────────────────────────────────────
section("d on a malformed row: AutoDoc deletes it (todos.remove_malformed)")
do
  check("the malformed row is listed", cursor_on(function(r)
    return r.kind == "malformed-task" and r.filepath == broken end) ~= nil)
  answers(1)
  sent, errors = {}, {}
  install_spies()
  press("d")
  remove_spies()
  restore_ui()
  check("todos.remove_malformed was sent", sent_count("todos.remove_malformed") == 1, vim.inspect(sent))
  check("the file is gone", not exists(broken))
  check("the panel wrote nothing under the store", #writes == 0, vim.inspect(writes))
end

do
  reload()
  check("the automation file is listed as malformed", cursor_on(function(r)
    return r.kind == "malformed-task" and r.filepath == auto_file end) ~= nil)
  answers(1)
  sent, errors = {}, {}
  install_spies()
  press("d")
  remove_spies()
  restore_ui()
  check("AutoDoc refuses to delete a file using automation, and the panel says so",
    exists(auto_file) and #errors > 0, vim.inspect(errors))
  check("… and the panel did not delete it itself", #writes == 0, vim.inspect(writes))
end

do
  -- An auto-core before the cutover has no remove_malformed: the panel says
  -- "update auto-core" and never falls back to the unlink.
  local again = store .. "/open/2026-10-01-broken-again.md"
  f = assert(io.open(again, "w")); f:write("---\nid: [\n---\n"); f:close()
  reload()
  cursor_on(function(r) return r.kind == "malformed-task" and r.filepath == again end)
  local real = todo.remove_malformed
  todo.remove_malformed = nil
  answers(1)
  errors = {}
  install_spies()
  press("d")
  remove_spies()
  restore_ui()
  todo.remove_malformed = real
  check("an older auto-core: \"update auto-core\"", errors[1] and errors[1]:find("update auto-core", 1, true),
    vim.inspect(errors))
  check("… and the file is untouched, nothing written", exists(again) and #writes == 0, vim.inspect(writes))
  vim.uv.fs_unlink(again)
end

-- ─────────────────────────────────────────────────────────────
section("M: AutoDoc moves the store (todos.move_store); the panel creates no directory")
do
  reload()
  local moved = vim.uv.fs_realpath(sandbox) .. "/moved"
  answers(1, moved)
  sent, errors = {}, {}
  install_spies()
  press("M")
  remove_spies()
  restore_ui()
  check("todos.move_store was sent", sent_count("todos.move_store") == 1, vim.inspect(sent))
  check("the store is at the new path", exists(moved .. "/open") and not exists(store), vim.inspect(errors))
  check("get_todo_dir follows it", todo.get_todo_dir() == moved, todo.get_todo_dir())
  check("the task moved with it", todo.get(keep) ~= nil)
  check("the panel renamed and created nothing itself", #writes == 0, vim.inspect(writes))
  local r = daemon.normalize(select(1, (function()
    local done, res = false, nil
    require("autodoc.session").call("todos.resolve", { { root = proj } }, function(x) res, done = x, true end)
    vim.wait(5000, function() return done end, 10)
    return res
  end)()))
  check("… and the store is still claimed (its claim moved with it)", r and r.claimed == true, vim.inspect(r))
end

do
  reload()
  local current = todo.get_todo_dir()
  local nowhere = vim.uv.fs_realpath(sandbox) .. "/no-such-parent/store"
  answers(1, nowhere)
  sent, errors = {}, {}
  install_spies()
  press("M")
  remove_spies()
  restore_ui()
  check("a missing parent is refused, with the reason", errors[1] and errors[1]:find("parent directory", 1, true),
    vim.inspect(errors))
  check("… nothing was sent", sent_count("todos.move_store") == 0 and sent_count("todos.set_dir") == 0,
    vim.inspect(sent))
  check("… nothing was created", not exists(vim.fn.fnamemodify(nowhere, ":h")) and #writes == 0,
    vim.inspect(writes))
  check("… and the store did not move", todo.get_todo_dir() == current)
end

do
  local other = vim.uv.fs_realpath(sandbox) .. "/existing-dir"
  vim.fn.mkdir(other, "p")
  local back = todo.get_todo_dir()
  answers(1, other)
  sent, errors = {}, {}
  install_spies()
  press("M")
  remove_spies()
  restore_ui()
  check("switch only (the target exists): todos.set_dir, no move", sent_count("todos.set_dir") >= 1
    and sent_count("todos.move_store") == 0, vim.inspect(sent))
  check("… the override points there", todo.get_todo_dir() == other, todo.get_todo_dir())
  check("… nothing written by the panel", #writes == 0, vim.inspect(writes))
  todo.set_todo_dir(back)
end

do
  reload()
  -- neither the current store nor the target exists
  local fresh = proj .. "-fresh"
  vim.fn.mkdir(fresh, "p")
  require("auto-core.git.worktree").set_workspace_root(fresh)
  reload()
  local target = vim.uv.fs_realpath(sandbox) .. "/never-made"
  answers(1, target)
  sent, errors = {}, {}
  install_spies()
  press("M")
  remove_spies()
  restore_ui()
  check("neither directory exists: refused, the panel creates none",
    errors[1] and errors[1]:find("neither", 1, true) and not exists(target) and #writes == 0,
    vim.inspect({ errors, writes }))
  require("auto-core.git.worktree").set_workspace_root(proj)
end

do
  reload()
  local real = todo.move_store
  todo.move_store = nil
  errors = {}
  answers(1, vim.uv.fs_realpath(sandbox) .. "/would-move")
  install_spies()
  press("M")
  remove_spies()
  restore_ui()
  todo.move_store = real
  check("an older auto-core: M says \"update auto-core\" and moves nothing",
    errors[1] and errors[1]:find("update auto-core", 1, true) and #writes == 0, vim.inspect(errors))
end

-- ─────────────────────────────────────────────────────────────
section("s and the status event: the file is exactly what AutoDoc wrote")
do
  reload()
  cursor_on(function(r) return r.kind == "task" and r.task and r.task.id == keep end)
  local select = vim.ui.select
  vim.ui.select = function(items, _, cb)
    local has_automated = false
    for _, i in ipairs(items) do if i == "automated" then has_automated = true end end
    check("the status choices offer no automated", not has_automated, vim.inspect(items))
    cb("deferred")
  end
  install_spies()
  press("s")
  -- the removed hook: a status:changed to automated used to make the panel
  -- write defaults into the file
  require("auto-core.events").publish("core.todo.status:changed", { id = keep, from = "open", to = "automated" })
  vim.wait(200, function() return false end, 10)
  remove_spies()
  vim.ui.select = select
  -- (nil when a direct write broke the file: the cells fail, not the suite)
  local cur = todo.get(keep)
  local fh = cur and io.open(cur.file_path, "r")
  local bytes = fh and fh:read("*a")
  if fh then fh:close() end
  check("the task is deferred, and AutoDoc still reads it", cur and cur.status == "deferred", cur and cur.status)
  check("the panel wrote nothing (no scaffold, no default hook)", #writes == 0, vim.inspect(writes))
  check("the file's bytes are AutoDoc's (its rev)", bytes and vim.fn.sha256(bytes) == cur.rev)
end

view.on_close()
io.stdout:write(string.format("\n%d passed, %d failed\n", passed, failed))
io.stdout:flush()
