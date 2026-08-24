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

  ---Absolute, symlink-resolved form of an EXISTING path. Returns nil
  ---when it does not exist. Canonicalising matters before any
  ---containment check: `/tmp/x/../../home/you` and a symlinked parent
  ---both defeat a naive string prefix test.
  local function realpath(p)
    if type(p) ~= "string" or p == "" then return nil end
    local ok, resolved = pcall(vim.uv.fs_realpath, vim.fn.fnamemodify(p, ":p"))
    if ok and type(resolved) == "string" then return resolved end
    return nil
  end

  ---Create a directory atomically from a `XXXXXX` template. One syscall
  ---picks the name AND creates it, which is what makes the result
  ---exclusively ours: an `fs_stat` probe followed by a separate `mkdir`
  ---is check-then-act and races between processes.
  local function mkdtemp(template)
    -- Synchronous luv calls return `nil, err, code` on failure, so bind
    -- all three: capturing only the first discards the reason and every
    -- ordinary failure reports a bare "(nil)".
    local ok, created, err, code = pcall(vim.uv.fs_mkdtemp, template)
    if not ok then
      error(("tests/_sandbox: fs_mkdtemp(%s) raised: %s")
        :format(template, tostring(created)))
    end
    if type(created) ~= "string" or created == "" then
      error(("tests/_sandbox: could not create sandbox root from %s: %s (%s)")
        :format(template, tostring(err), tostring(code)))
    end
    return created
  end

  local home = realpath(vim.env.HOME)
  ---Reject the home directory itself and EVERY descendant of it — not
  ---just dotfile children. An earlier version tested only
  ---`$HOME/.`-prefixed paths, which let `$HOME/anything` through.
  local function under_home(p)
    if type(p) ~= "string" or p == "" then
      error("tests/_sandbox: under_home() got a non-path; refusing to guess")
    end
    if not home then return false end
    return p == home or vim.startswith(p, home .. "/")
  end

  local root
  local shared = vim.env.AF_TEST_SANDBOX_ROOT
  if type(shared) == "string" and shared ~= "" then
    -- run-all.sh owns the parent and deletes it on exit. It is caller
    -- input, so it is validated BEFORE anything here mutates the disk.
    local parent = realpath(shared)
    if not parent then
      error(("tests/_sandbox: AF_TEST_SANDBOX_ROOT does not exist: %s")
        :format(shared))
    end
    if vim.fn.isdirectory(parent) ~= 1 then
      error(("tests/_sandbox: AF_TEST_SANDBOX_ROOT is not a directory: %s")
        :format(parent))
    end
    if under_home(parent) then
      error(("tests/_sandbox: refusing to sandbox under the home directory: %s")
        :format(parent))
    end
    -- ATOMIC exclusive create. `fs_mkdtemp` picks the name AND creates
    -- it in one syscall, so there is no check-then-act window and no
    -- way to land on a directory we did not create.
    --
    -- A `tempname()`-derived suffix is NOT unique: nvim's tempname is
    -- `<process-private-dir>/<counter>` and the counter restarts at 0
    -- in every fresh process, so `:t` was "0" for all of them and two
    -- same-label processes derived the identical `<parent>/<label>-0`.
    -- Under a forced interleaving both passed the old fs_stat probe.
    root = mkdtemp(parent .. "/" .. label .. "-XXXXXX")
  else
    -- Standalone run. Two properties matter and the first cut had
    -- neither:
    --
    --  1. VALIDATE BEFORE MUTATING. Creating first and checking
    --     containment afterwards left an orphan directory behind under
    --     a HOME-contained TMPDIR -- the rejection fired, but only
    --     after the mkdir.
    --  2. Create inside Neovim's PROCESS-PRIVATE temp directory (the
    --     dirname of `tempname()`), which Neovim sweeps on exit.
    --     Creating directly under `os_tmpdir()` leaked a whole
    --     config/state/cache tree on every standalone run; the
    --     original full-tempname path had this property for free and
    --     the round-2 rewrite threw it away.
    local managed = realpath(vim.fn.fnamemodify(vim.fn.tempname(), ":h"))
    if not managed then
      error("tests/_sandbox: could not resolve Neovim's managed temp dir")
    end
    if under_home(managed) then
      error(("tests/_sandbox: refusing to sandbox under the home directory: %s")
        :format(managed))
    end
    root = mkdtemp(managed .. "/" .. label .. "-XXXXXX")
  end


  local canonical = realpath(root) or root
  if under_home(canonical) then
    error(("tests/_sandbox: sandbox root resolves under the home directory: %s")
      :format(canonical))
  end

  local dirs = {
    XDG_CONFIG_HOME = canonical .. "/config",
    XDG_STATE_HOME  = canonical .. "/state",
    XDG_CACHE_HOME  = canonical .. "/cache",
  }
  for var, dir in pairs(dirs) do
    vim.fn.mkdir(dir, "p")
    vim.env[var] = dir
  end

  -- Fail loudly rather than let a suite run against the real home.
  -- A silently-unisolated run is the failure mode this helper exists to
  -- prevent, and it is invisible until some unrelated assertion breaks.
  for var, dir in pairs(dirs) do
    if vim.fn.isdirectory(dir) ~= 1 then
      error(("tests/_sandbox: %s could not be created at %s"):format(var, dir))
    end
    if vim.fn.filewritable(dir) ~= 2 then
      error(("tests/_sandbox: %s is not writable at %s"):format(var, dir))
    end
    if under_home(realpath(dir) or dir) then
      error(("tests/_sandbox: %s resolves inside the real home (%s)")
        :format(var, dir))
    end
  end

  return canonical
end

return sandbox
