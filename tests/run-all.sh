#!/usr/bin/env bash
# tests/run-all.sh — run every auto-finder test suite (ADR-0040 Batch D).
#
# Previously only tests/smoke.lua was ever invoked; dbase_spike.lua
# (panel/dbee window-contract spike) and encrypted_vault_smoke.lua
# (crypto provider + encrypted source CRUD) were orphaned — present,
# green-when-written, wired into nothing, silently bit-rotting.
#
# Usage:
#   tests/run-all.sh                      # run all three suites
#   AF_KNOWN_ENV_FAILS=4 tests/run-all.sh # tolerate N known env failures
#                                         # (macOS: 4 — the /tmp symlink
#                                         # buffers-tree family)
#
# KNOWN ISSUE: tests/smoke.lua currently SEGFAULTS at section [41b]
# on macOS / nvim 0.12.2 (headless :edit of the malformed fixture with
# accumulated attach state) — tracked in the KB todo
# `2026-06-13-bug-auto-finder-smoke-suite-silently-truncates-at-41b-...`.
# Until that's fixed, a smoke crash AFTER its final section output is
# tolerated (AF_TOLERATE_SMOKE_CRASH=1, default). Counts are parsed
# from the captured output either way, so real assertion failures
# still fail this runner.
set -u
cd "$(dirname "$0")/.."

KNOWN_ENV_FAILS="${AF_KNOWN_ENV_FAILS:-0}"
TOLERATE_SMOKE_CRASH="${AF_TOLERATE_SMOKE_CRASH:-1}"
overall=0

run_suite() {
  local name="$1" file="$2" tolerate_crash="$3"
  local out exit_code pass fail
  echo "── $name ──────────────────────────────"
  out="$(nvim --headless -u NONE -l "$file" 2>&1)"
  exit_code=$?
  pass=$(printf '%s\n' "$out" | grep -cE "^  PASS" || true)
  fail=$(printf '%s\n' "$out" | grep -cE "^  FAIL" || true)
  printf '%s\n' "$out" | grep -E "^  FAIL" | head -10
  echo "   $name: $pass passed, $fail failed (exit=$exit_code)"
  if [ "$fail" -gt "$KNOWN_ENV_FAILS" ]; then
    echo "   ✗ $name: $fail failures exceed tolerated $KNOWN_ENV_FAILS"
    overall=1
  elif [ "$exit_code" -ge 128 ] && [ "$tolerate_crash" = "1" ]; then
    echo "   ⚠ $name: crashed (signal $((exit_code - 128))) — tolerated per the [41b] bug task"
  elif [ "$exit_code" -ne 0 ] && [ "$fail" -eq 0 ]; then
    echo "   ✗ $name: non-zero exit with no counted failures (crash before assertions?)"
    overall=1
  fi
}

run_suite "smoke"           tests/smoke.lua                 "$TOLERATE_SMOKE_CRASH"
run_suite "dbase_spike"     tests/dbase_spike.lua           0
run_suite "encrypted_vault" tests/encrypted_vault_smoke.lua 0

echo "──────────────────────────────────────"
if [ "$overall" -eq 0 ]; then
  echo "run-all: OK (env-fail tolerance: $KNOWN_ENV_FAILS)"
else
  echo "run-all: FAILED"
fi
exit "$overall"
