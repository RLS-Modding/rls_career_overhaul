-- Accident recovery for company wrecks: replacement equipment, stranded freight and the crate that marks it.
-- Vehicle and scene queries, cargo recovery, replacement offers and reporting; bound through operations.lua.
local M = {}

-- Config ------------------------------------------------------------------------------------------

local ACCIDENT_RETURN_TIMEOUT = 20
local RETURN_START_DELAY_SECONDS = 0.3
local MARKER_SHAPE = "art/shapes/interface/checkpoint_marker.dae"

-- Shared helpers ----------------------------------------------------------------------------------

local function employedOnShift(employment)
  return employment.lifecycle.isEmployed() and employment.getState().shift
end

local function vecFromPos(pos)
  return vec3(pos.x, pos.y, pos.z)
end

local function plainPos(pos)
  return { x = pos.x, y = pos.y, z = pos.z }
end

-- Task guidance and UI ----------------------------------------------------------------------------

function M.accidentTaskGuidance(_ctx, shift)
  local acc = shift and shift.accident
  if not acc or acc.done then return nil end
  if acc.spawning then
    return {
      label = "Accident reported",
      subtext = "Issuing replacement equipment",
    }
  end
  if acc.needYardPickup then
    return {
      label = "Pick up replacement trailer at the yard",
      subtext = acc.yardSubtext or "Your truck and load are waiting at the accident scene",
    }
  end
  if acc.needReload then
    return {
      label = "Reload the stranded cargo",
      subtext = "Drive the replacement to the marked crate",
    }
  end
  if acc.needCouple then
    return {
      label = "Couple the stranded trailer",
      subtext = "Drive back to the accident scene — trailer and load are still there",
    }
  end
  return nil
end

function M.accidentUi(employment, shift)
  local acc = shift and shift.accident
  if not acc or acc.done then return nil end
  local task = M.accidentTaskGuidance(employment, shift)
  return employment.services.ui().formatAccident({
    label = task and task.label or nil,
    subtext = task and task.subtext or nil,
    canClaim = acc.pendingOffers and acc.pendingOffers[1] and not acc.spawning and true or false,
    spawning = acc.spawning and true or false,
  })
end

-- Vehicle and scene queries -----------------------------------------------------------------------

function M.inventorySpawnedVehId(employment, inventoryId)
  if not inventoryId or not employment.services.inventory() then return nil end
  local vehId = employment.services.inventory().getVehicleIdFromInventoryId
    and employment.services.inventory().getVehicleIdFromInventoryId(inventoryId)
  vehId = tonumber(vehId) or vehId
  if vehId and vehId >= 0 then return vehId end
  if not (employment.services.inventory().getInventoryIdFromVehicleId and getAllVehicles) then
    return nil
  end
  local want = tonumber(inventoryId) or inventoryId
  for _, veh in ipairs(getAllVehicles()) do
    local id = veh.getId and veh:getId()
    if id then
      local inv = employment.services.inventory().getInventoryIdFromVehicleId(id)
      if (tonumber(inv) or inv) == want then return id end
    end
  end
  return nil
end

function M.vehIsFlipped(_ctx, vehId)
  if not vehId then return false end
  local obj = getObjectByID(tonumber(vehId) or vehId)
  if not (obj and obj.getDirectionVectorUp) then return false end
  local up = obj:getDirectionVectorUp()
  return up and up.z < 0.35 or false
end

function M.spawnedVehLiveDamage(_ctx, vehId)
  if not vehId then return 0 end
  local live = 0
  local want = tonumber(vehId) or vehId
  if map.objects then
    local data = map.objects[vehId] or map.objects[want] or map.objects[tostring(vehId)]
    if data then live = tonumber(data.damage) or 0 end
    if live == 0 then
      for id, objData in pairs(map.objects) do
        if (tonumber(id) or id) == want or id == vehId then
          live = math.max(live, tonumber(objData.damage) or 0)
        end
      end
    end
  end
  local obj = getObjectByID(want or vehId)
  if obj and obj.getSectionDamageSum then
    local ok, sum = pcall(function() return tonumber(obj:getSectionDamageSum()) or 0 end)
    if ok and sum and sum > live then live = sum end
  end
  return live
end

function M.companyInventoryIsWrecked(employment, inventoryId)
  if not inventoryId then return false end
  if employment.services.insurance() and employment.services.insurance().inventoryVehNeedsRepair
      and employment.services.insurance().inventoryVehNeedsRepair(inventoryId) then
    return true
  end
  local vehId = M.inventorySpawnedVehId(employment, inventoryId)
  if M.vehIsFlipped(employment, vehId) then return true end
  return M.spawnedVehLiveDamage(employment, vehId) >= employment.constants.ACCIDENT_LIVE_DAMAGE
end

function M.accidentVehIdMatches(_ctx, vehId, idSet)
  if not vehId or not idSet then return false end
  if idSet[vehId] then return true end
  local n = tonumber(vehId)
  if n and idSet[n] then return true end
  return idSet[tostring(vehId)] and true or false
end

function M.markAccidentVehId(_ctx, idSet, vehId)
  if not vehId then return end
  idSet[vehId] = true
  idSet[tostring(vehId)] = true
  local n = tonumber(vehId)
  if n then idSet[n] = true end
end

function M.groundAccidentPos(_ctx, pos)
  if not pos then return pos end
  local z = be:getSurfaceHeightBelow(pos)
  if (not z or z < -1000 or z > 10000) and core_terrain then
    z = core_terrain.getTerrainHeight(pos)
  end
  if type(z) == "number" and z > -1000 and z < 10000 then
    pos.z = z + 0.05
  end
  return pos
end

-- The crate sits just off the road, on the side the scene is on.
function M.accidentBoxPosFromScene(employment, origin)
  local pos = vec3(origin.x or origin[1], origin.y or origin[2], origin.z or origin[3] or 0)
  local roadMap = map
  if roadMap and roadMap.findClosestRoad and roadMap.getMap then
    local _, nodeIdx = roadMap.findClosestRoad(pos)
    local mapData = roadMap.getMap()
    local node = nodeIdx and mapData and mapData.nodes and mapData.nodes[nodeIdx]
    if node and node.pos then
      local roadPos = vec3(node.pos)
      local side = pos - roadPos
      side.z = 0
      if side:squaredLength() < 0.25 then
        side = vec3(1, 0, 0)
      else
        side:normalize()
      end
      pos = pos + side * employment.constants.ACCIDENT_ROAD_OFFSET_M
    else
      pos = pos + vec3(employment.constants.ACCIDENT_ROAD_OFFSET_M, 0, 0)
    end
  else
    pos = pos + vec3(employment.constants.ACCIDENT_ROAD_OFFSET_M, 0, 0)
  end
  return M.groundAccidentPos(employment, pos)
end

-- Routing ----------------------------------------------------------------------------------------

function M.routeToWorldPos(employment, pos)
  if not pos then return false end
  local v = vec3(pos.x or pos[1], pos.y or pos[2], pos.z or pos[3] or 0)
  if freeroam_bigMapMode then
    freeroam_bigMapMode.setNavFocus(v)
  end
  if core_groundMarkers then
    core_groundMarkers.setPath({v}, {clearPathOnReachingTarget = false})
  end
  employment.parts.routing.refreshDeliveryPois()
  return true
end

function M.routeAccidentRecovery(employment)
  local shift = employment.getState().shift
  local acc = shift and shift.accident
  if not acc or acc.done or acc.spawning then return false end
  if acc.needYardPickup then
    return employment.parts.routing.routeToYard()
  end
  if acc.needReload and acc.pos then
    return M.routeToWorldPos(employment, acc.pos)
  end
  if acc.needCouple then
    if acc.strandedTrailerInvId and employment.services.inventory() and employment.services.inventory().getVehicleIdFromInventoryId then
      local vehId = employment.services.inventory().getVehicleIdFromInventoryId(acc.strandedTrailerInvId)
      local obj = vehId and getObjectByID(vehId)
      if obj and obj.getPosition then
        return M.routeToWorldPos(employment, obj:getPosition())
      end
    end
    if acc.pos then
      return M.routeToWorldPos(employment, acc.pos)
    end
  end
  return false
end

-- Scene props ------------------------------------------------------------------------------------

function M.deleteNamedStatic(_ctx, name)
  if not name then return end
  local obj = scenetree.findObject(name)
  if obj and obj.delete then obj:delete() end
end

function M.deleteAccidentCargoBox(employment)
  local acc = employment.getState().shift and employment.getState().shift.accident
  if not acc then return end
  M.deleteNamedStatic(employment, acc.boxName)
  M.deleteNamedStatic(employment, acc.markerName)
  acc.boxName = nil
  acc.markerName = nil
end

function M.spawnAccidentStatic(employment, name, shapeName, pos, scale, color)
  if not (name and shapeName and pos) then return nil end
  if scenetree.findObject(name) then
    M.deleteNamedStatic(employment, name)
  end
  local obj = createObject("TSStatic")
  if not obj then return nil end
  if obj.setField then
    obj:setField("shapeName", 0, shapeName)
  else
    obj.shapeName = shapeName
  end
  obj.shapeName = shapeName
  if obj.setPosition then
    obj:setPosition(vec3(pos.x, pos.y, pos.z))
  elseif obj.setPosRot then
    obj:setPosRot(pos.x, pos.y, pos.z, 0, 0, 0, 1)
  end
  obj.scale = scale or vec3(1, 1, 1)
  obj.useInstanceRenderData = true
  if color then
    if obj.setField then
      obj:setField("instanceColor", 0, string.format("%s %s %s %s", color[1], color[2], color[3], color[4] or 1))
    elseif ColorF then
      obj.instanceColor = ColorF(color[1], color[2], color[3], color[4] or 1):asLinear4F()
    end
  end
  obj.canSave = false
  if obj.setCanSave then obj:setCanSave(false) end
  local ok = pcall(function()
    obj:registerObject(name)
  end)
  if not ok then return nil end
  if scenetree.MissionGroup then
    pcall(function() scenetree.MissionGroup:addObject(obj) end)
  end
  return name
end

-- Level presentation overrides shared assets; a missing configured shape leaves the recovery marker.
local function crateShapeName()
  local levelData = require('overhaul/lib/world/levelData')
  local level = getCurrentLevelIdentifier()
  local localData = level and jsonReadFile(levelData.assetPath(level, 'employmentPresentation.json'))
  local data = localData or jsonReadFile('/gameplay/overhaul/logistics/presentation.json')
  local cargo = type(data) == 'table' and data.accidentCargo
  if type(data) ~= 'table' or data.version ~= 1 or type(cargo) ~= 'table' or type(cargo.shapes) ~= 'table' then
    log('W', 'employment', 'Accident cargo presentation is unavailable')
    return nil
  end
  for _, shape in ipairs(cargo.shapes) do
    if type(shape) ~= 'string' or shape == '' then
      log('W', 'employment', 'Invalid accident cargo shape; using the recovery marker')
      return nil
    end
    local asset = localData and levelData.assetPath(level, shape) or shape
    if asset and FS:fileExists(asset) then return asset end
  end
  log('W', 'employment', 'No configured accident cargo shape is available; using the recovery marker')
  return nil
end

function M.spawnAccidentCargoBox(employment, pos)
  if not pos then return nil, nil end
  M.deleteAccidentCargoBox(employment)
  local stamp = tostring(math.floor(((os.clock and os.clock()) or 0) * 1000))
  local boxName = "rlsAccCargoBox" .. stamp
  local markerName = "rlsAccCargoMark" .. stamp
  local cratePos = M.groundAccidentPos(employment, vecFromPos(pos))
  local crateShape = crateShapeName()
  if crateShape then
    M.spawnAccidentStatic(employment, boxName, crateShape, cratePos, vec3(0.45, 0.45, 0.45))
  end
  local markPos = vec3(cratePos.x, cratePos.y, cratePos.z + 2.4)
  M.spawnAccidentStatic(employment, markerName, MARKER_SHAPE, markPos, vec3(6, 6, 6), {0.95, 0.45, 0.08, 0.9})
  return boxName, markerName
end

function M.restoreAccidentCargoBox(employment)
  local acc = employment.getState().shift and employment.getState().shift.accident
  if not acc then return end
  acc.spawning = nil
  acc.rebindBusy = nil
  if not acc.needReload or not acc.pos then return end
  local boxAlive = acc.boxName and scenetree.findObject(acc.boxName)
  if boxAlive then return end
  local boxName, markerName = M.spawnAccidentCargoBox(employment, vecFromPos(acc.pos))
  acc.boxName = boxName
  acc.markerName = markerName
end

-- Cargo recovery ---------------------------------------------------------------------------------

function M.setCargoLocation(employment, cargoId, location)
  local parcelMgr = employment.services.parcelManager()
  if not (parcelMgr and cargoId and location) then return end
  local cargo = parcelMgr.getCargoById and (
    parcelMgr.getCargoById(cargoId)
    or parcelMgr.getCargoById(tonumber(cargoId))
    or parcelMgr.getCargoById(tostring(cargoId))
  )
  if cargo and cargo._transientMove and parcelMgr.clearTransientMoveForCargo then
    parcelMgr.clearTransientMoveForCargo(cargo.id)
  end
  if parcelMgr.changeCargoLocation then
    parcelMgr.changeCargoLocation(cargo and cargo.id or cargoId, location)
  elseif cargo then
    cargo.location = location
  end
end

-- True when the cargo rides in, or is headed for, a vehicle that the accident wrecked.
function M.cargoTiedToWreckedVeh(employment, cargo, wreckedVehIds, wreckedInvIds)
  if not cargo then return false end
  local function tiedVeh(vehId)
    if not vehId then return false end
    if wreckedVehIds and M.accidentVehIdMatches(employment, vehId, wreckedVehIds) then return true end
    if wreckedInvIds and employment.services.inventory() and employment.services.inventory().getInventoryIdFromVehicleId then
      local invId = employment.services.inventory().getInventoryIdFromVehicleId(vehId)
        or employment.services.inventory().getInventoryIdFromVehicleId(tonumber(vehId) or vehId)
      if invId and M.accidentVehIdMatches(employment, invId, wreckedInvIds) then return true end
    end
    return false
  end
  local loc = cargo.location
  if loc and loc.type == "vehicle" and tiedVeh(loc.vehId) then
    return true
  end
  if loc and loc.type == "vehicle" and loc.vehId and wreckedInvIds and next(wreckedInvIds)
      and not (employment.services.inventory() and employment.services.inventory().getInventoryIdFromVehicleId
        and employment.services.inventory().getInventoryIdFromVehicleId(loc.vehId)) then
    return true
  end
  local target = cargo._transientMove and cargo._transientMove.targetLocation
  if target and tiedVeh(target.vehId) then
    return true
  end
  return false
end

-- Moves cargo off the wreck: material loads are lost, anything else is salvaged at the accident.
function M.relocateCargoOffWrecked(employment, wreckedVehIds, wreckedInvIds)
  local salvaged, dumped, seen = {}, {}, {}
  local parcelMgr = employment.services.parcelManager()
  if not parcelMgr then return salvaged, dumped end
  local function cargoById(id)
    if not (id and parcelMgr.getCargoById) then return nil end
    return parcelMgr.getCargoById(id)
      or parcelMgr.getCargoById(tonumber(id))
      or parcelMgr.getCargoById(tostring(id))
  end
  local function consider(cargo)
    if not cargo or not cargo.id or seen[cargo.id] then return end
    if not M.cargoTiedToWreckedVeh(employment, cargo, wreckedVehIds, wreckedInvIds) then return end
    seen[cargo.id] = true
    if cargo.materialType then
      M.setCargoLocation(employment, cargo.id, { type = "deleted" })
      table.insert(dumped, cargo.id)
    else
      M.setCargoLocation(employment, cargo.id, { type = "accident" })
      table.insert(salvaged, cargo.id)
    end
  end
  if parcelMgr.getAllCargoInVehicles then
    for _, cargo in ipairs(parcelMgr.getAllCargoInVehicles(true) or {}) do
      consider(cargo)
    end
  end
  local shift = employment.getState().shift
  for _, cargoId in ipairs(shift and shift.assignedCargoIds or {}) do
    consider(cargoById(cargoId))
  end
  for _, cargoId in ipairs(shift and shift.stringCargoIds or {}) do
    consider(cargoById(cargoId))
  end
  return salvaged, dumped
end

-- Puts the stranded cargo back into the company trucks once they are parked near the crate.
local function companyUnitNear(employment, boxPos, limit)
  if not (employment.services.inventory() and employment.services.inventory().getVehicleIdFromInventoryId) then return false end
  for _, inventoryId in ipairs(employment.parts.equipment.collectCompanyInventoryIds()) do
    local vehId = employment.services.inventory().getVehicleIdFromInventoryId(inventoryId)
    local obj = vehId and getObjectByID(vehId)
    if obj and obj.getPosition and (obj:getPosition() - boxPos):length() <= limit then
      return true
    end
  end
  return false
end

-- Returns false when no truck slot can take the cargo, so the crate stays until the next try.
local function loadStrandedCargo(employment, acc, containers, parcelMgr)
  local slots = employment.parts.parcelLoading.buildCompanyParcelLoadSlots(containers)
  if not slots[1] then return false end
  for _, cargoId in ipairs(acc.cargoIds or {}) do
    local cargo = parcelMgr.getCargoById(cargoId)
    local dest = employment.parts.parcelLoading.takeParcelLoadLocation(slots, cargo or { slots = 1, weight = 0 })
    if dest then
      M.setCargoLocation(employment, cargoId, dest)
    end
  end
  return true
end

function M.tryRebindAccidentCargo(employment)
  local shift = employment.getState().shift
  local acc = shift and shift.accident
  if not acc or not acc.needReload or acc.rebindBusy then return end
  if not acc.pos then return end
  if not companyUnitNear(employment, vecFromPos(acc.pos), employment.constants.ACCIDENT_REBIND_M) then return end
  local g = employment.services.general()
  local parcelMgr = employment.services.parcelManager()
  if not (g and g.getNearbyVehicleCargoContainers and parcelMgr) then return end
  acc.rebindBusy = true
  g.getNearbyVehicleCargoContainers(function(containers)
    local live = employment.getState().shift and employment.getState().shift.accident
    if live then live.rebindBusy = nil end
    if not live or live ~= acc then return end
    if not loadStrandedCargo(employment, acc, containers, parcelMgr) then return end
    M.deleteAccidentCargoBox(employment)
    acc.needReload = nil
    acc.cargoIds = nil
    if g.requestUpdateContainerWeights then
      g.requestUpdateContainerWeights()
    end
    local cs = employment.services.cargoScreen()
    if cs and cs.onCargoPickedUp then
      cs.onCargoPickedUp()
    end
    ui_message("Stranded cargo loaded.", 6, "success")
    employment.parts.projections.refreshTaskGuidance(true)
    employment.parts.projections.notifyUi()
  end)
end

-- Steps the recovery forward once the player reaches the yard or the scene; ends it when nothing is left.
function M.tickAccidentRecovery(employment, dtSim)
  if not employment.lifecycle.isOnShift() then return end
  local shift = employment.getState().shift
  local acc = shift and shift.accident
  if not acc or acc.done or acc.spawning then return end
  acc.tickAcc = (tonumber(acc.tickAcc) or 0) + (dtSim or 0)
  if acc.tickAcc < 0.35 then return end
  acc.tickAcc = 0
  if acc.needYardPickup and employment.parts.routing.playerNearHomeYard(50) then
    acc.needYardPickup = nil
    employment.parts.projections.refreshTaskGuidance(true)
    M.routeAccidentRecovery(employment)
    employment.parts.projections.notifyUi()
  end
  if acc.needCouple and acc.pos then
    local player = getPlayerVehicle(0)
    local scene = vecFromPos(acc.pos)
    if player and player.getPosition and (player:getPosition() - scene):length() <= employment.constants.ACCIDENT_ARRIVE_M then
      acc.needCouple = nil
      employment.parts.projections.refreshTaskGuidance(true)
      employment.parts.projections.notifyUi()
    end
  end
  if acc.needReload then
    M.tryRebindAccidentCargo(employment)
  end
  if not acc.needYardPickup and not acc.needReload and not acc.needCouple then
    shift.accident = nil
    employment.parts.routing.routeCurrentAssignment()
    employment.parts.projections.refreshTaskGuidance(true)
    employment.parts.projections.notifyUi()
    employment.parts.persistence.saveEmploymentProgress()
  end
end

-- Replacement offers -----------------------------------------------------------------------------

function M.accidentEntryForInventory(employment, inventoryId)
  local vehInfo = employment.services.inventory().getVehicles()[inventoryId]
  local vehId = M.inventorySpawnedVehId(employment, inventoryId)
  local obj = vehId and getObjectByID(vehId)
  return {
    inventoryId = inventoryId,
    vehId = vehId,
    isTrailer = employment.parts.equipment.isCompanyTrailer(vehInfo, vehId),
    offer = employment.parts.equipment.inventoryVehAsLoanerOffer(vehInfo),
    pos = obj and obj.getPosition and obj:getPosition() or nil,
  }
end

-- Splits the company units into wrecked and surviving: the unit the player reported wins over the damage check.
function M.collectAccidentWreckage(employment, preferredVehId)
  local wrecked, survivors = {}, {}
  if not employment.services.inventory() then
    return wrecked, survivors
  end
  local entries = {}
  for _, inventoryId in ipairs(employment.parts.equipment.collectCompanyInventoryIds()) do
    local entry = M.accidentEntryForInventory(employment, inventoryId)
    entry.liveDamage = M.spawnedVehLiveDamage(employment, entry.vehId)
    entry.wrecked = M.companyInventoryIsWrecked(employment, inventoryId)
    table.insert(entries, entry)
  end
  local vehId = preferredVehId
  if not vehId or vehId < 0 then
    vehId = be:getPlayerVehicleID(0)
  end
  local preferInv = vehId and employment.services.inventory().getInventoryIdFromVehicleId
    and employment.services.inventory().getInventoryIdFromVehicleId(vehId)
  preferInv = tonumber(preferInv) or preferInv
  local preferVehN = tonumber(vehId)

  -- Only the unit the player reported is written off, not coupled trailers or other damaged gear nearby.
  if preferInv or preferVehN then
    for _, entry in ipairs(entries) do
      local inv = tonumber(entry.inventoryId) or entry.inventoryId
      local entryVehN = tonumber(entry.vehId)
      local isPreferred = (preferInv and inv == preferInv)
        or (preferVehN and entryVehN and entryVehN == preferVehN)
      if isPreferred then
        table.insert(wrecked, entry)
      else
        table.insert(survivors, entry)
      end
    end
    if wrecked[1] then return wrecked, survivors end
  end

  for _, entry in ipairs(entries) do
    if entry.wrecked then
      table.insert(wrecked, entry)
    else
      table.insert(survivors, entry)
    end
  end
  if wrecked[1] or not preferInv then return wrecked, survivors end

  local vehInfo = employment.services.inventory().getVehicles()[preferInv]
  if vehInfo and vehInfo.loanType == "company" then
    table.insert(wrecked, M.accidentEntryForInventory(employment, preferInv))
  end
  return wrecked, survivors
end

-- Offer to reissue a wrecked unit when the company's own offer is missing: the facility's loaner for the job kind.
function M.fallbackAccidentOffer(employment, entry, shift)
  local facId = (shift and shift.originFacId) or employment.getState().homeFacId
  local gen = employment.services.generator()
  local fac = gen and gen.getFacilityById(facId)
  local caps = employment.services.loanerCapabilities()
  if not (fac and caps and caps.getIssuedLoanersForFacility) then return nil end
  if employment.parts.eligibility.isRoleplayProfile(shift.jobKind) then
    return not entry.isTrailer and caps.getIssuedRoleplayVehicleForFacility(fac, {}) or nil
  end
  local loanerKind = employment.parts.equipment.shiftLoanerKind(shift)
  local truck, trailer
  if employment.shared.kindPolicy(loanerKind).materialContract then
    truck, trailer = employment.parts.eligibility.getIssuedEmploymentMaterials(fac, shift.cargoType, shift.targetLoad)
  else
    truck, trailer = caps.getIssuedLoanersForFacility(fac, loanerKind, {
      cargoType = shift.cargoType,
      targetLoad = shift.targetLoad,
      couplerClass = shift.couplerClass,
    })
  end
  if entry.isTrailer then return trailer end
  return truck
end

function M.enterAccidentReplacementTractor(employment)
  return employment.parts.equipment.enterCompanyTractor()
end

function M.getMissingAccidentReplacementOffers(employment, shift)
  shift = shift or employment.getState().shift
  local acc = shift and shift.accident
  if not acc then return {}, false, false end
  local hasTractor, hasTrailer = false, false
  for _, inventoryId in ipairs(employment.parts.equipment.captureIssuedInventoryIds()) do
    local vehInfo = employment.services.inventory() and employment.services.inventory().getVehicles()[inventoryId]
    local vehId = employment.services.inventory() and employment.services.inventory().getVehicleIdFromInventoryId
      and employment.services.inventory().getVehicleIdFromInventoryId(inventoryId)
    if employment.parts.equipment.isCompanyTrailer(vehInfo, vehId) then hasTrailer = true else hasTractor = true end
  end
  local caps = employment.services.loanerCapabilities()
  local missing = {}
  for _, offer in ipairs(acc.pendingOffers or {}) do
    local isTrailer = caps and caps.isTrailer(offer) or offer.vehOfferType == "trailer"
    if (isTrailer and not hasTrailer) or (not isTrailer and not hasTractor) then
      missing[#missing + 1] = offer
    end
  end
  return missing, hasTractor, hasTrailer
end

function M.finishAccidentSpawn(employment, replacedTractor)
  local shift = employment.getState().shift
  if not shift then return end
  local acc = shift.accident
  shift.issuedInventoryIds = employment.parts.equipment.captureIssuedInventoryIds()
  local missingOffers = M.getMissingAccidentReplacementOffers(employment, shift)
  if acc then
    acc.spawning = nil
    acc.pendingOffers = missingOffers[1] and missingOffers or nil
  end
  employment.shared.kindHandler(shift.jobKind, 'cancelAssignment', 'accident replacement')
  if replacedTractor then
    -- Truck write-off: leave trailer and load at the scene and put the player straight into the replacement truck.
    M.enterAccidentReplacementTractor(employment)
  end
  if acc and (acc.needCouple or acc.needYardPickup or acc.needReload) then
    M.routeAccidentRecovery(employment)
  else
    if employment.parts.eligibility.isRoleplayProfile(shift.jobKind) then
      shift.accident = nil
    end
    employment.parts.routing.routeCurrentAssignment()
  end
  employment.parts.projections.refreshTaskGuidance(true)
  employment.parts.projections.notifyUi()
  employment.parts.persistence.saveEmploymentProgress()
end

local function hasPendingAccidentOffers(employment)
  local shift = employment.getState().shift
  return shift and shift.accident and shift.accident.pendingOffers and shift.accident.pendingOffers[1]
end

function M.claimAccidentReplacement(employment)
  local shift = employment.getState().shift
  local acc = shift and shift.accident
  if not acc or not acc.pendingOffers or not acc.pendingOffers[1] then return false end
  if acc.spawning then return false end
  local pendingOffers = M.getMissingAccidentReplacementOffers(employment, shift)
  if not pendingOffers[1] then
    M.finishAccidentSpawn(employment, acc.replacedTractor == true)
    return true
  end
  acc.pendingOffers = pendingOffers
  acc.spawning = true
  for _, offer in ipairs(acc.pendingOffers) do
    employment.parts.equipment.markIssued(offer)
  end
  local replacedTractor = acc.replacedTractor and true or false
  if employment.services.loaners() and employment.services.loaners().spawnAllOffers then
    employment.services.loaners().spawnAllOffers(function()
      local batch = employment.services.loaners().consumeLastSpawnBatchResult
        and employment.services.loaners().consumeLastSpawnBatchResult()
      M.finishAccidentSpawn(employment, replacedTractor)
      if batch and batch.occupiedBlocked and hasPendingAccidentOffers(employment) then
        employment.parts.equipment.enterSpawnBlockedState({needCompanyLoaner = true, retryKind = "accidentReplacement"})
      end
    end)
  else
    M.finishAccidentSpawn(employment, replacedTractor)
  end
  return true
end

-- Reporting --------------------------------------------------------------------------------------

function M.canReportAccident(employment)
  if employment.getState().accidentReportInProgress then return false end
  if not employment.lifecycle.isOnShift() then return false end
  local shift = employment.getState().shift
  if not shift then return false end
  -- This reports stranded company equipment/cargo, not police incidents.
  if employment.shared.kindPolicy(shift.jobKind).accidentRecoveryDisabled then return false end
  if shift.accident and shift.accident.spawning then return false end
  if employment.parts.equipment.collectCompanyInventoryIds()[1] then return true end
  if not (employment.services.inventory() and employment.services.inventory().getInventoryIdFromVehicleId) then
    return false
  end
  local vehId = be:getPlayerVehicleID(0)
  local inventoryId = vehId and employment.services.inventory().getInventoryIdFromVehicleId(vehId)
  local vehInfo = inventoryId and employment.services.inventory().getVehicles()[inventoryId]
  return vehInfo and vehInfo.loanType == "company" or false
end

-- Replacement offers for every wrecked unit; nil when one cannot be reissued (the player is told why).
local function replacementOffersFor(employment, wrecked, shift)
  local pendingOffers = {}
  local replacedTractor, replacedTrailer = false, false
  for _, entry in ipairs(wrecked) do
    local offer = entry.offer or M.fallbackAccidentOffer(employment, entry, shift)
    if not offer or not offer.model then
      ui_message("Could not reissue that company vehicle.", 7, "warning")
      return nil
    end
    entry.offer = offer
    table.insert(pendingOffers, offer)
    if entry.isTrailer then replacedTrailer = true else replacedTractor = true end
  end
  return pendingOffers, replacedTractor, replacedTrailer
end

-- Which vehicles and inventory units the report writes off, where the scene is, and the stranded trailer.
local function reportScene(employment, wrecked, survivors)
  local wreckedVehIds, wreckedInvIds = {}, {}
  local scenePos
  for _, entry in ipairs(wrecked) do
    wreckedInvIds[entry.inventoryId] = true
    M.markAccidentVehId(employment, wreckedVehIds, entry.vehId)
    if not scenePos and entry.pos then scenePos = entry.pos end
  end
  local playerVehId = be:getPlayerVehicleID(0)
  if playerVehId and playerVehId >= 0 and employment.services.inventory() and employment.services.inventory().getInventoryIdFromVehicleId then
    local playerInvId = employment.services.inventory().getInventoryIdFromVehicleId(playerVehId)
    if playerInvId and wreckedInvIds[playerInvId] then
      M.markAccidentVehId(employment, wreckedVehIds, playerVehId)
    end
  end
  if not scenePos then
    local playerVeh = getPlayerVehicle(0)
    scenePos = playerVeh and playerVeh.getPosition and playerVeh:getPosition() or nil
  end
  local strandedTrailerInvId
  for _, entry in ipairs(survivors) do
    if entry.isTrailer then strandedTrailerInvId = entry.inventoryId end
  end
  return {
    wreckedVehIds = wreckedVehIds,
    wreckedInvIds = wreckedInvIds,
    scenePos = scenePos,
    strandedTrailerInvId = strandedTrailerInvId,
  }
end

-- Cargo that survives the wreck is salvaged, merged with the cargo of an earlier report that is still open.
local function salvageReportedCargo(employment, scene, shift)
  local salvaged, dumped = M.relocateCargoOffWrecked(employment, scene.wreckedVehIds, scene.wreckedInvIds)
  if dumped and dumped[1] then
    ui_message(string.format("%d material load%s on the wrecked equipment %s lost in the accident.",
      #dumped, #dumped == 1 and "" or "s", #dumped == 1 and "was" or "were"), 8, "warning")
  end
  local existing = shift.accident
  if existing and existing.cargoIds and existing.cargoIds[1] then
    for _, cargoId in ipairs(salvaged) do
      table.insert(existing.cargoIds, cargoId)
    end
    salvaged = existing.cargoIds
  end
  return salvaged
end

-- Places the crate and marker for stranded cargo; an open earlier report keeps its crate when this one has no new scene.
local function reportCrate(employment, scenePos, needReload, existing)
  local boxPos = scenePos and M.accidentBoxPosFromScene(employment, scenePos) or nil
  if needReload and boxPos then
    local boxName, markerName = M.spawnAccidentCargoBox(employment, boxPos)
    return boxPos, boxName, markerName
  end
  if existing then
    return existing.pos and vecFromPos(existing.pos) or boxPos, existing.boxName, existing.markerName
  end
  return boxPos, nil, nil
end

-- Leaves the wrecked and stranded vehicles at the scene instead of towing their trailers along.
local function detachReportedTrailers(employment, wrecked, survivors)
  for _, entry in ipairs(wrecked) do
    employment.parts.equipment.detachVehicleTrailers(entry.vehId)
  end
  for _, entry in ipairs(survivors) do
    if not entry.isTrailer then
      employment.parts.equipment.detachVehicleTrailers(entry.vehId)
    end
  end
end

local function accidentReportMessage(report)
  local msg
  if report.replacedTractor and report.replacedTrailer then
    msg = "Accident reported. Replacement equipment is at the yard."
  elseif report.replacedTractor and report.strandedTrailerInvId then
    msg = "Accident reported. You're in the replacement truck at the yard — go couple the stranded trailer and load."
  elseif report.replacedTrailer then
    msg = "Accident reported. Truck and load stay at the scene — drive back to the yard for a replacement trailer."
  else
    msg = "Accident reported. Replacement equipment is at the yard."
  end
  if report.needReload then
    msg = msg .. " Reload the stranded cargo at the marked crate."
  end
  return msg
end

-- Runs once the loaner returns are in (or timed out): the player hears the outcome and replacements are claimed.
local function completeAccidentReport(employment, report)
  employment.getState().accidentReportInProgress = nil
  if not employedOnShift(employment) then
    M.deleteAccidentCargoBox(employment)
    return
  end
  employment.parts.settlement.handleCompanyVehicleDamaged()
  if not employedOnShift(employment) then
    M.deleteAccidentCargoBox(employment)
    return
  end
  ui_message(accidentReportMessage(report), 8, "info")
  if employment.getState().shift and employment.getState().shift.accident then
    employment.getState().shift.accident.spawning = nil
  end
  M.claimAccidentReplacement(employment)
end

-- Waits for the loaner returns, or the timeout: a lost return callback must not lock accident reporting.
local function awaitLoanerReturns(employment, report)
  local pending = #report.wrecked
  local finished = false
  local function finishOnce()
    if finished then return end
    finished = true
    completeAccidentReport(employment, report)
  end
  local function startReturns()
    local loaners = employment.services.loaners()
    if not loaners or not loaners.returnVehicle then
      finishOnce()
      return
    end
    for _, entry in ipairs(report.wrecked) do
      loaners.returnVehicle(entry.inventoryId, function()
        pending = pending - 1
        if pending <= 0 then finishOnce() end
      end)
    end
  end
  core_jobsystem.create(function(job)
    job.sleep(RETURN_START_DELAY_SECONDS)
    startReturns()
  end)
  core_jobsystem.create(function(job)
    job.sleep(ACCIDENT_RETURN_TIMEOUT)
    if not finished then
      log("W", "accidentRecovery", "Loaner returns did not finish; continuing the accident report")
      finishOnce()
    end
  end)
end

function M.reportAccident(employment, preferredVehId)
  if not M.canReportAccident(employment) then
    ui_message("No company equipment to report.", 6, "warning")
    return false
  end
  local shift = employment.getState().shift
  if shift then employment.shared.kindHandler(shift.jobKind, 'cancelAssignment', 'accident report') end
  local wrecked, survivors = M.collectAccidentWreckage(employment, preferredVehId)
  if not wrecked[1] then
    ui_message("No damaged company equipment to report.", 6, "warning")
    return false
  end
  local pendingOffers, replacedTractor, replacedTrailer = replacementOffersFor(employment, wrecked, shift)
  if not pendingOffers then return false end

  local scene = reportScene(employment, wrecked, survivors)
  local salvaged = salvageReportedCargo(employment, scene, shift)
  local needReload = salvaged[1] and true or false
  local boxPos, boxName, markerName = reportCrate(employment, scene.scenePos, needReload, shift.accident)
  local strandedTrailerInvId = scene.strandedTrailerInvId
  shift.accident = {
    pos = boxPos and plainPos(boxPos)
      or (scene.scenePos and plainPos(scene.scenePos))
      or nil,
    cargoIds = needReload and salvaged or nil,
    boxName = boxName,
    markerName = markerName,
    needReload = needReload,
    needCouple = replacedTractor and strandedTrailerInvId and true or nil,
    needYardPickup = replacedTrailer and not replacedTractor and true or nil,
    yardSubtext = replacedTrailer and not replacedTractor
      and "Truck and load stay at the scene — pick up the new trailer at the yard"
      or nil,
    strandedTrailerInvId = strandedTrailerInvId,
    replacedTractor = replacedTractor,
    replacedTrailer = replacedTrailer,
    pendingOffers = pendingOffers,
    spawning = true,
  }
  employment.parts.equipment.stepOutIfInInventoryIds(scene.wreckedInvIds)
  detachReportedTrailers(employment, wrecked, survivors)
  employment.getState().accidentReportInProgress = true
  awaitLoanerReturns(employment, {
    wrecked = wrecked,
    replacedTractor = replacedTractor,
    replacedTrailer = replacedTrailer,
    strandedTrailerInvId = strandedTrailerInvId,
    needReload = needReload,
  })
  employment.parts.projections.notifyUi()
  return true
end

-- Context -----------------------------------------------------------------------------------------

local function accidentContext(inputs)
  local shared = inputs.shared
  return {
    getState = function() return inputs.state end,
    parts = inputs.parts,
    shared = inputs.shared,
    lifecycle = inputs.lifecycle,
    constants = inputs.config,
    services = setmetatable({
      ui = inputs.eligibility.uiLibrary,
      inventory = function() return overhaul_career_garage_inventory end,
      loaners = function() return overhaul_career_logistics_loanerVehicles end,
      insurance = function() return overhaul_career_repair_insurance end,
    }, {__index = shared}),
  }
end

-- Binding -----------------------------------------------------------------------------------------

function M.new(inputs)
  local api = require("overhaul/career/work/employment/operations").new {
    api = inputs.api,
    operations = M,
    context = function() return accidentContext(inputs) end,
    withContext = {
      accidentTaskGuidance = true,
      accidentUi = true,
      inventorySpawnedVehId = true,
      vehIsFlipped = true,
      spawnedVehLiveDamage = true,
      companyInventoryIsWrecked = true,
      canReportAccident = true,
      routeToWorldPos = true,
      routeAccidentRecovery = true,
      accidentVehIdMatches = true,
      markAccidentVehId = true,
      groundAccidentPos = true,
      accidentBoxPosFromScene = true,
      deleteNamedStatic = true,
      deleteAccidentCargoBox = true,
      spawnAccidentStatic = true,
      spawnAccidentCargoBox = true,
      restoreAccidentCargoBox = true,
      setCargoLocation = true,
      cargoTiedToWreckedVeh = true,
      relocateCargoOffWrecked = true,
      tryRebindAccidentCargo = true,
      tickAccidentRecovery = true,
      accidentEntryForInventory = true,
      collectAccidentWreckage = true,
      fallbackAccidentOffer = true,
      enterAccidentReplacementTractor = true,
      getMissingAccidentReplacementOffers = true,
      finishAccidentSpawn = true,
      claimAccidentReplacement = true,
      reportAccident = true,
    },
  }
  api.accidentRecoveryContext = function() return accidentContext(inputs) end
  return api
end

return M
