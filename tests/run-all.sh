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

# ── XDG SANDBOX ───────────────────────────────────────────────────
# One writable root per run, exported so every suite nests its
# config/state/cache under it (tests/_sandbox.lua reads this var).
#
# Why: the suites used to redirect XDG_CONFIG_HOME and XDG_STATE_HOME
# but leave XDG_CACHE_HOME on the real $HOME/.cache. auto-run writes
# each run under stdpath("cache"), so on a host where that is
# read-only the mkdir fails with E739, no job spawns, and ADR-0048's
# seven p46 assertions cascade off it — 147/7 instead of 154/0. Two
# agents on the same machine and commit disagreed for months over
# exactly this. It is an undeclared environment dependency, not a
# tolerable failure, so it is fixed here rather than absorbed into
# AF_KNOWN_ENV_FAILS.
#
# XDG_DATA_HOME is deliberately NOT redirected: installed treesitter
# parsers and plugin data live under it and redirecting it hides
# them, which fails ADR-0048 for a different reason. That experiment
# has been run; do not "complete the set".
# mktemp failure must be fatal. Without the explicit check, `set -u`
# alone leaves an empty value, the export silently degrades every suite
# to its own standalone fallback root, and the aggregate cleanup below
# then has nothing to remove -- a silent loss of the property this
# block exists to guarantee.
if ! AF_TEST_SANDBOX_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/auto-finder-testrun-XXXXXX")" \
   || [ -z "$AF_TEST_SANDBOX_ROOT" ] || [ ! -d "$AF_TEST_SANDBOX_ROOT" ]; then
  echo "run-all: FAILED — could not create a sandbox root under ${TMPDIR:-/tmp}" >&2
  exit 1
fi
export AF_TEST_SANDBOX_ROOT

cleanup_sandbox() {
  # Guard the rm: only ever remove a path matching the pattern we
  # created ourselves, never an empty or inherited value.
  case "$AF_TEST_SANDBOX_ROOT" in
    "${TMPDIR:-/tmp}"/auto-finder-testrun-*)
      rm -rf "$AF_TEST_SANDBOX_ROOT" ;;
  esac
}
# EXIT runs on normal termination; the signal traps clean up and then
# re-exit so the shell reports death-by-signal rather than success.
# Sharing one trap across EXIT and the signals would either skip
# cleanup on ^C or mask the signal in the exit status.
trap cleanup_sandbox EXIT
trap 'cleanup_sandbox; trap - INT;  kill -INT  $$' INT
trap 'cleanup_sandbox; trap - TERM; kill -TERM $$' TERM
echo "sandbox: $AF_TEST_SANDBOX_ROOT"

# PREFLIGHT: every suite this runner executes must route its XDG roots
# through tests/_sandbox.lua. A new suite that hand-assigns vim.env.XDG_*
# silently reintroduces the writable-$HOME dependency, and nothing else
# here would notice.
preflight_sandbox() {
  local bad=0 f
  for f in "$@"; do
    if ! grep -q '_sandbox\.lua' "$f"; then
      echo "run-all: FAILED — $f does not use tests/_sandbox.lua" >&2
      bad=1
    fi
    if grep -qE 'vim\.env\.XDG_(CONFIG|STATE|CACHE)_HOME[[:space:]]*=[[:space:]]*"/tmp' "$f"; then
      echo "run-all: FAILED — $f hardcodes a fixed /tmp XDG root" >&2
      bad=1
    fi
  done
  return $bad
}

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
  #   • "<prefix>: N passed, M failed, K skipped" (legacy prefixed form)
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

SUITES="tests/smoke.lua tests/smoke-automation.lua tests/smoke-adr0044.lua
tests/smoke-adr0048.lua tests/adr0059-e2e.lua tests/adr0060-repos-render.lua
tests/v0267-loop-guard.lua tests/adr0060-r1-view-lifecycle.lua"
# shellcheck disable=SC2086
if ! preflight_sandbox $SUITES; then
  echo "run-all: FAILED (preflight)"
  exit 1
fi

run_suite "smoke"           tests/smoke.lua
# [41]/[42] (ADR-0035 automation) — extracted from smoke.lua; the
# malformed-template :edit crashes only with smoke.lua's accumulated
# state, so a fresh process runs them safely.
run_suite "smoke_automation" tests/smoke-automation.lua
# [45] (ADR-0044 worktree:switched) — extracted from smoke.lua; needs a
# freshly-materialised panel window, which only happens early in a run.
run_suite "smoke_adr0044"   tests/smoke-adr0044.lua
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
