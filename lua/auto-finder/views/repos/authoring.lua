---auto-finder.views.repos.authoring — the consumer half of ADR-0065.
---
---**Most of this module now lives in `auto-core.review.draft`.** What is left
---here is the one function that could not go: `submit`, which needs
---`worktree.review` to write the pair.
---
---### Why the rest moved (2026-09-07)
---
---The draft STORE moved to auto-core in ADR-0081 §2.2, for a reason its own
---comment stated: "the plugin holding it was the one no other plugin may depend
---on". The DOMAIN layer over that store stayed here, and so the same trap
---stayed with it — which is exactly what happened when worktree.nvim's graph
---wanted to open a commit for review and had to reach UP into auto-finder,
---inverting the family's order (auto-core <- worktree <- auto-finder).
---
---So the domain layer followed the store down. Every name this module used to
---define is re-exported below, unchanged, so callers need no edit: the `scope`
---you get from here IS `auto-core.review.draft.scope`.
---
---`submit` stays because it is the only function that reaches sideways rather
---than down. auto-core depends on neither worktree nor auto-finder and must
---not, so a function needing `worktree.review` cannot live there.
---@module 'auto-finder.views.repos.authoring'

local M = {}

---_domain is the moved half. Required, not optional: this module is a facade
---over it and has nothing to fall back to.
---
---Resolved per-access rather than cached at load so a consumer that reloads
---auto-core mid-session does not keep talking to a stale table.
local function _domain()
  local ok, d = pcall(require, "auto-core.review.draft")
  if not ok or type(d) ~= "table" or type(d.scope) ~= "function" then
    error("auto-finder.repos.authoring: auto-core.review.draft is required"
      .. " (auto-core >= v0.2.22)", 0)
  end
  return d
end

---Everything the domain layer defines reads through, by NAME rather than by a
---copied list: a function added to `auto-core.review.draft` is reachable here
---the moment it exists, and one renamed there fails loudly here instead of
---silently resolving to a stale local copy.
setmetatable(M, { __index = function(_, k) return _domain()[k] end })

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
    kb_root = _domain().kb_root(),
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
