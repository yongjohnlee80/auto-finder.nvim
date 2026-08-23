---Config slot — interactive prompt buffer with a small command DSL.
---
---Modeled on auto-agents.nvim's panel/admin.lua. The buffer has
---`buftype = "prompt"`; <CR> on the prompt line fires the dispatch
---callback. Output is appended above the prompt like a REPL — the
---user always types at the bottom.
---@module 'auto-finder.panel.admin'

local M = {}

M._bufnr = nil

local PROMPT = "auto-finder> "

local function buf_valid()
  return M._bufnr ~= nil and vim.api.nvim_buf_is_valid(M._bufnr)
end

---Insert lines just above the prompt (always the last line of the buffer).
---@param lines string[]
local function emit(lines)
  if not buf_valid() or #lines == 0 then return end
  local count = vim.api.nvim_buf_line_count(M._bufnr)
  vim.api.nvim_buf_set_lines(M._bufnr, count - 1, count - 1, false, lines)
end

local function help_lines()
  return {
    "",
    "Commands:",
    "  help, ?, :h                  show this help (use `help <topic>` to drill in)",
    "  focus <N|name>               switch section (e.g. focus 1, focus files)",
    "  panel resize <N>             pin panel width to N cols (HARD CAP, in [min..max])",
    "  panel reset | dynamic        clear pin; let neo-tree auto-expand again",
    "  panel show                   display mode, default, range, live width",
    "  files show hidden            show .gitignored files in the tree",
    "  files show dotfiles          show files starting with `.` in the tree",
    "  files hide hidden            hide .gitignored files",
    "  files hide dotfiles          hide files starting with `.`",
    "  files follow on|off|toggle   reveal the active buffer in the files tree on BufEnter",
    "  repos follow on|off|toggle   reveal the active buffer's repo in the repos panel",
    "  slot add <type>              add a section of <type> at the end of the slot list",
    "  slot remove <N>              remove section at slot N (N>=1; slot 0 is protected)",
    "  slot modify <N> <type>       replace the section at slot N with <type>",
    "  slot assign                  walk slots 1..9 and re-arrange them interactively",
    "  slot assign <t1> <t2> …      set the whole arrangement in one line",
    "  slot types                   list available section types",
    "  dbase new <name>             create empty connections vault (encrypted if age/gpg present)",
    "  dbase ls                     list available vaults",
    "  dbase rm <name>              delete a vault",
    "  dbase load [name]            activate vault (prompts if name omitted)",
    "  dbase conn add               prompt for name/type/url, append to active vault",
    "  dbase conn ls                list connections in the active vault",
    "  dbase conn rm <name>         remove a connection by name",
    "  dbase migrate <name>         encrypt a legacy plaintext file to a vault",
    "  dbase rmlegacy <name>        delete a legacy plaintext file (after migrate)",
    "  dbase status                 show storage mode, provider, active vault, file counts",
    "  dbase lock                   forget cached passphrase (re-prompt on next access)",
    "  reload                       re-render the active section",
    "  status                       show current section, width, pin state",
    "  clear                        wipe history above the prompt",
    "  quit                         close the panel",
    "",
    "  defaults: hidden + dotfiles are SHOWN; files-follow ON, repos-follow OFF.",
    "",
  }
end

---Mutate neo-tree's runtime config for the filesystem source's
---filtered_items, then refresh the active section so the change is
---visible immediately.
---@param what "hidden"|"dotfiles"
---@param show boolean
---@return string|nil err
local function set_files_filter(what, show)
  local ok, neo = pcall(require, "auto-finder.neotree")
  if not ok then return "auto-finder.neotree is not installed" end
  if type(neo.config) ~= "table" then return "auto-finder.neotree config is not loaded yet" end
  neo.config.filesystem = neo.config.filesystem or {}
  local fi = neo.config.filesystem.filtered_items or {}
  if what == "hidden" then
    -- "hidden" → gitignored files. neo-tree's `hide_gitignored = false`
    -- makes them appear in the tree; `visible = true` styles them as
    -- visible-but-marked. We flip both for "show" so the change is
    -- consistent with neo-tree's two-axis filtering.
    fi.hide_gitignored = not show
    if show then fi.visible = true end
  elseif what == "dotfiles" then
    fi.hide_dotfiles = not show
    if show then fi.visible = true end
  else
    return "unknown filter '" .. tostring(what) .. "' (try hidden|dotfiles)"
  end
  neo.config.filesystem.filtered_items = fi
  -- Persist via the canonical auto-core.files prefs so a `files
  -- show/hide` toggle here also propagates to other consumers
  -- (md-harpoon's snacks-picker invocation, future plugins). No
  -- more local store.update — the canonical prefs live in
  -- state.namespace("core") files.show_hidden / files.show_dotfiles.
  -- Note the negative→positive flip: store used `hide_*`, auto-core
  -- uses `show_*`.
  local ok_core, core = pcall(require, "auto-core")
  if ok_core and core and core.files then
    if what == "hidden" then
      core.files.set_show_hidden(show == true)
    else
      core.files.set_show_dotfiles(show == true)
    end
  end
  return nil
end

---Resolve the new state for a follow-mode toggle command.
---@param action string|nil  -- "on" | "off" | "toggle"
---@param current boolean
---@return boolean|nil new_state, string|nil err
local function resolve_follow_action(action, current)
  if action == "on" or action == "true" or action == "1" then
    return true, nil
  elseif action == "off" or action == "false" or action == "0" then
    return false, nil
  elseif action == "toggle" or action == nil or action == "" then
    return not current, nil
  end
  return nil, "argument must be 'on', 'off', or 'toggle' (got '"
    .. tostring(action) .. "')"
end

---Update neo-tree's runtime filesystem.follow_current_file.enabled
---so toggling at runtime takes effect on the next BufEnter without
---needing setup() to re-run.
---@param enabled boolean
local function set_neotree_follow(enabled)
  local ok, neo = pcall(require, "auto-finder.neotree")
  if not ok or type(neo.config) ~= "table" then return end
  neo.config.filesystem = neo.config.filesystem or {}
  local fcf = neo.config.filesystem.follow_current_file
  if type(fcf) ~= "table" then
    fcf = { leave_dirs_open = false }
    neo.config.filesystem.follow_current_file = fcf
  end
  fcf.enabled = enabled == true
end

---Toggle a section's `cfg.<section>.follow` flag in-place on the
---live config, mirroring the change into neo-tree's runtime config
---for the files case so the BufEnter reveal turns on/off immediately.
---For repos, the autocmd installed by init.lua reads the flag at
---fire time, so the in-memory mutation is enough.
---@param section "files"|"repos"
---@param action string|nil  -- "on" | "off" | "toggle"
---@return string|nil err
local function set_follow(section, action)
  local af = require("auto-finder")
  if not (af.state and af.state.config) then
    return "config not initialized (call require('auto-finder').setup() first)"
  end
  af.state.config[section] = af.state.config[section] or {}
  local current = af.state.config[section].follow == true
  local new_state, err = resolve_follow_action(action, current)
  if err then return err end
  af.state.config[section].follow = new_state
  if section == "files" then
    set_neotree_follow(new_state)
  end
  -- v0.2.70: persist the toggle in the auto-finder state namespace so
  -- it survives nvim restarts (setup() reads it back and overrides the
  -- config default). Best-effort — a persistence failure must not
  -- break the live toggle that already applied above.
  pcall(function()
    require("auto-finder.state").set_follow(section, new_state)
  end)
  return nil
end

local function status_lines()
  local af = require("auto-finder")
  local sections = require("auto-finder.views").enabled()
  local labels = {}
  for _, s in ipairs(sections) do
    table.insert(labels, string.format("%d:%s", s.number, s.name))
  end
  local pin = af.state.user_width and " (pinned)" or ""
  local cfg = af.state.config or {}
  local w = cfg.width or {}
  local cols = vim.o.columns
  local resolved = "?"
  if af.state.config then
    local ok, n = pcall(require("auto-finder.config").resolve_width,
      af.state.config, cols)
    if ok then resolved = tostring(n) end
  end
  local live = "?"
  if af.state.panel_winid and vim.api.nvim_win_is_valid(af.state.panel_winid) then
    live = tostring(vim.api.nvim_win_get_width(af.state.panel_winid))
  end
  local files_follow = cfg.files and cfg.files.follow == true
  local repos_follow = cfg.repos and cfg.repos.follow == true
  return {
    "",
    "  section: " .. tostring(af.state.section),
    "  width   cached: " .. tostring(af.state.panel_width) .. pin ..
      "   resolved: " .. resolved ..
      "   live: " .. live,
    "  cfg     percentage: " .. tostring(w.percentage) ..
      "   min: " .. tostring(w.min) ..
      "   max: " .. tostring(w.max) ..
      "   cols: " .. tostring(cols),
    "  follow  files: " .. (files_follow and "on" or "off") ..
      "   repos: " .. (repos_follow and "on" or "off"),
    "  enabled: " .. table.concat(labels, " "),
    "",
  }
end

local function tokenize(input)
  local toks = {}
  for tok in input:gmatch("%S+") do table.insert(toks, tok) end
  return toks
end

local function is_help_token(tok)
  return tok == "help" or tok == "?" or tok == ":h"
end

---Build + start the interactive `slot assign` walk.
---
---Runs through `panel.wizard` — the same step runner the dbase
---wizards use — rather than a `vim.ui.input` chain, so the whole
---re-arrangement stays in the REPL transcript and <C-c> cancels it
---like every other multi-step prompt in this buffer.
---
---One step per slot 1..`SLOT_MAX`:
---   <type>   assign that section type to this slot
---   <CR>     (empty) finish the list here — unreached slots are dropped
---   <C-c>    cancel; the current arrangement is untouched
---
---A rejected entry re-asks the SAME slot rather than unwinding the
---walk, so a typo costs one line and not the whole arrangement. The
---end-of-walk drop is confirmed only when it actually removes a
---section — a pure re-arrangement applies straight through.
local function start_slot_assign_wizard()
  local wizard = require("auto-finder.panel.wizard")
  local af = require("auto-finder")
  local cfg = af.state and af.state.config
  if not cfg or not cfg.sections or not cfg.sections[1] then
    emit({ "slot assign: config not initialized" })
    return
  end

  local current  = cfg.sections
  local head     = current[1]
  local max_slot = af.SLOT_MAX or 9

  -- Everything the registry knows about minus the protected slot-0
  -- section. Recomputed per invocation (not cached) so third-party
  -- sections registered since the last call are offered too.
  local offerable = {}
  for _, t in ipairs(af._available_section_types()) do
    if t ~= head then offerable[#offerable + 1] = t end
  end

  local function field(n) return "slot" .. n end

  ---Types assigned by steps 1..n-1, in slot order. Stops at the first
  ---unset slot, which is exactly where the walk ended.
  local function assigned_before(values, n)
    local out = {}
    for i = 1, n - 1 do
      local v = values[field(i)]
      if v == nil then break end
      out[#out + 1] = v
    end
    return out
  end

  local function remaining_for(values, n)
    local taken = {}
    for _, t in ipairs(assigned_before(values, n)) do taken[t] = true end
    local out = {}
    for _, t in ipairs(offerable) do
      if not taken[t] then out[#out + 1] = t end
    end
    return out
  end

  local steps = {}
  for n = 1, max_slot do
    steps[#steps + 1] = {
      field = field(n),
      -- Both skip conditions are derived from `values`, so the runner
      -- needs no extra state: skip once the walk has ended (the
      -- previous slot came back empty) or once every offerable type
      -- is already spoken for.
      skip = function(values)
        if n > 1 and values[field(n - 1)] == nil then return true end
        return #remaining_for(values, n) == 0
      end,
      prompt = function()
        local now = current[n + 1]
        return string.format("slot %d%s", n,
          now and (" (now " .. now .. ")") or "")
      end,
      -- Normalise before validation so a whitespace-only line reads as
      -- "empty" (end of list) rather than as a section named "  ".
      parse = function(v)
        if v == nil then return nil end
        v = vim.trim(tostring(v))
        if v == "" then return nil end
        return v
      end,
      validate = function(value, values)
        if value == nil then return true end   -- empty → end of list
        if value == head then
          return false, "'" .. value .. "' is the protected slot-0 section"
        end
        for i, t in ipairs(assigned_before(values, n)) do
          if t == value then
            return false, "'" .. value .. "' is already at slot " .. i
          end
        end
        for _, t in ipairs(offerable) do
          if t == value then return true end
        end
        return false, "unknown type '" .. value .. "' — remaining: "
          .. table.concat(remaining_for(values, n), ", ")
      end,
    }
  end

  local function apply(tail, out)
    local err = af.slot_assign(tail)
    if err then
      out({ "  ! " .. err })
      return
    end
    out({
      "  slots: " .. table.concat(af.state.config.sections, " "),
      "  saved for this workspace — survives a restart.",
    })
  end

  local shown = {}
  for i = 2, #current do
    shown[#shown + 1] = (i - 1) .. ":" .. current[i]
  end

  wizard.start({
    name = "slot assign",
    banner = {
      "slot assign — re-arrange slots 1.." .. max_slot
        .. " (slot 0 '" .. head .. "' is fixed)",
      "  current:   " .. (#shown > 0 and table.concat(shown, "  ") or "(none)"),
      "  available: " .. table.concat(offerable, ", "),
      "  empty <CR> ends the list; slots you never reach are dropped.",
    },
    steps = steps,
    on_cancel = function(out)
      if out then out({ "  slot assign: cancelled — slots unchanged." }) end
    end,
    on_complete = function(values, out)
      local tail = assigned_before(values, max_slot + 1)
      if #tail == 0 then
        out({ "  slot assign: nothing assigned — slots unchanged." })
        return
      end

      local kept = {}
      for _, t in ipairs(tail) do kept[t] = true end
      local dropped = {}
      for i = 2, #current do
        if not kept[current[i]] then dropped[#dropped + 1] = current[i] end
      end
      if #dropped == 0 then return apply(tail, out) end

      -- Ending the walk early removes every section you did not
      -- re-list, taking its buffer with it. Cheap to do by accident on
      -- a wide arrangement, so this one case asks first.
      out({
        "  result:   " .. head .. " " .. table.concat(tail, " "),
        "  dropping: " .. table.concat(dropped, ", "),
      })
      local noun = (#dropped == 1) and "section" or "sections"
      wizard.start({
        name = "slot assign — confirm",
        steps = { {
          field   = "confirm",
          prompt  = "apply, dropping " .. #dropped .. " " .. noun .. "?",
          choices = { "y", "n" },
          default = "n",
        } },
        on_cancel = function(cout)
          if cout then cout({ "  slot assign: cancelled — slots unchanged." }) end
        end,
        on_complete = function(cvals, cout)
          if tostring(cvals.confirm or "n"):lower():match("^y") then
            apply(tail, cout)
          else
            cout({ "  slot assign: cancelled — slots unchanged." })
          end
        end,
      }, out)
    end,
  }, emit)
end

-- Forward declarations: dispatch() needs help_topic_lines and
-- panel_show_lines, get_or_create_buffer()'s <Tab> keymap needs
-- trigger_complete; all three are filled in further down so the
-- topical help table, panel-show formatter, and completion candidate
-- logic can stay grouped at the bottom of the file.
local help_topic_lines
local trigger_complete
local panel_show_lines

local function dispatch(input)
  input = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if input == "" then return end

  local toks = tokenize(input)
  local verb = toks[1]
  local af = require("auto-finder")

  if is_help_token(verb) then
    -- `help <topic>` shows topical help; `help` alone shows the
    -- full overview. Topics map onto the verb groups so users can
    -- discover what `panel`, `files`, `focus` accept without
    -- re-reading the whole help block.
    local topic = toks[2]
    if topic and topic ~= "" then
      emit(help_topic_lines(topic))
    else
      emit(help_lines())
    end
    return
  end

  if verb == "status" then
    emit(status_lines())

  elseif verb == "clear" then
    if buf_valid() then
      local last = vim.api.nvim_buf_line_count(M._bufnr)
      if last > 1 then
        vim.api.nvim_buf_set_lines(M._bufnr, 0, last - 1, false, {})
      end
    end

  elseif verb == "quit" then
    emit({ "(closing panel)" })
    vim.schedule(function() af.close() end)

  elseif verb == "reload" then
    vim.schedule(function() af.reload() end)

  elseif verb == "focus" then
    local target = toks[2]
    if not target then
      emit({ "focus: missing section (number or name)" })
    else
      vim.schedule(function()
        local ok, msg = af.focus(target)
        if not ok then emit({ "focus: " .. (msg or "failed") }) end
      end)
    end

  elseif verb == "panel" then
    local sub = toks[2]
    if sub == "resize" then
      local n = tonumber(toks[3])
      if not n then
        emit({ "panel resize: missing column count (e.g. 'panel resize 50')" })
      else
        vim.schedule(function() af.resize(n) end)
      end
    elseif sub == "reset" or sub == "dynamic" then
      -- `dynamic` is the user-facing alias for `reset` — both clear
      -- the pin and re-enable neo-tree's auto_expand_width.
      vim.schedule(function() af.reset_width() end)
    elseif sub == "show" then
      emit(panel_show_lines())
    else
      emit({ "panel: unknown subcommand '" .. tostring(sub) ..
        "' — try resize|reset|dynamic|show" })
    end

  elseif verb == "files" then
    local action = toks[2]
    if action == "follow" then
      local err = set_follow("files", toks[3])
      if err then
        emit({ "files follow: " .. err })
      else
        local state = af.state.config.files.follow and "on" or "off"
        emit({ "files follow: " .. state })
        vim.schedule(function() af.reload() end)
      end
    elseif action == "show" or action == "hide" then
      local what = toks[3]   -- hidden | dotfiles
      if what ~= "hidden" and what ~= "dotfiles" then
        emit({ "files " .. action .. ": target must be 'hidden' or 'dotfiles'" })
      else
        local err = set_files_filter(what, action == "show")
        if err then
          emit({ "files: " .. err })
        else
          emit({ "files: " .. action .. " " .. what })
          -- Re-render the files section so the change is visible
          -- immediately. If the user is currently on a different
          -- section, the change still takes effect on next focus.
          vim.schedule(function() af.reload() end)
        end
      end
    else
      emit({ "files: action must be 'show', 'hide', or 'follow' (got '"
        .. tostring(action) .. "')" })
    end

  elseif verb == "repos" then
    local action = toks[2]
    if action == "follow" then
      local err = set_follow("repos", toks[3])
      if err then
        emit({ "repos follow: " .. err })
      else
        local state = af.state.config.repos.follow and "on" or "off"
        emit({ "repos follow: " .. state })
      end
    else
      emit({ "repos: action must be 'follow' (got '" .. tostring(action) .. "')" })
    end

  elseif verb == "slot" then
    local sub = toks[2]
    if sub == "add" then
      local section_type = toks[3]
      if not section_type or section_type == "" then
        -- v0.2.6: a bare `slot add` is more useful as discovery
        -- than as an error. Print the still-available types
        -- (excluding ones already in use) so the user can pick.
        local in_use = af.state.config.sections or {}
        local in_use_set = {}
        for _, n in ipairs(in_use) do in_use_set[n] = true end
        local available, not_in_use = af._available_section_types(), {}
        for _, t in ipairs(available) do
          if not in_use_set[t] then not_in_use[#not_in_use + 1] = t end
        end
        if #not_in_use == 0 then
          emit({
            "slot add: every available type is already in use",
            "  in use:    " .. table.concat(in_use, " "),
            "  available: " .. table.concat(available, ", "),
          })
        else
          emit({
            "slot add <type> — pick one:",
            "  available: " .. table.concat(not_in_use, ", "),
            "  in use:    " .. table.concat(in_use, " "),
          })
        end
      else
        local err = af.slot_add(section_type)
        if err then
          emit({ "slot add: " .. err })
        else
          emit({ "slot added: " .. section_type
            .. "   sections: " .. table.concat(af.state.config.sections, " ") })
        end
      end
    elseif sub == "remove" then
      local n = tonumber(toks[3])
      if not n then
        emit({ "slot remove: N required (e.g. 'slot remove 2')" })
      else
        local err = af.slot_remove(n)
        if err then
          emit({ "slot remove: " .. err })
        else
          emit({ "slot removed: N=" .. n
            .. "   sections: " .. table.concat(af.state.config.sections, " ") })
        end
      end
    elseif sub == "modify" then
      local n = tonumber(toks[3])
      local new_type = toks[4]
      if not n then
        emit({ "slot modify: N required (e.g. 'slot modify 2 buffers')" })
      elseif not new_type or new_type == "" then
        emit({ "slot modify: new section type required" })
      else
        local err = af.slot_modify(n, new_type)
        if err then
          emit({ "slot modify: " .. err })
        else
          emit({ "slot modified: N=" .. n .. " → " .. new_type
            .. "   sections: " .. table.concat(af.state.config.sections, " ") })
        end
      end
    elseif sub == "assign" then
      if toks[3] then
        -- One-line form: `slot assign <t1> [<t2> …]` replaces the
        -- whole arrangement without prompting. Same all-or-nothing
        -- validation as the walk — for a user who already knows the
        -- layout they want (and the seam tests drive).
        local tail = {}
        for i = 3, #toks do tail[#tail + 1] = toks[i] end
        local err = af.slot_assign(tail)
        if err then
          emit({ err })
        else
          emit({ "slot assign: sections: "
            .. table.concat(af.state.config.sections, " ") })
        end
      else
        start_slot_assign_wizard()
      end
    elseif sub == "types" then
      local types = af._available_section_types()
      emit({ "available section types: " .. table.concat(types, ", ") })
    else
      emit({ "slot: subcommand must be 'add', 'remove', 'modify', "
        .. "'assign', or 'types' (got '" .. tostring(sub) .. "')" })
    end

  else
    -- Bare numeric input → focus N (e.g. user types "1" then <CR>).
    local n = tonumber(verb)
    if n then
      vim.schedule(function()
        local ok, msg = af.focus(n)
        if not ok then emit({ "focus: " .. (msg or "failed") }) end
      end)
    else
      emit({ "unknown command: " .. verb .. "  (try 'help')" })
    end
  end
end

---Get or lazily create the singleton config buffer.
---@return integer bufnr
function M.get_or_create_buffer()
  if buf_valid() then return M._bufnr end

  local bufnr = vim.api.nvim_create_buf(false, false)
  vim.bo[bufnr].buftype = "prompt"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].filetype = "auto-finder-config"
  pcall(vim.api.nvim_buf_set_name, bufnr, "auto-finder://config")

  vim.fn.prompt_setprompt(bufnr, PROMPT)
  vim.fn.prompt_setcallback(bufnr, function(input)
    -- Defer so vim has time to add the new prompt line. Without this,
    -- emit() would land between the user's input and the new prompt
    -- rather than above it.
    vim.schedule(function()
      local wizard = require("auto-finder.panel.wizard")
      if wizard.is_active() then
        wizard.feed(input or "")
      else
        dispatch(input)
      end
    end)
  end)

  -- <C-c> aborts an active wizard so multi-step prompts (dbase conn
  -- add, dbase load) can be cancelled in-panel. Falls through to the
  -- prompt buffer's default ^C when no wizard is running.
  vim.keymap.set({ "i", "n" }, "<C-c>", function()
    local wizard = require("auto-finder.panel.wizard")
    if wizard.is_active() then
      wizard.cancel()
    else
      local termcoded = vim.api.nvim_replace_termcodes("<C-c>", true, false, true)
      vim.api.nvim_feedkeys(termcoded, "n", false)
    end
  end, { buffer = bufnr, silent = true })

  -- Banner: written above the auto-generated prompt line.
  local banner = {
    "auto-finder.nvim — config (slot 0)",
    "Type ? for help, <Tab> for completion. Try 'status' to see panel state.",
  }
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, banner)

  -- Tab completion: buffer-local so we don't interfere with <Tab>
  -- elsewhere. Falls through to <C-n>/<C-p> walking the popup if
  -- it's already showing.
  vim.keymap.set("i", "<Tab>", function()
    if vim.fn.pumvisible() == 1 then return "<C-n>" end
    vim.schedule(trigger_complete)
    return ""
  end, { buffer = bufnr, expr = true, silent = true })
  vim.keymap.set("i", "<S-Tab>", function()
    if vim.fn.pumvisible() == 1 then return "<C-p>" end
    return "<S-Tab>"
  end, { buffer = bufnr, expr = true, silent = true })

  -- Pass F1..F12 through to global mappings instead of letting them
  -- land as literal `<F5>` text in the prompt buffer. The user's
  -- F-keys are typically wired to snacks float terminals (or other
  -- global functions) and should fire regardless of which buffer is
  -- focused. We briefly switch to normal mode (`<C-\><C-n>`) and
  -- re-feed the keystroke so vim's normal-mode dispatch picks up the
  -- global mapping; without this, prompt-buffer insert mode swallows
  -- F-keys and types their literal name.
  for i = 1, 12 do
    local key = string.format("<F%d>", i)
    vim.keymap.set("i", key, function()
      local exit = vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true)
      local fkey = vim.api.nvim_replace_termcodes(key, true, false, true)
      vim.api.nvim_feedkeys(exit .. fkey, "n", false)
    end, { buffer = bufnr, silent = true, nowait = true,
           desc = "passthrough " .. key .. " to global mapping" })
  end

  M._bufnr = bufnr
  return bufnr
end

---@return integer|nil
function M.get_bufnr()
  if buf_valid() then return M._bufnr end
  return nil
end

---For tests / external callers that want to drive the DSL programmatically.
---@param input string
function M.dispatch(input)
  dispatch(input)
end

-- ── tab completion ─────────────────────────────────────────────────────

---Compute completion candidates given the prompt text + cursor col.
---@param prompt string  -- line content after the prompt prefix
---@param cursor_col integer  -- 0-indexed cursor byte col within `prompt`
---@return integer token_start  -- 0-indexed start col of the current token
---@return string[] candidates  -- prefix-filtered, in display order
local function complete_at(prompt, cursor_col)
  local before = prompt:sub(1, cursor_col)
  local current = before:match("(%S*)$") or ""
  local token_start = #before - #current

  local prev_toks = {}
  for tok in before:sub(1, token_start):gmatch("%S+") do
    table.insert(prev_toks, tok)
  end

  local candidates
  if #prev_toks == 0 then
    candidates = { "help", "?", ":h", "focus", "panel", "files", "repos", "slot",
                   "reload", "status", "clear", "quit" }
  elseif #prev_toks == 1 and prev_toks[1] == "focus" then
    -- Numeric indices and section names from the live registry.
    candidates = {}
    local sections = require("auto-finder.views").enabled()
    for _, s in ipairs(sections) do
      table.insert(candidates, tostring(s.number))
      table.insert(candidates, s.name)
    end
  elseif #prev_toks == 1 and prev_toks[1] == "panel" then
    candidates = { "resize", "reset", "dynamic", "show" }
  elseif #prev_toks == 2 and prev_toks[1] == "panel" and prev_toks[2] == "resize" then
    -- Offer the configured default + a few round-number widths inside
    -- the allowed [min..max] range.
    local af = require("auto-finder")
    local cfg = af.state.config or {}
    local w = (cfg and cfg.width) or {}
    local default_w = w.default or 38
    local min_w, max_w = w.min or 25, w.max or 100
    local seen = {}
    candidates = {}
    local function push(v)
      local s = tostring(v)
      if v >= min_w and v <= max_w and not seen[s] then
        seen[s] = true
        table.insert(candidates, s)
      end
    end
    push(default_w)
    for _, v in ipairs({ 25, 30, 38, 50, 60, 80, 100 }) do push(v) end
  elseif #prev_toks == 1 and prev_toks[1] == "files" then
    candidates = { "show", "hide", "follow" }
  elseif #prev_toks == 2 and prev_toks[1] == "files"
      and (prev_toks[2] == "show" or prev_toks[2] == "hide") then
    candidates = { "hidden", "dotfiles" }
  elseif #prev_toks == 2 and prev_toks[1] == "files" and prev_toks[2] == "follow" then
    candidates = { "on", "off", "toggle" }
  elseif #prev_toks == 1 and prev_toks[1] == "repos" then
    candidates = { "follow" }
  elseif #prev_toks == 2 and prev_toks[1] == "repos" and prev_toks[2] == "follow" then
    candidates = { "on", "off", "toggle" }
  elseif #prev_toks == 1 and prev_toks[1] == "slot" then
    candidates = { "add", "remove", "modify", "assign", "types" }
  elseif #prev_toks >= 2 and prev_toks[1] == "slot"
      and prev_toks[2] == "assign" then
    -- `slot assign <t1> <t2> …` takes a type at every position, so
    -- offer everything not already named on this line and not the
    -- protected slot-0 section.
    candidates = {}
    local af = require("auto-finder")
    local sections = af.state.config.sections or {}
    local used = { [sections[1] or ""] = true }
    for i = 3, #prev_toks do used[prev_toks[i]] = true end
    for _, t in ipairs(af._available_section_types()) do
      if not used[t] then candidates[#candidates + 1] = t end
    end
  elseif #prev_toks == 2 and prev_toks[1] == "slot"
      and (prev_toks[2] == "add" or prev_toks[2] == "modify") then
    -- For add: only types NOT already in cfg.sections (no dupes).
    -- For modify: all available types (the caller may want to
    -- swap N's type to one that's currently elsewhere — but our
    -- own slot_modify will reject genuine collisions at runtime).
    candidates = {}
    local af = require("auto-finder")
    local available = af._available_section_types()
    if prev_toks[2] == "add" then
      local in_use = {}
      for _, n in ipairs(af.state.config.sections or {}) do
        in_use[n] = true
      end
      for _, t in ipairs(available) do
        if not in_use[t] then candidates[#candidates + 1] = t end
      end
    else
      candidates = available
    end
  elseif #prev_toks == 2 and prev_toks[1] == "slot"
      and prev_toks[2] == "remove" then
    -- Numeric slot indices >= 1 (slot 0 is protected).
    candidates = {}
    local af = require("auto-finder")
    for i = 1, math.max(0, #(af.state.config.sections or {}) - 1) do
      candidates[#candidates + 1] = tostring(i)
    end
  elseif #prev_toks == 3 and prev_toks[1] == "slot" and prev_toks[2] == "modify" then
    -- After "slot modify N", complete available types (exclude
    -- the type currently at slot N to avoid suggesting a no-op).
    candidates = {}
    local af = require("auto-finder")
    local n = tonumber(prev_toks[3])
    local current = n and (af.state.config.sections or {})[n + 1]
    for _, t in ipairs(af._available_section_types()) do
      if t ~= current then candidates[#candidates + 1] = t end
    end
  elseif #prev_toks == 1 and prev_toks[1] == "help" then
    -- `help <topic>` opens the topic's help directly. Topics map to
    -- the verb groups so users discover what's available.
    candidates = { "focus", "panel", "files", "repos", "slot", "general" }
  else
    candidates = {}
  end

  if current ~= "" then
    local filtered = {}
    for _, c in ipairs(candidates) do
      if vim.startswith(c, current) then table.insert(filtered, c) end
    end
    candidates = filtered
  end

  return token_start, candidates
end

---Trigger completion for the current admin buffer prompt line.
---(Filled into the forward-declared local — `function name()` here
---would shadow it instead of assigning.)
trigger_complete = function()
  local line = vim.api.nvim_get_current_line()
  if not vim.startswith(line, PROMPT) then return end
  local col = vim.fn.col(".") - 1  -- 0-indexed byte col in line
  if col < #PROMPT then return end
  local prompt = line:sub(#PROMPT + 1)
  local token_start, candidates = complete_at(prompt, col - #PROMPT)
  if #candidates == 0 then return end
  vim.fn.complete(#PROMPT + token_start + 1, candidates)
end

-- Exposed for tests; not part of the public surface.
M._complete_at = complete_at

-- ── panel show ─────────────────────────────────────────────────────────

---Render the panel-show output: mode (pinned vs dynamic),
---configured range, live width. Mirrors auto-agents' `panel show`
---layout so users learn one mental model across plugins.
panel_show_lines = function()
  local af = require("auto-finder")
  local cfg = af.state.config or {}
  local w = cfg.width or {}
  local pinned = af.state.user_width
  local mode = pinned and string.format("pinned at %d", pinned) or "dynamic"
  local default_w = w.default or "?"
  local min_w = w.min or "?"
  local max_w = w.max or "?"
  local live = "?"
  if af.state.panel_winid and vim.api.nvim_win_is_valid(af.state.panel_winid) then
    live = tostring(vim.api.nvim_win_get_width(af.state.panel_winid))
  end
  return {
    "",
    "  panel show",
    "    mode:    " .. mode,
    "    default: " .. tostring(default_w) .. " cols",
    "    range:   " .. tostring(min_w) .. ".." .. tostring(max_w),
    "    live:    " .. live,
    "",
  }
end

-- Exposed for tests; not part of the public surface.
M._panel_show_lines = panel_show_lines

-- ── topical help ───────────────────────────────────────────────────────

local TOPIC_HELP = {
  focus = {
    "",
    "  focus <N|name>             switch the active section",
    "    examples:  focus 1   focus files   focus 0   focus config",
    "    sections are enumerated in the winbar; click also works.",
    "",
  },
  panel = {
    "",
    "  panel resize <N>           pin panel width to N cols (HARD CAP)",
    "                               N must satisfy width.min <= N <= width.max",
    "  panel reset                clear the pin; let neo-tree auto-expand again",
    "  panel dynamic              alias for `panel reset`",
    "  panel show                 display mode / default / range / live",
    "",
    "  Modes:",
    "    pinned   panel is locked to the pin; neo-tree's auto_expand_width",
    "             is forced off on the live state so it can't fight the pin.",
    "    dynamic  panel starts at width.default; neo-tree's auto_expand_width",
    "             is free to grow it on demand. (default mode at startup)",
    "",
  },
  files = {
    "",
    "  files show hidden            show .gitignored files in the tree",
    "  files show dotfiles          show files starting with `.`",
    "  files hide hidden            hide .gitignored files",
    "  files hide dotfiles          hide files starting with `.`",
    "  files follow on|off|toggle   reveal the active buffer in the files tree",
    "",
    "  defaults: hidden + dotfiles are SHOWN; files-follow is ON.",
    "  follow maps to neo-tree's `filesystem.follow_current_file` and",
    "  fires on every BufEnter. Toggling here updates the live runtime",
    "  config (no setup() re-run needed) and persists across restarts",
    "  (v0.2.70; stored in the auto-finder state namespace).",
    "",
  },
  repos = {
    "",
    "  repos follow on|off|toggle   reveal the active buffer's repo",
    "                                 in the repos panel on every BufEnter",
    "",
    "  default: OFF — the active-repo signal is noisier than the active-",
    "  file signal. Requires auto-core (workspace_root is resolved via",
    "  `auto-core.git.worktree.get_workspace_root()`). Walks up from the",
    "  buffer's path until it hits a direct child of workspace_root,",
    "  then calls neo-tree's `reveal_file` on the auto-finder-repos",
    "  source. No-op if the repos section's buffer isn't currently live.",
    "  Toggles persist across restarts (v0.2.70), same as files-follow.",
    "",
  },
  slot = function()
    local types = require("auto-finder")._available_section_types()
    return {
      "",
      "  slot add <type>              append a section of <type> at the end",
      "  slot remove <N>              remove section at slot N (N >= 1)",
      "  slot modify <N> <type>       replace the section at slot N",
      "  slot assign                  interactive walk over slots 1..9",
      "  slot assign <t1> <t2> …      set the whole arrangement in one line",
      "  slot types                   list all available section types",
      "",
      "  <type> must be one of `slot types`'s output. Available right now:",
      "    " .. table.concat(types, ", ") .. ".",
      "  Third-party sections registered via `cfg.section_modules` also",
      "  show up; the list is recomputed on every `slot types` call.",
      "",
      "  Slot 0 (config) is protected — `remove` / `modify` / `assign`",
      "  all reject it.",
      "  Duplicates are rejected: a section type can only live in one slot",
      "  at a time.",
      "",
      "  `assign` is the one that can RE-ARRANGE. `modify` edits a single",
      "  slot and refuses a type that already lives elsewhere, so it can",
      "  never swap two slots; `assign` replaces the whole list at once,",
      "  so any permutation of the live sections is legal.",
      "  The walk asks slot by slot, showing the current occupant. An",
      "  empty <CR> ends the list — every slot you did not reach is",
      "  dropped, and that case asks for confirmation before applying.",
      "  <C-c> cancels the walk with nothing changed.",
      "",
      "  Slot mutations PERSIST per workspace (keyed by workspace root)",
      "  via the auto-finder state namespace, so an arrangement survives",
      "  an nvim restart. (Superseded the session-only behaviour this",
      "  help used to describe.)",
      "",
    }
  end,
  general = {
    "",
    "  reload                     re-render the active section",
    "  status                     show current section, width, pin state",
    "  clear                      wipe history above the prompt",
    "  quit                       close the panel (section buffers survive)",
    "",
    "  bare numeric input (e.g. just `1`) is shorthand for `focus 1`.",
    "  <Tab> completes; <S-Tab> walks the popup; <CR> submits.",
    "",
  },
}

-- Forward-declared above. Definition (not `local function`, since the
-- forward decl is `local help_topic_lines` and we're filling it in).
help_topic_lines = function(topic)
  local body = TOPIC_HELP[topic]
  if type(body) == "function" then body = body() end
  if type(body) ~= "table" then
    return { "", "  no help for '" .. tostring(topic) .. "' (try focus|panel|files|repos|slot|general)", "" }
  end
  local out = { "", "  help: " .. topic }
  for _, l in ipairs(body) do table.insert(out, l) end
  return out
end

---@param input string
function M._help_topic(input)
  return help_topic_lines(input)
end

return M
