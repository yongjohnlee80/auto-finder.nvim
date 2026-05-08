---Persistent state for auto-finder. Survives nvim restart so the
---user's `panel resize N` pin and other session-spanning preferences
---don't reset every time.
---
---Layout: a single JSON file at
---    `<stdpath('config')>/.auto-finder/config.json`
---
---Schema (current):
---```json
---{
---  "version": 1,
---  "panel": {
---    "user_width": <integer or null>,
---    "side": "left" | "right" | null
---  },
---  "files": {
---    "hide_dotfiles": <bool or null>,
---    "hide_gitignored": <bool or null>
---  }
---}
---```
---
---All fields are optional — missing entries fall back to the
---in-memory defaults supplied by `M.config.apply` (which themselves
---fall back to plugin defaults). Reads are best-effort: a missing,
---empty, or malformed file is treated as "no persisted state" and
---logged via vim.notify(WARN) so the user knows to re-pin if they
---expected something to stick.
---@module 'auto-finder.store'

local M = {}

---Resolve the directory that holds auto-finder's persistent state.
---Lives next to `.auto-agents-config/` for symmetry — both are
---namespaced under `<stdpath('config')>/`.
---@return string
local function dir_path()
  return vim.fn.stdpath("config") .. "/.auto-finder"
end

---@return string
local function file_path()
  return dir_path() .. "/config.json"
end

---Ensure the storage directory exists. Creates it (mode 0700) if not.
---@return string|nil err
local function ensure_dir()
  local d = dir_path()
  if vim.fn.isdirectory(d) == 1 then return nil end
  local ok = vim.fn.mkdir(d, "p", "0700")
  if ok ~= 1 then
    return "mkdir failed: " .. d
  end
  return nil
end

---Read the persisted config. Returns an empty table on any failure
---(missing file, empty file, malformed JSON) — callers treat absence
---as "use defaults". A WARN-level notify fires when the file exists
---but isn't readable / decodable so silent corruption is visible.
---@return table state
function M.load()
  local path = file_path()
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local lines = vim.fn.readfile(path)
  if not lines or #lines == 0 then return {} end
  local raw = table.concat(lines, "\n")
  if raw == "" then return {} end
  local ok, decoded = pcall(vim.fn.json_decode, raw)
  if not ok or type(decoded) ~= "table" then
    vim.notify(
      "auto-finder.store: failed to decode " .. path .. " — defaults will apply: " .. tostring(decoded),
      vim.log.levels.WARN)
    return {}
  end
  return decoded
end

---Write `state` to disk as pretty-printed JSON. Best-effort:
---failures are logged via vim.notify(WARN) but never throw so the
---user's panel operation isn't aborted by a disk hiccup.
---
---Only known top-level keys are persisted. Unknown keys (legacy /
---future / corruption) are stripped on save so we don't accumulate
---cruft. Missing values within known keys are persisted as `null`
---(via `vim.NIL` round-trip), which the loader treats as "use
---default".
---@param state table
function M.save(state)
  local err = ensure_dir()
  if err then
    vim.notify("auto-finder.store: " .. err, vim.log.levels.WARN)
    return
  end
  local sanitized = {
    version = 1,
    panel = {
      user_width = (state.panel or {}).user_width,
      side       = (state.panel or {}).side,
    },
    files = {
      hide_dotfiles   = (state.files or {}).hide_dotfiles,
      hide_gitignored = (state.files or {}).hide_gitignored,
    },
  }
  local ok, encoded = pcall(vim.fn.json_encode, sanitized)
  if not ok then
    vim.notify("auto-finder.store: json_encode failed: " .. tostring(encoded),
      vim.log.levels.WARN)
    return
  end
  local path = file_path()
  -- Pretty-print: human-readable when someone opens the file. Cheap
  -- — single-shot regex replace.
  encoded = encoded
    :gsub('","', '",\n  "')
    :gsub('":{', '": {\n    ')
    :gsub('}}', '\n  }\n}')
    :gsub('{"', '{\n  "')
  local write_ok = pcall(vim.fn.writefile, vim.split(encoded, "\n"), path)
  if not write_ok then
    vim.notify("auto-finder.store: write failed: " .. path, vim.log.levels.WARN)
  end
end

---Convenience: merge a partial update into the on-disk state. Loads
---current, applies a shallow merge, writes back. Used by callers
---that only want to mutate one field (e.g. `M.update({ panel = {
---user_width = 50 } })`).
---@param partial table
function M.update(partial)
  local current = M.load()
  current.version = 1
  for k, v in pairs(partial) do
    if type(v) == "table" then
      current[k] = current[k] or {}
      for kk, vv in pairs(v) do
        current[k][kk] = vv
      end
    else
      current[k] = v
    end
  end
  M.save(current)
end

-- Exposed for tests.
M._dir = dir_path
M._path = file_path

return M
