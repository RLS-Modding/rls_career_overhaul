-- Car meet activity, invitations, vehicle sales and map markers for one career.
-- Map: config, state, route helpers, named parts, update steps, transactions, purchase, lifecycle and hooks.

-- Requires ----------------------------------------------------------------------------------------
local M = {}
local statePush = require('overhaul/lib/ui/statePush')
local capabilities = require("overhaul/lib/platform/capabilities")
M.dependencies = {'gameplay_sites_sitesManager', 'util_configListGenerator'}
local persist = require('overhaul/career/carmeets/carmeets/persist')
local stockOverrides = require('overhaul/lib/vehicles/stockVehicleOverrides')
local gameTime = require('overhaul/lib/career/gameTime')

-- Config ------------------------------------------------------------------------------------------
local attendanceLevels = {
  LOW = 1,
  MEDIUM = 2,
  HIGH = 3
}
local MEET_CHECK_INTERVAL_S = 5
local EARLY_PENDING_INVITE_CAP = 3
local LATE_PENDING_INVITE_CAP = 5
local LATE_PENDING_INVITE_REP = 70
local DEFAULT_INVITE_EXPIRATION_S = gameTime.SIM_SECONDS_PER_GAME_DAY
-- Invite generation keeps its existing one-and-a-half-day wall-clock window.
local DEFAULT_INVITE_GENERATION_INTERVAL_S = 1.5 * gameTime.SIM_SECONDS_PER_GAME_DAY
local ACCEPTED_INVITE_MISS_MESSAGE = "You bailed on an accepted car meet invite."
local CLUB_DEFINITIONS_PATH = "gameplay/overhaul/carmeets/clubs.json"
local BAZAAR_OFFER_TTL_S = 180
local DEFAULT_SELL_OFFER_INTERVAL_S = 120
local CRUISE_TIMEOUT_S = 2400
local DEFAULT_SELL_OFFER_FIRST_CHECK_S = 45
local MEET_CLEANUP_DISTANCE_M = 100
local MEET_LEAVE_INTERVAL_S = 5
local VEHICLE_SPAWN_DISTANCE_M = 150
local VEHICLE_UPDATE_INTERVAL_S = 0.25
-- Pre-spawn all meet cars hidden on RSVP accept; reveal on approach (set false to revert)
local PRESPAWN_MEET_VEHICLES_ON_ACCEPT = true
local PRESPAWN_SPAWN_STAGGER_S = 0.1
local PRESPAWN_UNHIDE_PER_UPDATE = 2
local WALKING_MEET_ARRIVAL_DISTANCE_M = 18
local PLAYER_VEHICLE_AT_MEET_DISTANCE_M = 25
local CLUB_OBLIGATION_WINDOW_SIZE = 3
local CLUB_OBLIGATION_REQUIRED_ATTENDANCE = 1
local CLUB_STANDING_MAX = 100
local CLUB_STANDING_WARNING_THRESHOLD = 35
local CLUB_STANDING_MISS_PENALTY = 40

-- State -------------------------------------------------------------------------------------------
local callbacks = {}
local disposeSaleObserver
local carMeetState = {}
carMeetState.carmeetLocations = {}
carMeetState.carmeetSitesLevelId = nil
carMeetState.carmeetSitesAvailable = false
carMeetState.carMeetVehicles = {}
carMeetState.spawnedMeetVehicles = {}
carMeetState.carMeetPurchaseVehicles = {}
carMeetState.pendingVehicles = {}
carMeetState.usedConfigs = {}
carMeetState.lastGenerationTime = 0
carMeetState.generationInterval = DEFAULT_INVITE_GENERATION_INTERVAL_S
carMeetState.rsvpData = nil
carMeetState.lastUpdateCheck = 0
carMeetState.pendingInvites = {}
carMeetState.nextInviteId = 1
carMeetState.joinedClubs = {}
carMeetState.clubDefinitions = nil
carMeetState.loadedSavePath = nil
carMeetState.sceneRepDirty = false

carMeetState.careerActive = false
carMeetState.previousTrafficAmount = nil
carMeetState.meetGeneration = 0
carMeetState.vehicleVisibilityTimer = 0
carMeetState.meetState = {
  active = false,
  type = nil,
  location = nil,
  playerSpot = nil,
  startTime = 0,
  arrivalTime = 0,
  flags = {},
  phase = "waiting"
}

-- Helpers -----------------------------------------------------------------------------------------
local function currentWorldMinutes()
  return overhaul_world_weather.getWorldMinutes()
end
-- Ground-marker route owned by car meets. Cleanup clears it only while it is still ours, so a newer marketplace, delivery, journal or manual route survives. One table keeps these helpers under LuaJIT's 200-local limit.
local meetRoute = { target = nil, token = nil }
function meetRoute.copy(target)
  if not target then return nil end
  local ok, result = pcall(function()
    return vec3(target.x, target.y, target.z)
  end)
  return ok and result or nil
end
function meetRoute.set(target, options)
  local routeTarget = meetRoute.copy(target)
  if not routeTarget then
    return false
  end
  meetRoute.token = core_groundMarkers.setPath(routeTarget, options)
  meetRoute.target = routeTarget
  capabilities.get("groundMarkerOwnership").claim("carmeets")
  return true
end
function meetRoute.clear()
  local ownership = capabilities.get("groundMarkerOwnership")
  if ownership then ownership.release("carmeets") end
  local ownedTarget = meetRoute.target
  local ownedToken = meetRoute.token
  meetRoute.target = nil
  meetRoute.token = nil
  if not ownedTarget then return false end

  local currentTarget = core_groundMarkers.getTargetPos()
  if not currentTarget then return false end

  local ok, distance = pcall(function()
    return (currentTarget - ownedTarget):length()
  end)
  if not ok or distance > 1 then return false end

  if core_groundMarkers.clearOwnedPath then
    return core_groundMarkers.clearOwnedPath(ownedToken)
  end
  core_groundMarkers.resetAll()
  return true
end

-- Parts -------------------------------------------------------------------------------------------
persist.bind({
  read = function()
    return {
      lastGenerationTime = carMeetState.lastGenerationTime,
      rsvpData = carMeetState.rsvpData,
      pendingInvites = carMeetState.pendingInvites,
      nextInviteId = carMeetState.nextInviteId,
      joinedClubs = carMeetState.joinedClubs,
      loadedSavePath = carMeetState.loadedSavePath,
      sceneRepDirty = carMeetState.sceneRepDirty,
    }
  end,
  setState = function(state)
    carMeetState.lastGenerationTime = state.lastGenerationTime
    carMeetState.rsvpData = state.rsvpData
    carMeetState.pendingInvites = state.pendingInvites
    carMeetState.nextInviteId = state.nextInviteId
    carMeetState.joinedClubs = state.joinedClubs
    carMeetState.loadedSavePath = state.loadedSavePath
    carMeetState.sceneRepDirty = state.sceneRepDirty
  end,
  isCareerActive = function()
    return overhaul_career_career.isActive()
  end,
  getActiveSavePath = function()
    local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
    return savePath
  end,
})

local parts = {}
local partInputs = {
  parts = parts,
  carMeetState = carMeetState,
  callbacks = callbacks,
  EARLY_PENDING_INVITE_CAP = EARLY_PENDING_INVITE_CAP,
  LATE_PENDING_INVITE_CAP = LATE_PENDING_INVITE_CAP,
  LATE_PENDING_INVITE_REP = LATE_PENDING_INVITE_REP,
  BAZAAR_OFFER_TTL = BAZAAR_OFFER_TTL_S,
  persist = persist,
  CLUB_DEFINITIONS_PATH = CLUB_DEFINITIONS_PATH,
  CLUB_OBLIGATION_WINDOW_SIZE = CLUB_OBLIGATION_WINDOW_SIZE,
  CLUB_OBLIGATION_REQUIRED_ATTENDANCE = CLUB_OBLIGATION_REQUIRED_ATTENDANCE,
  CLUB_STANDING_MAX = CLUB_STANDING_MAX,
  CLUB_STANDING_WARNING_THRESHOLD = CLUB_STANDING_WARNING_THRESHOLD,
  CLUB_STANDING_MISS_PENALTY = CLUB_STANDING_MISS_PENALTY,
  meetRoute = meetRoute,
  DEFAULT_INVITE_EXPIRATION = DEFAULT_INVITE_EXPIRATION_S,
  DEFAULT_SELL_OFFER_INTERVAL = DEFAULT_SELL_OFFER_INTERVAL_S,
  CRUISE_TIMEOUT = CRUISE_TIMEOUT_S,
  DEFAULT_SELL_OFFER_FIRST_CHECK = DEFAULT_SELL_OFFER_FIRST_CHECK_S,
  stockOverrides = stockOverrides,
  attendanceLevels = attendanceLevels,
  VEHICLE_SPAWN_DISTANCE = VEHICLE_SPAWN_DISTANCE_M,
  PRESPAWN_MEET_VEHICLES_ON_ACCEPT = PRESPAWN_MEET_VEHICLES_ON_ACCEPT,
  PRESPAWN_UNHIDE_PER_UPDATE = PRESPAWN_UNHIDE_PER_UPDATE,
  WALKING_MEET_ARRIVAL_DISTANCE = WALKING_MEET_ARRIVAL_DISTANCE_M,
  PLAYER_VEHICLE_AT_MEET_DISTANCE = PLAYER_VEHICLE_AT_MEET_DISTANCE_M,
  DEFAULT_INVITE_GENERATION_INTERVAL = DEFAULT_INVITE_GENERATION_INTERVAL_S,
  PRESPAWN_SPAWN_STAGGER = PRESPAWN_SPAWN_STAGGER_S,
  currentWorldMinutes = currentWorldMinutes,
  ACCEPTED_INVITE_MISS_MESSAGE = ACCEPTED_INVITE_MISS_MESSAGE,
}
parts.sales = require('overhaul/career/carmeets/carmeets/sales').create(partInputs)
parts.clubs = require('overhaul/career/carmeets/carmeets/clubs').create(partInputs)
parts.meetTypesPart = require('overhaul/career/carmeets/carmeets/meetTypes').create(partInputs)
parts.invites = require('overhaul/career/carmeets/carmeets/invites').create(partInputs)
parts.flow = require('overhaul/career/carmeets/carmeets/flow').create(partInputs)
parts.rsvp = require('overhaul/career/carmeets/carmeets/rsvp').create(partInputs)

-- Update ------------------------------------------------------------------------------------------
-- An RSVP the player never acted on lapses one in-game day after it is first seen.
local function expireUnattendedMeetInvite()
  if carMeetState.rsvpData and not carMeetState.rsvpData.attended and (not carMeetState.meetState.active or carMeetState.meetState.phase == "waiting") then
    local worldMinutes = currentWorldMinutes()
    if worldMinutes then
      carMeetState.rsvpData.expiresWorldMinute = carMeetState.rsvpData.expiresWorldMinute or (worldMinutes + 1440)
      if worldMinutes >= carMeetState.rsvpData.expiresWorldMinute then
        carMeetState.rsvpData = nil
        meetRoute.clear()
        parts.invites.cleanupPreviousMeet()
        carMeetState.generationInterval = DEFAULT_INVITE_GENERATION_INTERVAL_S
        carMeetState.lastGenerationTime = os.time()
        require("overhaul/lib/save/store").request("carmeets:onUpdate")
        statePush.send('onCarMeetOverview', callbacks.getCarMeetOverview())
      end
    end
  end
end
-- Arrival at a waiting meet. Returns true only when the meet type is missing: the caller then stops the whole update.
local function beginCarMeetShowcase(currentTime)
  if carMeetState.meetState.active and carMeetState.meetState.phase == "waiting" then
    if parts.invites.isPlayerAtMeetArrivalPoint() then
      local meetType = parts.meetTypesPart.meetTypes[carMeetState.meetState.type]
      if not meetType then return true end

      local locationName = carMeetState.rsvpData and carMeetState.rsvpData.location or (carMeetState.meetState.location and carMeetState.meetState.location.zone and carMeetState.meetState.location.zone.name) or "carMeet"
      local arrival = overhaul_career_carmeets_reputation.awardMeetArrival({
        multiplier = meetType.baseReputationMultiplier,
        inventoryId = parts.sales.getMeetVehicleInventoryId(carMeetState.meetState),
        meetTypeKey = carMeetState.meetState.type,
        meetTypeName = meetType.name,
        location = carMeetState.rsvpData and carMeetState.rsvpData.location or nil,
        buzzZone = {
          id = "carMeet:" .. tostring(locationName),
          type = carMeetState.meetState.type or "meet",
          localPopularityRewardMinPercent = meetType.localPopularityRewardMinPercent or 0.4,
          localPopularityRewardMaxPercent = meetType.localPopularityRewardMaxPercent or 1.0,
          localPopularityCapPercent = meetType.localPopularityCapPercent or 8
        }
      })
      local message = meetType.actions.onArrival(arrival.reputation)
      if arrival.attendanceMessage then
        message = message .. "\n" .. arrival.attendanceMessage
      end
      local buzzRep = arrival.buzz and tonumber(arrival.buzz.amountPercent) or 0
      if buzzRep > 0 then
        message = message .. string.format("\nLocal buzz increased by %.2f%%.", buzzRep)
      elseif arrival.buzz and arrival.buzz.capped then
        message = message .. "\nThis car is already well known locally."
      end
      ui_message(message, 10, "info", "info")

      if carMeetState.rsvpData and carMeetState.rsvpData.clubId and carMeetState.meetState.flags and not carMeetState.meetState.flags.clubAttendanceTracked then
        parts.clubs.recordClubMeetResult(carMeetState.rsvpData.clubId, true, "attended club meet")
        carMeetState.meetState.flags.clubAttendanceTracked = true
      end
      meetRoute.clear()

      carMeetState.meetState.phase = "showcase"
      carMeetState.meetState.arrivalTime = currentTime
      carMeetState.meetState.flags.playerBroughtVehicle = parts.invites.didPlayerBringVehicleToMeet()
      if not carMeetState.meetState.flags.saleInventoryId then
        carMeetState.meetState.flags.saleInventoryId = parts.sales.resolveMeetSaleInventoryId()
      end
      if carMeetState.meetState.flags.saleInventoryId and carMeetState.meetState.flags.playerBroughtVehicle then
        parts.meetTypesPart.initializeMeetSaleOnArrival(carMeetState.meetState, currentTime)
      end
      if gameplay_rawPois and gameplay_rawPois.clear then
        gameplay_rawPois.clear()
      end
      if carMeetState.rsvpData then
        carMeetState.rsvpData.attended = true
      end
      require("overhaul/lib/save/store").request("carmeets:onUpdate")
      statePush.send('onCarMeetOverview', callbacks.getCarMeetOverview())
    end
  end
end
-- Meet cars only need their visibility refreshed while a meet is live.
local function tickVehicleVisibility(dtReal)
  if not carMeetState.meetState.active then return end
  carMeetState.vehicleVisibilityTimer = carMeetState.vehicleVisibilityTimer + (tonumber(dtReal) or 0)
  if carMeetState.vehicleVisibilityTimer >= VEHICLE_UPDATE_INTERVAL_S then
    carMeetState.vehicleVisibilityTimer = 0
    parts.invites.updateVehicleVisibility()
  end
end

-- Showcase: the meet type closes its showcase when the time runs out, and a car brought late can still join.
local function tickShowcase(currentTime)
  if not (carMeetState.meetState.active and carMeetState.meetState.phase == "showcase") then return end
  local meetType = parts.meetTypesPart.meetTypes[carMeetState.meetState.type]
  if meetType and currentTime - carMeetState.meetState.arrivalTime > meetType.showcaseDuration then
    if meetType.actions and meetType.actions.onShowcaseEnd then
      meetType.actions.onShowcaseEnd(carMeetState.meetState)
      parts.invites.expireMeetSaleOffers(carMeetState.meetState)
    end
  end
  if carMeetState.meetState.flags and not carMeetState.meetState.flags.playerSoldSaleVehicle then
    if not carMeetState.meetState.flags.saleInventoryId then
      carMeetState.meetState.flags.saleInventoryId = parts.sales.resolveMeetSaleInventoryId()
    end
    if carMeetState.meetState.flags.saleInventoryId and not carMeetState.meetState.flags.playerBroughtVehicle and parts.invites.didPlayerBringVehicleToMeet() then
      carMeetState.meetState.flags.playerBroughtVehicle = true
      if not carMeetState.meetState.flags.saleInitialized then
        parts.meetTypesPart.initializeMeetSaleOnArrival(carMeetState.meetState, currentTime)
      end
      statePush.send('onCarMeetOverview', callbacks.getCarMeetOverview())
    end
  end
end

-- A live meet (not yet cleaning up or ending): keeps the brought car's sale listing and the meet type's update going.
local function tickActiveMeet(currentTime)
  if not (carMeetState.meetState.active and carMeetState.meetState.type) then return end
  if carMeetState.meetState.flags and not carMeetState.meetState.flags.saleInventoryId and carMeetState.meetState.phase ~= "cleanup" and carMeetState.meetState.phase ~= "ending" then
    local resolved = parts.sales.resolveMeetSaleInventoryId()
    if resolved then
      carMeetState.meetState.flags.saleInventoryId = resolved
      carMeetState.meetState.flags.playerSoldSaleVehicle = false
    end
  end
  local meetType = parts.meetTypesPart.meetTypes[carMeetState.meetState.type]
  if meetType and meetType.onUpdate then
    meetType.onUpdate(carMeetState.meetState, currentTime)
  end
  parts.meetTypesPart.updateMeetSaleOffers(carMeetState.meetState, currentTime)
  if callbacks.canPlayerSellAtMeet(carMeetState.meetState) then
    statePush.refresh('onCarMeetOverview', callbacks.getCarMeetOverview())
  end
end

-- Starts the walk-away once: records every meet car to leave, clears showcase markers and expires offers.
local function startDispersal(currentTime)
  carMeetState.meetState.flags.vehiclesToLeave = {}
  for _, vehID in ipairs(carMeetState.spawnedMeetVehicles) do
    table.insert(carMeetState.meetState.flags.vehiclesToLeave, vehID)
  end
  carMeetState.meetState.flags.lastVehicleLeaveTime = currentTime
  carMeetState.meetState.flags.dispersalStarted = true
  parts.invites.expireMeetSaleOffers(carMeetState.meetState)
  -- Drop showcase inspect/sale markers immediately so they don't stick at the player's last location after leaving the meet.
  meetRoute.clear()
  if gameplay_rawPois and gameplay_rawPois.clear then
    gameplay_rawPois.clear()
  end
end

-- Sends one meet car on its way every MEET_LEAVE_INTERVAL seconds.
local function sendNextLeavingVehicle(currentTime)
  if not (#carMeetState.meetState.flags.vehiclesToLeave > 0 and currentTime - carMeetState.meetState.flags.lastVehicleLeaveTime >= MEET_LEAVE_INTERVAL_S) then return end
  local vehID = table.remove(carMeetState.meetState.flags.vehiclesToLeave, 1)
  local veh = getObjectByID(vehID)
  if veh then
    veh:queueLuaCommand('ai.setMode("traffic")')
    veh:queueLuaCommand('ai.setSpeedMode("legal")')
  end
  carMeetState.meetState.flags.lastVehicleLeaveTime = currentTime
end

local function tickEnding(currentTime)
  if not (carMeetState.meetState.active and carMeetState.meetState.phase == "ending") then return end
  local meetType = parts.meetTypesPart.meetTypes[carMeetState.meetState.type]

  if not carMeetState.meetState.flags.dispersalStarted then
    startDispersal(currentTime)
  end
  sendNextLeavingVehicle(currentTime)

  if #carMeetState.meetState.flags.vehiclesToLeave == 0 then
    if meetType and meetType.actions and meetType.actions.onLeave then
      local message = meetType.actions.onLeave()
      ui_message(message, 10, "info", "info")
    end
    carMeetState.meetState.phase = "cleanup"
    require("overhaul/lib/save/store").request("carmeets:onUpdate")
    statePush.send('onCarMeetOverview', callbacks.getCarMeetOverview())
  end
end

-- Despawns meet cars that are gone or out of range; with no player position every car goes at once.
local function despawnFarMeetVehicles(playerPos)
  for i = #carMeetState.spawnedMeetVehicles, 1, -1 do
    local vehID = carMeetState.spawnedMeetVehicles[i]
    local veh = getObjectByID(vehID)
    if not veh then
      table.remove(carMeetState.spawnedMeetVehicles, i)
    elseif not playerPos then
      -- No player position (edge case): despawn immediately so cleanup can't stall.
      table.remove(carMeetState.spawnedMeetVehicles, i)
      gameplay_traffic.removeTraffic(vehID)
      veh:delete()
    else
      local distance = (playerPos - veh:getPosition()):length()
      if distance > MEET_CLEANUP_DISTANCE_M then
        table.remove(carMeetState.spawnedMeetVehicles, i)
        gameplay_traffic.removeTraffic(vehID)
        veh:delete()
      end
    end
  end
end

local function tickCleanup()
  if carMeetState.meetState.phase ~= "cleanup" then return end
  despawnFarMeetVehicles(parts.sales.getPlayerReferencePosition())

  if #carMeetState.spawnedMeetVehicles == 0 then
    if carMeetState.rsvpData and carMeetState.rsvpData.type == "BAZAAR" and (tonumber(carMeetState.meetState.arrivalTime) or 0) <= 0 then
      parts.invites.applyInvitePenalty(carMeetState.rsvpData, "missed bazaar after RSVP", {sceneRep = true})
      ui_message(ACCEPTED_INVITE_MISS_MESSAGE, 8, "warning", "warning")
    end
    carMeetState.rsvpData = nil
    parts.invites.cleanupPreviousMeet()
    require("overhaul/lib/save/store").request("carmeets:onUpdate")
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not overhaul_career_career.isActive() then return end

  expireUnattendedMeetInvite()

  if not callbacks.ensureCarmeetSitesForCurrentLevel() then
    if carMeetState.meetState.active then
      parts.invites.cleanupPreviousMeet()
    end
    return
  end

  tickVehicleVisibility(dtReal)

  local currentTime = os.time()
  if currentTime - carMeetState.lastUpdateCheck >= MEET_CHECK_INTERVAL_S then
    carMeetState.lastUpdateCheck = currentTime
    if carMeetState.loadedSavePath then
      overhaul_career_carmeets_reputation.mergeLegacyCarRep()
    end
    parts.flow.checkAvailableMeets(true)

    if beginCarMeetShowcase(currentTime) then return end

    tickShowcase(currentTime)
    tickActiveMeet(currentTime)
    tickEnding(currentTime)
    tickCleanup()
  end
end

-- Sales and transactions --------------------------------------------------------------------------
function M.addTransactionReputation(kind, price, marketValue, inventoryId, soldVehicle)
  if carMeetState.meetState.active and inventoryId then
    carMeetState.meetState.flags.transactionRewards = carMeetState.meetState.flags.transactionRewards or {}
    local key = tostring(kind) .. ':' .. tostring(inventoryId)
    local vehicle = soldVehicle or overhaul_career_garage_inventory.getVehicles()[inventoryId]
    if not vehicle or carMeetState.meetState.flags.transactionRewards[key] == vehicle then return overhaul_career_carmeets_reputation.getReputation() end
    carMeetState.meetState.flags.transactionRewards[key] = vehicle
    if overhaul_career_carmeets_reputation.awardTransaction(kind, price, marketValue, inventoryId, carMeetState.meetState.type, soldVehicle) > 0 then
      require("overhaul/lib/save/store").request("carmeets:addTransactionReputation")
    end
  end
  return overhaul_career_carmeets_reputation.getReputation()
end
local function onMarketplaceVehicleSold(inventoryId, salePrice, marketValue, soldVehicle)
  if not carMeetState.meetState.active or not carMeetState.meetState.flags or tostring(carMeetState.meetState.flags.saleInventoryId) ~= tostring(inventoryId) then return end
  if carMeetState.meetState.active and carMeetState.meetState.flags and tostring(carMeetState.meetState.flags.saleInventoryId) == tostring(inventoryId) then
    carMeetState.meetState.flags.playerSoldSaleVehicle = true
  end
  if carMeetState.meetState.active and carMeetState.meetState.type == "BAZAAR" and tostring(carMeetState.meetState.flags.bazaarInventoryId) == tostring(inventoryId) then
    ui_message("Bazaar sale complete.", 5, "info", "info")
    statePush.send('onCarMeetOverview', callbacks.getCarMeetOverview())
  end
  if gameplay_rawPois and gameplay_rawPois.clear then
    gameplay_rawPois.clear()
  end
  M.addTransactionReputation("sell", salePrice, marketValue, inventoryId, soldVehicle)
end

-- Sale offers -------------------------------------------------------------------------------------
local function getMeetSaleOfferData()
  return parts.invites.buildMeetSaleOverviewPayload(true)
end
local function setMeetSaleAskingPrice(value)
  if not carMeetState.meetState.active or not carMeetState.meetState.flags then return false end
  local listing = carMeetState.meetState.flags.saleListing or parts.sales.ensureMeetSaleState(carMeetState.meetState)
  if not listing then return false end
  local marketValue = math.max(tonumber(listing.marketValue) or 0, 50)
  local minPrice = math.max(50, marketValue * 0.5)
  local maxPrice = math.max(minPrice, marketValue * 2.0)
  local askingPrice = math.floor((math.max(minPrice, math.min(maxPrice, tonumber(value) or marketValue)) + 25) / 50) * 50
  listing.value = askingPrice
  statePush.send('onCarMeetOverview', callbacks.getCarMeetOverview())
  guihooks.trigger('onCarMeetSaleOfferData', getMeetSaleOfferData())
  return getMeetSaleOfferData()
end
local function openMeetSaleOffers()
  -- only open while the showcase is live; an already open screen still receives the expired list
  local data = parts.invites.buildMeetSaleOverviewPayload()
  if not data then
    ui_message("Bring a vehicle to the meet during showcase to receive offers.", 5, "info", "info")
    return false
  end
  extensions.ui_router.navigate('carMeetOffers')
  core_jobsystem.create(function(job)
    job.sleep(0.1)
    guihooks.trigger('onCarMeetSaleOfferData', getMeetSaleOfferData() or data)
  end)
  return true
end
local function requestMeetSaleOfferData()
  guihooks.trigger('onCarMeetSaleOfferData', getMeetSaleOfferData())
end
local function acceptBazaarOffer(offerIndex)
  return M.acceptCarMeetOfferWithValue(offerIndex)
end
local function acceptCarMeetOfferWithValue(offerIndex, negotiatedValue)
  if not carMeetState.meetState.active or not carMeetState.meetState.flags or not callbacks.canPlayerSellAtMeet(carMeetState.meetState) then return false end
  local inventoryId = carMeetState.meetState.flags.saleInventoryId
  local listing = carMeetState.meetState.flags.saleListing or parts.sales.ensureMeetSaleState(carMeetState.meetState)
  local offers = carMeetState.meetState.flags.saleOffers or {}
  offerIndex = tonumber(offerIndex)
  local offer = offerIndex and offers[offerIndex]
  if not inventoryId or not listing or not offer then return false end
  if offer.expiredViewCounter ~= nil then return false end

  local salePrice = tonumber(negotiatedValue) or tonumber(offer.value) or 0
  local soldVehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  if not overhaul_career_garage_inventory.sellVehicle(inventoryId, salePrice) then
    ui_message("This vehicle can't be sold right now.", 5, "warning", "warning")
    return false
  end
  table.remove(offers, offerIndex)
  carMeetState.meetState.flags.playerSoldSaleVehicle = true
  if carMeetState.meetState.type == "BAZAAR" then
    ui_message("Bazaar sale complete.", 5, "info", "info")
  else
    ui_message("Vehicle sold to a car meet buyer.", 5, "info", "info")
  end
  M.addTransactionReputation("sell", salePrice, listing.marketValue, inventoryId, soldVehicle)
  if gameplay_rawPois and gameplay_rawPois.clear then
    gameplay_rawPois.clear()
  end
  statePush.send('onCarMeetOverview', callbacks.getCarMeetOverview())
  return true
end
local function declineBazaarOffer(offerIndex)
  if not carMeetState.meetState.active or not carMeetState.meetState.flags then return false end
  local offers = carMeetState.meetState.flags.saleOffers or {}
  offerIndex = tonumber(offerIndex)
  if not offerIndex or not offers[offerIndex] then return false end
  table.remove(offers, offerIndex)
  statePush.send('onCarMeetOverview', callbacks.getCarMeetOverview())
  return true
end
local function disableCarMeetOfferNegotiation(offerIndex)
  if not carMeetState.meetState.active or not carMeetState.meetState.flags then return false end
  local offers = carMeetState.meetState.flags.saleOffers or {}
  offerIndex = tonumber(offerIndex)
  if not offerIndex or not offers[offerIndex] then return false end
  offers[offerIndex].negotiationPossible = false
  statePush.send('onCarMeetOverview', callbacks.getCarMeetOverview())
  return true
end
local function negotiateBazaarOffer(offerIndex)
  if not carMeetState.meetState.active or not carMeetState.meetState.flags then return false end
  local listing = carMeetState.meetState.flags.saleListing or parts.sales.ensureMeetSaleState(carMeetState.meetState)
  local offers = carMeetState.meetState.flags.saleOffers or {}
  offerIndex = tonumber(offerIndex)
  local offer = offerIndex and offers[offerIndex]
  if not listing or not offer then return false end
  if offer.expiredViewCounter ~= nil then return false end
  overhaul_career_garage_inventory.getVehicleNegotiationService().startBuyingOffer({
    inventoryId = carMeetState.meetState.flags.saleInventoryId,
    niceName = (listing.niceName and core_locales.translateWithOrWithoutContext(listing.niceName)) or listing.niceName,
    thumbnail = listing.thumbnail,
    value = listing.value,
    marketValue = listing.marketValue
  }, offer, offerIndex)
  return true
end
local function startPurchaseOffer(shopId)
  shopId = tonumber(shopId)
  if not shopId then return false end
  if not carMeetState.meetState.active then
    ui_message("No active car meet purchase opportunity.", 5, "warning", "warning")
    return false
  end
  if not overhaul_career_garage_inventory.getVehicleShoppingService().canPurchase(true) then
    return false
  end
  overhaul_career_garage_inventory.getVehicleNegotiationService().startSellingOffer(shopId)
  return true
end

-- Purchase ----------------------------------------------------------------------------------------

local function getCarMeetPurchaseEntry(shopId)
  shopId = tonumber(shopId)
  if not shopId then return nil end
  for _, entry in ipairs(carMeetState.carMeetPurchaseVehicles) do
    if tonumber(entry.shopId) == shopId then
      return entry
    end
  end
  return nil
end

local function getCarMeetVehicleIdForShopId(shopId)
  local entry = getCarMeetPurchaseEntry(shopId)
  return entry and entry.vehicleId or nil
end

-- Paint names come from the purchase entry first, then from the shop vehicle info.
local function resolveCarMeetPaintNames(shopId, shopVehicleInfo)
  local entry = getCarMeetPurchaseEntry(shopId)
  if entry and type(entry.paintNames) == "table" and entry.paintNames[1] then
    return entry.paintNames, entry.modelKey
  end
  if shopVehicleInfo and type(shopVehicleInfo.paintNames) == "table" and shopVehicleInfo.paintNames[1] then
    local modelKey = shopVehicleInfo.model_key or shopVehicleInfo.modelKey
    return shopVehicleInfo.paintNames, modelKey
  end
  return nil, entry and entry.modelKey or shopVehicleInfo and (shopVehicleInfo.model_key or shopVehicleInfo.modelKey)
end

local function snapshotCarMeetVehicleForPurchase(vehId)
  vehId = tonumber(vehId)
  if not vehId then return false end
  local vehicleData = core_vehicle_manager.getVehicleData(vehId)
  if not vehicleData or type(vehicleData.config) ~= "table" then return false end
  vehicleData.config = deepcopy(vehicleData.config)
  return true
end

local function prepareCarMeetVehicleForPurchase(shopId, shopVehicleInfo)
  shopId = tonumber(shopId)
  if not shopId then return nil end
  local vehId = getCarMeetVehicleIdForShopId(shopId)
  if not vehId or not getObjectByID(vehId) then return nil end

  local paintNames, modelKey = resolveCarMeetPaintNames(shopId, shopVehicleInfo)
  if paintNames then
    parts.sales.applyRandomPaintToSpawnedVehicle(vehId, paintNames, modelKey)
  end
  snapshotCarMeetVehicleForPurchase(vehId)
  return vehId
end

-- Sold cars are deleted; kept cars are parked and handed to the player.
local function onCarMeetVehiclePurchased(shopId, keepVehicle)
  shopId = tonumber(shopId)
  if not shopId then return end
  for i = #carMeetState.carMeetPurchaseVehicles, 1, -1 do
    local entry = carMeetState.carMeetPurchaseVehicles[i]
    if tonumber(entry.shopId) == shopId then
      local veh = entry.vehicleId and getObjectByID(entry.vehicleId)
      if veh and not keepVehicle then
        gameplay_traffic.removeTraffic(entry.vehicleId)
        veh:delete()
      elseif veh and keepVehicle then
        gameplay_traffic.removeTraffic(entry.vehicleId)
        veh.playerUsable = true
        veh:queueLuaCommand('ai.setMode("disabled")')
        veh:queueLuaCommand('electrics.setIgnitionLevel(0)')
        veh:queueLuaCommand('if electrics.setLightsState then electrics.setLightsState(0) end')
        veh:queueLuaCommand('if electrics.set_warn_signal then electrics.set_warn_signal(0) end')
      end
      for j = #carMeetState.spawnedMeetVehicles, 1, -1 do
        if tonumber(carMeetState.spawnedMeetVehicles[j]) == tonumber(entry.vehicleId) then
          table.remove(carMeetState.spawnedMeetVehicles, j)
          break
        end
      end
      table.remove(carMeetState.carMeetPurchaseVehicles, i)
      break
    end
  end
  if gameplay_rawPois and gameplay_rawPois.clear then
    gameplay_rawPois.clear()
  end
  statePush.send('onCarMeetOverview', callbacks.getCarMeetOverview())
end

-- Showcase markers and activity -------------------------------------------------------------------
local function isWalkingForMeetInteraction()
  -- Walking and POI extensions can be absent while the level is being unloaded.
  return gameplay_walk and gameplay_walk.isWalking() == true
end
local function getMeetVehiclePoiPosition(entry)
  local veh = entry and entry.vehicleId and getObjectByID(entry.vehicleId)
  if veh then return veh:getPosition() end
  return entry and entry.pos or nil
end
local function getPlayerSalePoiPosition()
  -- Prefer the meet parking spot so the offers pin cannot follow the player vehicle around the map.
  if carMeetState.meetState.playerSpot and carMeetState.meetState.playerSpot.pos then
    return vec3(carMeetState.meetState.playerSpot.pos)
  end
  local veh = carMeetState.meetState.flags and carMeetState.meetState.flags.saleVehicleId and getObjectByID(carMeetState.meetState.flags.saleVehicleId)
  if veh then return veh:getPosition() end
  return nil
end
local function onGetRawPoiListForLevel(levelIdentifier, elements)
  if not overhaul_career_career.isActive() or not carMeetState.meetState.active or carMeetState.meetState.phase ~= "showcase" then return end

  for _, entry in ipairs(carMeetState.carMeetPurchaseVehicles or {}) do
    local pos = getMeetVehiclePoiPosition(entry)
    if pos then
      table.insert(elements, {
        id = "inspectVehicleMarker##carMeetPurchaseVehicle-" .. tostring(entry.shopId),
        data = {
          type = "carMeetPurchaseVehicle",
          shopId = entry.shopId,
          name = entry.name,
          sellerName = entry.sellerName
        },
        markerInfo = {
          inspectVehicleMarker = {
            pos = pos,
            radius = entry.markerRadius or 5,
            vehicleHeight = 4
          }
        }
      })
    end
  end

  if callbacks.canPlayerSellAtMeet(carMeetState.meetState) then
    local pos = getPlayerSalePoiPosition()
    if pos then
      local offers = carMeetState.meetState.flags.saleOffers or {}
      table.insert(elements, {
        id = "inspectVehicleMarker##carMeetPlayerSaleOffers-" .. tostring(carMeetState.meetState.flags.saleInventoryId),
        data = {
          type = "carMeetPlayerSaleOffers",
          inventoryId = carMeetState.meetState.flags.saleInventoryId,
          offerCount = #offers
        },
        markerInfo = {
          inspectVehicleMarker = {
            pos = pos,
            radius = 5,
            vehicleHeight = 4
          }
        }
      })
    end
  end
end
local function onActivityAcceptGatherData(elemData, activityData)
  if not carMeetState.meetState.active or carMeetState.meetState.phase ~= "showcase" then return end
  if not isWalkingForMeetInteraction() then return end

  for _, elem in ipairs(elemData or {}) do
    if elem.type == "carMeetPurchaseVehicle" then
      local blockReason = overhaul_career_garage_inventory.getVehicleShoppingService().getPurchaseBlockReason() or nil
      local props = {
        {
          icon = "person",
          keyLabel = "Seller",
          valueLabel = elem.sellerName or "Car Meet Owner"
        }
      }
      if blockReason then
        table.insert(props, {
          icon = "abandon",
          keyLabel = "Garage",
          valueLabel = blockReason
        })
      end
      table.insert(activityData, {
        icon = "carDealer",
        heading = elem.name or "Meet Vehicle",
        preheadings = {"Car Meet Sale"},
        sorting = {
          type = elem.type,
          id = elem.shopId
        },
        props = props,
        buttonLabel = "Make an Offer",
        startable = blockReason == nil,
        disableReason = blockReason,
        buttonFun = function() startPurchaseOffer(elem.shopId) end
      })
    elseif elem.type == "carMeetPlayerSaleOffers" then
      table.insert(activityData, {
        icon = "dialogOutline",
        heading = "Offers on Your Car",
        preheadings = {"Car Meet Buyers"},
        sorting = {
          type = elem.type,
          id = elem.inventoryId
        },
        props = {
          {
            icon = "dialogOutline",
            keyLabel = "Offers",
            valueLabel = tostring(elem.offerCount or 0)
          }
        },
        buttonLabel = "View Offers",
        buttonFun = openMeetSaleOffers
      })
    end
  end
end

-- Lifecycle ---------------------------------------------------------------------------------------
local function subscribeVehicleSales()
  if disposeSaleObserver then disposeSaleObserver() end
  disposeSaleObserver = overhaul_career_garage_inventory.subscribeVehicleSales("carmeets", onMarketplaceVehicleSold)
end

local function onExtensionLoaded()
  log("D", "carmeets", "Carmeets module initialized")
  carMeetState.careerActive = overhaul_career_career and overhaul_career_career.isActive() or false
  if carMeetState.careerActive then subscribeVehicleSales() end
  if gameplay_rawPois and gameplay_rawPois.clear then
    gameplay_rawPois.clear()
  end
end
local function onOverhaulActive(active)
  carMeetState.careerActive = active
  if active then
    subscribeVehicleSales()
  end
  if not active then
    local ownership = capabilities.get("groundMarkerOwnership")
    if ownership then ownership.release("carmeets") end
    persist.reset()
  elseif overhaul_career_career.isActive() then
    persist.load(nil)
  end
end
local function releaseMeetVehicles()
  if carMeetState.meetState.active or #carMeetState.spawnedMeetVehicles > 0 or carMeetState.previousTrafficAmount then
    local ok, err = pcall(parts.invites.cleanupPreviousMeet)
    if not ok then
      log('W', 'carmeets', 'Cleanup on unload failed: ' .. tostring(err))
    end
  end
end
-- Attendees must be gone before a Lua reload serializes stock traffic and checkpoints; career stop and every other unload still clean up in onExtensionUnloaded.
local disposeTemporaryVehicles = require('overhaul/lib/vehicles/temporary').declare('carMeets', releaseMeetVehicles)
-- Career modules unload before onOverhaulActive(false).
local function onExtensionUnloaded()
  if disposeSaleObserver then disposeSaleObserver() end
  disposeSaleObserver = nil
  local ownership = capabilities.get("groundMarkerOwnership")
  if ownership then ownership.release("carmeets") end
  disposeTemporaryVehicles()
  releaseMeetVehicles()
end

M.markSceneRepDirty = persist.markDirty

-- Public API --------------------------------------------------------------------------------------
function M.debugAdjustReputation(amount)
  overhaul_career_carmeets_reputation.addReputation(tonumber(amount) or 0, "debug adjustment")
  require("overhaul/lib/save/store").request("carmeets:debugAdjustReputation")
  statePush.send('onCarMeetOverview', callbacks.getCarMeetOverview())
  return callbacks.getCarMeetOverview()
end
M.requestRSVPData = function()
  statePush.send('onCarMeetOverview', callbacks.getCarMeetOverview())
end
function M.notifyOnPhoneAppInstalled()
  if not overhaul_career_career.isActive() then
    return
  end
  if #carMeetState.pendingInvites == 0 then
    return
  end
  parts.meetTypesPart.firePhoneLockNotification(carMeetState.pendingInvites[#carMeetState.pendingInvites])
end

-- Game hooks and exports --------------------------------------------------------------------------
M.onOverhaulSaveCurrentProfile = persist.saveCurrentProfile
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onWorldReadyState = parts.flow.onWorldReadyState
M.onUpdate = onUpdate
M.onOverhaulActive = onOverhaulActive
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel
M.onActivityAcceptGatherData = onActivityAcceptGatherData
M.checkAvailableMeets = parts.flow.checkAvailableMeets
M.rsvpToMeet = parts.rsvp.rsvpToMeet
M.decline = parts.rsvp.decline
M.cancelRSVP = parts.rsvp.cancelRSVP
M.setRoute = parts.rsvp.setRoute
M.debugGenerateInvite = parts.flow.generateInviteNow
M.debugGenerateInviteOfType = parts.rsvp.generateInviteOfType
M.debugClearInvites = parts.rsvp.clearPendingInvites
M.debugAccelerateInvite = parts.rsvp.debugAccelerateInvite
M.debugDumpState = parts.rsvp.dumpDebugState
M.joinClub = parts.invites.joinClub
M.leaveClub = parts.invites.leaveClub
M.onMarketplaceVehicleSold = onMarketplaceVehicleSold
M.acceptBazaarOffer = acceptBazaarOffer
M.acceptCarMeetOfferWithValue = acceptCarMeetOfferWithValue
M.declineBazaarOffer = declineBazaarOffer
M.disableCarMeetOfferNegotiation = disableCarMeetOfferNegotiation
M.negotiateBazaarOffer = negotiateBazaarOffer
M.requestMeetSaleOfferData = requestMeetSaleOfferData
M.setMeetSaleAskingPrice = setMeetSaleAskingPrice
M.openMeetSaleOffers = openMeetSaleOffers
M.getCarMeetVehicleIdForShopId = getCarMeetVehicleIdForShopId
M.prepareCarMeetVehicleForPurchase = prepareCarMeetVehicleForPurchase
M.snapshotCarMeetVehicleForPurchase = snapshotCarMeetVehicleForPurchase
M.onCarMeetVehiclePurchased = onCarMeetVehiclePurchased

-- Inventory sale-source contract ------------------------------------------------------------------

-- Project live public handlers so optional methods and replacements retain their call-time meaning.
function M.getVehicleSaleSource()
  return {
    acceptOffer = M.acceptCarMeetOfferWithValue,
    disableOfferNegotiation = M.disableCarMeetOfferNegotiation,
    preparePurchase = M.prepareCarMeetVehicleForPurchase,
    getWorldVehicleId = M.getCarMeetVehicleIdForShopId,
    snapshotPurchase = M.snapshotCarMeetVehicleForPurchase,
    onPurchased = M.onCarMeetVehiclePurchased,
    awardTransaction = M.addTransactionReputation,
  }
end

M.activity = require('overhaul/career/carmeets/carmeets/activity')(M)
return M
