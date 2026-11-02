---tests/_autodoc.lua — the AutoDoc daemon the todo cells run against.
---
---From auto-core v0.4.0, auto-core.todo forwards every call to AutoDoc's
---daemon (ADR 1791532020); the panel's todo cells therefore need autodoc.nvim
---on the runtimepath and an autodoc binary. This sets autodoc.nvim up against a
---daemon of the suite's OWN: its config names a socket, a state dir and a data
---dir under the suite's sandbox, so no test ever reaches a live store or a
---daemon another run started.
---
---Where autodoc comes from, first match wins:
---  1. AF_TEST_AUTODOC (a checkout) and AF_TEST_AUTODOC_BIN (its binary);
---  2. the sibling checkout `<plugins>/autodoc/main` and its `bin/autodoc`
---     (what .github/install-deps.sh builds).
---
---Usage, after the suite's _sandbox call:
---    dofile(<tests dir> .. "/_autodoc.lua")(sandbox_root, "smoke")
---Returns true, or false and the reason (the caller fails a cell with it: the
---todo cells are not skipped silently).
---@param sandbox_root string
---@param label string
---@return boolean ok, string? why
---daemons is the pids of the autodoc daemons started with config file cfg.
---@param cfg string
---@return string[]
local function daemons(cfg)
  local out = {}
  for _, pid in ipairs(vim.fn.systemlist({ "pgrep", "-f", "--", "--serve --config" })) do
    local cmd = vim.fn.system({ "ps", "-o", "command=", "-p", pid })
    if cmd:find(" --serve --config " .. cfg, 1, true) then out[#out + 1] = pid end
  end
  return out
end

---stop_on_exit stops the daemon started with cfg, and removes its socket folder, however
---the suite ends: a normal end or an error (VimLeavePre), :qa or :cquit (VimLeavePre too),
---or os.exit, which skips the autocmds, so it is wrapped. TERM, then KILL, until none is left
---(5 s at most).
---@param cfg string
---@param sockdir string
local function stop_on_exit(cfg, sockdir)
  local done = false
  local function stop()
    if done then return end
    done = true
    for i = 1, 20 do
      local pids = daemons(cfg)
      if #pids == 0 then break end
      vim.fn.system(vim.list_extend({ "kill", i > 10 and "-KILL" or "-TERM" }, pids))
      vim.uv.sleep(250)
    end
    vim.fn.delete(sockdir, "rf")
  end
  vim.api.nvim_create_autocmd("VimLeavePre", { callback = function() pcall(stop) end })
  local exit = os.exit
  os.exit = function(...)
    pcall(stop)
    return exit(...)
  end
end

return function(sandbox_root, label)
  local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
  local plugins = vim.fn.fnamemodify(here, ":h:h:h")
  local checkout = vim.env.AF_TEST_AUTODOC
  local bin = vim.env.AF_TEST_AUTODOC_BIN
  if not (checkout and checkout ~= "") then checkout = plugins .. "/autodoc/main" end
  if not (bin and bin ~= "") then bin = checkout .. "/bin/autodoc" end
  if vim.fn.isdirectory(checkout .. "/lua/autodoc") ~= 1 then
    return false, "autodoc.nvim not found (set AF_TEST_AUTODOC, or install-deps.sh): " .. checkout
  end
  if vim.fn.executable(bin) ~= 1 then
    return false, "the autodoc binary is not executable (set AF_TEST_AUTODOC_BIN): " .. bin
  end
  vim.opt.runtimepath:prepend(checkout)
  local root = vim.uv.fs_mkdtemp((sandbox_root or vim.fn.tempname()) .. "/ad-" .. label .. "-XXXXXX")
  for _, d in ipairs({ "state", "data" }) do vim.fn.mkdir(root .. "/" .. d, "p") end
  -- The socket path must stay under autodoc's 100-byte limit, which a deep
  -- sandbox (a long TMPDIR) exceeds, so it lives under /tmp. Not in /tmp itself:
  -- autodoc refuses a socket in a folder others can write (it could be replaced
  -- there), so it gets a folder of its own, mkdtemp's (mode 0700).
  -- The daemon outlives this nvim (autodoc starts it detached). run-all.sh stops it by
  -- the sandbox as well, but a suite run on its own (nvim -l tests/<suite>.lua) has only
  -- the stop below, on every way out (stop_on_exit).
  local sockdir = assert(vim.uv.fs_mkdtemp("/tmp/af-ad-XXXXXX"))
  local sock = string.format("%s/%s.sock", sockdir, label)
  local cfg = root .. "/config.toml"
  local f = assert(io.open(cfg, "w"))
  f:write(table.concat({
    "[server]",
    string.format("socket = %q", sock),
    string.format("state_dir = %q", root .. "/state"),
    string.format("data_dir = %q", root .. "/data"),
  }, "\n") .. "\n")
  f:close()
  local ok, err = pcall(function()
    require("autodoc").setup({ bin = bin, config = cfg, preview = false,
      offer_restart = false, offer_link = false })
  end)
  if not ok then return false, "autodoc.setup failed: " .. tostring(err) end
  stop_on_exit(cfg, sockdir)
  return true
end
