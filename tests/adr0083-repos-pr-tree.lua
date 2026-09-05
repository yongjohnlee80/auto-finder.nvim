-- ADR-0083: Repos tree PR row rendering, child reviews, dissociation, and PR actions
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
local sib = vim.fn.fnamemodify(root, ":h:h")
local branch_dir = vim.fn.fnamemodify(root, ":t")
for _, p in ipairs({ LAZY .. "/nui.nvim", LAZY .. "/plenary.nvim" }) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end
for _, plugin in ipairs({ "worktree.nvim", "auto-core.nvim" }) do
  for _, wt in ipairs({ "main", branch_dir }) do
    local r = sib .. "/" .. plugin .. "/" .. wt
    if vim.fn.isdirectory(r) == 1 then vim.opt.runtimepath:prepend(r) end
  end
end
vim.opt.runtimepath:prepend(root)
vim.o.columns, vim.o.lines = 200, 60

local sb = vim.fn.tempname() .. "-adr0083-pr"
dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/_sandbox.lua")("adr0083-pr")

-- Load plugin commands
pcall(vim.cmd, "runtime plugin/auto-finder.lua")

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
local pr_mod = require("worktree.pr")

-- Capture notifications
local notes = {}
local real_notify = logger.notify
logger.notify = function(msg, opts)
  table.insert(notes, { msg = tostring(msg), level = opts and opts.level })
end

local function last_note()
  return notes[#notes]
end

-- 1. Keymap bindings in panel buffer
local pbuf = tree.get_buffer(nil)
local keymaps = vim.api.nvim_buf_get_keymap(pbuf, "n")
local km_map = {}
for _, km in ipairs(keymaps) do
  km_map[km.lhs] = km
end

ok("ADR-0083: 'O' keymap bound on repos panel", km_map["O"] ~= nil)
ok("ADR-0083: 'O' keymap describes PR diff", km_map["O"] and km_map["O"].desc:find("diff PR", 1, true) ~= nil)
ok("ADR-0083: 'P' keymap bound on repos panel", km_map["P"] ~= nil)
ok("ADR-0083: 'P' keymap describes PR feedback / push", km_map["P"] and km_map["P"].desc:find("post inline feedback", 1, true) ~= nil)
ok("ADR-0083: 'G' keymap bound on repos panel", km_map["G"] ~= nil)
ok("ADR-0083: 'G' keymap describes GetPR", km_map["G"] and km_map["G"].desc:find("GetPR", 1, true) ~= nil)
ok("ADR-0083: 'N' keymap bound on repos panel", km_map["N"] ~= nil)
ok("ADR-0083: 'N' keymap describes CreatePR", km_map["N"] and km_map["N"].desc:find("CreatePR", 1, true) ~= nil)
ok("ADR-0083: 'd' keymap describes dissociate", km_map["d"] and km_map["d"].desc:find("dissociate", 1, true) ~= nil)

-- 2. tree.HELP documentation
local help_text = table.concat(tree.HELP, "\n")
ok("ADR-0083: HELP documents 'O' keymap", help_text:find("O     diff PR across all commits", 1, true) ~= nil)
ok("ADR-0083: HELP documents 'P' keymap", help_text:find("P     post inline feedback to PR", 1, true) ~= nil)
ok("ADR-0083: HELP documents 'G' keymap", help_text:find("G     GetPR:", 1, true) ~= nil)
ok("ADR-0083: HELP documents 'N' keymap", help_text:find("N     CreatePR:", 1, true) ~= nil)

-- 3. Commands registered
local cmds = vim.api.nvim_get_commands({})
ok("ADR-0083: :AutoFinderGetPR command registered", cmds["AutoFinderGetPR"] ~= nil)
ok("ADR-0083: :AutoFinderCreatePR command registered", cmds["AutoFinderCreatePR"] ~= nil)
ok("ADR-0083: :AutoFinderPostPRFeedback command registered", cmds["AutoFinderPostPRFeedback"] ~= nil)

-- 4. Tree PR rendering with child reviews
local mock_repo = {
  label = "test-repo",
  slug = "test-repo",
  common_dir = sb .. "/test-repo.git",
  path = sb .. "/test-repo",
  url = "https://github.com/user/test-repo.git",
}
local mock_wt = {
  path = sb .. "/test-repo/wt-pr42",
  branch = "pr-42",
  head = "c1a2b3c",
  watched = true,
}
local mock_pr_open = {
  number = 42,
  title = "Add PR feature",
  state = "open",
  draft = false,
  branch = "pr-42",
  base = "main",
  author = "alice",
  kb_doc = sb .. "/shared/prs/test-repo/pr-42.md",
}
local mock_pr_review = {
  name = "test-repo@c1a2b3c.r1.review.json",
  path = sb .. "/agents/reviewer/reviews/test-repo@c1a2b3c.r1.review.json",
  document = sb .. "/agents/reviewer/reviews/2026-09-05-test-repo-c1a2b3c-r1-review.md",
  commit = "c1a2b3c000000000000000000000000000000000",
  revision = 1,
  pr = 42,
  worst = "must-fix",
}

-- Create test directories and files
vim.fn.mkdir(vim.fs.dirname(mock_pr_open.kb_doc), "p")
vim.fn.writefile({ "# PR 42", "Body content" }, mock_pr_open.kb_doc)

vim.fn.mkdir(vim.fs.dirname(mock_pr_review.path), "p")
vim.fn.writefile({
  vim.json.encode({
    schema = "worktree.review/1",
    commit = mock_pr_review.commit,
    revision = 1,
    repo = { url = mock_repo.url, owner = "user", name = "test-repo" },
    pr = 42,
    comments = {
      { path = "foo.lua", line = 10, severity = "must-fix", body = "Fix this" },
    },
  })
}, mock_pr_review.path)
vim.fn.writefile({ "# Review r1" }, mock_pr_review.document)

-- Mock backend in auto-finder
local repos_backend = {
  available = function() return true end,
  repos = function() return { mock_repo } end,
  worktrees = function(r) return { mock_wt } end,
  children = function(repo, wt, opts) return {}, {} end,
  commit_divergence = function(r, wt) return { count = 0, items = {}, meta = { mode = "window", has_more = false } } end,
  pr_for_worktree = function(r, wt) return mock_pr_open end,
  reviews_for_pr = function(r, pr_num)
    if tostring(pr_num) == "42" then return { mock_pr_review } end
    return {}
  end,
  pr_diff = function(r, base_ref, pr_ref)
    return {
      {
        sha = mock_pr_review.commit,
        short = "c1a2b3c",
        subject = "Commit 1",
      },
    }
  end,
  diff = function(r, sha)
    return {
      {
        path = "foo.lua",
        kind = "modified",
        hunks = {},
      },
    }
  end,
  reviews = function(r, sha) return {} end,
  reviews_all = function(r) return { mock_pr_review } end,
  uncommitted = function(wt) return {} end,
  working_status = function(wt) return {} end,
  commits = function(r, wt, window) return {} end,
  remove_review = function(r, path) return true end,
}

-- Inject mock backend
package.loaded["worktree.repos"] = repos_backend

-- Open panel buffer and expand repo and worktree
local tbuf = tree.get_buffer(nil)
tree._expanded["repo:" .. mock_repo.common_dir] = true
tree._expanded["wt:" .. mock_wt.path] = true
tree.invalidate(nil)
tree.on_focus(nil, tbuf)

-- Inspect rows in tree
local rows = tree._rows or {}
local found_pr_row = nil
local found_pr_review_row = nil
for _, row in ipairs(rows) do
  if row.kind == "pr" and row.pr and row.pr.number == 42 then
    found_pr_row = row
  elseif row.kind == "review" and row.parent_pr and row.parent_pr.number == 42 then
    found_pr_review_row = row
  end
end

ok("ADR-0083: PR row rendered under worktree", found_pr_row ~= nil)
ok("ADR-0083: PR row text has title and [OPEN] badge",
  found_pr_row and found_pr_row.text:find("● PR #42: Add PR feature  [OPEN]", 1, true) ~= nil,
  found_pr_row and found_pr_row.text)
ok("ADR-0083: PR row highlight is AutoCoreGitAdded",
  found_pr_row and found_pr_row.hl == "AutoCoreGitAdded")

ok("ADR-0083: PR child review row rendered under PR", found_pr_review_row ~= nil)
ok("ADR-0083: child review row carries parent_pr",
  found_pr_review_row and found_pr_review_row.parent_pr ~= nil and found_pr_review_row.parent_pr.number == 42)

-- 5. Draft and Closed badges
mock_pr_open.draft = true
tree.invalidate(nil)
tree.on_focus(nil, tbuf)
local rows_draft = tree._rows or {}
for _, row in ipairs(rows_draft) do
  if row.kind == "pr" and row.pr and row.pr.number == 42 then
    ok("ADR-0083: Draft PR badge is [DRAFT]", row.text:find("[DRAFT]", 1, true) ~= nil)
    ok("ADR-0083: Draft PR highlight is AutoCoreReviewFrame", row.hl == "AutoCoreReviewFrame")
    break
  end
end

mock_pr_open.draft = false
mock_pr_open.state = "closed"
tree.invalidate(nil)
tree.on_focus(nil, tbuf)
local rows_closed = tree._rows or {}
for _, row in ipairs(rows_closed) do
  if row.kind == "pr" and row.pr and row.pr.number == 42 then
    ok("ADR-0083: Closed PR badge is [CLOSED]", row.text:find("[CLOSED]", 1, true) ~= nil)
    ok("ADR-0083: Closed PR highlight is AutoCoreGitDeleted", row.hl == "AutoCoreGitDeleted")
    break
  end
end
mock_pr_open.state = "open"
tree.invalidate(nil)
tree.on_focus(nil, tbuf)

-- 6. Dissociation via remove_review on review with parent_pr
local confirm_called = false
local mock_float = {
  confirm = function(prompt, opts)
    confirm_called = true
    ok("ADR-0083: dissociation prompt specifies PR number and keeping disk files",
      prompt:find("Dissociate review", 1, true) ~= nil and prompt:find("from PR #42", 1, true) ~= nil
      and prompt:find("Files on disk will NOT be deleted", 1, true) ~= nil,
      prompt)
    opts.on_choice("yes")
  end
}
package.loaded["auto-core.ui.float"] = mock_float

notes = {}
tree.remove_review(found_pr_review_row)
ok("ADR-0083: float.confirm called for dissociation", confirm_called)
ok("ADR-0083: dissociation notification logged",
  last_note() and last_note().msg:find("dissociated review", 1, true) ~= nil,
  vim.inspect(notes))

-- Verify review file on disk still exists and pr field was removed
local after_raw = table.concat(vim.fn.readfile(mock_pr_review.path), "\n")
local after_data = vim.json.decode(after_raw)
ok("ADR-0083: review JSON file still exists on disk", vim.fn.filereadable(mock_pr_review.path) == 1)
ok("ADR-0083: review JSON pr field was cleared (dissociated)", after_data.pr == nil)

-- SF2 Test: review whose pr does not match reports unassociated, does NOT report success
notes = {}
tree.remove_review(found_pr_review_row)
ok("SF2: unassociated review reports refusal warning",
  last_note() and last_note().msg:find("is not associated with PR #42", 1, true) ~= nil,
  vim.inspect(notes))
local found_false_dissociated = false
for _, n in ipairs(notes) do
  if n.msg:find("dissociated review", 1, true) then found_false_dissociated = true end
end
ok("SF2: success was NOT falsely reported for unassociated review", found_false_dissociated == false)

-- SF2 Test: write failure does not report success
local orig_store_write = package.loaded["worktree.store"].write_json
package.loaded["worktree.store"].write_json = function()
  return false, "simulated disk error"
end
-- Reset pr to 42 on disk
after_data.pr = 42
vim.fn.writefile({ vim.json.encode(after_data) }, mock_pr_review.path)
notes = {}
tree.remove_review(found_pr_review_row)
ok("SF2: failed write reports error",
  last_note() and last_note().msg:find("failed to save dissociated review", 1, true) ~= nil,
  vim.inspect(notes))
found_false_dissociated = false
for _, n in ipairs(notes) do
  if n.msg:find("dissociated review", 1, true) and not n.msg:find("failed", 1, true) then
    found_false_dissociated = true
  end
end
ok("SF2: success was NOT falsely reported on write failure", found_false_dissociated == false)
package.loaded["worktree.store"].write_json = orig_store_write

-- Clean up and re-dissociate
notes = {}
tree.remove_review(found_pr_review_row)

-- 7. Open PR diff (Action 2)
local open_diff_called = false
local mock_dv = {
  open = function(opts)
    open_diff_called = true
    ok("ADR-0083: diffview title contains PR number and title",
      opts.title and opts.title:find("PR #42: Add PR feature", 1, true) ~= nil,
      opts.title)
    ok("ADR-0083: files passed to diffview have commit_sha and commit_short",
      #opts.files == 1 and opts.files[1].commit_short == "c1a2b3c",
      vim.inspect(opts.files))
    if opts.on_close then
      opts.on_close({ path = "foo.lua", idx = 1, pane = "preview", lnum = 5, col = 2 })
    end
    return {}
  end,
  current_file = function() return { commit_sha = mock_pr_review.commit, path = "foo.lua" } end,
  close = function() end,
}
package.loaded["auto-core.ui.diffview"] = mock_dv

tree.open_pr_diff(found_pr_row)
ok("ADR-0083: open_pr_diff invoked diffview.open", open_diff_called)
ok("ADR-0083: resume snapshot recorded target_kind = pr",
  tree._resume and tree._resume.target_kind == "pr" and tree._resume.pr_number == 42)

-- 8. Post PR feedback (Action 4)
local post_called = false
pr_mod.post_feedback = function(repo, pr_number, reviews, opts)
  post_called = true
  ok("ADR-0083: post_feedback called with correct pr_number", pr_number == 42)
  return { ok = true }
end

notes = {}
-- Restore review for post_feedback test
repos_backend.reviews_for_pr = function(r, pr_num)
  return { mock_pr_review }
end
tree.post_pr_feedback(found_pr_row)
ok("ADR-0083: post_pr_feedback invoked worktree.pr.post_feedback", post_called)
ok("ADR-0083: post_pr_feedback reported success",
  last_note() and last_note().msg:find("feedback posted to PR #42", 1, true) ~= nil,
  vim.inspect(notes))

-- 9. Create PR (Action 6)
local create_called = false
pr_mod.create_pr = function(repo, opts)
  create_called = true
  ok("ADR-0083: create_pr called with title", opts.title == "New Test PR")
  return { ok = true, pr = { number = 99 } }
end

local orig_input = vim.ui.input
vim.ui.input = function(opts, cb)
  if opts.prompt:find("PR Title", 1, true) then
    cb("New Test PR")
  else
    cb("Test description")
  end
end

notes = {}
tree.create_pr_for_worktree({ repo = mock_repo, worktree = mock_wt })
ok("ADR-0083: create_pr_for_worktree called worktree.pr.create_pr", create_called)
ok("ADR-0083: create_pr_for_worktree reported success",
  last_note() and last_note().msg:find("created PR #99", 1, true) ~= nil,
  vim.inspect(notes))

-- 10. Get PR (Action 1)
local get_called = false
pr_mod.fetch_and_create_worktree = function(repo, pr_number, opts)
  get_called = true
  ok("ADR-0083: fetch_and_create_worktree called with PR number", pr_number == 55)
  return { ok = true, branch = "pr-55" }
end

vim.ui.input = function(opts, cb)
  cb("55")
end

notes = {}
tree.get_pr_for_repo({ repo = mock_repo })
ok("ADR-0083: get_pr_for_repo called worktree.pr.fetch_and_create_worktree", get_called)
ok("ADR-0083: get_pr_for_repo reported success",
  last_note() and last_note().msg:find("fetched PR #55 into branch pr-55", 1, true) ~= nil,
  vim.inspect(notes))

vim.ui.input = orig_input

print(string.format("%d passed, %d failed", pass, fail))
vim.cmd(fail > 0 and "cq" or "qa!")
