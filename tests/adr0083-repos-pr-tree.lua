-- ADR-0083 Amendment r9: PR as a [#N] BADGE on the worktree row (not its own
-- row), reviews tagged → #N with a [posted] badge, S submits one review entry,
-- P is push-only, and GetPR surfaces cancel / bad-input / errors.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
local sib = vim.fn.fnamemodify(root, ":h:h")
local branch_dir = vim.fn.fnamemodify(root, ":t")
for _, p in ipairs({ LAZY .. "/nui.nvim", LAZY .. "/plenary.nvim" }) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end
for _, plugin in ipairs({ "worktree.nvim", "auto-core.nvim" }) do
  -- A candidate must be able to SERVE the request, not merely exist (see the
  -- long note that used to live here: the LAST prepend wins, so a stale sibling
  -- shadowed a current copy and the suite aborted mid-run).
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

local sb = vim.fn.tempname() .. "-adr0083-pr"
dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/_sandbox.lua")("adr0083-pr")

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
local NS = vim.api.nvim_get_namespaces()["auto_finder_repos_tree"]

-- Capture notifications
local notes = {}
logger.notify = function(msg, opts)
  table.insert(notes, { msg = tostring(msg), level = opts and opts.level })
end
local function last_note() return notes[#notes] end

-- Extmark highlight groups painted on one buffer line (0-indexed).
local function hls_on_line(bufnr, lnum)
  local out = {}
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, { lnum, 0 }, { lnum, -1 }, { details = true })
  for _, m in ipairs(marks) do
    if m[4] and m[4].hl_group then out[m[4].hl_group] = true end
  end
  return out
end

-- The 0-indexed buffer line a row sits on (rows and lines are appended 1:1).
local function line_of_row(pred)
  for i, row in ipairs(tree._rows or {}) do
    if pred(row) then return i - 1, row end
  end
  return nil, nil
end

-- ── 1. Keymaps ────────────────────────────────────────────────
local pbuf = tree.get_buffer(nil)
local km_map = {}
for _, km in ipairs(vim.api.nvim_buf_get_keymap(pbuf, "n")) do km_map[km.lhs] = km end

ok("r9: 'O' keymap bound", km_map["O"] ~= nil)
ok("r9: 'O' describes the grouped WORKTREE diff (no PR entry any more)",
  km_map["O"] and km_map["O"].desc:find("worktree", 1, true) ~= nil, km_map["O"] and km_map["O"].desc)
ok("r9: 'P' keymap bound", km_map["P"] ~= nil)
ok("r9: 'P' describes PUSH ONLY, not feedback",
  km_map["P"] and km_map["P"].desc:find("push", 1, true) ~= nil
    and km_map["P"].desc:find("feedback", 1, true) == nil, km_map["P"] and km_map["P"].desc)
ok("r9: 'S' keymap bound (submit review)", km_map["S"] ~= nil)
ok("r9: 'S' describes submitting a review entry to its PR",
  km_map["S"] and km_map["S"].desc:find("submit", 1, true) ~= nil, km_map["S"] and km_map["S"].desc)
ok("r9: 'G' keymap describes GetPR", km_map["G"] and km_map["G"].desc:find("GetPR", 1, true) ~= nil)
ok("r9: 'N' keymap describes CreatePR", km_map["N"] and km_map["N"].desc:find("CreatePR", 1, true) ~= nil)
ok("r9: 'd' keymap describes dissociate", km_map["d"] and km_map["d"].desc:find("dissociate", 1, true) ~= nil)

-- ── 2. HELP ───────────────────────────────────────────────────
local help_text = table.concat(tree.HELP, "\n")
ok("r9: HELP documents 'O' as the worktree branch diff",
  help_text:find("O     diff this worktree", 1, true) ~= nil)
ok("r9: HELP documents 'P' as push",
  help_text:find("P     push this repository", 1, true) ~= nil
    and help_text:find("post inline feedback", 1, true) == nil)
ok("r9: HELP documents 'S' as submit", help_text:find("S     submit this review", 1, true) ~= nil)
ok("r9: HELP explains the [#N] worktree badge", help_text:find("[#N]", 1, true) ~= nil)
ok("r9: HELP explains the review → #N / [posted] badges",
  help_text:find("→ #N", 1, true) ~= nil and help_text:find("[posted]", 1, true) ~= nil)

-- HELP must document the PREREQUISITES of the PR keys, not only the keys.
-- G/N/S reach a forge and do nothing without a registered token, and the [#N]
-- badge is an association a reader cannot infer — a modal that lists the keys
-- and stops reads as complete while the surface stays unusable (Johno,
-- 2026-09-10). These assert the facts a user needs to ACT, so a help text that
-- drifts from the credential or association model fails here.
ok("creds: HELP names the command that registers a token",
  help_text:find(":WorktreeAuth set", 1, true) ~= nil)
ok("creds: HELP says a PR key does nothing until one is registered",
  help_text:find("no PR key works until", 1, true) ~= nil)
ok("creds: HELP gives both provider forms (command and env)",
  help_text:find("command pass show", 1, true) ~= nil
    and help_text:find("env GITHUB_TOKEN", 1, true) ~= nil)
ok("creds: HELP gives the key-resolution order",
  help_text:find("slug → host → env", 1, true) ~= nil)
ok("creds: HELP gives the slug's real shape (owner__name, not owner/name)",
  help_text:find("owner__name", 1, true) ~= nil)
ok("creds: HELP names the provider allowlist",
  help_text:find("pass, op, gh, secret-tool", 1, true) ~= nil)
ok("creds: HELP says the store holds a reference, not the secret",
  help_text:lower():find("the secret itself never touches disk", 1, true) ~= nil)
ok("creds: HELP does not print a token-looking literal",
  help_text:find("ghp_", 1, true) == nil)

ok("assoc: HELP gives BOTH ways a worktree becomes PR #N",
  help_text:find("branch is named pr-<N>", 1, true) ~= nil
    and help_text:find("shared/prs/<slug>/pr-<N>.md", 1, true) ~= nil)
ok("assoc: HELP says G and N write that document",
  help_text:find("G and N both write it", 1, true) ~= nil)
ok("assoc: HELP warns a review inherits its PR at DRAFT time",
  help_text:find("AT DRAFT TIME", 1, true) ~= nil
    and help_text:find("S can never submit it", 1, true) ~= nil)
ok("assoc: HELP says how to repoint and how to dissociate",
  help_text:find("Repoint one by editing", 1, true) ~= nil
    and help_text:find("delete the", 1, true) ~= nil)
ok("assoc: HELP distinguishes `d` (a REVIEW) from dissociating a worktree",
  help_text:find("`d` dissociates a REVIEW", 1, true) ~= nil)

-- The overlay is capped at the window height and says nothing about it, so a
-- reader who cannot see the bottom has no reason to think there IS a bottom.
ok("HELP's first line tells the reader it scrolls",
  tostring(tree.HELP[1]):find("scrolls", 1, true) ~= nil, tostring(tree.HELP[1]))

-- Credential PREFLIGHT (ADR-0083 §2.6 Action 1 step 1).
ok("preflight: HELP says the PR keys check for a token BEFORE prompting",
  help_text:find("check for a token BEFORE prompting", 1, true) ~= nil)
ok("preflight: HELP points at :WorktreeAuth status and i",
  help_text:find(":WorktreeAuth status", 1, true) ~= nil
    and help_text:find("i on a repo row shows which key resolves it", 1, true) ~= nil)

-- ── 3. Commands ───────────────────────────────────────────────
local cmds = vim.api.nvim_get_commands({})
ok("r9: :AutoFinderGetPR registered", cmds["AutoFinderGetPR"] ~= nil)
ok("r9: :AutoFinderCreatePR registered", cmds["AutoFinderCreatePR"] ~= nil)
ok("r9: :AutoFinderPostPRFeedback registered", cmds["AutoFinderPostPRFeedback"] ~= nil)

-- ── Fixtures ──────────────────────────────────────────────────
local mock_repo = {
  label = "test-repo", slug = "test-repo",
  common_dir = sb .. "/test-repo.git", path = sb .. "/test-repo",
  url = "https://github.com/user/test-repo.git",
}
local mock_wt = { path = sb .. "/test-repo/wt-pr42", branch = "pr-42", head = "c1a2b3c", watched = true }
local mock_pr = {
  number = 42, title = "Add PR feature", state = "open", draft = false,
  branch = "pr-42", base = "main", author = "alice",
  kb_doc = sb .. "/shared/prs/test-repo/pr-42.md",
}
local mock_review = {
  name = "test-repo@c1a2b3c.r1.review.json",
  path = sb .. "/agents/reviewer/reviews/test-repo@c1a2b3c.r1.review.json",
  document = sb .. "/agents/reviewer/reviews/2026-09-05-test-repo-c1a2b3c-r1-review.md",
  commit = "c1a2b3c000000000000000000000000000000000",
  revision = 1, pr = 42, worst = "must-fix", severities = { ["must-fix"] = 1 },
}
vim.fn.mkdir(vim.fs.dirname(mock_pr.kb_doc), "p")
vim.fn.writefile({ "# PR 42", "Body" }, mock_pr.kb_doc)
vim.fn.mkdir(vim.fs.dirname(mock_review.path), "p")
vim.fn.writefile({ vim.json.encode({
  schema = "worktree.review/1", commit = mock_review.commit, revision = 1,
  repo = { url = mock_repo.url, owner = "user", name = "test-repo" }, pr = 42,
  comments = { { path = "foo.lua", line = 10, severity = "must-fix", body = "Fix this" } },
}) }, mock_review.path)
vim.fn.writefile({ "# Review r1" }, mock_review.document)

local posted_flag = false
local repos_backend = {
  available = function() return true end,
  repos = function() return { mock_repo } end,
  worktrees = function() return { mock_wt } end,
  children = function() return {}, {} end,
  pr_for_worktree = function() return mock_pr end,
  reviews_index = function() return { mock_review } end,
  reviews_all = function() return { mock_review } end,
  reviews_for_pr = function(_, n) return tostring(n) == "42" and { mock_review } or {} end,
  review_posted = function(_, meta) return posted_flag and meta.pr == 42 end,
  uncommitted = function() return {} end,
  remove_review = function() return true end,
}
package.loaded["worktree.repos"] = repos_backend

-- ── 4. The [#N] badge is on the WORKTREE row; there is NO pr row ──
local tbuf = tree.get_buffer(nil)
tree._expanded["repo:" .. mock_repo.common_dir] = true
tree._expanded["wt:" .. mock_wt.path] = true
tree._expanded["reviews:" .. mock_repo.common_dir] = true
tree.invalidate(nil)
tree.on_focus(nil, tbuf)

local wt_lnum, wt_row = line_of_row(function(r) return r.kind == "worktree" end)
ok("r9: worktree row rendered", wt_row ~= nil)
ok("r9: *** worktree row carries a [#42] badge after the branch name ***",
  wt_row and wt_row.text:find("pr-42", 1, true) ~= nil and wt_row.text:find("[#42]", 1, true) ~= nil,
  wt_row and wt_row.text)
ok("r9: [#42] sits BEFORE the watch marker",
  wt_row and wt_row.text:find("%[#42%].*watched") ~= nil, wt_row and wt_row.text)
ok("r9: *** there is NO standalone PR row any more ***",
  select(1, line_of_row(function(r) return r.kind == "pr" end)) == nil)
ok("r9: open PR badge is painted AutoCoreGitAdded on the worktree line",
  wt_lnum and hls_on_line(tbuf, wt_lnum)["AutoCoreGitAdded"] == true)

-- The review shows in the reviews SECTION, tagged → #42 (not under a PR row).
local _, rev_row = line_of_row(function(r) return r.kind == "review" and r.review and r.review.pr == 42 end)
ok("r9: review appears in the reviews section", rev_row ~= nil)
ok("r9: *** review row is tagged → #42 ***",
  rev_row and rev_row.text:find("→ #42", 1, true) ~= nil, rev_row and rev_row.text)
ok("r9: review row carries the severity badge too",
  rev_row and rev_row.text:find("[must-fix]", 1, true) ~= nil, rev_row and rev_row.text)
ok("r9: review row has NO parent_pr (it is not under a PR entry)",
  rev_row and rev_row.parent_pr == nil)

-- ── 5. Badge COLOUR carries PR state (draft / closed) ──
mock_pr.draft = true
tree.invalidate(nil); tree.on_focus(nil, tbuf)
local d_lnum = line_of_row(function(r) return r.kind == "worktree" end)
ok("r9: DRAFT PR badge is painted AutoCoreReviewFrame",
  d_lnum and hls_on_line(tbuf, d_lnum)["AutoCoreReviewFrame"] == true)

mock_pr.draft = false; mock_pr.state = "closed"
tree.invalidate(nil); tree.on_focus(nil, tbuf)
local c_lnum = line_of_row(function(r) return r.kind == "worktree" end)
ok("r9: CLOSED PR badge is painted AutoCoreGitDeleted",
  c_lnum and hls_on_line(tbuf, c_lnum)["AutoCoreGitDeleted"] == true)
mock_pr.state = "open"

-- ── 6. [posted] badge comes from the backend receipt query ──
posted_flag = false
tree.invalidate(nil); tree.on_focus(nil, tbuf)
local _, unposted = line_of_row(function(r) return r.kind == "review" end)
ok("r9: an UNPOSTED review has no [posted] badge",
  unposted and unposted.text:find("[posted]", 1, true) == nil, unposted and unposted.text)
posted_flag = true
tree.invalidate(nil); tree.on_focus(nil, tbuf)
local _, posted = line_of_row(function(r) return r.kind == "review" end)
ok("r9: *** a POSTED review shows [posted] (from review_posted, not the JSON) ***",
  posted and posted.text:find("[posted]", 1, true) ~= nil, posted and posted.text)
posted_flag = false
tree.invalidate(nil); tree.on_focus(nil, tbuf)

-- ── 7. Dissociation still works on a review carrying meta.pr ──
local _, rrow = line_of_row(function(r) return r.kind == "review" and r.review and r.review.pr == 42 end)
local confirm_called = false
package.loaded["auto-core.ui.float"] = {
  confirm = function(prompt, opts)
    confirm_called = true
    ok("r9: dissociation prompt names PR #42 and keeps disk files",
      prompt:find("Dissociate review", 1, true) ~= nil and prompt:find("from PR #42", 1, true) ~= nil
        and prompt:find("Files on disk will NOT be deleted", 1, true) ~= nil, prompt)
    opts.on_choice("yes")
  end,
}
notes = {}
tree.remove_review(rrow)
ok("r9: float.confirm called for dissociation (via review.pr)", confirm_called)
ok("r9: dissociation notification logged",
  last_note() and last_note().msg:find("dissociated review", 1, true) ~= nil, vim.inspect(notes))
local after = vim.json.decode(table.concat(vim.fn.readfile(mock_review.path), "\n"))
ok("r9: review JSON still on disk", vim.fn.filereadable(mock_review.path) == 1)
ok("r9: review JSON pr field cleared", after.pr == nil)
-- restore
after.pr = 42
vim.fn.writefile({ vim.json.encode(vim.tbl_extend("force", after, {
  comments = { { path = "foo.lua", line = 10, severity = "must-fix", body = "Fix this" } } })) }, mock_review.path)

-- ── 8. S = submit_review posts ONE review entry's findings ──
local submit_pr, submit_reviews = nil, nil
pr_mod.post_feedback = function(_, pr_number, reviews)
  submit_pr, submit_reviews = pr_number, reviews
  return { ok = true }
end
notes = {}
tree.submit_review({ kind = "review", repo = mock_repo, review = mock_review })
ok("r9: *** submit_review posts to the review's PR (#42) ***", submit_pr == 42, tostring(submit_pr))
ok("r9: *** it submits exactly ONE review, with the comments ARRAY loaded from JSON ***",
  type(submit_reviews) == "table" and #submit_reviews == 1
    and type(submit_reviews[1].comments) == "table" and #submit_reviews[1].comments == 1,
  vim.inspect(submit_reviews))
ok("r9: submit_review reported success",
  last_note() and last_note().msg:find("submitted", 1, true) ~= nil, vim.inspect(notes))

-- S on a review with NO PR refuses (nothing to submit to)
notes = {}
tree.submit_review({ kind = "review", repo = mock_repo, review = { name = "x", path = mock_review.path } })
ok("r9: S on a review with no PR warns and posts nothing",
  last_note() and last_note().msg:find("not associated with a PR", 1, true) ~= nil, vim.inspect(notes))

-- S off a review row (e.g. a worktree) refuses
notes = {}
tree.submit_review({ kind = "worktree", repo = mock_repo, worktree = mock_wt })
ok("r9: S off a review entry warns",
  last_note() and last_note().msg:find("put the cursor on a review entry", 1, true) ~= nil, vim.inspect(notes))

-- ── 9. N = create_pr_for_worktree (two sequential prompts) ──
local create_title = nil
pr_mod.create_pr = function(_, opts) create_title = opts.title; return { ok = true, pr = { number = 99 } } end
local orig_input = vim.ui.input
vim.ui.input = function(opts, cb)
  cb(opts.prompt:find("PR Title", 1, true) and "New Test PR" or "Body text")
end
notes = {}
tree.create_pr_for_worktree({ repo = mock_repo, worktree = mock_wt })
ok("r9: N prompts title then body and creates the PR", create_title == "New Test PR")
ok("r9: N reported success",
  last_note() and last_note().msg:find("created PR #99", 1, true) ~= nil, vim.inspect(notes))

-- A created PR whose ASSOCIATION could not be written. The PR is open either
-- way, so the action succeeds — but the badge, `S`, and every review's `pr`
-- tag would simply be absent, which is the failure mode this whole change is
-- about. It must be said out loud rather than inferred from a missing badge.
pr_mod.create_pr = function(_, opts)
  create_title = opts.title
  return { ok = true, pr = { number = 99 }, branch = "feat/x",
           kb_doc_error = "mkdir: permission denied" }
end
notes = {}
tree.create_pr_for_worktree({ repo = mock_repo, worktree = mock_wt })
do
  local all = vim.tbl_map(function(n) return n.msg end, notes)
  local joined = table.concat(all, "\n")
  ok("assoc: N still reports the PR as created when the association fails",
    joined:find("created PR #99", 1, true) ~= nil, joined)
  ok("assoc: *** N WARNS that the PR is open but not associated ***",
    joined:find("NOT associated with", 1, true) ~= nil, joined)
  ok("assoc: the warning names the branch and the write error",
    joined:find(mock_wt.branch, 1, true) ~= nil
      and joined:find("permission denied", 1, true) ~= nil, joined)
  local warned = false
  for _, n in ipairs(notes) do
    if n.msg:find("NOT associated", 1, true) and n.level == vim.log.levels.WARN then warned = true end
  end
  ok("assoc: it is a WARN, not another INFO lost in the success toast", warned,
    vim.inspect(notes))
end
-- An OLDER worktree.nvim reports no association at all; the guarded read must
-- not turn that into a spurious warning.
pr_mod.create_pr = function(_, opts) create_title = opts.title; return { ok = true, pr = { number = 99 } } end
notes = {}
tree.create_pr_for_worktree({ repo = mock_repo, worktree = mock_wt })
ok("assoc: no kb_doc_error field means no warning",
  table.concat(vim.tbl_map(function(n) return n.msg end, notes), "\n")
    :find("NOT associated", 1, true) == nil, vim.inspect(notes))

-- ── 9c. credential PREFLIGHT gates G / N / S (r10.7) ──
do
  -- The gate must fire BEFORE the prompt. A refusal after the user has typed
  -- a PR number (or a title AND a body) is the failure this replaces, so the
  -- cells assert that ui.input was never REACHED — not merely that an error
  -- was reported.
  local creds = require("worktree.credentials")
  local orig_describe = creds.describe
  local prompted = 0
  local orig_input = vim.ui.input
  vim.ui.input = function(_, cb) prompted = prompted + 1; cb(nil) end

  creds.describe = function()
    return { configured = false, why = "no profile for acme__x",
             hint = ":WorktreeAuth set github.com command pass show <path/to/token>" }
  end

  notes = {}; prompted = 0
  tree.get_pr_for_repo({ kind = "repo", repo = mock_repo })
  ok("preflight: *** G refuses BEFORE prompting when no token resolves ***",
    prompted == 0, prompted .. " prompts")
  ok("preflight: and the refusal names the exact :WorktreeAuth line",
    last_note() and last_note().msg:find(":WorktreeAuth set github.com", 1, true) ~= nil,
    vim.inspect(notes))
  ok("preflight: the refusal names the action and the repo",
    last_note() and last_note().msg:find("GetPR", 1, true) ~= nil
      and last_note().msg:find(mock_repo.slug, 1, true) ~= nil, vim.inspect(notes))

  notes = {}; prompted = 0
  tree.create_pr_for_worktree({ kind = "worktree", repo = mock_repo, worktree = mock_wt })
  ok("preflight: *** N refuses before the title AND body prompts ***",
    prompted == 0 and last_note() and last_note().msg:find("CreatePR", 1, true) ~= nil,
    prompted .. " prompts / " .. vim.inspect(notes))

  -- Configured: the gate must be TRANSPARENT. A preflight that also blocks
  -- the working case is worse than none.
  creds.describe = function()
    return { configured = true, key = "github.com", kind = "env",
             var = "GITHUB_TOKEN", source = "environment" }
  end
  notes = {}; prompted = 0
  tree.get_pr_for_repo({ kind = "repo", repo = mock_repo })
  ok("preflight: *** with a token configured, G prompts as before ***",
    prompted == 1, prompted .. " prompts / " .. vim.inspect(notes))

  -- An OLDER worktree.nvim cannot report; the keys must keep working rather
  -- than being gated by the absence of the reporter.
  creds.describe = nil
  notes = {}; prompted = 0
  tree.get_pr_for_repo({ kind = "repo", repo = mock_repo })
  ok("preflight: *** no describe() at all does NOT gate the key ***",
    prompted == 1, prompted .. " prompts / " .. vim.inspect(notes))

  creds.describe = orig_describe
  vim.ui.input = orig_input
end

-- ── 10. G = get_pr_for_repo: success + error surfacing (C10-C12) ──
local fetched_num = nil
pr_mod.fetch_and_create_worktree = function(_, n) fetched_num = n; return { ok = true, branch = "pr-55" } end
vim.ui.input = function(_, cb) cb("55") end
notes = {}
tree.get_pr_for_repo({ repo = mock_repo })
ok("r9: G fetches a valid PR number", fetched_num == 55)
ok("r9: G reported success",
  last_note() and last_note().msg:find("fetched PR #55", 1, true) ~= nil, vim.inspect(notes))

-- C10: cancel (nil) is announced, not silent
vim.ui.input = function(_, cb) cb(nil) end
notes = {}
tree.get_pr_for_repo({ repo = mock_repo })
ok("r9 C10: *** a cancelled GetPR is announced, not silent ***",
  last_note() and last_note().msg:find("cancelled", 1, true) ~= nil, vim.inspect(notes))

-- C12: a non-numeric entry is rejected before any forge call
fetched_num = nil
vim.ui.input = function(_, cb) cb("not-a-number") end
notes = {}
tree.get_pr_for_repo({ repo = mock_repo })
ok("r9 C12: *** a non-numeric PR entry is rejected ***",
  last_note() and last_note().msg:find("is not a PR number", 1, true) ~= nil, vim.inspect(notes))
ok("r9 C12: and NO forge call was made for bad input", fetched_num == nil)

-- C11: a raising fetch is caught and surfaced, not left silent
pr_mod.fetch_and_create_worktree = function() error("boom from curl") end
vim.ui.input = function(_, cb) cb("77") end
notes = {}
tree.get_pr_for_repo({ repo = mock_repo })
ok("r9 C11: *** a raising fetch is caught and surfaced ***",
  last_note() and last_note().msg:find("errored", 1, true) ~= nil
    and last_note().msg:find("boom from curl", 1, true) ~= nil, vim.inspect(notes))

-- MF2: the :AutoFinderGetPR {arg} COMMAND path routes through the SAME
-- validation/guard helper as interactive `G` (it used to pass the arg straight
-- to the forge and let a raised fetch escape).
local cmd_fetch = nil
pr_mod.fetch_and_create_worktree = function(_, n) cmd_fetch = n; return { ok = true, branch = "pr-" .. tostring(n) } end
notes = {}
tree.get_pr_command({ fargs = { "abc" } })
ok("r9 MF2: *** command rejects a non-numeric arg (no forge call) ***",
  cmd_fetch == nil and last_note() and last_note().msg:find("is not a PR number", 1, true) ~= nil,
  vim.inspect(notes))

pr_mod.fetch_and_create_worktree = function(_, n) cmd_fetch = n; return { ok = false, error = "no such PR" } end
cmd_fetch = nil
notes = {}
tree.get_pr_command({ fargs = { "88" } })
ok("r9 MF2: command surfaces a returned fetch failure",
  cmd_fetch == 88 and last_note() and last_note().msg:find("could not fetch PR #88", 1, true) ~= nil,
  vim.inspect(notes))

pr_mod.fetch_and_create_worktree = function() error("boom from command") end
notes = {}
tree.get_pr_command({ fargs = { "89" } })
ok("r9 MF2: *** command catches a raised fetch and surfaces it ***",
  last_note() and last_note().msg:find("errored", 1, true) ~= nil
    and last_note().msg:find("boom from command", 1, true) ~= nil,
  vim.inspect(notes))

vim.ui.input = orig_input

print(string.format("%d passed, %d failed", pass, fail))
vim.cmd(fail > 0 and "cq" or "qa!")
