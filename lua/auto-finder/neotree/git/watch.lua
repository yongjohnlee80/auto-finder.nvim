local fs_watch = require("auto-finder.neotree.sources.filesystem.lib.fs_watch")
local events = require("auto-finder.neotree.events")
local log = require("auto-finder.neotree.log")
local M = {}

---@param worktree_root string?
---@param git_dir string?
M.watch = function(worktree_root, git_dir)
  if not git_dir or not worktree_root then
    return
  end
  local watcher = fs_watch.watch_folder(git_dir, function(err, fname)
    if fname then
      if vim.endswith(fname, ".lock") then
        return
      end
      if fname:find("_null-ls_", 1, true) then
        -- null-ls temp file: https://github.com/jose-elias-alvarez/null-ls.nvim/pull/1075
        return
      end
    end

    if err then
      log.error("git_event_callback: ", err)
      return
    end
    vim.schedule(function()
      events.fire_event(events.GIT_EVENT)
    end)
  end)
  fs_watch.updated_watched()
  return watcher
end

return M
