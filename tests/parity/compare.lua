---tests/parity/compare.lua — the ADR-0200 render-parity gate (§5 cell 1).
---
---Drives the NEW files / buffers / marks slots through auto-finder's public setup/open/focus against the
---fixture the goldens were frozen from, and compares with tests/fixtures/parity/*.json:
---
---  * width-38 scenarios: every line, every span (group, byte range), every span's RESOLVED colours
---    (catppuccin-mocha) and the window options must be equal. AutoFinder* groups are mapped to the
---    NeoTree* names they alias before comparing names, and must resolve to the same colours;
---  * width-70 scenarios: the retired size column (NeoTreeFileStats*) is removed from the golden; the rest
---    of each line and its spans must be equal, and the diagnostic sign must end at the window's edge.
---
---Run on VM43 from the worktree root:
---    AF_PARITY_DEPS=<dir holding mini.icons + catppuccin> nvim --headless -u NONE -l tests/parity/compare.lua
---@module 'tests.parity.compare'

local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h:h")
local plugins_root = vim.fn.fnamemodify(plugin_root, ":h:h")
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
local DEPS = vim.env.AF_PARITY_DEPS or ""

local function die(msg)
  io.stderr:write("parity compare: " .. msg .. "\n")
  os.exit(2)
end
for _, need in ipairs({ "mini.icons", "catppuccin" }) do
  if vim.fn.isdirectory(DEPS .. "/" .. need) ~= 1 then die("missing dependency " .. need) end
end
for _, p in ipairs({
  LAZY .. "/auto-core.nvim",
  LAZY .. "/worktree.nvim",
  plugins_root .. "/worktree.nvim/main",
  plugins_root .. "/auto-core.nvim/" .. vim.fn.fnamemodify(plugin_root, ":t"),
  DEPS .. "/mini.icons",
  DEPS .. "/catppuccin",
  plugin_root,
}) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end
local SANDBOX = dofile(plugin_root .. "/tests/_sandbox.lua")("parity-compare")

vim.o.columns, vim.o.lines = 200, 60
vim.o.swapfile, vim.o.hidden, vim.o.termguicolors = false, true, true
vim.env.AUTO_FINDER_DBASE_DISABLE_CRYPTO = "1"

local pass, fail = 0, 0
local function ok(name, cond, detail)
  print((cond and "  PASS  " or "  FAIL  ") .. name .. ((not cond and detail) and ("  — " .. tostring(detail)) or ""))
  if cond then pass = pass + 1 else fail = fail + 1 end
end

print("\n[0] provenance of what runs")
ok("auto-core fs.scan is on the runtimepath", pcall(require, "auto-core.fs.scan"))
ok("the loaded files view is this worktree's",
  vim.startswith(vim.api.nvim_get_runtime_file("lua/auto-finder/views/files/init.lua", false)[1] or "", plugin_root))

local mini_icons = require("mini.icons")
mini_icons.setup({})
mini_icons.mock_nvim_web_devicons()
require("catppuccin").setup({ flavour = "mocha" })
vim.cmd.colorscheme("catppuccin-mocha")

local ROOT = dofile(plugin_root .. "/tests/parity/fixture.lua")(die)
vim.cmd.cd(ROOT)

local af = require("auto-finder")
local files = require("auto-finder.views.files")
local model_mod = require("auto-finder.views.files.model")
local ALIAS = require("auto-finder.views.files.highlights").ALIAS

local function settle(pred, ms)
  vim.wait(ms or 3000, pred, 20)
  vim.wait(150)
end

local function resolved(group)
  local h = vim.api.nvim_get_hl(0, { name = group, link = false })
  local function hex(v) return v and string.format("#%06x", v) or nil end
  return { fg = hex(h.fg), bg = hex(h.bg), bold = h.bold or nil, italic = h.italic or nil,
    underline = h.underline or nil, strikethrough = h.strikethrough or nil }
end

local WIN_OPTS = { "cursorline", "cursorlineopt", "wrap", "list", "spell", "number", "relativenumber",
  "winhighlight", "foldcolumn", "signcolumn" }

local function observe(bufnr, winid)
  local spans = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })) do
    local d = m[4]
    if d.hl_group then
      spans[#spans + 1] = { row = m[2], col = m[3], end_col = d.end_col, hl = ALIAS[d.hl_group] or d.hl_group,
        hl_resolved = resolved(d.hl_group) }
    end
  end
  table.sort(spans, function(a, b)
    if a.row ~= b.row then return a.row < b.row end
    if a.col ~= b.col then return a.col < b.col end
    return a.hl < b.hl
  end)
  local win = {}
  for _, o in ipairs(WIN_OPTS) do win[o] = vim.api.nvim_get_option_value(o, { win = winid }) end
  -- the new winhighlight names AutoFinder* groups; compare it in NeoTree* terms
  win.winhighlight = win.winhighlight:gsub("AutoFinder(%w+)", function(n) return ALIAS["AutoFinder" .. n] or ("AutoFinder" .. n) end)
  return { lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), spans = spans,
    width = vim.api.nvim_win_get_width(winid), win = win }
end

local function load_golden(name)
  local f = assert(io.open(plugin_root .. "/tests/fixtures/parity/" .. name .. ".json"))
  local g = vim.json.decode(f:read("*a"))
  f:close()
  for _, s in ipairs(g.spans) do
    if vim.islist(s.hl_resolved or {}) then s.hl_resolved = {} end
  end
  return g
end

local function norm_resolved(r)
  local t = {}
  for _, k in ipairs({ "fg", "bg", "bold", "italic", "underline", "strikethrough" }) do
    if r and r[k] ~= nil and r[k] ~= vim.NIL then t[k] = r[k] end
  end
  return vim.inspect(t)
end

local function span_key(s)
  return ("%d:%d-%s %s %s"):format(s.row, s.col, tostring(s.end_col), s.hl, norm_resolved(s.hl_resolved))
end

---Strip the retired size column from a golden: its spans go, and each line is cut where they begin.
local function drop_stats(g)
  local cut = {}
  local spans = {}
  for _, s in ipairs(g.spans) do
    if s.hl == "NeoTreeFileStats" or s.hl == "NeoTreeFileStatsHeader" then
      cut[s.row] = math.min(cut[s.row] or math.huge, s.col)
    else
      spans[#spans + 1] = s
    end
  end
  return cut, spans
end

local function compare(name, got, opts)
  local g = load_golden(name)
  print(("\n[%s] %s"):format(opts.strict and "exact" or "size column removed", name))
  ok(name .. ": same number of lines", #got.lines == #g.lines, #got.lines .. " vs " .. #g.lines)
  local gspans = g.spans
  local cut = {}
  if not opts.strict then cut, gspans = drop_stats(g) end
  local diag_rows = {}
  for _, s in ipairs(gspans) do if s.hl:match("^Diagnostic") then diag_rows[s.row] = s end end
  local line_bad = {}
  for i, gl in ipairs(g.lines) do
    local nl = got.lines[i] or ""
    local r = i - 1
    if opts.strict then
      if nl ~= gl then line_bad[#line_bad + 1] = ("%d: %q ~= %q"):format(r, nl, gl) end
    else
      local left_g = gl:sub(1, (cut[r] or (#gl + 1)) - 1)
      local d = diag_rows[r]
      if d then left_g = gl:sub(1, d.col) end
      left_g = left_g:gsub("%s+$", "")
      local left_n = nl
      local nd
      for _, s in ipairs(got.spans) do if s.row == r and s.hl:match("^Diagnostic") then nd = s end end
      if nd then left_n = nl:sub(1, nd.col) end
      left_n = left_n:gsub("%s+$", "")
      if left_n ~= left_g then line_bad[#line_bad + 1] = ("%d: %q ~= %q"):format(r, left_n, left_g) end
      if d then
        if not nd or nl:sub(nd.col + 1, nd.end_col) ~= gl:sub(d.col + 1, d.end_col) or nd.hl ~= d.hl then
          line_bad[#line_bad + 1] = ("%d: diagnostic sign differs"):format(r)
        elseif vim.fn.strdisplaywidth(nl) ~= got.width then
          line_bad[#line_bad + 1] = ("%d: sign does not end at the window edge (%d vs %d)"):format(r,
            vim.fn.strdisplaywidth(nl), got.width)
        end
      end
    end
  end
  ok(name .. ": lines equal", #line_bad == 0, table.concat(line_bad, " | "))
  local want, have = {}, {}
  for _, s in ipairs(gspans) do
    if opts.strict or not s.hl:match("^Diagnostic") then want[#want + 1] = span_key(s) end
  end
  for _, s in ipairs(got.spans) do
    if opts.strict or not s.hl:match("^Diagnostic") then have[#have + 1] = span_key(s) end
  end
  table.sort(want); table.sort(have)
  local missing, extra = {}, {}
  local hs = {}
  for _, k in ipairs(have) do hs[k] = (hs[k] or 0) + 1 end
  for _, k in ipairs(want) do
    if (hs[k] or 0) > 0 then hs[k] = hs[k] - 1 else missing[#missing + 1] = k end
  end
  for k, n in pairs(hs) do for _ = 1, n do extra[#extra + 1] = k end end
  ok(name .. ": spans equal (names, ranges, resolved colours)", #missing == 0 and #extra == 0,
    "missing=" .. vim.inspect(missing) .. " extra=" .. vim.inspect(extra))
  if opts.strict then
    ok(name .. ": width equal", got.width == g.width, got.width .. " vs " .. g.width)
  end
  local wbad = {}
  for _, o in ipairs(WIN_OPTS) do
    if tostring(got.win[o]) ~= tostring(g.win[o]) then
      wbad[#wbad + 1] = o .. "=" .. tostring(got.win[o]) .. " (golden " .. tostring(g.win[o]) .. ")"
    end
  end
  ok(name .. ": window options equal", #wbad == 0, table.concat(wbad, ", "))
end

-- ── the same editor-side state the capture made ─────────────────────────────────────────────────
local function decorate_buffers()
  vim.cmd("edit " .. ROOT .. "/docs/readme.md")
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { "unsaved edit" })
  vim.cmd("edit " .. ROOT .. "/src/util/helper.lua")
  local ns = vim.api.nvim_create_namespace("parity-diag")
  vim.diagnostic.set(ns, 0, { { lnum = 0, col = 0, severity = vim.diagnostic.severity.ERROR, message = "x" } })
  vim.cmd("edit " .. ROOT .. "/Makefile")
end

local function touch_modified()
  local buf = vim.fn.bufnr(ROOT .. "/docs/readme.md")
  vim.bo[buf].modified = false
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "unsaved edit" })
  settle(function() return vim.bo[buf].modified end, 500)
end

local function wipe_scratch()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].buflisted and vim.api.nvim_buf_get_name(b) == "" and vim.fn.bufwinid(b) == -1
        and not vim.bo[b].modified then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
end

local REVEAL = { "src/util/helper.lua", "docs/guide.md", "a/b/c/deep.txt", ".github/workflows/ci.yml" }

local real_get_async = require("auto-core.git.status").get_async

local function boot()
  pcall(af.close)
  af.state.user_width = nil
  local ok_setup, err = pcall(af.setup, {
    width = { default = 38, min = 25, max = 100 },
    default_section = 1,
    sections = { "config", "files", "buffers", "marks" },
  })
  if not ok_setup then die("setup: " .. tostring(err)) end
  af.open(true)
end

local function has_git_span(bufnr)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })) do
    if (m[4].hl_group or ""):match("^AutoFinderGit") then return true end
  end
  return false
end

local function scenario_files(name, opts)
  files._reset_for_tests()
  require("auto-core.git.status")._reset_for_tests()
  local gs = require("auto-core.git.status")
  gs.get_async = opts.git and real_get_async or function(_, _, cb) vim.schedule(function() cb(nil, "off") end) end
  boot()
  af.focus("files")
  local st = files._state
  settle(function() return st.model and st.model.nodes[ROOT].children ~= nil end)
  if opts.width then af.resize(opts.width) end
  for _, rel in ipairs(REVEAL) do
    local done = false
    model_mod.reveal(st.model, ROOT .. "/" .. rel, function() done = true end)
    settle(function() return done end)
  end
  files.paint()
  if opts.marks then
    st.marks[ROOT .. "/zeta.txt"] = "cut"
    st.marks[ROOT .. "/Makefile"] = "copy"
    files.paint()
  end
  touch_modified()
  local bufnr = vim.api.nvim_win_get_buf(af.state.panel_winid)
  vim.api.nvim_set_current_win(af.state.panel_winid)
  if opts.git then
    settle(function() return has_git_span(bufnr) end, 5000)
  else
    vim.wait(600)
  end
  settle(function() return true end, 300)
  compare(name, observe(bufnr, af.state.panel_winid), { strict = not opts.width })
  gs.get_async = real_get_async
end

decorate_buffers()
scenario_files("files-w38-git", { git = true })
scenario_files("files-w38-nogit", { git = false })
scenario_files("files-w38-git-marks", { git = true, marks = true })
scenario_files("files-w70-git", { git = true, width = 70 })

local function scenario_buffers(name, width)
  wipe_scratch()
  if width then af.resize(width) else af.reset_width() end
  af.focus("buffers")
  touch_modified()
  local bufnr
  settle(function()
    bufnr = vim.api.nvim_win_get_buf(af.state.panel_winid)
    return vim.b[bufnr].auto_finder_view == "buffers" and #vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) > 1
  end)
  vim.api.nvim_set_current_win(af.state.panel_winid)
  settle(function() return true end, 300)
  compare(name, observe(bufnr, af.state.panel_winid), { strict = not width })
end
scenario_buffers("buffers-w38")
scenario_buffers("buffers-w70", 70)

do
  af.reset_width()
  local editor
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if w ~= af.state.panel_winid and vim.api.nvim_win_get_config(w).relative == "" then editor = w; break end
  end
  vim.api.nvim_win_call(editor, function()
    vim.cmd("edit " .. ROOT .. "/src/main.lua")
    vim.cmd("normal! ma")
  end)
  af.focus("marks")
  local bufnr
  settle(function()
    bufnr = vim.api.nvim_win_get_buf(af.state.panel_winid)
    return vim.b[bufnr].auto_finder_view == "marks"
  end)
  vim.api.nvim_set_current_win(af.state.panel_winid)
  settle(function() return vim.wo[af.state.panel_winid].cursorline end, 1000)
  compare("marks-w38", observe(bufnr, af.state.panel_winid), { strict = true })
end

print(string.format("\n%d passed, %d failed", pass, fail))
vim.fn.delete(SANDBOX, "rf")
os.exit(fail == 0 and 0 or 1)
