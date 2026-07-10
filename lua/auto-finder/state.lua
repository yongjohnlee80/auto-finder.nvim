---auto-finder.state — auto-core.state namespace wrapper.
---
---v0.2.0 migration step 2/4: panel `user_width` (the resize pin) and
---`last_section` (the section index restored on next open) move out of
---auto-finder's own JSON store at
---`<config>/.auto-finder/config.json` and into
---`auto-core.state.namespace("auto-finder", { persist = "json" })`,
---which persists to `<state>/auto-core/auto-finder.json`. The legacy
---store keeps the `files.*` filter prefs for now (out of scope for
---this step; future cleanup migrates them).
---
---Why a wrapper rather than direct namespace access at every call site:
---  - **type validation** lives here so callers don't repeat `type(n)
---    == "number"` checks
---  - **mirror sync**: a single watch in setup() keeps `M.state.user_
---    width` and `M.state.section` consistent with the namespace, so
---    the existing reader sites (winbar status, neo-tree fork's
---    pin-check, M.open's default-section fallback) keep working
---    unchanged
---  - **migration shim**: the one-shot legacy-store→namespace seed
---    runs here (called from init.lua's setup once after store.load)
---
---Public surface:
---
---  state.setup()                     -- claim namespace; idempotent
---  state.namespace()                 -- raw handle (advanced use)
---  state.get_user_width()            → integer?
---  state.set_user_width(n?)          → ok, err?
---  state.get_last_section()          → integer?
---  state.set_last_section(n?)        → ok, err?
---  state.get_sections_for(wskey)         → string[]?
---  state.set_sections_for(wskey, …)      → ok, err?
---  state.get_last_section_for(wskey)     → integer?
---  state.set_last_section_for(wskey, n?) → ok, err?
---  state.get_follow(section)             → boolean?
---  state.set_follow(section, enabled?)   → ok, err?
---  state.watch_user_width(cb)            → handle
---  state.watch_last_section(cb)          → handle
---
---Each watch_* helper subscribes the callback to
---`state.auto-finder:<key>:changed`. Callbacks receive the auto-core
---state-change payload `{ namespace, key, new, old }`.
---
---Note on range validation: width range (`cfg.width.min..max`) and
---section-registry validity are CALL-SITE concerns and stay there.
---The setters here only enforce type (number-or-nil). Mirrors the
---auto-agents v0.2.0 migration shape (commit `e2ab2d0`).
---
---`section_buffers` (the runtime per-section bufnr cache) is
---intentionally NOT routed through state.namespace — bufnrs reset
---every nvim session, so persisting them would be wrong. It stays
---in `M.state.section_buffers` as a transient runtime field.
---@module 'auto-finder.state'

local core = require("auto-core")

local M = {}

local NS_NAME = "auto-finder"

local DEFAULTS = {
  user_width   = nil,  -- nil = dynamic (resolved from cfg.width.default)
  last_section = nil,  -- nil = use cfg.default_section on next open
  -- v0.2.5: per-project section configuration. Keyed by workspace
  -- hash (sha256(workspace_root):sub(1,16) — the same shape
  -- md-harpoon uses for its per-project pins). Each entry holds
  -- the ordered slot list (e.g. { "config", "files", "buffers" }).
  -- Empty default — `get_sections_for(wskey)` returns nil for an
  -- unknown project, and `auto-finder.setup()` falls back to its
  -- own `{ config, files, repos }` default in that case.
  --
  -- Why per-project: different projects want different section
  -- mixes — e.g. a Go service uses `files + buffers`, a database
  -- ops project will want a `dbase` section (planned), a remote
  -- VPS workflow will want a `remote` section (planned). The
  -- v0.2.1 `cfg.section_modules` registry lets third parties
  -- register those types; this map persists the user's per-project
  -- composition.
  sections = {},
  -- v0.2.28: per-project last_section. Keyed by the same workspace
  -- hash as `sections`. Each entry holds the section index the
  -- user last focused on that project. Eliminates the
  -- "stale section 4 from project1 displayed as empty panel in
  -- project2" bug — the previous global `last_section` bled
  -- across workspaces. Writers update BOTH this map and the
  -- legacy `last_section` key so a downgrade still finds a
  -- sensible value; readers prefer this map and only fall back
  -- to the global key on a per-workspace miss.
  last_section_by_workspace = {},
  -- v0.2.70: persisted follow-mode toggles, keyed by section name
  -- ("files" / "repos"). Tri-state per section: absent = the user
  -- never toggled → the config default (`cfg.<section>.follow`)
  -- applies; true/false = explicit user choice via the admin DSL
  -- (`files follow on|off`), which now survives nvim restarts.
  -- Global (not per-workspace) — follow is a behavioral preference,
  -- not a project composition.
  follow = {},
}

local _ns = nil

---Idempotent claim of the auto-core namespace. Safe to call from
---setup() multiple times — auto-core's namespace registry is
---singleton-per-name.
---@return any  AutoCoreStateNamespace
function M.setup()
  if _ns then return _ns end
  _ns = core.state.namespace(NS_NAME, {
    defaults = DEFAULTS,
    persist  = "json",
  })
  return _ns
end

---Raw namespace handle. Use this for `:get_all()` snapshots, custom
---watches outside the helpers below, or `:persist_now()` flushes.
---@return any
function M.namespace()
  if not _ns then M.setup() end
  return _ns
end

-- ── user_width ───────────────────────────────────────────────

---@return integer?
function M.get_user_width()
  return M.namespace():get("user_width")
end

---Set or clear the panel width pin. `nil` clears (panel falls back
---to the dynamic resolver). Type-validated only — range validation
---against `cfg.width.min/max` stays at the call site (panel/host.lua
---M.resize).
---@param n integer?
---@return boolean ok, string? err
function M.set_user_width(n)
  if n == nil then
    M.namespace():set("user_width", nil)
    return true
  end
  if type(n) ~= "number" or n ~= math.floor(n) then
    return false, "user_width must be nil or an integer; got " .. tostring(n)
  end
  M.namespace():set("user_width", n)
  return true
end

---@param cb fun(payload: { namespace: string, key: string, new: any, old: any })
---@return any
function M.watch_user_width(cb)
  return M.namespace():watch("user_width", cb)
end

-- ── last_section ─────────────────────────────────────────────

---@return integer?
function M.get_last_section()
  return M.namespace():get("last_section")
end

---Update the last-focused section index. Type-validated only;
---section-registry validity stays at the call site (init.lua's
---legacy seed and panel/host.lua's focus path). Persists across
---nvim restarts — same behavior as the previous `store.update({
---panel = { last_section = ... } })` path it replaces.
---@param n integer?
---@return boolean ok, string? err
function M.set_last_section(n)
  if n == nil then
    M.namespace():set("last_section", nil)
    return true
  end
  if type(n) ~= "number" or n ~= math.floor(n) then
    return false, "last_section must be nil or an integer; got " .. tostring(n)
  end
  M.namespace():set("last_section", n)
  return true
end

---@param cb fun(payload: { namespace: string, key: string, new: any, old: any })
---@return any
function M.watch_last_section(cb)
  return M.namespace():watch("last_section", cb)
end

-- ── per-project section composition (v0.2.5) ─────────────────

---Fetch the persisted section list for `workspace_key`. Returns
---nil if the project has no recorded composition (caller falls
---back to its own default — `auto-finder.setup()` uses
---`{ "config", "files", "repos" }`).
---@param workspace_key string?  sha256(workspace_root):sub(1,16)
---@return string[]?
function M.get_sections_for(workspace_key)
  if type(workspace_key) ~= "string" or workspace_key == "" then return nil end
  local all = M.namespace():get("sections") or {}
  local v = all[workspace_key]
  if type(v) == "table" and #v > 0 then return v end
  return nil
end

---Persist the section list for `workspace_key`. Validates only
---that the list is a non-empty array of strings; uniqueness +
---registry-resolvability are CALL-SITE concerns
---(`auto-finder.slot_add` / `slot_modify` enforce them).
---@param workspace_key string
---@param sections string[]
---@return boolean ok, string? err
function M.set_sections_for(workspace_key, sections)
  if type(workspace_key) ~= "string" or workspace_key == "" then
    return false, "workspace_key must be a non-empty string"
  end
  if type(sections) ~= "table" or #sections == 0 then
    return false, "sections must be a non-empty list of strings"
  end
  for _, s in ipairs(sections) do
    if type(s) ~= "string" or s == "" then
      return false, "sections list must contain non-empty strings"
    end
  end
  -- Copy so we don't store a reference to a table the caller
  -- might mutate; auto-core's state diff treats deep-eq, but a
  -- defensive copy keeps the persisted shape decoupled.
  local copy = {}
  for i, s in ipairs(sections) do copy[i] = s end

  local all = vim.deepcopy(M.namespace():get("sections") or {})
  all[workspace_key] = copy
  M.namespace():set("sections", all)
  return true
end

-- ── per-project last_section (v0.2.28) ───────────────────────

---Fetch the persisted last-focused section for `workspace_key`.
---Returns nil when the project has no record yet — caller falls
---back to the legacy global `get_last_section()` (or
---`cfg.default_section`).
---@param workspace_key string?  sha256(workspace_root):sub(1,16)
---@return integer?
function M.get_last_section_for(workspace_key)
  if type(workspace_key) ~= "string" or workspace_key == "" then return nil end
  local all = M.namespace():get("last_section_by_workspace") or {}
  local n = all[workspace_key]
  if type(n) == "number" then return n end
  return nil
end

---Persist the last-focused section for `workspace_key`. Pass `nil`
---to clear the per-workspace record (caller falls through to the
---legacy global key on next read).
---@param workspace_key string
---@param n integer?
---@return boolean ok, string? err
function M.set_last_section_for(workspace_key, n)
  if type(workspace_key) ~= "string" or workspace_key == "" then
    return false, "workspace_key must be a non-empty string"
  end
  if n ~= nil and (type(n) ~= "number" or n ~= math.floor(n)) then
    return false, "last_section must be nil or an integer; got " .. tostring(n)
  end
  local all = vim.deepcopy(M.namespace():get("last_section_by_workspace") or {})
  all[workspace_key] = n
  M.namespace():set("last_section_by_workspace", all)
  return true
end

-- ── follow-mode persistence (v0.2.70) ────────────────────────

---Fetch the persisted follow toggle for a section. Returns nil when
---the user never toggled it — caller falls back to the config
---default (`cfg.<section>.follow`).
---@param section "files"|"repos"
---@return boolean?
function M.get_follow(section)
  if type(section) ~= "string" or section == "" then return nil end
  local all = M.namespace():get("follow") or {}
  local v = all[section]
  if type(v) == "boolean" then return v end
  return nil
end

---Persist the follow toggle for a section. Pass `nil` to clear the
---record (config default applies again on next setup).
---@param section "files"|"repos"
---@param enabled boolean?
---@return boolean ok, string? err
function M.set_follow(section, enabled)
  if type(section) ~= "string" or section == "" then
    return false, "section must be a non-empty string"
  end
  if enabled ~= nil and type(enabled) ~= "boolean" then
    return false, "follow must be nil or a boolean; got " .. tostring(enabled)
  end
  local all = vim.deepcopy(M.namespace():get("follow") or {})
  all[section] = enabled
  M.namespace():set("follow", all)
  return true
end

-- ── test-only ────────────────────────────────────────────────

---Test-only: clear the namespace cache + reset every key to defaults.
---Production code never calls this.
function M._reset_for_tests()
  if _ns then
    pcall(function()
      _ns:set("user_width",                DEFAULTS.user_width)
      _ns:set("last_section",              DEFAULTS.last_section)
      _ns:set("sections",                  vim.deepcopy(DEFAULTS.sections))
      _ns:set("last_section_by_workspace", vim.deepcopy(DEFAULTS.last_section_by_workspace))
      _ns:set("follow",                    vim.deepcopy(DEFAULTS.follow))
    end)
  end
  _ns = nil
end

return M
