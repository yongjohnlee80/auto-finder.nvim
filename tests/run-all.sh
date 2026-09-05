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
# Those [41]/[42] sections were extracted to tests/smoke-automation.lua,
# where process isolation plus preservation of nvim's natural headless
# geometry keeps the coverage live without provoking the same core defect.
# The panel-materialisation sections [45]/[46]/[47] moved to
# smoke-adr0044.lua / smoke-adr0048.lua, so smoke.lua now runs to its
# summary cleanly. See
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
    # Match an EXECUTABLE invocation, not the mere presence of the
    # string: a free `_sandbox.lua` grep is satisfied by a comment, so
    # deleting a suite's real call while leaving prose about it behind
    # kept the check green. The pattern is anchored at start-of-line
    # with an optional `local X =`, which a `--` comment cannot satisfy.
    if ! grep -qE '^[[:space:]]*(local[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*)?dofile\(.*_sandbox\.lua.*\)\(' "$f"; then
      echo "run-all: FAILED — $f has no executable tests/_sandbox.lua call" >&2
      bad=1
    fi
    # Both Lua quote styles; the original only caught double quotes.
    if grep -qE "vim\.env\.XDG_(CONFIG|STATE|CACHE|DATA)_HOME[[:space:]]*=[[:space:]]*[\"']/tmp" "$f"; then
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

# ── SUITE MANIFEST ────────────────────────────────────────────────
# ONE list drives both execution and the XDG preflight. They used to be
# two lists, which is a silent-bypass waiting to happen: adding a
# run_suite call without updating the preflight string meant the new
# suite was executed but never checked.
#
# Format: "<display-name>|<path>". Keep the per-suite rationale next to
# its entry so the reasons for the extractions stay discoverable.
SUITES=(
  "smoke|tests/smoke.lua"
  # [41]/[42] (ADR-0035 automation) — extracted from smoke.lua; the
  # malformed-template :edit crashes with smoke.lua's accumulated state.
  # The isolated runner also preserves natural headless geometry because
  # synthetic columns/lines independently provoke the core defect.
  "smoke_automation|tests/smoke-automation.lua"
  # [45] (ADR-0044 worktree:switched) — extracted from smoke.lua; needs
  # a freshly-materialised panel window, which only happens early.
  "smoke_adr0044|tests/smoke-adr0044.lua"
  # [46]/[47]/[48] (ADR-0048 Phase 3, views.tests/debug/env) — canonical
  # home for these panel-materialisation sections.
  "adr0048|tests/smoke-adr0048.lua"
  # ADR-0059 end-to-end: real fs.watch -> translator -> mounted panel,
  # counting actual root scans. The smoke [50] pins stub the tree, so
  # this is the only suite covering the real pipeline.
  "adr0059-e2e|tests/adr0059-e2e.lua"
  "adr0060-repos|tests/adr0060-repos-render.lua"
  "adr0060-git-actions|tests/adr0060-git-actions.lua"
  "v0267-loop|tests/v0267-loop-guard.lua"
  # ADR-0060 r1 — view-lifecycle latch.
  "r1-lifecycle|tests/adr0060-r1-view-lifecycle.lua"
  # ADR-0065 P3 — review authoring: draft, identity slug, interim submit.
  "adr0065-p3|tests/adr0065-p3-submit.lua"
  # ADR-0069 - semantic auto-core git-read call-site migration.
  "adr0069-git-reads|tests/adr0069-git-reads.lua"
  # ADR-0083 - attach review feedback to in-progress task.
  "adr0083-attach|tests/adr0083-repos-task-attach.lua"
  # ADR-0083 - diff resumption and session persistence.
  "adr0083-resume|tests/adr0083-diff-resumption.lua"
  # ADR-0083 - PR row rendering, child reviews, dissociation, and PR actions.
  "adr0083-pr-tree|tests/adr0083-repos-pr-tree.lua"
)

# The XDG contract binds EVERY runnable entrypoint, not only the ones
# this runner executes: bench-files-panel.lua and
# adr0060-gitignore-probe.lua are run by hand and would reintroduce the
# writable-$HOME dependency just as effectively. So preflight discovers
# tests/*.lua rather than reading the manifest, and excludes only
# underscore-prefixed support modules (_sandbox.lua itself).
preflight_targets() {
  local f
  for f in tests/*.lua; do
    case "$(basename "$f")" in
      _*) continue ;;      # support module, not an entrypoint
    esac
    printf '%s\n' "$f"
  done
}

if ! preflight_sandbox $(preflight_targets); then
  echo "run-all: FAILED (preflight)"
  exit 1
fi

# ── STANDALONE-BRANCH CONTRACT ────────────────────────────────────
# Every suite below takes the EXPORTED-ROOT branch of the helper,
# because this runner always exports AF_TEST_SANDBOX_ROOT. A bad edit
# once nested the standalone block inside the shared branch, breaking
# that path completely -- and this gate stayed green for a whole review
# round because nothing here ever exercised it.
#
# The contract runs fresh Neovim subprocesses with the variable UNSET,
# and checks the two properties only observable from outside the
# process: that the root is swept at exit, and that a refused location
# has nothing created in it. It is a .sh (not a tests/*.lua suite)
# precisely because those are post-exit observations.
echo "── sandbox_contract ──────────────────────────"
if contract_out="$(tests/sandbox-contract.sh 2>&1)"; then
  printf '%s\n' "$contract_out" | tail -1 | sed 's/^/   sandbox_contract: /'
else
  printf '%s\n' "$contract_out" | grep -E "^  FAIL" | head -5
  echo "   ✗ sandbox_contract: FAILED"
  overall=1
fi

for entry in "${SUITES[@]}"; do
  run_suite "${entry%%|*}" "${entry#*|}"
done
echo "──────────────────────────────────────"
if [ "$overall" -eq 0 ]; then
  echo "run-all: OK (env-fail tolerance: $KNOWN_ENV_FAILS)"
else
  echo "run-all: FAILED"
fi
exit "$overall"
