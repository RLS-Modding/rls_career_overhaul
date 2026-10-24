-- Quarry phone projection from live owner state.
-- Read location, contract and truck view builders before the final projection.
return function(readState)
  local projection = {}
  local QUARRY_UNLOCK_LEVEL = 10
  local KG_PER_TON = 1000
  local DEFAULT_TARGET_LOAD_KG = 25000

  local function getContractFacilityId(contract)
    if not contract then return nil end
    if contract.facilityId then return contract.facilityId end
    if projection.contracts.getFacilityIdForZone then
      return projection.contracts.getFacilityIdForZone(contract.groupTag or contract.loadingZoneTag)
    end
    if projection.zones.getFacilityIdForZone then
      return projection.zones.getFacilityIdForZone(contract.groupTag or contract.loadingZoneTag)
    end
    return nil
  end

  local function buildMaterialBreakdown(contract)
    local materialBreakdown = {}
    if contract.materialRequirements then
      for matKey, requiredQty in pairs(contract.materialRequirements) do
        local matCfg = projection.config.materials and projection.config.materials[matKey]
        table.insert(materialBreakdown, {
          materialKey = matKey,
          materialName = matCfg and matCfg.name or matKey,
          units = matCfg and matCfg.units or "items",
          required = requiredQty
        })
      end
    end
    return materialBreakdown
  end

  -- Mass stock is reported in tons (kg / KG_PER_TON); other units are only rounded.
  local function buildMaterialStocks(materialStocks)
    local enriched = {}
    for matKey, stockData in pairs(materialStocks) do
      local matConfig = projection.config.materials and projection.config.materials[matKey]
      local isMass = matConfig and matConfig.unitType == "mass"
      enriched[matKey] = {
        current = isMass and math.floor((stockData.current / KG_PER_TON) + 0.5) or math.floor(stockData.current + 0.5),
        max = isMass and math.floor((stockData.max / KG_PER_TON) + 0.5) or math.floor(stockData.max + 0.5),
        regenRate = stockData.regenRate,
        materialName = matConfig and matConfig.name or matKey,
        units = matConfig and matConfig.units or "items"
      }
    end
    return enriched
  end

  -- the player is standing in, or nil when the zone owner cannot say.
  local function buildNearbyZones()
    local currentZone = nil
    local allZonesByFacility = {}
    if projection.playerPosition then
      if projection.zones.getPlayerCurrentZone then
        currentZone = projection.zones.getPlayerCurrentZone(projection.playerPosition)
      end
      local zonesByFacility = {}
      for _, zone in ipairs(projection.zones.availableGroups or {}) do
        if zone.loading and zone.loading.center then
          local zoneCenter = vec3(zone.loading.center)
          local dist = (projection.playerPosition - zoneCenter):length()
          dist = math.floor(dist + 0.5)
          local zoneTag = zone.secondaryTag
          local facilityId = projection.zones.getFacilityIdForZone and projection.zones.getFacilityIdForZone(zoneTag) or nil
          local facilityCfg = facilityId and projection.config.facilities and projection.config.facilities[facilityId] or nil
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
          local cache = projection.zones.ensureGroupCache and projection.zones.ensureGroupCache(zone, projection.contracts.getCurrentGameHour) or nil
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
    return currentZone, allZonesByFacility
  end

  local function buildCurrentLocation(currentZone)
    local currentZoneTag = currentZone and currentZone.secondaryTag or nil
    local currentFacilityId = projection.zones.getFacilityIdForZone and projection.zones.getFacilityIdForZone(currentZoneTag) or nil
    local currentFacilityCfg = currentFacilityId and projection.config.facilities and projection.config.facilities[currentFacilityId] or nil
    local currentFacility = currentFacilityId and { id = currentFacilityId, name = (currentFacilityCfg and (currentFacilityCfg.name or currentFacilityId)) or currentFacilityId } or nil
    return currentZoneTag, currentFacilityId, currentFacility
  end

  local function getOperatorUnlock()
    local skillRewards = require("overhaul/lib/jobs/skillRewards")
    local operatorLevel = skillRewards.getSkillLevelRaw("careerSkills-operator", {"careerSkills-operator", "operator"})
    return operatorLevel, operatorLevel >= QUARRY_UNLOCK_LEVEL
  end

  -- Available contracts: none while the quarry is locked, and only those at the current facility
  -- when it is known.
  local function buildAvailableContracts(quarryUnlocked, currentFacilityId)
    local contractsForUI = {}
    for _, contract in ipairs(quarryUnlocked and (projection.contracts.ContractSystem.availableContracts or {}) or {}) do
      local contractFacilityId = getContractFacilityId(contract)
      if not currentFacilityId or (contractFacilityId == currentFacilityId) then
        local matConfig = contract.material and projection.config.materials and projection.config.materials[contract.material] or nil
        local materialBreakdown = buildMaterialBreakdown(contract)
        table.insert(contractsForUI, {
          id = contract.id,
          name = contract.name,
          tier = contract.tier,
          material = contract.material,
          materialName = matConfig and matConfig.name or contract.material,
          materialTypeName = contract.materialTypeName,
          requiredTons = contract.requiredTons,
          requiredItems = contract.requiredItems,
          materialBreakdown = materialBreakdown,
          isBulk = contract.isBulk,
          totalPayout = contract.totalPayout,
          paymentType = contract.paymentType,
          groupTag = contract.groupTag,
          loadingZoneTag = contract.loadingZoneTag,
          estimatedTrips = contract.estimatedTrips,
          expiresAt = contract.expiresAt,
          hoursRemaining = projection.contracts.getContractHoursRemaining(contract),
          expirationHours = contract.expirationHours,
          destinationName = contract.destination and contract.destination.name or nil,
          originZoneTag = contract.destination and contract.destination.originZoneTag or contract.groupTag,
          facilityId = contractFacilityId,
          unitType = contract.unitType,
          units = contract.units,
        })
      end
    end
    return contractsForUI
  end

  -- The contract in progress, or nil when none is active.
  local function buildActiveContract()
    if not projection.contracts.ContractSystem.activeContract then return nil end
    local contract = projection.contracts.ContractSystem.activeContract
    local matConfig = contract.material and projection.config.materials and projection.config.materials[contract.material] or nil
    local materialBreakdown = buildMaterialBreakdown(contract)
    return {
      id = contract.id,
      name = contract.name,
      tier = contract.tier,
      material = contract.material,
      materialName = matConfig and matConfig.name or contract.material,
      materialTypeName = contract.materialTypeName,
      requiredTons = contract.requiredTons,
      requiredItems = contract.requiredItems,
      materialBreakdown = materialBreakdown,
      totalPayout = contract.totalPayout,
      paymentType = contract.paymentType,
      groupTag = contract.groupTag,
      loadingZoneTag = contract.loadingZoneTag,
      estimatedTrips = contract.estimatedTrips,
      destinationName = contract.destination and contract.destination.name or nil,
      facilityId = getContractFacilityId(contract),
      unitType = contract.unitType,
      units = contract.units,
    }
  end

  -- Zones that take the active contract's material, with their stock. Without a compatible-zone
  local function buildCompatibleZones()
    local compat = projection.compatibleZones
    if (not compat or #compat == 0) and projection.contracts.ContractSystem.activeContract and projection.contracts.ContractSystem.activeContract.materialTypeName then
      compat = projection.zones.getZonesByTypeName(projection.contracts.ContractSystem.activeContract.materialTypeName) or {}
    end
    local compatibleZonesForUI = {}
    if compat and projection.zones.getZoneStockInfo then
      for _, z in ipairs(compat) do
        local cache = projection.zones.ensureGroupCache and projection.zones.ensureGroupCache(z, projection.contracts.getCurrentGameHour) or nil
        local materialNames = {}
        local materialKeys = z.materials or (z.materialType and { z.materialType } or {})
        for _, matKey in ipairs(materialKeys) do
          local matConfig = projection.config.materials and projection.config.materials[matKey]
          table.insert(materialNames, matConfig and matConfig.name or matKey)
        end
        local stockInfo = projection.zones.getZoneStockInfo(z, projection.contracts.getCurrentGameHour)
        if stockInfo and stockInfo.materialStocks then
          stockInfo.materialStocks = buildMaterialStocks(stockInfo.materialStocks)
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
    return compatibleZonesForUI
  end

  local function buildTruckState(currentZone, currentZoneTag)
    local currentZoneDisplayName = nil
    if currentZoneTag then
      local cache = currentZone and projection.zones.ensureGroupCache and projection.zones.ensureGroupCache(currentZone, projection.contracts.getCurrentGameHour) or nil
      currentZoneDisplayName = cache and cache.name or currentZoneTag
    end
    local truckState = {
      status = "none",
      truckId = projection.manager.jobObjects.truckID,
      currentZone = currentZoneDisplayName or currentZoneTag,
      zoneSwapPending = projection.manager.jobObjects.zoneSwapPending or false
    }
    if projection.contracts.ContractSystem.activeContract then
      if projection.currentState == projection.config.STATE_DELIVERING then
        truckState.status = "delivering"
      elseif projection.currentState == projection.config.STATE_LOADING then
        truckState.status = (projection.manager.truckStoppedInLoading and "at_zone") or "arriving"
      elseif projection.currentState == projection.config.STATE_TRUCK_ARRIVING then
        truckState.status = "arriving"
      elseif projection.currentState == projection.config.STATE_DRIVING_TO_SITE then
        truckState.status = (projection.manager.jobObjects.truckID and "arriving") or "spawning"
      elseif projection.currentState == projection.config.STATE_CHOOSING_ZONE then
        truckState.status = "none"
      else
        truckState.status = (projection.manager.jobObjects.truckID and "arriving") or "none"
      end
    end
    return truckState
  end

  -- Stock of the zone the player is standing in, rounded for display; nil when unavailable.
  local function buildZoneStock(currentZone)
    local enrichedZoneStock = nil
    if currentZone and projection.zones.getZoneStockInfo then
      local rawZoneStock = projection.zones.getZoneStockInfo(currentZone, projection.contracts.getCurrentGameHour)
      if rawZoneStock and rawZoneStock.materialStocks then
        -- Read raw contract fields before material lookup to keep projection side effects ordered.
        enrichedZoneStock = {
          current = math.floor(rawZoneStock.current + 0.5),
          max = math.floor(rawZoneStock.max + 0.5),
          materialStocks = {},
          spawnedProps = rawZoneStock.spawnedProps,
          materials = rawZoneStock.materials
        }
        enrichedZoneStock.materialStocks = buildMaterialStocks(rawZoneStock.materialStocks)
      end
    end
    return enrichedZoneStock
  end

  local function buildContractProgress()
    return {
      deliveredTons = projection.contracts.ContractSystem.contractProgress and projection.contracts.ContractSystem.contractProgress.deliveredTons or 0,
      totalPaidSoFar = projection.contracts.ContractSystem.contractProgress and projection.contracts.ContractSystem.contractProgress.totalPaidSoFar or 0,
      deliveredBlocks = projection.contracts.ContractSystem.contractProgress and projection.contracts.ContractSystem.contractProgress.deliveredBlocks or { big = 0, small = 0, total = 0 },
      deliveryCount = projection.contracts.ContractSystem.contractProgress and projection.contracts.ContractSystem.contractProgress.deliveryCount or 0,
      deliveredItems = projection.contracts.ContractSystem.contractProgress and projection.contracts.ContractSystem.contractProgress.deliveredItems or 0,
      deliveredItemsByMaterial = projection.contracts.ContractSystem.contractProgress and projection.contracts.ContractSystem.contractProgress.deliveredItemsByMaterial or {}
    }
  end

  local function buildTargetLoad()
    local matType = projection.manager.jobObjects.materialType
    if matType and projection.config.materials and projection.config.materials[matType] then
      local matConfig = projection.config.materials[matType]
      if matConfig.unitType == "mass" then
        return (matConfig.targetLoad or DEFAULT_TARGET_LOAD_KG) / KG_PER_TON
      end
    end
    return nil
  end

  local function getPhoneStateForUI()
    if not projection.config or not projection.contracts or not projection.zones or not projection.manager then return nil end
    local currentZone, allZonesByFacility = buildNearbyZones()
    currentZone = currentZone or projection.manager.jobObjects.activeGroup
    local currentZoneTag, currentFacilityId, currentFacility = buildCurrentLocation(currentZone)
    local operatorLevel, quarryUnlocked = getOperatorUnlock()
    local contractsForUI = buildAvailableContracts(quarryUnlocked, currentFacilityId)
    local activeContractForUI = buildActiveContract()
    local compatibleZonesForUI = buildCompatibleZones()
    local truckState = buildTruckState(currentZone, currentZoneTag)
    local allZonesStock = (projection.zones.getAllZonesStockInfo and projection.contracts.getCurrentGameHour) and projection.zones.getAllZonesStockInfo(projection.contracts.getCurrentGameHour) or {}
    local isComplete = projection.contracts.checkContractCompletion and projection.contracts.checkContractCompletion() or false
    local enrichedZoneStock = buildZoneStock(currentZone)
    return {
      state = projection.currentState,
      operatorLevel = operatorLevel,
      quarryUnlocked = quarryUnlocked,
      quarryUnlockLevel = QUARRY_UNLOCK_LEVEL,
      contractsCompleted = projection.contracts.PlayerData and projection.contracts.PlayerData.contractsCompleted or 0,
      availableContracts = contractsForUI,
      activeContract = activeContractForUI,
      contractProgress = buildContractProgress(),
      currentLoadMass = (projection.manager.jobObjects.currentLoadMass or 0) / KG_PER_TON,
      targetLoad = buildTargetLoad(),
      materialType = projection.manager.jobObjects.materialType or nil,
      itemBlocks = (projection.manager.jobObjects.materialType ~= "rocks") and projection.manager.getItemBlocksStatus() or {},
      anyItemDamaged = projection.manager.jobObjects.anyItemDamaged or false,
      deliveryBlocks = projection.manager.jobObjects.deliveryBlocksStatus or {},
      markerCleared = projection.manager.markerCleared,
      truckStopped = projection.manager.truckStoppedInLoading,
      zoneStock = enrichedZoneStock,
      currentFacility = currentFacility,
      compatibleZones = compatibleZonesForUI,
      truckState = truckState,
      allZonesStock = allZonesStock,
      allZonesByFacility = allZonesByFacility,
      isComplete = isComplete,
      currentSimTime = projection.contracts.getSimTime and projection.contracts.getSimTime() or nil,
    }
  end

  return {
    getPhoneStateForUI = function(...)
      projection.config, projection.contracts, projection.manager, projection.zones, projection.playerPosition, projection.compatibleZones, projection.currentState = readState()
      return getPhoneStateForUI(...)
    end,
  }

end
