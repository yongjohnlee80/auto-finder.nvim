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
    -- A key the `?` overlay does not mention is a key nobody discovers. The
    -- first version of this feature shipped all four undocumented.
    ok("[1] `" .. key .. "` appears in the ? help overlay",
      src:find('"  ' .. key .. '     ', 1, true) ~= nil)
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

-- ── [7] the MIGRATED neo-tree commands actually run ──────────────────
--
-- The blocker this exists for. The adapter was declared below its first use, so
-- the four staging commands closed over a nil GLOBAL `_run` and every one died
-- with "attempt to call global '_run'". `M._run` was exported and fine, which is
-- precisely why a test that called `M._run` passed while the commands were dead.
-- So: invoke the COMMANDS.
;(function()
  local cmds = require("auto-finder.neotree.sources.common.commands")
  local node = { type = "file", name = "f.txt", get_id = function() return "f.txt" end }
  local state = { tree = { get_node = function() return node end } }

  for _, name in ipairs({ "git_add_file", "git_unstage_file", "git_add_all",
                          "git_toggle_file_stage" }) do
    ok("[7] " .. name .. " is callable without raising", (pcall(cmds[name], state)))
  end

  -- And the adapter must be declared BEFORE its first use, not merely exported.
  -- Asserted on the source because that ordering is what broke, and a runtime
  -- call can be made to pass by an unrelated early return.
  local src = table.concat(vim.fn.readfile(plugin_root
    .. "/lua/auto-finder/neotree/sources/common/commands.lua"), "\n")
  local decl = src:find("local function _run", 1, true)
  local first_use = nil
  for pos in src:gmatch("()_run%(") do
    local line_start = src:sub(1, pos):match("[^\n]*$")
    if not line_start:match("^%s*%-%-") and not line_start:match("local function $")
       and not line_start:match("M%._run") then
      first_use = first_use or pos
    end
  end
  ok("[7] the adapter is declared before its first use",
    decl and first_use and decl < first_use,
    string.format("decl=%s first_use=%s", tostring(decl), tostring(first_use)))
end)()

-- ── [8] the write topics REACH the view's topic ──────────────────────
--
-- The third blocker. auto-core's in-process write topics had no path to
-- `auto-finder.core.repos:changed`, so the panel showed a stale UNCOMMITTED node
-- after its own `s` / `c` / `f`. A bus probe read 0 deliveries for all four
-- against 1 for the external-state control — the task's assumption that the
-- refresh came free was simply wrong.
;(function()
  require("auto-finder.core").ensure_started()
  local afe = require("auto-finder.core.events")
  local core_events = require("auto-core.events")
  local n = 0
  afe.subscribe("auto-finder.core.repos:changed", function() n = n + 1 end)
  ---delivered publishes one topic and reports how many repos:changed arrived.
  ---
  ---It SETTLES the bus first. Without that, a previous publish's handler landed
  ---inside the next measurement window and the success-gate assertion read a
  ---delivery it had not caused — a race that makes the gate look broken when it
  ---is not, and would equally hide a real regression.
  local function delivered(topic, payload)
    vim.wait(150)
    local before = n
    core_events.publish(topic, payload)
    vim.wait(400, function() return n > before end, 10)
    vim.wait(100)
    return n - before
  end

  for _, t in ipairs({
    { "core.git.index:changed",    { cwd = "/x", ok = true } },
    { "core.git.commit:completed", { cwd = "/x", ok = true } },
    { "core.git.fetch:completed",  { label = "r", ok = true } },
    { "core.git.push:completed",   { cwd = "/x", ok = true } },
  }) do
    ok("[8] " .. t[1] .. " reaches repos:changed", delivered(t[1], t[2]) == 1)
  end

  -- Success-gated: a refused write changed nothing, so invalidating for it would
  -- spend a render redrawing the same tree.
  ok("[8] a FAILED write does not invalidate",
    delivered("core.git.index:changed", { cwd = "/x", ok = false }) == 0)

  -- CONTROL: the external-state path must still work. If this reads 0 the probe
  -- is blind and the four assertions above prove nothing.
  ok("[8] CONTROL — external core.git.state:changed still arrives",
    delivered("core.git.state:changed",
      { repo_root = "/x", git_dir = "/x/.git", kind = "index" }) == 1)
end)()

-- ── [9] d removes a review JSON, but only after a confirmation (§11.6) ──
-- A review is the one artifact on this panel git cannot regenerate, so the
-- gate matters as much as the delete. Same shape as [4]'s push: the fallback
-- confirm path is forced so the assertions do not depend on which primitive is
-- present.
;(function()
  local removed = {}
  package.loaded["worktree.repos"] = {
    available = function() return true end,
    remove_review = function(repo, path)
      removed[#removed + 1] = { repo = repo, path = path }
      return true, nil, { path = path, document = "/kb/agents/lector/reviews/doc-r1-review.md",
        document_removed = true, tombstoned = true }
    end,
  }
  local asked = nil
  local orig_select = vim.ui.select
  local orig_float = package.loaded["auto-core.ui.float"]
  package.loaded["auto-core.ui.float"] = { confirm = nil }
  vim.ui.select = function(_, opts, cb) asked = opts and opts.prompt; cb("no") end

  local row = {
    kind = "review",
    repo = { label = "myrepo", slug = "own__myrepo", common_dir = "/x/.git" },
    review = { name = "own__myrepo@1cfe731.r1.review.json",
               path = "/store/reviews/own__myrepo/own__myrepo@1cfe731.r1.review.json",
               short = "1cfe731", revision = 1, severities = {} },
  }

  tree.remove_review(row)
  ok("[9] *** d asks before deleting ***", asked ~= nil, tostring(asked))
  ok("[9] and the prompt NAMES the review file",
    asked and asked:find("own__myrepo@1cfe731.r1.review.json", 1, true) ~= nil, tostring(asked))
  ok("[9] and the repository it belongs to",
    asked and asked:find("myrepo", 1, true) ~= nil, tostring(asked))
  ok("[9] *** and says BOTH the JSON and its Markdown are removed ***",
    asked and asked:lower():find("both the json and its markdown are removed", 1, true) ~= nil,
    tostring(asked))
  ok("[9] *** answering no deletes NOTHING ***", #removed == 0, tostring(#removed))

  vim.ui.select = function(_, _, cb) cb("yes") end
  tree.remove_review(row)
  ok("[9] *** answering yes removes exactly that file, once ***",
    #removed == 1 and removed[1].path == row.review.path, vim.inspect(removed))
  ok("[9] and it goes through the repo that owns the store",
    removed[1].repo and removed[1].repo.slug == "own__myrepo")


  -- No answer at all is not a yes.
  local prompted = false
  vim.ui.select = function(_, _, cb) prompted = true; cb(nil) end
  tree.remove_review(row)
  ok("[9] with no answer, nothing is deleted", #removed == 1, tostring(#removed))
  ok("[9] and it still prompted rather than assuming yes", prompted)

  -- Wrong row: a stray `d` in a tree full of files must not reach the store.
  -- `asked` is reset so the guard can be observed: a wrong row must return
  -- BEFORE the confirm, so no prompt is raised at all. (This assertion was
  -- briefly written as `ok(..., true)` — vacuous, exactly the class this repo
  -- has had to fix twice.)
  asked = nil
  vim.ui.select = function(_, opts, cb) asked = opts and opts.prompt; cb("yes") end
  local before = #removed
  for _, wrong in ipairs({
    { kind = "file", repo = row.repo, file = { path = "a.go" } },
    { kind = "commit", repo = row.repo, node = { sha = "abc" } },
    { kind = "repo", repo = row.repo },
    { kind = "reviews", repo = row.repo },
    { kind = "review", repo = row.repo, review = {} },   -- a row with no path
    -- The one that needs the KIND check rather than the path check: a row that
    -- is NOT a review while carrying a review's record. No row does that today,
    -- and the obvious next feature makes one — badging a changed file with the
    -- review that comments on it. `d` on a file row must not delete that file's
    -- review, so the guard is on the kind, not merely on the presence of a path.
    { kind = "file", repo = row.repo, file = { path = "a.go" }, review = row.review },
  }) do
    tree.remove_review(wrong)
  end
  ok("[9] *** d on anything that is not a review deletes nothing ***",
    #removed == before, ("%d vs %d"):format(#removed, before))
  ok("[9] *** and does not even raise the prompt — the guard returns first ***",
    asked == nil, tostring(asked))
  tree.remove_review(nil)
  ok("[9] d with no row under the cursor is a no-op", #removed == before)

  -- A failed delete is a notification, not a traceback (r1 SF2), and never a
  -- silent success.
  package.loaded["worktree.repos"] = {
    available = function() return true end,
    remove_review = function() return false, "the revision could not be fenced" end,
  }
  local said
  local prev_notify = logger.notify
  logger.notify = function(msg, o) said = tostring(msg); return prev_notify(msg, o) end
  local okc = pcall(tree.remove_review, row)
  logger.notify = prev_notify
  ok("[9] a refused delete does not throw", okc == true)
  ok("[9] *** and REPORTS why ***",
    said ~= nil and said:find("could not remove", 1, true) ~= nil
    and said:find("fenced", 1, true) ~= nil, tostring(said))

  -- An older worktree.nvim has no such verb: say so rather than doing nothing.
  package.loaded["worktree.repos"] = { available = function() return true end }
  said = nil
  logger.notify = function(msg, o) said = tostring(msg); return prev_notify(msg, o) end
  pcall(tree.remove_review, row)
  logger.notify = prev_notify
  ok("[9] against an older worktree.nvim it explains itself",
    said ~= nil and said:find("newer worktree.nvim", 1, true) ~= nil, tostring(said))

  -- Pair-aware removal (Johno, 2026-09-03), self-contained so it neither
  -- depends on nor perturbs the shared stub and counters above.
  do
    local rmd = {}
    local msgs = {}
    package.loaded["worktree.repos"] = {
      available = function() return true end,
      remove_review = function(repo, path)
        rmd[#rmd + 1] = { repo = repo, path = path }
        return true, nil, { path = path, document_removed = true,
          document = "/kb/agents/lector/reviews/doc-r1-review.md", tombstoned = true }
      end,
    }
    local prev = logger.notify
    logger.notify = function(m, o) msgs[#msgs + 1] = tostring(m); return prev(m, o) end
    vim.ui.select = function(_, _, cb) cb("yes") end

    local rrow = {
      kind = "review",
      repo = { label = "myrepo", slug = "own__myrepo", common_dir = "/x/.git" },
      review = { name = "own__myrepo@1cfe731.r1.review.json",
                 path = "/store/reviews/own__myrepo/own__myrepo@1cfe731.r1.review.json",
                 document = "/kb/agents/lector/reviews/doc-r1-review.md",
                 short = "1cfe731", revision = 1, severities = {} },
    }
    tree.remove_review(rrow)
    ok("[9] *** the removal message says the Markdown went too ***",
      (function() for _, n in ipairs(msgs) do
        if n:find("and its Markdown", 1, true) then return true end end return false end)(),
      vim.inspect(msgs))

    -- `d` on a review_file LEAF removes the whole review, not just that file.
    local leaf = { kind = "review_file", repo = rrow.repo, review = rrow.review,
                   path = rrow.review.document }
    local before_leaf = #rmd
    tree.remove_review(leaf)
    ok("[9] *** d on a pair LEAF removes the whole review (keyed on the JSON) ***",
      #rmd == before_leaf + 1 and rmd[#rmd].path == rrow.review.path,
      vim.inspect(rmd[#rmd]))

    logger.notify = prev
  end

  vim.ui.select = orig_select
  package.loaded["auto-core.ui.float"] = orig_float
  package.loaded["worktree.repos"] = nil
end)()

logger.notify = orig_notify
io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail)); io.stdout:flush()
if fail > 0 then os.exit(1) end
os.exit(0)
