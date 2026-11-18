-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Matches one list rule of a seller filter ("Config Type": ["Factory", "asotv"]) against a vehicle config.
-- Dealer stock (career/market/vehicleShopping/catalog.lua) and repo jobs (jobs/repo/vehiclePool.lua)
-- both read dealership filters through here, so a config stocks and repos under the same rules.
local M = {}

-- Attributes whose text is compared in any case. Config packs tag the same type as "ASOTV", "asotv" or
-- "AsoTV"; the other attributes keep exact matching. Another mod can add a name here.
M.caseInsensitiveAttributes = {
  ["Config Type"] = true,
}

-- Every config is checked against every dealer filter, so the any-case forms of each filter value list
-- and each config aggregates set are built once and reused. Both are read-only once loaded (dealer
-- filters are deep-copied for each catalog build); the weak keys let them go with the catalog.
local wantedKeySetByList = setmetatable({}, {__mode = "k"})
local aggregateKeysBySet = setmetatable({}, {__mode = "k"})

-- Text compares by its lowercase form; numbers, booleans and other values still compare exactly.
local function anyCaseKey(value)
  if type(value) ~= "string" then return value end
  return string.lower(value)
end

local function wantedKeySetFor(wantedValues)
  local keySet = wantedKeySetByList[wantedValues]
  if not keySet then
    keySet = {}
    for _, wanted in ipairs(wantedValues) do
      -- NaN cannot be a table key and never equals anything anyway.
      if wanted == wanted then keySet[anyCaseKey(wanted)] = true end
    end
    wantedKeySetByList[wantedValues] = keySet
  end
  return keySet
end

-- The tags a config carries, as an array so the per-filter check is a plain numeric loop.
local function aggregateKeysFor(aggregateSet)
  local keys = aggregateKeysBySet[aggregateSet]
  if not keys then
    keys = {}
    for key, present in pairs(aggregateSet) do
      if present then keys[#keys + 1] = anyCaseKey(key) end
    end
    aggregateKeysBySet[aggregateSet] = keys
  end
  return keys
end

-- True when the vehicle's value, or any value in its aggregates set, equals one of the wanted values.
-- wantedValues and the aggregates set are treated as read-only after their first use here: the any-case
-- caches key on their identity, so build a new list instead of editing one in place.
function M.matchesAny(vehicleInfo, attributeName, wantedValues)
  local vehicleValue = vehicleInfo[attributeName]
  local aggregateSet = type(vehicleInfo.aggregates) == "table" and vehicleInfo.aggregates[attributeName] or nil
  if type(aggregateSet) ~= "table" then aggregateSet = nil end

  if not M.caseInsensitiveAttributes[attributeName] then
    for _, wanted in ipairs(wantedValues) do
      if vehicleValue == wanted or (aggregateSet and aggregateSet[wanted]) then return true end
    end
    return false
  end

  local wantedKeys = wantedKeySetFor(wantedValues)
  if vehicleValue ~= nil and wantedKeys[anyCaseKey(vehicleValue)] then return true end
  if aggregateSet then
    local aggregateKeys = aggregateKeysFor(aggregateSet)
    for index = 1, #aggregateKeys do
      if wantedKeys[aggregateKeys[index]] then return true end
    end
  end
  return false
end

return M
