# auto-finder test-suite coverage inventory

**Purpose.** Make coverage legible *by reading this file*, so a dark or
stale section is detectable here instead of only by noticing absent
output — which is the sole reason the p46/[41] silent-truncation bug
survived as long as it did (KB todo
`2026-08-23-bug-auto-finder-smokelua-aborts-at-p46-…`).

Unlike `auto-finder-test-audit.md` (a log of failures fixed in place)
and `auto-finder-flaky.test.md` (tests removed with reimplementation
plans), this file MAPS COVERAGE: every suite → the production surface
it defends → its status.

Last verified: **2026-08-23**, `tests/run-all.sh` → **OK**, 9 suites,
**1048 assertions, 0 failed** (all suites `summary=1`). Branch
`test-suite-health` off `main@053f799`.

---

## Status legend

| status | meaning |
|---|---|
| `live` | runs green under `tests/run-all.sh` today |
| `dark` | present in the tree but never executed (truncation/unwired) — **none remain** |
| `stale` | asserts a surface that changed or was removed — **none remain** |
| `isolated` | moved to its own fresh-nvim process because it needs a freshly-materialised panel window (see §Panel-materialisation) |
| `pty-required` | would need a real UI (`script -qec`) to run — **none: see §Panel-materialisation, this turned out NOT to be needed** |

---

## Suite inventory (what `run-all.sh` runs)

| suite | file | assertions | defends | status |
|---|---|---:|---|---|
| smoke | `smoke.lua` | 672 | the whole panel/section/view/state surface — setup, width/pin, winfixbuf, section switching, store+namespace migration, buffers/repos/marks slots, live-refresh wiring, log wrapper, follow-mode, ADR-0026 core refactor (phases 1-9), views.todos + automation panel rendering, ADR-0040 restore/async-git, ADR-0059 files:changed classification, views._config_section, dbase facade (the renderer itself moved to autodb — ADR-0078) | live |
| smoke_automation | `smoke-automation.lua` | 36 | ADR-0035 [41] automation diagnostics (malformed-cron/execute diagnostics, lifecycle guards, bash-disabled indicator) + [42] `s`-modal scaffold on `automated` promotion | live (isolated, natural headless geometry — see below) |
| smoke_adr0044 | `smoke-adr0044.lua` | 6 | ADR-0044 [45] `worktree:switched` re-anchors the panel tree to the new cwd WITHOUT displacing a non-panel editor split | live (isolated) |
| adr0048 | `smoke-adr0048.lua` | 146 | ADR-0048 Phase 3 [46] views.tests (auto-run discovery consumer), [47] views.debug (entry points/sessions/breakpoints + secret masking), [48] r5 Env section | live (isolated — canonical home for [46]/[47]) |
| adr0059-e2e | `adr0059-e2e.lua` | 5 | ADR-0059 real `fs.watch` → translator → mounted panel, counting actual root scans (the only suite over the REAL pipeline; smoke [50] stubs the tree) | live |
| adr0060-repos | `adr0060-repos-render.lua` | 23 | ADR-0060 repos panel renders worktree.nvim's work-in-flight tree; git shed from the files panel | live |
| v0267-loop | `v0267-loop-guard.lua` | 12 | v0.2.67 notification→refresh loop guard | live |

---

## smoke.lua — section rollup

All sections `live`. Structure: sections `[1]`–`[44]`, `[50 ADR-0059]`,
then `[48]`/`[49]`/`[50 ADR-0058-M7]`. (Section NUMBERS are historical
and non-monotonic in source order; they are labels, not an ordering.)

- `[1]`–`[12c]` — setup, width/resolve, winfixbuf enforcement, section
  switching, resize/pin, close/reopen, filetype-on-open, store
  persistence + legacy→namespace migration, winbar regions, repos
  facade + icon overrides, last_section persistence, marks slot.
- `[13]`–`[28]` — directory-hijack defer, live-refresh + git.watch
  wiring, log wrapper, namespace migration, section-registry migration,
  buffers source + slot-mutation, out-of-cwd sibling grouping,
  follow-mode protection, dbase file/conn management, deferred
  scan.started toast, user-stories (buffers/files/repos panels).
- `[29]`–`[40]` — ADR-0026 core refactor phases 1-9 (skeleton →
  views facade → lifecycle/bus-reset → files cache+watchers → git
  cache+translation → core.buffers/repos → loading-placeholder →
  shared extraction → acceptance audit), v0.2.25 subscription
  survival, views.todos render/scan/Vars-modal/collapsible-archive,
  ADR-0050 node-id dedup, ADR-0035 Phase 1 six-bucket panel.
- `[43]`/`[44]` — ADR-0040 scope-safe restore + handle close + atomic
  dbase writes; async git runner + marks read-cache.
- `[50 ADR-0059]` — files:changed does only the work the event
  requires (classification: kind+visibility → skip/redraw/scan).
- `[48]` — views._config_section: launch-config kind filter, select,
  masked expand (env secret never reaches the buffer).
- `[49]` — RETIRED by ADR-0078: the renderer moved to
  `autodb.views.drawer`, and its coverage moved with it to autodb's own
  suite (§[18]). What stays here is the FACADE — the placeholder path
  and release-driven teardown. Formerly: mounts without autodb,
  scratch-buffer contract, keymap vocabulary, **toggle state**
  (reimplemented 2026-08-23 — see below).
- `[50 ADR-0058-M7]` — RETIRED in v0.4.0. It asserted a delegation
  between two backends ("absent → dbee remains in charge"); dbee is gone
  and there is only autodb, so with autodb absent the slot renders its
  own placeholder (asserted in `[35] A16`).

### Durable silent-truncation guards added 2026-08-23

- **`section(fn)` xpcall wrapper** (smoke.lua ~L100): each of the 33
  top-level IIFE section bodies runs under `xpcall`; an uncaught Lua
  error becomes a COUNTED failure naming the section, and the suite
  keeps running. Converts an abort from invisible truncation into a
  visible `[<section> ABORTED]` FAIL. Catches the Lua-error class
  (e.g. the old p46 nil-buffer throw).
- **run-all.sh summary sentinel**: a suite whose output lacks its
  terminal `N passed, M failed` / `RESULT: …` marker is counted
  FAILED regardless of partial PASS lines. This is the ONLY thing that
  catches a C-level crash (SIGABRT/SIGSEGV), which `xpcall` cannot.
  Positive-controlled 2026-08-23 (a suite that errors before its
  summary → flagged).

---

## Watch list — every section that was NOT `live` before 2026-08-23

| section | file (before → after) | was | disposition | evidence |
|---|---|---|---|---|
| `[41]` automation diagnostics | smoke.lua → `smoke-automation.lua` | dark (SIGABRT truncation source) | **EXTRACT** — the malformed-template `vim.cmd("edit")` trips neovim-core `grid_line_flush` (grid.c:595) with smoke.lua's accumulated state; the isolated runner must also preserve natural headless geometry because either copied synthetic option corrupts Neovim 0.12.2 | 36/0 in the isolated suite; geometry-preservation assertion is mutation-verified |
| `[42]` `s`-modal scaffold | smoke.lua → `smoke-automation.lua` | dark (behind [41]) | **EXTRACT** (+ scaffolding fix: `:vsplit` inherited winfixbuf from the panel current-win; cleared it) | 36/0 |
| `[45]` worktree:switched | smoke.lua → `smoke-adr0044.lua` | 5 env-fails (panel not materialised) | **ISOLATE** — passes 6/0 in a fresh process | 6/0 in the new suite |
| `[46]` views.tests | smoke.lua (removed) → `smoke-adr0048.lua` | 2 fails + p46 nil-buffer ABORT (the headline truncation) | **CONSOLIDATE** — duplicate of the passing adr0048 copy; smoke.lua copy removed, adr0048 is now canonical | adr0048 146/0 |
| `[47]` views.debug | smoke.lua (removed) → `smoke-adr0048.lua` | passed in smoke but a sync-hazard duplicate | **CONSOLIDATE** with [46] | adr0048 146/0 |
| `[49]` dbase.tree toggle | smoke.lua (reimplemented in place) | 3 fails | **REIMPLEMENT** — `_toggle` now gates on `row.expandable` (a flag on chevron rows, tree.lua ~L230), not `kind`; a nil row returns `false` not `nil`. Invariant unchanged; row shape moved | smoke 672/0 |
| `smoke-adr0048` p47 `d`-delete (×10) | `smoke-adr0048.lua` (pruned) | 10 fails | **PRUNE** — the breakpoint-delete surface was deliberately removed in `73b2293` ("views.debug: … drop delete surface"); `d` now means DEBUG. Rendering assertions (typed rows, file/section headers, orphaned marker) kept | commit `73b2293`; adr0048 146/0 |

**No `dark`, `stale`, or `pty-required` sections remain.**

---

## Panel-materialisation: isolation, NOT pty

The KB todo hypothesised the panel-not-materialising sections
([45]/[46]) would need a real UI under `script -qec` (the way
auto-core's `tests/ui/run.sh` supplies one). **Investigated and
disproved 2026-08-23:** the identical [46] code passes under plain
`nvim --headless` in `smoke-adr0048.lua`, and [45] passes 6/0 in a
fresh headless process. The failures were caused by smoke.lua's
ACCUMULATED window state (~45 prior sections of panel churn), not by
the absence of a UI. **Process isolation is the fix; no pty harness was
built.** If a future section genuinely needs UI events (`WinScrolled`,
real redraw timing) that headless cannot provide, THAT is when to add
the `script -qec` harness — record it here as `pty-required` first.

---

## Standalone-vs-consolidated: the shape decision

The standalone count grew because appending to smoke.lua is unreliable
for two distinct reasons, now understood:

1. **C-crash on the malformed-template edit** ([41]/[41b]) — must be
   isolated so it cannot truncate the rest.
2. **Panel won't materialise late in a long run** ([45]/[46]) — must
   run early / in a fresh process.

Both point the same way: **panel-heavy and crash-prone sections belong
in fresh-nvim standalones; the pure-logic bulk stays in smoke.lua.**
That is the shape this turn settled on. smoke.lua keeps everything that
runs deterministically to completion (672 assertions) and reaches its
summary cleanly; the standalones each own one fragile concern and are
all wired into `run-all.sh`.


## Retired coverage — nvim-dbee removal (v0.4.0)

`dbase_spike.lua` (101) and `encrypted_vault_smoke.lua` (54) were **deleted**,
along with `smoke.lua` §[23] (47), §[35] A16b (~13), the second §[50] (2),
§[43] 43e (3), and `adr0060-r1-view-lifecycle.lua` §[4]/§[6] (15). Roughly 235
assertions in total.

They covered nvim-dbee: the drawer window contract, `dbee.setup` ownership and
config forwarding, companion editor/result/call_log panes, the plaintext and
encrypted (age/gpg) connection stores, and the autodb-vs-dbee ownership latch on
the dbase slot. dbee was retired in AutoVim v0.4.0
([[0063-autovim-single-branch-runtime-platform-detection]] / autodb roadmap M8),
and every module under test went with it.

**This is a deliberate reduction, not a regression.** The behaviour that
survived is still pinned:

- dbase's no-backend path — `smoke.lua` §[35] A16, which also asserts the
  placeholder never mentions dbee.
- the autodb explorer itself — `smoke.lua` §[49] (16 assertions).
- the ownership latch — `adr0060-r1-view-lifecycle.lua` §[1]/§[2]/§[3]/§[5],
  via the **repos** slot, which still has two implementations.

Connection storage, encryption and users are now autodb's, tested in that repo.

Totals after removal: **881** across 8 suites (was 1113 across 10).
