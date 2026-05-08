---Thin facade over worktree.nvim. Single source of truth for repo
---discovery, repo→worktree expansion, and the active root — every
---decision (which dirs are git, what counts as a worktree, how the
---bare-vs-`.git` layout is detected) lives in worktree.nvim and
---this module just queries it.
---
---When worktree.nvim isn't installed, every accessor returns an
---empty result. The repos section then renders the empty-state
---placeholder; nothing throws.
---@module 'auto-finder.repos'

local M = {}

local function wt()
  local ok, mod = pcall(require, "worktree")
  if not ok then return nil end
  return mod
end

local function wt_git()
  local ok, mod = pcall(require, "worktree.git")
  if not ok then return nil end
  return mod
end

---The root directory worktree.nvim is scanning. Captured at its
---VimEnter (or set explicitly via `require("worktree").set_root(p)`).
---@return string|nil
function M.root()
  local mod = wt()
  if not mod then return nil end
  if type(mod.get_root) == "function" then
    local r = mod.get_root()
    if r then return r end
  end
  if type(mod.ensure_root) == "function" then
    return mod.ensure_root()
  end
  return nil
end

---List the discovered repos under worktree.nvim's root. Each entry
---is an absolute path. Includes the root itself when the root is a
---git repo (the case worktree.nvim's `list_child_repos` doesn't
---cover — it only walks immediate children, so opening nvim inside
---a single-repo directory like `~/.config/nvim` would otherwise
---show "no repos"). Children come after the root, sorted by
---worktree.nvim's `list_child_repos` order (alphabetical).
---@return string[]
function M.load()
  local g = wt_git()
  local root = M.root()
  if not g or not root then return {} end
  local out = {}
  if type(g.is_git) == "function" and g.is_git(root) then
    table.insert(out, root)
  end
  if type(g.list_child_repos) == "function" then
    for _, r in ipairs(g.list_child_repos(root) or {}) do
      if type(r) == "table" and type(r.path) == "string" then
        table.insert(out, r.path)
      end
    end
  end
  return out
end

---Flat list of every non-bare worktree path across all discovered
---repos. Used by consumer keymaps that want to scope picker queries
---to the active workspace (e.g. an `<leader><leader>` files-finder).
---Mirrors `M.load`'s root-inclusion logic — `worktree.collect_worktrees`
---only walks children, so we run `git worktree list --porcelain`
---against the root separately when it's itself a repo.
---@return string[]
function M.worktree_paths()
  local g = wt_git()
  local root = M.root()
  if not g or not root then return {} end
  local out = {}
  -- Root's own worktrees, when root is a git repo.
  if type(g.is_git) == "function" and g.is_git(root) and type(g.parse_porcelain) == "function" then
    local lines = vim.fn.systemlist({
      "git", "-C", root, "worktree", "list", "--porcelain",
    })
    if vim.v.shell_error == 0 then
      for _, t in ipairs(g.parse_porcelain(lines) or {}) do
        if not t.bare and type(t.path) == "string" then
          table.insert(out, t.path)
        end
      end
    end
  end
  -- Worktrees of immediate-child repos.
  if type(g.collect_worktrees) == "function" then
    for _, t in ipairs(g.collect_worktrees(root) or {}) do
      if not t.bare and type(t.path) == "string" then
        table.insert(out, t.path)
      end
    end
  end
  return out
end

return M
