-- auto-finder — ADR-0065 P3: the consumer half (draft, identity, submit).
--
-- Run headless:
--   nvim --headless -u NONE -l tests/adr0065-p3-submit.lua
--
-- The interim writer's safety argument is entirely about ORDER — the final
-- Markdown name is claimed before any JSON exists, and the JSON is published
-- last — so the failure paths are what this suite actually drives.
-- XDG isolation FIRST, before anything can touch vim.fn.stdpath(). The runner's
-- preflight enforces this for every suite in the manifest, and it caught this
-- file for good reason: it writes a review store and a $KB_ROOT, so an
-- unsandboxed run would reach into the real ones.
dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/_sandbox.lua")("adr0065p3")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
-- worktree + auto-core are siblings in the same bare-repo family.
--
-- Resolved by the family convention (`adr0060-git-actions.lua`): `main` first,
-- then the SAME-BRANCH sibling, and only directories that exist. The original
-- list named `review-authoring` on both siblings — the in-flight branch this
-- feature was written on. That is a name with an expiry date: once the work
-- merged, `worktree.nvim` kept no such worktree, `require("worktree.store")`
-- threw at load, and the suite died before its first assertion. The runner
-- reported it as truncated, which is exactly right and exactly why the summary
-- sentinel exists — but a harness that pins a branch name will break again on
-- the next branch, so this resolves by shape instead.
local sib = vim.fn.fnamemodify(root, ":h:h")
local branch_dir = vim.fn.fnamemodify(root, ":t")
for _, plugin in ipairs({ "worktree.nvim", "auto-core.nvim" }) do
  for _, wt in ipairs({ "main", branch_dir }) do
    local r = sib .. "/" .. plugin .. "/" .. wt
    if vim.fn.isdirectory(r) == 1 then
      vim.opt.runtimepath:append(r)
      package.path = r .. "/lua/?.lua;" .. r .. "/lua/?/init.lua;" .. package.path
    end
  end
end

local pass, fail = 0, 0
local function ok(n, c, d)
  if c then pass = pass + 1; io.stdout:write("  PASS  " .. n .. "\n")
  else fail = fail + 1; io.stdout:write("  FAIL  " .. n .. "  " .. tostring(d or "") .. "\n") end
  io.stdout:flush()
end

local A = require("auto-finder.views.repos.authoring")
local store = require("worktree.store")
local review = require("worktree.review")

-- Isolate the review store AND the KB so nothing touches the real ones.
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
store._root_override = tmp .. "/store"
vim.env.AUTO_AGENTS_KB_ROOT = tmp .. "/kb"

io.stdout:write("\n[1] a display name is not a path segment\n")
ok("spaces collapse to a slug", A.slugify("John Lee") == "john-lee", A.slugify("John Lee"))
ok("*** a traversal cannot survive slugification ***",
  A.slugify("../../etc") == "etc", A.slugify("../../etc"))
ok("*** nor can a separator ***", (A.slugify("a/b") or ""):find("/") == nil, A.slugify("a/b"))
ok("punctuation-only yields nil rather than an empty segment", A.slugify("///") == nil,
  tostring(A.slugify("///")))
ok("nil in, nil out", A.slugify(nil) == nil)

io.stdout:write("\n[2] the STORE owns the document path, not this module\n")
local SHA = string.rep("a", 40)
local repo = { slug = "own__repo", label = "repo", owner = "own", name = "repo" }
-- ADR-0067 §2.2: a caller-supplied path validated after writing is a preflight
-- in name only. auto-finder supplies a topic and a body; `worktree.review`
-- decides where they land, so there is no path for this side to get wrong.
ok("this module no longer builds a document path", A.markdown_path == nil)
local mp = review.canonical_document({
  kb_root = vim.env.AUTO_AGENTS_KB_ROOT, reviewer_slug = "john-lee",
  slug = repo.slug, topic = A.topic(repo, SHA), revision = 1 })
ok("*** the store's path is under the reviewer's own directory ***",
  mp and mp:find(tmp .. "/kb/agents/john-lee/reviews/", 1, true) == 1, tostring(mp))
ok("and carries the revision in the name", mp and mp:find("-r1-review.md", 1, true) ~= nil, tostring(mp))
local _, why = review.canonical_document({
  kb_root = vim.env.AUTO_AGENTS_KB_ROOT, reviewer_slug = nil,
  slug = repo.slug, revision = 1 })
ok("an unsafe reviewer refuses rather than guessing a path", why ~= nil, tostring(why))

io.stdout:write("\n[3] submit writes BOTH artifacts, JSON last\n")
-- ORDER is the safety argument, so record it rather than infer it from the
-- happy-path outcome: both artifacts existing says nothing about which was
-- created first, and "Markdown first" is what makes every failure leave an
-- orphan prose file rather than an unpaired projection.
-- ADR-0067 A4: the write goes through `save_pair`, so BOTH artifacts are
-- claimed with `store.create_exclusive` and the JSON no longer passes through
-- `review.save`. Record at that one boundary and classify by filename.
local order = {}
local real_create = store.create_exclusive
store.create_exclusive = function(path, body)
  local pth = tostring(path)
  if pth:find("%-review%.md$") then order[#order + 1] = "markdown"
  elseif pth:find("%.review%.json$") then order[#order + 1] = "json"
  elseif pth:find("%.reserve$") then order[#order + 1] = "reserve"
  elseif pth:find("%.tombstone$") then order[#order + 1] = "tombstone" end
  return real_create(path, body)
end
local d = A.draft(repo.slug, SHA)
d.comments = { { path = "foo.lua", line = 3, side = "RIGHT", severity = "must-fix", body = "bad" } }
d.unanchored = { { severity = "nit", body = "this module has no tests" } }
d.summary = "overall fine"
local res, reason = A.submit({ repo = repo, sha = SHA })
ok("*** submit succeeds ***", res ~= nil, tostring(reason))
ok("it wrote a Markdown review", res and vim.fn.filereadable(res.md_path) == 1, res and res.md_path)
ok("and a JSON projection", res and vim.fn.filereadable(res.json_path) == 1, res and res.json_path)
ok("at revision 1", res and res.revision == 1, res and tostring(res.revision))
local doc = review.load(repo.slug, SHA, 1)
ok("the JSON validates and round-trips the comment",
  doc and #doc.comments == 1 and doc.comments[1].line == 3, vim.inspect(doc and doc.comments))
local md = table.concat(vim.fn.readfile(res.md_path), "\n")
ok("*** the UNANCHORED finding lives in the Markdown ***",
  md:find("this module has no tests", 1, true) ~= nil, md)
ok("*** and is absent from the JSON — nothing was invented to place it ***",
  not vim.inspect(doc.comments):find("no tests", 1, true))
ok("the draft is cleared after a successful submit",
  #A.draft(repo.slug, SHA).comments == 0)
do
  local imd, ijson, ireserve
  for i, ev in ipairs(order) do
    if ev == "markdown" and not imd then imd = i end
    if ev == "json" and not ijson then ijson = i end
    if ev == "reserve" and not ireserve then ireserve = i end
  end
  ok("*** the revision is RESERVED before either artifact is written ***",
    ireserve ~= nil and ireserve < (imd or math.huge), vim.inspect(order))
  ok("*** the Markdown is claimed BEFORE the JSON is published ***",
    imd ~= nil and ijson ~= nil and imd < ijson, vim.inspect(order))
  ok("and each artifact is written exactly once (no retry, no double write)",
    (function()
      local n = { markdown = 0, json = 0 }
      for _, ev in ipairs(order) do if n[ev] then n[ev] = n[ev] + 1 end end
      return n.markdown == 1 and n.json == 1
    end)(), vim.inspect(order))
end
ok("*** the Markdown carries KB_RULES R2 frontmatter ***",
  md:find("^%-%-%-\ntype: review\n") ~= nil, md:sub(1, 80))
ok("and the inline Tags/Abstract preview lines",
  md:find("\n%*%*Tags:%*%* `type:review`") ~= nil
  and md:find("\n%*%*Abstract:%*%* ") ~= nil, md:sub(1, 400))
ok("the anchored finding appears in the prose with its path:line",
  md:find("foo.lua:3", 1, true) ~= nil, md)
-- What A4 actually buys. The interim wrote both artifacts but nothing linked
-- them on disk beyond a matching revision; `save_pair` sets the cross-reference.
ok("*** the JSON now cross-references its document (ADR-0067 A4) ***",
  doc ~= nil and doc.document == res.md_path, vim.inspect(doc and doc.document))
ok("and the reservation was released after the commit",
  vim.fn.filereadable(review.reserve_path(repo.slug, SHA, res.revision)) == 0,
  review.reserve_path(repo.slug, SHA, res.revision))

io.stdout:write("\n[4] a taken Markdown name ADVANCES the revision\n")
local d2 = A.draft(repo.slug, SHA)
d2.comments = { { path = "foo.lua", line = 4, side = "RIGHT", severity = "nit", body = "second" } }
-- Pre-create the name r2 would want, so the claim must move on.
local _, rslug = A.reviewer()
local taken = review.canonical_document({
  kb_root = vim.env.AUTO_AGENTS_KB_ROOT, reviewer_slug = rslug,
  slug = repo.slug, topic = A.topic(repo, SHA), revision = 2 })
store.ensure_dir(vim.fn.fnamemodify(taken, ":h"))
vim.fn.writefile({ "squatter" }, taken)
local res2, reason2 = A.submit({ repo = repo, sha = SHA })
ok("*** submit skips the taken name rather than overwriting it ***",
  res2 ~= nil and res2.revision >= 3, tostring(reason2) .. " " .. tostring(res2 and res2.revision))
ok("the squatted file is untouched",
  table.concat(vim.fn.readfile(taken), "") == "squatter")
ok("and the JSON it wrote matches the revision it claimed",
  res2 and review.load(repo.slug, SHA, res2.revision) ~= nil)

io.stdout:write("\n[5] a JSON failure PRESERVES and reports the orphan Markdown\n")
local d3 = A.draft(repo.slug, SHA)
d3.comments = { { path = "foo.lua", line = 5, side = "RIGHT", severity = "nit", body = "third" } }
-- Fail the CANONICAL JSON create specifically, which is the commit point.
-- Stubbing `review.save` no longer reaches the writer (A4).
local guard = store.create_exclusive
store.create_exclusive = function(path, body)
  if tostring(path):find("%.review%.json$") then
    return false, "injected write failure"
  end
  return guard(path, body)
end
local res3, reason3 = A.submit({ repo = repo, sha = SHA })
store.create_exclusive = real_create
ok("*** submit reports failure rather than claiming success ***", res3 == nil, tostring(res3))
ok("and names the kept Markdown so the prose is not thought lost",
  reason3 and reason3:find("is not lost", 1, true) ~= nil, tostring(reason3))
ok("*** no JSON was published for that revision ***", (function()
  for _, r in ipairs(review.list_for(repo.slug, SHA)) do
    if r.revision >= 4 then return false end
  end
  return true
end)(), vim.inspect(review.list_for(repo.slug, SHA)))
ok("the draft is RETAINED after a failed submit, so the work survives",
  #A.draft(repo.slug, SHA).comments == 1)
-- The orphan is the whole point of the ordering: assert it EXISTS and holds the
-- reviewer's prose, not merely that a path was mentioned in an error string.
local orphan = reason3 and reason3:match("(/[^%s]+%-review%.md)")
ok("*** the orphan Markdown actually exists on disk ***",
  orphan and vim.fn.filereadable(orphan) == 1, tostring(orphan))
ok("*** and still contains the reviewer's finding ***",
  orphan and table.concat(vim.fn.readfile(orphan), "\n"):find("third", 1, true) ~= nil,
  tostring(orphan))

io.stdout:write("\n[6] identity comes from the worktree under review, not nvim's cwd\n")
do
  -- Two repos with different configured identities. Running `git config` in
  -- Neovim's cwd answered for whichever repo the editor sat in, so a review of
  -- B was attributed to A.
  local ra, rb = tmp .. "/repo_a", tmp .. "/repo_b"
  for dir, who in pairs({ [ra] = "Alice A", [rb] = "Bob B" }) do
    vim.fn.mkdir(dir, "p")
    vim.fn.system({ "git", "-C", dir, "init", "-q" })
    vim.fn.system({ "git", "-C", dir, "config", "user.name", who })
  end
  local da = select(1, A.reviewer(ra))
  local db = select(1, A.reviewer(rb))
  ok("*** each worktree reports its OWN configured reviewer ***",
    da == "Alice A" and db == "Bob B", ("a=%s b=%s"):format(tostring(da), tostring(db)))
  ok("and they genuinely differ (positive control)", da ~= db)
end

io.stdout:write("\n[7] a draft is DIRTY on any of its three contents\n")
do
  -- One predicate drives submit, the close guard and the footer. Three separate
  -- inline checks is how the last defect happened: `submit` counted comments
  -- and summary but not unanchored findings, so a review consisting solely of
  -- "this module has no tests" — exactly what review-json §6 protects — was
  -- refused as "nothing to submit", and the close guard let it go unprompted.
  ok("an empty draft is not dirty", A.dirty({ comments = {}, unanchored = {} }) == false)
  ok("a comment makes it dirty", A.dirty({ comments = { {} } }) == true)
  ok("*** an UNANCHORED finding alone makes it dirty ***",
    A.dirty({ comments = {}, unanchored = { { body = "no tests" } } }) == true)
  ok("a summary alone makes it dirty",
    A.dirty({ comments = {}, summary = "looks fine" }) == true)
  ok("whitespace is not a summary", A.dirty({ comments = {}, summary = "   " }) == false)

  -- And the functional half: an unanchored-only review must actually WRITE.
  A.discard(repo.slug, SHA)
  local du = A.draft(repo.slug, SHA)
  du.unanchored = { { severity = "nit", body = "this module has no tests" } }
  local resu, whyu = A.submit({ repo = repo, sha = SHA })
  ok("*** an unanchored-only review submits rather than being refused ***",
    resu ~= nil, tostring(whyu))
  if resu then
    local mdu = table.concat(vim.fn.readfile(resu.md_path), "\n")
    ok("its finding is in the Markdown", mdu:find("no tests", 1, true) ~= nil)
    local du2 = review.load(repo.slug, SHA, resu.revision)
    ok("and the JSON carries zero comments, inventing nothing",
      du2 ~= nil and #du2.comments == 0, vim.inspect(du2 and du2.comments))
  end
end

io.stdout:write("\n[8] the draft survives every close path, and repaints\n")
do
  -- Criterion 8. The draft is the CONSUMER's precisely so the float's
  -- unvetoable teardowns cost windows rather than work; asserting it at the
  -- auto-core level only would leave that claim untested where it matters.
  local dv = require("auto-core.ui.diffview")
  local gitdiff = require("auto-core.git.diff")
  local PATCH = "diff --git a/foo.lua b/foo.lua\n--- a/foo.lua\n+++ b/foo.lua\n"
    .. "@@ -1,3 +1,3 @@\n a\n-b\n+c\n d\n"
  local files = gitdiff.parse(PATCH)
  vim.o.columns, vim.o.lines = 200, 50
  A.discard(repo.slug, SHA)
  local dr = A.draft(repo.slug, SHA)
  dr.comments = { { path = "foo.lua", line = 2, side = "RIGHT", severity = "nit", body = "kept" } }

  local function open()
    dv.open({ files = files, annotate = {
      on_add = function(a) table.insert(dr.comments, a) end,
      on_remove = function() end,
      pending = function() return dr.comments end,
    } })
  end

  local closers = {
    ["q"] = function(st, b)
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do
        if m.lhs == "q" and m.callback then m.callback() end
      end
    end,
    ["<Esc>"] = function(st, b)
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do
        if m.lhs == "<Esc>" and m.callback then m.callback() end
      end
    end,
    ["pane-lost"] = function(st) pcall(vim.api.nvim_win_close, st.float:winid("preview"), true) end,
    ["dispose"] = function(st) st.float:dispose() end,
  }
  for name, how in pairs(closers) do
    open()
    local st = dv._state_for_tests()
    how(st, st.float:bufnr("preview"))
    vim.wait(50, function() return not dv.is_open() end)
    ok(("*** the draft survives %s ***"):format(name),
      #dr.comments == 1 and dr.comments[1].body == "kept",
      ("%d comment(s)"):format(#dr.comments))
  end
  -- ...and reopening REPAINTS it, which is what makes survival useful.
  open()
  local painted = dv._pending_for(files[1])
  ok("*** and reopening repaints it through pending() ***",
    #painted == 1 and painted[1].author == "pending", vim.inspect(painted))
  dv.close()
end

io.stdout:write("\n[9] a submitted review reloads through the REAL annotation path\n")
do
  -- Criterion 12. Calling `review.load` directly proves the file is readable;
  -- it does NOT prove the panel can find it. The real path is
  -- `open_diff` -> backend.reviews -> review.load -> review.by_path -> the
  -- annotations table handed to the diff view, and only that covers the merge
  -- and grouping the reader actually depends on. `worktree.repos` is stubbed
  -- because a real backend needs a real repo; everything downstream is real.
  local tree = require("auto-finder.views.repos.tree")
  local dv = require("auto-core.ui.diffview")
  local PATCH = "diff --git a/foo.lua b/foo.lua\n--- a/foo.lua\n+++ b/foo.lua\n"
    .. "@@ -1,4 +1,4 @@\n a\n b\n-c\n+d\n"

  A.discard(repo.slug, SHA)
  local dz = A.draft(repo.slug, SHA)
  dz.comments = { { path = "foo.lua", line = 4, side = "RIGHT",
                    severity = "must-fix", body = "reloaded finding" } }
  local wrote = select(1, A.submit({ repo = repo, sha = SHA }))
  ok("a review exists to reload (positive control)", wrote ~= nil)

  package.loaded["worktree.repos"] = {
    available = function() return true end,
    diff = function() return require("auto-core.git.diff").parse(PATCH) end,
    reviews = function(_, sha) return review.list_for(repo.slug, sha) end,
  }
  vim.o.columns, vim.o.lines = 200, 50
  local row = {
    repo = repo,
    worktree = { path = tmp },
    node = { kind = "commit", sha = SHA, short = SHA:sub(1, 7), commit = { subject = "s" } },
  }
  tree.open_diff(row)
  local st = dv._state_for_tests()
  ok("*** open_diff opened the view ***", st ~= nil and dv.is_open())
  local anns = st and st.annotations or {}
  ok("*** the written review came back through backend.reviews -> by_path ***",
    anns["foo.lua"] ~= nil, vim.inspect(vim.tbl_keys(anns)))
  local found, authored = false, false
  for _, c in ipairs(anns["foo.lua"] or {}) do
    if c.body == "reloaded finding" then found = true; authored = c.author ~= nil end
  end
  ok("with the body the reviewer just wrote", found, vim.inspect(anns["foo.lua"]))
  ok("and the reviewer attributed from its document", authored)
  -- open_diff merges EVERY revision for the commit, newest last. Earlier
  -- sections wrote several reviews at this sha, so the reload proves the merge
  -- as well as the read — which a single-review fixture would not have.
  ok("*** and comments from EARLIER revisions are merged in, not replaced ***",
    #anns["foo.lua"] > 1, ("%d merged"):format(#(anns["foo.lua"] or {})))
  ok("the store really holds several revisions for this commit (positive control)",
    #review.list_for(repo.slug, SHA) > 1,
    ("%d revisions"):format(#review.list_for(repo.slug, SHA)))
  dv.close()
  package.loaded["worktree.repos"] = nil
end

io.stdout:write("\n[10] the panel help documents the diff view it opens\n")
-- The `?` overlay listed the panel's own keys and stopped there, so an entire
-- surface -- the one that writes reviews -- was undocumented. `s` is the sharp
-- case: in the PANEL it stages a file, in the DIFF VIEW it submits a review.
-- Same key, two meanings, and nothing on screen said so.
local tree = require("auto-finder.views.repos.tree")
ok("the help text is reachable for assertion", type(tree.HELP) == "table")
local help = table.concat(tree.HELP or {}, "\n")
ok("*** the diff view has a section of its own ***",
  help:lower():find("diff view", 1, true) ~= nil)
ok("*** c is documented as annotate ***", help:find("annotate", 1, true) ~= nil)
ok("*** x is documented as dropping a pending annotation ***",
  help:find("pending annotation", 1, true) ~= nil)
ok("*** s is documented as submit ***", help:find("submit", 1, true) ~= nil)
ok("*** and the s collision is called out ***",
  help:find("stage", 1, true) ~= nil and help:lower():find("same key", 1, true) ~= nil)
ok("UNCOMMITTED's disabled authoring is explained",
  help:find("UNCOMMITTED", 1, true) ~= nil)

io.stdout:write("\n[11] nothing to submit is refused, not written\n")
A.discard(repo.slug, SHA)
local res4, reason4 = A.submit({ repo = repo, sha = SHA })
ok("an empty draft refuses with a reason", res4 == nil and reason4 ~= nil, tostring(reason4))

vim.fn.delete(tmp, "rf")
io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
