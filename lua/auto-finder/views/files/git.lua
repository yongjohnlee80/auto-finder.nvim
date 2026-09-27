---auto-finder.views.files.git — filename git colours for the files slot (ADR-0200 §4.6).
---
---Data comes from auto-core.git.status.get_async (porcelain v2 -z, --no-optional-locks, ignored entries
---included, one shared subprocess per repo). This module turns those entries into a per-path colour code
---with the retired fork's exact rules, so the parity goldens hold:
---
---  * a file's code: `?` untracked, `!` ignored, else the WORKTREE side (Y) when it changed and the entry is
---    not a conflict, else the STAGED side (X); a changed side maps M/U → modified, R → renamed,
---    D → deleted, anything else → added;
---  * a directory takes the highest-priority code among its descendants, by `U?MADTRC.` (a record's
---    priority is the stronger of its two sides); ignored records are exact-path only and never bubble;
---  * a path with no record of its own inherits `?` / `!` from its nearest recorded ancestor (a
---    `?? dir/` / `!! dir/` record stands for the whole subtree).
---@module 'auto-finder.views.files.git'

local M = {}

local PRIORITY = "U?MADTRC."

local function side(c)
  if c == "M" or c == "U" then return "modified" end
  if c == "R" then return "renamed" end
  if c == "D" then return "deleted" end
  return "added"
end

local function is_conflict(x, y)
  return (x == y and (x == "A" or x == "D")) or x == "U" or y == "U"
end

---Colour code for a status string ("XY" with "." for unchanged, a single bubbled char, "?" or "!").
---@param status string?
---@return string?
function M.code(status)
  if not status then return nil end
  if status == "?" then return "untracked" end
  if status == "!" then return "ignored" end
  local x, y = status:sub(1, 1), status:sub(2, 2)
  if not is_conflict(x, y) and y ~= "" and y ~= "." then return side(y) end
  if x ~= "" and x ~= "." then return side(x) end
  return nil
end

local function dirname(p)
  local d = p:match("^(.*)/[^/]*$")
  return d
end

---Build the path → status table for one repo from auto-core entries, bubbling to directories.
---@param entries AutoCoreGitStatusEntry[]
---@param repo_root string  absolute, normalized
---@return table<string, string>
function M.build(entries, repo_root)
  local status, records, ignored = {}, {}, {}
  for _, e in ipairs(entries) do
    local rel = e.path:gsub("/$", "")
    local abs = repo_root .. "/" .. rel
    local x = e.status_x == " " and "." or e.status_x
    local y = e.status_y == " " and "." or e.status_y
    if x == "!" then
      ignored[#ignored + 1] = abs
    elseif x == "?" then
      status[abs] = "?"
      records[#records + 1] = { abs, "?" }
    else
      status[abs] = x .. y
      records[#records + 1] = { abs, x .. y }
    end
  end
  -- Bubble: walk records strongest-first; a parent keeps the first (strongest) status that reaches it.
  local buckets = {}
  for _, r in ipairs(records) do
    local s = r[2]
    local pa = PRIORITY:find(s:sub(1, 1), 1, true) or #PRIORITY
    local pb = #s > 1 and (PRIORITY:find(s:sub(2, 2), 1, true) or #PRIORITY) or pa
    local p = math.min(pa, pb)
    buckets[p] = buckets[p] or {}
    table.insert(buckets[p], r[1])
  end
  local parents = {}
  for p = 1, #PRIORITY - 1 do
    for _, path in ipairs(buckets[p] or {}) do
      local parent = dirname(path)
      while parent and #parent > #repo_root and parents[parent] == nil do
        parents[parent] = PRIORITY:sub(p, p)
        parent = dirname(parent)
      end
    end
  end
  for parent, s in pairs(parents) do status[parent] = s end
  for _, abs in ipairs(ignored) do status[abs] = "!" end
  return status
end

---Code for `path` inside the repo whose table is `status`.
---@param status table<string, string>
---@param repo_root string
---@param path string
---@return string?
function M.lookup(status, repo_root, path)
  local s = status[path]
  if s then return M.code(s) end
  local parent = dirname(path)
  while parent and #parent >= #repo_root do
    s = status[parent]
    if s then
      if s == "!" or s == "?" then return M.code(s) end
      return nil
    end
    parent = dirname(parent)
  end
  return nil
end

return M
