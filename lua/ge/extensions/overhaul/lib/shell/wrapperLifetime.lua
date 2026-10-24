-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Owns reversible field bindings without disturbing a later wrapper from another mod.
-- Policies choose hook refresh and direct replacements; retired guarded wrappers pass through.
local M = {}

-- Metadata never refers back to its weak key: an abandoned wrapper can collect.
local wrappers = setmetatable({}, {__mode = 'k'})
local forwarders = setmetatable({}, {__mode = 'k'})

-- Explicit forwarding metadata lets cooperating profilers and owners share a field.
local function containsWrapper(current, replacement)
  if type(replacement) ~= 'function' then return false end
  while current do
    if current == replacement then return true end
    current = forwarders[current]
  end
  return false
end

-- Register only wrappers known to call original, before publishing them to a field.
-- Upvalue reachability alone cannot distinguish forwarding from a retained override.
function M.registerForwarder(wrapper, original)
  assert(type(wrapper) == 'function' and type(original) == 'function', 'forwarders need two functions')
  assert(forwarders[wrapper] == nil or forwarders[wrapper] == original, 'forwarding metadata is immutable')
  local current = original
  while current do
    assert(current ~= wrapper, 'forwarding metadata must not cycle')
    current = forwarders[current]
  end
  forwarders[wrapper] = original
  return wrapper
end

local function liveOriginal(original)
  local owner = wrappers[original]
  while owner and not owner.state.active do
    original = owner.original
    owner = wrappers[original]
  end
  return original
end

local function refreshHook(binding)
  if binding.notify and type(binding.key) == "string" and binding.key:sub(1, 2) == "on" then
    binding.notify(binding.key)
  end
end

local function guardReplacement(original, replacement, state)
  local function guarded(...)
    if state.active then return replacement(...) end
    if type(original) == "function" then return original(...) end
  end
  return guarded, function() replacement = nil end
end

function M.prepare(target, key, makeWrapper, options)
  options = options or {}
  local state = options.state or {active = true}
  local original = liveOriginal(target[key])
  local replacement, guarded = makeWrapper(original, target, state)
  local release
  if type(replacement) == "function" and guarded ~= true and options.guard ~= false then
    local wrapped = replacement
    replacement, release = (options.makeGuard or guardReplacement)(original, replacement, state)
    -- Keep only the original in metadata so retirement can release wrapped's owner.
    if not options.makeGuard and containsWrapper(wrapped, original) then
      M.registerForwarder(replacement, original)
    end
  end
  if type(replacement) == 'function' and replacement ~= original then
    wrappers[replacement] = {original = original, state = state}
  end
  return {target = target, key = key, original = original, replacement = replacement, state = state,
    notify = options.notify, release = release}
end

function M.install(binding)
  binding.target[binding.key] = binding.replacement
  refreshHook(binding)
end

function M.retire(binding, notify)
  binding.state.active = false
  if binding.release then binding.release(); binding.release = nil end
  if binding.target[binding.key] ~= binding.replacement then return false end
  -- An inner owner may have unloaded before this one. Do not restore its dead layer.
  binding.target[binding.key] = liveOriginal(binding.original)
  if notify ~= false then refreshHook(binding) end
  return true
end

function M.intact(binding)
  local current = binding.target[binding.key]
  -- Registered chains are acyclic, so the every-frame check allocates no tables.
  return current == binding.replacement or containsWrapper(current, binding.replacement)
end

-- Build every replacement before assigning any field, preserving the adapter's construction order.
local function prepareFields(target, wrappers, state, notify, makeGuard)
  local fields = {}
  for key, makeWrapper in pairs(wrappers) do
    fields[key] = M.prepare(target, key, makeWrapper, {state = state, notify = notify, makeGuard = makeGuard})
  end
  return fields
end

local function retireFields(applied)
  applied.state.active = false
  for _, binding in pairs(applied.fields) do M.retire(binding) end
end

local function fieldsIntact(applied)
  for _, binding in pairs(applied.fields) do
    if not M.intact(binding) then return false end
  end
  return true
end

function M.create(resolve, wrappers, notify, makeGuard)
  local applied
  local function uninstall()
    if not applied then return end
    retireFields(applied)
    applied = nil
  end
  local function install()
    if applied and resolve() == applied.target and fieldsIntact(applied) then return end
    uninstall()
    local target = resolve()
    if type(target) ~= "table" then return end
    local state = {active = true}
    local fields = prepareFields(target, wrappers, state, notify, makeGuard)
    applied = {target = target, fields = fields, state = state}
    for _, binding in pairs(fields) do M.install(binding) end
  end
  local function refresh()
    if applied and resolve() == applied.target and fieldsIntact(applied) then return end
    install()
  end
  return install, uninstall, refresh
end

return M
