-- Condition compatibility: an empty subsystem integrity state is dropped so the numeric integrity applies instead.
-- Vehicle conditions keep their numeric integrity when no subsystem reports any detail.
-- Gearbox synchro wear read back from JSON gets its numeric gear keys again.

local M = {}

-- True when any subsystem entry carries real data; an empty table or nothing at all does not count.
local function hasIntegrityDetail(integrityState)
  for _, value in pairs(integrityState) do
    if type(value) ~= "table" or next(value) then return true end
  end
  return false
end

-- Real gearboxes stay well inside this range. Anything else is corrupt data, and a huge or infinite
-- index would make the gap-filling loop below run away.
local MIN_GEAR_INDEX, MAX_GEAR_INDEX = -10, 64

local function isGearIndex(index)
  return index ~= nil and index % 1 == 0 and index >= MIN_GEAR_INDEX and index <= MAX_GEAR_INDEX
end

function M.sanitizeSynchroWear(synchroWear)
  if type(synchroWear) ~= "table" then
    return nil
  end

  -- JSON can turn gear indices into strings; reverse gears use negative indices.
  -- A stock reset writes number keys beside stale text keys, so the number key wins.
  local cleaned = {}
  local maxIndex = 0
  for gearIndex, wear in pairs(synchroWear) do
    local index = tonumber(gearIndex)
    if isGearIndex(index) and (type(gearIndex) == "number" or cleaned[index] == nil) then
      cleaned[index] = tonumber(wear) or 0
      if index > maxIndex then
        maxIndex = index
      end
    end
  end

  if maxIndex < 1 then
    maxIndex = 6
  end

  for gearIndex = 0, maxIndex do
    cleaned[gearIndex] = cleaned[gearIndex] or 0
  end
  return cleaned
end

-- Stock gearboxes read synchroWear[gear] on every shift, so conditions read from JSON need numeric gear keys.
-- Only the wear tables change; every other device state is kept as saved.
function M.sanitizeSynchroWearInConditions(conditions)
  for _, condition in pairs(type(conditions) == "table" and conditions or {}) do
    local integrityState = type(condition) == "table" and condition.integrityState
    local powertrain = type(integrityState) == "table" and integrityState.powertrain
    for _, deviceState in pairs(type(powertrain) == "table" and powertrain or {}) do
      if type(deviceState) == "table" and type(deviceState.synchroWear) == "table" then
        deviceState.synchroWear = M.sanitizeSynchroWear(deviceState.synchroWear)
      end
    end
  end
  return conditions
end

function M.normalizeEmptyIntegrityStates(conditions)
  for _, condition in pairs(type(conditions) == "table" and conditions or {}) do
    local integrityState = type(condition) == "table" and condition.integrityState
    if type(integrityState) == "table" and not hasIntegrityDetail(integrityState) then
      condition.integrityState = nil
    end
  end
  return conditions
end

return M
