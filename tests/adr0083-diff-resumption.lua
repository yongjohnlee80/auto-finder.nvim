-- ADR-0083 Phase 3: Diff Resumption & Session Persistence in auto-finder
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

local sb = vim.fn.tempname() .. "-adr0083-resume"
dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/_sandbox.lua")("adr0083-resume")

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
local dv = require("auto-core.ui.diffview")
local diff_parser = require("auto-core.git.diff")

-- Capture notifications
local notes = {}
local real_notify = logger.notify
logger.notify = function(msg, opts)
  table.insert(notes, { msg = tostring(msg), level = opts and opts.level })
end

-- Isolated test state file
local test_state_file = sb .. "/last-diff-test.json"
tree._custom_state_file = test_state_file

local wt_dir = sb .. "/test-wt"
vim.fn.mkdir(wt_dir, "p")
local repo_dir = sb .. "/test-repo/.git"
vim.fn.mkdir(repo_dir, "p")

local PATCH_MULTI = table.concat({
  "diff --git a/file1.lua b/file1.lua",
  "--- a/file1.lua",
  "+++ b/file1.lua",
  "@@ -1,3 +1,3 @@",
  " a",
  "-b",
  "+B",
  " c",
  "diff --git a/file2.lua b/file2.lua",
  "--- a/file2.lua",
  "+++ b/file2.lua",
  "@@ -1,3 +1,3 @@",
  " x",
  "-y",
  "+Y",
  " z",
}, "\n")

local SHA = "1234567890abcdef1234567890abcdef12345678"
package.loaded["worktree.repos"] = {
  available = function() return true end,
  diff = function(repo, sha) return diff_parser.parse(PATCH_MULTI) end,
  diff_working = function(wt) return diff_parser.parse(PATCH_MULTI) end,
  reviews = function() return {} end,
  repos = function()
    return {
      { slug = "test-repo", common_dir = repo_dir, path = wt_dir, sample_worktree = wt_dir }
    }
  end,
  worktrees = function(repo)
    return {
      { path = wt_dir, branch = "feat", head = SHA }
    }
  end,
}

local repo_obj = { slug = "test-repo", common_dir = repo_dir, path = wt_dir, sample_worktree = wt_dir }
local wt_obj = { path = wt_dir, branch = "feat", head = SHA }
local row = {
  kind = "commit",
  repo = repo_obj,
  worktree = wt_obj,
  node = { kind = "commit", sha = SHA, short = SHA:sub(1, 7), commit = { subject = "feat: add stuff" } },
}

-- Test 1: Open diff, switch file and line, close, verify M._resume schema
tree.open_diff(row)
ok("diffview is open", dv.is_open() == true)

local st = dv._state_for_tests()
ok("opened at file1.lua", dv.current_file() and dv.current_file().path == "file1.lua")

-- Simulate moving cursor and navigating to next file
local middle = st.float:winid("middle")
vim.api.nvim_set_current_win(middle)
vim.api.nvim_win_set_cursor(middle, { 2, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = st.float:bufnr("middle") })

-- Next file via normal mapping ]f
vim.cmd("normal ]f")
ok("navigated to file2.lua via ]f", dv.current_file() and dv.current_file().path == "file2.lua")

local prev = st.float:winid("preview")
vim.api.nvim_set_current_win(prev)
vim.api.nvim_win_set_cursor(prev, { 3, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = st.float:bufnr("preview") })

dv.close()
ok("diffview closed", dv.is_open() == false)

-- Check in-memory M._resume structure
local r = tree._resume
ok("tree._resume populated", r ~= nil)
ok("M._resume.repo_slug is test-repo", r.repo_slug == "test-repo")
ok("M._resume.common_dir matches repo", r.common_dir == repo_dir)
ok("M._resume.worktree_path matches wt", r.worktree_path == wt_dir)
ok("M._resume.target_kind is commit", r.target_kind == "commit")
ok("M._resume.sha matches commit sha", r.sha == SHA)
ok("M._resume.active_file is file2.lua", r.active_file == "file2.lua")
ok("M._resume.active_idx is 2", r.active_idx == 2)
ok("M._resume.focused_pane is preview", r.focused_pane == "preview")
ok("M._resume.file_positions recorded file1.lua", r.file_positions["file1.lua"] ~= nil)
ok("file1.lua lnum recorded as 2", r.file_positions["file1.lua"].lnum == 2)
ok("file2.lua lnum recorded as 3", r.file_positions["file2.lua"].lnum == 3)
ok("M._resume.timestamp is recent", type(r.timestamp) == "number" and (os.time() - r.timestamp) < 5)

-- Test 2: Check persistent file on disk
ok("state file exists on disk", vim.fn.filereadable(test_state_file) == 1)
local content = vim.fn.readfile(test_state_file)
local disk_data = vim.json.decode(table.concat(content, "\n"))
ok("disk data repo_slug matches", disk_data.repo_slug == "test-repo")
ok("disk data active_file matches", disk_data.active_file == "file2.lua")
ok("disk data file_positions matches", disk_data.file_positions["file2.lua"].lnum == 3)

-- Test 3: In-session resumption
tree.resume_diff()
ok("resume_diff reopened diff", dv.is_open() == true)
ok("reopened at active_file file2.lua", dv.current_file() and dv.current_file().path == "file2.lua")
local cur_win = vim.api.nvim_get_current_win()
local st_resumed = dv._state_for_tests()
ok("focused pane is preview window", cur_win == st_resumed.float:winid("preview"))
ok("restored line 3 in preview pane", vim.api.nvim_win_get_cursor(cur_win)[1] == 3)
dv.close()

-- Test 4: Cross-restart resumption (clear memory M._resume)
tree._resume = nil
ok("can_resume reports true via lazy hydration from disk", tree.can_resume() == true)
ok("M._resume hydrated from disk", tree._resume ~= nil and tree._resume.row == nil)

tree.resume_diff()
ok("cross-restart resume_diff reopened diff", dv.is_open() == true)
ok("cross-restart opened at file2.lua", dv.current_file() and dv.current_file().path == "file2.lua")
local cur_win2 = vim.api.nvim_get_current_win()
local st_resumed2 = dv._state_for_tests()
ok("cross-restart focused pane is preview window", cur_win2 == st_resumed2.float:winid("preview"))
ok("cross-restart line 3 restored", vim.api.nvim_win_get_cursor(cur_win2)[1] == 3)
dv.close()

-- Test 5: Uncommitted diff resumption
local uncommitted_row = {
  kind = "uncommitted",
  repo = repo_obj,
  worktree = wt_obj,
  node = { kind = "uncommitted" },
}
tree.open_diff(uncommitted_row)
ok("uncommitted diff opened", dv.is_open() == true)
dv.close()

ok("uncommitted target_kind recorded", tree._resume.target_kind == "uncommitted")
ok("uncommitted sha is nil", tree._resume.sha == nil)

-- Reopen uncommitted via resume_diff across simulated restart
tree._resume = nil
ok("can_resume is true for uncommitted", tree.can_resume() == true)
tree.resume_diff()
ok("uncommitted resumed successfully", dv.is_open() == true)
dv.close()

-- Test 6: Stale/missing repository or worktree gracefully clears
tree._resume = nil
local stale_payload = {
  repo_slug = "stale-repo",
  common_dir = sb .. "/missing-repo/.git",
  worktree_path = sb .. "/missing-wt",
  target_kind = "commit",
  sha = SHA,
  active_file = "file1.lua",
  active_idx = 1,
  focused_pane = "preview",
  file_positions = {},
  timestamp = os.time(),
}
require("auto-core.fs.atomic").write(test_state_file, vim.json.encode(stale_payload), { mkdir = true })

notes = {}
tree.resume_diff()
ok("resume_diff did not open diff for missing repo/worktree", dv.is_open() == false)
ok("stale target warning emitted", notes[#notes] and notes[#notes].msg:find("no longer exists") ~= nil,
  notes[#notes] and notes[#notes].msg)
ok("M._resume cleared after stale detection", tree._resume == nil)
ok("stale state file deleted", vim.fn.filereadable(test_state_file) == 0)
ok("can_resume returns false after stale cleanup", tree.can_resume() == false)

-- Test 7: SF1 — Stale commit diff (repo/worktree exist, but commit has no diff / rebased / amended)
tree._resume = nil
local stale_commit_payload = {
  repo_slug = "test-repo",
  common_dir = repo_dir,
  worktree_path = wt_dir,
  target_kind = "commit",
  sha = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
  active_file = "file1.lua",
  active_idx = 1,
  focused_pane = "preview",
  file_positions = {},
  timestamp = os.time(),
}
require("auto-core.fs.atomic").write(test_state_file, vim.json.encode(stale_commit_payload), { mkdir = true })

-- Mock diff returning empty for deadbeef
local orig_diff = package.loaded["worktree.repos"].diff
package.loaded["worktree.repos"].diff = function(repo, sha)
  if sha:find("deadbeef") then return {} end
  return orig_diff(repo, sha)
end

ok("can_resume reports true before invocation", tree.can_resume() == true)
notes = {}
local res_ok, res_err = tree.resume_diff()
ok("SF1: resume_diff returns false on dead commit diff", res_ok == false)
local found_no_diff = false
local found_stale_cleared = false
for _, n in ipairs(notes) do
  if n.msg:find("no diff for") then found_no_diff = true end
  if n.msg:find("stale; cleared resume state") then found_stale_cleared = true end
end
ok("SF1: no diff warning logged for dead commit", found_no_diff)
ok("SF1: stale cleared warning logged", found_stale_cleared)
ok("SF1: M._resume cleared after dead commit detection", tree._resume == nil)
ok("SF1: stale state file removed from disk", vim.fn.filereadable(test_state_file) == 0)
ok("SF1: can_resume returns false after dead commit cleanup", tree.can_resume() == false)
package.loaded["worktree.repos"].diff = orig_diff

-- Test 8: N1 — Empty or truncated payload validation in _hydrate_resume
tree._resume = nil
require("auto-core.fs.atomic").write(test_state_file, "{}", { mkdir = true })
ok("N1: can_resume returns false for empty {} state file", tree.can_resume() == false)

require("auto-core.fs.atomic").write(test_state_file, '{"repo_slug":"foo"}', { mkdir = true })
ok("N1: can_resume returns false when target_kind is missing", tree.can_resume() == false)

require("auto-core.fs.atomic").write(test_state_file, '{"repo_slug":"foo","target_kind":"commit"}', { mkdir = true })
ok("N1: can_resume returns false when commit sha is missing", tree.can_resume() == false)
pcall(vim.fn.delete, test_state_file)

print(("\nTotal: %d passed, %d failed"):format(pass, fail))
if fail > 0 then vim.cmd("cquit 1") else vim.cmd("qall!") end
