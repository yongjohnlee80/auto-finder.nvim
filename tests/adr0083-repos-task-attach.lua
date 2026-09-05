-- ADR-0083: 'A' keymap on repos panel to attach review findings to in-progress task
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
local sib = vim.fn.fnamemodify(root, ":h:h")
local branch_dir = vim.fn.fnamemodify(root, ":t")
for _, p in ipairs({ LAZY .. "/nui.nvim", LAZY .. "/plenary.nvim" }) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end
for _, plugin in ipairs({ "worktree.nvim", "auto-core.nvim" }) do
  -- A candidate must be able to SERVE the request, not merely exist. These
  -- suites need worktree.pr / worktree.repos.reviews_index and
  -- auto-core.docstore; a checkout predating them cannot answer at all, and
  -- because the LAST prepend wins, a stale sibling shadowed a current copy —
  -- the suites aborted mid-run rather than reporting a count. Direction and
  -- precedence are unchanged; LAZY joins as the lowest-precedence candidate.
  local req = ({
    ["worktree.nvim"]  = { "lua/worktree/repos.lua", "function M.reviews_index" },
    ["auto-core.nvim"] = { "lua/auto-core/docstore/init.lua", "function M.write_json" },
  })[plugin]
  local function serves(r)
    if not req then return true end
    local f = r .. "/" .. req[1]
    if vim.fn.filereadable(f) ~= 1 then return false end
    for _, line in ipairs(vim.fn.readfile(f)) do
      if line:find(req[2], 1, true) then return true end
    end
    return false
  end
  local roots, fallback = {}, nil
  for _, r in ipairs({ LAZY .. "/" .. plugin,
                       sib .. "/" .. plugin .. "/main",
                       sib .. "/" .. plugin .. "/" .. branch_dir }) do
    if vim.fn.isdirectory(r) == 1 then
      if serves(r) then roots[#roots + 1] = r
      elseif not fallback then fallback = r end
    end
  end
  if #roots == 0 and fallback then roots[1] = fallback end
  for _, r in ipairs(roots) do vim.opt.runtimepath:prepend(r) end
end
vim.opt.runtimepath:prepend(root)
vim.o.columns, vim.o.lines = 200, 60

local sb = vim.fn.tempname() .. "-adr0083"
dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/_sandbox.lua")("adr0083")

local pass, fail = 0, 0
local function ok(n, c, d)
  if c then
    pass = pass + 1
    print("  PASS  " .. n)
  else
    fail = fail + 1
    print("  FAIL  " .. n .. (d and ("  — " .. tostring(d)) or ""))
  end
end

local tree = require("auto-finder.views.repos.tree")
local logger = require("auto-finder.log")
local todo_api = require("auto-core.todo")
local todo_paths = require("auto-core.todo.paths")

-- Capture notifications
local notes = {}
local real_notify = logger.notify
logger.notify = function(msg, opts)
  table.insert(notes, { msg = tostring(msg), level = opts and opts.level })
end

local function last_note()
  return notes[#notes]
end

-- 1. Verify 'A' keymap binding in buffer
local buf = vim.api.nvim_create_buf(false, true)
tree.get_buffer(nil) -- ensure module initialized
local keymaps = vim.api.nvim_buf_get_keymap(tree.get_buffer(nil), "n")
local found_A = false
for _, km in ipairs(keymaps) do
  if km.lhs == "A" then
    found_A = true
    ok("ADR-0083: 'A' keymap bound with expected description",
      km.desc and km.desc:find("attach review", 1, true) ~= nil,
      km.desc)
    break
  end
end
ok("ADR-0083: 'A' keymap exists on repos panel buffer", found_A)

-- 2. Pressing 'A' on non-review row
notes = {}
tree.attach_review_to_task(nil)
ok("ADR-0083: nil row warns cursor must be on review row",
  last_note() and last_note().msg:find("cursor must be on a review row", 1, true) ~= nil
  and last_note().level == vim.log.levels.WARN,
  vim.inspect(notes))

notes = {}
tree.attach_review_to_task({ kind = "commit", node = { sha = "1234567" } })
ok("ADR-0083: commit row warns cursor must be on review row",
  last_note() and last_note().msg:find("cursor must be on a review row", 1, true) ~= nil
  and last_note().level == vim.log.levels.WARN,
  vim.inspect(notes))

-- 3. Review row with no path
notes = {}
tree.attach_review_to_task({ kind = "review", review = {} })
ok("ADR-0083: review row with missing path warns",
  last_note() and last_note().msg:find("review has no file path", 1, true) ~= nil
  and last_note().level == vim.log.levels.WARN,
  vim.inspect(notes))

-- 4. Review row with no in-progress tasks
local saved_list = todo_api.list
local saved_update = todo_api.update

todo_api.list = function(filter)
  ok("ADR-0083: queries tasks with status in-progress",
    filter and filter.status == "in-progress")
  return {}
end

notes = {}
tree.attach_review_to_task({
  kind = "review",
  review = { path = "/tmp/repo@abc.r1.review.json", document = "/tmp/kb/review.md" },
})
ok("ADR-0083: warns when no in-progress tasks found",
  last_note() and last_note().msg:find("no in-progress tasks found", 1, true) ~= nil
  and last_note().level == vim.log.levels.WARN,
  vim.inspect(notes))

-- 5. Selection and attachment to task
local mock_tasks = {
  { id = "task-1", title = "Task One", status = "in-progress", review = nil },
  { id = "task-2", title = "Task Two", status = "in-progress", review = { "$KB_ROOT/existing.md" } },
}
todo_api.list = function(filter)
  return mock_tasks
end

local updated_id, updated_fields
todo_api.update = function(id, fields)
  updated_id = id
  updated_fields = fields
  return true, nil
end

local real_select = vim.ui.select
local select_items, select_prompt, select_formatted = nil, nil, {}
vim.ui.select = function(items, opts, on_choice)
  select_items = items
  select_prompt = opts and opts.prompt
  if opts and opts.format_item then
    for _, it in ipairs(items) do
      table.insert(select_formatted, opts.format_item(it))
    end
  end
  -- Simulate user selecting the first task
  on_choice(items[1])
end

notes = {}
tree.attach_review_to_task({
  kind = "review",
  review = { path = "/tmp/repo@abc.r1.review.json", document = "/tmp/kb/agents/wanda/review.md" },
})

ok("ADR-0083: vim.ui.select received candidate tasks",
  select_items and #select_items == 2, vim.inspect(select_items))
ok("ADR-0083: candidate formatting is '<title> (<id>)'",
  select_formatted[1] == "Task One (task-1)" and select_formatted[2] == "Task Two (task-2)",
  vim.inspect(select_formatted))
ok("ADR-0083: update called on selected task",
  updated_id == "task-1", updated_id)
ok("ADR-0083: review list contains attached document ref",
  updated_fields and updated_fields.review and #updated_fields.review == 1
  and updated_fields.review[1]:find("review.md", 1, true) ~= nil,
  vim.inspect(updated_fields))
ok("ADR-0083: info notification on successful attach",
  last_note() and last_note().msg:find("attached review to task 'Task One'", 1, true) ~= nil
  and last_note().level == vim.log.levels.INFO,
  vim.inspect(notes))

-- 6. Attach to task with existing reviews (deduplication & append)
vim.ui.select = function(items, opts, on_choice)
  on_choice(items[2]) -- select task-2 which already has $KB_ROOT/existing.md
end

updated_id, updated_fields = nil, nil
tree.attach_review_to_task({
  kind = "review_file",
  review = { path = "/tmp/repo@abc.r1.review.json", document = "/tmp/kb/new-finding.md" },
})

ok("ADR-0083: attached to task-2 with existing reviews",
  updated_id == "task-2", updated_id)
ok("ADR-0083: existing reviews preserved and new review appended",
  updated_fields and #updated_fields.review == 2
  and updated_fields.review[1] == "$KB_ROOT/existing.md"
  and updated_fields.review[2]:find("new-finding.md", 1, true) ~= nil,
  vim.inspect(updated_fields))

-- 7. Deduplication: attaching an already attached review
local dup_ref = updated_fields.review[2]
mock_tasks[2].review = { "$KB_ROOT/existing.md", dup_ref }
updated_id, updated_fields = nil, nil

tree.attach_review_to_task({
  kind = "review",
  review = { path = "/tmp/repo@abc.r1.review.json", document = dup_ref },
})
ok("ADR-0083: duplicate attachment avoided (length unchanged)",
  updated_fields and #updated_fields.review == 2,
  vim.inspect(updated_fields))

-- 8. User cancellation (dismiss picker)
vim.ui.select = function(items, opts, on_choice)
  on_choice(nil) -- user cancelled
end
updated_id, updated_fields = nil, nil
tree.attach_review_to_task({
  kind = "review",
  review = { path = "/tmp/repo@abc.r1.review.json", document = "/tmp/kb/review.md" },
})
ok("ADR-0083: cancelling picker does not call update",
  updated_id == nil and updated_fields == nil)

-- 9. Error in update
vim.ui.select = function(items, opts, on_choice)
  on_choice(items[1])
end
todo_api.update = function(id, fields)
  return nil, "disk full"
end
notes = {}
tree.attach_review_to_task({
  kind = "review",
  review = { path = "/tmp/repo@abc.r1.review.json", document = "/tmp/kb/review.md" },
})
ok("ADR-0083: update error reported via ERROR log",
  last_note() and last_note().msg:find("failed to attach review: disk full", 1, true) ~= nil
  and last_note().level == vim.log.levels.ERROR,
  vim.inspect(notes))

-- Restore mocks
todo_api.list = saved_list
todo_api.update = saved_update
vim.ui.select = real_select
logger.notify = real_notify

vim.fn.delete(sb, "rf")
print(string.format("\n%d passed, %d failed", pass, fail))
vim.cmd(fail > 0 and "cq" or "qa!")
