# auto-finder flaky-test catalog

Living index of smoke sections removed from `tests/smoke.lua` because
they became unreliable under the ADR 0026 structural refactor (or
were already unreliable before it). Each entry captures:

- **What the test asserted** — the user story or production
  invariant the section was intended to defend.
- **Why it became flaky** — the specific state-isolation,
  ordering, or stub-reachability problem.
- **When to reimplement** — the architectural milestone at which
  the test can be re-introduced against a stable surface.
- **Reference to the removal commit** — so a maintainer can recover
  the original code if needed.

The policy is documented in ADR 0026
([[0026-auto-finder-state-ui-separation]]) §6:

> During the refactor, smoke sections that test pre-refactor
> behavior may break in ways that aren't real regressions
> (state-isolation between sections, stale stub plumbing against
> moved code paths, etc.). Capture the user story, remove the
> legacy section, and reimplement against the new architecture
> at the phase that actually changes the surface under test.

If you find another section becoming flaky during a phase, follow
the same protocol: append an entry here, remove the legacy
section, and queue the reimplementation note.

---

## Catalog

### [24] show-race — `command.execute({action="show"})` survives `current_win` invalidation

- **Status:** removed (was flaky 1/263 since `v0.2.21`, commit
  `7bbb996`)
- **Removed in:** ADR 0026 Phase 4 cleanup (this commit)
- **Reimplementation milestone:** ~~ADR 0026 Phase 7
  (`loading-placeholder`)~~ — **deferred** to an auto-core API
  change (see "Why this section is hard to fix in place" below).

**User story / production invariant.** When the user (or
auto-core's internal callers) invokes `command.execute({ action
= "show", source = "filesystem" })`, the implementation in
`lua/auto-finder/neotree/command/init.lua` calls
`manager.navigate` asynchronously — capturing
`nvim_get_current_win()` BEFORE the async navigate and then
trying to restore focus to it in the callback. If the captured
window has been closed in the interim (the user moved on, a
sibling plugin closed the split, lazy.nvim's checker
interleaves at startup), the naïve `vim.api.nvim_set_current_win`
call would throw `Invalid window id` and surface as a
`vim.schedule` callback traceback.

The production guard at `command/init.lua:45-46` wraps the
`set_current_win` in a `vim.api.nvim_win_is_valid` check. The
invariant is: **show-action callbacks survive the race when the
captured window is closed before the navigate callback fires.**

**Why the test was flaky.** Section [24] stubbed
`manager.navigate` to close the victim window and fire the
callback synchronously — but the stub was unreachable because
earlier smoke sections ([3], [27]) leave the `filesystem`
neo-tree state mounted. `do_show_or_focus` at
`command/init.lua:19-48` early-returns when
`renderer.window_exists(state) == true`:

```lua
if args.action == "show" then
  if window_exists and not force_navigate then
    return                              -- ← early-return
  end
  local current_win = vim.api.nvim_get_current_win()
  manager.navigate(state, args.dir, args.reveal_file, function()
    -- the production guard lives in this callback ...
  end, false)
```

So the test's monkey-patched `manager.navigate` is never called,
`victim_win` stays open, and the second assertion (`victim
window was actually closed during the race`) fails reliably.
The first assertion (`pcall` succeeded) passes because the
function early-returns cleanly — but that's a false positive:
the guard wasn't exercised at all.

The defect is in the test's pre-state assumptions, not the
production code.

**Why this section is hard to fix in place during the refactor.**
A maintainer fix exists (reset `s.winid = nil` on every
filesystem-source state before running the section so
`window_exists` returns false; see
[[auto-finder-section-24-show-race-smoke-defect]] § Proposal B).
But the right place to add it is after Phase 7's view mount
contract lands — at that point the section can run against a
real generation-guarded placeholder mount and prove the guard
end-to-end without manually mutating sibling state.

**Reimplementation plan (deferred — pending auto-core change).**

The original plan was to re-add this against Phase 7's
loading-placeholder mount contract. **Phase 7 narrowed scope
to the dbase view only** (see
[tests/auto-finder-test-audit.md F7.1](./auto-finder-test-audit.md))
because of an auto-core Registry keymap-binding tension:
`auto-core.ui.section.Registry:focus` binds `0..9` + `q`
keymaps on whatever bufnr `section.get_buffer` returns; with a
placeholder + later swap, those keymaps land on the
placeholder and are wiped on swap, leaving the real buffer
without auto-core keymaps. Files / buffers / repos views
therefore keep synchronous mounts, and the show-race scenario
has no clean re-introduction point against the views the
production fix actually covers.

The reimplementation is unblocked when **`auto-core.ui.section`
exposes a public keymap-rebind hook** (e.g. a
`Registry:rebind_keymaps(bufnr)` method). At that point:

1. Mount the files view via `af.focus(1)`; the new mount
   contract makes the section transition through the
   placeholder generation guard.
2. Wait for the placeholder → real-buffer transition (using
   the same `vim.wait` polling against `_owned_bufs[bufnr]`
   pattern the audit log F4-cascade fixes use).
3. Stand up a victim window. Capture its winid as
   `current_win`.
4. Stub `manager.navigate` to close the victim then fire the
   restore-focus callback.
5. Invoke `command.execute({ action = "show", source =
   "filesystem", force_navigate = true })` to bypass the
   `window_exists` short-circuit cleanly.
6. Assert: `pcall` returned true; victim window invalid; the
   stub was actually reached (`navigate_called = true`).

Until that auto-core change lands, this test stays removed.
The production fix (the `pcall` guard around
`nvim_set_current_win` at `command/init.lua:45-46`) continues
to protect the user-visible behavior; only the test coverage
for that guard is on hold.

**References:**

- `lua/auto-finder/neotree/command/init.lua:19-48` —
  `do_show_or_focus` (the function the test was defending).
- Removed section was at `tests/smoke.lua:2066-2102` in commit
  `2301be4` (ADR 0026 Phase 4 ship).
- Original ship of the production guard: `auto-finder.nvim` commit
  `7bbb996` (v0.2.21, "guard nvim_set_current_win against closed
  window").
- Pre-refactor analysis: [[auto-finder-section-24-show-race-smoke-defect]]
  (KB synthesis, two fix proposals + verification plan).
