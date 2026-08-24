---tests/_sandbox.lua — one source of truth for headless XDG isolation.
---
---Every suite must route its XDG roots through this helper rather than
---assigning `vim.env.XDG_*` by hand. Usage, near the top of a suite and
---BEFORE anything that can touch `vim.fn.stdpath()`:
---
---    dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
---      .. "/_sandbox.lua")("adr0048")
---
---The call locates this file from the CALLER's own path rather than from
---a `plugin_root` local, so it works wherever a suite chooses to set up
---its roots — several suites derive `plugin_root` further down the file
---than they set XDG, and an ordering dependency there would be a trap.
---
---Returns the sandbox root (already created). The three XDG vars below
---point inside it.
---
---── Why this file exists ──────────────────────────────────────────────
---
---Suites used to set `XDG_CONFIG_HOME` and `XDG_STATE_HOME` inline and
---leave `XDG_CACHE_HOME` inheriting the real `$HOME/.cache`. That is an
---UNDECLARED DEPENDENCY ON A WRITABLE HOME CACHE, and it made the suite
---environment-sensitive in a way that silently changed results:
---auto-run writes each run under `~/.cache/nvim/auto-run/runs/…`, so on
---a host where that path is read-only the mkdir fails with `E739`, no
---job is ever spawned, and ADR-0048's seven `p46` assertions cascade off
---the missing spawn — 147/7 instead of 154/0. Two agents on the same
---machine and commit got different results for months because of it.
---
---Reproduce the old failure with `XDG_CACHE_HOME` pointed at a
---`chmod 555` directory; with this helper the same run is unaffected.
---
---**`XDG_DATA_HOME` is deliberately NOT redirected.** Installed
---treesitter parsers and plugin data live under it, and redirecting it
---hides them — which fails ADR-0048 for an entirely different reason.
---If you are tempted to add it here, don't; that experiment has been run.
---
---Roots are unique per run. The four suites that predated this helper
---used fixed `/tmp/auto-finder-<name>-{config,state}` paths, which two
---agents running concurrently would race through the same directories.
---When `run-all.sh` exports `AF_TEST_SANDBOX_ROOT` every suite nests
---under that one root so the runner can clean up in a single sweep;
---standalone runs fall back to `tempname()`.
---
---@param label string  short suite name, e.g. "smoke" / "adr0048"
---@return string root  absolute path to the sandbox root
local function sandbox(label)
  label = tostring(label or "suite"):gsub("[^%w%-_]", "-")

  local root
  local shared = vim.env.AF_TEST_SANDBOX_ROOT
  if type(shared) == "string" and shared ~= "" then
    -- run-all.sh owns the parent and deletes it on exit.
    root = shared .. "/" .. label
  else
    -- Standalone run: unique per invocation, so a concurrent run of the
    -- same suite cannot collide with us.
    root = vim.fn.tempname() .. "-" .. label
  end

  -- Fresh every time. A leftover root from a previous run at the same
  -- path would carry state the suite believes it does not have.
  vim.fn.delete(root, "rf")

  local dirs = {
    XDG_CONFIG_HOME = root .. "/config",
    XDG_STATE_HOME  = root .. "/state",
    XDG_CACHE_HOME  = root .. "/cache",
  }
  for var, dir in pairs(dirs) do
    vim.fn.mkdir(dir, "p")
    vim.env[var] = dir
  end

  -- Fail loudly rather than let a suite run against the real home.
  -- A silently-unisolated run is the failure mode this helper exists to
  -- prevent, and it is invisible until some unrelated assertion breaks.
  local home = vim.env.HOME
  for var, dir in pairs(dirs) do
    if vim.fn.isdirectory(dir) ~= 1 then
      error(("tests/_sandbox: %s could not be created at %s"):format(var, dir))
    end
    if vim.fn.filewritable(dir) ~= 2 then
      error(("tests/_sandbox: %s is not writable at %s"):format(var, dir))
    end
    if home and home ~= "" and vim.startswith(dir, home .. "/.") then
      error(("tests/_sandbox: %s resolves inside the real home (%s)")
        :format(var, dir))
    end
  end

  return root
end

return sandbox
