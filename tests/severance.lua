-- tests/severance.lua — auto-finder carries no neo-tree (ADR-0200 §4.9, §5 cell 10).
--
-- Run: nvim --headless -u NONE -l tests/severance.lua
--
-- A static check over the shipped tree (lua/, plugin/) and the suites (tests/): no module, require,
-- config key, dependency or comment names neo-tree, nui or plenary — except the ONE named exemption
-- below, which the forked-codebase-severance convention requires to carry its reason here, at the
-- guard, and to be checked for its premise and its liveness (named-exemptions-have-four-parts).

local root = vim.fn.fnamemodify(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
dofile(root .. "/tests/_sandbox.lua")("severance")

local pass, fail = 0, 0
local function ok(name, cond, detail)
  print((cond and "  PASS  " or "  FAIL  ") .. name .. ((not cond and detail) and ("  — " .. tostring(detail)) or ""))
  if cond then pass = pass + 1 else fail = fail + 1 end
end

-- ── the named exemption ──────────────────────────────────────────────────────────────────────────
-- EXEMPT BY NAME. Reason: colour schemes (catppuccin, tokyonight, everforest) and autovim's
-- transparency.lua style the file tree through the NeoTree* highlight GROUP NAMES. Johno ruled the
-- alias bridge on 2026-09-27 (task 2026-09-10-auto-finder-files-slot-rebuild, item 14): auto-finder
-- paints only AutoFinder* groups and default-links each to its NeoTree* name, so a theme's colours
-- keep applying. It is a name contract with colour schemes — no neo-tree code, module or dependency.
--
-- tests/parity/compare.lua is exempt for the same names and a second reason: the goldens it compares
-- against were recorded from the retired fork, so their spans NAME NeoTree* groups, and the gate maps
-- AutoFinder* back through the alias table to compare them.
local EXEMPT = {
  ["lua/auto-finder/views/files/highlights.lua"] = { allowed = { "NeoTree" } },
  ["tests/parity/compare.lua"] = { allowed = { "NeoTree" } },
}

-- Forbidden anywhere else. Case-sensitive Lua patterns.
local FORBIDDEN = {
  { pat = "neotree",          what = "neotree (module path / identifier)" },
  { pat = "neo%-tree",        what = "neo-tree" },
  { pat = "neo_tree",         what = "neo_tree (config key)" },
  { pat = "NeoTree",          what = "NeoTree (group or type name)" },
  { pat = "Neotree",          what = "Neotree (command)" },
  { pat = "nui%.nvim",        what = "nui.nvim (dependency)" },
  { pat = "require%(%s*[\"']nui", what = "require nui" },
  { pat = "plenary",          what = "plenary (dependency)" },
}

local function files_under(dir, out)
  local h = vim.uv.fs_scandir(root .. "/" .. dir)
  if not h then return out end
  while true do
    local name, t = vim.uv.fs_scandir_next(h)
    if not name then break end
    local rel = dir .. "/" .. name
    if t == "directory" then files_under(rel, out)
    elseif name:match("%.lua$") or name:match("%.vim$") or name:match("%.sh$") then out[#out + 1] = rel end
  end
  return out
end

local function read(rel)
  local f = io.open(root .. "/" .. rel, "r")
  if not f then return nil end
  local s = f:read("*a"); f:close()
  return s
end

print("\n[1] no neo-tree, nui or plenary in lua/, plugin/, tests/ (outside the named exemption)")
local scanned, violations = 0, {}
local self_rel = "tests/severance.lua"
for _, dir in ipairs({ "lua", "plugin", "tests" }) do
  for _, rel in ipairs(files_under(dir, {})) do
    if rel ~= self_rel then
      scanned = scanned + 1
      local content = read(rel) or ""
      local lineno = 0
      for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        lineno = lineno + 1
        for _, f in ipairs(FORBIDDEN) do
          if line:find(f.pat) then
            local ex = EXEMPT[rel]
            local allowed = false
            if ex then
              for _, a in ipairs(ex.allowed) do
                if f.what:find(a, 1, true) then allowed = true end
              end
            end
            if not allowed then
              violations[#violations + 1] = ("%s:%d  %s  | %s"):format(rel, lineno, f.what, vim.trim(line):sub(1, 80))
            end
          end
        end
      end
    end
  end
end
ok(("positive control: the walk scanned a real tree (%d files)"):format(scanned), scanned > 40, scanned)
ok("zero neo-tree / nui / plenary references", #violations == 0,
  #violations .. " hit(s):\n    " .. table.concat(vim.list_slice(violations, 1, 25), "\n    "))

print("\n[2] the retired modules are gone")
for _, rel in ipairs({ "lua/auto-finder/neotree.lua", "lua/auto-finder/neotree/init.lua",
  "lua/auto-finder/neotree/ui/renderer.lua", "lua/auto-finder/shared/neotree.lua",
  "lua/auto-finder/sections/_neotree.lua", "lua/auto-finder-repos/init.lua",
  "lua/auto-finder/shared/impl_latch.lua", "lua/auto-finder/core/files.lua", "lua/auto-finder/core/warm.lua" }) do
  ok("absent: " .. rel, vim.uv.fs_stat(root .. "/" .. rel) == nil)
end

print("\n[3] the named exemptions: premise and liveness")
for rel in pairs(EXEMPT) do
  local content = read(rel)
  ok("LIVE: the exempt file exists: " .. rel, content ~= nil)
  ok("LIVE: " .. rel .. " still names NeoTree* groups (an unused exemption excuses the next thing written there)",
    content ~= nil and content:find("NeoTree") ~= nil)
  ok("PREMISE: " .. rel .. " names no retired module path",
    content ~= nil and content:find("neotree") == nil and content:find("neo%-tree") == nil)
end
do
  local hl = read("lua/auto-finder/views/files/highlights.lua")
  ok("PREMISE: highlights.lua requires no module (group definitions only)",
    hl ~= nil and hl:find("require%s*%(") == nil)
end

print("\n[4] the guard fires (negative control against a temp file, never the real tree)")
do
  local probe = "lua is fine\nlocal x = require(\"auto-finder.neotree.ui.renderer\")\n"
  local hit = false
  for line in probe:gmatch("([^\n]*)\n") do
    for _, f in ipairs(FORBIDDEN) do if line:find(f.pat) then hit = true end end
  end
  ok("a line requiring the retired fork is caught", hit)
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
