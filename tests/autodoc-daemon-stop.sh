#!/usr/bin/env bash
# tests/autodoc-daemon-stop.sh — a suite that starts an AutoDoc daemon (tests/_autodoc.lua)
# stops it however the suite ends, also run on its own (`nvim -l tests/<suite>.lua`, as a
# reviewer or a gate runs one suite), where run-all.sh's stop by the sandbox never runs.
# A daemon outlives its nvim (autodoc starts it detached), so before this every suite run
# alone left its daemon running.
#
#   AF_TEST_AUTODOC=/path/to/autodoc  AF_TEST_AUTODOC_BIN=/path/to/binary
#   tests/autodoc-daemon-stop.sh
#
# Each way out is a tiny suite that sets the daemon up, makes one call so it has started, then
# ends: normally, by os.exit(1) (which skips the autocmds), or by an error. The daemons are told
# by their config's path (/ad-stopcell-…): nothing else is looked at or stopped, and any found
# left is stopped here, so a failure leaves nothing behind either.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1  ${2:-}"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/af-daemon-stop.XXXXXX")" || exit 1
trap 'rm -rf "$work"' EXIT

cell_daemons() {
  local p
  for p in $(pgrep -f -- '--serve --config' 2>/dev/null); do
    case "$(ps -o command= -p "$p" 2>/dev/null)" in
      *" --serve --config "*"/ad-stopcell-"*) echo "$p" ;;
    esac
  done | sort
}

for how in normal exit error; do
  cat > "$work/$how.lua" <<EOF
local root = "$PWD"
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h:h") .. "/auto-core.nvim/main")
local ok, why = dofile(root .. "/tests/_autodoc.lua")("$work", "stopcell")
if not ok then io.stdout:write("SETUP FAILED: " .. tostring(why) .. "\n"); os.exit(3) end
local done, answered = false, false
require("autodoc.todos").call("list_dirs", {}, function() answered = true; done = true end)
vim.wait(15000, function() return done end, 20)
io.stdout:write(answered and "DAEMON ANSWERED\n" or "NO ANSWER\n")
local how = "$how"
if how == "exit" then os.exit(1) elseif how == "error" then error("the suite fails here") end
EOF
  before="$(cell_daemons)"
  out="$(timeout 120 nvim --headless -u NONE -l "$work/$how.lua" 2>&1)"
  started="$(printf '%s' "$out" | grep -c 'DAEMON ANSWERED')"
  sleep 1
  left="$(comm -13 <(echo "$before") <(cell_daemons) | tr '\n' ' ')"
  left="${left% }"
  if [ "$started" != "1" ]; then
    bad "a suite ending $how: its daemon started" "$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
  elif [ -z "$left" ]; then
    ok "*** a suite ending $how stops the daemon it started ***"
  else
    bad "*** a suite ending $how stops the daemon it started ***" "still running: $left"
  fi
  [ -n "$left" ] && kill -KILL $left 2>/dev/null
done

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
