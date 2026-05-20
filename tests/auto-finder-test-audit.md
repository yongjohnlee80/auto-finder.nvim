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

## Phase 8 — `shared-extraction` + `logging-sweep` (2026-05-20, commit pending)

### Initial smoke delta: 401 passed / **4 failed**

### Failures

#### F8.1 — pre-existing bug: `vim.defer_fn` returns nil, so `vim.fn.timer_stop(prior)` was silently broken across the codebase

**Root cause.** The shared/debounce.lua I shipped initially
used the obvious pattern:

```lua
if timer then pcall(vim.fn.timer_stop, timer) end
timer = vim.defer_fn(fn, ms)
```

When the Phase 8 smoke exercised it (4 rapid triggers, expecting
1 fire), it observed **4 fires** — cancellation wasn't working.
Investigation revealed: `vim.defer_fn` is `vim.schedule_wrap`'d
internally, which doesn't propagate the inner `timer_start`
return value. So `timer` is always nil; the `if timer then`
branch never executes; cancel is silently a no-op.

**This was a pre-existing bug across the codebase.** The same
pattern was in `core/init.lua`'s pre-Phase-8 file-event
coalescer, and the Phase 4 burst-coalescing smoke (A4: "100
events → 1 fire") was passing by ACCIDENT — not because cancel
worked, but because the first deferred fire drained the buffer
and subsequent fires saw `if #_file_buf == 0 then return end`
and bailed. Same shape in `shared/neotree.lua`'s
schedule_refresh — `refresh_pending` flag + a no-op cancel.
The pattern worked because each consumer had a separate
"already drained / already fired" guard.

**Remediation.** Rewrite shared.debounce.coalesce with a
generation counter: each trigger bumps `pending_gen`; the
deferred fire captures `my_gen` at schedule time and checks
`my_gen == pending_gen` at fire time. Stale fires (where a
newer trigger superseded) are no-ops without touching the
state. Same latest-wins semantics; cancel works by simply
bumping `pending_gen` so every in-flight fire is now stale.

Phase 8's refactor flips both consumers (`shared/neotree.lua`
schedule_refresh + `core/init.lua` file-event coalescer) to
the new shared.debounce, so the bug is fixed in both places
in a single landed change. The audit log entry above
documents the pre-existing-bug shape for future maintainers.

#### F8.2 — `views/init.lua` log tag `"views"` violates A10

**Root cause.** The view registry's failure-mode log calls
used `"views"` (plural, matching the directory name) instead
of `"view.registry"` (per A10's `auto-finder.view.<name>`
scheme). Two occurrences in `views/init.lua` (both inside
`load_view`'s error paths).

**Remediation.** Renamed to `"view.registry"` — the registry
isn't itself a view, but `view.registry` fits the A10 scheme
as "the view-loading subsurface."

#### F8.3 — smoke A10 grep matched `logger.notifyIf` event-name args as if they were component tags

**Root cause.** The A10 smoke grep used pattern
`'logger%.[%w_]+%(%s*"([%w_.%-]+)"'` which matches the first
string arg of ANY logger method call — including
`logger.notifyIf(event_name, msg, opts)`. The first arg to
`notifyIf` is an EVENT name (subject to a different scheme,
typically `dbase.connection.changed` etc.), not a component
tag. Three false-positive violations from `views/dbase/events.lua`'s
notifyIf calls.

**Remediation.** Restrict the grep to LEVEL functions only
(error/warn/info/debug/trace). Lua patterns lack alternation,
so the smoke loops over the level set explicitly. notifyIf /
notify calls are now ignored by A10's grep.

#### F8.4 — smoke debounce `cancel` test asserting on stale state

**Root cause.** Same as F8.1 — once `cancel` actually works
(via the generation pattern), the test passes. Listed
separately because it was a distinct smoke assertion that
failed; the fix is the same as F8.1's remediation.

**Remediation.** Resolved by the F8.1 fix.

### Post-remediation smoke delta: **405 passed / 0 failed**

(Phase 7 baseline 399/0 + 9 new Phase 8 asserts — 3 for
debounce semantics, 1 for A9 (vim.notify grep), 1 for A10
(component-tag grep), 4 for the dbase tag migration smokes —
minus 3 dbase event-name false positives the F8.3 fix removed.)

---

## Phase 7 — `loading-placeholder` (2026-05-20, commit pending)

### Initial smoke delta: 399 passed / **9 failed**

Phase 7 set out to implement ADR §2.3's "every view's
`get_buffer` returns a placeholder; on_focus defers the real
mount" pattern. Initial wave of failures revealed timing
issues, then a deeper design tension surfaced (F7.1 below).

### Failures

#### F7.1 — auto-core Registry keymap binding incompatible with placeholder mount

**Root cause.** `auto-core.ui.section.Registry:focus` binds
`q`-close-panel and `0..9`-focus-section keymaps on the bufnr
returned by `section.get_buffer`. With the Phase 7 placeholder
pattern, those keymaps land on the placeholder buffer
(`bufhidden = wipe`); my deferred on_focus then swaps the panel
to the real neo-tree buffer, **wiping the placeholder**. The
real buffer never receives the keymaps. The smoke catches this
as "`q` bound on the panel buffer (overrides neo-tree
close_window)" — false.

`auto-core/ui/section.lua:51-71` (the local `apply_keymap`) is
not part of auto-core's public surface, so the deferred swap
has no clean hook to re-bind. Working around it inside
`shared/neotree.lua` would either:
- Duplicate `apply_keymap`'s logic (reaching into the
  Registry's `self.sections` for the 0..9 numbers + `self.panel`
  for the close action) — leaky abstraction.
- Force a second `Registry:focus(self.active)` to re-trigger
  binding — risks infinite re-entry through `section.on_focus`.
- Require auto-core to expose a public `apply_keymap` /
  `rebind` API — out of scope for this Phase 7 commit.

**Remediation.** Phase 7 scope narrowed to **`dbase` only**.
`shared/neotree.lua`'s `build_section` reverts to the
synchronous-mount get_buffer (status quo from Phase 6 — auto-core
binds keymaps on the real buffer, no swap). The Phase 7
infrastructure (`shared/loading.lua`, `shared/window.lua`, the
`_generation` + `_owned_bufs` + `_still_current` predicate in
build_section) all SHIP — they're just unused by neo-tree-backed
views for now. `views/dbase` uses the placeholder pattern fully
(A16); the deferred mount happens inside `M.on_focus` and never
touches the auto-core Registry's keymap-bound bufnr because
dbase already manages its own buffer lifecycle.

**A3 scope.** v3 of the smoke section [35] DROPS the "every
view returns a placeholder" assertion for files / buffers /
repos. The infrastructure exists; a future Phase 7 follow-up
can flip neo-tree-backed views to placeholder mode once
auto-core ships a public keymap-rebind hook. The dbase
placeholder (A16) is asserted in place.

**ADR amendment recommended.** §A3 should be softened from
"Every view's `get_buffer` returns a `shared.loading.buffer`
first" to "Views with async mount paths (dbase) return a
placeholder first; views with synchronous mount paths
(neo-tree-backed) may opt into the placeholder pattern when
auto-core provides a keymap-rebind hook." File for revision 4.

#### F7.2 — timing cascade (8 follow-on failures from F7.1's placeholder approach)

While the placeholder pattern was active in build_section, 8
existing smoke assertions failed because they assumed
`section._bufnr` was valid synchronously after `af.focus(N)`:

- `[6] panel back on neo-tree` — checked panel buffer's
  filetype was `auto-finder` immediately; placeholder filetype
  was empty.
- `[7] live width back to default (38)` — auto_expand_width
  side effects fired at a different time relative to
  reset_width.
- `[14] file-event under cwd triggers neo-tree manager.refresh`
  — schedule_refresh's guard `if not section._bufnr` returned
  early because mount hadn't completed.
- `[14b] core.git.state:changed for cwd triggers manager.refresh`
  — same guard.
- `[19] repos bufnr cached pre-event` — checked
  `_registry._bufs[repos.number]` was valid; cache still held
  the wipeable placeholder.
- `[22] panel window still displays buffers buffer` x2 — checked
  `nvim_win_get_buf(panel) == section._bufnr` immediately.
- `[22] panel window still displays repos buffer` — same.
- `[31] metrics:paint emit fires` — schedule_refresh guarded out.
- `[33] core.git.state:changed still triggers manager.refresh`
  — same.

**Root cause.** All eight cascade from F7.1's placeholder
approach making `section._bufnr` nil until the deferred mount
completes. Reverting build_section to synchronous mount
(F7.1's remediation) resolves all of these in one stroke.

**Remediation.** No per-assertion fix needed once F7.1's revert
landed. The polling waits added during initial debugging
(`vim.wait(500, function() return section._bufnr ~= nil end)`)
remain in place — harmless under sync mount (they return
immediately) AND useful as forward-defense if the placeholder
pattern ever turns back on for neo-tree-backed views.

#### F7.3 — Phase 6's `section.refresh()` metrics:paint emit polluting Phase 3 assertion

**Root cause.** Phase 6's `core_refresh_topic` opt added a
`section.refresh()` method that emits
`auto-finder.core.metrics:paint`. When buffers / repos views
refreshed earlier in the smoke run, their emits left
`paint_seen` holding `{ view = "buffers", … }` by the time
section [31]'s Phase 3 paint assertion checked.

**Remediation.** Filter the section [31] probe to
`p.view == "files"` so only the assertion's intended emit
counts. (Earlier section emits from buffers / repos are ignored
by the filtered probe.) The metrics:paint topic itself remains
unfiltered at publication — consumers filter at subscription
time.

### Post-remediation smoke delta: **399 passed / 0 failed**

### Carry-over: post-Phase-7 follow-ups

- Open Question for the ADR: when (if ever) should
  neo-tree-backed views adopt the placeholder pattern? The
  keymap-binding tension blocks it today; resolution requires
  an auto-core change. Filed as an ADR revision-4 candidate.
- The `_still_current` predicate + `_owned_bufs` table in
  build_section are dead code today. Keep them — they're the
  scaffolding the eventual flip will use. Logged at the top
  of `build_section` to discourage premature removal.

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
