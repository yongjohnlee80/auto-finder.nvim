#!/usr/bin/env bash
# tests/sandbox-contract.sh — subprocess contract for tests/_sandbox.lua.
#
# WHY THIS EXISTS
#
# Every suite in run-all.sh takes the EXPORTED-ROOT branch of the helper,
# because the runner always exports AF_TEST_SANDBOX_ROOT. So when a bad
# edit once nested the standalone block inside the shared branch — making
# `root` nil whenever that variable was unset — the standalone path was
# completely broken and the aggregate gate stayed green through an entire
# review round. Nothing checked in would have failed.
#
# That is the same shape as the bug this whole change set fixes: a gate
# that is green for environmental reasons rather than because the code
# works. So the standalone branch gets a mechanical contract of its own.
#
# Two properties can only be observed from OUTSIDE the Neovim process,
# which is why this is a shell script rather than another Lua suite:
#
#   1. the sandbox root is swept when Neovim exits (post-exit check);
#   2. a refused location has nothing created in it (post-exit check).
#
# Run directly, or via run-all.sh which owns it as a gate.
set -u
cd "$(dirname "$0")/.."

pass=0
fail=0
ok()   { pass=$((pass + 1)); echo "  PASS  $1"; }
bad()  { fail=$((fail + 1)); echo "  FAIL  $1  ${2:-}"; }

HELPER="$PWD/tests/_sandbox.lua"

# Allocation must be fatal BEFORE the trap is installed or any child path
# is derived. Under `set -u` without `errexit` a failed command
# substitution leaves WORK empty and execution continues, at which point
# "$WORK/standalone.txt" is `/standalone.txt` -- a root-level write. This
# is the same unchecked-mktemp mechanism already fixed in run-all.sh;
# this script advertises direct execution, so it cannot rely on the
# runner's guard.
if ! WORK="$(mktemp -d "${TMPDIR:-/tmp}/auto-finder-contract-XXXXXX")" \
   || [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
  echo "sandbox-contract: FAILED — could not allocate a work dir under ${TMPDIR:-/tmp}" >&2
  exit 1
fi

cleanup() {
  case "$WORK" in
    "${TMPDIR:-/tmp}"/auto-finder-contract-*) rm -rf "$WORK" ;;
  esac
}
trap cleanup EXIT

# ── 1. standalone branch: AF_TEST_SANDBOX_ROOT deliberately unset ──────
# `env -u` matters: run-all exports the variable, so inheriting it here
# would silently exercise the shared branch and prove nothing.
probe="$WORK/standalone.txt"
env -u AF_TEST_SANDBOX_ROOT nvim --headless -u NONE -i NONE --cmd "
lua
local root = dofile('$HELPER')('contract')
local f = io.open('$probe', 'w')
f:write(root, '\n')
f:write(vim.fn.stdpath('config'), '\n')
f:write(vim.fn.stdpath('state'), '\n')
f:write(vim.fn.stdpath('cache'), '\n')
f:write(tostring(vim.fn.isdirectory(root)), '\n')
f:close()
" -c qa >/dev/null 2>&1

if [ ! -s "$probe" ]; then
  bad "standalone: helper returned a usable root" "no probe output — the branch errored"
else
  root="$(sed -n 1p "$probe")"
  cfg="$(sed -n 2p "$probe")"
  st="$(sed -n 3p "$probe")"
  ca="$(sed -n 4p "$probe")"
  livedir="$(sed -n 5p "$probe")"

  [ -n "$root" ] \
    && ok "standalone: helper returned a root" \
    || bad "standalone: helper returned a root" "empty"
  [ "$livedir" = "1" ] \
    && ok "standalone: the root existed during the run" \
    || bad "standalone: the root existed during the run" "isdirectory=$livedir"

  for pair in "config:$cfg" "state:$st" "cache:$ca"; do
    kind="${pair%%:*}"; path="${pair#*:}"
    case "$path" in
      "$root"/*) ok "standalone: stdpath('$kind') is inside the root" ;;
      *)         bad "standalone: stdpath('$kind') is inside the root" "$path" ;;
    esac
  done

  # THE post-exit property. Neovim has exited by now.
  [ ! -d "$root" ] \
    && ok "standalone: the root is swept when Neovim exits" \
    || bad "standalone: the root is swept when Neovim exits" "$root still present"
fi

# ── 2. rejection branch: a HOME-contained TMPDIR must create nothing ───
# `-i NONE` on every subprocess above and below: the rejection path
# errors BEFORE the helper redirects XDG, so without it Neovim writes
# shada and nvim.log into the fake HOME. Cleanup would contain that, but
# unrelated state has no business in a hermeticity contract.
fake="$WORK/home"
mkdir -p "$fake/tmp"
rej="$WORK/reject.txt"
env -u AF_TEST_SANDBOX_ROOT HOME="$fake" TMPDIR="$fake/tmp" \
  nvim --headless -u NONE -i NONE \
  --cmd "lua dofile('$HELPER')('contract-reject')" -c qa >"$rej" 2>&1

grep -q "refusing to sandbox under the home directory" "$rej" \
  && ok "rejection: a HOME-contained TMPDIR is refused" \
  || bad "rejection: a HOME-contained TMPDIR is refused" "$(head -2 "$rej" | tr '\n' ' ')"

leftovers="$(find "$fake/tmp" -mindepth 1 2>/dev/null | head -5)"
[ -z "$leftovers" ] \
  && ok "rejection: nothing is created at the refused location" \
  || bad "rejection: nothing is created at the refused location" "$(echo "$leftovers" | tr '\n' ' ')"

# ── 3. shared branch still nests under the exported parent ─────────────
shared_parent="$WORK/exported"
mkdir -p "$shared_parent"
shared_root="$(AF_TEST_SANDBOX_ROOT="$shared_parent" nvim --headless -u NONE -i NONE \
  --cmd "lua io.write(dofile('$HELPER')('contract-shared'))" -c qa 2>/dev/null)"
case "$shared_root" in
  "$shared_parent"/contract-shared-*)
    ok "shared: the root nests under the exported parent" ;;
  *)
    bad "shared: the root nests under the exported parent" "$shared_root" ;;
esac

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
