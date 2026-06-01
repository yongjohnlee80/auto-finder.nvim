# AUTOMATION.md

Scheduled and event-driven task automation in `.todo-list/automated/`.

`auto-finder` (panel + diagnostics), `auto-core` (data model + engine), and `auto-agents` (slot resolver + terminal executor + mailbox surface) together ship an automation engine that fires cloned tasks from `.todo-list/automated/*.md` template files on cron schedules or event matches. This doc is the user-facing how-to.

Architectural context for the implementation lives in ADR-0035; this doc covers what you need to author and run automated tasks.

**Ships in:** `auto-core v0.1.49`, `auto-finder v0.2.48`, `auto-agents v0.2.49`.

---

## TL;DR

```vim
" 1. One-time per workspace — enable bash automation (interactive ack required).
:AutoAgentsTodosAutomationEnable

" 2. Drop a status: automated template under <workspace>/.todo-list/automated/<id>.md
"    See "Authoring" below.

" 3. Optionally fire it manually for testing.
:AutoAgentsTodos fire id=<template-id>

" 4. Watch fires in the auto-finder panel — Automated section + clones flowing
"    Open → In Progress → Completed.
```

The engine starts on `auto-agents.setup()` (typically editor startup). It does NOT require the auto-finder panel to be open — a `vim.uv.new_timer()` ticks every 30 seconds in the background regardless.

---

## When to use it

Use the automation engine for work that:

- **Runs on a schedule** — nightly backups, weekly digest jobs, "first Tuesday of every month" rituals.
- **Reacts to task events** — auto-assign new tasks to a reviewer, run a script when something flips to `completed`.
- **Is a recurring template** — the same shape every time, with each fire producing its own audit-trailed clone (one clone per fire; the template stays inert).

Skip it for:

- One-off scripts → run them in your shell.
- Tasks that don't fit a "clone per fire" model → use `todos.add` for ad-hoc work.
- Work that needs to run during Neovim startup → the engine isn't running yet during the `setup()` phase.

---

## Authoring an automated template

Templates live at `<workspace>/.todo-list/automated/<id>.md`. They use the same schema as other todo files; two fields turn a task into a template: `status: automated`, plus `condition:` + `execute:` lists.

### Minimal example

Every weekday at 09:00, assign the daily standup task to an agent named `lector`:

```yaml
---
id: "weekday-standup-assign"
version: 1
status: automated
title: "Weekday standup assignment"
description: "Assigns the standup brief to lector every weekday at 09:00."
created: "2026-05-31T00:00:00Z"
updated: "2026-05-31T00:00:00Z"
status_changed: "2026-05-31T00:00:00Z"
condition:
  - "0 9 * * 1-5"
execute:
  - "assign agent:lector"
---

# Weekday standup assignment

(Body content gets copied into each clone — add notes here the
assignee should see on every fire.)
```

The scheduler picks it up on the next 30-second tick and fires when the cron matches.

### Frontmatter fields specific to automation

| Field           | Required when           | Hand-editable | Notes |
|-----------------|-------------------------|--------------|-------|
| `condition`     | `status == automated`   | yes          | List of strings. AND-combined: every entry must be satisfied since `last_fired_at` for the template to fire. |
| `execute`       | `status == automated`   | yes          | List of step strings. Run sequentially; if a step fails, subsequent steps are skipped. |
| `origin`        | clones only (auto-set)  | NO           | Managed backref to the template id. The schema rejects `origin:` on automated templates. |
| `last_fired_at` | auto-set at fire-start  | NO           | Managed. Stamped BEFORE the chain runs so the debounce gate is durable while async work is in flight. |
| `exit_code`     | clones only (auto-set)  | NO           | Managed. Integer exit status of the fire's captured `bash` / `bash:<sec>` step (`0` on success, real code on failure). Absent when the fire had no captured bash step — terminal-routed `bash -t=N` records none. |

**Top-level `assignee:` on an automated template is REJECTED** with code `automation-template-assignee`. Templates are inert. To assign on every fire, use `execute: - assign agent:<name>` so the assignment runs on each clone instead of the template itself.

---

## `condition:` grammar

Each entry is either a **cron expression** or an **event reference**.

### Cron expressions (5-field)

| Field        | Range        | Notes |
|--------------|--------------|-------|
| minute       | 0..59        | |
| hour         | 0..23        | |
| day-of-month | 1..31        | |
| month        | 1..12        | |
| day-of-week  | 0..6 (Sun=0) | `7` accepted as a Sunday alias |

Tokens per field: `*`, `N`, `N-M`, `N,M,P`, `*/STEP`, `N-M/STEP`. Plus the **day-of-week ordinal `D#K`** (Kth occurrence of weekday D in the month): `2#1` = first Tuesday, `5#3` = third Friday, etc.

POSIX day-of-month + day-of-week semantics: if both are restricted, a day matches when EITHER matches (OR, not AND). If exactly one is restricted, that restriction decides. If both are `*`, every day matches.

Examples:

```
0 9 * * 1-5        # weekdays at 09:00
*/15 * * * *       # every 15 minutes
0 0 * * *          # daily at midnight
0 8 * * 2#1        # 08:00 on the first Tuesday each month
30 14 1 * *        # 14:30 on the 1st of every month
```

### Event references

`event:<topic>` — fires when the auto-core event bus publishes the matching topic since `last_fired_at`:

| Topic                  | Fires when |
|------------------------|------------|
| `event:new-task`       | any task transitions into `open` (created or moved from another bucket) |
| `event:task-completed` | any task transitions to `completed` |
| `event:task-archived`  | any task transitions to `archived` |
| `event:task-deferred`  | any task transitions to `deferred` |
| `event:assign:<agent>` | a task is assigned to `agent:<agent>` (e.g. `event:assign:lector`) |
| `event:assign:*`       | wildcard — fires on ANY assignment |

### Combining conditions

Conditions are **AND-combined**: `[cron, event:X]` fires only when the cron matches AND `event:X` has been observed since the last fire. Mix cron + events to write "if a new task arrives during business hours, ..." rules.

---

## `execute:` step grammar

Each step is a string matching one of the recognized primitives. Auto-core handles the first four directly; the next two are plugin-extended (auto-agents registers them at its setup time):

| Form                       | Owner       | Mechanism                                                   | Timeout       |
|----------------------------|-------------|-------------------------------------------------------------|---------------|
| `assign agent:<name>`      | auto-core   | `todo.assign(clone, "agent:<name>")` — fires notification   | n/a           |
| `assign user`              | auto-core   | `todo.assign(clone, "user")` — local-human sentinel; no mailbox | n/a       |
| `bash <cmd>`               | auto-core   | `vim.system` async, exit code captured into `exit_code`     | 1h default    |
| `bash:<sec> <cmd>`         | auto-core   | `vim.system` async, custom timeout in seconds               | `<sec>`s      |
| `assign slot:<N>`          | auto-agents | rewrite hook → resolves slot N → live agent name, then auto-core assign | n/a |
| `bash -t=<N> <cmd>` (1..4) | auto-agents | sends `<cmd>` to floating terminal T<N> via `auto-agents.term.send` | **none** (terminal owns lifecycle) |

Steps run **sequentially in declared order**. If any step fails, subsequent steps are skipped and the clone gets an `errors[]` entry with code `automation-step-failed`.

### `bash <cmd>` vs `bash -t=<N> <cmd>` — when to pick which

- **`bash <cmd>`** — unattended background scripts. Run via `vim.system`, so the process result is **captured**: the exit code lands in the clone's managed `exit_code:` field (`0` on success, the real code on failure), and stderr is folded into the clone's `errors[]` on a non-zero exit. On success the clone **auto-completes** (unless an earlier step assigned it to an agent — then the agent owns closing it). This is the default for a fresh scaffolded template.
- **`bash -t=<N>`** (N ∈ 1..4) — when the command should run in a **visible terminal window** under your eye. The text is injected + submitted via the floating-terminal stack; no timeout (the terminal session owns execution lifecycle). Because it runs in a live terminal the engine never reaps, there is **nothing to capture**: a `-t=` step records **no** `exit_code`, and "success" means the text was delivered to the terminal. The clone **completes on successful dispatch** (delivery accepted) — it does *not* wait for, or report, the eventual shell-command exit. If you need the actual command result recorded, use a captured `bash <cmd>` step instead.

---

## Bash trust gate (REQUIRED for any bash form)

Bash steps refuse to run until you've **interactively acknowledged** the trust prompt:

```vim
:AutoAgentsTodosAutomationEnable
```

This shows a `vim.fn.confirm` modal with the workspace path. Selecting "Yes" flips `bash_first_run_acknowledged` in the workspace state, then enables `bash_enabled = true`. **Mailbox callers cannot bootstrap this** — `todos.automation_set { bash_enabled = true }` returns `{code: trust_not_acknowledged}` until you ack interactively.

The point: `.todo-list/automated/` files are plain text, potentially checked into your project repo. Without the trust gate, opening a project with someone else's automated templates would let their bash commands run on your machine. The gate makes the trust decision explicit and per-workspace.

### Allowlist (optional)

Restrict which commands can run via a list of Lua-pattern prefixes:

```vim
:AutoAgentsTodos automation_set bash_allowlist={"^make ","^bash $WORKSPACE/scripts/"}
```

When set, only commands matching ≥1 pattern execute; non-matching steps fail with code `automation-bash-not-allowlisted`. The allowlist applies uniformly to both `bash <cmd>` and `bash -t=<N> <cmd>` (the command portion is checked after the `-t=N` flag is stripped).

To clear the allowlist:

```vim
:AutoAgentsTodos automation_set bash_allowlist=false
```

To disable bash entirely without removing the ack:

```vim
:AutoAgentsTodos automation_set bash_enabled=false
```

### Bypass for admins (host Lua only)

For one-off testing where you need to bypass the trust gate without flipping workspace state:

```lua
:lua require("auto-core.todo.automation").fire(
  "<template-id>",
  { bypass_bash_disabled = true, bypass_allowlist = true }
)
```

These bypass flags are **only reachable through the Lua API on the host**. The mailbox surface (`todos.fire`) rejects them uniformly — agents cannot bypass the trust gate.

---

## Firing manually (testing, one-offs)

```vim
:AutoAgentsTodos fire id=<template-id>
```

Returns `{clone_id, outcome, errors}` to `:messages`:

- `outcome = "ok"` — synchronous chain (only assigns / no bash). Clone is at its final state.
- `outcome = "in_flight"` — async chain (bash step kicked off). Clone is `in-progress`; subscribe to the `core.todo.automation:fired` event or check the clone later for the final state.
- `outcome = "failed"` — first step failed synchronously (trust gate, malformed step, unknown agent, ...). Clone has `errors[]` populated on disk.
- `outcome = "partial"` — a step succeeded then a later step failed. Earlier work landed; later steps skipped.

The `clone_id` is the canonical `<origin-id>--YYYYMMDDTHHMMSSZ` per-fire id.

---

## Observing fires in the panel

In the auto-finder todos panel:

- The **Automated** section lists every template. Rows for templates with bash steps show a `[bash:disabled]` indicator when `bash_enabled = false` for the workspace.
- On each fire, the clone shows up in **Open** (briefly) → **In Progress** (bumped at fire-start) → **Completed** (on success), or stays in **In Progress** with an `⚠ <N>` errors badge on failure. A clone that an `assign agent:` / `assign slot:` step handed to an agent stays **In Progress** for that agent to close. Clones whose fire ran a captured `bash` step also carry the recorded `exit_code` in their frontmatter.
- Per-bucket numbered indexes apply everywhere except `Archived` — so you can say "redo #3 in Completed" the same way you'd say "do #3 in Open".

The clone's body carries an automation trace section:

```markdown
## Automation trace
- Fired by: weekday-standup-assign
- Conditions matched:
  - `0 9 * * 1-5`
- Execute plan:
  1. `assign agent:lector`
```

---

## Real-time YAML diagnostics

Open any `.todo-list/automated/*.md` file in a buffer and auto-finder attaches a `vim.diagnostic` validator. The validator runs on `BufRead` / `BufNewFile` / `BufEnter` and revalidates on every `BufWritePost` + `TextChanged*` (200ms debounce).

Each malformed `condition[i]` / `execute[i]` entry surfaces as an in-buffer error diagnostic, line-precise to the offending `- <entry>` row. Same validator drives refresh-side `errors[]` population (so headless / mailbox callers see the same errors), so what you see in the buffer matches what the panel shows.

---

## Debugging failures

### "Why isn't my template firing?"

1. **Check `last_fired_at`** on the template. The scheduler debounces same-minute re-fires; if you JUST manually fired it, the cron won't re-fire that minute.
2. **Check the validator** — `auto-core.todo.refresh()` runs `automation.validate(task)` on every automated template; refresh-side errors land in `errors[]`. Open the file or look at the panel for the ⚠ badge.
3. **Edit the file in Neovim** — `.todo-list/automated/*.md` buffers get the live `vim.diagnostic` validator. Squiggly underlines point at the exact `- <entry>` line.

### "The bash step is refused"

Codes you might see in `errors[]`:

- `automation-bash-disabled` — workspace trust gate is off. Run `:AutoAgentsTodosAutomationEnable`.
- `automation-bash-not-allowlisted` — command doesn't match the `bash_allowlist` patterns. Either widen the allowlist or clear it.
- `automation-bash-t-no-resolver` — `bash -t=N` step but auto-agents isn't loaded.
- `automation-bash-t-range` — N out of 1..4. Floating terminals have only four slots.
- `automation-slot-no-resolver` — `assign slot:N` step but auto-agents isn't loaded.

### "Plugin-owned step (`assign slot:N` / `bash -t=N`) validates clean but fails at fire"

The auto-agents validators check syntax + range. Runtime failures (empty slot N, term.send returning false) only surface at fire-time. Check the clone's `errors[]` after the fire; the message includes the specific runtime reason ("no live agent in slot 5", "auto-agents.term.send returned false for slot 2", etc.).

### "How do I know when the scheduler last ran?"

```lua
:lua print(vim.inspect(require("auto-core.todo.automation").list_pending()))
```

Returns `{running, hooks, executors, events_satisfied}`. `running == false` means the engine isn't started (typically: auto-agents hasn't loaded). `events_satisfied` shows which events are currently staged for each template.

---

## Knobs + conventions

- **Scheduler tick**: 30 seconds. Sub-minute cron precision isn't supported.
- **Cron debounce**: same-minute re-fires are suppressed via `last_fired_at` (stamped at fire-START, durable while async work is in flight).
- **Clone lifecycle**:
  - Every fire bumps its clone `open → in-progress` at fire-start (before any step runs).
  - On success → clone **auto-completes**, UNLESS a step assigned it to an agent (`assign agent:` / `assign slot:`) — then it stays `in-progress` for that agent to close. (`assign user` does not block completion.)
  - Captured `bash <cmd>` / `bash:<sec>` steps record their `exit_code` (`0` on success, real code on failure). `bash -t=N` records none and completes on successful dispatch.
  - Any step fails → clone stays `in-progress` with `errors[]` populated (and the failing captured-bash step's `exit_code`).
- **Audit trail**: when `$AUTO_AGENTS_KB_ROOT` is set, every fire writes a `## [<ts>] automation-fire | origin=... clone=... outcome=...` line to `<kb>/log.md`. No-op when the env isn't set (auto-core stays KB-neutral).

---

## Quick reference

```vim
" Trust gate
:AutoAgentsTodosAutomationEnable                              " interactive ack + enable
:AutoAgentsTodos automation_set bash_enabled=false            " disable
:AutoAgentsTodos automation_set bash_allowlist={"^make "}     " restrict
:AutoAgentsTodos automation_set bash_allowlist=false          " clear restriction

" Fires
:AutoAgentsTodos fire id=<template-id>                        " manual fire (no bypass)

" Inspection
:AutoAgentsTodos list                                         " all open tasks
:AutoAgentsTodos list status=automated                        " just templates
:AutoAgentsTodos show id=<template-id>                        " full task dump
:AutoAgentsTodosDoc                                           " bootstrap doc with verb reference

" Lua API (host)
:lua require("auto-core.todo.automation").trust_state()       " current trust state
:lua require("auto-core.todo.automation").list_pending()      " engine snapshot
:lua require("auto-core.todo.automation").fire("<id>", {})    " programmatic fire
```

---

## See also

- [`README.md`](./README.md) — auto-finder feature overview
- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — internal architecture of the panel + view subsystem
- [`CHANGELOG.md`](./CHANGELOG.md) — version history (ADR-0035 implementation lands in v0.2.48)
- Companion repos:
  - [`auto-core.nvim`](https://github.com/yongjohnlee80/auto-core.nvim) (v0.1.49) — data model + automation engine + cron parser
  - [`auto-agents.nvim`](https://github.com/yongjohnlee80/auto-agents) (v0.2.49) — slot resolver + `bash -t=` executor + mailbox surface + trust-gate command