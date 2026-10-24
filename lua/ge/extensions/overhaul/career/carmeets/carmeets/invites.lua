-- Car meet invites and meet vehicles: arrival checks, eligible meet types, invites and penalties, sale payloads
-- Map: per-load state, arrival checks, club cards, invite handling, vehicle spawning and returned API.

local lib = {}
local capabilities = require("overhaul/lib/platform/capabilities")

function lib.create(inputs)
  local parts = inputs.parts
  -- State -----------------------------------------------------------------------------------------

  local carMeetState = inputs.carMeetState
  local callbacks = inputs.callbacks

  -- Helpers ---------------------------------------------------------------------------------------
  local function isPlayerWalkingMode()
    -- Walking can be absent while the level is being unloaded.
    return gameplay_walk and gameplay_walk.isWalking() == true
  end

  local function isInventoryVehicleNearMeet(inventoryId, playerPos)
    if not inventoryId then
      return false
    end
    local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
    if not vehId then return false end
    local veh = getObjectByID(vehId)
    if not veh then return false end
    local vehPos = veh:getPosition()
    if carMeetState.meetState.playerSpot and carMeetState.meetState.playerSpot.pos then
      if (vehPos - vec3(carMeetState.meetState.playerSpot.pos)):length() <= inputs.PLAYER_VEHICLE_AT_MEET_DISTANCE then
        return true
      end
    end
    if playerPos and (vehPos - playerPos):length() <= inputs.PLAYER_VEHICLE_AT_MEET_DISTANCE then
      return true
    end
    return false
  end

  local function didPlayerBringVehicleToMeet()
    local playerPos = parts.sales.getPlayerReferencePosition()
    if not playerPos then return false end

    local playerVehId = be:getPlayerVehicleID(0)
    if playerVehId and playerVehId >= 0 and not isPlayerWalkingMode() then
      if carMeetState.meetState.flags then
        local inventoryId = parts.sales.resolveMeetSaleInventoryId()
        if inventoryId then
          carMeetState.meetState.flags.saleInventoryId = inventoryId
        end
      end
      return true
    end

    local saleInventoryId = carMeetState.meetState.flags and carMeetState.meetState.flags.saleInventoryId
    if saleInventoryId and isInventoryVehicleNearMeet(saleInventoryId, playerPos) then
      return true
    end

    local lastId = overhaul_career_garage_inventory.getLastVehicle()
    if lastId and isInventoryVehicleNearMeet(lastId, playerPos) then
      if carMeetState.meetState.flags then
        carMeetState.meetState.flags.saleInventoryId = lastId
      end
      return true
    end

    return false
  end

  local function isPlayerAtMeetArrivalPoint()
    if not carMeetState.meetState.playerSpot then return false end
    local playerPos = parts.sales.getPlayerReferencePosition()
    if not playerPos then return false end

    if (playerPos - vec3(carMeetState.meetState.playerSpot.pos)):length() < 10 then
      return true
    end

    if isPlayerWalkingMode() then
      for _, entry in ipairs(carMeetState.carMeetPurchaseVehicles or {}) do
        local veh = entry and entry.vehicleId and getObjectByID(entry.vehicleId)
        local pos = veh and veh:getPosition() or entry.pos
        if pos and (playerPos - vec3(pos)):length() <= inputs.WALKING_MEET_ARRIVAL_DISTANCE then
          return true
        end
      end
    end

    return false
  end

  local function hasActiveClubForMeetType(meetType)
    if not meetType or not meetType.requiresActiveClub then return true end
    if meetType.requiredClubId then
      return parts.clubs.getActiveClubById(meetType.requiredClubId) ~= nil
    end
    return #parts.clubs.getActiveClubs() > 0
  end

  local function getEligibleMeetTypeKeys()
    local keys = {}
    for key, meetType in pairs(parts.meetTypesPart.meetTypes) do
      local unlockRep = meetType.unlockReputation or 0
      if overhaul_career_carmeets_reputation.getReputation() >= unlockRep and hasActiveClubForMeetType(meetType) then
        table.insert(keys, key)
      end
    end
    if #keys == 0 then
      table.insert(keys, "SHOWCASE")
    end
    return keys
  end

  local function getMeetArray()
    if not callbacks.ensureCarmeetSitesForCurrentLevel() then
      return {}
    end
    local meetArray = {}
    for name, data in pairs(carMeetState.carmeetLocations) do
      if data.parkingSpots and #data.parkingSpots > 1 then
        table.insert(meetArray, {name = name, data = data})
      end
    end
    return meetArray
  end

  local function buildInvite(selectedMeet, meetTypeKey)
    local meetType = parts.meetTypesPart.meetTypes[meetTypeKey] or parts.meetTypesPart.meetTypes.SHOWCASE
    local selectedClub = nil
    if meetType.requiresActiveClub then
      selectedClub = meetType.requiredClubId and parts.clubs.selectActiveClub(meetType.requiredClubId, false) or parts.clubs.selectActiveClub()
    end
    local levelIdentifier = getCurrentLevelIdentifier()
    local preview = "/levels/" .. levelIdentifier .. "/facilities/carmeets/" .. selectedMeet.name .. ".jpg"
    local now = os.time()
    local invite = {
      id = "carMeetInvite_" .. tostring(carMeetState.nextInviteId),
      generatedAt = now,
      expiresAt = now + (meetType.expirationSeconds or inputs.DEFAULT_INVITE_EXPIRATION),
      location = selectedMeet.name,
      type = meetTypeKey,
      typeName = meetType.name,
      description = meetType.description,
      preview = preview,
      missPenalty = meetType.missPenalty or 0,
      requiresVehicle = meetType.requiresVehicle == true,
      minVehicleValue = meetType.minVehicleValue,
      attendance = inputs.attendanceLevels.MEDIUM
    }
    if selectedClub then
      invite.clubId = selectedClub.id
      invite.clubName = selectedClub.name
    end
    carMeetState.nextInviteId = carMeetState.nextInviteId + 1
    return invite
  end

  local function removePendingInvite(inviteId)
    if not inviteId then return nil end
    for i, invite in ipairs(carMeetState.pendingInvites) do
      if invite.id == inviteId then
        return table.remove(carMeetState.pendingInvites, i)
      end
    end
    return nil
  end

  local function applyInvitePenalty(invite, reason, opts)
    opts = opts or {}
    if invite and invite.clubId then
      parts.clubs.recordClubMeetResult(invite.clubId, false, reason or "missed club invite")
    end
    -- Scene reputation only drops when missing an accepted Car Bazaar RSVP.
    if not opts.sceneRep then return end
    if not invite or invite.type ~= "BAZAAR" then return end
    local penalty = tonumber(invite.missPenalty)
    if not penalty or penalty == 0 then
      local meetType = parts.meetTypesPart.meetTypes.BAZAAR
      penalty = meetType and tonumber(meetType.missPenalty) or 0
    end
    if penalty == 0 then return end
    overhaul_career_carmeets_reputation.addReputation(penalty, reason or "missed bazaar invite")
    ui_message("Car meet reputation changed by " .. tostring(penalty) .. ".", 8, "warning", "warning")
  end

  local function expirePendingInvites()
    local now = os.time()
    local expiredAny = false
    for i = #carMeetState.pendingInvites, 1, -1 do
      local invite = carMeetState.pendingInvites[i]
      if invite.expiresAt and now >= invite.expiresAt then
        table.remove(carMeetState.pendingInvites, i)
        applyInvitePenalty(invite, "expired invite")
        expiredAny = true
      end
    end
    return expiredAny
  end

  -- Sale display ------------------------------------------------------------------------------------

  local function buildMeetSaleListingPayload(listing)
    if not listing then return nil end
    local niceName = listing.niceName
    if niceName ~= nil then
      local translated = core_locales.translateWithOrWithoutContext(niceName)
      if type(translated) == "string" and translated ~= "" then
        niceName = translated
      end
    end
    return {
      id = listing.id,
      niceName = niceName,
      value = listing.value,
      marketValue = listing.marketValue,
      minAskingPrice = math.floor(math.max(50, (tonumber(listing.marketValue) or 0) * 0.5)),
      maxAskingPrice = math.floor(math.max(50, (tonumber(listing.marketValue) or 0) * 2.0)),
      thumbnail = listing.thumbnail
    }
  end

  local function buildMeetSaleOverviewPayload(includeEnded)
    if not carMeetState.meetState.active or not carMeetState.meetState.flags or not carMeetState.meetState.flags.saleInventoryId then
      return nil
    end
    if carMeetState.meetState.flags.playerSoldSaleVehicle == true then
      return nil
    end
    -- once the showcase is over the offers only stay visible (as expired) for a screen that is already open
    if carMeetState.meetState.phase ~= "showcase" and not (includeEnded and carMeetState.meetState.flags.saleOffersExpired) then
      return nil
    end

    local listing
    if carMeetState.meetState.flags.playerBroughtVehicle or carMeetState.meetState.flags.saleInitialized then
      listing = carMeetState.meetState.flags.saleListing or parts.sales.ensureMeetSaleState(carMeetState.meetState)
    else
      local inventoryId = carMeetState.meetState.flags.saleInventoryId
      local vehicle = parts.sales.getInventoryVehicle(inventoryId) or {}
      local marketValue = parts.sales.getInventoryVehicleValue(inventoryId)
      listing = {
        id = inventoryId,
        inventoryId = inventoryId,
        niceName = parts.sales.getInventoryVehicleDisplayName(vehicle, "Your vehicle"),
        value = marketValue,
        marketValue = marketValue,
        thumbnail = overhaul_career_garage_inventory.getVehicleThumbnail(inventoryId) or nil
      }
    end
    if not listing then return nil end

    return {
      type = carMeetState.meetState.type,
      inventoryId = carMeetState.meetState.flags.saleInventoryId,
      sold = false,
      guaranteed = carMeetState.meetState.type == "BAZAAR",
      guaranteedTarget = carMeetState.meetState.flags.bazaarGuaranteedOffersTarget or 0,
      guaranteedGenerated = carMeetState.meetState.flags.bazaarGuaranteedOffersGenerated or 0,
      offers = carMeetState.meetState.flags.saleOffers or {},
      canReceiveOffers = callbacks.canPlayerSellAtMeet(carMeetState.meetState),
      needsVehicleAtMeet = carMeetState.meetState.flags.playerBroughtVehicle ~= true,
      listing = buildMeetSaleListingPayload(listing)
    }
  end

  -- Offers made at a meet only last as long as the meet: when the showcase ends every live offer expires (expiredViewCounter = 0, as marketplace offers do) and an open offers screen is told straight away.
  local function expireMeetSaleOffers(state)
    if not state or not state.flags or state.flags.saleOffersExpired then return end
    state.flags.saleOffersExpired = true
    local expiredAny = false
    for _, offer in ipairs(state.flags.saleOffers or {}) do
      if offer.expiredViewCounter == nil then
        offer.expiredViewCounter = 0
        offer.negotiationPossible = false
        expiredAny = true
      end
    end
    if expiredAny then
      guihooks.trigger('onCarMeetSaleOfferData', buildMeetSaleOverviewPayload(true))
    end
  end

  local function reconcileActiveMeetInvite()
    if carMeetState.rsvpData or not carMeetState.meetState.active then return end
    local locationName = carMeetState.meetState.location and carMeetState.meetState.location.zone and carMeetState.meetState.location.zone.name
    for i, invite in ipairs(carMeetState.pendingInvites) do
      if invite.location == locationName and invite.type == carMeetState.meetState.type then
        carMeetState.rsvpData = table.remove(carMeetState.pendingInvites, i)
        break
      end
    end
  end

  callbacks.getCarMeetOverview = function()
    reconcileActiveMeetInvite()
    local showActiveMeet = carMeetState.meetState.active
    local salePayload = showActiveMeet and buildMeetSaleOverviewPayload() or nil
    return {
      reputation = math.floor(overhaul_career_carmeets_reputation.getReputation() + 0.5),
      maxReputation = overhaul_career_carmeets_reputation.getMaxReputation(),
      pendingInviteCap = parts.sales.getPendingInviteCap(),
      invites = carMeetState.pendingInvites,
      activeInvite = showActiveMeet and carMeetState.rsvpData or nil,
      currentMeet = showActiveMeet and {
        type = carMeetState.meetState.type,
        phase = carMeetState.meetState.phase,
        location = carMeetState.rsvpData and carMeetState.rsvpData.location or (carMeetState.meetState.location and carMeetState.meetState.location.zone and carMeetState.meetState.location.zone.name),
        typeName = carMeetState.rsvpData and carMeetState.rsvpData.typeName or (parts.meetTypesPart.meetTypes[carMeetState.meetState.type] and parts.meetTypesPart.meetTypes[carMeetState.meetState.type].name),
        clubId = carMeetState.meetState.flags and carMeetState.meetState.flags.clubId,
        clubName = carMeetState.meetState.flags and carMeetState.meetState.flags.clubName,
        startTime = carMeetState.meetState.startTime,
        arrivalTime = carMeetState.meetState.arrivalTime,
        duration = parts.meetTypesPart.meetTypes[carMeetState.meetState.type] and parts.meetTypesPart.meetTypes[carMeetState.meetState.type].showcaseDuration or 600,
        arrived = carMeetState.meetState.phase ~= "waiting"
      } or nil,
      meetPurchaseVehicles = carMeetState.carMeetPurchaseVehicles,
      sale = salePayload and carMeetState.meetState.type ~= "BAZAAR" and salePayload or nil,
      bazaar = salePayload and carMeetState.meetState.type == "BAZAAR" and salePayload or nil,
      clubs = callbacks.getClubUiData()
    }
  end

  -- Club membership ---------------------------------------------------------------------------------

  local function clubDisableReason(club, joined, active, hasVehicle, requiredRep, joinFee, money)
    local disableReason = nil
    if joined then
      disableReason = active and "Joined" or "Inactive: missing qualifying vehicle"
    elseif overhaul_career_carmeets_reputation.getReputation() < requiredRep then
      disableReason = "Requires " .. tostring(requiredRep) .. " rep"
    elseif not hasVehicle then
      disableReason = club.joinRequiresInstalledModel and "Requires installed vehicle mod" or "Requires qualifying vehicle"
    elseif money < joinFee then
      disableReason = "Requires $" .. tostring(joinFee)
    end

    return disableReason
  end

  local function buildClubUiEntry(club, money)
    local joined = parts.clubs.isClubJoined(club.id)
    local membership = joined and parts.clubs.ensureClubMembership(club.id) or nil
    local active = parts.clubs.isClubActive(club)
    local hasVehicle = parts.clubs.playerOwnsClubVehicle(club)
    local requiredRep = tonumber(club.requiredRep) or 0
    local joinFee = tonumber(club.joinFee) or 0
    local obligationEvents = membership and tonumber(membership.obligationEvents) or 0
    local obligationAttended = membership and tonumber(membership.obligationAttended) or 0
    local obligationWindowSize = membership and tonumber(membership.obligationWindowSize) or inputs.CLUB_OBLIGATION_WINDOW_SIZE
    local requiredAttendance = membership and tonumber(membership.requiredAttendance) or inputs.CLUB_OBLIGATION_REQUIRED_ATTENDANCE
    local canJoin = not joined and overhaul_career_carmeets_reputation.getReputation() >= requiredRep and hasVehicle and money >= joinFee
    local disableReason = clubDisableReason(club, joined, active, hasVehicle, requiredRep, joinFee, money)

    local entry = {
      id = club.id,
      name = club.name,
      type = club.type,
      requiredRep = requiredRep,
      joinFee = joinFee,
      joined = joined,
      active = active,
      hasVehicle = hasVehicle,
      canJoin = canJoin,
      disableReason = disableReason,
      requirementsText = club.joinRequiresInstalledModel
      and "Installed model: " .. tostring(club.requirements.displayName or club.joinRequiresInstalledModel)
      or parts.clubs.clubRequirementText(club.requirements),
      standing = membership and math.floor((tonumber(membership.standing) or inputs.CLUB_STANDING_MAX) + 0.5) or nil,
      paidJoinFee = membership and tonumber(membership.paidJoinFee) or nil,
      obligationEvents = obligationEvents,
      obligationAttended = obligationAttended,
      obligationWindowSize = obligationWindowSize,
      requiredAttendance = requiredAttendance,
      obligationText = tostring(obligationAttended) .. "/" .. tostring(requiredAttendance) .. " attended in current " .. tostring(obligationWindowSize) .. "-event window"
    }

    return entry, joined, hasVehicle
  end

  callbacks.getClubUiData = function()
    local money = parts.clubs.getPlayerMoney()
    local availableClubs = {}
    local joinedClubList = {}

    for _, club in ipairs(parts.clubs.loadClubDefinitions()) do
      local entry, joined, hasVehicle = buildClubUiEntry(club, money)

      if joined then
        table.insert(joinedClubList, entry)
      elseif hasVehicle or club.type == "special" then
        table.insert(availableClubs, entry)
      end
    end

    return {
      reputation = math.floor(overhaul_career_carmeets_reputation.getReputation() + 0.5),
      money = money,
      availableClubs = availableClubs,
      joinedClubs = joinedClubList
    }
  end

  local function joinClub(clubId)
    clubId = tostring(clubId or "")
    for _, club in ipairs(parts.clubs.loadClubDefinitions()) do
      if club.id == clubId then
        if parts.clubs.isClubJoined(clubId) then
          return callbacks.getClubUiData()
        end
        local requiredRep = tonumber(club.requiredRep) or 0
        local joinFee = tonumber(club.joinFee) or 0
        if overhaul_career_carmeets_reputation.getReputation() < requiredRep then
          ui_message("You need more car meet rep to join this club.", 5, "warning", "warning")
          return callbacks.getClubUiData()
        end
        if not parts.clubs.playerOwnsClubVehicle(club) then
          ui_message(club.joinRequiresInstalledModel and "You need this vehicle mod installed to join this club."
            or "You need a qualifying vehicle to join this club.", 5, "warning", "warning")
          return callbacks.getClubUiData()
        end
        if parts.clubs.getPlayerMoney() < joinFee then
          ui_message("You cannot afford this club's joining fee.", 5, "warning", "warning")
          return callbacks.getClubUiData()
        end
        if joinFee > 0 then
          overhaul_career_economy_playerAttributes.addAttributes({money = -joinFee}, require("overhaul/lib/finance/metadata").tag({tags = {"carMeet", "clubJoin"}, label = "Joined car club: " .. (club.name or clubId)}, "service", {vehicleRelated = false}))
        end
        carMeetState.joinedClubs[clubId] = {
          joinedAt = os.time(),
          paidJoinFee = joinFee,
          standing = inputs.CLUB_STANDING_MAX,
          obligationEvents = 0,
          obligationAttended = 0,
          obligationWindowSize = inputs.CLUB_OBLIGATION_WINDOW_SIZE,
          requiredAttendance = inputs.CLUB_OBLIGATION_REQUIRED_ATTENDANCE
        }
        inputs.persist.markDirty()
        ui_message("Joined " .. (club.name or "car club") .. ".", 5, "info", "info")
        require("overhaul/lib/save/store").request("carmeets:joinClub")
        guihooks.trigger('onCarMeetOverview', callbacks.getCarMeetOverview())
        return callbacks.getClubUiData()
      end
    end
    ui_message("Club not found.", 5, "warning", "warning")
    return callbacks.getClubUiData()
  end

  local function leaveClub(clubId)
    clubId = tostring(clubId or "")
    if carMeetState.joinedClubs[clubId] then
      local clubName = "car club"
      for _, club in ipairs(parts.clubs.loadClubDefinitions()) do
        if tostring(club.id) == clubId then
          clubName = club.name or clubName
          break
        end
      end
      carMeetState.joinedClubs[clubId] = nil
      inputs.persist.markDirty()
      ui_message("Left " .. clubName .. ".", 5, "info", "info")
      require("overhaul/lib/save/store").request("carmeets:leaveClub")
      guihooks.trigger('onCarMeetOverview', callbacks.getCarMeetOverview())
      return callbacks.getClubUiData()
    end
    ui_message("You are not in that car club.", 5, "warning", "warning")
    return callbacks.getClubUiData()
  end

  -- Meet vehicles -----------------------------------------------------------------------------------

  local function cleanupPreviousMeet()
    carMeetState.meetGeneration = carMeetState.meetGeneration + 1
    for _, vehId in ipairs(carMeetState.spawnedMeetVehicles) do
      gameplay_traffic.removeTraffic(vehId)
      local veh = getObjectByID(vehId)
      if veh then
        veh:delete()
      end
    end
    carMeetState.spawnedMeetVehicles = {}
    -- Cleanup may outlive inventory, so resolve the same shopping contract without that extension.
    local shop = capabilities.get("vehicleShoppingService")
    local shoppingService = shop and shop.getVehicleShoppingService()
    if shoppingService and shoppingService.removeListings then
      shoppingService.removeListings()
    end
    carMeetState.carMeetPurchaseVehicles = {}
    carMeetState.pendingVehicles = {}
    inputs.meetRoute.clear()
    if gameplay_rawPois and gameplay_rawPois.clear then
      gameplay_rawPois.clear()
    end

    parts.clubs.restoreTrafficAmount()

    carMeetState.meetState.active = false
    carMeetState.meetState.type = nil
    carMeetState.meetState.location = nil
    carMeetState.meetState.playerSpot = nil
    carMeetState.meetState.startTime = 0
    carMeetState.meetState.arrivalTime = 0
    carMeetState.meetState.flags = {}
    carMeetState.meetState.phase = "waiting"
  end

  local function filterMeetPool(vehiclesForInfos, poolRuleTiers, meetType)
  if poolRuleTiers then
    local matchedInfos = {}
    local matchedRules = nil
    for _, rules in ipairs(poolRuleTiers) do
      matchedInfos = parts.clubs.filterVehicleInfosForPoolRules(vehiclesForInfos, rules)
      if #matchedInfos > 0 then
        matchedRules = rules
        break
      end
    end
    if #matchedInfos > 0 then
      vehiclesForInfos = matchedInfos
      log("D", "carmeets", "Applied car meet vehicle pool rules for " .. tostring(meetType and meetType.name or "meet")
        .. ": " .. tostring(#vehiclesForInfos) .. " eligible vehicles"
        .. " (populationMax=" .. tostring(matchedRules and matchedRules.populationMax or "any")
        .. ", valueMin=" .. tostring(matchedRules and matchedRules.valueMin or "any") .. ")")
    else
      log("D", "carmeets", "No vehicles matched car meet pool rules for " .. tostring(meetType and meetType.name or "meet") .. ". Falling back to identity-filtered pool.")
    end
  end

    return vehiclesForInfos
  end

  local function getCarMeetVehicles(meetType, club)
    local vehicles = {}
    local eligibleVehicles = inputs.stockOverrides.getEligibleVehicles(false, false)

    local filters = meetType and meetType.vehicleFilters or parts.meetTypesPart.meetTypes.SHOWCASE.vehicleFilters
    local poolRuleTiers = parts.clubs.getMeetVehiclePoolRules(meetType)
    local vehiclesForInfos = eligibleVehicles

    if club then
      vehiclesForInfos = {}
      for _, vehicleInfo in ipairs(eligibleVehicles or {}) do
        if parts.clubs.vehicleInfoMatchesClub(vehicleInfo, club) then
          table.insert(vehiclesForInfos, vehicleInfo)
        end
      end
      if #vehiclesForInfos == 0 then
        log("D", "carmeets", "No eligible car meet vehicles found for club " .. tostring(club.name or club.id) .. ".")
        return vehicles
      end
      log("D", "carmeets", "Eligible car meet vehicles for " .. tostring(club.name or club.id) .. ": " .. tostring(#vehiclesForInfos))
    end

    vehiclesForInfos = filterMeetPool(vehiclesForInfos, poolRuleTiers, meetType)

    local vehicleInfos = util_configListGenerator.getRandomVehicleInfos(
      {filter = filters},
      (club or poolRuleTiers) and 800 or 100,
      vehiclesForInfos,
      "Population"
    )

    local filteredInfos = vehicleInfos
    if club then
      filteredInfos = {}
      for _, vehicleInfo in ipairs(vehicleInfos) do
        if parts.clubs.vehicleInfoMatchesClub(vehicleInfo, club) then
          table.insert(filteredInfos, vehicleInfo)
        end
      end
      if #filteredInfos == 0 then
        log("D", "carmeets", "No sampled car meet vehicles matched club " .. tostring(club.name or club.id) .. " after meet filters.")
        return vehicles
      else
        log("D", "carmeets", "Filtered car meet vehicles for " .. tostring(club.name or club.id) .. ": " .. tostring(#filteredInfos) .. " of " .. tostring(#vehicleInfos))
      end
    end

    for _, vehicleInfo in ipairs(filteredInfos) do
      local pcPath = '/vehicles/' .. vehicleInfo.model_key .. '/configurations/' .. vehicleInfo.key .. '.pc'
      table.insert(vehicles, {
        model = vehicleInfo.model_key,
        config = pcPath,
        info = vehicleInfo
      })
    end

    return vehicles
  end

  local function getRandomVehicle(meetType, club)
    if #carMeetState.carMeetVehicles == 0 then
      carMeetState.carMeetVehicles = getCarMeetVehicles(meetType, club)
      if #carMeetState.carMeetVehicles == 0 then
        log("D", "carmeets", "No carmeet vehicles found for type: " .. (meetType and meetType.name or "unknown"))
        return nil
      end
    end

    local availableVehicles = {}
    for _, vehicle in ipairs(carMeetState.carMeetVehicles) do
      if not carMeetState.usedConfigs[vehicle.config] then
        table.insert(availableVehicles, vehicle)
      end
    end

    if #availableVehicles == 0 then
      log("D", "carmeets", "No unused vehicle configs available, allowing repeats for this meet")
      carMeetState.usedConfigs = {}
      carMeetState.carMeetVehicles = getCarMeetVehicles(meetType, club)
      for _, vehicle in ipairs(carMeetState.carMeetVehicles) do
        table.insert(availableVehicles, vehicle)
      end
      if #availableVehicles == 0 then
        return nil
      end
    end

    local vehicle = availableVehicles[math.random(#availableVehicles)]
    carMeetState.usedConfigs[vehicle.config] = true

    log("D", "carmeets", "Selected vehicle: " .. vehicle.model .. " with config: " .. vehicle.config)
    return vehicle
  end

  local function flushMeetSpawnPoisRefresh()
    if gameplay_rawPois and gameplay_rawPois.clear then
      gameplay_rawPois.clear()
    end
    guihooks.trigger('onCarMeetOverview', callbacks.getCarMeetOverview())
  end

  local function registerMeetPurchaseVehicle(vehicleSelection, spot, options, vehId, deferPoiRefresh)
    local shopInfo = parts.sales.buildCarMeetVehicleShopInfo(vehicleSelection, spot, carMeetState.meetState.type)
    if type(options.carMeetRandomPaintNames) == "table" then
      shopInfo.paintNames = deepcopy(options.carMeetRandomPaintNames)
    end
    local shopId = overhaul_career_garage_inventory.getVehicleShoppingService().registerListing(shopInfo)
    if shopId then
      table.insert(carMeetState.carMeetPurchaseVehicles, {
        shopId = shopId,
        vehicleId = vehId,
        modelKey = vehicleSelection.model,
        paintNames = shopInfo.paintNames,
        name = shopInfo.niceName,
        sellerName = shopInfo.sellerName,
        meetType = carMeetState.meetState.type,
        pos = vec3(spot.pos),
        markerRadius = spot.scl and spot.scl:length() / 2 + 2 or 5
      })
      if not deferPoiRefresh then
        flushMeetSpawnPoisRefresh()
      end
    end

  end

  local function spawnVehicleOptimized(spot, meetType, forceVisible, club, deferPoiRefresh)
    local vehicleSelection = getRandomVehicle(meetType, club)
    if not vehicleSelection then return nil end

    local options = {
      config = vehicleSelection.config,
      autoEnterVehicle = false,
      autoFlip = true,
      pos = vec3(spot.pos),
      rot = quat(spot.rot)
    }

    pcall(function()
      parts.sales.applyRandomPaintToSpawnOptions(options, vehicleSelection.model, vehicleSelection.config)
    end)

    local vehicle = core_vehicles.spawnNewVehicle(vehicleSelection.model, options)

    if vehicle then
      local vehId = vehicle:getID()
      gameplay_traffic.insertTraffic(vehId, true)
      pcall(function()
        parts.sales.applyRandomPaintToSpawnedVehicle(vehId, options.carMeetRandomPaintNames, vehicleSelection.model)
      end)
      vehicle.playerUsable = false
      vehicle:queueLuaCommand('electrics.setLightsState(1)')
      vehicle:queueLuaCommand('electrics.setIgnitionLevel(1)')

      if not forceVisible then
        vehicle:setHidden(true)
      end

      table.insert(carMeetState.spawnedMeetVehicles, vehId)
      registerMeetPurchaseVehicle(vehicleSelection, spot, options, vehId, deferPoiRefresh)

      return {
        id = vehId,
        pos = vec3(spot.pos),
        visible = forceVisible or false,
        hasCollision = forceVisible or false
      }
    end

    return nil
  end

  local function checkVehicleVisible(playerPos, vehiclePos)
    local startPos = playerPos + vec3(0, 0, 1.5)
    local endPos = vehiclePos + vec3(0, 0, 1)
    local direction = endPos - startPos
    local distance = direction:length()

    direction:normalize()
    local hitDistance = castRayStatic(startPos, direction, distance)
    return hitDistance >= distance * 0.90
  end

  -- Visibility update -------------------------------------------------------------------------------

  local function shouldRevealMeetVehicle(playerPos, vehiclePos)
    if (vehiclePos - playerPos):length() > inputs.VEHICLE_SPAWN_DISTANCE then
      return false
    end
    return checkVehicleVisible(playerPos, vehiclePos)
  end

  local function updateVehicleVisibility()
    if not carMeetState.meetState.active then return end

    local playerVeh = be:getPlayerVehicle(0)
    if not playerVeh then return end
    local playerPos = playerVeh:getPosition()
    local unhideBudget = inputs.PRESPAWN_MEET_VEHICLES_ON_ACCEPT and inputs.PRESPAWN_UNHIDE_PER_UPDATE or nil

    for i = #carMeetState.spawnedMeetVehicles, 1, -1 do
      local vehId = carMeetState.spawnedMeetVehicles[i]
      local veh = getObjectByID(vehId)

      if veh then
        local vehiclePos = veh:getPosition()
        local shouldBeVisible
        if inputs.PRESPAWN_MEET_VEHICLES_ON_ACCEPT then
          shouldBeVisible = shouldRevealMeetVehicle(playerPos, vehiclePos)
        else
          shouldBeVisible = checkVehicleVisible(playerPos, vehiclePos)
        end

        if shouldBeVisible and veh:isHidden() then
          if unhideBudget == nil or unhideBudget > 0 then
            veh:setHidden(false)
            if unhideBudget then unhideBudget = unhideBudget - 1 end
          end
        elseif not shouldBeVisible and not veh:isHidden() then
          veh:setHidden(true)
        end
      else
        table.remove(carMeetState.spawnedMeetVehicles, i)
      end
    end

    if not inputs.PRESPAWN_MEET_VEHICLES_ON_ACCEPT then
      for spotData in pairs(carMeetState.pendingVehicles) do
        local distance = (spotData.pos - playerPos):length()
        if distance <= inputs.VEHICLE_SPAWN_DISTANCE then
          local shouldBeVisible = checkVehicleVisible(playerPos, spotData.pos)
          local vehicleData = spawnVehicleOptimized(spotData, spotData.meetType, shouldBeVisible, spotData.club)
          carMeetState.pendingVehicles[spotData] = nil
        end
      end
    end
  end

  -- Public API ------------------------------------------------------------------------------------
  return {
    didPlayerBringVehicleToMeet = didPlayerBringVehicleToMeet,
    isPlayerAtMeetArrivalPoint = isPlayerAtMeetArrivalPoint,
    hasActiveClubForMeetType = hasActiveClubForMeetType,
    getEligibleMeetTypeKeys = getEligibleMeetTypeKeys,
    getMeetArray = getMeetArray,
    buildInvite = buildInvite,
    removePendingInvite = removePendingInvite,
    applyInvitePenalty = applyInvitePenalty,
    expirePendingInvites = expirePendingInvites,
    buildMeetSaleOverviewPayload = buildMeetSaleOverviewPayload,
    expireMeetSaleOffers = expireMeetSaleOffers,
    reconcileActiveMeetInvite = reconcileActiveMeetInvite,
    joinClub = joinClub,
    leaveClub = leaveClub,
    cleanupPreviousMeet = cleanupPreviousMeet,
    getCarMeetVehicles = getCarMeetVehicles,
    flushMeetSpawnPoisRefresh = flushMeetSpawnPoisRefresh,
    spawnVehicleOptimized = spawnVehicleOptimized,
    checkVehicleVisible = checkVehicleVisible,
    updateVehicleVisibility = updateVehicleVisibility,
  }
end

return lib
