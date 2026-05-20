---Owns the auto-finder dbase state directory and the user-facing
---connection-file + connection-entry operations driven from the
---config-section REPL.
---
---Layout under `vim.fn.stdpath("state") .. "/auto-finder/dbase/"`:
---
---  _active.json     pinned target for dbee's FileSource. Never listed
---                   in `dbase ls`; never created/removed by the user
---                   directly. Its contents are overwritten by
---                   `dbase load <name>` and mutated by `dbase conn add/rm`.
---  <name>.json      one user-managed connection-file per name. The
---                   "library" the user picks from with `dbase load`.
---
---The active name (the `<name>` whose contents currently populate
---`_active.json`) is persisted via `auto-core.state.namespace` so that
---it survives nvim restarts. The active file itself is just a
---convenience snapshot — `<name>.json` is the durable record.
---
---dbee only ever sees `_active.json`. We never call dbee's
---`add_source` / no-op `remove_source` (there isn't one) at runtime;
---swap semantics happen at the filesystem layer.
---ADR 0026 Phase 2: moved from `auto-finder.sections._dbase_files`.
---Original path remains valid via `sections/_dbase_files.lua` facade.
---@module 'auto-finder.views.dbase.files'

local logger = require("auto-finder.log")

local M = {}

---@type string
local STATE_SUBDIR = "auto-finder/dbase"
---@type string
local ACTIVE_BASENAME = "_active.json"
---@type string
local NS = "auto-finder.dbase"
---@type string
local KEY_ACTIVE = "active_file"

---Canonical dbee adapter aliases the admin REPL surfaces in its
---`dbase conn add` type-picker. These are the aliases registered by
---`nvim-dbee/dbee/adapters/*.go` — the list is hand-mirrored because
---the adapter registry lives in the Go binary, not in dbee's Lua
---surface. If dbee adds a backend, append it here; if it removes one,
---drop it (otherwise `dbee.api.core.source_reload` will error on the
---unknown type alias). Each name shown here is sufficient — aliases
---like `pg`, `postgresql`, `mssql`, `duck`, `mongo`, `sqlite3` also
---work upstream.
---@type string[]
M.TYPES = {
  "postgres", "mysql", "sqlite", "bigquery", "redis", "mongodb",
  "clickhouse", "databricks", "duckdb", "oracle", "redshift", "sqlserver",
}

---@private id charset matches dbee's `dbee.utils.random_string` so
---auto-finder-generated ids are indistinguishable from ids written by
---dbee's own `FileSource:create()`.
local ID_CHARSET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"

---@private
---@return string
local function random_string()
  local s = {}
  for _ = 1, 10 do
    local i = math.random(1, #ID_CHARSET)
    s[#s + 1] = ID_CHARSET:sub(i, i)
  end
  return table.concat(s)
end

---@private Mirror dbee's `FileSource:create()` prefix so a file
---written by our REPL is interchangeable with one written by dbee's
---own create-connection path.
---@return string
local function gen_id()
  return "file_source_/" .. random_string()
end

---@private Ensure every entry in `conns` has a non-empty `id` field.
---Mutates in place; returns the list plus a boolean indicating
---whether any entry was healed. dbee's `Handler:source_reload`
---errors hard on id-less entries, so this runs at every boundary
---where we write to disk or hand a list to dbee.
---@param conns table[]
---@return table[] conns, boolean changed
local function ensure_ids(conns)
  local changed = false
  for _, c in ipairs(conns or {}) do
    if type(c) == "table" and (type(c.id) ~= "string" or c.id == "") then
      c.id = gen_id()
      changed = true
    end
  end
  return conns, changed
end

-- Exposed for tests; not part of the public surface.
M._gen_id = gen_id
M._ensure_ids = ensure_ids

---Resolve the dbase state directory under `stdpath("state")`. Created
---on first call. Mirrors auto-core's `stdpath("state") .. "/auto-core/"`
---convention.
---@return string
function M.state_dir()
  local root = vim.fn.stdpath("state") .. "/" .. STATE_SUBDIR
  if vim.fn.isdirectory(root) == 0 then
    vim.fn.mkdir(root, "p")
  end
  return root
end

---Absolute path to the pinned `_active.json` file. Ensures it exists
---as an empty JSON array on first access so dbee's FileSource never
---sees a missing path.
---@return string
function M.active_path()
  local p = M.state_dir() .. "/" .. ACTIVE_BASENAME
  if vim.fn.filereadable(p) == 0 then
    M._write_json(p, {})
  end
  return p
end

---Normalize a user-supplied name into a basename with `.json` suffix.
---Rejects path separators (`dbase new ../etc/passwd` would otherwise
---escape the state dir).
---@param name string
---@return string|nil basename, string|nil err
function M.normalize_name(name)
  if type(name) ~= "string" or name == "" then
    return nil, "name is required"
  end
  if name:find("/") or name:find("\\") then
    return nil, "name must not contain path separators"
  end
  if name == "_active" or name == ACTIVE_BASENAME then
    return nil, "_active is reserved"
  end
  if not name:match("%.json$") then
    name = name .. ".json"
  end
  return name, nil
end

---Path under the state dir for a named connection file.
---@param name string  raw user name (`.json` optional)
---@return string|nil path, string|nil err
function M.path_for(name)
  local basename, err = M.normalize_name(name)
  if err then return nil, err end
  return M.state_dir() .. "/" .. basename, nil
end

---List user-managed connection files (basename without `.json`),
---sorted. The pinned `_active.json` is excluded — it's plumbing.
---@return string[]
function M.list()
  local dir = M.state_dir()
  local names = {}
  for entry, kind in vim.fs.dir(dir) do
    if (kind == "file" or kind == "link")
        and entry ~= ACTIVE_BASENAME
        and entry:match("%.json$") then
      names[#names + 1] = entry:gsub("%.json$", "")
    end
  end
  table.sort(names)
  return names
end

---Create a new empty connection file. Errors if it already exists so
---the user doesn't accidentally clobber a populated file with `dbase
---new` — they can `dbase rm` then `dbase new` if they really want
---that.
---@param name string
---@return string|nil basename, string|nil err
function M.new(name)
  local path, err = M.path_for(name)
  if err then return nil, err end
  if vim.fn.filereadable(path) == 1 then
    return nil, "file already exists: " .. vim.fs.basename(path)
  end
  local ok, write_err = M._write_json(path, {})
  if not ok then return nil, write_err end
  return vim.fs.basename(path), nil
end

---Delete a user-managed connection file. If it was the active file,
---also clears the persisted active marker and resets `_active.json`
---to an empty list so the drawer doesn't keep showing stale entries
---on next reload.
---@param name string
---@return boolean ok, string|nil err
function M.remove(name)
  local path, err = M.path_for(name)
  if err then return false, err end
  if vim.fn.filereadable(path) == 0 then
    return false, "no such file: " .. vim.fs.basename(path)
  end
  local current = M.current()
  local was_active = (current ~= nil)
      and (vim.fs.basename(path) == current
        or (current .. ".json") == vim.fs.basename(path))
  local rm_ok = (os.remove(path) ~= nil)
  if not rm_ok then return false, "rm failed: " .. path end
  if was_active then
    M._set_active(nil)
    M._write_json(M.active_path(), {})
    M._reload_dbee()
  end
  return true, nil
end

---Swap the contents of `_active.json` to match the named file's
---contents, persist the active marker, and ask dbee to reload its
---FileSource. The user picks from `M.list()`.
---
---Heals id-less entries on the way through so a legacy file written
---before id-generation landed (anything from v0.2.18) recovers
---automatically: ids are assigned and written back to both the named
---file (so the heal persists across future loads) and `_active.json`.
---@param name string
---@return string|nil basename, string|nil err
function M.load(name)
  local path, err = M.path_for(name)
  if err then return nil, err end
  if vim.fn.filereadable(path) == 0 then
    return nil, "no such file: " .. vim.fs.basename(path)
  end
  local connections, read_err = M._read_json(path)
  if read_err then return nil, read_err end
  local _, healed = ensure_ids(connections)
  if healed then
    -- Persist the heal back to the named file so we don't redo this
    -- on the next load. Silently ignore write failure — the in-memory
    -- list still has ids, and the active file write below is what
    -- dbee actually reads.
    M._write_json(path, connections)
  end
  local write_ok, write_err = M._write_json(M.active_path(), connections)
  if not write_ok then return nil, write_err end
  M._set_active(vim.fs.basename(path):gsub("%.json$", ""))
  M._reload_dbee()
  return vim.fs.basename(path), nil
end

---Persisted active filename (without `.json`), or nil if none has
---been loaded yet this install.
---@return string|nil
function M.current()
  local ok, state = pcall(require, "auto-core.state")
  if not ok or type(state) ~= "table" or type(state.namespace) ~= "function" then
    return nil
  end
  local ns = state.namespace(NS)
  if not ns or type(ns.get) ~= "function" then return nil end
  local val = ns:get(KEY_ACTIVE)
  if type(val) == "string" and val ~= "" then return val end
  return nil
end

---List connections in the currently-active file. Reads
---`_active.json` directly (the durable source of truth for what dbee
---sees). Returns `{}` if no file is loaded yet.
---@return table[] connections, string|nil err
function M.connections()
  return M._read_json(M.active_path())
end

---@class AutoFinderDbaseConn
---@field name string
---@field type string         e.g. "postgres", "mysql", "sqlite", "bigquery"
---@field url  string         dbee connection URL
---@field [string] any        passthrough — dbee accepts arbitrary extra fields per-type

---Append a connection to the active file (and the on-disk named
---file it was loaded from, if any). Triggers a dbee reload.
---@param spec AutoFinderDbaseConn
---@return boolean ok, string|nil err
function M.conn_add(spec)
  if type(spec) ~= "table" then return false, "connection spec must be a table" end
  if type(spec.name) ~= "string" or spec.name == "" then
    return false, "connection name is required"
  end
  if type(spec.type) ~= "string" or spec.type == "" then
    return false, "connection type is required (e.g. postgres, mysql, sqlite)"
  end
  if type(spec.url) ~= "string" or spec.url == "" then
    return false, "connection url is required"
  end
  local conns, read_err = M._read_json(M.active_path())
  if read_err then return false, read_err end
  -- Heal pre-existing id-less entries before adding to the list so a
  -- legacy v0.2.18 _active.json doesn't keep blocking dbee's
  -- source_reload after the user's next `conn add`.
  ensure_ids(conns)
  for _, existing in ipairs(conns) do
    if existing.name == spec.name then
      return false, "connection name already exists: " .. spec.name
    end
  end
  -- dbee's `Handler:source_reload` errors on id-less specs. Always
  -- stamp our own id when the caller didn't supply one — matches
  -- dbee's `FileSource:create()` prefix so the file is round-trip
  -- compatible with anything dbee writes itself.
  if type(spec.id) ~= "string" or spec.id == "" then
    spec.id = gen_id()
  end
  conns[#conns + 1] = spec
  local ok, err = M._write_json(M.active_path(), conns)
  if not ok then return false, err end
  -- Mirror into the on-disk named file so the change is durable across
  -- `dbase load` swaps. Silently skip if no active file is set — the
  -- user is editing an ephemeral session.
  local current = M.current()
  if current then
    local named_path = M.state_dir() .. "/" .. current .. ".json"
    M._write_json(named_path, conns)
  end
  M._reload_dbee()
  return true, nil
end

---Remove a connection by name from the active file (and its named
---mirror). Triggers a dbee reload.
---@param name string
---@return boolean ok, string|nil err
function M.conn_remove(name)
  if type(name) ~= "string" or name == "" then
    return false, "connection name is required"
  end
  local conns, read_err = M._read_json(M.active_path())
  if read_err then return false, read_err end
  local kept = {}
  local found = false
  for _, c in ipairs(conns) do
    if c.name == name then
      found = true
    else
      kept[#kept + 1] = c
    end
  end
  if not found then return false, "no such connection: " .. name end
  local ok, err = M._write_json(M.active_path(), kept)
  if not ok then return false, err end
  local current = M.current()
  if current then
    local named_path = M.state_dir() .. "/" .. current .. ".json"
    M._write_json(named_path, kept)
  end
  M._reload_dbee()
  return true, nil
end

---@private
---@param value string|nil
function M._set_active(value)
  local ok, state = pcall(require, "auto-core.state")
  if not ok or type(state) ~= "table" or type(state.namespace) ~= "function" then
    return
  end
  local ns = state.namespace(NS)
  if ns and type(ns.set) == "function" then
    ns:set(KEY_ACTIVE, value)
  end
end

---@private Ask dbee to re-read the pinned source. Soft-fails if dbee
---isn't loaded yet (the section may not have been focused; that's fine).
---
---Heals id-less entries in `_active.json` just in time — the user
---may have a legacy file on disk written by v0.2.18, and dbee's
---`Handler:source_reload` errors on id-less specs. This is cheap
---(one read + at most one write) and idempotent once ids are present.
function M._reload_dbee()
  local ok_setup, setup = pcall(require, "auto-finder.views.dbase.setup")
  if not ok_setup or not setup.is_setup_done() then return end
  local active = M.active_path()
  local conns, read_err = M._read_json(active)
  if not read_err then
    local _, healed = ensure_ids(conns)
    if healed then M._write_json(active, conns) end
  end
  local ok_api, api = pcall(require, "dbee.api")
  if not ok_api or type(api) ~= "table" or type(api.core) ~= "table" then return end
  local ok, err = pcall(api.core.source_reload, ACTIVE_BASENAME)
  if not ok then
    logger.warn("view.dbase.files", "source_reload failed: " .. tostring(err))
  end
end

---@private
---@param path string
---@return table[] conns, string|nil err
function M._read_json(path)
  if vim.fn.filereadable(path) == 0 then return {}, nil end
  local lines = {}
  for line in io.lines(path) do
    if not vim.startswith(vim.trim(line), "//") then
      lines[#lines + 1] = line
    end
  end
  local contents = table.concat(lines, "\n")
  if contents:match("^%s*$") then return {}, nil end
  local ok, data = pcall(vim.fn.json_decode, contents)
  if not ok then
    return {}, "could not parse json: " .. path
  end
  if type(data) ~= "table" then
    return {}, "json root must be an array: " .. path
  end
  return data, nil
end

---@private
---@param path string
---@param value table[]
---@return boolean ok, string|nil err
function M._write_json(path, value)
  -- json_encode an empty Lua table emits `{}` rather than `[]`, which
  -- dbee's FileSource:load() tolerates (it iterates with pairs) but
  -- silently produces zero connections AND obscures the file's
  -- intended shape from a human reader. Force the `[]` form for the
  -- empty case so the file always looks like the array it is.
  local encoded
  if type(value) == "table" and #value == 0 and next(value) == nil then
    encoded = "[]"
  else
    local ok, json = pcall(vim.fn.json_encode, value)
    if not ok then
      return false, "could not encode json for: " .. path
    end
    encoded = json
  end
  local f, ferr = io.open(path, "w+")
  if not f then return false, "could not open for write: " .. (ferr or path) end
  f:write(encoded)
  f:close()
  return true, nil
end

return M