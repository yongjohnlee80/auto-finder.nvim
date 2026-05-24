---Encrypted-vault controller. Equivalent of `files.lua` for the
---at-rest-encrypted storage model.
---
---Why a parallel module rather than dual-mode in files.lua? The
---storage model differs in two ways that matter at the boundary:
---
---  1. **Single dbee source, swappable path.** dbee's source list is
---     fixed at `dbee.setup` time. We register one `EncryptedFileSource`
---     whose `:name()` is stable; switching vaults flips the source's
---     internal `path` field then calls `source_reload(name)`. The
---     plaintext path keyed dbee off `_active.json` instead. Mixing
---     the two flows in one module would obscure the difference.
---
---  2. **No `_active.json` mirror.** Encrypted blobs are the sole
---     durable record. The cached plaintext lives only in
---     `encrypted_source`'s in-memory cache. files.lua's whole
---     mirror-the-active-file-into-_active.json dance has no analog.
---
---Active vault: the user-selected vault basename (without
---`.json.enc`). Persisted under `auto-core.state.namespace("auto-finder.dbase")`
---key `active_vault` so reopening neovim returns to the same vault.
---@module 'auto-finder.views.dbase.vault'

local crypto = require("auto-finder.views.dbase.crypto")
local logger = require("auto-finder.log")
local enc_source = require("auto-finder.views.dbase.encrypted_source")

local M = {}

local STATE_SUBDIR = "auto-finder/dbase"
local NS = "auto-finder.dbase"
local KEY_ACTIVE = "active_vault"
local VAULT_EXT = ".json.enc"

---Connection types we surface in the admin REPL. Mirrors the list
---in files.lua so the user sees the same options regardless of
---storage mode. Kept in sync manually — see files.lua TYPES for the
---rationale.
---@type string[]
M.TYPES = {
  "postgres", "mysql", "sqlite", "bigquery", "redis", "mongodb",
  "clickhouse", "databricks", "duckdb", "oracle", "redshift", "sqlserver",
}

---Module-level reference to the live EncryptedFileSource instance.
---Set by `M.bind_source(src)` from setup.lua so admin verbs can
---ask dbee to reload after CRUD without re-importing the source.
---@type table|nil
local _bound_source = nil

---Stable identifier dbee keys our source under. `dbee.handler:add_source`
---bucket-keys the source by `source:name()` at setup time; mutating
---name() afterward breaks `source_reload(...)` (it looks up the bucket
---by the NEW name and finds nothing). So name() returns this constant
---for the entire lifetime; the human-readable "which vault is active"
---label lives in `auto-core.state` under KEY_ACTIVE and is surfaced
---by `M.current()`.
M.SOURCE_ID = "auto-finder-vault"

---@return string
function M.state_dir()
  local root = vim.fn.stdpath("state") .. "/" .. STATE_SUBDIR
  if vim.fn.isdirectory(root) == 0 then
    vim.fn.mkdir(root, "p")
  end
  return root
end

---@param name string
---@return string|nil basename, string|nil err
function M.normalize_name(name)
  if type(name) ~= "string" or name == "" then
    return nil, "name is required"
  end
  if name:find("/") or name:find("\\") then
    return nil, "name must not contain path separators"
  end
  if name == "_active" then
    return nil, "_active is reserved"
  end
  -- Strip a trailing `.json` or `.json.enc` so users can write either.
  name = name:gsub("%.json%.enc$", ""):gsub("%.json$", "")
  return name, nil
end

---@param name string  user-supplied name
---@return string|nil path, string|nil err
function M.path_for(name)
  local base, err = M.normalize_name(name)
  if err then return nil, err end
  return M.state_dir() .. "/" .. base .. VAULT_EXT, nil
end

---List existing vaults (basenames sans extension), sorted.
---@return string[]
function M.list()
  local dir = M.state_dir()
  local names = {}
  for entry, kind in vim.fs.dir(dir) do
    if (kind == "file" or kind == "link") and entry:match("%.json%.enc$") then
      names[#names + 1] = entry:gsub("%.json%.enc$", "")
    end
  end
  table.sort(names)
  return names
end

---List plaintext-legacy files still on disk. Used by the admin REPL
---to surface which files are migration candidates.
---@return string[]
function M.list_legacy()
  local dir = M.state_dir()
  local names = {}
  for entry, kind in vim.fs.dir(dir) do
    if (kind == "file" or kind == "link")
        and entry ~= "_active.json"
        and entry:match("%.json$")
        and not entry:match("%.json%.enc$") then
      names[#names + 1] = entry:gsub("%.json$", "")
    end
  end
  table.sort(names)
  return names
end

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

---@private
local function set_current(value)
  local ok, state = pcall(require, "auto-core.state")
  if not ok or type(state) ~= "table" or type(state.namespace) ~= "function" then
    return
  end
  local ns = state.namespace(NS)
  if ns and type(ns.set) == "function" then
    ns:set(KEY_ACTIVE, value)
  end
end

---Bind the live dbee EncryptedFileSource instance so admin verbs
---can mutate `source.path` + call `source_reload`. Called from
---setup.lua at registration time.
---@param src table
function M.bind_source(src)
  _bound_source = src
end

---Test-only — inspect the binding.
function M._bound_source_for_testing()
  return _bound_source
end

---Repoint the bound source to a vault path and tell dbee to reload.
---Locks the in-memory plaintext cache ONLY when switching vault paths
---— a same-path repoint (after a CRUD op) keeps the cache so the user
---isn't re-prompted for the passphrase every time they add/remove a
---connection.
---
---**Stable source id** (lector review must-fix, 2026-05-24): the source
---was registered with dbee at setup time keyed by `source:name()`. We
---MUST NOT mutate that name afterward — dbee's handler stores sources
---in a name-bucketed map (`add_source(s)` → `sources[s:name()] = s`,
---see `nvim-dbee/lua/dbee/handler/init.lua:41-65`), so calling
---`source_reload(new_name)` after we've changed the source's name()
---looks up the wrong key and errors with `no source with id: …`. So
---repoint_source ONLY mutates the path; name() stays `SOURCE_ID`
---forever, and we always reload by `SOURCE_ID`.
---@param vault_path string|nil  nil → no active vault, source.load returns {}
local function repoint_source(vault_path)
  if not _bound_source then return end
  local new_path = vault_path or (M.state_dir() .. "/__no_active__" .. VAULT_EXT)
  local path_changed = _bound_source.path ~= new_path
  _bound_source.path = new_path
  if path_changed then
    enc_source.lock()  -- force re-decrypt against the new file
  end
  -- Skip the dbee reload when dbee.setup hasn't run yet (lector
  -- re-review should-fix, 2026-05-24). `dbase load` is legal before
  -- the dbase section has ever been focused — the persisted active
  -- vault path is enough for the later dbee.setup pass to register
  -- the source at the right location. Calling source_reload in that
  -- window raises `setup() has not been called yet` from dbee,
  -- which we previously surfaced as a WARN — scary false signal for
  -- what is just a deferred reload.
  local ok_setup, setup_mod = pcall(require, "auto-finder.views.dbase.setup")
  if not (ok_setup and setup_mod.is_setup_done()) then return end
  local ok_api, api = pcall(require, "dbee.api")
  if not ok_api or type(api) ~= "table" or type(api.core) ~= "table" then return end
  local ok, err = pcall(api.core.source_reload, M.SOURCE_ID)
  if not ok then
    logger.warn("view.dbase.vault", "source_reload failed: " .. tostring(err))
  end
end

---Create a brand new empty vault (encrypted). Errors if it exists.
---@param name string
---@return string|nil basename, string|nil err
function M.new(name)
  if not crypto.available() then
    return nil, "no crypto provider (install `age` or `gpg`)"
  end
  local path, err = M.path_for(name)
  if not path then return nil, err end
  if vim.fn.filereadable(path) == 1 then
    return nil, "vault already exists: " .. vim.fs.basename(path)
  end
  local ok, werr = enc_source.new_empty(path)
  if not ok then return nil, "vault create failed: " .. tostring(werr) end
  return vim.fs.basename(path), nil
end

---Delete a vault. Clears the active marker if it was the active one.
---@param name string
---@return boolean ok, string|nil err
function M.remove(name)
  local path, err = M.path_for(name)
  if not path then return false, err end
  if vim.fn.filereadable(path) == 0 then
    return false, "no such vault: " .. vim.fs.basename(path)
  end
  local current = M.current()
  local base = vim.fs.basename(path):gsub("%.json%.enc$", "")
  if current == base then
    set_current(nil)
    repoint_source(nil)
  end
  local rm_ok = (os.remove(path) ~= nil)
  if not rm_ok then return false, "rm failed: " .. path end
  return true, nil
end

---Activate a vault — sets it as `current`, repoints the bound dbee
---source, and forces a reload. Prompts for the passphrase only when
---the encrypted_source first reads from disk.
---@param name string
---@return string|nil basename, string|nil err
function M.load(name)
  local path, err = M.path_for(name)
  if not path then return nil, err end
  if vim.fn.filereadable(path) == 0 then
    return nil, "no such vault: " .. vim.fs.basename(path)
  end
  local base = vim.fs.basename(path):gsub("%.json%.enc$", "")
  set_current(base)
  repoint_source(path)
  return vim.fs.basename(path), nil
end

---@return table[] connections, string|nil err
function M.connections()
  if not _bound_source then return {}, "no active vault" end
  -- Use the error-propagating read path (lector review should-fix #2,
  -- 2026-05-24). `:load()` returns {} on decrypt/JSON/passphrase
  -- failure because dbee's pipeline expects a list — but a silently
  -- empty list to the user is dangerous for a security feature: it
  -- can make a real vault look wiped. `enc_source.read(src)` returns
  -- the actual failure so `dbase conn ls` can say "wrong passphrase"
  -- or "malformed vault" instead.
  local list, err = enc_source.read(_bound_source)
  if not list then return {}, err end
  return list, nil
end

---@param spec { name: string, type: string, url: string }
---@return boolean ok, string|nil err
function M.conn_add(spec)
  if type(spec) ~= "table" then return false, "spec must be a table" end
  if not _bound_source then return false, "no active vault — `dbase load <name>` first" end
  if type(spec.name) ~= "string" or spec.name == "" then
    return false, "connection name is required"
  end
  if type(spec.type) ~= "string" or spec.type == "" then
    return false, "connection type is required"
  end
  if type(spec.url) ~= "string" or spec.url == "" then
    return false, "connection url is required"
  end
  local existing = _bound_source:load()
  for _, c in ipairs(existing) do
    if c.name == spec.name then
      return false, "connection name already exists: " .. spec.name
    end
  end
  local ok, err = pcall(_bound_source.create, _bound_source, spec)
  if not ok then return false, tostring(err) end
  repoint_source(_bound_source.path)
  return true, nil
end

---@param name string  connection name (not id)
---@return boolean ok, string|nil err
function M.conn_remove(name)
  if not _bound_source then return false, "no active vault" end
  if type(name) ~= "string" or name == "" then
    return false, "connection name is required"
  end
  local existing = _bound_source:load()
  local target_id
  for _, c in ipairs(existing) do
    if c.name == name then target_id = c.id; break end
  end
  if not target_id then return false, "no such connection: " .. name end
  local ok, err = pcall(_bound_source.delete, _bound_source, target_id)
  if not ok then return false, tostring(err) end
  repoint_source(_bound_source.path)
  return true, nil
end

---Migrate a plaintext connection JSON file (legacy storage) to an
---encrypted vault. Leaves the plaintext source in place — user
---calls `dbase rmlegacy <name>` to delete it explicitly.
---@param name string
---@return string|nil dest_basename, string|nil err, integer? migrated_count
function M.migrate(name)
  if not crypto.available() then
    return nil, "no crypto provider"
  end
  local base, err = M.normalize_name(name)
  if err then return nil, err end
  local plain_path = M.state_dir() .. "/" .. base .. ".json"
  if vim.fn.filereadable(plain_path) == 0 then
    return nil, "no plaintext file at " .. plain_path
  end
  local dest = M.state_dir() .. "/" .. base .. VAULT_EXT
  if vim.fn.filereadable(dest) == 1 then
    return nil, "vault already exists at " .. dest
        .. "   (delete it first if you want to re-migrate)"
  end
  local migrated, merr = enc_source.migrate_from_plaintext(plain_path, dest)
  if not migrated then return nil, merr end
  return vim.fs.basename(dest), nil, #migrated
end

---Delete the plaintext file `<name>.json` if it exists. Explicit
---user opt-in for destruction — never automatic from migrate.
---@param name string
---@return boolean ok, string|nil err
function M.rmlegacy(name)
  local base, err = M.normalize_name(name)
  if err then return false, err end
  local plain_path = M.state_dir() .. "/" .. base .. ".json"
  if vim.fn.filereadable(plain_path) == 0 then
    return false, "no plaintext file at " .. plain_path
  end
  local rm_ok = (os.remove(plain_path) ~= nil)
  if not rm_ok then return false, "rm failed: " .. plain_path end
  return true, nil
end

---Status info for the admin REPL `dbase status` verb.
---@return { provider: string|nil, version: string|nil, active: string|nil, vaults: integer, legacy: integer }
function M.status()
  local prov = crypto.available()
  return {
    provider = prov and prov.name or nil,
    version  = prov and prov.version or nil,
    active   = M.current(),
    vaults   = #M.list(),
    legacy   = #M.list_legacy(),
  }
end

---Lock — drop cached passphrase + plaintext.
function M.lock()
  enc_source.lock()
end

return M
