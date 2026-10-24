-- Recovery offer generation, contract lookup and board projections.
-- Each exported call reads the owner state again so replacing a save cannot leave stale references.
return function(arrayToVec3, buildVehiclePool, candidateCanSpawn, chooseWeighted, constants,
      economyMultiplier, fixedCashQuote, getOwnedRecoveryYards, getPlayerPosition, getSkillLevel,
      getSpotKey, getSpotMinLevel, isRememberedUnspawnable, loadRecoverySites, objectivePosition,
      offerVehicleValue, randomMileageMeters, rememberUnspawnable, removeVehicleCandidate,
      rollCondition, spotAllowsRewardType, toQuatArray, toVec3Array, vehicleFitsSpot, readState)
  -- Refresh the owner's board and current map before each exported call to avoid stale references.
  local availableOffers
  local currentMap
  local simMinutes
  local state
  local function getMapState(mapId)
    if not mapId then return nil end
    state.maps[mapId] = state.maps[mapId] or {jobs = {}, trackedJobId = nil}
    state.maps[mapId].jobs = state.maps[mapId].jobs or {}
    return state.maps[mapId]
  end

  local function findJob(jobId)
    if not jobId then return nil end
    for mapId, mapState in pairs(state.maps or {}) do
      for _, job in ipairs(mapState.jobs or {}) do
        if job.id == jobId then return job, mapId, mapState end
      end
    end
  end

  local function findOffer(offerId)
    for index, offer in ipairs(availableOffers) do
      if offer.id == offerId then return offer, index end
    end
  end

  local function reservedSpotNames(mapId)
    local reservedSpotKeys = {}
    if mapId == currentMap then
      for _, offer in ipairs(availableOffers) do reservedSpotKeys[offer.spotName] = true end
    end
    local mapState = getMapState(mapId)
    for _, job in ipairs(mapState and mapState.jobs or {}) do reservedSpotKeys[job.spotName] = true end
    return reservedSpotKeys
  end

  local function nextContractId(prefix)
    local id = string.format("%s-%s-%d", prefix or "recovery", tostring(currentMap or "map"), state.nextId or 1)
    state.nextId = (state.nextId or 1) + 1
    return id
  end

  local function activeCount(mapId)
    local mapState = getMapState(mapId)
    return #(mapState and mapState.jobs or {})
  end

  local function offerCount()
    return #availableOffers
  end

  local function pickVehicleAndSpot(rewardType)
    local recoverySites = loadRecoverySites()
    local spots = recoverySites and recoverySites.parkingSpots and recoverySites.parkingSpots.objects
    if not spots then return nil end
    local skillLevel = getSkillLevel()
    local reservedSpotKeys = reservedSpotNames(currentMap)
    local eligibleSpots = {}
    for _, spot in pairs(spots) do
      local spotKey = getSpotKey(spot)
      if spot.pos and spotKey and not reservedSpotKeys[spotKey] and skillLevel >= getSpotMinLevel(spot)
          and spotAllowsRewardType(spot, rewardType) then
        eligibleSpots[#eligibleSpots + 1] = spot
      end
    end
    for shuffleIndex = #eligibleSpots, 2, -1 do
      local randomIndex = math.random(shuffleIndex)
      eligibleSpots[shuffleIndex], eligibleSpots[randomIndex] = eligibleSpots[randomIndex], eligibleSpots[shuffleIndex]
    end
    local pool = buildVehiclePool()
    for _, spot in ipairs(eligibleSpots) do
      local fittingVehicles = {}
      for _, candidate in ipairs(pool) do
        if not isRememberedUnspawnable(candidate.model_key, candidate.key)
            and vehicleFitsSpot(candidate, spot) then
          fittingVehicles[#fittingVehicles + 1] = candidate
        end
      end
      while #fittingVehicles > 0 do
        local vehicleInfo = chooseWeighted(fittingVehicles)
        if not vehicleInfo then break end
        if candidateCanSpawn(vehicleInfo) then return deepcopy(vehicleInfo), spot end
        rememberUnspawnable(vehicleInfo.model_key, vehicleInfo.key)
        fittingVehicles = removeVehicleCandidate(fittingVehicles, vehicleInfo)
      end
    end
  end

  local function generateOffer()
    if offerCount() >= constants.MAX_OFFERS or not currentMap then return nil end
    local skillLevel = getSkillLevel()
    local rewardType = skillLevel >= 10 and math.random(100) <= skillLevel and "vehicle" or "cash"
    local vehicleInfo, spot = pickVehicleAndSpot(rewardType)
    if not vehicleInfo or not spot then return nil end
    local years = vehicleInfo.Years or (vehicleInfo.aggregates and vehicleInfo.aggregates.Years)
    if type(years) == "table" and tonumber(years.min) and tonumber(years.max) then
      vehicleInfo.year = math.random(tonumber(years.min), tonumber(years.max))
    else
      vehicleInfo.year = 2023
    end
    vehicleInfo.Mileage = randomMileageMeters(vehicleInfo.year)
    local condition, missingWheelCount = rollCondition(vehicleInfo)
    local offer = {
      id = nextContractId("offer"),
      createdAt = simMinutes,
      expiresAt = simMinutes + constants.OFFER_TTL_MIN,
      spotName = getSpotKey(spot),
      targetPos = toVec3Array(spot.pos),
      targetRot = toQuatArray(spot.rot or quat(0, 0, 0, 1)),
      minLevel = getSpotMinLevel(spot),
      difficultyFee = spot.customFields and spot.customFields.values and tonumber(spot.customFields.values.difficultyFee),
      model = vehicleInfo.model_key,
      configKey = vehicleInfo.key,
      brand = vehicleInfo.Brand or vehicleInfo.model_key or "Unknown",
      name = vehicleInfo.Name or vehicleInfo.key or "Vehicle",
      year = vehicleInfo.year,
      mileage = vehicleInfo.Mileage,
      vehicleType = vehicleInfo.Type,
      recoveryTag = vehicleInfo.recoveryTag,
      tierLabel = vehicleInfo.recoveryTierLabel,
      payMultiplier = vehicleInfo.recoveryPayMultiplier,
      baseXp = vehicleInfo.recoveryBaseXp,
      vehicleValue = offerVehicleValue(vehicleInfo),
      rewardType = rewardType,
      condition = condition,
      missingWheelCount = missingWheelCount,
      wheelSeed = math.random(1000000)
    }
    if offer.rewardType == "cash" then
      local yards = getOwnedRecoveryYards()
      if #yards == 1 then offer.cashReward = select(1, fixedCashQuote(offer, yards[1])) end
    end
    availableOffers[#availableOffers + 1] = offer
    extensions.hook("onOffroadRecoveryOfferGenerated", offer.id)
    return offer
  end

  local function pickTrackedJobId(mapState)
    local fallback
    for _, candidate in ipairs(mapState and mapState.jobs or {}) do
      if candidate.status ~= "missing" then
        fallback = fallback or candidate.id
        if candidate.phase ~= "delivery" then
          return candidate.id
        end
      end
    end
    return fallback
  end

  local function removeJobFromState(job)
    local mapState = getMapState(job.mapId)
    for index, candidate in ipairs(mapState.jobs) do
      if candidate.id == job.id then
        table.remove(mapState.jobs, index)
        break
      end
    end
    if mapState.trackedJobId == job.id then
      mapState.trackedJobId = pickTrackedJobId(mapState)
    end
  end

  local function offersAvailableReason()
    if not currentMap then return false, "Enter a supported career map." end
    if getSkillLevel() < 5 then return false, "Reach Recovery level 5 to accept Off-Road Recovery contracts." end
    if economyMultiplier() <= 0 then return false, "Off-Road Recovery is disabled by the current economy settings." end
    local yards = getOwnedRecoveryYards()
    if #yards == 0 then return false, "Purchase or finance a Recovery Yard on this map to accept contracts.", yards end
    local recoverySites = loadRecoverySites()
    if not (recoverySites and recoverySites.parkingSpots and recoverySites.parkingSpots.objects and next(recoverySites.parkingSpots.objects)) then
      return false, "This map has no Off-Road Recovery locations.", yards
    end
    return true, nil, yards
  end

  local function offerUiData(offer, showCashReward)
    local playerPos = getPlayerPosition()
    return {
      id = offer.id,
      brand = offer.brand,
      name = offer.name,
      year = offer.year,
      tierLabel = offer.tierLabel,
      rewardType = offer.rewardType,
      cashReward = offer.rewardType == "cash" and showCashReward and offer.cashReward or nil,
      distance = playerPos and math.floor(playerPos:distance(arrayToVec3(offer.targetPos)) / 100 + 0.5) * 100 or 0,
      expiresIn = math.max(0, math.ceil((offer.expiresAt or simMinutes) - simMinutes)) * 60
    }
  end

  local function jobUiData(job)
    local objective = objectivePosition(job)
    local playerPos = getPlayerPosition()
    return {
      id = job.id,
      mapId = job.mapId,
      brand = job.brand,
      name = job.name,
      year = job.year,
      tierLabel = job.tierLabel,
      rewardType = job.rewardType,
      cashReward = job.rewardType == "cash" and job.cashReward or nil,
      yardName = job.yardName,
      status = job.status,
      phase = job.phase,
      tracked = job.mapId == currentMap and getMapState(currentMap).trackedJobId == job.id,
      distance = playerPos and objective and math.floor(playerPos:distance(objective) / 100 + 0.5) * 100 or 0
    }
  end

  return {
    activeCount = function(...)
      availableOffers, currentMap, simMinutes, state = readState()
      return activeCount(...)
    end,
    findJob = function(...)
      availableOffers, currentMap, simMinutes, state = readState()
      return findJob(...)
    end,
    findOffer = function(...)
      availableOffers, currentMap, simMinutes, state = readState()
      return findOffer(...)
    end,
    generateOffer = function(...)
      availableOffers, currentMap, simMinutes, state = readState()
      return generateOffer(...)
    end,
    getMapState = function(...)
      availableOffers, currentMap, simMinutes, state = readState()
      return getMapState(...)
    end,
    jobUiData = function(...)
      availableOffers, currentMap, simMinutes, state = readState()
      return jobUiData(...)
    end,
    nextContractId = function(...)
      availableOffers, currentMap, simMinutes, state = readState()
      return nextContractId(...)
    end,
    offerCount = function(...)
      availableOffers, currentMap, simMinutes, state = readState()
      return offerCount(...)
    end,
    offerUiData = function(...)
      availableOffers, currentMap, simMinutes, state = readState()
      return offerUiData(...)
    end,
    offersAvailableReason = function(...)
      availableOffers, currentMap, simMinutes, state = readState()
      return offersAvailableReason(...)
    end,
    removeJobFromState = function(...)
      availableOffers, currentMap, simMinutes, state = readState()
      return removeJobFromState(...)
    end,
  }
end
