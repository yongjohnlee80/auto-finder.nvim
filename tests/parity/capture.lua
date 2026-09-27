---tests/parity/capture.lua — freeze the CURRENT files/buffers look as goldens (ADR-0200 §5 cell 1).
---
---Runs auto-finder's shipped renderer against a deterministic fixture repo and writes, per scenario, every
---buffer line and every extmark span (hl group + the group's resolved colours) to
---tests/fixtures/parity/<scenario>.json. The ADR-0200 renderer is gated against these files, so they must
---be produced by RUNNING the code being replaced — never composed by hand
---([[auto-family-plugin-refactors]] "Moved ownership has a capability floor", rule 2).
---
---Run on VM43 (vm43-layout), from the worktree root:
---
---    AF_PARITY_DEPS=<dir holding mini.icons + catppuccin> \
---      nvim --headless -u NONE -l tests/parity/capture.lua
---
---Icons come from mini.icons' nvim-web-devicons mock and colours from catppuccin-mocha, the live session's
---provider and scheme (ADR-0200 rationale §R6). Both are required: a capture without them would freeze a
---look nobody runs, so a missing dependency aborts instead of degrading.
---@module 'tests.parity.capture'

local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h:h")
local plugins_root = vim.fn.fnamemodify(plugin_root, ":h:h")
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
local DEPS = vim.env.AF_PARITY_DEPS or ""

local function die(msg)
  io.stderr:write("parity capture: " .. msg .. "\n")
  os.exit(2)
end

for _, need in ipairs({ "mini.icons", "catppuccin" }) do
  if vim.fn.isdirectory(DEPS .. "/" .. need) ~= 1 then
    die("missing dependency " .. need .. " under AF_PARITY_DEPS=" .. DEPS)
  end
end

-- Last prepend wins: the worktree under test goes last so it shadows any installed auto-finder.
for _, p in ipairs({
  LAZY .. "/nui.nvim",
  LAZY .. "/plenary.nvim",
  LAZY .. "/auto-core.nvim",
  LAZY .. "/worktree.nvim",
  plugins_root .. "/worktree.nvim/main",
  plugins_root .. "/auto-core.nvim/main",
  DEPS .. "/mini.icons",
  DEPS .. "/catppuccin",
  plugin_root,
}) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end

local SANDBOX = dofile(plugin_root .. "/tests/_sandbox.lua")("parity-capture")

vim.o.columns = 200
vim.o.lines = 60
vim.o.swapfile = false
vim.o.hidden = true
vim.o.termguicolors = true
vim.env.AUTO_FINDER_DBASE_DISABLE_CRYPTO = "1"

local mini_icons = require("mini.icons")
mini_icons.setup({})
mini_icons.mock_nvim_web_devicons()
require("catppuccin").setup({ flavour = "mocha" })
vim.cmd.colorscheme("catppuccin-mocha")

-- ── fixture repo ──────────────────────────────────────────────────────────────
-- A fixed absolute path, so the root row (fnamemodify(root, ":~")) and every line width is identical on
-- every run; a tempname() would make each capture differ in its first line.
local ROOT = "/tmp/af-parity-fixture"
vim.fn.delete(ROOT, "rf")

local function write(rel, text)
  local p = ROOT .. "/" .. rel
  vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
  vim.fn.writefile(vim.split(text or rel, "\n"), p)
end

local function git(...)
  local r = vim.system({ "git", "-C", ROOT, ... }, { text = true }):wait()
  if r.code ~= 0 then die("git " .. table.concat({ ... }, " ") .. ": " .. (r.stderr or "")) end
end

for _, rel in ipairs({
  "src/main.lua", "src/util/helper.lua", "src/util/strings.lua", "docs/readme.md", "docs/guide.md",
  "a/b/c/deep.txt", ".github/workflows/ci.yml", ".env", "old.md", "Makefile", "zeta.txt",
  "debug.log", "build/out.bin", "tracked_then_deleted.txt",
}) do write(rel) end
write(".gitignore", "build/\n*.log")
vim.fn.mkdir(ROOT .. "/empty_dir", "p")
vim.uv.fs_symlink(ROOT .. "/src/main.lua", ROOT .. "/link.lua")

git("init", "-q", "-b", "main")
git("config", "user.email", "parity@example.invalid")
git("config", "user.name", "parity")
git("add", "-A")
git("commit", "-q", "-m", "fixture")
write("src/main.lua", "changed")                 -- worktree modified
write("staged.txt"); git("add", "staged.txt")    -- staged add
write("new.txt")                                  -- untracked
git("mv", "old.md", "renamed.md")                 -- staged rename
vim.fn.delete(ROOT .. "/tracked_then_deleted.txt") -- worktree delete

vim.cmd.cd(ROOT)

-- ── auto-finder with the live consumer's options (autovim lua/plugins/auto-finder.lua) ──────────────────
local function consumer_neo_tree(git_status)
  return {
    -- Git scenarios switch the fork's filename colouring back on as it was before ADR-0060 §2.8
    -- (66ffaf4): status fetched with the SYNC path, because the async path calls
    -- auto-core.git.repo.discover_async, which no auto-core release defines.
    enable_git_status = git_status,
    git_status_async = false,
    default_component_configs = { name = { use_git_status_colors = git_status } },
    window = { auto_expand_width = true },
    filesystem = {
      hijack_netrw_behavior = "disabled",
      filtered_items = {
        visible = true, hide_dotfiles = false, hide_gitignored = false,
        never_show = { ".git", "node_modules" }, ignore_files = {},
      },
      check_gitignore_in_search = false,
      components = {
        name = function(config, node, state)
          local cc = require("auto-finder.neotree.sources.common.components")
          local result = cc.name(config, node, state)
          local name = node.name or ""
          if node.type ~= "directory" and name:sub(1, 1) == "." then
            result.highlight = "NeoTreeDotfile"
          end
          return result
        end,
      },
    },
  }
end

local af = require("auto-finder")

local function resolved(group)
  local h = vim.api.nvim_get_hl(0, { name = group, link = false })
  local function hex(v) return v and string.format("#%06x", v) or nil end
  return {
    fg = hex(h.fg), bg = hex(h.bg), bold = h.bold or nil, italic = h.italic or nil,
    underline = h.underline or nil, strikethrough = h.strikethrough or nil,
  }
end

local function dump(bufnr, winid)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local spans = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })) do
    local d = m[4]
    if d.hl_group or d.virt_text then
      spans[#spans + 1] = {
        row = m[2], col = m[3], end_row = d.end_row, end_col = d.end_col,
        hl = d.hl_group, hl_resolved = d.hl_group and resolved(d.hl_group) or nil,
        virt_text = d.virt_text, virt_text_pos = d.virt_text_pos, priority = d.priority,
      }
    end
  end
  table.sort(spans, function(a, b)
    if a.row ~= b.row then return a.row < b.row end
    if a.col ~= b.col then return a.col < b.col end
    return tostring(a.hl) < tostring(b.hl)
  end)
  -- Window-local look. The fork's BufEnter handler (neotree/setup/init.lua buffer_enter_event) styles
  -- EVERY filetype=auto-finder buffer's window, not only its own views, so these are part of the panel's
  -- look for marks/todos/tests/repos too.
  local win = nil
  if winid then
    win = {}
    for _, o in ipairs({ "cursorline", "cursorlineopt", "wrap", "list", "spell", "number",
      "relativenumber", "winhighlight", "foldcolumn", "signcolumn" }) do
      win[o] = vim.api.nvim_get_option_value(o, { win = winid })
    end
  end
  return {
    lines = lines,
    spans = spans,
    width = winid and vim.api.nvim_win_get_width(winid) or nil,
    filetype = vim.bo[bufnr].filetype,
    win = win,
  }
end

local function files_state()
  local mgr = require("auto-finder.neotree.sources.manager")
  for _, s in ipairs(mgr._get_all_states()) do
    if s.name == "filesystem" and s.winid == af.state.panel_winid and s.tree then return s end
  end
end

local function settle(pred, ms)
  vim.wait(ms or 3000, pred, 20)
  vim.wait(150) -- one more scheduler round so trailing redraws land
end

-- Expanded set mirrors a working session: src/util, docs, a/b/c, .github/workflows.
local REVEAL = { "src/util/helper.lua", "docs/guide.md", "a/b/c/deep.txt", ".github/workflows/ci.yml" }

local function expand_all(state)
  local fs = require("auto-finder.neotree.sources.filesystem")
  for _, rel in ipairs(REVEAL) do
    local done = false
    fs.navigate(state, state.path, ROOT .. "/" .. rel, function() done = true end)
    settle(function() return done end)
  end
end

local function has_git_span(bufnr)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })) do
    if (m[4].hl_group or ""):match("^NeoTreeGit") then return true end
  end
  return false
end

-- AF_PARITY_OUT redirects the write (a provenance re-run compares against the committed goldens instead
-- of replacing them); AF_PARITY_ONLY is a comma list of scenario names to run.
local out_dir = vim.env.AF_PARITY_OUT or (plugin_root .. "/tests/fixtures/parity")
local ONLY = {}
for n in (vim.env.AF_PARITY_ONLY or ""):gmatch("[^,]+") do ONLY[n] = true end
local function wanted(name) return next(ONLY) == nil or ONLY[name] == true end
vim.fn.mkdir(out_dir, "p")
local manifest = { captured_from = nil, scenarios = {} }
do
  -- AF_PARITY_SHA when the run tree is a plain copy (VM43 staging carries no .git).
  local r = vim.system({ "git", "-C", plugin_root, "rev-parse", "HEAD" }, { text = true }):wait()
  manifest.captured_from = vim.env.AF_PARITY_SHA or vim.trim(r.stdout or "")
  for _, dep in ipairs({ "mini.icons", "catppuccin" }) do
    local d = vim.system({ "git", "-C", DEPS .. "/" .. dep, "rev-parse", "HEAD" }, { text = true }):wait()
    manifest[dep] = vim.trim(d.stdout or "")
  end
  manifest.nvim = tostring(vim.version())
end

-- Canonical JSON (sorted keys, one span per line): vim.json.encode's key order varies run to run, and a
-- provenance re-run must be comparable with cmp, and a golden change reviewable as a diff.
local function canon(v, indent)
  indent = indent or ""
  if type(v) ~= "table" then return vim.json.encode(v) end
  if vim.islist(v) then
    if #v == 0 then return "[]" end
    local parts = {}
    for _, x in ipairs(v) do parts[#parts + 1] = indent .. "  " .. canon(x, indent .. "  ") end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
  end
  local keys = vim.tbl_keys(v)
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = vim.json.encode(k) .. ":" .. canon(v[k], indent) end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function save(name, data)
  local path = out_dir .. "/" .. name .. ".json"
  local f = assert(io.open(path, "w"))
  f:write(canon(data) .. "\n")
  f:close()
  manifest.scenarios[#manifest.scenarios + 1] = name
  print(string.format("  captured %-24s lines=%d spans=%d width=%s",
    name, #data.lines, #data.spans, tostring(data.width)))
end

-- Editor-side state that decorates the tree: a modified buffer and an error diagnostic.
local function decorate_buffers()
  vim.cmd("edit " .. ROOT .. "/docs/readme.md")
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { "unsaved edit" })        -- [+] marker
  vim.cmd("edit " .. ROOT .. "/src/util/helper.lua")
  local ns = vim.api.nvim_create_namespace("parity-diag")
  vim.diagnostic.set(ns, 0, { { lnum = 0, col = 0, severity = vim.diagnostic.severity.ERROR, message = "x" } })
  vim.cmd("edit " .. ROOT .. "/Makefile")
end

-- An unsaved edit made AFTER the view mounted (flag false -> true), the steady state of editing with the
-- pane open. The fork paints no `[+]` for it: its BufModifiedSet handler never fills
-- state.opened_buffers in panel mode (probed on VM43, 2026-09-27). The goldens freeze that absence.
local function touch_modified()
  local buf = vim.fn.bufnr(ROOT .. "/docs/readme.md")
  vim.bo[buf].modified = false
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "unsaved edit" })
  settle(function() return vim.bo[buf].modified end, 500)
end

-- Listed, unnamed, empty buffers left by the harness's own open/close cycles are not part of the look.
local function wipe_scratch()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].buflisted and vim.api.nvim_buf_get_name(b) == "" and vim.fn.bufwinid(b) == -1
        and not vim.bo[b].modified then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
end

local function scenario_files(name, opts)
  if not wanted(name) then return end
  pcall(af.close)
  af.state.user_width = nil
  local ok_setup, err = pcall(af.setup, {
    width = { default = 38, min = 25, max = 100 },
    default_section = 1,
    sections = { "config", "files", "buffers", "marks" },
    neo_tree = consumer_neo_tree(opts.git),
  })
  if not ok_setup then die("setup: " .. tostring(err)) end
  af.open(true)
  af.focus("files")
  local state
  settle(function() state = files_state(); return state ~= nil end)
  if not state then die(name .. ": no filesystem state mounted") end
  if opts.width then af.resize(opts.width) end
  expand_all(state)
  if opts.marks then
    local cmds = require("auto-finder.neotree.sources.filesystem.commands")
    local function mark(rel, fn)
      local node = state.tree:get_node(ROOT .. "/" .. rel)
      if not node then die(name .. ": no node " .. rel) end
      require("auto-finder.neotree.ui.renderer").focus_node(state, node:get_id())
      cmds[fn](state)
    end
    mark("zeta.txt", "cut_to_clipboard")
    mark("Makefile", "copy_to_clipboard")
  end
  touch_modified()
  local bufnr = vim.api.nvim_win_get_buf(af.state.panel_winid)
  if opts.git then
    settle(function() return has_git_span(bufnr) end, 5000)
    if not has_git_span(bufnr) then die(name .. ": git colouring never painted") end
  end
  settle(function() return true end, 300)
  save(name, dump(bufnr, af.state.panel_winid))
end

local function scenario_buffers(name, width)
  if not wanted(name) then return end
  wipe_scratch()
  if width then af.resize(width) else af.reset_width() end
  af.focus("buffers")
  touch_modified()
  local bufnr
  settle(function()
    bufnr = vim.api.nvim_win_get_buf(af.state.panel_winid)
    return vim.bo[bufnr].filetype == "auto-finder" and #vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) > 1
  end)
  save(name, dump(bufnr, af.state.panel_winid))
end

print("\n[parity] capturing from " .. plugin_root)
decorate_buffers()
scenario_files("files-w38-git", { git = true })
scenario_files("files-w38-nogit", { git = false })
scenario_files("files-w38-git-marks", { git = true, marks = true })
scenario_files("files-w70-git", { git = true, width = 70 })
scenario_buffers("buffers-w38")
scenario_buffers("buffers-w70", 70)

-- The marks slot has its own renderer; captured for the WINDOW look the fork applies to it (and to every
-- other filetype=auto-finder view), which must survive the fork's deletion.
if wanted("marks-w38") then
  af.reset_width()
  vim.cmd("edit " .. ROOT .. "/src/main.lua")
  vim.cmd("normal! ma")
  af.focus("marks")
  local bufnr
  settle(function()
    bufnr = vim.api.nvim_win_get_buf(af.state.panel_winid)
    return vim.b[bufnr].auto_finder_view == "marks"
  end)
  -- the fork styles on BufEnter of the panel window: enter it as a user does
  vim.api.nvim_set_current_win(af.state.panel_winid)
  settle(function() return vim.wo[af.state.panel_winid].cursorline end, 1000)
  save("marks-w38", dump(bufnr, af.state.panel_winid))
end

local f = assert(io.open(out_dir .. "/manifest.json", "w"))
f:write(canon(manifest) .. "\n")
f:close()
print(string.format("\n%d passed, 0 failed", #manifest.scenarios))
vim.fn.delete(SANDBOX, "rf")
os.exit(0)
