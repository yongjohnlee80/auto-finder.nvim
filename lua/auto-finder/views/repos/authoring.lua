---auto-finder.views.repos.authoring — the consumer half of ADR-0065.
---
---auto-core's diff view owns the gesture and knows nothing about reviews; this
---module owns everything it deliberately does not: the DRAFT, the reviewer's
---identity, the verdict and summary, and the write.
---
---That the draft lives HERE rather than in the float is the load-bearing part.
---`ui.float.multi` can be torn down by paths no consumer can veto — `<Esc>`, a
---lost pane, a programmatic dispose — so work held by the float is work those
---paths destroy. Work held here survives them, and reopening the diff repaints
---it through `pending()`.
---
---**The writer is an INTERIM** (ADR-0065 §2.6). It is safe on its own terms —
---the final Markdown name is claimed BEFORE any JSON exists, and the JSON is
---published last with the exclusive `review.save`, so every failure leaves at
---most an orphan Markdown and never a projection without its primary. What it
---does not have is the reservation/tombstone protocol, the `document`
---cross-reference, or a fence for concurrent writers. Those are ADR-0067, whose
---A4 repoints `submit` onto `save_pair`. Do not build on this path.
---@module 'auto-finder.views.repos.authoring'

local M = {}

---SEVERITIES mirrors auto-core's normative order, so the unanchored composer
---offers the same ladder the anchored one does.
M.SEVERITIES = { "must-fix", "should-fix", "nit", "question" }

---### P5 — the draft lives in auto-core (ADR-0081 §2.2/§2.5)
---
---It used to be `M._drafts` here, which meant the plugin holding it was the one
---no other plugin may depend on: an agent could not read a draft, and the
---composer that FILLS a draft (auto-core's diff view) sat one plugin away from
---the store it appended to. Both are fixed by the store living in auto-core.
---
---What stays here is what auto-finder owns: the reviewer's identity, the render,
---and the submit.
local function _drafts()
  local ok, d = pcall(require, "auto-core.drafts")
  if not ok or type(d) ~= "table" or type(d.get) ~= "function" then
    error("auto-finder.repos.authoring: auto-core.drafts is required"
      .. " (auto-core >= v0.2.12)", 0)
  end
  return d
end

---scope is the draft's opaque key: repo slug plus the FULL commit.
---
---The full sha, never the abbreviation (§2.5). Two commits can share a short
---sha, and a scope that collides merges two reviewers' work silently; a scope
---derived from a window id would split one reviewer's work instead.
---@param slug string
---@param sha string
---@return string
function M.scope(slug, sha)
  local s, h = tostring(slug or ""), tostring(sha or "")
  -- ENFORCE the contract this function documents. It accepted a short sha
  -- happily, and a scope built from an abbreviation is the collision §2.5
  -- exists to prevent: two commits sharing a 7-char prefix would merge two
  -- reviewers' drafts into one (lector SF2). Refusing is right — a caller with
  -- only an abbreviation has not resolved its identity yet, and silently
  -- accepting it hides that until two drafts merge.
  -- Lua has no `%x{40}`: the repetition is built explicitly, once. The slug
  -- must be `@`-free, or it could forge the `@<sha>` / `@working:` delimiter
  -- the whole grammar rests on (lector, §2.5 amendment review).
  if s == "" or s:find("@", 1, true)
    or not h:match("^" .. ("%x"):rep(40) .. "$") then return nil end
  return s .. "@" .. h
end

---WORKING_MARK is the scope segment for a draft on UNCOMMITTED work (ADR-0081
---§2.5, uncommitted-scope amendment). `@working:` can never be a committed
---scope's `@<40-hex>`, so the two namespaces cannot collide. It carries the
---worktree's opaque IDENTITY (from `worktree_id`, an auto-core UUID) — not its
---path, which moves, and not its git registration name, which remove+recreate
---can reuse. A repo can have several linked worktrees, each with its own
---identity, so a draft belongs to exactly one of them.
M.WORKING_MARK = "@working:"

---worktree_id delegates to auto-core, which OWNS the git-layout knowledge and
---the identity file (ADR-0081 §2.5, lector r2). auto-finder keeps only
---draft/scope behaviour and never reads `.git` or constructs the admin path
---itself — that knowledge lived here briefly in r2 and was moved back.
---@param worktree_path string
---@param opts { create: boolean? }?
---@return string?  opaque UUID, or nil
function M.worktree_id(worktree_path, opts)
  local ok, core = pcall(require, "auto-core.git.worktree")
  if not ok or type(core) ~= "table" or type(core.worktree_id) ~= "function" then
    return nil
  end
  return core.worktree_id(worktree_path, opts)
end

---_slug_ok rejects a slug that could inject a scope delimiter. A committed
---scope ends in `@<40-hex>` and a working one carries `@working:`; a slug that
---contained `@` could forge either, so the whole grammar rests on the slug
---being `@`-free (sanitised slugs are `owner__repo`, which cannot contain one).
local function _slug_ok(s)
  return type(s) == "string" and s ~= "" and not s:find("@", 1, true)
end

---scope_working is the opaque draft key for uncommitted work in one worktree.
---
---Keyed by the worktree's durable IDENTITY, never its display path, so a moved
---worktree keeps its draft and a recreated one does not inherit an old draft.
---`submit` refuses this by inspection — the committed grammar it accepts cannot
---match a `@working:` scope — rather than by guessing.
---@param slug string
---@param worktree_id string   from `worktree_id`, not a raw path
---@return string?
function M.scope_working(slug, worktree_id)
  local s, id = tostring(slug or ""), tostring(worktree_id or "")
  if not _slug_ok(s) or id == "" then return nil end
  return s .. M.WORKING_MARK .. id
end

---is_working reports whether a scope is an uncommitted-work draft, by an
---ANCHORED parse — NOT a substring search (lector): the discriminator is the
---`@working:` segment at a real boundary, and the slug part must itself be
---delimiter-free, so a committed scope whose path metadata happened to contain
---the token cannot be misread as working.
---@param scope string
---@return boolean, string? slug, string? worktree_id
function M.is_working(scope)
  if type(scope) ~= "string" then return false end
  local s, id = scope:match("^(.-)" .. vim.pesc(M.WORKING_MARK) .. "(.+)$")
  if not s or not _slug_ok(s) or id == "" then return false end
  return true, s, id
end

---is_committed_scope reports whether a scope is EXACTLY the committed
---production `<slug>@<40-lowercase-hex>` — the only shape `submit` may save.
---FAIL-CLOSED: anything else (a working scope, a malformed one) is rejected here
---before it can reach the store.
---@param scope string
---@return boolean
function M.is_committed_scope(scope)
  if type(scope) ~= "string" then return false end
  local s, sha = scope:match("^(.-)@(" .. ("%x"):rep(40) .. ")$")
  return s ~= nil and _slug_ok(s) and sha ~= nil and sha == sha:lower()
end

---draft_working returns (and lazily creates) the draft for a worktree's
---uncommitted changes. The reviewer is snapshotted from that worktree, exactly
---as the committed path does (§2.5). The draft is keyed by the worktree's
---durable IDENTITY; the path is recorded as DISPLAY/RECOVERY metadata and is
---REFRESHED on every bind, which is precisely the move behaviour §2.5 asks for:
---a moved worktree rebinds to its own draft by identity and its display path
---catches up, rather than being silently conflated with anything else.
---@param slug string
---@param worktree_path string
---@return table?
function M.draft_working(slug, worktree_path)
  -- create=true: binding a draft is the moment the worktree's UUID is minted
  -- (by auto-core, which owns the git-layout resolution).
  local id = M.worktree_id(worktree_path, { create = true })
  local scope = id and M.scope_working(slug, id) or nil
  if not scope then return nil end
  local d = _drafts().get(scope)
  if d.verdict == nil then d.verdict = "comment" end
  if type(d.meta) ~= "table" then d.meta = {} end
  if d.meta.reviewer == nil then
    local display, rslug = M.reviewer(worktree_path)
    d.meta.reviewer = { display = display, slug = rslug,
                        bound_at = os.time(), cwd = worktree_path }
  end
  -- The opaque UUID keys the draft; the display path is lookup/recovery
  -- metadata, refreshed each bind so a moved worktree's path catches up. The
  -- gitdir is auto-core's internal detail and is not held here.
  d.meta.worktree_id = id
  d.meta.worktree = worktree_path
  return d
end

---peek_working reads the uncommitted draft WITHOUT creating one — and without
---minting a UUID (create=false), so a peek never writes admin metadata.
---@param slug string
---@param worktree_path string
---@return table?
function M.peek_working(slug, worktree_path)
  local id = M.worktree_id(worktree_path, { create = false })
  local scope = id and M.scope_working(slug, id) or nil
  return scope and _drafts().peek(scope) or nil
end

---draft returns (and lazily creates) the draft for a commit.
---
---The table is auto-core's and LIVE: findings go in `items` (the generic list
---auto-core's dirty predicate reads), while `verdict` and `summary` are this
---module's own fields on the same table.
---@return table
function M.draft(slug, sha, opts)
  local d = _drafts().get(M.scope(slug, sha))
  if d.verdict == nil then d.verdict = "comment" end
  -- SNAPSHOT the reviewer when the draft is first bound (ADR-0081 §2.5).
  -- `submit` used to resolve `git config user.name` at WRITE time, so a draft
  -- begun as Alice and submitted after the repo config changed was persisted as
  -- Bob -- silent authorship corruption, reproduced by lector (MF5). The
  -- snapshot lives in `meta`, which is CONTEXT and never makes a draft dirty.
  if type(d.meta) ~= "table" then d.meta = {} end
  -- ONLY FROM EXPLICIT RESOLVED CONTEXT. Binding without a `cwd` resolved
  -- `git config user.name` against whatever directory nvim happened to sit in,
  -- so a draft for repo B created through the legacy two-argument call was
  -- stamped with repo A's reviewer -- and because `submit` then TRUSTS the
  -- snapshot, it submitted B's review under A's name even though submit itself
  -- was given B's cwd (lector r3 MF2). The ambient cwd is not the repo under
  -- review; it is a coincidence.
  --
  -- With no cwd, the snapshot is deliberately left ABSENT, and `submit` -- which
  -- does know the cwd -- binds it correctly at that point. No snapshot is a
  -- recoverable state; a wrong one is not.
  local cwd = opts and opts.cwd
  if d.meta.reviewer == nil and type(cwd) == "string" and cwd ~= "" then
    local display, rslug = M.reviewer(cwd)
    -- Recorded even when it resolves to nothing, so a later read cannot mistake
    -- "we asked and got nothing" for "we never asked".
    d.meta.reviewer = { display = display, slug = rslug,
                        bound_at = os.time(), cwd = cwd }
  end
  return d
end

---reviewer_snapshot returns the identity bound to this draft, if any.
---@param slug string
---@param sha string
---@return table?
function M.reviewer_snapshot(slug, sha)
  local d = _drafts().peek(M.scope(slug, sha))
  return d and type(d.meta) == "table" and d.meta.reviewer or nil
end

---peek returns the draft for a commit WITHOUT creating one.
---
---The read a question needs. `draft()` materialises an empty shell for every
---scope it is asked about, and those shells then have to be filtered back out of
---any listing of unsaved work.
---@param slug string
---@param sha string
---@return table?
function M.peek(slug, sha)
  return _drafts().peek(M.scope(slug, sha))
end

---add_finding appends one finding to the draft.
---
---THE only way content enters a draft, so "is there unsaved work?" has exactly
---one answer. `anchored` is inferred from the presence of a line, because that
---is what makes a finding anchored -- a separate flag the caller had to
---remember to set is a flag the caller eventually forgets.
---@param d table
---@param item table
---@return table item
function M.add_finding(d, item)
  item = item or {}
  if item.anchored == nil then item.anchored = item.line ~= nil end
  table.insert(d.items, item)
  return item
end

---anchored / unanchored are the two views the composer and the renderer need.
---
---Derived from `items` rather than kept as two lists: two lists is two places
---for a finding to be missing from, and the count that drives "nothing to
---submit" was once computed from one of them.
---@param d table
---@return table[]
function M.anchored(d)
  local out = {}
  for _, i in ipairs((d or {}).items or {}) do
    if i.anchored then out[#out + 1] = i end
  end
  return out
end

---@param d table
---@return table[]
function M.unanchored(d)
  local out = {}
  for _, i in ipairs((d or {}).items or {}) do
    if not i.anchored then out[#out + 1] = i end
  end
  return out
end

---set_summary records a summary and declares it as content.
---
---A summary with no findings is still work (review-json §6), and auto-core's
---store is domain-agnostic so it cannot know that a field called `summary`
---counts -- the caller says so, once, here.
---@param slug string
---@param sha string
---@param text string?
function M.set_summary(slug, sha, text)
  local d = M.draft(slug, sha)
  local has = type(text) == "string" and vim.trim(text) ~= ""
  d.summary = has and vim.trim(text) or nil
  _drafts().touch(M.scope(slug, sha), has)
  return d.summary
end

---dirty reports whether a draft holds anything worth keeping.
---
---ONE predicate, shared by `submit` and the close guard. (The footer's pending
---COUNT comes from auto-core's `pending()` callback and is a different
---question — how many anchored annotations are drawn — so it deliberately does
---not route through here.) Three separate inline checks is how the last defect
---happened:
---`submit` counted comments and summary but not UNANCHORED findings, so a
---review that consisted solely of "this module has no tests" — precisely the
---kind review-json §6 exists to protect — was refused with "nothing to submit",
---and the close guard let the same draft go without a prompt.
---@param d table
---@return boolean
function M.dirty(d)
  -- auto-core's predicate, not a second one. It reads `items` plus the explicit
  -- `touched` bit that `set_summary` sets -- so a summary-only review still
  -- counts, which is the exact case the old three-inline-checks defect refused
  -- with "nothing to submit" while the close guard let it go unprompted.
  return _drafts().dirty(d)
end

---discard drops a draft outright.
function M.discard(slug, sha) return _drafts().discard(M.scope(slug, sha)) end

---discard_scope drops a draft by its opaque scope — the form a caller with a
---working-tree draft (no sha) or a lister already holding the scope needs.
---@param scope string
---@return boolean
function M.discard_scope(scope)
  if type(scope) ~= "string" or scope == "" then return false end
  return _drafts().discard(scope)
end

---slugify turns a display name into a safe PATH SEGMENT.
---
---A repo-local `git config user.name` is unconstrained: it can contain `/`,
---`..`, or a display name with no business being a directory. This is the
---review-json §2 repo-slug rule applied to the second path segment, for the
---same stated reason — a slug is a path segment and must not be able to escape
---the store.
---@param name string?
---@return string?  nil when nothing survives sanitisation
function M.slugify(name)
  if type(name) ~= "string" then return nil end
  local s = name:lower():gsub("[^a-z0-9_-]+", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
  if s == "" then return nil end
  return s
end

---reviewer resolves the DISPLAY name and the PATH slug — two different things.
---
---`cwd` is REQUIRED to be meaningful: `git config user.name` is per-repository,
---so running it in Neovim's cwd answers for whatever repo the editor happens to
---sit in, not the one being reviewed. With two repos open that silently
---attributed a review of repo B to repo A's configured identity. `git -C`
---pins it to the worktree under review.
---@param cwd string?  the worktree being reviewed
---@return string? display, string? slug
function M.reviewer(cwd)
  local display
  local cmd = { "git" }
  if type(cwd) == "string" and cwd ~= "" then
    cmd[#cmd + 1] = "-C"
    cmd[#cmd + 1] = cwd
  end
  cmd[#cmd + 1] = "config"
  cmd[#cmd + 1] = "user.name"
  local ok, out = pcall(vim.fn.systemlist, cmd)
  if ok and vim.v.shell_error == 0 and type(out) == "table"
    and out[1] and out[1] ~= "" then
    display = out[1]
  end
  display = display or vim.env.USER
  return display, M.slugify(display)
end

---_kb_root resolves `$KB_ROOT` through auto-core's canonical resolver, so the
---Markdown lands where every other durable doc does.
local function _kb_root()
  local ok, vars = pcall(require, "auto-core.todo.vars")
  if not ok then return nil end
  local okv, v = pcall(vars.get, "KB_ROOT")
  if okv and type(v) == "string" and v ~= "" then return v end
  return nil
end

---_topic is the filename's human half — short, safe, and derived from the
---commit so two reviews of different commits cannot collide on it.
local function _topic(repo, sha)
  local name = (repo and (repo.label or repo.slug)) or "review"
  return (M.slugify(name) or "review") .. "-" .. tostring(sha):sub(1, 7)
end

---topic is the human half of the document's filename.
---
---The PATH itself is no longer built here. ADR-0067 §2.2 gives the store
---ownership of the canonical path, because a caller-supplied path validated
---after writing is a preflight in name only — the first cut let a generator
---commit a pair outside `$KB_ROOT` entirely. We supply a topic and a body; the
---store decides where they land.
---@return string
function M.topic(repo, sha)
  local name = (repo and (repo.label or repo.slug)) or "review"
  return (M.slugify(name) or "review") .. "-" .. tostring(sha):sub(1, 7)
end

---render_markdown produces the PRIMARY artifact.
---
---Every anchored finding appears with its `path:line`, and so do the UNANCHORED
---ones — review-json §6 forbids inventing a line number to make something
---placeable, so a finding that does not fit an anchor lives here and only here.
---@return string
function M.render_markdown(opts)
  local d = opts.draft
  local date = os.date("!%Y-%m-%d")
  local n_anchored, n_unanchored = #M.anchored(d), #M.unanchored(d)
  -- KB_RULES R2: every new doc under `agents/<name>/` carries BOTH YAML
  -- frontmatter (for tools — kb.frontmatter, obsidian, the cost analyzer) and
  -- the inline Tags/Abstract preview lines (for LLMs skimming before load).
  -- They are not redundant and both are required.
  local lines = {
    "---",
    "type: review",
    ("created: %s"):format(date),
    ("updated: %s"):format(date),
    "status: open",
    ("tags: [review, %s, diff-review, %s]"):format(
      M.slugify(opts.repo_label or "repo") or "repo", d.verdict or "comment"),
    "---",
    "",
    ("# Review — %s @ %s"):format(opts.repo_label or "repo", tostring(opts.sha):sub(1, 7)),
    "",
    ("**Tags:** `type:review` `status:open` `owner:%s` `repo:%s` `area:diff-review`")
      :format(M.slugify(opts.reviewer or "") or "unknown",
              M.slugify(opts.repo_label or "repo") or "repo"),
    "",
    ("**Abstract:** %s review of `%s` at r%d — %d anchored finding(s), %d unanchored.")
      :format(d.verdict or "comment", tostring(opts.sha):sub(1, 7), opts.revision,
              n_anchored, n_unanchored),
    "",
    ("- **Reviewer:** %s"):format(opts.reviewer or "(unknown)"),
    ("- **Commit:** `%s`"):format(tostring(opts.sha)),
    ("- **Revision:** r%d"):format(opts.revision),
    ("- **Verdict:** %s"):format(d.verdict or "comment"),
    "",
  }
  if d.summary and d.summary ~= "" then
    lines[#lines + 1] = "## Summary"
    lines[#lines + 1] = ""
    for _, l in ipairs(vim.split(d.summary, "\n", { plain = true })) do lines[#lines + 1] = l end
    lines[#lines + 1] = ""
  end
  if #M.anchored(d) > 0 then
    lines[#lines + 1] = "## Anchored findings"
    lines[#lines + 1] = ""
    for _, c in ipairs(M.anchored(d)) do
      local where = ("`%s:%d`"):format(c.path, c.line)
      if c.start_line and c.start_line ~= c.line then
        where = ("`%s:%d-%d`"):format(c.path, c.start_line, c.line)
      end
      lines[#lines + 1] = ("### %s — %s (%s)"):format(c.severity or "comment", where, c.side or "RIGHT")
      lines[#lines + 1] = ""
      for _, l in ipairs(vim.split(c.body or "", "\n", { plain = true })) do lines[#lines + 1] = l end
      lines[#lines + 1] = ""
    end
  end
  if #M.unanchored(d) > 0 then
    -- §6: "a finding that is not anchored to a line has nowhere to go in the
    -- JSON and must not be dropped to fit the schema."
    lines[#lines + 1] = "## Unanchored findings"
    lines[#lines + 1] = ""
    for _, u in ipairs(M.unanchored(d)) do
      lines[#lines + 1] = ("- **%s** — %s"):format(u.severity or "comment", u.body or "")
    end
    lines[#lines + 1] = ""
  end
  return table.concat(lines, "\n")
end

---submit writes the pair through `worktree.review.save_pair`.
---
---ADR-0067 A4. This used to hand-roll the ordering — claim the final Markdown
---name, then publish the JSON with the exclusive `review.save` — which was
---correct for a single writer and documented as such. `save_pair` supersedes
---it and closes the three limits that version shipped with, together:
---
---  * the `document` cross-reference now exists, so the pair is legible on disk
---    rather than only by matching revisions;
---  * a reservation and tombstone fence the revision, so concurrent writers
---    cannot collide and a crashed one cannot have its number recycled;
---  * the commit point is the canonical JSON, so no reader can ever observe a
---    projection without its primary document.
---
---What did NOT change is the failure direction: a JSON that cannot be written
---still leaves the reviewer's prose on disk, and the draft is still retained.
---@return table? result  { json_path, md_path, revision }
---@return string? reason
function M.submit(opts)
  local okr, review = pcall(require, "worktree.review")
  if not okr then return nil, "worktree.review is unavailable" end

  local repo, sha = opts.repo, opts.sha
  local slug = repo and repo.slug
  if not (slug and sha) then return nil, "no repo/commit to attach a review to" end

  -- FAIL CLOSED (lector, §2.5 amendment review): the ONLY scope that may reach
  -- the store is the committed production `<slug>@<40-hex>`. A working scope, or
  -- any malformed one, is rejected here before `save_pair` — so an uncommitted
  -- draft can never be written as a saved review by any path, even a mistaken
  -- caller passing `sha = "working"`.
  if not M.is_committed_scope(M.scope(slug, sha) or "") then
    return nil, "refusing to save: a review must anchor to a full commit sha "
      .. "(a draft on uncommitted work stays a draft — commit first)"
  end

  -- `cwd` is passed so a first-touch snapshot resolves against the RIGHT repo;
  -- a dirty draft will already carry one from the composer.
  local d = M.draft(slug, sha, { cwd = opts.cwd })
  if not M.dirty(d) then
    return nil, "nothing to submit — add a comment, a summary or an unanchored finding first"
  end

  -- FROM THE SNAPSHOT, not from the config as it stands now. The draft was
  -- authored by whoever began it; re-resolving here re-attributed their work to
  -- whoever the repo config happens to name at submit time (lector MF5).
  local snap = (type(d) == "table" and type(d.meta) == "table" and d.meta.reviewer)
    or nil
  local display, rslug = snap and snap.display or nil, snap and snap.slug or nil
  if not display or display == "" then
    -- No snapshot -- a draft bound through the two-argument call, or one from
    -- before this change. Resolve from THIS submit's cwd, which is the repo
    -- actually under review, and record it so the draft stops being ambiguous.
    display, rslug = M.reviewer(opts.cwd)
    if type(d) == "table" and type(d.meta) == "table" then
      d.meta.reviewer = { display = display, slug = rslug,
                          bound_at = os.time(), cwd = opts.cwd,
                          bound_at_submit = true }
    end
  end
  if not rslug then
    return nil, "the reviewer name produced no safe path segment; set git config user.name"
  end

  local doc = review.new({
    slug = slug, url = repo.url, owner = repo.owner, name = repo.name,
    commit = sha, reviewer = display,
    verdict = d.verdict, summary = d.summary,
  })
  -- Carried so a later `validate_pair` can check the document really sits in
  -- THIS reviewer's directory rather than merely somewhere under the KB.
  doc.reviewer_slug = rslug
  doc.comments = vim.deepcopy(M.anchored(d))

  -- The generator runs only once the revision is WON, so the rendered document
  -- can name it. It returns a BODY only — and it must not raise: an `error()`
  -- here propagated out of the writer instead of returning a reason, and left
  -- the draft in a state the caller could not report on. `save_pair` guards it
  -- now, and this side simply has nothing left to throw.
  local res, err = review.save_pair(slug, doc, function(rev)
    return M.render_markdown({
      draft = d, repo_label = repo.label, sha = sha,
      reviewer = display, revision = rev,
    })
  end, {
    topic = M.topic(repo, sha),
    -- FORWARD the resolved KB root. `_kb_root()` has been sitting here,
    -- correct and unreachable, since ADR-0067 A4: it was written for
    -- `markdown_path`, that function was deleted when the store took ownership
    -- of the canonical path, and the value it resolves was never passed on. So
    -- `save_pair` fell back to reading `$AUTO_AGENTS_KB_ROOT` — a variable
    -- injected into AGENT spawns only — and every submit from the editor died
    -- at the preflight with "cannot resolve $KB_ROOT for the review document".
    -- Three fix rounds went past it because every test sets that variable and
    -- every agent process has it (Johno, 2026-09-02/03).
    --
    -- The resolver reaches the KB through AUTO-CORE, which owns the
    -- `auto-agents.kb.root()` hop, so the panel keeps depending on auto-core
    -- and worktree.nvim alone.
    kb_root = _kb_root(),
  })

  if not res then
    -- The orphan Markdown, when there is one, is PRESERVED by save_pair and
    -- named in its error: it is the reviewer's prose, and reporting a failure
    -- while silently deleting their writing would be the worse outcome. The
    -- draft is retained for the same reason.
    return nil, tostring(err)
  end

  M.discard(slug, sha)
  return { json_path = res.json_path, md_path = res.md_path, revision = res.revision }, nil
end

return M
