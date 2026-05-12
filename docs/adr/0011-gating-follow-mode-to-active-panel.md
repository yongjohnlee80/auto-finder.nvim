---
type: adr
number: 0011
status: accepted
date: 2026-05-11
---

# ADR 0011 — Gating Follow-Mode Reveals to Active Panel

## Context
In `auto-finder.nvim`, "follow mode" (files-follow and repos-follow) is a feature that automatically reveals the currently active buffer in the explorer tree. However, these follow-mode triggers were hijacking the panel UI. If a user was viewing the "buffers" or "repos" panel and opened a file, the files-follow `BufEnter` autocmd would fire and forcefully re-render the panel as the "files" section to show the revealed node. This interrupted the user's intent to stay in their chosen panel view.

## Decision
Add an "active-section guard" to every follow-mode trigger. Before executing a reveal/follow command, the handler must check if its corresponding section is the one currently active in the panel (`M.state.section`).

### 1. Files Follow Guard
In `_install_files_follow_autocmd`, the `fire` function now resolves the index of the "files" section and compares it against `M.state.section`.
```lua
local files_idx = require("auto-finder.sections")._by_name["files"]
if M.state and M.state.section ~= files_idx then return end
```

### 2. Repos Follow Guard
Similarly, in `_install_repos_follow_autocmd`, the `reveal` function checks the "repos" index:
```lua
local repos_idx = require("auto-finder.sections")._by_name["repos"]
if M.state and M.state.section ~= repos_idx then return end
```

## Alternatives Considered
* **Disabling Follow Mode on Section Switch:** Considered disabling follow mode entirely when the user leaves the section, but keeping it "ready" for when they return is more useful.
* **State-only Update (No UI change):** Considered allowing the follow mode to update its internal "last revealed" state without triggering a UI re-render, but an early return guard is simpler and achieves the same goal.

## Consequences
- **Pros:** Panel view stability is preserved during file navigation; no unexpected section switching.
- **Cons:** User must manually switch back to the "files" section to see the revealed node if they were previously viewing a different panel.

## Verification Plan
Smoke test under section [19] of `tests/smoke.lua` must assert that the panel window's displayed buffer remains unchanged when a new file is opened while a different section (e.g., "buffers") is active.
```lua
local buffers_section = require("auto-finder.sections")._by_number[buffers_idx]
ok("panel window still displays buffers-section buffer",
  vim.api.nvim_win_get_buf(af.state.panel_winid) == buffers_section._bufnr)
```

For repos-follow, the same smoke section must also assert that an active repos section preserves the editor window and focuses the repos source's synthetic workspace node id:
```lua
local expected_repo_node = "auto-finder-repos://" .. vim.fn.getcwd()
ok("repos-follow focused containing repo node",
  focused_repo_node == expected_repo_node)
```

## Status
Implemented and verified. Smoke test [19] confirms that opening a file while the "buffers" section is active no longer swaps the panel buffer, and that repos-follow focuses the containing repo node without replacing the editor window.
