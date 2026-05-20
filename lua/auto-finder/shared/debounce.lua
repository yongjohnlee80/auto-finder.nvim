---auto-finder.shared.debounce — reusable debounce helper.
---
---Two of the auto-finder modules grew their own copy of the
---"cancel + reschedule on each call" coalescer: `shared/neotree.lua`
---uses a 150 ms coalescer to collapse refresh storms before
---calling `manager.refresh`, and `core/init.lua`'s file-event
---translator uses a 100 ms coalescer to batch burst publishes.
---Phase 8 extracts that pattern into a single helper so future
---debounce-needing modules share the implementation.
---
---Single shape:
---
---  debounce.coalesce(fn, ms)
---
---Returns a callable. Each call cancels any prior pending fire
---and reschedules `fn` to run after `ms` milliseconds. After
---`fn` runs the timer is cleared; the next call starts a fresh
---window. Idempotent on rapid invocation.
---
---Optional second return is a `cancel` function that drops the
---pending fire without firing `fn`. Used by core/init.lua's
---test-only `_flush_file_events_for_tests` helper.
---
---@module 'auto-finder.shared.debounce'

local M = {}

---Wrap `fn` in a coalescing debouncer with window `ms`.
---
---Implementation note: vim.defer_fn returns nil (it's
---vim.schedule_wrap'd internally), so the obvious
---`vim.fn.timer_stop(prior)` cancellation pattern is silently
---broken — `prior` is always nil. The audit log F8.1 captured
---this as a pre-existing bug across the codebase; Phase 8 fixes
---it here by using a generation counter instead of cancellation:
---each trigger bumps `pending_gen`; the deferred fire checks if
---its captured gen still matches; stale fires are no-ops. Same
---semantics, no leaky timer handles.
---@param fn function
---@param ms integer  debounce window in milliseconds
---@return fun(...) trigger, fun() cancel
function M.coalesce(fn, ms)
  if type(fn) ~= "function" then
    error("shared.debounce.coalesce requires a function")
  end
  if type(ms) ~= "number" or ms <= 0 then
    error("shared.debounce.coalesce requires ms > 0")
  end

  -- Monotonic generation. Each trigger bumps it; only the timer
  -- callback whose captured `my_gen` matches the LIVE
  -- `pending_gen` at fire time actually runs `fn`.
  local pending_gen = 0
  -- Args captured from the most recent call. fn fires with
  -- the last call's args (latest-wins debounce semantics).
  local pending_args = nil

  local function trigger(...)
    pending_gen = pending_gen + 1
    pending_args = { n = select("#", ...), ... }
    local my_gen = pending_gen
    vim.defer_fn(function()
      if my_gen ~= pending_gen then return end  -- stale; superseded
      local args = pending_args
      pending_args = nil
      if args then
        fn(unpack(args, 1, args.n))
      else
        fn()
      end
    end, ms)
  end

  local function cancel()
    -- Bumping the generation drops every in-flight deferred fire
    -- (their captured `my_gen` no longer matches).
    pending_gen = pending_gen + 1
    pending_args = nil
  end

  return trigger, cancel
end

return M
