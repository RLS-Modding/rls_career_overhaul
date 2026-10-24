-- Clean Up Club spot progress, rewards and career persistence.
-- Read configuration, saved state, spot helpers, reward operations, public actions and game hooks.
local recordCleanup = require("overhaul/lib/progression/logbookFeed").register("overhaul.cleanupCompleted", {
  title = "Cleanup completed", label = "Jobs", icon = "checkmark"
}, "jobs/cleanupClub.lua")

local M = {}
local LOG_TAG = "cleanupClub"
local levelData = require("overhaul/lib/world/levelData")
local jsonCatalog = require("overhaul/lib/platform/jsonCatalog")
local REWARDS_FILE = "/gameplay/overhaul/cleanupClub/rewards.json"

-- Config ------------------------------------------------------------------------------------------

local SAVE_DIR = "/career/rls_career"
local MAX_ACTIVE_PER_MAP = 10
local SPAWN_INTERVAL_SECONDS = 30 * 60
local DEFAULT_REWARD_CONFIG = {
  fallbackMoney = {min = 500, max = 1000},
  rewards = {
    {id = "owned_part_small", type = "ownedVehiclePart", weight = 5, value = {min = 100, max = 2000}},
    {id = "owned_part_large", type = "ownedVehiclePart", weight = 4, value = {min = 3000, max = 10000}},
    {id = "money_small", type = "money", weight = 3, money = {min = 1000, max = 3000}},
    {id = "money_medium", type = "money", weight = 2, money = {min = 5000, max = 10000}},
    {id = "vehicle_junker", type = "vehicle", weight = 2, value = {min = 0, max = 10000}},
    {id = "vehicle_project", type = "vehicle", weight = 1, value = {min = 10000, max = 200000}}
  }
}

-- State -------------------------------------------------------------------------------------------

local state = {version = 1, maps = {}, totalCleared = 0}

local rewardConfig
local currentLevelId
local currentSitesPath
local locationConfig = {}
local sitesSupported = false
local spotsById = {}
local spotOrder = {}
local debrisObjects = {}
local initialized = false
local stateLoaded = false
local stagedSpotId
local dismissedSpotId
local lastPromptSpot
local lastPromptReward
local lastPromptRewardType

-- Persistence ownership -------------------------------------------------------------------------

-- Register this feature's file metadata before save hooks run.
require("overhaul/lib/save/store").registerKeys({
  {key = "jobs.cleanupClub", owner = "overhaul_jobs_cleanupClub", files = {"career/rls_career/cleanupClub.json"}, phase = "profile", required = true},
})
-- Resolve the service at each operation, including after a service-only Lua reload.
local saveSystem = setmetatable({}, {__index = function(_, name)
  return overhaul_career_saveSystem and overhaul_career_saveSystem[name]
end})
local persistence = require('overhaul/lib/save/store').bind(saveSystem).feature('jobs.cleanupClub', {
  owner = 'overhaul_jobs_cleanupClub', files = {'career/rls_career/cleanupClub.json'},
  root = 'slot', phase = 'profile', required = true, writer = {pretty = true},
  restore = function(context) return context.read() end,
})

-- Reward configuration --------------------------------------------------------------------------

local function tableCount(value)
  local count = 0
  for _ in pairs(value or {}) do count = count + 1 end
  return count
end

local function isCareerActive()
  return overhaul_career_career and overhaul_career_career.isActive() == true
end

local function notify(message, category)
  ui_message(message, 5, category or "info", category or "info")
end

local function clampRange(range, fallbackMin, fallbackMax)
  if type(range) ~= "table" then return {min = fallbackMin, max = fallbackMax} end
  local minValue = tonumber(range.min) or fallbackMin
  local maxValue = tonumber(range.max) or fallbackMax or minValue
  if maxValue < minValue then minValue, maxValue = maxValue, minValue end
  return {min = minValue, max = maxValue}
end

local function randomWholeRange(range)
  range = clampRange(range, 0, 0)
  local minValue = math.floor(range.min or 0)
  local maxValue = math.floor(range.max or minValue)
  if maxValue <= minValue then return minValue end
  return math.random(minValue, maxValue)
end

local function valueInRange(value, range)
  value = tonumber(value)
  if not value or type(range) ~= "table" then return false end
  return value >= (tonumber(range.min) or 0) and value <= (tonumber(range.max) or math.huge)
end

local function loadRewards()
  if rewardConfig then return rewardConfig end
  local loaded = jsonReadFile(REWARDS_FILE)
  if type(loaded) ~= "table" or type(loaded.rewards) ~= "table" or #loaded.rewards == 0 then
    rewardConfig = deepcopy(DEFAULT_REWARD_CONFIG)
    return rewardConfig
  end
  local rewards = {}
  for _, raw in ipairs(loaded.rewards) do
    if type(raw) == "table" and raw.type and (tonumber(raw.weight) or 0) > 0 then
      local reward = deepcopy(raw)
      reward.weight = tonumber(raw.weight) or 0
      if reward.type == "money" then
        reward.money = clampRange(reward.money, tonumber(raw.amount) or 500, tonumber(raw.amount) or 500)
      elseif reward.type == "ownedVehiclePart" or reward.type == "vehicle" then
        reward.value = clampRange(reward.value, 0, math.huge)
      end
      rewards[#rewards + 1] = reward
    end
  end
  if #rewards == 0 then
    rewardConfig = deepcopy(DEFAULT_REWARD_CONFIG)
  else
    rewardConfig = {
      fallbackMoney = clampRange(loaded.fallbackMoney, 500, 1000),
      rewards = rewards,
      shapes = loaded.shapes,
      vehicleRewardSellerIds = loaded.vehicleRewardSellerIds
    }
  end
  return rewardConfig
end

local function selectReward(requestedRewardId)
  local config = loadRewards()
  local pool = config.rewards or DEFAULT_REWARD_CONFIG.rewards
  if requestedRewardId then
    for _, reward in ipairs(pool) do
      if reward.id == requestedRewardId then return deepcopy(reward) end
    end
    return nil
  end
  local totalWeight = 0
  for _, reward in ipairs(pool) do totalWeight = totalWeight + math.max(tonumber(reward.weight) or 0, 0) end
  if totalWeight <= 0 then return pool[1] and deepcopy(pool[1]) or nil end
  local pick = math.random() * totalWeight
  local running = 0
  for _, reward in ipairs(pool) do
    running = running + math.max(tonumber(reward.weight) or 0, 0)
    if pick <= running then return deepcopy(reward) end
  end
  return pool[#pool] and deepcopy(pool[#pool]) or nil
end

-- Saved spot progress ---------------------------------------------------------------------------

local function ensureState()
  if type(state) ~= "table" then state = {} end
  state.version = tonumber(state.version) or 1
  state.maps = type(state.maps) == "table" and state.maps or {}
  state.totalCleared = math.max(0, math.floor(tonumber(state.totalCleared) or 0))
  for mapId, mapState in pairs(state.maps) do
    if type(mapState) ~= "table" then
      state.maps[mapId] = {elapsedSeconds = 0, active = {}, clearedCount = 0}
    else
      mapState.elapsedSeconds = math.max(0, tonumber(mapState.elapsedSeconds) or 0)
      mapState.active = type(mapState.active) == "table" and mapState.active or {}
      mapState.clearedCount = math.max(0, math.floor(tonumber(mapState.clearedCount) or 0))
    end
  end
end

local function getMapState(levelId)
  if not levelId then return nil end
  ensureState()
  local mapState = state.maps[levelId]
  if type(mapState) ~= "table" then
    mapState = {elapsedSeconds = 0, active = {}, clearedCount = 0}
    state.maps[levelId] = mapState
  end
  mapState.elapsedSeconds = math.max(0, tonumber(mapState.elapsedSeconds) or 0)
  mapState.active = type(mapState.active) == "table" and mapState.active or {}
  mapState.clearedCount = math.max(0, math.floor(tonumber(mapState.clearedCount) or 0))
  return mapState
end

local function currentSaveRoot()
  local _, profilePath = overhaul_career_saveSystem.getCurrentProfile()
  if profilePath then return profilePath end
  local _, slotPath = overhaul_career_saveSystem.getCurrentSaveSlot()
  return slotPath
end

local function ensureSaveDirectory(saveRoot, writer)
  if not saveRoot then return end
  local path = saveRoot .. SAVE_DIR
  if not writer.exists(path) then writer.mkdir(path, true) end
end

local function saveStateToRoot(saveRoot, writer)
  if not saveRoot then return false end
  if not stateLoaded then return false end
  if not persistence.isCurrent() then return false end
  ensureState()
  ensureSaveDirectory(saveRoot, writer)
  return persistence.write(saveRoot, deepcopy(state)) == true
end

local function loadState()
  local saveRoot = currentSaveRoot()
  local loaded = saveRoot and persistence.restore(saveRoot) or nil
  state = type(loaded) == "table" and loaded or {version = 1, maps = {}, totalCleared = 0}
  ensureState()
  stateLoaded = true
end

-- Spot names and positions ----------------------------------------------------------------------

local function asVec3(value, fallback)
  if type(value) == "table" then
    return vec3(tonumber(value[1]) or 0, tonumber(value[2]) or 0, tonumber(value[3]) or 0)
  end
  return fallback or vec3()
end

local function getFirstTag(rawSpot)
  local tags = rawSpot and rawSpot.customFields and rawSpot.customFields.tags
  if type(tags) ~= "table" then return nil end
  local first = tags[1] or tags[0]
  if type(first) == "string" and first ~= "" then return first end
  for key, value in pairs(tags) do
    if type(value) == "string" and value ~= "" then return value end
    if type(key) == "string" and value == true then return key end
  end
  return nil
end

local NEARBY_FACILITY_TYPES = {"garage", "gasStation", "dealership", "deliveryProvider", "tuningShop", "businessGarage", "passiveBusiness", "engineShop"}

local function facilityCenter(facility)
  local center, count = vec3(0, 0, 0), 0
  for _, pair in ipairs(facility and facility.doors or {}) do
    local obj = type(pair) == "table" and pair[1] and scenetree.findObject(pair[1])
    if obj then
      center = center + obj:getPosition()
      count = count + 1
    end
  end
  if count == 0 then return nil end
  return center / count
end

local function spotDisplayName(spot)
  if not spot then return "Clean Up Club" end
  if spot.displayName then return spot.displayName end
  local name = spot.name
  if type(name) ~= "string" or name == "" or name == spot.id then
    name = "Parking area"
    if spot.pos then
      local bestName, bestDist = nil, 400
      for _, facType in ipairs(NEARBY_FACILITY_TYPES) do
        local ok, list = pcall(overhaul_world_facilities.getFacilitiesByType, facType, currentLevelId)
        for _, fac in ipairs(ok and type(list) == "table" and list or {}) do
          local center = facilityCenter(fac)
          local dist = center and center:distance(spot.pos)
          local facName = fac.name and _tr(fac.name)
          if dist and dist < bestDist and type(facName) == "string" and facName ~= "" then
            bestName, bestDist = facName, dist
          end
        end
      end
      if bestName then name = "Parking area near " .. bestName end
    end
  end
  spot.displayName = name
  return name
end

local function interactionRadius(scale)
  if not scale then return 12 end
  return math.max(scale:length() / 2 + 4, 12)
end

local function objectToken(value)
  local token = tostring(value or "spot"):gsub("[^%w_%-]", "_")
  return token ~= "" and token or "spot"
end

-- Debris ownership and visibility ---------------------------------------------------------------

local function hidePrompt(force)
  local wasVisible = stagedSpotId ~= nil
  stagedSpotId = nil
  lastPromptSpot = nil
  lastPromptReward = nil
  lastPromptRewardType = nil
  if wasVisible or force then
    guihooks.trigger("CleanupClubPromptUi", {visible = false})
  end
end

local function stripObjectCollision(object)
  if not object then return end
  if object.setHidden then pcall(function() object:setHidden(true) end) end
  if object.disableCollision then pcall(function() object:disableCollision() end) end
  if object.setField then
    pcall(function() object:setField("collisionType", 0, "None") end)
  end
end

local function deleteObjectForSpot(spot)
  if not spot then return end
  local object = debrisObjects[spot.id]
  if not object then object = scenetree.findObject(spot.objectName) end
  stripObjectCollision(object)
  if object and object.delete then object:delete() end
  debrisObjects[spot.id] = nil
end

local function spotObjectStillPresent(spot)
  if not spot then return false end
  if debrisObjects[spot.id] then return true end
  if not spot.objectName then return false end
  return scenetree.findObject(spot.objectName) ~= nil
end

local function waitForSpotCollisionClear(job, spot)
  local waited = 0
  while spotObjectStillPresent(spot) and waited < 1.0 do
    job.sleep(0.05)
    waited = waited + 0.05
  end
  -- castRayStatic can keep the deleted mesh for a tick after scenetree removal.
  job.sleep(0.2)
end

local function clearRuntimeObjects()
  for _, object in pairs(debrisObjects) do
    if object and object.delete then object:delete() end
  end
  debrisObjects = {}
  for _, spot in ipairs(spotOrder) do
    local object = scenetree.findObject(spot.objectName)
    if object and object.delete then object:delete() end
  end
end

local function rewardShape(reward)
  local shapes = locationConfig.shapes or {}
  local path = shapes[reward and reward.type == "vehicle" and "vehicle" or "debris"]
  return levelData.assetPath(currentLevelId, path)
end

local function ensureObjectForSpot(spot, reward)
  if not spot then return nil end
  local shapeName = rewardShape(reward)
  if not shapeName then return nil end
  local existing = debrisObjects[spot.id]
  if not existing then existing = scenetree.findObject(spot.objectName) end
  if existing and existing.shapeName ~= shapeName then
    existing:delete()
    existing = nil
  end
  if existing then
    if existing.setHidden then existing:setHidden(false) end
    debrisObjects[spot.id] = existing
    return existing
  end
  local object = createObject("TSStatic")
  if not object then return nil end
  object.shapeName = shapeName
  object:setPosRot(
    spot.pos.x, spot.pos.y, spot.pos.z,
    spot.rot[1] or 0, spot.rot[2] or 0, spot.rot[3] or 0, spot.rot[4] or 1
  )
  object.scale = vec3(1, 1, 1)
  object.useInstanceRenderData = true
  object:setField("canSave", 0, "0")
  object:setField("canSaveDynamicFields", 0, "1")
  object.canSave = false
  object:registerObject(spot.objectName)
  debrisObjects[spot.id] = object
  return object
end

-- Map reconciliation and generation -------------------------------------------------------------

local function reconcileCurrentMapState()
  if not currentLevelId or not sitesSupported then return false end
  local changed = false
  local mapState = getMapState(currentLevelId)
  for spotId, active in pairs(mapState.active) do
    if not spotsById[spotId] then
      mapState.active[spotId] = nil
      changed = true
    elseif type(active) ~= "table" then
      mapState.active[spotId] = {reward = selectReward()}
      changed = true
    elseif type(active.reward) ~= "table" then
      active.reward = selectReward()
      changed = true
    end
  end
  local cap = math.min(MAX_ACTIVE_PER_MAP, #spotOrder)
  if tableCount(mapState.active) >= cap and mapState.elapsedSeconds ~= 0 then
    mapState.elapsedSeconds = 0
    changed = true
  end
  return changed
end

local function rebuildCurrentObjects()
  if not currentLevelId or not sitesSupported then return end
  local mapState = getMapState(currentLevelId)
  for _, spot in ipairs(spotOrder) do
    local active = mapState.active[spot.id]
    if active then
      ensureObjectForSpot(spot, active.reward)
    else
      deleteObjectForSpot(spot)
    end
  end
end

local function positionFromData(value)
  if type(value) ~= "table" then return nil end
  local x, y, z = value.x or value[1], value.y or value[2], value.z or value[3]
  if not jsonCatalog.finite(x) or not jsonCatalog.finite(y) or not jsonCatalog.finite(z) then return nil end
  return vec3(x, y, z)
end

local function loadCleanupCollection(levelId, collection, seen)
  local sitesPath = levelData.assetPath(levelId, collection.sitesFile)
  local raw = sitesPath and jsonReadFile(sitesPath)
  if type(raw) ~= "table" or type(raw.parkingSpots) ~= "table" then
    log("W", LOG_TAG, "Cleanup collection unavailable: " .. tostring(sitesPath))
  else
    for index, rawSpot in ipairs(raw.parkingSpots) do
      local id = type(rawSpot.name) == "string" and rawSpot.name:match("^%s*(.-)%s*$") or ""
      if id ~= "" and collection.id then id = collection.id .. "::" .. id end
      if id == "" then
        log("W", LOG_TAG, string.format("Ignoring cleanup spot %d without a name in %s", index, sitesPath))
      elseif seen[id] then
        log("W", LOG_TAG, string.format("Ignoring duplicate cleanup spot '%s' in %s", id, sitesPath))
      elseif not positionFromData(rawSpot.pos) then
        log("W", LOG_TAG, string.format("Ignoring cleanup spot '%s' with invalid position (requires 3 finite numbers) in %s", id, sitesPath))
      else
        seen[id] = true
        local scale = asVec3(rawSpot.scl, vec3(2.5, 6, 3))
        local spot = {
          id = id,
          name = getFirstTag(rawSpot) or id,
          pos = positionFromData(rawSpot.pos),
          rot = type(rawSpot.rot) == "table" and rawSpot.rot or {0, 0, 0, 1},
          scale = scale,
          radius = interactionRadius(scale),
          objectName = string.format("cleanupClub_%s_%03d_%s", objectToken(levelId), index, objectToken(id))
        }
        spotsById[id] = spot
        spotOrder[#spotOrder + 1] = spot
      end
    end
  end
end

local function loadCurrentSites(force)
  local levelId = getCurrentLevelIdentifier()
  if not force and levelId == currentLevelId and currentSitesPath then return sitesSupported end
  clearRuntimeObjects()
  hidePrompt()
  dismissedSpotId = nil
  currentLevelId = levelId
  local global = loadRewards()
  local localConfig = (levelId and jsonReadFile(levelData.assetPath(levelId, "overhaul/cleanup.json"))) or {}
  locationConfig = {
    shapes = localConfig.shapes or global.shapes,
    vehicleRewardSellerIds = localConfig.vehicleRewardSellerIds or global.vehicleRewardSellerIds or {},
  }
  local collections = localConfig.sitesFiles or (localConfig.sitesFile and {{sitesFile = localConfig.sitesFile}})
  currentSitesPath = levelId and collections and levelId or nil
  sitesSupported = false
  spotsById = {}
  spotOrder = {}
  if not currentSitesPath then log("W", LOG_TAG, "Cleanup disabled: missing overhaul/cleanup.json sitesFile/sitesFiles"); return false end
  for _, role in ipairs({"vehicle", "debris"}) do
    local path = locationConfig.shapes and levelData.assetPath(levelId, locationConfig.shapes[role])
    if not path or not FS:fileExists(path) then
      log("W", LOG_TAG, "Cleanup disabled: unavailable " .. role .. " shape " .. tostring(path)); return false
    end
  end
  local seen = {}
  for _, collection in ipairs(collections) do loadCleanupCollection(levelId, collection, seen) end
  sitesSupported = #spotOrder > 0
  if sitesSupported then
    reconcileCurrentMapState()
    rebuildCurrentObjects()
  end
  return sitesSupported
end

local function inactiveSpots()
  local result = {}
  if not currentLevelId or not sitesSupported then return result end
  local mapState = getMapState(currentLevelId)
  for _, spot in ipairs(spotOrder) do
    if not mapState.active[spot.id] then result[#result + 1] = spot end
  end
  return result
end

local function generateCleanup(requestedSpot, requestedRewardId)
  if not loadCurrentSites(false) or not currentLevelId then return false, "This map has no cleanup sites." end
  local mapState = getMapState(currentLevelId)
  local cap = math.min(MAX_ACTIVE_PER_MAP, #spotOrder)
  if tableCount(mapState.active) >= cap then return false, "This map is at its cleanup cap." end
  local spot = requestedSpot
  if spot then
    if not spotsById[spot.id] then return false, "Cleanup spot is not on the current map." end
    if mapState.active[spot.id] then return false, "Cleanup spot is already active." end
  else
    local candidates = inactiveSpots()
    if #candidates == 0 then return false, "No inactive cleanup spots are available." end
    spot = candidates[math.random(1, #candidates)]
  end
  local reward = selectReward(requestedRewardId)
  if requestedRewardId and not reward then return false, "Unknown cleanup reward: " .. tostring(requestedRewardId) end
  reward = reward or selectReward()
  mapState.active[spot.id] = {reward = reward}
  mapState.elapsedSeconds = 0
  ensureObjectForSpot(spot, reward)
  return true, spot
end

-- Reward settlement -----------------------------------------------------------------------------

local function grantMoneyReward(amount, spot)
  amount = math.max(0, math.floor(tonumber(amount) or 0))
  if amount <= 0 or not overhaul_career_career.isActive() then return false end
  local change = {money = amount}
  local reason = {label = spotDisplayName(spot) .. " cleanup reward", tags = {"gameplay", "cleanupClub"}}
  -- This map owner outlives payment; the wallet still accepts its legacy reward during a reload.
  local payment = overhaul_career_economy_payment
  if payment and type(payment.payout) == "function" then
    local accepted, problem = payment.payout(require("overhaul/lib/finance/metadata").tagPayout({amount = change.money, reason = reason}, "activity:cleanupClub", {vehicleRelated = false, locationId = spot.id, locationName = spotDisplayName(spot)}))
    -- Legacy wallet mutation had no refusal branch; keep the same completion without retry.
    if accepted ~= true then log("W", LOG_TAG, "Cleanup payout refused: " .. tostring(problem))
    else spot.logbookReward = amount end
  else
    overhaul_career_economy_playerAttributes.addAttributes(change, require("overhaul/lib/finance/metadata").tag(reason, "activity:cleanupClub", {vehicleRelated = false, locationId = spot.id, locationName = spotDisplayName(spot)}))
  end
  notify("You found $" .. tostring(amount) .. " in the debris.", "info")
  return true
end

local function grantFallbackMoney(spot)
  return grantMoneyReward(randomWholeRange(loadRewards().fallbackMoney), spot)
end

local function getOwnedPartRewardCandidates(range)
  local candidates = {}
  if not overhaul_career_career.isActive() then return candidates end
  local inventory = overhaul_career_parts_partInventory.getInventory() or {}
  local vehicles = overhaul_career_garage_inventory.getVehicles() or {}
  for _, part in pairs(inventory) do
    local vehicle = part and part.location and vehicles[part.location]
    if vehicle and vehicle.owned and tonumber(part.location) and tonumber(part.location) > 0 and valueInRange(part.value, range) then
      candidates[#candidates + 1] = part
    end
  end
  return candidates
end

local function getPartVehicleLabel(part)
  local modelKey = part and part.vehicleModel
  if modelKey then
    local modelData = core_vehicles.getModel(modelKey)
    local modelInfo = modelData and modelData.model
    if type(modelInfo) == "table" then
      local brand = modelInfo.Brand or modelInfo.brand
      local name = modelInfo.Name or modelInfo.name
      if brand and name then return tostring(brand) .. " " .. tostring(name) end
      if name then return tostring(name) end
    end
  end
  if overhaul_career_career.isActive() and part and part.location then
    local vehicle = (overhaul_career_garage_inventory.getVehicles() or {})[part.location]
    if vehicle and vehicle.niceName then return tostring(vehicle.niceName) end
    if vehicle and vehicle.model then return tostring(vehicle.model) end
  end
  return tostring(modelKey or "vehicle")
end

local function grantOwnedVehiclePartReward(reward)
  if not overhaul_career_career.isActive() then return false end
  local candidates = getOwnedPartRewardCandidates(reward.value)
  if #candidates == 0 then return false end
  local sourcePart = candidates[math.random(1, #candidates)]
  local vehicleLabel = getPartVehicleLabel(sourcePart)
  local part = deepcopy(sourcePart)
  part.location = 0
  part.partId = nil
  part.partShopId = nil
  part.finalValue = nil
  part.sourcePart = nil
  part.rewardSource = "cleanupClub"
  overhaul_career_parts_partInventory.addPartToInventory(part)
  local partLabel = type(part.description) == "table" and part.description.description or part.name or "part"
  notify("You found a " .. tostring(partLabel) .. " for a " .. tostring(vehicleLabel) .. ".", "info")
  return true
end

local function getVehicleRewardCandidates(range)
  local candidates = {}
  if not overhaul_career_career.isActive() then return candidates end
  for _, vehicleInfo in ipairs(overhaul_career_market_vehicleShopping.getVehiclesInShop() or {}) do
    if vehicleInfo and valueInRange(vehicleInfo.Value or vehicleInfo.value or vehicleInfo.marketValue, range) then
      candidates[#candidates + 1] = vehicleInfo
    end
  end
  if #candidates > 0 then return candidates end
  for _, sellerId in ipairs(locationConfig.vehicleRewardSellerIds) do
    for _, vehicleInfo in ipairs(overhaul_career_market_vehicleShopping.getRandomVehicleFromCache(sellerId, 30) or {}) do
      if vehicleInfo and valueInRange(vehicleInfo.Value or vehicleInfo.value or vehicleInfo.marketValue, range) then
        vehicleInfo = deepcopy(vehicleInfo)
        vehicleInfo.sellerId = vehicleInfo.sellerId or sellerId
        vehicleInfo.sellerName = vehicleInfo.sellerName or "Clean Up Club Recovery"
        vehicleInfo.Mileage = tonumber(vehicleInfo.Mileage) or 0
        vehicleInfo.year = tonumber(vehicleInfo.year) or 1985
        candidates[#candidates + 1] = vehicleInfo
        if #candidates >= 25 then return candidates end
      end
    end
  end
  return candidates
end

local function grantVehicleReward(reward, spot)
  if not overhaul_career_career.isActive() then return false end
  local candidates = getVehicleRewardCandidates(reward.value)
  if #candidates == 0 and reward.value and (tonumber(reward.value.max) or 0) < 10000 then
    candidates = getVehicleRewardCandidates({min = tonumber(reward.value.min) or 0, max = 10000})
  end
  if #candidates == 0 then
    notify("Clean Up Club could not find a matching recovery vehicle, paying fallback cash.", "warning")
    return false
  end
  local vehicleInfo = deepcopy(candidates[math.random(1, #candidates)])
  local spawnTransform = spot and {
    pos = {spot.pos.x, spot.pos.y, spot.pos.z},
    rot = deepcopy(spot.rot)
  } or nil
  if overhaul_career_market_vehicleShopping.grantRewardVehicle(vehicleInfo, "Clean Up Club cleanup reward", {
    ignoreGarageLimit = true,
    randomPaint = true,
    spawnTransform = spawnTransform
  }) then
    notify("Clean Up Club recovered a vehicle: " .. tostring(vehicleInfo.niceName or vehicleInfo.Name or vehicleInfo.key or "vehicle") .. ".", "info")
    return true
  end
  notify("Clean Up Club vehicle recovery failed, paying fallback cash.", "warning")
  return false
end

local function grantReward(reward, spot)
  if not reward then return grantFallbackMoney(spot) end
  local granted = false
  if reward.type == "money" then
    granted = grantMoneyReward(reward.amount or randomWholeRange(reward.money), spot)
  elseif reward.type == "ownedVehiclePart" then
    granted = grantOwnedVehiclePartReward(reward)
  elseif reward.type == "vehicle" then
    core_jobsystem.create(function(job)
      waitForSpotCollisionClear(job, spot)
      if not grantVehicleReward(reward, spot) then
        grantFallbackMoney(spot)
      end
      if overhaul_career_saveSystem and overhaul_career_saveSystem.saveCurrent then
        require("overhaul/lib/save/store").request("cleanupClub:grantReward")
      end
    end)
    return true
  end
  return granted or grantFallbackMoney(spot)
end

-- Interaction prompts ---------------------------------------------------------------------------

local function promptPayload(spot, reward)
  local isVehicle = reward and reward.type == "vehicle"
  return {
    visible = true,
    payload = {
      title = "Clean Up Club",
      spotId = spot.id,
      siteName = spotDisplayName(spot),
      kind = isVehicle and "vehicle" or "debris",
      actionLabel = isVehicle and "Open Container" or "Clear Debris"
    }
  }
end

local function updatePrompt(force)
  if not isCareerActive() or not sitesSupported or not currentLevelId then
    hidePrompt(force)
    return
  end
  local mapState = getMapState(currentLevelId)
  if not next(mapState.active) then
    dismissedSpotId = nil
    hidePrompt(force)
    return
  end
  local vehicle = getPlayerVehicle(0)
  if not vehicle then
    hidePrompt(force)
    return
  end
  local playerPos = vehicle:getPosition()
  local nearest, nearestDistance
  for _, spot in ipairs(spotOrder) do
    if mapState.active[spot.id] then
      local deltaX, deltaY, deltaZ = spot.pos.x - playerPos.x, spot.pos.y - playerPos.y, spot.pos.z - playerPos.z
      local distance = deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ
      if distance <= spot.radius * spot.radius and (not nearestDistance or distance < nearestDistance) then
        nearest = spot
        nearestDistance = distance
      end
    end
  end
  if nearest then
    if dismissedSpotId == nearest.id then
      if force then hidePrompt(true) end
      return
    end
    stagedSpotId = nearest.id
    local reward = mapState.active[nearest.id].reward
    local rewardType = reward and reward.type
    if force or lastPromptSpot ~= nearest or lastPromptReward ~= reward or lastPromptRewardType ~= rewardType then
      guihooks.trigger("CleanupClubPromptUi", promptPayload(nearest, reward))
      lastPromptSpot = nearest
      lastPromptReward = reward
      lastPromptRewardType = rewardType
    end
  else
    dismissedSpotId = nil
    hidePrompt(force)
  end
end

function M.requestPromptUi()
  updatePrompt(true)
end

local function updateGeneration(dtSim)
  if not sitesSupported or not currentLevelId then return end
  local mapState = getMapState(currentLevelId)
  local cap = math.min(MAX_ACTIVE_PER_MAP, #spotOrder)
  if cap <= 0 then return end
  if tableCount(mapState.active) >= cap then
    if mapState.elapsedSeconds ~= 0 then
      mapState.elapsedSeconds = 0
    end
    return
  end
  local elapsed = math.max(tonumber(dtSim) or 0, 0)
  if elapsed <= 0 then return end
  mapState.elapsedSeconds = math.min(SPAWN_INTERVAL_SECONDS, mapState.elapsedSeconds + elapsed)
  if mapState.elapsedSeconds >= SPAWN_INTERVAL_SECONDS then
    local generated = generateCleanup()
    if not generated then mapState.elapsedSeconds = 0 end
  end
end

function M.completeCleanup(spotId)
  if not isCareerActive() or not loadCurrentSites(false) then return false end
  local spot = spotsById[spotId]
  local mapState = currentLevelId and getMapState(currentLevelId)
  local active = spot and mapState and mapState.active[spotId]
  if not active then return false end
  mapState.active[spotId] = nil
  mapState.clearedCount = mapState.clearedCount + 1
  state.totalCleared = state.totalCleared + 1
  if stagedSpotId == spotId then hidePrompt() end
  deleteObjectForSpot(spot)
  spot.logbookReward = nil
  grantReward(active.reward, spot)
  recordCleanup({detail = spotDisplayName(spot) .. " / " .. tostring(active.reward and active.reward.type or "Debris cleared"),
    money = spot.logbookReward})
  spot.logbookReward = nil
  require("overhaul/lib/save/store").request("cleanupClub:completeCleanup")
  return true
end

function M.closePrompt()
  dismissedSpotId = stagedSpotId
  hidePrompt()
end

-- Debug actions ---------------------------------------------------------------------------------

local function prepareDebugSession()
  if isCareerActive() or not stateLoaded then return end
  clearRuntimeObjects()
  hidePrompt()
  dismissedSpotId = nil
  state = {version = 1, maps = {}, totalCleared = 0}
  stateLoaded = false
  currentLevelId = nil
  currentSitesPath = nil
  sitesSupported = false
  spotsById = {}
  spotOrder = {}
end

function M.debugGenerateCleanup(spotKey, rewardId)
  if not isCareerActive() then
    local reason = "Clean Up Club debug spawning requires Career Mode."
    notify(reason, "warning")
    return false, reason
  end
  prepareDebugSession()
  if not loadCurrentSites(false) then return false, "This map has no cleanup sites." end
  local requestedSpot
  if spotKey then
    local wanted = string.lower(tostring(spotKey))
    for _, spot in ipairs(spotOrder) do
      if string.lower(spot.id) == wanted or string.lower(spot.name) == wanted then
        requestedSpot = spot
        break
      end
    end
    if not requestedSpot then return false, "Cleanup spot not found: " .. tostring(spotKey) end
  end
  local generated, result = generateCleanup(requestedSpot, rewardId)
  if not generated then return false, result end
  notify("Debug spawned cleanup at " .. tostring(result.name) .. ".", "info")
  return true, {id = result.id, name = result.name, reward = deepcopy(getMapState(currentLevelId).active[result.id].reward)}
end

function M.debugForceSpawn(count, rewardId)
  if type(count) == "string" and rewardId == nil then
    rewardId = count
    count = 1
  end
  count = math.min(MAX_ACTIVE_PER_MAP, math.max(1, math.floor(tonumber(count) or 1)))
  if not isCareerActive() then
    local reason = "Clean Up Club debug spawning requires Career Mode."
    notify(reason, "warning")
    return false, reason
  end
  prepareDebugSession()
  if not loadCurrentSites(false) then return false, "This map has no cleanup sites." end
  local spawned = {}
  local stoppedReason
  for _ = 1, count do
    local generated, result = generateCleanup(nil, rewardId)
    if not generated then
      stoppedReason = result
      break
    end
    spawned[#spawned + 1] = {
      id = result.id,
      name = result.name,
      reward = deepcopy(getMapState(currentLevelId).active[result.id].reward)
    }
  end
  if #spawned == 0 then return false, stoppedReason or "No cleanup was generated." end
  local names = {}
  for _, cleanup in ipairs(spawned) do names[#names + 1] = cleanup.name end
  notify("Debug spawned " .. tostring(#spawned) .. " cleanup" .. (#spawned == 1 and "" or "s") .. ": " .. table.concat(names, ", ") .. ".", "info")
  return true, {
    requested = count,
    spawnedCount = #spawned,
    spawned = spawned,
    stoppedReason = stoppedReason,
    state = M.getDebugState()
  }
end

function M.debugFocusCleanup(spotId)
  if not isCareerActive() then
    local reason = "Clean Up Club debug focus requires Career Mode."
    notify(reason, "warning")
    return false, reason
  end
  prepareDebugSession()
  if not loadCurrentSites(false) then return false, "This map has no cleanup sites." end
  local mapState = currentLevelId and getMapState(currentLevelId)
  local spot
  if spotId then
    spot = spotsById[tostring(spotId)]
    if not spot then return false, "Cleanup spot not found: " .. tostring(spotId) end
    if not mapState.active[spot.id] then return false, "Cleanup spot is not active: " .. tostring(spotId) end
  else
    for _, candidate in ipairs(spotOrder) do
      if mapState.active[candidate.id] then
        spot = candidate
        break
      end
    end
  end
  if not spot then return false, "There are no active cleanups to focus." end
  local cameraPos = vec3(spot.pos.x + 15, spot.pos.y + 15, spot.pos.z + 10)
  local lookDir = vec3(spot.pos.x - cameraPos.x, spot.pos.y - cameraPos.y, spot.pos.z + 1 - cameraPos.z)
  commands.setFreeCamera()
  core_camera.setPosition(0, cameraPos)
  core_camera.setRotation(0, quatFromDir(lookDir))
  core_camera.resetCamera(0)
  notify("Debug camera focused on " .. tostring(spot.name) .. ".", "info")
  return true, {id = spot.id, name = spot.name, pos = {spot.pos.x, spot.pos.y, spot.pos.z}}
end

function M.debugAdvanceTimer(seconds)
  if not isCareerActive() then return false end
  if not loadCurrentSites(false) then return false end
  updateGeneration(math.max(tonumber(seconds) or 0, 0))
  return true, M.getDebugState()
end

function M.getDebugState()
  loadCurrentSites(false)
  local mapState = currentLevelId and getMapState(currentLevelId) or nil
  return {
    levelId = currentLevelId,
    sitesPath = currentSitesPath,
    supported = sitesSupported,
    siteCount = #spotOrder,
    maxActive = math.min(MAX_ACTIVE_PER_MAP, #spotOrder),
    activeCount = mapState and tableCount(mapState.active) or 0,
    elapsedSeconds = mapState and mapState.elapsedSeconds or 0,
    totalCleared = state.totalCleared,
    mapState = mapState and deepcopy(mapState) or nil
  }
end

function M.onGetRawPoiListForLevel()
  -- Discovery is intentionally visual-only. Do not publish map POIs or routes.
end

-- Per-frame update ------------------------------------------------------------------------------

local function onUpdate(_, dtSim)
  if not initialized or not isCareerActive() then return end
  local levelId = getCurrentLevelIdentifier()
  if levelId ~= currentLevelId then loadCurrentSites(true) end
  if not sitesSupported then return end
  updateGeneration(dtSim)
  updatePrompt()
end

-- Lifecycle -------------------------------------------------------------------------------------

local function activate()
  loadState()
  loadRewards()
  loadCurrentSites(true)
  initialized = true
end

local function onExtensionLoaded()
  if isCareerActive() then activate() else initialized = true end
end

local function onOverhaulModulesActivated()
  activate()
end

local function onCareerActivated()
  activate()
end

local function onWorldReadyState(worldReadyState)
  if worldReadyState == 2 and isCareerActive() then loadCurrentSites(true) end
end

local function onClientStartMission()
  if isCareerActive() then loadCurrentSites(true) end
end

local function onClientEndMission()
  hidePrompt()
  dismissedSpotId = nil
  clearRuntimeObjects()
  currentLevelId = nil
  currentSitesPath = nil
  sitesSupported = false
  spotsById = {}
  spotOrder = {}
end

local function onExtensionUnloaded()
  hidePrompt()
  clearRuntimeObjects()
  initialized = false
  persistence.dispose()
end

-- Game hooks ------------------------------------------------------------------------------------

M.onExtensionLoaded = onExtensionLoaded
M.onOverhaulModulesActivated = onOverhaulModulesActivated
M.onCareerActivated = onCareerActivated
M.onWorldReadyState = onWorldReadyState
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onOverhaulSaveCurrentProfile = function(path, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  if not stateLoaded and isCareerActive() then loadState() end
  saveStateToRoot(path, writer)
end
M.onUpdate = onUpdate
M.onExtensionUnloaded = onExtensionUnloaded

M.activity = require('overhaul/jobs/cleanupClub/activity')(M)

return M
