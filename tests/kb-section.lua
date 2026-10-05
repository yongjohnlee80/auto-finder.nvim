-- tests/kb-section.lua — the kb section: a facade over AutoDoc's KB drawer (ADR 1791209945 §7).
--
-- Run: nvim --headless -u NONE -l tests/kb-section.lua
--
-- AutoDoc is not on the headless runtimepath, so the no-backend path runs for real; the hosted
-- path runs against a stub of AutoDoc's drawer host registry (package.preload), shaped like
-- autodb's (register_host / has_host / unregister_host / open), because that is the contract the
-- facade mirrors.

local root = vim.fn.fnamemodify(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
dofile(root .. "/tests/_sandbox.lua")("kb-section")

local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
local sib = vim.fn.fnamemodify(root, ":h:h")
for _, r in ipairs({ LAZY .. "/auto-core.nvim", sib .. "/auto-core.nvim/main" }) do
  if vim.fn.isdirectory(r) == 1 then vim.opt.runtimepath:prepend(r) end
end
vim.opt.runtimepath:prepend(root)

local pass, fail = 0, 0
local function ok(name, cond, detail)
  print((cond and "  PASS  " or "  FAIL  ") .. name .. ((not cond and detail) and ("  — " .. tostring(detail)) or ""))
  if cond then pass = pass + 1 else fail = fail + 1 end
end

-- ── no backend: the placeholder names AutoDoc ────────────────────────────────────────────────────
do
  local kb = require("auto-finder.views.kb")
  kb._bufnr, kb._owned_bufs = nil, {}
  ok("the facade is the kb section", kb.name == "kb")
  ok("AutoDoc is not available headless", kb._available_for_tests() == false)
  local b = kb.get_buffer(0)
  ok("get_buffer returns a valid buffer with no backend", type(b) == "number" and vim.api.nvim_buf_is_valid(b), tostring(b))
  ok("the buffer is tagged view='kb'", vim.b[b].auto_finder_view == "kb", tostring(vim.b[b].auto_finder_view))
  ok("it is the kb placeholder, by name", vim.api.nvim_buf_get_name(b):find("auto-finder-kb://placeholder", 1, true) ~= nil,
    vim.api.nvim_buf_get_name(b))
  local text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  ok("it points the user at AutoDoc", text:find("AutoDoc", 1, true) ~= nil, text)
  ok("on_focus is safe with no backend", pcall(kb.on_focus, 0, b))
  kb.on_close()
  ok("on_close disposes the buffer it owned", vim.api.nvim_buf_is_valid(b) == false)
end

-- ── a stub of AutoDoc's drawer host registry ─────────────────────────────────────────────────────
local registry = { hosts = {}, registers = 0, opens = 0, released = 0 }
package.loaded["autodoc.session"] = {}
package.loaded["autodoc.views.drawer"] = {
  register_host = function(p)
    registry.registers = registry.registers + 1
    registry.hosts[p.id] = p
    return true
  end,
  has_host = function(id) return registry.hosts[id] ~= nil end,
  unregister_host = function(id) registry.hosts[id] = nil end,
  open = function()
    registry.opens = registry.opens + 1
    local view = {
      get_buffer = function()
        local b = vim.api.nvim_create_buf(false, true)
        vim.b[b].auto_finder_view = "kb"
        return b
      end,
      on_focus = function() end,
    }
    local p = registry.hosts["auto-finder"]
    if p then p.mount(view, function() registry.released = registry.released + 1 end) end
  end,
}

do
  local kb = require("auto-finder.views.kb")
  ok("with AutoDoc's drawer and session present, the section is available", kb._available_for_tests() == true)
  ok("register advertises auto-finder as a host", kb.register() == true and kb.is_registered())
  local p = registry.hosts["auto-finder"]
  ok("the provider outranks AutoDoc's own panel (priority 100 > 0)", p and p.priority == 100, p and p.priority)
  ok("the provider's profile is auto-finder's identity",
    p and p.profile.filetype == "auto-finder" and p.profile.buf_var_value == "kb" and p.profile.buf_name == "auto-finder://kb")
  -- get_buffer mounts through the registry: the registry builds the view, the facade shows it
  local b = kb.get_buffer(0)
  ok("get_buffer asks the registry to mount here", registry.opens == 1, registry.opens)
  ok("and shows the view the registry handed over", type(b) == "number" and vim.api.nvim_buf_is_valid(b) and kb._view ~= nil)
  kb.on_close()
  ok("on_close hands the release back to the registry", registry.released == 1, registry.released)
  ok("and drops the view", kb._view == nil)
  kb.unregister()
  ok("unregister withdraws the host", not kb.is_registered())
end

-- ── _sync_kb_host: edge-triggered, the registry's word over a local copy ─────────────────────────
do
  local af = require("auto-finder")
  local views = require("auto-finder.views")
  local saved = views._by_name
  registry.registers = 0
  views._by_name = vim.tbl_extend("force", saved or {}, { kb = {} })
  af._sync_kb_host()
  af._sync_kb_host()
  ok("a present kb section registers once, however often it syncs", registry.registers == 1, registry.registers)
  local by_name = vim.tbl_extend("force", {}, views._by_name)
  by_name.kb = nil
  views._by_name = by_name
  af._sync_kb_host()
  ok("a removed kb section withdraws the host", registry.hosts["auto-finder"] == nil)
  views._by_name = saved
end

print(string.format("kb-section: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
