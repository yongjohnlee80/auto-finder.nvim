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
---@return string? display, string? slug
function M.reviewer()
  local display
  local ok, out = pcall(vim.fn.systemlist, { "git", "config", "user.name" })
  if ok and type(out) == "table" and out[1] and out[1] ~= "" then display = out[1] end
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

---markdown_path builds the canonical primary-document path for a revision.
---@return string? path, string? reason
function M.markdown_path(repo, sha, reviewer_slug, revision)
  local kb = _kb_root()
  if not kb then return nil, "cannot resolve $KB_ROOT — is auto-core loaded?" end
  if not reviewer_slug then
    return nil, "the reviewer name produced no safe path segment; set git config user.name"
  end
  local date = os.date("!%Y-%m-%d")
  return ("%s/agents/%s/reviews/%s-%s-r%d-review.md")
    :format(kb, reviewer_slug, date, _topic(repo, sha), revision)
end

---render_markdown produces the PRIMARY artifact.
---
---Every anchored finding appears with its `path:line`, and so do the UNANCHORED
---ones — review-json §6 forbids inventing a line number to make something
---placeable, so a finding that does not fit an anchor lives here and only here.
---@return string
function M.render_markdown(opts)
  local d = opts.draft
  local lines = {
    ("# Review — %s @ %s"):format(opts.repo_label or "repo", tostring(opts.sha):sub(1, 7)),
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

---submit writes the pair: the final Markdown name is claimed FIRST, the JSON
---published LAST.
---
---The ordering is the whole safety argument (ADR-0065 §2.6):
---
---  * The Markdown is claimed at its FINAL name, in the home §6 established,
---    before any JSON exists — so there is no rename step that can fail and
---    strand a projection.
---  * `review.save` is used, NOT `save_next`. `save` is an exclusive create
---    that refuses an existing revision; `save_next` RE-SELECTS the revision on
---    collision, which would silently divorce the JSON from the Markdown
---    already claimed for N.
---  * The JSON is published last, so every failure leaves at most an orphan
---    Markdown — a primary document nobody has projected yet, which §6 permits
---    — and never a projection without its primary.
---@return table? result  { json_path, md_path, revision }
---@return string? reason
function M.submit(opts)
  local okr, review = pcall(require, "worktree.review")
  if not okr then return nil, "worktree.review is unavailable" end
  local oks, store = pcall(require, "worktree.store")
  if not oks then return nil, "worktree.store is unavailable" end

  local repo, sha = opts.repo, opts.sha
  local slug = repo and repo.slug
  if not (slug and sha) then return nil, "no repo/commit to attach a review to" end

  local d = M.draft(slug, sha)
  if #(d.comments or {}) == 0 and not (d.summary and d.summary ~= "") then
    return nil, "nothing to submit — add a comment or a summary first"
  end

  local display, rslug = M.reviewer()
  if not rslug then
    return nil, "the reviewer name produced no safe path segment; set git config user.name"
  end

  local start = review.latest_revision(slug, sha) + 1
  for rev = start, start + 24 do
    local md_path, mderr = M.markdown_path(repo, sha, rslug, rev)
    if not md_path then return nil, mderr end

    local body = M.render_markdown({
      draft = d, repo_label = repo.label, sha = sha, reviewer = display, revision = rev,
    })
    if not store.ensure_dir(vim.fn.fnamemodify(md_path, ":h")) then
      return nil, "could not create " .. vim.fn.fnamemodify(md_path, ":h")
    end
    -- Claim the FINAL name. A collision advances the revision so BOTH names
    -- move together; it never reuses N with a different document.
    local claimed, cerr = store.create_exclusive(md_path, body)
    if cerr then return nil, cerr end
    if claimed then
      local doc = review.new({
        slug = slug, url = repo.url, owner = repo.owner, name = repo.name,
        commit = sha, reviewer = display,
        verdict = d.verdict, summary = d.summary,
      })
      doc.revision = rev
      doc.comments = vim.deepcopy(d.comments or {})
      local jpath, jerr = review.save(slug, doc)
      if not jpath then
        -- The orphan Markdown is PRESERVED and reported, never quietly removed:
        -- it is the reviewer's prose, and §6 tolerates a primary document that
        -- has not been projected yet.
        return nil, ("the review JSON could not be written (%s). Your Markdown review is "
          .. "kept at %s — it is not lost."):format(tostring(jerr), md_path)
      end
      M.discard(slug, sha)
      return { json_path = jpath, md_path = md_path, revision = rev }, nil
    end
    -- name taken: try the next revision
  end
  return nil, "could not claim a revision after 25 attempts"
end

return M
