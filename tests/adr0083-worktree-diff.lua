-- The Git Diff View over a WORKTREE's branch (Johno, 2026-09-08).
--
-- "let's allow opening diff_view on worktree as well in addition to PR
--  diff_view. This will work the same way as PR diff_view, grouping file
--  changes with commits. Of course since the changes are diff from the based
--  branch, so main branch will not open this diff_view naturally, the title
--  should indicate that as well such as {worktree name} -> {target branch}.
--  Let's assign "O" key on the worktree or branch to open the diff_view."
--
-- Built on a REAL bare-ish git layout, not a mocked backend: the whole
-- question is which commits `<base>..<branch>` resolves to, and a stubbed
-- `pr_diff` would answer it by construction. Only `auto-core.ui.diffview` is
-- mocked, so what the panel HANDS the renderer can be read off directly.
--
-- Run headless:  nvim --headless -u NONE -l tests/adr0083-worktree-diff.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
local sib = vim.fn.fnamemodify(root, ":h:h")
local branch_dir = vim.fn.fnamemodify(root, ":t")
for _, p in ipairs({ LAZY .. "/nui.nvim", LAZY .. "/plenary.nvim" }) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end
-- A sibling candidate must be able to SERVE the request, not merely exist: a
-- stale checkout shadows a current one because the LAST prepend wins, and the
-- suite then aborts mid-run instead of reporting a count. Same guard the
-- other ADR-0083 suites carry, for the same reason.
for _, plugin in ipairs({ "worktree.nvim", "auto-core.nvim" }) do
  local req = ({
    ["worktree.nvim"]  = { "lua/worktree/repos.lua", "function M.base_branch" },
    ["auto-core.nvim"] = { "lua/auto-core/docstore/init.lua", "function M.write_json" },
  })[plugin]
  local function serves(r)
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

local sb = vim.fn.tempname() .. "-adr0083-wtdiff"
dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/_sandbox.lua")("adr0083-wtdiff")
pcall(vim.cmd, "runtime plugin/auto-finder.lua")

local pass, fail = 0, 0
local function ok(n, c, d)
  if c then pass = pass + 1; print("  PASS  " .. n)
  else fail = fail + 1; print("  FAIL  " .. n .. (d and ("  — " .. tostring(d)) or "")) end
end

-- ─── a real layout: base `trunk`, a diverged `feature`, and a detached one ──
--
-- The base branch is deliberately NOT called "main". `base_branch` used to be
-- asked for through `backend.resolve_base`, a function worktree.nvim has never
-- exported — so the guarded call never ran and every repo silently defaulted
-- to the literal "main". On a repo whose base IS main that bug is invisible.
local lab = sb .. "/lab"; vim.fn.mkdir(lab, "p")
local function G(dir, ...)
  local a = { "git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t" }
  for _, x in ipairs({ ... }) do a[#a + 1] = x end
  return vim.system(a, {}):wait().code
end

local proj = lab .. "/proj"; vim.fn.mkdir(proj, "p")
G(proj, "init", "-q", "-b", "trunk")
vim.fn.writefile({ "base" }, proj .. "/a.txt")
G(proj, "add", "."); G(proj, "commit", "-q", "-m", "base one")

-- `feature` adds TWO commits touching different files, so "grouping file
-- changes with commits" has something to group.
G(proj, "worktree", "add", "-q", "-b", "feature", lab .. "/feature")
local fwt = lab .. "/feature"
vim.fn.writefile({ "one" }, fwt .. "/first.txt")
G(fwt, "add", "."); G(fwt, "commit", "-q", "-m", "add first")
vim.fn.writefile({ "two" }, fwt .. "/second.txt")
vim.fn.writefile({ "edited" }, fwt .. "/a.txt")
G(fwt, "add", "."); G(fwt, "commit", "-q", "-m", "add second and edit a")

local store = require("worktree.store")
store._root_override = sb .. "/wtstore"
require("worktree.watch")._reset_for_tests()
require("worktree.repos")._reset_for_tests()
require("worktree").set_root(lab)

local tree = require("auto-finder.views.repos.tree")
local logger = require("auto-finder.log")
local backend = require("worktree.repos")
ok("precondition: the repos backend is available", backend.available() == true)

local notes = {}
logger.notify = function(msg, opts)
  table.insert(notes, { msg = tostring(msg), level = opts and opts.level })
end
local function noted(s)
  for _, n in ipairs(notes) do
    if n.msg:find(s, 1, true) then return n end
  end
  return nil
end

local repos = backend.repos(lab)
local repo = repos[1]
ok("precondition: one repo discovered", repo ~= nil and repo.common_dir ~= nil,
  vim.inspect(repos))

local wt_by_branch = {}
for _, w in ipairs(backend.worktrees(repo)) do
  wt_by_branch[w.branch or w.path] = w
end
ok("precondition: both worktrees are listed",
  wt_by_branch["trunk"] ~= nil and wt_by_branch["feature"] ~= nil,
  vim.inspect(vim.tbl_keys(wt_by_branch)))
ok("precondition: the base branch is `trunk`, NOT the literal \"main\"",
  backend.base_branch(repo) == "trunk", tostring(backend.base_branch(repo)))
ok("precondition: the backend marks trunk as the base worktree",
  wt_by_branch["trunk"].is_base == true)

-- ─── the mocked renderer ────────────────────────────────────────────────────
local captured = nil
local mock_dv = {
  open = function(opts)
    captured = opts
    if opts.on_close then
      opts.on_close({ path = "first.txt", idx = 1, pane = "preview", lnum = 3, col = 1 })
    end
    return { mock = true }
  end,
  current_file = function() return nil end,
  close = function() end,
}
package.loaded["auto-core.ui.diffview"] = mock_dv

local function row_for(branch)
  return { kind = "worktree", repo = repo, worktree = wt_by_branch[branch] }
end

-- ─── [1] the happy path ─────────────────────────────────────────────────────

print("\n[1] a diverged worktree opens the Git Diff View over base..branch")
do
  captured, notes = nil, {}
  local okr, float = tree.open_worktree_diff(row_for("feature"))
  ok("[1] it reports success and returns the float",
    okr == true and float ~= nil, tostring(okr))
  ok("[1] the renderer was actually invoked", captured ~= nil)

  -- Johno: "the title should indicate that as well such as {worktree name} ->
  -- {target branch}". Both halves asserted, and the ARROW between them, so a
  -- title naming only the branch cannot pass.
  ok("[1] *** the title reads {worktree} -> {base} ***",
    captured ~= nil and captured.title:find("feature → trunk", 1, true) ~= nil,
    captured and captured.title or "nil")
  ok("[1] *** and carries the panel's formal name, Git Diff View ***",
    captured ~= nil and captured.title:find("Git Diff View", 1, true) ~= nil,
    captured and captured.title or "nil")
  ok("[1] the formal name is exported for consumers to read",
    tree.PANEL_TITLE == "Git Diff View", tostring(tree.PANEL_TITLE))

  -- "grouping file changes with commits": every file carries the commit it
  -- came from, which is what the diff view groups on.
  local shas, subjects, paths = {}, {}, {}
  for _, f in ipairs(captured and captured.files or {}) do
    shas[f.commit_sha or "?"] = true
    subjects[f.commit_subject or "?"] = true
    paths[f.new_path or f.path] = true
  end
  ok("[1] *** exactly the two commits the branch adds are represented ***",
    vim.tbl_count(shas) == 2, vim.inspect(vim.tbl_keys(shas)))
  ok("[1] *** every changed file is tagged with its commit's subject ***",
    subjects["add first"] == true and subjects["add second and edit a"] == true,
    vim.inspect(vim.tbl_keys(subjects)))
  ok("[1] the files are the ones the branch actually touched",
    paths["first.txt"] and paths["second.txt"] and paths["a.txt"],
    vim.inspect(vim.tbl_keys(paths)))
  -- The base commit is NOT in the range. Without this, a diff built from
  -- `git log <branch>` rather than `<base>..<branch>` would pass everything
  -- above and show the whole history.
  ok("[1] *** the base branch's own commit is NOT in the range ***",
    subjects["base one"] == nil, vim.inspect(vim.tbl_keys(subjects)))
  ok("[1] every file carries a short sha for the group header", (function()
    for _, f in ipairs(captured.files) do
      if type(f.commit_short) ~= "string" or #f.commit_short ~= 7 then return false end
    end
    return #captured.files > 0
  end)())

  -- The worktree directory has to reach the renderer: whole-file context is
  -- read with `git show <rev>:<path>` and needs somewhere to run.
  ok("[1] the worktree path is handed over for whole-file context",
    captured.worktree == fwt, tostring(captured.worktree))

  -- The offset that makes this panel tellable apart from the Agent Edits
  -- Queue. Asserted as VALUES, in the direction opposite auto-agents'.
  ok("[1] *** the panel is offset down and right, away from the Agent Edits Queue ***",
    captured.row_offset == 2 and captured.col_offset == 6,
    ("row=%s col=%s"):format(tostring(captured.row_offset), tostring(captured.col_offset)))

  ok("[1] a submit key is attached, as on the PR path", (function()
    for _, k in ipairs(captured.keymaps or {}) do
      if k.key == "s" then return true end
    end
    return false
  end)())
end

-- ─── [2] the resume snapshot ────────────────────────────────────────────────

print("\n[2] closing records a resumable worktree diff")
do
  ok("[2] *** the resume snapshot records target_kind = worktree ***",
    tree._resume ~= nil and tree._resume.target_kind == "worktree",
    tree._resume and vim.inspect(tree._resume.target_kind) or "nil")
  ok("[2] it records the worktree path it was opened on",
    tree._resume and tree._resume.worktree_path == fwt,
    tree._resume and tostring(tree._resume.worktree_path) or "nil")
  ok("[2] and a sha, which is what _hydrate_resume validates on",
    tree._resume and type(tree._resume.sha) == "string" and tree._resume.sha ~= "")
  ok("[2] it carries no PR number, because there is no PR",
    tree._resume and tree._resume.pr_number == nil)
  ok("[2] the reader's position survives",
    tree._resume and tree._resume.active_file == "first.txt"
      and tree._resume.focused_pane == "preview",
    tree._resume and vim.inspect(tree._resume.active_file) or "nil")

  -- can_resume is what the <C-g> modal probes to decide whether to offer the
  -- entry at all, so a worktree diff has to satisfy it like a PR diff does.
  ok("[2] *** can_resume() is true after a worktree diff ***", tree.can_resume() == true)

  -- And resuming dispatches back to the WORKTREE path, not to the
  -- single-commit `open_diff`. Before this branch, `target_kind` fell through
  -- the else arm and reopened one commit's diff instead of the range.
  captured, notes = nil, {}
  local okres = tree.resume_diff()
  ok("[2] *** resume_diff reopens the RANGE, not a single commit ***",
    okres == true and captured ~= nil
      and captured.title:find("feature → trunk", 1, true) ~= nil,
    captured and captured.title or ("resume=" .. tostring(okres)))
end

-- ─── [3] the base branch declines, and says why ─────────────────────────────

print("\n[3] the base branch has nothing to diff against")
do
  captured, notes = nil, {}
  local okr, err = tree.open_worktree_diff(row_for("trunk"))
  ok("[3] *** the base worktree declines ***", okr == false, tostring(okr))
  ok("[3] the renderer was never invoked", captured == nil)
  -- Johno: "main branch will not open this diff_view naturally". The reason
  -- matters: `trunk..trunk` is empty, so without this branch the panel would
  -- report "adds no commits", which reads like a failure rather than the
  -- tautology it is.
  ok("[3] *** and says it IS the base branch, naming it ***",
    noted("trunk IS the base branch") ~= nil, vim.inspect(notes))
  ok("[3] the error is identified, not just a message",
    err == "worktree is the base branch", tostring(err))

  -- The same decision from a worktree object that has no `is_base` field —
  -- the resume path builds one from a path alone. A check that only read
  -- `is_base` would open an empty `trunk..trunk` here.
  captured, notes = nil, {}
  local bare_row = {
    kind = "worktree", repo = repo,
    worktree = { path = proj, branch = "trunk" },  -- no is_base
  }
  local okr2 = tree.open_worktree_diff(bare_row)
  ok("[3] *** a worktree object WITHOUT is_base is still recognised as the base ***",
    okr2 == false and captured == nil and noted("IS the base branch") ~= nil,
    vim.inspect(notes))
end

-- ─── [4] degenerate worktrees ───────────────────────────────────────────────

print("\n[4] worktrees that cannot be diffed refuse clearly")
do
  captured, notes = nil, {}
  local okr, err = tree.open_worktree_diff({ kind = "worktree", repo = repo })
  ok("[4] a row with no worktree refuses", okr == false and err == "no worktree")
  ok("[4] and says where the cursor should be",
    noted("put the cursor on a worktree") ~= nil, vim.inspect(notes))

  -- A worktree with neither branch nor head cannot name a range. It must say
  -- so rather than resolve `trunk..nil` into the whole history.
  captured, notes = nil, {}
  local okr2, err2 = tree.open_worktree_diff({
    kind = "worktree", repo = repo,
    worktree = { path = lab .. "/ghost" },
  })
  ok("[4] *** a worktree with no branch or HEAD refuses rather than guessing ***",
    okr2 == false and err2 == "no head" and captured == nil,
    tostring(err2))

  -- A branch that is level with its base adds nothing. Distinct from the base
  -- branch itself: this one is a real, separate branch that simply has no
  -- commits of its own yet, and the message names both sides.
  G(proj, "branch", "level", "trunk")
  G(proj, "worktree", "add", "-q", lab .. "/level", "level")
  require("worktree.repos")._reset_for_tests()
  local lvl
  for _, w in ipairs(backend.worktrees(repo)) do
    if w.branch == "level" then lvl = w end
  end
  captured, notes = nil, {}
  local okr3 = tree.open_worktree_diff({ kind = "worktree", repo = repo, worktree = lvl })
  ok("[4] *** a branch level with its base reports adding no commits ***",
    okr3 == false and captured == nil
      and noted("adds no commits on top of trunk") ~= nil,
    vim.inspect(notes))
end

-- ─── [5] the `O` key dispatches by row kind, for real ───────────────────────
--
-- The keymap description is asserted in adr0083-repos-pr-tree.lua, but a
-- description is a proxy. This runs the callback the panel actually bound.

print("\n[5] O on a worktree row opens the worktree diff")
do
  local pbuf = tree.get_buffer(nil)

  -- `_row_under_cursor` reads the cursor of the window the keymaps were BOUND
  -- with, not the current window — so the panel window has to exist before
  -- the binding. `on_focus` is the real entry point for that: it rebinds and
  -- repaints, exactly as focusing the panel does.
  tree._expanded["repo:" .. repo.common_dir] = true
  local win = vim.api.nvim_open_win(pbuf, false, {
    relative = "editor", row = 0, col = 0, width = 80, height = 40,
  })
  tree.on_focus(win, pbuf)

  local km
  for _, k in ipairs(vim.api.nvim_buf_get_keymap(pbuf, "n")) do
    if k.lhs == "O" then km = k end
  end
  ok("[5] O is bound on the repos panel", km ~= nil and type(km.callback) == "function")

  local target_line = nil
  for i, r in ipairs(tree._rows or {}) do
    if r.kind == "worktree" and r.worktree and r.worktree.branch == "feature" then
      target_line = i
    end
  end
  ok("[5] a `feature` worktree row is rendered", target_line ~= nil,
    vim.inspect(vim.tbl_map(function(r) return r.kind end, tree._rows or {})))

  if target_line and km then
    vim.api.nvim_win_set_cursor(win, { target_line, 0 })
    captured, notes = nil, {}
    local okcb, cberr = pcall(km.callback)
    ok("[5] the callback ran without error", okcb, tostring(cberr))
    ok("[5] *** pressing O on the worktree row opened the RANGE diff ***",
      captured ~= nil and captured.title:find("feature → trunk", 1, true) ~= nil,
      captured and captured.title or vim.inspect(notes))

    -- And O on the BASE worktree row declines through the same key, so the
    -- dispatch is not merely "any worktree row opens something".
    local base_line = nil
    for i, r in ipairs(tree._rows or {}) do
      if r.kind == "worktree" and r.worktree and r.worktree.branch == "trunk" then
        base_line = i
      end
    end
    if base_line then
      vim.api.nvim_win_set_cursor(win, { base_line, 0 })
      captured, notes = nil, {}
      pcall(km.callback)
      ok("[5] *** O on the base worktree row declines, through the same key ***",
        captured == nil and noted("IS the base branch") ~= nil, vim.inspect(notes))
    else
      ok("[5] *** O on the base worktree row declines, through the same key ***",
        false, "no trunk row rendered")
    end
  else
    ok("[5] the callback ran without error", false, "not staged")
    ok("[5] *** pressing O on the worktree row opened the RANGE diff ***", false,
      "could not stage the row under the cursor")
    ok("[5] *** O on the base worktree row declines, through the same key ***", false,
      "could not stage the row under the cursor")
  end
  pcall(vim.api.nvim_win_close, win, true)
end

vim.fn.delete(sb, "rf")
io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
