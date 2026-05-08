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
    "  reload                       re-render the active section",
    "  status                       show current section, width, pin state",
    "  clear                        wipe history above the prompt",
    "  quit                         close the panel",
    "",
    "  defaults: hidden + dotfiles are SHOWN. Use `files hide …` to filter.",
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
  local ok, neo = pcall(require, "neo-tree")
  if not ok then return "neo-tree is not installed" end
  if type(neo.config) ~= "table" then return "neo-tree config is not loaded yet" end
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
  -- Persist so the filter survives nvim restart.
  local store = require("auto-finder.store")
  if what == "hidden" then
    store.update({ files = { hide_gitignored = not show } })
  else
    store.update({ files = { hide_dotfiles = not show } })
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
    local action = toks[2]   -- show | hide
    local what = toks[3]     -- hidden | dotfiles
    if action ~= "show" and action ~= "hide" then
      emit({ "files: action must be 'show' or 'hide' (e.g. 'files show hidden')" })
    elseif what ~= "hidden" and what ~= "dotfiles" then
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
    vim.schedule(function() dispatch(input) end)
  end)

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
    candidates = { "help", "?", ":h", "focus", "panel", "files",
                   "reload", "status", "clear", "quit" }
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
    candidates = { "show", "hide" }
  elseif #prev_toks == 2 and prev_toks[1] == "files"
      and (prev_toks[2] == "show" or prev_toks[2] == "hide") then
    candidates = { "hidden", "dotfiles" }
  elseif #prev_toks == 1 and prev_toks[1] == "help" then
    -- `help <topic>` opens the topic's help directly. Topics map to
    -- the verb groups so users discover what's available.
    candidates = { "focus", "panel", "files", "general" }
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
    "  files show hidden          show .gitignored files in the tree",
    "  files show dotfiles        show files starting with `.`",
    "  files hide hidden          hide .gitignored files",
    "  files hide dotfiles        hide files starting with `.`",
    "",
    "  defaults: hidden + dotfiles are SHOWN. Use `files hide ...` to filter.",
    "  the change is applied immediately and persists for the session.",
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
  if not body then
    return { "", "  no help for '" .. tostring(topic) .. "' (try focus|panel|files|general)", "" }
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
