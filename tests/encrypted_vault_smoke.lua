-- Encrypted-vault + layout-defaults smoke for v0.2.34.
--
-- Three slices:
--   1. crypto provider boundary — synthetic provider register/unregister,
--      vault header round-trips through the right backend.
--   2. encrypted source CRUD — new / load / create / delete via dbee's
--      Source interface, plus migrate_from_plaintext.
--   3. setup.lua defaults — verify dbase.editor.buffer_options.buflisted
--      ends up true so SQL notes show in winbar / buffers tree.
--
-- Run from the worktree root:
--   nvim --headless -u NONE -l tests/encrypted_vault_smoke.lua
--
-- Exits 0 on PASS, 1 on FAIL. Doesn't depend on a real `age` or `gpg`
-- — uses an in-process synthetic provider so it stays hermetic.

local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
local nvim_plugins_root = vim.fn.fnamemodify(plugin_root, ":h:h")

local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
for _, p in ipairs({
  LAZY .. "/plenary.nvim",
  LAZY .. "/nui.nvim",
  LAZY .. "/nvim-dbee",
  LAZY .. "/auto-core.nvim",
  nvim_plugins_root .. "/nvim-dbee",
  nvim_plugins_root .. "/auto-core.nvim/main",
  plugin_root,
}) do
  if vim.fn.isdirectory(p) == 1 then
    vim.opt.runtimepath:prepend(p)
  end
end

vim.o.swapfile = false
vim.o.hidden = true
vim.fn.delete("/tmp/auto-finder-vault-smoke-state", "rf")
vim.env.XDG_STATE_HOME = "/tmp/auto-finder-vault-smoke-state"

local fail_count, pass_count, skip_count = 0, 0, 0
local function ok(name, cond, detail)
  if cond then
    pass_count = pass_count + 1
    print(string.format("  PASS  %s", name))
  else
    fail_count = fail_count + 1
    print(string.format("  FAIL  %s  %s", name, tostring(detail or "")))
  end
end
local function skip(name, reason)
  skip_count = skip_count + 1
  print(string.format("  SKIP  %s  (%s)", name, reason))
end

-- ───────────────────── 1. synthetic provider ───────────────────────────
print("\n[1] synthetic crypto provider — register / probe / round-trip")
local crypto = require("auto-finder.views.dbase.crypto")

-- A trivial XOR-cipher provider purely to exercise the boundary. The
-- ciphertext is base64-ish so it survives io.write/read cleanly.
local function make_xor_provider(name, magic)
  local function xor(s, k)
    local out = {}
    for i = 1, #s do
      out[i] = string.char(bit.bxor(s:byte(i), k:byte(((i - 1) % #k) + 1)))
    end
    return table.concat(out)
  end
  return {
    name    = name,
    probe   = function() return name .. " stub v0" end,
    encrypt = function(s, pass)
      local raw = xor(s, pass .. magic)
      -- base64-encode so we don't store NUL bytes (the io path strips
      -- some when files get edited). vim.base64.encode is built-in.
      return vim.base64.encode(raw), nil
    end,
    decrypt = function(s, pass)
      local ok_dec, raw = pcall(vim.base64.decode, s)
      if not ok_dec then return nil, "stub base64 decode failed" end
      return xor(raw, pass .. magic), nil
    end,
  }
end

local stub = make_xor_provider("stub-xor", "MAGIC")
crypto._register_provider(stub)
crypto.set_provider("stub-xor")

local probe = crypto.available()
ok("[1.1] provider boundary surfaces stub-xor", probe and probe.name == "stub-xor",
  vim.inspect(probe))

local sample = '[{"id":"a","name":"db","type":"sqlite","url":":memory:"}]'
local ct, err = crypto.encrypt(sample, "hunter2")
ok("[1.2] encrypt returns non-empty ciphertext",
  type(ct) == "string" and #ct > 0, err or "")
ok("[1.3] header carries provider name",
  ct and ct:find("^AUTO%-FINDER%-DBASE%-VAULT v1 stub%-xor\n"),
  ct and ct:sub(1, 60) or "no ct")

local rt, derr = crypto.decrypt(ct, "hunter2")
ok("[1.4] decrypt round-trips with correct passphrase", rt == sample,
  derr or ("got " .. tostring(rt)))

local wrong, wderr = crypto.decrypt(ct, "wrong-pass")
-- The XOR stub doesn't authenticate so wrong passphrase yields garbage
-- (different bytes) rather than an explicit failure. age/gpg both
-- DO authenticate and would return an error here. We accept either:
-- explicit error, or output that differs from the known-good plaintext.
ok("[1.5] decrypt with wrong pass returns mismatched plaintext or err",
  wderr ~= nil or (wrong ~= sample),
  string.format("wrong=%s err=%s sample=%s",
    tostring(wrong and wrong:sub(1, 30)), tostring(wderr),
    sample:sub(1, 30)))

-- ───────────────────── 2. encrypted source CRUD ────────────────────────
print("\n[2] EncryptedFileSource — new / load / create / delete / migrate")
local enc = require("auto-finder.views.dbase.encrypted_source")
enc._set_passphrase_for_testing("hunter2")  -- skip the inputsecret prompt

local vault_path = "/tmp/auto-finder-vault-smoke-state/encrypted_vault.json.enc"
vim.fn.mkdir(vim.fn.fnamemodify(vault_path, ":h"), "p")

local ok_new, new_err = enc.new_empty(vault_path)
ok("[2.1] new_empty writes a fresh encrypted vault", ok_new, new_err)
ok("[2.2] vault file exists on disk after new_empty",
  vim.fn.filereadable(vault_path) == 1)

-- Drop the in-memory cache so :load actually re-reads from disk and
-- exercises the decrypt path.
enc.lock()
enc._set_passphrase_for_testing("hunter2")
local src = enc.new(vault_path, { name = "test-vault" })
ok("[2.3] EncryptedFileSource.name reflects the display name",
  src:name() == "test-vault", "got " .. tostring(src:name()))
local conns = src:load()
ok("[2.4] :load on fresh vault returns empty list",
  type(conns) == "table" and #conns == 0,
  "got " .. vim.inspect(conns))

local cid = src:create({ name = "first", type = "sqlite", url = ":memory:" })
ok("[2.5] :create returns a non-empty id",
  type(cid) == "string" and #cid > 0, "got " .. tostring(cid))
ok("[2.6] :load after :create yields one entry", #src:load() == 1)

-- Force a disk re-read by dropping the cache. This is the critical
-- path: encrypt to disk, drop cache, decrypt from disk, parse JSON.
enc.lock()
enc._set_passphrase_for_testing("hunter2")
local src2 = enc.new(vault_path, { name = "test-vault" })
local conns2 = src2:load()
ok("[2.7] vault contents survive cache-drop + re-decrypt",
  #conns2 == 1 and conns2[1].name == "first",
  vim.inspect(conns2))

src2:delete(cid)
ok("[2.8] :delete reduces the list", #src2:load() == 0)

-- migrate_from_plaintext
local plain_path = "/tmp/auto-finder-vault-smoke-state/legacy.json"
local plain_dest = "/tmp/auto-finder-vault-smoke-state/migrated.json.enc"
local f = io.open(plain_path, "w")
f:write('[{"id":"legacy-1","name":"legacy","type":"postgres","url":"postgres://localhost"}]')
f:close()

enc.lock()
enc._set_passphrase_for_testing("hunter2")
local migrated, merr = enc.migrate_from_plaintext(plain_path, plain_dest)
ok("[2.9] migrate_from_plaintext returns migrated list",
  type(migrated) == "table" and #migrated == 1, merr)
ok("[2.10] migration LEAVES the plaintext source in place",
  vim.fn.filereadable(plain_path) == 1)
ok("[2.11] migrated vault is readable as an encrypted source",
  vim.fn.filereadable(plain_dest) == 1)
-- Verify contents
enc.lock()
enc._set_passphrase_for_testing("hunter2")
local migrated_src = enc.new(plain_dest)
local migrated_conns = migrated_src:load()
ok("[2.12] migrated vault round-trips to the original connection",
  #migrated_conns == 1 and migrated_conns[1].name == "legacy",
  vim.inspect(migrated_conns))

-- ───────────────────── 3. vault controller ─────────────────────────────
print("\n[3] vault controller — new / list / load / status")
-- vault uses stdpath('state')/auto-finder/dbase which we redirected
-- via XDG_STATE_HOME at the top of the file.
local vault = require("auto-finder.views.dbase.vault")
-- The vault module calls require("auto-finder.views.dbase.encrypted_source")
-- directly — primed cache is still in place from section [2].
enc._set_passphrase_for_testing("hunter2")
crypto.set_provider("stub-xor")  -- ensure vault.new still picks our stub

local basename, vnew_err = vault.new("work")
ok("[3.1] vault.new returns a basename",
  basename == "work.json.enc",
  vnew_err or ("got " .. tostring(basename)))
local listed = vault.list()
ok("[3.2] vault.list reports the new vault",
  #listed == 1 and listed[1] == "work",
  vim.inspect(listed))

-- Bind a fresh source pointing at the new vault and exercise the
-- vault controller's load() repointing logic. Without a bound source,
-- vault.load is a no-op on dbee but should still set the active marker.
local vault_path2 = vault.state_dir() .. "/work.json.enc"
enc.lock()
enc._set_passphrase_for_testing("hunter2")
vault.bind_source(enc.new(vault_path2, { name = "work" }))

local _, lerr = vault.load("work")
ok("[3.3] vault.load(name) sets the active marker",
  vault.current() == "work", lerr or vim.inspect(vault.current()))

-- vault.load → repoint_source → enc_source.lock() drops the cache,
-- so re-prime before the next CRUD operation. In real use the user
-- would hit the inputsecret prompt here; tests prime explicitly.
enc._set_passphrase_for_testing("hunter2")

local _, addrr = vault.conn_add({ name = "primary", type = "postgres",
  url = "postgres://localhost/db" })
ok("[3.4] vault.conn_add succeeds against the active vault",
  addrr == nil, addrr)
local active_conns = vault.connections()
ok("[3.5] vault.connections() reflects the add",
  type(active_conns) == "table" and #active_conns == 1
    and active_conns[1].name == "primary",
  vim.inspect(active_conns))

local _, rmerr = vault.conn_remove("primary")
ok("[3.6] vault.conn_remove deletes by name",
  rmerr == nil, rmerr)
ok("[3.7] after remove, vault.connections is empty",
  #vault.connections() == 0)

local s = vault.status()
ok("[3.8] vault.status surfaces provider name",
  s.provider == "stub-xor", vim.inspect(s))
ok("[3.9] vault.status surfaces vault count",
  s.vaults == 1, vim.inspect(s))

-- ───────────────────── 4. setup.lua editor.buflisted default ───────────
print("\n[4] setup.lua plumbs editor.buffer_options.buflisted = true")
-- Probe the merged dbee config indirectly by intercepting dbee.setup
-- before ensure_setup fires. We monkey-patch dbee.setup to capture
-- its `cfg` argument.
local setup_mod = require("auto-finder.views.dbase.setup")
setup_mod.reset()
local captured_cfg
local ok_dbee, dbee = pcall(require, "dbee")
if not ok_dbee then
  skip("setup.lua buflisted defaulting", "dbee unavailable")
else
  local orig = dbee.setup
  dbee.setup = function(c) captured_cfg = c; return orig(c) end
  -- Force a fresh setup pass with no consumer override.
  setup_mod.ensure_setup({})
  dbee.setup = orig

  ok("[4.1] dbee.setup was invoked", captured_cfg ~= nil)
  ok("[4.2] cfg.editor exists",
    type(captured_cfg) == "table" and type(captured_cfg.editor) == "table",
    vim.inspect(captured_cfg and captured_cfg.editor))
  ok("[4.3] cfg.editor.buffer_options.buflisted == true",
    captured_cfg and captured_cfg.editor
      and captured_cfg.editor.buffer_options
      and captured_cfg.editor.buffer_options.buflisted == true,
    vim.inspect(captured_cfg and captured_cfg.editor and
      captured_cfg.editor.buffer_options))

  -- Consumer override should layer ON TOP of our default rather than
  -- replace it: keep buflisted=true, add their swapfile=false.
  setup_mod.reset()
  captured_cfg = nil
  dbee.setup = function(c) captured_cfg = c; return nil end
  setup_mod.ensure_setup({
    extra = { editor = { buffer_options = { swapfile = false } } },
  })
  dbee.setup = orig

  ok("[4.4] consumer override preserves our buflisted default",
    captured_cfg and captured_cfg.editor.buffer_options.buflisted == true,
    vim.inspect(captured_cfg and captured_cfg.editor.buffer_options))
  ok("[4.5] consumer override merges their key alongside ours",
    captured_cfg and captured_cfg.editor.buffer_options.swapfile == false,
    vim.inspect(captured_cfg and captured_cfg.editor.buffer_options))
end

-- ───────────────────── 5. source_reload uses stable id (regression) ───
-- Lector review must-fix, 2026-05-24. Before this fix, vault.load(name)
-- mutated the source's display_name then called source_reload(name)
-- — but dbee's handler keyed the source under the name() it returned
-- AT setup time, so the reload missed and the drawer never refreshed.
-- The contract now: source:name() returns vault.SOURCE_ID for the
-- entire lifetime; vault.load mutates only path and reloads by
-- SOURCE_ID.
print("\n[5] stable-source-id reload contract (lector must-fix regression)")
do
  local vault_mod = require("auto-finder.views.dbase.vault")
  ok("[5.1] vault.SOURCE_ID is the stable id constant",
    vault_mod.SOURCE_ID == "auto-finder-vault",
    "got " .. tostring(vault_mod.SOURCE_ID))

  -- Spin up a fresh bound source pointing at __no_active__ (the
  -- setup.lua initial state when no vault is active yet). Then call
  -- vault.load("work") and assert: (a) source.path was repointed,
  -- (b) source.display_name DID NOT change (= SOURCE_ID throughout),
  -- (c) any source_reload call went through with SOURCE_ID as the
  -- single argument.
  local placeholder = vault_mod.state_dir() .. "/__no_active__.json.enc"
  local stable_src = enc.new(placeholder, { name = vault_mod.SOURCE_ID })
  enc._set_passphrase_for_testing("hunter2")
  vault_mod.bind_source(stable_src)

  ok("[5.2] bound source initially named SOURCE_ID",
    stable_src:name() == vault_mod.SOURCE_ID,
    "got " .. tostring(stable_src:name()))

  -- Intercept dbee.api.core.source_reload so we can prove the
  -- argument is SOURCE_ID rather than the vault basename.
  local reload_calls = {}
  local ok_api, api = pcall(require, "dbee.api")
  local orig_reload
  if ok_api and api and api.core then
    orig_reload = api.core.source_reload
    api.core.source_reload = function(id)
      table.insert(reload_calls, id)
      return true
    end
  else
    skip("[5.3] source_reload interception",
      "dbee.api.core not available — listing skipped")
  end

  local lname = "work"  -- created in section [3]
  local _, lerr = vault_mod.load(lname)
  ok("[5.3] vault.load returns no error", lerr == nil, lerr)

  ok("[5.4] source.path was repointed to the loaded vault",
    stable_src.path:sub(-#"work.json.enc") == "work.json.enc",
    "got path=" .. tostring(stable_src.path))

  ok("[5.5] source.name() STILL returns SOURCE_ID after vault.load",
    stable_src:name() == vault_mod.SOURCE_ID,
    "got name=" .. tostring(stable_src:name()))

  if orig_reload then
    ok("[5.6] dbee.api.core.source_reload was called at least once",
      #reload_calls >= 1, "calls=" .. vim.inspect(reload_calls))
    ok("[5.7] every source_reload call used SOURCE_ID, not vault name",
      (function()
        for _, id in ipairs(reload_calls) do
          if id ~= vault_mod.SOURCE_ID then return false end
        end
        return #reload_calls > 0
      end)(),
      "calls=" .. vim.inspect(reload_calls))
    api.core.source_reload = orig_reload  -- restore
  end

  -- Switch vaults — load the migrated vault from section [2] (which
  -- lives at a different path) and re-assert. This exercises the
  -- A → B switch class of failure Lector called out specifically.
  -- We re-use the existing migrated vault file rather than creating
  -- a new one, by symlinking it into the state dir under a new name.
  local switch_target = vault_mod.state_dir() .. "/switch.json.enc"
  vim.fn.delete(switch_target)
  -- A regular copy works fine for this test — we just need a second
  -- valid vault path the controller can switch to.
  vim.fn.system({ "cp", plain_dest, switch_target })

  reload_calls = {}
  if orig_reload then
    api.core.source_reload = function(id)
      table.insert(reload_calls, id)
      return true
    end
  end
  enc._set_passphrase_for_testing("hunter2")
  local _, switch_err = vault_mod.load("switch")
  ok("[5.8] vault.load switches to a different vault without error",
    switch_err == nil, switch_err)
  ok("[5.9] source.path now points to switch.json.enc",
    stable_src.path:sub(-#"switch.json.enc") == "switch.json.enc",
    "got path=" .. tostring(stable_src.path))
  ok("[5.10] source.name() STILL SOURCE_ID after vault SWITCH",
    stable_src:name() == vault_mod.SOURCE_ID,
    "got name=" .. tostring(stable_src:name()))
  if orig_reload then
    ok("[5.11] source_reload after switch still uses SOURCE_ID",
      (function()
        for _, id in ipairs(reload_calls) do
          if id ~= vault_mod.SOURCE_ID then return false end
        end
        return #reload_calls > 0
      end)(),
      "calls=" .. vim.inspect(reload_calls))
    api.core.source_reload = orig_reload
  end
end

-- ───────────────────── 6. decrypt-error propagation (lector should-fix) ─
-- vault.connections() must return (nil, err) on decrypt failure rather
-- than silently empty list — populated vault must not look "wiped"
-- to the user when the passphrase is wrong.
print("\n[6] vault.connections() propagates decrypt errors")
do
  local vault_mod = require("auto-finder.views.dbase.vault")
  -- Build a vault with a known passphrase, then prime the CACHE with
  -- the WRONG passphrase and force a re-decrypt by dropping the
  -- plaintext cache (enc.lock). Then call vault.connections() and
  -- assert the error surfaces.
  local err_vault_path = vault_mod.state_dir() .. "/err-probe.json.enc"
  enc._set_passphrase_for_testing("the-right-pass")
  enc.lock()
  enc._set_passphrase_for_testing("the-right-pass")
  local stub_src = enc.new(err_vault_path, { name = vault_mod.SOURCE_ID })
  -- Write a real vault with one connection using the right passphrase.
  pcall(stub_src.create, stub_src, { name = "x", type = "sqlite", url = ":memory:" })

  -- Now bind a FRESH source instance pointing at the same path, and
  -- prime the cache with the WRONG passphrase. The XOR stub's
  -- decrypt with the wrong passphrase yields garbage JSON, which
  -- read_vault catches as "decrypted payload is not valid JSON".
  enc.lock()
  enc._set_passphrase_for_testing("wrong-pass")
  local fresh_src = enc.new(err_vault_path, { name = vault_mod.SOURCE_ID })
  vault_mod.bind_source(fresh_src)

  local conns, err = vault_mod.connections()
  ok("[6.1] vault.connections() returns nil-or-empty + an err on bad decrypt",
    err ~= nil,
    "conns=" .. vim.inspect(conns) .. " err=" .. tostring(err))
  ok("[6.2] err string mentions the actual problem",
    type(err) == "string"
      and (err:find("JSON") or err:find("decrypt") or err:find("passphrase")),
    "got err=" .. tostring(err))
end

-- ───────────────────── 7. pre-setup WARN suppression (lector re-review) ─
-- vault.repoint_source must NOT call dbee.api.core.source_reload (and
-- therefore must not log a WARN) when dbee.setup hasn't run yet. The
-- `dbase load <name>` path before first dbase focus is legal and
-- should be a quiet success.
print("\n[7] vault.repoint_source skips dbee reload when setup is not done")
do
  local vault_mod = require("auto-finder.views.dbase.vault")
  local setup_mod = require("auto-finder.views.dbase.setup")
  local logger = require("auto-finder.log")

  -- Force setup_done = false. We can't call setup_mod.ensure_setup
  -- yet because it would actually run dbee.setup; instead drop the
  -- _done flag directly to simulate the pre-first-focus state.
  setup_mod.reset()
  ok("[7.1] setup.is_setup_done() reports false before reset baseline",
    setup_mod.is_setup_done() == false)

  -- Capture any WARN entries the logger emits during this section.
  local original_warn = logger.warn
  local captured_warns = {}
  ---@diagnostic disable-next-line: duplicate-set-field
  logger.warn = function(ns, msg, ...)
    captured_warns[#captured_warns + 1] = { ns = ns, msg = msg }
    return original_warn(ns, msg, ...)
  end

  -- Set up a fresh bound source pointing at the placeholder path.
  enc._set_passphrase_for_testing("hunter2")
  local pre_path = vault_mod.state_dir() .. "/__no_active__.json.enc"
  vault_mod.bind_source(enc.new(pre_path, { name = vault_mod.SOURCE_ID }))

  -- vault.load — the path that previously emitted the false WARN.
  -- Use the "work" vault created in section [3].
  local _, lerr = vault_mod.load("work")
  ok("[7.2] vault.load returns no error pre-setup", lerr == nil, lerr)

  local saw_reload_warn = false
  for _, w in ipairs(captured_warns) do
    if type(w.msg) == "string" and w.msg:find("source_reload failed") then
      saw_reload_warn = true; break
    end
  end
  ok("[7.3] no `source_reload failed` WARN emitted pre-setup",
    not saw_reload_warn,
    "got warns=" .. vim.inspect(captured_warns))

  -- Path repointing AND active marker MUST still happen — only the
  -- dbee reload is conditional.
  ok("[7.4] source.path was still repointed despite no dbee reload",
    vault_mod._bound_source_for_testing().path
      :sub(-#"work.json.enc") == "work.json.enc")
  ok("[7.5] vault.current() still reflects the loaded vault",
    vault_mod.current() == "work")

  logger.warn = original_warn
end

-- ───────────────────── 8. provider posture (lector re-review) ──────────
-- gpg is the default; age requires AUTO_FINDER_DBASE_PROVIDER_AGE=1.
print("\n[8] provider posture: gpg default, age opt-in")
do
  -- Drop the test stub-xor override so we exercise the live registry.
  crypto.set_provider(nil)

  -- Inject one synthetic provider into the default registry (gpg-slot)
  -- and one into the age-opt-in slot. The latter uses a dedicated
  -- setter because the age slot is gated separately by env var —
  -- it's NOT part of the default PROVIDERS list.
  local stub_gpg = {
    name    = "gpg",
    probe   = function() return "fake-gpg" end,
    encrypt = function(s) return "G:" .. s, nil end,
    decrypt = function(s) return s:sub(3), nil end,
  }
  local stub_age = {
    name    = "age",
    probe   = function() return "fake-age" end,
    encrypt = function(s) return "A:" .. s, nil end,
    decrypt = function(s) return s:sub(3), nil end,
  }
  crypto._register_provider(stub_gpg)             -- default-active
  crypto._set_age_provider_for_testing(stub_age)  -- env-gated

  -- Default posture: age opt-in env NOT set → gpg wins.
  vim.env.AUTO_FINDER_DBASE_PROVIDER_AGE = nil
  local prov = crypto.available()
  ok("[8.1] default provider is gpg when AGE opt-in is unset",
    prov and prov.name == "gpg",
    vim.inspect(prov))

  -- Opt-in: env set to "1" → age wins (it's listed first when
  -- enabled, matching the implementation).
  vim.env.AUTO_FINDER_DBASE_PROVIDER_AGE = "1"
  prov = crypto.available()
  ok("[8.2] age wins when AUTO_FINDER_DBASE_PROVIDER_AGE=1",
    prov and prov.name == "age",
    vim.inspect(prov))

  -- Empty string still means "off".
  vim.env.AUTO_FINDER_DBASE_PROVIDER_AGE = ""
  prov = crypto.available()
  ok("[8.3] empty string env value does NOT enable age",
    prov and prov.name == "gpg",
    vim.inspect(prov))

  -- Header-dispatch still finds age on read even when the registry
  -- isn't currently advertising it (a vault encrypted on a machine
  -- with AGE opt-in must decrypt on a machine where the env is
  -- unset, provided age is on PATH).
  vim.env.AUTO_FINDER_DBASE_PROVIDER_AGE = "1"
  local ct = crypto.encrypt("hello", "pass")
  ok("[8.4] encrypt under AGE produces an age-tagged blob",
    ct and ct:find("AUTO%-FINDER%-DBASE%-VAULT v1 age"),
    "got header=" .. tostring(ct and ct:sub(1, 50)))
  vim.env.AUTO_FINDER_DBASE_PROVIDER_AGE = nil
  local pt = crypto.decrypt(ct, "pass")
  ok("[8.5] age-encrypted blob decrypts when env is unset (probe still finds age)",
    pt == "hello",
    "got pt=" .. tostring(pt))

  crypto._unregister_provider("gpg")
  crypto._set_age_provider_for_testing(nil)  -- restore production age entry
end

-- ───────────────────── 9. cleanup + report ─────────────────────────────
crypto.set_provider(nil)
crypto._unregister_provider("stub-xor")

print("\n──────────────────────────────────────────────")
print(string.format("Encrypted vault smoke: %d passed, %d failed, %d skipped",
  pass_count, fail_count, skip_count))
print("──────────────────────────────────────────────")
vim.cmd("cquit " .. (fail_count == 0 and "0" or "1"))
