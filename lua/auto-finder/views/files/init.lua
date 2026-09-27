---auto-finder.views.files — the files slot (ADR-0200).
---
---A lazy tree over the working directory, built on auto-core.fs.scan (reads), auto-core.fs.watch
---(non-recursive, expanded directories only) and auto-core.git.status (filename colours). Nothing here
---reads a collapsed directory, and a hidden pane does no work:
---
---  shown  (on_focus)  : new owner token → subscribe → arm a watch on every expanded dir → re-read each
---                       expanded dir once (fresh) → git colours → paint
---  hidden (BufHidden / on_close): cancel the token's reads → release every watch → dispose the
---                       subscriptions and autocmds → stop timers. The model and buffer are KEPT, so the
---                       next show is cheap.
---
---An event re-reads only the directory it names; a content change only refreshes git colours. There is no
---full-root refresh anywhere.
---@module 'auto-finder.views.files'

local model_mod = require("auto-finder.views.files.model")
local render = require("auto-finder.views.files.render")
local gitc = require("auto-finder.views.files.git")

local M = {
  name = "files",
  description = "files",
}

---@class (private) AutoFinderFilesState
local S = {
  bufnr = nil,     ---@type integer?
  winid = nil,     ---@type integer?
  model = nil,     ---@type AutoFinderFilesModel?
  rows = nil,      ---@type AutoFinderRow[]?   rows painted last
  items = {},      -- visible entries aligned with buffer lines
  shown = false,
  subs = nil,      -- shared.view_subs
  augroup = nil,
  timers = {},     -- name → uv timer
  repo_top = nil,  -- git toplevel of the root (nil = not a repo / unknown)
  git = {},        -- repo root → path → status (views/files/git.build)
  diag = {},       -- path → { severity_number, severity_string }
  marks = {},      -- path → "cut"|"copy"
  search = nil,    -- { term, model } while a search result is shown
  follow_seq = 0,
}
M._state = S

-- ── config ─────────────────────────────────────────────────────────────────────────────────────────
local function cfg()
  local ok, af = pcall(require, "auto-finder")
  local c = ok and af.state and af.state.config or {}
  return c.files or {}, c
end

local function show_hidden()
  local ok, core = pcall(require, "auto-core")
  if ok and core.files then return core.files.get_show_hidden() end
  return true
end

local function show_dotfiles()
  local ok, core = pcall(require, "auto-core")
  if ok and core.files then return core.files.get_show_dotfiles() end
  return true
end

-- ── timers ─────────────────────────────────────────────────────────────────────────────────────────
local function after(name, ms, fn)
  local t = S.timers[name]
  if not t then
    t = vim.uv.new_timer()
    S.timers[name] = t
  end
  t:stop()
  t:start(ms, 0, vim.schedule_wrap(fn))
end

local function stop_timers()
  for name, t in pairs(S.timers) do
    pcall(t.stop, t); pcall(t.close, t)
    S.timers[name] = nil
  end
end

-- ── diagnostics (the retired fork's get_diagnostic_counts) ────────────────────────────────────────
local SEV = { "Error", "Warn", "Info", "Hint" }
local function compute_diag()
  local lookup = {}
  for ns in pairs(vim.diagnostic.get_namespaces()) do
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" and vim.diagnostic.is_enabled({ bufnr = b, ns_id = ns }) then
        for sev = 1, 4 do
          if #vim.diagnostic.get(b, { namespace = ns, severity = sev }) > 0 then
            local e = lookup[name]
            if not e or sev < e.severity_number then
              lookup[name] = { severity_number = sev, severity_string = SEV[sev] }
            end
          end
        end
      end
    end
  end
  -- bubble to parent directories
  local files = vim.tbl_keys(lookup)
  for _, f in ipairs(files) do
    local e = lookup[f]
    local parent = vim.fs.dirname(f)
    while parent and parent ~= "/" and parent ~= "." do
      local pe = lookup[parent]
      if not pe or e.severity_number < pe.severity_number then
        lookup[parent] = { severity_number = e.severity_number, severity_string = e.severity_string }
      end
      local up = vim.fs.dirname(parent)
      if up == parent then break end
      parent = up
    end
  end
  S.diag = lookup
end

-- ── painting ───────────────────────────────────────────────────────────────────────────────────────
local function current_model() return S.search and S.search.model or S.model end

local function repo_for(model, path)
  local p = path
  while p and #p >= #model.root do
    local n = model.nodes[p]
    if n and n.repo_root and S.git[p] then return p end
    if p == model.root then break end
    p = vim.fs.dirname(p)
  end
  if S.repo_top and S.git[S.repo_top] then return S.repo_top end
  return nil
end

local function git_code(model, path)
  local repo = repo_for(model, path)
  if not repo then return nil end
  return gitc.lookup(S.git[repo], repo, path)
end

local function root_label(model)
  local label = vim.fn.fnamemodify(model.root, ":~") .. "  ▲"
  if S.search then label = ('Find "%s" in '):format(S.search.term) .. label end
  return label
end

local function item_for(model, v)
  local n = v.node
  local it = {
    kind = v.depth == 0 and "root" or n.type,
    name = v.depth == 0 and root_label(model) or n.name,
    depth = v.depth, is_last = v.is_last, continues = v.continues,
    expanded = n.expanded, mark = S.marks[n.path],
  }
  if n.type == "directory" and v.depth > 0 then
    it.empty = n.children ~= nil and #n.children == 0
  end
  if v.depth > 0 then
    it.git = git_code(model, n.path)
    local d = S.diag[n.path]
    if d then
      if n.type == "directory" then
        if not n.expanded and d.severity_number == 1 then it.diag = d.severity_string end
      else
        it.diag = d.severity_string
      end
    end
  end
  return it
end

local function auto_expand(rows)
  local win = S.winid
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  local af = require("auto-finder")
  if af.state.user_width and af.state.user_width > 0 then return end
  local _, top = cfg()
  local max = top.width and top.width.max or 100
  local want = 0
  for _, r in ipairs(rows) do if r.width > want then want = r.width end end
  local info = vim.fn.getwininfo(win)[1]
  want = math.min(want + (info and info.textoff or 0), max)
  if want > vim.api.nvim_win_get_width(win) then pcall(vim.api.nvim_win_set_width, win, want) end
end

---Repaint from the current model. Only changed lines are written (render.paint).
function M.paint()
  local b = S.bufnr
  if not (b and vim.api.nvim_buf_is_valid(b)) then return end
  local model = current_model()
  if not model then return end
  local width = (S.winid and vim.api.nvim_win_is_valid(S.winid)) and vim.api.nvim_win_get_width(S.winid) or 38
  local visible = model_mod.visible(model)
  local rows = {}
  for i, v in ipairs(visible) do rows[i] = render.row(item_for(model, v), width) end
  local first, last = render.paint(b, S.rows, rows)
  S.rows, S.items = rows, visible
  auto_expand(rows)
  if first then
    -- a width change re-positions every right-aligned sign
    local w2 = (S.winid and vim.api.nvim_win_is_valid(S.winid)) and vim.api.nvim_win_get_width(S.winid) or width
    if w2 ~= width then
      local rows2 = {}
      for i, v in ipairs(visible) do rows2[i] = render.row(item_for(model, v), w2) end
      render.paint(b, S.rows, rows2)
      S.rows = rows2
    end
  end
  return first, last
end

-- ── git ────────────────────────────────────────────────────────────────────────────────────────────
local function apply_hidden()
  if not S.model then return end
  if show_hidden() then
    S.model.hidden = nil
    return
  end
  local hidden = {}
  for repo, status in pairs(S.git) do
    for path, s in pairs(status) do
      if s == "!" then hidden[path] = true end
    end
    local _ = repo
  end
  S.model.hidden = hidden
end

function M.git_refresh()
  if not S.shown or not S.model then return end
  local model, token = S.model, S.model.token
  local repos = {}
  if S.repo_top then repos[S.repo_top] = true end
  for _, dir in ipairs(model_mod.expanded_dirs(model)) do
    local n = model.nodes[dir]
    if n and n.repo_root then repos[dir] = true end
  end
  local status = require("auto-core.git.status")
  for repo in pairs(repos) do
    status.get_async(repo, { ignored = true }, function(entries)
      if not rawequal(token, model.token) or not S.shown then return end
      S.git[repo] = entries and gitc.build(entries, repo) or nil
      apply_hidden()
      M.paint()
    end)
  end
end

local function git_schedule() after("git", 300, M.git_refresh) end

local function resolve_repo_top(model)
  local token = model.token
  vim.system({ "git", "--no-optional-locks", "-C", model.root, "rev-parse", "--show-toplevel" }, { text = true },
    function(r)
      vim.schedule(function()
        if not rawequal(token, model.token) then return end
        S.repo_top = r.code == 0 and vim.trim(r.stdout or "") or nil
        git_schedule()
      end)
    end)
end

-- ── watches ────────────────────────────────────────────────────────────────────────────────────────
local function arm(node)
  if node.watch or node.type ~= "directory" or not S.shown then return end
  node.watch = require("auto-core.fs.watch").start(node.path, { recursive = false, self_extend = false })
end

local function disarm(node)
  if node.watch then
    pcall(require("auto-core.fs.watch").stop, node.watch)
    node.watch = nil
  end
end

local function disarm_all(model)
  if not model then return end
  for _, n in pairs(model.nodes) do disarm(n) end
end

---Number of watch handles the view holds (tests, benchmark).
function M.watch_count()
  local n = 0
  if S.model then
    for _, node in pairs(S.model.nodes) do if node.watch then n = n + 1 end end
  end
  return n
end

-- ── reads ──────────────────────────────────────────────────────────────────────────────────────────
local function read_then_paint(path, fresh, cb)
  local model = S.model
  model_mod.read(model, path, fresh, function(changed)
    if changed then
      -- newly listed children may be expanded directories (re-root restores nothing; a read of a known
      -- dir keeps its children's expansion), so arm whatever is expanded and shown
      for _, d in ipairs(model_mod.expanded_dirs(model)) do arm(model.nodes[d]) end
      M.paint()
    end
    if cb then cb(changed) end
  end)
end

local pending_reads = {}
local function schedule_read(path)
  pending_reads[path] = true
  after("read", 100, function()
    local paths = pending_reads
    pending_reads = {}
    for p in pairs(paths) do
      local n = S.model and S.model.nodes[p]
      if n and n.expanded and n.children then read_then_paint(p, true) end
    end
  end)
end

-- ── lifecycle ──────────────────────────────────────────────────────────────────────────────────────
local function new_model(root)
  local c = cfg()
  S.model = model_mod.new(root, { never_show = c.never_show, show_dotfiles = show_dotfiles() })
  S.git, S.repo_top, S.rows, S.search = {}, nil, nil, nil
end

local subscribe -- forward

---Suspend all work. Idempotent. The model and buffer survive.
function M.suspend()
  if not S.shown and not S.subs then return end
  S.shown = false
  if S.model and S.model.token then
    require("auto-core.fs.scan").cancel(S.model.token)
    S.model.token = nil
  end
  if S.search then require("auto-finder.views.files.search").cancel() end
  disarm_all(S.model)
  if S.subs then pcall(function() S.subs:dispose_all() end) end
  if S.augroup then pcall(vim.api.nvim_del_augroup_by_id, S.augroup); S.augroup = nil end
  stop_timers()
  pending_reads = {}
end

---Resume on show: token, subscriptions, watches, then a re-read of every expanded directory.
function M.resume(panel_winid)
  S.winid = panel_winid
  if not S.model or S.model.root ~= vim.fn.getcwd() then
    if S.model then disarm_all(S.model) end
    new_model(vim.fn.getcwd())
  end
  if S.shown then return end
  S.shown = true
  S.model.token = {}
  subscribe()
  local dirs = model_mod.expanded_dirs(S.model)
  for _, d in ipairs(dirs) do arm(S.model.nodes[d]) end
  for _, d in ipairs(dirs) do read_then_paint(d, true) end
  compute_diag()
  resolve_repo_top(S.model)
  M.paint()
end

---Re-root at `root` (worktree switch, :cd).
function M.reroot(root)
  if S.model and S.model.root == root then return end
  if S.model and S.model.token then require("auto-core.fs.scan").cancel(S.model.token) end
  disarm_all(S.model)
  new_model(root)
  if S.shown then
    S.model.token = {}
    arm(S.model.nodes[root])
    read_then_paint(root, true)
    resolve_repo_top(S.model)
  end
  M.paint()
end

-- ── follow ─────────────────────────────────────────────────────────────────────────────────────────
local function set_cursor_to(path)
  if not (S.winid and vim.api.nvim_win_is_valid(S.winid)) then return end
  for i, v in ipairs(S.items) do
    if v.node.path == path then
      pcall(vim.api.nvim_win_set_cursor, S.winid, { i, 0 })
      return true
    end
  end
end

local function follow(buf)
  local c = cfg()
  if c.follow == false or not S.shown or S.search then return end
  local views = require("auto-finder.views")
  if views.active() ~= "files" then return end
  if vim.bo[buf].buftype ~= "" then return end
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" or not vim.startswith(path, S.model.root .. "/") then return end
  S.follow_seq = S.follow_seq + 1
  local seq = S.follow_seq
  model_mod.reveal(S.model, path, function(found)
    if seq ~= S.follow_seq or not found then return end
    for _, d in ipairs(model_mod.expanded_dirs(S.model)) do arm(S.model.nodes[d]) end
    M.paint()
    set_cursor_to(path)
  end)
end

-- ── subscriptions ──────────────────────────────────────────────────────────────────────────────────
subscribe = function()
  local view_subs = require("auto-finder.shared.view_subs")
  S.subs = S.subs or view_subs.new()
  S.subs:replace("files-fs", "core.file:*", function(payload)
    if type(payload) ~= "table" or type(payload.path) ~= "string" or not S.model then return end
    local parent = vim.fs.dirname(payload.path)
    local dir = S.model.nodes[parent]
    if not dir then return end
    if payload.change == "modified" and S.model.nodes[payload.path] then
      git_schedule()
      return
    end
    if dir.expanded and dir.children then
      schedule_read(parent)
    elseif dir.children then
      dir.stale = true
    end
    git_schedule()
  end)
  S.subs:replace("files-dirty", "core.fs.dir:dirty", function(payload)
    if type(payload) ~= "table" or not S.model then return end
    local dir = S.model.nodes[payload.path]
    if dir and dir.expanded and dir.children then schedule_read(payload.path) end
  end)
  S.subs:replace("files-git", "core.git.state:changed", function() git_schedule() end)
  S.subs:replace("files-worktree", "worktree:switched", function()
    vim.schedule(function() M.reroot(vim.fn.getcwd()) end)
  end)
  local ok, core = pcall(require, "auto-core")
  if ok and core.files then
    S.subs:replace("files-hidden", "state.core:files.show_hidden:changed", function()
      apply_hidden(); M.paint()
    end)
    S.subs:replace("files-dotfiles", "state.core:files.show_dotfiles:changed", function()
      if not S.model then return end
      S.model.show_dotfiles = show_dotfiles()
      for _, d in ipairs(model_mod.expanded_dirs(S.model)) do read_then_paint(d, true) end
    end)
  end

  S.augroup = vim.api.nvim_create_augroup("auto-finder.files.view", { clear = true })
  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group = S.augroup,
    callback = function() after("diag", 200, function() compute_diag(); M.paint() end) end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = S.augroup,
    callback = function(ev)
      local path = vim.api.nvim_buf_get_name(ev.buf)
      local parent = vim.fs.dirname(path)
      if S.model and not S.model.nodes[path] and S.model.nodes[parent] and S.model.nodes[parent].expanded then
        schedule_read(parent)
      end
      git_schedule()
    end,
  })
  vim.api.nvim_create_autocmd("FocusGained", { group = S.augroup, callback = git_schedule })
  vim.api.nvim_create_autocmd("DirChanged", {
    group = S.augroup,
    callback = function() vim.schedule(function() M.reroot(vim.fn.getcwd()) end) end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = S.augroup,
    callback = function(ev) after("follow", 60, function() if vim.api.nvim_buf_is_valid(ev.buf) then follow(ev.buf) end end) end,
  })
  vim.api.nvim_create_autocmd("WinResized", {
    group = S.augroup,
    callback = function() if S.winid and vim.tbl_contains(vim.v.event.windows or {}, S.winid) then M.paint() end end,
  })
end

-- ── cursor & actions ───────────────────────────────────────────────────────────────────────────────
local function node_under_cursor()
  if not (S.winid and vim.api.nvim_win_is_valid(S.winid)) then return nil end
  local line = vim.api.nvim_win_get_cursor(S.winid)[1]
  local v = S.items[line]
  return v and v.node
end

local function target_dir(node)
  if not node then return S.model.root end
  if node.type == "directory" then return node.path end
  return vim.fs.dirname(node.path)
end

local function toggle(node)
  local model = current_model()
  if node.type ~= "directory" or node.path == model.root then return end
  if node.expanded then
    model_mod.collapse(model, node.path)
    for _, d in pairs(model.nodes) do
      if d.watch and not vim.tbl_contains(model_mod.expanded_dirs(model), d.path) then disarm(d) end
    end
    M.paint()
  else
    model_mod.expand(model, node.path, function()
      if model == S.model then arm(node) end
      M.paint()
    end)
    M.paint()
  end
end

local function open(cmd)
  local node = node_under_cursor()
  if not node then return end
  if node.type == "directory" then return toggle(node) end
  local af = require("auto-finder")
  local target = af._editor_target_winid()
  if target then
    pcall(vim.api.nvim_set_current_win, target)
    pcall(vim.cmd, (cmd or "edit") .. " " .. vim.fn.fnameescape(node.path))
  else
    pcall(vim.cmd, "rightbelow vsplit " .. vim.fn.fnameescape(node.path))
  end
end

local function action_ctx(node)
  return {
    root = S.model.root,
    node = node,
    dir = target_dir(node),
    done = function(dirs, focus)
      if S.search then M.clear_search() end
      local pending = #dirs
      local function finished()
        pending = pending - 1
        if pending > 0 then return end
        if focus then
          model_mod.reveal(S.model, focus, function()
            M.paint()
            set_cursor_to(focus)
          end)
        else
          M.paint()
        end
        git_schedule()
      end
      if pending == 0 then pending = 1; return finished() end
      for _, d in ipairs(dirs) do
        local n = S.model.nodes[d]
        if n and n.children then
          if not n.expanded and d == target_dir(node) then n.expanded = true; arm(n) end
          read_then_paint(d, true, finished)
        else
          finished()
        end
      end
    end,
  }
end

local function with_node(fn)
  return function()
    local node = node_under_cursor()
    if node then fn(node) end
  end
end

local function mark(op)
  return with_node(function(node)
    if node.path == S.model.root then return end
    S.marks[node.path] = S.marks[node.path] ~= op and op or nil
    M.paint()
  end)
end

function M.clear_search()
  if not S.search then return end
  require("auto-finder.views.files.search").cancel()
  S.search = nil
  S.rows = S.rows -- the diff against the search rows repaints only what differs
  M.paint()
end

local function start_search()
  if not S.model then return end
  local search = require("auto-finder.views.files.search")
  local c = cfg()
  local function show(term, paths)
    local m = model_mod.new(S.model.root, { never_show = c.never_show, show_dotfiles = true })
    m.token = nil
    for _, p in ipairs(paths) do
      local rel = p:sub(#m.root + 2)
      local acc = m.root
      local segs = vim.split(rel, "/", { plain = true })
      for i, seg in ipairs(segs) do
        local path = acc .. "/" .. seg
        local parent = m.nodes[acc]
        parent.children = parent.children or {}
        if not m.nodes[path] then
          local is_dir = i < #segs or vim.fn.isdirectory(path) == 1
          m.nodes[path] = { path = path, name = seg, type = is_dir and "directory" or "file", parent = acc,
            expanded = i < #segs }
          table.insert(parent.children, path)
        end
        acc = path
      end
    end
    for _, n in pairs(m.nodes) do
      if n.children then
        table.sort(n.children, function(a, b) return model_mod._sort_nodes(m.nodes[a], m.nodes[b]) end)
      end
    end
    S.search = { term = term, model = m }
    M.paint()
  end
  search.prompt(S.winid, {
    on_term = function(term)
      if term == "" then return M.clear_search() end
      search.run(S.model.root, term, { never_show = c.never_show or model_mod.NEVER_SHOW, hidden = show_hidden() },
        function(paths) show(term, paths) end)
    end,
    on_close = function(keep) if not keep then M.clear_search() end end,
    move = function(d)
      if not (S.winid and vim.api.nvim_win_is_valid(S.winid)) then return end
      local line = vim.api.nvim_win_get_cursor(S.winid)[1]
      pcall(vim.api.nvim_win_set_cursor, S.winid, { math.max(1, math.min(#S.items, line + d)), 0 })
    end,
  })
end

local function collapse_node()
  local node = node_under_cursor()
  if not node then return end
  local model = current_model()
  local dir = (node.type == "directory" and node.expanded and node.path ~= model.root) and node
    or model.nodes[node.parent or ""]
  if dir and dir.path ~= model.root then
    toggle(dir)
    set_cursor_to(dir.path)
  end
end

local function collapse_all()
  local model = current_model()
  for _, n in pairs(model.nodes) do
    if n.type == "directory" and n.path ~= model.root and n.expanded then
      n.expanded = false
      disarm(n)
    end
  end
  M.paint()
end

local function refresh()
  if not S.model then return end
  for _, d in ipairs(model_mod.expanded_dirs(S.model)) do read_then_paint(d, true) end
  git_schedule()
end

local function toggle_hidden()
  local ok, core = pcall(require, "auto-core")
  if ok and core.files then core.files.set_show_hidden(not core.files.get_show_hidden()) end
end

---The kept keymaps (ADR-0200 §4.7). `cfg.files.mappings` adds or overrides: { [lhs] = name | fun | false }.
M.ACTIONS = {
  open = { function() open("edit") end, "open in editor / toggle directory" },
  open_split = { function() open("split") end, "open in a split" },
  open_vsplit = { function() open("vsplit") end, "open in a vertical split" },
  open_tabnew = { function() open("tabnew") end, "open in a new tab" },
  add = { with_node(function(n) require("auto-finder.views.files.actions").add(action_ctx(n)) end), "add file (end with / for a directory)" },
  add_directory = { with_node(function(n) require("auto-finder.views.files.actions").add_directory(action_ctx(n)) end), "add directory" },
  delete = { with_node(function(n) require("auto-finder.views.files.actions").delete(action_ctx(n)) end), "delete" },
  rename = { with_node(function(n) require("auto-finder.views.files.actions").rename(action_ctx(n)) end), "rename" },
  move = { with_node(function(n) require("auto-finder.views.files.actions").move(action_ctx(n)) end), "move" },
  copy_to_clipboard = { mark("copy"), "mark for copy" },
  cut_to_clipboard = { mark("cut"), "mark for cut (move)" },
  paste_from_clipboard = { with_node(function(n)
    require("auto-finder.views.files.actions").paste(action_ctx(n), S.marks)
  end), "paste marked items here" },
  search = { start_search, "search (filter as you type)" },
  clear_search = { M.clear_search, "clear search" },
  toggle_hidden = { toggle_hidden, "toggle hidden (gitignored) files" },
  close_node = { collapse_node, "collapse directory" },
  close_all_nodes = { collapse_all, "collapse all" },
  refresh = { refresh, "re-read expanded directories" },
  show_file_details = { with_node(function(n)
    local repo = repo_for(S.model, n.path)
    local raw = repo and S.git[repo] and S.git[repo][n.path] or nil
    require("auto-finder.views.files.actions").info(action_ctx(n), raw)
  end), "file details" },
}

M.DEFAULT_KEYS = {
  ["<cr>"] = "open", ["<2-LeftMouse>"] = "open", S = "open_split", s = "open_vsplit", t = "open_tabnew",
  a = "add", A = "add_directory", d = "delete", r = "rename", m = "move",
  y = "copy_to_clipboard", x = "cut_to_clipboard", p = "paste_from_clipboard",
  ["/"] = "search", ["<C-x>"] = "clear_search", H = "toggle_hidden",
  C = "close_node", z = "close_all_nodes", R = "refresh", i = "show_file_details",
}

local function apply_keymaps(b)
  local keys = vim.deepcopy(M.DEFAULT_KEYS)
  for lhs, v in pairs(cfg().mappings or {}) do keys[lhs] = v end
  for lhs, v in pairs(keys) do
    if v == false or v == "none" then
      pcall(vim.keymap.del, "n", lhs, { buffer = b })
    else
      local fn, desc
      if type(v) == "function" then fn, desc = v, "auto-finder.files: custom"
      elseif M.ACTIONS[v] then fn, desc = M.ACTIONS[v][1], "auto-finder.files: " .. M.ACTIONS[v][2] end
      if fn then vim.keymap.set("n", lhs, fn, { buffer = b, silent = true, nowait = true, desc = desc }) end
    end
  end
  require("auto-finder.shared.help").install_help_keymap("files", b)
end

-- ── section contract ───────────────────────────────────────────────────────────────────────────────
function M.get_buffer(panel_winid)
  require("auto-finder.panel.window_style").attach()
  if not (S.bufnr and vim.api.nvim_buf_is_valid(S.bufnr)) then
    local b = vim.api.nvim_create_buf(false, true)
    vim.bo[b].bufhidden = "hide"
    vim.bo[b].buftype = "nofile"
    vim.bo[b].swapfile = false
    vim.bo[b].modifiable = false
    vim.bo[b].filetype = "auto-finder"
    vim.b[b].auto_finder_view = "files"
    pcall(vim.api.nvim_buf_set_name, b, "auto-finder://files")
    vim.api.nvim_create_autocmd("BufHidden", { buffer = b, callback = function() M.suspend() end })
    S.bufnr, S.rows = b, nil
    apply_keymaps(b)
  end
  S.winid = panel_winid
  return S.bufnr
end

function M.on_focus(panel_winid, bufnr)
  if bufnr ~= S.bufnr then return end
  apply_keymaps(bufnr)
  M.resume(panel_winid)
end

function M.on_close()
  M.suspend()
end

---Test-only: forget everything, including the buffer.
function M._reset_for_tests()
  M.suspend()
  if S.bufnr and vim.api.nvim_buf_is_valid(S.bufnr) then pcall(vim.api.nvim_buf_delete, S.bufnr, { force = true }) end
  S.bufnr, S.winid, S.model, S.rows, S.items = nil, nil, nil, nil, {}
  S.git, S.diag, S.marks, S.search, S.subs, S.repo_top = {}, {}, {}, nil, nil, nil
end

return M
