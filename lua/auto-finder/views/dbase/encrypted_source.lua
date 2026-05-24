---dbee Source backed by an at-rest encrypted JSON vault.
---
---Replaces the old plaintext `_active.json` + per-name JSON file
---workflow. Connection URLs (which carry credentials) live on disk
---only in their encrypted form; decryption happens in-memory and the
---plaintext never reaches a file or a log line.
---
---Implements dbee's `Source` interface
---(`nvim-dbee/lua/dbee/sources.lua:13-25`):
---  - `name()` / `load()`  — mandatory
---  - `create / update / delete` — optional CRUD
---  - `file()` is INTENTIONALLY omitted: returning a path would invite
---    `dbee.api.ui.source_edit` to open the encrypted blob in a buffer,
---    which would either show ciphertext or worse, prompt the user to
---    hand-edit it.
---
---Passphrase handling:
---  - Prompted via `vim.fn.inputsecret` on first need, cached in a
---    module-local for this nvim session only.
---  - Tests / headless can pre-set the passphrase via
---    `M._set_passphrase_for_testing(value)`.
---  - Cleared by `M.lock()` (drops the cached passphrase + plaintext).
---
---Soft-dep on `auto-finder.views.dbase.crypto`: if no crypto provider
---is on PATH, this source surfaces a clear error rather than silently
---falling back to plaintext.
---@module 'auto-finder.views.dbase.encrypted_source'

local crypto = require("auto-finder.views.dbase.crypto")
local logger = require("auto-finder.log")

local M = {}

---@type string|nil  module-scoped passphrase cache (memory-only)
local _cached_passphrase = nil

---@type table<string, table[]>  in-memory plaintext cache keyed by vault path
local _plaintext_cache = {}

---@private id charset mirrors dbee's `dbee.utils.random_string` so
---auto-finder-generated ids are interchangeable with ids written by
---dbee's own `FileSource:create()`.
local ID_CHARSET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"

local function random_string()
  local s = {}
  for _ = 1, 10 do
    local i = math.random(1, #ID_CHARSET)
    s[#s + 1] = ID_CHARSET:sub(i, i)
  end
  return table.concat(s)
end

local function gen_id()
  return "encrypted_source_/" .. random_string()
end

---Request the session passphrase. Returns the cached value if set,
---otherwise prompts via `vim.fn.inputsecret`. The prompt is suppressed
---when no TTY is attached (smoke tests) — in that case the caller
---must have primed the cache via `_set_passphrase_for_testing`.
---@return string|nil pass, string|nil err
local function get_passphrase(prompt)
  if _cached_passphrase and _cached_passphrase ~= "" then
    return _cached_passphrase, nil
  end
  -- In headless / no-stdin contexts vim.fn.inputsecret returns "" and
  -- the user gets no chance to provide it. Refuse to proceed rather
  -- than encrypting under an empty passphrase.
  if vim.fn.has("gui_running") == 0 and not vim.fn.has("nvim") then
    -- defensive: should never hit
    return nil, "no input channel for passphrase"
  end
  local ok, value = pcall(vim.fn.inputsecret, prompt or "dbase vault passphrase: ")
  if not ok then return nil, "passphrase prompt cancelled" end
  if type(value) ~= "string" or value == "" then
    return nil, "empty passphrase rejected"
  end
  _cached_passphrase = value
  return value, nil
end

---@private  Try to load the encrypted file at `path` and decrypt it.
---On missing file → `{}` (no error, no prompt).
---On empty file → `{}`.
---On decrypt failure → propagate error (caller surfaces to user).
---@param path string
---@return table[]|nil conns, string|nil err
local function read_vault(path)
  if _plaintext_cache[path] then
    return _plaintext_cache[path], nil
  end
  if vim.fn.filereadable(path) == 0 then
    _plaintext_cache[path] = {}
    return {}, nil
  end
  local f, ferr = io.open(path, "r")
  if not f then return nil, "vault open failed: " .. tostring(ferr) end
  local ciphertext = f:read("*a")
  f:close()
  if ciphertext == "" then
    _plaintext_cache[path] = {}
    return {}, nil
  end
  local pass, perr = get_passphrase("dbase vault passphrase for " ..
    vim.fs.basename(path) .. ": ")
  if not pass then return nil, perr end
  local plaintext, derr = crypto.decrypt(ciphertext, pass)
  if not plaintext then
    -- Wrong passphrase is the likely cause — clear the cache so the
    -- next attempt re-prompts.
    _cached_passphrase = nil
    return nil, derr
  end
  local ok, data = pcall(vim.fn.json_decode, plaintext)
  if not ok then
    return nil, "decrypted payload is not valid JSON"
  end
  if type(data) ~= "table" then
    return nil, "decrypted payload must be a JSON array"
  end
  _plaintext_cache[path] = data
  return data, nil
end

---@private Encrypt + persist. Updates the in-memory cache to reflect
---what's now on disk.
---@param path string
---@param conns table[]
---@return boolean ok, string|nil err
local function write_vault(path, conns)
  local pass, perr = get_passphrase("dbase vault passphrase for " ..
    vim.fs.basename(path) .. ": ")
  if not pass then return false, perr end
  local ok_enc, plaintext = pcall(vim.fn.json_encode, conns or {})
  if not ok_enc then return false, "json_encode failed" end
  local ciphertext, derr = crypto.encrypt(plaintext, pass)
  if not ciphertext then return false, derr end
  -- Atomic write: tempfile + rename. Avoids corrupted blobs on
  -- crash mid-write.
  local tmp = path .. ".tmp." .. tostring(os.time())
  local f, ferr = io.open(tmp, "w")
  if not f then return false, "vault tempfile open failed: " .. tostring(ferr) end
  f:write(ciphertext)
  f:close()
  -- Restrictive perms on the encrypted blob too — defense in depth.
  os.execute("chmod 600 " .. vim.fn.shellescape(tmp))
  local ok_rename = os.rename(tmp, path)
  if not ok_rename then
    os.remove(tmp)
    return false, "vault rename failed"
  end
  _plaintext_cache[path] = conns
  return true, nil
end

---@class EncryptedFileSource
---@field path string
---@field display_name string
local EncryptedFileSource = {}

---@param path string  absolute path to the encrypted vault file
---@param opts? { name?: string }
---@return table  dbee-compatible Source instance
function M.new(path, opts)
  if type(path) ~= "string" or path == "" then
    error("EncryptedFileSource requires a path")
  end
  opts = opts or {}
  local o = setmetatable({
    path = path,
    display_name = opts.name or vim.fs.basename(path),
  }, { __index = EncryptedFileSource })
  return o
end

function EncryptedFileSource:name()
  return self.display_name
end

---@return table[]  ConnectionParams[]
function EncryptedFileSource:load()
  local conns, err = read_vault(self.path)
  if not conns then
    -- dbee swallows errors from source:load and treats them as "no
    -- connections" — we surface the why via auto-core.log so the user
    -- can still find out. Admin REPL callers that need the actual
    -- error (e.g. `dbase conn ls` distinguishing "wrong passphrase"
    -- from "empty vault") use `M.read(self)` instead — see below.
    logger.error("view.dbase.encrypted_source",
      "load failed: " .. tostring(err))
    return {}
  end
  -- Ensure ids on every entry — dbee's source_reload errors on
  -- id-less specs.
  for _, c in ipairs(conns) do
    if type(c) == "table" and (type(c.id) ~= "string" or c.id == "") then
      c.id = gen_id()
    end
  end
  return conns
end

---Non-dbee-facing read. Returns the same connection list as :load()
---on success, BUT propagates the decrypt / parse / passphrase error
---instead of silently coercing to `{}`. The admin REPL (`dbase conn
---ls`) uses this so a real failure shows the cause rather than
---making a populated vault look wiped — which would be dangerous UX
---for a security feature (lector review should-fix #2, 2026-05-24).
---@param src table  EncryptedFileSource instance
---@return table[]|nil conns, string|nil err
function M.read(src)
  if type(src) ~= "table" or type(src.path) ~= "string" then
    return nil, "invalid source"
  end
  local conns, err = read_vault(src.path)
  if not conns then return nil, err end
  for _, c in ipairs(conns) do
    if type(c) == "table" and (type(c.id) ~= "string" or c.id == "") then
      c.id = gen_id()
    end
  end
  return conns, nil
end

---@param conn table   ConnectionParams
---@return string id
function EncryptedFileSource:create(conn)
  if type(conn) ~= "table" or vim.tbl_isempty(conn) then
    error("cannot create an empty connection")
  end
  local existing, err = read_vault(self.path)
  if not existing then
    error("vault read failed: " .. tostring(err))
  end
  conn.id = conn.id or gen_id()
  table.insert(existing, conn)
  local ok, werr = write_vault(self.path, existing)
  if not ok then error("vault write failed: " .. tostring(werr)) end
  return conn.id
end

---@param id string
function EncryptedFileSource:delete(id)
  if type(id) ~= "string" or id == "" then
    error("no id passed to delete")
  end
  local existing, err = read_vault(self.path)
  if not existing then
    error("vault read failed: " .. tostring(err))
  end
  local kept = {}
  for _, c in ipairs(existing) do
    if c.id ~= id then table.insert(kept, c) end
  end
  local ok, werr = write_vault(self.path, kept)
  if not ok then error("vault write failed: " .. tostring(werr)) end
end

---@param id string
---@param details table
function EncryptedFileSource:update(id, details)
  if type(id) ~= "string" or id == "" then
    error("no id passed to update")
  end
  if type(details) ~= "table" or vim.tbl_isempty(details) then
    error("cannot update with empty details")
  end
  local existing, err = read_vault(self.path)
  if not existing then
    error("vault read failed: " .. tostring(err))
  end
  for _, c in ipairs(existing) do
    if c.id == id then
      c.name = details.name or c.name
      c.url  = details.url  or c.url
      c.type = details.type or c.type
    end
  end
  local ok, werr = write_vault(self.path, existing)
  if not ok then error("vault write failed: " .. tostring(werr)) end
end

---NOTE: `:file()` is intentionally not implemented. dbee's drawer
---uses this to offer "edit source file" — pointing it at the
---ciphertext would be useless, and pointing it at a plaintext
---temp file would defeat the security goal.

---Drop the cached passphrase and any decrypted plaintext. Forces the
---next vault access to re-prompt. Idempotent.
function M.lock()
  _cached_passphrase = nil
  _plaintext_cache = {}
end

---Test-only: prime the passphrase cache so headless smokes don't try
---to call inputsecret().
function M._set_passphrase_for_testing(value)
  _cached_passphrase = value
end

---Test-only: peek at the in-memory plaintext cache.
function M._cache_for_testing()
  return _plaintext_cache
end

---Create an empty encrypted vault at `path`. Used by `vault.new()`
---when the user wants a fresh vault with no connections yet.
---Prompts for passphrase on first call (so the user sets it during
---vault creation, not on first read).
---@param path string
---@return boolean ok, string|nil err
function M.new_empty(path)
  return write_vault(path, {})
end

---Migration helper — read a plaintext JSON connection file and
---write its contents to an encrypted vault at `dest`. Returns the
---list of migrated connections (for caller logging) plus an err on
---failure. Leaves the source file in place; the user removes it
---explicitly via `dbase rmlegacy`.
---@param plaintext_path string
---@param dest string
---@return table[]|nil migrated, string|nil err
function M.migrate_from_plaintext(plaintext_path, dest)
  if vim.fn.filereadable(plaintext_path) == 0 then
    return nil, "no such plaintext file: " .. plaintext_path
  end
  local f, ferr = io.open(plaintext_path, "r")
  if not f then return nil, "plaintext open failed: " .. tostring(ferr) end
  local raw = f:read("*a")
  f:close()
  local lines = {}
  for line in raw:gmatch("[^\n]*\n?") do
    if not vim.startswith(vim.trim(line), "//") then
      lines[#lines + 1] = line
    end
  end
  local contents = table.concat(lines)
  if contents:match("^%s*$") then contents = "[]" end
  local ok_decode, data = pcall(vim.fn.json_decode, contents)
  if not ok_decode or type(data) ~= "table" then
    return nil, "plaintext file is not a JSON array"
  end
  -- Stamp ids on any id-less entries before encrypting.
  for _, c in ipairs(data) do
    if type(c) == "table" and (type(c.id) ~= "string" or c.id == "") then
      c.id = gen_id()
    end
  end
  -- Always write — even an empty list — so the user sees the encrypted
  -- file appear and can verify the passphrase round-trips.
  local ok_write, werr = write_vault(dest, data)
  if not ok_write then return nil, werr end
  return data, nil
end

return M
