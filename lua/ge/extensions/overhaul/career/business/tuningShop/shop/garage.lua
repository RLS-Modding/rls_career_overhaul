-- Tuning shop: garage zones, personal vehicles and vehicle selection.
-- Read: zone lookup, inventory and personal-vehicle rows, the selection, then the upgrade reads and exports.

local BUSINESS_TYPE = "tuningShop"
local PERSONAL_ID_PREFIX = "personal_"
local SHOP_UPGRADES_TREE = "shop-upgrades"
local QUALITY_OF_LIFE_TREE = "quality-of-life"
local UPGRADE_BONUS_PER_LEVEL = 0.25

local installer = {}

function installer.new(inputs)
  local parts = inputs.parts
  -- Garage zones ----------------------------------------------------------------------------------

  -- The fleet knows the garage first; the facility's garage id is the fallback.
  local function findBusinessGarage(businessId)
    local garage = overhaul_career_business_fleet.getBusinessGarage(BUSINESS_TYPE, businessId)
    if garage then
      return garage
    end

    local business = overhaul_world_facilities.getFacility(BUSINESS_TYPE, businessId)
    if not business then
      return nil
    end
    for _, candidate in ipairs(overhaul_world_facilities.getFacilitiesByType("businessGarage") or {}) do
      if candidate.id == business.businessGarageId then
        return candidate
      end
    end
    return nil
  end

  local function loadGarageZones(garage)
    if not garage or not garage.sitesFile then
      return nil
    end
    local sites = gameplay_sites_sitesManager.loadSites(garage.sitesFile)
    if not sites or not sites.zones then
      return nil
    end
    return sites.zones
  end

  local function getGarageZones(businessId)
    if inputs.cachedGarageZones[businessId] then
      return inputs.cachedGarageZones[businessId]
    end
    local zones = loadGarageZones(findBusinessGarage(businessId))
    if zones then
      inputs.cachedGarageZones[businessId] = zones
    end
    return zones
  end

  local function zonesContain(zones, pos)
    for _, zone in ipairs(zones.sorted or {}) do
      if zone and zone.containsPoint2D and zone:containsPoint2D(pos) then
        return true
      end
    end
    return false
  end

  local function isPositionInGarageZone(businessId, pos)
    if not businessId or not pos then
      return false
    end
    local zones = getGarageZones(businessId)
    if not zones then
      return false
    end
    return zonesContain(zones, pos)
  end

  -- Personal vehicle ids embed the spawned id; a fleet id needs the fleet to resolve it.
  local function isPersonalVehicleId(vehicleId)
    if not vehicleId then
      return false
    end
    return tostring(vehicleId):sub(1, #PERSONAL_ID_PREFIX) == PERSONAL_ID_PREFIX
  end

  local function getSpawnedIdFromPersonalVehicleId(vehicleId)
    if not isPersonalVehicleId(vehicleId) then
      return nil
    end
    return tonumber(tostring(vehicleId):sub(#PERSONAL_ID_PREFIX + 1))
  end

  local function spawnedVehicleIdFor(businessId, vehicleId)
    if isPersonalVehicleId(vehicleId) then
      return getSpawnedIdFromPersonalVehicleId(vehicleId)
    end
    return overhaul_career_business_fleet.getSpawnedVehicleId(businessId, vehicleId)
  end

  local function isSpawnedVehicleInGarageZone(businessId, vehicleId)
    if not businessId or not vehicleId then
      return false
    end
    local spawnedVehId = spawnedVehicleIdFor(businessId, vehicleId)
    if not spawnedVehId then
      return false
    end
    local vehObj = be:getObjectByID(spawnedVehId)
    local vehPos = vehObj and vehObj:getPosition()
    if not vehPos then
      return false
    end
    return isPositionInGarageZone(businessId, vehPos)
  end

  -- The player's car stands in for the player; on foot the free camera does.
  local function playerPosition()
    local playerVeh = be:getPlayerVehicle(0)
    if playerVeh then
      return playerVeh:getPosition()
    end
    local cam = core_camera.getActiveCamName()
    if cam == "freeCam" or cam == "free" then
      return core_camera.getPosition()
    end
    return nil
  end

  local function isPlayerInTuningShopZone(businessId)
    if not businessId then
      return false
    end
    local playerPos = playerPosition()
    if not playerPos then
      return false
    end
    return isPositionInGarageZone(businessId, playerPos)
  end

  -- Upgrade and skill reads -----------------------------------------------------------------------
  local function normalizeBusinessId(businessId)
    return tonumber(businessId) or businessId
  end

  local function getGenerationIntervalSeconds(businessId)
    if not businessId then
      return inputs.GEN_INTERVAL_SECONDS
    end
    local marketingLevel = overhaul_career_business_skillTree.getNodeProgress(businessId, SHOP_UPGRADES_TREE, "marketing") or 0
    return inputs.GEN_INTERVAL_SECONDS / (1 + UPGRADE_BONUS_PER_LEVEL * marketingLevel)
  end

  local function getXPGainMultiplier(businessId)
    if not businessId then
      return 1
    end
    local xpGainLevel = overhaul_career_business_skillTree.getNodeProgress(businessId, SHOP_UPGRADES_TREE, "xp-gain") or 0
    return 1 + (UPGRADE_BONUS_PER_LEVEL * xpGainLevel)
  end

  local function getJobExpirySeconds(businessId)
    return inputs.EXPIRY_SECONDS
  end

  local function ensureJobLifetime(job, businessId)
    if not job then
      return
    end
    local lifetime = tonumber(job.remainingLifetime)
    if not lifetime or lifetime <= 0 then
      job.remainingLifetime = getJobExpirySeconds(businessId)
    else
      job.remainingLifetime = lifetime
    end
  end

  local function getSkillTreeLevel(businessId, treeId, nodeId)
    if not businessId then
      return 0
    end
    local level = overhaul_career_business_skillTree.getNodeProgress(businessId, treeId, nodeId)
    return tonumber(level) or 0
  end

  local function isPersonalUseUnlocked(businessId)
    if not businessId then
      return false
    end
    local level = overhaul_career_business_skillTree.getNodeProgress(businessId, QUALITY_OF_LIFE_TREE, "personal-use")
    return (tonumber(level) or 0) >= 1
  end

  -- Inventory and personal rows -------------------------------------------------------------------

  -- Bought cars only: loans, test drives, unspawned cars and cars outside the zone are left out.
  local function inventorySpawnedInZone(zones, inventoryId, vehInfo)
    if vehInfo.loanType then
      return nil
    end
    if overhaul_career_market_testDrive.isActive() then
      return nil
    end
    local spawnedId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
    if not spawnedId then
      return nil
    end
    local vehObj = be:getObjectByID(spawnedId)
    local vehPos = vehObj and vehObj:getPosition()
    if vehPos and zonesContain(zones, vehPos) then
      return spawnedId
    end
    return nil
  end

  local function getInventoryVehiclesInGarageZone(businessId)
    if not businessId then
      return {}
    end
    local zones = getGarageZones(businessId)
    if not zones or not zones.sorted then
      return {}
    end
    local inventoryVehicles = overhaul_career_garage_inventory.getVehicles()
    if not inventoryVehicles then
      return {}
    end

    local results = {}
    for inventoryId, vehInfo in pairs(inventoryVehicles) do
      local spawnedId = inventorySpawnedInZone(zones, inventoryId, vehInfo)
      if spawnedId then
        table.insert(results, {spawnedId = spawnedId, inventoryId = inventoryId, inventoryVehicleData = vehInfo})
      end
    end
    return results
  end

  local function personalNiceName(model)
    if not model then
      return nil
    end
    local vehicleData = core_vehicles.getModel(model)
    if vehicleData and vehicleData.model then
      return ((vehicleData.model.Brand or "") .. " " .. (vehicleData.model.Name or model)):match("^%s*(.-)%s*$")
    end
    return nil
  end

  local function personalConfigKey(config)
    local configKey = config.partConfigFilename
    if configKey then
      local _, key = path.splitWithoutExt(configKey)
      return key
    end
    return configKey
  end

  local function createPersonalVehicleEntry(businessId, inventoryId, inventoryVehicleData, spawnedId)
    if not inventoryId or not inventoryVehicleData or not spawnedId then
      return nil
    end
    local model = inventoryVehicleData.model
    local config = inventoryVehicleData.config or {}
    local configKey = personalConfigKey(config)
    local niceName = personalNiceName(model)
    return {
      vehicleId = PERSONAL_ID_PREFIX .. tostring(spawnedId),
      jobId = nil,
      model = model,
      model_key = model,
      config = config,
      vehicleConfig = {model_key = model, key = configKey},
      vars = config.vars or {},
      partConditions = inventoryVehicleData.partConditions or {},
      mileage = inventoryVehicleData.mileage or 0,
      niceName = niceName or model or "Unknown Vehicle",
      isPersonal = true,
      inventoryId = inventoryId,
      spawnedVehicleId = spawnedId,
      owned = inventoryVehicleData.owned,
      storedTime = os.time(),
    }
  end

  -- Personal cars in the garage take no damage and always count as in the zone.
  local function decoratePersonalRow(formatted, businessId, inventoryId, spawnedVehicleId)
    formatted.damage = 0
    formatted.damageLocked = false
    formatted.damageThreshold = inputs.getDamageThreshold(businessId)
    formatted.inGarageZone = true
    formatted.isPersonal = true
    formatted.inventoryId = inventoryId
    formatted.spawnedVehicleId = spawnedVehicleId
  end

  local function getFormattedPersonalVehiclesInZone(businessId)
    if not businessId then
      return {}
    end

    local business = overhaul_world_facilities.getFacility(BUSINESS_TYPE, businessId)
    local isOnBusinessMap = business ~= nil
    local playerInZone = isOnBusinessMap and isPlayerInTuningShopZone(businessId) or false
    local formattedPersonalVehicles = {}
    if not (isPersonalUseUnlocked(businessId) and playerInZone and isOnBusinessMap) then
      return formattedPersonalVehicles
    end

    for _, invVeh in ipairs(getInventoryVehiclesInGarageZone(businessId)) do
      local personalEntry = createPersonalVehicleEntry(businessId, invVeh.inventoryId, invVeh.inventoryVehicleData, invVeh.spawnedId)
      if personalEntry then
        local formatted = parts.views.formatVehicleForUI(personalEntry, businessId)
        if formatted then
          decoratePersonalRow(formatted, businessId, invVeh.inventoryId, personalEntry.spawnedVehicleId)
          table.insert(formattedPersonalVehicles, formatted)
        end
      end
    end
    return formattedPersonalVehicles
  end

  -- Selection -------------------------------------------------------------------------------------
  local function findInventoryVehicleInZone(businessId, inventoryId)
    for _, invVeh in ipairs(getInventoryVehiclesInGarageZone(businessId)) do
      if invVeh.inventoryId == inventoryId then
        return invVeh
      end
    end
    return nil
  end

  local function announcePersonalSelection(businessId, inventoryId, personalEntry)
    local formatted = parts.views.formatVehicleForUI(personalEntry, businessId)
    if formatted then
      decoratePersonalRow(formatted, businessId, inventoryId, personalEntry.spawnedVehicleId)
      formatted.isActive = true
    end
    guihooks.trigger('businessComputer:onPersonalVehicleSelected', {
      businessType = BUSINESS_TYPE,
      businessId = tostring(businessId),
      vehicle = formatted,
    })
  end

  local function selectPersonalVehicle(businessId, inventoryId)
    if not businessId or not inventoryId then
      return {success = false, errorCode = "missingParams"}
    end
    if not isPersonalUseUnlocked(businessId) then
      return {success = false, errorCode = "personalUseNotUnlocked", message = "Personal Use upgrade is not unlocked"}
    end
    local found = findInventoryVehicleInZone(businessId, inventoryId)
    if not found then
      return {success = false, errorCode = "vehicleNotInZone", message = "Vehicle is not in the garage zone"}
    end
    local personalEntry = createPersonalVehicleEntry(businessId, found.inventoryId, found.inventoryVehicleData, found.spawnedId)
    if not personalEntry then
      return {success = false, errorCode = "failedToCreate", message = "Failed to create personal vehicle entry"}
    end

    inputs.activePersonalVehicle[normalizeBusinessId(businessId)] = personalEntry
    do
      announcePersonalSelection(businessId, inventoryId, personalEntry)
    end
    return {success = true, vehicle = personalEntry}
  end

  local function getActivePersonalVehicle(businessId)
    return inputs.activePersonalVehicle[normalizeBusinessId(businessId)]
  end

  local function clearActivePersonalVehicle(businessId)
    inputs.activePersonalVehicle[normalizeBusinessId(businessId)] = nil
  end

  local function getLiquidationValue(businessId)
    return math.floor((overhaul_career_business_partInventory.getLiquidationValue(businessId) or 0) + 0.5)
  end

  -- Public API ------------------------------------------------------------------------------------
  return {
    clearActivePersonalVehicle = clearActivePersonalVehicle,
    createPersonalVehicleEntry = createPersonalVehicleEntry,
    ensureJobLifetime = ensureJobLifetime,
    getActivePersonalVehicle = getActivePersonalVehicle,
    getFormattedPersonalVehiclesInZone = getFormattedPersonalVehiclesInZone,
    getGenerationIntervalSeconds = getGenerationIntervalSeconds,
    getInventoryVehiclesInGarageZone = getInventoryVehiclesInGarageZone,
    getJobExpirySeconds = getJobExpirySeconds,
    getLiquidationValue = getLiquidationValue,
    getSkillTreeLevel = getSkillTreeLevel,
    getXPGainMultiplier = getXPGainMultiplier,
    isPersonalUseUnlocked = isPersonalUseUnlocked,
    isPlayerInTuningShopZone = isPlayerInTuningShopZone,
    isPositionInGarageZone = isPositionInGarageZone,
    isSpawnedVehicleInGarageZone = isSpawnedVehicleInGarageZone,
    normalizeBusinessId = normalizeBusinessId,
    selectPersonalVehicle = selectPersonalVehicle,
  }
end

return installer
