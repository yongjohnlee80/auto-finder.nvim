local utils = require("auto-finder.neotree.utils")
local log = require("auto-finder.neotree.log")
local Queue = require("auto-finder.neotree.collections").Queue

---@type table<string, neotree.collections.Queue?>
local event_queues = {}
---@type table <string, neotree.event.Definition?>
local event_definitions = {}
local M = {}

---@class neotree.event.Handler.Result
---@field handled boolean?

---@class neotree.event.Handler
---@field event neotree.EventName|string
---@field handler fun(table?):(neotree.event.Handler.Result?)
---@field id string?

local typecheck = require("auto-finder.neotree.health.typecheck")
local validate = typecheck.validate
---@param event_handler neotree.event.Handler
local validate_event_handler = function(event_handler)
  return validate("event_handler", event_handler, function(eh)
    validate("event", eh.event, "string")
    validate("handler", eh.handler, "function")
  end)
end

M.clear_all_events = function()
  for event_name, queue in pairs(event_queues) do
    M.destroy_event(event_name)
  end
  event_queues = {}
end

---count_subscribers reports how many handlers are registered for `event_name`.
---
---`event_queues` is a module local, so before this existed there was no way to
---observe it from outside: auto-finder's files-panel benchmark reached for
---`rawget(events, "subscriptions")`, found nothing, and reported an empty
---neo-tree census BOTH before and after the ADR-0060 git-subscription removal.
---That reading was an artifact, not a measurement, and it sat inside the
---evidence for the removal (ADR-0060 r1 SF5). An assertion is only worth
---hanging on a number something can actually observe.
---
---Read-only and allocation-free; 0 for an event nobody has subscribed to.
---@param event_name neotree.EventName|string
---@return integer
M.count_subscribers = function(event_name)
  local queue = event_queues[event_name]
  if not queue or not queue._list then return 0 end
  return queue._list.size or 0
end

---subscribed_events lists every event name that currently has a queue, so a
---census can assert on what IS registered rather than only probing names it
---already thought to ask about.
---@return string[]
M.subscribed_events = function()
  local out = {}
  for name, queue in pairs(event_queues) do
    if queue and queue._list and (queue._list.size or 0) > 0 then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

---@class neotree.event.Definition
---@field teardown function?
---@field setup function?
---@field setup_was_run boolean?

---@param event_name neotree.EventName|string
---@param opts neotree.event.Definition
M.define_event = function(event_name, opts)
  local existing = event_definitions[event_name]
  if existing ~= nil then
    error("Event already defined: " .. event_name)
  end
  event_definitions[event_name] = opts
end

---@param event_name neotree.EventName|string
---@return boolean existed_and_destroyed
M.destroy_event = function(event_name)
  local existing = event_definitions[event_name]
  if existing == nil then
    return false
  end
  if existing.setup_was_run and type(existing.teardown) == "function" then
    local success, result = pcall(existing.teardown)
    if not success then
      log.error("Error in teardown for", event_name, ":", result)
    end
    existing.setup_was_run = false
  end
  event_queues[event_name] = nil
  return true
end

---@param event neotree.EventName|string
---@param args table
local fire_event_internal = function(event, args)
  local queue = event_queues[event]
  if queue == nil then
    return nil
  end

  if queue:is_empty() then
    --log.trace("Event queue is empty")
    return nil
  end
  log.trace("Firing event:", event, "with args:", args)
  local seed = utils.get_value(event_definitions, event .. ".seed")
  if seed ~= nil then
    local success, result = pcall(seed, args)
    if success and result then
      log.trace("Seed for", event, "returned: ", result)
    elseif success then
      log.trace("Seed for", event, "returned falsy, cancelling event")
    else
      log.error("Error in seed function for", event .. ": ", result)
    end
  end

  return queue:for_each(function(event_handler)
    local remove_node = event_handler == nil or event_handler.cancelled
    if not remove_node then
      local success, result = pcall(event_handler.handler, args)
      local id = event_handler.id or event_handler
      if success then
        log.trace("Handler", id, "for", event, "called successfully.")
      else
        log.at.error.format("Error in event handler for event %s[%s]: %s", event, id, result)
      end
      if event_handler.once then
        event_handler.cancelled = true
        return true
      end
      return result
    end
  end)
end

---@param event neotree.EventName|string
---@param args any?
M.fire_event = function(event, args)
  local freq = utils.get_value(event_definitions, event .. ".debounce_frequency", 0, true)
  local strategy = utils.get_value(event_definitions, event .. ".debounce_strategy", 0, true)
  if freq > 0 then
    utils.debounce("EVENT_FIRED: " .. event, function()
      fire_event_internal(event, args or {})
    end, freq, strategy)
  else
    return fire_event_internal(event, args or {})
  end
end

---@param event_handler neotree.event.Handler
M.subscribe = function(event_handler)
  validate_event_handler(event_handler)

  local queue = event_queues[event_handler.event]
  if queue == nil then
    log.debug("Creating queue for event:", event_handler.event)
    queue = Queue:new()
    local def = event_definitions[event_handler.event]
    if def and type(def.setup) == "function" then
      local success, result = pcall(def.setup)
      if success then
        def.setup_was_run = true
        log.debug("Ran setup for event", event_handler.event)
      else
        log.error("Error in setup for", event_handler.event, ":", result)
      end
    end
    event_queues[event_handler.event] = queue
  end
  log.debug("Adding event handler [", event_handler.id, "] for event:", event_handler.event)
  queue:add(event_handler)
end

---@param event_handler neotree.event.Handler
M.unsubscribe = function(event_handler)
  local queue = event_queues[event_handler.event]
  if queue == nil then
    return nil
  end
  queue:remove_by_id(event_handler.id or event_handler)
  if queue:is_empty() then
    M.destroy_event(event_handler.event)
    event_queues[event_handler.event] = nil
  else
    event_queues[event_handler.event] = queue
  end
end

return M
