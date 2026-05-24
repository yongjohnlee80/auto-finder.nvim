---Passphrase-based encrypt/decrypt provider for auto-finder dbase
---connection vaults.
---
---Lector's handoff is explicit: do not hand-roll crypto. Stand up a
---small provider boundary around a standard local tool — `age` first,
---`gpg` second — and fail clearly when neither is available. Plaintext
---never touches disk via this module; passphrase never appears on a
---command line where `ps` could see it (we feed it via a 0600 tempfile
---and unlink before returning).
---
---Provider precedence:
---  1. `age` (modern, simple passphrase mode)
---  2. `gpg` (universal, --symmetric + --pinentry-mode loopback)
---
---API:
---  M.available()       → { name, version }|nil
---  M.encrypt(s, pass)  → string|nil, err   ASCII-armored ciphertext
---  M.decrypt(s, pass)  → string|nil, err   plaintext
---  M.set_provider(name)                     override default order (test/install)
---
---The encrypted blob format is opaque — the provider tag is encoded as
---the first line of the file so we can dispatch to the right decoder
---on read. Format:
---
---  AUTO-FINDER-DBASE-VAULT v1 <provider>
---  <ciphertext payload>
---
---This lets a user who set up `age` on machine A read the vault on
---machine B that only has `gpg`, IF they re-encrypt — there's no
---cross-provider compatibility otherwise.
---@module 'auto-finder.views.dbase.crypto'

local M = {
  _provider_override = nil,  ---@type string|nil
}

---Header that prefixes every encrypted vault. Lets us dispatch
---decryption to the right backend and version-gate format changes.
local HEADER_PREFIX = "AUTO-FINDER-DBASE-VAULT v1 "

---@private Write a string to a 0600-perm tempfile. Returns the path.
---Caller must `os.remove(path)` after use. The file is created with
---restrictive perms BEFORE the secret is written so there's no
---0644-window race for another process to read it.
---@param contents string
---@return string|nil path, string|nil err
local function write_secure_tempfile(contents)
  local path = vim.fn.tempname()
  -- Create with 0600 first via a touch + chmod dance. io.open's "w"
  -- mode produces 0666 & umask, which on a typical 022 umask leaves
  -- 0644 — readable by every user on the machine before we get a
  -- chance to chmod. Pre-creating with 0600 via vim.fn.system avoids
  -- this race.
  local touch_ok = vim.fn.system({ "install", "-m", "600", "/dev/null", path })
  if vim.v.shell_error ~= 0 then
    -- `install` may not be available on minimal containers; fall back
    -- to open + chmod + check. Acknowledge the small window.
    local f, ferr = io.open(path, "w")
    if not f then return nil, "tempfile open failed: " .. tostring(ferr) end
    f:close()
    os.execute("chmod 600 " .. vim.fn.shellescape(path))
  end
  local _ = touch_ok
  local f, ferr = io.open(path, "w")
  if not f then
    os.remove(path)
    return nil, "tempfile write failed: " .. tostring(ferr)
  end
  f:write(contents)
  f:close()
  return path, nil
end

---@private
---@param cmd string[]
---@param stdin string|nil
---@param env table<string,string>|nil  extra env vars merged with parent
---@return integer code, string stdout, string stderr
local function run(cmd, stdin, env)
  -- vim.system is the modern API; auto-finder requires Neovim ≥0.10.
  local opts = { stdin = stdin or "", text = true }
  if env then opts.env = env end
  local res = vim.system(cmd, opts):wait()
  return res.code or -1, res.stdout or "", res.stderr or ""
end

---@private Probe an executable's `--version` output and return a
---short version string, or nil if the binary isn't on PATH.
---@param bin string
---@return string|nil version
local function probe(bin)
  if vim.fn.executable(bin) ~= 1 then return nil end
  local code, stdout = run({ bin, "--version" })
  if code ~= 0 then return nil end
  return (stdout:match("[^\n]+") or bin):gsub("%s+$", "")
end

---@private age encrypt/decrypt. age's passphrase mode normally reads
---from /dev/tty which is awkward to script. We pass the passphrase
---in the subprocess env (`AGE_PASSPHRASE`), which rage and recent age
---builds honor — and which never lands on a command line or disk.
---If the local age doesn't support env-var passphrase, the call
---fails and the user gets a clear error pointing at gpg.
local function age_encrypt(plaintext, passphrase)
  local code, stdout, stderr = run(
    { "age", "--passphrase", "--armor", "--output", "-" },
    plaintext,
    { AGE_PASSPHRASE = passphrase })
  if code ~= 0 then
    return nil, "age encrypt failed: " .. stderr
  end
  return stdout, nil
end

local function age_decrypt(ciphertext, passphrase)
  local code, stdout, stderr = run(
    { "age", "--decrypt", "--output", "-" },
    ciphertext,
    { AGE_PASSPHRASE = passphrase })
  if code ~= 0 then
    return nil, "age decrypt failed: " .. stderr
  end
  return stdout, nil
end

---@private gpg encrypt/decrypt via a 0600 tempfile holding the
---passphrase. `--pinentry-mode loopback` forces gpg to read the
---passphrase from the file rather than spawning a pinentry agent.
local function gpg_encrypt(plaintext, passphrase)
  local pwfile, err = write_secure_tempfile(passphrase)
  if not pwfile then return nil, err end
  local code, stdout, stderr = run({
    "gpg", "--batch", "--yes", "--quiet",
    "--pinentry-mode", "loopback",
    "--passphrase-file", pwfile,
    "--symmetric", "--cipher-algo", "AES256",
    "--armor", "--output", "-",
  }, plaintext)
  os.remove(pwfile)
  if code ~= 0 then
    return nil, "gpg encrypt failed: " .. stderr
  end
  return stdout, nil
end

local function gpg_decrypt(ciphertext, passphrase)
  local pwfile, err = write_secure_tempfile(passphrase)
  if not pwfile then return nil, err end
  local code, stdout, stderr = run({
    "gpg", "--batch", "--yes", "--quiet",
    "--pinentry-mode", "loopback",
    "--passphrase-file", pwfile,
    "--decrypt", "--output", "-",
  }, ciphertext)
  os.remove(pwfile)
  if code ~= 0 then
    return nil, "gpg decrypt failed (likely wrong passphrase): " .. stderr
  end
  return stdout, nil
end

---Provider registry. Each entry: { name, probe, encrypt, decrypt }.
---Order matters — first match wins unless `_provider_override` says
---otherwise.
---
---**Provider posture (lector re-review, 2026-05-24):** `gpg` is the
---supported default. `age` is left out of the default registry
---because its passphrase automation is build-dependent (relies on
---`AGE_PASSPHRASE` env honored by `rage` and recent age; stock age
---reads `/dev/tty` only). Users who specifically want age can opt in
---with `AUTO_FINDER_DBASE_PROVIDER_AGE=1`. We re-evaluate making age
---default once a real-provider smoke proves the passphrase path on
---the target platforms.
local PROVIDERS = {
  {
    name    = "gpg",
    probe   = function() return probe("gpg") end,
    encrypt = gpg_encrypt,
    decrypt = gpg_decrypt,
  },
}

local AGE_PROVIDER = {
  name    = "age",
  probe   = function() return probe("age") end,
  encrypt = age_encrypt,
  decrypt = age_decrypt,
}

---@private Build the active provider list — gpg always, age only
---when the opt-in env var is set. Computed at every `pick_provider`
---call so the env var can change at runtime (tests need this).
---@return table[]
local function active_providers()
  local out = {}
  -- age comes FIRST when opted in, so users who explicitly choose
  -- it get it. Default precedence remains gpg-only.
  if (os.getenv("AUTO_FINDER_DBASE_PROVIDER_AGE") or "") ~= "" then
    out[#out + 1] = AGE_PROVIDER
  end
  for _, p in ipairs(PROVIDERS) do out[#out + 1] = p end
  return out
end

---@private
---@return table|nil entry, string|nil version
local function pick_provider()
  if M._provider_override then
    -- Override path looks up by name across ALL registered providers
    -- (default + age + any test-injected stub) so tests can force a
    -- specific provider regardless of env-gated registry membership.
    local all = { AGE_PROVIDER }
    for _, p in ipairs(PROVIDERS) do all[#all + 1] = p end
    for _, p in ipairs(all) do
      if p.name == M._provider_override then
        local v = p.probe()
        if v then return p, v end
        return nil, nil
      end
    end
    return nil, nil
  end
  for _, p in ipairs(active_providers()) do
    local v = p.probe()
    if v then return p, v end
  end
  return nil, nil
end

---@return { name: string, version: string }|nil
function M.available()
  -- Hard opt-out for headless / smoke contexts. Set when an external
  -- test driver wants the legacy plaintext code path even though
  -- `gpg` / `age` is installed on the host. Real users never set
  -- this — they get encrypted-by-default whenever a provider is
  -- detected.
  if (os.getenv("AUTO_FINDER_DBASE_DISABLE_CRYPTO") or "") ~= "" then
    return nil
  end
  local p, v = pick_provider()
  if not p then return nil end
  return { name = p.name, version = v }
end

---@param plaintext string
---@param passphrase string
---@return string|nil ciphertext, string|nil err
function M.encrypt(plaintext, passphrase)
  if type(plaintext) ~= "string" then
    return nil, "plaintext must be a string"
  end
  if type(passphrase) ~= "string" or passphrase == "" then
    return nil, "passphrase is required"
  end
  local p = pick_provider()
  if not p then
    return nil, "no crypto provider available (install `age` or `gpg`)"
  end
  local body, err = p.encrypt(plaintext, passphrase)
  if not body then return nil, err end
  return HEADER_PREFIX .. p.name .. "\n" .. body, nil
end

---Decrypt a vault blob. The provider is selected from the header
---line so a blob encrypted with gpg on one machine still decrypts
---when the local default has shifted to age (assuming gpg is also
---installed on the new machine).
---@param ciphertext string
---@param passphrase string
---@return string|nil plaintext, string|nil err
function M.decrypt(ciphertext, passphrase)
  if type(ciphertext) ~= "string" or ciphertext == "" then
    return nil, "ciphertext is empty"
  end
  if type(passphrase) ~= "string" or passphrase == "" then
    return nil, "passphrase is required"
  end
  local first_nl = ciphertext:find("\n")
  if not first_nl then
    return nil, "vault is missing the provider header"
  end
  local header = ciphertext:sub(1, first_nl - 1)
  local body = ciphertext:sub(first_nl + 1)
  if not vim.startswith(header, HEADER_PREFIX) then
    return nil, "vault header is malformed: " .. header
  end
  local provider_name = header:sub(#HEADER_PREFIX + 1)
  -- Header-dispatch looks across the FULL provider set (default plus
  -- the opt-in `age` plus any test stub). A vault encrypted on a
  -- machine with `AUTO_FINDER_DBASE_PROVIDER_AGE=1` should still
  -- decrypt on a machine where the env var isn't set — provided
  -- age is on PATH. The probe call below will fail loudly with a
  -- helpful "requires `age` but it is not on PATH" if the binary
  -- is missing.
  local all = { AGE_PROVIDER }
  for _, p in ipairs(PROVIDERS) do all[#all + 1] = p end
  local entry
  for _, p in ipairs(all) do
    if p.name == provider_name then entry = p; break end
  end
  if not entry then
    return nil, "vault was encrypted with unknown provider: " .. provider_name
  end
  if not entry.probe() then
    return nil, "vault requires `" .. provider_name .. "` but it is not on PATH"
  end
  return entry.decrypt(body, passphrase)
end

---Test/install hook — force a specific provider regardless of probe
---order. Pass nil to revert to default precedence.
---@param name string|nil
function M.set_provider(name)
  M._provider_override = name
end

---@private Test hook: inject a synthetic provider into the registry.
---Useful for headless tests that need deterministic encrypt/decrypt
---without depending on a real crypto binary on the runner.
---@param entry { name: string, probe: fun():string|nil, encrypt: fun(s:string, pass:string):string|nil,string|nil, decrypt: fun(s:string, pass:string):string|nil,string|nil }
function M._register_provider(entry)
  table.insert(PROVIDERS, 1, entry)
end

---@private Test hook: drop a previously-registered synthetic provider
---by name. Idempotent.
function M._unregister_provider(name)
  for i, p in ipairs(PROVIDERS) do
    if p.name == name then table.remove(PROVIDERS, i); return end
  end
end

---@private Test hook: replace the age-opt-in entry so we can exercise
---the env-gated path without a real `age` binary on the runner. Pass
---nil to restore the production age stub. The replacement keeps the
---env-gating behavior in `active_providers()` (i.e. still only
---participates when `AUTO_FINDER_DBASE_PROVIDER_AGE` is set).
local PROD_AGE_PROVIDER = AGE_PROVIDER
function M._set_age_provider_for_testing(entry)
  AGE_PROVIDER = entry or PROD_AGE_PROVIDER
end

return M
