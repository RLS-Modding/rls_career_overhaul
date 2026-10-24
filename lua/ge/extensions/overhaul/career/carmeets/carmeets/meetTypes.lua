-- Car meet types: the meet type table with its phase updates, phone layout and lock notification, and sale offers on arrival.
-- Map: per-load state, route helpers, cruise phases, meet definitions, notification and returned API.

local lib = {}
local phoneLayout = require("overhaul/lib/phone/layoutOwner")

function lib.create(inputs)
  local parts = inputs.parts
  -- State -----------------------------------------------------------------------------------------

  local carMeetState = inputs.carMeetState
  local callbacks = inputs.callbacks

  -- Helpers ---------------------------------------------------------------------------------------
  local function getAiPath(path, vehIndex)
    local aiPath = {}
    local veh = be:getObject(vehIndex)
    if not veh then return nil end
    local firstWpAdded = false
    local vehPos = veh:getPosition()
    local vehFwd = veh:getDirectionVector()
    local prevDot = nil
    local prevWp = nil
    local startDist = path[1] and path[1].distToTarget or 0
    local firstValidWp = nil
    -- find the first valid waypoint
    for _, marker in ipairs(path) do
      if marker.wp then
        firstValidWp = marker.wp
        if not firstWpAdded then
          local toWp = (marker.pos - vehPos):normalized()
          local dot = toWp:dot(vehFwd)
          -- If we have a previous dot product and this one is lower, we found our local maximum
          if prevDot and dot < prevDot and prevDot > 0 then
            table.insert(aiPath, prevWp)
            firstWpAdded = true
          end
          prevDot = dot
          prevWp = marker.wp
        else
          table.insert(aiPath, marker.wp)
        end
      end
    end
    -- If we haven't found a local maximum but have a positive dot product, use the last one
    if not firstWpAdded and prevDot and prevDot > 0 then
      table.insert(aiPath, prevWp)
      firstWpAdded = true
    end
    -- fallback: if no waypoint is in front of vehicle, use the first waypoint that's 25m away and all other waypoints
    if not firstWpAdded then
      for _, marker in ipairs(path) do
        if marker.wp and startDist - marker.distToTarget > 25 then
          table.insert(aiPath, marker.wp)
        end
      end
    end
    return aiPath
  end

  local function getCruiseDestination(meetLocation)
    if not meetLocation then return nil end

    local meetCenter = meetLocation.position
    local minDistance = 2000
    local maxDistance = 20000

    local otherMeets = callbacks.getCarMeetLocations()
    local validDestinations = {}

    for name, location in pairs(otherMeets) do
      if name ~= meetLocation.zone.name then
        local distance = (location.position - meetCenter):length()
        if distance >= minDistance and distance <= maxDistance then
          table.insert(validDestinations, location.position)
        end
      end
    end

    if #validDestinations > 0 then
      return validDestinations[math.random(#validDestinations)]
    end

    local mapData = map.getMap()
    if mapData and mapData.nodes then
      local validNodes = {}

      for nodeId, node in pairs(mapData.nodes) do
        if node.pos then
          local distance = (node.pos - meetCenter):length()
          if distance >= minDistance and distance <= maxDistance then
            table.insert(validNodes, node.pos)
          end
        end
      end

      if #validNodes > 0 then
        return validNodes[math.random(#validNodes)]
      end
    end

    return nil
  end

  -- Cruise phases ---------------------------------------------------------------------------------

  local function cruiseVehicleIndex(vehicleId)
    for index = 0, be:getObjectCount() - 1 do
      if be:getObject(index) and be:getObject(index):getID() == vehicleId then return index end
    end
    return -1
  end

  local function collectCruiseVehicles(routePlanner, state)
    local routeStartPos = routePlanner.path[1] and routePlanner.path[1].pos or state.flags.cruiseDestination
    local vehicleDistances = {}
    for _, vehicleId in ipairs(carMeetState.spawnedMeetVehicles) do
      local vehicle = getObjectByID(vehicleId)
      if vehicle then
        local vehiclePos = vehicle:getPosition()
        local distance = (vehiclePos - routeStartPos):length()
        table.insert(vehicleDistances, {id = vehicleId, vehicle = vehicle, distance = distance})
      end
    end
    -- Closest cars join first, so the group does not cross itself leaving the parking area.
    table.sort(vehicleDistances, function(a, b) return a.distance < b.distance end)
    return vehicleDistances
  end

  local function sendVehicleOnCruise(vehicleData, routePlanner)
    local vehicle = getObjectByID(vehicleData.id)
    if not vehicle then return end
    local vehicleIndex = cruiseVehicleIndex(vehicleData.id)
    if vehicleIndex < 0 then return end
    local aiPath = getAiPath(routePlanner.path, vehicleIndex)
    if not aiPath or #aiPath == 0 then return end
    local pathStr = '{wpTargetList = '..serialize(aiPath)
    pathStr = pathStr..', noOfLaps = 1, aggression = 0.5, avoidCars = "on"}'
    vehicle:queueLuaCommand('ai.driveUsingPath('..pathStr..')')
    vehicle:queueLuaCommand('ai.setRacing(true)')
    vehicle:queueLuaCommand('ai.driveInLane("on")')
    log("D", "carmeets", "Sending vehicle " .. vehicleData.id .. " (distance: " .. string.format("%.1f", vehicleData.distance) .. "m) on cruise route")
  end

  local function scheduleCruiseVehicles(state)
    local cruiseGeneration = carMeetState.meetGeneration
    core_jobsystem.create(function(job)
      job.sleep(1.0)
      if cruiseGeneration ~= carMeetState.meetGeneration then return end
      local routePlanner = core_groundMarkers.routePlanner
      if not routePlanner or not routePlanner.path or #routePlanner.path == 0 then return end
      local vehicleDistances = collectCruiseVehicles(routePlanner, state)
      for _, vehicleData in ipairs(vehicleDistances) do
        job.sleep(1.5)
        if cruiseGeneration ~= carMeetState.meetGeneration then return end
        sendVehicleOnCruise(vehicleData, routePlanner)
      end
    end)
  end

  local function beginCruise(state, currentTime)
    state.flags.cruiseDestination = getCruiseDestination(state.location)
    if not state.flags.cruiseDestination then state.phase = "ending"; return end
    local message = "Follow the cruise route with the group!"
    ui_message(message, 10, "info", "info")
    local options = {color = {0, 1, 0.4}, step = 4, renderDecals = true}
    inputs.meetRoute.set(state.flags.cruiseDestination, options)
    scheduleCruiseVehicles(state)
    state.flags.cruiseStarted = true
    state.flags.cruiseStartedAt = currentTime
    state.flags.routeEndCheckRadius = 50
    state.flags.routeEndPosition = state.flags.cruiseDestination
  end

  local function completeCruise(state)
    state.flags.playerReachedDestination = true
    local cruiseReputation = overhaul_career_carmeets_reputation.awardCruiseComplete(parts.sales.getMeetVehicleInventoryId(state), state.type)
    local message = string.format("Great cruise!\nYou completed the route with the group!\nBonus reputation: %.1f%%", tonumber(cruiseReputation) or 0)
    ui_message(message, 10, "info", "info")
    inputs.meetRoute.clear()
    require("overhaul/lib/save/store").request("carmeets:cruiseComplete")
    state.phase = "ending"
    state.flags.dispersalStarted = false
    parts.clubs.clearMeetShowcasePois(state)
  end

  local function updateCruiseProgress(state, currentTime)
    state.flags.cruiseStartedAt = state.flags.cruiseStartedAt or currentTime
    if currentTime - state.flags.cruiseStartedAt > inputs.CRUISE_TIMEOUT then
      ui_message("The cruise group moved on without you.", 10, "info", "info")
      inputs.meetRoute.clear()
      state.phase = "ending"
      state.flags.dispersalStarted = false
      parts.clubs.clearMeetShowcasePois(state)
      return
    end
    local playerVehicle = be:getPlayerVehicle(0)
    if playerVehicle and state.flags.routeEndPosition then
      local distance = (playerVehicle:getPosition() - state.flags.routeEndPosition):length()
      if distance < state.flags.routeEndCheckRadius then completeCruise(state) end
    end
  end

  local function updateCruise(state, currentTime)
    if state.phase ~= "cruise" then return end
    if not state.flags.cruiseStarted then beginCruise(state, currentTime)
    elseif not state.flags.playerReachedDestination then updateCruiseProgress(state, currentTime) end
  end

  -- Meet definitions ------------------------------------------------------------------------------

  local function showcaseMeetType()
    return {
      name = "Showcase",
      description = "Show off your ride and admire others",
      unlockReputation = 0,
      expirationSeconds = inputs.DEFAULT_INVITE_EXPIRATION,
      missPenalty = 0,
      requiresVehicle = false,
      baseReputationMultiplier = 1.0,
      showcaseDuration = 600,
      preferredTimes = {0.417, 0.458, 0.500},
      timeWindow = 0.02,
      vehicleFilters = {
        whiteList = {
          ["Config Type"] = {"CarmeetRLS", "Custom"},
          ["Body Style"] = {"Sedan", "Hatchback", "SUV", "Coupe"}
        }
      },
      actions = {
        onArrival = function(reputation)
          return string.format("Welcome to the showcase!\nCommunity liked your car!\nScene reputation increased by %.1f%%", tonumber(reputation) or 0)
        end,
        onShowcaseEnd = function(state)
          state.phase = "ending"
          state.flags.dispersalStarted = false
          parts.clubs.clearMeetShowcasePois(state)
          ui_message("Car meet is over, vehicles starting to leave!", 10, "info", "info")
        end,
        onLeave = function()
          return "Car meet is over, Thanks for coming!"
        end
      },
      onUpdate = nil
    }
  end

  local function streetCruiseMeetType()
    return {
      name = "Cruise",
      description = "Meet up and cruise to a destination",
      unlockReputation = 10,
      expirationSeconds = inputs.DEFAULT_INVITE_EXPIRATION,
      missPenalty = 0,
      requiresVehicle = false,
      requiresActiveClub = false,
      baseReputationMultiplier = 1.5,
      showcaseDuration = 600,
      preferredTimes = {0.875, 0.917, 0.958},
      timeWindow = 0.025,
      vehicleFilters = {
        whiteList = {
          ["Body Style"] = {"Coupe", "Sedan", "Hatchback"}
        }
      },
      vehiclePoolRules = {
        tiers = {
          {populationMax = 5000},
          {populationMax = 10000}
        }
      },
      actions = {
        onArrival = function(reputation)
          parts.clubs.saveAndReduceTraffic(0.7)
          return string.format("Ready to cruise!\nCruisers respect your ride!\nCommunity reputation increased by %.1f%%", tonumber(reputation) or 0)
        end,
        onShowcaseEnd = function(state)
          state.phase = "cruise"
          state.flags.cruiseStarted = false
          state.flags.playerReachedDestination = false
          parts.clubs.clearMeetShowcasePois(state)
        end,
        onLeave = function()
          local leaveGeneration = carMeetState.meetGeneration
          core_jobsystem.create(function(job)
            job.sleep(10)
            if leaveGeneration ~= carMeetState.meetGeneration then return end
            parts.clubs.restoreTrafficAmount()
          end)
          return "Cruise complete! Drive safe out there!"
        end
      },
      onUpdate = updateCruise
    }
  end

  local function clubMeetType()
    return {
      name = "Car Club",
      description = "A club meet for owners with the right cars",
      unlockReputation = 30,
      expirationSeconds = inputs.DEFAULT_INVITE_EXPIRATION,
      missPenalty = 0,
      requiresVehicle = false,
      requiresActiveClub = true,
      baseReputationMultiplier = 1.2,
      showcaseDuration = 600,
      vehicleFilters = {
        whiteList = {
          ["Body Style"] = {"Sedan", "Hatchback", "SUV", "Coupe"}
        }
      },
      vehiclePoolRules = {
        tiers = {
          {populationMax = 5000},
          {populationMax = 10000}
        }
      },
      actions = {
        onArrival = function(reputation)
          return "Welcome to the club meet!\nYour reputation increased by " .. reputation .. "."
        end,
        onShowcaseEnd = function(state)
          state.phase = "ending"
          state.flags.dispersalStarted = false
          parts.clubs.clearMeetShowcasePois(state)
          ui_message("Club meet is over, vehicles starting to leave!", 10, "info", "info")
        end,
        onLeave = function()
          return "Club meet is over. Thanks for coming!"
        end
      },
      onUpdate = nil
    }
  end

  local function bazaarMeetType()
    return {
      name = "Car Bazaar",
      description = "Bring a car, make deals, and try to leave with a sale",
      unlockReputation = 70,
      expirationSeconds = inputs.DEFAULT_INVITE_EXPIRATION,
      missPenalty = -2,
      requiresVehicle = true,
      requiresActiveClub = true,
      requiredClubId = "car_bazaar_club",
      baseReputationMultiplier = 1.0,
      showcaseDuration = 600,
      vehicleFilters = {
        whiteList = {
          ["Body Style"] = {"Sedan", "Hatchback", "SUV", "Coupe", "Truck"}
        }
      },
      vehiclePoolRules = {
        tiers = {
          {populationMax = 2500},
          {populationMax = 5000},
          {populationMax = 10000}
        }
      },
      actions = {
        onArrival = function(reputation)
          return "Welcome to the Car Bazaar!\nSell your brought vehicle before the meet ends."
        end,
        onShowcaseEnd = function(state)
          state.phase = "ending"
          state.flags.dispersalStarted = false
          parts.clubs.clearMeetShowcasePois(state)
          if not state.flags.playerSoldSaleVehicle then
            ui_message("Bazaar ended without a sale.", 10, "warning", "warning")
          else
            ui_message("Bazaar is over, vehicles starting to leave!", 10, "info", "info")
          end
        end,
        onLeave = function()
          return "Bazaar complete. See you at the next one."
        end
      },
      onUpdate = function(state, currentTime)
        if state.phase ~= "showcase" then return end
        if not callbacks.canPlayerSellAtMeet(state) then return end
        local inventoryId = state.flags.saleInventoryId
        if not inventoryId or state.flags.playerSoldSaleVehicle then return end
        local schedule = state.flags.bazaarOfferSchedule or {}
        local generated = state.flags.bazaarGuaranteedOffersGenerated or 0
        local nextOfferAt = schedule[generated + 1]
        if not nextOfferAt or currentTime < nextOfferAt then return end

        local offer = parts.sales.generateMeetSaleOffer(state, inputs.BAZAAR_OFFER_TTL)
        if offer then
          state.flags.bazaarGuaranteedOffersGenerated = generated + 1
          ui_message("A Bazaar buyer made an offer on your vehicle.", 6, "info", "info")
          if gameplay_rawPois and gameplay_rawPois.clear then
            gameplay_rawPois.clear()
          end
          guihooks.trigger('onCarMeetOverview', callbacks.getCarMeetOverview())
        end
      end
    }
  end

  local function eliteMeetType()
    return {
      name = "Elite Cars",
      description = "Invite-only high-end meet for rare and expensive builds",
      unlockReputation = 90,
      expirationSeconds = inputs.DEFAULT_INVITE_EXPIRATION,
      missPenalty = 0,
      requiresVehicle = true,
      requiresActiveClub = true,
      requiredClubId = "elite_cars_club",
      minVehicleValue = 200000,
      baseReputationMultiplier = 1.5,
      showcaseDuration = 600,
      vehicleFilters = {
        whiteList = {
          ["Body Style"] = {"Sedan", "Hatchback", "SUV", "Coupe"}
        }
      },
      vehiclePoolRules = {
        tiers = {
          {populationMax = 500, valueMin = 200000},
          {populationMax = 2500, valueMin = 200000},
          {populationMax = 5000, valueMin = 200000},
          {valueMin = 200000}
        }
      },
      actions = {
        onArrival = function(reputation)
          return "Welcome to the elite meet.\nYour reputation increased by " .. reputation .. "."
        end,
        onShowcaseEnd = function(state)
          state.phase = "ending"
          state.flags.dispersalStarted = false
          parts.clubs.clearMeetShowcasePois(state)
          ui_message("Elite meet is over, vehicles starting to leave!", 10, "info", "info")
        end,
        onLeave = function()
          return "Elite meet complete."
        end
      },
      onUpdate = nil
    }
  end

  local meetTypes = {
    SHOWCASE = showcaseMeetType(),
    STREET_CRUISE = streetCruiseMeetType(),
    CLUB = clubMeetType(),
    BAZAAR = bazaarMeetType(),
    ELITE = eliteMeetType(),
  }

  local function getMeetType(typeKey)
    return meetTypes[typeKey]
  end

  -- === Lock-screen peek Routes through the phone OS dispatcher so the player's Notifications toggle (Settings -> Notifications -> Car Meet -> Invites) is always respected.
  local function firePhoneLockNotification(invite)
    if not invite then return end
    local layout = phoneLayout.get()
    if not (layout and layout.fireNotification) then return end
    local typeName = invite.typeName or invite.type or "Invite"
    local where = invite.location or invite.clubName or ""
    local message = where ~= "" and (typeName .. " - " .. where) or typeName
    layout.fireNotification("carMeet.invite", {
      title = "New Invite",
      message = message,
      kind = "invite",
      ttl = 8,
      meta = invite.clubName or "",
      source = "Car Meets",
      sound = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" }
    })
  end

  local function updateMeetSaleOffers(state, currentTime)
    if not state or state.phase ~= "showcase" or state.type == "BAZAAR" then return end
    if not callbacks.canPlayerSellAtMeet(state) then return end
    local inventoryId = state.flags and state.flags.saleInventoryId
    if not inventoryId or state.flags.playerSoldSaleVehicle then return end
    if currentTime < (state.flags.nextSellOfferCheckAt or 0) then return end

    state.flags.nextSellOfferCheckAt = currentTime + inputs.DEFAULT_SELL_OFFER_INTERVAL
    local listing = parts.sales.ensureMeetSaleState(state)
    local chance = parts.sales.getSellOfferChance(state.type) * parts.sales.getAskingPriceOfferChanceMultiplier(listing)
    if math.random() > math.min(0.95, chance) then return end

    local meetType = meetTypes[state.type]
    local remaining = meetType and state.arrivalTime and meetType.showcaseDuration and ((state.arrivalTime + meetType.showcaseDuration) - currentTime) or inputs.BAZAAR_OFFER_TTL
    local offer = parts.sales.generateMeetSaleOffer(state, math.max(60, remaining + 30))
    if offer then
      ui_message("Someone at the meet made an offer on your vehicle.", 6, "info", "info")
      if gameplay_rawPois and gameplay_rawPois.clear then
        gameplay_rawPois.clear()
      end
      guihooks.trigger('onCarMeetOverview', callbacks.getCarMeetOverview())
    end
  end

  local function initializeMeetSaleOnArrival(state, currentTime)
    if not state or not state.flags or not state.flags.saleInventoryId or state.flags.saleInitialized then return end
    state.flags.saleInitialized = true
    local playerVehicleId = be:getPlayerVehicleID(0)
    if playerVehicleId and playerVehicleId >= 0 then
      state.flags.saleVehicleId = playerVehicleId
    elseif state.flags.saleInventoryId then
      local parkedVehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(state.flags.saleInventoryId)
      if parkedVehId and parkedVehId >= 0 then
        state.flags.saleVehicleId = parkedVehId
      end
    end
    parts.sales.ensureMeetSaleState(state)

    if state.type == "BAZAAR" then
      state.flags.bazaarOfferSchedule = {}
      local meetType = meetTypes[state.type] or {}
      local duration = meetType.showcaseDuration or 600
      for i = 1, state.flags.bazaarGuaranteedOffersTarget or 1 do
        table.insert(state.flags.bazaarOfferSchedule, (state.arrivalTime or currentTime) + math.floor(duration * (i / ((state.flags.bazaarGuaranteedOffersTarget or 1) + 1))))
      end
    else
      state.flags.nextSellOfferCheckAt = currentTime + inputs.DEFAULT_SELL_OFFER_FIRST_CHECK
    end

    guihooks.trigger('onCarMeetOverview', callbacks.getCarMeetOverview())
    if gameplay_rawPois and gameplay_rawPois.clear then
      gameplay_rawPois.clear()
    end
  end

  -- Public API ------------------------------------------------------------------------------------
  return {
    meetTypes = meetTypes,
    getMeetType = getMeetType,
    firePhoneLockNotification = firePhoneLockNotification,
    updateMeetSaleOffers = updateMeetSaleOffers,
    initializeMeetSaleOnArrival = initializeMeetSaleOnArrival,
  }
end

return lib
