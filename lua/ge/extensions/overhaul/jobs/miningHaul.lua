-- Mining haul shifts: ore pickup, delivery and per-ton pay.
-- Read config, shift state, loading helpers, payouts, frame updates, public actions and save hooks.
local recordJob = require("overhaul/lib/progression/logbookFeed").register("overhaul.miningDeliveryCompleted", {
  title = "Mining delivery completed", label = "Jobs", icon = "deliveryTruck"
}, "jobs/miningHaul.lua")

local M = {}
local vehicleCommands = require('overhaul/lib/vehicles/vehicleCommands')
local statePush = require('overhaul/lib/ui/statePush')
-- Register this feature's file metadata before save hooks run.
local saveStore = require("overhaul/lib/save/store")
local issued = require('overhaul/lib/vehicles/issued')
local levelData = require('overhaul/lib/world/levelData')
local jsonCatalog = require('overhaul/lib/platform/jsonCatalog')
local physicalCargo = require('overhaul/jobs/miningHaul/physicalCargo')

-- Config ------------------------------------------------------------------------------------------

local SAVE_DIR = "/career/rls_career"
local SAVE_FILE = SAVE_DIR .. "/miningHaul.json"

local DEFAULT_CONFIG = {
  label = "Mining Company",
  vehicle = { model = "dumptruck", config = "standard", bedSettings = "dumptruck", licenseText = "HT-55" },
  material = { model = "rock_pile", config = "default", count = 1, tons = 100 },
  loader = { model = "wl40", config = "arm_bucket", licenseText = "WL-40", pickupOffset = {0, -5, 0.25}, lookAtMaterial = true },
  economy = { payPerRock = 350, payPerTon = 20, diamondChance = 0.12, diamondBonus = 4500, repairCost = 750 },
  detection = { officeRadius = 8, pickupRadius = 10, dropoffVehicleRadius = 14, minDeliveryRatio = 0.005, bedRouteRatio = 0.02, nodeStep = 10, processNodeStep = 1, dropoffPadding = {1.0, 1.0, 0.75} },
  autoLoad = { enabled = true, dropHeight = 1.0, spacing = 1.25, offsetSide = 0, offsetForward = 0, offsetUp = 0 },
  bedSettings = {
    dumptruck = { offsetBack = 3.1, offsetSide = 0, length = 5.8, width = 3.2, floorHeight = 1.05, loadHeight = 3.0 },
    us_semi = { offsetBack = 3.0, offsetSide = -0.45, length = 6.0, width = 2.4, floorHeight = 0.3, loadHeight = 3.5 }
  }
}

-- State -------------------------------------------------------------------------------------------

local config = nil
local locationConfigs = {}
local locationSites = {}
local selectedLocationId
local economy = {}
local runtimeConfig = {}
local sites = nil
local loadedLevel = nil
local configChecked = false
local sitesChecked = false
local lastUiMode = nil
local uiTimer = 0
local checkTimer = 0
local pickupPromptState = nil

local savedStateLoaded = false
local loadedProfileName
local deferredLegacyState

local state = {
  active = false,
  phase = "idle",
  truckId = nil,
  inventoryId = nil,
  loaderId = nil,
  currentPickupIndex = 0,
  propIds = {},
  deliveredThisRun = 0,
  deliveriesCompleted = 0,
  oreDelivered = 0,
  diamondsFound = 0,
  grossEarnings = 0,
  repairCosts = 0
}

-- Save metadata and shift reset -----------------------------------------------------------------

local function registerSaveKey()
  saveStore.registerKeys({
    {key = "jobs.miningHaul", owner = "overhaul_jobs_miningHaul", files = {"career/rls_career/miningHaul.json"}, phase = "profile", required = true},
  })
end
registerSaveKey()

local function resetShiftProgress()
  state.phase = "idle"
  state.truckId = nil
  state.inventoryId = nil
  state.loaderId = nil
  state.currentPickupIndex = 0
  state.propIds = {}
  state.deliveredThisRun = 0
  state.deliveriesCompleted = 0
  state.oreDelivered = 0
  state.diamondsFound = 0
  state.grossEarnings = 0
  state.repairCosts = 0
  pickupPromptState = nil
end

local function deepcopyTable(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = deepcopyTable(v) end
  return out
end

local function mergeInto(base, extra)
  if type(extra) ~= "table" then return base end
  for k, v in pairs(extra) do
    if type(v) == "table" and type(base[k]) == "table" and #v == 0 then
      mergeInto(base[k], v)
    else
      base[k] = deepcopyTable(v)
    end
  end
  return base
end

local function cargo()
  return physicalCargo
end

local function toVec3(v)
  local cargoTools = cargo()
  return cargoTools.toVec3(v)
end

-- Location discovery and sites -----------------------------------------------------------------------

local function resolvedEconomy(source)
  if type(source) ~= "table" and type(source) ~= "string" then return nil end
  return {
    payPerTon = tonumber(source.payPerTon) or tonumber(source.payPerRock) or 350,
    diamondChance = source.diamondChance or DEFAULT_CONFIG.economy.diamondChance,
    diamondBonus = source.diamondBonus or DEFAULT_CONFIG.economy.diamondBonus,
    repairCost = math.max(0, math.floor(tonumber(source.repairCost) or DEFAULT_CONFIG.economy.repairCost)),
  }
end

-- Malformed containers fail when the original action reads them, after admission and spawn work.
local function miningPayPerTon()
  if not economy then return tonumber(config.economy.payPerTon) end
  return economy.payPerTon
end

local function miningRepairCost()
  if not economy then return tonumber(config.economy.repairCost) end
  return economy.repairCost
end

-- False values used as missing data stay distinct from explicit zero and malformed truthy values.
local function resolvedSection(source, defaults)
  source = source or defaults
  if type(source) == "string" then source = {} end
  if type(source) ~= "table" then return source end
  local resolved = deepcopyTable(source)
  for key, value in pairs(defaults) do resolved[key] = source[key] or value end
  return resolved
end

local function resolvedMaterial(source)
  local resolved = resolvedSection(source, DEFAULT_CONFIG.material)
  if type(resolved) ~= "table" then return resolved end
  resolved.tons = math.max(1, tonumber(resolved.tons) or DEFAULT_CONFIG.material.tons)
  resolved.count = math.max(1, math.floor(tonumber(resolved.count) or DEFAULT_CONFIG.material.count))
  resolved.pickupOffset = type(resolved.pickupOffset) == "table" and resolved.pickupOffset or {0, 0, 0.25}
  return resolved
end

local function resolvedAutoLoad(source)
  local resolved = resolvedSection(source, DEFAULT_CONFIG.autoLoad)
  if type(resolved) ~= "table" then return resolved end
  resolved.dropHeight = math.max(0, tonumber(resolved.dropHeight) or DEFAULT_CONFIG.autoLoad.dropHeight)
  for _, key in ipairs({"offsetSide", "offsetForward", "offsetUp"}) do
    resolved[key] = tonumber(resolved[key]) or DEFAULT_CONFIG.autoLoad[key]
  end
  return resolved
end

local function resolvedSpawnSettings(source)
  local resolved = deepcopyTable(source)
  for _, key in ipairs({"sitesFile", "label", "officeSpot", "truckSpawnSpot", "pickupSpots", "dropOffArea"}) do
    resolved[key] = source[key] or DEFAULT_CONFIG[key]
  end
  for _, section in ipairs({"vehicle", "loader"}) do
    resolved[section] = resolvedSection(source[section], DEFAULT_CONFIG[section])
  end
  resolved.material = resolvedMaterial(source.material)
  resolved.autoLoad = resolvedAutoLoad(source.autoLoad)
  resolved.detection = (type(source.detection) == "table" or type(source.detection) == "string") and resolvedSection(source.detection, DEFAULT_CONFIG.detection) or source.detection
  resolved.optionalDetection = resolved.detection or deepcopyTable(DEFAULT_CONFIG.detection)
  if type(resolved.loader) == "table" then
    local offset = resolved.loader.pickupOffset
    resolved.loader.pickupOffset = type(offset) == "table" and offset or DEFAULT_CONFIG.loader.pickupOffset
  end
  if type(resolved.optionalDetection) == "table" then
    local padding = resolved.optionalDetection.dropoffPadding
    resolved.optionalDetection.dropoffPadding = type(padding) == "table" and padding or DEFAULT_CONFIG.detection.dropoffPadding
  end
  resolved.dropOffBoxFallback = source.dropOffAreaFallback
  return resolved
end

runtimeConfig = resolvedSpawnSettings(DEFAULT_CONFIG)

local function validSpatialArray(values, size, positive)
  if type(values) ~= "table" or #values ~= size then return false end
  for index = 1, size do
    local value = values[index]
    if not jsonCatalog.finite(value) or (positive and value <= 0) then return false end
  end
  return true
end

local function collectLocationRecords(level)
  local localFiles = FS:findFiles("/levels/" .. level .. "/", "*.miningHaul.json", -1, true, false) or {}
  local globalFiles = FS:findFiles("/gameplay/overhaul/mining/", "*.miningHaul.json", -1, true, false) or {}
  table.sort(localFiles); table.sort(globalFiles)
  local records, sources = {}, {}
  for _, file in ipairs(globalFiles) do
    local data = jsonReadFile(file)
    if type(data) == "table" and data.levelId == level and data.id then records[data.id], sources[data.id] = data, file end
  end
  for _, file in ipairs(localFiles) do
    local data = jsonReadFile(file)
    if type(data) == "table" then
      local id = data.id
      if not id then
        local onlyId = next(records)
        if onlyId and next(records, onlyId) == nil then id = onlyId end
      end
      if id then records[id], sources[id] = mergeInto(records[id] or {}, data), file
      else log("W", "miningHaul", "Mining disabled: missing id in " .. file) end
    else log("W", "miningHaul", "Ignoring invalid mining config: " .. file) end
  end
  return records, sources
end

local function invalidLocationField(data)
  local missing
  if type(data) == "table" then
    for _, key in ipairs({"id", "organizationId", "sitesFile", "officeSpot", "truckSpawnSpot"}) do
      if type(data[key]) ~= "string" or data[key] == "" then missing = key; break end
    end
    if type(data.pickupSpots) ~= "table" or #data.pickupSpots == 0 then missing = "pickupSpots" end
    if not data.dropOffArea and not data.dropOffAreaFallback then missing = "dropOffArea or dropOffAreaFallback" end
    if data.dropOffAreaFallback then
      local box = data.dropOffAreaFallback
      for key, count in pairs({position = 3, rotationMatrix = 9, scale = 3}) do
        if type(box) ~= "table" or not validSpatialArray(box[key], count, key == "scale") then
          missing = "dropOffAreaFallback." .. key .. " (requires " .. count .. " finite numbers" .. (key == "scale" and ", all positive)" or ")")
          break
        end
      end
    end
  else missing = "object" end
  return missing
end

local function selectConfiguredLocation()
  config = locationConfigs[selectedLocationId]
  if not config and (not selectedLocationId or not state.active) then
    local ids = {}; for id in pairs(locationConfigs) do ids[#ids + 1] = id end; table.sort(ids)
    selectedLocationId = ids[1]
    for _, id in ipairs(ids) do
      if locationConfigs[id].defaultLocation then selectedLocationId = id; break end
    end
    config = selectedLocationId and locationConfigs[selectedLocationId]
  end
end

local function loadConfig(force)
  local level = getCurrentLevelIdentifier()
  if not level then
    config = nil
    runtimeConfig = resolvedSpawnSettings(DEFAULT_CONFIG)
    sites = nil
    loadedLevel = nil
    configChecked = false
    sitesChecked = false
    return nil
  end
  if not force and configChecked and loadedLevel == level then return config end
  config = nil
  runtimeConfig = resolvedSpawnSettings(DEFAULT_CONFIG)
  sites = nil
  loadedLevel = level
  configChecked = true
  sitesChecked = false
  local records, sources = collectLocationRecords(level)
  locationConfigs, locationSites = {}, {}
  for id, data in pairs(records) do
    local file = sources[id]
    local missing = invalidLocationField(data)
    if missing then
      log("W", "miningHaul", "Mining disabled in " .. file .. ": missing or invalid " .. missing)
    elseif locationConfigs[data.id] then
      log("W", "miningHaul", "Duplicate mining location disabled: " .. data.id)
    else
      locationConfigs[data.id] = mergeInto(deepcopyTable(DEFAULT_CONFIG), data)
    end
  end
  selectConfiguredLocation()
  if not config then
    log("W", "miningHaul", "Mining disabled: no valid local mining configurations")
    return nil
  end
  economy = resolvedEconomy(config.economy)
  runtimeConfig = resolvedSpawnSettings(config)
  return config
end

local function loadSites(force)
  if not config then loadConfig() end
  if not config then return nil end
  local level = getCurrentLevelIdentifier()
  if not level then return nil end
  if not force and sitesChecked and loadedLevel == level then return sites end
  sites = nil
  sitesChecked = true
  local file = levelData.assetPath(level, runtimeConfig.sitesFile)
  local loadedSites = jsonReadFile(file)
  if type(loadedSites) ~= "table" or type(loadedSites.parkingSpots) ~= "table" then
    log("W", "miningHaul", "Mining disabled; missing or invalid sites file: " .. tostring(file))
    return nil
  end
  local names = {runtimeConfig.officeSpot, runtimeConfig.truckSpawnSpot}
  for _, name in ipairs(runtimeConfig.pickupSpots) do names[#names + 1] = name end
  for _, name in ipairs(names) do
    local found = false
    for _, spot in ipairs(loadedSites.parkingSpots) do
      if spot.name == name then
        if not validSpatialArray(spot.pos, 3) then
          log("W", "miningHaul", "Mining disabled: configured spot " .. tostring(name) .. " requires a position with 3 finite numbers in " .. file)
          return nil
        end
        found = true
        break
      end
    end
    if not found then log("W", "miningHaul", "Mining disabled: missing configured spot " .. tostring(name) .. " in " .. file); return nil end
  end
  local area = runtimeConfig.dropOffArea and scenetree.findObject(runtimeConfig.dropOffArea)
  if not area and not runtimeConfig.dropOffBoxFallback then
    log("W", "miningHaul", "Mining disabled: drop-off area is unavailable"); return nil
  end
  sites = loadedSites
  return sites
end

local function ensureAvailable(force)
  loadConfig(force == true)
  if config then loadSites(force == true) end
  if not sites and not state.active then
    local ids = {}
    for id in pairs(locationConfigs) do if id ~= selectedLocationId then ids[#ids + 1] = id end end
    table.sort(ids)
    for _, id in ipairs(ids) do
      selectedLocationId = id
      config = locationConfigs[id]
      economy = resolvedEconomy(config.economy)
      runtimeConfig = resolvedSpawnSettings(config)
      sitesChecked = false
      if loadSites() then break end
    end
  end
  return config ~= nil and sites ~= nil
end

local function findSpot(name)
  if not sites then loadSites() end
  if not sites or not sites.parkingSpots then return nil end
  for _, spot in ipairs(sites.parkingSpots) do
    if spot.name == name then return spot end
  end
  return nil
end

local function spotPos(name)
  local spot = findSpot(name)
  return spot and spot.pos and toVec3(spot.pos) or nil
end

local function spotRot(name)
  local spot = findSpot(name)
  local cargoTools = cargo()
  if spot and spot.rot and cargoTools and cargoTools.toQuat then return cargoTools.toQuat(spot.rot) end
  return quat(0, 0, 0, 1)
end

-- Persistence -----------------------------------------------------------------------------------

local function savePayload()
  if deferredLegacyState then return deferredLegacyState end
  if not state.active then
    return {
      active = false,
      phase = "idle",
      currentPickupIndex = 0,
      deliveredThisRun = 0,
      deliveriesCompleted = 0,
      oreDelivered = 0,
      diamondsFound = 0,
      grossEarnings = 0,
      repairCosts = 0
    }
  end
  return {
    active = true,
    locationId = selectedLocationId,
    phase = state.phase,
    currentPickupIndex = state.currentPickupIndex,
    deliveredThisRun = state.deliveredThisRun,
    deliveriesCompleted = state.deliveriesCompleted,
    oreDelivered = state.oreDelivered,
    diamondsFound = state.diamondsFound,
    grossEarnings = state.grossEarnings,
    repairCosts = state.repairCosts
  }
end

local persistence
local function savePersistence()
  if persistence then return persistence end
  persistence = assert(saveStore.feature("jobs.miningHaul", {
    owner = "overhaul_jobs_miningHaul",
    files = {"career/rls_career/miningHaul.json"},
    root = "slot",
    phase = "profile",
    required = true,
    writer = {pretty = true},
    capture = function(context, writer)
      local dirPath = context.path():match("^(.*)/[^/]+$")
      if not writer.exists(dirPath) then writer.mkdir(dirPath) end
      context.write(savePayload())
    end,
  }))
  return persistence
end

local function saveStateToPath(savePath, writer)
  if not savePath then return end
  savePersistence().capture(savePath, writer)
end

local function loadSavedState()
  if not overhaul_career_saveSystem then return end
  local profileName, savePath = overhaul_career_saveSystem.getCurrentProfile()
  if savedStateLoaded and loadedProfileName == profileName then
    if state.active then
      state.propIds = {}
      state.truckId = nil
      state.inventoryId = nil
      state.loaderId = nil
    end
    return
  end
  if not savePath then return end
  savedStateLoaded = true
  loadedProfileName = profileName
  deferredLegacyState = nil
  local data = jsonReadFile(savePath .. SAVE_FILE)
  if type(data) ~= "table" or data.active ~= true then
    state.active = false
    resetShiftProgress()
    return
  end
  if data.locationId == nil and not getCurrentLevelIdentifier() then
    deferredLegacyState = data
    savedStateLoaded = false
    return
  end
  if data.locationId == nil then
    local onlyId = next(locationConfigs)
    if not onlyId or next(locationConfigs, onlyId) ~= nil then
      state.active = false
      resetShiftProgress()
      log("W", "miningHaul", "Legacy mining shift not restored: location identity is missing and no unique location is configured")
      return
    end
    data.locationId = onlyId
    log("W", "miningHaul", "Migrated legacy mining shift to the sole configured location: " .. onlyId)
  end
  selectedLocationId = data.locationId
  state.active = true
  state.phase = data.phase or "toPickup"
  state.currentPickupIndex = tonumber(data.currentPickupIndex) or 0
  state.deliveredThisRun = tonumber(data.deliveredThisRun) or 0
  state.deliveriesCompleted = tonumber(data.deliveriesCompleted) or 0
  state.oreDelivered = tonumber(data.oreDelivered) or 0
  state.diamondsFound = tonumber(data.diamondsFound) or 0
  state.grossEarnings = tonumber(data.grossEarnings) or 0
  state.repairCosts = tonumber(data.repairCosts) or 0
  state.propIds = {}
  state.truckId = nil
  state.inventoryId = nil
  state.loaderId = nil
end

local function clearSavedState()
  state.active = false
end

-- Vehicle and loading geometry ------------------------------------------------------------------

local function isConfiguredTruck(veh)
  if not veh or not veh.getJBeamFilename then return false end
  local ok, model = pcall(function() return veh:getJBeamFilename() end)
  local expected = runtimeConfig.vehicle.model
  return ok and model == expected
end

local function playerPos()
  local veh = be:getPlayerVehicle(0)
  return veh and veh:getPosition() or nil
end

local function distTo(pos)
  local p = playerPos()
  return (p and pos) and p:distance(pos) or math.huge
end

local function isNearSpot(name, radius)
  local pos = spotPos(name)
  return pos and distTo(pos) <= (radius or 8)
end

local function getBedSettings()
  local key = runtimeConfig.vehicle.bedSettings
  return config and config.bedSettings and config.bedSettings[key] or DEFAULT_CONFIG.bedSettings.dumptruck
end

local function tableOffset(t, fallback)
  t = type(t) == "table" and t or fallback
  return vec3(tonumber(t[1] or t.x) or 0, tonumber(t[2] or t.y) or 0, tonumber(t[3] or t.z) or 0)
end

local function spotYaw(name)
  local spot = findSpot(name)
  local rot = spot and spot.rot
  if not rot then return 0 end
  local z = tonumber(rot[3] or rot.z) or 0
  local w = tonumber(rot[4] or rot.w) or 1
  return 2 * math.atan2(z, w)
end

local function spotLocalToWorld(name, offset)
  local base = spotPos(name)
  if not base then return nil end
  local yaw = spotYaw(name)
  local right = vec3(math.cos(yaw), -math.sin(yaw), 0)
  local forward = vec3(math.sin(yaw), math.cos(yaw), 0)
  return base + (right * offset.x) + (forward * offset.y) + vec3(0, 0, offset.z)
end

local function getTruckObj()
  if state.truckId then
    local obj = be:getObjectByID(state.truckId)
    if obj then return obj end
    return nil
  end
  local veh = be:getPlayerVehicle(0)
  return isConfiguredTruck(veh) and veh or nil
end

local function truckDistTo(pos)
  local truck = getTruckObj()
  return (truck and pos) and truck:getPosition():distance(pos) or math.huge
end

local function isTruckNearSpot(name, radius)
  local pos = spotPos(name)
  return pos and truckDistTo(pos) <= (radius or 8)
end

-- Pickup resources and guidance -----------------------------------------------------------------

local function clearProps()
  if cargo() then cargo().deleteProps(state.propIds) end
  state.propIds = {}
end

local function pruneDeadProps()
  local live = {}
  for _, id in ipairs(state.propIds or {}) do
    if id and be:getObjectByID(id) then table.insert(live, id) end
  end
  state.propIds = live
  return #live
end

local function clearLoader()
  if state.loaderId then
    local obj = be:getObjectByID(state.loaderId)
    if obj then obj:delete() end
  end
  state.loaderId = nil
end

local function clearPickupResources()
  clearProps()
  clearLoader()
end

-- The truck is adopted from inventory; only the loader and ore belong to
-- this temporary world. Keep shift progress for the next owner's restore.
require("overhaul/lib/vehicles/temporary").declare("miningHaul", clearPickupResources)

local function setMarker(pos, clearOnReach)
  if not pos then return false end
  if core_groundMarkers then
    core_groundMarkers.setPath(pos, { clearPathOnReachingTarget = clearOnReach == true })
  end
  return true
end

local function clearMarker()
  if core_groundMarkers then core_groundMarkers.setPath(nil) end
end

local function currentPickupName()
  local pickups = runtimeConfig.pickupSpots
  if #pickups == 0 then return nil end
  local idx = state.currentPickupIndex
  if idx < 1 or idx > #pickups then idx = 1 end
  return pickups[idx]
end

local function chooseNextPickup()
  local pickups = runtimeConfig.pickupSpots
  if #pickups == 0 then return nil end
  if #pickups == 1 then
    state.currentPickupIndex = 1
  else
    local previousIndex = state.currentPickupIndex
    local nextIndex = previousIndex
    for _ = 1, 5 do
      nextIndex = math.random(1, #pickups)
      if nextIndex ~= previousIndex then break end
    end
    if nextIndex == previousIndex then
      nextIndex = (previousIndex % #pickups) + 1
    end
    state.currentPickupIndex = nextIndex
  end
  return currentPickupName()
end

local function spawnPickupResources()
  local pickupName = currentPickupName()
  local cargoTools = cargo()
  if not pickupName or not cargoTools then return false end
  clearPickupResources()
  local mat = runtimeConfig.material
  local rockOffset = tableOffset(mat.pickupOffset)
  local rockPos = spotLocalToWorld(pickupName, rockOffset)
  if not rockPos then return false end
  local rockId = cargoTools.spawnProp(mat.model, mat.config, rockPos, spotRot(pickupName), { cling = true, safeSpawn = true })
  if rockId then table.insert(state.propIds, rockId) end
  local loaderCfg = runtimeConfig.loader
  local loaderOffset = tableOffset(loaderCfg.pickupOffset)
  local loaderPos = spotLocalToWorld(pickupName, loaderOffset)
  if loaderPos then
    local loaderRot = spotRot(pickupName)
    if loaderCfg.lookAtMaterial ~= false and rockPos and quatFromDir then
      local dir = rockPos - loaderPos
      if dir:length() > 0.1 then loaderRot = quatFromDir(dir:normalized(), vec3(0, 0, 1)) end
    end
    state.loaderId = cargoTools.spawnProp(loaderCfg.model, loaderCfg.config, loaderPos, loaderRot, { cling = true, safeSpawn = true, licenseText = loaderCfg.licenseText })
  end
  return #state.propIds > 0
end

-- HUD and delivery detection --------------------------------------------------------------------

local function showUi(mode, payload, refresh)
  lastUiMode = mode
  payload = payload or {}
  payload.visible = true
  payload.mode = mode
  payload.active = state.active
  payload.phase = state.phase
  payload.label = runtimeConfig.label
  if payload.oreDelivered == nil then payload.oreDelivered = state.oreDelivered end
  if payload.deliveriesCompleted == nil then payload.deliveriesCompleted = state.deliveriesCompleted end
  if payload.diamondsFound == nil then payload.diamondsFound = state.diamondsFound end
  if payload.repairCosts == nil then payload.repairCosts = state.repairCosts end
  if payload.grossEarnings == nil then payload.grossEarnings = state.grossEarnings end
  if payload.netEarnings == nil then payload.netEarnings = math.max(0, state.grossEarnings - state.repairCosts) end
  if refresh then
    statePush.refresh("MiningHaulUi", payload)
  else
    statePush.send("MiningHaulUi", payload)
  end
end

local function hideUi()
  lastUiMode = nil
  statePush.send("MiningHaulUi", { visible = false })
end

local function dropOffPadding()
  if type(runtimeConfig.optionalDetection) ~= "table" then
    return config.detection.dropoffPadding
  end
  return runtimeConfig.optionalDetection.dropoffPadding
end

local function getDropOffBox()
  local areaName = runtimeConfig.dropOffArea
  local areaObj = areaName and scenetree.findObject(areaName)
  local cargoTools = cargo()
  local box = cargoTools.makeBoxFromGameplayArea(areaObj, runtimeConfig.dropOffBoxFallback)
  if box then
    local padding = tableOffset(dropOffPadding())
    box.halfWidth = box.halfWidth + math.max(0, padding.x)
    box.halfLength = box.halfLength + math.max(0, padding.y)
    box.halfHeight = box.halfHeight + math.max(0, padding.z)
  end
  return box
end

local function dropOffTargetPos()
  local box = getDropOffBox()
  return box and box.center
end

local function deliveredLoadRatio()
  local cargoTools = cargo()
  local box = getDropOffBox()
  if not cargoTools or not box then return 0 end
  local nodeStep = runtimeConfig.optionalDetection.processNodeStep
  local totalRatio = 0
  pruneDeadProps()
  for _, id in ipairs(state.propIds) do
    totalRatio = totalRatio + cargoTools.getLoadRatioInBox(id, box, nodeStep)
  end
  return totalRatio
end

local function deliveredTonsFromRatio(ratio)
  local mat = runtimeConfig.material
  local tons = mat.tons
  ratio = tonumber(ratio) or 0
  if ratio <= 0 then return 0 end
  return math.max(1, math.floor(ratio * tons + 0.5))
end

local function isTruckAtDropoff()
  local box = getDropOffBox()
  local truck = getTruckObj()
  if box and truck and cargo().isPointInBox(truck:getPosition(), box) then return true end
  local fallbackPos = config.dropOffAreaFallback and toVec3(config.dropOffAreaFallback.position)
  return fallbackPos and distTo(fallbackPos) <= runtimeConfig.optionalDetection.dropoffVehicleRadius
end

local function bedLoadRatio()
  local truck = getTruckObj()
  local cargoTools = cargo()
  if not truck or not cargoTools then return 0 end
  local totalRatio = 0
  pruneDeadProps()
  for _, id in ipairs(state.propIds) do
    totalRatio = totalRatio + cargoTools.getBedLoadRatio(id, truck, getBedSettings(), config.detection.nodeStep)
  end
  return totalRatio
end

local function canAutoLoadTruck()
  if not state.active or state.phase ~= "toPickup" then return false end
  if config and config.autoLoad and config.autoLoad.enabled == false then return false end
  local truck = getTruckObj()
  if not truck then return false end
  local pickupName = currentPickupName()
  return pickupName and isTruckNearSpot(pickupName, runtimeConfig.detection.pickupRadius) or false
end

local function hudPayload(extra)
  local payload = extra or {}
  payload.pickupName = currentPickupName()
  payload.target = state.phase == "toDropoff" and "Processing Facility" or "Excavation Zone"
  payload.deliveredThisRun = state.deliveredThisRun
  payload.totalProps = #state.propIds
  payload.canEnd = state.active
  local dropoffRatio = deliveredLoadRatio and deliveredLoadRatio() or 0
  payload.deliveredTons = deliveredTonsFromRatio and deliveredTonsFromRatio(dropoffRatio) or 0
  payload.canProcess = state.active
  payload.canLoad = canAutoLoadTruck and canAutoLoadTruck() or false
  if state.phase == "toPickup" then
    local pickupName = currentPickupName()
    payload.atPickup = pickupName and isTruckNearSpot(pickupName, runtimeConfig.detection.pickupRadius) or false
    if dropoffRatio >= runtimeConfig.optionalDetection.minDeliveryRatio then
      payload.target = "Ready to Process"
    else
      payload.target = payload.atPickup and "Load with WL-40" or "Excavation Zone"
    end
  elseif state.phase == "toDropoff" then
    if dropoffRatio >= runtimeConfig.optionalDetection.minDeliveryRatio then
      payload.target = "Ready to Process"
    elseif isTruckAtDropoff() then
      payload.target = "Dump Ore in Zone"
    end
  end
  return payload
end

-- Payout and loaner vehicles --------------------------------------------------------------------

local function payDelivery(amount)
  amount = math.floor(tonumber(amount) or 0)
  if amount <= 0 then return end
  local skillRewards = require("overhaul/lib/jobs/skillRewards")
  local operatorLevel = skillRewards.getSkillLevel("careerSkills-operator", {"careerSkills-operator", "operator"})
  local baseAmount = amount
  amount = math.floor(baseAmount * skillRewards.getOperatorMoneyBonusMultiplier(3, operatorLevel) + 0.5)
  local operatorXp = math.max(1, math.floor(baseAmount / 10))
  if overhaul_career_career.isActive() then
    local accepted = overhaul_career_economy_payment.payout(require("overhaul/lib/finance/metadata").tagPayout({
      amount = amount,
      xp = {["careerSkills-operator"] = operatorXp},
      label = "Mining Company ore delivery",
      tags = {"gameplay", "miningHaul", "delivery"}
    }, "activity:miningHaul", {vehicleId = state.inventoryId}))
    if accepted == true then recordJob({detail = "Ore delivered", money = amount}) end
  end
  Engine.Audio.playOnce("AudioGui", "event:>UI>Career>Buy_01")
  require("overhaul/lib/save/store").request("miningHaul:payDelivery")
end

local function registerLoaner(vehId)
  return issued.adopt(overhaul_career_garage_inventory, vehId, "work", config.organizationId)
end

local function returnLoaner()
  local inventoryId = state.inventoryId
  local truckId = state.truckId
  state.truckId = nil
  state.inventoryId = nil
  local careerMode = overhaul_career_career.isActive()
  if inventoryId and careerMode then
    issued.returnAdopted(overhaul_career_garage_inventory, inventoryId)
  elseif truckId then
    local ownedInventoryId = careerMode and overhaul_career_garage_inventory.getInventoryIdFromVehicleId(truckId)
    local obj = not ownedInventoryId and be:getObjectByID(truckId)
    if obj then obj:delete() end
  end
end

local function spawnLoaner()
  local spawnName = runtimeConfig.truckSpawnSpot
  local pos = spotPos(spawnName)
  if not pos then return false end
  local vehCfg = runtimeConfig.vehicle
  local obj = core_vehicles.spawnNewVehicle(vehCfg.model, {
    pos = pos,
    rot = spotRot(spawnName),
    config = vehCfg.config,
    licenseText = vehCfg.licenseText,
    autoEnterVehicle = false
  })
  if not obj then return false end
  state.truckId = obj:getID()
  state.inventoryId = registerLoaner(state.truckId)
  if core_vehicleBridge then
    core_vehicleBridge.executeAction(obj, "initPartConditions", {}, 0, 1, 1)
  end
  return true
end

local function autoLoadOffsets(count, spacing)
  local offsets = {}
  count = math.max(1, math.floor(tonumber(count) or 1))
  spacing = math.max(0.25, tonumber(spacing) or 1.25)
  local columns = math.max(1, math.ceil(math.sqrt(count)))
  local rows = math.max(1, math.ceil(count / columns))
  for i = 1, count do
    local col = (i - 1) % columns
    local row = math.floor((i - 1) / columns)
    table.insert(offsets, vec3((col - (columns - 1) * 0.5) * spacing, (row - (rows - 1) * 0.5) * spacing, 0))
  end
  return offsets
end

local function updateDeliveryPrompt()
  if state.phase ~= "toDropoff" then return end
  showUi("hud", hudPayload())
end

local function resetShiftFields()
  resetShiftProgress()
end

local function isLiveLoaner(truckId, inventoryId)
  if not truckId or not inventoryId or not be:getObjectByID(truckId) then return false end
  if overhaul_career_career.isActive() then
    return overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId) == truckId
  end
  return true
end

-- Pickup and office prompts ---------------------------------------------------------------------

local function handlePickup()
  local pickupName = currentPickupName()
  if not pickupName or state.phase ~= "toPickup" then return end
  if #state.propIds == 0 then spawnPickupResources() end
  if bedLoadRatio() >= runtimeConfig.optionalDetection.bedRouteRatio then
    state.phase = "toDropoff"
    pickupPromptState = nil
    state.deliveredThisRun = 0
    setMarker(dropOffTargetPos(), false)
    showUi("hud", hudPayload({ notice = "Ore detected in bed" }))
    return
  end
  local promptState = "route"
  if isTruckNearSpot(pickupName, runtimeConfig.detection.pickupRadius) then
    promptState = "loading"
  end
  if promptState ~= pickupPromptState then
    pickupPromptState = promptState
    showUi("hud", hudPayload())
  end
end

local function locationOffice(data)
  if locationSites[data.id] == nil then
    locationSites[data.id] = jsonReadFile(levelData.assetPath(getCurrentLevelIdentifier(), data.sitesFile)) or false
  end
  local raw = locationSites[data.id]
  for _, spot in ipairs(raw and raw.parkingSpots or {}) do
    if spot.name == data.officeSpot and spot.pos then return toVec3(spot.pos) end
  end
end

local function handleOfficePrompt()
  if not state.active then
    local position = playerPos()
    local nearestId, nearestDistance
    for id, data in pairs(locationConfigs) do
      local office = locationOffice(data)
      local distance = office and position and (office - position):length()
      if distance and distance <= (data.detection.officeRadius or DEFAULT_CONFIG.detection.officeRadius) and (not nearestDistance or distance < nearestDistance) then
        nearestId, nearestDistance = id, distance
      end
    end
    if nearestId and nearestId ~= selectedLocationId and not M.selectLocation(nearestId) then return end
  end
  local nearOffice = isNearSpot(runtimeConfig.officeSpot, runtimeConfig.detection.officeRadius)
  if nearOffice and lastUiMode ~= "intro" and lastUiMode ~= "office" and lastUiMode ~= "summary" then
    M.showOffice()
  elseif not nearOffice and (lastUiMode == "intro" or lastUiMode == "office") then
    hideUi()
  end
end

-- Per-frame update --------------------------------------------------------------------------------

local function onUpdate(dtReal, dtSim, dtRaw)
  if not (overhaul_career_career and overhaul_career_career.isActive()) then return end
  if not getCurrentLevelIdentifier() then return end
  if not ensureAvailable() then return end
  local dt = dtSim or dtReal or dtRaw or 0
  checkTimer = checkTimer + dt
  uiTimer = uiTimer + dt
  if checkTimer >= 0.2 then
    checkTimer = 0
    handleOfficePrompt()
    if state.active then
      if not state.truckId then
        local veh = be:getPlayerVehicle(0)
        if isConfiguredTruck(veh) then state.truckId = veh:getID() end
      end
      if state.phase == "toPickup" then
        handlePickup()
      elseif state.phase == "toDropoff" then
        updateDeliveryPrompt()
      end
    end
  end
  if state.active and uiTimer >= 0.75 and (lastUiMode == "hud" or not lastUiMode) then
    uiTimer = 0
    showUi("hud", hudPayload(), true)
  end
end

-- Lifecycle -------------------------------------------------------------------------------------

local function discardUnavailableShift()
  hideUi()
  if not state.active then return end
  clearPickupResources()
  clearMarker()
  state.active = false
  resetShiftProgress()
  log("W", "miningHaul", "Discarded an active mining shift because this level has no valid mining configuration")
end

local function restoreWorld()
  local prevTruckId, prevInventoryId = state.truckId, state.inventoryId
  local available = ensureAvailable(true)
  loadSavedState()
  if state.active and selectedLocationId ~= (config and config.id) then available = ensureAvailable(true) end
  if not available then
    discardUnavailableShift()
    return
  end
  if state.active then
    state.phase = state.phase == "toDropoff" and "toPickup" or state.phase
    clearPickupResources()
    spawnPickupResources()
    setMarker(spotPos(currentPickupName()) or spotPos(config.officeSpot), false)
    if isLiveLoaner(prevTruckId, prevInventoryId) then
      state.truckId, state.inventoryId = prevTruckId, prevInventoryId
    elseif not spawnLoaner() then
      log("W", "miningHaul", "Could not re-issue the HT-55 loaner for a restored mining shift")
    end
  end
end

local function onWorldReadyState(worldReadyState)
  if worldReadyState == 2 then restoreWorld() end
end

local function onExtensionLoaded()
  if overhaul_career_saveSystem then savePersistence() end
  math.randomseed(os.time())
  local available = ensureAvailable(true)
  loadSavedState()
  if state.active and selectedLocationId ~= (config and config.id) then available = ensureAvailable(true) end
  -- Extensions can be loaded at the main menu before a level exists. Preserve
  if not available and getCurrentLevelIdentifier() then discardUnavailableShift() end
end

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  if not savedStateLoaded then
    loadSavedState()
    if not savedStateLoaded and not deferredLegacyState then return end
  end
  saveStateToPath(currentSavePath, writer)
end

-- Public API ------------------------------------------------------------------------------------

function M.startShift(locationId)
  if locationId and not M.selectLocation(locationId) then return false end
  if state.active then return false end
  if not ensureAvailable() then return false end
  resetShiftFields()
  state.active = true
  if not spawnLoaner() then
    state.active = false
    ui_message("Mining Company could not spawn the HT-55 loaner.", 5, "Mining Company")
    return false
  end
  chooseNextPickup()
  state.phase = "toPickup"
  spawnPickupResources()
  setMarker(spotPos(currentPickupName()), false)
  showUi("hud", hudPayload({ notice = "Shift started" }))
  return true
end

function M.endShift()
  if not state.active then return false end
  local summary = {
    oreDelivered = state.oreDelivered,
    deliveriesCompleted = state.deliveriesCompleted,
    diamondsFound = state.diamondsFound,
    repairCosts = state.repairCosts,
    grossEarnings = state.grossEarnings,
    netEarnings = math.max(0, state.grossEarnings - state.repairCosts)
  }
  clearPickupResources()
  returnLoaner()
  clearMarker()
  state.active = false
  resetShiftFields()
  clearSavedState()
  showUi("summary", summary)
  require("overhaul/lib/save/store").request("miningHaul:endShift")
  return true
end

function M.repairTruck()
  if not state.active then return false end
  if not isLiveLoaner(state.truckId, state.inventoryId) then
    showUi("office", { notice = "Only the company HT-55 loaner can be repaired here" })
    return false
  end
  local truck = be:getObjectByID(state.truckId)
  local cost = miningRepairCost()
  if cost > 0 and overhaul_career_career.isActive() then
    local paid = overhaul_career_economy_payment.pay({ money = { amount = cost, canBeNegative = false } }, require("overhaul/lib/finance/metadata").tag({
      label = "Mining Company HT-55 repair",
      tags = {"gameplay", "miningHaul", "repair"}
    }, "repair", {vehicleId = state.inventoryId}))
    if not paid then
      showUi("office", { notice = "Not enough money to repair the HT-55", repairCost = cost })
      return false
    end
  end
  truck:queueLuaCommand("extensions.load('overhaulDamageState'); if overhaulDamageState then "
    .. vehicleCommands.call('overhaulDamageState', 'reset') .. "; end; if recovery then recovery.recoverInPlace(); end")
  if core_vehicleBridge then
    core_vehicleBridge.executeAction(truck, "initPartConditions", {}, 0, 1, 1)
  end
  state.repairCosts = state.repairCosts + cost
  showUi("office", { notice = "HT-55 repaired", repairCost = cost })
  return true
end

function M.loadTruck()
  if not state.active then return false end
  if not canAutoLoadTruck() then
    showUi("hud", hudPayload({ notice = "Park the HT-55 at the excavation zone" }))
    return false
  end
  local cargoTools = cargo()
  local truck = getTruckObj()
  local bed = cargoTools and cargoTools.makeBedData and cargoTools.makeBedData(truck, getBedSettings()) or nil
  if not cargoTools or not truck or not bed then
    showUi("hud", hudPayload({ notice = "Could not find the HT-55 bed" }))
    return false
  end
  clearPickupResources()
  local mat = runtimeConfig.material
  local autoLoadCfg = runtimeConfig.autoLoad
  local spawned = 0
  local rot = quat(0, 0, 0, 1)
  if quatFromDir then
    rot = quatFromDir(truck:getDirectionVector():normalized(), truck:getDirectionVectorUp():normalized())
  end
  for _, offset in ipairs(autoLoadOffsets(mat.count, autoLoadCfg.spacing)) do
    local clampedX = math.max(-bed.halfWidth * 0.55, math.min(bed.halfWidth * 0.55, offset.x))
    local clampedY = math.max(-bed.halfLength * 0.55, math.min(bed.halfLength * 0.55, offset.y))
    local pos = bed.center + (bed.axisX * (clampedX + autoLoadCfg.offsetSide)) + (bed.axisY * (clampedY + autoLoadCfg.offsetForward)) + (bed.axisZ * (bed.halfHeight + autoLoadCfg.dropHeight + autoLoadCfg.offsetUp))
    local rockId = cargoTools.spawnProp(mat.model, mat.config, pos, rot, { cling = false, safeSpawn = false })
    if rockId then
      table.insert(state.propIds, rockId)
      spawned = spawned + 1
    end
  end
  if spawned <= 0 then
    showUi("hud", hudPayload({ notice = "Could not load ore" }))
    return false
  end
  state.phase = "toDropoff"
  pickupPromptState = nil
  state.deliveredThisRun = 0
  state.truckId = truck:getID()
  setMarker(dropOffTargetPos(), false)
  showUi("hud", hudPayload({ notice = "Ore loaded into HT-55" }))
  return true
end

function M.closeUi()
  if lastUiMode == "summary" then
    require("overhaul/lib/save/store").request("miningHaul:closeUi")
  end
  hideUi()
end

function M.showOffice()
  if state.active then
    showUi("office", { canRepair = true, canEnd = true })
  else
    showUi("intro", {
      title = "HT-55 Driver Program",
      body = "The Mining Company is looking for temporary drivers to move ore from active excavation zones to the processing facility."
    })
  end
end

function M.dismissResult()
  if state.active then showUi("hud", hudPayload()) else hideUi() end
end

function M.processOre()
  if not state.active then return false end
  local ratio = deliveredLoadRatio and deliveredLoadRatio() or 0
  if ratio < runtimeConfig.optionalDetection.minDeliveryRatio then
    local notice = pruneDeadProps() > 0 and "Tracked ore is not in the hopper" or "No tracked ore remains"
    showUi("hud", hudPayload({ notice = notice }))
    return false
  end
  local deliveredTons = deliveredTonsFromRatio(ratio)
  local payPerTon = miningPayPerTon()
  local pay = math.max(0, math.floor(deliveredTons * payPerTon + 0.5))
  local diamond = false
  local diamondBonus = 0
  if deliveredTons > 0 and math.random() < economy.diamondChance then
    diamond = true
    diamondBonus = economy.diamondBonus
    state.diamondsFound = state.diamondsFound + 1
  end
  local totalPay = pay + diamondBonus
  state.oreDelivered = state.oreDelivered + deliveredTons
  state.deliveriesCompleted = state.deliveriesCompleted + 1
  state.grossEarnings = state.grossEarnings + totalPay
  clearPickupResources()
  chooseNextPickup()
  state.phase = "toPickup"
  state.deliveredThisRun = 0
  pickupPromptState = nil
  spawnPickupResources()
  payDelivery(totalPay)
  setMarker(spotPos(currentPickupName()), false)
  local notice = tostring(deliveredTons) .. " tons processed"
  if diamond then notice = notice .. " + diamond bonus" end
  showUi("hud", hudPayload({ notice = notice }))
  return true
end

function M.selectLocation(id)
  if state.active then return false, "End the current mining shift first." end
  loadConfig()
  if not locationConfigs[id] then return false, "Mining location unavailable." end
  selectedLocationId = id
  config = locationConfigs[id]
  economy = resolvedEconomy(config.economy)
  runtimeConfig = resolvedSpawnSettings(config)
  sites, sitesChecked = nil, false
  return loadSites() ~= nil
end

function M.getLocations()
  loadConfig()
  local result = {}
  for id, data in pairs(locationConfigs) do result[#result + 1] = {id = id, name = data.label} end
  table.sort(result, function(a, b) return a.id < b.id end)
  return result
end

-- Game hooks ------------------------------------------------------------------------------------

function M.onGetRawPoiListForLevel(levelIdentifier, elements)
  if not (overhaul_career_career and overhaul_career_career.isActive()) then return end
  if not ensureAvailable() or levelIdentifier ~= getCurrentLevelIdentifier() then return end
  for _, data in pairs(locationConfigs) do
    local officePos = locationOffice(data)
    if officePos then
      local radius = data.detection.officeRadius
      local label = data.label
      table.insert(elements, {
        id = "miningHaulOffice_" .. data.id,
        data = {
          type = "miningHaul",
          pos = officePos,
          icon = "poi_pickup_round",
          name = label,
          description = "Start or end an HT-55 hauling shift."
        },
        markerInfo = {
          inspectVehicleMarker = {
            pos = officePos,
            radius = radius,
            vehicleHeight = 4
          },
          bigmapMarker = {
            pos = officePos,
            icon = "poi_pickup_round",
            name = label,
            description = "Start or end an HT-55 hauling shift.",
            cardIcon = "boxTruck",
          },
          clusterType = "activity"
        },
        pos = officePos,
        radius = radius
      })
    end
  end
end

M.onUpdate = onUpdate
M.isAvailable = function() return ensureAvailable() end
M.onWorldReadyState = onWorldReadyState
M.restoreWorld = restoreWorld
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = function()
  clearPickupResources()
  -- Retain the disposed adapter so a late save cannot write this retired load's state.
  if persistence then persistence.dispose() end
  -- Keep coverage metadata without retaining this load's callbacks or replacing a newer load.
  if not saveStore.getKey("jobs.miningHaul") then
    registerSaveKey()
  end
end
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.onOverhaulBeforeSetProfile = function()
  savedStateLoaded = false
  loadedProfileName = nil
  deferredLegacyState = nil
end

M.activity = require('overhaul/jobs/miningHaul/activity')(M)

return M
