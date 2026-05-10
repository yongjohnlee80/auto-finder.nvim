---Persistent file-filter state for auto-finder. Survives nvim restart
---so the per-session show-dotfiles / show-gitignored toggles don't
---reset every time.
---
---**v0.2.0 step 2/4:** `panel.user_width` (resize pin) and
---`panel.last_section` (last-focused section index) MOVED to
---`auto-core.state.namespace("auto-finder")` json persist — see
---`lua/auto-finder/state.lua`. The save path below STRIPS those keys
---so legacy values eventually drain from this file. The legacy
---*loader* still surfaces them so init.lua's one-shot seed can copy
---them into the namespace on first run after upgrade. Old store
---files containing them are otherwise harmless (the loader returns
---them; setup() seeds; save() strips on next mutation).
---
---Layout: a single JSON file at
---    `<stdpath('config')>/.auto-finder/config.json`
---
---Schema (current — post-step-2):
---```json
---{
---  "version": 1,
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

---Write `state` as pretty-printed JSON. Strips unknown top-level keys
---so legacy / future / corrupted entries never accumulate. v0.2.0
---step 2: also strips `panel.user_width` and `panel.last_section` —
---those live in `auto-core.state.namespace("auto-finder")` now.
---Missing values are persisted as JSON null and treated by the loader
---as "use default".
---@param state table
function M.save(state)
  local sanitized = {
    version = 1,
    -- panel.user_width / panel.last_section are deliberately omitted —
    -- they migrated to auto-core state.namespace in v0.2.0 step 2.
    -- Future cleanup may drop the `panel` table entirely once `side`
    -- (already legacy and ignored on load) ages out of users' files.
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
