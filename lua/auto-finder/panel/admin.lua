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
    "  slot types                   list available section types",
    "  dbase new <name>             create empty connections file (`.json` auto-appended)",
    "  dbase ls                     list available connections files",
    "  dbase rm <name>              delete a connections file",
    "  dbase load [name]            load file as active (prompts if name omitted)",
    "  dbase conn add               prompt for name/type/url, append to active file",
    "  dbase conn ls                list connections in the active file",
    "  dbase conn rm <name>         remove a connection by name",
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
  return nil
end

local function status_lines()
  local af = require("auto-finder")
  local sections = require("auto-finder.sections").enabled()
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
    elseif sub == "types" then
      local types = af._available_section_types()
      emit({ "available section types: " .. table.concat(types, ", ") })
    else
      emit({ "slot: subcommand must be 'add', 'remove', 'modify', or 'types' (got '"
        .. tostring(sub) .. "')" })
    end

  elseif verb == "dbase" then
    local files = require("auto-finder.sections._dbase_files")
    local sub = toks[2]

    if sub == "new" then
      local name = toks[3]
      if not name or name == "" then
        emit({ "dbase new: name required (e.g. 'dbase new work')" })
      else
        local basename, err = files.new(name)
        if err then
          emit({ "dbase new: " .. err })
        else
          emit({ "dbase: created " .. basename
            .. "   (use `dbase load " .. basename:gsub("%.json$", "") .. "` to activate)" })
        end
      end

    elseif sub == "ls" then
      local names = files.list()
      local current = files.current()
      if #names == 0 then
        emit({ "dbase: no connection files yet (try `dbase new <name>`)" })
      else
        local lines = { "dbase files:" }
        for _, n in ipairs(names) do
          local marker = (n == current) and "  * " or "    "
          lines[#lines + 1] = marker .. n
        end
        if current then
          lines[#lines + 1] = "  (* = active)"
        else
          lines[#lines + 1] = "  (none active — use `dbase load <name>`)"
        end
        emit(lines)
      end

    elseif sub == "rm" then
      local name = toks[3]
      if not name or name == "" then
        emit({ "dbase rm: name required (e.g. 'dbase rm work')" })
      else
        local ok, err = files.remove(name)
        if not ok then
          emit({ "dbase rm: " .. err })
        else
          emit({ "dbase: removed " .. name })
        end
      end

    elseif sub == "load" then
      local name = toks[3]
      if not name or name == "" then
        local names = files.list()
        if #names == 0 then
          emit({ "dbase load: no files to load (try `dbase new <name>` first)" })
        else
          -- In-panel wizard pick. Listing the available names as the
          -- banner keeps the conversation in the REPL — no separate
          -- cmdline prompt at the bottom of the editor.
          local banner = { "dbase load: pick a file" }
          for _, n in ipairs(names) do banner[#banner + 1] = "    " .. n end
          local valid = {}
          for _, n in ipairs(names) do valid[n] = true end
          require("auto-finder.panel.wizard").start({
            name = "dbase.load",
            banner = banner,
            steps = {
              {
                field = "name",
                prompt = "file name",
                choices = names,
                validate = function(v)
                  if not v or v == "" then return false, "name is required" end
                  if not valid[v] and not valid[v:gsub("%.json$", "")] then
                    return false, "no such file: " .. v
                  end
                  return true
                end,
              },
            },
            on_complete = function(values)
              local basename, err = files.load(values.name)
              if err then
                emit({ "dbase load: " .. err })
              else
                emit({ "dbase: loaded " .. basename })
              end
            end,
          }, emit)
        end
      else
        local basename, err = files.load(name)
        if err then
          emit({ "dbase load: " .. err })
        else
          emit({ "dbase: loaded " .. basename })
        end
      end

    elseif sub == "conn" then
      local action = toks[3]

      if action == "add" then
        -- Multi-step prompt runs inside the admin REPL via the wizard
        -- (mirrors auto-agents' agent.add). Cancelling with <C-c>
        -- preserves the partial state on screen as history.
        local DBASE_TYPES = require("auto-finder.sections._dbase_files").TYPES
        local type_set = {}
        for _, t in ipairs(DBASE_TYPES) do type_set[t] = true end
        require("auto-finder.panel.wizard").start({
          name = "dbase.conn.add",
          banner = "dbase conn add — Enter blank to cancel any step.",
          steps = {
            {
              field = "name",
              prompt = "connection name",
              validate = function(v)
                if not v or v == "" then return false, "name is required" end
                return true
              end,
            },
            {
              field = "type",
              prompt = "type",
              choices = DBASE_TYPES,
              default = "postgres",
              validate = function(v)
                if not type_set[v] then
                  return false, "type must be one of " .. table.concat(DBASE_TYPES, "|")
                end
                return true
              end,
            },
            {
              field = "url",
              prompt = "url",
              validate = function(v)
                if not v or v == "" then return false, "url is required" end
                return true
              end,
            },
          },
          on_complete = function(values)
            local ok, err = files.conn_add({
              name = values.name, type = values.type, url = values.url,
            })
            if not ok then
              emit({ "dbase conn add: " .. err })
            else
              emit({ "dbase: added connection '" .. values.name
                .. "' (" .. values.type .. ")" })
            end
          end,
        }, emit)

      elseif action == "ls" then
        local conns, read_err = files.connections()
        if read_err then
          emit({ "dbase conn ls: " .. read_err })
        elseif #conns == 0 then
          local current = files.current()
          if current then
            emit({ "dbase: no connections in '" .. current .. "' yet (try `dbase conn add`)" })
          else
            emit({ "dbase: no file loaded — use `dbase load <name>` first" })
          end
        else
          local current = files.current() or "(unsaved)"
          emit({ "dbase connections in '" .. current .. "':" })
          for _, c in ipairs(conns) do
            emit({ "    " .. tostring(c.name or "?")
              .. "    [" .. tostring(c.type or "?") .. "]" })
          end
        end

      elseif action == "rm" then
        local cname = toks[4]
        if not cname or cname == "" then
          emit({ "dbase conn rm: connection name required" })
        else
          local ok, err = files.conn_remove(cname)
          if not ok then
            emit({ "dbase conn rm: " .. err })
          else
            emit({ "dbase: removed connection '" .. cname .. "'" })
          end
        end

      else
        emit({ "dbase conn: action must be 'add', 'ls', or 'rm' (got '"
          .. tostring(action) .. "')" })
      end

    else
      emit({ "dbase: subcommand must be 'new', 'ls', 'rm', 'load', or 'conn' (got '"
        .. tostring(sub) .. "')" })
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
                   "dbase", "reload", "status", "clear", "quit" }
  elseif #prev_toks == 1 and prev_toks[1] == "focus" then
    -- Numeric indices and section names from the live registry.
    candidates = {}
    local sections = require("auto-finder.sections").enabled()
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
    candidates = { "add", "remove", "modify", "types" }
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
    candidates = { "focus", "panel", "files", "repos", "slot", "dbase", "general" }
  elseif #prev_toks == 1 and prev_toks[1] == "dbase" then
    candidates = { "new", "ls", "rm", "load", "conn" }
  elseif #prev_toks == 2 and prev_toks[1] == "dbase" and prev_toks[2] == "conn" then
    candidates = { "add", "ls", "rm" }
  elseif #prev_toks == 2 and prev_toks[1] == "dbase"
      and (prev_toks[2] == "rm" or prev_toks[2] == "load") then
    -- Existing user files (no `.json` suffix in completion — matches
    -- the dispatch's normalize_name, which appends it if missing).
    local ok_files, files = pcall(require, "auto-finder.sections._dbase_files")
    candidates = ok_files and files.list() or {}
  elseif #prev_toks == 3 and prev_toks[1] == "dbase"
      and prev_toks[2] == "conn" and prev_toks[3] == "rm" then
    -- Existing connection names in the currently-active file.
    local ok_files, files = pcall(require, "auto-finder.sections._dbase_files")
    candidates = {}
    if ok_files then
      local conns = files.connections() or {}
      for _, c in ipairs(conns) do
        if type(c.name) == "string" then candidates[#candidates + 1] = c.name end
      end
    end
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
    "  config (no setup() re-run needed) and persists for the session.",
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
    "",
  },
  slot = function()
    local types = require("auto-finder")._available_section_types()
    return {
      "",
      "  slot add <type>              append a section of <type> at the end",
      "  slot remove <N>              remove section at slot N (N >= 1)",
      "  slot modify <N> <type>       replace the section at slot N",
      "  slot types                   list all available section types",
      "",
      "  <type> must be one of `slot types`'s output. Available right now:",
      "    " .. table.concat(types, ", ") .. ".",
      "  Third-party sections registered via `cfg.section_modules` also",
      "  show up; the list is recomputed on every `slot types` call.",
      "",
      "  Slot 0 (config) is protected — `remove` / `modify` reject it.",
      "  Duplicates are rejected: a section type can only live in one slot",
      "  at a time. Mutations are SESSION-ONLY in v0.2.5 (do not survive",
      "  nvim restart); persisting via the auto-finder state namespace is",
      "  a follow-up.",
      "",
    }
  end,
  dbase = {
    "",
    "  dbase                        database UI (drawer + editor + result panes)",
    "",
    "  Add the panel section with `slot add dbase` (it's NOT in the",
    "  default slot set — only added when you want it).",
    "",
    "  File management — `~/.local/state/nvim/auto-finder/dbase/`:",
    "    dbase new <name>           create empty connections file",
    "                                 `.json` is appended automatically",
    "    dbase ls                   list available files (`*` marks active)",
    "    dbase rm <name>            delete a file",
    "    dbase load [name]          activate file (prompts if name omitted)",
    "",
    "  Connection management — operates on the ACTIVE file:",
    "    dbase conn add             prompt for name / type / url",
    "    dbase conn ls              list connections in the active file",
    "    dbase conn rm <name>       remove a connection by name",
    "",
    "  The active file's contents are mirrored into `_active.json`, which",
    "  is what dbee's FileSource reads. Swapping files via `dbase load`",
    "  rewrites `_active.json` and calls `source_reload` — the drawer",
    "  reflects the change without re-running `dbee.setup`. The named",
    "  file (e.g. `work.json`) remains the durable record.",
    "",
    "  Mounting & companion panes:",
    "  Focusing the dbase slot shows the connection drawer in the panel.",
    "  <CR> on a connection opens dbee's editor + result + call_log panes",
    "  in the main editor area (NOT in any auto-core panel). Closing the",
    "  panel, reloading auto-finder, or removing the dbase slot tears",
    "  those companions down; plain focus changes leave them mounted.",
    "",
    "  Programmatic config (advanced) — `cfg.dbase` at setup:",
    "    sources  list of dbee Source instances. When set, REPLACES the",
    "             pinned FileSource default; the file commands above no",
    "             longer drive the drawer. Use this only if you're",
    "             bypassing auto-finder's file management.",
    "    extra    passthrough table merged into `dbee.setup`'s config.",
    "",
    "  Emitted events (subscribe with `:AutoCoreLogEvent notify <topic>`):",
    "    auto-finder.dbase.connection.changed",
    "    auto-finder.dbase.call.started",
    "    auto-finder.dbase.call.completed",
    "  Failures (setup, call) go through `log.error` and always toast.",
    "",
  },
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
    return { "", "  no help for '" .. tostring(topic) .. "' (try focus|panel|files|repos|slot|dbase|general)", "" }
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
