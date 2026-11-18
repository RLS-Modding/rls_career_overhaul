-- Garage ownership, grants, discovery and save files; state comes from garageManager.
-- Read save/cooldown helpers, acquisition and starter rules, capacity setup, then lifecycle and exports.
local recordDiscovery = require("overhaul/lib/progression/logbookFeed").register("overhaul.garageDiscovered", {
  title = "Garage discovered", label = "Discovery", icon = "garage01"
}, "career/garage/garageManager/ownership.lua")

local recordPurchase = require("overhaul/lib/progression/logbookFeed").register("overhaul.propertyPurchased", {
  title = "Property purchased", label = "Property", icon = "garage01"
}, "career/garage/garageManager/ownership.lua")

local saveStore = require("overhaul/lib/save/store")
local ensureDir = require("overhaul/lib/save/ensureDir")
local levelData = require("overhaul/lib/world/levelData")
local vehicleMap = require("overhaul/career/garage/inventory/vehicleMap")

-- Config ------------------------------------------------------------------------------------------

local LOG_TAG = "garageManager"
local MAX_RANDOM_STARTING_GARAGE_PRICE = 50000 -- the free random starter pool only holds homes priced in (0, 50000]

-- Persistence ------------------------------------------------------------------------------------

local function installPersistence(inputs, helpers)
  local saveFiles = {
    [inputs.saveFile] = "career/rls_career/" .. inputs.saveFile,
    ["negotiationCooldowns.json"] = "career/rls_career/negotiationCooldowns.json",
  }
  local saveFeature
  local saveFeatureRejected = false

  function helpers.garageSavePath(currentSavePath, file)
    -- Bind when a profile is read or saved, after the career's save service is available.
    if not saveFeature and not saveFeatureRejected then
      saveFeature = saveStore.feature("garage.ownership", {
        owner = "overhaul_career_garage_garageManager",
        files = {saveFiles[inputs.saveFile], saveFiles["negotiationCooldowns.json"]},
        phase = "profile",
        required = true,
      })
      saveFeatureRejected = saveFeature == nil
    end
    -- A rejected metadata registration must not stop the existing safe writer from saving the profile.
    local filePath = saveFiles[file]
    if saveFeature then filePath = saveFeature.path("", filePath) end
    -- The profile prefix stays verbatim, including any trailing slash older callers pass.
    return currentSavePath .. "/" .. filePath
  end

  function helpers.savePurchasedGarages(currentSavePath, writer)
    if not currentSavePath then return end
    helpers.syncBusinessGarages()
    writer = writer or overhaul_career_saveSystem.getSaveWriter()
    ensureDir.parentOf(writer, helpers.garageSavePath(currentSavePath, inputs.saveFile))
    local data = {
      version = 1,
      garages    = inputs.state.purchasedGarages,
      discovered = inputs.state.discoveredGarages,
      acquisitions = inputs.state.garageAcquisitions,
      relinquishedGrants = inputs.state.relinquishedGrants,
    }
    overhaul_career_saveSystem.jsonWriteFileSafe(helpers.garageSavePath(currentSavePath, inputs.saveFile), data, true)
  end

  function helpers.saveNegotiationCooldowns(currentSavePath, writer)
    if not currentSavePath then return end
    ensureDir.parentOf(writer, helpers.garageSavePath(currentSavePath, inputs.saveFile))
    local data = {
      cooldowns = inputs.state.negotiationCooldowns,
      frozenPrices = inputs.state.frozenPrices
    }
    overhaul_career_saveSystem.jsonWriteFileSafe(helpers.garageSavePath(currentSavePath, "negotiationCooldowns.json"), data, true)
  end

  function helpers.onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
    writer = writer or overhaul_career_saveSystem.getSaveWriter()
    log("D", LOG_TAG, "Saving garage data to: " .. helpers.garageSavePath(currentSavePath, inputs.saveFile))
    helpers.savePurchasedGarages(currentSavePath, writer)
    helpers.saveNegotiationCooldowns(currentSavePath, writer)
  end

  function helpers.disposeSaveFeature()
    if saveFeature then saveFeature.dispose() end
  end
end

-- Business bundles and mode ---------------------------------------------------------------------

local function installBusinessOwnership(inputs, helpers)
  function helpers.syncBusinessGarages()
    for _, bundle in ipairs(inputs.bundles.getAll()) do
      local id = bundle.garageId
      if id then
        if inputs.bundles.isOwned(bundle) then
          inputs.state.purchasedGarages[id] = true
          inputs.state.discoveredGarages[id] = true
          inputs.state.garageAcquisitions[id] = helpers.newGrant()
          inputs.state.relinquishedGrants[id] = nil
        else
          inputs.state.purchasedGarages[id] = nil
          inputs.state.garageAcquisitions[id] = nil
          inputs.state.garageSize[id] = nil
        end
      end
    end
  end

  function helpers.isHardcoreMode()
    return overhaul_career_economy_difficultyMode.isHardcoreMode()
  end
end

-- Negotiation cooldowns and prices --------------------------------------------------------------

local function installNegotiationPrices(inputs, helpers)
  function helpers.getCurrentSimTime()
    return os.time()
  end

  -- Prune with the wall clock used by getCurrentSimTime.
  function helpers.pruneExpiredNegotiations()
    local currentTime = os.time()
    for garageId, cooldownTime in pairs(inputs.state.negotiationCooldowns) do
      if currentTime - (tonumber(cooldownTime) or 0) > inputs.NEGOTIATION_COOLDOWN_SECONDS then
        inputs.state.negotiationCooldowns[garageId] = nil
      end
    end
    for garageId, frozen in pairs(inputs.state.frozenPrices) do
      local stamp = type(frozen) == "table" and tonumber(frozen.timestamp) or nil
      if not stamp or currentTime - stamp > inputs.NEGOTIATION_COOLDOWN_SECONDS then
        inputs.state.frozenPrices[garageId] = nil
      end
    end
  end

  function helpers.loadNegotiationCooldowns()
    if not overhaul_career_career.isActive() then return end
    local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
    if not currentSavePath then return end

    local data = jsonReadFile(helpers.garageSavePath(currentSavePath, "negotiationCooldowns.json"))
    if data then
      inputs.state.negotiationCooldowns = data.cooldowns or {}
      inputs.state.frozenPrices = data.frozenPrices or {}
      helpers.pruneExpiredNegotiations()
    end
  end

  function helpers.canNegotiateGarage(garageId)
    if not garageId then return false, 0 end
    local currentTime = helpers.getCurrentSimTime()
    local lastNegotiationTime = inputs.state.negotiationCooldowns[garageId]
    if not lastNegotiationTime then return true, 0 end
    local cooldownRemaining = math.max(0, inputs.NEGOTIATION_COOLDOWN_SECONDS - (currentTime - lastNegotiationTime))
    return cooldownRemaining == 0, cooldownRemaining
  end

  function helpers.setNegotiationCooldown(garageId)
    if not garageId then return end
    inputs.state.negotiationCooldowns[garageId] = helpers.getCurrentSimTime()
  end

  function helpers.storePrice(store, garageId, price)
    if not garageId or not price then return end
    store[garageId] = {
      price = price,
      timestamp = helpers.getCurrentSimTime()
    }
  end

  -- A price older than the cooldown is dropped instead of returned.
  function helpers.readFreshPrice(store, garageId)
    if not garageId then return nil end
    local entry = store[garageId]
    if not entry then return nil end
    if helpers.getCurrentSimTime() - entry.timestamp > inputs.NEGOTIATION_COOLDOWN_SECONDS then
      store[garageId] = nil
      return nil
    end
    return entry.price
  end

  function helpers.freezeNegotiatedPrice(garageId, price)
    helpers.storePrice(inputs.state.frozenPrices, garageId, price)
  end

  function helpers.getFrozenPrice(garageId)
    return helpers.readFreshPrice(inputs.state.frozenPrices, garageId)
  end

  function helpers.setPendingNegotiatedPrice(garageId, price)
    helpers.storePrice(inputs.pendingNegotiatedPrices, garageId, price)
  end

  function helpers.getPendingNegotiatedPrice(garageId)
    return helpers.readFreshPrice(inputs.pendingNegotiatedPrices, garageId)
  end

  function helpers.clearPendingNegotiatedPrice(garageId)
    if garageId then inputs.pendingNegotiatedPrices[garageId] = nil end
  end

  function helpers.clearFrozenPrice(garageId)
    if garageId then inputs.state.frozenPrices[garageId] = nil end
  end
end

-- Ownership and acquisition ---------------------------------------------------------------------

local function installAcquisitionRules(inputs, helpers)
  function helpers.newGrant()
    return { type = "grant", amountPaid = 0 }
  end

  function helpers.isPurchasedGarage(garageId)
    local bundle = inputs.bundles.forGarage(garageId)
    if bundle then return inputs.bundles.isOwned(bundle) end
    return inputs.state.purchasedGarages[garageId] or false
  end

  function helpers.isNotPurchasableGarage(garageId, garage)
    if not garageId then return false end
    garage = garage or overhaul_world_facilities.getFacilityIfExists("garage", garageId)
    return garage and garage.notPurchasable == true
  end

  function helpers.normalizeAcquisition(acquisition)
    if type(acquisition) ~= "table" then return helpers.newGrant() end
    local amountPaid = math.max(0, math.floor(tonumber(acquisition.amountPaid) or 0))
    local acquisitionType = acquisition.type
    if acquisitionType ~= "purchase" and acquisitionType ~= "finance" and acquisitionType ~= "grant" then
      acquisitionType = amountPaid > 0 and "purchase" or "grant"
    end
    if acquisitionType ~= "grant" and amountPaid <= 0 then acquisitionType = "grant" end
    return { type = acquisitionType, amountPaid = amountPaid, level = acquisition.level }
  end

  function helpers.setGarageAcquisition(garageId, acquisition)
    if not garageId then return end
    inputs.state.garageAcquisitions[garageId] = helpers.normalizeAcquisition(acquisition)
  end

  function helpers.clearGarageAcquisition(garageId)
    if garageId then inputs.state.garageAcquisitions[garageId] = nil end
  end

  function helpers.getGarageAcquisition(garageId)
    if not garageId then return nil end
    local info = inputs.state.garageAcquisitions[garageId]
    if info then return helpers.normalizeAcquisition(info) end
    return nil
  end

  function helpers.wasGaragePurchasedWithMoney(garageId)
    local info = helpers.getGarageAcquisition(garageId)
    return info ~= nil and (tonumber(info.amountPaid) or 0) > 0
  end

  function helpers.isGrantedGarageOwnership(garageId)
    if not garageId or not inputs.state.purchasedGarages[garageId] then return false end
    return not helpers.wasGaragePurchasedWithMoney(garageId)
  end

  function helpers.isRelinquishedGrant(garageId)
    return garageId and inputs.state.relinquishedGrants[garageId] == true
  end

  function helpers.markRelinquishedGrant(garageId)
    if garageId then inputs.state.relinquishedGrants[garageId] = true end
  end

  function helpers.clearRelinquishedGrant(garageId)
    if garageId then inputs.state.relinquishedGrants[garageId] = nil end
  end

  function helpers.isAccessibleGarage(garageId)
    local bundle = inputs.bundles.forGarage(garageId)
    if bundle then return inputs.bundles.isOwned(bundle) end
    if helpers.isNotPurchasableGarage(garageId) then return false end
    if inputs.state.purchasedGarages[garageId] then return true end
    if overhaul_career_garage_property_propertyRentals.isRentedGarage(garageId) then return true end
    return false
  end

  function helpers.isDiscoveredGarage(garageId)
    return inputs.state.discoveredGarages[garageId] or false
  end

  function helpers.isGarageForSale(garageId)
    if inputs.bundles.forGarage(garageId) then return false end
    if not garageId then return false end
    return overhaul_career_garage_property_realEstateNegotiation.getPropertyListing(garageId) ~= nil
  end
end

-- Starting garages ------------------------------------------------------------------------------

local function installStartingGarages(inputs, helpers)
  function helpers.isChallengeStartingGarage(garageId)
    if not garageId then return false end
    if not overhaul_career_challengeModes.isChallengeActive() then return false end
    local activeChallenge = overhaul_career_challengeModes.getActiveChallenge()
    if not activeChallenge or not activeChallenge.startingGarages then return false end
    for _, startingGarageId in ipairs(activeChallenge.startingGarages) do
      if startingGarageId == garageId then return true end
    end
    return false
  end

  -- A challenge with startingGarageMode "none" starts homeless, whatever the career's garage preference says.
  function helpers.isNoGarageChallenge()
    if not overhaul_career_challengeModes.isChallengeActive() then return false end
    local activeChallenge = overhaul_career_challengeModes.getActiveChallenge()
    return activeChallenge ~= nil and activeChallenge.startingGarageMode == "none"
  end

  function helpers.getManualStartingGaragePreference()
    return overhaul_career_career.getStartingGaragePreference() or {mode = "default", garageId = nil}
  end

  function helpers.isManualStartingGarage(garageId)
    if not garageId then return false end
    local preference = helpers.getManualStartingGaragePreference()
    if preference.mode ~= "default" or not preference.garageId or preference.garageId == "" then return false end
    return preference.garageId == garageId
  end

  function helpers.getDefaultStartingGarageId(levelName)
    local facilities = overhaul_world_facilities.getFacilities(levelName or getCurrentLevelIdentifier())
    if not facilities or not facilities.garages then return nil end
    for _, garage in ipairs(facilities.garages) do
      if garage.starterGarage then return garage.id end
    end
    return nil
  end

  function helpers.isEligibleRandomStartingGarage(garage)
    if type(garage) ~= "table" or not garage.id then return false end
    if garage.notPurchasable == true then return false end
    local price = tonumber(garage.defaultPrice)
    if not price or price <= 0 or price > MAX_RANDOM_STARTING_GARAGE_PRICE then return false end
    return true
  end

  function helpers.getRandomStartingGaragePool(levelName)
    local facilities = overhaul_world_facilities.getFacilities(levelName or getCurrentLevelIdentifier())
    local pool = {}
    if not facilities or type(facilities.garages) ~= "table" then return pool end
    for _, garage in ipairs(facilities.garages) do
      if helpers.isEligibleRandomStartingGarage(garage) then table.insert(pool, garage.id) end
    end
    return pool
  end

  function helpers.pickRandomStartingGarageId(levelName)
    local pool = helpers.getRandomStartingGaragePool(levelName)
    -- A map with no purchasable home in the price range falls back to its own starter.
    if #pool == 0 then return helpers.getDefaultStartingGarageId(levelName) end
    return pool[math.random(1, #pool)]
  end

  -- The pick is locked into the career preference so the teleport and the grant stay stable.
  function helpers.resolveAndPersistRandomStartingGarage(levelName)
    local preference = helpers.getManualStartingGaragePreference()
    if preference.mode ~= "default" then return nil end
    if preference.garageId and preference.garageId ~= "" then
      return helpers.getGarageFacilityQuiet(preference.garageId) and preference.garageId or nil
    end

    local picked = helpers.pickRandomStartingGarageId(levelName)
    if not picked then return nil end

    overhaul_career_career.setStartingGaragePreference("default", picked)
    log("I", LOG_TAG, string.format(
      "Resolved random starting garage for %s: %s",
      tostring(levelName or getCurrentLevelIdentifier()),
      tostring(picked)))
    return picked
  end

  function helpers.hasAnyPurchasedGarage()
    for _ in pairs(inputs.state.purchasedGarages) do return true end
    return false
  end

  function helpers.getEffectiveStartingGarages(levelName)
    if helpers.isNoGarageChallenge() then return {}, "challenge" end
    if overhaul_career_challengeModes.isChallengeActive() then
      local activeChallenge = overhaul_career_challengeModes.getActiveChallenge()
      if activeChallenge and activeChallenge.startingGarages and #activeChallenge.startingGarages > 0 then
        local eligible = {}
        for _, garageId in ipairs(activeChallenge.startingGarages) do
          if helpers.getGarageFacilityQuiet(garageId) and not inputs.bundles.forGarage(garageId) then
            eligible[#eligible + 1] = garageId
          end
        end
        return eligible, "challenge"
      end
    end

    -- Hardcore never grants or teleports to a free starting garage.
    if helpers.isHardcoreMode() or overhaul_career_career.hardcoreMode then return {}, "hardcore" end

    local preference = helpers.getManualStartingGaragePreference()
    if preference.mode == "none" then return {}, "none" end
    if preference.garageId and preference.garageId ~= "" then
      if inputs.bundles.forGarage(preference.garageId) then return {}, "businessBundle" end
      if helpers.getGarageFacilityQuiet(preference.garageId) then return {preference.garageId}, "specific" end
      return {}, "otherLevel"
    end

    -- A career saved as default+nil already owns its map starter (or none); a new random pick would grant a second home.
    if helpers.hasAnyPurchasedGarage() then
      local legacyId = helpers.getDefaultStartingGarageId(levelName)
      if legacyId then return {legacyId}, "default" end
      return {}, "default"
    end

    local randomGarageId = helpers.resolveAndPersistRandomStartingGarage(levelName)
    if randomGarageId then return {randomGarageId}, "random" end
    return {}, "default"
  end

  function helpers.getPrimaryStartingGarageId(levelName)
    return helpers.getEffectiveStartingGarages(levelName)[1]
  end

  function helpers.isEffectiveStartingGarage(garageId, levelName)
    if not garageId then return false end
    for _, startingGarageId in ipairs(helpers.getEffectiveStartingGarages(levelName) or {}) do
      if startingGarageId == garageId then return true end
    end
    return false
  end

  function helpers.getGarageFacilityQuiet(garageId)
    if not garageId then return nil end
    return overhaul_world_facilities.getFacilityIfExists("garage", garageId)
  end

  function helpers.isGrantedStartingGarage(garageId, garage)
    if not garageId then return false end
    garage = garage or helpers.getGarageFacilityQuiet(garageId)
    if not garage or garage.starterGarage then return false end
    return helpers.isChallengeStartingGarage(garageId) or helpers.isManualStartingGarage(garageId)
  end

  function helpers.isFreeStarterGarage(garageId, garage)
    garage = garage or helpers.getGarageFacilityQuiet(garageId)
    if not garage or not garage.starterGarage then return false end
    if helpers.isHardcoreMode() then return false end
    return helpers.isEffectiveStartingGarage(garageId)
  end

  function helpers.inferLegacyAcquisition(garageId)
    local garage = helpers.getGarageFacilityQuiet(garageId)
    if not garage then return helpers.newGrant() end
    if helpers.isFreeStarterGarage(garageId, garage) or helpers.isGrantedStartingGarage(garageId, garage) then return helpers.newGrant() end
    local defaultPrice = math.max(0, math.floor(tonumber(garage.defaultPrice) or 0))
    if defaultPrice <= 0 then return helpers.newGrant() end
    return { type = "purchase", amountPaid = defaultPrice }
  end

  function helpers.isStarterGaragePurchasable(garageId)
    if not garageId then return false end
    local garage = helpers.getGarageFacilityQuiet(garageId)
    if not garage or not garage.starterGarage then return false end
    if inputs.state.purchasedGarages[garageId] then return false end
    if helpers.isHardcoreMode() then return true end
    if helpers.isEffectiveStartingGarage(garageId) then return false end
    return true
  end
end

-- Capacity setup --------------------------------------------------------------------------------

local function installGarageSetup(inputs, helpers)
  function helpers.reloadRecoveryPrompt()
    overhaul_ui_recoveryPrompt.addTowingButtons()
    overhaul_ui_recoveryPrompt.addTaxiButtons()
  end

  function helpers.buildGarageSizes()
    helpers.syncBusinessGarages()
    inputs.state.garageSize = {}
    local garages = overhaul_world_facilities.getFacilitiesByType("garage")
    if not garages then return end
    for _, garage in pairs(garages) do
      if helpers.isGarageForSale(garage.id) then
        inputs.state.garageSize[tostring(garage.id)] = nil
      else
        local isRented = overhaul_career_garage_property_propertyRentals.isRentedGarage(garage.id)
        if inputs.state.purchasedGarages[garage.id] or isRented then
          inputs.state.garageSize[tostring(garage.id)] = math.ceil(garage.capacity / (helpers.isHardcoreMode() and 2 or 1))
        end
      end
    end
  end

  function helpers.addPurchasedGarage(garageId, acquisition)
    if inputs.bundles.forGarage(garageId) then return false end
    if helpers.isNotPurchasableGarage(garageId) then
      log("D", LOG_TAG, "Ignoring purchase of non-purchasable facility: " .. tostring(garageId))
      return
    end
    local wasOwned = inputs.state.purchasedGarages[garageId]
    log("I", LOG_TAG, "Adding purchased garage: " .. garageId)
    inputs.state.purchasedGarages[garageId] = true
    inputs.state.discoveredGarages[garageId] = true
    helpers.clearRelinquishedGrant(garageId)
    helpers.setGarageAcquisition(garageId, acquisition)
    local acquisitionState = inputs.state.garageAcquisitions[garageId]
    acquisitionState.level = acquisitionState.level or getCurrentLevelIdentifier()
    if not wasOwned and acquisition and (acquisition.type == "purchase" or acquisition.type == "finance") then
      local garage = helpers.getGarageFacilityQuiet(garageId)
      recordPurchase({name = garage and garage.name or tostring(garageId),
        detail = (garage and garage.name or tostring(garageId)) .. (acquisition.type == "finance" and " / Financed property value" or " / Property purchase including closing costs"),
        money = -(tonumber(acquisition.historyAmountPaid or acquisition.amountPaid) or 0)})
    end
    helpers.reloadRecoveryPrompt()
    helpers.buildGarageSizes()
  end

  function helpers.addDiscoveredGarage(garageId)
    if inputs.state.discoveredGarages[garageId] then return end
    local garage = helpers.getGarageFacilityQuiet(garageId)
    recordDiscovery({name = garage and garage.name or tostring(garageId),
      receipt = tostring(getCurrentLevelIdentifier()) .. ":" .. tostring(garageId)})
    if garage and garage.defaultPrice == 0 and not garage.notPurchasable and not helpers.isRelinquishedGrant(garageId) then
      inputs.state.purchasedGarages[garageId] = true
      helpers.setGarageAcquisition(garageId, helpers.newGrant())
      inputs.state.garageAcquisitions[garageId].level = getCurrentLevelIdentifier()
    end
    inputs.state.discoveredGarages[garageId] = true
    helpers.reloadRecoveryPrompt()
  end

  function helpers.purchaseDefaultGarage()
    if overhaul_career_career.hardcoreMode or helpers.isHardcoreMode() then return end

    local effectiveStartingGarages, source = helpers.getEffectiveStartingGarages()
    if source == "challenge" then
      log("D", LOG_TAG, "purchaseDefaultGarage: Skipping default garage purchase - challenge has starting garages: " .. dumps(effectiveStartingGarages))
      return
    end

    local preference = helpers.getManualStartingGaragePreference()
    if preference.mode == "none" then
      log("D", LOG_TAG, "purchaseDefaultGarage: Skipping default garage purchase for manual starting garage mode: " .. tostring(preference.mode))
      return
    end

    local garageId = effectiveStartingGarages and effectiveStartingGarages[1] or preference.garageId
    if not garageId or garageId == "" then
      log("W", LOG_TAG, "purchaseDefaultGarage: No eligible starting garage resolved")
      return
    end
    if helpers.isRelinquishedGrant(garageId) then
      log("D", LOG_TAG, "purchaseDefaultGarage: Skipping re-grant of relinquished starting garage: " .. garageId)
      return
    end
    if inputs.state.purchasedGarages[garageId] then return end

    log("D", LOG_TAG, string.format(
      "purchaseDefaultGarage: Granting starting garage (%s): %s",
      tostring(source),
      tostring(garageId)))
    helpers.addPurchasedGarage(garageId, helpers.newGrant())
  end

  function helpers.fillGarages()
    local levelName = getCurrentLevelIdentifier()
    if not levelName then return end
    local getFacilityIfExists = overhaul_world_facilities.getFacilityIfExists
    for id, vehicle in pairs(overhaul_career_garage_inventory.getVehicles()) do
      local location = vehicle.location
      local locationOnCurrentMap = location and getFacilityIfExists("garage", location)
      local pending = overhaul_career_garage_inventory.isVehiclePendingTravel
      local vehicleLevel, reason = vehicleMap.resolve(vehicle)
      local lastSeenElsewhere = reason == "ambiguous" or (vehicleLevel and vehicleLevel ~= levelName)
      local parkedHere = vehicle.worldPosition and vehicle.worldPosition.level == levelName
      if not location and vehicle.lastKnownLevel == levelName and not parkedHere and not (pending and pending(id)) then
        -- An unlocated record without local evidence cannot safely claim storage on this map.
        overhaul_career_garage_inventory.moveVehicleToGarage(id)
      elseif locationOnCurrentMap and not parkedHere and not lastSeenElsewhere and not vehicle.niceLocation then
        overhaul_career_garage_inventory.moveVehicleToGarage(id, location)
      end
    end
  end
end

-- Loading ---------------------------------------------------------------------------------------

local function installLoadReconciliation(inputs, helpers)
  -- Public tuning tents used to auto-own as free $0 garages; strip that leftover ownership.
  function helpers.stripNotPurchasableOwnership()
    local removedAny = false
    for garageId in pairs(inputs.state.purchasedGarages) do
      if helpers.isNotPurchasableGarage(garageId) and not inputs.bundles.forGarage(garageId) then
        inputs.state.purchasedGarages[garageId] = nil
        helpers.clearGarageAcquisition(garageId)
        removedAny = true
      end
    end
    if removedAny then
      log("I", LOG_TAG, "Removed ownership of public tuning stations from save data")
    end
  end

  function helpers.backfillAcquisitions()
    for garageId, owned in pairs(inputs.state.purchasedGarages) do
      if owned and not inputs.state.garageAcquisitions[garageId] then
        helpers.setGarageAcquisition(garageId, helpers.inferLegacyAcquisition(garageId))
      end
    end
  end

  -- The alias identifies the historical property's map; the player's last travel destination does not.
  function helpers.migrateRecoveryYardPrototype(currentSavePath, saveVersion)
    local recoveryState = jsonReadFile(currentSavePath .. "/career/rls_career/offroadRecovery.json") or {}
    if (tonumber(recoveryState.nextId) or 1) <= 1 then return end
    local career = jsonReadFile(currentSavePath .. "/career/general.json") or {}
    local savedMap = levelData.resolveAlias("map", career.level or getCurrentLevelIdentifier(), {saveVersion = saveVersion})
    for _, grant in ipairs(levelData.loadAliases("garageRecoveryGrant")) do
      local ownerMap, historicalOwner = levelData.resolveAlias("garageRecoveryOwnerMap", grant.from, {saveVersion = saveVersion})
      local target, matched = levelData.resolveAlias("garageRecoveryGrant", grant.from,
        {levelId = historicalOwner and ownerMap or savedMap, saveVersion = saveVersion})
      if matched then
        local migrated = false
        if inputs.state.purchasedGarages[grant.from] and not inputs.state.purchasedGarages[target] then
          inputs.state.purchasedGarages[target] = true
          inputs.state.discoveredGarages[target] = true
          helpers.clearRelinquishedGrant(target)
          if not inputs.state.garageAcquisitions[target] then
            helpers.setGarageAcquisition(target, helpers.inferLegacyAcquisition(target))
          end
          migrated = true
        elseif inputs.state.discoveredGarages[grant.from] and not inputs.state.discoveredGarages[target] then
          inputs.state.discoveredGarages[target] = true
          migrated = true
        end
        if migrated then
          log("I", LOG_TAG, "Restored " .. target .. " access from the " .. grant.from .. " recovery prototype")
        end
      end
    end
  end

  -- `source` names where the starting garage came from, for the log lines.
  function helpers.ensureStartingGarageGranted(garageId, source)
    if inputs.bundles.forGarage(garageId) then return end -- bundles cannot be granted as starters
    if helpers.isRelinquishedGrant(garageId) then
      log("D", LOG_TAG, "loadPurchasedGarages: Skipping relinquished " .. source .. " starting garage: " .. garageId)
    elseif not inputs.state.purchasedGarages[garageId] then
      log("D", LOG_TAG, "loadPurchasedGarages: Adding missing " .. source .. " starting garage: " .. garageId)
      inputs.state.purchasedGarages[garageId] = true
      inputs.state.discoveredGarages[garageId] = true
      helpers.setGarageAcquisition(garageId, helpers.newGrant())
    elseif not inputs.state.garageAcquisitions[garageId] then
      helpers.setGarageAcquisition(garageId, helpers.newGrant())
    end
  end

  function helpers.ensureChallengeStartingGarages()
    if not overhaul_career_challengeModes.isChallengeActive() then return end
    local activeChallenge = overhaul_career_challengeModes.getActiveChallenge()
    if not (activeChallenge and activeChallenge.startingGarages and #activeChallenge.startingGarages > 0) then return end
    log("D", LOG_TAG, "loadPurchasedGarages: Ensuring challenge starting garages are purchased: " .. dumps(activeChallenge.startingGarages))
    for _, garageId in ipairs(activeChallenge.startingGarages) do
      helpers.ensureStartingGarageGranted(garageId, "challenge")
    end
  end

  function helpers.ensureManualStartingGarage()
    if helpers.isNoGarageChallenge() then return end
    local preference = helpers.getManualStartingGaragePreference()
    if preference.mode == "default" and preference.garageId and preference.garageId ~= "" then
      helpers.ensureStartingGarageGranted(preference.garageId, "manually selected")
    end
  end

  function helpers.loadPurchasedGarages()
    if not overhaul_career_career.isActive() then return end
    local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
    if not currentSavePath then return end

    local data = jsonReadFile(helpers.garageSavePath(currentSavePath, inputs.saveFile)) or {}
    inputs.state.purchasedGarages = data.garages or {}
    inputs.state.discoveredGarages = data.discovered or {}
    inputs.state.garageAcquisitions = data.acquisitions or {}
    inputs.state.relinquishedGrants = data.relinquishedGrants or {}

    helpers.stripNotPurchasableOwnership()
    helpers.backfillAcquisitions()
    helpers.migrateRecoveryYardPrototype(currentSavePath, tonumber(data.version) or 0)

    if overhaul_career_career.hardcoreMode and not data.garages then
      inputs.state.purchasedGarages = {}
      inputs.state.discoveredGarages = {}
      inputs.state.garageAcquisitions = {}
      inputs.state.relinquishedGrants = {}
    end

    helpers.ensureChallengeStartingGarages()
    helpers.ensureManualStartingGarage()

    helpers.reloadRecoveryPrompt()
    helpers.buildGarageSizes()
    helpers.fillGarages()
  end
end

-- Lifecycle -------------------------------------------------------------------------------------

local function installLifecycle(helpers)
  function helpers.onOverhaulModulesActivated()
    helpers.loadPurchasedGarages()
  end

  function helpers.onExtensionLoaded()
    helpers.loadPurchasedGarages()
    helpers.loadNegotiationCooldowns()
    helpers.buildGarageSizes()
  end
end

-- Public API --------------------------------------------------------------------------------------

local ownership = {}

function ownership.new(inputs)
  local helpers = {}
  installPersistence(inputs, helpers)
  installBusinessOwnership(inputs, helpers)
  installNegotiationPrices(inputs, helpers)
  installAcquisitionRules(inputs, helpers)
  installStartingGarages(inputs, helpers)
  installGarageSetup(inputs, helpers)
  installLoadReconciliation(inputs, helpers)
  installLifecycle(helpers)

  return helpers
end

return ownership
