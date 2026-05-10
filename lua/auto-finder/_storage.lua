---Shared JSON-on-disk helpers used by `auto-finder.store` and
---`auto-finder.repos`. Both modules persist into a single per-config
---directory (`<stdpath('config')>/.auto-finder/`) but in distinct
---files; the read/write/encode/decode plumbing is common to both.
---
---Failures are best-effort: a missing or malformed file returns `{}`,
---a write failure logs via vim.notify(WARN) but never throws so a
---disk hiccup doesn't abort the user's edit flow.
---@module 'auto-finder._storage'

local M = {}

---Resolve the root directory for auto-finder's persistent state.
---Lives next to `.auto-agents-config/` so both agent-style plugins
---namespace under `<stdpath('config')>/`.
---@return string
function M.dir_path()
  return vim.fn.stdpath("config") .. "/.auto-finder"
end

---Ensure the storage directory exists. Creates it (mode 0700) if not.
---@return string|nil err
function M.ensure_dir()
  local d = M.dir_path()
  if vim.fn.isdirectory(d) == 1 then return nil end
  local ok = vim.fn.mkdir(d, "p", "0700")
  if ok ~= 1 then return "mkdir failed: " .. d end
  return nil
end

---Read a JSON file under the storage dir. Returns `{}` for missing,
---empty, or malformed files (logs WARN on the malformed case so
---silent corruption is visible).
---@param filename string  -- bare filename, e.g. "config.json"
---@return table
function M.read_json(filename)
  local path = M.dir_path() .. "/" .. filename
  if vim.fn.filereadable(path) ~= 1 then return {} end
  local lines = vim.fn.readfile(path)
  if not lines or #lines == 0 then return {} end
  local raw = table.concat(lines, "\n")
  if raw == "" then return {} end
  local ok, decoded = pcall(vim.fn.json_decode, raw)
  if not ok or type(decoded) ~= "table" then
    require("auto-finder.logger").warn("_storage",
      "failed to decode " .. path .. " — defaults will apply: " .. tostring(decoded))
    return {}
  end
  return decoded
end

---Write `data` to `<storage-dir>/<filename>` as light pretty-printed
---JSON. Best-effort: failures notify (WARN) and swallow so the
---calling op isn't aborted by I/O.
---@param filename string
---@param data table
function M.write_json(filename, data)
  local err = M.ensure_dir()
  if err then
    require("auto-finder.logger").warn("_storage", err)
    return
  end
  local ok, encoded = pcall(vim.fn.json_encode, data)
  if not ok then
    require("auto-finder.logger").warn("_storage",
      "json_encode failed: " .. tostring(encoded))
    return
  end
  -- Lightweight pretty-print so the file is readable when opened.
  -- Schema-agnostic: insert newlines around object/array boundaries
  -- and after commas. Cheap (single-pass gsub) and good enough for
  -- the small flat schemas this plugin persists.
  encoded = encoded
    :gsub('","', '",\n    "')
    :gsub('":%[', '": [\n    ')
    :gsub('":{', '": {\n    ')
    :gsub('}}', '\n  }\n}')
    :gsub('%]}', '\n  ]\n}')
    :gsub('{"', '{\n  "')
  local path = M.dir_path() .. "/" .. filename
  pcall(vim.fn.writefile, vim.split(encoded, "\n"), path)
end

return M
