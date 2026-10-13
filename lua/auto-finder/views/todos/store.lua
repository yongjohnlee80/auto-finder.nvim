---auto-finder.views.todos.store — the todos panel's one door to AutoDoc's daemon.
---
---AutoDoc owns the todo store: its format, its rules and every write (ADR
---1791532020). The panel calls the daemon's `todos.*` verbs itself, through
---autodoc.nvim's client (`autodoc.todos`), rather than through auto-core.todo,
---which auto-core v0.4.1 removes (§3 steps 4 and 5).
---
---Where the store is still comes from auto-core: `auto-core.todo.where` maps
---this Neovim's project root to the daemon's `At` (a workspace name, or
---`{root}`) and claims the store once per root, with the rollback guard. That
---is the one copy of the rule; this module does not repeat it (ADR r12).
---
---There is no Lua fallback (ADR §4): without autodoc.nvim, or without the
---daemon, every call answers an error, and the panel says "AutoDoc required".
---
---Every function is asynchronous: `cb(result, err)`, err a string such as
---"todos.stale: …" (the daemon's code name, then its message).
---@module 'auto-finder.views.todos.store'

local M = {}

M.REQUIRED = "AutoDoc required: the todos panel calls AutoDoc's daemon (ADR 1791532020). "
  .. "Install autodoc.nvim (v0.1.39 or later) and its binary."

M.NEEDS_AUTOCORE = "the todos panel needs auto-core v0.4.0 or later (its store resolution, "
  .. "auto-core.todo.where): update auto-core"

-- The daemon's codes the panel acts on (autodoc core/todo/module.go).
M.STALE, M.NOT_A_STORE, M.UNCLAIMED = -32071, -32074, -32077

---deps loads what the door needs, or answers why it can't.
---@return { where: table, daemon: table, todos: table }|nil, string? why
local function deps()
  local ok_w, where = pcall(require, "auto-core.todo.where")
  local ok_d, daemon = pcall(require, "auto-core.todo.daemon")
  if not (ok_w and ok_d and type(where) == "table" and type(daemon) == "table"
      and type(where.ensure) == "function" and type(daemon.run) == "function") then
    return nil, M.NEEDS_AUTOCORE
  end
  local ok_t, todos = pcall(require, "autodoc.todos")
  if not ok_t or type(todos) ~= "table" or type(todos.call) ~= "function" then
    return nil, M.REQUIRED
  end
  return { where = where, daemon = daemon, todos = todos }
end

---available says whether the panel can reach AutoDoc at all: autodoc.nvim
---loads, and auto-core resolves stores. It does not start the daemon.
---@return boolean ok, string? why
function M.available()
  local d, why = deps()
  return d ~= nil, why
end

---format turns a daemon error ({code, message}) or any other error into the
---panel's string: "<code name>: <message>".
---@param err any
---@return string
function M.format(err)
  local ok_d, daemon = pcall(require, "auto-core.todo.daemon")
  if ok_d and type(daemon.format) == "function" then return daemon.format(err) end
  if type(err) == "table" then return tostring(err.message or err.msg or "unknown error") end
  return tostring(err)
end

---is reports whether err carries the daemon code.
---@param err any
---@param code integer
---@return boolean
function M.is(err, code)
  return type(err) == "table" and err.code == code
end

---dir is this project's store directory. It never waits: before the store has
---been resolved once it is the directory auto-core resolves locally (the
---override, else <root>/.todo-list), and the resolution starts in the
---background. nil when the door is unavailable.
---@return string?
function M.dir()
  local d = deps()
  if not d then return nil end
  local root = d.where.root()
  local c = d.where.cached(root)
  if c and type(c.store) == "string" then return c.store end
  M._kick(d, root)
  return d.where.local_dir(root)
end

local _kicking = {}
function M._kick(d, root)
  if _kicking[root] then return end
  _kicking[root] = true
  vim.schedule(function()
    d.daemon.run(function() return d.where.ensure(root) end, function()
      _kicking[root] = nil
    end)
  end)
end

---context resolves (and, the first time, claims) this project's store:
---cb(ctx) with ctx { root, at, store, store_id, claimed, writable }, or
---cb(nil, err). `root` is a root a sequence captured at its start (default:
---the project root now).
---@param cb fun(ctx: table|nil, err: string|nil)
---@param root string?
function M.context(cb, root)
  local d, why = deps()
  if not d then return cb(nil, why) end
  root = root or d.where.root()
  d.daemon.run(function() return d.where.ensure(root) end, function(ok, ctx)
    if not ok then return cb(nil, tostring(ctx)) end
    cb(ctx)
  end)
end

---call runs todos.<verb>(ctx.at, …) for this project's store. cb(result, err,
---ctx): result has vim.NIL normalized away; err is the daemon's {code, message}
---(see M.format and M.is), or a string when the store could not be resolved.
---An unclaimed answer drops auto-core's cached resolution, so the next call
---resolves again (and the rollback guard decides whether it claims).
---@param verb string the verb's own name: "list", not "todos.list"
---@param args any[] the params after `at`
---@param cb fun(result: any, err: any, ctx: table|nil)
function M.call(verb, args, cb)
  M.context(function(ctx, cerr)
    if not ctx then return cb(nil, cerr) end
    M.call_at(ctx, verb, args, cb)
  end)
end

---call_at runs todos.<verb>(ctx.at, …) on the store a previous call resolved,
---without resolving the project again. ONE STORE PER OPERATION: a sequence
---(add → scaffold → add; a load's active buckets, then its months) resolves
---once and sends every later step here, so a project switch while one step
---waits cannot send the next to another project's store (Lector, auto-agents
---#26 r1 P2: the same class).
---@param ctx table a ctx a previous call answered
---@param verb string
---@param args any[]
---@param cb fun(result: any, err: any, ctx: table)
function M.call_at(ctx, verb, args, cb)
  local d = deps()
  if not d then return cb(nil, M.REQUIRED, ctx) end
  local params = { ctx.at }
  for i = 1, #(args or {}) do params[i + 1] = args[i] end
  local ok, perr = pcall(d.todos.call, verb, params, function(res, err)
    res, err = d.daemon.normalize(res), d.daemon.normalize(err)
    if M.is(err, M.UNCLAIMED) then d.where.reset(ctx.root) end
    cb(res, err, ctx)
  end)
  if not ok then cb(nil, "autodoc: " .. tostring(perr), ctx) end
end

---file_path is a daemon task's absolute path in the store ctx names.
---@param ctx table
---@param task table
---@return string?
function M.file_path(ctx, task)
  if type(task) ~= "table" or type(task.path) ~= "string" or type(ctx) ~= "table"
      or type(ctx.store) ~= "string" then
    return nil
  end
  return ctx.store .. "/" .. task.path
end

---decorate adds `file_path` (absolute) to each task.
---@param ctx table
---@param tasks table[]
---@return table[]
local function decorate(ctx, tasks)
  for _, t in ipairs(tasks) do
    if type(t) == "table" then t.file_path = M.file_path(ctx, t) end
  end
  return tasks
end
M._decorate = decorate

local function list_of(v) return type(v) == "table" and v or {} end

---load reads the store for the panel: the active buckets first, then every
---archive month. on_part(snapshot, done) runs twice, with the same snapshot
---table growing: `done = false` after the active buckets, `done = true` after
---the archive. snapshot = { ctx, tasks, malformed = { {path, reason} } }. A
---store that does not exist yet (a project before its first task) is empty,
---not an error. Nothing is asked before it returns (the first call is
---scheduled), so mounting the panel never waits on the daemon. Returns a cancel
---function; after it, nothing more is called.
---@param on_part fun(snapshot: table|nil, done: boolean, err: string|nil)
---@return fun() cancel
function M.load(on_part)
  local cancelled = false
  local snap = { tasks = {}, malformed = {} }
  local function fail(err)
    if cancelled then return end
    cancelled = true
    on_part(nil, true, M.format(err))
  end
  local function add(listing)
    for _, t in ipairs(decorate(snap.ctx, list_of(listing and listing.tasks))) do
      snap.tasks[#snap.tasks + 1] = t
    end
    for _, m in ipairs(list_of(listing and listing.malformed)) do
      snap.malformed[#snap.malformed + 1] = m
    end
  end
  vim.schedule(function()
    if cancelled then return end
    M.call("list", {}, function(active, err, ctx)
      if cancelled then return end
      snap.ctx = ctx
      if M.is(err, M.NOT_A_STORE) then
        cancelled = true
        return on_part(snap, true)
      end
      if err then return fail(err) end
      add(active)
      on_part(snap, false)
      if cancelled then return end
      M.call_at(snap.ctx, "list", { { buckets = { "archived" } } }, function(months, merr)
        if cancelled then return end
        if merr then return fail(merr) end
        local wanted = {}
        for _, p in ipairs(list_of(months and months.partitions)) do
          if type(p) == "table" and type(p.month) == "string" then wanted[#wanted + 1] = p.month end
        end
        -- One month at a time: the archive is the bulk of a store, and a month's
        -- answer is decoded on the UI loop.
        local i = 0
        local function next_month()
          if cancelled then return end
          i = i + 1
          if i > #wanted then
            cancelled = true
            return on_part(snap, true)
          end
          M.call_at(snap.ctx, "list", { { buckets = { "archived/" .. wanted[i] } } }, function(listing, lerr)
            if cancelled then return end
            if lerr then return fail(lerr) end
            add(listing)
            next_month()
          end)
        end
        next_month()
      end)
    end)
  end)
  return function() cancelled = true end
end

---refresh reconciles the active buckets (the daemon's refresh: misplaced
---files, errors[], the 28-day archive). cb(summary, err).
---@param cb fun(summary: table|nil, err: string|nil)
function M.refresh(cb)
  M.call("refresh", {}, function(s, err)
    if M.is(err, M.NOT_A_STORE) then return cb({}) end -- nothing to reconcile yet
    if err then return cb(nil, M.format(err)) end
    cb(s or {})
  end)
end

---add creates a task, scaffolding a new project's store first when the daemon
---says there is none yet. cb(task, err), the task with its file_path.
---@param spec table
---@param cb fun(task: table|nil, err: string|nil)
function M.add(spec, cb)
  M.call("add", { spec }, function(task, err, ctx)
    if M.is(err, M.NOT_A_STORE) then
      return M.call_at(ctx, "scaffold", {}, function(_, serr)
        if serr then return cb(nil, M.format(serr)) end
        M.call_at(ctx, "add", { spec }, function(t2, err2, ctx2)
          if err2 then return cb(nil, M.format(err2)) end
          t2.file_path = M.file_path(ctx2, t2)
          cb(t2)
        end)
      end)
    end
    if err then return cb(nil, M.format(err)) end
    task.file_path = M.file_path(ctx, task)
    cb(task)
  end)
end

---mutate runs one write verb on a task the panel read at `task.rev`, so a task
---changed since (by an agent, by hand) is refused as todos.stale rather than
---overwritten. cb(new_task, err, err_raw).
---@param verb "status"|"assign"|"update"|"remove"
---@param task table the panel's row task: id, rev, file_path
---@param extra any[] the params after rev
---@param cb fun(task: table|nil, err: string|nil, raw: any)
function M.mutate(verb, task, extra, cb)
  if type(task) ~= "table" or type(task.id) ~= "string" or type(task.rev) ~= "string" then
    return cb(nil, "the panel's row has no task id and rev: reload it (R)")
  end
  local args = { task.id, task.rev }
  for i = 1, #(extra or {}) do args[#args + 1] = extra[i] end
  M.call(verb, args, function(res, err, ctx)
    if err then return cb(nil, M.format(err), err) end
    if type(res) == "table" then res.file_path = M.file_path(ctx, res) end
    cb(res)
  end)
end

---follow keeps open buffers on a task the daemon moved or rewrote (auto-core's
---buffers: a buffer left on the old path would recreate the task in the bucket
---it left on its next :w).
---@param before table? the task as the panel read it
---@param after table? the task the daemon answered
function M.follow(before, after)
  if type(before) ~= "table" or type(after) ~= "table" then return end
  local ok, buffers = pcall(require, "auto-core.todo.buffers")
  if not ok or type(buffers) ~= "table" then return end
  local from, to = before.file_path, after.file_path
  if type(from) ~= "string" or type(to) ~= "string" then return end
  if from ~= to then
    pcall(buffers.retarget, from, to)
  else
    pcall(buffers.reload, to)
  end
end

---publish sends one of the core.todo:* events, as auto-core.todo did for its
---callers: other views (and other plugins) re-read on them.
---@param topic string
---@param payload table
function M.publish(topic, payload)
  local ok, events = pcall(require, "auto-core.events")
  if ok and events and type(events.publish) == "function" then
    pcall(events.publish, topic, payload)
  end
end

---poke_notifier asks auto-core's assignment notifier to poll now, after an
---assignment the panel made (ADR §2.5): the agent hears of it at once rather
---than at the next timer tick.
function M.poke_notifier()
  pcall(function() require("auto-core.todo.notifier").poll_soon() end)
end

---set_dir points this project at another existing store directory (or back at
---<root>/.todo-list with ""). The override is per ROOT, so it goes to the
---daemon as {root}, then auto-core's record and resolution are refreshed.
---cb(ok, err).
---@param dir string absolute, or ""
---@param cb fun(ok: boolean, err: string|nil)
function M.set_dir(dir, cb)
  local d, why = deps()
  if not d then return cb(false, why) end
  local root = d.where.root()
  local ok, perr = pcall(d.todos.call, "set_dir", { { root = root }, dir }, function(_, err)
    err = d.daemon.normalize(err)
    if err then return cb(false, M.format(err)) end
    d.where.set_override(root, dir ~= "" and dir or nil)
    d.where.reset(root)
    -- resolve (and claim) the new store now: the root this call started on,
    -- not the project root after the wait (Lector, auto-agents #26 r2 P2)
    M.context(function(_, cerr) cb(cerr == nil, cerr) end, root)
  end)
  if not ok then cb(false, "autodoc: " .. tostring(perr)) end
end

---move_store moves this project's store to `to` (nothing may be there; its
---parent must exist). The store keeps its claim, change log and cursors.
---cb(new_store, err).
---@param to string absolute
---@param cb fun(store: string|nil, err: string|nil)
function M.move_store(to, cb)
  M.call("move_store", { to }, function(r, err, ctx)
    if err then return cb(nil, M.format(err)) end
    local d = deps()
    if d and ctx then
      d.where.set_override(ctx.root, r.store)
      d.where.reset()
    end
    cb(r.store)
  end)
end

---remove_malformed deletes one malformed file the daemon listed (its
---store-relative path). cb(ok, err).
---@param rel string
---@param cb fun(ok: boolean, err: string|nil)
function M.remove_malformed(rel, cb)
  M.call("remove_malformed", { rel }, function(_, err)
    if err then return cb(false, M.format(err)) end
    cb(true)
  end)
end

---Test seam.
function M._reset_for_tests() _kicking = {} end

return M
