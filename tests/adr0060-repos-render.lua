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
