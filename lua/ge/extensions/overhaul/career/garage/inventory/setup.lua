-- Inventory load owns saved records, restoration outcomes and ordered career placement.
-- Read in order: save decoding, world restoration, player placement, migration settlement, lifecycle retries.
local setup = {}
local vehicleMap = require('overhaul/career/garage/inventory/vehicleMap')
local levelData = require('overhaul/lib/world/levelData')

function setup.new(inputs)
  -- State -----------------------------------------------------------------------------------------
  -- These objects belong to this inventory load even if its caller replaces an input field later.
  local vehicles = inputs.vehicles
  local travel = inputs.travel
  local M = inputs.M
  local teleportPlayerToStartingGarage = inputs.teleportPlayerToStartingGarage
  local helpers = {}

  -- Save decoding ---------------------------------------------------------------------------------

  local function elapseDelayedAccess(vehicleData, saveInfo)
    if vehicleData.timeToAccess and vehicleData.delayReason ~= "engineRetailInstall"
        and vehicleData.delayReason ~= "engineRetailPickup" then
      vehicleData.timeToAccess = vehicleData.timeToAccess - inputs.dateUtils.timeSince(saveInfo.date)
      if vehicleData.timeToAccess <= 0 then
        vehicleData.timeToAccess = nil
        vehicleData.delayReason = nil
        vehicleData.repairTimeTotal = nil
      end
    end
  end

  -- The model database is not ready during load, so validate saved config data directly.
  local function flagMissingFile(vehicleData)
    local savedConfig = vehicleData.config or {}
    local configFilename = savedConfig.partConfigFilename
    local configFileExists = type(configFilename) == "string" and configFilename ~= ""
      and (FS:fileExists(configFilename) or FS:fileExists("/" .. configFilename:gsub("^/", "")))
    local hasParts = type(savedConfig.parts) == "table" and next(savedConfig.parts) ~= nil
    local hasPartsTree = type(savedConfig.partsTree) == "table" and next(savedConfig.partsTree) ~= nil
    if configFileExists or hasParts or hasPartsTree then
      vehicleData.missingFile = nil
      return
    end
    vehicleData.missingFile = true
    log("W", "career.inventory", string.format(
      "Vehicle %s marked missingFile (model=%s pc=%s)",
      tostring(vehicleData.id), tostring(vehicleData.model), tostring(configFilename)))
  end

  local function loadVehicleRecords(saveInfo, savePath)
    local files = FS:findFiles(savePath .. "/career/vehicles/", '*.json', 0, false, false)
    for i = 1, tableSize(files) do
      local vehicleData = jsonReadFile(files[i])
      if type(vehicleData) == "table" and vehicleData.id ~= nil then
        vehicleData.listedForAuction = vehicleData.listedForAuction == true or nil
        vehicleData.partConditions = deserialize(vehicleData.partConditions)
        vehicleData.partConditions = inputs.sanitizeMaintenancePartConditionsForVehicle(vehicleData, vehicleData.partConditions)
        elapseDelayedAccess(vehicleData, saveInfo)
        vehicles[vehicleData.id] = vehicleData
        flagMissingFile(vehicleData)
      else
        log("E", "career.inventory", "Skipped unreadable legacy vehicle record: " .. tostring(files[i]))
      end
    end
  end

  local function quarantineVehicles(migrationPlan)
    for _, inventoryId in ipairs(migrationPlan.quarantinedVehicleIds or {}) do
      inventoryId = tonumber(inventoryId)
      if inventoryId and vehicles[inventoryId] then
        vehicles[inventoryId].migrationQuarantined = true
        vehicles[inventoryId].missingFile = true
      end
    end
  end

  local function currentSaveFolder(savePath)
    return savePath:gsub("[/\\]+$", ""):match("([^/\\]+)$")
  end

  local function loadPreparedMigration(saveSlot, savePath)
    inputs.state.pendingMigrationCashOutVehicleIds = nil
    inputs.state.pendingMigrationPlan = nil
    inputs.state.pendingMigrationApplication = false
    inputs.state.pendingMigrationRetry = false
    inputs.state.currentMigrationSaveFolder = currentSaveFolder(savePath)
    local migrationPlan = overhaul_career_saveMigration.getPreparedMigration(saveSlot, inputs.state.currentMigrationSaveFolder)
    if type(migrationPlan) ~= "table" then return end
    inputs.state.pendingMigrationPlan = deepcopy(migrationPlan)
    inputs.state.pendingMigrationApplication = migrationPlan.status ~= "applied"
    inputs.state.pendingMigrationRetry = inputs.state.pendingMigrationApplication
    if inputs.state.pendingMigrationApplication then
      inputs.state.pendingMigrationCashOutVehicleIds = deepcopy(migrationPlan.cashOutVehicleIds or {})
    end
    quarantineVehicles(migrationPlan)
  end

  local function countEntries(map)
    local count = 0
    for _ in pairs(map) do count = count + 1 end
    return count
  end

  local function storeLoadedTransform(inventoryId, transform)
    if not inventoryId or type(transform) ~= "table" or not transform.pos then return end
    local loaded = {
      pos = vec3(transform.pos),
      rot = quat(transform.rot)
    }
    if not inputs.saveAnyVehiclePosDEBUG then
      loaded.option = "garage"
    end
    inputs.state.loadedVehiclesLocations[inventoryId] = loaded
  end

  -- Older saves encoded numeric ids as arrays; object keys preserve the intended mapping.
  local function storeSpawnedTransforms(rawSpawned)
    if rawSpawned[1] and type(rawSpawned[1]) == "table" and rawSpawned[1].pos and rawSpawned["1"] == nil then
      local onlyId = inputs.state.vehicleToEnterId or inputs.state.lastVehicle or inputs.state.favoriteVehicle
      if onlyId and #rawSpawned == 1 then
        storeLoadedTransform(onlyId, rawSpawned[1])
      else
        for index, transform in ipairs(rawSpawned) do
          storeLoadedTransform(tonumber(index), transform)
        end
      end
    else
      for inventoryId, transform in pairs(rawSpawned) do
        storeLoadedTransform(tonumber(inventoryId), transform)
      end
    end
  end

  local function loadSpawnedLocations(rawSpawned)
    if not rawSpawned then
      inputs.state.loadedVehiclesLocations = nil -- will force spawning at garage
      log("I", "career.inventory", "No spawnedPlayerVehicles in save; will use garage/walk restore")
      return
    end
    inputs.state.loadedVehiclesLocations = {}
    storeSpawnedTransforms(rawSpawned)
    log("I", "career.inventory", string.format(
      "Loaded %d spawnedPlayerVehicles (currentVehicle=%s)",
      countEntries(inputs.state.loadedVehiclesLocations), tostring(inputs.state.vehicleToEnterId)))
  end

  -- Older saves can lose the current id while retaining the spawned positions.
  local function recoverCurrentVehicleId()
    if inputs.state.lastVehicle and inputs.state.loadedVehiclesLocations[inputs.state.lastVehicle] then
      inputs.state.vehicleToEnterId = inputs.state.lastVehicle
    elseif inputs.state.favoriteVehicle and inputs.state.loadedVehiclesLocations[inputs.state.favoriteVehicle] then
      inputs.state.vehicleToEnterId = inputs.state.favoriteVehicle
    else
      for inventoryId, _ in pairs(inputs.state.loadedVehiclesLocations) do
        inputs.state.vehicleToEnterId = inventoryId
        break
      end
    end
  end

  local function loadInventoryState(inventoryData, justSwitched)
    if not inventoryData then return end
    inputs.state.vehicleToEnterId = tonumber(inventoryData.currentVehicle)
    inputs.state.lastVehicle = tonumber(inventoryData.lastVehicle)
    inputs.state.favoriteVehicle = tonumber(inventoryData.favoriteVehicle)
    travel.savedSession = nil
    if type(inventoryData.mapTravel) == "table" then
      travel.pending = deepcopy(inventoryData.mapTravel)
      if (travel.pending.arrivalPending or travel.pending.sessionRestore) and type(inventoryData.vehicleRelationships) == "table" then
        travel.savedSession = deepcopy(inventoryData.vehicleRelationships)
      end
    elseif type(inventoryData.vehicleRelationships) == "table" then
      travel.pending = deepcopy(inventoryData.vehicleRelationships)
    end
    local currentLevel = getCurrentLevelIdentifier()
    local resumedRestore = travel.pending and travel.pending.destination == currentLevel
      and (travel.pending.arrivalPending or travel.pending.sessionRestore)
    inputs.state.loadedVehiclesLevel = (not justSwitched or resumedRestore) and currentLevel or nil
    loadSpawnedLocations(inventoryData.spawnedPlayerVehicles)
    local sourceLevel = inputs.state.loadedVehiclesLevel or (travel.pending and travel.pending.source)
    if sourceLevel then
      for inventoryId in pairs(inputs.state.loadedVehiclesLocations or {}) do
        if vehicles[inventoryId] and not vehicles[inventoryId].lastKnownLevel then
          vehicles[inventoryId].lastKnownLevel = sourceLevel
        end
      end
    end
    -- World parking belongs to its map and survives saves made while the player is elsewhere.
    for inventoryId, record in pairs(vehicles) do
      local parked = record.worldPosition
      if parked and parked.level == currentLevel and vehicleMap.resolve(record) == currentLevel then
        inputs.state.loadedVehiclesLocations = inputs.state.loadedVehiclesLocations or {}
        inputs.state.loadedVehiclesLocations[inventoryId] = {
          pos = vec3(parked.pos), rot = quat(parked.rot), worldLevel = currentLevel,
        }
      end
    end
    -- A stored vehicle cannot be entered before it has a world binding.
    if not (inputs.state.loadedVehiclesLocations and inputs.state.loadedVehiclesLocations[inputs.state.vehicleToEnterId]) then
      inputs.state.vehicleToEnterId = nil
    end
    if not justSwitched and not inputs.state.vehicleToEnterId and inputs.state.loadedVehiclesLocations then
      recoverCurrentVehicleId()
    end
    inputs.state.unicycleSavedPosition = inventoryData.unicyclePos and vec3(inventoryData.unicyclePos) or nil
  end

  local function onExtensionLoaded()
    if not overhaul_career_career.isActive() then return false end

    inputs.state.inventorySetupDone = false
    inputs.state.lastFailedSpawnPos = nil
    inputs.state.hardcoreStarterGranted = false

    local saveSlot, savePath = overhaul_career_saveSystem.getCurrentProfile()
    if not saveSlot or not savePath then return end

    table.clear(vehicles)
    table.clear(inputs.vehIdToInventoryId)
    table.clear(inputs.inventoryIdToVehId)
    helpers.bumpAllGenerations()
    travel.activeRestore = nil
    travel.savedSession = nil
    travel.pending = nil
    travel.restoreAttempts = 0

    local saveInfo = jsonReadFile(savePath .. "/info.json")
    if not saveInfo or saveInfo.version < inputs.minimumVersion then return end

    loadVehicleRecords(saveInfo, savePath)
    local inventoryData = jsonReadFile(savePath .. "/career/inventory.json")
    local levelName = getCurrentLevelIdentifier()
    local generalSaveInfo = jsonReadFile(savePath .. "/career/general.json")
    local justSwitched = generalSaveInfo and generalSaveInfo.justSwitched or false
    if not levelName and generalSaveInfo and generalSaveInfo.level then
      levelName = tostring(generalSaveInfo.level)
    end
    loadPreparedMigration(saveSlot, savePath)
    loadInventoryState(inventoryData, justSwitched)
    for _, record in pairs(vehicles) do vehicleMap.repair(record) end
  end

  -- World restoration -----------------------------------------------------------------------------

  local function teleportRestoredVehicle(veh, location)
    if spawn.safeTeleport(veh, location.pos, location.rot) == false then error('Vehicle placement failed') end
  end

  -- Keep spawn and teleport failures separate so a placed binding can retry its saved position.
  local function spawnRestoredVehicle(inventoryId, location, justSwitched)
    local spawnLocation = location
    if justSwitched then
      spawnLocation = levelData.recoverySpawn(getCurrentLevelIdentifier())
    end
    if justSwitched and not spawnLocation then
      log('W', 'career.inventory', 'Map arrival has no local spawn; keeping vehicle pending')
      return {pendingLocation = location, clearCurrent = true, failedSpawn = true}
    end
    local spawnOk, vehOrErr = pcall(function()
      return helpers.spawnVehicle(inventoryId, nil, nil, spawnLocation, true)
    end)
    local veh = spawnOk and vehOrErr or nil
    if not spawnOk then
      log("E", "career.inventory", string.format(
        "setupInventory: spawnVehicle threw for %s: %s", tostring(inventoryId), tostring(vehOrErr)))
    end
    if not veh then
      return {pendingLocation = location, clearCurrent = true, failedSpawn = true,
        failedSpawnPos = spawnLocation and spawnLocation.pos or nil, warnFailedCurrent = true}
    end
    local teleportOk, teleportErr = pcall(function()
      teleportRestoredVehicle(veh, spawnLocation)
    end)
    if not teleportOk then
      if M.completeVehiclePlacement then M.completeVehiclePlacement(inventoryId, veh:getID()) end
      log("E", "career.inventory", string.format(
        "setupInventory: safeTeleport threw for %s: %s", tostring(inventoryId), tostring(teleportErr)))
      return {pendingLocation = location, clearCurrent = true, failedSpawn = true,
        failedSpawnPos = spawnLocation.pos}
    end
    if M.completeVehiclePlacement then M.completeVehiclePlacement(inventoryId, veh:getID()) end
    log("I", "career.inventory", string.format(
      "setupInventory: restored vehicle %s at saved/world position", tostring(inventoryId)))
    return {}
  end

  local function restoreSavedVehicle(inventoryId, location, justSwitched)
    local vehInfo = vehicles[inventoryId]
    if not vehInfo then
      log("E", "career.inventory", string.format(
        "setupInventory: missing vehicle data for spawned id %s", tostring(inventoryId)))
      return {pendingLocation = location}
    end
    if vehInfo.loanType == "work" and not vehInfo.logisticsInUse then
      overhaul_career_logistics_loanerVehicles.returnVehicle(inventoryId)
      return {loanedVehicleReturned = true}
    end
    if vehInfo.loanType == "rental" and not vehInfo.logisticsInUse and not vehInfo.brokerRentalId then
      return {clearCurrent = true}
    end
    if vehInfo.loanType == "company" and overhaul_career_work_employment.shouldAbortInterruptedShiftOnLoad() then
      overhaul_career_logistics_loanerVehicles.returnVehicle(inventoryId)
      return {clearCurrent = true, loanedVehicleReturned = true}
    end
    if justSwitched and inputs.state.vehicleToEnterId ~= inventoryId then
      log("I", "career.inventory", string.format(
        "setupInventory: deferring non-current vehicle %s during justSwitched", tostring(inventoryId)))
      return {}
    end
    return spawnRestoredVehicle(inventoryId, location, justSwitched)
  end

  local function applyRestorationResult(inventoryId, result, remainingSpawns)
    remainingSpawns[inventoryId] = result.pendingLocation
    if result.clearCurrent and inputs.state.vehicleToEnterId == inventoryId then
      if result.failedSpawn then inputs.state.lastFailedSpawnPos = result.failedSpawnPos end
      if result.warnFailedCurrent then
        log("W", "career.inventory", string.format(
          "setupInventory: failed to spawn current vehicle %s; will walk-fallback", tostring(inventoryId)))
      end
      inputs.state.vehicleToEnterId = nil
    end
    if result.loanedVehicleReturned then inputs.state.loanedVehicleReturned = true end
  end

  local function restoreWorldVehicles(mapTravelRestored, justSwitched)
    if mapTravelRestored and not next(inputs.state.loadedVehiclesLocations or {}) then
      inputs.state.loadedVehiclesLocations = nil
      inputs.state.inventorySetupDone = true
      return
    end
    if not inputs.state.loadedVehiclesLocations then
      inputs.state.inventorySetupDone = false
      return
    end
    local remainingSpawns = {}
    for inventoryId, location in pairs(inputs.state.loadedVehiclesLocations) do
      local arriving = justSwitched and location.worldLevel ~= getCurrentLevelIdentifier()
      applyRestorationResult(inventoryId, restoreSavedVehicle(inventoryId, location, arriving), remainingSpawns)
    end
    if next(remainingSpawns) then
      inputs.state.loadedVehiclesLocations = remainingSpawns
      inputs.state.inventorySetupDone = false
      log("W", "career.inventory", "setupInventory: some spawns remain pending for retry")
    else
      inputs.state.loadedVehiclesLocations = nil
      inputs.state.inventorySetupDone = true
    end
  end

  local function collectRentalReturns()
    local rentalIdsToReturn = {}
    for inventoryId, vehInfo in pairs(vehicles) do
      if vehInfo.loanType == "rental" and vehInfo.owningOrganization and not vehInfo.logisticsInUse and not vehInfo.brokerRentalId then
        rentalIdsToReturn[#rentalIdsToReturn + 1] = inventoryId
      end
    end
    return rentalIdsToReturn
  end

  local function returnSavedRentals(rentalIdsToReturn)
    for _, inventoryId in ipairs(rentalIdsToReturn) do
      if vehicles[inventoryId] then
        overhaul_career_logistics_loanerVehicles.returnVehicle(inventoryId)
        if inputs.state.vehicleToEnterId == inventoryId then inputs.state.vehicleToEnterId = nil end
        inputs.state.loanedVehicleReturned = true
      end
    end
  end

  -- Player placement ------------------------------------------------------------------------------

  local function restorePlayer(levelName, justSwitched)
    if inputs.state.vehicleToEnterId and inputs.inventoryIdToVehId[inputs.state.vehicleToEnterId] then
      local enterOk, enterErr = pcall(function() helpers.enterVehicle(inputs.state.vehicleToEnterId) end)
      if not enterOk then
        log("E", "career.inventory", "setupInventory: enterVehicle threw: " .. tostring(enterErr))
        inputs.state.inventorySetupDone = helpers.teleportWalkFallback(levelName, inputs.state.lastFailedSpawnPos) == true
      else
        inputs.state.pendingWalkRestore = false
        inputs.state.inventorySetupDone = true
        helpers.ensureGameCameraWithRetry()
      end
    else
      -- A failed spawn stays on this map; a map switch must not reuse the previous walking position.
      local preferredWalkPos
      if inputs.state.lastFailedSpawnPos then
        preferredWalkPos = inputs.state.lastFailedSpawnPos
      elseif justSwitched then
        preferredWalkPos = nil
      else
        preferredWalkPos = inputs.state.unicycleSavedPosition
      end
      inputs.state.inventorySetupDone = helpers.teleportWalkFallback(levelName, preferredWalkPos) == true
    end
    extensions.hook("onOverhaulSetupInventoryFinished")
  end

  local function positionHardcorePlayer(placement)
    if not placement then return false end
    return helpers.teleportWalkFallback(getCurrentLevelIdentifier(), placement.pos, placement.rot)
  end

  local function pickHardcoreStarterInfo()
    local eligibleVehicles = util_configListGenerator.getEligibleVehicles(false, false)
    local hardcoreFilter = {
      whiteList = {
        ["Config Type"] = {"Hardcore"}
      }
    }
    local hardcoreVehicleInfos = util_configListGenerator.getRandomVehicleInfos({
      filter = hardcoreFilter
    }, 6, eligibleVehicles, "Population")
    if not hardcoreVehicleInfos or #hardcoreVehicleInfos == 0 then
      log("E", "career.inventory", "Hardcore starter: no vehicles with Config Type Hardcore found")
      return nil
    end
    log("I", "career.inventory", string.format("Hardcore starter pool size: %d", #hardcoreVehicleInfos))
    return hardcoreVehicleInfos[math.random(#hardcoreVehicleInfos)]
  end

  local function spawnHardcoreStarter(starterInfo, placement)
    local model = starterInfo.model_key
    -- Prefer pcFilename; fall back to model-root key path (not /configurations/).
    local config = starterInfo.pcFilename
      or ('/vehicles/' .. model .. '/' .. starterInfo.key .. '.pc')
    local options = {
      config = config,
      licenseText = "Hardcore",
      vehicleName = "First Car",
      pos = placement.pos,
      rot = placement.rot
    }
    local spawningOptions = sanitizeVehicleSpawnOptions(model, options)
    spawningOptions.autoEnterVehicle = false
    local veh = core_vehicles.spawnNewVehicle(model, spawningOptions)
    inputs.state.hardcoreStarterGranted = veh ~= nil
    if not veh then return nil end
    core_vehicleBridge.executeAction(veh, 'setIgnitionLevel', 0)
    core_vehicles.setPlateText("Uncle's", veh:getID())
    return veh
  end

  local function addHardcoreStarterToInventory(veh)
    local mileage = 900000 * 1609.344
    veh:queueLuaCommand(string.format("partCondition.initConditions(nil, %d, nil, %f)", mileage, 0.5))
    local inventoryId = M.addVehicle(veh:getID(), nil, {
      starter = true
    })
    if not inventoryId then
      log("E", "career.inventory", "Hardcore starter vehicle spawned but failed to enter inventory")
      return
    end
    -- Starter cars are gifts, not insured purchases.
    extensions.hook("onOverhaulVehicleAddedToInventory", {
      inventoryId = inventoryId,
      purchaseData = {insuranceId = -1},
    })
    overhaul_career_career.setBoughtStarterVehicle(true)
  end

  local function grantHardcoreStarter(playerSpawn, vehicleSpawn)
    if not playerSpawn or not vehicleSpawn then return false end
    if not positionHardcorePlayer(playerSpawn) then return false end
    local starterInfo = pickHardcoreStarterInfo()
    if not starterInfo then return false end
    local veh = spawnHardcoreStarter(starterInfo, vehicleSpawn)
    if not veh then return false end
    addHardcoreStarterToInventory(veh)
    return true
  end

  local function restoreWalkingPosition(levelName, justSwitched)
    if not gameplay_walk.isWalking() then return end
    -- A map handoff was already placed by restorePlayer; saved coordinates belong only to this level.
    if not justSwitched and inputs.state.unicycleSavedPosition then
      spawn.safeTeleport(getPlayerVehicle(0), inputs.state.unicycleSavedPosition)
    elseif not justSwitched and not inputs.state.lastFailedSpawnPos then
      teleportPlayerToStartingGarage(levelName)
    end
    helpers.ensureGameCameraWithRetry()
  end

  local function finalizeCareerPlacement(newCareerSave, levelName, justSwitched)
    if not newCareerSave then
      restoreWalkingPosition(levelName, justSwitched)
      extensions.hook("onOverhaulEnterVehicleFinished", inputs.state.currentVehicle)
      return
    end
    inputs.state.saveCareer = 0
    local data = overhaul_career_career.hardcoreMode and levelData.loadStart(levelName)
    local mode = data and data.modes and data.modes.hardcore
    if mode and mode.enabled == false then mode = nil end
    local playerSpawn = mode and levelData.resolveSpawn(mode.playerSpawn, levelName)
    local vehicleSpawn = mode and levelData.resolveSpawn(mode.vehicleSpawn, levelName)
    if overhaul_career_career.hardcoreMode and inputs.state.hardcoreStarterGranted then
      log("I", "career.inventory", "setupInventory retry: hardcore starter already granted")
      if not positionHardcorePlayer(playerSpawn) then inputs.state.inventorySetupDone = false end
    elseif overhaul_career_career.hardcoreMode then
      if not grantHardcoreStarter(playerSpawn, vehicleSpawn) then
        log('W', 'career.inventory', 'Hardcore starter unavailable: configure playerSpawn and vehicleSpawn for this map')
        inputs.state.inventorySetupDone = false
        teleportPlayerToStartingGarage(levelName)
      end
    else
      teleportPlayerToStartingGarage(levelName)
      overhaul_career_garage_garageManager.purchaseDefaultGarage()
    end
  end

  local function setupInventory(_levelPath)
    local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
    if not savePath then
      log("E", "career.inventory", "setupInventory: no save path")
      return
    end
    local data = jsonReadFile(savePath .. "/info.json")
    local generalData = jsonReadFile(savePath .. "/career/general.json")
    local levelName = generalData and generalData.level or getCurrentLevelIdentifier()
    local justSwitched = generalData and generalData.justSwitched or false
    local pendingCount = countEntries(inputs.state.loadedVehiclesLocations or {})
    log("I", "career.inventory", string.format(
      "setupInventory: begin level=%s justSwitched=%s tutorial=%s pendingSpawns=%s current=%s alreadyDone=%s",
      tostring(levelName), tostring(justSwitched), tostring(false),
      tostring(pendingCount), tostring(inputs.state.vehicleToEnterId), tostring(inputs.state.inventorySetupDone)))
    -- Completion still permits retries for saved world spawns, map travel and a missing walking character.
    if inputs.state.inventorySetupDone and not travel.pending and not inputs.state.pendingWalkRestore
        and not (inputs.state.loadedVehiclesLocations and pendingCount > 0) then
      log("D", "career.inventory", "setupInventory: skip (already completed)")
      return
    end
    if justSwitched and not overhaul_career_economy_difficultyMode.isHardcoreMode() then
      overhaul_career_garage_garageManager.purchaseDefaultGarage()
    end
    inputs.state.lastFailedSpawnPos = nil
    local mapTravelRestored = travel.restore(levelName, justSwitched)
    if not mapTravelRestored and not inputs.state.vehicleToEnterId and inputs.state.loadedVehiclesLocations then
      for inventoryId in pairs(inputs.state.loadedVehiclesLocations) do
        if vehicles[inventoryId] then
          inputs.state.vehicleToEnterId = inventoryId
          break
        end
      end
    end
    local rentalIdsToReturn = collectRentalReturns()
    local justArrived = justSwitched and inputs.state.loadedVehiclesLevel ~= levelName
    restoreWorldVehicles(mapTravelRestored, justArrived)
    returnSavedRentals(rentalIdsToReturn)
    restorePlayer(levelName, justArrived)
    finalizeCareerPlacement(not data, levelName, justArrived)
    commands.setGameCamera()
    log("I", "career.inventory", string.format(
      "setupInventory: end walking=%s current=%s freecam=%s",
      tostring(gameplay_walk.isWalking()), tostring(inputs.state.currentVehicle),
      tostring(commands.isFreeCamera())))
  end

  -- Migration settlement --------------------------------------------------------------------------

  local function refreshPendingMigration()
    if inputs.state.pendingMigrationApplication then return true end
    local saveSlot, savePath = overhaul_career_saveSystem.getCurrentProfile()
    if not saveSlot or not savePath then return false end
    local saveFolder = currentSaveFolder(savePath)
    local migrationPlan = overhaul_career_saveMigration.getPreparedMigration(saveSlot, saveFolder)
    if type(migrationPlan) ~= "table" or migrationPlan.status == "applied" then return false end
    inputs.state.currentMigrationSaveFolder = saveFolder
    inputs.state.pendingMigrationPlan = deepcopy(migrationPlan)
    inputs.state.pendingMigrationCashOutVehicleIds = deepcopy(migrationPlan.cashOutVehicleIds or {})
    inputs.state.pendingMigrationApplication = true
    quarantineVehicles(migrationPlan)
    return true
  end

  -- Legacy plans need one combined credit; per-car saves are unsafe during career activation.
  local function cashOutLegacyVehicles()
    if type(overhaul_career_economy_playerAttributes.getAllAttributes()) ~= "table" then
      return nil
    end
    local appliedCashOutVehicleIds = {}
    local compensation = 0
    for _, inventoryId in ipairs(inputs.state.pendingMigrationCashOutVehicleIds) do
      inventoryId = tonumber(inventoryId)
      local vehicle = inventoryId and vehicles[inventoryId]
      if vehicle and helpers.isPersonalInventoryId(inventoryId) then
        if vehicle.owned ~= false then
          compensation = compensation + math.max(0, tonumber(vehicle.configBaseValue) or 0)
        end
        if vehicle.loanType ~= "work" then
          M.removeVehicle(inventoryId)
          table.insert(appliedCashOutVehicleIds, inventoryId)
        end
      end
    end
    if compensation > 0 then
      overhaul_career_economy_playerAttributes.addAttributes({money = compensation}, require("overhaul/lib/finance/metadata").tag({tags = {"migration", "selling"}, label = "Legacy save vehicle migration"}, "refund"))
    end
    return appliedCashOutVehicleIds
  end

  local function applyPendingMigration()
    if not inputs.state.pendingMigrationApplication and not refreshPendingMigration() then return false end
    local appliedCashOutVehicleIds = {}
    local migrationPlan = inputs.state.pendingMigrationPlan or {}
    if migrationPlan.preprocessed then
      appliedCashOutVehicleIds = deepcopy(inputs.state.pendingMigrationCashOutVehicleIds or {})
    elseif type(inputs.state.pendingMigrationCashOutVehicleIds) == "table" then
      appliedCashOutVehicleIds = cashOutLegacyVehicles()
      if not appliedCashOutVehicleIds then return false end
    end
    local saveSlot = overhaul_career_saveSystem.getCurrentProfile()
    local applied = overhaul_career_saveMigration.markMigrationApplied(saveSlot, inputs.state.currentMigrationSaveFolder, appliedCashOutVehicleIds)
    if not applied then
      log("E", "career.inventory", "Failed to record the prepared Career migration as applied")
      return false
    end
    inputs.state.pendingMigrationApplication = false
    inputs.state.pendingMigrationPlan = nil
    inputs.state.pendingMigrationCashOutVehicleIds = nil
    return true
  end

  -- Lifecycle -------------------------------------------------------------------------------------

  local function trySetupInventory(errorPrefix)
    local ok, err = pcall(setupInventory)
    if not ok then
      log("E", "career.inventory", errorPrefix .. tostring(err))
      helpers.ensureGameCameraWithRetry()
    end
  end

  local function onOverhaulActive(active)
    if not active then return end
    inputs.state.pendingWalkRestore = false
    trySetupInventory("onOverhaulActive setupInventory threw: ")
  end

  local function onWorldReadyState(state)
    if state ~= 2 or not overhaul_career_career.isActive() then return end
    local errorPrefix
    if travel.pending then
      log("I", "career.inventory", "onWorldReadyState: retrying map travel vehicle restore")
      errorPrefix = "onWorldReadyState map travel restore threw: "
    elseif inputs.state.loadedVehiclesLocations and next(inputs.state.loadedVehiclesLocations) then
      log("I", "career.inventory", "onWorldReadyState: retrying pending vehicle restore")
      errorPrefix = "onWorldReadyState setupInventory threw: "
    elseif inputs.state.pendingWalkRestore then
      log("I", "career.inventory", "onWorldReadyState: retrying walking restore")
      errorPrefix = "onWorldReadyState walk restore threw: "
    else
      if commands.isFreeCamera() then helpers.ensureGameCameraWithRetry() end
      return
    end
    inputs.state.inventorySetupDone = false
    trySetupInventory(errorPrefix)
  end

  return {
    applyPendingMigration = applyPendingMigration,
    onExtensionLoaded = onExtensionLoaded,
    onOverhaulActive = onOverhaulActive,
    onWorldReadyState = onWorldReadyState,
    bindInputs = function(inputs)
      helpers.bumpAllGenerations = inputs.bumpAllGenerations
      helpers.ensureGameCameraWithRetry = inputs.ensureGameCameraWithRetry
      helpers.enterVehicle = inputs.enterVehicle
      helpers.isPersonalInventoryId = inputs.isPersonalInventoryId
      helpers.spawnVehicle = inputs.spawnVehicle
      helpers.teleportWalkFallback = inputs.teleportWalkFallback
    end,
  }
end

return setup
