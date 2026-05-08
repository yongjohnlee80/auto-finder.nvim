---Persistent panel + filter state for auto-finder. Survives nvim
---restart so `panel resize N`, the active section, and per-session
---file-filter prefs don't reset every time.
---
---Layout: a single JSON file at
---    `<stdpath('config')>/.auto-finder/config.json`
---
---Schema (current):
---```json
---{
---  "version": 1,
---  "panel": {
---    "user_width":   <integer or null>,
---    "side":         "left" | "right" | null,    // legacy, ignored on load
---    "last_section": <integer or null>           // restored on next open
---  },
---  "files": {
---    "hide_dotfiles":   <bool or null>,
---    "hide_gitignored": <bool or null>
---  }
---}
---```
---
---All fields are optional — missing entries fall back to in-memory
---defaults from `auto-finder.config`. Reads are best-effort via
---`auto-finder._storage` (a missing/malformed file → empty table).
---
---Repo-registry state is intentionally NOT persisted here — see
---`auto-finder.repos` for that, in its own `repos.json`.
---@module 'auto-finder.store'

local storage = require("auto-finder._storage")

local M = {}

local FILENAME = "config.json"

---Read the persisted state. Empty table on any failure.
---@return table state
function M.load()
  return storage.read_json(FILENAME)
end

---Write `state` as pretty-printed JSON. Strips unknown top-level
---keys so legacy / future / corrupted entries never accumulate.
---Missing values are persisted as JSON null and treated by the
---loader as "use default".
---@param state table
function M.save(state)
  local sanitized = {
    version = 1,
    panel = {
      user_width   = (state.panel or {}).user_width,
      side         = (state.panel or {}).side,
      last_section = (state.panel or {}).last_section,
    },
    files = {
      hide_dotfiles   = (state.files or {}).hide_dotfiles,
      hide_gitignored = (state.files or {}).hide_gitignored,
    },
  }
  storage.write_json(FILENAME, sanitized)
end

---Shallow-merge `partial` into the on-disk state. Used when callers
---want to mutate one field (e.g. `M.update({ panel = { user_width
---= 50 } })`) without touching the rest.
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
M._dir = storage.dir_path
M._path = function() return storage.dir_path() .. "/" .. FILENAME end

return M
