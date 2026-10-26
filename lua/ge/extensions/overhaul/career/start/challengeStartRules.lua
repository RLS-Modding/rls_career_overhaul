-- Challenge start rules: starting garage mode, starter vehicles and map-bound garages.
-- Reading order: config, starter vehicles, validation, then the public API. challengeCatalog validates through it.

-- Requires -------------------------------------------------------------

local levelData = require('overhaul/lib/world/levelData')

local M = {}

-- Config ---------------------------------------------------------------

-- "none" starts the challenge without any garage; "default" keeps the normal starting-garage choice.
local STARTING_GARAGE_MODES = {default = true, none = true}

-- Starter vehicles -----------------------------------------------------

-- Starter vehicles are "model/configKey" entries naming a config under /vehicles.
local function starterVehiclePath(entry)
  if type(entry) ~= "string" then return nil end
  local model, configKey = entry:match("^([^/]+)/([^/]+)$")
  if not model then return nil end
  return "/vehicles/" .. model .. "/" .. configKey .. ".pc", model, configKey
end

local function configTypeOf(vehicleInfo)
  local configType = vehicleInfo["Config Type"]
  if not configType and vehicleInfo.aggregates and vehicleInfo.aggregates["Config Type"] then
    configType = next(vehicleInfo.aggregates["Config Type"])
  end
  return configType
end

-- The editor offers the same worn-out pool as the hardcore start; JSON challenges may name any config.
local function getAvailableStarterVehicles()
  local available = {}
  local seen = {}
  if not util_configListGenerator then return available end
  for _, vehicleInfo in ipairs(util_configListGenerator.getEligibleVehicles(false, false) or {}) do
    local id = vehicleInfo.model_key and vehicleInfo.key and (vehicleInfo.model_key .. "/" .. vehicleInfo.key)
    if id and not seen[id] and configTypeOf(vehicleInfo) == "Hardcore" then
      seen[id] = true
      table.insert(available, {
        id = id,
        name = vehicleInfo.Name or vehicleInfo.Configuration or id,
        model = vehicleInfo.model_key,
      })
    end
  end
  table.sort(available, function(left, right) return left.name < right.name end)
  return available
end

-- Validation -----------------------------------------------------------

local function checkStartingGarageFields(challengeData)
  local mode = challengeData.startingGarageMode
  if mode ~= nil and not STARTING_GARAGE_MODES[mode] then
    return false, "Starting garage mode must be 'default' or 'none'"
  end
  local startingGarages = challengeData.startingGarages
  if startingGarages ~= nil and type(startingGarages) ~= "table" then
    return false, "Starting garages must be a list"
  end
  if mode == "none" and startingGarages and #startingGarages > 0 then
    return false, "A challenge without a starting garage cannot list starting garages"
  end
  return true
end

-- Missing config files are skipped when the gift is granted, so content from absent mods does not block a challenge.
local function checkStarterVehiclesField(starterVehicles)
  if starterVehicles == nil then return true end
  if type(starterVehicles) ~= "table" then
    return false, "Starter vehicles must be a list"
  end
  for _, entry in ipairs(starterVehicles) do
    if not starterVehiclePath(entry) then
      return false, string.format("Invalid starter vehicle '%s'; expected model/config", tostring(entry))
    end
  end
  return true
end

local function garageIdsOnMap(getAvailableGarages, mapId)
  local onMap = {}
  for _, garage in ipairs(getAvailableGarages() or {}) do
    if garage.mapId == mapId then onMap[garage.id] = true end
  end
  return onMap
end

-- Garage ids only resolve on the map the challenge loads; ids from another map could never be granted or owned.
local function checkGaragesOnChallengeMap(challengeData, getAvailableGarages)
  local lists = {}
  for _, field in ipairs({"startingGarages", "targetGarages"}) do
    local ids = challengeData[field]
    if type(ids) == "table" and #ids > 0 then lists[field] = ids end
  end
  if not next(lists) or not getAvailableGarages then return true end

  local mapId = challengeData.map or levelData.defaultMap()
  if not mapId then return true end
  local onMap = garageIdsOnMap(getAvailableGarages, mapId)
  -- An unreadable or uninstalled map cannot be judged here; starting the career reports it instead.
  if not next(onMap) then return true end

  for _, ids in pairs(lists) do
    for _, garageId in ipairs(ids) do
      if not onMap[garageId] then
        return false, string.format("Garage '%s' is not available on map '%s'", tostring(garageId), mapId)
      end
    end
  end
  return true
end

-- Runs after the catalog's own checks; getAvailableGarages lists the editor's garages across every career map.
local function validate(challengeData, getAvailableGarages)
  local ok, message = checkStartingGarageFields(challengeData)
  if not ok then return false, message end

  ok, message = checkStarterVehiclesField(challengeData.starterVehicles)
  if not ok then return false, message end

  return checkGaragesOnChallengeMap(challengeData, getAvailableGarages)
end

-- Public API -----------------------------------------------------------

M.STARTING_GARAGE_MODES = STARTING_GARAGE_MODES
M.starterVehiclePath = starterVehiclePath
M.getAvailableStarterVehicles = getAvailableStarterVehicles
M.validate = validate

return M
