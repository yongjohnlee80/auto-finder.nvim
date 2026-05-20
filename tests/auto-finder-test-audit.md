# auto-finder test-failure audit log

Audit trail for every smoke failure encountered during the ADR
0026 refactor arc (or any future refactor) **and** the
remediation action taken. Different from
`tests/auto-finder-flaky.test.md`, which catalogs tests that
were *removed* with reimplementation plans. This doc records
tests that *failed* during a phase and were *fixed in place*.

Each entry captures:

- **Phase** — which phase / commit hit the failure.
- **Failing assertion(s)** — the exact label printed by the smoke
  runner.
- **Root cause** — what made the assertion fail (production code
  change? pre-state assumption broken by the refactor? race?).
- **Remediation** — the exact change applied to fix it. Code
  edit, smoke edit, or both.
- **Smoke delta** — before/after totals (passed/failed).
- **Commit reference** — the SHA where the fix landed (so
  reviewers can diff the remediation).

## Policy (forward-looking)

For every phase commit that follows ADR 0026:

1. Run the smoke; record the **initial** delta (passed/failed)
   in the phase's commit message draft.
2. If failed > 0, **before** committing, append an entry below
   for each distinct failure. The entry must include root cause
   and remediation.
3. Re-run the smoke; record the **post-remediation** delta in
   the same commit message.
4. The commit lands with passed > 0 and failed == 0 (or, if a
   failure is being intentionally removed, document it in
   `auto-finder-flaky.test.md` instead and reduce the suite by
   that section).

When a remediation **moves** a test rather than fixing it (e.g.
removes a stale assertion because the surface under test
moved), prefer documenting in `auto-finder-flaky.test.md` so the
reimplementation plan is captured. The audit log is for "the
test had to change shape to match the new architecture."

---

## Phase 3 — `core-lifecycle` (2026-05-19, commit `5061373`)

### Initial smoke delta: 326 passed / **5 failed**

Phase 2 baseline was 326/1 (the 1 = section [24] pre-existing
flake — see [auto-finder-flaky.test.md](./auto-finder-flaky.test.md)).
Phase 3 added 16 new asserts in section [31] (`A7` bus-reset +
`A8` handle release + lifecycle invariants + translation +
metrics:paint emit).

### Failures

#### F3.1 — `core.is_started() is true after af.setup()`

**Root cause.** Section [29] (Phase 1 smoke) ended with
`core._reset_for_tests()` to leave core "not started" for later
sections. Phase 3 made `setup()` transitively call
`ensure_started`, so subsequent sections now expect a live
core. The Phase 1 cleanup was Phase-1-conservative; Phase 3
made it incorrect.

**Remediation.** Removed the `core._reset_for_tests()` cleanup
from section [29]'s closing. Replaced the inline comment with:
*"Phase 1 originally cleaned up with `core._reset_for_tests()`
so later sections could assume 'not started.' Phase 3 makes
that assumption wrong: setup() now wires ensure_started
transitively, so subsequent sections expect a live core. Leave
it running."*

**Knock-on remediations.** F3.2, F3.3 had the same root cause
and were fixed by the same edit.

#### F3.2 — `ensure_started captured > 0 handles`

**Root cause.** Identical to F3.1.

**Remediation.** Covered by F3.1's edit.

#### F3.3 — `ensure_started is idempotent (handle count unchanged on re-call)`

**Root cause.** Identical to F3.1 — the initial state was 0
handles instead of N, so the "second call doesn't grow"
assertion fired against a fresh subscribe.

**Remediation.** Covered by F3.1's edit.

#### F3.4 — `metrics:paint emit fires from existing render path`

**Root cause.** Section [31] originally placed the metrics:paint
test AFTER the bus-reset test (`auto-core.events._reset_for_tests`).
The bus reset wiped `shared/neotree.lua`'s `core.file:*`
subscription, and its one-shot `_fs_subscribed` flag prevented
re-arm on subsequent focus. By the time the metrics:paint test
fired its synthetic event, the subscriber that would drive
`schedule_refresh` was dead.

**Remediation.** Reordered section [31] to put the metrics:paint
assertion BEFORE the bus-reset test. Added an inline comment
documenting the limitation:

> The shared/neotree.lua subscriber registers via the one-shot
> `_fs_subscribed` flag — once a bus reset wipes it, the flag
> stays true and the subscription doesn't re-arm until Phase 7
> migrates that path into the re-armable shape. So we verify
> metrics:paint BEFORE the bus-reset test below, while
> shared/neotree.lua's subscriber is still alive.

The underlying limitation is filed for Phase 7's `loading-placeholder`
mount contract.

### Post-remediation smoke delta: **342 passed / 1 failed**

The 1 remaining failure is the pre-existing section [24] flake
(still present at this phase; removed later).

---

## Phase 4 — `core-files-state` (2026-05-19, commits `2301be4` + `55c24ed`)

### Initial smoke delta: 345 passed / **11 failed**

Phase 4 made `core.ensure_started` actually open the fs.watch
handle and start the chunked warmer — both no-ops before. This
broke several pre-Phase-4 assertions that assumed the old
shape (section module owned the handle, ensure_started was a
no-op, etc.).

### Failures

#### F4.1 — `files section has _ensure_fs_watch (live_refresh wired)`

**Root cause.** Phase 4 deleted `_ensure_fs_watch` and
`_stop_fs_watch` from the section. The handle owner moved to
`core/watchers.lua` per ADR §A2 (every fs.watch.start /
git.watch.start call must live inside `lua/auto-finder/core/`).

**Remediation.** Rewrote section [14] entirely. Old assertions
about `section._ensure_fs_watch` / `_fs_watch_handle` /
`_fs_watch_root` replaced with assertions about
`core.watchers.list()` and `section._arm_live_refresh_subs`
(the new exposed re-arming function).

**Knock-on remediations.** F4.2, F4.3, F4.4 had the same root
cause and were covered by the same rewrite.

#### F4.2 — `files section has _stop_fs_watch`

Covered by F4.1.

#### F4.3 — `watcher handle present after focus(files)`

Covered by F4.1.

#### F4.4 — `watcher root matches getcwd`

Covered by F4.1.

#### F4.5 — `git.watch handle present after focus(files)`

**Root cause.** Same as F4.1 — git.watch ownership moved to
core/watchers in the same phase (A2 required both fs.watch and
git.watch to live in core/).

**Remediation.** Section [14b] rewritten to assert
`files_section._git_watch_handle == nil` (handle moved away)
and that publishing `core.git.state:changed` still triggers
`manager.refresh` via the new translation chain.

#### F4.6 — `core.files.snapshot_now starts in cold readiness`

**Root cause.** Phase 1 [29] asserted readiness == "cold" right
after `ensure_started(nil)` — under the assumption that Phase 1's
ensure_started was a no-op. Phase 4's ensure_started now opens
watchers and kicks off the chunked warmer, so readiness
transitions cold → warming → ready shortly after setup. The
cold-state assertion no longer survives.

**Remediation.** Softened the assertion from "starts in cold
readiness" to "returns a known readiness state" (matches `cold`
| `warming` | `ready` | `partial`). The Phase 1 smoke shape
remains, just at a coarser granularity.

**Knock-on remediations.** F4.7, F4.8 had the same root cause
and were fixed by parallel softening edits.

#### F4.7 — `core.watchers.list() returns empty array on cold start`

**Root cause.** Same as F4.6 — ensure_started now opens a
watcher, so `list()` isn't empty.

**Remediation.** Softened to "returns a list (may have entries
from setup)."

#### F4.8 — `core.warm.status() returns 'cold' on Phase 1 skeleton`

**Root cause.** Same as F4.6 — ensure_started now starts the
warmer.

**Remediation.** Softened to "returns a known status."

#### F4.9 — `pre-reset: translator fires on core.file:created`

**Root cause.** Phase 4's translator added 100ms debounce +
burst-coalescing. The Phase 3 smoke published a synthetic
`core.file:created` and asserted the translated event fires
synchronously — but Phase 4 deferred emission to a debounce
window.

**Remediation.** Added `core._flush_file_events_for_tests()`
calls in section [31] after each synthetic publish so the
assertion doesn't race the debounce timer. The flush helper was
added to `core/init.lua` specifically for this smoke
synchronization need (test-only surface).

**Knock-on remediations.** F4.10, F4.11, F4.12 had the same
root cause and were fixed by the same flush calls.

#### F4.10 — `pre-reset: translated payload carries kind='upsert'`

Covered by F4.9.

#### F4.11 — `pre-reset: translated payload carries the path`

Covered by F4.9.

#### F4.12 — `A7: translator re-arms after bus reset (event fires)`

Covered by F4.9 (same debounce-race issue, in the post-reset
re-arm assertion).

#### F4.13 — `A7: post-reset payload still carries kind='upsert'`

Covered by F4.9.

#### F4.14 — `A8: fs.watch handle count unchanged across ensure_started/stop`

**Root cause.** Phase 3 A8 captured `fs_before` AFTER setup
(which already opened a watcher in Phase 4), then asserted
"stop returns list to the before-state." But stop releases
ALL handles, so after_stop = 0, before = 1, after != before.
The "unchanged across" framing was wrong for Phase 4's reality.

**Remediation.** Restructured A8: call `stop()` FIRST to
baseline at 0, then `ensure_started` (asserts handle count
grew), then `stop` again (asserts return to baseline). Same
acceptance intent ("stop releases what ensure_started opens"),
just measured cleanly.

#### F4.15 — `A8: git.watch handle count unchanged across ensure_started/stop`

Covered by F4.14.

#### F4.16 — `victim window was actually closed during the race`

**Root cause.** Pre-existing section [24] flake (since
v0.2.21) — see
[auto-finder-flaky.test.md § Section [24] show-race](./auto-finder-flaky.test.md#24-show-race--commandexecuteactionshow-survives-current_win-invalidation).

**Remediation.** Section removed in commit `55c24ed`. Captured
in the flaky-test catalog with the user story + Phase 7
reimplementation plan.

### Post-remediation smoke delta: **356 passed / 1 failed**

Then section [24] removed in `55c24ed`: **355 passed / 0 failed.**

---

## Phase 6 — `core-buffers-repos` (2026-05-20, commit pending at audit-doc edit time)

### Initial smoke delta: smoke crashed during section [34]

The Phase 6 smoke fired `vim.cmd("edit " .. probe)` to test that
`core.buffers` picks up new buffers via BufAdd. The command
errored hard with:

```
E1513: Cannot switch buffer. 'winfixbuf' is enabled
```

… because by the time section [34] runs, the auto-finder panel
window is the current window AND has `winfixbuf=true` (the
panel-ownership marker per [[auto-core-panel-ownership]]). The
`:edit` command tries to switch the current window's buffer to
the new file's buffer, which `winfixbuf` blocks.

### Failures

#### F6.1 — section [34] crash: `:edit` can't switch panel buffer

**Root cause.** Test fixture chose the wrong nvim command for
the user-story under test. core.buffers tracks buffer-list
mutations regardless of which window is current; the test
needed a "add a buffer to the list" action, not "open this
file in the current window." `:edit` does both — and the
"open in current window" half collides with the panel's
winfixbuf guard.

**Remediation.** Switched the test from `:edit` to `:badd`.
`:badd` fires `BufAdd` (which is what core.buffers subscribes
to) without changing any window's buffer — exactly the
contract core.buffers cares about.

**Why this matters for future smokes.** Anywhere the smoke
needs to add a probe buffer while the panel is mounted as the
current window, use `:badd <path>`. If the test specifically
needs an EDITED buffer (different from added-but-not-loaded),
focus a non-panel window first via `vim.api.nvim_set_current_win`
on a previously-opened editor window, then `:edit`.

### Post-remediation smoke delta: **382 passed / 0 failed**

(Phase 5 baseline 366/0 + 16 new Phase 6 asserts.)

---

## Phase 5 — `core-git-state` (2026-05-20, commit `ac841ad`)

### Initial smoke delta: 365 passed / **1 failed**

### Failures

#### F5.1 — `core.git.state:changed still triggers manager.refresh via the translated topic`

**Root cause.** Section [31]'s bus reset earlier in the same
smoke run wiped `shared/neotree.lua`'s subscriptions. The
section's `_fs_subscribed = true` flag is one-shot, so the
later `_arm_live_refresh_subs` call (transitively via
`af.focus(1)`) bails out without re-subscribing. By the time
section [33]'s end-to-end assertion publishes its synthetic
`core.git.state:changed`, no subscriber drives `schedule_refresh`.

This is the same pre-Phase-7 limitation Phase 3 documented in
F3.4.

**Remediation.** Reset `files_section._fs_subscribed = false`
and explicitly call `files_section._arm_live_refresh_subs()`
in the smoke before the assertion. An inline comment in the
smoke names the dance as a smoke-side workaround, not a
production concern (real users don't hit
`auto-core.events._reset_for_tests`).

The underlying limitation is filed for Phase 7's
`loading-placeholder` mount contract, where the section's
subscription becomes generation-guarded + re-armable on every
focus.

### Post-remediation smoke delta: **366 passed / 0 failed**

---

## Cross-cutting observations

Three failure clusters recur across phases:

1. **One-shot subscription flags in shared/neotree.lua** (F3.4,
   F5.1). The pattern `_fs_subscribed = true` blocks re-arm
   after a bus reset. Phase 7's loading-placeholder mount
   contract removes the one-shot pattern in favor of a
   re-armable `shared.view_subs` set.

2. **Pre-state assumptions broken by ensure_started growing
   side effects** (F3.1–F3.3, F4.6–F4.8). Each phase that adds
   work to `ensure_started` invalidates earlier smoke
   assertions that captured the no-op state. Mitigated by:
   - Removing aggressive `core._reset_for_tests()` cleanups
     from early-phase sections.
   - Softening "starts in X state" assertions to "returns a
     known state."

3. **Translator timing changes** (F4.9–F4.13). Phase 4's
   debounce + coalescing broke any smoke that expected
   synchronous translation. Mitigated by the
   `_flush_file_events_for_tests` test-only flush helper. Any
   future phase that adds new debounce / coalescing surfaces
   must expose a parallel `_flush_*_for_tests` helper so the
   smoke can synchronize.

## Cross-references

- [tests/auto-finder-flaky.test.md](./auto-finder-flaky.test.md)
  — sister doc for tests *removed* during the refactor.
- [[0026-auto-finder-state-ui-separation]] (KB) — the umbrella
  ADR these phases implement.
- [[auto-finder-section-24-show-race-smoke-defect]] (KB) — the
  deep root-cause analysis of section [24] from before the
  refactor; preserved as historical reference.
