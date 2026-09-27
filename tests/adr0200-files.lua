-- tests/adr0200-files.lua — the rebuilt files slot's behaviour (ADR-0200 §5 cells 2-4, 6-9).
--
-- Run: nvim --headless -u NONE -l tests/adr0200-files.lua   (on VM43, per vm43-layout)
--
-- Every cell counts the WORK it is about — directory reads (a spy on auto-core.fs.scan.read_dir),
-- git subprocesses (a spy on auto-core.git.status.get_async), watch handles held — and every "zero"
-- claim is preceded by a precondition proving the counter moves when work does happen.

local plugin_root = vim.fn.fnamemodify(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
local plugins_root = vim.fn.fnamemodify(plugin_root, ":h:h")
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
for _, p in ipairs({
  LAZY .. "/auto-core.nvim",
  LAZY .. "/worktree.nvim",
  plugins_root .. "/worktree.nvim/main",
  plugins_root .. "/auto-core.nvim/main",
  plugins_root .. "/auto-core.nvim/" .. vim.fn.fnamemodify(plugin_root, ":t"),
  plugin_root,
}) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end
local SANDBOX = dofile(plugin_root .. "/tests/_sandbox.lua")("adr0200-files")
vim.o.columns, vim.o.lines, vim.o.swapfile, vim.o.hidden = 200, 60, false, true
vim.env.AUTO_FINDER_DBASE_DISABLE_CRYPTO = "1"

local pass, fail = 0, 0
local function ok(name, cond, detail)
  print((cond and "  PASS  " or "  FAIL  ") .. name .. ((not cond and detail ~= nil) and ("  — " .. tostring(detail)) or ""))
  if cond then pass = pass + 1 else fail = fail + 1 end
end
local function section(title, fn)
  print("\n" .. title)
  local okr, err = xpcall(fn, debug.traceback)
  if not okr then fail = fail + 1; print("  FAIL  [ABORTED] " .. tostring(err)) end
end
local function wait(pred, ms) return vim.wait(ms or 2000, pred, 10) end

print("[0] provenance")
ok("auto-core.fs.scan is on the runtimepath", pcall(require, "auto-core.fs.scan"))
ok("the loaded files view is this worktree's",
  vim.startswith(vim.api.nvim_get_runtime_file("lua/auto-finder/views/files/init.lua", false)[1] or "", plugin_root))

-- ── fixture ────────────────────────────────────────────────────────────────────────────────────────
local ROOT = vim.fn.tempname() .. "-adr0200-files"
local function mk(rel, body)
  local p = ROOT .. "/" .. rel
  vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
  if body ~= false then vim.fn.writefile({ body or rel }, p) end
  return p
end
local function git(dir, ...)
  return vim.system({ "git", "-C", dir, ... }, { text = true }):wait()
end
mk("a/one.txt"); mk("a/deep/two.txt"); mk("b/three.txt"); mk("c/four.txt"); mk("top.txt"); mk(".hidden")
mk("wide/.keep"); mk("f1/f2/leaf.txt"); mk("build/out.txt")
for i = 1, 20000 do vim.uv.fs_close(vim.uv.fs_open(ROOT .. "/wide/f" .. i, "w", 420)) end
git(ROOT, "init", "-q", "-b", "main"); git(ROOT, "config", "user.email", "t@example.invalid"); git(ROOT, "config", "user.name", "t")
vim.fn.writefile({ "ignored_dir/" }, ROOT .. "/.gitignore")
mk("ignored_dir/x.txt")
git(ROOT, "add", "-A"); git(ROOT, "commit", "-q", "-m", "init")
mk("untracked_dir/u.txt")             -- untracked directory: `?? untracked_dir/`
-- a nested repo: the outer repo reports `?? nested/`; the nested repo's own read reports inner.txt modified,
-- so the colour tells which read answered
mk("nested/inner.txt")
git(ROOT .. "/nested", "init", "-q", "-b", "main")
git(ROOT .. "/nested", "config", "user.email", "t@example.invalid"); git(ROOT .. "/nested", "config", "user.name", "t")
git(ROOT .. "/nested", "add", "-A"); git(ROOT .. "/nested", "commit", "-q", "-m", "init")
vim.fn.writefile({ "changed" }, ROOT .. "/nested/inner.txt")
vim.cmd.cd(ROOT)
ROOT = vim.fn.getcwd()

-- ── spies ──────────────────────────────────────────────────────────────────────────────────────────
local scan = require("auto-core.fs.scan")
local status = require("auto-core.git.status")
local real_read, real_status = scan.read_dir, status.get_async
local READS, STATUS = {}, {}
scan.read_dir = function(path, ...) READS[#READS + 1] = path; return real_read(path, ...) end
status.get_async = function(root, opts, cb) STATUS[#STATUS + 1] = root; return real_status(root, opts, cb) end
local function reset_counts() READS, STATUS = {}, {} end
local function reads_of(p) local n = 0; for _, r in ipairs(READS) do if r == p then n = n + 1 end end; return n end

local af = require("auto-finder")
af.setup({ width = { default = 38, min = 25, max = 100 }, default_section = 1, sections = { "config", "files" } })
af.open(true)
af.focus(1)
local fview = require("auto-finder.views.files")
local model_mod = require("auto-finder.views.files.model")
local S = fview._state
wait(function() return S.shown and S.model and S.model.nodes[ROOT] and S.model.nodes[ROOT].children ~= nil end, 3000)

local function visible_paths()
  local t = {}
  for _, v in ipairs(S.items) do t[v.node.path] = true end
  return t
end
local function cursor_to(path)
  for i, v in ipairs(S.items) do
    if v.node.path == path then vim.api.nvim_win_set_cursor(S.winid, { i, 0 }); return true end
  end
  error("not a visible row: " .. path)
end
-- expand / collapse through the view's own <cr> toggle, so watches follow exactly as they do for a user
local function expand(rel)
  local path = ROOT .. "/" .. rel
  if S.model.nodes[path] and S.model.nodes[path].expanded then return end
  cursor_to(path); fview.ACTIONS.open[1]()
  wait(function() local n = S.model.nodes[path]; return n and n.children ~= nil and visible_paths()[path] end)
end
local function collapse(rel)
  local path = ROOT .. "/" .. rel
  if not S.model.nodes[path].expanded then return end
  cursor_to(path); fview.ACTIONS.open[1]()
end
local function reads_done() return scan.stats().reads end

section("[2] a hidden pane does nothing; the next show catches up", function()
  expand("a"); expand("b")
  reset_counts()
  vim.fn.writefile({ "x" }, ROOT .. "/a/probe-while-shown.txt")
  wait(function() return reads_of(ROOT .. "/a") > 0 end, 2000)
  ok("precondition: while shown, a create in an expanded dir reads that dir", reads_of(ROOT .. "/a") >= 1,
    vim.inspect(READS))
  ok("precondition: while shown, watches are held", fview.watch_count() >= 3, fview.watch_count())
  wait(function() return fview.git_watch_count() >= 1 end)
  ok("precondition: while shown, the repo's git watch is held", fview.git_watch_count() >= 1, fview.git_watch_count())
  af.close()
  ok("after close: the view is suspended", S.shown == false)
  ok("after close: zero directory watches held", fview.watch_count() == 0, fview.watch_count())
  ok("after close: zero git watches held", fview.git_watch_count() == 0, fview.git_watch_count())
  vim.wait(400)
  reset_counts()
  for i = 1, 30 do vim.fn.writefile({ "x" }, ROOT .. "/a/burst" .. i .. ".txt") end
  vim.fn.writefile({ "x" }, ROOT .. "/b/while-hidden.txt")
  vim.wait(1200)
  ok("while hidden: zero directory reads across a burst of 31 writes", #READS == 0, vim.inspect(READS))
  ok("while hidden: zero git status reads", #STATUS == 0, vim.inspect(STATUS))
  -- the view's own subscriptions, not only the released watches: core events reaching a hidden view
  local events = require("auto-core.events")
  events.publish("auto-finder.core.files:changed", { kind = "created", path = ROOT .. "/a/x", dir = ROOT .. "/a" })
  events.publish("auto-finder.core.git:changed", { repo_root = ROOT, kind = "index" })
  vim.wait(900)
  ok("while hidden: core files/git events cost zero reads and zero git status reads", #READS == 0 and #STATUS == 0,
    vim.inspect({ READS, STATUS }))
  ok("while hidden: the view scheduled no timer (its subscriptions and autocmds are gone)",
    next(S.timers) == nil, vim.inspect(vim.tbl_keys(S.timers)))
  af.open(true); af.focus(1)
  wait(function() return S.shown and visible_paths()[ROOT .. "/b/while-hidden.txt"] end, 3000)
  local exp = model_mod.expanded_dirs(S.model)
  local extra = 0
  for _, d in ipairs(exp) do if reads_of(d) > 1 then extra = extra + 1 end end
  ok("show: each expanded directory re-read once", extra == 0 and reads_of(ROOT) >= 1, vim.inspect(READS))
  ok("show: the changes made while hidden appear", visible_paths()[ROOT .. "/b/while-hidden.txt"] == true
    and visible_paths()[ROOT .. "/a/burst30.txt"] == true)
  local collapsed = 0
  for _, r in ipairs(READS) do if r == ROOT .. "/c" then collapsed = collapsed + 1 end end
  ok("show: a collapsed directory is not read", collapsed == 0)
end)

section("[3] hide and re-root during an in-flight read make it inert", function()
  -- a wide directory's read spans many ticks; hide while it runs
  local node = S.model.nodes[ROOT .. "/wide"]
  ok("precondition: the wide dir has not been read", node and node.children == nil)
  local fired = false
  local t = vim.uv.new_timer()
  t:start(0, 1, vim.schedule_wrap(function()
    local st = scan.stats()
    if not fired and st.inflight > 0 then
      fired = true; t:stop(); t:close()
      af.close()
    end
  end))
  model_mod.expand(S.model, ROOT .. "/wide", function() end)
  wait(function() return fired end, 3000)
  wait(function() return scan.stats().slots == 0 end, 10000)
  ok("precondition: the hide happened mid-read", fired)
  ok("the cancelled read never reached the model", S.model.nodes[ROOT .. "/wide"].children == nil)
  ok("no scanner slot left behind", scan.stats().slots == 0, vim.inspect(scan.stats()))
  af.open(true); af.focus(1)
  wait(function() return S.shown end)
  -- re-root while a read is in flight: the old model's callback must not land in the new one
  local old_model = S.model
  local other = vim.fn.tempname() .. "-reroot"
  vim.fn.mkdir(other, "p"); vim.fn.writefile({ "x" }, other .. "/only-here.txt")
  local flip = false
  local t2 = vim.uv.new_timer()
  t2:start(0, 1, vim.schedule_wrap(function()
    if not flip and scan.stats().inflight > 0 then
      flip = true; t2:stop(); t2:close()
      fview.reroot(other)
    end
  end))
  model_mod.expand(old_model, ROOT .. "/wide", function() end)
  wait(function() return flip end, 3000)
  wait(function() return scan.stats().slots == 0 end, 10000)
  ok("precondition: the re-root happened mid-read", flip and S.model ~= old_model)
  ok("the old model's read did not apply after the re-root", old_model.nodes[ROOT .. "/wide"].children == nil)
  wait(function() return visible_paths()[other .. "/only-here.txt"] end)
  ok("the new root is listed", visible_paths()[other .. "/only-here.txt"] == true)
  fview.reroot(ROOT)
  wait(function() return S.model.nodes[ROOT].children ~= nil end)
end)

section("[4] a toggle storm costs reads bounded by the expanded set, never a collapsed dir", function()
  expand("a"); expand("b")
  local E = #model_mod.expanded_dirs(S.model)
  vim.wait(400)
  reset_counts()
  local r0 = reads_done()
  local spawns = 0
  local real_system = vim.system
  vim.system = function(cmd, ...)
    if type(cmd) == "table" and cmd[1] == "git" then spawns = spawns + 1 end
    return real_system(cmd, ...)
  end
  local t0 = vim.uv.now()
  for _ = 1, 20 do af.close(); af.open(true); af.focus(1); vim.wait(80) end
  local dur = vim.uv.now() - t0
  vim.wait(600)
  vim.system = real_system
  ok(("20 toggles spawn at most 3 git subprocesses (%d): the toplevel is resolved once per root, and a "
    .. "status read waits for the pane to settle"):format(spawns), spawns <= 3, spawns)
  local performed = reads_done() - r0
  local bound = E * (math.ceil(dur / scan.MIN_INTERVAL_MS) + 1)
  ok(("20 toggles: performed reads (%d) ≤ E × (ceil(duration / interval) + 1) = %d (E=%d, %dms)")
    :format(performed, bound, E, dur), performed <= bound and performed > 0)
  ok(("…fewer than one per toggle per dir (%d requests coalesced into %d reads)"):format(#READS, performed),
    performed < 20 * E)
  local bad = {}
  for _, r in ipairs(READS) do
    local n = S.model.nodes[r]
    if not (n and n.expanded) then bad[#bad + 1] = r end
  end
  ok("no read of a collapsed or unexpanded directory", #bad == 0, vim.inspect(bad))
end)

section("[6] the watch set equals the expanded set", function()
  local function expanded_n() return #model_mod.expanded_dirs(S.model) end
  expand("a/deep")
  ok("after expand: watches == expanded dirs", fview.watch_count() == expanded_n(),
    fview.watch_count() .. " vs " .. expanded_n())
  collapse("a/deep")
  ok("after collapse: watches == expanded dirs", fview.watch_count() == expanded_n(),
    fview.watch_count() .. " vs " .. expanded_n())
  af.close()
  ok("hidden: zero watches", fview.watch_count() == 0)
  af.open(true); af.focus(1)
  wait(function() return S.shown end)
  ok("shown again: watches == expanded dirs", fview.watch_count() == expanded_n(),
    fview.watch_count() .. " vs " .. expanded_n())
end)

section("[7] live updates read only the directory they name", function()
  reset_counts()
  vim.fn.writefile({ "x" }, ROOT .. "/b/live-new.txt")
  wait(function() return visible_paths()[ROOT .. "/b/live-new.txt"] end, 1500)
  ok("a create in an expanded dir appears within 1.5 s", visible_paths()[ROOT .. "/b/live-new.txt"] == true)
  ok("…reading that directory and no other", reads_of(ROOT .. "/b") >= 1 and #READS == reads_of(ROOT .. "/b"),
    vim.inspect(READS))
  reset_counts()
  vim.fn.delete(ROOT .. "/b/live-new.txt")
  wait(function() return not visible_paths()[ROOT .. "/b/live-new.txt"] end, 1500)
  ok("a delete disappears", not visible_paths()[ROOT .. "/b/live-new.txt"])
  local deep = S.model.nodes[ROOT .. "/a/deep"]
  ok("precondition: a/deep is collapsed but was read", not deep.expanded and deep.children ~= nil)
  reset_counts()
  require("auto-core.events").publish("auto-finder.core.files:changed",
    { kind = "created", path = ROOT .. "/a/deep/new", dir = ROOT .. "/a/deep" })
  vim.wait(500)
  ok("an event naming a collapsed, read directory reads nothing and marks it stale",
    #READS == 0 and deep.stale == true, vim.inspect({ READS, deep.stale }))
  reset_counts()
  vim.fn.writefile({ "x" }, ROOT .. "/c/in-collapsed.txt")
  vim.wait(800)
  ok("a create in a collapsed directory reads nothing", #READS == 0, vim.inspect(READS))
  expand("c")
  ok("…and shows once the directory is expanded", visible_paths()[ROOT .. "/c/in-collapsed.txt"] == true)
  reset_counts()
  require("auto-core.events").publish("core.fs.dir:dirty", { path = ROOT .. "/b", reason = "unnamed" })
  wait(function() return reads_of(ROOT .. "/b") > 0 end, 1500)
  ok("a nameless (dirty) event re-reads the directory", reads_of(ROOT .. "/b") >= 1, vim.inspect(READS))
end)

section("[7b] a directory named like build output still updates live", function()
  -- auto-core.fs.watch's default ignore list (/build/, /dist/, /target/, …) is matched against the full
  -- path; a directory the user expanded must not inherit it
  expand("build")
  reset_counts()
  vim.fn.writefile({ "x" }, ROOT .. "/build/fresh.txt")
  wait(function() return visible_paths()[ROOT .. "/build/fresh.txt"] end, 1500)
  ok("a create in an expanded build/ appears", visible_paths()[ROOT .. "/build/fresh.txt"] == true,
    vim.inspect(READS))
end)

section("[8] git colours", function()
  wait(function() return S.git[S.repo_top or ""] ~= nil end, 3000)
  ok("precondition: the repo's status was read", S.repo_top == ROOT and S.git[ROOT] ~= nil, tostring(S.repo_top))
  vim.wait(400)
  reset_counts()
  for i = 1, 10 do vim.fn.writefile({ "x" }, ROOT .. "/a/g" .. i .. ".txt") end
  vim.wait(1200)
  local for_root = 0
  for _, r in ipairs(STATUS) do if r == ROOT then for_root = for_root + 1 end end
  ok(("a settled burst of 10 writes costs few status reads (%d)"):format(for_root), for_root >= 1 and for_root <= 2,
    vim.inspect(STATUS))
  expand("untracked_dir"); expand("nested")
  wait(function() return S.git[ROOT .. "/nested"] ~= nil end, 3000)
  fview.paint()
  local codes = {}
  for i, v in ipairs(S.items) do
    for _, sp in ipairs(S.rows[i].spans) do
      if sp[3]:match("^AutoFinderGit") then codes[v.node.path] = sp[3] end
    end
  end
  ok("a clean file beside untracked siblings is NOT coloured untracked (a bubbled code is not a record)",
    codes[ROOT .. "/a/one.txt"] == nil, tostring(codes[ROOT .. "/a/one.txt"]))
  ok("…while its directory carries the bubbled untracked colour", codes[ROOT .. "/a"] == "AutoFinderGitUntracked",
    tostring(codes[ROOT .. "/a"]))
  ok("a file inside an untracked directory is coloured by the directory's record",
    codes[ROOT .. "/untracked_dir/u.txt"] == "AutoFinderGitUntracked", vim.inspect(codes))
  ok("a nested repo gets its own status read", S.git[ROOT .. "/nested"] ~= nil)
  ok("precondition: the outer repo reports the nested repo as untracked",
    S.git[ROOT][ROOT .. "/nested"] == "??", tostring(S.git[ROOT][ROOT .. "/nested"]))
  ok("a nested repo's file is answered by the nested repo's read (modified, not the outer `??`)",
    codes[ROOT .. "/nested/inner.txt"] == "AutoFinderGitModified", vim.inspect(codes))
  reset_counts()
  require("auto-core.events").publish("core.git.state:changed", { repo_root = ROOT, git_dir = ROOT .. "/.git", kind = "index" })
  vim.wait(900)
  ok("a git-state event reads no directory", #READS == 0, vim.inspect(READS))

  -- an external commit touches only .git/ (no working-tree event): the view's own git watch must see it
  vim.wait(400)
  reset_counts()
  git(ROOT, "add", "a/g1.txt"); git(ROOT, "commit", "-q", "-m", "g1")
  wait(function()
    for _, r in ipairs(STATUS) do if r == ROOT then return true end end
  end, 3000)
  local reread = false
  for _, r in ipairs(STATUS) do if r == ROOT then reread = true end end
  ok("an external `git commit` (no file event) re-reads the repo's status", reread, vim.inspect(STATUS))
  wait(function() return S.git[ROOT] and S.git[ROOT][ROOT .. "/a/g1.txt"] == nil end, 1500)
  ok("…and the committed file loses its untracked colour", S.git[ROOT] and S.git[ROOT][ROOT .. "/a/g1.txt"] == nil)
end)

section("[9] keymaps: kept keys act, dropped keys are unmapped", function()
  local b = S.bufnr
  local function mapped(lhs)
    local m = vim.api.nvim_buf_call(b, function() return vim.fn.maparg(lhs, "n", false, true) end)
    if type(m) == "table" and m.buffer == 1 then return m end
  end
  for lhs in pairs(fview.DEFAULT_KEYS) do
    local m = mapped(lhs)
    ok("kept key mapped with a description: " .. lhs, m ~= nil and (m.desc or "") ~= "", m and m.desc)
  end
  for _, lhs in ipairs({ "P", "w", "O", "D", "#", "f", ".", "b", "c", "<C-r>", "e", "<", ">" }) do
    ok("dropped key unmapped: " .. lhs, mapped(lhs) == nil)
  end
  ok("? opens help", mapped("?") ~= nil)

  local real_input = vim.ui.input
  local answer
  vim.ui.input = function(_, cb) cb(answer) end
  -- a: add a file under the directory at the cursor
  cursor_to(ROOT .. "/b"); answer = "added.txt"
  fview.ACTIONS.add[1]()
  wait(function() return visible_paths()[ROOT .. "/b/added.txt"] end)
  ok("a: adds a file (and shows it)", vim.uv.fs_stat(ROOT .. "/b/added.txt") ~= nil
    and visible_paths()[ROOT .. "/b/added.txt"] == true)
  cursor_to(ROOT .. "/b"); answer = "newdir/"
  fview.ACTIONS.add[1]()
  wait(function() return visible_paths()[ROOT .. "/b/newdir"] end)
  ok("a: a trailing / makes a directory", (vim.uv.fs_stat(ROOT .. "/b/newdir") or {}).type == "directory")
  -- r: rename
  cursor_to(ROOT .. "/b/added.txt"); answer = "renamed.txt"
  fview.ACTIONS.rename[1]()
  wait(function() return visible_paths()[ROOT .. "/b/renamed.txt"] end)
  ok("r: renames", vim.uv.fs_stat(ROOT .. "/b/renamed.txt") ~= nil and vim.uv.fs_stat(ROOT .. "/b/added.txt") == nil)
  -- m: move
  cursor_to(ROOT .. "/b/renamed.txt"); answer = "a/moved.txt"
  fview.ACTIONS.move[1]()
  wait(function() return vim.uv.fs_stat(ROOT .. "/a/moved.txt") ~= nil end)
  ok("m: moves", vim.uv.fs_stat(ROOT .. "/a/moved.txt") ~= nil and vim.uv.fs_stat(ROOT .. "/b/renamed.txt") == nil)
  -- y / p: copy and paste
  cursor_to(ROOT .. "/top.txt"); fview.ACTIONS.copy_to_clipboard[1]()
  ok("y: marks for copy (rendered as ' (copy)')", S.marks[ROOT .. "/top.txt"] == "copy")
  cursor_to(ROOT .. "/b")
  fview.ACTIONS.paste_from_clipboard[1]()
  wait(function() return vim.uv.fs_stat(ROOT .. "/b/top.txt") ~= nil end)
  wait(function() return visible_paths()[ROOT .. "/b/top.txt"] end)
  ok("p: pastes a copy into the directory at the cursor (and shows it)", vim.uv.fs_stat(ROOT .. "/b/top.txt") ~= nil
    and vim.uv.fs_stat(ROOT .. "/top.txt") ~= nil and next(S.marks) == nil and visible_paths()[ROOT .. "/b/top.txt"])
  -- d: delete (irreversible modal: answer yes)
  local modal = require("auto-core.ui.modal")
  local real_open = modal.open
  modal.open = function(o) o.on_choice(true) end
  cursor_to(ROOT .. "/b/top.txt")
  fview.ACTIONS.delete[1]()
  wait(function() return vim.uv.fs_stat(ROOT .. "/b/top.txt") == nil end)
  ok("d: deletes after the confirm", vim.uv.fs_stat(ROOT .. "/b/top.txt") == nil)
  cursor_to(ROOT); fview.ACTIONS.delete[1]()
  ok("d: refuses the root", vim.uv.fs_stat(ROOT) ~= nil)
  modal.open = real_open
  vim.ui.input = real_input
  -- H: hides gitignored entries
  local core_files = require("auto-core").files
  core_files.set_show_hidden(true)
  wait(function() return visible_paths()[ROOT .. "/ignored_dir"] end)
  ok("precondition: the ignored directory is shown while show_hidden", visible_paths()[ROOT .. "/ignored_dir"] == true)
  -- let the git refresh the file actions above scheduled land first: H must re-filter on its own
  vim.wait(900)
  reset_counts()
  fview.ACTIONS.toggle_hidden[1]()
  wait(function() return not visible_paths()[ROOT .. "/ignored_dir"] end, 800)
  ok("H: hides gitignored entries, without a git read", not visible_paths()[ROOT .. "/ignored_dir"] and #STATUS == 0,
    vim.inspect(STATUS))
  fview.ACTIONS.toggle_hidden[1]()
  wait(function() return visible_paths()[ROOT .. "/ignored_dir"] end, 800)
  ok("H again: shows them, without a git read", visible_paths()[ROOT .. "/ignored_dir"] == true and #STATUS == 0,
    vim.inspect(STATUS))
  -- i: details
  cursor_to(ROOT .. "/top.txt")
  local lines = require("auto-finder.views.files.actions").info(
    { root = ROOT, node = S.model.nodes[ROOT .. "/top.txt"], dir = ROOT, done = function() end }, nil)
  ok("i: details list name, path, type, size, modified",
    lines[1]:find("Name: top.txt", 1, true) and lines[2]:find("Path: " .. ROOT .. "/top.txt", 1, true)
      and table.concat(lines, "\n"):find("Size:", 1, true) and table.concat(lines, "\n"):find("Modified:", 1, true),
    vim.inspect(lines))
  -- /: search shows matches as a tree
  local search = require("auto-finder.views.files.search")
  if search.argv(ROOT, "four", { never_show = { ".git" }, hidden = true }) then
    local got
    search.run(ROOT, "four", { never_show = { ".git" }, hidden = true }, function(p) got = p end)
    wait(function() return got ~= nil end, 3000)
    ok("/: the finder returns the match", got and vim.tbl_contains(got, ROOT .. "/c/four.txt"), vim.inspect(got))
  else
    ok("/: a finder is available (fd, fdfind or find)", false)
  end
end)

section("[10] follow reveals the entered file, reading only its unread ancestors", function()
  af.state.config.files.follow = true
  ok("precondition: f1 has never been read", S.model.nodes[ROOT .. "/f1"].children == nil)
  reset_counts()
  local editor
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if w ~= af.state.panel_winid and vim.api.nvim_win_get_config(w).relative == "" then editor = w end
  end
  vim.api.nvim_set_current_win(editor)
  local target = ROOT .. "/f1/f2/leaf.txt"
  vim.cmd("edit " .. vim.fn.fnameescape(target))
  local function on_target()
    local line = vim.api.nvim_win_get_cursor(S.winid)[1]
    return S.items[line] ~= nil and S.items[line].node.path == target
  end
  wait(on_target, 2000)
  ok("the panel cursor is on the entered file", on_target())
  ok("follow read f1 and f1/f2 once each and nothing else",
    reads_of(ROOT .. "/f1") == 1 and reads_of(ROOT .. "/f1/f2") == 1 and #READS == 2, vim.inspect(READS))
  ok("the revealed directories are watched", fview.watch_count() == #model_mod.expanded_dirs(S.model))
end)

scan.read_dir, status.get_async = real_read, real_status
vim.fn.delete(ROOT, "rf")
vim.fn.delete(SANDBOX, "rf")
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
