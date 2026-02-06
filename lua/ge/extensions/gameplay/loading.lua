local M = {}
M.dependencies = {"gameplay_sites_sitesManager"}

local Config, Contracts, Zones, Manager, UI

local currentState
local compatibleZones = {}
local uiUpdateTimer = 0
local contractUpdateTimer = 0

local cachedPlayerVeh = nil
local cachedPlayerPos = nil
local playerCacheTimer = 0

local loadedExtensions = {}

local function getPhoneStateForUI()
  if not Config or not Contracts or not Zones or not Manager then return nil end

  local currentZone = nil
  local allZonesByFacility = {}
  
  if cachedPlayerPos then
    if Zones.getPlayerCurrentZone then
      currentZone = Zones.getPlayerCurrentZone(cachedPlayerPos)
    end
    
    local zonesByFacility = {}
    
    for _, zone in ipairs(Zones.availableGroups or {}) do
      if zone.loading and zone.loading.center then
        local zoneCenter = vec3(zone.loading.center)
        local dist = (cachedPlayerPos - zoneCenter):length()
        dist = math.floor(dist + 0.5)
        
        local zoneTag = zone.secondaryTag
        local facilityId = Zones.getFacilityIdForZone and Zones.getFacilityIdForZone(zoneTag) or nil
        local facilityCfg = facilityId and Config.facilities and Config.facilities[facilityId] or nil
        local facilityName = facilityCfg and (facilityCfg.name or facilityId) or facilityId or "Unknown"
        
        if not facilityId then
          facilityId = "unknown"
          facilityName = "Unknown"
        end
        
        if not zonesByFacility[facilityId] then
          zonesByFacility[facilityId] = {
            facilityId = facilityId,
            facilityName = facilityName,
            zones = {}
          }
        end
        
        local cache = Zones.ensureGroupCache and Zones.ensureGroupCache(zone, Contracts.getCurrentGameHour) or nil
        table.insert(zonesByFacility[facilityId].zones, {
          zoneTag = zoneTag,
          displayName = cache and cache.name or zoneTag,
          distance = dist,
          position = zone.loading.center
        })
      end
    end
    
    for facilityId, facilityData in pairs(zonesByFacility) do
      table.sort(facilityData.zones, function(a, b) return a.distance < b.distance end)
      table.insert(allZonesByFacility, facilityData)
    end
    
    table.sort(allZonesByFacility, function(a, b)
      local aMinDist = a.zones[1] and a.zones[1].distance or math.huge
      local bMinDist = b.zones[1] and b.zones[1].distance or math.huge
      return aMinDist < bMinDist
    end)
  end
  
  currentZone = currentZone or Manager.jobObjects.activeGroup

  local currentZoneTag = currentZone and currentZone.secondaryTag or nil
  local currentFacilityId = Zones.getFacilityIdForZone and Zones.getFacilityIdForZone(currentZoneTag) or nil
  local currentFacilityCfg = currentFacilityId and Config.facilities and Config.facilities[currentFacilityId] or nil
  local currentFacility = currentFacilityId and { id = currentFacilityId, name = (currentFacilityCfg and (currentFacilityCfg.name or currentFacilityId)) or currentFacilityId } or nil

  local function getContractFacilityId(contract)
    if not contract then return nil end
    if contract.facilityId then return contract.facilityId end
    if Contracts.getFacilityIdForZone then
      return Contracts.getFacilityIdForZone(contract.groupTag or contract.loadingZoneTag)
    end
    if Zones.getFacilityIdForZone then
      return Zones.getFacilityIdForZone(contract.groupTag or contract.loadingZoneTag)
    end
    return nil
  end

  local contractsForUI = {}
  for _, c in ipairs(Contracts.ContractSystem.availableContracts or {}) do
    local contractFacilityId = getContractFacilityId(c)
    if not currentFacilityId or (contractFacilityId == currentFacilityId) then
      local matConfig = c.material and Config.materials and Config.materials[c.material] or nil
      local materialBreakdown = {}
      if c.materialRequirements then
        for matKey, requiredQty in pairs(c.materialRequirements) do
          local matCfg = Config.materials and Config.materials[matKey]
          table.insert(materialBreakdown, {
            materialKey = matKey,
            materialName = matCfg and matCfg.name or matKey,
            units = matCfg and matCfg.units or "items",
            required = requiredQty
          })
        end
      end
      table.insert(contractsForUI, {
        id = c.id,
        name = c.name,
        tier = c.tier,
        material = c.material,
        materialName = matConfig and matConfig.name or c.material,
        materialTypeName = c.materialTypeName,
        requiredTons = c.requiredTons,
        requiredItems = c.requiredItems,
        materialBreakdown = materialBreakdown,
        isBulk = c.isBulk,
        totalPayout = c.totalPayout,
        paymentType = c.paymentType,
        groupTag = c.groupTag,
        loadingZoneTag = c.loadingZoneTag,
        estimatedTrips = c.estimatedTrips,
        expiresAt = c.expiresAt,
        hoursRemaining = Contracts.getContractHoursRemaining(c),
        expirationHours = c.expirationHours,
        destinationName = c.destination and c.destination.name or nil,
        originZoneTag = c.destination and c.destination.originZoneTag or c.groupTag,
        facilityId = contractFacilityId,
        unitType = c.unitType,
        units = c.units,
      })
    end
  end

  local activeContractForUI = nil
  if Contracts.ContractSystem.activeContract then
    local c = Contracts.ContractSystem.activeContract
    local matConfig = c.material and Config.materials and Config.materials[c.material] or nil
    local materialBreakdown = {}
    if c.materialRequirements then
      for matKey, requiredQty in pairs(c.materialRequirements) do
        local matCfg = Config.materials and Config.materials[matKey]
        table.insert(materialBreakdown, {
          materialKey = matKey,
          materialName = matCfg and matCfg.name or matKey,
          units = matCfg and matCfg.units or "items",
          required = requiredQty
        })
      end
    end
    activeContractForUI = {
      id = c.id,
      name = c.name,
      tier = c.tier,
      material = c.material,
      materialName = matConfig and matConfig.name or c.material,
      materialTypeName = c.materialTypeName,
      requiredTons = c.requiredTons,
      requiredItems = c.requiredItems,
      materialBreakdown = materialBreakdown,
      totalPayout = c.totalPayout,
      paymentType = c.paymentType,
      groupTag = c.groupTag,
      loadingZoneTag = c.loadingZoneTag,
      estimatedTrips = c.estimatedTrips,
      destinationName = c.destination and c.destination.name or nil,
      facilityId = getContractFacilityId(c),
      unitType = c.unitType,
      units = c.units,
    }
  end

  local compat = compatibleZones
  if (not compat or #compat == 0) and Contracts.ContractSystem.activeContract and Contracts.ContractSystem.activeContract.materialTypeName then
    compat = Zones.getZonesByTypeName(Contracts.ContractSystem.activeContract.materialTypeName) or {}
  end

  local compatibleZonesForUI = {}
  if compat and Zones.getZoneStockInfo then
    for _, z in ipairs(compat) do
      local cache = Zones.ensureGroupCache and Zones.ensureGroupCache(z, Contracts.getCurrentGameHour) or nil
      local materialNames = {}
      local materialKeys = z.materials or (z.materialType and { z.materialType } or {})
      for _, matKey in ipairs(materialKeys) do
        local matConfig = Config.materials and Config.materials[matKey]
        table.insert(materialNames, matConfig and matConfig.name or matKey)
      end
      local stockInfo = Zones.getZoneStockInfo(z, Contracts.getCurrentGameHour)
      if stockInfo and stockInfo.materialStocks then
        local enrichedMaterialStocks = {}
        for matKey, stockData in pairs(stockInfo.materialStocks) do
          local matConfig = Config.materials and Config.materials[matKey]
          local isMass = matConfig and matConfig.unitType == "mass"
          enrichedMaterialStocks[matKey] = {
            current = isMass and math.floor((stockData.current / 1000) + 0.5) or math.floor(stockData.current + 0.5),
            max = isMass and math.floor((stockData.max / 1000) + 0.5) or math.floor(stockData.max + 0.5),
            regenRate = stockData.regenRate,
            materialName = matConfig and matConfig.name or matKey,
            units = matConfig and matConfig.units or "items"
          }
        end
        stockInfo.materialStocks = enrichedMaterialStocks
      end
      table.insert(compatibleZonesForUI, {
        zoneTag = z.secondaryTag,
        displayName = cache and cache.name or z.secondaryTag,
        materials = materialNames,
        materialKeys = materialKeys,
        stock = stockInfo,
      })
    end
  end

  local currentZoneDisplayName = nil
  if currentZoneTag then
    local cache = currentZone and Zones.ensureGroupCache and Zones.ensureGroupCache(currentZone, Contracts.getCurrentGameHour) or nil
    currentZoneDisplayName = cache and cache.name or currentZoneTag
  end
  
  local truckState = {
    status = "none",
    truckId = Manager.jobObjects.truckID,
    currentZone = currentZoneDisplayName or currentZoneTag,
    zoneSwapPending = Manager.jobObjects.zoneSwapPending or false
  }
  if Contracts.ContractSystem.activeContract then
    if currentState == Config.STATE_DELIVERING then
      truckState.status = "delivering"
    elseif currentState == Config.STATE_LOADING then
      truckState.status = (Manager.truckStoppedInLoading and "at_zone") or "arriving"
    elseif currentState == Config.STATE_TRUCK_ARRIVING then
      truckState.status = "arriving"
    elseif currentState == Config.STATE_DRIVING_TO_SITE then
      truckState.status = (Manager.jobObjects.truckID and "arriving") or "spawning"
    elseif currentState == Config.STATE_CHOOSING_ZONE then
      truckState.status = "none"
    else
      truckState.status = (Manager.jobObjects.truckID and "arriving") or "none"
    end
  end

  local allZonesStock = (Zones.getAllZonesStockInfo and Contracts.getCurrentGameHour) and Zones.getAllZonesStockInfo(Contracts.getCurrentGameHour) or {}
  
  local isComplete = Contracts.checkContractCompletion and Contracts.checkContractCompletion() or false
  
  local enrichedZoneStock = nil
  if currentZone and Zones.getZoneStockInfo then
    local rawZoneStock = Zones.getZoneStockInfo(currentZone, Contracts.getCurrentGameHour)
    if rawZoneStock and rawZoneStock.materialStocks then
      enrichedZoneStock = {
        current = math.floor(rawZoneStock.current + 0.5),
        max = math.floor(rawZoneStock.max + 0.5),
        materialStocks = {},
        spawnedProps = rawZoneStock.spawnedProps,
        materials = rawZoneStock.materials
      }
      for matKey, stock in pairs(rawZoneStock.materialStocks) do
        local matConfig = Config.materials and Config.materials[matKey]
        local isMass = matConfig and matConfig.unitType == "mass"
        enrichedZoneStock.materialStocks[matKey] = {
          current = isMass and math.floor((stock.current / 1000) + 0.5) or math.floor(stock.current + 0.5),
          max = isMass and math.floor((stock.max / 1000) + 0.5) or math.floor(stock.max + 0.5),
          regenRate = stock.regenRate,
          materialName = matConfig and matConfig.name or matKey,
          units = matConfig and matConfig.units or "items"
        }
      end
    end
  end

  return {
    state = currentState,
    contractsCompleted = Contracts.PlayerData and Contracts.PlayerData.contractsCompleted or 0,
    availableContracts = contractsForUI,
    activeContract = activeContractForUI,
    contractProgress = {
      deliveredTons = Contracts.ContractSystem.contractProgress and Contracts.ContractSystem.contractProgress.deliveredTons or 0,
      totalPaidSoFar = Contracts.ContractSystem.contractProgress and Contracts.ContractSystem.contractProgress.totalPaidSoFar or 0,
      deliveredBlocks = Contracts.ContractSystem.contractProgress and Contracts.ContractSystem.contractProgress.deliveredBlocks or { big = 0, small = 0, total = 0 },
      deliveryCount = Contracts.ContractSystem.contractProgress and Contracts.ContractSystem.contractProgress.deliveryCount or 0,
      deliveredItems = Contracts.ContractSystem.contractProgress and Contracts.ContractSystem.contractProgress.deliveredItems or 0,
      deliveredItemsByMaterial = Contracts.ContractSystem.contractProgress and Contracts.ContractSystem.contractProgress.deliveredItemsByMaterial or {}
    },
    currentLoadMass = (Manager.jobObjects.currentLoadMass or 0) / 1000,
    targetLoad = (function()
      local matType = Manager.jobObjects.materialType
      if matType and Config.materials and Config.materials[matType] then
        local matConfig = Config.materials[matType]
        if matConfig.unitType == "mass" then
          return (matConfig.targetLoad or 25000) / 1000
        end
      end
      return nil
    end)(),
    materialType = Manager.jobObjects.materialType or nil,
    itemBlocks = (Manager.jobObjects.materialType ~= "rocks") and Manager.getItemBlocksStatus() or {},
    anyItemDamaged = Manager.jobObjects.anyItemDamaged or false,
    deliveryBlocks = Manager.jobObjects.deliveryBlocksStatus or {},
    markerCleared = Manager.markerCleared,
    truckStopped = Manager.truckStoppedInLoading,
    zoneStock = enrichedZoneStock,
    currentFacility = currentFacility,
    compatibleZones = compatibleZonesForUI,
    truckState = truckState,
    allZonesStock = allZonesStock,
    allZonesByFacility = allZonesByFacility,
    isComplete = isComplete,
    currentSimTime = Contracts.getSimTime and Contracts.getSimTime() or nil,
  }
end

local function triggerPhoneState()
  local payload = getPhoneStateForUI()
  if payload then
    guihooks.trigger('updateQuarryState', payload)
  end
end

local function loadSubModules()
  local path = "/lua/ge/extensions/gameplay/loading/"
  local files = FS:findFiles(path, "*.lua", -1, true, false)
  
  loadedExtensions = {}
  if files then
    for _, filePath in ipairs(files) do
      local filename = string.match(filePath, "([^/]+)%.lua$")
      if filename then
        local extName = "gameplay_loading_" .. filename
        extensions.unload(extName)
        setExtensionUnloadMode(extName, "manual")
        table.insert(loadedExtensions, extName)
      end
    end
  end
  loadManualUnloadExtensions()

  Config = gameplay_loading_config
  Contracts = gameplay_loading_contracts
  Zones = gameplay_loading_zones
  Manager = gameplay_loading_manager
  UI = gameplay_loading_ui

  if Config then currentState = Config.STATE_IDLE end
end

local function unloadSubModules()
  for _, extName in ipairs(loadedExtensions) do
    extensions.unload(extName)
  end
  loadedExtensions = {}
end

-- Coordination callbacks for modules
local uiCallbacks = {
  onAcceptContract = function(index)
    local contract, zones = Contracts.acceptContract(index, Zones.getZonesByTypeName)
    if contract then
      if Zones and contract.materialTypeName then
        local compatibleZonesList = Zones.getZonesByTypeName(contract.materialTypeName)
        for _, zone in ipairs(compatibleZonesList) do
          local cache = Zones.ensureGroupCache(zone, Contracts.getCurrentGameHour)
          if cache then
            cache.spawnedPropCounts = {}
          end
        end
      end
      Manager.jobObjects.zoneSwapPending = false
      Manager.jobObjects.zoneSwapTargetZone = nil
      Manager.jobObjects.zoneSwapTruckAtDestination = false
      currentState = Config.STATE_CHOOSING_ZONE
      compatibleZones = zones
    end
  end,
  onDeclineAll = function()
    currentState = Config.STATE_IDLE
    Manager.jobOfferSuppressed = true
    triggerPhoneState()
    if career_career and career_career.isActive() and career_saveSystem then
      career_saveSystem.saveCurrent()
    end
  end,
  getCompatibleZones = function()
    if #compatibleZones == 0 and Contracts.ContractSystem.activeContract and Contracts.ContractSystem.activeContract.materialTypeName then
      compatibleZones = Zones.getZonesByTypeName(Contracts.ContractSystem.activeContract.materialTypeName)
    end
    return compatibleZones
  end,
  onSwapZone = function()
    local contract = Contracts.ContractSystem.activeContract
    if contract and contract.materialTypeName then
      if Contracts.checkContractCompletion() then
        if Manager.jobObjects.truckID then
          local obj = be:getObjectByID(Manager.jobObjects.truckID)
          if obj then obj:delete() end
        end
        Manager.cleanupJob(true, Config.STATE_IDLE)
        currentState = Config.STATE_AT_QUARRY_DECIDE
        Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Mission_End_Success')
        ui_message("Contract complete! Ready to finalize.", 6, "success")
        return
      end
      
      compatibleZones = Zones.getZonesByTypeName(contract.materialTypeName)
      if #compatibleZones > 1 then
        if currentState == Config.STATE_DELIVERING and Manager.jobObjects.truckID then
          local truck = be:getObjectByID(Manager.jobObjects.truckID)
          if truck then
            local loadedPropIds = Manager.getLoadedPropIdsInTruck(0.1)
            if loadedPropIds and #loadedPropIds > 0 then
              Manager.jobObjects.zoneSwapLoadedPropIds = loadedPropIds
              local materialType = Manager.jobObjects.materialType
              local matConfig = materialType and Config.materials and Config.materials[materialType]
              
              if matConfig and matConfig.unitType == "item" then
                Manager.jobObjects.deliveryBlocksStatus = Manager.getItemBlocksStatus()
                Manager.jobObjects.zoneSwapDeliveryBlocksStatus = Manager.jobObjects.deliveryBlocksStatus
              end
              
              Manager.jobObjects.zoneSwapDeliveredMass = Manager.jobObjects.lastDeliveredMass or Manager.jobObjects.currentLoadMass or 0
            end
          end
        end
        
        if currentState ~= Config.STATE_DELIVERING then
          Manager.clearProps()
        else
          Manager.jobObjects.zoneSwapClearPropsOnArrival = true
        end
        currentState = Config.STATE_CHOOSING_ZONE
        Manager.jobObjects.zoneSwapPending = true
        Manager.jobObjects.zoneSwapTargetZone = nil
        Manager.jobObjects.zoneSwapTruckAtDestination = false
        
        if Manager.jobObjects.truckID then
          local destPos = Manager.jobObjects.deliveryDestination and vec3(Manager.jobObjects.deliveryDestination.pos) or (Manager.jobObjects.activeGroup and Manager.jobObjects.activeGroup.destination and vec3(Manager.jobObjects.activeGroup.destination.pos))
          if destPos then
            Manager.driveTruckToPoint(Manager.jobObjects.truckID, destPos)
            ui_message("Select new zone. Truck driving to destination...", 5, "info")
          else
            ui_message("Select new zone...", 5, "info")
          end
        else
          ui_message("Select new zone...", 5, "info")
        end
        
        Manager.jobObjects.currentLoadMass = 0
        Manager.jobObjects.lastDeliveredMass = 0
        Manager.deliveryTimer = 0
        Manager.truckStoppedTimer = 0
        Manager.truckLastPosition = nil
        
        triggerPhoneState()
      end
    end
  end,
  onSelectZone = function(zoneIndex)
    if not zoneIndex or zoneIndex <= 0 then
      return
    end
    if #compatibleZones == 0 then
      local contract = Contracts.ContractSystem.activeContract
      if contract and contract.materialTypeName then
        compatibleZones = Zones.getZonesByTypeName(contract.materialTypeName) or {}
      end
    end
    if zoneIndex > #compatibleZones then
      return
    end
    local selectedZone = compatibleZones[zoneIndex]
    local contract = Contracts.ContractSystem.activeContract
    if contract and selectedZone then
      if Manager.jobObjects.zoneSwapPending then
        Manager.jobObjects.zoneSwapTargetZone = selectedZone
        contract.group = selectedZone
        contract.loadingZoneTag = selectedZone.secondaryTag
        local oldGroup = Manager.jobObjects.activeGroup
        Manager.jobObjects.materialType = selectedZone.materialType or contract.material or "rocks"
        Manager.jobObjects.activeGroup = selectedZone
        
        Manager.clearUnloadedProps(oldGroup)
        local playerVeh = be:getPlayerVehicle(0)
        local playerPos = playerVeh and playerVeh:getPosition() or cachedPlayerPos
        Manager.spawnJobMaterials(Contracts, Zones, playerPos)
        
        compatibleZones = {}
        currentState = Config.STATE_DELIVERING
        local targetPos = Manager.getLoadingZoneTargetPos(selectedZone)
        if targetPos then
          core_groundMarkers.setPath(targetPos)
        end
        ui_message(string.format("Zone selected: %s. Truck will spawn when you enter the zone.", selectedZone.secondaryTag), 5, "info")
        triggerPhoneState()
        return
      else
        contract.group = selectedZone
        contract.loadingZoneTag = selectedZone.secondaryTag
        local oldGroup = Manager.jobObjects.activeGroup
        Manager.jobObjects.materialType = selectedZone.materialType or contract.material or "rocks"
        Manager.jobObjects.truckSpawnQueued = true
        local playerVeh = be:getPlayerVehicle(0)
        local playerPos = playerVeh and playerVeh:getPosition() or cachedPlayerPos
        
        Manager.clearUnloadedProps(oldGroup)
        Manager.jobObjects.activeGroup = selectedZone
        Manager.spawnJobMaterials(Contracts, Zones, playerPos)
        
        currentState = Config.STATE_DRIVING_TO_SITE
        Manager.markerCleared = false
        compatibleZones = {}
        local targetPos = Manager.getLoadingZoneTargetPos(selectedZone)
        if targetPos then
          core_groundMarkers.setPath(targetPos)
        end
        ui_message(string.format("Zone selected: %s. Drive to zone.", selectedZone.secondaryTag), 5, "info")
        triggerPhoneState()
      end
    end
  end,
  onAbandonContract = function()
    Contracts.abandonContract(function(deleteTruck) 
      Manager.cleanupJob(deleteTruck, Config.STATE_IDLE) 
      currentState = Config.STATE_IDLE
      compatibleZones = {}
    end)
  end,
  onSendTruck = function()
    if currentState == Config.STATE_DELIVERING then
      return
    end
    if not Manager.jobObjects.truckID then
      return
    end
    local truck = be:getObjectByID(Manager.jobObjects.truckID)
    if not truck then
      Manager.jobObjects.truckID = nil
      return
    end
    local destPos = Manager.jobObjects.deliveryDestination and vec3(Manager.jobObjects.deliveryDestination.pos) or (Manager.jobObjects.activeGroup and Manager.jobObjects.activeGroup.destination and vec3(Manager.jobObjects.activeGroup.destination.pos))
    if destPos then
      local materialType = Manager.jobObjects.materialType
      local matConfig = materialType and Config.materials and Config.materials[materialType]
      if matConfig and matConfig.unitType == "item" then
        Manager.jobObjects.lastDeliveredMass = 0
        Manager.jobObjects.deliveryBlocksStatus = Manager.getItemBlocksStatus()
      else
        Manager.jobObjects.lastDeliveredMass = Manager.jobObjects.currentLoadMass or 0
      end
      Manager.jobObjects.deliveredPropIds = Manager.getLoadedPropIdsInTruck(0.1)
      Manager.deliveryTimer = 0
      Manager.truckStoppedTimer = 0
      Manager.truckLastPosition = nil
      Manager.truckDamage = 0
      Manager.damageCheckQueued = false
      Manager.teleportQueued = false
      core_groundMarkers.setPath(nil)
      Manager.driveTruckToPoint(Manager.jobObjects.truckID, destPos)
      currentState = Config.STATE_DELIVERING
    end
  end,
  onFinalizeContract = function()
    Contracts.completeContract(function(deleteTruck) 
      Manager.cleanupJob(deleteTruck, Config.STATE_IDLE)
      currentState = Config.STATE_IDLE
      if career_career and career_career.isActive() and career_saveSystem then
        career_saveSystem.saveCurrent()
      end
    end, Manager.clearProps)
  end,
  onLoadMore = function()
    if Manager.beginActiveContractTrip(Contracts, Zones, UI) then
      currentState = Config.STATE_DRIVING_TO_SITE
    end
  end,
  onSetZoneWaypoint = function(zoneTag)
    if not zoneTag then return end
    
    for _, zone in ipairs(Zones.availableGroups or {}) do
      if zone.secondaryTag == zoneTag and zone.loading and zone.loading.center then
        local targetPos = vec3(zone.loading.center)
        core_groundMarkers.setPath(targetPos)
        local cache = Zones.ensureGroupCache and Zones.ensureGroupCache(zone, Contracts.getCurrentGameHour) or nil
        local zoneName = cache and cache.name or zoneTag
        ui_message(string.format("Waypoint set to %s", zoneName), 5, "info")
        return
      end
    end
  end
}

local function updatePlayerCache(dt)
  playerCacheTimer = playerCacheTimer + dt
  local checkInterval = Config.settings.zones and Config.settings.zones.checkInterval or 0.1
  if playerCacheTimer >= checkInterval then
    cachedPlayerVeh = be:getPlayerVehicle(0)
    if cachedPlayerVeh then
      local success, pos = pcall(function() return cachedPlayerVeh:getPosition() end)
      if success then
        cachedPlayerPos = pos
      else
        cachedPlayerVeh = nil
        cachedPlayerPos = nil
      end
    else
      cachedPlayerPos = nil
    end
    playerCacheTimer = 0
  end
end

local function forceBrakesAndDisableAI(truckId, truck)
  if not truck or not truckId then return end
  truck:queueLuaCommand("ai.setMode('disabled')")
  truck:queueLuaCommand("input.event('brake', 1, 1)")
  truck:queueLuaCommand("input.event('throttle', 0, 1)")
  truck:queueLuaCommand("input.event('parkingbrake', 1, 1)")
end

local function handleTruckNudging(truckId, truck, targetPos, arrivalDist, atTarget)
  if not truck or not targetPos or not Manager then return false end
  
  local truckPos = truck:getPosition()
  local distToTarget = (truckPos - targetPos):length()
  local timeSinceRoute = os.clock() - (Manager.truckRouteStartTime or 0)
  local canNudge = timeSinceRoute > 5 and distToTarget < 30
  
  if atTarget or not canNudge then return false end
  
  local truckSpeed = truck:getVelocity():length()
  if not Manager.truckNudging and truckSpeed >= 0.5 then return false end
  
  if distToTarget <= arrivalDist then
    return false
  end
  
  Manager.truckNudging = true
  
  local throttle = 0
  local brake = 0
  
  local dirToTarget = (targetPos - truckPos):normalized()
  local truckDir = truck:getDirectionVector():normalized()
  local truckRight = truck:getDirectionVectorUp():cross(truckDir):normalized()
  local steerDot = truckRight:dot(dirToTarget)
  local steering = math.max(-1, -math.min(1, steerDot * 2))
  
  local approachZone = arrivalDist + 5
  local targetSpeed = 9.0
  if distToTarget < 3 then
    targetSpeed = 1.8
  elseif distToTarget < 6 then
    targetSpeed = 3.0
  elseif distToTarget < 10 then
    targetSpeed = 4.8
  elseif distToTarget < 15 then
    targetSpeed = 6.0
  elseif distToTarget <= approachZone and distToTarget > arrivalDist then
    local approachProgress = math.max(0, math.min(1, (distToTarget - arrivalDist) / 5))
    targetSpeed = 0.5 + (1.5 * approachProgress)
  end
  
  local speedError = targetSpeed - truckSpeed
  local speedControlGain = 0.4
  
  if speedError > 0.1 then
    throttle = math.min(1.0, speedError * speedControlGain)
  elseif speedError < -0.1 then
    brake = math.min(0.8, -speedError * speedControlGain * 0.8)
  end
  
  Manager.nudgeTruckWithControl(truckId, throttle, brake, steering)
  return true
end

local function onUpdate(dt)
  if not Config or not Contracts or not Zones or not Manager or not UI then return end

  if Contracts.updateSimTime then
    Contracts.updateSimTime(dt)
  end

  local settingsZones = Config.settings and Config.settings.zones
  local settingsPayload = Config.settings and Config.settings.payload
  local settingsTruck = Config.settings and Config.settings.truck
  local settingsUI = Config.settings and Config.settings.ui

  updatePlayerCache(dt)

  if not cachedPlayerVeh or not cachedPlayerPos then return end
  local playerVeh = cachedPlayerVeh
  local playerPos = cachedPlayerPos

  if Manager.jobObjects.truckID then
    local truck = be:getObjectByID(Manager.jobObjects.truckID)
    if truck then
      local arrivalDist = settingsTruck and settingsTruck.arrivalDistanceThreshold or 10.0
      local truckPos = truck:getPosition()
      local targetPos = nil
      
      if currentState == Config.STATE_DELIVERING then
        targetPos = Manager.jobObjects.deliveryDestination and vec3(Manager.jobObjects.deliveryDestination.pos) or (Manager.jobObjects.activeGroup and Manager.jobObjects.activeGroup.destination and vec3(Manager.jobObjects.activeGroup.destination.pos))
      elseif Manager.jobObjects.zoneSwapPending then
        targetPos = Manager.jobObjects.deliveryDestination and vec3(Manager.jobObjects.deliveryDestination.pos) or (Manager.jobObjects.activeGroup and Manager.jobObjects.activeGroup.destination and vec3(Manager.jobObjects.activeGroup.destination.pos))
      elseif currentState == Config.STATE_TRUCK_ARRIVING or currentState == Config.STATE_LOADING then
        local group = Manager.jobObjects.activeGroup
        if group then
          local hasDesignatedStop = group.stopLocations and #group.stopLocations > 0
          local routingTargetPos = Manager.getLoadingZoneTargetPos(group)
          local stopLocationPos = hasDesignatedStop and group.stopLocations[1] and group.stopLocations[1].pos and vec3(group.stopLocations[1].pos) or nil
          targetPos = stopLocationPos or routingTargetPos
        end
      end
      
      if targetPos then
        local distToTarget = (truckPos - targetPos):length()
        if distToTarget < arrivalDist then
          forceBrakesAndDisableAI(Manager.jobObjects.truckID, truck)
        end
      end
    end
  end

  if not Zones.sitesData then
    Zones.sitesLoadTimer = Zones.sitesLoadTimer + dt
    local retryInterval = settingsZones and settingsZones.sitesLoadRetryInterval or 1.0
    if Zones.sitesLoadTimer >= retryInterval then
      Zones.loadQuarrySites(Contracts.getCurrentGameHour)
      Zones.sitesLoadTimer = 0
    end
  end

  if Contracts.getSimTime then
    Zones.updateZoneStocks(dt, Contracts.getSimTime)
  end
  UI.drawWorkSiteMarker(dt, currentState, Config.STATE_DRIVING_TO_SITE, Manager.markerCleared, Manager.jobObjects.activeGroup)
  UI.drawZoneChoiceMarkers(dt, currentState, Config.STATE_CHOOSING_ZONE, compatibleZones)
  
  if currentState == Config.STATE_LOADING then
    Manager.payloadUpdateTimer = Manager.payloadUpdateTimer + dt
    local payloadInterval = settingsPayload and settingsPayload.updateInterval or 0.25
    if Manager.payloadUpdateTimer >= payloadInterval then
      Manager.jobObjects.currentLoadMass = Manager.calculateTruckPayload()
      Manager.calculateItemDamage()
      Manager.processPendingRespawns(dt, Zones, Contracts)
      Manager.payloadUpdateTimer = 0
    end
  end

  UI.drawDebugOBB()

  local function spawnOrMoveTruckToZone(zone, isZoneSwap)
    if not zone or not zone.loading or not zone.spawn or not zone.spawn.pos then
      return false
    end
    
    local truckExists = false
    if Manager.jobObjects.truckID then
      local truck = be:getObjectByID(Manager.jobObjects.truckID)
      truckExists = truck ~= nil
      if not truckExists then
        Manager.jobObjects.truckID = nil
      end
    end
    
    local shouldSpawnTruck = not Manager.jobObjects.truckID
    local truckReady = false
    
    if shouldSpawnTruck then
      truckReady = true
    elseif truckExists then
      if isZoneSwap then
        truckReady = Manager.jobObjects.zoneSwapTruckAtDestination or false
      else
        truckReady = Manager.jobObjects.truckSpawnQueued or false
      end
    end
    
    if not truckReady then
      return false
    end
    
    local targetPos = Manager.getLoadingZoneTargetPos(zone)
    Manager.jobObjects.loadingZoneTargetPos = targetPos
    
    if shouldSpawnTruck then
      local truckId = Manager.spawnTruckForGroup(zone, Manager.jobObjects.materialType, targetPos)
      if truckId then
        Manager.jobObjects.truckID = truckId
        Manager.driveTruckToPoint(truckId, targetPos)
        Manager.jobObjects.truckSpawnQueued = false
        return true
      end
    elseif truckExists and Manager.jobObjects.truckID then
      local truck = be:getObjectByID(Manager.jobObjects.truckID)
      if truck then
        local pos, rot = Manager.calculateSpawnTransformForLocation(vec3(zone.spawn.pos), targetPos)
        spawn.safeTeleport(truck, pos, rot, nil, nil, nil, true)
        Manager.driveTruckToPoint(Manager.jobObjects.truckID, targetPos)
        return true
      else
        Manager.jobObjects.truckID = nil
        local truckId = Manager.spawnTruckForGroup(zone, Manager.jobObjects.materialType, targetPos)
        if truckId then
          Manager.jobObjects.truckID = truckId
          Manager.driveTruckToPoint(truckId, targetPos)
          Manager.jobObjects.truckSpawnQueued = false
          return true
        end
      end
    end
    
    return false
  end

  if Manager.jobObjects.zoneSwapPending and Manager.jobObjects.zoneSwapTargetZone and Manager.jobObjects.truckID then
    local truck = be:getObjectByID(Manager.jobObjects.truckID)
    if truck then
      local destPos = Manager.jobObjects.deliveryDestination and vec3(Manager.jobObjects.deliveryDestination.pos) or (Manager.jobObjects.activeGroup and Manager.jobObjects.activeGroup.destination and vec3(Manager.jobObjects.activeGroup.destination.pos))
      if destPos then
        local arrivalDist = settingsTruck and settingsTruck.arrivalDistanceThreshold or 10.0
        local truckPos = truck:getPosition()
        if not Manager.jobObjects.zoneSwapTruckAtDestination and (truckPos - destPos):length() < arrivalDist then
          Manager.jobObjects.zoneSwapTruckAtDestination = true
          Manager.stopTruck(Manager.jobObjects.truckID)
          
          if Manager.jobObjects.zoneSwapLoadedPropIds and #Manager.jobObjects.zoneSwapLoadedPropIds > 0 then
            local contract = Contracts.ContractSystem.activeContract
            if contract then
              local materialType = Manager.jobObjects.materialType
              local matConfig = materialType and Config.materials and Config.materials[materialType]
              
              if matConfig and matConfig.unitType == "item" then
                Manager.jobObjects.deliveryBlocksStatus = Manager.jobObjects.zoneSwapDeliveryBlocksStatus
              end
              
              local deliveredMass = Manager.jobObjects.zoneSwapDeliveredMass or 0
              local tons = deliveredMass / 1000
              Contracts.ContractSystem.contractProgress.deliveredTons = (Contracts.ContractSystem.contractProgress.deliveredTons or 0) + tons
              Contracts.ContractSystem.contractProgress.deliveryCount = (Contracts.ContractSystem.contractProgress.deliveryCount or 0) + 1
              
              local contractTypeName = contract.materialTypeName
              if contractTypeName and contract.unitType == "item" then
                local deliveredSet = {}
                for _, id in ipairs(Manager.jobObjects.zoneSwapLoadedPropIds) do deliveredSet[id] = true end
                
                if not Contracts.ContractSystem.contractProgress.deliveredItemsByMaterial then
                  Contracts.ContractSystem.contractProgress.deliveredItemsByMaterial = {}
                end
                
                for _, entry in ipairs(Manager.propQueue) do
                  if entry.id and deliveredSet[entry.id] and entry.materialType then
                    local entryMatConfig = Config.materials and Config.materials[entry.materialType]
                    if entryMatConfig and entryMatConfig.typeName == contractTypeName then
                      Contracts.ContractSystem.contractProgress.deliveredItems = (Contracts.ContractSystem.contractProgress.deliveredItems or 0) + 1
                      Contracts.ContractSystem.contractProgress.deliveredItemsByMaterial[entry.materialType] = (Contracts.ContractSystem.contractProgress.deliveredItemsByMaterial[entry.materialType] or 0) + 1
                    end
                  end
                end
              end
              
              Manager.despawnPropIds(Manager.jobObjects.zoneSwapLoadedPropIds, Zones, Contracts, true)
              Manager.jobObjects.zoneSwapLoadedPropIds = nil
              Manager.jobObjects.deliveredPropIds = nil
              Manager.jobObjects.deliveryBlocksStatus = nil
              Manager.jobObjects.zoneSwapDeliveryBlocksStatus = nil
              
              if Contracts.checkContractCompletion() then
                Manager.jobObjects.zoneSwapPending = false
                Manager.jobObjects.zoneSwapTargetZone = nil
                Manager.jobObjects.zoneSwapTruckAtDestination = false
                Manager.jobObjects.zoneSwapClearPropsOnArrival = false
                Manager.clearProps()
                if Manager.jobObjects.truckID then
                  local truckObj = be:getObjectByID(Manager.jobObjects.truckID)
                  if truckObj then truckObj:delete() end
                  Manager.jobObjects.truckID = nil
                end
                Manager.jobObjects.truckStoppedInLoading, Manager.markerCleared = false, true
                currentState = Config.STATE_AT_QUARRY_DECIDE
                Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Mission_End_Success')
                ui_message("Contract complete! Ready to finalize.", 6, "success")
                core_groundMarkers.setPath(nil)
                return
              end
            end
          end
          
          if Manager.jobObjects.zoneSwapClearPropsOnArrival then
            if not Manager.jobObjects.zoneSwapTargetZone then
              Manager.clearProps()
            end
            Manager.jobObjects.zoneSwapClearPropsOnArrival = false
            if Manager.jobObjects.truckID then
              local truckObj = be:getObjectByID(Manager.jobObjects.truckID)
              if truckObj then truckObj:delete() end
              Manager.jobObjects.truckID = nil
            end
          end
        end
      end
    end
  end

  if Manager.jobObjects.zoneSwapPending and Manager.jobObjects.zoneSwapTargetZone then
    local selectedZone = Manager.jobObjects.zoneSwapTargetZone
    if selectedZone.loading and selectedZone.loading:containsPoint2D(playerPos) then
      if Manager.jobObjects.truckID then
        local truck = be:getObjectByID(Manager.jobObjects.truckID)
        if not truck then
          Manager.jobObjects.truckID = nil
        end
      end
      if Manager.jobObjects.zoneSwapTruckAtDestination and spawnOrMoveTruckToZone(selectedZone, true) then
        currentState = Config.STATE_LOADING
        Manager.truckStoppedInLoading = false
        Manager.markerCleared = false
        Manager.jobObjects.zoneSwapPending = false
        Manager.jobObjects.zoneSwapTargetZone = nil
        Manager.jobObjects.zoneSwapTruckAtDestination = false
        Manager.jobObjects.zoneSwapClearPropsOnArrival = false
        Manager.deliveryTimer = 0
        Manager.truckStoppedTimer = 0
        Manager.truckLastPosition = nil
        core_groundMarkers.setPath(nil)
      end
    end
  end

  if currentState == Config.STATE_IDLE then
    if Manager.jobOfferSuppressed and not Zones.isPlayerInAnyLoadingZone(playerPos) then
      Manager.jobOfferSuppressed = false
    end
    if not Manager.jobOfferSuppressed and playerVeh then
      local success, jbeamFilename = pcall(function() return playerVeh:getJBeamFilename() end)
      if success and jbeamFilename == "wl40" then
        if Zones.isPlayerInAnyLoadingZone(playerPos) then
          local currentZone = Zones.getPlayerCurrentZone and Zones.getPlayerCurrentZone(playerPos)
          local zoneTag = currentZone and currentZone.secondaryTag
          if Contracts.shouldRefreshContracts(zoneTag) or not Contracts.ContractSystem.initialContractsGenerated then
            Contracts.generateInitialContracts(Zones.availableGroups)
          end
          currentState = Config.STATE_CONTRACT_SELECT
          Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Mission_Unlock_01')
        end
      end
    end

  elseif currentState == Config.STATE_CONTRACT_SELECT then
    contractUpdateTimer = contractUpdateTimer + dt
    if contractUpdateTimer >= 1.0 then
      contractUpdateTimer = 0
      Contracts.checkContractExpiration()
      Contracts.trySpawnNewContract(Zones.availableGroups)
    end
    if #Contracts.ContractSystem.availableContracts == 0 and #Zones.availableGroups > 0 then
      if not Contracts.isCareerMode() then
        Contracts.generateInitialContracts(Zones.availableGroups)
      end
    end
    if not Zones.isPlayerInAnyLoadingZone(playerPos) then
      currentState = Config.STATE_IDLE
    end

  elseif currentState == Config.STATE_CHOOSING_ZONE then

  elseif currentState == Config.STATE_DRIVING_TO_SITE then
    local group = Manager.jobObjects.activeGroup
    if not group or not group.loading then
      Contracts.abandonContract(function(deleteTruck) Manager.cleanupJob(deleteTruck, Config.STATE_IDLE) end)
      currentState = Config.STATE_IDLE
      return
    end
    local targetPos = Manager.getLoadingZoneTargetPos(group)
    if targetPos then
      if not core_groundMarkers.getTargetPos() or core_groundMarkers.getTargetPos() ~= targetPos then
        core_groundMarkers.setPath(targetPos)
      end
    end
    
    local hasDesignatedStop = group.stopLocations and #group.stopLocations > 0
    
    if Manager.jobObjects.truckSpawnQueued or not Manager.jobObjects.truckID then
      if spawnOrMoveTruckToZone(group, false) then
        if hasDesignatedStop then
          currentState = Config.STATE_TRUCK_ARRIVING
        else
          currentState = Config.STATE_LOADING
          Manager.truckStoppedInLoading = false
        end
        Manager.deliveryTimer = 0
        Manager.truckStoppedTimer = 0
        Manager.truckLastPosition = nil
        if not hasDesignatedStop then
          core_groundMarkers.setPath(nil)
        end
      end
    end
    
    if group.loading:containsPoint2D(playerPos) then
      if not Manager.markerCleared then
        Manager.markerCleared = true
        if #Manager.propQueue == 0 then
          Manager.spawnJobMaterials(Contracts, Zones, playerPos)
        end
      end
    end
    
    if Manager.markerCleared and not Manager.jobObjects.truckID and Manager.jobObjects.deferredTruckTargetPos then
      Manager.queueTruckSpawn(group, Manager.jobObjects.materialType, Manager.jobObjects.deferredTruckTargetPos, currentState, Config.STATE_DRIVING_TO_SITE, Config.STATE_TRUCK_ARRIVING, function(s) currentState = s end)
    end

  elseif currentState == Config.STATE_TRUCK_ARRIVING then
    local group = Manager.jobObjects.activeGroup
    if not group or not group.loading then
      Contracts.abandonContract(function(deleteTruck) Manager.cleanupJob(deleteTruck, Config.STATE_IDLE) end)
      currentState = Config.STATE_IDLE
      return
    end
    
    if Manager.jobObjects.truckID and not Manager.truckStoppedInLoading then
      local truck = be:getObjectByID(Manager.jobObjects.truckID)
      if not truck then
        Contracts.failContract(0, "Truck lost! Contract failed.", "error", Manager.cleanupJob)
        currentState = Config.STATE_IDLE
        return
      end
      
      local hasDesignatedStop = group.stopLocations and #group.stopLocations > 0
      local routingTargetPos = Manager.getLoadingZoneTargetPos(group)
      local stopLocationPos = hasDesignatedStop and group.stopLocations[1] and group.stopLocations[1].pos and vec3(group.stopLocations[1].pos) or nil
      local truckPos = truck:getPosition()
      local arrivalSpeed = settingsTruck and settingsTruck.arrivalSpeedThreshold or 2.0
      
      if hasDesignatedStop and routingTargetPos then
        local arrivalDist = settingsTruck and settingsTruck.arrivalDistanceThreshold or 10.0
        local arrivalTargetPos = stopLocationPos or routingTargetPos
        local atTarget = (truckPos - arrivalTargetPos):length() < arrivalDist
        
        if not Manager.jobObjects.loadingZoneTargetPos or (Manager.jobObjects.loadingZoneTargetPos - routingTargetPos):length() > 0.1 then
          Manager.jobObjects.loadingZoneTargetPos = routingTargetPos
          Manager.driveTruckToPoint(Manager.jobObjects.truckID, routingTargetPos)
        end
        
        if atTarget and truck:getVelocity():length() < arrivalSpeed then
          Manager.truckNudging = false
          Manager.stopNudging(Manager.jobObjects.truckID)
          Manager.stopTruck(Manager.jobObjects.truckID)
          Manager.truckStoppedInLoading = true
          if #Manager.propQueue == 0 then
            Manager.spawnJobMaterials(Contracts, Zones, playerPos)
          end
          ui_message("Truck arrived at loading zone.", 5, "success")
          currentState = Config.STATE_LOADING
          Manager.deliveryTimer = 0
          Manager.truckStoppedTimer = 0
          Manager.truckLastPosition = nil
          core_groundMarkers.setPath(nil)
          Engine.Audio.playOnce('AudioGui', 'event:>UI>Countdown>3_seconds')
        else
          handleTruckNudging(Manager.jobObjects.truckID, truck, arrivalTargetPos, arrivalDist, atTarget)
        end
      elseif not hasDesignatedStop and group.loading:containsPoint2D(truckPos) and truck:getVelocity():length() < arrivalSpeed then
        Manager.stopTruck(Manager.jobObjects.truckID)
        Manager.truckStoppedInLoading = true
        if #Manager.propQueue == 0 then
          Manager.spawnJobMaterials(Contracts, Zones, playerPos)
        end
        ui_message("Truck arrived at loading zone.", 5, "success")
        currentState = Config.STATE_LOADING
        Manager.deliveryTimer = 0
        Manager.truckStoppedTimer = 0
        Manager.truckLastPosition = nil
        core_groundMarkers.setPath(nil)
        Engine.Audio.playOnce('AudioGui', 'event:>UI>Countdown>3_seconds')
      end
    end

  elseif currentState == Config.STATE_LOADING then
    local group = Manager.jobObjects.activeGroup
    if not group or not group.loading then
      Contracts.abandonContract(function(deleteTruck) Manager.cleanupJob(deleteTruck, Config.STATE_IDLE) end)
      currentState = Config.STATE_IDLE
      return
    end
    
    Manager.deliveryTimer = 0
    Manager.truckStoppedTimer = 0
    Manager.truckLastPosition = nil
    
    if Manager.jobObjects.truckID and not Manager.truckStoppedInLoading then
      local truck = be:getObjectByID(Manager.jobObjects.truckID)
      if not truck then
        Contracts.failContract(0, "Truck lost! Contract failed.", "error", Manager.cleanupJob)
        currentState = Config.STATE_IDLE
        return
      end
      local arrivalSpeed = settingsTruck and settingsTruck.arrivalSpeedThreshold or 2.0
      local hasDesignatedStop = group.stopLocations and #group.stopLocations > 0
      local routingTargetPos = Manager.getLoadingZoneTargetPos(group)
      local stopLocationPos = hasDesignatedStop and group.stopLocations[1] and group.stopLocations[1].pos and vec3(group.stopLocations[1].pos) or nil
      local truckPos = truck:getPosition()
      local arrivalTargetPos = stopLocationPos or routingTargetPos
      local atTarget = arrivalTargetPos and (truckPos - arrivalTargetPos):length() < (settingsTruck and settingsTruck.arrivalDistanceThreshold or 10.0)
      
      if hasDesignatedStop and routingTargetPos then
        if not Manager.jobObjects.loadingZoneTargetPos or (Manager.jobObjects.loadingZoneTargetPos - routingTargetPos):length() > 0.1 then
          Manager.jobObjects.loadingZoneTargetPos = routingTargetPos
          Manager.driveTruckToPoint(Manager.jobObjects.truckID, routingTargetPos)
        end

        if atTarget and truck:getVelocity():length() < arrivalSpeed then
          Manager.truckNudging = false
          Manager.stopNudging(Manager.jobObjects.truckID)
          Manager.stopTruck(Manager.jobObjects.truckID)
          Manager.truckStoppedInLoading = true
          if #Manager.propQueue == 0 then
            Manager.spawnJobMaterials(Contracts, Zones, playerPos)
          end
          ui_message("Truck arrived at loading zone.", 5, "success")
          core_groundMarkers.setPath(nil)
          Engine.Audio.playOnce('AudioGui', 'event:>UI>Countdown>3_seconds')
        else
          handleTruckNudging(Manager.jobObjects.truckID, truck, arrivalTargetPos, settingsTruck and settingsTruck.arrivalDistanceThreshold or 10.0, atTarget)
        end
      elseif not hasDesignatedStop and group.loading:containsPoint2D(truckPos) and truck:getVelocity():length() < arrivalSpeed then
        Manager.stopTruck(Manager.jobObjects.truckID)
        Manager.truckStoppedInLoading = true
        if #Manager.propQueue == 0 then
          Manager.spawnJobMaterials(Contracts, Zones, playerPos)
        end
        ui_message("Truck arrived at loading zone.", 5, "success")
        core_groundMarkers.setPath(nil)
        Engine.Audio.playOnce('AudioGui', 'event:>UI>Countdown>3_seconds')
      end
    end

  elseif currentState == Config.STATE_DELIVERING then
    Manager.payloadUpdateTimer = Manager.payloadUpdateTimer + dt
    local payloadInterval = settingsPayload and settingsPayload.updateInterval or 0.25
    if Manager.payloadUpdateTimer >= payloadInterval then
      Manager.calculateItemDamage()
      Manager.processPendingRespawns(dt, Zones, Contracts)
      Manager.payloadUpdateTimer = 0
    end
    
    local destPos = Manager.jobObjects.deliveryDestination and vec3(Manager.jobObjects.deliveryDestination.pos) or (Manager.jobObjects.activeGroup and Manager.jobObjects.activeGroup.destination and vec3(Manager.jobObjects.activeGroup.destination.pos))
    local movementResult, deliveryTime = Manager.handleTruckMovement(dt, destPos, Contracts)

    -- Nudging logic for delivery destination
    if destPos and Manager.jobObjects.truckID then
      local truck = be:getObjectByID(Manager.jobObjects.truckID)
      if truck then
        local arrivalDist = settingsTruck and settingsTruck.arrivalDistanceThreshold or 10.0
        local truckPos = truck:getPosition()
        local atTarget = (truckPos - destPos):length() < arrivalDist
        
        if not handleTruckNudging(Manager.jobObjects.truckID, truck, destPos, arrivalDist, atTarget) and atTarget and Manager.truckNudging then
          Manager.truckNudging = false
          Manager.stopNudging(Manager.jobObjects.truckID)
        end
      end
    end

    if movementResult == "damaged" then
      local contract = Contracts.ContractSystem.activeContract
      if not contract then Manager.cleanupJob(true, Config.STATE_IDLE); currentState = Config.STATE_IDLE; return end
      
      local stuckPropIds = Manager.getLoadedPropIdsInTruck(0.1)
      
      if deliveryTime and deliveryTime >= 30.0 then
        local deliveredMass = Manager.jobObjects.lastDeliveredMass or 0
        local tons = deliveredMass / 1000
        Contracts.ContractSystem.contractProgress.deliveredTons = (Contracts.ContractSystem.contractProgress.deliveredTons or 0) + tons
        Contracts.ContractSystem.contractProgress.deliveryCount = (Contracts.ContractSystem.contractProgress.deliveryCount or 0) + 1
        
        local contractTypeName = contract.materialTypeName
        if contractTypeName and contract.unitType == "item" and stuckPropIds and #stuckPropIds > 0 then
          local deliveredSet = {}
          for _, id in ipairs(stuckPropIds) do deliveredSet[id] = true end
          
          if not Contracts.ContractSystem.contractProgress.deliveredItemsByMaterial then
            Contracts.ContractSystem.contractProgress.deliveredItemsByMaterial = {}
          end
          
          for _, entry in ipairs(Manager.propQueue) do
            if entry.id and deliveredSet[entry.id] and entry.materialType then
              local entryMatConfig = Config.materials and Config.materials[entry.materialType]
              if entryMatConfig and entryMatConfig.typeName == contractTypeName then
                Contracts.ContractSystem.contractProgress.deliveredItems = (Contracts.ContractSystem.contractProgress.deliveredItems or 0) + 1
                Contracts.ContractSystem.contractProgress.deliveredItemsByMaterial[entry.materialType] = (Contracts.ContractSystem.contractProgress.deliveredItemsByMaterial[entry.materialType] or 0) + 1
              end
            end
          end
        end
      end
      
      if #stuckPropIds > 0 then
        Manager.despawnPropIds(stuckPropIds, Zones, Contracts, true)
      end
      
      local deliveredMass = Manager.jobObjects.lastDeliveredMass or 0
      Manager.jobObjects.deliveredPropIds, Manager.jobObjects.currentLoadMass, Manager.jobObjects.lastDeliveredMass = nil, 0, 0
      Manager.deliveryTimer = 0
      Manager.truckStoppedTimer = 0
      Manager.truckLastPosition = nil
      Manager.truckDamage = 0
      Manager.damageCheckQueued = false
      Manager.teleportQueued = false
      
      if Manager.jobObjects.activeGroup and contract.unitType ~= "item" and deliveredMass > 0 then
        Manager.respawnMassMaterials(Contracts, Zones, deliveredMass)
      end
      
      if Contracts.checkContractCompletion() then
        if Manager.jobObjects.truckID then
          local obj = be:getObjectByID(Manager.jobObjects.truckID)
          if obj then obj:delete() end
        end
        Manager.jobObjects.truckID, Manager.truckStoppedInLoading, Manager.markerCleared = nil, false, true
        currentState = Config.STATE_AT_QUARRY_DECIDE
        Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Mission_End_Success')
        ui_message("Contract complete! Ready to finalize.", 6, "success")
      else
        if #Manager.propQueue == 0 then Manager.spawnJobMaterials(Contracts, Zones, playerPos) end
        local group = Manager.jobObjects.activeGroup
        if group and Manager.jobObjects.truckID then
          local truck = be:getObjectByID(Manager.jobObjects.truckID)
          if truck then
            Manager.stopTruck(Manager.jobObjects.truckID)
            local loadingCenter = vec3(group.loading.center)
            local pos, rot = Manager.calculateSpawnTransformForLocation(vec3(group.spawn.pos), loadingCenter)
            spawn.safeTeleport(truck, pos, rot, nil, nil, nil, true)
            Manager.driveTruckToPoint(Manager.jobObjects.truckID, loadingCenter)
            currentState = Config.STATE_LOADING
            Manager.truckStoppedInLoading = false
          end
        end
      end
    elseif movementResult == true then
      -- Delivery arrived
      local contract = Contracts.ContractSystem.activeContract
      if not contract then Manager.cleanupJob(true, Config.STATE_IDLE); currentState = Config.STATE_IDLE; return end
      
      -- Update progress
      local deliveredMass = Manager.jobObjects.lastDeliveredMass or 0
      local tons = deliveredMass / 1000
      Contracts.ContractSystem.contractProgress.deliveredTons = (Contracts.ContractSystem.contractProgress.deliveredTons or 0) + tons
      Contracts.ContractSystem.contractProgress.deliveryCount = (Contracts.ContractSystem.contractProgress.deliveryCount or 0) + 1
      
      local contractTypeName = contract.materialTypeName
      if contractTypeName and contract.unitType == "item" and Manager.jobObjects.deliveredPropIds then
        local deliveredSet = {}
        for _, id in ipairs(Manager.jobObjects.deliveredPropIds) do deliveredSet[id] = true end
        
        if not Contracts.ContractSystem.contractProgress.deliveredItemsByMaterial then
          Contracts.ContractSystem.contractProgress.deliveredItemsByMaterial = {}
        end
        
        for _, entry in ipairs(Manager.propQueue) do
          if entry.id and deliveredSet[entry.id] and entry.materialType then
            local entryMatConfig = Config.materials and Config.materials[entry.materialType]
            if entryMatConfig and entryMatConfig.typeName == contractTypeName then
              Contracts.ContractSystem.contractProgress.deliveredItems = (Contracts.ContractSystem.contractProgress.deliveredItems or 0) + 1
              Contracts.ContractSystem.contractProgress.deliveredItemsByMaterial[entry.materialType] = (Contracts.ContractSystem.contractProgress.deliveredItemsByMaterial[entry.materialType] or 0) + 1
            end
          end
        end
      end

      if Manager.jobObjects.deliveredPropIds and #Manager.jobObjects.deliveredPropIds > 0 then
        Manager.despawnPropIds(Manager.jobObjects.deliveredPropIds, Zones, Contracts, true)
      end
      
      Manager.jobObjects.deliveredPropIds, Manager.jobObjects.currentLoadMass, Manager.jobObjects.lastDeliveredMass = nil, 0, 0
      Manager.deliveryTimer = 0
      Manager.truckStoppedTimer = 0
      Manager.truckLastPosition = nil
      
      if Manager.jobObjects.activeGroup then
        if contract.unitType ~= "item" and deliveredMass > 0 then
          Manager.respawnMassMaterials(Contracts, Zones, deliveredMass)
        end
        Manager.spawnJobMaterials(Contracts, Zones, playerPos)
      end
      
      if Contracts.checkContractCompletion() then
        if Manager.jobObjects.truckID then
          local obj = be:getObjectByID(Manager.jobObjects.truckID)
          if obj then obj:delete() end
        end
        Manager.jobObjects.truckID, Manager.truckStoppedInLoading, Manager.markerCleared = nil, false, true
        currentState = Config.STATE_AT_QUARRY_DECIDE
        Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Mission_End_Success')
        ui_message("Contract complete! Ready to finalize.", 6, "success")
      else
        Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Mission_End_Success')
        if #Manager.propQueue == 0 then
          if contract.unitType ~= "item" and deliveredMass > 0 then
            Manager.respawnMassMaterials(Contracts, Zones, deliveredMass)
          end
          Manager.spawnJobMaterials(Contracts, Zones, playerPos)
        end
        local group = Manager.jobObjects.activeGroup
        if group and Manager.jobObjects.truckID then
          local truck = be:getObjectByID(Manager.jobObjects.truckID)
          if truck then
            Manager.stopTruck(Manager.jobObjects.truckID)
            local loadingCenter = vec3(group.loading.center)
            local pos, rot = Manager.calculateSpawnTransformForLocation(vec3(group.spawn.pos), loadingCenter)
            spawn.safeTeleport(truck, pos, rot, nil, nil, nil, true)
            Manager.driveTruckToPoint(Manager.jobObjects.truckID, loadingCenter)
            currentState = Config.STATE_LOADING
            Manager.truckStoppedInLoading = false
            Manager.deliveryTimer = 0
            Manager.truckStoppedTimer = 0
            Manager.truckLastPosition = nil
          end
        end
      end
    end
  end

  local uiUpdateInterval = settingsUI and settingsUI.updateInterval or 0.5
  if currentState ~= Config.STATE_IDLE then
    uiUpdateTimer = uiUpdateTimer + dt
    if uiUpdateTimer >= uiUpdateInterval then
      uiUpdateTimer = 0
      triggerPhoneState()
    end
  end
end

local function onExtensionLoaded()
  loadSubModules()
end

local function onExtensionUnloaded()
  if Manager then
    Manager.cleanupJob(true, Config and Config.STATE_IDLE or nil)
  end
  unloadSubModules()
  Config, Contracts, Zones, Manager, UI = nil, nil, nil, nil, nil
  currentState = nil
  compatibleZones = {}
  cachedPlayerVeh = nil
  cachedPlayerPos = nil
  playerCacheTimer = 0
  uiUpdateTimer = 0
  contractUpdateTimer = 0
end

local function onClientStartMission()
  if not Zones then return end
  Zones.sitesData, Zones.availableGroups, Zones.groupCache = nil, {}, {}
  Manager.cleanupJob(true, Config.STATE_IDLE)
  Contracts.ContractSystem.availableContracts, Contracts.ContractSystem.activeContract = {}, nil
  Contracts.ContractSystem.nextContractSpawnTime = nil
  Contracts.ContractSystem.initialContractsGenerated = false
  currentState = Config.STATE_IDLE
  compatibleZones = {}
  cachedPlayerVeh = nil
  cachedPlayerPos = nil
  playerCacheTimer = 0
end

local function onClientEndMission()
  if not Manager then return end
  Manager.cleanupJob(true, Config.STATE_IDLE)
  Zones.sitesData, Zones.availableGroups, Zones.groupCache = nil, {}, {}
  Contracts.ContractSystem.availableContracts, Contracts.ContractSystem.activeContract = {}, nil
  Contracts.ContractSystem.nextContractSpawnTime = nil
  currentState = Config.STATE_IDLE
end

local function onItemDamageCallback(objId, isDamaged)
  if Manager then
    Manager.itemDamageState[objId] = { isDamaged = isDamaged, lastUpdate = os.clock() }
  end
end

local function saveLoadingData(currentSavePath)
  if not career_career or not career_career.isActive() then return end
  if not Contracts or not Zones or not Config then return end
  
  if not currentSavePath then
    local slot, path = career_saveSystem.getCurrentSaveSlot()
    currentSavePath = path
    if not currentSavePath then return end
  end

  local dirPath = currentSavePath .. "/career/rls_career"
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end

  local saveData = {}
  
  local facilitiesByContract = {}
  local activeContractFacilityId = nil
  
  for _, contract in ipairs(Contracts.ContractSystem.availableContracts or {}) do
    local facilityId = contract.facilityId
    if not facilityId and (contract.groupTag or contract.loadingZoneTag) then
      facilityId = Contracts.getFacilityIdForZone(contract.groupTag or contract.loadingZoneTag)
    end
    
    if facilityId then
      if not facilitiesByContract[facilityId] then
        facilitiesByContract[facilityId] = {}
      end
      table.insert(facilitiesByContract[facilityId], Contracts.serializeContract(contract))
    end
  end
  
  if Contracts.ContractSystem.activeContract then
    local contract = Contracts.ContractSystem.activeContract
    activeContractFacilityId = contract.facilityId
    if not activeContractFacilityId and (contract.groupTag or contract.loadingZoneTag) then
      activeContractFacilityId = Contracts.getFacilityIdForZone(contract.groupTag or contract.loadingZoneTag)
    end
  end
  
  for facilityId, contracts in pairs(facilitiesByContract) do
    if not saveData[facilityId] then
      saveData[facilityId] = {
        contracts = {
          availableContracts = {},
          activeContract = nil,
          contractProgress = {},
          nextContractSpawnTime = nil,
          initialContractsGenerated = false
        },
        zoneStocks = {}
      }
    end
    saveData[facilityId].contracts.availableContracts = contracts
  end
  
  if activeContractFacilityId and Contracts.ContractSystem.activeContract then
    if not saveData[activeContractFacilityId] then
      saveData[activeContractFacilityId] = {
        contracts = {
          availableContracts = {},
          activeContract = nil,
          contractProgress = {},
          nextContractSpawnTime = nil,
          initialContractsGenerated = false
        },
        zoneStocks = {}
      }
    end
    saveData[activeContractFacilityId].contracts.activeContract = Contracts.serializeContract(Contracts.ContractSystem.activeContract)
    saveData[activeContractFacilityId].contracts.contractProgress = Contracts.ContractSystem.contractProgress or {}
  end
  
  local earliestSpawnTime = Contracts.ContractSystem.nextContractSpawnTime
  for facilityId, facilityData in pairs(saveData) do
    if earliestSpawnTime then
      facilityData.contracts.nextContractSpawnTime = earliestSpawnTime
    end
    facilityData.contracts.initialContractsGenerated = Contracts.ContractSystem.initialContractsGenerated or false
  end
  
  for zoneTag, cache in pairs(Zones.groupCache or {}) do
    local facilityId = Zones.getFacilityIdForZone(zoneTag)
    if facilityId and Zones.validateZoneBelongsToFacility(zoneTag, facilityId) then
      if not saveData[facilityId] then
        saveData[facilityId] = {
          contracts = {
            availableContracts = {},
            activeContract = nil,
            contractProgress = {},
            nextContractSpawnTime = nil,
            initialContractsGenerated = false
          },
          zoneStocks = {}
        }
      end
      
      if cache.materialStocks then
        local zoneStockData = {
          materialStocks = {},
          spawnedPropCounts = cache.spawnedPropCounts or {}
        }
        
        for matKey, stock in pairs(cache.materialStocks) do
          zoneStockData.materialStocks[matKey] = {
            current = stock.current,
            max = stock.max,
            regenRate = stock.regenRate,
            nextRegenTime = stock.nextRegenTime
          }
        end
        
        saveData[facilityId].zoneStocks[zoneTag] = zoneStockData
      end
    end
  end
  
  career_saveSystem.jsonWriteFileSafe(dirPath .. "/loading.json", saveData, true)
end

local function loadLoadingData()
  if not career_career or not career_career.isActive() then return end
  if not Contracts or not Zones or not Config then return end
  
  if not Zones.sitesData then
    Zones.loadQuarrySites(Contracts.getCurrentGameHour)
  end
  
  local slot, path = career_saveSystem.getCurrentSaveSlot()
  if not path then return end
  
  local filePath = path .. "/career/rls_career/loading.json"
  local saveData = jsonReadFile(filePath) or {}
  
  if not saveData or next(saveData) == nil then return end
  
  local allAvailableContracts = {}
  local activeContract = nil
  local contractProgress = {}
  local nextContractSpawnTime = nil
  local initialContractsGenerated = false
  
  for facilityId, facilityData in pairs(saveData) do
    if not Config.facilities or not Config.facilities[facilityId] then
      goto continue
    end
    
    if facilityData.contracts then
      if facilityData.contracts.availableContracts then
        for _, serializedContract in ipairs(facilityData.contracts.availableContracts) do
          local contract = Contracts.deserializeContract(serializedContract)
          if contract then
            if not contract.facilityId then
              contract.facilityId = facilityId
            end
            if contract.facilityId == facilityId then
              table.insert(allAvailableContracts, contract)
            end
          end
        end
      end
      
      if facilityData.contracts.activeContract and not activeContract then
        local contract = Contracts.deserializeContract(facilityData.contracts.activeContract)
        if contract then
          if not contract.facilityId then
            contract.facilityId = facilityId
          end
          if contract.facilityId == facilityId then
            activeContract = contract
            contractProgress = facilityData.contracts.contractProgress or {}
          end
        end
      end
      
      if facilityData.contracts.nextContractSpawnTime then
        if not nextContractSpawnTime or (facilityData.contracts.nextContractSpawnTime < nextContractSpawnTime) then
          nextContractSpawnTime = facilityData.contracts.nextContractSpawnTime
        end
      end
      
      if facilityData.contracts.initialContractsGenerated then
        initialContractsGenerated = true
      end
    end
    
    if facilityData.zoneStocks then
      for zoneTag, zoneStockData in pairs(facilityData.zoneStocks) do
        if Zones.validateZoneBelongsToFacility(zoneTag, facilityId) then
          local cache = Zones.ensureGroupCache({secondaryTag = zoneTag}, Contracts.getCurrentGameHour)
          if cache then
            if zoneStockData.materialStocks then
              for matKey, stockData in pairs(zoneStockData.materialStocks) do
                if cache.materialStocks[matKey] then
                  cache.materialStocks[matKey].current = stockData.current or cache.materialStocks[matKey].current
                  cache.materialStocks[matKey].max = stockData.max or cache.materialStocks[matKey].max
                  cache.materialStocks[matKey].regenRate = stockData.regenRate or cache.materialStocks[matKey].regenRate
                  cache.materialStocks[matKey].nextRegenTime = stockData.nextRegenTime
                end
              end
            end
            
            if zoneStockData.spawnedPropCounts then
              cache.spawnedPropCounts = zoneStockData.spawnedPropCounts
            end
          end
        end
      end
    end
    
    ::continue::
  end
  
  Contracts.ContractSystem.availableContracts = allAvailableContracts
  Contracts.ContractSystem.activeContract = activeContract
  Contracts.ContractSystem.contractProgress = contractProgress
  Contracts.ContractSystem.nextContractSpawnTime = nextContractSpawnTime
  Contracts.ContractSystem.initialContractsGenerated = initialContractsGenerated
  
  if activeContract and (activeContract.groupTag or activeContract.loadingZoneTag) then
    local zoneTag = activeContract.groupTag or activeContract.loadingZoneTag
    for _, group in ipairs(Zones.availableGroups or {}) do
      if group.secondaryTag == zoneTag then
        activeContract.group = group
        activeContract.loadingZoneTag = zoneTag
        break
      end
    end
  end
  
  Contracts.sortContracts()
end

local function onSaveCurrentSaveSlot(currentSavePath)
  saveLoadingData(currentSavePath)
end

local function onCareerModulesActivated(alreadyInLevel)
  if alreadyInLevel and Contracts and Zones and Config then
    core_jobsystem.create(function(job)
      job.sleep(0.5)
      if Zones.sitesData or Zones.loadQuarrySites then
        if not Zones.sitesData then
          Zones.loadQuarrySites(Contracts.getCurrentGameHour)
        end
        job.sleep(0.1)
        loadLoadingData()
      end
    end)
  end
end

-- API Exports
M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onItemDamageCallback = onItemDamageCallback
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onCareerModulesActivated = onCareerModulesActivated

M.requestQuarryState = function() triggerPhoneState() end
M.acceptContractFromUI = function(index) uiCallbacks.onAcceptContract(index) end
M.declineAllContracts = function() uiCallbacks.onDeclineAll() end
M.abandonContractFromUI = function() uiCallbacks.onAbandonContract() end
M.sendTruckFromUI = function() uiCallbacks.onSendTruck() end
M.finalizeContractFromUI = function() uiCallbacks.onFinalizeContract() end
M.loadMoreFromUI = function() uiCallbacks.onLoadMore() end
M.resumeTruck = function() if Manager then Manager.resumeTruck() end end
M.selectZoneFromUI = function(zoneIndex) uiCallbacks.onSelectZone(zoneIndex) end
M.swapZoneFromUI = function() uiCallbacks.onSwapZone() end
M.setZoneWaypointFromUI = function(zoneTag) uiCallbacks.onSetZoneWaypoint(zoneTag) end

return M
