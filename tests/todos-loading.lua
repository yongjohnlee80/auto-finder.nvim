-- nvim --headless -u NONE -l tests/todos-loading.lua
-- AF_TODOS_BASELINE=1 tests the committed renderer with the same assertions.
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
local todo = require("auto-core.todo")
local dir = sandbox .. "/tasks"
todo.set_todo_dir(dir)
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
local md = require("auto-core.todo.md")
local decode, reads = md.decode, 0
md.decode = function(...)
  reads = reads + 1
  return decode(...)
end
local b = view.get_buffer(0)
check("mount does not decode task files", reads == 0)
check("mount displays loading placeholder", table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"):find("Loading", 1, true) ~= nil)
view.on_focus(0, b)
check("focus does not decode task files synchronously", reads == 0)
check("eventual render includes active, archived and malformed files", vim.wait(3000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  return text:find("Active task", 1, true) and text:find("Archived", 1, true) and text:find("broken.md", 1, true) and not view._loading
end, 5))
check("first mount scans each file once", reads == 3)
local original_scan = todo.scan
local scans = 0
todo.scan = function(...)
  scans = scans + 1
  return original_scan(...)
end
view.on_focus(0, b)
view.on_close()
vim.wait(100, function() return false end, 5)
check("closing cancels pending load", scans == 0 and view._bufnr == nil)
md.decode = decode
todo.scan = original_scan

if type(todo.scan_async) == "function" then
  local stages = {}
  todo.scan_async(function(result, done, err)
    stages[#stages + 1] = { result = vim.deepcopy(result), done = done, err = err }
  end)
  check("async scan finishes", vim.wait(3000, function() return #stages >= 2 and stages[#stages].done end, 5))
  check("active stage excludes archives", stages[1] and #stages[1].result.tasks == 1 and #stages[1].result.malformed == 1)
  check("final scan equals synchronous scan", stages[#stages] and vim.deep_equal(stages[#stages].result, todo.scan()))
  local called = false
  local cancel = todo.scan_async(function() called = true end)
  cancel()
  vim.wait(100, function() return false end, 5)
  check("scan cancellation suppresses callbacks", not called)

  local archive_task = assert(todo.get(archived))
  local archive_dir = require("auto-core.todo.paths").task_file_path(dir,
    archived, "archived", archive_task.archived_at):match("^(.*)/")
  for i = 1, 128 do
    local task = vim.deepcopy(archive_task)
    task.id = "2026-10-09-archive-fixture-" .. i
    vim.fn.writefile(vim.split(md.encode(task), "\n", { plain = true }),
      archive_dir .. "/" .. task.id .. ".md")
  end
  local heartbeat, decode_count, yielded, done = false, 0, false, false
  md.decode = function(...)
    decode_count = decode_count + 1
    if decode_count == 1 then vim.schedule(function() heartbeat = true end) end
    if decode_count > 32 and heartbeat then yielded = true end
    return decode(...)
  end
  local active_first = false
  todo.scan_async(function(result, complete)
    if not complete then active_first = #result.tasks == 1 end
    done = complete
  end)
  check("large archive finishes", vim.wait(3000, function() return done end, 5))
  check("large archive yields to the editor between batches", yielded)
  check("active result precedes archive decoding", active_first)
  md.decode = decode

  local other_dir = sandbox .. "/other-tasks"
  todo.set_todo_dir(other_dir)
  local shared = assert(todo.add({ title = "Active task" }))
  check("two stores share the same task id", shared == active)
  assert(todo.update(shared, { title = "Different location" }))
  todo.set_todo_dir(dir)
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
  vim.fn.confirm = function() todo.set_todo_dir(other_dir); return 1 end
  press("d")
  check("delete confirmation cannot follow a store switch", todo.get(shared) ~= nil)
  todo.set_todo_dir(dir)
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
  todo.set_todo_dir(other_dir)
  check("row lookup rejects a switch before focus", view._row_under_cursor(0) == nil)
  status_callback("completed")
  check("pending status choice cannot mutate the new store", todo.get(shared).status == "open")
  assignment_callback("Start this task")
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
  local async_scan, loads = todo.scan_async, 0
  todo.scan_async = function(...)
    loads = loads + 1
    return async_scan(...)
  end
  local events = require("auto-core.events")
  for _ = 1, 10 do events.publish("core.todo:changed", { kind = "update" }) end
  check("event burst reloads", vim.wait(3000, function() return loads > 0 and not view._loading end, 5))
  check("event burst coalesces into one scan", loads == 1)
  check("background loads do not hijack editor focus",
    vim.api.nvim_get_current_win() == editor_win and vim.api.nvim_get_current_buf() == editor_buf)
  todo.scan_async = async_scan

  todo.set_todo_dir(dir)
  view.on_focus(0, b)
  todo.set_todo_dir(other_dir)
  check("visible pending load follows directory change without focus",
    vim.wait(3000, function()
      local content = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
      return not view._loading and content:find("Different location", 1, true) ~= nil
    end, 5))

  md.decode = function() error("injected decoder failure") end
  local focus_ok = pcall(view.on_focus, 0, b)
  check("decoder failure ends loading", focus_ok and vim.wait(3000, function() return not view._loading end, 5))
  check("decoder failure is visible and does not retain stale rows",
    vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]:find("loading failed", 1, true) ~= nil
      and #view._rows == 0)
  md.decode = decode
  view.on_focus(0, b)
  check("loading recovers after failure", vim.wait(3000, function()
    local content = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
    return not view._loading and content:find("Different location", 1, true) ~= nil
  end, 5))
  view.on_close()

  todo.scan_async = nil
  reads = 0
  md.decode = function(...)
    reads = reads + 1
    return decode(...)
  end
  b = view.get_buffer(0)
  check("older-core fallback mounts without synchronous decoding", reads == 0)
  check("older-core fallback eventually renders", vim.wait(3000, function()
    local content = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
    return not view._loading and content:find("Different location", 1, true) ~= nil
  end, 5))
  vim.api.nvim_win_set_buf(0, b)
  check("older-core fallback has an actionable task", select_active())
  todo.set_todo_dir(dir)
  view.on_focus(0, b)
  check("older-core fallback clears old rows before deferred scan", #view._rows == 0)
  confirmations, selections = 0, 0
  vim.fn.confirm = function() confirmations = confirmations + 1; return 1 end
  vim.ui.select = function() selections = selections + 1 end
  press("d")
  press("s")
  check("older-core loading actions leave the new store untouched",
    confirmations == 0 and selections == 0 and todo.get(active).status == "open")
  vim.fn.confirm, vim.ui.select = confirm, select
  check("older-core location switch eventually renders", vim.wait(3000, function()
    local content = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
    return not view._loading and content:find("Active task", 1, true) ~= nil
  end, 5))
  todo.scan_async = async_scan
  md.decode = decode
  view.on_close()
else
  check("core provides cooperative async scanner", false)
end
todo.set_todo_dir(nil)
io.stdout:write(string.format("%d passed, %d failed\n", passed, failed))
io.stdout:flush()
vim.cmd(failed == 0 and "qa!" or "cquit")