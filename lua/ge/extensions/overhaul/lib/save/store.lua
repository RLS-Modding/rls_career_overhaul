-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- SaveStore: binds owner persistence to the existing save pipeline and tracks unsafe lifetimes.
-- Writes keep the capture boundary: captured slot writes, immediate writes, and the key registry.

local keyRegistry = require('overhaul/lib/save/keyRegistry')

local M = {}

M.TRACE_LIMIT = 64

local trace = {}

local function record(entry)
  trace[#trace + 1] = entry
  if #trace > M.TRACE_LIMIT then table.remove(trace, 1) end
end

-- Manual, forced and named-save flags from saveCurrent's arguments, for the trace.
local function describe(arg2, arg3)
  local options = type(arg2) == "table" and arg2 or {}
  return options.manual == true or options.playSuccessSound == true or arg2 == true,
    options.force == true, options.saveName or arg3
end

-- Forwards the arguments untouched (same count), so saveCurrent sees exactly the old call.
local function requestOn(saveSystem, reason, ...)
  if type(reason) ~= "string" or reason == "" then
    log("W", "saveStore", "save request without a reason")
    reason = "unknown"
  end
  local accepted = nil
  if saveSystem.requestSave then
    accepted = saveSystem.requestSave(reason, ...)
  else
    accepted = saveSystem.saveCurrent(...)
  end
  local _, arg2, arg3 = ...
  local manual, force, saveName = describe(arg2, arg3)
  record({reason = reason, accepted = accepted, manual = manual, force = force, saveName = saveName})
  return accepted
end

-- Forward all save arguments unchanged; request tags describe existing save intent.
function M.request(reason, ...)
  return requestOn(overhaul_career_saveSystem, reason, ...)
end

-- The facade bound to the saveSystem table the caller sees, so a harness can route requests to its own table.
function M.bind(saveSystem)
  return {
    request = function(reason, ...)
      return requestOn(saveSystem, reason, ...)
    end,
    feature = function(key, descriptor)
      return require('overhaul/lib/save/feature').create(saveSystem, key, descriptor)
    end,
  }
end

-- Recent requests, oldest first (copies).
function M.getRequestTrace()
  local result = {}
  for i, entry in ipairs(trace) do
    result[i] = {reason = entry.reason, accepted = entry.accepted, manual = entry.manual,
      force = entry.force, saveName = entry.saveName}
  end
  return result
end

function M.clearRequestTrace()
  trace = {}
end

-- A career-slot file written from a save hook or owner during capture.
function M.writeSlot(filename, obj, pretty, numberPrecision, tempFileName)
  return overhaul_career_saveSystem.jsonWriteFileSafe(filename, obj, pretty, numberPrecision, tempFileName)
end

-- Settings, migration and import writes cannot wait for the next career capture.
function M.writeNow(filename, obj, pretty, numberPrecision, tempFileName)
  return overhaul_career_saveSystem.jsonWriteFileSafe(filename, obj, pretty, numberPrecision, tempFileName)
end

-- The running capture's writer, or the direct one.
function M.writer()
  return overhaul_career_saveSystem.getSaveWriter()
end

-- Owners invoke the adapter at their existing save and restore boundaries.
function M.feature(key, descriptor)
  return require('overhaul/lib/save/feature').create(overhaul_career_saveSystem, key, descriptor)
end


M.registerKey = keyRegistry.register
M.registerKeys = keyRegistry.registerAll
M.discoverAddonKeys = keyRegistry.discoverAddonKeys
M.getKey = keyRegistry.get
M.keys = keyRegistry.list
M.keyForFile = keyRegistry.matchFile

-- Save holds live until their owner releases them, including refusal and teardown.
local active = {}
local count = 0

-- Returns a token whose release() ends this hold alone; options.stage picks the gate it blocks.
function M.hold(owner, reason, options)
  assert(type(owner) == 'table' or (type(owner) == 'string' and owner ~= ''), 'save hold needs an owner')
  assert(type(reason) == 'string' and reason ~= '', 'save hold needs a reason')
  local token = {}
  options = options or {}
  assert(type(options) == 'table', 'save hold options must be a table')
  assert(options.stage == nil or options.stage == 'beforeRoute' or options.stage == 'beforeRecovery'
    or options.stage == 'settlement', 'unknown save hold stage')
  assert(options.recover == nil or type(options.recover) == 'function', 'save hold recovery must be a function')
  active[token] = {owner = owner, reason = reason, stage = options.stage or 'settlement', recover = options.recover}
  count = count + 1
  function token.release()
    if not active[token] then return false end
    active[token] = nil
    count = count - 1
    return true
  end
  return token
end

-- Releases every hold of one owner, or all holds when no owner is given.
function M.releaseHolds(owner)
  for token, entry in pairs(active) do
    if owner == nil or entry.owner == owner then token.release() end
  end
end

-- True while any hold is up, or while a hold at this stage is up.
function M.isHeld(stage)
  if stage == nil then return count > 0 end
  for _, entry in pairs(active) do
    if entry.stage == stage then return true end
  end
  return false
end

-- Runs each hold's recovery; called once the earlier save gates have passed.
function M.recoverHolds()
  for _, entry in pairs(active) do
    if entry.recover then entry.recover() end
  end
end

return M
