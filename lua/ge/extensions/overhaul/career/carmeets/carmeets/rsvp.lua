-- Car meet invite actions: debug helpers, invite generation by type, acceptance checks, RSVP, decline, cancel and route.
-- Map: per-load state, invite actions, RSVP, route ownership and returned API.

local lib = {}

function lib.create(inputs)
  local parts = inputs.parts

  local carMeetState = inputs.carMeetState
  local callbacks = inputs.callbacks

  local function clearPendingInvites()
    carMeetState.pendingInvites = {}
    require("overhaul/lib/save/store").request("carmeets:clearPendingInvites")
    guihooks.trigger('onCarMeetOverview', callbacks.getCarMeetOverview())
    ui_message("Cleared pending invites.", 4, "info", "info")
    return callbacks.getCarMeetOverview()
  end

  local function debugAccelerateInvite()
    carMeetState.generationInterval = inputs.DEFAULT_INVITE_GENERATION_INTERVAL
    carMeetState.lastGenerationTime = os.time() - (carMeetState.generationInterval - 10)
    require("overhaul/lib/save/store").request("carmeets:debugAccelerateInvite")
    guihooks.trigger('onCarMeetOverview', callbacks.getCarMeetOverview())
    ui_message("Next invite in ~10 seconds.", 5, "info", "info")
    return callbacks.getCarMeetOverview()
  end

  local function generateInviteOfType(typeKey)
    parts.invites.expirePendingInvites()
    typeKey = tostring(typeKey or "SHOWCASE")
    local meetType = parts.meetTypesPart.meetTypes[typeKey]
    if not meetType then
      ui_message("Unknown car meet type: " .. typeKey, 5, "warning", "warning")
      return callbacks.getCarMeetOverview()
    end
    if #carMeetState.pendingInvites >= parts.sales.getPendingInviteCap() then
      ui_message("Car meet invite list is full.", 5, "info", "info")
      return callbacks.getCarMeetOverview()
    end
    if overhaul_career_carmeets_reputation.getReputation() < (meetType.unlockReputation or 0) then
      ui_message("Not enough rep for " .. meetType.name .. ".", 5, "warning", "warning")
      return callbacks.getCarMeetOverview()
    end
    if not parts.invites.hasActiveClubForMeetType(meetType) then
      ui_message("No active club for " .. meetType.name .. ".", 5, "warning", "warning")
      return callbacks.getCarMeetOverview()
    end

    local meetArray = parts.invites.getMeetArray()
    if #meetArray == 0 then
      ui_message("No car meet locations available on this map.", 5, "warning", "warning")
      return callbacks.getCarMeetOverview()
    end
    local invite = parts.invites.buildInvite(meetArray[math.random(#meetArray)], typeKey)
    table.insert(carMeetState.pendingInvites, invite)
    parts.meetTypesPart.firePhoneLockNotification(invite)
    carMeetState.lastGenerationTime = os.time()
    require("overhaul/lib/save/store").request("carmeets:generateInviteOfType")
    guihooks.trigger('onCarMeetOverview', callbacks.getCarMeetOverview())
    ui_message("Generated " .. (invite.typeName or invite.type) .. " invite.", 5, "info", "info")
    return callbacks.getCarMeetOverview()
  end

  local function dumpDebugState()
    log("D", "carmeets", "Car meet debug state: " .. serialize({
      reputation = overhaul_career_carmeets_reputation.getReputation(),
      pendingInvites = carMeetState.pendingInvites,
      rsvpData = carMeetState.rsvpData,
      joinedClubs = carMeetState.joinedClubs,
      attendanceHistory = overhaul_career_carmeets_reputation.getPersistState().attendanceHistory,
      meetState = {
        active = carMeetState.meetState.active,
        type = carMeetState.meetState.type,
        phase = carMeetState.meetState.phase,
        startTime = carMeetState.meetState.startTime,
        arrivalTime = carMeetState.meetState.arrivalTime,
        flags = carMeetState.meetState.flags
      }
    }))
    ui_message("Car meet state dumped to log.", 4, "info", "info")
    return callbacks.getCarMeetOverview()
  end

  local function validateInviteAcceptance(invite)
    if not invite then return false, "Invite not found." end
    local meetType = parts.meetTypesPart.meetTypes[invite.type]
    if not meetType then return false, "Meet type not found." end
    if meetType.requiresActiveClub then
      local requiredClubId = meetType.requiredClubId or invite.clubId
      local selectedClub = requiredClubId and parts.clubs.selectActiveClub(requiredClubId, false) or parts.clubs.selectActiveClub()
      if not selectedClub then
        return false, "This invite requires an active car club."
      end
    end
    local inventoryId = callbacks.getCurrentInventoryId()
    if meetType.requiresVehicle and not inventoryId then
      return false, "This meet requires you to bring a vehicle."
    end
    if meetType.minVehicleValue then
      local vehicleValue = parts.sales.getInventoryVehicleValue(inventoryId)
      if vehicleValue < meetType.minVehicleValue then
        return false, "This meet requires a vehicle worth at least $" .. tostring(meetType.minVehicleValue) .. "."
      end
    end
    return true
  end

  local function rsvpToMeet(inviteId, level)
    if carMeetState.meetState.active then
      ui_message("You already have an active car meet invite.", 5, "info", "info")
      guihooks.trigger('onCarMeetOverview', callbacks.getCarMeetOverview())
      return false
    end
    local invite = parts.invites.removePendingInvite(inviteId)
    if not invite then
      return false
    end
    local ok, reason = validateInviteAcceptance(invite)
    if not ok then
      table.insert(carMeetState.pendingInvites, invite)
      ui_message(reason or "Cannot accept this invite.", 6, "warning", "warning")
      guihooks.trigger('onCarMeetOverview', callbacks.getCarMeetOverview())
      return false
    end
    invite.attendance = inputs.attendanceLevels[level] or invite.attendance or inputs.attendanceLevels.MEDIUM
    carMeetState.rsvpData = invite
    local worldMinutes = inputs.currentWorldMinutes()
    carMeetState.rsvpData.expiresWorldMinute = worldMinutes and (worldMinutes + 1440) or nil
    if not callbacks.startCarMeet(carMeetState.rsvpData.location, carMeetState.rsvpData.type, carMeetState.rsvpData.attendance, carMeetState.rsvpData.clubId) then
      carMeetState.rsvpData = nil
      table.insert(carMeetState.pendingInvites, invite)
      guihooks.trigger('onCarMeetOverview', callbacks.getCarMeetOverview())
      return false
    end
    require("overhaul/lib/save/store").request("carmeets:rsvpToMeet")
    return true
  end

  local function decline(inviteId)
    local invite = parts.invites.removePendingInvite(inviteId)
    parts.invites.applyInvitePenalty(invite, "declined invite")
    -- A pending invite does not own the active route. Declining it must not disturb navigation for an active meet or another career activity.
    carMeetState.generationInterval = inputs.DEFAULT_INVITE_GENERATION_INTERVAL
    carMeetState.lastGenerationTime = os.time()
    require("overhaul/lib/save/store").request("carmeets:decline")
  end

  local function cancelRSVP()
    local attended = (carMeetState.meetState.active and carMeetState.meetState.phase ~= "waiting") or (carMeetState.rsvpData and carMeetState.rsvpData.attended)
    if not attended then
      parts.invites.applyInvitePenalty(carMeetState.rsvpData, "abandoned accepted invite", {sceneRep = true})
      if carMeetState.rsvpData and carMeetState.rsvpData.type == "BAZAAR" then
        ui_message(inputs.ACCEPTED_INVITE_MISS_MESSAGE, 8, "warning", "warning")
      end
    end
    carMeetState.rsvpData = nil
    inputs.meetRoute.clear()
    parts.invites.cleanupPreviousMeet()
    carMeetState.generationInterval = inputs.DEFAULT_INVITE_GENERATION_INTERVAL
    carMeetState.lastGenerationTime = os.time()
    require("overhaul/lib/save/store").request("carmeets:cancelRSVP")
  end

  local function setRoute()
    if not carMeetState.rsvpData then return end
    if not callbacks.ensureCarmeetSitesForCurrentLevel() then return end
    local meet = carMeetState.carmeetLocations[carMeetState.rsvpData.location]
    if not meet then
      log("D", "carmeets", "Car meet location not found: " .. carMeetState.rsvpData.location)
      return
    end

    local playerSpot = carMeetState.meetState.active and carMeetState.meetState.playerSpot
    if not playerSpot then
      playerSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(be:getPlayerVehicleID(0), meet.parkingSpots)
    end
    if not playerSpot or not playerSpot.pos then return end

    local options = {
      color = {1, 0.4, 0},
      step = 4,
      renderDecals = true
    }
    inputs.meetRoute.set(playerSpot.pos, options)
  end

  return {
    clearPendingInvites = clearPendingInvites,
    debugAccelerateInvite = debugAccelerateInvite,
    generateInviteOfType = generateInviteOfType,
    dumpDebugState = dumpDebugState,
    rsvpToMeet = rsvpToMeet,
    decline = decline,
    cancelRSVP = cancelRSVP,
    setRoute = setRoute,
  }
end

return lib
