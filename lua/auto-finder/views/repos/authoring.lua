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

-- Drafts, keyed by `<slug>@<sha>`. One per commit under review.
M._drafts = {}

local function _key(slug, sha) return tostring(slug) .. "@" .. tostring(sha) end

---draft returns (and lazily creates) the draft for a commit.
---@return table
function M.draft(slug, sha)
  local k = _key(slug, sha)
  M._drafts[k] = M._drafts[k] or { comments = {}, summary = nil, verdict = "comment" }
  return M._drafts[k]
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
  if type(d) ~= "table" then return false end
  return #(d.comments or {}) > 0
    or #(d.unanchored or {}) > 0
    or (type(d.summary) == "string" and vim.trim(d.summary) ~= "")
end

---discard drops a draft outright.
function M.discard(slug, sha) M._drafts[_key(slug, sha)] = nil end

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
  local n_anchored, n_unanchored = #(d.comments or {}), #(d.unanchored or {})
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
  if #(d.comments or {}) > 0 then
    lines[#lines + 1] = "## Anchored findings"
    lines[#lines + 1] = ""
    for _, c in ipairs(d.comments) do
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
  if #(d.unanchored or {}) > 0 then
    -- §6: "a finding that is not anchored to a line has nowhere to go in the
    -- JSON and must not be dropped to fit the schema."
    lines[#lines + 1] = "## Unanchored findings"
    lines[#lines + 1] = ""
    for _, u in ipairs(d.unanchored) do
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

  local d = M.draft(slug, sha)
  if not M.dirty(d) then
    return nil, "nothing to submit — add a comment, a summary or an unanchored finding first"
  end

  local display, rslug = M.reviewer(opts.cwd)
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
  doc.comments = vim.deepcopy(d.comments or {})

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
