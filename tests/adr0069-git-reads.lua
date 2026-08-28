-- tests/adr0069-git-reads.lua - auto-finder call-site controls for ADR-0069.
--
-- Run: nvim --headless -u NONE -l tests/adr0069-git-reads.lua

dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/_sandbox.lua")("adr0069-git-reads")

local this = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local plugin_root = vim.fn.fnamemodify(this, ":h")
local plugins_root = vim.fn.fnamemodify(plugin_root, ":h:h")
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
for _, path in ipairs({
  LAZY .. "/nui.nvim",
  LAZY .. "/plenary.nvim",
  plugins_root .. "/auto-core.nvim/main",
  plugin_root,
}) do
  if vim.fn.isdirectory(path) == 1 then
    vim.opt.runtimepath:prepend(path)
  end
end
vim.o.swapfile = false

local pass, fail = 0, 0
local function ok(name, condition, detail)
  local line = condition and ("  PASS  " .. name)
    or ("  FAIL  " .. name .. (detail and ("  - " .. tostring(detail)) or ""))
  io.stdout:write(line:gsub("[\r\n]+", " "), "\n")
  io.stdout:flush()
  if condition then pass = pass + 1 else fail = fail + 1 end
end

local warnings = {}
local fake_log = {
  warn = function(message) warnings[#warnings + 1] = tostring(message) end,
  debug = function() end,
  trace = function() end,
  error = function() end,
  at = { warn = { format = function() return "warning" end } },
}
fake_log.assert = function(value, message, ...)
  if not value then
    if select("#", ...) > 0 then message = string.format(message, ...) end
    error(message or "assertion failed")
  end
  return value
end

local function reset_module(name)
  package.loaded[name] = nil
end

local function same_list(actual, expected)
  if #actual ~= #expected then return false end
  for i, value in ipairs(expected) do
    if actual[i] ~= value then return false end
  end
  return true
end

io.stdout:write("ADR-0069 - auto-finder git-read call sites\n")

-- Completion consumes list_refs as-is: full-ref lexical ordering and duplicate
-- handling belong to auto-core, while this compatibility layer adds the key
-- prefix and HEAD only for a non-empty successful result.
;(function()
  local refs_result, refs_error
  local calls = {}
  package.loaded["auto-finder.neotree.command.parser"] = {
    parse = function() return {} end,
    resolve_path = function(path) return path end,
    list_args = {}, path_args = {}, ref_args = { "git_base" }, reverse_lookup = {},
    argtypes = { REF = "ref", PATH = "path", LIST = "list" },
    argtype_lookup = { git_base = "ref" }, arguments = {},
  }
  package.loaded["auto-finder.neotree.log"] = fake_log

  local function load_completion()
    package.loaded["auto-core.git"] = {
      worktree = { list_refs = function(path)
        calls[#calls + 1] = path
        return refs_result, refs_error
      end },
    }
    reset_module("auto-finder.neotree.command.completion")
    return require("auto-finder.neotree.command.completion")
  end

  refs_result = { "feature", "same", "same", "origin/HEAD", "topic" }
  refs_error = nil
  local completion = load_completion()
  local output = completion.complete_args("git_base=", "Neotree")
  ok("[1] completion preserves order, duplicates, and remote HEAD",
    output == table.concat({
      "git_base=HEAD", "git_base=feature", "git_base=same", "git_base=same",
      "git_base=origin/HEAD", "git_base=topic",
    }, "\n"), output)
  ok("[1] completion passes the current cwd", #calls == 1 and calls[1] == vim.fn.getcwd())

  refs_result = {}
  calls = {}
  completion = load_completion()
  ok("[1] an empty repository has no candidates",
    completion.complete_args("git_base=", "Neotree") == "")
  ok("[1] empty completion still performs exactly one semantic read", #calls == 1)

  refs_result, refs_error = nil, "not a repository"
  calls = {}
  completion = load_completion()
  ok("[1] a repository error has no candidates",
    completion.complete_args("git_base=", "Neotree") == "")

  warnings = {}
  refs_result, refs_error = nil, "Git 2.15+ required"
  completion = load_completion()
  completion.complete_args("git_base=", "Neotree")
  completion.complete_args("git_base=", "Neotree")
  ok("[1] completion warns once for the Git floor",
    #warnings == 1 and warnings[1] == "Git 2.15+ required", vim.inspect(warnings))
end)()

-- Parser validation must pass cwd and the unmodified ref as two API arguments.
-- The mock models rev_exists_at's commit-ish contract so this remains a
-- call-site test rather than duplicating auto-core's process tests.
;(function()
  local calls = {}
  local accepted = { main = true, lightweight = true, annotated = true }
  local mode = "normal"
  package.loaded["auto-core.git"] = {
    log = { rev_exists_at = function(path, ref)
      calls[#calls + 1] = { path, ref }
      if mode == "unsupported" then return false, "Git 2.15+ required" end
      return accepted[ref] == true
    end },
  }
  package.loaded["auto-finder.neotree.log"] = fake_log
  package.loaded["auto-finder.neotree"] = { ensure_config = function() end }
  reset_module("auto-finder.neotree.command.parser")
  local parser = require("auto-finder.neotree.command.parser")
  parser.setup({ "filesystem" })

  local original_cwd = vim.fn.getcwd()
  local repo_a = vim.fn.tempname()
  local repo_b = vim.fn.tempname()
  vim.fn.mkdir(repo_a, "p")
  vim.fn.mkdir(repo_b, "p")
  vim.cmd("cd " .. vim.fn.fnameescape(repo_a))
  parser.parse({ "git_base=main" }, true)
  vim.cmd("cd " .. vim.fn.fnameescape(repo_b))
  parser.parse({ "git_base=main" }, true)
  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  ok("[2] parser selects each repository from current cwd",
    calls[1][1] == repo_a and calls[2][1] == repo_b, vim.inspect(calls))

  for _, ref in ipairs({ "main", "lightweight", "annotated" }) do
    local parsed = parser.parse({ "git_base=" .. ref }, true)
    ok("[2] parser accepts commit-ish " .. ref, parsed.git_base == ref)
  end
  for _, ref in ipairs({ "blob", "tree", "missing" }) do
    local parsed_ok = pcall(parser.parse, { "git_base=" .. ref }, true)
    ok("[2] parser rejects non-commit-ish " .. ref, not parsed_ok)
  end

  local marker = vim.fn.tempname()
  os.remove(marker)
  local injection = "main;touch${IFS}" .. marker
  local before = #calls
  pcall(parser.parse, { "git_base=" .. injection }, true)
  ok("[2] parser passes metacharacters as one unchanged ref argument",
    #calls == before + 1 and calls[#calls][2] == injection, vim.inspect(calls[#calls]))
  ok("[2] parser validation cannot execute the injected side effect",
    vim.uv.fs_stat(marker) == nil)

  before = #calls
  pcall(parser.parse, { "git_base=--help" }, true)
  ok("[2] option-shaped input remains a value, not process grammar",
    #calls == before + 1 and calls[#calls][2] == "--help")

  warnings = {}
  mode = "unsupported"
  local strict_ok, strict_err = pcall(parser.parse, { "git_base=main" }, true)
  local loose_ok, loose = pcall(parser.parse, { "git_base=main" }, false)
  parser.parse({ "git_base=main" }, false)
  ok("[2] strict parsing raises the explicit Git floor",
    not strict_ok and tostring(strict_err):find("Git 2.15+ required", 1, true) ~= nil,
    strict_err)
  ok("[2] non-strict parsing suppresses the floor error",
    loose_ok and loose.git_base == nil)
  ok("[2] parser warns only once for unsupported Git", #warnings == 1, vim.inspect(warnings))

  local pos_dir = vim.fn.tempname() .. "-posdir"
  vim.fn.mkdir(pos_dir, "p")
  local pos_file = pos_dir .. "/a.txt"
  vim.fn.writefile({ "x" }, pos_file)
  local pos_parse_ok, pos_dir_result = pcall(parser.parse, { pos_dir }, true)
  ok("[2] positional directory still resolves under the Git floor",
    pos_parse_ok and pos_dir_result.dir == pos_dir, vim.inspect(pos_dir_result))
  local pos_file_ok, pos_file_result = pcall(parser.parse, { pos_file }, true)
  ok("[2] positional file still resolves under the Git floor",
    pos_file_ok and pos_file_result.reveal_file == pos_file, vim.inspect(pos_file_result))
  local neither_ok, neither_err = pcall(parser.parse, { "not-a-ref-not-a-path" }, true)
  ok("[2] positional neither ref nor path surfaces the floor reason",
    not neither_ok and tostring(neither_err):find("Git 2.15+ required", 1, true) ~= nil,
    neither_err)
  vim.fn.delete(pos_dir, "rf")
 end)()

local status_builds = 0
local function version_at_least(version, major, minor, patch)
  patch = patch or 0
  local actual_patch = version.patch or 0
  if version.major ~= major then return version.major > major end
  if version.minor ~= minor then return version.minor > minor end
  return actual_patch >= patch
end

local function load_git(core_git)
  status_builds = 0
  package.loaded["auto-core.git"] = core_git
  package.loaded["auto-finder.neotree.log"] = fake_log
  package.loaded["auto-finder.neotree.git.utils"] = {
    run_coroutine_on_interval = function() end,
  }
  package.loaded["auto-finder.neotree.git.cmd"] = {
    with_args = function(args)
      status_builds = status_builds + 1
      local command = { "git" }
      for _, arg in ipairs(args) do command[#command + 1] = arg end
      return command
    end,
  }
  package.loaded["auto-finder.neotree.git.ls-files"] = {}
  package.loaded["auto-finder.neotree.git.diff"] = {}
  package.loaded["auto-finder.neotree.git.parser"] = {
    parse_status_porcelain = function() return {} end,
  }
  package.loaded["auto-finder.neotree.events"] = {
    BEFORE_GIT_STATUS = "before", GIT_STATUS_CHANGED = "changed",
    fire_event = function() end,
  }
  package.loaded["auto-finder.neotree"] = {
    config = {
      filesystem = { use_libuv_file_watcher = false },
      git_status_scope_to_path = false,
    },
  }
  reset_module("auto-finder.neotree.git")
  return require("auto-finder.neotree.git")
end

-- Discovery wrapper: one sync call or one async call, positional compatibility,
-- failure delivery, cwd capture, and the fork's Windows spelling policy.
;(function()
  local sync_calls, async_calls = {}, {}
  local sync_result = {
    ok = true, worktree_root = "/repo", git_dir = "/repo/.git",
    superproject_worktree_root = "/super",
  }
  local async_result = sync_result
  local core = {
    version_at_least = function() return true end,
    repo = {
      discover = function(path)
        sync_calls[#sync_calls + 1] = path
        return sync_result
      end,
      discover_async = function(path, callback)
        async_calls[#async_calls + 1] = path
        callback(async_result)
      end,
    },
  }
  local git = load_git(core)
  local root, git_dir, super = git.find_worktree_info("/input")
  ok("[3] sync discovery calls repo.discover exactly once",
    #sync_calls == 1 and #async_calls == 0 and sync_calls[1] == "/input")
  ok("[3] sync discovery preserves positional API",
    root == "/repo" and git_dir == "/repo/.git" and super == "/super")

  local callback_count, callback_values = 0
  git.find_worktree_info("/async", function(...)
    callback_count = callback_count + 1
    callback_values = { ... }
  end)
  ok("[3] async discovery calls repo.discover_async exactly once",
    #async_calls == 1 and #sync_calls == 1 and async_calls[1] == "/async")
  ok("[3] async compatibility callback fires exactly once",
    callback_count == 1 and same_list(callback_values, { "/repo", "/repo/.git", "/super" }))

  async_result = { ok = false, kind = "not_repo", error = "not a repository" }
  callback_count, callback_values = 0, { "sentinel" }
  git.find_worktree_info("/missing", function(...)
    callback_count = callback_count + 1
    callback_values = { ... }
  end)
  ok("[3] async failure still delivers exactly once with nil positions",
    callback_count == 1 and callback_values[1] == nil and callback_values[2] == nil
      and callback_values[3] == nil)

  local before_async = #async_calls
  local callback_ok = pcall(git.find_worktree_info, "/bad-callback", true)
  ok("[3] invalid callback raises before discovery starts",
    not callback_ok and #async_calls == before_async)

  sync_calls = {}
  git.find_worktree_info(nil)
  ok("[3] nil path captures and passes cwd once",
    #sync_calls == 1 and sync_calls[1] == (vim.uv or vim.loop).cwd())

  local utils = require("auto-finder.neotree.utils")
  local restore_windows = utils._set_is_windows(true)
  sync_result = {
    ok = true, worktree_root = "C:/repo", git_dir = "C:/repo/.git",
    superproject_worktree_root = "/msys/super",
  }
  root, git_dir, super = git.find_worktree_info("C:/input")
  restore_windows()
  ok("[3] Windows wrapper converts drive paths but preserves MSYS roots",
    root == "C:\\repo" and git_dir == "C:\\repo\\.git" and super == "/msys/super",
    vim.inspect({ root, git_dir, super }))
end)()

-- M.status has its own floor gate after discovery. This ensures no status
-- process starts even if a future discovery implementation accidentally
-- returns a root for an unsupported version.
;(function()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  vim.system({ "git", "init", "-q", repo }, {}):wait()

  for _, version in ipairs({
    { major = 2, minor = 11 }, { major = 2, minor = 12 },
    { major = 2, minor = 13 }, { major = 2, minor = 14 },
  }) do
    local core = {
      version = function() return vim.deepcopy(version) end,
      version_at_least = function(major, minor, patch)
        return version_at_least(version, major, minor, patch)
      end,
      repo = {
        discover = function()
          return { ok = true, worktree_root = repo, git_dir = repo .. "/.git" }
        end,
      },
    }
    local git = load_git(core)
    local result = git.status(repo)
    ok(("[4] Git %d.%d is below the status floor"):format(version.major, version.minor),
      result == nil and status_builds == 0, status_builds)
  end

  for _, version in ipairs({ { major = 2, minor = 15 }, { major = 3, minor = 0 } }) do
    local core = {
      version = function() return vim.deepcopy(version) end,
      version_at_least = function(major, minor, patch)
        return version_at_least(version, major, minor, patch)
      end,
      repo = {
        discover = function()
          return { ok = true, worktree_root = repo, git_dir = repo .. "/.git" }
        end,
      },
    }
    local git = load_git(core)
    local status_ok = pcall(git.status, repo)
    ok(("[4] Git %d.%d selects porcelain v2"):format(version.major, version.minor),
      status_ok and git._supported_status_porcelain_version == 2 and status_builds == 1,
      vim.inspect({ status_ok, git._supported_status_porcelain_version, status_builds }))
  end

  local core = {
    version = function() return nil, "missing git" end,
    version_at_least = function() return false end,
    repo = {
      discover = function()
        return { ok = false, kind = "unsupported", error = "Git 2.15+ required" }
      end,
    },
  }
  warnings = {}
  local git = load_git(core)
  local result = git.status(repo)
  ok("[4] unsupported discovery starts no status process", result == nil and status_builds == 0)
  ok("[4] status path warns once for the Git floor", #warnings == 1, vim.inspect(warnings))
end)()

-- A synchronous filesystem scan must finish repository discovery before the
-- scan renders. This drives the real fs_scan entrypoint over a real directory;
-- only its collaborators are replaced with recorders.
;(function()
  local scan_root = vim.fn.tempname()
  vim.fn.mkdir(scan_root, "p")
  vim.fn.writefile({ "content" }, scan_root .. "/file.txt")
  local order = {}
  local git = {
    worktrees = {},
    find_worktree_info = function(path)
      order[#order + 1] = "discover:" .. path
      return path, path .. "/.git"
    end,
    _find_existing_status_code_in_git_status = function() end,
  }
  package.loaded["auto-finder.neotree.git"] = git
  package.loaded["auto-finder.neotree.git.utils"] = {
    might_be_in_git_repo = function(path) return path end,
  }
  package.loaded["auto-finder.neotree.git.check-ignore"] = {
    check = function() return {} end,
  }
  package.loaded["auto-finder.neotree.ui.renderer"] = {
    acquire_window = function() end,
    show_nodes = function(_, _, _, callback)
      order[#order + 1] = "render"
      if callback then callback() end
    end,
    get_expanded_nodes = function() return {} end,
    select_nodes = function() return {} end,
  }
  package.loaded["auto-finder.neotree.sources.filesystem.lib.fs_watch"] = {
    updated_watched = function() end,
  }
  package.loaded["auto-finder.neotree.sources.filesystem.lib.ignored"] = {
    mark_ignored = function() end,
  }
  package.loaded["auto-finder.neotree.sources.common.file-nesting"] = {
    get_nesting_callback = function() end,
    nest_items = function() end,
  }
  package.loaded["auto-finder.neotree"] = {
    config = {
      enable_git_status = true,
      sort_case_insensitive = false,
      filesystem = { scan_mode = "shallow" },
    },
  }
  reset_module("auto-finder.neotree.sources.common.file-items")
  reset_module("auto-finder.neotree.sources.filesystem.lib.fs_scan")
  local fs_scan = require("auto-finder.neotree.sources.filesystem.lib.fs_scan")
  local state = {
    path = scan_root,
    async_directory_scan = "never",
    enable_git_status = true,
    use_libuv_file_watcher = false,
    sort_function_override = function(a, b) return a.path < b.path end,
    filtered_items = {
      hide_gitignored = true,
      never_show = {}, never_show_by_pattern = {},
      always_show = {}, always_show_by_pattern = {},
      hide_by_name = {}, hide_by_pattern = {},
    },
  }
  fs_scan.get_items_sync(state, nil, nil, function() end)
  vim.wait(100, function() return order[#order] == "render" end, 5)
  ok("[5] fs scan performs synchronous discovery exactly once",
    order[1] == "discover:" .. scan_root
      and #vim.tbl_filter(function(value) return vim.startswith(value, "discover:") end, order) == 1,
    vim.inspect(order))
  ok("[5] fs discovery completes before render",
    same_list(order, { "discover:" .. scan_root, "render" }), vim.inspect(order))
end)()

-- The command must synchronously discover and mutate git_base state before it
-- decides whether navigation is forced.
;(function()
  local order = {}
  local state = { path = "/repo", current_position = "left" }
  package.loaded["auto-finder.neotree.command.parser"] = {}
  package.loaded["auto-finder.neotree.command.completion"] = { complete_args = function() end }
  package.loaded["auto-finder.neotree.log"] = fake_log
  package.loaded["auto-finder.neotree.sources.manager"] = {
    get_state = function() return state end,
    navigate = function(current)
      order[#order + 1] = "navigate:" .. tostring(current.git_base_by_worktree["/repo"])
    end,
  }
  package.loaded["auto-finder.neotree.ui.renderer"] = {
    window_exists = function() return false end,
    close = function() return false end,
  }
  package.loaded["auto-finder.neotree.ui.inputs"] = {}
  package.loaded["auto-finder.neotree.git"] = {
    find_worktree_info = function(path)
      order[#order + 1] = "discover:" .. path
      return "/repo", "/repo/.git"
    end,
  }
  package.loaded["auto-finder.neotree"] = {
    config = {
      default_source = "filesystem", sources = { "filesystem" },
      filesystem = { window = { position = "left" } },
    },
    ensure_config = function() end,
  }
  reset_module("auto-finder.neotree.command")
  local command = require("auto-finder.neotree.command")
  command.execute({ action = "focus", source = "filesystem", dir = "/repo", git_base = "main" })
  ok("[6] command discovery and state mutation precede navigation",
    same_list(order, { "discover:/repo", "navigate:main" }), vim.inspect(order))
end)()

-- The removed watch call is tested through the real callback, not a source
-- count: a git-dir event still publishes GIT_EVENT without any discovery.
;(function()
  local watch_callback, discovery_calls, event_calls = nil, 0, 0
  package.loaded["auto-finder.neotree.sources.filesystem.lib.fs_watch"] = {
    watch_folder = function(_, callback) watch_callback = callback; return "watcher" end,
    updated_watched = function() end,
  }
  package.loaded["auto-finder.neotree.events"] = {
    GIT_EVENT = "git-event",
    fire_event = function(event) if event == "git-event" then event_calls = event_calls + 1 end end,
  }
  package.loaded["auto-finder.neotree.log"] = fake_log
  package.loaded["auto-finder.neotree.git"] = {
    find_worktree_info = function() discovery_calls = discovery_calls + 1 end,
  }
  reset_module("auto-finder.neotree.git.watch")
  local watch = require("auto-finder.neotree.git.watch")
  local watcher = watch.watch("/repo", "/repo/.git")
  watch_callback(nil, "index")
  vim.wait(100, function() return event_calls == 1 end, 5)
  ok("[7] watch remains active and publishes its event", watcher == "watcher" and event_calls == 1)
  ok("[7] watch callback performs no repository discovery", discovery_calls == 0)
end)()

io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
io.stdout:flush()
if fail > 0 then os.exit(1) end
os.exit(0)
