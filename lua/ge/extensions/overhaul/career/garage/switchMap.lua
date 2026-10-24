-- Map travel from the garage: stages personal vehicles, works out which ride on carriers, switches the level.
-- Inventory persistence and vehicleTransport.lua call captureInventoryRelationships; read getGroups, then switchMap.
local M = {}
local levelData = require('overhaul/lib/world/levelData')
local carriedFrame = require('overhaul/lib/vehicles/carriedFrame')

-- Config ------------------------------------------------------------------------------------------

local TRAVEL_BLOCKED_MESSAGE = 'Finish or cancel Broker work and return rented equipment before travelling to another map.'
local MAX_CARRIED_RELATIVE_SPEED_SQUARED = 6.25 -- a child sliding faster than this on a carrier is not riding it
local BRAKE_CAPTURE_TIMEOUT_SECONDS = 0.5

-- State -------------------------------------------------------------------------------------------

local stagedVehicles = {}
local nextEntryOrder = 0
local walkingInside = false
local panelActive = false
local switchInProgress = false
local manualCarrierAssignments = {}
local nearbySelections = {}
local nearbyCandidates = {}
local stagingRefreshPending = false
-- Vehicle eligibility -----------------------------------------------------------------------------

-- Uses be:getObjectByID: the global getObjectByID caches the miss while a replaced vehicle is unregistered.

local function isUncoupledNearbyVehicle(vehId)
  for _, connection in ipairs(core_vehicles.attachedCouplers or {}) do
    if connection[1] == vehId or connection[2] == vehId then return false end
  end
  return true
end

local function isPersonalInventoryId(inventoryId)
  if type(inventoryId) ~= "number" and not (type(inventoryId) == "string" and tonumber(inventoryId)) then
    return false
  end
  local vehicle = overhaul_career_garage_inventory.getVehicle(inventoryId)
  return vehicle and vehicle.owned ~= false and vehicle.loanType == nil
end

local function getEligibleInventoryId(vehId, sessionIds)
  vehId = tonumber(vehId)
  if not vehId then return nil end
  local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)
  return (sessionIds and sessionIds[inventoryId] or isPersonalInventoryId(inventoryId)) and inventoryId or nil
end

local function getVehicleLabel(inventoryId)
  return overhaul_career_garage_inventory.getVehicleNiceNameTranslated(inventoryId) or ("Vehicle " .. tostring(inventoryId))
end

local function isWalkingSubject(subjectId)
  return subjectId == be:getPlayerVehicleID(0)
    and gameplay_walk
    and gameplay_walk.isWalking
    and gameplay_walk.isWalking()
end

local function getActivePersonalVehicles(sessionIds)
  local result = {}
  local inventoryMap = overhaul_career_garage_inventory.getMapInventoryIdToVehId()
  for inventoryId, vehId in pairs(inventoryMap or {}) do
    inventoryId = tonumber(inventoryId)
    vehId = tonumber(vehId)
    local object = vehId and be:getObjectByID(vehId) or nil
    if inventoryId and object and object:getActive() and (sessionIds and sessionIds[inventoryId] or isPersonalInventoryId(inventoryId)) then
      result[inventoryId] = vehId
    end
  end
  return result
end

local function pruneStagedVehicles()
  for vehId, entry in pairs(stagedVehicles) do
    local object = be:getObjectByID(vehId)
    local inventoryId = object and object:getActive() and getEligibleInventoryId(vehId) or nil
    if not inventoryId or inventoryId ~= entry.inventoryId then
      stagedVehicles[vehId] = nil
    end
  end
end

local function stageVehicle(vehId, inventoryId)
  if stagedVehicles[vehId] then return end
  nextEntryOrder = nextEntryOrder + 1
  stagedVehicles[vehId] = {inventoryId = inventoryId, order = nextEntryOrder}
end

-- Carrier detection -------------------------------------------------------------------------------

local function withinCarrierRange(childId, carrierId)
  local child, carrier = be:getObjectByID(childId), be:getObjectByID(carrierId)
  if not child or not carrier or not be:getObjectOOBBIsInitialized(carrierId) then return false end
  local delta = child:getPosition() - vec3(be:getObjectOOBBCenterXYZ(carrierId))
  local distanceSquared = 0
  for axis = 0, 2 do
    local halfAxis = vec3(be:getObjectOOBBHalfAxisXYZ(carrierId, axis))
    local length = halfAxis:length()
    if length <= 0 then return false end
    local outside = math.max(0, math.abs(delta:dot(halfAxis) / length) - length)
    distanceSquared = distanceSquared + outside * outside
  end
  return distanceSquared <= 64
end

local carrierTokens = {
  "flatbed", "rollback", "tiltdeck", "carcarrier", "car_hauler",
  "dryvan", "boxutility", "containertrailer",
}

local function containsCarrierToken(value, visited)
  if type(value) == "string" then
    local normalized = value:lower()
    for _, token in ipairs(carrierTokens) do
      if normalized:find(token, 1, true) then return true end
    end
    return false
  end
  if type(value) ~= "table" then return false end
  visited = visited or {}
  if visited[value] then return false end
  visited[value] = true
  for key, child in pairs(value) do
    if containsCarrierToken(key, visited) or containsCarrierToken(child, visited) then return true end
  end
  return false
end

-- The live object provides only the model; the inventory record retains its config path.
local function isCarrierVehicle(vehId, inventoryId)
  local object = be:getObjectByID(vehId)
  local inventoryVehicle = overhaul_career_garage_inventory.getVehicle(inventoryId) or {}
  if object and object.getJBeamFilename and containsCarrierToken(object:getJBeamFilename()) then return true end
  return containsCarrierToken(inventoryVehicle.model) or containsCarrierToken(inventoryVehicle.config)
end

local function isVehicleOnCarrier(childId, carrierId)
  if childId == carrierId
      or not be:getObjectOOBBIsInitialized(childId)
      or not be:getObjectOOBBIsInitialized(carrierId) then
    return false
  end
  local child = be:getObjectByID(childId)
  local carrier = be:getObjectByID(carrierId)
  if not child or not carrier then return false end
  local childVelocity = child:getVelocity()
  local carrierVelocity = carrier:getVelocity()
  if childVelocity and carrierVelocity
      and (childVelocity - carrierVelocity):squaredLength() > MAX_CARRIED_RELATIVE_SPEED_SQUARED then
    return false
  end

  local delta = vec3(be:getObjectOOBBCenterXYZ(childId)) - vec3(be:getObjectOOBBCenterXYZ(carrierId))
  local axes = {
    vec3(be:getObjectOOBBHalfAxisXYZ(carrierId, 0)),
    vec3(be:getObjectOOBBHalfAxisXYZ(carrierId, 1)),
    vec3(be:getObjectOOBBHalfAxisXYZ(carrierId, 2)),
  }
  local upIndex, upAmount = 1, -1
  for index = 1, 3 do
    local amount = math.abs(axes[index].z)
    if amount > upAmount then upIndex, upAmount = index, amount end
  end
  for index = 1, 3 do
    local half = axes[index]:length()
    if half < 0.25 then return false end
    local along = delta:dot(axes[index] / half)
    if index == upIndex then
      if along < -(half * 0.05) or along > half + 0.55 then return false end
    else
      local inset = half > 4 and 1.15 or 0.65
      if math.abs(along) > math.max(0.45, half - inset) then return false end
    end
  end
  return true
end

-- Vehicle trees -----------------------------------------------------------------------------------

local function captureRelativeOffset(childInventoryId, carrierInventoryId)
  local childId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(childInventoryId)
  local carrierId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(carrierInventoryId)
  local child = childId and be:getObjectByID(childId) or nil
  local carrier = carrierId and be:getObjectByID(carrierId) or nil
  if not child or not carrier then return nil end
  local ok, offset = pcall(function()
    local matrix = carrier:getRefNodeMatrix():inverse() * child:getRefNodeMatrix()
    local pos = matrix:getPosition()
    local rot = matrix:toEuler()
    return {x = pos.x, y = pos.y, z = pos.z, rx = rot.x, ry = rot.y, rz = rot.z}
  end)
  return ok and offset or nil
end

local function captureTreeNode(entry, parentInventoryId, sessionIds)
  if not entry then return nil end
  local inventoryId = getEligibleInventoryId(entry.vehId, sessionIds)
  if not inventoryId then return nil end
  local node = {
    inventoryId = inventoryId,
    label = getVehicleLabel(inventoryId),
    coupledParentInventoryId = parentInventoryId,
    children = {},
  }
  if entry.offsetData then
    node.parentNode = entry.offsetData.parentNode
    node.node = entry.offsetData.node
    node.couplerOffset = parentInventoryId and captureRelativeOffset(inventoryId, parentInventoryId) or nil
  end
  for _, child in ipairs(entry.children or {}) do
    local childNode = captureTreeNode(child, inventoryId, sessionIds)
    if childNode then node.children[#node.children + 1] = childNode end
  end
  table.sort(node.children, function(a, b) return tostring(a.inventoryId) < tostring(b.inventoryId) end)
  return node
end

local function singleVehicleTree(inventoryId)
  return {inventoryId = inventoryId, label = getVehicleLabel(inventoryId), children = {}}
end

local function flattenTree(node, into, depth, order)
  if not node then return end
  into[#into + 1] = {
    inventoryId = node.inventoryId,
    label = node.label,
    depth = depth or 0,
    coupledParentInventoryId = node.coupledParentInventoryId,
    order = order,
  }
  for _, child in ipairs(node.children or {}) do
    flattenTree(child, into, (depth or 0) + 1, order)
  end
end

local function markTreeSeen(node, seen)
  if not node then return end
  seen[node.inventoryId] = true
  for _, child in ipairs(node.children or {}) do
    markTreeSeen(child, seen)
  end
end

-- Groups and carrier assignments ------------------------------------------------------------------

-- Each pass drops one link of a carrier loop: the lowest-id automatic link, else the one where the walk closed.
local function removeAssignmentCycles(assignments, assignmentSources)
  while true do
    local ids = {}
    for inventoryId in pairs(assignments) do ids[#ids + 1] = inventoryId end
    table.sort(ids)
    local removed
    for _, inventoryId in ipairs(ids) do
      local path, pathIndex = {}, {}
      local cursor = inventoryId
      while cursor and assignments[cursor] do
        if pathIndex[cursor] then
          local removeId
          for index = pathIndex[cursor], #path do
            local candidate = path[index]
            if assignmentSources[candidate] == "auto" and (not removeId or candidate < removeId) then
              removeId = candidate
            end
          end
          removeId = removeId or cursor
          assignments[removeId] = nil
          assignmentSources[removeId] = nil
          removed = true
          break
        end
        path[#path + 1] = cursor
        pathIndex[cursor] = #path
        cursor = assignments[cursor]
      end
      if removed then break end
    end
    if not removed then return end
  end
end

local function sortedStagedEntries(sourceVehicles)
  local entries = {}
  for vehId, entry in pairs(sourceVehicles or stagedVehicles) do
    entries[#entries + 1] = {vehId = vehId, inventoryId = entry.inventoryId, order = entry.order}
  end
  table.sort(entries, function(a, b) return a.order < b.order end)
  return entries
end

local function hasMember(members, inventoryId)
  for _, member in ipairs(members) do
    if member.inventoryId == inventoryId then return true end
  end
  return false
end

local function makeGroup(tree, order, current)
  local members = {}
  flattenTree(tree, members, 0, order)
  return {rootInventoryId = tree.inventoryId, order = order, current = current, members = members, tree = tree}
end

-- The coupled tree around a staged vehicle, or the vehicle alone when the tree cannot be built.
local function coupledTreeFor(entry, sessionIds)
  local coupledIds = {}
  local ok = pcall(overhaul_vehicles_playerVehicles.fillCouplerGroup, entry.vehId, coupledIds, {resolveLead = true})
  if not ok then coupledIds[1] = entry.vehId end
  local rootVehId = coupledIds[1] or entry.vehId
  if getEligibleInventoryId(rootVehId, sessionIds) then
    local generatedOk, generated = pcall(core_vehicles.generateAttachedVehiclesTree, rootVehId)
    if generatedOk and generated then
      local tree = captureTreeNode(generated, nil, sessionIds)
      if tree then return tree end
    end
  end
  return singleVehicleTree(entry.inventoryId)
end

local function buildStagedGroups(entries, sessionIds, playerInventoryId)
  local groups, seen, coupledGroupByInventoryId = {}, {}, {}
  for _, entry in ipairs(entries) do
    if not seen[entry.inventoryId] then
      local tree = coupledTreeFor(entry, sessionIds)
      local group = makeGroup(tree, entry.order, false)
      markTreeSeen(tree, seen)
      group.current = playerInventoryId ~= nil and hasMember(group.members, playerInventoryId)
      groups[#groups + 1] = group
      for _, member in ipairs(group.members) do
        coupledGroupByInventoryId[member.inventoryId] = tree.inventoryId
      end
    end
  end
  return groups, seen, coupledGroupByInventoryId
end

local function collectCarrierInventoryIds(seen, activeVehicles)
  local carrierIds = {}
  for inventoryId in pairs(seen) do
    local vehId = activeVehicles[inventoryId]
    if vehId and isCarrierVehicle(vehId, inventoryId) then carrierIds[#carrierIds + 1] = inventoryId end
  end
  table.sort(carrierIds)
  return carrierIds
end

local function assignNearbySelections(scan)
  local seen, active = scan.seen, scan.activeVehicles
  for childId, parentId in pairs(nearbySelections) do
    if not seen[childId] and seen[parentId] and active[childId] and active[parentId]
        and isCarrierVehicle(active[parentId], parentId)
        and withinCarrierRange(active[childId], active[parentId]) then
      scan.autoAssignments[childId] = parentId
      scan.autoAdded[#scan.autoAdded + 1] = childId
    end
  end
end

local function nearestCarrierFor(scan, childInventoryId, childVehId)
  local groupOf, active = scan.coupledGroupByInventoryId, scan.activeVehicles
  local bestCarrierId, bestDistance
  for _, carrierInventoryId in ipairs(scan.carrierIds) do
    if childInventoryId ~= carrierInventoryId
        and groupOf[childInventoryId] ~= groupOf[carrierInventoryId]
        and isVehicleOnCarrier(childVehId, active[carrierInventoryId]) then
      local child = be:getObjectByID(childVehId)
      local carrier = be:getObjectByID(active[carrierInventoryId])
      local distance = child and carrier and (child:getPosition() - carrier:getPosition()):squaredLength() or math.huge
      if not bestDistance or distance < bestDistance then
        bestCarrierId = carrierInventoryId
        bestDistance = distance
      end
    end
  end
  return bestCarrierId
end

local function assignCarrierRiders(scan)
  for childInventoryId, childVehId in pairs(scan.activeVehicles) do
    local carrierId = nearestCarrierFor(scan, childInventoryId, childVehId)
    if carrierId then
      scan.autoAssignments[childInventoryId] = carrierId
      if not scan.seen[childInventoryId] and not (scan.useNearbySelections and nearbySelections[childInventoryId]) then
        scan.autoAdded[#scan.autoAdded + 1] = childInventoryId
      end
    end
  end
end

-- Vehicles that ride a carrier without being staged get a group of their own.
local function appendAutoAddedGroups(groups, scan, playerInventoryId)
  table.sort(scan.autoAdded)
  local autoOrder = nextEntryOrder
  for _, inventoryId in ipairs(scan.autoAdded) do
    autoOrder = autoOrder + 1
    groups[#groups + 1] = makeGroup(singleVehicleTree(inventoryId), autoOrder, playerInventoryId == inventoryId)
    scan.seen[inventoryId] = true
    scan.coupledGroupByInventoryId[inventoryId] = inventoryId
  end
end

-- Manual choices override automatic ones; a child set to 0 is forced off its carrier.
local function resolveAssignments(scan)
  local seen, groupOf = scan.seen, scan.coupledGroupByInventoryId
  local assignments, assignmentSources = {}, {}
  for childInventoryId, carrierInventoryId in pairs(scan.autoAssignments) do
    if seen[childInventoryId] and seen[carrierInventoryId] then
      assignments[childInventoryId] = carrierInventoryId
      assignmentSources[childInventoryId] = "auto"
    end
  end
  for childInventoryId, carrierInventoryId in pairs(manualCarrierAssignments) do
    if not seen[childInventoryId] then
      manualCarrierAssignments[childInventoryId] = nil
    elseif carrierInventoryId == 0 then
      assignments[childInventoryId] = nil
      assignmentSources[childInventoryId] = nil
    elseif seen[carrierInventoryId] and childInventoryId ~= carrierInventoryId
        and groupOf[childInventoryId] ~= groupOf[carrierInventoryId] then
      assignments[childInventoryId] = carrierInventoryId
      assignmentSources[childInventoryId] = "manual"
    else
      manualCarrierAssignments[childInventoryId] = nil
    end
  end
  removeAssignmentCycles(assignments, assignmentSources)
  return assignments, assignmentSources
end

local function getGroups(sourceVehicles, sessionIds)
  -- Quitting unloads the inventory before the end-mission staging reset publishes.
  if not overhaul_career_garage_inventory then return {}, {}, {} end
  if not sourceVehicles then pruneStagedVehicles() end
  local entries = sortedStagedEntries(sourceVehicles)
  local playerVehId = be:getPlayerVehicleID(0)
  local walking = gameplay_walk.isWalking()
  local playerInventoryId = not walking and getEligibleInventoryId(playerVehId, sessionIds) or nil

  local groups, seen, coupledGroupByInventoryId = buildStagedGroups(entries, sessionIds, playerInventoryId)
  local activeVehicles = getActivePersonalVehicles(sessionIds)
  local scan = {
    seen = seen,
    activeVehicles = activeVehicles,
    coupledGroupByInventoryId = coupledGroupByInventoryId,
    carrierIds = collectCarrierInventoryIds(seen, activeVehicles),
    autoAssignments = {},
    autoAdded = {},
    useNearbySelections = not sourceVehicles,
  }
  if scan.useNearbySelections then assignNearbySelections(scan) end
  assignCarrierRiders(scan)
  appendAutoAddedGroups(groups, scan, playerInventoryId)
  local assignments, assignmentSources = resolveAssignments(scan)

  table.sort(groups, function(a, b)
    if a.current ~= b.current then return a.current end
    return a.order < b.order
  end)
  return groups, assignments, assignmentSources
end

-- Staging panel -----------------------------------------------------------------------------------

local function canTravel()
  if switchInProgress then return false end
  local playerVehId = tonumber(be:getPlayerVehicleID(0))
  if isWalkingSubject(playerVehId) then return walkingInside end
  local entry = playerVehId and stagedVehicles[playerVehId]
  return entry ~= nil and getEligibleInventoryId(playerVehId) ~= nil
end

local function stagingUiLists(groups, assignments, assignmentSources)
  local vehicleCount = 0
  local uiGroups, uiVehicles, listed = {}, {}, {}
  for _, group in ipairs(groups) do
    vehicleCount = vehicleCount + #group.members
    uiGroups[#uiGroups + 1] = {
      rootInventoryId = group.rootInventoryId,
      current = group.current,
      members = group.members,
    }
    for _, member in ipairs(group.members) do
      if not listed[member.inventoryId] then
        listed[member.inventoryId] = true
        uiVehicles[#uiVehicles + 1] = {
          inventoryId = member.inventoryId,
          label = member.label,
          current = group.current and member.depth == 0,
          order = group.order,
          coupledParentInventoryId = member.coupledParentInventoryId,
          carrierInventoryId = assignments[member.inventoryId],
          carrierSource = assignmentSources[member.inventoryId],
          nearbySelected = nearbySelections[member.inventoryId] ~= nil,
        }
      end
    end
  end
  return uiGroups, uiVehicles, vehicleCount
end

local function getStagingData()
  local ok, groups, assignments, assignmentSources = pcall(getGroups)
  if not ok then
    log("E", "switchMap", "getGroups failed: " .. tostring(groups))
    groups, assignments, assignmentSources = {}, {}, {}
  end
  local uiGroups, uiVehicles, vehicleCount = stagingUiLists(groups, assignments, assignmentSources)
  local playerVehId = tonumber(be:getPlayerVehicleID(0))
  if panelActive and vehicleCount == 0 and not walkingInside
      and not (playerVehId and stagedVehicles[playerVehId]) then
    panelActive = false
  end
  return {
    visible = panelActive,
    walkingInside = walkingInside,
    canTravel = canTravel(),
    switching = switchInProgress,
    vehicleCount = vehicleCount,
    groupCount = #uiGroups,
    groups = uiGroups,
    vehicles = uiVehicles,
    nearbyVehicles = nearbyCandidates,
  }
end

local function publishStagingData()
  stagingRefreshPending = false
  local data = getStagingData()
  guihooks.trigger("MapTravelStaging", data)
  return data
end

local function refreshNearby()
  nearbyCandidates = {}
  if not panelActive or switchInProgress then return publishStagingData() end
  local groups = getGroups()
  local active = getActivePersonalVehicles()
  local listed, carriers = {}, {}
  for _, group in ipairs(groups) do
    for _, member in ipairs(group.members) do
      local id = member.inventoryId
      listed[id] = true
      if not nearbySelections[id] and active[id] and isCarrierVehicle(active[id], id) then carriers[id] = active[id] end
    end
  end
  for id, vehId in pairs(active) do
    if not listed[id] and isUncoupledNearbyVehicle(vehId) then
      local options = {}
      for parentId, parentVehId in pairs(carriers) do
        if withinCarrierRange(vehId, parentVehId) then
          options[#options + 1] = {value = parentId, label = getVehicleLabel(parentId)}
        end
      end
      table.sort(options, function(a, b) return a.value < b.value end)
      if #options > 0 then
        nearbyCandidates[#nearbyCandidates + 1] = {inventoryId = id, label = getVehicleLabel(id), carriers = options}
      end
    end
  end
  table.sort(nearbyCandidates, function(a, b) return a.inventoryId < b.inventoryId end)
  for id in pairs(nearbySelections) do
    if not listed[id] then
      nearbyCandidates[#nearbyCandidates + 1] = {inventoryId = id, label = getVehicleLabel(id), invalidSelection = true, carriers = {}}
    end
  end
  return publishStagingData()
end

-- Manifest and brake states -----------------------------------------------------------------------

local function buildManifest(levelName, sourceVehicles, sessionIds)
  local groups, assignments, assignmentSources = getGroups(sourceVehicles, sessionIds)
  local manifestGroups, carriedVehicles = {}, {}
  local currentInventoryId
  for _, group in ipairs(groups) do
    manifestGroups[#manifestGroups + 1] = {
      rootInventoryId = group.rootInventoryId,
      order = group.order,
      current = group.current,
      tree = group.tree,
    }
    if group.current then currentInventoryId = group.rootInventoryId end
  end
  for childInventoryId, carrierInventoryId in pairs(assignments) do
    local inventory = overhaul_career_garage_inventory
    local saved = inventory.getCarriedPlacement and inventory.getCarriedPlacement(childInventoryId, carrierInventoryId)
    local staging = not sourceVehicles
    if staging and saved and not saved.staged then saved = nil end
    local offset = saved and saved.offset or captureRelativeOffset(childInventoryId, carrierInventoryId)
    if offset then
      local support
      if saved then support = saved.support else
        support = carriedFrame.capture(
          be:getObjectByID(inventory.getVehicleIdFromInventoryId(childInventoryId)),
          be:getObjectByID(inventory.getVehicleIdFromInventoryId(carrierInventoryId)))
      end
      local relation = {
        inventoryId = childInventoryId,
        parentInventoryId = carrierInventoryId,
        source = assignmentSources[childInventoryId],
        offset = offset,
        support = support,
        brake = 0,
        parkingbrake = 0,
        staged = staging or (saved and saved.staged) or false,
      }
      if inventory.rememberCarriedPlacement then inventory.rememberCarriedPlacement(relation, relation.staged) end
      carriedVehicles[#carriedVehicles + 1] = relation
    end
  end
  if sourceVehicles and overhaul_career_garage_inventory.clearCarriedPlacement then
    for _, entry in pairs(sourceVehicles) do
      if not assignments[entry.inventoryId] then
        overhaul_career_garage_inventory.clearCarriedPlacement(entry.inventoryId)
      end
    end
  end
  table.sort(carriedVehicles, function(a, b) return a.inventoryId < b.inventoryId end)
  return {
    version = 2,
    source = getCurrentLevelIdentifier(),
    destination = levelName,
    walking = gameplay_walk.isWalking() or false,
    currentInventoryId = currentInventoryId,
    groups = manifestGroups,
    carriedVehicles = carriedVehicles,
  }
end

local function requestBrakeInput(vehicle, entry, field, electricsKey, completeOne)
  local requested = pcall(function()
    core_vehicleBridge.requestValue(vehicle, function(result)
      entry[field] = clamp(tonumber(result and result.result) or 0, 0, 1)
      completeOne()
    end, "electricsValue", electricsKey)
  end)
  if not requested then completeOne() end
end

-- Calls back once every brake reply is in, or after a timeout if a vehicle never answers.
local function captureBrakeStates(entries, callback)
  if #entries == 0 then callback() return end
  local pending = #entries * 2
  local finished = false
  local function completeOne()
    if finished then return end
    pending = pending - 1
    if pending <= 0 then
      finished = true
      callback()
    end
  end
  for _, entry in ipairs(entries) do
    local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(entry.inventoryId)
    local veh = vehId and be:getObjectByID(vehId) or nil
    if veh then
      requestBrakeInput(veh, entry, "brake", "brake_input", completeOne)
      requestBrakeInput(veh, entry, "parkingbrake", "parkingbrake_input", completeOne)
    else
      completeOne()
      completeOne()
    end
  end
  core_jobsystem.create(function(job)
    job.sleep(BRAKE_CAPTURE_TIMEOUT_SECONDS)
    if not finished then
      finished = true
      callback()
    end
  end)
end

-- Inventory ids that stay with the player through a travel even though they are not personal vehicles.
local function collectSessionInventoryIds(inventoryIds)
  local sessionIds = {}
  local employment = overhaul_career_work_employment
  for inventoryId in pairs(inventoryIds) do
    inventoryId = tonumber(inventoryId)
    local info = inventoryId and overhaul_career_garage_inventory.getVehicle(inventoryId)
    if inventoryId and ((info and (info.logisticsInUse or info.brokerRentalId or info.brokerJobId))
        or (employment and employment.shouldPersistVehicle and employment.shouldPersistVehicle(inventoryId))) then
      sessionIds[inventoryId] = true
    end
  end
  return sessionIds
end

-- Keeps the node when allowed; children of a dropped node become roots of their own.
local function pruneTree(node, allowed, rootGroups)
  local children = {}
  for _, child in ipairs(node.children or {}) do
    local kept = pruneTree(child, allowed, rootGroups)
    if kept then children[#children + 1] = kept end
  end
  if not allowed(node.inventoryId) then
    for _, child in ipairs(children) do
      child.coupledParentInventoryId = nil
      child.couplerOffset = nil
      rootGroups[#rootGroups + 1] = {tree = child, rootInventoryId = child.inventoryId}
    end
    return nil
  end
  node.children = children
  return node
end

local function appendTreeBrakeStates(node, brakeStates)
  brakeStates[#brakeStates + 1] = node
  for _, child in ipairs(node.children or {}) do appendTreeBrakeStates(child, brakeStates) end
end

local function captureInventoryRelationships(inventoryIds)
  local sessionIds = collectSessionInventoryIds(inventoryIds)
  local entries = {}
  for inventoryId, vehId in pairs(getActivePersonalVehicles(sessionIds)) do
    if inventoryIds[inventoryId] or inventoryIds[tostring(inventoryId)] then
      entries[vehId] = {inventoryId = inventoryId, order = tonumber(inventoryId) or 0}
    end
  end
  local manifest = buildManifest(getCurrentLevelIdentifier(), entries, sessionIds)
  local function allowed(id) return inventoryIds[id] or inventoryIds[tostring(id)] end

  local groups = {}
  for _, group in ipairs(manifest.groups) do
    if pruneTree(group.tree, allowed, groups) then groups[#groups + 1] = group end
  end
  manifest.groups = groups
  local carried = {}
  for _, relation in ipairs(manifest.carriedVehicles) do
    if allowed(relation.inventoryId) and allowed(relation.parentInventoryId) then carried[#carried + 1] = relation end
  end
  manifest.carriedVehicles = carried
  manifest.brakeStates = {}
  for _, group in ipairs(groups) do appendTreeBrakeStates(group.tree, manifest.brakeStates) end
  for _, relation in ipairs(carried) do manifest.brakeStates[#manifest.brakeStates + 1] = relation end
  return manifest
end

-- Travel ------------------------------------------------------------------------------------------

local function performSwitch(levelName, manifest)
  overhaul_career_garage_inventory.prepareMapTravel(manifest)
  local switchOk, accepted, reason = pcall(overhaul_career_career.switchCareerLevel, levelName)
  if not switchOk then
    reason = accepted
    accepted = false
  end
  if accepted then
    panelActive = false
    publishStagingData()
    overhaul_integration_services_parking.resetAll()
    return
  end
  switchInProgress = false
  overhaul_career_garage_inventory.clearPreparedMapTravel()
  guihooks.trigger("toastrMsg", {
    type = "error",
    title = "Map travel unavailable",
    msg = tostring(reason or "The destination could not be loaded."),
  })
  publishStagingData()
end

local function getTravelBlockers()
  local broker = overhaul_career_logistics_broker
  if not broker then return nil end
  if not broker.hasObligations() then return nil end
  return broker.getObligations()
end

local function publishTravelBlocked(levelName, blockers, message)
  guihooks.trigger("MapTravelBlocked", {
    destination = levelName,
    blockers = blockers or {jobs = {}, rentals = {}, totalFine = 0, count = 0},
    message = message,
  })
end

local function refuseTravel(levelName, reason)
  guihooks.trigger("MapTravelUnavailable", {
    destination = levelName, message = reason,
  })
  return false, reason
end

local function nearbyLoadOutOfRange(assignments)
  local active = getActivePersonalVehicles()
  for childId, parentId in pairs(nearbySelections) do
    if assignments[childId] ~= parentId or not active[childId] or not active[parentId]
        or not withinCarrierRange(active[childId], active[parentId])
        or not isUncoupledNearbyVehicle(active[childId]) then
      return true
    end
  end
  return false
end

local function switchMap(levelName)
  local blockers = getTravelBlockers()
  if blockers then
    publishTravelBlocked(levelName, blockers, nil)
    return false, TRAVEL_BLOCKED_MESSAGE
  end
  if getCurrentLevelIdentifier() == levelName then
    return refuseTravel(levelName, "Already in the requested destination")
  end
  if not canTravel() then
    return refuseTravel(levelName, "Return to the map travel area before travelling")
  end
  local _, assignments = getGroups()
  if nearbyLoadOutOfRange(assignments) then
    refreshNearby()
    return refuseTravel(levelName,
      "A nearby load is no longer within range of its carrier. Remove it or move it closer.")
  end

  local manifest = buildManifest(levelName)
  switchInProgress = true
  publishStagingData()
  captureBrakeStates(manifest.carriedVehicles, function() performSwitch(levelName, manifest) end)
  return true
end

local function reportBlockedAfterClearing(levelName, reason)
  local remaining = getTravelBlockers()
  if remaining then
    publishTravelBlocked(levelName, remaining, tostring(reason or TRAVEL_BLOCKED_MESSAGE))
  else
    guihooks.trigger("toastrMsg", {type = "warning", title = "Map travel", msg = tostring(reason or TRAVEL_BLOCKED_MESSAGE)})
    publishStagingData()
  end
end

local function resolveTravelBlockers(levelName)
  local broker = overhaul_career_logistics_broker
  if not getTravelBlockers() then return switchMap(levelName) end
  local ok, message = broker.clearObligations(function(success, failures)
    if not success then
      publishTravelBlocked(levelName, getTravelBlockers(), table.concat(failures or {}, ' '))
      return
    end
    local accepted, reason = switchMap(levelName)
    if not accepted then reportBlockedAfterClearing(levelName, reason) end
  end)
  if not ok then publishTravelBlocked(levelName, getTravelBlockers(), message) end
  return ok, message
end

-- Carrier assignment editing ----------------------------------------------------------------------

local function setCarrierAssignment(childInventoryId, carrierInventoryId)
  childInventoryId = tonumber(childInventoryId)
  carrierInventoryId = tonumber(carrierInventoryId)
  if not childInventoryId or not carrierInventoryId or childInventoryId == carrierInventoryId then return false end

  local groups, assignments = getGroups()
  local listed, coupledGroupByInventoryId = {}, {}
  for _, group in ipairs(groups) do
    for _, member in ipairs(group.members) do
      listed[member.inventoryId] = true
      coupledGroupByInventoryId[member.inventoryId] = group.rootInventoryId
    end
  end
  if not listed[childInventoryId] and listed[carrierInventoryId] and not nearbySelections[carrierInventoryId]
      and panelActive and not switchInProgress then
    local active = getActivePersonalVehicles()
    if active[childInventoryId] and active[carrierInventoryId] and isUncoupledNearbyVehicle(active[childInventoryId])
        and isCarrierVehicle(active[carrierInventoryId], carrierInventoryId)
        and withinCarrierRange(active[childInventoryId], active[carrierInventoryId]) then
      nearbySelections[childInventoryId] = carrierInventoryId
      manualCarrierAssignments[childInventoryId] = carrierInventoryId
      if overhaul_career_garage_inventory.clearCarriedPlacement then overhaul_career_garage_inventory.clearCarriedPlacement(childInventoryId) end
      refreshNearby()
      return true
    end
  end
  if not listed[childInventoryId] or not listed[carrierInventoryId]
      or coupledGroupByInventoryId[childInventoryId] == coupledGroupByInventoryId[carrierInventoryId] then
    return false
  end

  local ancestor = carrierInventoryId
  local visited = {}
  while ancestor do
    if ancestor == childInventoryId or visited[ancestor] then return false end
    visited[ancestor] = true
    ancestor = assignments[ancestor]
  end
  if nearbySelections[childInventoryId] then
    local active = getActivePersonalVehicles()
    if nearbySelections[carrierInventoryId] or not active[childInventoryId] or not active[carrierInventoryId]
        or not isCarrierVehicle(active[carrierInventoryId], carrierInventoryId)
        or not withinCarrierRange(active[childInventoryId], active[carrierInventoryId]) then return false end
    nearbySelections[childInventoryId] = carrierInventoryId
  end
  manualCarrierAssignments[childInventoryId] = carrierInventoryId
  if overhaul_career_garage_inventory.clearCarriedPlacement then overhaul_career_garage_inventory.clearCarriedPlacement(childInventoryId) end
  publishStagingData()
  return true
end

local function clearCarrierAssignment(childInventoryId)
  childInventoryId = tonumber(childInventoryId)
  if not childInventoryId then return false end
  if overhaul_career_garage_inventory.clearCarriedPlacement then overhaul_career_garage_inventory.clearCarriedPlacement(childInventoryId) end
  if nearbySelections[childInventoryId] then
    nearbySelections[childInventoryId] = nil
    manualCarrierAssignments[childInventoryId] = nil
    refreshNearby()
    return true
  end
  manualCarrierAssignments[childInventoryId] = 0
  publishStagingData()
  return true
end

local function cancelSwitch()
  panelActive = false
  publishStagingData()
end

local function openForTester()
  if not overhaul_career_career.isActive() then return false, "Career is not active." end
  local triggerObject = levelData.travelTrigger()
  if not triggerObject then return false, "No switchMaps trigger on this level." end
  local veh = getPlayerVehicle(0)
  if veh then spawn.safeTeleport(veh, triggerObject:getPosition(), nil, nil, nil, nil, nil, false) end
  local playerVehId = tonumber(be:getPlayerVehicleID(0))
  local inventoryId = playerVehId and getEligibleInventoryId(playerVehId) or nil
  if inventoryId then
    stageVehicle(playerVehId, inventoryId)
  elseif gameplay_walk.isWalking() then
    walkingInside = true
  end
  panelActive = true
  publishStagingData()
  return true
end

-- Lifecycle ---------------------------------------------------------------------------------------

local function resetStaging()
  table.clear(nearbySelections)
  nearbyCandidates = {}
  table.clear(stagedVehicles)
  table.clear(manualCarrierAssignments)
  nextEntryOrder = 0
  walkingInside = false
  panelActive = false
  switchInProgress = false
  publishStagingData()
end

-- Public API --------------------------------------------------------------------------------------

M.captureInventoryRelationships = captureInventoryRelationships
M.captureRelationshipBrakes = captureBrakeStates
M.switchMap = switchMap
M.getTravelBlockers = getTravelBlockers
M.resolveTravelBlockers = resolveTravelBlockers
M.openForTester = openForTester
M.setCarrierAssignment = setCarrierAssignment
M.refreshNearby = refreshNearby
M.clearCarrierAssignment = clearCarrierAssignment
M.cancelSwitch = cancelSwitch
-- The HUD's remappable gameplay action opens menu controls only while in use.
M.engagePanel = function()
  if not panelActive or switchInProgress or not overhaul_career_career.isActive() then return false end
  guihooks.trigger("MapTravelPanelEngage")
  return true
end
M.requestStagingData = publishStagingData

-- Game hooks --------------------------------------------------------------------------------------

function M.onRouteLeave()
  simTimeAuthority.pause(false)
end

function M.onBeamNGTrigger(data)
  if not data or type(data.triggerName) ~= 'string' or not overhaul_career_career.isActive() then return end
  if data.event ~= "enter" and data.event ~= "exit" then return end
  local subjectId = tonumber(data.subjectID)
  if not subjectId then return end
  if data.triggerName:lower() ~= 'switchmaps' then return end

  local entering = data.event == "enter"
  local playerSubject = subjectId == tonumber(be:getPlayerVehicleID(0))
  if playerSubject and isWalkingSubject(subjectId) then
    walkingInside = entering
    if entering then panelActive = true end
  else
    local inventoryId = getEligibleInventoryId(subjectId)
    if entering and inventoryId then
      stageVehicle(subjectId, inventoryId)
      if playerSubject then panelActive = true end
    elseif not entering then
      local entry = stagedVehicles[subjectId]
      if entry then stagedVehicles[subjectId] = nil end
    end
  end
  publishStagingData()
end

function M.onVehicleDestroyed(vehId)
  if stagedVehicles[vehId] then
    stagedVehicles[vehId] = nil
    stagingRefreshPending = true
  end
end

function M.onVehicleSwitched(_, _, player)
  if player == nil or player == 0 then
    if not gameplay_walk.isWalking() then
      walkingInside = false
    end
    -- Both switch notifications of a vehicle rebuild coalesce into one refresh on the next update.
    stagingRefreshPending = true
  end
end

function M.onUpdate()
  if stagingRefreshPending then publishStagingData() end
end

function M.onOverhaulActive(active)
  if not active then
    resetStaging()
  elseif not levelData.travelTrigger() then
    log('W', 'switchMap', 'Map travel unavailable: this level has no switchMaps trigger')
  end
end

function M.onClientEndMission()
  resetStaging()
end


M.onUiReady = publishStagingData

local function mapSwitcherDescription(levelIdentifier)
  local mapRows = {}
  for _, levelName in pairs(overhaul_world_maps.getOtherAvailableMaps(levelIdentifier)) do
    mapRows[#mapRows + 1] = levelName
  end
  table.sort(mapRows, function(a, b) return string.lower(a) < string.lower(b) end)
  if #mapRows == 0 then return nil end
  local description = "Available maps to switch to:\n"
  for _, levelName in ipairs(mapRows) do
    description = description .. "- " .. levelName .. "\n"
  end
  return description
end

function M.onGetRawPoiListForLevel(levelIdentifier, elements)
  if not overhaul_career_career.isActive() then return end
  local description = mapSwitcherDescription(levelIdentifier)
  if not description then return end
  local switchObject = levelData.travelTrigger(levelIdentifier)
  if not switchObject then return end
  local preview = overhaul_world_maps.resolveMapAsset(levelIdentifier, 'travelPreview')
  elements[#elements + 1] = {
    id = 'map_switcher',
    data = {type = "travel"},
    markerInfo = {
      bigmapMarker = {
        pos = switchObject:getPosition(),
        icon = "poi_fasttravel_round_orange_green",
        name = "Map travel",
        description = description,
        previews = preview and {preview} or {},
        thumbnail = preview,
        cardIcon = "fastTravel",
      },
    },
  }
end

function M.onOverhaulRecoveryRelationships(request)
  if request.capture then return end
  request.capture = M.captureInventoryRelationships
end

return M
