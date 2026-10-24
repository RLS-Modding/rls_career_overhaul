-- Garage towing coordinates vehicle groups through the shared garageTow placement strategy.
-- Read protected jobs, group validation and manifests, movement, then public tow hooks.
local M = {}

local garageTow = require('overhaul/lib/vehicles/placement').strategy('garageTow')
M.plan = garageTow.plan

-- Config ------------------------------------------------------------------------------------------

local LOG_TAG = "garageVehicleTransport"
local PLACEMENT_SETTLE_SECONDS = 0.1
local POLL_SECONDS = 0.05
local POLL_LIMIT = 40
local UNHITCH_FAILED_MESSAGE = "The recovery vehicle could not be unhitched. Tow cancelled; no charge."
local TOW_CHANGED_MESSAGE = "Tow cancelled: vehicle or map changed."
local NO_SPOTS_MESSAGE = "No free garage spots fit your vehicle and trailer. Nothing was moved or charged."
local PLACEMENT_RESTORED_MESSAGE =
  "Vehicle placement failed. Positions restored; no tow charge. Check trailer couplings before driving."

-- State -------------------------------------------------------------------------------------------

local active = false

-- Shared helpers ----------------------------------------------------------------------------------

local function failTow(callback, message)
  active = false
  ui_message(message, 8, "warning")
  if callback then callback(false, message) end
  return false
end

-- An error inside a tow job must not leave the tow lock set until the level unloads.
local function protectedJob(body, onError)
  core_jobsystem.create(function(job)
    local ok, err = pcall(body, job)
    if not ok then
      log("E", LOG_TAG, tostring(err))
      onError(job)
    end
  end)
end

-- Vehicle groups ----------------------------------------------------------------------------------

local function towRelations(mapping, manifest)
  local children, loaded = {}, {}
  local function visit(node)
    local id = mapping[tonumber(node.inventoryId)]
    if id then
      children[id] = {}
      for _, child in ipairs(node.children or {}) do
        local childId = mapping[tonumber(child.inventoryId)]
        if childId then children[id][#children[id] + 1] = childId end
        visit(child)
      end
    end
  end
  for _, group in ipairs(manifest.groups) do visit(group.tree) end
  for _, relation in ipairs(manifest.carriedVehicles or {}) do
    local parent, child = mapping[tonumber(relation.parentInventoryId)], mapping[tonumber(relation.inventoryId)]
    if parent and child then loaded[parent] = loaded[parent] or {}; table.insert(loaded[parent], child) end
  end
  return children, loaded
end

local function collectTowVehicleGroups(mapping, manifest, rigRecovery, rootId)
  local leaveCargo = not rigRecovery.isRecoveryCargo(rootId)
  local function isCargo(id) return leaveCargo and id ~= rootId and rigRecovery.isRecoveryCargo(id) end
  local children, loaded = towRelations(mapping, manifest)
  local objects, original, groups, memberGroup = {}, {}, {}, {}

  -- A nil group starts a new tow group rooted at this vehicle.
  local function add(id, group)
    if not group then
      group = {root = id, ids = {}}
      groups[#groups + 1] = group
    end
    if memberGroup[id] or isCargo(id) then return end
    local object = getObjectByID(id)
    if not object then return end
    objects[id], memberGroup[id] = object, group
    original[id] = {
      pos = vec3(object:getPosition()),
      rot = quat(object:getClusterRotationSlow(object:getRefNodeId())),
    }
    group.ids[#group.ids + 1] = id
    for _, child in ipairs(loaded[id] or {}) do add(child, group) end
    for _, child in ipairs(children[id] or {}) do
      if not memberGroup[child] and not isCargo(child) then add(child) end
    end
  end

  local function newlyReached(from, to)
    if memberGroup[from] and to and not memberGroup[to] and not isCargo(to) then return to end
  end

  add(rootId)
  local progress = true
  while progress do
    progress = false
    for _, connection in ipairs(core_vehicles.attachedCouplers or {}) do
      local a, b = connection[1], connection[2]
      local reached = newlyReached(a, b) or newlyReached(b, a)
      if reached then
        add(reached)
        progress = true
      end
    end
  end
  return objects, original, groups, memberGroup, leaveCargo
end

-- Spots and positions -----------------------------------------------------------------------------

local function towParkingSpotIsClear(spot, objects)
  if not spot.hasAnyVehicles then return false end
  local occupied, ids = spot:hasAnyVehicles()
  if not occupied then return true end
  if not ids or not ids[1] then return false end
  for _, id in ipairs(ids) do if not objects[id] then return false end end
  return true
end

local function groupFitsSpot(objects, group, spot)
  local size, offset = garageTow.footprint(group, objects)
  group.offset = offset
  return spot.scl and size.x <= (spot.scl.x or 0) and size.y <= (spot.scl.y or 0) and size.z <= (spot.scl.z or 0)
end

local function towIsValid(placement)
  if placement.level ~= getCurrentLevelIdentifier() or placement.inventory ~= overhaul_career_garage_inventory then
    return false
  end
  for id, object in pairs(placement.objects) do
    if getObjectByID(id) ~= object then return false end
  end
  return true
end

local function restorePositions(placement, job)
  job.sleep(PLACEMENT_SETTLE_SECONDS)
  for id, pose in pairs(placement.original) do
    local object = getObjectByID(id)
    if object then
      local current = quat(object:getClusterRotationSlow(object:getRefNodeId()))
      garageTow.moveCluster(object, pose.pos, current:inversed() * pose.rot)
    end
  end
end

-- Returns false with "occupied" or the thrown error when the plan cannot be placed.
local function placeEntries(placement, plan)
  local objects = placement.objects
  for _, entry in ipairs(plan) do
    if entry.spot and not towParkingSpotIsClear(entry.spot, objects) then return false, "occupied" end
  end
  local ok, err = pcall(function()
    for _, entry in ipairs(plan) do
      groupFitsSpot(objects, entry.group, entry.spot)
      garageTow.placeGroup(entry, objects)
    end
  end)
  if not ok then return false, err end
  return true
end

-- Coupled placement ---------------------------------------------------------------------------------

-- Returns true when the job is over: the tow was placed, or it was cancelled and reported.
local function tryCoupledPlacements(placement, job)
  local callback = placement.request.callback
  for _, entry in ipairs(placement.coupledTries) do
    if not towIsValid(placement) then failTow(callback, TOW_CHANGED_MESSAGE); return true end
    if placeEntries(placement, {entry}) then
      job.sleep(PLACEMENT_SETTLE_SECONDS)
      if not towIsValid(placement) then failTow(callback, TOW_CHANGED_MESSAGE); return true end
      if not garageTow.placementBlocked(entry.group.ids, placement.objects) then
        active = false
        if callback then callback(true) end
        return true
      end
    end
  end
  return false
end

-- Split placement ---------------------------------------------------------------------------------

local function hitchConnections(placement, plan)
  local objects = placement.objects
  local destinations, connections, seen = {}, {}, {}
  for _, entry in ipairs(plan) do
    for _, id in ipairs(entry.group.ids) do destinations[id] = entry end
  end
  for _, connection in ipairs(core_vehicles.attachedCouplers or {}) do
    if objects[connection[1]] or objects[connection[2]] then
      if not objects[connection[1]] or not objects[connection[2]] then
        return nil, "Select the lead vehicle before towing this coupled group."
      end
      if destinations[connection[1]] ~= destinations[connection[2]] then
        local key = table.concat(connection, ':')
        if not seen[key] then
          seen[key] = true
          connections[#connections + 1] = {connection[1], connection[2], connection[3], connection[4], key = key}
        end
      end
    end
  end
  return connections, nil, seen
end

local function removeDuplicateCouplers(seen)
  local retained = {}
  for i = #(core_vehicles.attachedCouplers or {}), 1, -1 do
    local key = table.concat(core_vehicles.attachedCouplers[i], ':')
    if seen[key] and retained[key] then table.remove(core_vehicles.attachedCouplers, i) end
    retained[key] = true
  end
end

local function queueDetachCommands(objects, connections)
  for _, connection in ipairs(connections) do
    objects[connection[1]]:queueLuaCommand(string.format('beamstate.disableAutoCoupling(); obj:detachCoupler(%d, 0)', connection[3]))
    objects[connection[2]]:queueLuaCommand('beamstate.disableAutoCoupling()')
  end
end

local function couplersDetached(connections)
  for _, connection in ipairs(connections) do
    for _, current in ipairs(core_vehicles.attachedCouplers or {}) do
      if (current[1] == connection[1] and current[2] == connection[2])
        or (current[2] == connection[1] and current[1] == connection[2]) then return false end
    end
  end
  return true
end

-- Returns "detached", "stuck", or "cancelled" once the cancellation has been reported.
local function waitForDetach(placement, job, connections)
  for _ = 1, POLL_LIMIT do
    if couplersDetached(connections) then break end
    job.sleep(POLL_SECONDS)
    if not towIsValid(placement) then
      failTow(placement.request.callback, TOW_CHANGED_MESSAGE)
      return "cancelled"
    end
  end
  return couplersDetached(connections) and "detached" or "stuck"
end

local function forgetTrailerRegistrations(connections)
  local trailerData = core_trailerRespawn and core_trailerRespawn.getTrailerData()
  for _, connection in ipairs(connections) do
    for _, pair in ipairs({{connection[1], connection[2]}, {connection[2], connection[1]}}) do
      local registered = trailerData and trailerData[pair[1]]
      if type(registered) == 'table' and registered.trailerId == pair[2] then trailerData[pair[1]] = nil end
    end
  end
end

local function placeSplitGroups(placement, job)
  local callback = placement.request.callback
  local splitPlan = placement.splitPlan
  local connections, hitchError, seen = hitchConnections(placement, splitPlan)
  if hitchError then
    restorePositions(placement, job)
    failTow(callback, hitchError)
    return
  end
  removeDuplicateCouplers(seen)
  queueDetachCommands(placement.objects, connections)
  local detachState = waitForDetach(placement, job, connections)
  if detachState == "cancelled" then return end
  if detachState == "stuck" then
    restorePositions(placement, job)
    failTow(callback, "Trailer could not be disconnected. Tow cancelled; no charge.")
    return
  end
  forgetTrailerRegistrations(connections)
  local ok, err = placeEntries(placement, splitPlan)
  if not ok then
    restorePositions(placement, job)
    if err == "occupied" then
      failTow(callback, "Garage spawn area became occupied. No tow charge; check trailer couplings before driving.")
    else
      log("E", LOG_TAG, tostring(err))
      failTow(callback, PLACEMENT_RESTORED_MESSAGE)
    end
    return
  end
  if #splitPlan > 1 then ui_message("Truck and trailer towed to the garage separately.", 8, "info") end
  active = false
  if callback then callback(true) end
end

local function placeTowedVehicles(placement, job)
  local callback = placement.request.callback
  if not towIsValid(placement) then failTow(callback, TOW_CHANGED_MESSAGE); return end
  if placement.coupledTries and tryCoupledPlacements(placement, job) then return end
  if not placement.splitPlan then
    restorePositions(placement, job)
    failTow(callback, NO_SPOTS_MESSAGE)
    return
  end
  placeSplitGroups(placement, job)
end

local function recoverFailedPlacement(placement, job)
  if not active then return end
  pcall(restorePositions, placement, job)
  failTow(placement.request.callback, PLACEMENT_RESTORED_MESSAGE)
end

-- Tow entry points --------------------------------------------------------------------------------

-- Recovery cargo is unhitched first, then the tow restarts once with cargoRetry set.
local function releaseTowRecoveryCargo(request, rigRecovery, cargoConnections)
  local callback = request.callback
  if request.cargoRetry then return failTow(callback, UNHITCH_FAILED_MESSAGE) end
  active = true
  local released, releaseError = pcall(rigRecovery.releaseCargo, cargoConnections)
  if not released then
    log("E", LOG_TAG, tostring(releaseError))
    return failTow(callback, UNHITCH_FAILED_MESSAGE)
  end
  protectedJob(function(job)
    for _ = 1, POLL_LIMIT do
      if rigRecovery.cargoReleased(cargoConnections) then break end
      job.sleep(POLL_SECONDS)
    end
    active = false
    if not rigRecovery.cargoReleased(cargoConnections) then
      failTow(callback, UNHITCH_FAILED_MESSAGE)
      return
    end
    rigRecovery.forgetCargoPairs(cargoConnections)
    if getObjectByID(request.rootId) ~= request.vehicle then
      failTow(callback, TOW_CHANGED_MESSAGE)
      return
    end
    M.tow(request.garageId, request.vehicle, callback, request.resetVeh, true)
  end, function()
    failTow(callback, UNHITCH_FAILED_MESSAGE)
  end)
  return true
end

local function isSingleVehicleTow(groups, rootId)
  if #groups ~= 1 or #groups[1].ids ~= 1 then return false end
  for _, connection in ipairs(core_vehicles.attachedCouplers or {}) do
    if connection[1] == rootId or connection[2] == rootId then return false end
  end
  return true
end

function M.tow(garageId, vehicle, callback, resetVeh, cargoRetry)
  if active then
    ui_message("A vehicle tow is already in progress.", 5, "warning")
    if callback then callback(false, "A vehicle tow is already in progress.") end
    return false
  end
  local inventory = overhaul_career_garage_inventory
  local capture = overhaul_career_garage_switchMap
  local function fail(message) return failTow(callback, message) end
  if not vehicle or not inventory or not capture or not capture.captureInventoryRelationships then
    return fail("Vehicle transport is not ready.")
  end
  local permissions = overhaul_career_permissions
  if permissions then
    local status = permissions.getStatusForTag("recoveryTowToGarage", {vehId = vehicle:getID(),
      inventoryId = inventory.getInventoryIdFromVehicleId(vehicle:getID())})
    if not status.allow then return fail(status.label or "Cancel current job to tow") end
  end
  local garage = overhaul_world_facilities.getGarage(garageId)
  if not garage then return fail("Garage is unavailable. Nothing was moved or charged.") end
  local spots = overhaul_world_facilities.getParkingSpotsForFacility(garage) or {}
  local mapping = inventory.getMapInventoryIdToVehId()
  local manifest = capture.captureInventoryRelationships(mapping)
  local rigRecovery = require('overhaul/lib/logistics/rigRecovery')
  local request = {
    garageId = garageId, vehicle = vehicle, callback = callback, resetVeh = resetVeh,
    cargoRetry = cargoRetry, rootId = vehicle:getID(),
  }
  local objects, original, groups, memberGroup, leaveCargo = collectTowVehicleGroups(mapping, manifest, rigRecovery, request.rootId)

  local cargoConnections = leaveCargo and rigRecovery.cargoConnections(memberGroup) or {}
  if #cargoConnections > 0 then return releaseTowRecoveryCargo(request, rigRecovery, cargoConnections) end
  local singleVehicle = isSingleVehicleTow(groups, request.rootId)
  if singleVehicle then
    active = true
    local dyno = overhaul_career_parts_dyno_dynoSession
    local dynoPaused = dyno and dyno.beginGarageTow and dyno.beginGarageTow(vehicle:getID())
    local ok, result = pcall(overhaul_world_facilities.teleportToGarage, garageId, vehicle, resetVeh, true)
    active = false
    if not ok or result ~= true then
      if dynoPaused then dyno.cancelGarageTow() end
      return fail("Vehicle placement failed. No tow charge.")
    end
    if callback then callback(true) end
    return true
  end
  local function clear(spot)
    return towParkingSpotIsClear(spot, objects)
  end
  local coupledTries, splitPlan = M.plan(groups, spots, function(group, spot) return groupFitsSpot(objects, group, spot) end, clear)
  if not coupledTries and not splitPlan then return fail(NO_SPOTS_MESSAGE) end

  active = true
  local placement = {
    request = request, inventory = inventory, level = getCurrentLevelIdentifier(),
    objects = objects, original = original, coupledTries = coupledTries, splitPlan = splitPlan,
  }
  protectedJob(function(job) placeTowedVehicles(placement, job) end,
    function(job) recoverFailedPlacement(placement, job) end)
  return true
end

-- Game hooks --------------------------------------------------------------------------------------

function M.onClientEndMission()
  active = false
end

return M
