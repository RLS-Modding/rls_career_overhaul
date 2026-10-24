-- Competitive event capabilities, course selection and one authored player/AI staging document.
-- Stateless discovery uses the existing race catalog; each consumer owns its level cache.
local M = {}
local raceDataCatalog = require("overhaul/lib/events/raceDataCatalog")
local levelData = require("overhaul/lib/world/levelData")
local catalog = require("overhaul/lib/platform/jsonCatalog")

local function nonempty(value)
  return type(value) == "string" and value ~= ""
end

local function validStaging(staging)
  if type(staging) ~= "table" or not nonempty(staging.sitesFile) or not nonempty(staging.playerSpot) then
    return false
  end
  if staging.aiSpots ~= nil then
    if type(staging.aiSpots) ~= "table" or #staging.aiSpots == 0 then return false end
    local seen = {[staging.playerSpot] = true}
    for _, name in ipairs(staging.aiSpots) do
      if not nonempty(name) or seen[name] then return false end
      seen[name] = true
    end
    return true
  end
  return nonempty(staging.stagingPrefix)
end

-- The normal race catalog owns event rows. Fragments may add competitive metadata to an existing row
-- without replacing its timing, rewards or course. The first declaration owns that race's metadata.
function M.loadRaceDefinitions(levelId)
  if not nonempty(levelId) then return {} end
  local path = "levels/" .. levelId .. "/race_data.json"
  local data = raceDataCatalog.read(path)
  local definitions = {}
  for id, race in pairs(type(data) == "table" and data.races or {}) do
    definitions[id] = {race = race, competitive = race.competitive, defaultCompetitive = race.defaultCompetitive,
      staging = race.staging,
      racingTeam = race.racingTeam}
  end
  local entries = raceDataCatalog.scan(path)
  local seen = {}
  for _, fragment in ipairs(entries) do
    for id, metadata in pairs(type(fragment.competitiveRaces) == "table" and fragment.competitiveRaces or {}) do
      local definition = definitions[id]
      if seen[id] or not definition or type(metadata) ~= "table" or type(metadata.competitive) ~= "boolean"
        or (metadata.defaultCompetitive ~= nil and type(metadata.defaultCompetitive) ~= "boolean")
        or (metadata.racingTeam ~= nil and type(metadata.racingTeam) ~= "table")
        or not validStaging(metadata.staging) then
        log("W", "circuitConfig", "Ignoring invalid or duplicate competitive metadata for " .. tostring(id))
      else
        seen[id] = true
        definition.competitive = metadata.competitive
        definition.defaultCompetitive = metadata.defaultCompetitive
        definition.staging = metadata.staging
        definition.racingTeam = metadata.racingTeam
      end
    end
  end
  return definitions
end

local function validVector(value, count, positive)
  if type(value) ~= "table" then return false end
  for i = 1, count do
    if not catalog.finite(value[i]) or (positive and value[i] <= 0) then return false end
  end
  return true
end

-- Player and AI read exactly one authored document. Broken explicit bindings never search elsewhere.
function M.loadStaging(staging, levelId)
  local function unavailable(reason)
    log("W", "circuitConfig", "Competitive staging unavailable: " .. reason)
    return nil, reason
  end
  if not validStaging(staging) then return unavailable("missing or invalid per-race staging metadata") end
  levelId = levelId or getCurrentLevelIdentifier()
  if not nonempty(levelId) then return unavailable("no active level") end
  local path = levelData.assetPath(levelId, staging.sitesFile)
  local data = jsonReadFile(path)
  if type(data) ~= "table" or type(data.parkingSpots) ~= "table" then
    return unavailable("missing sites document " .. path)
  end
  local byName, aiSpots = {}, {}
  for _, spot in ipairs(data.parkingSpots) do
    if type(spot) == "table" and nonempty(spot.name) then
      if byName[spot.name] then return unavailable("duplicate parking spot " .. spot.name) end
      byName[spot.name] = spot
    end
  end
  if staging.aiSpots then
    for _, name in ipairs(staging.aiSpots) do
      if not byName[name] then return unavailable("missing AI parking spot " .. name) end
      aiSpots[#aiSpots + 1] = byName[name]
    end
  else
    for name, spot in pairs(byName) do
      if name ~= staging.playerSpot and name:sub(1, #staging.stagingPrefix) == staging.stagingPrefix then
        aiSpots[#aiSpots + 1] = spot
      end
    end
    table.sort(aiSpots, function(a, b)
      local an, bn = tonumber(a.name:match("(%d+)$")) or math.huge, tonumber(b.name:match("(%d+)$")) or math.huge
      if an == bn then return a.name < b.name end
      return an < bn
    end)
  end
  local player = byName[staging.playerSpot]
  if not player then return unavailable("missing player parking spot " .. staging.playerSpot) end
  if not validVector(player.pos, 3) or not validVector(player.rot, 4) or not validVector(player.scl, 3, true) then
    return unavailable("invalid player parking transform " .. staging.playerSpot)
  end
  if #aiSpots == 0 then return unavailable("no authored AI parking spots") end
  for _, spot in ipairs(aiSpots) do
    if not validVector(spot.pos, 3) or not validVector(spot.rot, 4) then
      return unavailable("invalid AI parking transform " .. spot.name)
    end
  end
  return {playerSpot = player, aiSpots = aiSpots, sitesPath = path}
end

-- Route selection is data validation, shared by offer discovery and staging admission.
function M.routeForRace(definition, useAltRoute)
  local race = definition and definition.race
  if type(race) ~= "table" then return nil, "Race has no course data" end
  if useAltRoute then
    if type(race.altRoute) ~= "table" then return nil, "Race has no alternate route" end
    race = race.altRoute
  end
  local roads = race.checkpointRoad
  if type(roads) == "string" then
    if roads == "" then return nil, "Race has no checkpoint course" end
  elseif type(roads) == "table" and #roads > 0 then
    for _, road in ipairs(roads) do
      if not nonempty(road) then return nil, "Race has an invalid checkpoint road" end
    end
  else
    return nil, "Race has no checkpoint course"
  end
  return race
end

function M.stagingForRace(definition, useAltRoute)
  local race = definition and definition.race
  if type(race) ~= "table" then return nil end
  if useAltRoute then
    if type(race.altRoute) ~= "table" then return nil end
    if race.altRoute.staging ~= nil then return race.altRoute.staging end
  end
  return race.staging or definition.staging
end

return M
