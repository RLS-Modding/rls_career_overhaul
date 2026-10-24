-- Selects repo destinations, pickup spots and vehicle configurations for standalone or company jobs.
-- Read generation steps first, then destination and pickup selection, configuration and display helpers.
return function(
  VehicleRepoJob,
  buildRepoStateData,
  configListGenerator,
  getEligibleRepoVehiclesForDealership,
  parkingReservation,
  pickWeightedRepoVehicleInfo,
  usedVehicleCondition
)
  -- Shared helpers ----------------------------------------------------------------------------------
  local function abortRepoGeneration(self, message)
    if message then log("W", "repo", message) end
    if self.employmentMode then
      local onAbort = self.employmentOnAbort
      self.employmentOnComplete = nil
      self.employmentOnAbort = nil
      self:resetToInitialState()
      if onAbort then onAbort(message or "Car haul failed.", true) end
      return
    end
    self:resetToInitialState()
    guihooks.trigger("updateRepoState", buildRepoStateData(self))
  end

  -- Five frame boundaries let the engine and vehicle state settle between generation steps.
  local function yieldGenerationFrames()
    for _ = 1, 5 do
      coroutine.yield()
    end
  end
  local function prepareGenerationDestination(self)
    if self.employmentMode then
      self:selectEmploymentDelivery()
      if not self.deliveryLocation then
        abortRepoGeneration(self, "No dropoff found for company haul assignment")
        return false
      end
      yieldGenerationFrames()
      self:buildEmploymentVehiclePool()
      if not self.employmentVehicleCandidates or #self.employmentVehicleCandidates == 0 then
        abortRepoGeneration(self, "No vehicles available for company pickup assignment")
        return false
      end
    else
      self:selectDealership()
      if not self.selectedDealership then
        abortRepoGeneration(self, "No dealership found for repo job generation")
        return false
      end
      yieldGenerationFrames()

      self:determineDeliveryLocation()
      if not self.deliveryLocation then
        abortRepoGeneration(self, "No reservable dealership dropoff spot found for repo job generation")
        return false
      end
    end
    yieldGenerationFrames()
    return true
  end
  local function prepareGenerationPickup(self)
    if self.employmentMode and self:selectEmploymentPickup() then
      -- Partner-yard pickup spots already filled into validSpots.
    else
      self:filterValidSpots()
    end
    yieldGenerationFrames()

    self:selectRandomSpot()
    if not self.selectedSpot then
      abortRepoGeneration(self, "No reservable pickup spot found for repo job generation")
      return false
    end
    yieldGenerationFrames()

    self:generateVehicleConfig()
    if not self.vehicleConfig then
      abortRepoGeneration(self)
      return false
    end
    yieldGenerationFrames()
    return true
  end
  local function spawnWhenStationary(self)
    -- Wait for player vehicle to be stationary before spawning
    local playerSpeedMps = be:getPlayerVehicle(0):getVelocity():length()
    while not self.spawnedVehicle and playerSpeedMps > 1 do
      coroutine.yield()
      playerSpeedMps = be:getPlayerVehicle(0):getVelocity():length()
    end
    if not self.spawnedVehicle then
      self:spawnVehicle()
      if not self.vehicleId then
        abortRepoGeneration(self)
        return
      end
      self.spawnedVehicle = true
    end
    local finalData = buildRepoStateData(self)
    guihooks.trigger("updateRepoState", finalData)
  end
  local function runGeneration(self)
    self:initializePlayerVehicle()
    yieldGenerationFrames()

    self:findParkingSpots()
    yieldGenerationFrames()
    if not prepareGenerationDestination(self) then return end
    if not prepareGenerationPickup(self) then return end
    spawnWhenStationary(self)
  end

  -- Generation --------------------------------------------------------------------------------------

  function VehicleRepoJob:generateJob()
    self:resetToInitialState({ preserveEmployment = true })
    self.reservationToken = parkingReservation.makeReservationToken("repo")
    local stateData = buildRepoStateData(self, {
      state = "loading",
      vehicle = nil,
      deliveryLocation = "",
      distanceToDestination = 0,
      totalDistance = 0,
      reward = 0,
      repoTag = "",
      repoTierLabel = "",
    })
    guihooks.trigger("updateRepoState", stateData)
    self.jobCoroutine = coroutine.create(function() runGeneration(self) end)
  end

  -- Destinations and pickup spots --------------------------------------------------------------------

  function VehicleRepoJob:selectDealership()
    local facilities = overhaul_world_facilities.getFacilities(getCurrentLevelIdentifier())
    local dealerships = {}
    for _, facility in ipairs(facilities and facilities.dealerships or {}) do
      dealerships[#dealerships + 1] = facility
    end
    -- Repair/recovery yards participate in the normal repo selection and skill pool.
    local generator = overhaul_career_logistics_generator
    for _, facility in ipairs(generator and generator.getFacilities() or {}) do
      if facility.repoProvider then dealerships[#dealerships + 1] = facility end
    end
    if not dealerships or #dealerships == 0 then return end
    self.eligibleVehicles = configListGenerator.getEligibleVehicles(false, false) or {}
    self.availableDealerships = {}
    self.eligibleRepoVehiclesByDealership = {}
    for _, dealership in ipairs(parkingReservation.shuffleSpots(dealerships)) do
      local repoCandidates = getEligibleRepoVehiclesForDealership(dealership, self.eligibleVehicles)
      if repoCandidates and #repoCandidates > 0 then
        self.eligibleRepoVehiclesByDealership[dealership.id] = repoCandidates
        table.insert(self.availableDealerships, dealership)
      else
        log(
          "I",
          "repo",
          string.format("Skipping dealership '%s'; no unlocked repo candidates found", tostring(dealership.name))
        )
      end
    end
    self.selectedDealership = self.availableDealerships[1]
  end
  local function pickStaticFacilitySpot(spots)
    for _, spot in ipairs(parkingReservation.shuffleSpots(spots or {})) do
      if spot and spot.pos then return spot end
    end
  end
  local function appendUniqueFacilitySpot(spotList, seenKeys, spot)
    if not spot or not spot.pos then return end
    local key = (spot.getPath and spot:getPath()) or spot.psPath or spot.name or spot
    if seenKeys[key] then return end
    seenKeys[key] = true
    table.insert(spotList, spot)
  end
  local function appendFacilitySpotCollection(spotList, seenKeys, collection)
    if type(collection) ~= "table" then return end
    if collection[1] then
      for _, spot in ipairs(collection) do
        appendUniqueFacilitySpot(spotList, seenKeys, spot)
      end
    else
      for _, spot in pairs(collection) do
        if type(spot) == "table" then appendUniqueFacilitySpot(spotList, seenKeys, spot) end
      end
    end
  end
  local function getEmploymentDeliveryFacility(facilityId)
    if not facilityId then return nil end
    if overhaul_career_career.isActive() then
      local facility = overhaul_career_logistics_generator.getFacilityById(facilityId)
      if facility then return facility end
    end
    return overhaul_world_facilities.getFacility("deliveryProvider", facilityId)
  end
  local function collectEmploymentDeliverySpots(facility)
    local facilitySpots, seenKeys = {}, {}
    if not facility then return facilitySpots end
    appendFacilitySpotCollection(facilitySpots, seenKeys, facility.loanerTrailerSpots)
    appendFacilitySpotCollection(facilitySpots, seenKeys, facility.dropOffSpots)
    appendFacilitySpotCollection(facilitySpots, seenKeys, facility.loanerNonTrailerSpots)
    appendFacilitySpotCollection(facilitySpots, seenKeys, facility.inspectSpots)
    appendFacilitySpotCollection(facilitySpots, seenKeys, facility.pickUpSpots)
    for _, spot in ipairs(overhaul_world_facilities.getParkingSpotsForFacility(facility) or {}) do
      appendUniqueFacilitySpot(facilitySpots, seenKeys, spot)
    end
    return facilitySpots
  end

  -- Company employment: return recovered vehicles to the employer yard, not a dealership.
  function VehicleRepoJob:selectEmploymentDelivery()
    self.deliveryLocation = nil
    self:releaseDeliveryReservation()
    local facilityId = self.employmentHomeFacId
    local facility = getEmploymentDeliveryFacility(facilityId)
    if not facility then
      log("W", "repo", string.format("Employment delivery facility not found: %s", tostring(facilityId)))
      return
    end
    local yardName = self.employmentDeliveryLabel or facility.name or facility.id or "the company yard"
    self.employmentDeliveryLabel = yardName
    self.selectedDealership = { id = facilityId, name = yardName }
    local facilitySpots, seenKeys = {}, {}
    appendFacilitySpotCollection(facilitySpots, seenKeys, facility.inspectSpots)
    for _, accessPoint in pairs(facility.accessPointsByName or {}) do
      if accessPoint.isInspectSpot and accessPoint.ps then
        appendUniqueFacilitySpot(facilitySpots, seenKeys, accessPoint.ps)
      end
    end
    if not facilitySpots[1] then
      log(
        "W",
        "repo",
        string.format("No parking spots on employer facility '%s' (%s)", tostring(yardName), tostring(facilityId))
      )
      return
    end
    local spotLists = { facilitySpots }
    for _, spots in ipairs(spotLists) do
      local liveDeliverySpot =
        parkingReservation.findReservableSpot(parkingReservation.shuffleSpots(spots), self.reservationToken)
      if liveDeliverySpot then
        self.deliveryLocation = liveDeliverySpot
        self.reservedDeliverySpot = liveDeliverySpot
        log("I", "repo", string.format("Employment dropoff at '%s' (%s)", tostring(yardName), tostring(facilityId)))
        return
      end
      local staticDeliverySpot = pickStaticFacilitySpot(spots)
      if staticDeliverySpot then
        self.deliveryLocation = staticDeliverySpot
        self.reservedDeliverySpot = nil
        log(
          "I",
          "repo",
          string.format("Using static employer dropoff for '%s' (%s)", tostring(yardName), tostring(facilityId))
        )
        return
      end
    end

    log(
      "W",
      "repo",
      string.format("No dropoff spot found at employer '%s' (%s)", tostring(yardName), tostring(facilityId))
    )
  end

  -- Partner-yard pickup for company haul (no city-wide distance gates).
  function VehicleRepoJob:selectEmploymentPickup()
    self.validSpots = {}
    local facilityId = self.employmentPickupFacId
    if not facilityId then return false end
    local facility = getEmploymentDeliveryFacility(facilityId)
    if not facility then
      log("W", "repo", string.format("Employment pickup facility not found: %s", tostring(facilityId)))
      return false
    end
    local facilitySpots = collectEmploymentDeliverySpots(facility)
    if not facilitySpots[1] then
      log("W", "repo", string.format("No parking spots on pickup facility '%s'", tostring(facilityId)))
      return false
    end
    local preferred, fallback = {}, {}
    for _, spot in ipairs(facilitySpots) do
      local path = string.lower(tostring((spot.getPath and spot:getPath()) or spot.psPath or spot.name or ""))
      if path:find("trailer", 1, true) or path:find("loaner", 1, true) or path:find("garage_trailer", 1, true) then
        table.insert(preferred, spot)
      else
        table.insert(fallback, spot)
      end
    end
    if #preferred > 0 then
      self.validSpots = preferred
    elseif #fallback > 0 then
      self.validSpots = fallback
    else
      self.validSpots = facilitySpots
    end
    local yardName = self.employmentPickupLabel or facility.name or facility.id or "partner yard"
    self.employmentPickupLabel = yardName
    log(
      "I",
      "repo",
      string.format(
        "Employment pickup at '%s' (%s) with %d spots",
        tostring(yardName),
        tostring(facilityId),
        #self.validSpots
      )
    )
    return #self.validSpots > 0
  end

  function VehicleRepoJob:buildEmploymentVehiclePool()
    self.employmentVehicleCandidates = {}
    self.eligibleVehicles = configListGenerator.getEligibleVehicles(false, false) or {}
    local facilities = overhaul_world_facilities.getFacilities(getCurrentLevelIdentifier())
    local dealerships = facilities and facilities.dealerships or {}
    local seenKeys = {}
    for _, dealership in ipairs(dealerships) do
      local candidates = getEligibleRepoVehiclesForDealership(dealership, self.eligibleVehicles)
      for _, candidate in ipairs(candidates or {}) do
        local key = candidate.key
          or candidate.model_key
          or (candidate.model and candidate.config and (candidate.model .. "/" .. candidate.config))
        if key and not seenKeys[key] then
          seenKeys[key] = true
          table.insert(self.employmentVehicleCandidates, candidate)
        end
      end
    end
  end

  function VehicleRepoJob:determineDeliveryLocation()
    self.deliveryLocation = nil
    self:releaseDeliveryReservation()
    local dealerships = self.availableDealerships or (self.selectedDealership and { self.selectedDealership } or {})
    for _, dealership in ipairs(dealerships) do
      local facilitySpots = dealership.repoProvider and collectEmploymentDeliverySpots(dealership)
        or overhaul_world_facilities.getParkingSpotsForFacility(dealership)
        or {}
      local liveDeliverySpot =
        parkingReservation.findReservableSpot(parkingReservation.shuffleSpots(facilitySpots), self.reservationToken)
      if liveDeliverySpot then
        self.selectedDealership = dealership
        self.deliveryLocation = liveDeliverySpot
        self.reservedDeliverySpot = liveDeliverySpot
        return
      end

      -- Facility site spots can be absent from the live pool, so retain the static fallback.
      local staticDeliverySpot = pickStaticFacilitySpot(facilitySpots)
      if staticDeliverySpot then
        self.selectedDealership = dealership
        self.deliveryLocation = staticDeliverySpot
        self.reservedDeliverySpot = nil
        log(
          "W",
          "repo",
          string.format("Using unreserved static dropoff spot for dealership '%s'", tostring(dealership.name))
        )
        return
      end

      log(
        "I",
        "repo",
        string.format("Rerolling dealership '%s'; no reservable dropoff spot found", tostring(dealership.name))
      )
    end
  end

  function VehicleRepoJob:filterValidSpots()
    self.validSpots = {}
    for _, spot in pairs(self.parkingSpots.objects) do
      if spot.pos then
        local distanceFromPlayer = (spot.pos - self.playerPosition):length()
        local distanceFromDestination = (spot.pos - self.deliveryLocation.pos):length()
        if distanceFromPlayer >= 300 and distanceFromDestination >= 600 then table.insert(self.validSpots, spot) end
      end
    end
  end

  function VehicleRepoJob:selectRandomSpot()
    self.selectedSpot = nil
    self:releasePickupReservation()
    if #self.validSpots == 0 then return end
    local livePickupSpot =
      parkingReservation.findReservableSpot(parkingReservation.shuffleSpots(self.validSpots), self.reservationToken)
    if livePickupSpot then
      self.selectedSpot = livePickupSpot
      self.reservedPickupSpot = livePickupSpot
      return
    end
    if self.employmentMode and self.employmentPickupFacId then
      local staticPickupSpot = pickStaticFacilitySpot(self.validSpots)
      if staticPickupSpot then
        self.selectedSpot = staticPickupSpot
        self.reservedPickupSpot = nil
      end
    end
  end

  -- Vehicle configuration and display ---------------------------------------------------------------

  function VehicleRepoJob:generateVehicleConfig()
    local selectedVehicleInfo
    if self.employmentMode then
      selectedVehicleInfo = pickWeightedRepoVehicleInfo(self.employmentVehicleCandidates)
    else
      local dealershipId = self.selectedDealership and self.selectedDealership.id
      local dealershipCandidates = dealershipId
          and self.eligibleRepoVehiclesByDealership
          and self.eligibleRepoVehiclesByDealership[dealershipId]
        or nil
      selectedVehicleInfo = pickWeightedRepoVehicleInfo(dealershipCandidates)
      if not selectedVehicleInfo then
        log(
          "W",
          "repo",
          string.format(
            "Selected dealership '%s' had no unlocked repo candidates during vehicle generation",
            tostring(self.selectedDealership and self.selectedDealership.name)
          )
        )
        return
      end
    end
    if not selectedVehicleInfo then
      if self.employmentMode then log("W", "repo", "No unlocked repo candidates for company pickup assignment") end
      return
    end
    self.randomVehicleInfo = deepcopy(selectedVehicleInfo)
    self.vehicleConfig = self.randomVehicleInfo.key
    self.repoTag = self.randomVehicleInfo.repoTag
    self.repoTierLabel = self.randomVehicleInfo.repoTierLabel

    if
      not usedVehicleCondition.generateUsedVehicleCondition(
        { id = "private", salesChannel = "local" },
        self.randomVehicleInfo
      )
    then
      log("W", "repo", "Invalid used-car year bounds")
      self.randomVehicleInfo = nil
      self.vehicleConfig = nil
      return
    end
    if overhaul_career_career.isActive() then
      self.vehicleValue = overhaul_career_market_valueCalculator.getVehicleCatalogIntrinsicBookValue({
        catalogBaseValue = self.randomVehicleInfo.Value,
        mileageMeters = self.randomVehicleInfo.Mileage,
        age = math.max(0, (tonumber(os.date("%Y")) or 2026) - self.randomVehicleInfo.year),
        modelName = self.randomVehicleInfo.model_key,
        configKey = self.randomVehicleInfo.key,
        logContext = "repo",
        applyVehicleBuyMarket = false,
      }) or overhaul_career_market_valueCalculator.getAdjustedVehicleBaseValue(self.randomVehicleInfo.Value, {
        mileage = self.randomVehicleInfo.Mileage,
        age = math.max(0, (tonumber(os.date("%Y")) or 2026) - self.randomVehicleInfo.year),
      })
    end
    local stateData = buildRepoStateData(self)
    guihooks.trigger("updateRepoState", stateData)
  end
  local function isFactoryPaint(paint, paintName)
    if type(paintName) ~= "string" or paintName == "" or paintName == "(Custom)" then return false end
    if type(paint) ~= "table" then return false end
    return paint.class ~= "custom"
  end
  local function pickRepoSpawnPaint(modelKey, configKey)
    if not modelKey then return nil, nil end
    local modelData = core_vehicles.getModel(modelKey)
    local modelPaints = modelData and modelData.model and modelData.model.paints
    if type(modelPaints) ~= "table" then return nil, nil end
    if core_vehiclePaints and core_vehiclePaints.getRandomPaints then
      for _ = 1, 8 do
        local paintResult = core_vehiclePaints.getRandomPaints(modelKey, configKey)
        local name = paintResult and paintResult.paintName1
        local named = name and modelPaints[name]
        if isFactoryPaint(named, name) then return tostring(name), deepcopy(named) end
      end
    end
    local factoryNames = {}
    for name, paint in pairs(modelPaints) do
      if isFactoryPaint(paint, name) then factoryNames[#factoryNames + 1] = name end
    end
    if factoryNames[1] then
      local name = factoryNames[math.random(#factoryNames)]
      return tostring(name), deepcopy(modelPaints[name])
    end
    return nil, nil
  end
  local function repoVehicleName(instance)
    local vehicleInfo = instance and (instance.vehInfo or instance.randomVehicleInfo) or nil
    local vehicleName = ""
    if vehicleInfo then
      vehicleName = ((vehicleInfo.Brand or "") .. " " .. (vehicleInfo.Name or "")):gsub("^%s+", ""):gsub("%s+$", "")
      if vehicleName == "" then vehicleName = tostring(vehicleInfo.Name or vehicleInfo.model_key or "vehicle") end
    else
      vehicleName = "vehicle"
    end
    return vehicleName
  end
  local function formatRepoVehicleDisplayName(instance)
    local vehicleName = repoVehicleName(instance)
    local color = instance and instance.paintName
    if type(color) ~= "string" or color == "" or color == "(Custom)" then color = "unknown color" end
    return tostring(color) .. " " .. vehicleName
  end
  return {
    abortRepoGeneration = abortRepoGeneration,
    formatRepoVehicleDisplayName = formatRepoVehicleDisplayName,
    pickRepoSpawnPaint = pickRepoSpawnPaint,
    repoVehicleName = repoVehicleName,
  }
end
