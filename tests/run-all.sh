#!/usr/bin/env bash
# tests/run-all.sh — run every auto-finder test suite (ADR-0040 Batch D).
#
# Every standalone suite is wired in here; an unwired suite is exactly
# the orphan-bit-rot this runner exists to prevent.
#
# Usage:
#   tests/run-all.sh                      # run all suites
#   AF_KNOWN_ENV_FAILS=N tests/run-all.sh # tolerate N genuine env fails
#
# ── SUMMARY SENTINEL (KB todo 2026-08-23) ──────────────────────────
# Each suite ends by printing a canonical "N passed, M failed" summary
# line. A suite whose output does NOT contain that line did not reach
# the end of its file — it aborted (Lua error) or crashed (SIGABRT/
# SIGSEGV) mid-run — and is counted as FAILED, NOT parsed for whatever
# partial PASS lines it managed to emit. This is the durable guard
# against silent truncation: it is the ONLY thing that can catch a
# C-level crash (a Lua xpcall cannot). It replaces the former
# AF_TOLERATE_SMOKE_CRASH leniency, which silently hid exactly this
# class — the truncation that this todo was opened to fix.
#
# History: tests/smoke.lua used to abort at section [41]/[41b] — a
# neovim-core grid_line_flush SIGABRT on Linux, a SEGFAULT on macOS —
# on the headless `:edit` of the malformed automated-template fixture
# with the suite's accumulated attach state (KB todo
# 2026-06-13-bug-auto-finder-smoke-suite-silently-truncates-at-41b-…).
# Those [41]/[42] sections were extracted to tests/smoke-automation.lua
# (fresh process, low state → no crash), and the panel-materialisation
# sections [45]/[46]/[47] to smoke-adr0044.lua / smoke-adr0048.lua, so
# smoke.lua now runs to its summary cleanly. See
# tests/auto-finder-coverage.md for the full suite→surface inventory.
set -u
cd "$(dirname "$0")/.."

KNOWN_ENV_FAILS="${AF_KNOWN_ENV_FAILS:-0}"
overall=0

run_suite() {
  local name="$1" file="$2"
  local out exit_code pass fail
  echo "── $name ──────────────────────────────"
  out="$(nvim --headless -u NONE -l "$file" 2>&1)"
  exit_code=$?
  pass=$(printf '%s\n' "$out" | grep -cE "^  PASS" || true)
  fail=$(printf '%s\n' "$out" | grep -cE "^  FAIL" || true)
  printf '%s\n' "$out" | grep -E "^  FAIL" | head -10
  # Summary sentinel: did the suite reach its end-of-file terminal
  # marker? Suites use three heterogeneous but recognised formats:
  #   • "N passed, M failed"                      (smoke, adr0048, …)
  #   • "<prefix>: N passed, M failed, K skipped" (dbase_spike, vault)
  #   • "RESULT: all expectations met|NOT met"    (adr0059-e2e)
  # Anything else means the suite truncated before its end-of-file.
  local saw_summary=0
  if printf '%s\n' "$out" | grep -qE "[0-9]+ passed, [0-9]+ failed|RESULT: (all expectations met|expectations NOT met)"; then
    saw_summary=1
  fi
  echo "   $name: $pass passed, $fail failed (exit=$exit_code, summary=$saw_summary)"
  if [ "$saw_summary" -ne 1 ]; then
    # No summary line ⇒ the suite truncated before end-of-file. This is
    # a crash or an uncaught abort; count it FAILED regardless of how
    # many PASS lines it emitted first (they are partial and untrustworthy).
    local sig=""
    [ "$exit_code" -ge 128 ] && sig=" (signal $((exit_code - 128)))"
    echo "   ✗ $name: no 'N passed, M failed' summary — suite truncated/crashed$sig"
    overall=1
  elif [ "$fail" -gt "$KNOWN_ENV_FAILS" ]; then
    echo "   ✗ $name: $fail failures exceed tolerated $KNOWN_ENV_FAILS"
    overall=1
  elif [ "$exit_code" -ne 0 ] && [ "$fail" -eq 0 ]; then
    echo "   ✗ $name: non-zero exit with no counted failures"
    overall=1
  fi
}

run_suite "smoke"           tests/smoke.lua
# [41]/[42] (ADR-0035 automation) — extracted from smoke.lua; the
# malformed-template :edit crashes only with smoke.lua's accumulated
# state, so a fresh process runs them safely.
run_suite "smoke_automation" tests/smoke-automation.lua
# [45] (ADR-0044 worktree:switched) — extracted from smoke.lua; needs a
# freshly-materialised panel window, which only happens early in a run.
run_suite "smoke_adr0044"   tests/smoke-adr0044.lua
run_suite "dbase_spike"     tests/dbase_spike.lua
run_suite "encrypted_vault" tests/encrypted_vault_smoke.lua
# [46]/[47]/[48] (ADR-0048 Phase 3, views.tests/debug/env) — canonical
# home for these panel-materialisation sections (see the file header).
run_suite "adr0048"         tests/smoke-adr0048.lua
# ADR-0059 end-to-end: real fs.watch -> translator -> mounted panel,
# counting actual root scans. The smoke [50] pins stub the tree, so
# this is the only suite covering the real pipeline.
run_suite "adr0059-e2e"    tests/adr0059-e2e.lua
run_suite "adr0060-repos" tests/adr0060-repos-render.lua
run_suite "v0267-loop"    tests/v0267-loop-guard.lua
# ADR-0060 r1 — view-lifecycle latch (added on main@474a871; merged
# onto the 2-arg + summary-sentinel run_suite here).
run_suite "r1-lifecycle"  tests/adr0060-r1-view-lifecycle.lua

echo "──────────────────────────────────────"
if [ "$overall" -eq 0 ]; then
  echo "run-all: OK (env-fail tolerance: $KNOWN_ENV_FAILS)"
else
  echo "run-all: FAILED"
fi
exit "$overall"
