-- ADR-0060 P4 render harness: drive the real tree over a real repo layout.
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
local PR = "/home/johno/Source/Projects/nvim-plugins"
for _, p in ipairs({ PR .. "/auto-core.nvim/main", PR .. "/worktree.nvim/main",
                     LAZY .. "/nui.nvim", LAZY .. "/plenary.nvim",
                     PR .. "/auto-finder.nvim/main" }) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end
vim.o.columns, vim.o.lines = 200, 60
local sb = vim.fn.tempname() .. "-p4"
dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
  .. "/_sandbox.lua")("p4")

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
local rv = review.new({ commit = commit.sha, revision = 1, reviewer = "lector",
                        owner = "render", name = "fixture" })
rv.comments = { { path = "newfile.txt", line = 1, side = "RIGHT", severity = "nit", body = "x" } }
review.save(repo.slug, rv)
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
