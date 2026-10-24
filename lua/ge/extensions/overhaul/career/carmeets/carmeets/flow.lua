-- Car meet flow: meet locations and sites per level, the start of a meet, availability checks and invite generation.
-- Map: per-load state, meet startup steps, invite generation, lifecycle and returned API.

local lib = {}

function lib.create(inputs)
  local parts = inputs.parts
  -- State -----------------------------------------------------------------------------------------

  local carMeetState = inputs.carMeetState
  local callbacks = inputs.callbacks

  callbacks.getCarMeetLocations = function()
    local locations = {}

    local sitePath = gameplay_sites_sitesManager.getCurrentLevelSitesFileByName('carmeet')
    if not sitePath then
      return locations
    end

    local siteData = gameplay_sites_sitesManager.loadSites(sitePath)
    if not siteData then
      return locations
    end

    for _, zone in ipairs(siteData.zones.sorted) do
      local meetName = zone.name
      locations[meetName] = {
        zone = zone,
        parkingSpots = {},
        position = vec3(zone.top.pos),
        tags = zone.customFields.sortedTags
      }

      for _, spot in ipairs(siteData.parkingSpots.sorted) do
        for _, tag in ipairs(spot.customFields.sortedTags) do
          if tag == meetName then
            table.insert(locations[meetName].parkingSpots, spot)
          end
        end
      end
    end

    carMeetState.carmeetLocations = locations

    return locations
  end

  callbacks.ensureCarmeetSitesForCurrentLevel = function()
    local levelId = getCurrentLevelIdentifier()
    if not levelId or levelId == "" then
      carMeetState.carmeetSitesLevelId = nil
      carMeetState.carmeetSitesAvailable = false
      carMeetState.carmeetLocations = {}
      return false
    end
    if carMeetState.carmeetSitesLevelId == levelId then
      return carMeetState.carmeetSitesAvailable
    end

    carMeetState.carmeetSitesLevelId = levelId
    carMeetState.carmeetLocations = callbacks.getCarMeetLocations()
    carMeetState.carmeetSitesAvailable = next(carMeetState.carmeetLocations) ~= nil
    return carMeetState.carmeetSitesAvailable
  end

  -- Helpers ---------------------------------------------------------------------------------------
  local function clearCarmeetStateForUnavailableMap()
    if carMeetState.rsvpData then
      carMeetState.rsvpData = nil
      inputs.meetRoute.clear()
    end
    if carMeetState.meetState.active then
      parts.invites.cleanupPreviousMeet()
    end
  end

  local function onWorldReadyState(state)
    if state == 2 and carMeetState.careerActive then
      carMeetState.carmeetSitesLevelId = nil
      callbacks.ensureCarmeetSitesForCurrentLevel()
      local _, activeSavePath = overhaul_career_saveSystem.getCurrentProfile()
      if activeSavePath then
        inputs.persist.load(activeSavePath)
      end
      if carMeetState.meetState.active then
        parts.invites.cleanupPreviousMeet()
      end
      if not carMeetState.carmeetSitesAvailable then
        clearCarmeetStateForUnavailableMap()
      elseif carMeetState.rsvpData and carMeetState.rsvpData.location and not carMeetState.carmeetLocations[carMeetState.rsvpData.location] then
        clearCarmeetStateForUnavailableMap()
      elseif carMeetState.rsvpData and carMeetState.rsvpData.attended then
        -- Restarting an attended meet would award arrival rewards twice.
        carMeetState.rsvpData = nil
        inputs.meetRoute.clear()
      elseif carMeetState.rsvpData and carMeetState.rsvpData.location and not carMeetState.meetState.active then
        callbacks.startCarMeet(carMeetState.rsvpData.location, carMeetState.rsvpData.type, carMeetState.rsvpData.attendance, carMeetState.rsvpData.clubId)
      end
    end
  end

  -- Meet startup ----------------------------------------------------------------------------------

  local function initializeMeetState(meet, meetTypeKey)
    carMeetState.meetState.active = true
    carMeetState.meetState.type = meetTypeKey
    carMeetState.meetState.location = meet
    carMeetState.meetState.startTime = os.time()
    carMeetState.meetState.arrivalTime = 0
    carMeetState.meetState.phase = "waiting"
    carMeetState.meetState.flags = {}
  end

  local function chooseMeetClub(meetType, meetTypeKey, clubId)
    local selectedClub = nil
    if meetType.requiresActiveClub then
      local requiredClubId = meetType.requiredClubId or clubId
      selectedClub = requiredClubId and parts.clubs.selectActiveClub(requiredClubId, false) or parts.clubs.selectActiveClub()
    end
    if meetType.requiresActiveClub and not selectedClub then
      log("D", "carmeets", "Car meet type requires an active club, but none was found: " .. tostring(meetTypeKey))
      ui_message("This invite requires an active car club.", 6, "warning", "warning")
      carMeetState.meetState.active = false
      carMeetState.meetState.type = nil
      carMeetState.meetState.location = nil
      carMeetState.meetState.flags = {}
      return nil, false
    end
    if selectedClub then
      carMeetState.meetState.flags.clubId = selectedClub.id
      carMeetState.meetState.flags.clubName = selectedClub.name
    end
    return selectedClub, true
  end

  local function prepareMeetSale(meetTypeKey)
    local saleInventoryId = parts.sales.resolveMeetSaleInventoryId()
    if saleInventoryId then
      carMeetState.meetState.flags.saleInventoryId = saleInventoryId
      carMeetState.meetState.flags.playerSoldSaleVehicle = false
      carMeetState.meetState.flags.saleInitialized = false
    end
    if meetTypeKey == "BAZAAR" then
      carMeetState.meetState.flags.bazaarInventoryId = saleInventoryId
      carMeetState.meetState.flags.bazaarGuaranteedOffersTarget = math.random(1, 2)
      carMeetState.meetState.flags.bazaarGuaranteedOffersGenerated = 0
      carMeetState.meetState.flags.bazaarOfferSchedule = {}
    end
  end

  local function meetSpotCount(attendanceLevel, maxSpots)
    local spotCount
    if attendanceLevel == 1 then spotCount = 2
    elseif attendanceLevel == 2 then spotCount = math.ceil(maxSpots / 2)
    elseif attendanceLevel == 3 then spotCount = maxSpots end
    return math.min(spotCount, maxSpots)
  end

  local function selectPlayerSpot(meet)
    -- Only the list changes; each spot must keep its reference to the full sites graph.
    local availableSpots = {}
    for i, spot in ipairs(meet.parkingSpots) do availableSpots[i] = spot end
    local playerVehicleId = be:getPlayerVehicleID(0)
    carMeetState.meetState.playerSpot = playerVehicleId and playerVehicleId >= 0
      and gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(playerVehicleId, availableSpots) or availableSpots[1]
    for i, spot in ipairs(availableSpots) do
      if spot == carMeetState.meetState.playerSpot then table.remove(availableSpots, i); break end
    end
    return availableSpots
  end

  local function scheduleMeetVehicles(meet, meetType, selectedClub, spotCount, spawnedVehicles, availableSpots)
    local options = {color = {1, 0.4, 0}, step = 4, renderDecals = true}
    inputs.meetRoute.set(carMeetState.meetState.playerSpot.pos, options)
    local playerVeh = be:getPlayerVehicle(0)
    local playerPos = playerVeh and playerVeh:getPosition() or vec3(meet.position)
    local spawnGeneration = carMeetState.meetGeneration
    core_jobsystem.create(function(job)
      local deferPoiRefresh = inputs.PRESPAWN_MEET_VEHICLES_ON_ACCEPT
      for i = 1, spotCount do
        if spawnGeneration ~= carMeetState.meetGeneration or not carMeetState.meetState.active then return end
        local randomIndex = math.random(#availableSpots)
        local spot = availableSpots[randomIndex]
        table.remove(availableSpots, randomIndex)
        if inputs.PRESPAWN_MEET_VEHICLES_ON_ACCEPT then
          local vehicleData = parts.invites.spawnVehicleOptimized(spot, meetType, false, selectedClub, true)
          if vehicleData then table.insert(spawnedVehicles, vehicleData) end
        else
          local distance = (vec3(spot.pos) - playerPos):length()
          if distance <= inputs.VEHICLE_SPAWN_DISTANCE then
            local forceVisible = parts.invites.checkVehicleVisible(playerPos, vec3(spot.pos))
            local vehicleData = parts.invites.spawnVehicleOptimized(spot, meetType, forceVisible, selectedClub)
            if vehicleData then table.insert(spawnedVehicles, vehicleData) end
          else
            local spotData = {pos = vec3(spot.pos), rot = quat(spot.rot), meetType = meetType, club = selectedClub}
            carMeetState.pendingVehicles[spotData] = true
          end
        end
        job.sleep(inputs.PRESPAWN_MEET_VEHICLES_ON_ACCEPT and inputs.PRESPAWN_SPAWN_STAGGER or 0.1)
      end
      if spawnGeneration ~= carMeetState.meetGeneration then return end
      if deferPoiRefresh then parts.invites.flushMeetSpawnPoisRefresh() end
    end)
  end

  callbacks.startCarMeet = function(meetName, meetTypeKey, attendanceLevel, clubId)
    carMeetState.usedConfigs = {}
    parts.invites.cleanupPreviousMeet()
    if not callbacks.ensureCarmeetSitesForCurrentLevel() then return false end
    local meet = carMeetState.carmeetLocations[meetName]
    if not meet then log("D", "carmeets", "Car meet location not found: " .. tostring(meetName)); return false end
    local meetType = parts.meetTypesPart.getMeetType(meetTypeKey)
    if not meetType then log("D", "carmeets", "Meet type not found: " .. tostring(meetTypeKey)); return false end
    initializeMeetState(meet, meetTypeKey)
    local selectedClub, clubReady = chooseMeetClub(meetType, meetTypeKey, clubId)
    if not clubReady then return false end
    prepareMeetSale(meetTypeKey)
    local spotCount = meetSpotCount(attendanceLevel, #meet.parkingSpots - 1)
    carMeetState.carMeetVehicles = parts.invites.getCarMeetVehicles(meetType, selectedClub)
    local spawnedVehicles = {}
    local availableSpots = selectPlayerSpot(meet)
    scheduleMeetVehicles(meet, meetType, selectedClub, spotCount, spawnedVehicles, availableSpots)
    return true
  end

  local function shouldGenerateNewMeet()
    if carMeetState.meetState.active then return false end
    local currentTime = os.time()
    return (currentTime - carMeetState.lastGenerationTime) >= carMeetState.generationInterval and #carMeetState.pendingInvites < parts.sales.getPendingInviteCap()
  end

  local function refreshMeetState()
    parts.invites.reconcileActiveMeetInvite()
    for _, club in ipairs(parts.clubs.loadClubDefinitions()) do
      if parts.clubs.isClubJoined(club.id) then
        parts.clubs.ensureClubMembership(club.id)
      end
    end
  end

  local function checkAvailableMeets(skipOverview)
    local expiredAny = parts.invites.expirePendingInvites()

    if shouldGenerateNewMeet() then
      local meetArray = parts.invites.getMeetArray()
      if #meetArray > 0 then
        local selectedMeet = meetArray[math.random(#meetArray)]
        local typeKeys = parts.invites.getEligibleMeetTypeKeys()
        local selectedTypeKey = typeKeys[math.random(#typeKeys)]

        local newInvite = parts.invites.buildInvite(selectedMeet, selectedTypeKey)
        table.insert(carMeetState.pendingInvites, newInvite)
        parts.meetTypesPart.firePhoneLockNotification(newInvite)
        carMeetState.lastGenerationTime = os.time()
        carMeetState.generationInterval = inputs.DEFAULT_INVITE_GENERATION_INTERVAL
        require("overhaul/lib/save/store").request("carmeets:checkAvailableMeets")
        expiredAny = false
      end
    end

    if expiredAny then
      require("overhaul/lib/save/store").request("carmeets:checkAvailableMeets")
    end

    if skipOverview then
      refreshMeetState()
      return
    end
    return callbacks.getCarMeetOverview()
  end

  local function generateInviteNow()
    parts.invites.expirePendingInvites()

    if #carMeetState.pendingInvites >= parts.sales.getPendingInviteCap() then
      ui_message("Car meet invite list is full.", 5, "info", "info")
      guihooks.trigger('onCarMeetOverview', callbacks.getCarMeetOverview())
      return callbacks.getCarMeetOverview()
    end

    local meetArray = parts.invites.getMeetArray()
    if #meetArray == 0 then
      ui_message("No car meet locations available on this map.", 5, "warning", "warning")
      guihooks.trigger('onCarMeetOverview', callbacks.getCarMeetOverview())
      return callbacks.getCarMeetOverview()
    end

    local selectedMeet = meetArray[math.random(#meetArray)]
    local typeKeys = parts.invites.getEligibleMeetTypeKeys()
    local selectedTypeKey = typeKeys[math.random(#typeKeys)]
    local invite = parts.invites.buildInvite(selectedMeet, selectedTypeKey)

    table.insert(carMeetState.pendingInvites, invite)
    parts.meetTypesPart.firePhoneLockNotification(invite)
    carMeetState.lastGenerationTime = os.time()
    require("overhaul/lib/save/store").request("carmeets:generateInviteNow")
    guihooks.trigger('onCarMeetOverview', callbacks.getCarMeetOverview())
    ui_message("Generated car meet invite: " .. (invite.typeName or invite.type), 5, "info", "info")

    return callbacks.getCarMeetOverview()
  end

  -- Public API ------------------------------------------------------------------------------------
  return {
    onWorldReadyState = onWorldReadyState,
    checkAvailableMeets = checkAvailableMeets,
    generateInviteNow = generateInviteNow,
  }
end

return lib
