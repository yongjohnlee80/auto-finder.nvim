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
local sib = vim.fn.fnamemodify(root, ":h:h")
for _, r in ipairs({ sib .. "/worktree.nvim/review-authoring",
                     sib .. "/auto-core.nvim/review-authoring" }) do
  vim.opt.runtimepath:append(r)
  package.path = r .. "/lua/?.lua;" .. r .. "/lua/?/init.lua;" .. package.path
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

io.stdout:write("\n[2] the markdown path lands under $KB_ROOT/agents/<slug>/reviews\n")
local SHA = string.rep("a", 40)
local repo = { slug = "own__repo", label = "repo", owner = "own", name = "repo" }
local mp = A.markdown_path(repo, SHA, "john-lee", 1)
ok("*** it is under the reviewer's own directory ***",
  mp and mp:find(tmp .. "/kb/agents/john-lee/reviews/", 1, true) == 1, tostring(mp))
ok("and carries the revision in the name", mp and mp:find("-r1-review.md", 1, true) ~= nil, tostring(mp))
local _, why = A.markdown_path(repo, SHA, nil, 1)
ok("an unsafe reviewer refuses rather than guessing a path", why ~= nil, tostring(why))

io.stdout:write("\n[3] submit writes BOTH artifacts, JSON last\n")
-- ORDER is the safety argument, so record it rather than infer it from the
-- happy-path outcome: both artifacts existing says nothing about which was
-- created first, and "Markdown first" is what makes every failure leave an
-- orphan prose file rather than an unpaired projection.
local order = {}
local real_create, real_save = store.create_exclusive, review.save
store.create_exclusive = function(path, body)
  if tostring(path):find("%-review%.md$") then order[#order + 1] = "markdown" end
  return real_create(path, body)
end
review.save = function(slug, doc, o)
  order[#order + 1] = "json"
  return real_save(slug, doc, o)
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
ok("*** the Markdown was claimed BEFORE the JSON was published ***",
  order[1] == "markdown" and order[2] == "json", vim.inspect(order))
ok("and exactly one of each (no retry, no double write)", #order == 2, vim.inspect(order))
ok("*** the Markdown carries KB_RULES R2 frontmatter ***",
  md:find("^%-%-%-\ntype: review\n") ~= nil, md:sub(1, 80))
ok("and the inline Tags/Abstract preview lines",
  md:find("\n%*%*Tags:%*%* `type:review`") ~= nil
  and md:find("\n%*%*Abstract:%*%* ") ~= nil, md:sub(1, 400))
ok("the anchored finding appears in the prose with its path:line",
  md:find("foo.lua:3", 1, true) ~= nil, md)

io.stdout:write("\n[4] a taken Markdown name ADVANCES the revision\n")
local d2 = A.draft(repo.slug, SHA)
d2.comments = { { path = "foo.lua", line = 4, side = "RIGHT", severity = "nit", body = "second" } }
-- Pre-create the name r2 would want, so the claim must move on.
local _, rslug = A.reviewer()
local taken = A.markdown_path(repo, SHA, rslug, 2)
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
local real_save = review.save
review.save = function() return nil, "injected write failure" end
local res3, reason3 = A.submit({ repo = repo, sha = SHA })
review.save = real_save
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

io.stdout:write("\n[7] nothing to submit is refused, not written\n")
A.discard(repo.slug, SHA)
local res4, reason4 = A.submit({ repo = repo, sha = SHA })
ok("an empty draft refuses with a reason", res4 == nil and reason4 ~= nil, tostring(reason4))

vim.fn.delete(tmp, "rf")
io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
