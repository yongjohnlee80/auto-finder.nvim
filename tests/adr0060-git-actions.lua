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
  local orig_modal = package.loaded["auto-core.ui.modal"]
  -- Force the fallback path so the assertion does not depend on which
  -- confirm primitive is present.
  -- Both surfaces are nil'd: `_confirm` prefers `ui.modal` (ADR-0195 D3) and
  -- only then falls back to `float.confirm`, then to `vim.ui.select`.
  package.loaded["auto-core.ui.float"] = { confirm = nil }
  package.loaded["auto-core.ui.modal"] = { open = nil }
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
  package.loaded["auto-core.ui.modal"] = orig_modal
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

  -- These verbs resolve their working directory from the EDITOR's cwd
  -- (commands.lua `_cwd()` = vim.loop.cwd()) — correct for a real user, whose
  -- editor sits inside the repo. But this suite runs under tests/run-all.sh,
  -- which cd's to the plugin worktree, so driving them for REAL once ran
  -- `git add -A` in the plugin worktree and staged its own files — which then
  -- rode into a tagged release on a later bare commit (KB todo 2026-09-02).
  -- Stub the single git-write owner (`auto-core.git.write`, resolved lazily by
  -- commands.lua `_core_write` via require, so package.loaded is the seam) so
  -- these verbs are exercised for ROUTING only: no real git touches any tree.
  local WRITE = "auto-core.git.write"
  local saved_write = package.loaded[WRITE]
  local calls = {}
  local function _rec(verb)
    return function(...)
      local n = select("#", ...)
      calls[#calls + 1] = { verb = verb, cwd = (select(1, ...)) }
      local cb = select(n, ...)          -- _run appends the callback last
      if type(cb) == "function" then cb(true, "") end
    end
  end
  -- `.stage` must be a function or _core_write's guard rejects the table.
  package.loaded[WRITE] = { stage = _rec("stage"), unstage = _rec("unstage"),
                            stage_all = _rec("stage_all") }

  for _, name in ipairs({ "git_add_file", "git_unstage_file", "git_add_all",
                          "git_toggle_file_stage" }) do
    ok("[7] " .. name .. " is callable without raising", (pcall(cmds[name], state)))
  end

  package.loaded[WRITE] = saved_write

  -- Routing, not merely non-raising: each write reached auto-core's single
  -- owner (where the cwd is ultimately applied), never a raw git in the suite.
  -- git_toggle_file_stage reads a status first and short-circuits on a path
  -- absent from the tree, so it is asserted callable above, not for routing.
  local function _saw(verb)
    for _, c in ipairs(calls) do if c.verb == verb then return true end end
    return false
  end
  ok("[7] git_add_all routes to auto-core git.write.stage_all", _saw("stage_all"))
  ok("[7] git_add_file routes to auto-core git.write.stage", _saw("stage"))
  ok("[7] git_unstage_file routes to auto-core git.write.unstage", _saw("unstage"))

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

-- ── [9] D removes a review JSON, but only after a confirmation (§11.6) ──
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
  local orig_modal = package.loaded["auto-core.ui.modal"]
  -- Both surfaces are nil'd: `_confirm` prefers `ui.modal` (ADR-0195 D3) and
  -- only then falls back to `float.confirm`, then to `vim.ui.select`.
  package.loaded["auto-core.ui.float"] = { confirm = nil }
  package.loaded["auto-core.ui.modal"] = { open = nil }
  vim.ui.select = function(_, opts, cb) asked = opts and opts.prompt; cb("no") end

  local row = {
    kind = "review",
    repo = { label = "myrepo", slug = "own__myrepo", common_dir = "/x/.git" },
    review = { name = "own__myrepo@1cfe731.r1.review.json",
               path = "/store/reviews/own__myrepo/own__myrepo@1cfe731.r1.review.json",
               short = "1cfe731", revision = 1, severities = {} },
  }

  tree.delete_review(row)
  ok("[9] *** D asks before deleting ***", asked ~= nil, tostring(asked))
  ok("[9] and the prompt NAMES the review file",
    asked and asked:find("own__myrepo@1cfe731.r1.review.json", 1, true) ~= nil, tostring(asked))
  ok("[9] and the repository it belongs to",
    asked and asked:find("myrepo", 1, true) ~= nil, tostring(asked))
  ok("[9] *** and says BOTH the JSON and its Markdown are removed ***",
    asked and asked:lower():find("both the json and its markdown are removed", 1, true) ~= nil,
    tostring(asked))
  ok("[9] *** answering no deletes NOTHING ***", #removed == 0, tostring(#removed))

  vim.ui.select = function(_, _, cb) cb("yes") end
  tree.delete_review(row)
  ok("[9] *** answering yes removes exactly that file, once ***",
    #removed == 1 and removed[1].path == row.review.path, vim.inspect(removed))
  ok("[9] and it goes through the repo that owns the store",
    removed[1].repo and removed[1].repo.slug == "own__myrepo")


  -- No answer at all is not a yes.
  local prompted = false
  vim.ui.select = function(_, _, cb) prompted = true; cb(nil) end
  tree.delete_review(row)
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
    -- review that comments on it. `D` on a file row must not delete that file's
    -- review, so the guard is on the kind, not merely on the presence of a path.
    { kind = "file", repo = row.repo, file = { path = "a.go" }, review = row.review },
  }) do
    tree.delete_review(wrong)
  end
  ok("[9] *** D on anything that is not a review deletes nothing ***",
    #removed == before, ("%d vs %d"):format(#removed, before))
  ok("[9] *** and does not even raise the prompt — the guard returns first ***",
    asked == nil, tostring(asked))
  tree.delete_review(nil)
  ok("[9] D with no row under the cursor is a no-op", #removed == before)

  -- A failed delete is a notification, not a traceback (r1 SF2), and never a
  -- silent success.
  package.loaded["worktree.repos"] = {
    available = function() return true end,
    remove_review = function() return false, "the revision could not be fenced" end,
  }
  local said
  local prev_notify = logger.notify
  logger.notify = function(msg, o) said = tostring(msg); return prev_notify(msg, o) end
  local okc = pcall(tree.delete_review, row)
  logger.notify = prev_notify
  ok("[9] a refused delete does not throw", okc == true)
  ok("[9] *** and REPORTS why ***",
    said ~= nil and said:find("could not remove", 1, true) ~= nil
    and said:find("fenced", 1, true) ~= nil, tostring(said))

  -- An older worktree.nvim has no such verb: say so rather than doing nothing.
  package.loaded["worktree.repos"] = { available = function() return true end }
  said = nil
  logger.notify = function(msg, o) said = tostring(msg); return prev_notify(msg, o) end
  pcall(tree.delete_review, row)
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
    tree.delete_review(rrow)
    ok("[9] *** the removal message says the Markdown went too ***",
      (function() for _, n in ipairs(msgs) do
        if n:find("and its Markdown", 1, true) then return true end end return false end)(),
      vim.inspect(msgs))

    -- `D` on a review_file LEAF removes the whole review, not just that file.
    local leaf = { kind = "review_file", repo = rrow.repo, review = rrow.review,
                   path = rrow.review.document }
    local before_leaf = #rmd
    tree.delete_review(leaf)
    ok("[9] *** D on a pair LEAF removes the whole review (keyed on the JSON) ***",
      #rmd == before_leaf + 1 and rmd[#rmd].path == rrow.review.path,
      vim.inspect(rmd[#rmd]))

    logger.notify = prev
  end

  vim.ui.select = orig_select
  package.loaded["auto-core.ui.float"] = orig_float
  package.loaded["auto-core.ui.modal"] = orig_modal
  package.loaded["worktree.repos"] = nil
end)()

-- ── [10] ADR-0195 D3: the delete confirm is an IRREVERSIBLE modal ───────
-- [9] proves the gate exists through the degraded fallback. This proves the
-- SHAPE of the real one: the raw filename moves into the modal's BODY, where it
-- is readable, and irreversibility is passed as an ENFORCED construction input
-- rather than left to the caller's answer ordering — auto-core is what drops the
-- affirmative default and puts the decline first.
;(function()
  local removed = {}
  package.loaded["worktree.repos"] = {
    available = function() return true end,
    remove_review = function(repo, path)
      removed[#removed + 1] = { repo = repo, path = path }
      return true, nil, { path = path, document_removed = true }
    end,
  }
  local seen, answer = nil, false
  local orig_modal = package.loaded["auto-core.ui.modal"]
  package.loaded["auto-core.ui.modal"] = {
    open = function(o) seen = o; if o.on_choice then o.on_choice(answer) end end,
  }

  local row = {
    kind = "review",
    repo = { label = "myrepo", slug = "own__myrepo", common_dir = "/x/.git" },
    review = { name = "own__myrepo@1cfe731.r1.review.json",
               path = "/store/reviews/own__myrepo/own__myrepo@1cfe731.r1.review.json",
               short = "1cfe731", revision = 1, severities = {} },
  }

  tree.delete_review(row)
  local body = seen
    and (type(seen.body) == "table" and table.concat(seen.body, "  ") or tostring(seen.body))
    or ""
  ok("[10] D opens the shared modal", seen ~= nil)
  ok("[10] *** the delete is declared IRREVERSIBLE ***",
    seen ~= nil and seen.reversibility == "irreversible", seen and tostring(seen.reversibility))
  ok("[10] the BODY carries the raw review filename, not a truncated prompt line",
    body:find("own__myrepo@1cfe731.r1.review.json", 1, true) ~= nil, body)
  ok("[10] the body says both halves go and it cannot be undone",
    body:find("Markdown", 1, true) ~= nil
      and body:lower():find("cannot be undone", 1, true) ~= nil, body)
  ok("[10] it offers a cancel-role answer for auto-core to order first", (function()
    for _, it in ipairs((seen and seen.items) or {}) do
      if it.role == "cancel" then return true end
    end
    return false
  end)())
  ok("[10] *** declining removes nothing ***", #removed == 0, #removed)

  answer = true
  tree.delete_review(row)
  ok("[10] (control) confirming removes exactly that review, once",
    #removed == 1 and removed[1].path == row.review.path, vim.inspect(removed))

  package.loaded["auto-core.ui.modal"] = orig_modal
  package.loaded["worktree.repos"] = nil
end)()

-- ── [11] ADR-0195 SF2: the DEGRADED fallback is decline-first too ───────
-- On an auto-core predating ui.modal the confirm degrades to a picker, which has
-- no notion of a default — so ORDER is the only safety mechanism there, and a
-- bare <CR> takes the FIRST row. For the irreversible delete that row must be
-- the decline. (lector, PR#53 P0: it was hardcoded yes-first, so a bare Enter on
-- an older auto-core removed both review files.)
;(function()
  local removed = {}
  local function repos_stub()
    return {
      available = function() return true end,
      remove_review = function(repo, path)
        removed[#removed + 1] = { repo = repo, path = path }
        return true, nil, { path = path, document_removed = true }
      end,
    }
  end
  package.loaded["worktree.repos"] = repos_stub()

  local shown = nil
  local orig_select = vim.ui.select
  local orig_float = package.loaded["auto-core.ui.float"]
  local orig_modal = package.loaded["auto-core.ui.modal"]
  -- Force the DEGRADED path: neither modal nor float.confirm is present.
  package.loaded["auto-core.ui.float"] = { confirm = nil }
  package.loaded["auto-core.ui.modal"] = { open = nil }

  local row = {
    kind = "review",
    repo = { label = "myrepo", slug = "own__myrepo", common_dir = "/x/.git" },
    review = { name = "own__myrepo@1cfe731.r1.review.json",
               path = "/store/reviews/own__myrepo/own__myrepo@1cfe731.r1.review.json",
               short = "1cfe731", revision = 1, severities = {} },
  }

  -- Model a bare <CR>: a picker takes its FIRST row.
  vim.ui.select = function(items, _, cb) shown = items; cb(items[1]) end
  tree.delete_review(row)
  ok("[11] *** the degraded delete lists the DECLINE first ***",
    shown ~= nil and shown[1] == "no", shown and vim.inspect(shown))
  ok("[11] *** so a bare <CR> on an older auto-core removes NOTHING ***",
    #removed == 0, #removed)

  -- (control) the affirmative is still reachable, and still removes.
  vim.ui.select = function(_, _, cb) cb("yes") end
  tree.delete_review(row)
  ok("[11] (control) choosing yes still removes exactly that review",
    #removed == 1 and removed[1].path == row.review.path, vim.inspect(removed))

  -- (control) a REVERSIBLE question keeps its affirmative first, so <CR> acts.
  local pushed = 0
  package.loaded["worktree.repos"] = { available = function() return true end,
                                       push = function() pushed = pushed + 1 end }
  local pshown = nil
  vim.ui.select = function(items, _, cb) pshown = items; cb(items[1]) end
  tree.git_push({ kind = "repo", repo = { label = "myrepo", common_dir = "/x/.git" } })
  ok("[11] (control) a REVERSIBLE question is still affirmative-first",
    pshown ~= nil and pshown[1] == "yes", pshown and vim.inspect(pshown))

  vim.ui.select = orig_select
  package.loaded["auto-core.ui.float"] = orig_float
  package.loaded["auto-core.ui.modal"] = orig_modal
  package.loaded["worktree.repos"] = nil
end)()

-- ── [11b] the LEGACY-FLOAT branch carries the same ordering ─────────────
--
-- [11] nils float.confirm, so it only ever reaches the raw vim.ui.select last
-- resort. That left the middle rung untested: an auto-core new enough to have
-- `float.confirm` but too old for `ui.modal`. Its safety depends entirely on the
-- call passing `items = items` — and lector proved the gap by deleting exactly
-- that argument, which reintroduces yes-first bare Enter while the suite stayed
-- 99/0. A branch that no cell enters is not covered by the cells around it.
;(function()
  local removed = {}
  package.loaded["worktree.repos"] = {
    available = function() return true end,
    remove_review = function(repo, path)
      removed[#removed + 1] = { repo = repo, path = path }
      return true, nil, { path = path, document_removed = true }
    end,
  }

  local orig_float = package.loaded["auto-core.ui.float"]
  local orig_modal = package.loaded["auto-core.ui.modal"]
  -- Modal ABSENT, float.confirm PRESENT: the exact older-auto-core rung.
  package.loaded["auto-core.ui.modal"] = { open = nil }

  local seen = nil
  local function float_stub(enter)
    package.loaded["auto-core.ui.float"] = {
      confirm = function(prompt, opts)
        seen = { prompt = prompt, items = opts and opts.items }
        -- Model a bare <CR>: float.confirm's picker takes its FIRST item.
        if opts and opts.on_choice then opts.on_choice(enter and enter(opts) or nil) end
      end,
    }
  end

  local row = {
    kind = "review",
    repo = { label = "myrepo", slug = "own__myrepo", common_dir = "/x/.git" },
    review = { name = "own__myrepo@1cfe731.r1.review.json",
               path = "/store/reviews/own__myrepo/own__myrepo@1cfe731.r1.review.json",
               short = "1cfe731", revision = 1, severities = {} },
  }

  float_stub(function(opts) return opts.items and opts.items[1] end)
  tree.delete_review(row)
  -- Assert the LIST REACHED THE CALL before indexing it: dropping `items = items`
  -- leaves it nil, and that must read as a failure, not a crash.
  ok("[11b] *** the legacy float.confirm RECEIVES the item list ***",
    seen ~= nil and type(seen.items) == "table", seen and vim.inspect(seen))
  ok("[11b] *** and it is DECLINE-first ***",
    seen and type(seen.items) == "table" and seen.items[1] == "no",
    seen and vim.inspect(seen.items))
  ok("[11b] *** so a bare <CR> on that auto-core removes NOTHING ***",
    #removed == 0, #removed)

  -- (control) the affirmative is still reachable through the same branch.
  float_stub(function() return "yes" end)
  tree.delete_review(row)
  ok("[11b] (control) choosing yes still removes exactly that review",
    #removed == 1 and removed[1].path == row.review.path, vim.inspect(removed))

  -- (control) a REVERSIBLE question keeps its affirmative first here too.
  package.loaded["worktree.repos"] = { available = function() return true end,
                                       push = function() end }
  float_stub(function(opts) return opts.items and opts.items[1] end)
  tree.git_push({ kind = "repo", repo = { label = "myrepo", common_dir = "/x/.git" } })
  ok("[11b] (control) a REVERSIBLE question is still affirmative-first",
    seen and type(seen.items) == "table" and seen.items[1] == "yes",
    seen and vim.inspect(seen.items))

  package.loaded["auto-core.ui.float"] = orig_float
  package.loaded["auto-core.ui.modal"] = orig_modal
  package.loaded["worktree.repos"] = nil
end)()

-- ── [13] ADR-0195 D4: `d` archives, `D` deletes ─────────────────────────
--
-- The substance of D4 is a SAFETY property, not a feature: the key a user
-- presses from muscle memory on a review they wanted to tidy away must no
-- longer be able to destroy it. So the load-bearing assertion is a NEGATIVE —
-- `d` never reaches remove_review — and it is stated first, because a cell that
-- only checks "archive_review was called" would still pass if `d` called both.
;(function()
  local archived, unarchived, removed = {}, {}, {}
  local function backend()
    return {
      available      = function() return true end,
      archive_review = function(repo, path) archived[#archived + 1] = path; return true end,
      unarchive_review = function(repo, path) unarchived[#unarchived + 1] = path; return true end,
      remove_review  = function(repo, path) removed[#removed + 1] = path; return true, nil, {} end,
      reviews_all    = function() return {} end,
      reviews_index  = function() return {} end,
    }
  end
  package.loaded["worktree.repos"] = backend()

  local seen = nil
  local orig_modal = package.loaded["auto-core.ui.modal"]
  package.loaded["auto-core.ui.modal"] = {
    open = function(o) seen = o; for _, it in ipairs(o.items or {}) do
      if it.role == "confirm" then o.on_choice(it.value) end end end,
  }

  local function review_row(extra)
    local r = { kind = "review",
      repo = { label = "myrepo", slug = "own__myrepo", common_dir = "/x/.git" },
      review = { name = "own__myrepo@1cfe731.r1.review.json",
                 path = "/store/reviews/own__myrepo/own__myrepo@1cfe731.r1.review.json",
                 short = "1cfe731", revision = 1, severities = {} } }
    for k, v in pairs(extra or {}) do r.review[k] = v end
    return r
  end

  tree.remove_review(review_row())
  ok("[13] *** `d` on a plain review NEVER deletes it ***", #removed == 0, #removed)
  ok("[13] *** it archives instead ***",
    #archived == 1 and archived[1]:find("r1.review.json", 1, true) ~= nil,
    vim.inspect(archived))
  ok("[13] and the archive question is REVERSIBLE — it keeps its default",
    seen and seen.reversibility == "reversible", seen and seen.reversibility)
  ok("[13] the body promises the files stay, which is the user's whole ask",
    seen and table.concat(seen.body or {}, " "):find("stay on disk", 1, true) ~= nil,
    seen and vim.inspect(seen.body))
  ok("[13] and it says how to see them again",
    seen and table.concat(seen.body or {}, " "):find("za", 1, true) ~= nil,
    seen and vim.inspect(seen.body))

  -- The inverse, on a row the section only shows while archived rows are shown.
  tree.remove_review(review_row({ archived = true }))
  ok("[13] *** `d` on an ARCHIVED review restores it ***",
    #unarchived == 1, vim.inspect(unarchived))
  ok("[13] and it does not archive it a second time", #archived == 1, #archived)
  ok("[13] and it still never deletes", #removed == 0, #removed)

  -- `D` is the only way to the destructive path.
  tree.delete_review(review_row())
  ok("[13] *** `D` deletes, and only `D` ***", #removed == 1, vim.inspect(removed))
  ok("[13] *** and D's question is IRREVERSIBLE ***",
    seen and seen.reversibility == "irreversible", seen and seen.reversibility)

  -- A worktree row keeps d's older meaning; the split must not swallow it.
  local before = #archived
  tree.remove_review({ kind = "worktree", repo = { label = "r", common_dir = "/x/.git" },
                       worktree = { path = "/wt" } })
  ok("[13] `d` on a worktree is untouched by the split — nothing is archived",
    #archived == before, #archived)

  -- An older worktree.nvim has no archive verbs. `d` must then say so rather
  -- than silently falling back to the delete it used to be.
  package.loaded["worktree.repos"] = {
    available = function() return true end,
    remove_review = function(_, path) removed[#removed + 1] = path; return true, nil, {} end,
  }
  reset()
  local before_rm = #removed
  tree.remove_review(review_row())
  ok("[13] *** a backend without archive_review does NOT fall back to deleting ***",
    #removed == before_rm, ("%d vs %d"):format(#removed, before_rm))
  ok("[13] it explains what is missing and that D still works",
    last():find("archive_review", 1, true) ~= nil and last():find("D", 1, true) ~= nil,
    last())

  package.loaded["auto-core.ui.modal"] = orig_modal
  package.loaded["worktree.repos"] = nil
end)()

-- ── [13b] the `za` toggle is what makes archiving reversible ────────────
--
-- An archive the user cannot get back to has been deleted as far as they are
-- concerned, so the toggle is not a convenience — it is the other half of the
-- safety property [13] asserts.
;(function()
  local repo = { label = "myrepo", slug = "own__myrepo", common_dir = "/x/.git" }
  package.loaded["worktree.repos"] = {
    available = function() return true end,
    -- A CAPABLE backend: the archive interface is what the panel gates on.
    archive_review = function() return true end,
    unarchive_review = function() return true end,
    reviews_all = function() return {} end,
    reviews_index = function() return {} end,
  }

  ok("[13b] a repo starts by HIDING archived reviews",
    tree.archived_mode(repo) == "active", tree.archived_mode(repo))
  tree.toggle_archived({ kind = "reviews", repo = repo })
  ok("[13b] *** za reveals them ***", tree.archived_mode(repo) == "all",
    tree.archived_mode(repo))
  tree.toggle_archived({ kind = "reviews", repo = repo })
  ok("[13b] and za again hides them", tree.archived_mode(repo) == "active",
    tree.archived_mode(repo))

  -- The mode is PER REPO: one repo revealing its archived reviews must not
  -- reveal another's, or the toggle would be a global the user has to undo
  -- somewhere they were not looking.
  local other = { label = "b", slug = "own__b", common_dir = "/y/.git" }
  tree.toggle_archived({ kind = "reviews", repo = repo })
  ok("[13b] the mode is per-repo, not global",
    tree.archived_mode(repo) == "all" and tree.archived_mode(other) == "active",
    ("%s / %s"):format(tree.archived_mode(repo), tree.archived_mode(other)))
  tree.toggle_archived({ kind = "reviews", repo = repo })

  reset()
  tree.toggle_archived(nil)
  ok("[13b] za with no row says where the cursor belongs, and does not raise",
    last():find("cursor", 1, true) ~= nil, last())

  -- The SOURCE has to thread the mode into both store calls. The count and the
  -- rows come from two different functions, and a mode applied to only one of
  -- them is the "(3) over two rows" defect worktree.nvim had to fix.
  local src = table.concat(vim.fn.readfile(
    plugin_root .. "/lua/auto-finder/views/repos/tree.lua"), "\n")
  ok("[13b] *** the ROWS are requested with the mode ***",
    src:find("reviews_all(repo, { include_archived = amode })", 1, true) ~= nil)
  ok("[13b] *** and so is the COUNT ***",
    src:find("reviews_index(repo, { include_archived = amode })", 1, true) ~= nil)
  ok("[13b] the hidden ones are still COUNTED, so an archive is never invisible",
    src:find('include_archived = "archived_only"', 1, true) ~= nil
      and src:find("archived\"", 1, true) ~= nil)
  ok("[13b] `za` is bound",
    src:find('set("za", function() M.toggle_archived', 1, true) ~= nil)
  ok("[13b] `D` is bound to the delete, not to d's handler",
    src:find('set("D", function() M.delete_review', 1, true) ~= nil
      and src:find('set("d", function() M.remove_review', 1, true) ~= nil)

  package.loaded["worktree.repos"] = nil
end)()

-- ── [13c] an OLDER worktree.nvim must not be told it can archive ────────
--
-- Lua discards an argument a function does not declare, so a pre-v0.5.20
-- `reviews_all(repo)` accepts `{ include_archived = "archived_only" }` and
-- returns EVERY review. The panel then counted all of them as archived and `za`
-- announced "showing archived reviews" over a listing that had not changed.
--
-- This is the failure mode an optional argument always has: passing an option
-- to a function that ignores it is indistinguishable from success. So the gate
-- is the presence of the archive INTERFACE, not the acceptance of an option.
;(function()
  local calls = {}
  -- Legacy shape: reviews_all / reviews_index exist, the archive verbs do not,
  -- and the listing ignores any opts it is handed.
  package.loaded["worktree.repos"] = {
    available = function() return true end,
    reviews_all = function(_, opts)
      calls[#calls + 1] = { fn = "reviews_all", opts = opts }
      return { { revision = 1, name = "a.review.json", path = "/s/a.review.json" } }
    end,
    reviews_index = function(_, opts)
      calls[#calls + 1] = { fn = "reviews_index", opts = opts }
      return { { revision = 1, name = "a.review.json", path = "/s/a.review.json" } }
    end,
  }
  local repo = { label = "old", slug = "own__old", common_dir = "/old/.git" }

  ok("[13c] *** the mode is pinned to active on an incapable backend ***",
    tree.archived_mode(repo) == "active", tree.archived_mode(repo))

  reset()
  tree.toggle_archived({ kind = "reviews", repo = repo })
  ok("[13c] *** za REFUSES rather than claiming to show archives ***",
    tree.archived_mode(repo) == "active", tree.archived_mode(repo))
  ok("[13c] and it names what is missing",
    last():find("archive_review", 1, true) ~= nil, last())

  package.loaded["worktree.repos"] = nil
end)()

-- [12] ADR-0195 D5 — the migration manifest, asserted by SET-EQUALITY.
--
-- A count alone is not an audit. r0's manifest was WRONG while its count looked
-- right: it mislabelled two help overlays as confirmations and listed the
-- `_confirm` helper instead of its callers. A wrong conversion can replace a
-- missed required one and leave any count green — so this pins exact MEMBERSHIP
-- (which enclosing function holds which surface) as well as the totals.
--
-- Identity is the enclosing function name, not a line number: line numbers drift
-- with every edit above them, and a drifting assertion gets "fixed" by updating
-- the expectation, which is how an audit stops auditing.
;(function()
  local src = plugin_root .. "/lua/auto-finder/views/repos/tree.lua"
  local lines = vim.fn.readfile(src)
  ok("[12] the audited source is the shipped repos tree", #lines > 0, #lines)

  local found = { confirm = {}, overlay = {}, picker = {}, legacy = {},
                  modal = {}, vimfn = {}, irreversible = {} }
  local fn = "<file scope>"
  for _, line in ipairs(lines) do
    local l = line:match("^local function ([%w_]+)") or line:match("^function (M%.[%w_]+)")
    if l then fn = l end
    -- Comments describe surfaces without being them; a doc line naming
    -- `float.confirm` must not count as a call site.
    if not line:match("^%s*%-%-") then
      if line:match("_confirm%(") and not line:match("^local function _confirm")
        then table.insert(found.confirm, fn) end
      if line:match("pcall%(float%.help_overlay") then table.insert(found.overlay, fn) end
      if line:match("vim%.ui%.select%(")          then table.insert(found.picker, fn) end
      if line:match("float%.confirm%(")           then table.insert(found.legacy, fn) end
      if line:match("modal%.open%(")              then table.insert(found.modal, fn) end
      if line:match("vim%.fn%.confirm%(")         then table.insert(found.vimfn, fn) end
      if line:match("irreversible%s*=%s*true")    then table.insert(found.irreversible, fn) end
    end
  end

  local function seteq(label, got, want)
    local g, w = vim.deepcopy(got), vim.deepcopy(want)
    table.sort(g); table.sort(w)
    ok(label .. " — membership", table.concat(g, ", ") == table.concat(w, ", "),
      ("got {%s} want {%s}"):format(table.concat(g, ", "), table.concat(w, ", ")))
    ok(label .. " — count", #g == #w, ("%d vs %d"):format(#g, #w))
  end

  -- The five confirmation surfaces of D5's auto-finder rows. `remove_review`
  -- appears TWICE by design: the reversible PR-dissociation and the
  -- irreversible non-PR delete are different questions in one function.
  -- UPDATED DELIBERATELY for ADR-0195 D4, which is the moment this audit is most
  -- likely to be weakened: the easy move when a set-equality cell goes red is to
  -- paste in whatever the code now does, which turns the audit into a mirror. So
  -- each row below is justified, and the classification is the thing asserted —
  -- D4 moved the destructive surface to its own function and added two
  -- reversible ones, so the IRREVERSIBLE set must SHRINK to exactly `D`'s
  -- handler even as the confirmation set grows.
  seteq("[12] *** every confirmation, after the d/D split ***", found.confirm, {
    "M.associate_worktree",   -- re-point PR association        (reversible)
    "M.dissociate_worktree",  -- release worktree from PR       (reversible)
    "M.remove_review",        -- `d`: dissociate PR review      (reversible)
    "M.remove_review",        -- `d`: ARCHIVE a plain review    (reversible, new)
    "M.remove_review",        -- `d`: UNARCHIVE an archived one (reversible, new)
    "M.git_push",             -- push                           (reversible)
    "M._delete_review",       -- `D`: delete the pair        (IRREVERSIBLE)
  })

  -- Help overlays stay overlays: an overlay is not a question, so converting one
  -- to a modal would invent a decision the user never had to make.
  seteq("[12] the help overlays stayed overlays", found.overlay, { "_info", "_help" })

  -- Pickers stay pickers. `_confirm`'s own last-resort `vim.ui.select` is a
  -- degradation path, not a menu, so it is named separately rather than quietly
  -- inflating the picker set.
  local pickers, in_confirm = {}, 0
  for _, f in ipairs(found.picker) do
    if f == "_confirm" then in_confirm = in_confirm + 1 else table.insert(pickers, f) end
  end
  seteq("[12] the pickers stayed pickers", pickers, {
    "M.open_diff", "M.open_diff", "M._submit_review", "M.attach_review_to_task",
  })
  ok("[12] _confirm holds exactly one fallback picker", in_confirm == 1, in_confirm)

  -- No confirmation escapes the helper: every one routes through `_confirm`, so
  -- the D3 reversibility contract has a single place it can be enforced.
  seteq("[12] *** modal.open is reached ONLY through _confirm ***", found.modal, { "_confirm" })
  seteq("[12] *** float.confirm survives ONLY as _confirm's degradation ***",
    found.legacy, { "_confirm" })
  ok("[12] *** no raw vim.fn.confirm remains ***", #found.vimfn == 0, vim.inspect(found.vimfn))

  -- Exactly one surface is irreversible, and it is the delete.
  -- STILL exactly one, and it moved: the irreversible surface is now reachable
  -- only from `D`'s handler, which is the whole substance of D4. If `d`'s
  -- function ever appears here again, the key split has been undone.
  seteq("[12] *** exactly one site declares itself irreversible, and it is D's ***",
    found.irreversible, { "M._delete_review" })
end)()

logger.notify = orig_notify
io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail)); io.stdout:flush()
if fail > 0 then os.exit(1) end
os.exit(0)
