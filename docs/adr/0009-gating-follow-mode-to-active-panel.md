# ADR: Gating Follow-Mode Reveals to Active Panel

## 1. Objective and Motivation
In `auto-finder.nvim`, "follow mode" (files-follow and repos-follow) is a feature that automatically reveals the currently active buffer in the explorer tree. However, a bug was identified where these follow-mode triggers would hijack the panel UI. If a user was viewing the "buffers" or "repos" panel and opened a file, the files-follow `BufEnter` autocmd would fire and forcefully re-render the panel as the "files" section to show the revealed node. This interrupted the user's intent to stay in their chosen panel view.

## 2. Key Files & Context
* **`auto-finder.nvim/lua/auto-finder/init.lua`:** Contains the `BufEnter` autocmd factory functions (`_install_files_follow_autocmd` and `_install_repos_follow_autocmd`).
* **`auto-finder.nvim/lua/auto-finder/sections/init.lua`:** Manages the section registry and numeric indices.

## 3. Proposed Solution
The solution is to add an "active-section guard" to every follow-mode trigger. Before executing a reveal/follow command, the handler must check if its corresponding section is the one currently active in the panel (`M.state.section`).

### 3.1 Files Follow Guard
In `_install_files_follow_autocmd`, the `fire` function now resolves the index of the "files" section and compares it against `M.state.section`.
```lua
local files_idx = require("auto-finder.sections")._by_name["files"]
if M.state and M.state.section ~= files_idx then return end
```

### 3.2 Repos Follow Guard
Similarly, in `_install_repos_follow_autocmd`, the `reveal` function checks the "repos" index:
```lua
local repos_idx = require("auto-finder.sections")._by_name["repos"]
if M.state and M.state.section ~= repos_idx then return end
```

## 4. Alternatives Considered
* **Disabling Follow Mode on Section Switch:** We considered disabling follow mode entirely when the user leaves the "files" section. However, the user might want follow mode to be "ready" as soon as they switch back to "files".
* **State-only Update (No UI change):** We considered allowing the follow mode to update its internal "last revealed" state without triggering a UI re-render. This was deemed unnecessarily complex compared to a simple early return guard.

## 5. Verification & Testing
* **Smoke Test Addition:** A new test case will be added to `tests/smoke.lua` that:
    1. Enables `files.follow`.
    2. Focuses the "buffers" section.
    3. Opens a new file buffer.
    4. Verifies that `M.state.section` remains focused on "buffers" and hasn't been hijacked by "files".
* **Manual Verification:** Toggle between panels and open files to ensure the active panel persists.

## 6. Implementation Status
Implemented and verified in branch `fix-files-follow-mode`.