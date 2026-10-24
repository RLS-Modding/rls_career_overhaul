-- Company logistics employment: assigned parcel loading, ground clearance and return pickups.
-- Reading order: return text, cargo location, clearance, bay slots, guarded loading and assigned pickups.
local part = {}
local REMOTE_PICKUP_DISTANCE = 12

-- Return text -------------------------------------------------------------------------------------

local function installReturnText(api, inputs)
  local shared = inputs.shared
  local eligibility = inputs.eligibility
  local state = inputs.state

  api.finalizeAssignedParcelRewards = function(cargoIds)
    local generator = shared.generator()
    local parcelMgr = shared.parcelManager()
    if not (generator and generator.finalizeParcelItemDistanceAndRewards and parcelMgr and parcelMgr.getCargoById) then
      return
    end
    for _, cargoId in ipairs(cargoIds or {}) do
      local cargo = parcelMgr.getCargoById(cargoId)
      if cargo then
        generator.finalizeParcelItemDistanceAndRewards(cargo)
      end
    end
  end

  api.describeFacilityName = function(facId)
    if not facId then return "the yard" end
    local generator = shared.generator()
    local facility = generator and generator.getFacilityById(facId)
    if facility and facility.name then
      return eligibility.translateUiText(facility.name, facId)
    end
    return tostring(facId)
  end

  -- Clear return-leg copy. If pickup isn't where you just dropped off, say so explicitly.
  api.formatReturnParcelGuidance = function(pickupFacId, dest, cargoCount, dropOffFacId)
    local pickupName = api.describeFacilityName(pickupFacId)
    local destFacId = dest and dest.facId
    local destName = api.describeFacilityName(destFacId)
    local toOffice = destFacId and destFacId == ((state.shift and state.shift.originFacId) or state.homeFacId)
    local count = tonumber(cargoCount) or 0
    local remotePickup = dropOffFacId and pickupFacId and dropOffFacId ~= pickupFacId
    local countBit = count > 0 and string.format("%d parcel%s", count, count == 1 and "" or "s") or "Return load"
    local pickLabel, deliverLabel, subtext
    if remotePickup then
      pickLabel = string.format("Pick up return load at %s", pickupName)
      subtext = toOffice
        and string.format("%s · deliver to the office", countBit)
        or string.format("%s · deliver to %s", countBit, destName)
    else
      pickLabel = string.format("Pick up return load at %s", pickupName)
      subtext = toOffice and string.format("%s · back to the office", countBit) or countBit
    end
    deliverLabel = string.format("Deliver return to %s", destName)
    return pickLabel, deliverLabel, subtext
  end

  function api.describeDest(dest)
    if not dest then return "the destination" end
    local raw
    if shared.parcelManager() then
      raw = shared.parcelManager().getLocationLabelShort(dest)
    end
    return eligibility.translateUiText(raw or dest.facId, dest.facId or "the destination")
  end
end

-- Cargo location -----------------------------------------------------------------------------------

local function installCargoLocations(api, inputs)
  local shared = inputs.shared

  api.assignedReturnCargoInVehicle = function(shift)
    if not shift then return false end
    if shift.assignedCargoIds and shift.assignedCargoIds[1] then
      local parcelMgr = shared.parcelManager()
      if parcelMgr then
        for _, cargoId in ipairs(shift.assignedCargoIds) do
          local cargo = parcelMgr.getCargoById(cargoId)
          if cargo and cargo.location and cargo.location.type == "vehicle" then
            return true
          end
        end
      end
    end
    -- Trailer backhaul: coupled / en-route counts as acquired.
    if shift.assignedOfferId and overhaul_career_logistics_vehicleTasks then
      local tasks = overhaul_career_logistics_vehicleTasks.getVehicleTasks() or {}
      for _, task in ipairs(tasks) do
        if not task.remove and task.offer and task.offer.id == shift.assignedOfferId then
          local step = task.tasks and task.tasks[task.activeTaskIndex]
          if step and (step.type == "bringToDestination" or step.type == "confirmDropOff") then
            return true
          end
        end
      end
    end
    return false
  end

  api.isInspectProviderSpot = function(facId, psPath)
    if not facId or not psPath then return false end
    local generator = shared.generator()
    local facility = generator and generator.getFacilityById(facId)
    if not facility then return false end
    for _, accessPoint in pairs(facility.accessPointsByName or {}) do
      if accessPoint.isInspectSpot then
        local path = accessPoint.psPath
        if not path and accessPoint.ps and accessPoint.ps.getPath then
          path = accessPoint.ps:getPath()
        end
        if path == psPath and accessPoint.logisticTypesProvidedLookup and next(accessPoint.logisticTypesProvidedLookup) then
          return true
        end
      end
    end
    return false
  end

  api.cargoAtInspectProviderSpot = function(cargo)
    local loc = cargo and cargo.location
    if not loc or loc.type ~= "facilityParkingspot" then return false end
    return api.isInspectProviderSpot(loc.facId, loc.psPath)
  end

  api.nextRemoteParcelPickup = function(shift, skipNearPlayer)
    local parcelMgr = shared.parcelManager()
    if not (shift and shared.kindPolicy(shift.jobKind).parcels and parcelMgr) then return end
    for _, id in ipairs(shift.assignedCargoIds or {}) do
      local cargo = parcelMgr.getCargoById(id)
      local location = cargo and cargo.location
      if location and location.type == "facilityParkingspot" and not inputs.dropOff.cargoHasTimedModifier(cargo)
          and not (skipNearPlayer and inputs.routing.playerNearLocation(location, REMOTE_PICKUP_DISTANCE)) then
        return location
      end
    end
  end

  api.parcelPickupPendingAtOrigin = function(shift)
    local origin = shift and shift.originLocation
    local parcelMgr = shared.parcelManager()
    if not (shift and shared.kindPolicy(shift.jobKind).parcels and origin and parcelMgr) then return false end
    for _, id in ipairs(shift.assignedCargoIds or {}) do
      local cargo = parcelMgr.getCargoById(id)
      local location = cargo and cargo.location
      if location and location.type == "facilityParkingspot" and location.facId == origin.facId
          and (not origin.psPath or location.psPath == origin.psPath)
          and not inputs.dropOff.cargoHasTimedModifier(cargo) then return true end
    end
    return false
  end
end

-- Weight and ground clearance ---------------------------------------------------------------------

local function installGroundClearance(api, inputs)
  local shared = inputs.shared

  api.measureVehicleGroundClearance = function(vehId)
    vehId = tonumber(vehId) or vehId
    if not vehId then return nil end
    local veh = scenetree.findObjectById(vehId)
    if not veh or not veh.getPosition then return nil end
    local pos = veh:getPosition()
    if not pos then return nil end
    local origin = vec3(pos.x, pos.y, pos.z + 2)
    local hit = castRayStatic(origin, vec3(0, 0, -1), 8)
    if not hit or hit >= 8 then return nil end
    local groundZ = origin.z - hit
    return pos.z - groundZ
  end

  api.countAssignedParcelsOnVehicle = function(shift, vehId)
    vehId = tonumber(vehId) or vehId
    local parcelMgr = shared.parcelManager()
    if not (shift and vehId and parcelMgr and parcelMgr.getCargoById) then return 0 end
    local n = 0
    for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
      local cargo = parcelMgr.getCargoById(cargoId)
      local loc = cargo and cargo.location
      if loc and loc.type == "vehicle" and tonumber(loc.vehId) == vehId then
        n = n + 1
      end
    end
    return n
  end

  api.unloadHeaviestAssignedParcelFromTruck = function(shift, vehId)
    vehId = tonumber(vehId) or vehId
    local parcelMgr = shared.parcelManager()
    if not (shift and vehId and parcelMgr and parcelMgr.getCargoById and parcelMgr.changeCargoLocation) then
      return false
    end
    if api.countAssignedParcelsOnVehicle(shift, vehId) <= 1 then
      return false
    end
    local bestId, bestWeight = nil, nil
    for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
      local cargo = parcelMgr.getCargoById(cargoId)
      local loc = cargo and cargo.location
      if loc and loc.type == "vehicle" and tonumber(loc.vehId) == vehId then
        local weight = tonumber(cargo.weight) or 0
        if not bestWeight or weight > bestWeight then
          bestWeight = weight
          bestId = cargoId
        end
      end
    end
    if not bestId then return false end
    local cargo = parcelMgr.getCargoById(bestId)
    local returnLoc = shift.originLocation or (cargo and cargo.origin)
    if not returnLoc then return false end
    parcelMgr.changeCargoLocation(bestId, returnLoc)
    local keep = {}
    for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
      if cargoId ~= bestId then
        keep[#keep + 1] = cargoId
      end
    end
    shift.assignedCargoIds = keep
    if shift.stringCargoIds then
      local membership = {}
      for _, cargoId in ipairs(shift.stringCargoIds) do
        if cargoId ~= bestId then
          membership[#membership + 1] = cargoId
        end
      end
      shift.stringCargoIds = membership
    end
    return true, bestId, bestWeight
  end

  api.applyContainerWeightsWithOverlay = function(onSettled)
    local general = shared.general()
    if not (general and general.requestUpdateContainerWeights and general.updateContainerWeights) then
      if onSettled then onSettled() end
      return
    end
    general.requestUpdateContainerWeights()
    general.updateContainerWeights(function(data)
      local maxDelay = 0
      for _, delay in pairs(data or {}) do
        maxDelay = math.max(maxDelay, tonumber(delay) or 0)
      end
      local function unfreeze()
        for id, _ in pairs(data or {}) do
          local veh = scenetree.findObjectById(id)
          if veh then
            pcall(core_vehicleBridge.executeAction, veh, "setFreeze", false)
          end
        end
      end
      core_jobsystem.create(function(job)
        if maxDelay > 0 then
          job.sleep(math.max(maxDelay, 1) + 0.5)
        end
        unfreeze()
        job.sleep(0.6)
        if onSettled then onSettled() end
      end)
    end)
  end
end

-- Clearance trim -----------------------------------------------------------------------------------

local function trimStillLoading(operation)
  return operation.state.shift == operation.shift
    and operation.shift._clearanceTrimToken == operation.token
end

local function hideTrimOverlay(operation)
  if not operation.overlayShown then return end
  operation.overlayShown = false
  guihooks.trigger("rlsCareerLoadingOverlay", {visible = false})
end

local function finishClearanceTrim(operation)
  hideTrimOverlay(operation)
  if not trimStillLoading(operation) then return end
  operation.onDone(operation.trimmed)
end

local function checkAndTrim(operation)
  if not trimStillLoading(operation) then hideTrimOverlay(operation); return end
  local emptyClearance = tonumber(operation.emptyClearance)
  local loadedClearance = operation.api.measureVehicleGroundClearance(operation.vehId)
  if not emptyClearance or emptyClearance < 0.08 or not loadedClearance then
    finishClearanceTrim(operation)
    return
  end
  local ratio = loadedClearance / emptyClearance
  if ratio >= operation.minRatio or operation.trimmed >= operation.maxTrims then
    operation.shared.shiftLog("parcel clearance", string.format(
      "accept ratio=%.3f empty=%.3f loaded=%.3f trimmed=%d",
      ratio, emptyClearance, loadedClearance, operation.trimmed))
    finishClearanceTrim(operation)
    return
  end
  local removed = operation.api.unloadHeaviestAssignedParcelFromTruck(operation.shift, operation.vehId)
  if not removed then
    operation.shared.shiftLog("parcel clearance", string.format(
      "cannot trim further ratio=%.3f empty=%.3f loaded=%.3f", ratio, emptyClearance, loadedClearance))
    finishClearanceTrim(operation)
    return
  end
  operation.trimmed = operation.trimmed + 1
  operation.shared.shiftLog("parcel clearance", string.format(
    "trim #%d ratio=%.3f -> reweigh", operation.trimmed, ratio))
  operation.api.applyContainerWeightsWithOverlay(operation.check)
end

local function showTrimOverlay(operation)
  if operation.overlayShown or operation.runtime.nextAssignmentTransition then return end
  operation.overlayShown = true
  guihooks.trigger("rlsCareerLoadingOverlay", {visible = true, message = "Loading cargo"})
end

-- One operation retains its callback and token across every asynchronous reweigh.
local function installClearanceTrim(api, inputs)
  local runtime = inputs.runtime
  local shared = inputs.shared
  local state = inputs.state
  api.beginParcelClearanceTrimAfterLoad = function(shift, vehId, emptyClearance, onDone)
    vehId = tonumber(vehId) or vehId
    onDone = onDone or function() end
    if not shift or not vehId then onDone(0); return end
    shift._clearanceTrimToken = (shift._clearanceTrimToken or 0) + 1
    local operation = {
      shift = shift, vehId = vehId, emptyClearance = emptyClearance, onDone = onDone,
      token = shift._clearanceTrimToken, trimmed = 0,
      minRatio = tonumber(runtime.PARCEL_LOAD_CLEARANCE_RATIO) or 0.60,
      maxTrims = math.floor(tonumber(runtime.PARCEL_LOAD_CLEARANCE_MAX_TRIMS) or 12),
      overlayShown = false, api = api, state = state, runtime = runtime, shared = shared,
    }
    operation.check = function() checkAndTrim(operation) end
    showTrimOverlay(operation)
    api.applyContainerWeightsWithOverlay(operation.check)
  end
end

-- Bay slots ----------------------------------------------------------------------------------------

local function installBaySlots(api)
  api.buildCompanyParcelLoadSlots = function(containers)
    local slots = {}
    for _, container in ipairs(containers or {}) do
      if container.cargoTypesLookup and container.cargoTypesLookup.parcel and (container.freeCargoSlots or 0) > 0 then
        local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(container.vehId)
        local vehInfo = inventoryId and overhaul_career_garage_inventory.getVehicles()[inventoryId]
        if vehInfo and vehInfo.loanType == "company" then
          local usedWeight = 0
          for _, cargo in ipairs(container.rawCargo or {}) do
            usedWeight = usedWeight + (tonumber(cargo.weight) or 0)
          end
          for _, cargo in ipairs(container.transientCargo or {}) do
            usedWeight = usedWeight + (tonumber(cargo.weight) or 0)
          end
          slots[#slots + 1] = {
            location = { type = "vehicle", vehId = container.vehId, containerId = container.containerId },
            free = tonumber(container.freeCargoSlots) or 0,
            usedWeight = usedWeight,
            vehId = container.vehId,
          }
        end
      end
    end
    return slots
  end

  -- Prefers the lightest bay that still fits the parcel, then the lightest bay at all.
  api.takeParcelLoadLocation = function(slots, cargo)
    if not (slots and slots[1] and cargo) then return nil end
    local need = math.max(0, tonumber(cargo.slots) or 0)
    local bestFit, bestFitWeight, bestFitFree
    local bestAny, bestAnyWeight, bestAnyFree
    for i = 1, #slots do
      local slot = slots[i]
      local w = slot.usedWeight or 0
      local free = slot.free or 0
      if not bestAny or w < bestAnyWeight or (w == bestAnyWeight and free > bestAnyFree) then
        bestAny, bestAnyWeight, bestAnyFree = slot, w, free
      end
      if free >= need then
        if not bestFit or w < bestFitWeight or (w == bestFitWeight and free > bestFitFree) then
          bestFit, bestFitWeight, bestFitFree = slot, w, free
        end
      end
    end
    local slot = bestFit or bestAny
    if not slot then return nil end
    slot.free = (slot.free or 0) - need
    slot.usedWeight = (slot.usedWeight or 0) + (tonumber(cargo.weight) or 0)
    return {
      type = "vehicle",
      vehId = slot.location.vehId,
      containerId = slot.location.containerId,
    }
  end
end

-- Cargo binding ------------------------------------------------------------------------------------

-- Binding only runs while the shift is on its outbound or return leg.
local function isLoadingPhase(shift)
  return shift.phase == "outbound" or shift.phase == "return"
end

local function issuedVehicleIds(shift)
  local vehicleIds = {}
  for _, inventoryId in ipairs(shift.issuedInventoryIds or {}) do
    local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
    if vehId then vehicleIds[vehId] = true end
  end
  return vehicleIds
end

local function hasLiveAssignedCargo(parcelMgr, shift)
  for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
    if parcelMgr.getCargoById(cargoId) then return true end
  end
  return false
end

-- A full company bay means the truck still carries stale cargo from an earlier shift.
local function companyBayIsFull(containers)
  for _, container in ipairs(containers or {}) do
    if container.cargoTypesLookup and container.cargoTypesLookup.parcel and (container.freeCargoSlots or 0) <= 0 then
      local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(container.vehId)
      local vehInfo = inventoryId and overhaul_career_garage_inventory.getVehicles()[inventoryId]
      if vehInfo and vehInfo.loanType == "company" then
        return true
      end
    end
  end
  return false
end

local function clearStaleTruckCargo(inputs, shift)
  shift._clearedStaleTruckCargo = true
  inputs.equipment.deleteCargoOnCompanyVehicles()
  shift.parcelLoadRetryAt = inputs.shared.nowSim() + 0.5
end

local function retryDuringTransition(inputs, shift)
  if shift.parcelLoadAttempts >= 10 then
    inputs.routing.handleAssignmentStartFailure("The company truck's cargo containers are unavailable.")
  else
    shift.parcelLoadRetryAt = inputs.shared.nowSim() + 1
  end
end

local function waitInsideVan(inputs, shift)
  shift.parcelLoadRetryAt = inputs.shared.nowSim() + 1
  if shift.parcelLoadAttempts == 1 then
    ui_message("Stay in the company van. Cargo loads when the bay is ready.", 6, "info")
  elseif shift.parcelLoadAttempts == 8 and not shift._autoLoadGetInPrompted then
    shift._autoLoadGetInPrompted = true
    ui_message("The van's cargo bay isn't responding. Step out and get back in.", 7, "warning")
  end
end

local function giveUpOnBay(inputs, shift)
  shift.parcelLoadPending = nil
  shift.parcelLoadRetryAt = nil
  shift.parcelLoadAttempts = nil
  inputs.routing.handleAssignmentStartFailure("The company truck's cargo containers are unavailable. Please try another assignment.")
end

local function promptGetInVan(shift)
  if not shift._autoLoadGetInPrompted then
    shift._autoLoadGetInPrompted = true
    ui_message("Get in the company van. Cargo loads after you're in it.", 6, "info")
  end
end

-- Runs when no company bay answered with free slots: wait, clear stale cargo, or send the player to the truck.
local function handleNoBayAvailable(inputs, shift, containers)
  local routing = inputs.routing
  local inTruck = inputs.equipment.playerInIssuedCompanyTruck()
  if companyBayIsFull(containers) and not shift._clearedStaleTruckCargo then
    clearStaleTruckCargo(inputs, shift)
    return
  end
  shift.parcelLoadAttempts = (shift.parcelLoadAttempts or 0) + 1
  if inputs.runtime.nextAssignmentTransition then
    retryDuringTransition(inputs, shift)
    return
  end
  if inTruck then
    waitInsideVan(inputs, shift)
    return
  end
  if shift.parcelLoadAttempts >= 10 then
    giveUpOnBay(inputs, shift)
    return
  end
  shift.parcelLoadRetryAt = inputs.shared.nowSim() + 1
  if inputs.equipment.routeToCompanyTruck and inputs.equipment.routeToCompanyTruck() then
    promptGetInVan(shift)
    return
  end
  routing.routeCurrentAssignment()
end

-- Cargo at a separate pickup dock loads once the player has driven up to it.
local function atRemotePickup(inputs, shift, cargo)
  local loc = cargo.location
  return (shift.needsRemotePickup or shift.returnNeedsPickup) and loc ~= nil
    and loc.type == "facilityParkingspot" and inputs.routing.playerNearLocation(loc, REMOTE_PICKUP_DISTANCE)
end

-- Moves each assigned parcel into a bay slot, or stages it for a manual pickup.
local function placeAssignedCargo(api, inputs, shift, slots, parcelMgr)
  local dropOff = inputs.dropOff
  local autoLoaded = false
  local stagedManual = false
  local truckFull = false
  local loadOrder = {}
  for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
    loadOrder[#loadOrder + 1] = cargoId
  end
  table.sort(loadOrder, function(a, b)
    local ca = parcelMgr.getCargoById(a)
    local cb = parcelMgr.getCargoById(b)
    return (tonumber(ca and ca.weight) or 0) > (tonumber(cb and cb.weight) or 0)
  end)
  for _, cargoId in ipairs(loadOrder) do
    local cargo = parcelMgr.getCargoById(cargoId)
    if cargo and dropOff.cargoHasTimedModifier(cargo) then
      -- Timed parcels are not loaded by this pass.
    elseif cargo and cargo.location and cargo.location.type == "accident" then
      -- Wreck cargo is not loaded by this pass.
    elseif cargo and cargo.logisticsPending and cargo.location and cargo.location.type == "vehicle" then
      local dest = api.takeParcelLoadLocation(slots, cargo)
      if dest then
        parcelMgr.changeCargoLocation(cargoId, dest)
        autoLoaded = true
      else
        stagedManual = true
        truckFull = true
      end
    elseif cargo and cargo.location and cargo.location.type == "vehicle" then
      -- Already aboard the truck.
    elseif cargo and (api.cargoAtInspectProviderSpot(cargo) or atRemotePickup(inputs, shift, cargo)) then
      local dest = api.takeParcelLoadLocation(slots, cargo)
      if dest then
        if cargo._transientMove and parcelMgr.clearTransientMoveForCargo then
          parcelMgr.clearTransientMoveForCargo(cargoId)
        end
        parcelMgr.changeCargoLocation(cargoId, dest)
        autoLoaded = true
      else
        stagedManual = true
        truckFull = true
      end
    elseif cargo then
      local dest = api.takeParcelLoadLocation(slots, cargo)
      if dest and not cargo._transientMove then
        parcelMgr.addTransientMoveCargo(cargoId, dest)
        stagedManual = true
      elseif not dest then
        stagedManual = true
        truckFull = true
      end
    end
  end
  return autoLoaded, stagedManual, truckFull
end

local function updateRemotePickupFlags(api, shift, truckFull)
  local completedRemotePickup = shift.returnNeedsPickup or shift.needsRemotePickup
  local nextPickup = completedRemotePickup and not truckFull and api.nextRemoteParcelPickup(shift, true)
  if nextPickup then
    shift.originLocation = {type = nextPickup.type, facId = nextPickup.facId, psPath = nextPickup.psPath}
  else
    shift.returnNeedsPickup = nil
    shift.needsRemotePickup = nil
    if completedRemotePickup then shift.dropOffDepartureRequired = nil end
  end
  shift._autoLoadGetInPrompted = nil
end

local function announceAutoLoad(inputs, shift, parcelCount, trimmedCount, deliveryLabel)
  local assignment = inputs.assignment
  local projections = inputs.projections
  local msg = string.format(
    "%d parcel%s loaded — %s",
    parcelCount,
    parcelCount == 1 and "" or "s",
    deliveryLabel or "deliver to the assigned destination")
  if (tonumber(trimmedCount) or 0) > 0 then
    msg = string.format(
      "%d parcel%s loaded (trimmed %d for weight) — %s",
      parcelCount,
      parcelCount == 1 and "" or "s",
      trimmedCount,
      deliveryLabel or "deliver to the assigned destination")
  end
  assignment.assignmentMessage(msg, 7, "info")
  if shift.stringMode and shift.outboundLabel then
    projections.firePhoneNotification("employment.stringReady", "Route ready", shift.outboundLabel, "success")
  end
end

-- Runs after the bay load settles: routes the player, announces the result and marks the next assignment ready.
local function finishAutoLoad(inputs, shift, autoLoaded, stagedManual, trimmedCount)
  local state = inputs.state
  local dropOff = inputs.dropOff
  local routing = inputs.routing
  local assignment = inputs.assignment
  local projections = inputs.projections
  if not state.shift or state.shift ~= shift then return end
  if shift.stringMode then
    dropOff.rebuildStringFromFinalTruckLoad(shift)
  end
  routing.routeCurrentAssignment()
  routing.refreshDeliveryPois()
  local parcelCount = dropOff.countAssignedParcelsOnTruck(shift)
  local deliveryLabel = shift.phase == "return" and shift.returnDeliverLabel or shift.outboundLabel
  if autoLoaded and not stagedManual then
    announceAutoLoad(inputs, shift, parcelCount, trimmedCount, deliveryLabel)
  elseif autoLoaded and stagedManual then
    assignment.assignmentMessage("Some assigned parcels are at another dock — pick those up next.", 6, "info")
  end
  projections.refreshTaskGuidance(true)
  projections.notifyUi()
  assignment.markNextAssignmentReady(shift)
end

-- Runs once a bay answered with free slots: loads the cargo, then trims weight if anything went aboard.
local function loadAssignedCargoOntoSlots(api, inputs, shift, slots, parcelMgr)
  shift.parcelLoadPending = nil
  shift.parcelLoadRetryAt = nil
  shift.parcelLoadAttempts = nil
  local loadVehId = slots[1].vehId
  local emptyClearance = api.measureVehicleGroundClearance(loadVehId)
  local autoLoaded, stagedManual, truckFull = placeAssignedCargo(api, inputs, shift, slots, parcelMgr)
  local onTruck = inputs.dropOff.countAssignedParcelsOnTruck(shift)
  if not (autoLoaded or (shift.stringMode and onTruck > 0)) then
    inputs.routing.routeCurrentAssignment()
    return
  end
  updateRemotePickupFlags(api, shift, truckFull)
  local function finish(trimmedCount)
    finishAutoLoad(inputs, shift, autoLoaded, stagedManual, trimmedCount)
  end
  if not autoLoaded then
    finish(0)
    return
  end
  local cargoScreen = inputs.shared.cargoScreen()
  if cargoScreen and cargoScreen.onCargoPickedUp then
    cargoScreen.onCargoPickedUp()
  end
  api.beginParcelClearanceTrimAfterLoad(shift, loadVehId, emptyClearance, finish)
end

-- Starts the assigned cargo's load into the company truck. The scan callback acts only for the shift and token it was started for.
local function installCargoBinding(api, inputs)
  local state = inputs.state
  local runtime = inputs.runtime
  local shared = inputs.shared
  local routing = inputs.routing
  local dropOff = inputs.dropOff

  api.bindAssignedCargoToIssuedTruck = function()
    local shift = state.shift
    if not shift or not shared.kindPolicy(shift.jobKind).parcels then return end
    if not isLoadingPhase(shift) then return end
    if shift.accident and shift.accident.needReload then
      routing.routeCurrentAssignment()
      return
    end
    if inputs.runtime.bindAssignedInFlight then return end
    api.finalizeAssignedParcelRewards(shift.assignedCargoIds)
    dropOff.purgeTimedParcelsFromShift(shift)
    local parcelMgr = shared.parcelManager()
    local general = shared.general()
    if not (parcelMgr and general and general.getNearbyVehicleCargoContainers) then
      routing.routeCurrentAssignment()
      return
    end
    if not hasLiveAssignedCargo(parcelMgr, shift) then
      shift.parcelLoadPending = nil
      shift.parcelLoadRetryAt = nil
      routing.handleAssignmentStartFailure("The assigned parcels are no longer available.")
      return
    end
    runtime.bindAssignedToken = (runtime.bindAssignedToken or 0) + 1
    local bindToken = runtime.bindAssignedToken
    inputs.runtime.bindAssignedInFlight = true
    shift.parcelLoadPending = true
    local vehicleIds = issuedVehicleIds(shift)
    general.getNearbyVehicleCargoContainers(function(containers)
      if not state.shift or state.shift ~= shift or runtime.bindAssignedToken ~= bindToken then return end
      inputs.runtime.bindAssignedInFlight = false
      if not isLoadingPhase(shift) then return end
      local slots = api.buildCompanyParcelLoadSlots(containers)
      if not slots[1] then
        handleNoBayAvailable(inputs, shift, containers)
        return
      end
      loadAssignedCargoOntoSlots(api, inputs, shift, slots, parcelMgr)
    end, vehicleIds)
  end
end

-- Pickup -------------------------------------------------------------------------------------------

local function installAssignedPickup(api, inputs)
  local state, shared, routing, lifecycle = inputs.state, inputs.shared, inputs.routing, inputs.lifecycle

  function api.tryAutoLoadAssignedParcelsAtSpot(facId, psPath)
    if not lifecycle.isOnShift() then return false end
    local shift = state.shift
    if not shift or not shared.kindPolicy(shift.jobKind).parcels then return false end
    if not isLoadingPhase(shift) then return false end
    if shift.accident and shift.accident.needReload then return false end
    if inputs.runtime.bindAssignedInFlight then return false end
    local remotePickup = (shift.phase == "return" and shift.returnNeedsPickup)
      or (shift.phase == "outbound" and shift.needsRemotePickup)
    if not remotePickup and not api.isInspectProviderSpot(facId, psPath) then return false end
    if api.assignedReturnCargoInVehicle(shift) and not shift.returnNeedsPickup and not shift.needsRemotePickup then
      return false
    end
    local parcelMgr = shared.parcelManager()
    if not parcelMgr then return false end
    local expected = shift.originLocation
    if remotePickup and expected and expected.facId == facId
        and (not expected.psPath or expected.psPath == psPath)
        and not inputs.endDay.assignedParcelFreightAlive(shift) then
      ui_message("The assigned return parcels are gone — finding another return load.", 6, "info")
      inputs.backhaul.assignReturnLoad(facId)
      inputs.projections.refreshTaskGuidance(true)
      return true
    end
    local anyHere = false
    for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
      local cargo = parcelMgr.getCargoById(cargoId)
      local loc = cargo and cargo.location
      if loc and loc.type == "facilityParkingspot" and loc.facId == facId and loc.psPath == psPath then
        anyHere = true
        break
      end
    end
    if not anyHere then
      if remotePickup then
        api.stageAssignedReturnPickup()
      end
      return false
    end
    api.bindAssignedCargoToIssuedTruck()
    return true
  end

  api.stageAssignedReturnPickup = function()
    local shift = state.shift
    if not shift or not shared.kindPolicy(shift.jobKind).parcels then return false end
    if not (shift.returnNeedsPickup or shift.needsRemotePickup) then return false end
    local parcelMgr = shared.parcelManager()
    local general = shared.general()
    if not (parcelMgr and general and general.getNearbyVehicleCargoContainers) then return false end
    if not routing.playerNearLocation(shift.originLocation, REMOTE_PICKUP_DISTANCE) then
      if parcelMgr.clearTransientMoveForCargo then
        for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
          local cargo = parcelMgr.getCargoById(cargoId)
          if cargo and cargo._transientMove then parcelMgr.clearTransientMoveForCargo(cargoId) end
        end
      end
      return false
    end
    general.getNearbyVehicleCargoContainers(function(containers)
      if not state.shift or state.shift ~= shift then return end
      local slots = api.buildCompanyParcelLoadSlots(containers)
      if not slots[1] then return end
      local staged = false
      for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
        local cargo = parcelMgr.getCargoById(cargoId)
        if cargo and cargo.location and cargo.location.type == "facilityParkingspot" then
          if not cargo._transientMove then
            local dest = api.takeParcelLoadLocation(slots, cargo)
            if dest then
              parcelMgr.addTransientMoveCargo(cargoId, dest)
              staged = true
            end
          end
        end
      end
      if staged then
        routing.refreshDeliveryPois()
        inputs.projections.notifyUi()
      end
    end)
    return true
  end

  api.hasAssignedReturnCargoAtSpot = function(facId, psPath)
    if not lifecycle.isOnShift() then return false end
    local shift = state.shift
    if not shift or not shared.kindPolicy(shift.jobKind).parcels then return false end
    if not (shift.returnNeedsPickup or shift.needsRemotePickup) then return false end
    local parcelMgr = shared.parcelManager()
    if not parcelMgr then return false end
    for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
      local cargo = parcelMgr.getCargoById(cargoId)
      local loc = cargo and cargo.location
      if loc and loc.type == "facilityParkingspot" and loc.facId == facId and loc.psPath == psPath then
        return true
      end
    end
    return false
  end
end

-- Constructor -------------------------------------------------------------------------------------

function part.new(inputs)
  local api = inputs.api or {}
  local runtime = inputs.runtime

  inputs.runtime.bindAssignedInFlight = false
  runtime.PARCEL_LOAD_CLEARANCE_RATIO = 0.60
  runtime.PARCEL_LOAD_CLEARANCE_MAX_TRIMS = 12

  installReturnText(api, inputs)
  installCargoLocations(api, inputs)
  installGroundClearance(api, inputs)
  installClearanceTrim(api, inputs)
  installBaySlots(api)
  installCargoBinding(api, inputs)
  installAssignedPickup(api, inputs)
  return api
end

return part
