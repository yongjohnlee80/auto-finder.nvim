-- Read-only profiling of an existing store; never calls refresh().
-- AF_TODOS_BENCH_DIR=/path/to/.todo-list nvim --headless -u NONE -l tests/bench/todos-loading.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h:h") .. "/auto-core.nvim/main")
dofile(root .. "/tests/_sandbox.lua")("todos-benchmark")
local dir = assert(vim.env.AF_TODOS_BENCH_DIR, "Set AF_TODOS_BENCH_DIR to an existing store")
assert(vim.fn.isdirectory(dir) == 1, "Store does not exist: " .. dir)
local todo = require("auto-core.todo")
todo.set_todo_dir(dir)
local started = vim.uv.hrtime()
local result = todo.scan()
local synchronous_ms = (vim.uv.hrtime() - started) / 1e6
local async_scan = todo.scan_async
local active_ms, complete_ms
todo.scan_async = function(callback)
  return async_scan(function(snapshot, done, err)
    callback(snapshot, done, err)
    if done then complete_ms = (vim.uv.hrtime() - started) / 1e6
    else active_ms = (vim.uv.hrtime() - started) / 1e6 end
  end)
end
local view = require("auto-finder.views.todos")
started = vim.uv.hrtime()
local buf = view.get_buffer(0)
view.on_focus(0, buf)
local mount_ms = (vim.uv.hrtime() - started) / 1e6
assert(vim.wait(60000, function() return complete_ms ~= nil end, 5), "Timed out")
local archives = 0
for _, task in ipairs(result.tasks) do
  if task.status == "archived" then archives = archives + 1 end
end
io.stdout:write(string.format(
  "tasks=%d archived=%d malformed=%d\nsync_scan_ms=%.2f mount_and_focus_ms=%.2f active_render_ms=%.2f complete_render_ms=%.2f\n",
  #result.tasks, archives, #result.malformed, synchronous_ms, mount_ms, active_ms, complete_ms))
io.stdout:flush()
view.on_close()
vim.cmd("qa!")