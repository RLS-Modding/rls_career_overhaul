-- Legacy race_data.json remains authoritative. Add-on fragments add races by id.
-- No cache: race owners retain their existing per-instance caching and mutation semantics.
local M = {}
local catalog = require("overhaul/lib/platform/jsonCatalog")
local burnoutConfig = require("overhaul/lib/events/burnoutConfig")
local dragStripEvents = require("overhaul/lib/events/dragStripEvents")

local TAG = "overhaul_raceDataCatalog"
local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do
    out[k] = copy(v)
  end
  return out
end
local function validBusinessProof(proof)
  if proof == nil then return true end
  if type(proof) ~= "table" or type(proof.supported) ~= "boolean" then return false end
  local function timeUnit(unit) return unit == "s" or unit == "min" end
  if not timeUnit(proof.timeUnit) or not timeUnit(proof.legacyTargetTimeUnit) then return false end
  if proof.eventId ~= nil and not catalog.validId(proof.eventId) then return false end
  if proof.legacyRaceType ~= nil and not catalog.validId(proof.legacyRaceType) then return false end
  if proof.leaderboardLabels ~= nil then
    if type(proof.leaderboardLabels) ~= "table" then return false end
    for key, label in pairs(proof.leaderboardLabels) do
      if type(key) ~= "number" or key < 1 or key % 1 ~= 0
        or type(label) ~= "string" or label == "" then return false end
    end
  end
  return true
end

local function validRowProof(row)
  return validBusinessProof(row.businessProof)
    and (type(row.altRoute) ~= "table" or validBusinessProof(row.altRoute.businessProof))
end

-- Base race rows remain available when their optional proof metadata is malformed.
local function validateBaseProof(base, path)
  if type(base) ~= "table" or type(base.races) ~= "table" then return base end
  local result = base
  for id, row in pairs(base.races) do
    if type(row) == "table" and not validRowProof(row) then
      if result == base then result = copy(base) end
      if not validBusinessProof(row.businessProof) then result.races[id].businessProof = nil end
      if type(row.altRoute) == "table" and not validBusinessProof(row.altRoute.businessProof) then
        result.races[id].altRoute.businessProof = nil
      end
      log("W", TAG, "Business proof disabled for " .. tostring(id) .. " at " .. path .. ": invalid metadata")
    end
  end
  return result
end

-- Route and sled labels reach the same UI/cache consumers as the main race label.
local function validLabels(row)
  if row.label ~= nil and type(row.label) ~= "string" then return false end
  if type(row.altRoute) == "table" and not validLabels(row.altRoute) then return false end
  if type(row.sledPresets) == "table" then
    for _, sled in ipairs(row.sledPresets) do
      if type(sled) == "table" and not validLabels(sled) then return false end
    end
  end
  return true
end
local function validate(entry)
  if type(entry.races) ~= "table" then return nil, "races must be an object keyed by race id" end
  for id, race in pairs(entry.races) do
    if not catalog.validId(id) or type(race) ~= "table" then return nil, "invalid race id or row" end
    if not validLabels(race) then return nil, "race labels must be strings" end
    if not validRowProof(race) then return nil, "businessProof requires supported:boolean, s|min time units and valid optional identity/labels" end
    if entry.namespace and id:sub(1, #entry.namespace + 1) ~= entry.namespace .. "." then
      return nil, "race ids must start with namespace."
    end
    if race.type ~= nil then
      if type(race.type) ~= "table" then return nil, "race.type must be a list" end
      for _, discipline in ipairs(race.type) do
        if type(discipline) ~= "string" or discipline == "" then return nil, "invalid race discipline" end
      end
    end
  end
  return entry
end
function M.scan(basePath)
  local dir = assert(basePath:match("^(.*)/race_data%.json$"), "expected a level race_data.json path") .. "/race_data/"
  return catalog.scan(dir, validate, TAG)
end
-- checkExists preserves callers that previously tested the legacy path before reading it.
-- Without fragments or malformed optional proof metadata, preserve the original read result.
function M.read(basePath, checkExists)
  local base
  if not checkExists or FS:fileExists(basePath) then base = jsonReadFile(basePath) end
  base = validateBaseProof(base, basePath)
  local entries, rejected = M.scan(basePath)
  if #entries == 0 then return base, rejected end
  if type(base) == "table" and base.races ~= nil and type(base.races) ~= "table" then
    log("W", TAG, "Ignoring race fragments: legacy races is not an object at " .. basePath)
    return base, rejected
  end
  -- Copy only when adding a row. Re-hashing a no-op merge would change legacy pairs() order.
  local data, copied, seen = base, false, {}
  for id in pairs(type(base) == "table" and base.races or {}) do
    seen[id] = basePath
  end
  for _, entry in ipairs(entries) do
    local ids = {}
    for id in pairs(entry.races) do
      ids[#ids + 1] = id
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
      if seen[id] then
        local reason = "race id " .. id .. " already belongs to " .. seen[id]
        rejected[#rejected + 1] = { id = entry.id, raceId = id, reason = reason }
        log("W", TAG, "Ignoring race in fragment " .. entry.id .. ": " .. reason)
      else
        if not copied then
          data = type(base) == "table" and copy(base) or {}
          data.races = data.races or {}
          copied = true
        end
        data.races[id] = copy(entry.races[id])
        seen[id] = entry.id
      end
    end
  end
  return data, rejected
end
-- The event views and leaderboard comparisons use the same fresh level data.
function M.loadRaces(levelIdentifier)
  local races = {}
  if levelIdentifier then
    local raceData = M.read("levels/" .. levelIdentifier .. "/race_data.json")
    if raceData then races = raceData.races or {} end
    for _, event in ipairs(burnoutConfig.loadLevelData(levelIdentifier).events) do
      races[event.eventId] = burnoutConfig.raceData(event)
    end
    dragStripEvents.addUnbound(levelIdentifier, races)
  end
  return races
end
-- Exact data keys only: route suffixes and labels never grant proof support.
function M.getBusinessProof(levelIdentifier, raceId)
  if type(levelIdentifier) ~= "string" or levelIdentifier == "" or type(raceId) ~= "string" then return nil end
  local data = M.read("levels/" .. levelIdentifier .. "/race_data.json")
  local races = type(data) == "table" and type(data.races) == "table" and data.races or {}
  local race = races[raceId]
  local proof = type(race) == "table" and race.businessProof
  if proof and proof.supported == true then return proof end
  for _, row in pairs(races) do
    local alt = type(row) == "table" and type(row.altRoute) == "table" and row.altRoute.businessProof
    if alt and alt.supported == true and alt.eventId == raceId then return alt end
  end
  return nil
end

return M
