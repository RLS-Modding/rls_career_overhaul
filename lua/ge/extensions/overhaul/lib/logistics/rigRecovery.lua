-- Vehicle recovery preserves existing damage and settles each operation once.
-- Read rig collection and destination planning, then scan, release, clear and settlement steps.
local M = {}

local rigPlacement = require("overhaul/lib/vehicles/placement").strategy("rigRecovery")

-- Config ------------------------------------------------------------------------------------------

local LOCAL_FORWARD = vec3(0, -1, 0)

-- State -------------------------------------------------------------------------------------------

-- One operation per kind is in flight at a time; M.recover refuses new work while any is set.
local pending
local releasing
local scanning

-- Helpers -----------------------------------------------------------------------------------------

local function suppressPoliceSpeedSpike(ids)
  local answer = {handled = false}
  if overhaul_shell_gameMode and overhaul_shell_gameMode.isActive() then
    extensions.hook('onOverhaulRecoverySpeedSpike', ids, answer)
    if answer.handled then return end
  end
  local police = gameplay_police
  if police and police.ignoreSpeedingAfterRecovery then
    police.ignoreSpeedingAfterRecovery(ids)
  elseif police and police.ignoreSpeedingAfterTeleport then
    police.ignoreSpeedingAfterTeleport()
  end
end

local function nodeOffset(id, name, transform)
  local data = core_vehicle_manager.getVehicleData(id)
  for _, node in pairs(data and data.vdata and data.vdata.nodes or {}) do
    if node.name == name or node.cid == name then
      local obj = getObjectByID(id)
      if transform and obj then
        local position = obj:getPosition() + obj:getNodePosition(node.cid)
        return (transform * MatrixF(true)):inverse():mulP3F(position), node.couplerTag or node.tag
      end
      local offsets = core_vehicles.vehsCouplerOffset[id]
      return offsets and offsets[node.cid], node.couplerTag or node.tag
    end
  end
end

local function couplerIsOnFrontSide(couplerOffset, veh)
  if not couplerOffset or not veh or not veh.initialCollidableNodePosBB then
    return false
  end
  local refNodeInitial = veh:getInitialNodePosition(veh:getRefNodeId())
  local centerOffset = veh.initialCollidableNodePosBB:getCenter() - refNodeInitial
  return (couplerOffset - centerOffset):dot(LOCAL_FORWARD) > 0
end

local function hitchRotation(parentId, childId, parentOffset, childOffset)
  local rotation = MatrixF(true)
  local parentObj, childObj = getObjectByID(parentId), getObjectByID(childId)
  if parentObj and childObj and couplerIsOnFrontSide(parentOffset, parentObj) == couplerIsOnFrontSide(childOffset, childObj) then
    rotation:setFromEuler(vec3(0, 0, math.pi))
  end
  return rotation
end

-- True when the coupler pair (either order) is still attached in the engine.
local function sameCouplerPair(pair, a, b)
  return (pair[1] == a and pair[2] == b) or (pair[2] == a and pair[1] == b)
end

local function isCoupled(a, b)
  for _, pair in ipairs(core_vehicles.attachedCouplers or {}) do
    if sameCouplerPair(pair, a, b) then return true end
  end
  return false
end

-- Recovery drives on the road, so the rig faces flat; a degenerate direction falls back to north.
local function flatDirection(dir)
  local flat = vec3(dir.x, dir.y, 0)
  if flat:squaredLength() < 0.01 then flat = vec3(0, 1, 0) end
  return flat
end

-- Reports to the caller's completion callback when one was given.
local function report(completed, success, why)
  if completed then completed(success, why) end
end

local function rearmHinges(group, hinges)
  for _, hinge in ipairs(hinges or {}) do
    local obj = group.objects[hinge.parent] or getObjectByID(hinge.parent)
    if not isCoupled(hinge.parent, hinge.id) and obj and hinge.tag then
      pcall(obj.queueLuaCommand, obj, string.format("beamstate.activateAutoCoupling(%q)", hinge.tag))
    end
  end
end


local function pruneCargo(node, isRoot)
  if not node then return nil end
  if not isRoot and M.isRecoveryCargo(node.vehId) then return nil end
  local copy = {}
  for key, value in pairs(node) do copy[key] = value end
  copy.children = {}
  for _, child in ipairs(node.children or {}) do
    local kept = pruneCargo(child, false)
    if kept then copy.children[#copy.children + 1] = kept end
  end
  return copy
end

local function treeIds(node, into)
  if not node then return into end
  if node.vehId then into[node.vehId] = true end
  for _, child in ipairs(node.children or {}) do treeIds(child, into) end
  return into
end

-- Cuts recovery cargo out of the coupler tree and drops it from the ids the rig will move.
local function pruneLeftCargo(tree, ids)
  local allIds = treeIds(tree, {})
  local prunedTree = pruneCargo(tree, true)
  local keptIds = treeIds(prunedTree, {})
  local filtered = {}
  for _, id in ipairs(ids) do
    if not M.isRecoveryCargo(id) and (keptIds[id] or not allIds[id]) then filtered[#filtered + 1] = id end
  end
  return prunedTree, filtered
end

-- Records a vehicle's pose the first time it joins the group; false when it is not loaded.
local function addMember(members, id)
  if members.seen[id] then return true end
  local obj = getObjectByID(id)
  if not obj then return false end
  local rotation = obj:getClusterRotationSlow(obj:getRefNodeId())
  local transform = QuatF(rotation.x, rotation.y, rotation.z, rotation.w):getMatrix()
  transform:setColumn(3, obj:getPosition())
  members.seen[id], members.objects[id], members.original[id] = true, obj, transform
  return true
end

local function addCarried(members, ids, child, parent)
  members.carried[#members.carried + 1] = { id = child, parent = parent,
    offset = (members.original[parent] * MatrixF(true)):inverse() * members.original[child] }
  ids[#ids + 1] = child
end

-- Adds cargo that task tracking says rides on the rig. Returns true while load detection is still waiting.
local function addCarriedFromTasks(members, ids, leaveCargo, inv, tasks)
  local candidates = {}
  for _, id in pairs(inv and inv.getMapInventoryIdToVehId() or {}) do candidates[id] = true end
  for _, task in ipairs(tasks.readTasks()) do
    if not task.remove then candidates[task.vehId] = true end
  end
  local ordered = {}
  for id in pairs(candidates) do ordered[#ordered + 1] = id end
  table.sort(ordered)
  for _, child in ipairs(ordered) do
    if not members.seen[child] and not (leaveCargo and M.isRecoveryCargo(child)) then
      local parent, waiting = tasks.carrierOf(child, ids)
      if parent and addMember(members, child) then
        addCarried(members, ids, child, parent)
      elseif waiting then
        return true
      end
    end
  end
  return false
end

-- Adds carried vehicles from the saved inventory manifest, parents before children.
local function addCarriedFromManifest(members, ids, leaveCargo, inv, capture)
  local active = inv.getMapInventoryIdToVehId()
  local manifest = capture(active)
  for _ = 1, #(manifest.carriedVehicles or {}) + 1 do
    for _, relation in ipairs(manifest.carriedVehicles or {}) do
      local parent, child = active[relation.parentInventoryId], active[relation.inventoryId]
      if parent and child and members.seen[parent] and not members.seen[child]
          and not (leaveCargo and M.isRecoveryCargo(child)) and addMember(members, child) then
        addCarried(members, ids, child, parent)
      end
    end
  end
end

local function planHinges(group)
  local hinges = {}
  local function inspect(node, parent)
    if not node then return true end
    if not group.objects[node.vehId] or not group.original[node.vehId] then return false end
    if parent then
      local relation = node.offsetData or {}
      local a, tag = nodeOffset(parent, relation.parentNode, group.original[parent])
      local b = nodeOffset(node.vehId, relation.node, group.original[node.vehId])
      if not a or not b then return false end
      hinges[#hinges + 1] = {
        id = node.vehId,
        parent = parent,
        a = a,
        b = b,
        rotation = hitchRotation(parent, node.vehId, a, b),
        tag = tag,
      }
    end
    for _, child in ipairs(node.children or {}) do
      if not inspect(child, node.vehId) then return false end
    end
    return true
  end
  if not inspect(group.tree) then
    return nil, "The trailer coupling data is not ready. Try again after the vehicle finishes loading."
  end
  return hinges
end

local function startRecovery(group, hinges, destinations, mode, completed, validate)
  local ok, err = pcall(function()
    suppressPoliceSpeedSpike(group.ids)
    for _, id in ipairs(group.ids) do
      rigPlacement.moveVehicle(group.objects[id], destinations[id])
    end
    rearmHinges(group, hinges)
  end)
  if not ok then
    suppressPoliceSpeedSpike(group.ids)
    log("E", "logisticsRecovery", tostring(err))
    return false, "Recovery could not complete. Your job and vehicles have been retained."
  end
  if completed then
    pending = {
      group = group,
      destinations = destinations,
      hinges = hinges,
      elapsed = 0,
      completed = completed,
      mode = mode,
      validate = validate,
    }
  end
  return true
end

local function finishPlan(operation, destinations, reason)
  if not destinations then
    return false, reason or "Recovery could not complete. Your job and vehicles have been retained."
  end
  if operation.mode == "road" then
    if #rigPlacement.blockingTraffic(operation.group, destinations) > 0 then
      operation.destinations, operation.elapsed, operation.clearingTraffic = destinations, 0, true
      operation.search = nil
      pending = operation
      return true
    end
    if not rigPlacement.placementClear(operation.group, destinations) then
      return false, "The recovery position is still blocked. Nothing was moved."
    end
  end
  return startRecovery(operation.group, operation.hinges, destinations, operation.mode, operation.completed, operation.validate)
end

local function validateOperationGroup(operation)
  for _, id in ipairs(operation.group.ids) do
    local allowed, reason = operation.validate(id)
    if not allowed then return false, reason end
    local obj = getObjectByID(id)
    if not obj or (obj:getPosition() - operation.group.original[id]:getColumn(3)):squaredLength() > 1 then
      return false, "The rig moved while preparing recovery. Nothing was moved."
    end
  end
  return true
end

local function continueRoadSearch(operation)
  local allowed, why = validateOperationGroup(operation)
  if not allowed then return false, why end
  local ok, destinations, reason = coroutine.resume(operation.search)
  if not ok then
    log("E", "logisticsRecovery", tostring(destinations))
    return false, "Recovery could not find a safe road position. Nothing was moved."
  end
  if coroutine.status(operation.search) ~= "dead" then
    pending = operation
    return true
  end
  return finishPlan(operation, destinations, reason)
end

-- Update ------------------------------------------------------------------------------------------

local function updateScan(dtSim)
  local scan = scanning
  scan.elapsed = scan.elapsed + (dtSim or 0)
  scanning = nil
  local ok, why = M.recover(scan.vehId, scan.mode, scan.validate, scan.completed)
  if scanning then
    scanning.elapsed = scan.elapsed
    if scanning.elapsed >= 2 then
      scanning = nil
      scan.completed(false, "Load detection is not ready. Nothing was moved and no recovery fee was charged.")
    end
  elseif not ok then
    scan.completed(false, why)
  end
end

local function updateRelease(dtSim)
  local release = releasing
  release.elapsed = release.elapsed + (dtSim or 0)
  local released = M.cargoReleased(release.connections)
  if not released and release.elapsed < 2 then return end
  releasing = nil
  if not released then
    report(release.completed, false, "The recovery vehicle could not be unhitched. No recovery fee was charged.")
    return
  end
  M.forgetCargoPairs(release.connections)
  local ok, why = M.recover(release.vehId, release.mode, release.validate, release.completed)
  if not ok then
    report(release.completed, false, why or "Recovery could not complete. Your job and vehicles have been retained.")
  end
end

-- The guarded traffic step, run under pcall: relocate blocking traffic first, then delete it and place the rig.
local function trafficClearStep(operation)
  local allowed, reason = validateOperationGroup(operation)
  if not allowed then return false, reason end
  local blocked = rigPlacement.blockingTraffic(operation.group, operation.destinations)
  if not operation.trafficRelocated then
    operation.trafficRelocated, operation.elapsed = true, 0
    for _, other in ipairs(blocked) do
      if gameplay_traffic.forceTeleport then
        gameplay_traffic.forceTeleport(other:getID(), operation.destinations[operation.group.root]:getColumn(3))
      end
    end
    pending = operation
    return true
  end
  for _, other in ipairs(blocked) do other:delete() end
  if not rigPlacement.placementClear(operation.group, operation.destinations) then
    return false, "The recovery position is still blocked. Nothing was moved."
  end
  return startRecovery(operation.group, operation.hinges, operation.destinations, operation.mode, operation.completed, operation.validate)
end

local function updateTrafficClear(operation)
  if operation.elapsed < 0.1 then return end
  pending = nil
  local ran, success, why = pcall(trafficClearStep, operation)
  if not ran then
    report(operation.completed, false, "Recovery could not clear the road position. No recovery fee was charged.")
  elseif not success then
    report(operation.completed, false, why or "The recovery position is still blocked. No recovery fee was charged.")
  end
end

-- True once every vehicle is upright at its destination and every hinge has reconnected.
local function operationReady(operation)
  for _, id in ipairs(operation.group.ids) do
    local obj = getObjectByID(id)
    if not obj or (obj:getPosition() - operation.destinations[id]:getColumn(3)):squaredLength() > 4
        or obj:getDirectionVectorUp().z < 0.5 then
      return false
    end
  end
  for _, hinge in ipairs(operation.hinges) do
    if not isCoupled(hinge.parent, hinge.id) then return false end
  end
  return true
end

-- Last resort for a rig that never settled: upright it where it stands, or retry on the road.
local function settleStalled(operation)
  if operation.elapsed < 4 then return end
  pending = nil
  suppressPoliceSpeedSpike(operation.group.ids)
  if rigPlacement.groupUprightOnTerrain(operation.group) then
    rearmHinges(operation.group, operation.hinges)
    operation.completed(true, nil, operation.mode)
    return
  end
  if operation.mode ~= "road" then
    local ok, why = M.recover(operation.group.root, "road", operation.validate, operation.completed)
    if ok then return end
    operation.completed(false, why or "Recovery could not safely place and reconnect the rig. No recovery fee was charged; your jobs remain active.")
    return
  end
  operation.completed(false, "Recovery could not safely place and reconnect the rig. No recovery fee was charged; your jobs remain active.")
end

local function updateSettling(operation)
  if operation.elapsed < 0.75 then return end
  if operationReady(operation) then
    pending = nil
    suppressPoliceSpeedSpike(operation.group.ids)
    operation.completed(true, nil, operation.mode)
    return
  end
  settleStalled(operation)
end

function M.update(dtSim)
  if scanning then return updateScan(dtSim) end
  if releasing then return updateRelease(dtSim) end
  if not pending then return end
  local operation = pending
  if operation.search then
    pending = nil
    local ok, why = continueRoadSearch(operation)
    if not ok and operation.completed then operation.completed(false, why) end
    return
  end
  operation.elapsed = operation.elapsed + dtSim
  if operation.clearingTraffic then return updateTrafficClear(operation) end
  return updateSettling(operation)
end

-- Public API --------------------------------------------------------------------------------------

function M.isRecoveryCargo(vehId)
  vehId = tonumber(vehId)
  if not vehId then return false end
  local answer = {isCargo = false}
  extensions.hook("onOverhaulIsRecoveryCargo", vehId, answer)
  return answer.isCargo
end

function M.cargoConnections(members)
  local list = {}
  for _, connection in ipairs(core_vehicles.attachedCouplers or {}) do
    local a, b = connection[1], connection[2]
    if (members[a] and not members[b] and M.isRecoveryCargo(b))
        or (members[b] and not members[a] and M.isRecoveryCargo(a)) then
      list[#list + 1] = connection
    end
  end
  return list
end

function M.releaseCargo(connections)
  for _, connection in ipairs(connections) do
    local a, b = getObjectByID(connection[1]), getObjectByID(connection[2])
    if a then a:queueLuaCommand(string.format("beamstate.disableAutoCoupling(); obj:detachCoupler(%d, 0)", connection[3])) end
    if b then b:queueLuaCommand("beamstate.disableAutoCoupling()") end
  end
end

function M.cargoReleased(connections)
  for _, connection in ipairs(connections) do
    if isCoupled(connection[1], connection[2]) then return false end
  end
  return true
end

function M.forgetCargoPairs(connections)
  local trailerData = core_trailerRespawn and core_trailerRespawn.getTrailerData and core_trailerRespawn.getTrailerData()
  if not trailerData then return end
  for _, connection in ipairs(connections) do
    for _, pair in ipairs({ { connection[1], connection[2] }, { connection[2], connection[1] } }) do
      local registered = trailerData[pair[1]]
      if type(registered) == "table" and registered.trailerId == pair[2] then trailerData[pair[1]] = nil end
    end
  end
end

-- Gathers the rig: the coupled root, its trailers and any carried vehicles, each with its pose. Returns nil, reason, and a waiting flag when load detection has not finished yet.
function M.collect(vehId, opts)
  local ids = { vehId }
  overhaul_vehicles_playerVehicles.fillCouplerGroup(vehId, ids, { resolveLead = true })
  local root = ids[1]
  local tree = core_vehicles.generateAttachedVehiclesTree(root)
  local leaveCargo = opts and opts.leaveCargo and not M.isRecoveryCargo(root) and not M.isRecoveryCargo(vehId)
  if leaveCargo then
    tree, ids = pruneLeftCargo(tree, ids)
  end
  local members = { seen = {}, objects = {}, original = {}, carried = {} }
  for _, id in ipairs(ids) do
    if not addMember(members, id) then return nil, "A connected vehicle is unavailable." end
  end
  local inv = overhaul_career_garage_inventory
  local tasks, relationships = {}, {}
  if opts and opts.leaveCargo then extensions.hook("onOverhaulRecoveryCargoCarriers", tasks) end
  if not tasks.carrierOf and inv then extensions.hook("onOverhaulRecoveryRelationships", relationships) end
  if opts and opts.leaveCargo and tasks.carrierOf then
    if addCarriedFromTasks(members, ids, leaveCargo, inv, tasks) then
      return nil, "Load detection is still checking this rig. Try again in a moment.", true
    end
  elseif inv and relationships.capture then
    addCarriedFromManifest(members, ids, leaveCargo, inv, relationships.capture)
  end
  return { root = root, ids = ids, objects = members.objects, original = members.original, carried = members.carried,
    tree = tree, cargoConnections = leaveCargo and M.cargoConnections(members.seen) or {} }
end

function M.recover(vehId, mode, validate, completed)
  if pending or releasing or scanning then return false, "Please wait for the current recovery to finish." end
  local group, reason, waiting = M.collect(vehId, { leaveCargo = mode == "road" })
  if not group then
    if waiting and completed then
      scanning = { vehId = vehId, mode = mode, validate = validate, completed = completed, elapsed = 0 }
      return true
    end
    return false, reason
  end
  for _, id in ipairs(group.ids) do
    local ok, why = validate(id)
    if not ok then return false, why end
  end
  if #group.cargoConnections > 0 then
    M.releaseCargo(group.cargoConnections)
    releasing = {
      vehId = vehId, mode = mode, validate = validate, completed = completed,
      connections = group.cargoConnections, elapsed = 0,
    }
    return true
  end
  local root = group.objects[group.root]
  local pos, dir = root:getPosition(), root:getDirectionVector()
  if mode == "road" then
    local roadPos, roadDir, why = rigPlacement.roadTarget(pos, dir)
    if not roadPos then return false, why end
    pos, dir = roadPos, roadDir
  end
  dir = flatDirection(dir)

  local hinges, hingeReason = planHinges(group)
  if not hinges then return false, hingeReason end

  local operation = { group = group, hinges = hinges, mode = mode, completed = completed, validate = validate }
  local destinations = nil
  local planReason = nil
  if mode ~= "road" then
    destinations, planReason = rigPlacement.planDestinations(group, hinges, pos, dir)
    if not destinations then
      local roadPos, roadDir = rigPlacement.roadTarget(root:getPosition(), root:getDirectionVector())
      if roadPos then
        operation.mode, pos = "road", roadPos
        dir = flatDirection(roadDir)
      end
    end
  end
  if operation.mode == "road" then
    operation.search = rigPlacement.planRoadDestinations(group, hinges, pos, dir)
    return continueRoadSearch(operation)
  end
  return finishPlan(operation, destinations, planReason)
end

return M
