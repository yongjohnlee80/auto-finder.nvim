# Parity goldens — provenance (ADR-0200 §5 cell 1)

Produced by RUNNING the neo-tree fork renderer, never composed by hand. Harness: `tests/parity/capture.lua`.

| Run | Where | auto-finder | auto-core | Scenarios | Result |
|---|---|---|---|---|---|
| capture | VM43 `~/agents-review-and-tests/auto-finder-adr0200-capture-4b462f6/` | bac3db7 | 021b022 (`preserve/git-read-wip`) | all seven | written here |
| provenance | VM43 `~/agents-review-and-tests/auto-finder-adr0200-capture-4b462f6/prov/` | bac3db7 | ceb3945 (main, shipped) | files-w38-nogit, buffers-w38, buffers-w70, marks-w38 | byte-identical (`cmp`) |

- **Git scenarios** (`*-git*`) are a REFERENCE for the fork's intended filename colouring, not a
  shipped-runtime observation: on shipped auto-core the fork's git path throws, because
  `auto-core.git.repo.discover` / `discover_async` exist only at 021b022 (ADR-0200 rationale §R7). They
  switch on `enable_git_status`, `git_status_async = false` and `name.use_git_status_colors`, the fork's
  colouring as it was before ADR-0060 §2.8 (66ffaf4).
- **Non-git scenarios** reproduce byte-for-byte on shipped auto-core main.
- Every golden carries `win`, the window-local look (cursorline, `winhighlight` → `NeoTree*` groups, nowrap,
  nonumber, …). The fork applies it on BufEnter to EVERY filetype=auto-finder buffer, so `marks-w38` is the
  witness that views with their own renderer depend on it too (ADR-0200 rationale §R10).
- Icons: mini.icons f642e3b (nvim-web-devicons mock). Colours: catppuccin edefef7, flavour mocha. nvim 0.12.5.
- No `[+]` marker appears although `docs/readme.md` carries an unsaved edit made after mount: the fork
  never paints one in panel mode (ADR-0200 rationale §R9).
- Refresh rule: re-run the harness and the provenance comparison together, and never `rsync --delete` this
  directory back from VM43 — this file is local-only there.
