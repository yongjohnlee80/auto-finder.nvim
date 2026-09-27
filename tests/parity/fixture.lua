---tests/parity/fixture.lua — the parity fixture repo (ADR-0200 §5 cell 1).
---
---Byte-for-byte the tree tests/parity/capture.lua built when the goldens were frozen (commit bac3db7):
---a fixed absolute path, so every line width matches; nested dirs, dotfiles, a symlink, gitignored
---entries, and a worktree modification, a staged add, an untracked file, a staged rename and a worktree
---delete. Returns the root.
---@param die fun(msg: string)
---@return string root
return function(die)
  local ROOT = "/tmp/af-parity-fixture"
  vim.fn.delete(ROOT, "rf")

  local function write(rel, text)
    local p = ROOT .. "/" .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
    vim.fn.writefile(vim.split(text or rel, "\n"), p)
  end

  local function git(...)
    local r = vim.system({ "git", "-C", ROOT, ... }, { text = true }):wait()
    if r.code ~= 0 then die("git " .. table.concat({ ... }, " ") .. ": " .. (r.stderr or "")) end
  end

  for _, rel in ipairs({
    "src/main.lua", "src/util/helper.lua", "src/util/strings.lua", "docs/readme.md", "docs/guide.md",
    "a/b/c/deep.txt", ".github/workflows/ci.yml", ".env", "old.md", "Makefile", "zeta.txt",
    "debug.log", "build/out.bin", "tracked_then_deleted.txt",
  }) do write(rel) end
  write(".gitignore", "build/\n*.log")
  vim.fn.mkdir(ROOT .. "/empty_dir", "p")
  vim.uv.fs_symlink(ROOT .. "/src/main.lua", ROOT .. "/link.lua")

  git("init", "-q", "-b", "main")
  git("config", "user.email", "parity@example.invalid")
  git("config", "user.name", "parity")
  git("add", "-A")
  git("commit", "-q", "-m", "fixture")
  write("src/main.lua", "changed")
  write("staged.txt"); git("add", "staged.txt")
  write("new.txt")
  git("mv", "old.md", "renamed.md")
  vim.fn.delete(ROOT .. "/tracked_then_deleted.txt")
  return ROOT
end
