---auto-finder.shared.window — window-walking helpers per
---[[auto-core-panel-ownership]].
---
---The canonical panel marker is `w:auto_core_panel_name` — a
---non-empty string means "this window is an auto-core panel
---owned by some plugin." The legacy `w:auto_finder_panel = 1`
---marker is still stamped on auto-finder's panel for backwards
---compat (existing code that hasn't migrated yet).
---
---Two predicates, asymmetric per the convention:
---
---  is_any_panel(winid)         — broad: any auto-core panel
---                                 (used for exclusion when
---                                 picking a non-panel target)
---  is_auto_finder_panel(winid) — narrow: only auto-finder's
---                                 panel (used for targeted
---                                 lookups + the five-guard
---                                 _still_current predicate
---                                 in build_section)
---
---@module 'auto-finder.shared.window'

local M = {}

---Broad exclusion check — any auto-core-stamped panel
---(auto-finder, auto-agents, future plugins). Use this when
---picking an editor-area target that must NOT be a panel.
---@param winid integer
---@return boolean
function M.is_any_panel(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then return false end
  if vim.w[winid].auto_finder_panel == 1 then return true end
  local name = vim.w[winid].auto_core_panel_name
  return type(name) == "string" and name ~= ""
end

---Narrow check — specifically auto-finder's panel. Matches both
---the legacy marker and the canonical name. Used by the
---five-guard `_still_current` predicate in build_section's
---placeholder mount.
---@param winid integer
---@return boolean
function M.is_auto_finder_panel(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then return false end
  if vim.w[winid].auto_finder_panel == 1 then return true end
  return vim.w[winid].auto_core_panel_name == "auto-finder"
end

return M
