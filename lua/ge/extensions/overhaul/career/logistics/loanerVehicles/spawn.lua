-- Loaner spawning. Map: config, facility lookup, blocked prompt, failure cleanup, placement, batch steps, public API.
-- Read resetSpawnBatchResult, isEmploymentOffer, employmentOwnsSpawnPrompt, loanerSpawnFacility in order.

local issued = require('overhaul/lib/vehicles/issued')
local routeLease = require('overhaul/lib/activity/routeLease')

local spawning = {}

local LOG_TAG = "loanerVehicles"
local LOANER_NO_SPACE_MSG = "There are no parking spots for loaner vehicles of this type."
local LOANER_OCCUPIED_MSG = "Vehicle spawn area is blocked. Clear the marked stalls, then retry."
local BLOCKED_TASK_ID = "loaner-spawn-blocked"
-- A stall with a car rolling faster than this (m/s, squared) counts as moving.
local MOVING_SPEED_SQUARED = 0.25 * 0.25
local INITIALIZE_TIMEOUT_SECONDS = 8
-- Employment cars start high above the stall and drop onto validated ground in placement.
local EMPLOYMENT_SPAWN_HEIGHT_METERS = 1000
local NEARBY_RADIUS_SQUARED = 40 * 40

local function createSpawnRuntime(offers)
  -- Placement lives behind lib/vehicles/placement as its "loaner" strategy; bind() hands it the offer lookups.
  local loanerPlacement = require('overhaul/lib/vehicles/placement').strategy('loaner').create()
  loanerPlacement.bind({
    flattenXY = offers.flattenXY,
    getConfigInfo = offers.getConfigInfo,
    getInspectParkingSpot = offers.getInspectParkingSpot,
    isTrailerVehicle = offers.isTrailerVehicle,
  })

  return {
    placement = loanerPlacement,
    batchResult = {occupiedBlocked = false, hardFail = false},
    pendingOffers = {},
    markerCorners = {},
    lastActionSignature = nil,
  }
end

function spawning.new(inputs)
  local api = {}
  local offers = inputs.offers

  local spawnRuntime = createSpawnRuntime(offers)
  local blockedRoute = routeLease.new()

  local function resetSpawnBatchResult()
    spawnRuntime.batchResult.occupiedBlocked = false
    spawnRuntime.batchResult.hardFail = false
  end

  -- Facilities and spots -----------------------------------------------------------------------------

  local function isEmploymentOffer(offer)
    local record = issued.forVehicle(offer)
    return offer and ((record and record.isCompany) or offer._fromEmploymentPool)
  end

  local function employmentOwnsSpawnPrompt()
    local employment = overhaul_career_work_employment
    local status = employment and employment.getBlockedSpawnStatus and employment.getBlockedSpawnStatus()
    return status ~= nil
  end

  -- Facility for one offer's spawn. Logs and returns nil when the offer cannot be spawned.
  local function loanerSpawnFacility(offer)
    local sourceFacilityId = offer.sourceFacility and offer.sourceFacility.id
    if not sourceFacilityId then
      log("E", LOG_TAG, string.format("Loaner %s missing sourceFacility; skipping spawn", tostring(offer.id)))
      return nil
    end
    local facility = offers.getDeliveryFacility(sourceFacilityId)
    if not facility then
      log("E", LOG_TAG, string.format("Loaner %s facility unavailable: %s", tostring(offer.id), tostring(sourceFacilityId)))
      return nil
    end
    return facility
  end

  local function collectSpotsForOffers(offerList)
    local spots, seen = {}, {}
    local function addSpot(spot)
      if type(spot) ~= "table" or not spot.pos then return end
      local key = (spot.getPath and spot:getPath()) or spot
      if seen[key] then return end
      seen[key] = true
      spots[#spots + 1] = spot
    end
    for _, offer in pairs(offerList or {}) do
      local sourceFacilityId = offer.sourceFacility and offer.sourceFacility.id
      local facility = sourceFacilityId and offers.getDeliveryFacility(sourceFacilityId)
      if facility then
        local configInfo = offers.getConfigInfo(offer.model, offer.config)
        local isTrailer = offers.isTrailerVehicle(configInfo, offer.model)
        local list = isTrailer and facility.loanerTrailerSpots or facility.loanerNonTrailerSpots
        for _, spot in ipairs(list or {}) do addSpot(spot) end
      end
    end
    return spots
  end

  -- Blocked prompt -----------------------------------------------------------------------------------

  -- Reports whether the spots are free, whether a car in them is still moving, and who is in them.
  local function inspectBlockedOccupancy(blocked)
    local spots = (blocked and blocked.spots) or {}
    local occupantIds, seen, moving = {}, {}, false
    local occupied = false
    local reservation = require('overhaul/lib/parking/reservation')
    for _, spot in ipairs(spots) do
      reservation.clearParkedOccupants(spot)
      local status, ids = reservation.getSpotOccupants(spot)
      if status ~= 'empty' then
        occupied = true
        for _, vehId in ipairs(ids or {}) do
          if not seen[vehId] then
            seen[vehId] = true
            occupantIds[#occupantIds + 1] = vehId
            local obj = getObjectByID(vehId)
            local vel = obj and obj.getVelocity and obj:getVelocity()
            if vel and vel:squaredLength() > MOVING_SPEED_SQUARED then
              moving = true
            end
          end
        end
      end
    end
    return not occupied, moving, occupantIds, spots
  end

  local function routeToBlockedSpots(spots)
    local best = nil
    for _, spot in ipairs(spots or {}) do
      if spot.pos then best = spot.pos; break end
    end
    if not best then return false end
    if freeroam_bigMapMode and freeroam_bigMapMode.setNavFocus then
      freeroam_bigMapMode.setNavFocus(best)
    end
    blockedRoute.set(best, {clearPathOnReachingTarget = false})
    return true
  end

  local function refreshLoanerSpawnAction(force)
    local visible = inputs.state.spawnBlocked ~= nil and not employmentOwnsSpawnPrompt()
    local ready = visible and inputs.state.spawnBlocked.ready == true and not inputs.state.spawnBlocked.retryInFlight
    local signature = tostring(visible) .. tostring(ready)
    if force or signature ~= spawnRuntime.lastActionSignature then
      guihooks.trigger("EmploymentSpawnAction", {visible = visible, ready = ready})
      spawnRuntime.lastActionSignature = signature
    end
    if not inputs.state.spawnBlocked then
      guihooks.trigger("DiscardTasklistItem", BLOCKED_TASK_ID)
      return
    end
    if employmentOwnsSpawnPrompt() then return end
    ui_appContainers.showApp("topLeft", "tasks")
    local label = inputs.state.spawnBlocked.ready and "Ready to spawn" or "Clear the spawn area"
    local subtext = "Clear the highlighted stalls, then select Spawn vehicle"
    guihooks.trigger("SetTasklistHeader", { label = "Loaner vehicles" })
    guihooks.trigger("SetTasklistTask", {
      id = BLOCKED_TASK_ID,
      label = label,
      subtext = subtext,
      active = true,
      type = "message",
      clear = false,
    })
  end

  local function clearLoanerSpawnBlocked()
    if not inputs.state.spawnBlocked then return end
    inputs.state.spawnBlocked.token = (inputs.state.spawnBlocked.token or 0) + 1
    inputs.state.spawnBlocked = nil
    spawnRuntime.markerCorners = {}
    spawnRuntime.pendingOffers = {}
    local current = blockedRoute.isCurrent()
    blockedRoute.clear()
    if current and freeroam_bigMapMode and freeroam_bigMapMode.setNavFocus then
      freeroam_bigMapMode.setNavFocus(nil)
    end
    refreshLoanerSpawnAction(true)
  end

  local function enterLoanerSpawnBlocked(waitingOffers)
    waitingOffers = waitingOffers or spawnRuntime.pendingOffers
    if not next(waitingOffers or {}) then return false end
    if employmentOwnsSpawnPrompt() then
      for id, offer in pairs(waitingOffers) do
        inputs.state.markedForSpawningLoaners[id] = offer
      end
      return false
    end
    overhaul_phone_phone.closePhone()
    extensions.ui_router.navigate("play")
    local spots = collectSpotsForOffers(waitingOffers)
    local clear, moving, occupantIds = inspectBlockedOccupancy({spots = spots})
    local previousToken = inputs.state.spawnBlocked and inputs.state.spawnBlocked.token or 0
    local alreadyWaiting = inputs.state.spawnBlocked ~= nil
    inputs.state.spawnBlocked = {
      token = previousToken + 1,
      offers = {},
      spots = spots,
      occupantIds = occupantIds,
      occupantMoving = moving,
      ready = clear,
      accum = 0,
      retryInFlight = nil,
    }
    for id, offer in pairs(waitingOffers) do
      inputs.state.spawnBlocked.offers[id] = offer
      inputs.state.markedForSpawningLoaners[id] = offer
    end
    spawnRuntime.pendingOffers = {}
    spawnRuntime.markerCorners = {}
    routeToBlockedSpots(spots)
    if not alreadyWaiting then
      ui_message("Clear the highlighted spawn area, then select Spawn vehicle.", 8, "warning")
    end
    refreshLoanerSpawnAction(true)
    if overhaul_integration_services_markerInteraction then overhaul_integration_services_markerInteraction.setForceReevaluateOpenPrompt() end
    return true
  end

  -- The four corners of a stall, lifted to the ground under each one. Computed once per stall.
  local function blockedStallCorners(spot)
    local corners = spawnRuntime.markerCorners[spot]
    if corners then return corners end
    corners = {}
    local axisX = vec3(1, 0, 0):rotated(spot.rot)
    local axisY = vec3(0, 1, 0):rotated(spot.rot)
    for _, sideX in ipairs({-1, 1}) do
      for _, sideY in ipairs({-1, 1}) do
        local pos = spot.pos + axisX * sideX * spot.scl.x * 0.5 + axisY * sideY * spot.scl.y * 0.5
        local hit = Engine.castRay(pos + vec3(0, 0, 5), pos - vec3(0, 0, 10), true, false)
        pos = (hit and vec3(hit.pt) or pos) + vec3(0, 0, 0.12)
        corners[#corners + 1] = {pos = pos, x = axisX * -sideX, y = axisY * -sideY}
      end
    end
    spawnRuntime.markerCorners[spot] = corners
    return corners
  end

  local function drawBlockedStall(spot, corners, ready, outlineColor)
    local center = vec3(0, 0, 0)
    for _, corner in ipairs(corners) do center = center + corner.pos end
    center = center * 0.25
    local direction = vec3(0, 1, 0):rotated(spot.rot)
    local fill = ready and ColorF(0.15, 1, 0.25, 0.25) or ColorF(1, 0.6, 0.05, 0.25)
    debugDrawer:drawSquarePrism(center - direction * spot.scl.y * 0.5,
      center + direction * spot.scl.y * 0.5, Point2F(0.15, spot.scl.x), Point2F(0.15, spot.scl.x), fill)
    if not ready then
      for _, corner in ipairs(corners) do
        debugDrawer:drawCylinder(corner.pos, corner.pos + corner.x, 0.07, outlineColor)
        debugDrawer:drawCylinder(corner.pos, corner.pos + corner.y, 0.07, outlineColor)
        debugDrawer:drawCylinder(corner.pos, corner.pos + vec3(0, 0, 0.6), 0.07, outlineColor)
      end
    end
  end

  local function drawLoanerSpawnBlockedArea(blocked)
    if not debugDrawer or not blocked then return end
    local outlineColor = ColorF(1, 0.05, 0.05, 1)
    for _, spot in ipairs(blocked.spots or {}) do
      if spot.pos and spot.rot and spot.scl then
        drawBlockedStall(spot, blockedStallCorners(spot), blocked.ready, outlineColor)
      end
    end
  end

  -- Checks the stalls every 2 s (1 s while a car is still moving) and flips the prompt when they clear.
  function api.tickBlocked(dtSim)
    local blocked = inputs.state.spawnBlocked
    if not blocked or blocked.retryInFlight then return end
    drawLoanerSpawnBlockedArea(blocked)
    blocked.accum = (blocked.accum or 0) + (tonumber(dtSim) or 0)
    local interval = blocked.occupantMoving and 1 or 2
    if blocked.accum < interval then return end
    blocked.accum = 0
    local clear, moving, occupantIds, spots = inspectBlockedOccupancy(blocked)
    blocked.occupantMoving = moving
    blocked.occupantIds = occupantIds
    blocked.spots = spots
    if blocked.ready ~= clear then
      blocked.ready = clear
      refreshLoanerSpawnAction(true)
      if overhaul_integration_services_markerInteraction then overhaul_integration_services_markerInteraction.setForceReevaluateOpenPrompt() end
    end
  end

  -- No-space handling -------------------------------------------------------------------------------

  -- A car that could not be placed is deleted. An occupied stall waits for the player, except for employment offers, which employment retries itself. Other failures show a no-space message.
  local function abortLoanerNoSpace(vehObj, offer, reason)
    log("W", LOG_TAG, string.format("No space for loaner %s (%s)", tostring(offer and offer.id), tostring(reason or "noSpace")))
    if reason == "occupied" then
      spawnRuntime.batchResult.occupiedBlocked = true
    else
      spawnRuntime.batchResult.hardFail = true
    end
    if vehObj then
      pcall(function() vehObj:delete() end)
    end
    if reason == "occupied" then
      if not offer then
        ui_message(LOANER_OCCUPIED_MSG, 8, "loanerSpawnBlocked")
      elseif not isEmploymentOffer(offer) then
        spawnRuntime.pendingOffers[offer.id] = offer
      end
    else
      ui_message(LOANER_NO_SPACE_MSG, 5, "loanerNoSpace")
    end
  end

  -- Placement ---------------------------------------------------------------------------------------

  -- A placed car becomes an inventory vehicle with its owner, loan type and broker ids, and a rental starts billing.
  local function registerPlacedLoaner(attempt)
    local offer, facility, vehObj, vehId = attempt.offer, attempt.facility, attempt.vehObj, attempt.vehId
    local inventoryId = overhaul_career_garage_inventory.addVehicle(vehId, nil, {owned = false})
    attempt.registeredInventoryId = inventoryId
    local vehicleInfo = inventoryId and overhaul_career_garage_inventory.getVehicles()[inventoryId]
    if not vehicleInfo then
      log("E", LOG_TAG, string.format("Loaner %s was spawned but could not be added to inventory", tostring(offer.id)))
      abortLoanerNoSpace(vehObj, offer, "inventory")
      inputs.state.vehicleAdded = true
      return
    end
    vehicleInfo.owningOrganization = facility.associatedOrganization
    vehicleInfo.loanType = offer.loanType
    vehicleInfo.brokerRentalId = offer.brokerRentalId
    vehicleInfo.brokerDepotId = offer.brokerDepotId
    vehicleInfo.brokerMap = offer.brokerMap
    local offerRecord = issued.forVehicle(offer)
    if offerRecord and offerRecord.isRental then
      vehicleInfo.rentalHourlyRate = offer.hourlyRate or offers.getHourlyRateForOffer(offer)
      inputs.initRentalBilling(vehicleInfo)
    end
  end

  -- Runs inside the placement job: place the car, then register it. Errors are caught by the caller.
  local function placeLoanerAndRegister(attempt, placementJob)
    if not attempt.vehObj or not scenetree.findObjectById(attempt.vehId) then
      inputs.state.vehicleAdded = true
      return
    end
    local placed, bestParkingSpot, placeReason = spawnRuntime.placement.teleportLoanerToFacility(
      attempt.facility, attempt.vehObj, attempt.vehId, attempt.offer, function() placementJob.sleep(0) end)
    if attempt.finished then return end
    if not placed then
      abortLoanerNoSpace(attempt.vehObj, attempt.offer, placeReason)
      inputs.state.vehicleAdded = true
      return
    end
    attempt.offer.vehPos = attempt.vehObj:getPosition() or (bestParkingSpot and bestParkingSpot.pos)
    attempt.batch.lookAtPos = attempt.offer.vehPos
    registerPlacedLoaner(attempt)
  end

  local function runPlacementAttempt(attempt, placementJob)
    if attempt.finished then return end
    local callbackOk, callbackErr = pcall(placeLoanerAndRegister, attempt, placementJob)
    if not callbackOk then
      log("E", LOG_TAG, string.format("Could not finish retrieving loaner %s: %s", tostring(attempt.offer.id), tostring(callbackErr)))
      if attempt.registeredInventoryId then
        overhaul_career_garage_inventory.removeVehicle(attempt.registeredInventoryId, true)
      else
        abortLoanerNoSpace(attempt.vehObj, attempt.offer, "placement")
      end
      inputs.state.vehicleAdded = true
    end
    attempt.finished = true
  end

  -- Employment spawns start high above a stall, away from occupants. A missing bridge reply must not leave the car falling from there, so those spawns time out.
  local function startInitializeTimeout(attempt)
    core_jobsystem.create(function(job)
      job.sleep(INITIALIZE_TIMEOUT_SECONDS)
      if attempt.finished then return end
      attempt.finished = true
      abortLoanerNoSpace(attempt.vehObj, attempt.offer, "initializationTimeout")
      inputs.state.vehicleAdded = true
    end)
  end

  -- The step callback for one spawned car: initialize its part conditions, then place it once the bridge replies.
  local function loanerSpawnedCallback(offer, facility, options, batch)
    return function(step, vehId)
      local vehObj = scenetree.findObjectById(vehId)
      if not facility or not vehObj then
        log("E", LOG_TAG, string.format("Could not initialize loaner %s: facility or vehicle is unavailable", tostring(offer.id)))
        inputs.state.vehicleAdded = true
        return
      end
      local initOk, initErr = pcall(core_vehicleBridge.executeAction, vehObj, 'initPartConditions', {}, offer.vehMileage or 0, 1, 1)
      if not initOk then
        log("E", LOG_TAG, string.format("Could not initialize loaner %s: %s", tostring(offer.id), tostring(initErr)))
      end
      local attempt = {offer = offer, facility = facility, vehObj = vehObj, vehId = vehId, batch = batch, finished = false}
      core_vehicleBridge.requestValue(vehObj, function()
        if attempt.finished then return end
        core_jobsystem.create(function(placementJob)
          runPlacementAttempt(attempt, placementJob)
        end)
      end, 'ping')
      if options.safeSpawn == false then
        startInitializeTimeout(attempt)
      end
    end
  end

  -- Employment offers start above their anchor stall; the placement callback settles them onto the ground.
  local function applyEmploymentSpawnAnchor(facility, options)
    local anchor = (facility.loanerNonTrailerSpots or {})[1] or (facility.loanerTrailerSpots or {})[1]
      or offers.getInspectParkingSpot(facility)
    if not anchor then
      for _, accessPoint in pairs(facility.accessPointsByName or {}) do
        if accessPoint.ps and accessPoint.ps.pos then
          anchor = accessPoint.ps
          break
        end
      end
    end
    if anchor and anchor.pos then
      options.pos = anchor.pos + vec3(0, 0, EMPLOYMENT_SPAWN_HEIGHT_METERS)
      options.rot = anchor.rot
      options.safeSpawn = false
    end
  end

  -- Batch ---------------------------------------------------------------------------------------------

  -- One marked offer adds its steps to the sequence. An offer with no usable facility is logged and skipped.
  local function addOfferSteps(sequence, offer, batch)
    local options = {model = offer.model, config = offer.config, autoEnterVehicle = false, removeTraffic = false}
    local facility = loanerSpawnFacility(offer)
    if not facility then return end
    if isEmploymentOffer(offer) then
      applyEmploymentSpawnAnchor(facility, options)
    end
    table.insert(sequence, overhaul_shell_stepHandler.makeStepReturnTrueFunction(function()
      inputs.state.vehicleAdded = false
      return true
    end))
    table.insert(sequence, overhaul_shell_stepHandler.makeStepSpawnVehicle(options,
      loanerSpawnedCallback(offer, facility, options, batch)))
    table.insert(sequence, overhaul_shell_stepHandler.makeStepReturnTrueFunction(function()
      return inputs.state.vehicleAdded
    end))
  end

  -- After the batch, the player turns toward the last car placed while walking.
  local function turnTowardSpawnedLoaner(batch)
    if not batch.lookAtPos then return end
    local playerVehicle = getPlayerVehicle(0)
    local camDir = playerVehicle and (batch.lookAtPos - playerVehicle:getPosition()) or nil
    if camDir and gameplay_walk.isWalking() then
      gameplay_walk.setRot(camDir)
    end
  end

  -- cargoScreen often calls this from a live stepHandler callback. Starting a nested sequence there replaces the outer task data and skips the fade, so the sequence always starts on the next job tick.
  local function startSpawnSequenceWhenReady(sequence, onComplete)
    core_jobsystem.create(function(job)
      job.sleep(0)
      local general = overhaul_career_logistics_general
      local waited = 0
      while general and general.isContainerWeightUpdatePending() and waited < 60 do
        job.sleep(0.05)
        waited = waited + 0.05
      end
      if general and general.isContainerWeightUpdatePending() then
        log("W", LOG_TAG, "Cargo loading did not settle before loaner spawn timeout")
      elseif waited > 0 then
        job.sleep(0)
      end
      overhaul_shell_stepHandler.startStepSequence(sequence, onComplete)
    end)
  end

  function api.spawnAllOffers(onComplete)
    if not next(inputs.state.markedForSpawningLoaners) then
      log("W", LOG_TAG, "spawnAllOffers called with no marked loaners")
      if onComplete then onComplete() end
      return
    end
    resetSpawnBatchResult()
    spawnRuntime.pendingOffers = {}
    inputs.state.vehicleAdded = false
    local batch = {}
    local sequence = {
      overhaul_shell_stepHandler.makeStepFadeToBlack(0.4),
    }
    for _, offer in pairs(inputs.state.markedForSpawningLoaners) do
      addOfferSteps(sequence, offer, batch)
    end
    if #sequence <= 1 then
      log("W", LOG_TAG, "spawnAllOffers had marked loaners but built no spawn steps")
      inputs.state.markedForSpawningLoaners = {}
      if onComplete then onComplete() end
      return
    end
    table.insert(sequence, overhaul_shell_stepHandler.makeStepReturnTrueFunction(function()
      -- markedForSpawningLoaners may already be empty: cargoScreen unmarks after spawnAllOffers returns, and the sequence runs one tick later.
      turnTowardSpawnedLoaner(batch)
      inputs.state.markedForSpawningLoaners = {}
      return true
    end))
    table.insert(sequence, overhaul_shell_stepHandler.makeStepFadeFromBlack(0.4))

    startSpawnSequenceWhenReady(sequence, function()
      if spawnRuntime.batchResult.occupiedBlocked and next(spawnRuntime.pendingOffers) then
        enterLoanerSpawnBlocked(spawnRuntime.pendingOffers)
      end
      if onComplete then onComplete() end
    end)
  end

  -- Public API ---------------------------------------------------------------------------------------

  local function installSpawnActions()
    function api.consumeLastSpawnBatchResult()
      local result = {
        occupiedBlocked = spawnRuntime.batchResult.occupiedBlocked and true or false,
        hardFail = spawnRuntime.batchResult.hardFail and true or false,
      }
      resetSpawnBatchResult()
      return result
    end

    function api.getBlockedSpawnStatus()
      if not inputs.state.spawnBlocked or employmentOwnsSpawnPrompt() then return nil end
      local veh = getPlayerVehicle(0)
      local pos = veh and veh:getPosition()
      local nearby = false
      for _, spot in ipairs(inputs.state.spawnBlocked.spots or {}) do
        if pos and spot.pos and (pos - spot.pos):squaredLength() <= NEARBY_RADIUS_SQUARED then
          nearby = true
          break
        end
      end
      return {ready = inputs.state.spawnBlocked.ready == true and not inputs.state.spawnBlocked.retryInFlight, nearby = nearby}
    end

    -- The player pressed Spawn vehicle at the blocked stalls: re-check them, then retry the batch once they are clear.
    function api.spawnBlockedOffers()
      local status = api.getBlockedSpawnStatus()
      local blocked = inputs.state.spawnBlocked
      if not status or not status.nearby or not blocked or blocked.retryInFlight then return false end
      local clear = inspectBlockedOccupancy(blocked)
      blocked.ready = clear
      if not clear then
        ui_message("The spawn area is still blocked. Clear the highlighted stalls first.", 6, "warning")
        refreshLoanerSpawnAction(true)
        return false
      end
      blocked.retryInFlight = true
      for id, offer in pairs(blocked.offers or {}) do
        inputs.state.markedForSpawningLoaners[id] = offer
      end
      local token = blocked.token
      api.spawnAllOffers(function()
        if not inputs.state.spawnBlocked or inputs.state.spawnBlocked.token ~= token then return end
        local batch = api.consumeLastSpawnBatchResult()
        inputs.state.spawnBlocked.retryInFlight = nil
        if batch.occupiedBlocked then
          enterLoanerSpawnBlocked(inputs.state.spawnBlocked.offers)
          return
        end
        if batch.hardFail then
          clearLoanerSpawnBlocked()
          return
        end
        clearLoanerSpawnBlocked()
      end)
      return true
    end

    function api.cancelBlockedSpawn()
      clearLoanerSpawnBlocked()
      inputs.state.markedForSpawningLoaners = {}
    end

    function api.onOverhaulVehicleAdded()
      inputs.state.vehicleAdded = true
    end
  end
  installSpawnActions()

  return api
end

return spawning
