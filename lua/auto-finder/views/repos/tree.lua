---View — the repos explorer over worktree.nvim (ADR-0060 §2.2).
---
---A pure renderer, the same shape as `views/dbase/tree.lua` is over autodb:
---every byte of data arrives through `worktree.repos`, and this view never
---shells git itself. The tree it draws:
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
---**Everything is cached per node id.** A repaint (cursor move, watch toggle,
---focus change) must cost ZERO git subprocesses — the panel this replaces ran a
---blocking `git status` per worktree on every navigate plus a `git config` per
---repo, which is what made it expensive. Git is paid on first expand and after
---an explicit invalidation only.
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
  if opts.hl then hls[#hls + 1] = { lnum = #lines - 1, hl = opts.hl } end
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

-- Johno's scheme (ADR-0060 §2.2): deleted RED, modified GREEN, added GREEN
-- with a `+`. Added and modified share the colour on purpose; the MARKER is
-- what distinguishes them.
local KIND_HL = {
  added      = "AutoCoreGitAdded",
  modified   = "AutoCoreGitModified",
  deleted    = "AutoCoreGitDeleted",
  renamed    = "AutoCoreGitRenamed",
  untracked  = "AutoCoreGitUntracked",
  conflicted = "AutoCoreGitConflicted",
}
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
    _row(rows, lines, hls, {
      kind = opts.kind, id = opts.id, expandable = true,
      repo = opts.repo, worktree = opts.worktree, node = opts.node,
      hl = opts.hl,
      text = string.rep(IND, depth) .. _chevron(open) .. " "
        .. opts.label .. (opts.suffix or ""),
    })
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
          local wopen = container(1, {
            kind = "worktree", id = wid, repo = repo, worktree = wt,
            hl = wt.watched and "AutoCoreSectionActive" or "AutoCoreSectionInactive",
            label = wt.branch or vim.fn.fnamemodify(wt.path, ":t")
              .. (wt.detached and "  (detached)" or ""),
            suffix = suffix,
          })
          if wopen then
            if not wt.watched then
              -- §2.3: an unwatched worktree computes NOTHING. Say why, so the
              -- empty expansion reads as a choice rather than a failure.
              msg(2, "not watched — w to watch and list commits")
            else
              local cc = _cache(wid)
              if not cc.items then
                local extra = (M._more[wid] or 0)
                local nodes, meta = backend.children(repo, wt, {
                  limit = 15 + extra * 15,
                })
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
              for _, node in ipairs(cc.items) do
                local nid = node.kind == "uncommitted"
                  and ("unc:" .. wt.path) or ("commit:" .. node.sha)
                local nopen = container(2, {
                  kind = node.kind, id = nid, repo = repo, worktree = wt,
                  node = node,
                  hl = node.kind == "uncommitted" and "AutoCoreGitModified" or nil,
                  label = node.label,
                })
                if nopen then
                  local fc = _cache(nid)
                  if not fc.items then
                    if node.kind == "uncommitted" then
                      fc.items = backend.uncommitted(wt)
                      fc.reviews = {}
                    else
                      fc.items = backend.commit_files(repo, node.sha)
                      fc.reviews = backend.reviews(repo, node.sha)
                    end
                  end
                  if #fc.items == 0 and #(fc.reviews or {}) == 0 then
                    msg(3, "(no files)")
                  end
                  for _, f in ipairs(fc.items) do
                    _row(rows, lines, hls, {
                      kind = "file", repo = repo, worktree = wt, node = node,
                      file = f, hl = KIND_HL[f.kind] or "AutoCoreDimmed",
                      text = string.rep(IND, 3) .. (KIND_MARK[f.kind] or "?")
                        .. " " .. f.path
                        .. (f.orig and ("  ← " .. f.orig) or ""),
                    })
                  end
                  -- Requirement 9: review files sit beside the changed files.
                  for _, rv in ipairs(fc.reviews or {}) do
                    _row(rows, lines, hls, {
                      kind = "review", repo = repo, worktree = wt, node = node,
                      review = rv, hl = "AutoCoreReviewFrame",
                      text = string.rep(IND, 3) .. "R " .. rv.name,
                    })
                  end
                end
              end
              -- Only a bounded window shows a load-more affordance; a
              -- divergence range is already complete by definition.
              if cc.meta and cc.meta.mode == "window" and #cc.items > 0 then
                _row(rows, lines, hls, {
                  kind = "more", id = wid, repo = repo, worktree = wt,
                  hl = "AutoCoreDimmed",
                  text = string.rep(IND, 2) .. "… m for more commits",
                })
              end
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
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, h.lnum, 0,
      { end_line = h.lnum + 1, hl_group = h.hl })
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
  if row.kind == "review" then return _open_path(row.review.path) end
  if row.kind == "more" then return M.load_more(row) end
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
function M.open_diff(row)
  local backend = _repos()
  if not (backend and row and row.repo) then return end
  local node = row.node
  local uncommitted = node and node.kind == "uncommitted"
  local sha = node and node.sha
  if not sha and not uncommitted then
    logger.notify("repos: put the cursor on a commit or UNCOMMITTED to diff it",
      { level = vim.log.levels.WARN })
    return
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
    return
  end
  files = files or {}
  if #files == 0 then
    logger.notify("repos: no diff for "
      .. tostring(uncommitted and "UNCOMMITTED" or row.node.short),
      { level = vim.log.levels.WARN })
    return
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
  if uncommitted then
    -- The schema needs a 40-hex commit and a working tree has none, so the
    -- capability is PRESENT-but-disabled: `c` explains rather than doing
    -- nothing, and `x`/`s` stay unbound so nothing implies a draft exists.
    annotate = {
      disabled_reason = "UNCOMMITTED has no commit to anchor a review to — commit or stash first",
    }
  else
    local draft = authoring.draft(row.repo.slug, sha)
    annotate = {
      on_add = function(a) table.insert(draft.comments, a) end,
      on_remove = function(a)
        for i = #draft.comments, 1, -1 do
          local c = draft.comments[i]
          if c.path == a.path and c.line == a.line and (c.side or "RIGHT") == (a.side or "RIGHT") then
            table.remove(draft.comments, i)
            break
          end
        end
      end,
      pending = function() return draft.comments end,
      before_close = function(reason)
        if reason ~= "key" or #draft.comments == 0 then return "close" end
        -- The prompt is ASYNCHRONOUS and this hook is not, so cancel NOW and
        -- finish through the non-prompting "resume" reason. A hook that
        -- prompted on "key" would prompt again on the finishing call and never
        -- close (ADR-0065 §2.3).
        vim.schedule(function()
          vim.ui.select({ "submit", "discard", "cancel" }, {
            prompt = ("%d unsent comment(s):"):format(#draft.comments),
          }, function(choice)
            if choice == "submit" then
              M._submit_review(row, sha)
            elseif choice == "discard" then
              authoring.discard(row.repo.slug, sha)
              pcall(function() dv.close("resume") end)
            end
          end)
        end)
        return "cancel"
      end,
    }
    keymaps = { { key = "s", desc = "submit review",
                  fn = function() M._submit_review(row, sha) end } }
  end

  local handle, err = dv.open({
    files = files,
    annotations = annotations,
    annotate = annotate,
    keymaps = keymaps,
    title = " " .. tostring(row.node.short) .. "  "
      .. tostring((row.node.commit or {}).subject or "") .. " ",
  })
  if not handle then
    -- Refusing on a narrow window is deliberate (auto-core sets MIN_COLUMNS):
    -- half a diff read as a whole one is worse than none.
    logger.notify("repos: " .. tostring(err), { level = vim.log.levels.WARN })
    return
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
  local draft = authoring.draft(row.repo.slug, sha)
  local verdicts = { "comment", "approved", "change_requested" }
  vim.ui.select(verdicts, { prompt = "verdict:" }, function(verdict)
    if not verdict then return end
    draft.verdict = verdict
    vim.ui.input({ prompt = "summary (optional): " }, function(summary)
      draft.summary = summary
      local res, reason = authoring.submit({ repo = row.repo, sha = sha })
      if not res then
        logger.notify("repos: " .. tostring(reason), { level = vim.log.levels.ERROR })
        return
      end
      logger.notify(("repos: wrote review r%d — %s + %s")
        :format(res.revision, vim.fn.fnamemodify(res.md_path, ":t"),
                vim.fn.fnamemodify(res.json_path, ":t")))
      -- Reopen so the freshly-written review renders from DISK: the round trip
      -- is the confirmation, not the notification.
      local dv_ok, dv2 = pcall(require, "auto-core.ui.diffview")
      if dv_ok then pcall(dv2.close, "resume") end
      vim.schedule(function() M.open_diff(row) end)
    end)
  end)
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
      "",
      "An unwatched worktree costs no git calls; w toggles it.",
    }
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
  elseif row.kind == "review" then
    lines = {
      "Review: " .. tostring(row.review.name),
      "  revision: " .. tostring(row.review.revision),
      "  path:     " .. tostring(row.review.path),
      "",
      "<CR> opens the JSON.",
    }
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

local HELP = {
  "auto-finder repos — worktree explorer",
  "",
  "  repo → worktree → UNCOMMITTED / commits → files · reviews",
  "",
  "  <CR>  expand · open a file · open a review JSON",
  "  o     diff the commit — three columns: files | a/ (old) | b/ (new)",
  "  w     watch / unwatch this worktree (persists)",
  "  m     load another window of commits",
  "  i     info about the node          R  reload (all with no node)",
  "  ?     this help",
  "",
  "  git actions:",
  "  f     fetch this repository",
  "  s     stage / unstage a file under UNCOMMITTED",
  "  c     commit what is staged (prompts for a message)",
  "  P     push — confirms first, and names the repo",
  "",
  "  An UNWATCHED worktree lists no commits, on purpose: it costs no",
  "  git calls at all. Press w on the worktree you are working in.",
}

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

---git_push is `P`: publish, but only after an explicit confirmation.
---
---`P` is one keypress from `p`, and a push is the only action on this panel
---that leaves the machine. The confirmation NAMES the repository, because "are
---you sure?" on a panel holding several repos does not say which one is about
---to be published — and the point is that a mistyped key on the wrong row
---cannot publish.
function M.git_push(row)
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
    "auto-finder.repos: push (confirms first)")
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

function M.on_close()
  _dispose_subscriptions()
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
