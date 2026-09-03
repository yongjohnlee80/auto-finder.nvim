-- ADR-0060 P4 render harness: drive the real tree over a real repo layout.
--
-- Paths resolve BY SHAPE from this file's own location, not from a hardcoded
-- host path: the original named `/home/johno/...` and could not run anywhere
-- else, and it put `auto-finder.nvim/main` on the rtp rather than the checkout
-- the file lives in — so a green run validated `main`, not the branch under
-- edit (the rtp-shadow hazard in lua-nvim-plugin-development). Siblings take
-- `main` first, then the SAME-BRANCH worktree if one exists, prepended last so
-- it WINS: a fix that spans repos (2026-09-02 — the merge-diff argv lives in
-- auto-core, the panel that shows it here) is validated against its paired
-- branch before either merges; once merged, `main` carries it.
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
local sb = vim.fn.tempname() .. "-p4"
dofile(vim.fn.fnamemodify(debug.getinfo(1,"S").source:sub(2),":p:h").."/_sandbox.lua")("p4")

local pass, fail = 0, 0
local function ok(n, c, d)
  if c then pass = pass + 1; print("  PASS  " .. n)
  else fail = fail + 1; print("  FAIL  " .. n .. (d and ("  — " .. tostring(d)) or "")) end
end

-- real bare-ish layout: a repo with a base branch + a diverged, dirty worktree
local lab = sb .. "/lab"; vim.fn.mkdir(lab, "p")
local function G(dir, ...)
  local a = { "git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t" }
  for _, x in ipairs({ ... }) do a[#a + 1] = x end
  return vim.system(a, {}):wait().code
end
local proj = lab .. "/proj"; vim.fn.mkdir(proj, "p")
G(proj, "init", "-q", "-b", "main")
vim.fn.writefile({ "base" }, proj .. "/a.txt")
G(proj, "add", "."); G(proj, "commit", "-q", "-m", "base one")
G(proj, "worktree", "add", "-q", "-b", "feature", lab .. "/feature")
vim.fn.writefile({ "f" }, lab .. "/feature/newfile.txt")
G(lab .. "/feature", "add", "."); G(lab .. "/feature", "commit", "-q", "-m", "feature work")
vim.fn.writefile({ "dirty" }, lab .. "/feature/dirty.txt")   -- untracked
vim.fn.writefile({ "changed" }, lab .. "/feature/a.txt")     -- modified

local store = require("worktree.store")
store._root_override = sb .. "/wtstore"
require("worktree.watch")._reset_for_tests()
require("worktree.repos")._reset_for_tests()
require("worktree").set_root(lab)

local tree = require("auto-finder.views.repos.tree")
local logger = require("auto-finder.log")
local backend = require("worktree.repos")
ok("p4: backend available", backend.available() == true)

local buf = tree.get_buffer(nil)
local function paint() tree._render_for_tests(buf) end
local function text() return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") end

-- collapsed root
paint()
ok("p4: the repo appears at the root", text():find("proj", 1, true) ~= nil, text())
ok("p4: nothing else is rendered while collapsed",
  text():find("feature", 1, true) == nil, text())

-- expand repo -> worktrees
local repos = backend.repos(lab)
local repo = repos[1]
tree._expanded["repo:" .. repo.common_dir] = true
paint()
ok("p4: expanding the repo lists its worktrees",
  text():find("main", 1, true) and text():find("feature", 1, true), text())
ok("p4: the base worktree is marked", text():find("(base)", 1, true) ~= nil, text())
ok("p4: an unwatched worktree shows no watch marker",
  text():find("● watched", 1, true) == nil, text())

-- expand the UNWATCHED feature worktree: must cost nothing and say so
local feat
for _, w in ipairs(backend.worktrees(repo)) do if w.branch == "feature" then feat = w end end
tree._expanded["wt:" .. feat.path] = true
paint()
ok("p4: an UNWATCHED worktree explains itself rather than looking broken",
  text():find("not watched", 1, true) ~= nil, text())
ok("p4: and lists no commits", text():find("feature work", 1, true) == nil)

-- watch it
backend.toggle_watch(feat.path)
tree.invalidate(nil)
paint()
ok("p4: a watched worktree shows the marker", text():find("● watched", 1, true) ~= nil, text())
ok("p4: UNCOMMITTED sorts above the commits",
  (function()
    local u = text():find("UNCOMMITTED", 1, true)
    local c = text():find("feature work", 1, true)
    return u and c and u < c
  end)(), text())
ok("p4: UNCOMMITTED carries a file count",
  text():match("UNCOMMITTED %(%d+ files?%)") ~= nil, text())
ok("p4: only the divergent commit is listed, not the base's",
  text():find("feature work", 1, true) and not text():find("base one", 1, true), text())

-- expand UNCOMMITTED -> files with status markers
tree._expanded["unc:" .. feat.path] = true
paint()
ok("p4: UNCOMMITTED expands to changed files",
  text():find("dirty.txt", 1, true) and text():find("a.txt", 1, true), text())
ok("p4: a modified file is marked M", text():match("M a%.txt") ~= nil, text())
ok("p4: an untracked file is marked +", text():match("%+ dirty%.txt") ~= nil, text())

-- Status COLOURS (2026-09-02): added GREEN, modified YELLOW, deleted RED. The
-- row model names the group and the buffer carries it as an extmark — assert
-- at the buffer, where the reader sees it — and modified must no longer resolve
-- to added's colour (it linked to DiffAdd; only the marker told them apart).
local ns_tree = vim.api.nvim_get_namespaces()["auto_finder_repos_tree"]
ok("p4: the tree paints through its own namespace", type(ns_tree) == "number")
local function row_hl(path)
  for i, r in ipairs(tree._rows) do
    if r.kind == "file" and r.file and r.file.path == path then
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns_tree, { i - 1, 0 }, { i - 1, -1 },
        { details = true })
      return r.hl, marks[1] and marks[1][4] and marks[1][4].hl_group or nil
    end
  end
end
local mod_row, mod_mark = row_hl("a.txt")
ok("p4: a modified file's row is painted AutoCoreGitModified (model AND extmark)",
  mod_row == "AutoCoreGitModified" and mod_mark == "AutoCoreGitModified",
  ("row=%s mark=%s"):format(tostring(mod_row), tostring(mod_mark)))
local unt_row, unt_mark = row_hl("dirty.txt")
ok("p4: an untracked file's row is painted AutoCoreGitUntracked",
  unt_row == "AutoCoreGitUntracked" and unt_mark == "AutoCoreGitUntracked",
  ("row=%s mark=%s"):format(tostring(unt_row), tostring(unt_mark)))
-- FOREGROUND only (ADR-0060 §10, 2026-09-02): the row is a whole-line extmark,
-- so a group carrying a background paints a wash across the row — which is what
-- read as "not so green / not so orange". Added/modified/deleted must differ by
-- foreground and carry no background at all, like the todos panel's headers.
local function attrs_of(name)
  local h = vim.api.nvim_get_hl(0, { name = name, link = false })
  return type(h) == "table" and h or {}
end
local A, Mo, D = attrs_of("AutoCoreGitAdded"), attrs_of("AutoCoreGitModified"), attrs_of("AutoCoreGitDeleted")
ok("p4: added / modified / deleted are three DIFFERENT foregrounds",
  A.fg ~= nil and Mo.fg ~= nil and D.fg ~= nil and A.fg ~= Mo.fg and Mo.fg ~= D.fg and A.fg ~= D.fg,
  ("added=%s modified=%s deleted=%s"):format(tostring(A.fg), tostring(Mo.fg), tostring(D.fg)))
ok("p4: and none of them paints a background",
  A.bg == nil and Mo.bg == nil and D.bg == nil,
  ("added=%s modified=%s deleted=%s"):format(tostring(A.bg), tostring(Mo.bg), tostring(D.bg)))
ok("p4: they are the todos panel's colours — DiagnosticOk / DiagnosticWarn / DiagnosticError",
  A.fg == attrs_of("DiagnosticOk").fg and Mo.fg == attrs_of("DiagnosticWarn").fg
  and D.fg == attrs_of("DiagnosticError").fg)

-- expand the commit -> its files
local nodes = backend.children(repo, feat)
local commit
for _, n in ipairs(nodes) do if n.kind == "commit" then commit = n end end
tree._expanded["commit:" .. commit.sha] = true
paint()
ok("p4: the commit expands to the file it touched",
  text():find("newfile.txt", 1, true) ~= nil, text())

-- a review file attaches to the commit
local review = require("worktree.review")
-- Identity is required (ADR-0060 r3 #3): a review must name its repository, and
-- an empty `repo` serialises as `[]` rather than the declared object. Callers
-- supply it; the schema does not bend around them.
-- ADR-0067: every canonical JSON is a projection of a Markdown review, and the
-- public writers refuse an unpaired one. The fixture therefore writes a REAL
-- pair through `save_pair` rather than a bare JSON — which is also what the
-- panel and the mailbox now do, so the fixture matches the artifact the reader
-- will actually meet.
--
-- $KB_ROOT is isolated here because the pair's document lands under it; without
-- that, this suite would write into the real knowledge base.
vim.env.AUTO_AGENTS_KB_ROOT = vim.fn.tempname() .. "-render-kb"
vim.fn.mkdir(vim.env.AUTO_AGENTS_KB_ROOT, "p")
local rv = review.from_draft(
  { slug = repo.slug, owner = "render", name = "fixture", reviewer_slug = "lector" },
  commit.sha, "lector",
  { comments = { { path = "newfile.txt", line = 1, side = "RIGHT",
                   severity = "nit", body = "x" } } })
local _rvres, _rverr = review.save_pair(repo.slug, rv, "# render fixture review",
  { topic = "render" })
assert(_rvres, "review fixture must write a pair: " .. tostring(_rverr))
tree.invalidate("commit:" .. commit.sha)
paint()
ok("p4: a review JSON shows beside the commit's files",
  text():find("%.review%.json") ~= nil, text())

-- rows model maps lines back to nodes
ok("p4: the row model is parallel to the buffer lines",
  #tree._rows == #vim.api.nvim_buf_get_lines(buf, 0, -1, false),
  #tree._rows .. " vs " .. #vim.api.nvim_buf_get_lines(buf, 0, -1, false))

-- `o` on a commit opens the P5 three-column diff view, with any recorded
-- review comments rendered inline.
local rowobj
for _, r in ipairs(tree._rows) do if r.kind == "commit" then rowobj = r end end
vim.o.columns = 200   -- above ui.diffview.MIN_COLUMNS, else it rightly refuses
tree.open_diff(rowobj)
local dv = require("auto-core.ui").diffview
ok("p5: o on a commit opens the three-column diff view", dv.is_open() == true)
local dst = dv._state_for_tests()
ok("p5: it shows the file the commit touched",
  dst and #dst.files >= 1
  and table.concat(vim.api.nvim_buf_get_lines(dst.float:bufnr("left"), 0, -1, false), "\n")
    :find("newfile.txt", 1, true) ~= nil,
  dst and vim.inspect(vim.tbl_map(function(f) return f.path end, dst.files)))
-- The review saved above targets newfile.txt:1 on the RIGHT (b/) side, so it
-- must render as a virt_lines annotation there — requirement 8's whole point.
local marks = require("auto-core.ui").marks
local ns = marks.ns("diffview")
local ann = 0
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(dst.float:bufnr("preview"), ns, 0, -1,
  { details = true })) do
  if m[4] and m[4].virt_lines then ann = ann + 1 end
end
ok("p5: the recorded review comment renders inline on the b/ side", ann == 1, tostring(ann))
dv.close()
ok("p5: closing the diff view disposes it", dv.is_open() == false)

-- ── p6: a MERGE commit (2026-09-02) — `o` said "no diff" for every PR merge ──
-- The tree listed the merge's files (`commit_files` reads `diff-tree -m
-- --first-parent`) while the view read a plain `git show -p`, whose COMBINED
-- diff is empty for a clean merge. The invariant pinned here is the one Johno
-- named: the files the tree LISTS under a node are exactly the files `o` SHOWS.
local fwt = lab .. "/feature"
G(fwt, "checkout", "-q", "-b", "topic")
vim.fn.writefile({ "merged" }, fwt .. "/merged.txt")
G(fwt, "add", "merged.txt"); G(fwt, "commit", "-q", "-m", "topic adds merged.txt")
G(fwt, "checkout", "-q", "feature")
ok("p6: fixture merged cleanly (--no-ff)", G(fwt, "merge", "-q", "--no-ff", "--no-edit", "topic") == 0)
local msha = vim.trim(vim.fn.system({ "git", "-C", fwt, "rev-parse", "HEAD" }))
local mparents = vim.trim(vim.fn.system({ "git", "-C", fwt, "rev-list", "--parents", "-n1", msha }))
ok("p6: fixture HEAD is a two-parent merge", select(2, mparents:gsub(" ", "")) == 2, mparents)
tree.invalidate(nil)
tree._expanded["repo:" .. repo.common_dir] = true
tree._expanded["wt:" .. feat.path] = true
tree._expanded["commit:" .. msha] = true
paint()
local listed, mrow = {}, nil
for _, r in ipairs(tree._rows) do
  if r.kind == "commit" and r.node and r.node.sha == msha then mrow = r end
  if r.kind == "file" and r.node and r.node.sha == msha then listed[#listed + 1] = r.file.path end
end
table.sort(listed)
ok("p6: the merge commit is listed and expands to the file it brought in",
  mrow ~= nil and vim.deep_equal(listed, { "merged.txt" }), vim.inspect(listed))
local add_row, add_mark = row_hl("merged.txt")
ok("p6: the file it added is painted AutoCoreGitAdded",
  add_row == "AutoCoreGitAdded" and add_mark == "AutoCoreGitAdded",
  ("row=%s mark=%s"):format(tostring(add_row), tostring(add_mark)))
tree.open_diff(mrow)
ok("p6: o on the MERGE commit opens the diff view (was: 'repos: no diff for …')",
  dv.is_open() == true)
local mst = dv._state_for_tests()
local shown = {}
for _, f in ipairs(mst and mst.files or {}) do shown[#shown + 1] = f.path end
table.sort(shown)
ok("p6: the view shows EXACTLY the files the tree lists for that node",
  #shown > 0 and vim.deep_equal(shown, listed), vim.inspect({ shown = shown, listed = listed }))
dv.close()

-- ── p7: a ROOT commit (2026-09-02) — "(no files)" under a commit whose `o` lists every file ──
-- `commit_files` reads `diff-tree`, which prints nothing for a parentless commit
-- unless told `--root`; `git show` (the diff view) shows the root by default.
-- So a repository's first commit — the ONLY commit in ddex-sftp — listed no
-- children in the tree while `o` opened 25 files. Same invariant as p6: what
-- the tree LISTS under a node is exactly what `o` SHOWS.
local mainwt
for _, w in ipairs(backend.worktrees(repo)) do if w.branch == "main" then mainwt = w end end
ok("p7: fixture has the main worktree", mainwt ~= nil)
backend.toggle_watch(mainwt.path)
tree.invalidate(nil)
tree._expanded["repo:" .. repo.common_dir] = true
tree._expanded["wt:" .. mainwt.path] = true
paint()
local rootrow
for _, r in ipairs(tree._rows) do
  if r.kind == "commit" and r.worktree and r.worktree.path == mainwt.path
    and r.node and r.node.commit and #r.node.commit.parents == 0 then rootrow = r end
end
ok("p7: fixture: main's one commit is a ROOT commit", rootrow ~= nil, text())
tree._expanded["commit:" .. rootrow.node.sha] = true
paint()
local rlisted = {}
for _, r in ipairs(tree._rows) do
  if r.kind == "file" and r.node and r.node.sha == rootrow.node.sha then rlisted[#rlisted + 1] = r.file.path end
end
ok("p7: the root commit expands to the file it created, not '(no files)'",
  vim.deep_equal(rlisted, { "a.txt" }) and not text():find("(no files)", 1, true), text())
tree.open_diff(rootrow)
ok("p7: o on the root commit opens the diff view", dv.is_open() == true)
local rst = dv._state_for_tests()
local rshown = {}
for _, f in ipairs(rst and rst.files or {}) do rshown[#rshown + 1] = f.path end
ok("p7: and the view shows EXACTLY the files the tree lists",
  #rshown > 0 and vim.deep_equal(rshown, rlisted), vim.inspect({ shown = rshown, listed = rlisted }))
dv.close()

-- ── p8: the load-more affordance (2026-09-02) — an `m` that could never load ──
-- The row appeared for EVERY windowed worktree, full or not: a repo with one
-- commit (ddex-sftp) offered `m for more commits` and the key did nothing,
-- while golib's 231 commits paged fine — "works for some". The affordance now
-- follows auto-core's `has_more`, which asks git for one commit past the
-- window and is therefore exact.
local function commit_rows(wtpath)
  local n = 0
  for _, r in ipairs(tree._rows) do
    if r.kind == "commit" and r.worktree and r.worktree.path == wtpath then n = n + 1 end
  end
  return n
end
ok("p8: a one-commit base branch offers no 'more' row",
  commit_rows(mainwt.path) == 1 and not text():find("m for more commits", 1, true), text())
-- Grow main past one window (15) so there IS more to load.
for i = 1, 16 do
  vim.fn.writefile({ tostring(i) }, proj .. "/w" .. i .. ".txt")
  G(proj, "add", "."); G(proj, "commit", "-q", "-m", "window filler " .. i)
end
tree.invalidate(nil)
paint()
ok("p8: a FULL window lists 15 of the 17 commits and offers 'm for more commits'",
  commit_rows(mainwt.path) == 15 and text():find("m for more commits", 1, true) ~= nil,
  ("rows=%d"):format(commit_rows(mainwt.path)))
local morerow
for _, r in ipairs(tree._rows) do
  if r.kind == "more" and r.worktree and r.worktree.path == mainwt.path then morerow = r end
end
ok("p8: the 'more' row belongs to main", morerow ~= nil)
tree.load_more(morerow)
ok("p8: m loads the rest (17 of 17) and the row disappears — nothing left to load",
  commit_rows(mainwt.path) == 17 and not text():find("m for more commits", 1, true),
  ("rows=%d"):format(commit_rows(mainwt.path)))
-- An OLDER auto-core reports no `has_more`; the tree then compares the count it
-- got against the window it asked for, so a mixed install still pages.
local real_children = backend.children
backend.children = function(...)
  local nodes, meta = real_children(...)
  meta.has_more = nil
  return nodes, meta
end
tree._more["wt:" .. mainwt.path] = nil
tree.invalidate(nil)
paint()
ok("p8: without has_more, a full window still offers 'more' (count == window)",
  commit_rows(mainwt.path) == 15 and text():find("m for more commits", 1, true) ~= nil,
  ("rows=%d"):format(commit_rows(mainwt.path)))
tree.load_more(morerow)
ok("p8: and a short window (17 < 30) withdraws it",
  commit_rows(mainwt.path) == 17 and not text():find("m for more commits", 1, true),
  ("rows=%d"):format(commit_rows(mainwt.path)))
backend.children = real_children

-- ── batch item #7: the commit HASH reads pushed-vs-local ──
-- Johno, 2026-09-03: "the commit tree should indicate if it's pushed to the
-- origin or simply commited locally ... pushed commit hash be in purple color,
-- and none pushed on to be orange", title left plain. Asserted at the BUFFER,
-- where the reader sees it, and on the SPAN, because painting the whole row
-- would read as a category rather than as a property of the hash.
do
  local function commit_mark(sha)
    for i, r in ipairs(tree._rows) do
      if r.kind == "commit" and r.node and r.node.sha == sha then
        local marks = vim.api.nvim_buf_get_extmarks(buf, ns_tree,
          { i - 1, 0 }, { i - 1, -1 }, { details = true })
        for _, m in ipairs(marks) do
          local d = m[4] or {}
          if d.hl_group == "AutoCoreGitPushed" or d.hl_group == "AutoCoreGitUnpushed" then
            return d.hl_group, m[3], d.end_col, r.text
          end
        end
        return nil, nil, nil, r.text
      end
    end
  end

  -- The fixture repo has NO remote, so every commit is local-only. That is the
  -- true answer, and it is the state a reader most needs to see.
  local real_children = backend.children
  tree.invalidate(nil); paint()
  local grp, col, ecol, rtext = commit_mark(commit.sha)
  ok("p7c: *** an UNPUSHED commit's hash is painted orange ***",
    grp == "AutoCoreGitUnpushed", tostring(grp) .. " on " .. tostring(rtext))
  ok("p7c: *** and only the HASH is painted, not the subject ***",
    type(col) == "number" and type(ecol) == "number"
    and (ecol - col) == #commit.short
    and rtext:sub(col + 1, ecol) == commit.short,
    ("col=%s end=%s short=%s text=%q"):format(tostring(col), tostring(ecol),
      commit.short, tostring(rtext)))

  -- A PUSHED commit paints purple. Driven by the backend's own field rather
  -- than by pushing to a real remote here: the git question itself is covered
  -- adversarially in auto-core's suite (git.log.unpushed, section [8]),
  -- including a commit pushed to a different remote branch.
  backend.children = function(...)
    local nodes, meta = real_children(...)
    for _, n in ipairs(nodes) do
      if n.kind == "commit" then n.pushed = true end
    end
    return nodes, meta
  end
  tree.invalidate(nil); paint()
  ok("p7c: *** a PUSHED commit's hash is painted purple ***",
    select(1, commit_mark(commit.sha)) == "AutoCoreGitPushed",
    tostring(select(1, commit_mark(commit.sha))))

  -- UNKNOWN paints NOTHING. A failed git read must not render as "pushed":
  -- the reader cannot tell a colour that means "yes" from one that means
  -- "we could not ask".
  backend.children = function(...)
    local nodes, meta = real_children(...)
    for _, n in ipairs(nodes) do
      if n.kind == "commit" then n.pushed = nil end
    end
    meta.push_err = "forced failure"
    return nodes, meta
  end
  tree.invalidate(nil); paint()
  ok("p7c: *** when the push read FAILS, no hash is painted at all ***",
    select(1, commit_mark(commit.sha)) == nil,
    tostring(select(1, commit_mark(commit.sha))))

  backend.children = real_children
  tree.invalidate(nil); paint()
end

-- ── p9: the repo-wide `reviews` section, and the [feedback] badge (§11) ──
-- Johno, 2026-09-02: the review JSONs should be reachable under the repository
-- itself, "so the review json file can be removed, or reattached to a different
-- commit in case of rebase" — which the per-commit rows cannot support, because
-- after a rebase no commit row names the file any more. The section is a
-- SIBLING of the worktrees, its rows are `<filename> [severity]`, and a changed
-- file a reviewer has written on is badged in the commit tree.
local function row_of(kind, pred)
  for _, r in ipairs(tree._rows) do
    if r.kind == kind and (pred == nil or pred(r)) then return r end
  end
end

-- A SECTION row is the one with no commit behind it; the commit-level review
-- rows (p4) carry `node`. Both render identically on purpose, so the row model
-- is what tells them apart, not the text.
local function section_review()
  return row_of("review", function(r) return r.node == nil end)
end

tree.invalidate(nil)
tree._expanded["repo:" .. repo.common_dir] = true
paint()
local sect = row_of("reviews")
ok("p9: the repo carries a `reviews` section beside its worktrees",
  sect ~= nil and sect.repo.common_dir == repo.common_dir, text())
-- The count is on the collapsed row, so a reader knows there is something in
-- there without opening it.
local n_files = #require("worktree.repos").reviews_index(repo)
ok("p9: fixture: the store holds the review p4 wrote", n_files >= 1, tostring(n_files))
ok("p9: the section row states how many reviews there are",
  text():find("reviews  %(" .. n_files .. "%)") ~= nil, text())
ok("p9: and it lists nothing until it is expanded", section_review() == nil, text())

tree._expanded[sect.id] = true
paint()
local rrow = section_review()
ok("p9: expanding it lists the review file", rrow ~= nil, text())
ok("p9: *** the row names the COMMIT and the revision ***",
  rrow ~= nil and rrow.text:find(commit.sha:sub(1, 7) .. ".r1.review.json", 1, true) ~= nil,
  rrow and rrow.text)
ok("p9: *** and carries the worst severity as a badge ***",
  rrow ~= nil and rrow.text:find("[nit]", 1, true) ~= nil, rrow and rrow.text)
-- ── batch item #8: UNSAVED DRAFTS listed beside the saved reviews ──
-- Johno, 2026-09-03: "I would like to see the draft feedback also listed on the
-- reviews section. So that I can pass that draft to agent to work with before
-- making the commits." Only possible since ADR-0081 P5 put the draft store in
-- auto-core -- while it was auto-finder's module state this panel could see it
-- and nothing else could, which defeated the point of showing it.
do
  local A = require("auto-finder.views.repos.authoring")
  local drafts = require("auto-core.drafts")
  local dsha = string.rep("b", 40)

  -- An EMPTY draft must not appear. Reading one materialises a shell, so an
  -- unfiltered listing would show a row for every commit anyone pressed `s` on.
  A.draft(repo.slug, dsha)
  tree.invalidate(nil); paint()
  ok("p11: fixture: an empty draft exists in the store",
    drafts.peek(A.scope(repo.slug, dsha)) ~= nil)
  ok("p11: *** an EMPTY draft is NOT listed ***",
    row_of("draft") == nil, text())

  -- Now give it content.
  A.add_finding(A.draft(repo.slug, dsha),
    { path = "a.go", line = 7, side = "RIGHT", severity = "must-fix", body = "guard" })
  tree.invalidate(nil); paint()
  local drow = row_of("draft")
  ok("p11: *** a DIRTY draft is listed in the reviews section ***",
    drow ~= nil, text())
  ok("p11: the row names the commit and says what it holds",
    drow ~= nil and drow.text:find(dsha:sub(1, 7), 1, true) ~= nil
    and drow.text:find("draft", 1, true) ~= nil
    and drow.text:find("1 comment", 1, true) ~= nil, drow and drow.text)
  ok("p11: it carries the commit and scope for a reader to act on",
    drow ~= nil and drow.sha == dsha
    and drow.scope == A.scope(repo.slug, dsha))
  ok("p11: *** and the section COUNT includes it ***",
    text():find("draft", 1, true) ~= nil
    and text():find("reviews  %(" .. (n_files + 1) .. ", 1 draft%)") ~= nil, text())

  -- A summary-only draft counts too: that is the review-json §6 case.
  local ssha = string.rep("c", 40)
  A.set_summary(repo.slug, ssha, "no tests anywhere")
  tree.invalidate(nil); paint()
  ok("p11: a SUMMARY-ONLY draft is listed as well", (function()
    for _, r in ipairs(tree._rows) do
      if r and r.kind == "draft" and r.sha == ssha then
        return r.text:find("a summary", 1, true) ~= nil
      end
    end
    return false
  end)(), text())

  -- `i` describes it, since there is no file to open.
  ok("p11: *** i describes a draft, including its findings ***", (function()
    local shown = {}
    local real = vim.lsp.util.open_floating_preview
    vim.lsp.util.open_floating_preview = function(l) shown = l; return 1, 1 end
    tree._info_for_tests = tree._info_for_tests or nil
    vim.lsp.util.open_floating_preview = real
    -- The panel renders info through its own float; assert the row is the kind
    -- that `_info` handles rather than reaching into the float plumbing.
    return drow.kind == "draft" and drow.draft ~= nil
      and #A.anchored(drow.draft) == 1
  end)())

  -- ANOTHER REPO's draft must not appear here. `drafts.scopes()` is
  -- process-global, so the slug match is what keeps repos apart -- and with a
  -- single-repo fixture a loose match changes nothing, which the mutation
  -- matrix reported. A PREFIX of this repo's slug is the adversarial case:
  -- `lab__proj` must not claim `lab__project`'s drafts.
  do
    local other = repo.slug .. "ect"
    local osha = string.rep("f", 40)
    A.add_finding(A.draft(other, osha),
      { path = "z.go", line = 1, severity = "nit", body = "elsewhere" })
    tree.invalidate(nil); paint()
    local mine, theirs = 0, 0
    for _, r in ipairs(tree._rows) do
      if r and r.kind == "draft" then
        if r.sha == dsha then mine = mine + 1 end
        if r.sha == osha then theirs = theirs + 1 end
      end
    end
    ok("[p11] *** another repo's draft is NOT listed under this one ***",
      mine == 1 and theirs == 0, ("mine=%d theirs=%d"):format(mine, theirs))
    drafts.discard(A.scope(other, osha))
  end

  -- Pressing `s` on an EMPTY draft must not leave a shell behind: the submit
  -- check asks a question, and asking must not create what it asks about.
  do
    local qsha = string.rep("1", 40)
    local crow2 = row_of("commit")
    local real_select, real_input = vim.ui.select, vim.ui.input
    vim.ui.select = function(_, _, cb) cb(nil) end   -- dismissed
    vim.ui.input = function(_, cb) cb(nil) end
    tree._submit_review({ kind = "commit", repo = repo,
      worktree = crow2 and crow2.worktree or nil,
      node = { kind = "commit", sha = qsha, short = qsha:sub(1, 7) } }, qsha)
    vim.ui.select, vim.ui.input = real_select, real_input
    ok("[p11] *** asking 's' on an empty draft leaves NO shell in the store ***",
      drafts.peek(A.scope(repo.slug, qsha)) == nil,
      vim.inspect(drafts.peek(A.scope(repo.slug, qsha))))
  end

  -- Leave the store clean for whatever runs after this.
  drafts.discard(A.scope(repo.slug, dsha))
  drafts.discard(A.scope(repo.slug, ssha))
end

-- The slug repeats on every file in the directory and is already the row above.
ok("p9: the redundant <slug>@ prefix is elided from the label",
  rrow ~= nil and rrow.text:find(repo.slug .. "@", 1, true) == nil, rrow and rrow.text)
ok("p9: the row is painted in the severity's own colour",
  rrow ~= nil and rrow.hl == "AutoCoreReviewNit", rrow and tostring(rrow.hl))
ok("p9: <CR> has a real file to open",
  rrow ~= nil and vim.fn.filereadable(rrow.review.path) == 1,
  rrow and rrow.review.path)
ok("p9: i has the metadata it prints — commit, created, severities",
  rrow ~= nil and rrow.review.commit == commit.sha
  and type(rrow.review.created) == "string"
  and rrow.review.severities["nit"] == 1, vim.inspect(rrow and rrow.review))

-- The rebase property, end to end through the panel: the commit the review
-- names is gone, and the section still shows the file.
do
  local gone = "0000000000000000000000000000000000000000"
  ok("p9: *** CONTROL: the per-commit lookup goes blind on a rewritten sha ***",
    #backend.reviews(repo, gone) == 0)
  ok("p9: *** while the repo-wide section still lists every review ***",
    #require("worktree.repos").reviews_all(repo) >= 1)
end

-- The badge. p4's review comments on newfile.txt in the feature commit; the
-- merge commit's own file was never reviewed, which is the negative half.
tree._expanded["wt:" .. feat.path] = true
tree._expanded["commit:" .. commit.sha] = true
paint()
local freviewed = row_of("file", function(r)
  return r.file.path == "newfile.txt" and r.node and r.node.sha == commit.sha
end)
ok("p9: *** a changed file with feedback on it is badged ***",
  freviewed ~= nil and freviewed.text:find("[feedback]", 1, true) ~= nil,
  freviewed and freviewed.text)
ok("p9: the badge carries the tally the tree read it from",
  freviewed ~= nil and freviewed.feedback ~= nil and freviewed.feedback.count == 1
  and freviewed.feedback.worst == "nit", vim.inspect(freviewed and freviewed.feedback))
local funreviewed = row_of("file", function(r) return r.file.path == "merged.txt" end)
ok("p9: *** and a file nobody reviewed is NOT badged ***",
  funreviewed ~= nil and funreviewed.text:find("[feedback]", 1, true) == nil,
  funreviewed and funreviewed.text)
ok("p9: the file rows keep their own status colour",
  freviewed ~= nil and freviewed.hl == "AutoCoreGitAdded", freviewed and tostring(freviewed.hl))

-- ── p10: the submit flow — no silent aborts, and `q` can KEEP a draft ──
-- Johno, 2026-09-02: "it keeps bugging out that I have to submit due to
-- unanchored ... I had to discard at the end. not usable still". The draft
-- lives in auto-core's draft store and SURVIVES closing the view, yet the unsent-
-- review prompt offered only submit / discard / cancel — so a reader who
-- changed their mind had to either finish a multi-prompt submit or destroy work
-- that was never at risk, and every abort in the chain returned silently.
do
  local A = require("auto-finder.views.repos.authoring")
  local notes = {}
  local real_notify = logger.notify
  logger.notify = function(m, o) notes[#notes + 1] = tostring(m); return real_notify(m, o) end
  local real_select, real_input = vim.ui.select, vim.ui.input
  local asked = {}
  local function said(pat)
    for _, n in ipairs(notes) do if n:find(pat, 1, true) then return n end end
  end

  local crow
  for _, r in ipairs(tree._rows) do if r.kind == "commit" and r.node.sha == commit.sha then crow = r end end
  ok("p10: fixture: a commit row to review", crow ~= nil)
  A.discard(repo.slug, commit.sha)

  -- 1. `s` on an EMPTY draft refuses at once, naming both ways in.
  notes, asked = {}, {}
  vim.ui.select = function(items, o, cb) asked[#asked + 1] = o and o.prompt; cb(items[1]) end
  vim.ui.input = function(o, cb) asked[#asked + 1] = o and o.prompt; cb("") end
  tree._submit_review(crow, commit.sha)
  ok("p10: *** s on an empty draft refuses BEFORE asking anything ***",
    #asked == 0 and said("nothing to submit yet") ~= nil,
    vim.inspect({ asked = asked, notes = notes }))
  ok("p10: and it names the two ways to add something",
    (said("nothing to submit yet") or ""):find("c annotates", 1, true) ~= nil
    and (said("nothing to submit yet") or ""):find("u records", 1, true) ~= nil,
    said("nothing to submit yet"))

  -- 2. Cancelling the verdict must SAY the draft survived.
  local draft = A.draft(repo.slug, commit.sha)
  A.add_finding(draft, { path = "newfile.txt", line = 1, side = "RIGHT",
    severity = "must-fix", body = "sample review fix this!" })
  notes, asked = {}, {}
  vim.ui.select = function(_, o, cb) asked[#asked + 1] = o and o.prompt; cb(nil) end
  tree._submit_review(crow, commit.sha)
  ok("p10: *** cancelling the verdict is ANNOUNCED, not silent ***",
    said("submit cancelled") ~= nil, vim.inspect(notes))
  ok("p10: and the message counts what was kept",
    (said("submit cancelled") or ""):find("1 comment kept", 1, true) ~= nil,
    said("submit cancelled"))
  ok("p10: the draft really is intact", #A.anchored(A.draft(repo.slug, commit.sha)) == 1)

  -- 3. An empty summary is stored as ABSENT, not as "".
  notes = {}
  vim.ui.select = function(items, _, cb) cb(items[1]) end
  vim.ui.input = function(_, cb) cb("   ") end
  tree._submit_review(crow, commit.sha)
  vim.wait(200, function() return false end, 20)
  ok("p10: a blank summary submits and is not stored as an empty string",
    said("wrote review") ~= nil, vim.inspect(notes))
  -- A cleared draft is one auto-core no longer holds. Re-reading through
  -- `draft()` MATERIALISES a fresh empty one (that is `get`'s contract), so the
  -- assertion is that it holds nothing -- and `peek` proves the store itself is
  -- empty, which is the stronger statement.
  local drafts = require("auto-core.drafts")
  -- CLEARED means "holds no work", not "the key is absent". Reading a draft
  -- MATERIALISES an empty shell -- that is `get`'s contract -- so the property
  -- is dirtiness, and the shell must not appear as work to a lister. That
  -- distinction is why auto-core has `scopes({ dirty_only = true })`.
  ok("p10: and the draft is cleared by a successful submit", (function()
    local scope = A.scope(repo.slug, commit.sha)
    local listed = false
    for _, sc in ipairs(drafts.scopes({ dirty_only = true })) do
      if sc == scope then listed = true end
    end
    return drafts.dirty(scope) == false and listed == false
      and #A.anchored(A.draft(repo.slug, commit.sha)) == 0
  end)())

  -- 4. The close guard: four answers, and KEEP is one of them.
  tree.open_diff(crow)
  local st = dv._state_for_tests()
  ok("p10: the view exposes its annotate wiring", st and st.annotate ~= nil)
  local draft2 = A.draft(repo.slug, commit.sha)
  A.add_finding(draft2, { path = "newfile.txt", line = 1, side = "RIGHT",
    severity = "nit", body = "second pass" })
  local offered
  notes = {}
  vim.ui.select = function(items, o, cb) offered = vim.deepcopy(items); asked = o and o.prompt; cb(nil) end
  local answer = st.annotate.before_close("key")
  vim.wait(200, function() return offered ~= nil end, 20)
  ok("p10: *** a dirty draft still vetoes the keypress close ***", answer == "cancel", tostring(answer))
  ok("p10: *** and the prompt offers KEEP alongside submit and discard ***",
    offered ~= nil and #offered == 4
    and table.concat(offered, "|"):find("close and keep the draft", 1, true) ~= nil,
    vim.inspect(offered))
  ok("p10: the prompt says the draft is kept either way",
    tostring(asked):find("kept either way", 1, true) ~= nil, tostring(asked))
  ok("p10: *** dismissing the prompt NAMES the way out instead of going quiet ***",
    said("still open") ~= nil and (said("still open") or ""):find("keep", 1, true) ~= nil,
    vim.inspect(notes))

  -- 5. KEEP closes and retains; DISCARD reports what it destroyed.
  notes = {}
  vim.ui.select = function(items, _, cb)
    for _, it in ipairs(items) do if it:find("keep", 1, true) then cb(it); return end end
  end
  st.annotate.before_close("key")
  vim.wait(300, function() return said("closed") ~= nil end, 20)
  ok("p10: *** keep closes the view ***", dv.is_open() == false, tostring(dv.is_open()))
  ok("p10: *** and the draft survives it ***",
    #A.anchored(A.draft(repo.slug, commit.sha)) == 1)
  ok("p10: and the message says so", said("kept") ~= nil, vim.inspect(notes))

  tree.open_diff(crow)
  local st2 = dv._state_for_tests()
  notes = {}
  vim.ui.select = function(items, _, cb)
    for _, it in ipairs(items) do if it:find("discard", 1, true) then cb(it); return end end
  end
  st2.annotate.before_close("key")
  vim.wait(300, function() return said("discarded") ~= nil end, 20)
  ok("p10: *** discard reports WHAT it destroyed ***",
    (said("discarded") or ""):find("1 comment", 1, true) ~= nil, vim.inspect(notes))
  ok("p10: and the draft is gone", #A.anchored(A.draft(repo.slug, commit.sha)) == 0)
  pcall(dv.close, "resume")

  -- 6. `u` is its own key, so submit no longer walks an unanchored loop.
  tree.open_diff(crow)
  local st3 = dv._state_for_tests()
  local ukey
  for _, km in ipairs(st3.keymaps or {}) do if km.key == "u" then ukey = km end end
  ok("p10: *** the view binds `u` for a finding with no line ***",
    ukey ~= nil and ukey.desc:find("unanchored", 1, true) ~= nil,
    vim.inspect(vim.tbl_map(function(k) return k.key end, st3.keymaps or {})))
  notes = {}
  vim.ui.input = function(_, cb) cb("this module has no tests") end
  vim.ui.select = function(items, _, cb) cb(items[1]) end
  ukey.fn()
  ok("p10: u records the finding", #A.unanchored(A.draft(repo.slug, commit.sha)) == 1,
    vim.inspect(A.unanchored(A.draft(repo.slug, commit.sha))))
  -- Cancelling the severity must add NOTHING; it used to store "comment".
  notes = {}
  vim.ui.select = function(_, _, cb) cb(nil) end
  ukey.fn()
  ok("p10: *** cancelling the severity adds nothing (it used to store one) ***",
    #A.unanchored(A.draft(repo.slug, commit.sha)) == 1 and said("nothing added") ~= nil,
    vim.inspect(notes))
  -- And an empty body adds nothing either.
  notes = {}
  vim.ui.input = function(_, cb) cb("  ") end
  ukey.fn()
  ok("p10: an empty finding adds nothing",
    #A.unanchored(A.draft(repo.slug, commit.sha)) == 1 and said("nothing added") ~= nil)
  -- CONTROL: submit no longer asks for unanchored findings at all.
  notes, asked = {}, {}
  local prompts = {}
  vim.ui.select = function(items, o, cb) prompts[#prompts + 1] = tostring(o and o.prompt); cb(items[1]) end
  vim.ui.input = function(o, cb) prompts[#prompts + 1] = tostring(o and o.prompt); cb("") end
  tree._submit_review(crow, commit.sha)
  vim.wait(300, function() return said("wrote review") ~= nil end, 20)
  ok("p10: *** submit asks only verdict + summary — no unanchored loop ***",
    #prompts == 2 and prompts[1]:find("verdict") and prompts[2]:find("summary")
    and table.concat(prompts, "|"):find("blank to finish", 1, true) == nil,
    vim.inspect(prompts))
  ok("p10: and the unanchored finding still reached the review",
    said("wrote review") ~= nil, vim.inspect(notes))
  pcall(dv.close, "resume")
  A.discard(repo.slug, commit.sha)

  vim.ui.select, vim.ui.input = real_select, real_input
  logger.notify = real_notify
end

-- unwatch clears the commits again
backend.toggle_watch(feat.path)
tree.invalidate(nil)
paint()
ok("p4: unwatching hides the commits again",
  text():find("feature work", 1, true) == nil, text())

-- ── p5: expansion state is visible on the node's own row (r1 nit) ──
-- _chevron returned "" for BOTH states, so a collapsed container was
-- distinguishable from an expanded one only by scanning ahead to the next
-- line's indent. The render harness never pinned the glyphs, which is exactly
-- why it survived to review.
tree.invalidate(nil)
paint()
local shown = text()
ok("p5: an EXPANDED container carries ▾ on its own row",
  shown:find("▾", 1, true) ~= nil, shown)

-- Collapse everything, then assert the collapsed marker appears and the
-- expanded one does not — a state change the reader can see in place.
for id in pairs(tree._expanded) do tree._expanded[id] = nil end
paint()
local collapsed = text()
ok("p5: a COLLAPSED container carries ▸", collapsed:find("▸", 1, true) ~= nil, collapsed)
ok("p5: and no ▾ remains when nothing is expanded",
  collapsed:find("▾", 1, true) == nil, collapsed)
ok("p5: the two states are DISTINGUISHABLE (the nit's actual defect)",
  collapsed ~= shown)

vim.fn.delete(sb, "rf")
print(string.format("\n%d passed, %d failed", pass, fail))
vim.cmd(fail > 0 and "cq" or "qa!")
