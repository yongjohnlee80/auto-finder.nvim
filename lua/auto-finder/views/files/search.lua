---auto-finder.views.files.search — `/` search for the files slot (ADR-0200 §4.7).
---
---The retired fork's `fuzzy_finder`: a basename glob `*term*` under the root, found by an external
---command (fd / fdfind, else find), at most `LIMIT` results, files and directories, hidden and gitignored
---entries included while the panel shows them. `never_show` names (.git, node_modules) are excluded at
---the source, so a search never walks git objects. Each keystroke cancels the job before it.
---
---The input is a one-line float over the panel, searched as you type (debounced). <CR>/<S-CR> close it and
---keep the results; <Esc>/<C-CR> close it and clear them; <C-n>/<C-p>/<Down>/<Up> move the tree cursor.
---@module 'auto-finder.views.files.search'

local M = {}

M.LIMIT = 50
M.DEBOUNCE_MS = 150

local _cmd
local function command()
  if _cmd == nil then
    if vim.fn.executable("fdfind") == 1 then _cmd = "fdfind"
    elseif vim.fn.executable("fd") == 1 then _cmd = "fd"
    elseif vim.fn.executable("find") == 1 then _cmd = "find"
    else _cmd = false end
  end
  return _cmd or nil
end
function M._reset_command_cache() _cmd = nil end

---argv for one search.
---@param root string
---@param term string
---@param opts { never_show: string[], hidden: boolean }
function M.argv(root, term, opts)
  local cmd = command()
  if not cmd then return nil end
  local glob = "*" .. term .. "*"
  if cmd == "find" then
    local a = { "find", root }
    for _, n in ipairs(opts.never_show) do vim.list_extend(a, { "-name", n, "-prune", "-o" }) end
    if not opts.hidden then vim.list_extend(a, { "-name", ".*", "-prune", "-o" }) end
    vim.list_extend(a, { "-iname", glob, "-print" })
    return a, false
  end
  local a = { cmd, "--color", "never", "--max-results", tostring(M.LIMIT) }
  if opts.hidden then vim.list_extend(a, { "--hidden", "--no-ignore" }) end
  for _, n in ipairs(opts.never_show) do vim.list_extend(a, { "--exclude", n }) end
  vim.list_extend(a, { "--glob", "--", glob, root })
  return a, true
end

local _job

---Run a search; `cb(paths)` on the main loop with at most LIMIT absolute paths. Cancels any running one.
function M.run(root, term, opts, cb)
  M.cancel()
  local argv, limited = M.argv(root, term, opts)
  if not argv then return cb({}) end
  local job
  job = vim.system(argv, { text = true }, function(res)
    vim.schedule(function()
      if _job ~= job then return end -- superseded
      _job = nil
      local out = {}
      for line in (res.stdout or ""):gmatch("[^\n]+") do
        local p = line:gsub("/$", "")
        if p ~= root then out[#out + 1] = p end
        if not limited and #out >= M.LIMIT then break end
      end
      cb(out)
    end)
  end)
  _job = job
end

function M.cancel()
  if _job then pcall(function() _job:kill(15) end) end
  _job = nil
end

---Open the prompt float over `panel_winid`. `on_term(term)` fires (debounced) as the text changes;
---`on_close(keep)` when it closes. `move(delta)` moves the tree cursor from inside the prompt.
function M.prompt(panel_winid, handlers)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "prompt"
  vim.fn.prompt_setprompt(buf, "/")
  local width = math.max(10, vim.api.nvim_win_get_width(panel_winid) - 2)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "win", win = panel_winid, row = 0, col = 0, width = width, height = 1,
    style = "minimal", border = "rounded", title = " Filter ", noautocmd = true,
  })
  local timer = vim.uv.new_timer()
  local closed = false
  local function text()
    local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
    return (line:gsub("^/", ""))
  end
  local function close(keep)
    if closed then return end
    closed = true
    pcall(timer.stop, timer); pcall(timer.close, timer)
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.cmd("stopinsert")
    if vim.api.nvim_win_is_valid(panel_winid) then pcall(vim.api.nvim_set_current_win, panel_winid) end
    handlers.on_close(keep)
  end
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = buf,
    callback = function()
      timer:stop()
      timer:start(M.DEBOUNCE_MS, 0, vim.schedule_wrap(function()
        if not closed then handlers.on_term(text()) end
      end))
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = function() close(true) end })
  local function map(lhs, fn) vim.keymap.set({ "i", "n" }, lhs, fn, { buffer = buf, nowait = true }) end
  map("<CR>", function() close(true) end)
  map("<S-CR>", function() close(true) end)
  map("<Esc>", function() close(false) end)
  map("<C-CR>", function() close(false) end)
  for lhs, d in pairs({ ["<C-n>"] = 1, ["<Down>"] = 1, ["<C-p>"] = -1, ["<Up>"] = -1 }) do
    map(lhs, function() handlers.move(d) end)
  end
  vim.cmd("startinsert!")
  return { close = close }
end

return M
