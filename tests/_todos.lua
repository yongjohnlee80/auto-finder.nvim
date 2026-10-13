---tests/_todos.lua — a synchronous todo client for the suites' fixtures and
---assertions, over the panel's own door (views/todos/store.lua).
---
---auto-core v0.4.1 removes `auto-core.todo` (ADR 1791532020 §3 step 5), so the
---cells no longer seed their stores through it. This file gives them the same
---handful of calls, each waiting (bounded) for AutoDoc's daemon:
---
---  T.add(spec)          → id; raises on error
---  T.get(id)            → task | nil, err
---  T.status(id, new)    → task | nil, err   (reads the rev first)
---  T.assign(id, who, r) → task | nil, err
---  T.update(id, patch)  → task | nil, err
---  T.refresh()          → summary; raises on error
---  T.list(opts)         → tasks (the daemon's list opts: buckets, tag, …)
---  T.dir()              → the store directory
---
---It is a test fixture, not a second client: it holds no rule of its own, and
---each call is one or two daemon verbs. Like any client of the store (the
---panel, auto-agents' todos.* verbs) it publishes the core.todo:* events after
---its writes, so a cell sees the panel react as it does to an agent's change.
---
---Usage: local todo = dofile(<tests dir> .. "/_todos.lua")
local store = require("auto-finder.views.todos.store")

local T = {}

-- NOTE: deadline. The daemon is another process; a fixture call that never
-- answers fails its cell rather than hanging the suite.
T.WAIT_MS = 15000

local function wait(fn)
  local done, res = false, nil
  fn(function(...) res = { n = select("#", ...), ... }; done = true end)
  if not vim.wait(T.WAIT_MS, function() return done end, 10) then
    return nil, "AutoDoc did not answer within " .. T.WAIT_MS .. " ms"
  end
  return unpack(res, 1, res.n)
end

function T.dir()
  wait(function(cb) store.context(function(ctx, err) cb(ctx, err) end) end)
  return store.dir()
end

-- The fields todos.add takes (the daemon's Spec); a fixture's other keys
-- (completed_at, …) are the daemon's to stamp, and are dropped as the shim did.
local SPEC_FIELDS = { "id", "title", "description", "status", "due", "priority", "assignee",
  "tags", "adr", "review", "blocked" }

function T.add(spec)
  local s = {}
  for _, k in ipairs(SPEC_FIELDS) do s[k] = spec[k] end
  local task, err = wait(function(cb) store.add(s, cb) end)
  if not task then error("_todos.add: " .. tostring(err), 2) end
  store.publish("core.todo:changed", { kind = "add", id = task.id })
  return task.id, task
end

function T.get(id)
  local task, err, ctx = wait(function(cb) store.call("get", { id }, cb) end)
  if err then return nil, store.format(err) end
  task.file_path = store.file_path(ctx, task)
  return task
end

local function mutate(verb, id, extra)
  local cur, gerr = T.get(id)
  if not cur then return nil, gerr end
  local task, err = wait(function(cb) store.mutate(verb, cur, extra, cb) end)
  if task then
    store.follow(cur, task)
    if cur.status ~= task.status then
      store.publish("core.todo.status:changed", { id = id, from = cur.status, to = task.status })
    end
    store.publish("core.todo:changed", { kind = verb, id = id })
  end
  return task, err
end

function T.status(id, new) return mutate("status", id, { new }) end
function T.update(id, patch) return mutate("update", id, { patch }) end
function T.assign(id, who, reason)
  local extra = { who or "" }
  if reason then extra[2] = reason end
  return mutate("assign", id, extra)
end

function T.refresh()
  local s, err = wait(function(cb) store.refresh(cb) end)
  if not s then error("_todos.refresh: " .. tostring(err), 2) end
  store.publish("core.todo:refreshed", { summary = s })
  return s
end

function T.list(opts)
  local args = {}
  if opts and next(opts) ~= nil then args[1] = opts end
  local l, err, ctx = wait(function(cb) store.call("list", args, cb) end)
  if err then error("_todos.list: " .. store.format(err), 2) end
  return store._decorate(ctx, (l and l.tasks) or {})
end

return T
