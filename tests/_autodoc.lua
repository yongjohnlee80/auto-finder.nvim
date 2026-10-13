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
  -- sandbox (a long TMPDIR) exceeds; it lives in /tmp under this process's pid.
  -- The daemon is stopped by run-all.sh (its --config names this sandbox).
  local sock = string.format("/tmp/af-ad-%d-%s.sock", vim.uv.os_getpid(), label)
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
  return true
end
