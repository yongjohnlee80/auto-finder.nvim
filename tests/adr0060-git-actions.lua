-- tests/adr0060-git-actions.lua — repos panel git actions (f / s / c / P).
--
-- Run:  nvim --headless -u NONE -l tests/adr0060-git-actions.lua
--
-- These test the PANEL's share of the feature and nothing else. The git
-- behaviour lives in auto-core (tests/git_write.lua, against a real repo) and
-- the verbs in worktree.nvim (smoke [10g]); what is left here is the part this
-- layer actually owns: which verb a row implies, that the outward-facing one is
-- confirmed, and that every failure arrives as a notification rather than a
-- keymap traceback (ADR-0060 r1 SF2).

-- XDG isolation FIRST, before anything can touch stdpath(). The runner's
-- preflight enforces this per suite, which is what keeps a headless run from
-- writing into the real config/state dirs.
-- ONE LINE deliberately: run-all's preflight matches `dofile(...)(` anchored at
-- start-of-line, so a wrapped call reads as absent. (The helper's own docstring
-- shows the wrapped form, which would not satisfy that check either.)
dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/_sandbox.lua")("adr0060-git-actions")

local this = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local plugin_root = vim.fn.fnamemodify(this, ":h")
local plugins_root = vim.fn.fnamemodify(plugin_root, ":h:h")
local branch_dir = vim.fn.fnamemodify(plugin_root, ":t")
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
-- Ascending priority (prepend reverses): the same-branch auto-core sibling wins
-- over `main`, because this change spans both repos and `main` has none of the
-- new primitives.
for _, p in ipairs({
  LAZY .. "/nui.nvim", LAZY .. "/plenary.nvim",
  plugins_root .. "/auto-core.nvim/main",
  plugins_root .. "/auto-core.nvim/" .. branch_dir,
  plugins_root .. "/worktree.nvim/main",
  plugins_root .. "/worktree.nvim/" .. branch_dir,
  plugin_root,
}) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end
vim.o.swapfile = false

local pass, fail = 0, 0
local function ok(name, cond, detail)
  local line = cond and ("  PASS  " .. name)
    or ("  FAIL  " .. name .. (detail and ("  — " .. tostring(detail)) or ""))
  io.stdout:write(line:gsub("[\r\n]+", " "), "\n"); io.stdout:flush()
  if cond then pass = pass + 1 else fail = fail + 1 end
end

io.stdout:write("ADR-0060 — repos panel git actions\n")

local tree = require("auto-finder.views.repos.tree")

-- Capture notifications: the acceptance criterion is that failures surface as
-- messages, so the messages ARE the observable.
local notes = {}
local logger = require("auto-finder.log")
local orig_notify = logger.notify
logger.notify = function(msg, opts) notes[#notes + 1] = { msg = msg, opts = opts } end
local function last() return notes[#notes] and notes[#notes].msg or "" end
local function reset() notes = {} end

-- ── [1] every handler exists and is bound ────────────────────────────
;(function()
  for _, fn in ipairs({ "git_fetch", "git_stage_toggle", "git_commit", "git_push" }) do
    ok("[1] " .. fn .. " is exported", type(tree[fn]) == "function")
  end
  -- The keys must be BOUND, not merely implemented. `_apply_keymaps` is local,
  -- so assert against the source: an unbound key is invisible to any test that
  -- calls the handler directly.
  local src = table.concat(vim.fn.readfile(
    plugin_root .. "/lua/auto-finder/views/repos/tree.lua"), "\n")
  for key, fn in pairs({ f = "git_fetch", s = "git_stage_toggle",
                         c = "git_commit", P = "git_push" }) do
    ok("[1] `" .. key .. "` is bound to " .. fn,
      src:find('set("' .. key .. '", function() M.' .. fn, 1, true) ~= nil)
  end
end)()

-- ── [2] a wrong row is a message, never a traceback ──────────────────
;(function()
  reset()
  ok("[2] fetch on nothing does not raise", pcall(tree.git_fetch, nil))
  ok("[2] and says where the cursor belongs",
    last():find("put the cursor on a repository", 1, true) ~= nil, last())

  reset()
  ok("[2] stage on nothing does not raise", pcall(tree.git_stage_toggle, nil))
  ok("[2] and says so", last():find("changed file", 1, true) ~= nil, last())

  reset()
  -- A file row that is NOT under UNCOMMITTED must be refused: staging a file
  -- from a historical commit is meaningless.
  ok("[2] stage on a commit's file does not raise",
    pcall(tree.git_stage_toggle, {
      kind = "file", file = { path = "x", x = " ", y = "M" },
      worktree = { path = "/tmp/x" }, node = { kind = "commit", sha = "abc" },
    }))
  ok("[2] and it explains only UNCOMMITTED can be staged",
    last():find("only files under UNCOMMITTED", 1, true) ~= nil, last())

  reset()
  ok("[2] push on nothing does not raise", pcall(tree.git_push, nil))
  ok("[2] and asks for a repository row",
    last():find("put the cursor on a repository", 1, true) ~= nil, last())

  reset()
  ok("[2] commit on nothing does not raise", pcall(tree.git_commit, nil))
  ok("[2] and asks for a worktree",
    last():find("worktree", 1, true) ~= nil, last())
end)()

-- ── [3] `s` picks its direction from git's index column ──────────────
;(function()
  -- The whole point of rendering BOTH porcelain columns: `x` is the staged
  -- side, so it — not `y` — decides whether `s` stages or unstages.
  local calls = {}
  -- `available()` is mandatory: `_repos()` refuses a backend without it, which
  -- is the version-skew gate. A mock missing it is refused too — as the first
  -- version of this test discovered.
  local backend = { available = function() return true end,
                    stage = function(...) calls[#calls + 1] = { "stage", ... } end,
                    unstage = function(...) calls[#calls + 1] = { "unstage", ... } end }
  package.loaded["worktree.repos"] = backend

  local function row(x, y)
    return { kind = "file", file = { path = "f.txt", x = x, y = y },
             worktree = { path = "/tmp/wt" }, node = { kind = "uncommitted" } }
  end
  local cases = {
    { "??", "stage",   "untracked" },
    { " M", "stage",   "modified, not staged" },
    { "M ", "unstage", "staged" },
    { "MM", "unstage", "staged AND modified again" },
    { "A ", "unstage", "added to the index" },
  }
  for _, c in ipairs(cases) do
    calls = {}
    tree.git_stage_toggle(row(c[1]:sub(1, 1), c[1]:sub(2, 2)))
    ok("[3] `" .. c[1] .. "` (" .. c[3] .. ") -> " .. c[2],
      #calls == 1 and calls[1][1] == c[2],
      vim.inspect(vim.tbl_map(function(x) return x[1] end, calls)))
  end
  package.loaded["worktree.repos"] = nil
end)()

-- ── [4] push CONFIRMS, and a refusal does not publish ────────────────
;(function()
  local pushed = 0
  package.loaded["worktree.repos"] = { available = function() return true end,
                                       push = function() pushed = pushed + 1 end }
  local asked = nil
  local orig_select = vim.ui.select
  local orig_float = package.loaded["auto-core.ui.float"]
  -- Force the fallback path so the assertion does not depend on which
  -- confirm primitive is present.
  package.loaded["auto-core.ui.float"] = { confirm = nil }
  vim.ui.select = function(items, opts, cb) asked = opts and opts.prompt; cb("no") end

  local repo_row = { kind = "repo", repo = { label = "myrepo", common_dir = "/x/.git" } }
  tree.git_push(repo_row)
  ok("[4] push asks before publishing", asked ~= nil, tostring(asked))
  ok("[4] and the prompt NAMES the repository",
    asked and asked:find("myrepo", 1, true) ~= nil, tostring(asked))
  ok("[4] answering no does NOT push", pushed == 0, pushed)

  vim.ui.select = function(items, opts, cb) cb("yes") end
  tree.git_push(repo_row)
  ok("[4] answering yes pushes exactly once", pushed == 1, pushed)

  -- The dangerous default: if the confirm surface is unavailable, a push must
  -- still be gated rather than proceeding unasked.
  local prompted = false
  vim.ui.select = function(_, opts, cb) prompted = true; cb(nil) end
  tree.git_push(repo_row)
  ok("[4] with no answer at all, nothing is published", pushed == 1, pushed)
  ok("[4] and it still prompted rather than assuming yes", prompted)

  vim.ui.select = orig_select
  package.loaded["auto-core.ui.float"] = orig_float
  package.loaded["worktree.repos"] = nil
end)()

-- ── [5] commit refuses an empty index BEFORE prompting ───────────────
;(function()
  local prompted, committed = false, false
  package.loaded["worktree.repos"] = {
    available = function() return true end,
    has_staged = function() return false end,
    commit = function() committed = true end,
  }
  local orig_input = vim.ui.input
  vim.ui.input = function() prompted = true end
  reset()
  tree.git_commit({ kind = "worktree", worktree = { path = "/tmp/wt" } })
  ok("[5] nothing staged -> no prompt at all", prompted == false)
  ok("[5] and no commit", committed == false)
  ok("[5] and it says to press `s` first",
    last():find("nothing staged", 1, true) ~= nil, last())

  -- With something staged it prompts, and an empty message cancels.
  package.loaded["worktree.repos"] = {
    available = function() return true end,
    has_staged = function() return true end,
    commit = function() committed = true end,
  }
  vim.ui.input = function(_, cb) prompted = true; cb("") end
  reset()
  tree.git_commit({ kind = "worktree", worktree = { path = "/tmp/wt" } })
  ok("[5] staged -> it prompts", prompted)
  ok("[5] an empty message cancels rather than committing", committed == false)
  ok("[5] and says it cancelled", last():find("cancelled", 1, true) ~= nil, last())

  vim.ui.input = function(_, cb) cb("a real message") end
  tree.git_commit({ kind = "worktree", worktree = { path = "/tmp/wt" } })
  ok("[5] a real message commits", committed)

  vim.ui.input = orig_input
  package.loaded["worktree.repos"] = nil
end)()

-- ── [6] a version-skewed backend degrades to a message ───────────────
;(function()
  -- available() true but NO verbs: the exact version-skew shape.
  package.loaded["worktree.repos"] = { available = function() return true end }
  reset()
  ok("[6] fetch against a backend with no verbs does not raise",
    pcall(tree.git_fetch, { kind = "repo", repo = { label = "r", common_dir = "/x" } }))
  ok("[6] and it names what is missing",
    last():find("newer worktree.nvim", 1, true) ~= nil, last())
  package.loaded["worktree.repos"] = nil
end)()

logger.notify = orig_notify
io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail)); io.stdout:flush()
if fail > 0 then os.exit(1) end
os.exit(0)
