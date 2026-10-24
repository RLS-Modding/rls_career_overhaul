-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Reads per-tick odometers and integrity from stock part tags without collecting unused visual conditions.
-- Returns nil for unsupported layouts so callers fall back to stock getConditions().
local M = {}

local max, min = math.max, math.min

local resolvedFor
local resolved

local function upvalueIndex(fn, wanted)
  for index = 1, 255 do
    local name = debug.getupvalue(fn, index)
    if name == nil then return nil end
    if name == wanted then return index end
  end
end

local function resolve(getConditions)
  if resolvedFor == getConditions then return resolved end
  resolvedFor, resolved = getConditions, false
  if type(getConditions) ~= "function" or type(debug) ~= "table" or type(debug.getupvalue) ~= "function" then
    return resolved
  end
  local layout = {
    initDone = upvalueIndex(getConditions, "hasExecutedInitWork"),
    setParts = upvalueIndex(getConditions, "hasSetPartCondition"),
    parts = upvalueIndex(getConditions, "activeParts"),
    getCondition = upvalueIndex(getConditions, "getCondition"),
  }
  if not (layout.initDone and layout.setParts and layout.parts and layout.getCondition) then return resolved end
  local _, getCondition = debug.getupvalue(getConditions, layout.getCondition)
  if type(getCondition) ~= "function" then return resolved end
  layout.bases = upvalueIndex(getCondition, "partOdometerAbsoluteBaseValues")
  layout.starts = upvalueIndex(getCondition, "partOdometerRelativeStartingValues")
  layout.applied = upvalueIndex(getCondition, "lastAppliedPartConditions")
  layout.tags = upvalueIndex(getCondition, "partTypeData")
  if not (layout.bases and layout.starts and layout.applied and layout.tags) then return resolved end
  resolved = layout
  return resolved
end

local function readTables(getConditions)
  local layout = resolve(getConditions)
  if not layout then return nil end
  local get = debug.getupvalue
  local _, initDone = get(getConditions, layout.initDone)
  local _, setParts = get(getConditions, layout.setParts)
  local _, parts = get(getConditions, layout.parts)
  local _, getCondition = get(getConditions, layout.getCondition)
  if type(setParts) ~= "table" or type(parts) ~= "table" or type(getCondition) ~= "function" then return nil end
  local _, bases = get(getCondition, layout.bases)
  local _, starts = get(getCondition, layout.starts)
  local _, applied = get(getCondition, layout.applied)
  local _, tags = get(getCondition, layout.tags)
  if type(bases) ~= "table" or type(starts) ~= "table" or type(applied) ~= "table" or type(tags) ~= "table" then
    return nil
  end
  return initDone, setParts, parts, getCondition, bases, starts, applied, tags
end

-- A part's tag list split once, the way each stock reader splits it.
local parsedByTags = setmetatable({}, {__mode = "k"})

local function parseTags(partTags)
  local parsed = parsedByTags[partTags]
  if parsed then return parsed end
  parsed = {powertrain = {}, energyStorage = {}, breakGroups = {}, damageableBeams = {}, hasFlexbodies = false}
  for _, partType in ipairs(partTags) do
    local pieces = split(partType, ":")
    if pieces[1] == "powertrainDevice" then
      table.insert(parsed.powertrain, partType)
    elseif pieces[1] == "energyStorage" then
      table.insert(parsed.energyStorage, partType)
    elseif pieces[1] == "jbeam" then
      if pieces[2] == "breakGroup" then table.insert(parsed.breakGroups, pieces[3]) end
      if pieces[2] == "flexbody" then parsed.hasFlexbodies = true end
      if pieces[2] == "beamDamage" then table.insert(parsed.damageableBeams, tonumber(pieces[3])) end
    end
  end
  parsedByTags[partTags] = parsed
  return parsed
end

-- beamstate.getPartCondition, reading the same tables without re-splitting the tags.
local function jbeamCondition(parsed, beamDamageTracker, brokenBreakGroups)
  local partCondition = {integrityValue = 1, integrityState = {}, visualValue = 1, visualState = {}}
  local breakGroupCount = #parsed.breakGroups
  local brokenBreakGroupCount = 0
  for _, breakGroupName in ipairs(parsed.breakGroups) do
    if brokenBreakGroups[breakGroupName] then brokenBreakGroupCount = brokenBreakGroupCount + 1 end
  end
  local damageableBeams = parsed.damageableBeams
  if parsed.hasFlexbodies and (breakGroupCount > 0 or #damageableBeams > 0) then
    local brokenBeamCount = 0
    local deformedBeamCount = 0
    for _, beamCid in ipairs(damageableBeams) do
      local beamDamage = beamDamageTracker[beamCid] or 0
      if beamDamage >= 0.01 then deformedBeamCount = deformedBeamCount + 1 end
      if beamDamage >= 0.9 then brokenBeamCount = brokenBeamCount + 1 end
    end
    local tooMuchBeamDamage = deformedBeamCount > (#damageableBeams * 0.01)
    local tooManyBrokenBeams = brokenBeamCount > 2
    local tooManyBreakGroupsBroken = breakGroupCount > 0 and
      (brokenBreakGroupCount > 1 or (brokenBreakGroupCount == breakGroupCount))
    if tooManyBreakGroupsBroken or tooMuchBeamDamage or tooManyBrokenBeams then
      partCondition.visualState.needsReplacement = true
      partCondition.integrityValue = 0
      return partCondition, true
    end
  end
  return partCondition, false
end

-- Uncovered integrity values defer to stock paint and spawn conditions.
local function integrityEntry(partTags, odometerValue)
  local beamDamageTracker = beamstate and beamstate.deformedBeams
  local brokenBreakGroups = beamstate and beamstate.brokenBreakGroups
  if type(partTags) ~= "table" or type(beamDamageTracker) ~= "table" or type(brokenBreakGroups) ~= "table" then
    return nil
  end
  local parsed = parseTags(partTags)
  local powertrainCondition, hasPowertrain = powertrain.getPartCondition(parsed.powertrain)
  local energyStorageCondition, hasEnergyStorage = energyStorage.getPartCondition(parsed.energyStorage)
  local jbeam, hasJbeam = jbeamCondition(parsed, beamDamageTracker, brokenBreakGroups)
  if not (hasPowertrain or hasEnergyStorage or hasJbeam) then return nil end
  return {
    odometer = odometerValue,
    integrityValue = min(powertrainCondition.integrityValue, energyStorageCondition.integrityValue, jbeam.integrityValue),
    integrityState = {
      powertrain = hasPowertrain and powertrainCondition.integrityState or nil,
      energyStorage = hasEnergyStorage and energyStorageCondition.integrityState or nil,
      jbeam = hasJbeam and jbeam.integrityState or nil
    }
  }
end

-- Keep omitted spawn-conditioned parts absent until the next full condition pass.
local omitted = {}

function M.noteFullConditions(conditions)
  local source = partCondition and partCondition.getConditions
  local initDone, _, parts, _, _, _, applied = readTables(source)
  omitted = {}
  if not initDone or type(conditions) ~= "table" then return end
  for partId in pairs(parts) do
    if applied[partId] and conditions[partId] == nil then omitted[partId] = true end
  end
end

-- Odometer-only entries are reused between ticks; callers read them within the tick.
local odometerEntries = {}

-- False preserves stock's empty-condition result; nil requests a full condition pass.
function M.build(integrityParts)
  local source = partCondition and partCondition.getConditions
  local odometer = extensions.odometer
  if type(odometer) ~= "table" or type(odometer.getRelativeRecording) ~= "function" then return nil end
  if type(split) ~= "function" or type(powertrain) ~= "table" or type(energyStorage) ~= "table" then return nil end
  local initDone, setParts, parts, getCondition, bases, starts, applied, tags = readTables(source)
  -- Before its first pass getConditions prepares the part data itself.
  if not initDone then return nil end
  if next(setParts) == nil then return false end
  local result = {}
  local recording = odometer.getRelativeRecording()
  for partId in pairs(parts) do
    if applied[partId] and not omitted[partId] then
      local odometerValue = (bases[partId] or 0) + max(recording - (starts[partId] or 0), 0)
      if integrityParts and integrityParts[partId] then
        local ok, entry = pcall(integrityEntry, tags[partId], odometerValue)
        if ok and entry == nil then ok, entry = pcall(getCondition, partId) end
        if ok then result[partId] = entry end
      else
        local entry = odometerEntries[partId]
        if not entry then
          entry = {}
          odometerEntries[partId] = entry
        end
        entry.odometer = odometerValue
        result[partId] = entry
      end
    end
  end
  return result
end

return M
