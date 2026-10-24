-- Bus route state, passenger boarding, stop rewards and shift settlement for one career.
-- Read config and state, named parts, route phases, frame update, public controls and hooks.
local recordRoute = require("overhaul/lib/progression/logbookFeed").register("overhaul.busRouteCompleted", {
  title = "Bus route completed", label = "Jobs", icon = "bus"
}, "jobs/bus.lua")

local M = {}
local shared = {}
local parts = {}
M.dependencies = {'overhaul_vehicles_passengerOccupants', 'overhaul_integration_patches_groundMarkerOwnership'}

local core_groundMarkers = require('core/groundMarkers')
local core_vehicles = require('core/vehicles')
local jobSkillRewards = require('overhaul/lib/jobs/skillRewards')
local capabilities = require('overhaul/lib/platform/capabilities')
local facilityRole = require('overhaul/lib/logistics/facilityRole')

local BUS_REWARD_CONFIG_PATH = "gameplay/overhaul/bus/rewardConfig.json"
local BUS_SKILL_PATH_IDS = {"careerSkills-passenger", "passenger"}
local SUBCONTRACTOR_MIN_BUS_SKILL_LEVEL = 20
local PLAYER_OWNED_BUS_DECLINE_MSG = "Player owned bus requires level 20"
local MARKER_OWNER = 'bus'
local COUNTDOWN_TICK = 2 -- seconds per passenger in the boarding countdown

-- Config ------------------------------------------------------------------------------------------

local config = {
  baseFare = 600,
  rewardMultiplier = 0.5,
  tipMultiplier = 20,
  dwellDurationBase = 10,
  stopSettleDelay = 2.5,
  accelThreshold = 3.5,
  routeCooldown = 10,
  reputationDivisor = 500,
  -- Org thresholds are logistics-sized; scale bus rep so routes feel rewarding.
  reputationMultiplier = 30,
  bonusMultiplierBase = 1,
  bonusMultiplierFactor = 3,
  tipBaseScore = 8,
  tipPerPassengerMultiplier = 2,
  roughRidePenaltyMultiplier = 10,
  loopBonusFactor = 0.5,
  stopVelocityThreshold = 0.5,
  -- Few-stop routes (long legs, limited stops): mileage pay when #stopTriggers < this; $/mile before economy/reward multipliers.
  limitedStopsRouteMaxStops = 5,
  payPerMile = 600,
  metersPerMile = 1609.344,
  odometerMaxStepMeters = 400,
  loopCompletionXpPerStop = 8,
  loopCompletionTipReference = 400,
}

-- State -------------------------------------------------------------------------------------------

local currentStopIndex = nil
local stopTriggers = {}
local dwellTimer = nil
local dwellDuration = config.dwellDurationBase
local tipDwellReference = config.dwellDurationBase
local consecutiveStops = 0
local currentRouteActive = false
local routePaused = false
local accumulatedReward = 0
local passengersOnboard = 0
local activeBusID = nil
local currentBusOrgId = nil
local routeInitialized = false
local totalStopsCompleted = 0
local routeCooldown = 0
local currentVehiclePartsTree = nil
local stopMonitorActive = false

local stopSettleTimer = 0
local stopSettleDelay = config.stopSettleDelay
local currentTriggerName = nil
local roughRide = 0
local lastVelocity = nil
local tipTotal = 0
local loopTipBaseline = 0
local loopRewardBaseline = 0
local trueBoarding = 0
local trueDeboarding = 0
local boardingCoroutine = nil
local currentFinalStopName = nil
local stopIndexWhereBoardingStarted = nil
local pendingRouteInit = false
local isCalculatingRoute = false
local routeCalcTimer = 0
local uiUpdateTimer = 0
local currentRouteName = nil
local stopDisplayNames = {}
local routeItems = {}

local currentLoanerCut = 0
local routeOdometerMeters = 0
local lastOdometerPos = nil
local endingShift = false
local routeSessionId = nil
local routeSessionSequence = 0
local seatSetupVehId = nil
local busRewardConfig = nil
local countdownSeats = nil

-- Parts -------------------------------------------------------------------------------------------

parts.stopMarkers = require('overhaul/jobs/bus/stopMarkers')()
parts.seats = require('overhaul/jobs/bus/seats')()
parts.routeConfig = require('overhaul/jobs/bus/routeConfig')()
parts.routePath = require('overhaul/jobs/bus/routePath')(core_groundMarkers, function()
  return currentStopIndex, routeItems, stopTriggers
end)

-- Passengers outside the bus: waiting at the stop, walking in and out with the countdown (visual only).
local paxWalkers = require('overhaul/jobs/bus/paxWalkers')({stop = function()
  if not currentStopIndex or not stopTriggers or not stopTriggers[currentStopIndex] then return nil end
  return currentStopIndex, stopTriggers[currentStopIndex], stopTriggers[currentStopIndex % #stopTriggers + 1]
end, isCurrent = function()
  local loaded = rawget(_G, 'overhaul_jobs_bus')
  return loaded == nil or loaded == M
end})

-- Skill rewards -----------------------------------------------------------------------------------

local function getBusRewardConfig()
  if busRewardConfig ~= nil then
    return busRewardConfig
  end
  busRewardConfig = jobSkillRewards.loadRewardConfig(BUS_REWARD_CONFIG_PATH)
  return busRewardConfig
end

local function getBusSkillContext()
  local skillConfig = jobSkillRewards.getSkillConfig(getBusRewardConfig())
  local attributeKey = jobSkillRewards.getAttributeKey(skillConfig, "careerSkills-passenger")
  local skillLevel = jobSkillRewards.getSkillLevel(attributeKey, BUS_SKILL_PATH_IDS)
  return skillConfig, attributeKey, skillLevel
end

local function awardBusSkillXp(attributeKey, amount, reason, flatReward)
  if not amount or amount <= 0 then return end
  if not (overhaul_career_career and overhaul_career_career.isActive()) then return end
  local payment = overhaul_career_economy_payment

  local rewardData = {[attributeKey] = {amount = amount}}
  overhaul_career_economy_difficultyMode.scalePaymentRewardData(rewardData, {includeMoney = false})
  -- Stop XP falls back only for this guard; removed XP still posts an empty change.
  local awarded = (rewardData[attributeKey] and rewardData[attributeKey].amount) or (flatReward and 0 or amount)
  if awarded <= 0 then return end
  if not rewardData[attributeKey] then
    -- Removed XP still posts one empty change without checking the payout result.
    payment.payout({xp = rewardData, reason = reason or {}, fullReward = true, allowEmpty = true})
    return
  end
  local accepted, problem = payment.payout({xp = {[attributeKey] = awarded}, reason = reason, fullReward = true})
  if accepted ~= true then
    -- Stops are already committed at this boundary; retrying would duplicate route work.
    log('W', 'bus', 'Skill payout refused: ' .. tostring(problem))
  end
end

-- Loaner vehicles and organizations ---------------------------------------------------------------

local function isLoanerVehicle(vehId)
  if not vehId or not (overhaul_career_career and overhaul_career_career.isActive()) then
    return false
  end
  local loaningOrgs = capabilities.get('vehicleLoans').getLoaningOrgsOfVehicle(vehId)
  return loaningOrgs ~= nil and next(loaningOrgs) ~= nil
end

local function isOffroadRecoveryTarget(vehId)
  return overhaul_jobs_recovery.blocksJobShifts(vehId) == true
end

-- Capture the route's organization so exit settlement cannot pay a new provider.
local function getBusOrganizationId(vehId, binding)
  vehId = vehId or activeBusID or be:getPlayerVehicleID(0)
  local loaningOrgs
  if vehId and overhaul_career_career and overhaul_career_career.isActive() then
    loaningOrgs = capabilities.get('vehicleLoans').getLoaningOrgsOfVehicle(vehId)
  end
  local emp = overhaul_career_work_employment
  local shift = not (binding and (binding.organizationId ~= nil or binding.facilityId))
    and emp and emp.isRoleplayShift() and emp.getUiState()
  local employer = shift and {facilityId = shift.homeFacId, organizationId = shift.employerOrgId}
  local orgId = facilityRole.operator("bus", loaningOrgs, binding, employer)
  if not orgId then log("W", "bus", "Bus operator unavailable: route, employer and vehicle have no local operator binding") end
  return orgId
end

local function canStartBusShift(vehId)
  if isOffroadRecoveryTarget(vehId) then
    return false
  end
  local emp = overhaul_career_work_employment
  if emp and emp.blocksRoleplay() then
    ui_message("Finish your company shift before starting bus work.", 6, "warning")
    return false
  end
  if isLoanerVehicle(vehId) then
    return true
  end
  if not jobSkillRewards.isPlayerOwnedInventoryVehicle(vehId) then
    return true
  end
  local _, _, skillLevel = getBusSkillContext()
  if skillLevel >= SUBCONTRACTOR_MIN_BUS_SKILL_LEVEL then
    return true
  end
  ui_message(PLAYER_OWNED_BUS_DECLINE_MSG, 8, "error", "error")
  return false
end

-- Navigation ownership ----------------------------------------------------------------------------

local function syncGroundMarkerClaim()
  local ownership = rawget(_G, 'overhaul_integration_patches_groundMarkerOwnership')
  if not ownership then return end
  if currentRouteActive == true or stopMonitorActive == true or pendingRouteInit == true then
    ownership.claim(MARKER_OWNER)
  else
    ownership.release(MARKER_OWNER)
  end
end

-- Seats and capacity ------------------------------------------------------------------------------

-- The countdown changes drawn seats only; passenger claims change when the stop commits.
local function showCountdownSeats(vehicle, count)
  if count == countdownSeats then return end
  countdownSeats = count
  overhaul_vehicles_passengerOccupants.display('bus', vehicle:getID(), count)
end

-- Malformed parts fall back to 20 so a bus can still admit a route.
local function calculateSeatingCapacity()
  local fallbackCapacity = 20
  if not currentVehiclePartsTree then
    return fallbackCapacity
  end
  if type(currentVehiclePartsTree) ~= "table" then
    log('W', 'bus', "Warning: currentVehiclePartsTree is not a table, using fallback capacity")
    return fallbackCapacity
  end
  local success, result = pcall(parts.seats.cyclePartsTree, {currentVehiclePartsTree}, 0)
  if not success then
    log('W', 'bus', string.format("Warning: Error calculating seating capacity: %s", tostring(result)))
    return fallbackCapacity
  end
  return math.max(1, result or fallbackCapacity)
end

-- Clear the cached parts tree before requesting the replacement vehicle response.
local function retrievePartsTree()
  currentVehiclePartsTree = nil
  local vehicle = be:getPlayerVehicle(0)
  if vehicle then
    vehicle:queueLuaCommand([[
      local partsTree = v.config.partsTree
      obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(]] .. require('overhaul/lib/vehicles/callbacks').open('busPartsTree', {owner = 'bus', vehId = vehicle:getID()}) .. [[, 'busPartsTree', serialize(partsTree)))
  ]])
  end
end

-- Legacy buses without occupant slots keep their part-based capacity.
local function estimateCapacityFromParts(partsTree)
  local capacity = math.max(1, calculateSeatingCapacity())

  local capOverrides = {
    ["schoolbus_interior_b"] = 24,
    ["schoolbus_interior_c"] = 40,
    ["prisonbus"] = 20,
    ["citybus_seats"] = 34,
    ["citybus"] = 34,
    ["dm_vanbus"] = 24,
    ["vanbus"] = 24,
    ["van_bus"] = 24,
    ["vanbusframe"] = 24
  }

  local capOverride = nil
  local function checkPartTreeForKeywords(tree)
    if capOverride then return end
    for k, v in pairs(tree) do
      if type(k) == "string" then
        local name = string.lower(k)
        for pattern, capacity in pairs(capOverrides) do
          if name:find(pattern) then
            capOverride = capacity
            log('D', 'bus', string.format("%s detected via partsTree → capacity %d", pattern, capacity))
            return
          end
        end
      end
      if type(v) == "table" then
        checkPartTreeForKeywords(v)
        if capOverride then return end
      end
    end
  end

  checkPartTreeForKeywords(partsTree)

  if capOverride then
    return capOverride
  elseif capacity <= 12 then
    log('D', 'bus', "Generic or van-based transport detected → fallback capacity 12")
    return 12
  end
  return capacity
end

-- Fit occupant slots before route initialization so visible seats and capacity agree.
local function returnPartsTree(partsTree)
  currentVehiclePartsTree = partsTree
  local vehicle = be:getPlayerVehicle(0)
  local vehId = vehicle and vehicle:getID()
  local occupants = overhaul_vehicles_passengerOccupants
  local seatSlots = occupants and occupants.scanSeatSlots(partsTree)

  if pendingRouteInit and vehId and vehId == activeBusID and seatSlots and #seatSlots.empty > 0
    and seatSetupVehId ~= vehId then
    seatSetupVehId = vehId
    local stationary = vehicle:getVelocity():length() < 1
    local filling = stationary and occupants.fillEmptySeatSlots(vehId, partsTree, retrievePartsTree)
    if filling then
      ui_message(string.format("Fitting %d passenger seats...", filling), 3, "info", "bus")
      return
    end
  end

  local seatCapacity = seatSlots and occupants.countPassengerSeats(vehId, seatSlots.total) or 0
  M.vehicleCapacity = seatCapacity > 0 and seatCapacity or estimateCapacityFromParts(partsTree)

  log('D', 'bus', string.format("Vehicle seating capacity detected: %d seats", M.vehicleCapacity))
  ui_message(string.format("Vehicle seating capacity detected: %d passengers.", M.vehicleCapacity), 5, "info", "info")

  if pendingRouteInit then
    pendingRouteInit = false
    syncGroundMarkerClaim()
    local vehicle = be:getPlayerVehicle(0)
    if vehicle and canStartBusShift(vehicle:getID()) then
      shared.initRoute()
    end
  end
end

-- Stop markers and guidance -----------------------------------------------------------------------

-- The current stop owns its perimeter until navigation advances.
local function showCurrentStopMarkers(stopIndex)
  local targetStopIndex = stopIndex or currentStopIndex
  if not targetStopIndex or not stopTriggers or not stopTriggers[targetStopIndex] then
    log('D', 'bus', "showCurrentStopMarkers: Invalid stop index or triggers")
    return
  end

  local currentTrigger = stopTriggers[targetStopIndex]
  local triggerName = currentTrigger:getName() or "unknown"
  log('D', 'bus', string.format("Showing markers for stop %d: %s", targetStopIndex, triggerName))
  parts.stopMarkers.createStopPerimeter(currentTrigger)
end

shared.isBus = function(vehicle)
  if not vehicle then return false end
  local plate = core_vehicles.getVehicleLicenseText(vehicle)
  return plate and plate:upper() == "BUS"
end

local function getNextTrigger()
  if not currentStopIndex then
    return nil
  end
  return stopTriggers[currentStopIndex]
end

local function showNextStopMarker(targetStopIndex)
  local nextStopIndex = targetStopIndex
  if not nextStopIndex then
    nextStopIndex = (currentStopIndex or 1) + 1
    if nextStopIndex > #stopTriggers then
      nextStopIndex = 1
    end
  end

  local trigger = stopTriggers[nextStopIndex]
  if not trigger then
    return
  end

  core_groundMarkers.resetAll()
  local vehicle = be:getPlayerVehicle(0)
  local targetPos = trigger:getPosition()

  if vehicle then
    local fromStopIndex = nextStopIndex - 1
    if fromStopIndex < 1 then
      fromStopIndex = #stopTriggers
    end

    local pathPoints = parts.routePath.buildPathToStop(nextStopIndex, vehicle:getPosition(), fromStopIndex)
    if #pathPoints == 1 then
      pathPoints[2] = targetPos
    end

    parts.routePath.setupRoutePlannerWithWaypoints(pathPoints, targetPos)
  else
    core_groundMarkers.setPath(targetPos, {clearPathOnReachingTarget = false})
  end

  showCurrentStopMarkers(nextStopIndex)
end

-- Waypoints stay ordered between stops; a missing vehicle uses the direct route.
local function setupRouteNavigation(vehicle, targetPos, targetStopIndex)
  if not vehicle then
    core_groundMarkers.setPath(targetPos, {clearPathOnReachingTarget = false})
    return
  end

  local pathPoints = parts.routePath.buildPathToStop(targetStopIndex, vehicle:getPosition())
  if #pathPoints == 1 then
    pathPoints[2] = targetPos
  end

  parts.routePath.setupRoutePlannerWithWaypoints(pathPoints, targetPos)
end

-- Boarding ----------------------------------------------------------------------------------------

-- An interrupted attempt restores its drawn seats before another stop can commit passengers.
local function cancelBoardingAttempt(restoreMarkers)
  local hadAttempt = stopIndexWhereBoardingStarted ~= nil or dwellTimer ~= nil or boardingCoroutine ~= nil
  if hadAttempt then
    local vehicle = activeBusID and be:getObjectByID(activeBusID)
    if vehicle then core_vehicleBridge.executeAction(vehicle, 'setFreeze', false) end
  end
  dwellTimer = nil
  boardingCoroutine = nil
  stopMonitorActive = false
  syncGroundMarkerClaim()
  stopSettleTimer = 0
  stopIndexWhereBoardingStarted = nil
  trueBoarding, trueDeboarding = 0, 0
  -- The countdown's seats were provisional too: the committed passengers show again.
  if countdownSeats ~= nil and overhaul_vehicles_passengerOccupants then
    overhaul_vehicles_passengerOccupants.displayRestore('bus')
  end
  countdownSeats = nil
  if hadAttempt then paxWalkers.stopCancelled() end
  if hadAttempt and restoreMarkers and currentRouteActive then showCurrentStopMarkers() end
end

-- Final or ending-shift stops only unload; ordinary stops draw counts before the animation starts.

local function animateBoarding(vehicle)
  core_vehicleBridge.executeAction(vehicle, 'setFreeze', true)
  paxWalkers.stopStarted(vehicle:getID(), trueDeboarding, trueBoarding, COUNTDOWN_TICK)

  local function waitForAnimation(duration)
    local t = 0
    while t < duration do
      local dt = coroutine.yield()
      t = t + (dt or 0.033)
    end
  end

  if trueDeboarding > 0 then
    for i = trueDeboarding, 1, -1 do
      ui_message(string.format("Stop %d\nDeboarding: %d\nBoarding: 0", currentStopIndex, i), 2, "bus",
        "bus_anim")
      showCountdownSeats(vehicle, parts.seats.whileLeaving(passengersOnboard, trueDeboarding, i))
      paxWalkers.passengerLeft()
      waitForAnimation(COUNTDOWN_TICK)
    end
  else
    ui_message(string.format("Stop %d\nDeboarding: 0\nBoarding: 0", currentStopIndex), 1, "bus",
      "bus_anim")
  end

  if trueBoarding > 0 then
    for i = 1, trueBoarding do
      ui_message(string.format("Stop %d\nDeboarding: 0\nBoarding: %d", currentStopIndex, i), 2, "bus",
        "bus_anim")
      -- the passenger walks in during the tick and sits down as it ends
      waitForAnimation(COUNTDOWN_TICK)
      showCountdownSeats(vehicle, parts.seats.whileBoarding(passengersOnboard, trueDeboarding, i,
        M.vehicleCapacity))
      paxWalkers.passengerBoarded(i)
    end
  else
    ui_message(string.format("Stop %d\nDeboarding: 0\nBoarding: 0", currentStopIndex), 1, "bus",
      "bus_anim")
  end
end

local function beginStopBoarding(vehicle, trigger)
  dwellTimer = 0
  stopIndexWhereBoardingStarted = currentStopIndex
  parts.stopMarkers.hideStopMarkers()

  local triggerName = trigger:getName() or ""
  local isFinalStop = (triggerName == currentFinalStopName)

  if isFinalStop or endingShift then
    trueBoarding = 0
    trueDeboarding = passengersOnboard
    tipDwellReference = math.max(6, trueDeboarding * 0.6)
    dwellDuration = 0
  else
    local capacity = M.vehicleCapacity
    trueDeboarding = (passengersOnboard > 0) and math.random(1, math.min(passengersOnboard, 6)) or 0
    local availableSpace = math.max(0, capacity - passengersOnboard + trueDeboarding)
    local maxBoarding = math.min(12, availableSpace)
    trueBoarding = maxBoarding > 0 and math.random(math.min(3, maxBoarding), maxBoarding) or 0

    local baseIdle = math.random(8, 12)
    local existingDwellCalc = baseIdle + (trueBoarding * 0.8) + (trueDeboarding * 0.5)
    local animationDuration = (trueDeboarding * 2) + (trueBoarding * 2) + baseIdle
    dwellDuration = math.max(existingDwellCalc, animationDuration + 1)
    tipDwellReference = dwellDuration

    boardingCoroutine = coroutine.create(function() animateBoarding(vehicle) end)
  end
end

-- Route settlement --------------------------------------------------------------------------------

local function routeSettlementMessage(reason, payout)
  local msg = "Shift ended."
  if reason then
    msg = msg .. " (" .. reason .. ")"
  end

  local reputationGain = 0

  local routePayout = nil
  if payout and payout > 0 then
    local grossPayout = payout
    local emp = overhaul_career_work_employment
    local escrowRoleplay = emp and emp.shouldEscrowRoleplayPay()
    payout = 0

    local basePay = accumulatedReward
    local tipsEarned = tipTotal
    local busReputation = math.floor(grossPayout / config.reputationDivisor) * (config.reputationMultiplier or 1)
    local busOrgId = currentBusOrgId
    local busRepKey = busOrgId and busOrgId .. "Reputation"
    if busRepKey and overhaul_career_economy_difficultyMode and overhaul_career_economy_difficultyMode.scaleFlatRewards then
      local scaled = {
        [busRepKey] = busReputation
      }
      overhaul_career_economy_difficultyMode.scaleFlatRewards(scaled, {includeMoney = false})
      busReputation = math.max(0, math.floor((tonumber(scaled[busRepKey]) or busReputation) + 0.5))
    end
    reputationGain = busOrgId and busReputation or 0
    routePayout = {amount = 0, orgId = busOrgId, rep = reputationGain,
      label = "Bus Route", tags = {"transport", "bus", "gameplay"}, fullReward = true}

    msg = msg .. string.format("\nStops completed: %d\nBase pay:   $%d\nTips:       $%d",
      totalStopsCompleted, basePay, tipsEarned)
    if escrowRoleplay then
      local keep = emp.depositRoleplayEscrow("Bus route", grossPayout, {vehicleObjectId = activeBusID}) or 0
      local endingDay = emp.isEndingDay()
      if endingDay then
        msg = msg .. string.format("\n--------------------\nRoute pay: $%d\nReputation gained: +%d",
          keep, reputationGain)
      else
        msg = msg .. string.format("\n--------------------\nHeld until End day: $%d\nReputation gained: +%d",
          keep, reputationGain)
      end
    else
      msg = msg .. string.format("\n--------------------\nClock in at the depot for route pay.\nReputation gained: +%d",
        reputationGain)
    end
  else
    msg = msg .. "\nNo payout earned."
  end

  return msg, routePayout
end

local function endRoute(reason, payout)
  local completedRouteName = currentRouteName
  overhaul_vehicles_passengerOccupants.clear('bus')
  paxWalkers.destroy()
  if not (currentRouteActive or pendingRouteInit or stopMonitorActive) then return false end
  cancelBoardingAttempt(false)
  routePaused = false
  pendingRouteInit = false
  syncGroundMarkerClaim()
  isCalculatingRoute = false
  endingShift = false
  currentTriggerName = nil
  routeOdometerMeters = 0
  lastOdometerPos = nil

  currentRouteActive = false
  syncGroundMarkerClaim()
  dwellTimer = nil
  routeInitialized = false
  currentFinalStopName = nil
  currentRouteName = nil
  core_groundMarkers.resetAll()
  parts.stopMarkers.hideStopMarkers()

  local msg, routePayout = routeSettlementMessage(reason, payout)

  ui_message(msg, 8, "info", "info")
  log('D', 'bus', (msg:gsub("\n", " ")))

  local vehicle = be:getPlayerVehicle(0)
  if vehicle then
    vehicle:queueLuaCommand([[
      if controller and controller.onGameplayEvent then
        controller.onGameplayEvent("bus_onRouteChange", {
          routeId="00", routeID="00", direction="Not in Service", tasklist={}
        })
      end
    ]])
  end

  if routePayout and overhaul_career_career and overhaul_career_career.isActive() then
    local accepted, problem = overhaul_career_economy_payment.payout(require("overhaul/lib/finance/metadata").tagPayout(routePayout, "activity:bus", {vehicleObjectId = activeBusID}))
    if accepted ~= true then
      -- Refusal historically finishes the route; preserve that outcome without a retry.
      log('W', 'bus', 'Route payout refused: ' .. tostring(problem))
    elseif not (overhaul_career_work_employment and overhaul_career_work_employment.isOnShift()) then
      recordRoute({detail = completedRouteName or "Bus route settled", money = routePayout.amount ~= 0 and routePayout.amount or nil})
    end
  end

  accumulatedReward, passengersOnboard, totalStopsCompleted, tipTotal = 0, 0, 0, 0
  loopTipBaseline = 0
  loopRewardBaseline = 0
  roughRide, lastVelocity, activeBusID = 0, nil, nil
  currentBusOrgId = nil
  currentLoanerCut = 0

  guihooks.trigger('DiscardTasklistItem', 'bus_passenger_count')
  guihooks.trigger('ClearTasklist')
  return true
end

-- Repeated endings cannot settle an inactive route or pay for an unfinished stop.
local function requestEndShift(immediate)
  if not (currentRouteActive or pendingRouteInit or stopMonitorActive) then return true end
  if endingShift and not immediate then return true end
  endingShift = true
  cancelBoardingAttempt(true)
  if immediate or passengersOnboard == 0 then
    local reason = immediate and passengersOnboard > 0 and "remaining passengers transferred" or "shift complete"
    return endRoute(reason, accumulatedReward + tipTotal)
  end
  local currentStop = stopTriggers and stopTriggers[currentStopIndex]
  if currentStop and currentTriggerName == currentStop:getName() then
    -- An interrupted occupied stop keeps its place in the route until its dwell completes.
    currentStopIndex = currentStopIndex % #stopTriggers + 1
    currentTriggerName = nil
    isCalculatingRoute = true
    routeCalcTimer = 0
  end
  ui_message(string.format("Finishing shift — drop off your %d passengers at the next stop. No new passengers will board.", passengersOnboard), 8, "info", "bus")
  shared.updateTasklist()
  return true
end

-- Tasklist and controller display -----------------------------------------------------------------

-- Publish one ordered tasklist to both the vehicle controller and UI.
function shared.updateTasklist(paxOverride)
  if not currentRouteActive then return end
  local count = paxOverride or passengersOnboard

  local header = currentRouteName or "Bus Route"
  guihooks.trigger('SetTasklistHeader', {label = header})

  local paxLabel = routePaused and string.format("Route paused — return to your bus (%d passengers aboard)", count) or endingShift
    and string.format("Finishing shift — drop off %d passengers at the next stop", count)
    or string.format("Passengers on Board: %d", count)
  guihooks.trigger('SetTasklistTask', {
    id = "bus_passenger_count",
    label = paxLabel,
    done = false,
    active = true,
    type = "message",
    clear = false
  })
end

function shared.updateBusControllerDisplay()
  if not currentRouteActive or not currentStopIndex or not stopTriggers or #stopTriggers == 0 then
    return
  end

  local routeData = {
    routeId = "RLS",
    routeID = "RLS",
    direction = "",
    tasklist = {}
  }

  local currentStop = stopTriggers[currentStopIndex]
  local triggerName = currentStop:getName() or ""
  routeData.direction = stopDisplayNames[triggerName] or triggerName or string.format("Stop %02d", currentStopIndex)

  -- Waypoints never become passenger stops.
  local function addStopToList(i)
    local t = stopTriggers[i]
    local name = t:getName() or ""
    local label = stopDisplayNames[name] or string.format("Stop %02d", i)
    table.insert(routeData.tasklist, {name, label})
  end

  for i = currentStopIndex, #stopTriggers do
    addStopToList(i)
  end
  for i = 1, currentStopIndex - 1 do
    addStopToList(i)
  end

  local vehicle = be:getPlayerVehicle(0)
  if vehicle then
    vehicle:queueLuaCommand(string.format([[
      if controller and controller.onGameplayEvent then
        controller.onGameplayEvent("bus_setLineInfo", %s)
      end
    ]], dumps(routeData)))
  end

  guihooks.trigger('BusDisplayUpdate', routeData)
end

-- Route start -------------------------------------------------------------------------------------

local function routeInitializationAllowed()
  local emp = overhaul_career_work_employment
  if emp and emp.isEndingDay() then
    pendingRouteInit = false
    syncGroundMarkerClaim()
    return false
  end
  if currentRouteActive and routeInitialized then
    log('D', 'bus', "Route already active, skipping reinitialization")
    return false
  end

  if emp and emp.blocksRoleplay() then
    pendingRouteInit = false
    syncGroundMarkerClaim()
    ui_message("Finish your company shift before starting bus work.", 6, "warning")
    return false
  end

  local busMultiplier = overhaul_career_economyAdjuster.getSectionMultiplier("bus") or 1.0
  if busMultiplier == 0 then
    ui_message("Bus routes are currently disabled.", 5, "error", "error")
    log('D', 'bus', "Bus multiplier is set to 0, route initialization cancelled")
    return false
  end

  return true
end

local function loadRouteSelection()
  local routes = parts.routeConfig.loadRoutesFromJSON()
  if not routes then
    ui_message("No route configuration found for this map.", 5, "error", "error")
    return nil
  end

  local allTriggers, allWaypoints = parts.routeConfig.collectScenetreeObjects()
  if not next(allTriggers) then
    ui_message("No bus stops found on this map.", 5, "error", "error")
    return nil
  end

  local selectedRoute, selectedRouteKey = parts.routeConfig.selectRandomRoute(routes)
  if not selectedRoute then
    ui_message("No routes available in configuration.", 5, "error", "error")
    return nil
  end

  return selectedRoute, selectedRouteKey, allTriggers, allWaypoints
end

shared.initRoute = function()
  if not routeInitializationAllowed() then return end

  local selectedRoute, selectedRouteKey, allTriggers, allWaypoints = loadRouteSelection()
  if not selectedRoute then return end

  local routeName = selectedRoute.name or selectedRouteKey
  currentRouteName = routeName
  currentBusOrgId = getBusOrganizationId(activeBusID or be:getPlayerVehicleID(0), selectedRoute)
  if not currentBusOrgId then
    log("W", "bus", "Bus route disabled: no configured operator available")
    ui_message("No operator configured for this bus route.", 5, "error", "error")
    return
  end
  log('D', 'bus',
    string.format("Selected route: %s (%s) with %d stops (org=%s)", routeName, selectedRouteKey,
      #selectedRoute.stops, tostring(currentBusOrgId)))

  stopTriggers, routeItems, stopDisplayNames = parts.routeConfig.buildRouteFromConfig(selectedRoute, allTriggers, allWaypoints)
  if #stopTriggers == 0 then
    ui_message("No valid stops found for selected route.", 5, "error", "error")
    return
  end

  currentFinalStopName = stopTriggers[#stopTriggers]:getName() or ""

  local vehicle = be:getPlayerVehicle(0)
  if not vehicle then
    return
  end

  currentStopIndex = 1
  consecutiveStops, dwellTimer, accumulatedReward, totalStopsCompleted = 0, nil, 0, 0
  routeOdometerMeters, lastOdometerPos = 0, nil
  currentRouteActive, routeInitialized, passengersOnboard, routeCooldown = true, true, 0, 0
  syncGroundMarkerClaim()
  endingShift = false
  routeSessionSequence = routeSessionSequence + 1
  routeSessionId = tostring(os.time()) .. ":" .. tostring(M) .. ":" .. routeSessionSequence
  tipTotal, roughRide, lastVelocity = 0, 0, nil
  loopTipBaseline = 0
  loopRewardBaseline = 0

  local startStopName = stopTriggers[currentStopIndex]:getName() or "Unknown"
  local targetPos = stopTriggers[currentStopIndex]:getPosition()

  setupRouteNavigation(vehicle, targetPos, 1)

  ui_message(string.format("Bus route '%s' started. Proceed to %s. Route has %d stops.", routeName, startStopName,
    #stopTriggers), 6, "info", "info")

  shared.updateBusControllerDisplay()
  shared.updateTasklist()

  showCurrentStopMarkers()
end

-- Stop processing ---------------------------------------------------------------------------------

-- Tips follow the XP award so the original reward order remains fixed.
local function computeStopEarnings()
  local base = config.baseFare
  local bonusMultiplier = config.bonusMultiplierBase + (consecutiveStops / #stopTriggers) * config.bonusMultiplierFactor
  local stopPayout = math.floor(base * bonusMultiplier)

  local mileagePayout = 0
  if #stopTriggers < config.limitedStopsRouteMaxStops then
    local payPerMeter = config.payPerMile / config.metersPerMile
    mileagePayout = math.floor(routeOdometerMeters * payPerMeter + 0.5)
  end

  local combined = stopPayout + mileagePayout
  local sectionMultiplier = (overhaul_career_economyAdjuster and overhaul_career_economyAdjuster.getSectionMultiplier("bus")) or 1.0
  local payout = math.floor(combined * sectionMultiplier + 0.5)
  local rewardMultiplier = config.rewardMultiplier or 1
  payout = math.floor(payout * rewardMultiplier + 0.5)

  local skillConfig, busAttributeKey, busSkillLevel = getBusSkillContext()
  local moneyBonus = jobSkillRewards.getJobMoneyBonusMultiplier(skillConfig, busSkillLevel)
  local progressionPayout = payout
  payout = math.floor(payout * moneyBonus + 0.5)

  return {payout = payout, progressionPayout = progressionPayout, moneyBonus = moneyBonus,
    sectionMultiplier = sectionMultiplier, rewardMultiplier = rewardMultiplier,
    skillConfig = skillConfig, attributeKey = busAttributeKey}
end

-- Commit rider counts and rewards before choosing loop completion or the next stop.
local function commitStopPassengers(vehicle)
  log('D', 'bus', string.format("Dwell complete at stop %d", currentStopIndex))

  consecutiveStops = consecutiveStops + 1
  totalStopsCompleted = totalStopsCompleted + 1

  passengersOnboard = math.min(math.max(0, passengersOnboard + trueBoarding - trueDeboarding),
    M.vehicleCapacity)
  overhaul_vehicles_passengerOccupants.setPassengers('bus', vehicle:getID(), passengersOnboard)
  if countdownSeats then overhaul_vehicles_passengerOccupants.displayCommit('bus') end
  countdownSeats = nil
  if boardingCoroutine then
    paxWalkers.stopEnded()
  else
    paxWalkers.finalDrop(vehicle:getID(), trueDeboarding)
  end

end

local function recordStopTips(earnings)
  local tipsEarned = 0
  if trueDeboarding > 0 then
    local avgRough = math.max(0, roughRide / math.max(1, tipDwellReference))
    local tipPerPassenger = math.max(0, config.tipBaseScore - avgRough) * config.tipPerPassengerMultiplier
    tipsEarned = math.floor(tipPerPassenger * trueDeboarding * config.tipMultiplier)
    tipsEarned = math.floor(tipsEarned * earnings.sectionMultiplier + 0.5)
    tipsEarned = math.floor(tipsEarned * earnings.rewardMultiplier + 0.5)
    tipsEarned = math.floor(tipsEarned * earnings.moneyBonus + 0.5)
    tipTotal = tipTotal + tipsEarned
  end
  log('D', 'bus', string.format("Tips: +%d   TotalTips=%d", tipsEarned, tipTotal))

  return tipsEarned
end

local function completeRouteLoop()
  local loopBonus = math.floor(math.max(0, accumulatedReward - loopRewardBaseline) * config.loopBonusFactor)
  accumulatedReward = accumulatedReward + loopBonus
  loopRewardBaseline = accumulatedReward
  local totalPotential = accumulatedReward + tipTotal

  local loopTips = math.max(0, tipTotal - loopTipBaseline)
  local tipReference = math.max(1, config.loopCompletionTipReference or 400)
  local qualityMult = 1 + math.min(1, loopTips / tipReference)
  local completionXp = math.max(1, math.floor((#stopTriggers * (config.loopCompletionXpPerStop or 8)) * qualityMult + 0.5))
  local _, busAttributeKey = getBusSkillContext()
  awardBusSkillXp(busAttributeKey, completionXp, {
    label = string.format("Bus route bonus: +%d XP", completionXp),
    tags = {"transport", "bus", "gameplay"},
  }, true)
  loopTipBaseline = tipTotal

  local surgeBonusText = (overhaul_career_economy_activityHeat and overhaul_career_economy_activityHeat.formatSurgeBonusText("bus")) or ""
  ui_message(string.format(
    "Loop complete! Bonus +$%d (+50%%)%s\nRoute earnings so far: $%d\nTips: $%d\nTotal potential payout: $%d\nBonus XP: +%d",
    loopBonus, surgeBonusText, accumulatedReward, tipTotal, totalPotential, completionXp), 6, "info", "info")

  passengersOnboard = 0
  overhaul_vehicles_passengerOccupants.clear('bus')
  trueBoarding = 0
  trueDeboarding = 0

  routeCooldown = config.routeCooldown
  currentStopIndex = 1
  lastOdometerPos = nil

  isCalculatingRoute = true
  routeCalcTimer = 0

  shared.updateBusControllerDisplay()
  shared.updateTasklist()

  overhaul_career_saveSystem.saveCurrent()
end

local function advanceRouteStop(payout, tipsEarned)
  if endingShift then
    endRoute("final passengers dropped off", accumulatedReward + tipTotal)
    return
  end
  local nextStopIndex = math.min((currentStopIndex or 1) + 1, #stopTriggers)
  local nextStopName = stopTriggers[nextStopIndex]:getName() or "Unknown"
  log('D', 'bus', string.format("Moving to next stop: index %d, name %s", nextStopIndex, nextStopName))

  local stopSurgeText = (overhaul_career_economy_activityHeat and overhaul_career_economy_activityHeat.formatSurgeBonusText("bus")) or ""
  ui_message(string.format("Proceed to Stop %02d\nBase pay: $%d%s\nTips: $%d\nTotal tips: $%d",
    nextStopIndex, payout, stopSurgeText, tipsEarned, tipTotal), 8, "info", "bus_next")

  currentStopIndex = nextStopIndex
  isCalculatingRoute = true
  routeCalcTimer = 0
  shared.updateBusControllerDisplay()
  shared.updateTasklist()
end

local function completeBusStopBoarding(vehicle, trigger)
  commitStopPassengers(vehicle)

  local earnings = computeStopEarnings()
  local payout = earnings.payout
  accumulatedReward = accumulatedReward + payout

  awardBusSkillXp(earnings.attributeKey, jobSkillRewards.getSkillRewardAmount(earnings.skillConfig, earnings.progressionPayout), {
    label = string.format("Bus stop payout: $%d", payout),
    tags = {"transport", "bus", "gameplay"}
  })
  routeOdometerMeters = 0
  lastOdometerPos = vehicle:getPosition()

  local tipsEarned = recordStopTips(earnings)

  roughRide = 0

  core_vehicleBridge.executeAction(vehicle, 'setFreeze', false)
  boardingCoroutine = nil

  dwellTimer = nil
  stopMonitorActive = false
  syncGroundMarkerClaim()
  stopSettleTimer = 0
  stopIndexWhereBoardingStarted = nil
  currentTriggerName = nil

  local triggerName = trigger:getName() or ""
  if triggerName == currentFinalStopName then
    if endingShift then
      endRoute("final passengers dropped off", accumulatedReward + tipTotal)
      return
    end

    completeRouteLoop()
  else
    advanceRouteStop(payout, tipsEarned)

  end
end

-- A boarding attempt belongs to one stop and must be cancelled before the stop changes.
local function stopProcessingAllowed()
  if not currentRouteActive or not currentStopIndex then
    return false
  end
  if routeCooldown > 0 then
    return false
  end
  if not stopTriggers or #stopTriggers == 0 then
    return false
  end
  if currentStopIndex < 1 or currentStopIndex > #stopTriggers then
    return false
  end

  if stopIndexWhereBoardingStarted and (dwellTimer == nil
    or (boardingCoroutine == nil and not endingShift and stopTriggers[currentStopIndex]:getName() ~= currentFinalStopName)) then
    cancelBoardingAttempt(true)
    return false
  end

  return true
end

local function processStop(vehicle, dtSim)
  if not stopProcessingAllowed() then return end

  local trigger = getNextTrigger()
  if not trigger then
    return
  end

  local expectedStopName = stopTriggers[currentStopIndex]:getName()
  if expectedStopName and trigger:getName() ~= expectedStopName then
    return
  end

  if currentTriggerName == trigger:getName() then
    local velocity = vehicle:getVelocity():length()

    if velocity > config.stopVelocityThreshold then
      ui_message("Come to a complete stop before passengers can board.", 2, "info", "info")
      cancelBoardingAttempt(true)
      return
    end

    if not stopMonitorActive then
      stopMonitorActive = true
      syncGroundMarkerClaim()
      stopSettleTimer = 0
      ui_message("Please open doors to begin boarding", 2.5, "info", "bus")
    else
      stopSettleTimer = stopSettleTimer + (dtSim or 0.033)
    end

    if stopSettleTimer < config.stopSettleDelay then
      dwellTimer = nil
      return
    end

    if not dwellTimer then
      beginStopBoarding(vehicle, trigger)
    end

    dwellTimer = dwellTimer + (dtSim or 0.033)

    if (boardingCoroutine and coroutine.status(boardingCoroutine) == "dead") or (not boardingCoroutine and dwellTimer >= dwellDuration) then
      completeBusStopBoarding(vehicle, trigger)
    end

  else
    cancelBoardingAttempt(true)
  end
end

-- Vehicle switching -------------------------------------------------------------------------------

-- Company routes pause on exit; independent routes settle immediately.

local function enterBus(oldId, newId, newVeh)
  if currentRouteActive and activeBusID and newId ~= activeBusID then
    local oldBus = be:getObjectByID(activeBusID)
    if routePaused and not oldBus then
      endRoute("bus replaced", accumulatedReward + tipTotal)
    else
      return
    end
  end
  if not currentRouteActive or not routeInitialized then
    -- Fitting passenger seats respawns the bus in place; keep the pending shift start.
    if oldId == newId and pendingRouteInit then
      return
    end
    if not canStartBusShift(newId) then
      return
    end
    if activeBusID ~= newId then
      seatSetupVehId = nil
    end
    activeBusID = newId
    currentLoanerCut = parts.routeConfig.calculateLoanerCut(newId)
    -- Clear before resolve so a new bus with no loaning org cannot keep a stale org.
    currentBusOrgId = nil
    currentBusOrgId = getBusOrganizationId(newId)
    ui_message("Shift started. Welcome in! Drive careful out there.", 10, "info", "info")
    pendingRouteInit = true
    syncGroundMarkerClaim()
    retrievePartsTree()
  else
    activeBusID = newId
    if routePaused then
      routePaused = false
      overhaul_vehicles_passengerOccupants.setPassengers('bus', newId, passengersOnboard)
      if countdownSeats then overhaul_vehicles_passengerOccupants.display('bus', newId, countdownSeats) end
      if stopIndexWhereBoardingStarted then core_vehicleBridge.executeAction(newVeh, 'setFreeze', true) end
      showNextStopMarker(currentStopIndex)
      shared.updateTasklist()
      ui_message("Bus route resumed.", 4, "info")
    end
    paxWalkers.resume()
    log('D', 'bus', "Route already active, not reinitializing")
  end
end

local function onVehicleSwitched(oldId, newId, player)
  if player and player ~= 0 then return end
  if oldId ~= newId then overhaul_vehicles_passengerOccupants.clear('bus', true) end
  if oldId ~= newId then paxWalkers.pause() end -- kept for a roleplay pause; route ends delete them
  local newVeh = be:getObjectByID(newId)

  if currentRouteActive and activeBusID and oldId == activeBusID and newId ~= activeBusID then
    local emp = overhaul_career_work_employment
    if emp and emp.isRoleplayShift() then
      local bus = be:getObjectByID(activeBusID)
      if bus and stopIndexWhereBoardingStarted then core_vehicleBridge.executeAction(bus, 'setFreeze', false) end
      routePaused = true
      lastVelocity, lastOdometerPos = nil, nil
      shared.updateTasklist()
      ui_message("Route paused. Return to your bus to continue; use End Day in Phone > Employment to finish.", 8, "info")
    else
      requestEndShift(true)
    end
  end

  if newVeh and shared.isBus(newVeh) then enterBus(oldId, newId, newVeh) end
end

-- Per-frame update --------------------------------------------------------------------------------

-- Boarding animation, ride quality and stop settlement share the same simulation step.
local function updateRouteSchedule(dtSim)
  -- Reassert after a marker-patch reload; route state still belongs to this bus instance.
  syncGroundMarkerClaim()
  paxWalkers.update(dtSim) -- returns at once while no walker is shown
  local emp = overhaul_career_work_employment
  if emp and emp.blocksRoleplay() then
    if currentRouteActive or stopMonitorActive or pendingRouteInit then
      pendingRouteInit = false
      syncGroundMarkerClaim()
      endRoute("company logistics shift", 0)
    end
    return false
  end

  -- Complete retained End Day requests before starting a new route loop.
  if currentRouteActive and not endingShift and emp and emp.isEndingDay() then
    requestEndShift(false)
  end

  if routePaused then return false end

  if isCalculatingRoute then
    routeCalcTimer = routeCalcTimer + (dtSim or 0.033)
    if routeCalcTimer > 0.5 then
      local vehicle = be:getPlayerVehicle(0)

      showNextStopMarker(currentStopIndex)

      if vehicle then
        core_vehicleBridge.executeAction(vehicle, 'setFreeze', false)
      end

      isCalculatingRoute = false
    end
    return false
  end

  if currentRouteActive and routeInitialized then
    uiUpdateTimer = uiUpdateTimer + (dtSim or 0.033)
    if uiUpdateTimer > 0.5 then
      uiUpdateTimer = 0
      shared.updateTasklist()
      local bus = activeBusID and be:getObjectByID(activeBusID)
      if bus then paxWalkers.poll(bus:getPosition()) end
    end
  end

  if routeCooldown > 0 then
    routeCooldown = math.max(0, routeCooldown - (dtSim or 0))
    return false
  end

  return true
end

local function updateDrivingRoute(vehicle, dtSim)
  local velocity = vehicle:getVelocity()

  if lastVelocity then
    local deltaVel = velocity - lastVelocity
    local safeDt = (dtSim and dtSim > 0) and dtSim or 0.01
    local accel = deltaVel:length() / safeDt
    local accelThreshold = config.accelThreshold

    if accel > accelThreshold then
      roughRide = roughRide + (accel - accelThreshold) * safeDt * config.roughRidePenaltyMultiplier
    end
  end

  lastVelocity = velocity

  if stopTriggers and #stopTriggers < config.limitedStopsRouteMaxStops then
    local pos = vehicle:getPosition()
    if lastOdometerPos then
      local d = pos:distance(lastOdometerPos)
      if d > 0 and d <= config.odometerMaxStepMeters then
        routeOdometerMeters = routeOdometerMeters + d
      end
    end
    lastOdometerPos = pos
  end

end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not updateRouteSchedule(dtSim) then return end

  local vehicle = be:getPlayerVehicle(0)
  if not vehicle or vehicle:getID() ~= activeBusID or not shared.isBus(vehicle) or not routeInitialized then
    return
  end

  if boardingCoroutine and coroutine.status(boardingCoroutine) ~= "dead" then
    local ok, err = coroutine.resume(boardingCoroutine, dtSim)
    if not ok then
      log('D', 'bus', string.format("Boarding animation coroutine error at stop %d: %s", currentStopIndex or -1,
        tostring(err)))
      cancelBoardingAttempt(true)
      return
    end
  end

  updateDrivingRoute(vehicle, dtSim)

  processStop(vehicle, dtSim)
end

-- Only the active bus may change dwell state.
local function onBeamNGTrigger(data)
  local trackedVehicleId = currentRouteActive and activeBusID or be:getPlayerVehicleID(0)
  if trackedVehicleId ~= data.subjectID then
    return
  end
  if not currentRouteActive and gameplay_walk and gameplay_walk.isWalking() then
    return
  end

  local routeStop = false
  for _, trigger in ipairs(stopTriggers or {}) do
    if trigger:getName() == data.triggerName then
      routeStop = true
      break
    end
  end
  if not routeStop then return end

  if data.event == "enter" then
    currentTriggerName = data.triggerName
  elseif data.event == "exit" then
    if currentTriggerName == data.triggerName then
      currentTriggerName = nil
      cancelBoardingAttempt(true)
    end
  end
end

-- Lifecycle ---------------------------------------------------------------------------------------

-- Unfreeze and remove transient route state before the extension unloads.
local function resetRouteState()
  if overhaul_vehicles_passengerOccupants then overhaul_vehicles_passengerOccupants.clear('bus') end
  paxWalkers.destroy()
  routePaused = false
  cancelBoardingAttempt(false)
  endingShift = false
  routeSessionId = nil

  parts.stopMarkers.clearStopMarkers()

  -- Profile switches and unload can reset routes outside a level.
  if core_groundMarkers then
    core_groundMarkers.resetAll()
  end

  boardingCoroutine = nil

  currentStopIndex = nil
  stopTriggers = {}
  dwellTimer = nil
  dwellDuration = config.dwellDurationBase
  tipDwellReference = config.dwellDurationBase
  consecutiveStops = 0
  currentRouteActive = false
  syncGroundMarkerClaim()
  accumulatedReward = 0
  passengersOnboard = 0
  activeBusID = nil
  currentBusOrgId = nil
  routeInitialized = false
  totalStopsCompleted = 0
  routeCooldown = 0
  currentVehiclePartsTree = nil
  stopMonitorActive = false
  syncGroundMarkerClaim()
  stopSettleTimer = 0
  currentTriggerName = nil
  roughRide = 0
  lastVelocity = nil
  tipTotal = 0
  loopTipBaseline = 0
  loopRewardBaseline = 0
  trueBoarding = 0
  trueDeboarding = 0
  currentFinalStopName = nil
  stopIndexWhereBoardingStarted = nil
  pendingRouteInit = false
  syncGroundMarkerClaim()
  isCalculatingRoute = false
  routeCalcTimer = 0
  currentRouteName = nil
  stopDisplayNames = {}
  routeItems = {}
  currentLoanerCut = 0
  routeOdometerMeters = 0
  lastOdometerPos = nil

  M.vehicleCapacity = nil

  guihooks.trigger('ClearTasklist')
end

-- Startup sweeps walker pools left by a replaced bus instance.
local function onExtensionLoaded()
  paxWalkers.sweep() -- walkers left in the scene by a Lua reload
  ui_message("Bus module loaded. Enter a BUS vehicle to begin your route.", 3, "info", "info")
  log('D', 'bus', "Extension loaded.")
end

local function onExtensionUnloaded()
  log('D', 'bus', "Extension unloading, cleaning up...")
  resetRouteState()
  paxWalkers.retire()
  log('D', 'bus', "Extension unloaded successfully.")
end

-- Vehicle-backed passenger walkers must be gone before a Lua reload serializes stock checkpoints.
require('overhaul/lib/vehicles/temporary').declare('bus', function() paxWalkers.destroy() end)

local function onClientEndMission()
  resetRouteState()
end

local function onOverhaulActive(active)
  if active == false then resetRouteState() end
end

-- Public API --------------------------------------------------------------------------------------

M.returnPartsTree = returnPartsTree
M.canUsePersonalVehicle = function(vehId)
  return shared.isBus(be:getObjectByID(vehId)) and canStartBusShift(vehId)
end
-- The diagnostic walker probe reads this instance instead of reconstructing a second visual owner.
M.devWalkers = function()
  return {walkers = paxWalkers, busId = activeBusID, routeActive = M.isBusRouteActive()}
end
-- Console check for the walking passengers: one figure 3 m in front of the player (visual only).
M.debugSpawnWalker = function()
  local veh = be:getPlayerVehicle(0)
  if not veh then return {error = 'no player vehicle'} end
  local fwd = vec3(veh:getDirectionVector()):z0()
  if fwd:length() < 1e-3 then fwd = vec3(0, 1, 0) end
  fwd = fwd:normalized()
  local pos = vec3(veh:getPosition()) + fwd * 3
  return paxWalkers.debugSpawn(pos, math.atan2(fwd.x, fwd.y)) -- facing the player (-fwd)
end
M.isBusRouteActive = function()
  return currentRouteActive == true or stopMonitorActive == true or pendingRouteInit == true
end

M.requestEndShift = requestEndShift
M.getShiftState = function()
  return {
    active = currentRouteActive,
    passengers = passengersOnboard,
    ending = endingShift,
    paused = routePaused,
    routeId = currentRouteActive and routeSessionId or nil,
  }
end

M.getEmploymentTaskGuidance = function()
  if routePaused then
    return {label = "Bus route paused", subtext = "Return to your bus to continue the route"}
  end
  if currentRouteActive then
    local stop = stopTriggers[currentStopIndex]
    local name = stop and stopDisplayNames[stop:getName()] or nil
    return {label = endingShift and "Finish your bus route" or "Drive to the next bus stop",
      subtext = endingShift and string.format("Drop off %d passengers at the next stop to end the day", passengersOnboard)
        or string.format("%s / %d passengers aboard", name or ("Stop " .. tostring(currentStopIndex)), passengersOnboard)}
  end
  return {label = "Enter your bus", subtext = "Get in your assigned or personal bus to begin the route"}
end

M.cancelActiveRoute = function(reason)
  if not (currentRouteActive or stopMonitorActive or pendingRouteInit) then
    return false
  end
  endRoute(reason or "cancelled", 0)
  return true
end

-- The host adopts this instance only when its employment parent is ready.
M.activity = require('overhaul/jobs/bus/activity')(M)

-- Game hooks --------------------------------------------------------------------------------------

M.onVehicleSwitched = onVehicleSwitched
M.onUpdate = onUpdate
M.onBeamNGTrigger = onBeamNGTrigger
M.onExtensionLoaded = onExtensionLoaded
M.onOverhaulBeforeSetProfile = resetRouteState
M.onExtensionUnloaded = onExtensionUnloaded
M.onClientEndMission = onClientEndMission
M.onOverhaulActive = onOverhaulActive
M.onOverhaulBeforeLuaReload = function()
  -- Settlement changes session state. Its save request follows the autosave setting;
  -- with autosave off, only a later manual save checkpoints the held pay and reputation.
  if endRoute("Lua reload", accumulatedReward + tipTotal) then
    require('overhaul/lib/save/store').request('bus:reloadWages')
  end
end
M.onOverhaulBeforeSaveExit = function()
  if endRoute("leaving career", accumulatedReward + tipTotal) then
    require('overhaul/lib/save/store').request('bus:exitWages')
  end
end
-- The bus is gone (also mid-countdown): its walkers go too; the job itself is untouched.
M.onVehicleDestroyed = function(vehId)
  if vehId ~= nil and vehId == activeBusID then paxWalkers.hide() end
end

return M
