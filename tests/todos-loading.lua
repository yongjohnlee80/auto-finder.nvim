-- nvim --headless -u NONE -l tests/todos-loading.lua
-- AF_TODOS_BASELINE=1 tests the committed renderer with the same assertions.
--
-- The todos panel loads from AutoDoc's daemon itself (ADR 1791532020 §3 step
-- 4), through its door (views/todos/store.lua): the active buckets first, then
-- the archive month by month, never synchronously, and never from a store the
-- project has switched away from.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local family = vim.fn.fnamemodify(root, ":h:h")
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(family .. "/auto-core.nvim/main")
local sandbox = dofile(root .. "/tests/_sandbox.lua")("todos-loading")
local passed, failed = 0, 0
local function check(name, condition)
  if condition then passed = passed + 1 else failed = failed + 1 end
  io.stdout:write((condition and "  PASS  " or "  FAIL  ") .. name .. "\n")
end
-- A daemon of this suite's own.
local autodoc_ok, autodoc_why = dofile(root .. "/tests/_autodoc.lua")(sandbox, "loading")
check("AutoDoc is set up (" .. tostring(autodoc_why or "ok") .. ")", autodoc_ok)
local todo = dofile(root .. "/tests/_todos.lua")
local store = require("auto-finder.views.todos.store")

---set_dir points the project at a store directory and waits for it.
local function set_dir(d)
  local done = false
  store.set_dir(d or "", function() done = true end)
  vim.wait(5000, function() return done end, 10)
end

local dir = vim.uv.fs_realpath(sandbox) .. "/tasks"
vim.fn.mkdir(dir, "p") -- set_dir needs an existing directory
set_dir(dir)
local active = assert(todo.add({ title = "Active task" }))
local archived = assert(todo.add({ title = "Archived task" }))
assert(todo.status(archived, "archived"))
vim.fn.writefile({ "not frontmatter" }, dir .. "/open/broken.md")
local view = require("auto-finder.views.todos")
if vim.env.AF_TODOS_BASELINE == "1" then
  local baseline = vim.system({ "git", "-C", root, "show",
    "HEAD:lua/auto-finder/views/todos/init.lua" }, { text = true }):wait()
  assert(baseline.code == 0, baseline.stderr)
  view = assert(loadstring(baseline.stdout, "@committed-todos-view"))()
end
-- AutoDoc's daemon decodes the files; what the panel controls is when it
-- asks. Count the listings it sends, and inject a listing failure on demand.
local ad_todos = require("autodoc.todos")
local real_call = ad_todos.call
local reads, fail_list = 0, false
ad_todos.call = function(verb, params, cb)
  if verb == "list" then
    reads = reads + 1
    if fail_list then return cb(nil, { message = "injected listing failure" }) end
  end
  real_call(verb, params, cb)
end
reads = 0
local b = view.get_buffer(0)
check("mount does not list the store", reads == 0)
check("mount displays loading placeholder", table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"):find("Loading", 1, true) ~= nil)
view.on_focus(0, b)
check("focus does not list the store synchronously", reads == 0)
check("eventual render includes active, archived and malformed files", vim.wait(3000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  return text:find("Active task", 1, true) and text:find("Archived", 1, true) and text:find("broken.md", 1, true) and not view._loading
end, 5))
-- one listing of the active buckets, one of the archive's months, one per month
check("first mount lists once: active, the months, the one month", reads == 3)
local loads_done = 0
local real_load = store.load
store.load = function(on_part)
  return real_load(function(...)
    loads_done = loads_done + 1
    return on_part(...)
  end)
end
view.on_focus(0, b)
view.on_close()
vim.wait(200, function() return false end, 5)
check("closing cancels pending load", loads_done == 0 and view._bufnr == nil)
store.load = real_load

do
  local stages = {}
  store.load(function(result, done, err)
    stages[#stages + 1] = { tasks = result and #result.tasks, malformed = result and #result.malformed,
      done = done, err = err }
  end)
  check("the load finishes", vim.wait(3000, function() return #stages >= 2 and stages[#stages].done end, 5))
  check("active stage excludes archives", stages[1] and stages[1].tasks == 1 and stages[1].malformed == 1)
  check("the final stage adds the archive", stages[#stages] and stages[#stages].tasks == 2)
  local called = false
  local cancel = store.load(function() called = true end)
  cancel()
  vim.wait(100, function() return false end, 5)
  check("load cancellation suppresses callbacks", not called)

  -- 128 more archived tasks in the same month, each a copy of the archived
  -- task's file under a new id: the archive is the bulk of a real store.
  local archive_task = assert(todo.get(archived))
  local bytes = table.concat(vim.fn.readfile(archive_task.file_path), "\n") .. "\n"
  local archive_dir = archive_task.file_path:match("^(.*)/")
  for i = 1, 128 do
    local id = "2026-10-09-archive-fixture-" .. i
    vim.fn.writefile(vim.split((bytes:gsub("\nid: [^\n]+\n", "\nid: " .. id .. "\n", 1)), "\n",
      { plain = true }), archive_dir .. "/" .. id .. ".md")
  end
  local heartbeat, beat_before_archive, done = false, nil, false
  local active_first = false
  store.load(function(result, complete)
    if not complete then active_first = #result.tasks == 1 end
    if complete then beat_before_archive = heartbeat end
    done = complete
  end)
  vim.schedule(function() heartbeat = true end)
  check("large archive finishes", vim.wait(3000, function() return done end, 5))
  check("the editor runs while the archive is read", beat_before_archive == true)
  check("active result precedes the archive", active_first)

  local other_dir = vim.uv.fs_realpath(sandbox) .. "/other-tasks"
  vim.fn.mkdir(other_dir, "p") -- set_dir needs an existing directory
  set_dir(other_dir)
  local shared = assert(todo.add({ title = "Active task" }))
  check("two stores share the same task id", shared == active)
  assert(todo.update(shared, { title = "Different location" }))
  set_dir(dir)
  b = view.get_buffer(0)
  vim.api.nvim_win_set_buf(0, b)
  check("old location renders before switch", vim.wait(3000, function()
    return not view._loading
  end, 5))
  local function select_active()
    for _, row in ipairs(view._rows) do
      if row.task and row.task.id == active then
        vim.api.nvim_win_set_cursor(0, { row.lnum, 0 })
        return true
      end
    end
    return false
  end
  local function press(key)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do
      if map.lhs == key then map.callback(); return end
    end
    error("missing keymap " .. key)
  end
  check("old task is actionable before switch", select_active())
  local confirm, select = vim.fn.confirm, vim.ui.select
  local confirmations, selections, status_callback = 0, 0
  vim.fn.confirm = function() set_dir(other_dir); return 1 end
  press("d")
  vim.wait(200, function() return false end, 5)
  check("delete confirmation cannot follow a store switch", todo.get(shared) ~= nil)
  set_dir(dir)
  local agents, input = package.loaded["auto-agents"], vim.ui.input
  local assignment_callback
  package.loaded["auto-agents"] = {
    spawned_agents = function() return { { name = "loading-test", slot = 1 } } end,
  }
  vim.ui.select = function(items, _, callback) callback(items[1]) end
  vim.ui.input = function(_, callback) assignment_callback = callback end
  press("A")
  check("assignment prompt opens on old task", assignment_callback ~= nil)
  package.loaded["auto-agents"], vim.ui.input = agents, input
  vim.fn.confirm = function() confirmations = confirmations + 1; return 1 end
  vim.ui.select = function(_, _, callback)
    selections = selections + 1
    status_callback = callback
  end
  press("s")
  check("status picker opens on old task", status_callback ~= nil)
  set_dir(other_dir)
  check("row lookup rejects a switch before focus", view._row_under_cursor(0) == nil)
  status_callback("completed")
  vim.wait(200, function() return false end, 5)
  check("pending status choice cannot mutate the new store", todo.get(shared).status == "open")
  assignment_callback("Start this task")
  vim.wait(200, function() return false end, 5)
  check("pending assignment cannot mutate the new store",
    todo.get(shared).assignee == nil and todo.get(shared).status == "open")
  confirmations, selections = 0, 0
  view.on_focus(0, b)
  check("location switch immediately clears action rows", #view._rows == 0)
  check("location switch immediately replaces old text with loading",
    table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"):find("Loading", 1, true) ~= nil)
  press("d")
  press("s")
  check("loading rows cannot open delete or status prompts", confirmations == 0 and selections == 0)
  check("loading actions leave same-id task untouched", todo.get(shared) and todo.get(shared).status == "open")
  vim.fn.confirm, vim.ui.select = confirm, select
  check("location switch finishes", vim.wait(3000, function() return not view._loading end, 5))
  local text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  check("stale location cannot overwrite current tasks",
    text:find("Different location", 1, true) ~= nil and text:find("Active task", 1, true) == nil)

  vim.api.nvim_win_set_buf(0, b)
  vim.cmd("vsplit")
  vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(false, true))
  local editor_win, editor_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local loads = 0
  store.load = function(...)
    loads = loads + 1
    return real_load(...)
  end
  local events = require("auto-core.events")
  for _ = 1, 10 do events.publish("core.todo:changed", { kind = "update" }) end
  check("event burst reloads", vim.wait(3000, function() return loads > 0 and not view._loading end, 5))
  check("event burst coalesces into one load", loads == 1)
  check("background loads do not hijack editor focus",
    vim.api.nvim_get_current_win() == editor_win and vim.api.nvim_get_current_buf() == editor_buf)
  store.load = real_load

  set_dir(dir)
  view.on_focus(0, b)
  set_dir(other_dir)
  check("visible pending load follows directory change without focus",
    vim.wait(3000, function()
      local content = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
      return not view._loading and content:find("Different location", 1, true) ~= nil
    end, 5))

  fail_list = true
  local focus_ok = pcall(view.on_focus, 0, b)
  check("a listing failure ends loading", focus_ok and vim.wait(3000, function() return not view._loading end, 5))
  check("a listing failure is visible and does not retain stale rows",
    vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]:find("loading failed", 1, true) ~= nil
      and #view._rows == 0)
  fail_list = false
  view.on_focus(0, b)
  check("loading recovers after failure", vim.wait(3000, function()
    local content = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
    return not view._loading and content:find("Different location", 1, true) ~= nil
  end, 5))
  view.on_close()
end
ad_todos.call = real_call
set_dir(nil)
io.stdout:write(string.format("%d passed, %d failed\n", passed, failed))
io.stdout:flush()
vim.cmd(failed == 0 and "qa!" or "cquit")
