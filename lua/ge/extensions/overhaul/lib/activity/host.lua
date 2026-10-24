-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Activity host: an instance keeps the activity definitions registered with it and delegates to the owners' existing
-- functions. It never decides who may start, settles, saves or releases anything, and dispatches no lifecycle hook.

local definition = require('overhaul/lib/activity/definition')
local transitions = require('overhaul/lib/activity/transitions')

local M = {}

local RESOURCE_MODULES = {
  route = 'overhaul/lib/activity/resources/route',
  traffic = 'overhaul/lib/activity/resources/traffic',
  timer = 'overhaul/lib/activity/resources/timer',
  tasklist = 'overhaul/lib/activity/resources/tasklist',
  parking = 'overhaul/lib/activity/resources/parking',
  input = 'overhaul/lib/activity/resources/input',
  camera = 'overhaul/lib/activity/resources/camera',
}
M.RESOURCE_MODULES = RESOURCE_MODULES

local function pack(...) return {n = select('#', ...), ...} end

-- Each step takes the instance's registry: {options, definitions, order, resourceSets}.

local function register(registry, activityDef)
  local ok, errors = definition.validate(activityDef)
  if not ok then return false, errors end
  if registry.definitions[activityDef.id] then
    return false, {"activity " .. activityDef.id .. " is already registered"}
  end
  if activityDef.parent ~= nil and not registry.definitions[activityDef.parent] then
    return false, {"parent " .. activityDef.parent .. " of " .. activityDef.id .. " is not registered"}
  end
  registry.definitions[activityDef.id] = definition.copy(activityDef)
  registry.order[#registry.order + 1] = activityDef.id
  return true
end

-- A reload retains registration order, children and resource adapters.
local function replace(registry, activityDef)
  local ok, errors = definition.validate(activityDef)
  if not ok then return false, errors end
  local old = registry.definitions[activityDef.id]
  if not old then return false, {"activity " .. activityDef.id .. " is not registered"} end
  if activityDef.parent ~= old.parent then return false, {"activity " .. activityDef.id .. " cannot change its parent"} end
  registry.definitions[activityDef.id] = definition.copy(activityDef)
  return true
end

local function unregister(registry, id)
  if not registry.definitions[id] then return false end
  for _, other in ipairs(registry.order) do
    if registry.definitions[other].parent == id then
      return false, {"activity " .. other .. " is a child of " .. id}
    end
  end
  registry.definitions[id] = nil
  for i, registeredId in ipairs(registry.order) do
    if registeredId == id then table.remove(registry.order, i) break end
  end
  local set = registry.resourceSets[id]
  registry.resourceSets[id] = nil
  return true, set
end

local function children(registry, id)
  local out = {}
  for _, other in ipairs(registry.order) do
    if registry.definitions[other].parent == id then out[#out + 1] = other end
  end
  return out
end

-- Dispatch in registration order and propagate owner errors unchanged.
local function dispatch(registry, transition, ...)
  assert(transitions.NAMES[transition], "unknown transition " .. tostring(transition))
  local handled, results = {}, {}
  for _, id in ipairs(registry.order) do
    local activityDef = registry.definitions[id]
    local handler = activityDef and activityDef.transitions and activityDef.transitions[transition]
    if handler then
      handled[#handled + 1] = id
      results[id] = pack(handler(...))
    end
  end
  return handled, results
end

-- Keep each adapter until its activity is unregistered or the host expires.
local function resources(registry, id)
  if not registry.definitions[id] then return nil end
  local set = registry.resourceSets[id]
  if not set then
    set = setmetatable({}, {__index = function(cache, kind)
      local path = (registry.options.resourceModules or RESOURCE_MODULES)[kind]
      if not path then return nil end
      local adapter = require(path).create(id)
      rawset(cache, kind, adapter)
      return adapter
    end})
    registry.resourceSets[id] = set
  end
  return set
end

-- Creates a host with its own registry. opts.resourceModules optionally replaces RESOURCE_MODULES (tests).
function M.new(opts)
  local registry = {options = opts or {}, definitions = {}, order = {}, resourceSets = {}}
  local host = {}

  -- Validated and copied; returns true, or false and the errors.
  function host.register(activityDef) return register(registry, activityDef) end
  -- Swaps a registered activity's definition; the parent may not change.
  function host.replace(activityDef) return replace(registry, activityDef) end
  function host.unregister(id) return unregister(registry, id) end
  function host.get(id) return registry.definitions[id] end
  function host.has(id) return registry.definitions[id] ~= nil end
  function host.children(id) return children(registry, id) end
  -- Each registered handler for the transition, in registration order, with the hook's own arguments.
  function host.dispatch(transition, ...) return dispatch(registry, transition, ...) end
  -- Per-activity resource adapters, created on first use.
  function host.resources(id) return resources(registry, id) end

  function host.list()
    local out = {}
    for i, id in ipairs(registry.order) do out[i] = id end
    return out
  end

  -- Delegates to the owner's existing action and returns exactly what it returns.
  function host.action(id, name, ...)
    local activityDef = registry.definitions[id]
    local action = activityDef and activityDef.actions and activityDef.actions[name]
    if not action then return nil end
    return action(...)
  end

  function host.project(id)
    local activityDef = registry.definitions[id]
    if not activityDef or not activityDef.state then return nil end
    return activityDef.state()
  end

  function host.isActive(id)
    local activityDef = registry.definitions[id]
    if not activityDef or not activityDef.probe then return false end
    return activityDef.probe() == true
  end

  function host.canStart(id, otherId)
    local activityDef = registry.definitions[id]
    if not activityDef or not activityDef.canStart then return true end
    return activityDef.canStart(otherId) ~= false
  end

  return host
end

return M
