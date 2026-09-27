# Files slot benchmark — before (the retired fork) vs after (ADR-0200)

Measured on VM43, 2026-09-27, by `tests/bench/run.sh` (driver: `tests/bench/files-panel.lua`), CI's
Neovim v0.12.5 tarball. **Before**: auto-finder `b6f2b11` with auto-core `5bba92e` (the fork's CI pin) and
autovim's `neo_tree` block. **After**: `feat/files-rebuild` @ `3d8e874` with auto-core #53 @ `0b1908e`.
Fixture: 4 git repos under a workspace repo, 4,445 directories, ~33k files, a 2,000-file `node_modules`
and a 500-file `build/`. Medians of 3 runs; each cell is before → after.

| scenario | dir reads | entries examined | git subprocesses | live watches | ms |
|---|---|---|---|---|---|
| setup | 4,446 → 0 | 37,341 → 0 | 0 → 0 | 4,445 → 0 | 190 → 0 |
| mount | 2 → 1 | 10 → 5 | 0 → 3 | 4,445 → 2 | 72 → 330 |
| follow a deep file | 6 → 4 | 57 → 47 | 0 → 2 | 4,445 → 8 | 107 → 405 |
| toggle x20 | 50 → 40 | 250 → 416 | 0 → 2 | 4,445 → 8 | 1,894 → 1,969 |
| :w x20 | 36 → 1 | 342 → 8 | 0 → 2 | 4,445 → 8 | 1,064 → 1,288 |
| 5000 creates, collapsed dir | 0 → 0 | 0 → 0 | 0 → 0 | 4,445 → 8 | 0 → 0 |
| git add + commit | 0 → 0 | 0 → 0 | 0 → 1 | 4,445 → 8 | 31 → 384 |
| hidden: 200 writes | 0 → 0 | 0 → 0 | 0 → 0 | 4,445 → 0 | 0 → 0 |

Columns: **dir reads** = `uv.fs_scandir` + `uv.fs_opendir` calls; **entries examined** = names returned by
`fs_scandir_next` / `fs_readdir`; **git subprocesses** = git spawns, once per spawn; **live watches** =
`fs_event` handles alive at the end of the scenario (`uv.walk`); **ms** = from the scenario's first
action until the counters stop moving.

## Reading it

- **The resource win is the watch set and startup.** The fork walked all 4,445 directories at setup
  (37k entries) to arm a recursive watch, and then held 4,445 inotify handles for the whole session —
  shown or hidden. The rebuilt slot holds one handle per expanded directory (2–8 here) plus one narrow
  `git.watch`, and **zero** while hidden.
- **`:w` ×20**: 36 → 1 directory reads. A write to a file the tree already lists refreshes colours only.
- **Toggle ×20**: both are bounded (the fork by its throttles, the rebuild by `fs.scan`'s 250 ms interval
  over the 5 expanded directories). The rebuild re-reads on show by design (rationale §R8), so it
  examines more entries here; it can never reach a directory that is not expanded.
- **Git subprocesses are new on purpose.** The fork's git colouring could not run on shipped auto-core
  (rationale §R7), so "before" spawns none and shows no colours. The rebuild's cost is about one status
  read per settled change per shown repo; the toggle storm costs 2, not one per toggle.
- **ms** for the rebuild includes the 300 ms settle before its git read, which the fork did not have.
  It is time until the work stops, not time until the tree is painted (the tree paints on the first read).
- **5,000 creates in a collapsed directory** and **200 writes while hidden** cost nothing in either. The
  fork already skipped them (ADR-0059/0060) but paid for the 4,445 handles delivering the events.
