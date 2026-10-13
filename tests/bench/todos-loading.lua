-- Read-only profiling of an existing store through AutoDoc's daemon (the
-- panel's door, views/todos/store.lua); never calls refresh. Points this
-- Neovim's project at the store with todos.set_dir, so run it against a COPY,
-- with an AutoDoc of its own.
-- AF_TODOS_BENCH_DIR=/path/to/.todo-list nvim --headless -u NONE -l tests/bench/todos-loading.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h:h") .. "/auto-core.nvim/main")
local sandbox = dofile(root .. "/tests/_sandbox.lua")("todos-benchmark")
local dir = assert(vim.env.AF_TODOS_BENCH_DIR, "Set AF_TODOS_BENCH_DIR to an existing store")
assert(vim.fn.isdirectory(dir) == 1, "Store does not exist: " .. dir)
local ok_ad, why = dofile(root .. "/tests/_autodoc.lua")(sandbox, "bench")
assert(ok_ad, why)
local store = require("auto-finder.views.todos.store")
local set = false
store.set_dir((vim.fn.fnamemodify(dir, ":p"):gsub("/$", "")), function(ok, err)
  assert(ok, err)
  set = true
end)
assert(vim.wait(60000, function() return set end, 5), "set_dir timed out")
local real_load = store.load
local started
local active_ms, complete_ms, totals
store.load = function(callback)
  return real_load(function(snapshot, done, err)
    callback(snapshot, done, err)
    if done then
      complete_ms = (vim.uv.hrtime() - started) / 1e6
      totals = snapshot and { tasks = #snapshot.tasks, malformed = #snapshot.malformed } or { err = err }
    else
      active_ms = (vim.uv.hrtime() - started) / 1e6
    end
  end)
end
local view = require("auto-finder.views.todos")
started = vim.uv.hrtime()
local buf = view.get_buffer(0)
view.on_focus(0, buf)
local mount_ms = (vim.uv.hrtime() - started) / 1e6
assert(vim.wait(60000, function() return complete_ms ~= nil end, 5), "Timed out")
io.stdout:write(string.format(
  "tasks=%s malformed=%s\nmount_and_focus_ms=%.2f active_render_ms=%.2f complete_render_ms=%.2f\n",
  tostring(totals.tasks), tostring(totals.malformed), mount_ms, active_ms or -1, complete_ms))
io.stdout:flush()
view.on_close()
vim.cmd("qa!")
