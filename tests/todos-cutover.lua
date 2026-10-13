-- tests/todos-cutover.lua — the todos panel calls AutoDoc's daemon itself and
-- writes nothing under a .todo-list (ADR 1791532020 §3 steps 3 and 4).
--
-- Every change goes through autodoc.nvim's todos client to a REAL AutoDoc
-- daemon of this suite's own; auto-core only says where the store is
-- (auto-core.todo.where). The panel never loads `auto-core.todo` itself, which
-- auto-core v0.4.1 removes.
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

local todo = dofile(root .. "/tests/_todos.lua")       -- the fixtures' client
local door = require("auto-finder.views.todos.store")  -- the panel's own door
local view = require("auto-finder.views.todos")

local proj = vim.uv.fs_realpath(sandbox) .. "/proj"
vim.fn.mkdir(proj, "p")
require("auto-core.git.worktree").set_workspace_root(proj)

-- ── the spies ──────────────────────────────────────────────────
-- Every daemon verb, the panel's and auto-core's store resolution alike, goes
-- through autodoc.todos.call (where.lua's door looks the field up per call).
local ad_todos = require("autodoc.todos")
local real_call = ad_todos.call
local sent, pending = {}, 0
ad_todos.call = function(verb, params, cb)
  sent[#sent + 1] = "todos." .. verb
  pending = pending + 1
  real_call(verb, params, function(r, e)
    pending = pending - 1
    cb(r, e)
  end)
end
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
local errors = {}
local log = require("auto-finder.log")
local real_error = log.error
log.error = function(component, msg, ...)
  errors[#errors + 1] = tostring(msg)
  return real_error(component, msg, ...)
end

local b = view.get_buffer(0)
vim.api.nvim_win_set_buf(0, b)
---settle waits until no daemon call is in flight and the panel is not loading,
---twice over a short gap: an answer schedules the panel's reload, and an event
---schedules another.
local function settle()
  local function idle() return pending == 0 and not view._loading end
  local ok1 = vim.wait(5000, idle, 10)
  vim.wait(30, function() return false end, 10)
  return ok1 and vim.wait(5000, idle, 10)
end
local function reload()
  view.on_focus(0, b)
  return settle()
end
local function text() return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n") end
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
-- An action under the write spy: press, wait for the daemon, then unspy.
local function act(key)
  install_spies()
  press(key)
  settle()
  remove_spies()
end
local confirm, input = vim.fn.confirm, vim.ui.input
local function answers(confirm_choice, input_text)
  vim.fn.confirm = function() return confirm_choice end
  vim.ui.input = function(_, cb) cb(input_text) end
end
local function restore_ui() vim.fn.confirm, vim.ui.input = confirm, input end

-- ── fixture ────────────────────────────────────────────────────
local keep = assert(todo.add({ title = "Keep me" }))
local store = todo.dir()
local broken = store .. "/open/2026-10-01-broken.md"
local f = assert(io.open(broken, "w")); f:write("---\nid: [unclosed\n---\n# Broken\n"); f:close()
local auto_file = store .. "/open/2026-10-01-automated.md"
local t = vim.deepcopy(assert(todo.get(keep)))
local bytes0 = assert(io.open(t.file_path, "r")):read("*a")
f = assert(io.open(auto_file, "w"))
f:write((bytes0:gsub("\nid: [^\n]+\n", "\nid: 2026-10-01-automated\n", 1)
  :gsub("\nstatus: open\n", "\nstatus: open\ncondition:\n  - \"0 0 * * *\"\n", 1)))
f:close()
check("the panel loads the store", reload())
check("the panel lists the task", text():find("Keep me", 1, true) ~= nil, text())

-- ─────────────────────────────────────────────────────────────
section("the panel is a direct client: it never loads auto-core.todo")
do
  check("auto-core.todo was never required (auto-core v0.4.1 removes it)",
    package.loaded["auto-core.todo"] == nil)
  check("the load went to the daemon (todos.list)", sent_count("todos.list") >= 1, vim.inspect(sent))
end

-- ─────────────────────────────────────────────────────────────
section("d on a malformed row: AutoDoc deletes it (todos.remove_malformed)")
do
  check("the malformed row is listed", cursor_on(function(r)
    return r.kind == "malformed-task" and r.filepath == broken end) ~= nil)
  answers(1)
  sent, errors = {}, {}
  act("d")
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
  act("d")
  restore_ui()
  check("AutoDoc refuses to delete a file using automation, and the panel says so",
    exists(auto_file) and #errors > 0, vim.inspect(errors))
  check("… and the panel did not delete it itself", #writes == 0, vim.inspect(writes))
end

do
  -- An auto-core before the cutover has no store resolution (where): the
  -- panel says "update auto-core", offers no row to act on, and never falls
  -- back to reading or unlinking the files itself.
  local again = store .. "/open/2026-10-01-broken-again.md"
  f = assert(io.open(again, "w")); f:write("---\nid: [\n---\n"); f:close()
  local real_where = package.loaded["auto-core.todo.where"]
  package.loaded["auto-core.todo.where"] = {}
  sent = {}
  install_spies()
  reload()
  answers(1)
  press("d")
  settle()
  restore_ui()
  remove_spies()
  package.loaded["auto-core.todo.where"] = real_where
  check("an older auto-core: \"update auto-core\"", text():find("update auto-core", 1, true) ~= nil, text())
  -- The floor is found by feature (auto-core.todo.where), not by a version
  -- comparison; what must stay right is the version the message names: where
  -- ships in auto-core v0.4.0 (ADR 1791532020 D4, amended).
  check("… and it names the release that carries the store resolution, auto-core v0.4.0",
    text():find("auto-core v0.4.0 or later", 1, true) ~= nil, text())
  check("… with no rows, so d acts on nothing", #(view._rows or {}) == 0)
  check("… and the file is untouched, nothing sent or written",
    exists(again) and #sent == 0 and #writes == 0, vim.inspect({ sent, writes }))
  vim.uv.fs_unlink(again)
end

-- ─────────────────────────────────────────────────────────────
section("without AutoDoc the panel says \"AutoDoc required\" (no Lua fallback)")
do
  local real_mod = package.loaded["autodoc.todos"]
  package.loaded["autodoc.todos"] = "unavailable"
  sent, errors = {}, {}
  install_spies()
  reload()
  remove_spies()
  check("the panel shows AutoDoc required", text():find("AutoDoc required", 1, true) ~= nil, text())
  check("… with no rows to act on", #(view._rows or {}) == 0)
  check("… asks nothing and writes nothing", #sent == 0 and #writes == 0, vim.inspect({ sent, writes }))
  package.loaded["autodoc.todos"] = real_mod
  check("R brings the panel back once AutoDoc is there", (function()
    press("R")
    settle()
    return text():find("Keep me", 1, true) ~= nil
  end)(), text())
end

-- ─────────────────────────────────────────────────────────────
section("a stale row: a write at an old rev is refused (todos.stale) and the panel reloads")
do
  reload()
  local row = cursor_on(function(r) return r.kind == "task" and r.task and r.task.id == keep end)
  check("the task row is under the cursor", row ~= nil)
  -- another client changes the task after the panel read it (an agent's
  -- todos.update): the row's rev is now old
  local changed = todo.update(keep, { priority = "high" })
  check("another client changed the task", changed ~= nil and changed.rev ~= (row and row.task.rev))
  local select = vim.ui.select
  vim.ui.select = function(_, _, cb) cb("deferred") end
  sent, errors = {}, {}
  -- the panel has not reloaded yet (the change's event is only scheduled),
  -- so the row under the cursor still carries the old rev
  act("s")
  local n_status = sent_count("todos.status")
  vim.ui.select = select
  local cur = todo.get(keep)
  check("the stale write was refused: the task is still open", cur and cur.status == "open",
    cur and cur.status)
  check("… the panel said the task changed, and reloaded", errors[1]
    and errors[1]:find("changed since the panel read it", 1, true), vim.inspect(errors))
  check("… and the other client's change survived", cur and cur.priority == "high")
  check("… the panel sent the status once, at the old rev (no retry)",
    n_status == 1, vim.inspect(sent))
end

-- ─────────────────────────────────────────────────────────────
section("M: AutoDoc moves the store (todos.move_store); the panel creates no directory")
do
  reload()
  local moved = vim.uv.fs_realpath(sandbox) .. "/moved"
  answers(1, moved)
  sent, errors = {}, {}
  act("M")
  restore_ui()
  check("todos.move_store was sent", sent_count("todos.move_store") == 1, vim.inspect(sent))
  check("the store is at the new path", exists(moved .. "/open") and not exists(store), vim.inspect(errors))
  check("the panel's store follows it", door.dir() == moved, door.dir())
  check("the task moved with it", todo.get(keep) ~= nil)
  check("the panel renamed and created nothing itself", #writes == 0, vim.inspect(writes))
  local r = require("auto-core.todo.daemon").normalize(select(1, (function()
    local done, res = false, nil
    require("autodoc.session").call("todos.resolve", { { root = proj } }, function(x) res, done = x, true end)
    vim.wait(5000, function() return done end, 10)
    return res
  end)()))
  check("… and the store is still claimed (its claim moved with it)", r and r.claimed == true, vim.inspect(r))
end

do
  reload()
  local current = door.dir()
  local nowhere = vim.uv.fs_realpath(sandbox) .. "/no-such-parent/store"
  answers(1, nowhere)
  sent, errors = {}, {}
  act("M")
  restore_ui()
  check("a missing parent is refused, with the reason", errors[1] and errors[1]:find("parent directory", 1, true),
    vim.inspect(errors))
  check("… nothing was sent", sent_count("todos.move_store") == 0 and sent_count("todos.set_dir") == 0,
    vim.inspect(sent))
  check("… nothing was created", not exists(vim.fn.fnamemodify(nowhere, ":h")) and #writes == 0,
    vim.inspect(writes))
  check("… and the store did not move", door.dir() == current)
end

do
  local other = vim.uv.fs_realpath(sandbox) .. "/existing-dir"
  vim.fn.mkdir(other, "p")
  local back = door.dir()
  answers(1, other)
  sent, errors = {}, {}
  act("M")
  restore_ui()
  check("switch only (the target exists): todos.set_dir, no move", sent_count("todos.set_dir") >= 1
    and sent_count("todos.move_store") == 0, vim.inspect(sent))
  check("… the override points there", door.dir() == other, door.dir())
  check("… nothing written by the panel", #writes == 0, vim.inspect(writes))
  local done = false
  door.set_dir(back, function() done = true end)
  vim.wait(5000, function() return done end, 10)
  check("… and back again", door.dir() == back, door.dir())
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
  act("M")
  restore_ui()
  check("neither directory exists: refused, the panel creates none",
    errors[1] and errors[1]:find("neither", 1, true) and not exists(target) and #writes == 0,
    vim.inspect({ errors, writes }))
  require("auto-core.git.worktree").set_workspace_root(proj)
end

do
  reload()
  local real_where = package.loaded["auto-core.todo.where"]
  package.loaded["auto-core.todo.where"] = {}
  errors = {}
  answers(1, vim.uv.fs_realpath(sandbox) .. "/would-move")
  act("M")
  restore_ui()
  package.loaded["auto-core.todo.where"] = real_where
  check("an older auto-core: M says \"update auto-core\" and moves nothing",
    errors[1] and errors[1]:find("update auto-core", 1, true) and #writes == 0, vim.inspect(errors))
  check("… naming auto-core v0.4.0", errors[1] and errors[1]:find("auto-core v0.4.0 or later", 1, true),
    vim.inspect(errors))
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
  sent = {}
  install_spies()
  press("s")
  -- the removed hook: a status:changed to automated used to make the panel
  -- write defaults into the file
  require("auto-core.events").publish("core.todo.status:changed", { id = keep, from = "open", to = "automated" })
  settle()
  remove_spies()
  vim.ui.select = select
  local n_status, n_get = sent_count("todos.status"), sent_count("todos.get")
  -- (nil when a direct write broke the file: the cells fail, not the suite)
  local cur = todo.get(keep)
  local fh = cur and io.open(cur.file_path, "r")
  local bytes = fh and fh:read("*a")
  if fh then fh:close() end
  check("the task is deferred, and AutoDoc still reads it", cur and cur.status == "deferred", cur and cur.status)
  check("… in ONE todos.status, at the row's rev (no read-then-write)", n_status == 1 and n_get == 0,
    vim.inspect(sent))
  check("the panel wrote nothing (no scaffold, no default hook)", #writes == 0, vim.inspect(writes))
  check("the file's bytes are AutoDoc's (its rev)", bytes and vim.fn.sha256(bytes) == cur.rev)
  check("the panel shows it under Deferred", text():find("Deferred %(%d+%).-Keep me") ~= nil, text())
end

-- ─────────────────────────────────────────────────────────────
section("open buffers follow a task the panel moved")
do
  local cur = assert(todo.get(keep))
  vim.cmd("edit " .. vim.fn.fnameescape(cur.file_path))
  local tbuf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_buf(0, b)
  reload()
  cursor_on(function(r) return r.kind == "task" and r.task and r.task.id == keep end)
  local select = vim.ui.select
  vim.ui.select = function(_, _, cb) cb("open") end
  act("s")
  vim.ui.select = select
  local after = assert(todo.get(keep))
  check("the task moved back to open", after.status == "open" and after.file_path ~= cur.file_path)
  check("the buffer on it now names its new path (auto-core's buffers)",
    vim.api.nvim_buf_is_valid(tbuf) and vim.api.nvim_buf_get_name(tbuf) == after.file_path,
    vim.api.nvim_buf_is_valid(tbuf) and vim.api.nvim_buf_get_name(tbuf))
  pcall(vim.api.nvim_buf_delete, tbuf, { force = true })
end

check("auto-core.todo was still never required", package.loaded["auto-core.todo"] == nil)
view.on_close()
ad_todos.call = real_call
io.stdout:write(string.format("\n%d passed, %d failed\n", passed, failed))
io.stdout:flush()
