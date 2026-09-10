---View — the repos explorer over worktree.nvim (ADR-0060 §2.2).
---
---A pure renderer over an external data API: every byte of TREE DATA arrives
---through `worktree.repos`, and this view shells no git of its own for reads
---or actions.
---
---(This used to cite `views/dbase/tree.lua` as the sibling example of the same
---shape. That file is gone — ADR-0078 moved the drawer into autodb, leaving
---`views/dbase/init.lua` as a host-provider facade rather than a renderer, so
---the analogy no longer holds either way.)
---
---ONE NARROW EXCEPTION, and it is not tree data: submitting a review resolves
---the reviewer identity by shelling `git -C <worktree> config user.name`
---(`authoring.reviewer`, reached from `_submit_review` below). It is run
---per-worktree deliberately — `user.name` is per-repository, so answering from
---Neovim's cwd would attribute a review of one repo to another's identity.
---
---The tree it draws:
---
---    ▾ repo
---      ▾ worktree            ● watched
---        ▾ UNCOMMITTED (n files)
---            <changed file>
---        ▾ <commit>
---            <changed file>
---            <review json>
---      ▸ <collapsed worktree>
---
---**Everything is cached per node id.** A CACHE-PRESERVING repaint — cursor
---move, focus change — must cost ZERO git subprocesses. The panel this replaces
---ran a blocking `git status` per worktree on every navigate plus a `git config`
---per repo, which is what made it expensive. Git is paid on first expand and
---after an explicit invalidation.
---
---Toggling a watch is an INVALIDATION, not a free repaint: `toggle_watch` drops
---the `repo:` and `wt:` caches and force-expands a newly watched worktree, so
---the render that follows re-reads status and history. This paragraph used to
---list watch toggle among the zero-git repaints; it was wrong, and the README
---repeated it verbatim until 2026-09-01 (auto-finder#15).
---@module 'auto-finder.views.repos.tree'

local logger = require("auto-finder.log")

local M = {}

local NS = vim.api.nvim_create_namespace("auto_finder_repos_tree")

---REFRESH_TOPIC is the single translated topic this view listens to. The core
---translator publishes it for worktree switch/add/remove AND for a watch
---toggled elsewhere, so the view never subscribes upstream (invariant A1).
M.REFRESH_TOPIC = "auto-finder.core.repos:changed"
local FILETYPE = "auto-finder"

-- ─── backend access (optional dependency) ─────────────────────

---_repos returns worktree.nvim's repos surface, or nil when it is absent or
---too old. Nil is a normal state: the panel renders an explanation.
local function _repos()
  local ok, r = pcall(require, "worktree.repos")
  if not ok or type(r) ~= "table" then return nil end
  if type(r.available) ~= "function" or not r.available() then return nil end
  return r
end

---_base_branch resolves the branch a repo's work diverges FROM.
---
---Delegated, never re-derived. `worktree.repos.base_branch` already asks
---`origin/HEAD` first and falls back through local `main` / `master`, and it
---caches per common-dir; the tree renders "(base)" markers from the same
---answer, so a second implementation here would let the marker and the diff
---range disagree about which branch is the base.
---
---This replaces two call sites that asked for `backend.resolve_base` — a
---function worktree.nvim has never exported. Both were written
---`type(...) == "function" and ...`, so they never errored and never ran:
---the base silently defaulted to the literal "main" on every repo, including
---ones whose default branch is not called that.
---@param repo table
---@return string? branch
local function _base_branch(repo)
  local backend = _repos()
  if backend and type(backend.base_branch) == "function" then
    local ok, b = pcall(backend.base_branch, repo)
    if ok and type(b) == "string" and b ~= "" then return b end
  end
  return nil
end

---_range_commits lists the commits `head` adds on top of `base`, oldest first,
---each with its changed files.
---
---The name is deliberately about the RANGE rather than about PRs. The backend
---function is called `pr_diff` because a PR was its first caller, but nothing
---in it is PR-specific: it runs `git log <base>..<head>`. A branch with no PR
---asks the same question.
---@param repo table
---@param base string
---@param head string
---@return table[] commits
local function _range_commits(repo, base, head)
  local backend = _repos()
  if backend and type(backend.pr_diff) == "function" then
    local ok, c = pcall(backend.pr_diff, repo, base, head)
    if ok and type(c) == "table" then return c end
  end
  local ok_pr, pr_mod = pcall(require, "worktree.pr")
  if ok_pr and type(pr_mod) == "table" and type(pr_mod.pr_diff_commits) == "function" then
    local ok, c = pcall(pr_mod.pr_diff_commits, repo, base, head)
    if ok and type(c) == "table" then return c end
  end
  return {}
end

-- ─── cache ────────────────────────────────────────────────────

M._expanded = {}
M._cache = {}
M._bufnr = nil
M._rows = nil
M._more = {}   -- node id -> extra commit windows requested

local function _cache(id)
  M._cache[id] = M._cache[id] or {}
  return M._cache[id]
end

---invalidate drops one node's cached children, or everything.
function M.invalidate(id)
  if id then M._cache[id] = nil else M._cache = {} end
end

local _rerender  -- forward declaration

-- ─── row model ────────────────────────────────────────────────

local function _row(rows, lines, hls, opts)
  lines[#lines + 1] = opts.text
  rows[#rows + 1] = opts
  local n = #lines - 1
  if opts.hl then hls[#hls + 1] = { lnum = n, hl = opts.hl } end
  -- `spans` paint part of the row over the whole-line `hl`. Each is a byte
  -- range into `opts.text` with its own group and a higher priority, so a
  -- badge (e.g. a severity) shows through the row's status colour.
  for _, sp in ipairs(opts.spans or {}) do
    hls[#hls + 1] = { lnum = n, hl = sp.hl, col = sp.from, end_col = sp.to,
                      priority = sp.priority or 200 }
  end
  return #lines
end

---_chevron marks a container's expansion state on its OWN row (ADR-0060 §2.2's
---tree grammar). Both states returned the empty string, so collapsed vs
---expanded was inferable only by scanning ahead to the next line's indent —
---recoverable, but not where a reader looks (r1 nit).
---
---Applied uniformly to every container, including a collapsed commit. The ADR's
---diagram omits the glyph there, but that is an inconsistency in the diagram
---rather than a rule: its "Rules" list never restates the grammar, and a
---collapsed commit needs the affordance as much as a collapsed worktree.
---Both glyphs are one display cell and the call site appends a space, so leaf
---rows (independently indented at IND*3) do not move.
local function _chevron(expanded) return expanded and "▾" or "▸" end

-- Johno's scheme (ADR-0060 §2.2 as revised in §10, 2026-09-02): added GREEN
-- with a `+`, modified YELLOW/ORANGE, deleted RED — FOREGROUND only, the way
-- the todos panel colours its Completed and Deferred headers. The groups are
-- auto-core's, which links them to the Diagnostic* family (Ok/Warn/Error).
-- They used to link to DiffAdd/DiffDelete, whose background tints painted the
-- whole row a wash that read as "not so green"; a derived yellow tint for
-- modified (auto-core v0.2.8) had the same problem and is gone. The `+`
-- marker stays: it still tells added from modified when colour cannot.
local KIND_HL = {
  added      = "AutoCoreGitAdded",
  modified   = "AutoCoreGitModified",
  deleted    = "AutoCoreGitDeleted",
  renamed    = "AutoCoreGitRenamed",
  untracked  = "AutoCoreGitUntracked",
  conflicted = "AutoCoreGitConflicted",
}
-- Review severity colours are auto-core's ANNOTATION groups, so a finding reads
-- the same in this tree as it does inline in the diff view. They link to the
-- Diagnostic* family — foreground only, like the status colours above (§10).
local SEVERITY_HL = {
  ["must-fix"]   = "AutoCoreReviewMustFix",
  ["should-fix"] = "AutoCoreReviewShouldFix",
  ["nit"]        = "AutoCoreReviewNit",
  ["question"]   = "AutoCoreReviewQuestion",
}

-- A PR is no longer its own row (ADR-0083 Amendment r9): it is an ASSOCIATION
-- with the worktree/branch, shown as a `[#N]` badge on that row. The colour
-- carries the state the old `[OPEN]/[DRAFT]/[CLOSED]` text did — green open,
-- gray draft, red closed/merged — so the number reads its state at a glance.
---@param pr table  a worktree.repos PR record ({ number, state, draft, ... })
---@return string highlight_group
local function _pr_badge_hl(pr)
  if pr.draft or pr.state == "draft" then return "AutoCoreReviewFrame" end
  if pr.state == "closed" or pr.state == "merged" then return "AutoCoreGitDeleted" end
  return "AutoCoreGitAdded"
end

---CLOSE_CHOICES are the answers to the unsent-review prompt, spelled out.
---
---`keep` is the one that was MISSING, and its absence was the defect. A draft
---lives in **auto-core's draft store** — process memory, keyed by repo slug plus
---the full commit (ADR-0081 §2.5) — so it SURVIVES closing the diff view and
---repaints on reopen; `open_diff` says so in its own comment. It moved there
---from `authoring._drafts` so that every plugin, an agent included, can read a
---draft without depending on auto-finder. The prompt nevertheless offered only submit / discard /
---cancel, which forced a reader who just wanted to look away into either
---finishing a multi-prompt submit or destroying work that was never at risk.
---Johno hit exactly that: "it keeps bugging out that I have to submit ... I had
---to discard at the end" (2026-09-02).
local CLOSE_CHOICES = {
  submit  = "submit the review now",
  keep    = "close and keep the draft",
  discard = "discard the draft",
  stay    = "stay in the diff view",
}

---_draft_holds names a draft's contents for a prompt or a message.
---
---A COUNT is the difference between "something went wrong" and "your three
---comments are still here", and every message below that reports a non-event
---uses it. The footer's own count is a different question — how many ANCHORED
---annotations are drawn — so unanchored findings appear here and not there.
---@param d table
---@return string
local function _draft_holds(d)
  -- Required HERE, not at file scope: this module's other users of `authoring`
  -- are inside functions, and a file-scope require would load it at a different
  -- point in the dependency graph than the rest of the file expects.
  local authoring = require("auto-finder.views.repos.authoring")
  local bits = {}
  local a, u = #authoring.anchored(d), #authoring.unanchored(d)
  if a > 0 then bits[#bits + 1] = a .. (a == 1 and " comment" or " comments") end
  if u > 0 then bits[#bits + 1] = u .. " unanchored" end
  if type(d.summary) == "string" and vim.trim(d.summary) ~= "" then
    bits[#bits + 1] = "a summary"
  end
  if #bits == 0 then return "nothing" end
  return table.concat(bits, " + ")
end

---_repo_drafts lists this repo's UNSAVED drafts, newest scope order.
---
---From auto-core's store, filtered to scopes that actually hold work. The scope
---grammar is `<slug>@<full sha>` (ADR-0081 §2.5), so the slug match is exact —
---a prefix match would let `lab__proj` claim `lab__project`'s drafts.
---@param repo table
---@return { sha: string, short: string, holds: string, scope: string, draft: table }[]
local function _repo_drafts(repo)
  local ok, drafts = pcall(require, "auto-core.drafts")
  if not ok or type(drafts) ~= "table" or type(drafts.scopes) ~= "function" then
    return {}
  end
  local authoring = require("auto-finder.views.repos.authoring")
  local out = {}
  for _, scope in ipairs(drafts.scopes({ dirty_only = true })) do
    local d = drafts.peek(scope)
    -- A COMMIT draft: `<slug>@<40-hex>`. An UNCOMMITTED draft:
    -- `<slug>@working:<worktree-path>` (ADR-0081 §2.5). Both are surfaced so a
    -- reader can hand either to an agent; the uncommitted one has no sha and
    -- reopens the UNCOMMITTED diff instead.
    local slug, sha = tostring(scope):match("^(.*)@(%x+)$")
    if d and slug == repo.slug and sha then
      out[#out + 1] = {
        sha = sha, short = sha:sub(1, 7), scope = scope, draft = d,
        holds = "(draft — " .. _draft_holds(d) .. ")",
      }
    else
      -- ANCHORED parse (lector): `is_working` returns the slug + worktree id
      -- from a real `@working:` boundary, not a substring search.
      local ok_w, wslug = authoring.is_working(scope)
      if d and ok_w and wslug == repo.slug then
        out[#out + 1] = {
          working = true, worktree = d.meta and d.meta.worktree or nil,
          short = "UNCOMMITTED", scope = scope, draft = d,
          holds = "(draft — " .. _draft_holds(d) .. ")",
        }
      end
    end
  end
  table.sort(out, function(a, b) return a.scope < b.scope end)
  return out
end

---_review_label renders one review row as a FILENAME plus a bracketed badge
---(§11 — Johno: "the severity should be appended beside the filename in
---filename [severity] kinda way").
---
---The `<slug>@` prefix is dropped. Every file in a repo's review directory
---carries the same slug, so on these rows it is twenty-odd columns of a narrow
---panel spent repeating the repo row above; what remains still names the commit
---— `<short-sha>.r<N>.review.json` — which is the identifying half. `i` prints
---the whole path.
---
---The badge is the WORST severity in the file, because that is what a reader
---triages on. A review with no comments has no severity to show, so it falls
---back to its verdict — a summary-only approval is the common case — and a file
---that would not parse says so instead of looking empty. Malformed is additive,
---never a replacement: a review can carry real findings AND fail validation,
---and hiding either half is how a reviewer loses one.
---@param meta table  a `worktree.review.describe` record
---@param posted boolean?  whether this review's findings are posted to its PR
---@return string
local function _review_label(meta, posted)
  local name = tostring(meta.name or "?")
  if meta.slug and meta.slug ~= "" then
    name = name:gsub("^" .. vim.pesc(meta.slug) .. "@", "")
  end
  -- PR association + posted state (ADR-0083 Amendment r9). A review that belongs
  -- to a PR is tagged `→ #N`; once its findings are on the forge it also carries
  -- `[posted]`. Both ride at the END of the label, after the severity badge, so
  -- `foo.lua [must-fix] → #43 [posted]` reads left-to-right most-important-first.
  local tail = ""
  if meta.pr then tail = tail .. "  → #" .. tostring(meta.pr) end
  if posted then tail = tail .. "  [posted]" end
  -- An UNDESCRIBED record — an older worktree.nvim's cheap `{revision, path,
  -- name}` — has no severity to report. It gets the bare filename rather than a
  -- badge that would read as "no comments" when the truth is "not looked at".
  if meta.severities == nil then return name .. tail end
  local parts = {}
  if meta.worst then parts[#parts + 1] = meta.worst
  elseif meta.verdict and meta.verdict ~= "" then parts[#parts + 1] = meta.verdict
  elseif not meta.err then parts[#parts + 1] = "no comments" end
  if meta.err then parts[#parts + 1] = "malformed" end
  return name .. "  [" .. table.concat(parts, " · ") .. "]" .. tail
end

---_review_posted asks the backend whether a review's findings are all on the
---forge (read from the two-phase posting RECEIPT — the review JSON itself is an
---ADR-0067 immutable artifact and must not be written to). Guarded: an older
---worktree.nvim without `review_posted` simply never shows `[posted]`, so this
---auto-finder release degrades cleanly ahead of the worktree.nvim side landing.
---@param repo table?
---@param meta table
---@return boolean
local function _review_posted(repo, meta)
  if not (repo and meta and meta.pr) then return false end
  local backend = _repos()
  if not (backend and type(backend.review_posted) == "function") then return false end
  local ok, res = pcall(backend.review_posted, repo, meta)
  return ok and res == true
end

---_render_review draws one review as an EXPANDABLE row whose children are its
---two paired files — the Markdown primary and the JSON projection (ADR-0067).
---
---Johno, 2026-09-03: a review is a 1:1 pair, and the tree should show it as one:
---`reviews → <repo>@<sha> [severity] → [markdown, json]`. `<CR>` on the review
---toggles the pair; `<CR>` on either child opens that file — so the Markdown can
---be OPENED AND EDITED for more context, not just the JSON read. Both the
---per-commit review rows and the repo-wide section render through here, so the
---same review reads identically wherever it appears.
---
---Keyed on the review's own path, which is unique per (repo, commit, revision),
---so a review expanded in the section and under its commit share one state.
---@param rows table[]
---@param lines string[]
---@param hls table[]
---@param depth integer
---@param meta table   a `worktree.review.describe` record (has .path, .document)
---@param extra table  { repo, worktree?, node? } carried onto every emitted row
local function _render_review(rows, lines, hls, depth, meta, extra)
  local IND = "  "
  local id = "review:" .. tostring(meta.path)
  local open = M._expanded[id] == true
  local ppr = extra and (extra.parent_pr or extra.pr)
  local posted = _review_posted(extra and extra.repo, meta)
  _row(rows, lines, hls, {
    kind = "review", id = id, expandable = true,
    repo = extra.repo, worktree = extra.worktree, node = extra.node, review = meta,
    parent_pr = ppr,
    hl = (meta.worst and SEVERITY_HL[meta.worst]) or "AutoCoreReviewFrame",
    text = string.rep(IND, depth) .. _chevron(open) .. " " .. _review_label(meta, posted),
  })
  if not open then return end
  -- The pair, newest-primary first: Markdown, then JSON. A review whose document
  -- field is absent (a malformed or legacy JSON) shows only the JSON and says
  -- the Markdown is missing rather than drawing a row that opens nothing.
  if type(meta.document) == "string" and meta.document ~= "" then
    _row(rows, lines, hls, {
      kind = "review_file", repo = extra.repo, worktree = extra.worktree,
      node = extra.node, review = meta, path = meta.document,
      parent_pr = ppr,
      hl = "AutoCoreReviewBody",
      text = string.rep(IND, depth + 1) .. "md   "
        .. (vim.fn.fnamemodify(meta.document, ":t")),
    })
  else
    _row(rows, lines, hls, {
      kind = "message", hl = "AutoCoreDimmed",
      text = string.rep(IND, depth + 1) .. "md   (no Markdown recorded)",
    })
  end
  _row(rows, lines, hls, {
    kind = "review_file", repo = extra.repo, worktree = extra.worktree,
    node = extra.node, review = meta, path = meta.path,
    parent_pr = ppr,
    hl = "AutoCoreReviewFrame",
    text = string.rep(IND, depth + 1) .. "json " .. (vim.fn.fnamemodify(meta.path, ":t")),
  })
end

-- Fallback marker for items with no index side (a commit's files).
local KIND_MARK = {
  added = "+", modified = "M", deleted = "D",
  renamed = "R", untracked = "+", conflicted = "!",
}

---_status_mark renders a change's marker.
---
---Working-tree items carry porcelain `x`/`y`, and showing BOTH columns is how
---git itself conveys staged-vs-unstaged: a file staged and then modified again
---reads `MM`, which a single glyph cannot express. Commit items have no index
---side, so they keep the one-glyph kind mark, padded to the same width so the
---paths stay aligned in both cases.
---@param f table
---@return string
local function _status_mark(f)
  if type(f.x) == "string" and type(f.y) == "string" and #f.x == 1 and #f.y == 1 then
    return f.x .. f.y
  end
  return (KIND_MARK[f.kind] or "?") .. " "
end

-- ─── render ───────────────────────────────────────────────────

local function _render(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return end
  local ok_hl, hl = pcall(require, "auto-core.ui.highlights")
  if ok_hl then hl.ensure() end

  local lines, rows, hls = {}, {}, {}
  local IND = "  "
  local backend = _repos()

  local function msg(depth, text, group)
    _row(rows, lines, hls, { kind = "message", hl = group or "AutoCoreDimmed",
      text = string.rep(IND, depth) .. text })
  end

  local function container(depth, opts)
    local open = M._expanded[opts.id] == true
    local prefix = string.rep(IND, depth) .. _chevron(open) .. " "
    _row(rows, lines, hls, {
      kind = opts.kind, id = opts.id, expandable = true,
      repo = opts.repo, worktree = opts.worktree, node = opts.node,
      hl = opts.hl,
      text = prefix .. opts.label .. (opts.suffix or ""),
    })
    -- `spans` are offsets into the LABEL, so a caller never has to know how
    -- wide the indent or the chevron is -- which is exactly the kind of
    -- duplicated layout arithmetic that drifts when the glyph changes.
    for _, sp in ipairs(opts.spans or {}) do
      hls[#hls + 1] = { lnum = #lines - 1, hl = sp.hl,
                        col = #prefix + sp.from, end_col = #prefix + sp.to }
    end
    return open
  end

  if not backend then
    msg(0, "worktree.nvim's repos surface is unavailable.", "AutoCoreDimmed")
    msg(0, "Install/update yongjohnlee80/worktree.nvim to use this panel.")
  else
    -- ── root: repositories ──
    local root = _cache("root")
    if not root.items then root.items = backend.repos() end
    if #root.items == 0 then
      msg(0, "No repositories found under the workspace root.", "AutoCoreDimmed")
      msg(0, "? for help")
    end

    for _, repo in ipairs(root.items) do
      local rid = "repo:" .. repo.common_dir
      local ropen = container(0, {
        kind = "repo", id = rid, repo = repo, hl = "AutoCorePanelTitle",
        label = repo.label, suffix = repo.is_bare and "  (bare)" or "",
      })
      if ropen then
        local rc = _cache(rid)
        if not rc.items then
          -- Capture BOTH values (r2 SF1). The error was discarded here, so a
          -- failed `git worktree list` rendered "(no worktrees)" — byte-identical
          -- to a clean empty list, and in practice that string was ONLY ever the
          -- failure, since every discovered repo has at least one worktree.
          -- Cached alongside the items so a repaint costs no git.
          local items, werr = backend.worktrees(repo)
          rc.items, rc.err = items, werr
        end
        if #rc.items == 0 then
          if rc.err then
            msg(1, "git worktree list failed — R to retry", "AutoCoreGitDeleted")
          else
            msg(1, "(no worktrees)")
          end
        end
        for _, wt in ipairs(rc.items) do
          local wid = "wt:" .. wt.path
          -- The watch marker is the panel's one piece of persistent state the
          -- user drives; show it plainly so `w` has visible feedback.
          local suffix = wt.watched and "  ● watched" or ""
          if wt.is_base then suffix = suffix .. "  (base)" end
          -- Resolve the branch name once so the PR badge can append to it. The
          -- bare `wt.branch or <dir>` form MUST be parenthesised or `..` binds
          -- the `(detached)` suffix to the fallback alone (Lua `..` > `or`).
          local branch_label = wt.branch
            or (vim.fn.fnamemodify(wt.path, ":t") .. (wt.detached and "  (detached)" or ""))
          -- PR association (ADR-0083 Amendment r9): a worktree whose branch is a
          -- PR carries a `[#N]` badge after the name, BEFORE the watch marker —
          -- the PR is no longer a row of its own. Cached per-worktree (`false`
          -- records "looked up, no PR") so an unchanged repaint costs no backend
          -- call; `invalidate()` — which GetPR fires — re-queries.
          local wc = _cache(wid)
          if wc.pr == nil then
            local found = nil
            if type(backend.pr_for_worktree) == "function" then
              found = backend.pr_for_worktree(repo, wt)
            end
            wc.pr = found or false
          end
          local pr = wc.pr or nil
          local wlabel, wspans = branch_label, nil
          if pr then
            local from = #wlabel + 2 -- badge sits after two padding spaces
            wlabel = wlabel .. "  [#" .. tostring(pr.number) .. "]"
            wspans = { { from = from, to = #wlabel, hl = _pr_badge_hl(pr) } }
          end
          local wopen = container(1, {
            kind = "worktree", id = wid, repo = repo, worktree = wt,
            hl = wt.watched and "AutoCoreSectionActive" or "AutoCoreSectionInactive",
            label = wlabel,
            suffix = suffix,
            spans = wspans,
          })
          if wopen then
            if not wt.watched then
              -- §2.3: an unwatched worktree computes NOTHING. Say why, so the
              -- empty expansion reads as a choice rather than a failure.
              msg(2, "not watched — w to watch and list commits")
            else
              local cc = _cache(wid)
              -- The window this worktree has asked for so far: the base 15
              -- (ADR-0060 §2.4) plus one more window per `m`.
              local window = 15 + (M._more[wid] or 0) * 15
              if not cc.items then
                local nodes, meta = backend.children(repo, wt, { limit = window })
                cc.items, cc.meta = nodes, meta
              end
              if #cc.items == 0 then
                -- A FAILED read must never render as a clean tree (ADR-0060 r1
                -- SF3). `children()` reports git failures in meta; claiming
                -- "clean" when the status read errored tells the user they have
                -- no uncommitted work when we simply could not look.
                local rerr = cc.meta and (cc.meta.status_err or cc.meta.log_err)
                if rerr then
                  msg(2, "git read failed — R to retry", "AutoCoreGitDeleted")
                else
                  msg(2, "(no commits, clean tree)")
                end
              elseif cc.meta and (cc.meta.status_err or cc.meta.log_err) then
                -- Partial success: commits listed but the status read failed, so
                -- the absence of an UNCOMMITTED row is not evidence of a clean
                -- tree. Say so rather than letting omission imply it.
                msg(2, "working-tree status unavailable", "AutoCoreGitDeleted")
              end
              -- (ADR-0083 Amendment r9) The PR is now a `[#N]` badge on the
              -- worktree row above, not a row of its own; its reviews appear in
              -- the repo's reviews section tagged `→ #N`. No PR block here.
              for _, node in ipairs(cc.items) do
                local nid = node.kind == "uncommitted"
                  and ("unc:" .. wt.path) or ("commit:" .. node.sha)
                -- PUSH STATE on the hash (Johno, 2026-09-03: "pushed commit
                -- hash be in purple color, and none pushed on to be orange",
                -- with the title left plain). `pushed` is nil when the read
                -- FAILED, and nil paints nothing: a panel that renders every
                -- hash purple because git errored is worse than one that
                -- renders none, because the reader cannot tell.
                local spans
                if node.kind == "commit" and node.pushed ~= nil and node.short then
                  spans = { { from = 0, to = #node.short,
                              hl = node.pushed and "AutoCoreGitPushed"
                                or "AutoCoreGitUnpushed" } }
                end
                local nopen = container(2, {
                  kind = node.kind, id = nid, repo = repo, worktree = wt,
                  node = node,
                  hl = node.kind == "uncommitted" and "AutoCoreGitModified" or nil,
                  label = node.label,
                  spans = spans,
                })
                if nopen then
                  local fc = _cache(nid)
                  if not fc.items then
                    if node.kind == "uncommitted" then
                      fc.items = backend.uncommitted(wt)
                      fc.reviews = {}
                      -- The working tree has no commit for a review to anchor
                      -- to, so it can carry no feedback by construction.
                      fc.reviewed = {}
                    else
                      fc.items = backend.commit_files(repo, node.sha)
                      -- ONE read pass answers both questions this commit's rows
                      -- ask: what reviews it has (described, so each row can
                      -- show its severity) and which of its files carry
                      -- comments (a pure merge over those same records). Paid
                      -- once per expansion and cached with the file list, so a
                      -- repaint costs nothing.
                      --
                      -- Guarded on the SURFACE, not a version: against an older
                      -- worktree.nvim the rows fall back to the cheap revision
                      -- listing and no file is badged, which is the tree this
                      -- panel has always drawn.
                      if type(backend.reviews_described) == "function" then
                        fc.reviews = backend.reviews_described(repo, node.sha)
                        fc.reviewed = type(backend.tally_paths) == "function"
                          and backend.tally_paths(fc.reviews) or {}
                      else
                        fc.reviews = backend.reviews(repo, node.sha)
                        fc.reviewed = {}
                      end
                    end
                  end
                  if #fc.items == 0 and #(fc.reviews or {}) == 0 then
                    msg(3, "(no files)")
                  end
                  for _, f in ipairs(fc.items) do
                    -- The badge names the WORST SEVERITY on the file (Johno,
                    -- 2026-09-03), not the literal word "feedback": `[must-fix]`
                    -- tells the reader which file to open first, and it is
                    -- painted in the severity's own colour (a span over the
                    -- badge) so it reads the same as the finding does inline.
                    -- The tally already carries `worst` (worktree tally_paths).
                    local reviewed = (fc.reviewed or {})[f.path]
                    local worst = reviewed and reviewed.worst or nil
                    local body = string.rep(IND, 3) .. (KIND_MARK[f.kind] or "?")
                      .. " " .. f.path
                      .. (f.orig and ("  ← " .. f.orig) or "")
                    local badge = worst and ("  [" .. worst .. "]") or ""
                    local spans
                    if worst and SEVERITY_HL[worst] then
                      -- Paint just the `[severity]` badge, not the whole row.
                      spans = { { from = #body, to = #body + #badge,
                                  hl = SEVERITY_HL[worst] } }
                    end
                    _row(rows, lines, hls, {
                      kind = "file", repo = repo, worktree = wt, node = node,
                      file = f, hl = KIND_HL[f.kind] or "AutoCoreDimmed",
                      feedback = reviewed or nil, severity = worst,
                      text = body .. badge,
                      spans = spans,
                    })
                  end
                  -- The per-commit review rows are GONE (Johno, 2026-09-03): the
                  -- same review already appears in the repo's `reviews` section,
                  -- and listing it twice — once here, once there — is the
                  -- redundancy that made the tree read as if there were two
                  -- reviews. The file badge above is the only in-commit trace a
                  -- reviewed file needs; the review DOCUMENT lives under
                  -- `reviews`. `fc.reviews` is still fetched, but only to feed
                  -- the badge tally (`fc.reviewed`).
                end
              end
              -- Only a bounded window that is actually FULL shows a load-more
              -- affordance: a divergence range is complete by definition, and
              -- a window that came back short has nothing left to load. The
              -- row used to appear for EVERY windowed worktree, so a repo with
              -- one commit offered `m` and the key could never do anything —
              -- three of this workspace's four repos (2026-09-02) — while a
              -- long history paged fine: "works for some". auto-core reports
              -- `has_more` exactly (it asks for one commit past the window);
              -- an older auto-core without the field falls back to comparing
              -- the commits it returned against the window we asked for.
              local more = false
              if cc.meta and cc.meta.mode == "window" then
                if cc.meta.has_more ~= nil then
                  more = cc.meta.has_more == true
                else
                  local n = 0
                  for _, node in ipairs(cc.items) do
                    if node.kind == "commit" then n = n + 1 end
                  end
                  more = n >= window
                end
              end
              if more then
                _row(rows, lines, hls, {
                  kind = "more", id = wid, repo = repo, worktree = wt,
                  hl = "AutoCoreDimmed",
                  text = string.rep(IND, 2) .. "… m for more commits",
                })
              end
            end
          end
        end

        -- ── reviews: the repository's whole review index (§11) ──
        --
        -- A SIBLING of the worktrees rather than a child of a commit, because
        -- under a commit is the one place a review cannot always be found. The
        -- file names the sha it reviewed, so the moment history is rewritten —
        -- a rebase, an amend — no commit row can show it and the review is
        -- invisible in the tree, which is exactly when someone needs to find
        -- it and re-point it. Keyed on the repo, nothing in the store hides.
        --
        -- Two tiers of cost, each paying only for what it draws: the count on
        -- this row is one directory scan (`reviews_index`), and the documents
        -- are opened only once the section is expanded (`reviews_all`).
        -- Guarded on the surface, not on a version: an older worktree.nvim
        -- simply renders the tree it always did.
        if type(backend.reviews_index) == "function" then
          local vid = "reviews:" .. repo.common_dir
          local vc = _cache(vid)
          if not vc.index then vc.index = backend.reviews_index(repo) or {} end
          -- The count includes UNSAVED drafts: a section that says "(2)" while
          -- holding two reviews and a draft is lying about what is inside it,
          -- and the draft is the row a reader is most likely looking for.
          local ndrafts = #_repo_drafts(repo)
          local ntotal = #vc.index + ndrafts
          local vopen = container(1, {
            kind = "reviews", id = vid, repo = repo,
            hl = "AutoCoreSectionInactive",
            label = "reviews",
            suffix = ntotal > 0
              and ("  (" .. ntotal .. (ndrafts > 0
                and (", " .. ndrafts .. " draft" .. (ndrafts == 1 and "" or "s"))
                or "") .. ")")
              or "",
          })
          if vopen then
            if not vc.items then vc.items = backend.reviews_all(repo) or {} end
            if #vc.items == 0 then
              msg(2, "(no reviews recorded for this repository)")
            end
            for _, meta in ipairs(vc.items) do
              _render_review(rows, lines, hls, 2, meta, { repo = repo })
            end
            -- UNSAVED DRAFTS, beside the saved reviews (Johno, 2026-09-03:
            -- "I would like to see the draft feedback also listed on the
            -- reviews section. So that I can pass that draft to agent to work
            -- with before making the commits").
            --
            -- Readable here at all only because ADR-0081 P5 moved the draft
            -- store into auto-core: while it was auto-finder's module state,
            -- this panel could see it but nothing else could, which defeated
            -- the purpose of showing it.
            --
            -- `dirty_only` is load-bearing: reading a draft materialises an
            -- empty shell, so an unfiltered listing would show a row for every
            -- commit anyone ever pressed `s` on.
            for _, d in ipairs(_repo_drafts(repo)) do
              local n = #lines
              lines[n + 1] = ("      %s  %s"):format(d.short, d.holds)
              hls[#hls + 1] = { lnum = n, col = 6, end_col = 6 + #d.short,
                                hl = "AutoCoreGitModified" }
              rows[n + 1] = { kind = "draft", depth = 2, repo = repo,
                              sha = d.sha, scope = d.scope, draft = d.draft,
                              -- A working draft carries no sha; `<CR>` reopens
                              -- the UNCOMMITTED diff instead of a commit's.
                              working = d.working, worktree = d.worktree,
                              -- `text` is what every other row carries, and it
                              -- is how the suites identify a row without
                              -- re-deriving its label.
                              text = lines[n + 1] }
            end
          end
        end
      end
    end
  end

  if #lines == 0 then msg(0, "(nothing to show)") end

  -- Keep the cursor where it was: a background refresh must not move the user.
  local win = vim.fn.bufwinid(bufnr)
  local cursor = win ~= -1 and vim.api.nvim_win_get_cursor(win) or nil

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  for _, h in ipairs(hls) do
    if h.col then
      -- A COLUMN SPAN: only part of the row is painted. Needed because a
      -- commit's push state is a property of its HASH, not of the row -- a
      -- whole row in purple reads as a category, and the subject line is the
      -- reader's text, not a status field. Whole-row entries (no `col`) keep
      -- the original behaviour, so nothing else changes.
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, h.lnum, h.col,
        { end_row = h.lnum, end_col = h.end_col, hl_group = h.hl,
          priority = h.priority })
    else
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, h.lnum, 0,
        { end_line = h.lnum + 1, hl_group = h.hl })
    end
  end
  vim.bo[bufnr].modifiable = false

  if cursor and win ~= -1 then
    pcall(vim.api.nvim_win_set_cursor, win,
      { math.min(cursor[1], math.max(#lines, 1)), cursor[2] })
  end
  M._rows = rows
end

_rerender = function()
  if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then _render(M._bufnr) end
end

-- ─── actions ──────────────────────────────────────────────────

local function _row_under_cursor(panel_winid)
  if not (M._rows and panel_winid and vim.api.nvim_win_is_valid(panel_winid)) then
    return nil
  end
  return M._rows[vim.api.nvim_win_get_cursor(panel_winid)[1]]
end

local function _toggle(row)
  if not row or not row.id or not row.expandable then return false end
  if M._expanded[row.id] then
    M._expanded[row.id] = nil
    -- Collapsing invalidates: re-expanding must re-read, because the tree
    -- shows work in flight and it moves.
    M.invalidate(row.id)
  else
    M._expanded[row.id] = true
  end
  _rerender()
  return true
end

---_editor_win finds a normal window to open a file into — never the panel.
local function _editor_win()
  local af = require("auto-finder")
  if af._editor_target_winid then
    local w = af._editor_target_winid()
    if w then return w end
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.bo[b].buftype == "" and vim.bo[b].buflisted then return w end
  end
  return nil
end

---_open_path opens a real file in the editor area (requirement 10).
local function _open_path(path)
  if not path or path == "" then return end
  local esc = vim.fn.fnameescape(path)
  local w = _editor_win()
  if w then
    pcall(vim.api.nvim_set_current_win, w)
    pcall(vim.cmd, "edit " .. esc)
  else
    pcall(vim.cmd, "botright vsplit " .. esc)
  end
end

---_activate is `<CR>`.
local function _activate(row)
  if not row then return end
  if row.kind == "file" then
    -- A file under UNCOMMITTED exists on disk; one under a commit may not
    -- (it could be deleted, or from another worktree), so resolve against the
    -- worktree and fall back to telling the user rather than opening nothing.
    local abs = (row.worktree and row.worktree.path or "") .. "/" .. row.file.path
    if vim.fn.filereadable(abs) == 1 then return _open_path(abs) end
    logger.notify("repos: " .. row.file.path .. " is not present in this worktree",
      { level = vim.log.levels.WARN })
    return
  end
  if row.kind == "review_file" then return _open_path(row.path) end
  if row.kind == "draft" then
    -- A draft has no file to open, so `<CR>` reopens the DIFF where the work
    -- continues and the draft repaints. A working draft reopens the UNCOMMITTED
    -- diff; a commit draft reopens that commit's.
    if row.working then
      return M.open_diff({
        kind = "uncommitted", repo = row.repo,
        worktree = row.worktree and { path = row.worktree } or nil,
        node = { kind = "uncommitted" },
      })
    end
    return M.open_diff({
      kind = "commit", repo = row.repo, worktree = row.worktree,
      node = { kind = "commit", sha = row.sha, short = row.sha:sub(1, 7) },
    })
  end
  if row.kind == "more" then return M.load_more(row) end
  -- A review row now EXPANDS into its [markdown, json] pair rather than opening
  -- the JSON directly — the Markdown is openable and editable from the child
  -- row (Johno, 2026-09-03). `_toggle` handles it via id/expandable.
  _toggle(row)
end

---load_more requests another commit window (§2.4, `m`).
function M.load_more(row)
  if not row or not row.worktree then return end
  local wid = "wt:" .. row.worktree.path
  M._more[wid] = (M._more[wid] or 0) + 1
  M.invalidate(wid)
  _rerender()
end

---toggle_watch is `w` — the panel's one persistent user decision (§2.3).
function M.toggle_watch(row)
  local backend = _repos()
  if not (backend and row and row.worktree) then
    logger.notify("repos: put the cursor on a worktree to watch it",
      { level = vim.log.levels.WARN })
    return
  end
  -- BIND the error (r2 #5). Only the first value was captured, so a failed
  -- persist — ENOSPC, EPERM, lock contention, a malformed store — was a SILENT
  -- NO-OP REPAINT: `set()` returns the unchanged real state and skips its
  -- publish, so the row looked identical and the user assumed the keypress had
  -- not registered. Same treatment as the `o` diff call site below.
  local watched, werr = backend.toggle_watch(row.worktree.path)
  if werr then
    logger.notify("repos: could not persist the watch — " .. tostring(werr),
      { level = vim.log.levels.ERROR })
  end
  -- The worktree row's own cache holds the stale `watched` flag, and its
  -- children must be recomputed (or discarded) either way.
  M.invalidate("repo:" .. row.repo.common_dir)
  M.invalidate("wt:" .. row.worktree.path)
  if watched then M._expanded["wt:" .. row.worktree.path] = true end
  _rerender()
end

---open_diff is `o` on a commit: the three-column diff view (§2.5), with any
---recorded review comments rendered inline where they belong.
---
---Annotations come from the review JSONs already attached to the commit, so a
---review written by an agent shows up next to the code without any extra step
---— requirement 8's "see agent's or my review feedback right on the panel".
function M.open_diff(row, opts)
  local backend = _repos()
  if not (backend and row and row.repo) then return false, "missing backend or repo" end
  local node = row.node
  local uncommitted = node and node.kind == "uncommitted"
  local sha = node and node.sha
  if not sha and not uncommitted then
    logger.notify("repos: put the cursor on a commit or UNCOMMITTED to diff it",
      { level = vim.log.levels.WARN })
    return false, "no commit or uncommitted target"
  end
  -- Guarded because `diff()` reaches into auto-core's diff parser. availability
  -- is probed up front, but an unprotected call here surfaced as a raw keymap
  -- traceback rather than a message if that surface was ever incomplete
  -- (ADR-0060 r1 SF2). A missing capability is a notification, not a stacktrace.
  -- UNCOMMITTED has no sha; it diffs the WORKING TREE instead. Until now `o`
  -- on it warned "put the cursor on a commit" and returned, so the one node
  -- whose diff you most often want was the only one you could not open.
  local dok, files
  if uncommitted then
    dok, files = pcall(backend.diff_working, row.worktree)
  else
    dok, files = pcall(backend.diff, row.repo, sha)
  end
  if not dok then
    logger.notify("repos: cannot diff — " .. tostring(files),
      { level = vim.log.levels.ERROR })
    return false, "cannot diff"
  end
  files = files or {}
  if #files == 0 then
    logger.notify("repos: no diff for "
      .. tostring(uncommitted and "UNCOMMITTED" or (row.node and row.node.short) or sha),
      { level = vim.log.levels.WARN })
    return false, "no diff"
  end

  -- Merge every revision's comments, newest revision last so a later pass
  -- renders over an earlier one rather than being hidden by it.
  local annotations = {}
  local ok_rev, review = pcall(require, "worktree.review")
  -- Reviews are keyed by commit; UNCOMMITTED has none to merge.
  if ok_rev and sha then
    local revs = backend.reviews(row.repo, sha)
    for i = #revs, 1, -1 do
      -- pcall'd: only the `require` above was guarded, so ONE malformed review
      -- file turned `o` into a raw keymap traceback (r2 #4d). validate() no
      -- longer throws on a scalar comment element, but a review store is
      -- written by agents and hand-editable — a bad file must cost the reader
      -- that file, not the whole diff view.
      --
      -- THREE results are bound, not two (r3 #4). `review.load` reports
      -- malformed JSON and failed validation NORMALLY as `(nil, err)` — it does
      -- not throw — so through pcall that arrives as `(true, nil, err)`. Binding
      -- only `(ok, doc)` meant the warning branch never ran for the COMMON
      -- malformed-file case and the review was skipped in silence: the very
      -- defect this guard was added to fix, reintroduced one line lower. Now a
      -- thrown error and a returned error are distinguished and both reported.
      local ok_doc, doc, load_err = pcall(review.load, row.repo.slug, sha,
        revs[i].revision)
      if not ok_doc then
        logger.notify(("repos: review r%d threw while loading — %s")
          :format(revs[i].revision, tostring(doc)),
          { level = vim.log.levels.ERROR })
        doc = nil
      elseif load_err then
        logger.notify(("repos: skipping unreadable review r%d — %s")
          :format(revs[i].revision, tostring(load_err)),
          { level = vim.log.levels.WARN })
        doc = nil
      end
      if doc then
        for path, list in pairs(review.by_path(doc)) do
          annotations[path] = annotations[path] or {}
          for _, c in ipairs(list) do
            c.author = c.author or doc.reviewer
            table.insert(annotations[path], c)
          end
        end
      end
    end
  end

  local ok_dv, dv = pcall(require, "auto-core.ui.diffview")
  if not ok_dv then
    logger.notify("repos: auto-core.ui.diffview is unavailable",
      { level = vim.log.levels.ERROR })
    return
  end
  -- ADR-0065: authoring. The draft is OURS, not the float's — which is what
  -- makes an unvetoable close (`<Esc>`, a lost pane, dispose) cost windows
  -- rather than work.
  local authoring = require("auto-finder.views.repos.authoring")
  local annotate, keymaps
  -- A draft can be authored on BOTH a commit and UNCOMMITTED work (ADR-0081
  -- §2.5 uncommitted-scope amendment). The two differ only in the SCOPE the
  -- draft is keyed to and whether it can be SUBMITTED: a SAVED review still
  -- needs a commit to anchor to, so on uncommitted `s` explains rather than
  -- writes, and the draft is the vehicle for handing ongoing work to an agent.
  local wt_path = row.worktree and row.worktree.path or nil
  local draft, scope, submit_fn
  if uncommitted then
    scope = authoring.scope_working(row.repo.slug, wt_path)
    draft = scope and authoring.draft_working(row.repo.slug, wt_path) or nil
    submit_fn = function()
      logger.notify("repos: UNCOMMITTED can't be saved as a review yet — commit, then "
        .. "reopen and press s. Your draft IS saved and listed under this repo's "
        .. "reviews, so an agent can pick it up now.", { level = vim.log.levels.WARN })
    end
  else
    scope = authoring.scope(row.repo.slug, sha)
    -- The repo's worktree path, so the reviewer SNAPSHOT this binds resolves
    -- against the right repository's `git config user.name` (ADR-0081 §2.5).
    draft = authoring.draft(row.repo.slug, sha, { cwd = wt_path })
    submit_fn = function() M._submit_review(row, sha) end
  end
  if not draft then
    -- The scope itself could not be formed — a worktree with no path. This is
    -- the only case that still disables authoring; UNCOMMITTED no longer is.
    annotate = { disabled_reason =
      "no worktree path to anchor a draft to — open the diff from a watched worktree" }
  else
    annotate = {
      -- Findings go in through ONE entry point (ADR-0081 P5), so "is there
      -- unsaved work?" has exactly one answer. An anchored annotation carries a
      -- line, which is what makes it anchored -- not a flag a caller must
      -- remember to set.
      on_add = function(a) authoring.add_finding(draft, a) end,
      on_remove = function(a)
        for i = #draft.items, 1, -1 do
          local c = draft.items[i]
          if c.anchored and c.path == a.path and c.line == a.line
            and (c.side or "RIGHT") == (a.side or "RIGHT") then
            table.remove(draft.items, i)
            break
          end
        end
      end,
      -- The ANCHORED findings only: this is what the diff view repaints as
      -- marks, and an unanchored finding has no line to paint.
      pending = function() return authoring.anchored(draft) end,
      before_close = function(reason)
        -- The SAME predicate `submit` uses. A summary-only or unanchored-only
        -- draft is real work, and checking `#comments` here let it close
        -- without a prompt while `submit` separately refused to write it.
        if reason ~= "key" or not authoring.dirty(draft) then return "close" end
        -- The prompt is ASYNCHRONOUS and this hook is not, so cancel NOW and
        -- finish through the non-prompting "resume" reason. A hook that
        -- prompted on "key" would prompt again on the finishing call and never
        -- close (ADR-0065 §2.3).
        vim.schedule(function()
          local C = CLOSE_CHOICES
          -- Submit is offered ONLY when there is a commit to save to; on
          -- UNCOMMITTED the draft is kept for an agent, and the prompt says so.
          local choices = uncommitted and { C.keep, C.discard, C.stay }
            or { C.submit, C.keep, C.discard, C.stay }
          vim.ui.select(choices, {
            prompt = ("unsent %s — %s (kept either way):"):format(
              uncommitted and "draft (uncommitted)" or "review", _draft_holds(draft)),
          }, function(choice)
            if choice == C.submit then
              submit_fn()
            elseif choice == C.keep then
              logger.notify(("repos: closed — %s kept; reopen with o%s")
                :format(_draft_holds(draft),
                  uncommitted and " (listed under reviews for an agent)"
                    or " and s submits"), { level = vim.log.levels.INFO })
              pcall(function() dv.close("resume") end)
            elseif choice == C.discard then
              -- The one destructive answer, so it says what it destroyed.
              local held = _draft_holds(draft)
              authoring.discard_scope(scope)
              logger.notify("repos: discarded " .. held, { level = vim.log.levels.WARN })
              pcall(function() dv.close("resume") end)
            else
              -- `stay`, or the prompt itself dismissed. Doing nothing is
              -- correct — the view is still open because this hook vetoed the
              -- close — but SAYING nothing is what made the prompt read as a
              -- loop, so the way out is named.
              logger.notify(("repos: still open — %s kept; q offers `%s`")
                :format(_draft_holds(draft), C.keep), { level = vim.log.levels.INFO })
            end
          end)
        end)
        return "cancel"
      end,
    }
    keymaps = {
      { key = "s", desc = uncommitted and "submit (commit first)" or "submit review",
        fn = submit_fn },
      -- UNANCHORED findings need a way in (review-json §6): "this module has no
      -- tests", "the ADR contradicts §3" — findings with no `(path, line)`,
      -- which must not be dropped to fit the schema and must not be given an
      -- invented line number.
      --
      -- Their own KEY, because they used to be collected by a loop on the
      -- submit path: every submit asked "unanchored finding 1 (blank to
      -- finish)" whether or not the reviewer had one, so writing a
      -- single-comment review cost three modal prompts and each was another
      -- place to abort into silence. `c` annotates a line and `u` records a
      -- finding without one; `s` now only asks what it cannot infer.
      { key = "u", desc = "unanchored finding",
        fn = function()
          vim.ui.input({ prompt = "finding with no line: " }, function(body)
            if not (body and vim.trim(body) ~= "") then
              logger.notify("repos: nothing added", { level = vim.log.levels.INFO })
              return
            end
            vim.ui.select(authoring.SEVERITIES, { prompt = "severity:" }, function(sev)
              -- No severity, no finding. It used to fall back to "comment" and
              -- store it anyway, so cancelling the picker still changed the
              -- draft.
              if not sev then
                logger.notify("repos: nothing added — no severity chosen",
                  { level = vim.log.levels.INFO })
                return
              end
              authoring.add_finding(draft,
                { severity = sev, body = vim.trim(body), anchored = false })
              logger.notify(("repos: %s on this review — s submits")
                :format(_draft_holds(draft)), { level = vim.log.levels.INFO })
            end)
          end)
        end },
    }
  end

  -- `o` opens the current file for full examination (requirement 7). Bound for
  -- both a commit and UNCOMMITTED — the difference is only which draft state
  -- exists, not whether a file can be opened. The file the view SHOWS may be a
  -- historical revision; what the reader wants to read is the working-tree copy,
  -- so the path resolves against the worktree, not the commit. The current file
  -- arrives from auto-core (it fires at press time, and the shown file changes
  -- under j/k, so an open-time capture would be stale). Closing with "resume"
  -- is deliberate: it skips the unsent-review prompt because pressing `o` is an
  -- explicit navigation, and the draft is owned by `authoring` — it survives the
  -- close and repaints on reopen.
  keymaps = keymaps or {}
  table.insert(keymaps, {
    key = "o", desc = "open this file",
    fn = function(f)
      local rel = f and (f.new_path or f.path or f.old_path)
      if not rel or rel == "" then
        logger.notify("repos: no file to open", { level = vim.log.levels.WARN })
        return
      end
      local base = (row.worktree and row.worktree.path)
        or (row.repo and (row.repo.path or row.repo.common_dir)) or ""
      local abs = base ~= "" and (base .. "/" .. rel) or rel
      if vim.fn.filereadable(abs) ~= 1 then
        logger.notify("repos: " .. rel .. " is not present in this worktree",
          { level = vim.log.levels.WARN })
        return
      end
      pcall(function() dv.close("resume") end)
      _open_path(abs)
    end,
  })

  -- Whole-file context (`X`) is not something the view can synthesise from the
  -- patch: `auto-core.git.diff._sides_full` shells out to `git -C <dir> show
  -- <rev>:<path>` for each side, so it needs a directory AND a revision. Given
  -- neither it cannot read either side, falls through its
  -- `if not blines and not alines` guard, and returns the HUNK render — while
  -- the footer still reads `[context: full]`. The toggle then looked broken
  -- because the only thing it changed was a label.
  --
  -- UNCOMMITTED has no sha: `uncommitted` routes _sides_full to `HEAD` for the
  -- old side and the file on disk for the new one, which is the correct pair
  -- for a working tree.
  local diff_dir = (row.worktree and row.worktree.path)
    or (row.repo and (row.repo.sample_worktree or row.repo.path or row.repo.common_dir))

  local handle, err = dv.open({
    files = files,
    annotations = annotations,
    annotate = annotate,
    keymaps = keymaps,
    worktree = diff_dir,
    sha = sha,
    uncommitted = uncommitted or nil,
    -- Reopen where a prior session left off (requirement 6). nil on a first
    -- open; set only when `resume_diff` re-enters here.
    initial = (opts and opts.initial) or (row.file and { path = row.file.path }) or nil,
    -- Remember this diff and the reader's last position so the <C-g> modal can
    -- recall it. The position is auto-core's (it owns the panes); the row is
    -- ours (it names the repo, worktree and commit to reopen). Captured on
    -- EVERY close, so "resume" always means the diff you last looked at.
    on_close = function(pos)
      pos = pos or {}
      local cur_file = pos.path
      local cur_idx = pos.idx
      local cur_pane = pos.pane
      local file_positions = pos.file_positions or {}
      if cur_file and not file_positions[cur_file] then
        file_positions[cur_file] = {
          lnum = pos.lnum or 1,
          col = pos.col or 0,
          pane = cur_pane or "preview",
        }
      end

      M._resume = {
        repo_slug = row.repo and row.repo.slug,
        common_dir = row.repo and row.repo.common_dir,
        worktree_path = (row.worktree and row.worktree.path) or (row.repo and (row.repo.sample_worktree or row.repo.path)),
        target_kind = (row.node and row.node.kind) or row.kind,
        sha = row.node and row.node.sha,
        pr_number = row.node and row.node.pr_number,
        active_file = cur_file,
        active_idx = cur_idx,
        focused_pane = cur_pane,
        file_positions = file_positions,
        timestamp = os.time(),
        row = row,
        pos = pos,
      }
      M._persist_resume()
    end,
    title = " " .. tostring(row.node.short) .. "  "
      .. tostring((row.node.commit or {}).subject or "") .. " ",
  })
  if not handle then
    -- Refusing on a narrow window is deliberate (auto-core sets MIN_COLUMNS):
    -- half a diff read as a whole one is worse than none.
    logger.notify("repos: " .. tostring(err), { level = vim.log.levels.WARN })
    return false, err
  end

  -- Feedback anchored to a line the diff does not show would otherwise vanish
  -- silently; name it instead.
  local lost = dv.unplaced_for(files, annotations)
  if #lost > 0 then
    local names = {}
    for _, l in ipairs(lost) do
      names[#names + 1] = l.path .. ":" .. tostring(l.line)
    end
    logger.notify("repos: " .. #lost .. " review comment(s) are not on a line in "
      .. "this diff — " .. table.concat(names, ", "),
      { level = vim.log.levels.WARN })
  end
  return true, handle
end

---_submit_review collects the verdict and summary, then writes the pair.
---
---Asks for the parts auto-core deliberately does not know about — a verdict is
---a review concept and a diff has no reviewer — and hands the rest to
---`authoring.submit`.
function M._submit_review(row, sha)
  local authoring = require("auto-finder.views.repos.authoring")
  local okr, review = pcall(require, "worktree.review")
  if not okr then
    logger.notify("repos: worktree.review is unavailable", { level = vim.log.levels.ERROR })
    return
  end
  -- PEEK, not get: this is a question ("is there anything to submit?"), and
  -- asking it must not create the thing it asks about. A `get` here left an
  -- empty shell in the store for every commit a reader merely pressed `s` on,
  -- and those shells are what a draft LISTER would have to filter back out.
  -- PEEK ONLY. `peek(...) or draft(...)` was the first attempt and it defeated
  -- itself: the fallback created the very shell peeking was meant to avoid, so
  -- every commit a reader merely pressed `s` on left an entry behind — and
  -- those entries are what the draft listing in the reviews section then has
  -- to filter back out. A question must not create what it asks about.
  local draft = authoring.peek(row.repo.slug, sha)
  -- Refuse EARLY and say what would make it submittable. `authoring.submit`
  -- refuses an empty draft too, but only after the reader has answered a
  -- verdict and a summary — two prompts spent to be told there was nothing to
  -- write.
  if not (draft and authoring.dirty(draft)) then
    logger.notify("repos: nothing to submit yet — c annotates a line, u records a finding without one",
      { level = vim.log.levels.WARN })
    return
  end
  local verdicts = { "comment", "approved", "change_requested" }
  vim.ui.select(verdicts, { prompt = "verdict:" }, function(verdict)
    -- Abort LOUDLY, naming what survived. A silent `return` here is what made
    -- the close prompt read as a loop: cancel the verdict, get no message,
    -- press q, meet the same prompt, conclude the panel is stuck.
    if not verdict then
      logger.notify(("repos: submit cancelled — %s kept"):format(_draft_holds(draft)),
        { level = vim.log.levels.INFO })
      return
    end
    draft.verdict = verdict
    vim.ui.input({ prompt = "summary (optional): " }, function(summary)
      -- An empty or dismissed summary is NOT an abort — a review may be all
      -- comments — but it must not be stored as "" either, which is neither a
      -- summary nor absent. The verdict is the only thing `s` insists on.
      -- Through `set_summary`, which also DECLARES the summary as content:
      -- auto-core's store is domain-agnostic and cannot know that a field
      -- called `summary` is work rather than context (ADR-0081 §2.5).
      authoring.set_summary(row.repo.slug, sha, summary)
      M._finish_submit(row, sha)
    end)
  end)
end

---_finish_submit performs the write once the composer has everything.
function M._finish_submit(row, sha)
  local authoring = require("auto-finder.views.repos.authoring")
  do
      local res, reason = authoring.submit({
        repo = row.repo, sha = sha,
        cwd = row.worktree and row.worktree.path or nil,
      })
      if not res then
        logger.notify("repos: " .. tostring(reason), { level = vim.log.levels.ERROR })
        return
      end
      logger.notify(("repos: wrote review r%d — %s + %s")
        :format(res.revision, vim.fn.fnamemodify(res.md_path, ":t"),
                vim.fn.fnamemodify(res.json_path, ":t")))
      -- The TREE is now stale: a new review means the commit's changed files
      -- gain a [feedback] badge, the commit gains a review row, and the repo's
      -- reviews section gains an entry — but the write happens outside the
      -- topic the view subscribes to, so nothing invalidated the cached nodes.
      -- Before this, a badge appeared only after a manual R or a panel reopen
      -- (Johno, 2026-09-03: the badge "must be visible from that tree").
      -- A submit is infrequent; a whole-tree invalidation is the honest cost.
      M.invalidate(nil)
      _rerender()
      -- Reopen so the freshly-written review renders from DISK: the round trip
      -- is the confirmation, not the notification.
      local dv_ok, dv2 = pcall(require, "auto-core.ui.diffview")
      if dv_ok then pcall(dv2.close, "resume") end
      vim.schedule(function() M.open_diff(row) end)
  end
end

---The panel's FORMAL name, and the only place it is spelled.
---
---Johno, 2026-09-08: this panel and auto-agents' diff queue were both called
---some variant of "diff view", which made a request like "close the diff view"
---ambiguous and a keymap description misleading. They review different things
---and now say so: THIS one shows commits against a base branch, so it is the
---**Git Diff View**; auto-agents' queue of proposed agent edits is the **Agent
---Edits Queue**.
---
---Exported rather than inlined at the float so a consumer naming the panel —
---AutoVim's navigation modal does — reads the name from here instead of
---keeping a second copy that can drift.
M.PANEL_TITLE = "Git Diff View"

---Deliberate shift off centre.
---
---Both panels are near-full-screen and both centred, so opening one over the
---other read as a redraw rather than as a different panel. This one sits DOWN
---and RIGHT; the Agent Edits Queue sits up and left by the same amount, giving
---a visible offset in both axes without either leaving the middle of the
---screen. auto-core clamps these to the available margin, so a small terminal
---degrades to centred instead of pushing a pane off screen, and an auto-core
---predating the option ignores them.
M.PANEL_ROW_OFFSET = 2
M.PANEL_COL_OFFSET = 6

---Open a diffview over a RANGE of commits, with review authoring attached.
---
---One implementation, two callers: `open_pr_diff` (a PR's commits) and
---`open_worktree_diff` (a branch's commits against its base). The two differ
---only in how they NAME the range and where they resolve it from — everything
---after that (expanding commits to files, gathering existing review
---annotations, the authoring draft, the `s` submit key, the resume snapshot)
---is identical. Written twice it would have drifted: the PR path already
---carried three fixes the second one would not have had.
---
---@param spec table
---  repo         table    the repo row's repo
---  commits      table[]  ordered oldest-first; each { sha, short?, subject? }
---  title        string   the float's title, already formatted
---  target_kind  string   "pr" | "worktree" — recorded in the resume snapshot
---  wt           table?   the worktree row, when there is one
---  wt_path      string?  a directory that can answer `git show <rev>:<path>`
---  pr           table?   PR metadata; PR-only annotation lookup + submit tag
---  reviews_for  fun():table[]  existing review metadata for this range
---  empty_msg    string   notified when the range has no changed files
---@param opts table?  { context?, initial? }
---@return boolean ok, any float_or_err
local function _open_range_diff(spec, opts)
  opts = opts or {}
  local backend = _repos()
  local repo = spec.repo

  local all_files = {}
  for _, c in ipairs(spec.commits) do
    local files = {}
    if type(backend.diff) == "function" then
      local dok, dfiles = pcall(backend.diff, repo, c.sha)
      if dok and type(dfiles) == "table" then files = dfiles end
    end
    for _, f in ipairs(files) do
      f.commit_sha = c.sha
      f.commit_short = c.short or c.sha:sub(1, 7)
      f.commit_subject = c.subject or ""
      table.insert(all_files, f)
    end
  end

  if #all_files == 0 then
    logger.notify(spec.empty_msg, { level = vim.log.levels.WARN })
    return false, "no diff"
  end

  local annotations = {}
  local ok_rev, review = pcall(require, "worktree.review")
  if ok_rev then
    for _, r_meta in ipairs(spec.reviews_for() or {}) do
      local ok_doc, doc = pcall(review.load, repo.slug, r_meta.commit or r_meta.sha, r_meta.revision)
      if ok_doc and doc then
        for path, list in pairs(review.by_path(doc)) do
          annotations[path] = annotations[path] or {}
          for _, comment in ipairs(list) do
            comment.author = comment.author or doc.reviewer
            table.insert(annotations[path], comment)
          end
        end
      end
    end
  end

  local ok_dv, dv = pcall(require, "auto-core.ui.diffview")
  if not ok_dv then
    logger.notify("repos: auto-core.ui.diffview is unavailable", { level = vim.log.levels.ERROR })
    return false, "diffview unavailable"
  end

  local authoring = require("auto-finder.views.repos.authoring")
  local default_sha = spec.commits[1] and spec.commits[1].sha or "HEAD"
  local draft = authoring.draft(repo.slug, default_sha, { cwd = spec.wt_path })
  if spec.pr then draft.pr = spec.pr.number end

  local annotate = {
    on_add = function(a)
      local cur_file = dv.current_file()
      if cur_file and cur_file.commit_sha then
        a.commit = cur_file.commit_sha
      end
      authoring.add_finding(draft, a)
    end,
    on_remove = function(a)
      for i = #draft.items, 1, -1 do
        local c = draft.items[i]
        if c.anchored and c.path == a.path and c.line == a.line
          and (c.side or "RIGHT") == (a.side or "RIGHT") then
          table.remove(draft.items, i)
        end
      end
    end,
    pending = function() return authoring.anchored(draft) end,
    before_close = function(reason)
      if #draft.items > 0 and reason == "key" then
        return false
      end
      return true
    end,
  }

  local keymaps = {
    {
      key = "s",
      desc = "submit",
      fn = function()
        if #draft.items == 0 then
          logger.notify("repos: no findings to submit", { level = vim.log.levels.WARN })
          return
        end
        -- Findings are grouped by the commit they were anchored on, NOT by the
        -- range: a review belongs to a commit, and the range is only how the
        -- reader arrived at it.
        local by_commit = {}
        for _, item in ipairs(draft.items) do
          local sha = item.commit or default_sha
          by_commit[sha] = by_commit[sha] or {}
          table.insert(by_commit[sha], item)
        end
        for sha, items in pairs(by_commit) do
          local rev_payload = {
            schema = review.SCHEMA,
            commit = sha,
            revision = 1,
            repo = { url = repo.url, owner = repo.slug, name = repo.label },
            reviewer = vim.g.auto_agents_name or "reviewer",
            reviewer_slug = vim.g.auto_agents_name or "reviewer",
            pr = spec.pr and spec.pr.number or nil,
            comments = {},
          }
          for _, it in ipairs(items) do
            table.insert(rev_payload.comments, {
              path = it.path,
              line = it.line,
              severity = it.severity or "comment",
              body = it.body,
              side = it.side or "RIGHT",
            })
          end
          local md_body = spec.pr
            and string.format("# Review for commit %s (PR #%s)\n\nSubmitted from repos panel.\n",
              sha:sub(1, 7), tostring(spec.pr.number))
            or string.format("# Review for commit %s (%s)\n\nSubmitted from repos panel.\n",
              sha:sub(1, 7), spec.range_label or "range")
          local ok_save, serr = review.save_pair(repo.slug, rev_payload, md_body)
          if not ok_save then
            logger.notify(string.format("repos: failed to save review for %s — %s", sha:sub(1, 7), tostring(serr)), { level = vim.log.levels.ERROR })
          end
        end
        draft.items = {}
        M.invalidate(nil)
        _rerender()
        dv.close("submit")
        logger.notify(spec.submitted_msg, { level = vim.log.levels.INFO })
      end,
    },
  }

  local float, err = dv.open({
    title = spec.title,
    files = all_files,
    annotations = annotations,
    annotate = annotate,
    keymaps = keymaps,
    worktree = spec.wt_path,
    row_offset = M.PANEL_ROW_OFFSET,
    col_offset = M.PANEL_COL_OFFSET,
    -- Every entry in `all_files` carries its own `commit_sha`, which `_show`
    -- prefers. This is the floor under that: a file that somehow arrives
    -- without one still resolves a revision instead of silently dropping to
    -- the hunk render.
    sha = default_sha,
    context = opts.context or "hunk",
    initial = opts.initial,
    on_close = function(pos)
      pos = pos or {}
      local cur_file = pos.path
      local cur_idx = pos.idx
      local cur_pane = pos.pane
      local file_positions = pos.file_positions or {}
      if cur_file and not file_positions[cur_file] then
        file_positions[cur_file] = {
          lnum = pos.lnum or 1,
          col = pos.col or 0,
          pane = cur_pane or "preview",
        }
      end

      M._resume = {
        repo_slug = repo and repo.slug,
        common_dir = repo and repo.common_dir,
        worktree_path = spec.wt_path,
        target_kind = spec.target_kind,
        pr_number = spec.pr and spec.pr.number or nil,
        sha = default_sha,
        active_file = cur_file,
        active_idx = cur_idx,
        focused_pane = cur_pane,
        file_positions = file_positions,
        context = pos and pos.context,
        timestamp = os.time(),
        row = spec.row,
        pos = pos,
      }
      M._persist_resume()
    end,
  })
  if not float then
    logger.notify("repos: cannot open diff — " .. tostring(err), { level = vim.log.levels.ERROR })
    return false, err
  end
  return true, float
end

---open_pr_diff opens multi-commit PR diffview (ADR-0083 §2.6 Action 2).
---@param row table
---@param opts table?
function M.open_pr_diff(row, opts)
  opts = opts or {}
  local backend = _repos()
  if not (backend and row and row.repo) then return false, "missing backend or repo" end

  local pr = row.pr
  local wt = row.worktree
  if not pr and wt and type(backend.pr_for_worktree) == "function" then
    pr = backend.pr_for_worktree(row.repo, wt)
  end
  if not pr then
    logger.notify("repos: put the cursor on a PR or a worktree with a PR to open PR diff",
      { level = vim.log.levels.WARN })
    return false, "no PR found"
  end

  local base_branch = pr.base or pr.base_ref or _base_branch(row.repo) or "main"
  local pr_branch = pr.branch or (wt and wt.branch) or ("pr-" .. tostring(pr.number))
  local commits = _range_commits(row.repo, base_branch, pr_branch)

  -- A PR row does not always have a worktree — `pr_for_worktree` matches on
  -- branch name, and the PR tree renders rows for PRs whose branch was never
  -- checked out here. `wt.path or nil` then handed the view no directory and
  -- whole-file context died the same silent death `open_diff` suffered: the
  -- repo's own checkout answers `git show <rev>:<path>` just as well.
  local wt_path = (wt and wt.path)
    or (row.repo and (row.repo.sample_worktree or row.repo.path))
    or nil

  return _open_range_diff({
    repo        = row.repo,
    row         = row,
    wt          = wt,
    wt_path     = wt_path,
    commits     = commits,
    target_kind = "pr",
    pr          = pr,
    range_label = string.format("PR #%s", tostring(pr.number)),
    title       = string.format(" %s — PR #%s: %s ", M.PANEL_TITLE, tostring(pr.number), pr.title or ""),
    empty_msg   = string.format("repos: no changed files found for PR #%s", tostring(pr.number)),
    submitted_msg = string.format("repos: submitted review for PR #%s", tostring(pr.number)),
    reviews_for = function()
      if type(backend.reviews_for_pr) == "function" then
        return backend.reviews_for_pr(row.repo, pr.number)
      end
      local out = {}
      for _, c in ipairs(commits) do
        for _, r in ipairs(backend.reviews(row.repo, c.sha) or {}) do
          table.insert(out, r)
        end
      end
      return out
    end,
  }, opts)
end

---open_worktree_diff opens the Git Diff View over everything a worktree's
---branch adds on top of its base branch, grouped by commit.
---
---Johno, 2026-09-08: "let's allow opening diff_view on worktree as well in
---addition to PR diff_view. This will work the same way as PR diff_view,
---grouping file changes with commits."
---
---The PR diff answers "what does this PR change", which is the same question
---as "what does this branch change" — a PR is just a branch with a number
---attached. So a branch that has no PR yet, or will never have one, was
---unreviewable for no reason other than the missing number. This is the same
---machinery pointed at `<base>..<branch>` directly.
---
---THE BASE BRANCH DECLINES, and says why. `main..main` is empty, so the base
---worktree would otherwise open an empty diff and report "no changed files",
---which reads like a failure rather than the tautology it is.
---@param row table
---@param opts table?
function M.open_worktree_diff(row, opts)
  opts = opts or {}
  local backend = _repos()
  if not (backend and row and row.repo) then return false, "missing backend or repo" end

  local wt = row.worktree
  if not wt then
    logger.notify("repos: put the cursor on a worktree to open its diff",
      { level = vim.log.levels.WARN })
    return false, "no worktree"
  end

  local base = _base_branch(row.repo)
  if not base then
    logger.notify("repos: cannot resolve this repository's base branch — nothing to diff against",
      { level = vim.log.levels.WARN })
    return false, "no base branch"
  end

  -- The name for the LEFT of the arrow. A detached worktree has no branch, so
  -- it is named by its directory — which is what the tree row shows too.
  local head = wt.branch or wt.head
  local label = wt.branch or vim.fn.fnamemodify(wt.path, ":t")

  -- `is_base` is the backend's own answer, and it is the one the tree renders
  -- "(base)" from; falling back to a name comparison covers a worktree object
  -- built without it (the resume path constructs one from a path alone).
  if wt.is_base or (wt.branch ~= nil and wt.branch == base) then
    logger.notify(string.format(
      "repos: %s IS the base branch — there is nothing to diff it against", base),
      { level = vim.log.levels.INFO })
    return false, "worktree is the base branch"
  end

  if not head then
    logger.notify("repos: this worktree has no branch or HEAD to diff",
      { level = vim.log.levels.WARN })
    return false, "no head"
  end

  local commits = _range_commits(row.repo, base, head)

  return _open_range_diff({
    repo        = row.repo,
    row         = row,
    wt          = wt,
    wt_path     = wt.path or (row.repo.sample_worktree or row.repo.path),
    commits     = commits,
    target_kind = "worktree",
    pr          = nil,
    range_label = string.format("%s -> %s", label, base),
    -- Johno: "the title should indicate that as well such as {worktree name}
    -- -> {target branch}".
    title       = string.format(" %s — %s → %s ", M.PANEL_TITLE, label, base),
    empty_msg   = string.format(
      "repos: %s adds no commits on top of %s — nothing to diff", label, base),
    submitted_msg = string.format("repos: submitted review for %s → %s", label, base),
    reviews_for = function()
      local out = {}
      for _, c in ipairs(commits) do
        for _, r in ipairs(backend.reviews(row.repo, c.sha) or {}) do
          table.insert(out, r)
        end
      end
      return out
    end,
  }, opts)
end

---_load_review_for_post reads a described review's FULL JSON and shapes it for
---`worktree.pr.post_feedback`, which iterates the comments ARRAY — a `describe`
---record only carries the comment COUNT, so passing one straight through posts
---nothing (and `ipairs` on a number errors). Returns nil + a reason when there
---is nothing postable.
---@param meta table  a describe record (has .path, .name)
---@return table? rev, string? why
local function _load_review_for_post(meta)
  if not (meta and meta.path) then return nil, "no review path" end
  local ok_store, store = pcall(require, "worktree.store")
  if not ok_store then return nil, "worktree.store unavailable" end
  local data, rerr = store.read_json(meta.path)
  if not data then return nil, rerr or "unreadable review json" end
  local comments = type(data.comments) == "table" and data.comments or {}
  if #comments == 0 then return nil, "review has no line findings to post" end
  return {
    commit = data.commit,
    sha = data.commit,
    doc_name = meta.name or vim.fn.fnamemodify(meta.path, ":t"),
    comments = comments,
  }, nil
end

---submit_review posts the findings of ONE selected review entry to its PR
---(ADR-0083 Amendment r9, `S`). The move off `P` is deliberate: `P` posted
---whatever review group the cursor's PR row implied, which risked sending an
---unintended batch. `S` submits exactly the review the cursor sits on.
---@param row table
function M.submit_review(row)
  local backend = _repos()
  -- Accept the review row or either of its pair leaves (like `d`): the two
  -- files are one review.
  if not (row and (row.kind == "review" or row.kind == "review_file")
      and row.review and row.review.path) then
    logger.notify("repos: put the cursor on a review entry to submit it (S)",
      { level = vim.log.levels.WARN })
    return
  end
  if not (backend and row.repo) then return end
  local meta = row.review
  local pr_number = meta.pr
  if not pr_number then
    logger.notify(string.format(
      "repos: review %s is not associated with a PR — nothing to submit to",
      tostring(meta.name or meta.path)), { level = vim.log.levels.WARN })
    return
  end
  local rev, why = _load_review_for_post(meta)
  if not rev then
    logger.notify(string.format("repos: cannot submit %s — %s",
      tostring(meta.name or meta.path), tostring(why)), { level = vim.log.levels.WARN })
    return
  end
  local ok_pr, pr_mod = pcall(require, "worktree.pr")
  if not ok_pr then
    logger.notify("repos: worktree.pr is unavailable", { level = vim.log.levels.ERROR })
    return
  end
  local ok_call, res = pcall(pr_mod.post_feedback, row.repo, pr_number, { rev })
  if not ok_call then
    logger.notify(string.format("repos: submitting review to PR #%s errored — %s",
      tostring(pr_number), tostring(res)), { level = vim.log.levels.ERROR })
    return
  end
  if res and res.ok then
    M.invalidate(nil); _rerender()
    logger.notify(string.format("repos: submitted %s to PR #%s",
      tostring(meta.name or "review"), tostring(pr_number)), { level = vim.log.levels.INFO })
  else
    logger.notify(string.format("repos: failed to submit review to PR #%s — %s",
      tostring(pr_number), tostring(res and res.error or "unknown")),
      { level = vim.log.levels.ERROR })
  end
end

---post_pr_feedback posts EVERY review associated with a PR (the legacy
---`:AutoFinderPostPRFeedback` command). The per-entry `S` (submit_review) is the
---keymapped path now; this stays as a bulk command.
---@param row table
---@param opts table?
function M.post_pr_feedback(row, opts)
  opts = opts or {}
  local backend = _repos()
  if not (backend and row and row.repo) then return end

  local pr = row.pr
  local wt = row.worktree
  if not pr and wt and type(backend.pr_for_worktree) == "function" then
    pr = backend.pr_for_worktree(row.repo, wt)
  end
  if not pr and row.review and row.review.pr then
    pr = { number = row.review.pr }
  end
  if not pr then
    logger.notify("repos: put cursor on a PR or a worktree with a PR to post feedback",
      { level = vim.log.levels.WARN })
    return
  end

  local ok_pr, pr_mod = pcall(require, "worktree.pr")
  if not ok_pr then
    logger.notify("repos: worktree.pr is unavailable", { level = vim.log.levels.ERROR })
    return
  end

  local metas = {}
  if type(backend.reviews_for_pr) == "function" then
    metas = backend.reviews_for_pr(row.repo, pr.number)
  else
    for _, r in ipairs(backend.reviews_all(row.repo)) do
      if r.pr and tostring(r.pr) == tostring(pr.number) then
        table.insert(metas, r)
      end
    end
  end
  -- Shape each described review into a postable payload (comments ARRAY, not
  -- the describe count). A review with no line findings is skipped, not fatal.
  local reviews = {}
  for _, m in ipairs(metas) do
    local rev = _load_review_for_post(m)
    if rev then table.insert(reviews, rev) end
  end

  if #reviews == 0 then
    logger.notify(string.format("repos: no postable review findings associated with PR #%s", tostring(pr.number)),
      { level = vim.log.levels.WARN })
    return
  end

  local res = pr_mod.post_feedback(row.repo, pr.number, reviews, opts)
  if res and res.ok then
    logger.notify(string.format("repos: feedback posted to PR #%s (receipt saved)", tostring(pr.number)),
      { level = vim.log.levels.INFO })
  else
    logger.notify(string.format("repos: failed to post feedback to PR #%s — %s", tostring(pr.number), tostring(res and res.error or "unknown")),
      { level = vim.log.levels.ERROR })
  end
end

---create_pr_for_worktree prompts and creates a new PR for worktree branch (ADR-0083 §2.6 Action 6).
---@param row table
function M.create_pr_for_worktree(row)
  local backend = _repos()
  if not (backend and row and row.repo and row.worktree) then
    logger.notify("repos: put cursor on a worktree to create a PR",
      { level = vim.log.levels.WARN })
    return
  end

  local repo = row.repo
  local wt = row.worktree
  local branch = wt.branch or "HEAD"
  -- `_base_branch`, not `backend.resolve_base` — worktree.nvim has never
  -- exported the latter, so this line opened every PR against the literal
  -- "main" regardless of what the repo's default branch actually is.
  local base = _base_branch(repo) or "main"

  vim.ui.input({ prompt = string.format("PR Title for %s: ", branch) }, function(title)
    if not title or title == "" then return end
    vim.ui.input({ prompt = "PR Description: " }, function(body)
      local ok_pr, pr_mod = pcall(require, "worktree.pr")
      if not ok_pr then
        logger.notify("repos: worktree.pr is unavailable", { level = vim.log.levels.ERROR })
        return
      end
      local res = pr_mod.create_pr(repo, {
        title = title,
        body = body or "",
        head = branch,
        base = base,
      })
      if res and res.ok then
        M.invalidate(nil)
        _rerender()
        logger.notify(string.format("repos: created PR #%s: %s", tostring(res.pr and res.pr.number or ""), title),
          { level = vim.log.levels.INFO })
        -- The PR exists either way; the KB doc is what ASSOCIATES it with this
        -- branch. Losing it silently is the whole failure mode being fixed —
        -- the badge, `S`, and every review's `pr` tag would just be absent with
        -- nothing said. Guarded field read, so an older worktree.nvim (which
        -- reports no association at all) simply never warns.
        if res.kb_doc_error then
          logger.notify(string.format(
            "repos: PR #%s is open but NOT associated with %s (%s) — run G on #%s to write it",
            tostring(res.pr and res.pr.number or "?"), branch,
            tostring(res.kb_doc_error), tostring(res.pr and res.pr.number or "?")),
            { level = vim.log.levels.WARN })
        end
      else
        logger.notify(string.format("repos: could not create PR — %s", tostring(res and res.error or "unknown")),
          { level = vim.log.levels.ERROR })
      end
    end)
  end)
end

---_fetch_pr validates a PR identifier and fetches it, surfacing EVERY outcome —
---bad input, a returned failure, or a raised error. Shared by the interactive
---`G` and the `:AutoFinderGetPR {n}` command so BOTH validate and guard
---identically (lector PR #45 MF2: the command path passed input straight to the
---forge URL and let a raised fetch error escape).
---@param repo table
---@param raw string|number|nil  the supplied PR identifier
---@return boolean ok
function M._fetch_pr(repo, raw)
  local input = vim.trim(tostring(raw or ""))
  if input == "" then
    logger.notify("repos: GetPR cancelled (no PR number entered)", { level = vim.log.levels.INFO })
    return false
  end
  -- C12: it must be a positive integer before a forge URL is built from it.
  local num = tonumber(input)
  if not num or num ~= math.floor(num) or num <= 0 then
    logger.notify(string.format("repos: '%s' is not a PR number", input), { level = vim.log.levels.WARN })
    return false
  end
  local ok_pr, pr_mod = pcall(require, "worktree.pr")
  if not ok_pr then
    logger.notify("repos: worktree.pr is unavailable", { level = vim.log.levels.ERROR })
    return false
  end
  -- C11: fetch_and_create_worktree can RAISE (a non-allowlisted provider, a curl
  -- failure); a bare call escaped with no toast. pcall and surface it.
  local ok_call, res = pcall(pr_mod.fetch_and_create_worktree, repo, num)
  if not ok_call then
    logger.notify(string.format("repos: GetPR #%s errored — %s", tostring(num), tostring(res)),
      { level = vim.log.levels.ERROR })
    return false
  end
  if res and res.ok then
    M.invalidate(nil); _rerender()
    logger.notify(string.format("repos: fetched PR #%s into branch %s", tostring(num), tostring(res.branch)),
      { level = vim.log.levels.INFO })
    return true
  end
  logger.notify(string.format("repos: could not fetch PR #%s — %s", tostring(num), tostring(res and res.error or "unknown")),
    { level = vim.log.levels.ERROR })
  return false
end

---get_pr_for_repo fetches PR branch and creates worktree (ADR-0083 §2.6 Action 1).
---@param row table
function M.get_pr_for_repo(row)
  local backend = _repos()
  if not (backend and row and row.repo) then
    logger.notify("repos: put cursor on a repository or worktree to fetch PR",
      { level = vim.log.levels.WARN })
    return
  end
  local repo = row.repo
  vim.ui.input({ prompt = string.format("Fetch PR # for %s: ", repo.label) }, function(input)
    -- C10: a cancel (nil) is announced distinctly from an empty entry; the rest
    -- of validation/guarding is shared with the command path.
    if input == nil then
      logger.notify("repos: GetPR cancelled", { level = vim.log.levels.INFO })
      return
    end
    M._fetch_pr(repo, input)
  end)
end

function M.get_pr_command(opts)
  local backend = _repos()
  local root = _cache("root")
  local repos = (root and root.items) or (backend and backend.repos()) or {}
  local repo = repos[1]
  if not repo then
    logger.notify("repos: no repository found in workspace", { level = vim.log.levels.ERROR })
    return
  end
  local arg = opts and opts.fargs and opts.fargs[1]
  if arg then
    -- Route the command through the SAME validation + guard as `G` (MF2).
    M._fetch_pr(repo, arg)
  else
    M.get_pr_for_repo({ repo = repo })
  end
end

function M.create_pr_command(opts)
  local backend = _repos()
  local root = _cache("root")
  local repos = (root and root.items) or (backend and backend.repos()) or {}
  local repo = repos[1]
  if not repo then
    logger.notify("repos: no repository found in workspace", { level = vim.log.levels.ERROR })
    return
  end
  local wts = (backend and backend.worktrees(repo)) or {}
  local wt = wts[1]
  M.create_pr_for_worktree({ repo = repo, worktree = wt })
end

function M.post_pr_feedback_command(opts)
  local backend = _repos()
  local root = _cache("root")
  local repos = (root and root.items) or (backend and backend.repos()) or {}
  local repo = repos[1]
  if not repo then
    logger.notify("repos: no repository found in workspace", { level = vim.log.levels.ERROR })
    return
  end
  local arg = opts and opts.fargs and opts.fargs[1]
  if arg then
    M.post_pr_feedback({ repo = repo, pr = { number = tonumber(arg) or arg } })
  else
    vim.ui.input({ prompt = "Post feedback for PR #: " }, function(input)
      if input and input ~= "" then
        M.post_pr_feedback({ repo = repo, pr = { number = tonumber(input) or input } })
      end
    end)
  end
end

---_info is `i`.
local function _info(row)
  if not row then return end
  local lines
  if row.kind == "repo" then
    lines = {
      "Repository: " .. tostring(row.repo.label),
      "  common dir: " .. tostring(row.repo.common_dir),
      "  bare:       " .. tostring(row.repo.is_bare),
      "  slug:       " .. tostring(row.repo.slug),
      "  remote:     " .. tostring(row.repo.url or "(none)"),
      "",
      "Reviews for this repo are stored under its slug.",
    }
  elseif row.kind == "worktree" then
    lines = {
      "Worktree: " .. tostring(row.worktree.branch or row.worktree.path),
      "  path:     " .. tostring(row.worktree.path),
      "  head:     " .. tostring(row.worktree.head),
      "  detached: " .. tostring(row.worktree.detached),
      "  watched:  " .. tostring(row.worktree.watched),
      "  is base:  " .. tostring(row.worktree.is_base),
    }
    -- The PR is now the worktree's [#N] badge (Amendment r9), so its details —
    -- and the KB doc path the old PR-row `<CR>` used to open — live here in the
    -- worktree's info instead.
    local backend = _repos()
    local wpr = backend and type(backend.pr_for_worktree) == "function"
      and backend.pr_for_worktree(row.repo, row.worktree) or nil
    if wpr then
      vim.list_extend(lines, {
        "",
        "PR #" .. tostring(wpr.number) .. ": " .. tostring(wpr.title or ""),
        "  state:  " .. tostring(wpr.state or (wpr.draft and "draft" or "open")),
        "  base:   " .. tostring(wpr.base or wpr.base_ref or "(unknown)"),
        "  kb_doc: " .. tostring(wpr.kb_doc or "(none)"),
      })
    end
    vim.list_extend(lines, {
      "",
      row.worktree.is_base
        and "This IS the base branch, so there is nothing to diff it against."
        or ("O opens the Git Diff View for everything this branch adds on top of "
            .. tostring(_base_branch(row.repo) or "its base") .. "."),
      "An unwatched worktree costs no git calls; w toggles it.",
    })
  elseif row.kind == "commit" then
    local c = row.node.commit or {}
    lines = {
      "Commit " .. tostring(row.node.short),
      "  " .. tostring(c.subject),
      "  author:  " .. tostring(c.author) .. " <" .. tostring(c.email) .. ">",
      "  date:    " .. os.date("%Y-%m-%d %H:%M", tonumber(c.ts) or 0),
      "  parents: " .. tostring(#(c.parents or {})),
      "  merge:   " .. tostring(c.merge),
      "",
      "o opens its diff.",
    }
  elseif row.kind == "file" then
    lines = {
      "File: " .. tostring(row.file.path),
      "  change:   " .. tostring(row.file.kind),
      "  index:    " .. tostring(row.file.x) .. "  worktree: " .. tostring(row.file.y),
      row.file.orig and ("  renamed from: " .. row.file.orig) or "",
    }
  elseif row.kind == "reviews" then
    local backend = _repos()
    local dir = backend and type(backend.reviews_dir) == "function"
      and backend.reviews_dir(row.repo) or nil
    lines = {
      "Reviews for " .. tostring(row.repo.label),
      "  slug:  " .. tostring(row.repo.slug),
      "  store: " .. tostring(dir or "(unavailable)"),
      "",
      "One file per (repo, commit, revision). Listed here for the WHOLE repo,",
      "so a review still shows after a rebase has moved the commit it names.",
      "",
      "<CR> on a review opens its JSON · i describes it",
    }
  elseif row.kind == "draft" then
    -- A draft has no document to read: everything known about it is in the
    -- store, and this is the view that lets a reader decide whether to finish
    -- it, hand it to an agent, or drop it.
    local authoring = require("auto-finder.views.repos.authoring")
    local d = row.draft or {}
    lines = {
      "Unsaved draft (nothing on disk yet)",
      "  repo:    " .. tostring(row.repo.label),
      row.working
        and ("  target:  UNCOMMITTED (" .. tostring(row.worktree or "?") .. ")")
        or  ("  commit:  " .. tostring(row.sha)),
      "  scope:   " .. tostring(row.scope),
      "  holds:   " .. _draft_holds(d),
      "  verdict: " .. tostring(d.verdict or "comment"),
      "",
    }
    for _, c in ipairs(authoring.anchored(d)) do
      lines[#lines + 1] = ("  [%s] %s:%s  %s")
        :format(tostring(c.severity), tostring(c.path), tostring(c.line),
                tostring(c.body))
    end
    for _, u in ipairs(authoring.unanchored(d)) do
      lines[#lines + 1] = ("  [%s] (no line)  %s")
        :format(tostring(u.severity), tostring(u.body))
    end
    if type(d.summary) == "string" and d.summary ~= "" then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "  summary: " .. d.summary
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "It lives in auto-core's draft store, so an agent can read"
    lines[#lines + 1] = "it without going through this panel. <CR> opens the diff."
  elseif row.kind == "review" then
    -- Both kinds of review row land here — the ones under a commit and the
    -- ones in the repo's `reviews` section — and only the second arrives
    -- already described, so the document is read here either way. This is the
    -- view §11 asks for: which commit, when, by whom, and how bad.
    local backend = _repos()
    local meta = row.review
    if backend and type(backend.review_meta) == "function" then
      meta = backend.review_meta(row.review.path) or row.review
    end
    lines = {
      "Review: " .. tostring(meta.name),
      "  commit:   " .. tostring(meta.commit
        or ("(not recorded — the filename says " .. tostring(meta.short) .. ")")),
      "  revision: " .. tostring(meta.revision),
      "  created:  " .. tostring(meta.created or "(not recorded)"),
      "  reviewer: " .. tostring(meta.reviewer or "(not recorded)"),
      "  verdict:  " .. tostring(meta.verdict or "(none)"),
      "  comments: " .. tostring(meta.comments or 0)
        .. (((meta.resolved or 0) > 0) and ("  (" .. meta.resolved .. " resolved)") or ""),
      "  worst:    " .. tostring(meta.worst or "(no comments)"),
      "  path:     " .. tostring(meta.path),
    }
    if meta.severities and next(meta.severities) then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "  severities:"
      -- The ladder in order, then anything unrecognised, so a severity this
      -- version has never heard of is still shown rather than dropped.
      local seen = {}
      for _, sev in ipairs({ "must-fix", "should-fix", "nit", "question" }) do
        seen[sev] = true
        local n = meta.severities[sev]
        if n then lines[#lines + 1] = ("    %-11s %d"):format(sev, n) end
      end
      local rest = {}
      for sev in pairs(meta.severities) do
        if not seen[sev] then rest[#rest + 1] = sev end
      end
      table.sort(rest)
      for _, sev in ipairs(rest) do
        lines[#lines + 1] = ("    %-11s %d"):format(sev, meta.severities[sev])
      end
    end
    if meta.file_list and #meta.file_list > 0 then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "  files:"
      for _, p in ipairs(meta.file_list) do
        local f = meta.files[p] or {}
        lines[#lines + 1] = ("    %s  (%d%s)"):format(p, f.count or 0,
          f.worst and (", " .. f.worst) or "")
      end
    end
    if meta.summary and meta.summary ~= "" then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "  summary: " .. tostring(meta.summary)
    end
    if meta.revision_mismatch then
      lines[#lines + 1] = ""
      lines[#lines + 1] = ("  ! the document says revision %s, the filename says %s")
        :format(tostring(meta.revision_mismatch), tostring(meta.revision))
    end
    if meta.err then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "  ! " .. tostring(meta.err)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "<CR> opens the JSON."
  else
    return
  end
  local ok, float = pcall(require, "auto-core.ui.float")
  if ok and float and float.help_overlay then
    pcall(float.help_overlay, lines, { title = "repos" })
  else
    logger.notify(table.concat(lines, "\n"), { level = vim.log.levels.INFO })
  end
end

local function _reload(row)
  if row and row.id then M.invalidate(row.id) else M.invalidate(nil) end
  _rerender()
end

---HELP is `?`. Exported so the suite can assert it still documents the surfaces
---this view opens — an overlay that silently falls behind its own keymaps is
---worse than none, because it reads as complete.
---
---It documents the PREREQUISITES too, not only the keys. `G`/`N`/`S` reach a
---forge and do nothing at all without a registered token, and the `[#N]` badge
---they hang everything on comes from an association a reader has no way to
---infer — so a modal that lists the keys and stops is precisely the shape that
---reads as complete while leaving the surface unusable (Johno, 2026-09-10:
---"the ? help modal is missing how I can manage the PAT credential to perform
---such action, and how to manage PR associations").
---
---The overlay is a focused, scrollable buffer capped at the window height, and
---nothing on it says so — hence the header hint, which costs no line.
M.HELP = {
  "auto-finder repos — worktree explorer      j/k scrolls · q closes",
  "",
  "  repo → worktree → UNCOMMITTED / commits → files · reviews",
  "  repo → reviews  → every review this repository has, newest first",
  "",
  "  badges:  a file with review feedback on it        [feedback]",
  "           a worktree whose branch is a PR          [#N]",
  "             green open · gray draft · red closed",
  "           a review <commit>.r<N>.review.json  [severity]  → #N  [posted]",
  "",
  "  MOVE AND LOOK",
  "  <CR>  expand · open a file · open a review JSON",
  "  o     diff the commit — three columns: files | a/ (old) | b/ (new)",
  "  O     diff this worktree's branch across its commits (against its base)",
  "  m     load another window of commits",
  "  i     info about the node — on a worktree, its PR, base and KB doc",
  "  R     reload (all with no node)",
  "  w     watch / unwatch this worktree (persists)",
  "  ?     this help",
  "",
  "  GIT",
  "  f     fetch this repository",
  "  s     stage / unstage a file under UNCOMMITTED",
  "  c     commit what is staged (prompts for a message)",
  "  P     push this repository — confirms first, and names the repo",
  "",
  "  PULL REQUESTS            (every key here needs a token — see below)",
  "  G     GetPR: fetch PR #n's branch into a worktree (on a repo)",
  "  N     CreatePR: open a PR for this worktree's branch (on a worktree)",
  "  S     submit this review entry's findings to its PR (on a review)",
  "  d     remove a review / dissociate it from its PR — confirms first",
  "  A     attach review feedback to an in-progress task",
  "",
  "  THE TOKEN — no PR key works until one is registered. There is no",
  "  ambient default, and nothing prompts you for it. From any buffer:",
  "    :WorktreeAuth set github.com command pass show git/pat",
  "    :WorktreeAuth set github.com env GITHUB_TOKEN",
  "    :WorktreeAuth list            lists profiles, never the token",
  "    :WorktreeAuth clear github.com",
  "  <key> is matched slug → host → env, first hit wins:",
  "    slug  owner__name (double underscore), for one repository",
  "    host  github.com — one token for every repo there, the usual case",
  "    env   $GITHUB_TOKEN, and only when the host really is github.com",
  "  Providers are allowlisted: pass, op, gh, secret-tool, keyctl,",
  "  security. Profiles live in worktree-auth.json (mode 0600) and hold",
  "  the REFERENCE — the secret itself never touches disk or a process",
  "  argument list.",
  "",
  "  PR ASSOCIATION — what puts the [#N] on a worktree. It is PR #N when",
  "  its branch is named pr-<N>, OR when the document",
  "    $AUTO_AGENTS_KB_ROOT/shared/prs/<slug>/pr-<N>.md",
  "  says `branch: <this worktree's branch>`. G and N both write it, so",
  "  the ordinary flows need no manual step.",
  "  A review inherits its PR from the worktree AT DRAFT TIME. Open the",
  "  diff on a worktree with no association and the review carries no PR,",
  "  so S can never submit it — associate first, then review.",
  "  Repoint one by editing that document's `branch:`; delete the",
  "  document to dissociate the worktree. `d` dissociates a REVIEW.",
  "",
  "  IN THE DIFF VIEW (o / O), on the a/ or b/ pane:",
  "  c     annotate the line — in visual mode, the selection",
  "  u     record a finding with NO line (\"this module has no tests\")",
  "  x     drop a pending annotation on this line",
  "  s     submit — verdict, an optional summary, then writes the JSON",
  "        and its paired Markdown. q on an unsent draft offers to close",
  "        and KEEP it — a draft survives closing and repaints on reopen.",
  "  o     open this file's working-tree copy for full examination",
  "  <Tab>/<S-Tab> or <C-l>/<C-h>  cycle panes        q  close",
  "",
  "  Same key, two meanings: in the PANEL s stages a file and c commits;",
  "  in the DIFF VIEW s submits a review and c annotates a line.",
  "",
  "  On UNCOMMITTED you can still c/u to leave a DRAFT — it is saved and",
  "  listed under the repo's reviews, so an agent can pick it up. Only s is",
  "  held back: a SAVED review anchors to a commit sha, so commit first,",
  "  then reopen and s.",
  "",
  "  An UNWATCHED worktree lists no commits, on purpose: it costs no",
  "  git calls at all. Press w on the worktree you are working in.",
}
local HELP = M.HELP

local function _help()
  local ok, float = pcall(require, "auto-core.ui.float")
  if ok and float and float.help_overlay then
    pcall(float.help_overlay, HELP, { title = "repos" })
  else
    logger.notify(table.concat(HELP, "\n"), { level = vim.log.levels.INFO })
  end
end

-- ─── git actions (ADR-0060) ───────────────────────────────────────
--
-- These bind keys to `worktree.repos` verbs and do nothing else. No git runs
-- from this file: worktree.nvim owns git for this surface and auto-core owns
-- the argv. The panel's only jobs are choosing which verb a row implies,
-- confirming the outward-facing one, and turning a failure into a message.
--
-- Every handler follows the ADR-0060 r1 SF2 rule: a missing capability or a
-- failed git call is a NOTIFICATION, never a raw keymap traceback.

---_notify_result is the single reporting path for a git action.
local function _notify_result(label, ok, err)
  if ok then
    logger.notify("repos: " .. label, { level = vim.log.levels.INFO })
  else
    logger.notify("repos: " .. label .. " failed — " .. tostring(err or "unknown"),
      { level = vim.log.levels.ERROR })
  end
end

---_verb resolves a backend verb, notifying rather than throwing when absent.
local function _verb(name)
  local backend = _repos()
  local fn = backend and backend[name]
  if type(fn) ~= "function" then
    logger.notify("repos: this action needs a newer worktree.nvim (" .. name .. ")",
      { level = vim.log.levels.WARN })
    return nil
  end
  return fn
end

---git_fetch is `f` on a repo row.
function M.git_fetch(row)
  if not (row and row.repo) then
    logger.notify("repos: put the cursor on a repository to fetch",
      { level = vim.log.levels.WARN })
    return
  end
  local fn = _verb("fetch"); if not fn then return end
  local label = row.repo.label or "repo"
  logger.notify("repos: fetching " .. label .. "...", { level = vim.log.levels.INFO })
  local ok = pcall(fn, row.repo, function(done, err)
    _notify_result("fetch " .. label, done, err)
  end)
  if not ok then _notify_result("fetch " .. label, false, "call failed") end
end

---git_stage_toggle is `s` on a file under UNCOMMITTED.
---
---The direction comes from git's own index column: porcelain `x` is the staged
---side, so anything other than a space or `?` there means this path already has
---something staged and `s` should take it back out. That is why the panel
---renders BOTH columns — a file staged and then edited again reads `MM`, and a
---single glyph could not tell you which way `s` will go.
function M.git_stage_toggle(row)
  if not (row and row.kind == "file" and row.file and row.worktree) then
    logger.notify("repos: put the cursor on a changed file to stage it",
      { level = vim.log.levels.WARN })
    return
  end
  if not (row.node and row.node.kind == "uncommitted") then
    logger.notify("repos: only files under UNCOMMITTED can be staged",
      { level = vim.log.levels.WARN })
    return
  end
  local f = row.file
  local x = type(f.x) == "string" and f.x or "?"
  local staged = x ~= " " and x ~= "?" and x ~= ""
  local fn = _verb(staged and "unstage" or "stage"); if not fn then return end
  local path = f.path
  if type(path) ~= "string" or path == "" then
    logger.notify("repos: that row has no path to stage", { level = vim.log.levels.WARN })
    return
  end
  local verb = staged and "unstage" or "stage"
  local ok = pcall(fn, row.worktree, path, function(done, err)
    _notify_result(verb .. " " .. path, done, err)
  end)
  if not ok then _notify_result(verb .. " " .. path, false, "call failed") end
end

---git_commit is `c`: prompt for a message, commit what is staged.
---
---It checks `has_staged` BEFORE prompting. Asking for a message and then
---refusing is worse than saying up front that there is nothing to commit, and
---the ordering is the one thing the panel controls.
function M.git_commit(row)
  local wt = row and (row.worktree or (row.repo and row.repo.sample_worktree))
  if not wt then
    logger.notify("repos: put the cursor on a worktree or one of its files to commit",
      { level = vim.log.levels.WARN })
    return
  end
  local backend = _repos()
  if backend and type(backend.has_staged) == "function" then
    local pok, staged = pcall(backend.has_staged, wt)
    if pok and staged == false then
      logger.notify("repos: nothing staged — press `s` on a file first",
        { level = vim.log.levels.WARN })
      return
    end
  end
  local fn = _verb("commit"); if not fn then return end
  vim.ui.input({ prompt = "Commit message: " }, function(msg)
    if not msg or vim.trim(msg) == "" then
      logger.notify("repos: commit cancelled", { level = vim.log.levels.INFO })
      return
    end
    local ok = pcall(fn, wt, msg, function(done, err)
      _notify_result("commit", done, err)
    end)
    if not ok then _notify_result("commit", false, "call failed") end
  end)
end

---remove_review is `d` on a review row: delete the review's JSON, after a
---confirmation that NAMES it (§11.6).
---
---A review is the only artifact on this panel that git cannot regenerate, so it
---gets the treatment §9 gave `push`: the prompt names the file and the
---repository, because "are you sure?" on a panel holding several repos does not
---say which one is about to go.
---
---It also says what is KEPT. The canonical Markdown is the PRIMARY and this
---JSON is its projection (ADR-0067), the Markdown lives in the knowledge base
---rather than the review store, and a projection can be written again from
---prose while prose cannot be recovered from a projection — so only the JSON
---goes. "Remove the review" could reasonably be read as removing both, which
---is exactly why the prompt says which it means.
---
---`d`, not `x`: in the diff view `x` DROPS A PENDING annotation that was never
---written, and using one key for "discard an unsaved draft" and "delete a file
---from disk" would blur the only distinction that matters here.
function M.remove_review(row)
  -- Accept the review row OR either of its pair leaves: `d` on the Markdown or
  -- the JSON removes the whole review, since the two files are one thing.
  if not (row and (row.kind == "review" or row.kind == "review_file")
      and row.review and row.review.path) then
    logger.notify("repos: put the cursor on a review to remove it",
      { level = vim.log.levels.WARN })
    return
  end
  local backend = _repos()
  if not (backend and type(backend.remove_review) == "function") then
    logger.notify("repos: removing a review needs a newer worktree.nvim (remove_review)",
      { level = vim.log.levels.WARN })
    return
  end
  local meta = row.review
  local pr_num = (row.parent_pr and row.parent_pr.number)
    or (row.pr and row.pr.number)
    or (row.review and row.review.pr)
  if pr_num then
    local label = tostring(meta.name or meta.path)
    local prompt = string.format("Dissociate review %s from PR #%s? (Files on disk will NOT be deleted)", label, tostring(pr_num))
    local function go_dissociate(choice)
      if choice ~= "yes" then
        logger.notify("repos: dissociation cancelled", { level = vim.log.levels.INFO })
        return
      end
      local ok_store, store = pcall(require, "worktree.store")
      local ok_pr, pr_mod = pcall(require, "worktree.pr")
      local data, rerr = ok_store and store.read_json(meta.path)
      if not data then
        logger.notify("repos: could not read review JSON to dissociate — " .. tostring(rerr), { level = vim.log.levels.ERROR })
        return
      end
      local did_change = false
      if ok_pr and pr_mod.dissociate_review then
        did_change = pr_mod.dissociate_review(data, pr_num)
      else
        if tonumber(data.pr) == tonumber(pr_num) then
          data.pr = nil
          did_change = true
        end
      end
      if not did_change then
        logger.notify(string.format("repos: review %s is not associated with PR #%s", label, tostring(pr_num)), { level = vim.log.levels.WARN })
        return
      end
      local write_ok = false
      local werr = nil
      if ok_store and store.write_json then
        local wok, err = store.write_json(meta.path, data)
        if wok then
          write_ok = true
        else
          werr = err
        end
      else
        local ok_atomic, fs_atomic = pcall(require, "auto-core.fs.atomic")
        if ok_atomic and fs_atomic.write then
          local wok, err = fs_atomic.write(meta.path, vim.json.encode(data))
          if wok then
            write_ok = true
          else
            werr = err
          end
        else
          local wok, err = pcall(vim.fn.writefile, { vim.json.encode(data) }, meta.path)
          if wok and err == 0 then
            write_ok = true
          else
            werr = err or "write failed"
          end
        end
      end
      if not write_ok then
        logger.notify(string.format("repos: failed to save dissociated review %s: %s", label, tostring(werr or "write error")), { level = vim.log.levels.ERROR })
        return
      end
      M.invalidate(nil)
      _rerender()
      logger.notify(string.format("repos: dissociated review %s from PR #%s", label, tostring(pr_num)), { level = vim.log.levels.INFO })
    end
    local okc, float = pcall(require, "auto-core.ui.float")
    if okc and float and type(float.confirm) == "function" then
      float.confirm(prompt, { on_choice = go_dissociate })
    else
      vim.ui.select({ "yes", "no" }, { prompt = prompt }, go_dissociate)
    end
    return
  end

  -- The RAW filename, not the elided row label: a prompt that is about to
  -- delete something names it exactly as the filesystem does.
  local label = tostring(meta.name or meta.path)
  local prompt = ("Delete review %s from %s?  Both the JSON and its Markdown are removed."):format(
    label, tostring(row.repo and row.repo.label or "this repository"))

  local function go(choice)
    if choice ~= "yes" then
      logger.notify("repos: removal cancelled", { level = vim.log.levels.INFO })
      return
    end
    local ok, err, detail = backend.remove_review(row.repo, meta.path)
    if not ok then
      logger.notify("repos: could not remove " .. label .. " — " .. tostring(err),
        { level = vim.log.levels.ERROR })
      return
    end
    -- EVERYTHING is invalidated, not just one node: the file was listed in the
    -- repo's `reviews` section and again under its commit, its severity fed a
    -- file's `[feedback]` badge, and the section's count came from a third
    -- read. A partial invalidation leaves one of those showing a file that is
    -- no longer there.
    M.invalidate(nil)
    _rerender()
    -- Report what was removed. Both halves go now (Johno, 2026-09-03 — the two
    -- files are one review); a Markdown that could not be deleted is surfaced so
    -- an orphan does not linger unseen.
    local doc = detail and detail.document
    local msg
    if doc and detail.document_removed == false and not detail.document_absent then
      msg = "repos: removed " .. label .. " (JSON gone; its Markdown could NOT be "
        .. "deleted — " .. tostring(detail.document_error or "unknown")
        .. ", left at " .. tostring(doc) .. ")"
    elseif doc and detail.document_removed then
      msg = "repos: removed " .. label .. " and its Markdown"
    else
      msg = "repos: removed " .. label
    end
    logger.notify(msg, { level = vim.log.levels.INFO })
  end

  local okc, float = pcall(require, "auto-core.ui.float")
  if okc and float and type(float.confirm) == "function" then
    float.confirm(prompt, { on_choice = go })
  else
    -- No confirm primitive is NOT a licence to delete unconfirmed.
    vim.ui.select({ "yes", "no" }, { prompt = prompt }, go)
  end
end

---attach_review_to_task is `A` on a review row: attach the review's canonical
---Markdown (or JSON) path to an in-progress task in .todo-list/in-progress/ (ADR-0083 §2.1).
function M.attach_review_to_task(row)
  if not (row and (row.kind == "review" or row.kind == "review_file") and row.review) then
    logger.notify("repos: cursor must be on a review row to attach feedback",
      { level = vim.log.levels.WARN })
    return
  end
  local meta = row.review
  local review_path = meta.document or meta.md_path or meta.path
  if not review_path or review_path == "" then
    logger.notify("repos: review has no file path", { level = vim.log.levels.WARN })
    return
  end
  local ok_todo, todo_api = pcall(require, "auto-core.todo")
  if not (ok_todo and todo_api and type(todo_api.list) == "function") then
    logger.notify("repos: auto-core.todo not available", { level = vim.log.levels.WARN })
    return
  end
  local tasks = todo_api.list({ status = "in-progress" })
  if not tasks or #tasks == 0 then
    logger.notify("repos: no in-progress tasks found in .todo-list/in-progress/",
      { level = vim.log.levels.WARN })
    return
  end
  local items = {}
  for _, t in ipairs(tasks) do
    table.insert(items, {
      task = t,
      label = string.format("%s (%s)", t.title or "untitled", t.id or "no-id"),
    })
  end
  vim.ui.select(items, {
    prompt = "Attach review to in-progress task:",
    format_item = function(item) return item.label end,
  }, function(choice)
    if not choice then return end
    local sel_task = choice.task
    local ok_paths, todo_paths = pcall(require, "auto-core.todo.paths")
    local portable_ref
    if ok_paths and todo_paths and type(todo_paths.to_portable) == "function" then
      portable_ref = todo_paths.to_portable(review_path)
    else
      local ok_vars, vars = pcall(require, "auto-core.todo.vars")
      if ok_vars and vars and type(vars.symbolize_path) == "function" then
        portable_ref = vars.symbolize_path(review_path)
      else
        portable_ref = review_path
      end
    end
    local updated_reviews = {}
    if type(sel_task.review) == "table" then
      for _, r in ipairs(sel_task.review) do
        table.insert(updated_reviews, r)
      end
    elseif type(sel_task.review) == "string" and sel_task.review ~= "" then
      table.insert(updated_reviews, sel_task.review)
    end
    local exists = false
    for _, r in ipairs(updated_reviews) do
      if r == portable_ref or r == review_path then
        exists = true
        break
      end
    end
    if not exists then
      table.insert(updated_reviews, portable_ref)
    end
    local ok, err = todo_api.update(sel_task.id, { review = updated_reviews })
    if ok then
      logger.notify(string.format("repos: attached review to task '%s'", sel_task.title or sel_task.id),
        { level = vim.log.levels.INFO })
    else
      logger.notify(string.format("repos: failed to attach review: %s", tostring(err)),
        { level = vim.log.levels.ERROR })
    end
  end)
end

---git_push is `P`: publish, but only after an explicit confirmation.
---
---`P` is one keypress from `p`, and a push is the only action on this panel
---that leaves the machine. The confirmation NAMES the repository, because "are
---you sure?" on a panel holding several repos does not say which one is about
---to be published — and the point is that a mistyped key on the wrong row
---cannot publish.
function M.git_push(row)
  -- `P` is PUSH ONLY (ADR-0083 Amendment r9). It used to double as "post inline
  -- feedback" when the cursor sat on a PR row — a cursor-position overload that
  -- risked posting an unintended review group. Posting now has its own key `S`
  -- on a specific review entry (M.submit_review), so `P` never posts.
  if not (row and row.repo) then
    logger.notify("repos: put the cursor on a repository to push",
      { level = vim.log.levels.WARN })
    return
  end
  local fn = _verb("push"); if not fn then return end
  local label = row.repo.label or "this repo"
  local prompt = "Push " .. label .. " to its remote?"
  local function go(choice)
    if choice ~= "yes" then
      logger.notify("repos: push cancelled", { level = vim.log.levels.INFO })
      return
    end
    logger.notify("repos: pushing " .. label .. "...", { level = vim.log.levels.INFO })
    local ok = pcall(fn, row.repo, nil, function(done, err)
      _notify_result("push " .. label, done, err)
    end)
    if not ok then _notify_result("push " .. label, false, "call failed") end
  end
  local okc, float = pcall(require, "auto-core.ui.float")
  if okc and float and type(float.confirm) == "function" then
    float.confirm(prompt, { on_choice = go })
  else
    -- No confirm primitive is NOT a licence to push unconfirmed.
    vim.ui.select({ "yes", "no" }, { prompt = prompt }, go)
  end
end

-- ─── keymaps + subscriptions ──────────────────────────────────

local function _apply_keymaps(bufnr, panel_winid)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local set = function(lhs, fn, desc)
    pcall(vim.keymap.set, "n", lhs, fn,
      { buffer = bufnr, silent = true, nowait = true, desc = desc })
  end
  set("<CR>", function() _activate(_row_under_cursor(panel_winid)) end,
    "auto-finder.repos: expand / open")
  set("o", function() M.open_diff(_row_under_cursor(panel_winid)) end,
    "auto-finder.repos: diff this commit")
  -- `O` is the GROUPED diff: every commit in a range, in one view. `o` is the
  -- single thing under the cursor. Since a PR is no longer its own row
  -- (Amendment r9), `O` on the WORKTREE answers "what does this branch change"
  -- against its base — which is the same question as "what does this PR change",
  -- the PR being a branch with a number attached (Johno, 2026-09-08). Anything
  -- else falls through to `o`'s behaviour rather than doing nothing.
  set("O", function()
    local row = _row_under_cursor(panel_winid)
    if row and row.kind == "worktree" then
      M.open_worktree_diff(row)
    else
      M.open_diff(row)
    end
  end, "auto-finder.repos: grouped diff — worktree branch against its base / commit")
  set("w", function() M.toggle_watch(_row_under_cursor(panel_winid)) end,
    "auto-finder.repos: watch / unwatch this worktree")
  set("m", function() M.load_more(_row_under_cursor(panel_winid)) end,
    "auto-finder.repos: load more commits")
  set("i", function() _info(_row_under_cursor(panel_winid)) end,
    "auto-finder.repos: info")
  set("R", function() _reload(_row_under_cursor(panel_winid)) end,
    "auto-finder.repos: reload")
  set("f", function() M.git_fetch(_row_under_cursor(panel_winid)) end,
    "auto-finder.repos: fetch this repository")
  set("s", function() M.git_stage_toggle(_row_under_cursor(panel_winid)) end,
    "auto-finder.repos: stage / unstage this file")
  set("c", function() M.git_commit(_row_under_cursor(panel_winid)) end,
    "auto-finder.repos: commit what is staged")
  set("P", function() M.git_push(_row_under_cursor(panel_winid)) end,
    "auto-finder.repos: push this repository (confirms first)")
  set("S", function() M.submit_review(_row_under_cursor(panel_winid)) end,
    "auto-finder.repos: submit this review entry to its PR")
  set("d", function() M.remove_review(_row_under_cursor(panel_winid)) end,
    "auto-finder.repos: remove review / dissociate from its PR (confirms first)")
  set("A", function() M.attach_review_to_task(_row_under_cursor(panel_winid)) end,
    "auto-finder.repos: attach review to in-progress task")
  set("G", function() M.get_pr_for_repo(_row_under_cursor(panel_winid)) end,
    "auto-finder.repos: fetch PR branch and create worktree (GetPR)")
  set("N", function() M.create_pr_for_worktree(_row_under_cursor(panel_winid)) end,
    "auto-finder.repos: create PR for worktree (CreatePR)")
  set("?", _help, "auto-finder.repos: help")
end

---_ensure_subscriptions keeps exactly one handler per topic.
---
---`view_subs:replace` rather than a `_subscribed` boolean: the boolean form
---silently survives a bus reset and the view then stops updating with no sign
---anything is wrong ([[view-subs-over-subscribe-flags]]).
local function _ensure_subscriptions()
  local ok_vs, vs = pcall(require, "auto-finder.shared.view_subs")
  if not ok_vs then return end
  M._subs = M._subs or vs.new()

  -- ONE subscription, to the TRANSLATED topic. The A1 invariant (ADR-0026
  -- Phase 4) forbids a view from subscribing to an upstream topic such as
  -- `worktree:switched` or `worktree.watch:changed`; auto-finder's core
  -- translator folds all of those onto `auto-finder.core.repos:changed`, which
  -- is the only thing this view listens to.
  M._subs:replace("repos-core", M.REFRESH_TOPIC, function()
    M.invalidate(nil)
    vim.schedule(_rerender)
  end)
end

local function _dispose_subscriptions()
  if M._subs and M._subs.dispose_all then
    pcall(function() M._subs:dispose_all() end)
  end
  M._subs = nil
end

-- ─── view lifecycle contract ──────────────────────────────────

function M.get_buffer(panel_winid)
  if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
    _apply_keymaps(M._bufnr, panel_winid)
    _ensure_subscriptions()
    return M._bufnr
  end
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = "hide"
  vim.bo[b].buftype = "nofile"
  vim.bo[b].swapfile = false
  vim.bo[b].filetype = FILETYPE
  vim.b[b].auto_finder_view = "repos"
  pcall(vim.api.nvim_buf_set_name, b, "auto-finder://repos")
  M._bufnr = b
  _render(b)
  _apply_keymaps(b, panel_winid)
  _ensure_subscriptions()
  return b
end

function M.on_focus(panel_winid, bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  _apply_keymaps(bufnr, panel_winid)
  _ensure_subscriptions()
  _render(bufnr)
end

---_state_file returns the durable path to the serialized diff session.
function M._state_file()
  if M._custom_state_file then return M._custom_state_file end
  return vim.fn.stdpath("state") .. "/auto-finder/last-diff.json"
end

---_persist_resume writes M._resume to disk atomically.
function M._persist_resume()
  if not M._resume then return end
  local ok_atomic, fs_atomic = pcall(require, "auto-core.fs.atomic")
  if not ok_atomic or type(fs_atomic.write) ~= "function" then return end
  local payload = {
    repo_slug = M._resume.repo_slug,
    common_dir = M._resume.common_dir,
    worktree_path = M._resume.worktree_path,
    target_kind = M._resume.target_kind,
    sha = M._resume.sha,
    pr_number = M._resume.pr_number,
    active_file = M._resume.active_file,
    active_idx = M._resume.active_idx,
    focused_pane = M._resume.focused_pane,
    file_positions = M._resume.file_positions,
    timestamp = M._resume.timestamp or os.time(),
  }
  pcall(fs_atomic.write, M._state_file(), vim.json.encode(payload), { mkdir = true })
end

---_hydrate_resume loads M._resume from disk if not present in memory.
function M._hydrate_resume()
  if M._resume ~= nil then return M._resume end
  local state_path = M._state_file()
  if vim.fn.filereadable(state_path) ~= 1 then return nil end
  local ok, content = pcall(vim.fn.readfile, state_path)
  if not ok or not content or #content == 0 then return nil end
  local raw = table.concat(content, "\n")
  local dok, data = pcall(vim.json.decode, raw)
  if not dok or type(data) ~= "table" then return nil end
  -- Validate payload carries necessary fields (N1)
  if not (data.repo_slug or data.common_dir) or not data.target_kind then
    return nil
  end
  if data.target_kind ~= "uncommitted" and not data.sha and not data.pr_number then
    return nil
  end
  M._resume = data
  return M._resume
end

---can_resume reports whether a diff has been opened this session (or saved from a
---previous session) and can be reopened where it was left. The <C-g> modal probes
---this to decide whether to offer the entry at all.
---@return boolean
function M.can_resume()
  return M._hydrate_resume() ~= nil
end

---resume_diff reopens the last diff at the reader's last position. This is what
---makes leaving the diff to check a file (the `o` key) safe: the way back is one
---gesture, from anywhere, through the navigation modal.
function M.resume_diff()
  local r = M._hydrate_resume()
  if not r then
    logger.notify("repos: no diff to resume — open one with o first",
      { level = vim.log.levels.INFO })
    return false, "no diff to resume"
  end

  -- Validate repo and worktree directories exist on disk
  local repo_dir = r.common_dir or (r.row and r.row.repo and r.row.repo.common_dir)
  local wt_path = r.worktree_path or (r.row and r.row.worktree and r.row.worktree.path)
  if (repo_dir and vim.fn.isdirectory(repo_dir) ~= 1) or (wt_path and vim.fn.isdirectory(wt_path) ~= 1) then
    M._resume = nil
    pcall(vim.fn.delete, M._state_file())
    logger.notify("repos: previous diff target repository/worktree no longer exists",
      { level = vim.log.levels.WARN })
    return false, "target repo or worktree no longer exists"
  end

  local row = r.row
  if not row then
    local backend = _repos()
    local repo_obj = nil
    if backend and type(backend.repos) == "function" then
      for _, repo in ipairs(backend.repos() or {}) do
        if repo.slug == r.repo_slug or repo.common_dir == r.common_dir then
          repo_obj = repo
          break
        end
      end
    end
    if not repo_obj then
      repo_obj = {
        slug = r.repo_slug,
        common_dir = r.common_dir,
        path = r.worktree_path,
        sample_worktree = r.worktree_path,
      }
    end
    local wt_obj = nil
    if backend and type(backend.worktrees) == "function" and repo_obj then
      for _, wt in ipairs(backend.worktrees(repo_obj) or {}) do
        if wt.path == r.worktree_path then
          wt_obj = wt
          break
        end
      end
    end
    if not wt_obj and r.worktree_path then
      wt_obj = { path = r.worktree_path }
    end
    local node_obj = {
      kind = r.target_kind,
      sha = r.sha,
      short = r.sha and r.sha:sub(1, 7) or (r.target_kind == "uncommitted" and "UNCOMMITTED" or ""),
      pr_number = r.pr_number,
      commit = { subject = "" },
    }
    row = {
      kind = r.target_kind,
      repo = repo_obj,
      worktree = wt_obj,
      node = node_obj,
    }
  end

  local initial = {
    path = r.active_file,
    active_file = r.active_file,
    idx = r.active_idx,
    active_idx = r.active_idx,
    pane = r.focused_pane,
    focused_pane = r.focused_pane,
    file_positions = r.file_positions,
    lnum = (r.file_positions and r.active_file and r.file_positions[r.active_file] and r.file_positions[r.active_file].lnum) or (r.pos and r.pos.lnum),
    col = (r.file_positions and r.active_file and r.file_positions[r.active_file] and r.file_positions[r.active_file].col) or (r.pos and r.pos.col),
  }

  local ok_open, open_err
  if r.target_kind == "pr" then
    if not row.pr and r.pr_number then
      row.pr = { number = r.pr_number }
    end
    ok_open, open_err = M.open_pr_diff(row, { initial = initial })
  elseif r.target_kind == "worktree" then
    -- The row reconstruction above re-resolves the worktree from the backend
    -- by path, which is what supplies `branch` and `is_base` — a resumed
    -- worktree diff needs the branch to name its range. When the backend
    -- cannot answer, the row falls back to a path-only worktree and this
    -- declines with "no branch or HEAD to diff", which the caller below turns
    -- into a cleared resume state rather than an empty diff.
    ok_open, open_err = M.open_worktree_diff(row, { initial = initial })
  else
    ok_open, open_err = M.open_diff(row, { initial = initial })
  end

  if ok_open == false then
    -- Commit or target diff no longer exists (e.g. rebased, amended, force-pushed).
    -- Retire stale resume state (SF1).
    M._resume = nil
    pcall(vim.fn.delete, M._state_file())
    logger.notify(string.format("repos: previous diff target (%s) is stale; cleared resume state",
      tostring(r.sha and r.sha:sub(1, 7) or r.target_kind or "target")),
      { level = vim.log.levels.WARN })
    return false, open_err
  end
  return true
end

function M.on_close()
  _dispose_subscriptions()
  M._persist_resume()
  -- DELETE the buffer, do not merely drop the pointer (ADR-0060 r1 SF1).
  -- `get_buffer` creates it with bufhidden=hide, so clearing `M._bufnr` alone
  -- leaked one named `auto-finder://repos` buffer per close/reopen — and per
  -- worktree switch, which is far more frequent. Every sibling view
  -- (dbase, todos, tests, debug, marks) and the legacy section delete theirs;
  -- this file was copied from dbase/tree.lua with the delete block dropped.
  --
  -- bufhidden=wipe is NOT the alternative: it kills the buffer on an ordinary
  -- section switch, leaving `M._bufnr` dangling at an invalid buffer, which
  -- silently disables `_rerender` until the next mount notices.
  if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
    pcall(vim.api.nvim_buf_delete, M._bufnr, { force = true })
  end
  -- The cache goes with the panel: on the next open the work in flight may
  -- have moved, and a stale tree is worse than a brief re-read.
  M.invalidate(nil)
  M._bufnr = nil
  M._rows = nil
end

function M.refresh()
  M.invalidate(nil)
  _rerender()
end

M._render_for_tests = _render
M._row_under_cursor_for_tests = _row_under_cursor

return M
