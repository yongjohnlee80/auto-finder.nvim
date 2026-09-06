-- ADR-0083 Phase 3: Diff Resumption & Session Persistence in auto-finder
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

local sb = vim.fn.tempname() .. "-adr0083-fullctx"
dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/_sandbox.lua")("adr0083-fullctx")

-- ADR-0083 §2.4 — the full-context toggle must RENDER full context.
--
-- `auto-core.git.diff._sides_full` can only read a file's whole text when the
-- caller hands it a worktree plus a revision. `M.open_diff` did not pass either,
-- so `_sides_full` fell through its `if not blines and not alines` guard and
-- returned the HUNK render — while the footer still said `[context: full]`.
-- The label observed nothing. This suite drives the real keystroke against a
-- real git repo so the rendered row count, not the state flag, is the witness.

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
local dv = require("auto-core.ui.diffview")
local diff_parser = require("auto-core.git.diff")

-- ── a REAL git repo: _sides_full shells out to `git show <rev>:<path>` ──
local repo = sb .. "/fullctx-repo"
vim.fn.mkdir(repo, "p")
local function git(...)
  local args = { "git", "-C", repo, ... }
  local r = vim.system(args, { text = true }):wait()
  if r.code ~= 0 then error("git " .. table.concat({ ... }, " ") .. " failed: " .. tostring(r.stderr)) end
  return vim.trim(r.stdout or "")
end
git("init", "-q", "-b", "main")
git("config", "user.email", "test@example.com")
git("config", "user.name", "test")

-- 40 lines, so two edits far apart leave a gap no 3-line context can bridge.
local base = {}
for i = 1, 40 do base[i] = "line " .. i end
vim.fn.writefile(base, repo .. "/wide.lua")
git("add", "wide.lua")
git("commit", "-q", "-m", "base")

local edited = vim.deepcopy(base)
edited[2] = "line 2 CHANGED"
edited[38] = "line 38 CHANGED"
vim.fn.writefile(edited, repo .. "/wide.lua")
git("add", "wide.lua")
git("commit", "-q", "-m", "two distant edits")
local SHA = git("rev-parse", "HEAD")

local raw = vim.system({ "git", "-C", repo, "show", "-p", "-m", "--first-parent",
  "--no-color", SHA }, { text = true }):wait().stdout
local parsed = diff_parser.parse(vim.split(raw, "\n", { plain = true }))

package.loaded["worktree.repos"] = {
  available = function() return true end,
  diff = function() return diff_parser.parse(vim.split(raw, "\n", { plain = true })) end,
  diff_working = function() return {} end,
  reviews = function() return {} end,
  reviews_all = function() return {} end,
  repos = function() return { { slug = "fullctx", common_dir = repo .. "/.git",
    path = repo, sample_worktree = repo } } end,
  worktrees = function() return { { path = repo, branch = "main", head = SHA } } end,
}

local row = {
  kind = "commit",
  repo = { slug = "fullctx", common_dir = repo .. "/.git", path = repo, sample_worktree = repo },
  worktree = { path = repo, branch = "main", head = SHA },
  node = { kind = "commit", sha = SHA, short = SHA:sub(1, 7),
           commit = { subject = "two distant edits" } },
}

-- ── baseline: the fixture must actually HAVE a gap ──────────────────
-- A file whose hunk render already covers every line would make every
-- assertion below pass while observing nothing.
ok("fixture parsed one file", #parsed == 1, "#parsed=" .. tostring(#parsed))
ok("fixture has two distant hunks", parsed[1] and #(parsed[1].hunks or {}) == 2,
  "hunks=" .. tostring(parsed[1] and #(parsed[1].hunks or {})))

local opened = tree.open_diff(row)
ok("diffview opened", opened == true and dv.is_open() == true)

local st = dv._state_for_tests()
local middle = st.float:winid("middle")
local mbuf = st.float:bufnr("middle")
local hunk_rows = vim.api.nvim_buf_line_count(mbuf)
ok("hunk render is narrower than the file (gap exists)", hunk_rows < 40,
  "hunk_rows=" .. tostring(hunk_rows))

-- ── the defect: press X, the real key the user presses ──────────────
vim.api.nvim_set_current_win(middle)
vim.cmd("normal X")

local st2 = dv._state_for_tests()
ok("X flipped the context flag to full", st2.context == "full",
  "context=" .. tostring(st2.context))

local full_rows = vim.api.nvim_buf_line_count(st2.float:bufnr("middle"))
ok("X RENDERS full context (>= every line of the file)", full_rows >= 40,
  "full_rows=" .. tostring(full_rows) .. " hunk_rows=" .. tostring(hunk_rows))
ok("full render is strictly larger than the hunk render", full_rows > hunk_rows,
  "full_rows=" .. tostring(full_rows) .. " hunk_rows=" .. tostring(hunk_rows))

-- ── open_diff must hand the view what _sides_full needs ─────────────
ok("open_diff passed worktree through", st2.worktree ~= nil and st2.worktree ~= "",
  "worktree=" .. tostring(st2.worktree))
ok("open_diff passed sha through", st2.sha == SHA,
  "sha=" .. tostring(st2.sha))

dv.close("test")

-- ── §2 a PR row with NO worktree must still resolve a directory ──────
-- `pr_for_worktree` matches on branch name, so the tree renders PR rows for
-- PRs whose branch was never checked out here. `wt.path or nil` then handed
-- the view nothing and full context died the same silent death.
local backend = package.loaded["worktree.repos"]
backend.pr_diff = function()
  return { { sha = SHA, short = SHA:sub(1, 7), subject = "two distant edits" } }
end
backend.reviews_for_pr = function() return {} end
backend.resolve_base = function() return "main" end

local pr_row = {
  kind = "pr",
  repo = { slug = "fullctx", common_dir = repo .. "/.git", path = repo, sample_worktree = repo },
  worktree = nil,   -- the case that broke
  pr = { number = 42, title = "distant edits", state = "open",
         base = "main", branch = "main" },
}

local pr_ok = tree.open_pr_diff(pr_row, { context = "full" })
ok("PR diff opened without a worktree", pr_ok == true and dv.is_open() == true)

local pst = dv._state_for_tests()
ok("PR path fell back to the repo checkout", pst and pst.worktree == repo,
  "worktree=" .. tostring(pst and pst.worktree))
ok("PR path carries a revision floor", pst and pst.sha == SHA,
  "sha=" .. tostring(pst and pst.sha))

local pr_rows = pst and vim.api.nvim_buf_line_count(pst.float:bufnr("middle")) or 0
ok("PR diff renders full context when asked for it", pr_rows >= 40,
  "pr_rows=" .. tostring(pr_rows))

dv.close("test")

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then vim.cmd("cq") else vim.cmd("q") end
