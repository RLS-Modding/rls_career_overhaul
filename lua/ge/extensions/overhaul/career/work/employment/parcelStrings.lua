-- Parcel-string capacity, stop ordering and assignment transformations for one employment instance.
-- Pure operations: M.new binds them to the instance context through operations.lua.
local M = {}

-- Config ------------------------------------------------------------------------------------------

local STRING_CLUSTER_M = 200
local LEVEL_STOPS_FULL = 30
local LEVEL_STOPS_MIN = 4
local LEVEL_STOPS_MAX = 8
local FALLBACK_SLOTS = 256

-- Shared helpers ----------------------------------------------------------------------------------

local function finitePositive(value)
  value = tonumber(value)
  return value and value > 0 and value < math.huge and value or nil
end

local function clampedLevel(level)
  if level == nil then return nil end
  return math.max(0, math.min(LEVEL_STOPS_FULL, math.floor(tonumber(level) or 0)))
end

local function stringDestOf(group)
  return group.destLocation or group.destination or group.destFacId
end

local function assignedSetFromShift(shift)
  local set = {}
  for _, id in ipairs((shift and shift.assignedCargoIds) or {}) do
    set[id] = true
  end
  return set
end

local function withoutDelivered(cargoIds, delivered)
  local kept = {}
  for _, cargoId in ipairs(cargoIds or {}) do
    if not delivered[cargoId] then
      table.insert(kept, cargoId)
    end
  end
  return kept
end

-- Capacity and selection --------------------------------------------------------------------------

function M.maxStopsForLevel(level)
  local lv = clampedLevel(level)
  if lv == nil then return math.huge end
  return math.floor(LEVEL_STOPS_MIN + (LEVEL_STOPS_MAX - LEVEL_STOPS_MIN) * (lv / LEVEL_STOPS_FULL) + 1e-9)
end

function M.maxSlotsPerDest(capacity, level)
  capacity = math.max(1, math.floor(tonumber(capacity) or 1))
  local lv = clampedLevel(level)
  if lv == nil then return capacity end
  local split = 3 - 2 * (lv / LEVEL_STOPS_FULL)
  return math.max(1, math.ceil(capacity / split))
end

function M.resolveCapacity(employment, fac)
  local slots = FALLBACK_SLOTS
  local caps = employment.services.loanerCapabilities and employment.services.loanerCapabilities()
  if caps and fac then
    local truck = caps.getIssuedLoanersForFacility(fac, "parcel", {})
    if truck and caps.getParcelSlots then
      slots = math.floor(finitePositive(caps.getParcelSlots(truck)) or FALLBACK_SLOTS)
    end
  end
  return slots
end

function M.takeOneItem(items, slotBudget)
  slotBudget = tonumber(slotBudget) or 0
  for _, item in ipairs(items or {}) do
    local itemSlots = math.max(1, math.floor(tonumber(item.slots) or 1))
    if itemSlots <= slotBudget then
      return { item }, itemSlots
    end
  end
  return {}, 0
end

function M.takeItems(items, slotBudget)
  local take = {}
  local usedSlots = 0
  slotBudget = tonumber(slotBudget) or 0
  for _, item in ipairs(items or {}) do
    local itemSlots = math.max(1, math.floor(tonumber(item.slots) or 1))
    if usedSlots + itemSlots <= slotBudget then
      take[#take + 1] = item
      usedSlots = usedSlots + itemSlots
    end
  end
  return take, usedSlots
end

function M.trimItems(employment, fac, items)
  return M.takeItems(items, M.resolveCapacity(employment, fac))
end

function M.cargoMatchesStop(cargo, stop)
  if not (cargo and stop) then return false end
  local cargoId = cargo.id
  for _, id in ipairs(stop.cargoIds or {}) do
    if id == cargoId or tostring(id) == tostring(cargoId) then return true end
  end
  local dest = cargo.destination
  if not (dest and dest.facId and stop.destFacId) then return false end
  if dest.facId ~= stop.destFacId then return false end
  if stop.destPsPath and dest.psPath and dest.psPath ~= stop.destPsPath then return false end
  return true
end

-- Facility locations and distances ----------------------------------------------------------------

function M.resolveFacilityLocation(employment, facOrLoc, preferredPsPath)
  if type(facOrLoc) == "table" then
    if facOrLoc.type == "facilityParkingspot" and facOrLoc.facId and facOrLoc.psPath then
      return facOrLoc
    end
    if facOrLoc.facId and facOrLoc.psPath then
      return { type = "facilityParkingspot", facId = facOrLoc.facId, psPath = facOrLoc.psPath }
    end
  end
  local facId = type(facOrLoc) == "table" and facOrLoc.facId or facOrLoc
  if not facId then return nil end
  if preferredPsPath then
    return { type = "facilityParkingspot", facId = facId, psPath = preferredPsPath }
  end
  local gen = employment.services.generator and employment.services.generator()
  local fac = gen and gen.getFacilityById and gen.getFacilityById(facId)
  if not fac then return nil end
  local spot = (fac.dropOffSpots and fac.dropOffSpots[1])
    or (fac.pickUpSpots and fac.pickUpSpots[1])
    or (fac.inspectSpots and fac.inspectSpots[1])
  if not spot then return nil end
  local path = (spot.getPath and spot:getPath()) or spot.psPath
  if not path then return nil end
  return { type = "facilityParkingspot", facId = facId, psPath = path }
end

function M.facDistanceBetween(employment, fromFacOrLoc, toFacOrLoc)
  if not fromFacOrLoc or not toFacOrLoc then return math.huge end
  local fromId = type(fromFacOrLoc) == "table" and fromFacOrLoc.facId or fromFacOrLoc
  local toId = type(toFacOrLoc) == "table" and toFacOrLoc.facId or toFacOrLoc
  local fromPs = type(fromFacOrLoc) == "table" and fromFacOrLoc.psPath
  local toPs = type(toFacOrLoc) == "table" and toFacOrLoc.psPath
  if fromId and toId and fromId == toId and (not fromPs or not toPs or fromPs == toPs) then
    return 0
  end
  local gen = employment.services.generator and employment.services.generator()
  if not (gen and gen.getDistanceBetweenFacilities) then return math.huge end
  local loc1 = M.resolveFacilityLocation(employment, fromFacOrLoc)
  local loc2 = M.resolveFacilityLocation(employment, toFacOrLoc)
  if not loc1 or not loc2 then return math.huge end
  local dist = (gen.getDistanceBetweenFacilities(loc1, loc2))
  return tonumber(dist) or math.huge
end

-- Stop ordering and updates -----------------------------------------------------------------------

-- Nearest-neighbour order; groups within the cluster radius of the last stop follow it immediately.
function M.orderGroups(employment, groups, fromLoc)
  local remaining = {}
  for _, g in ipairs(groups or {}) do table.insert(remaining, g) end
  local ordered = {}
  local cursor = fromLoc
  local function pickNearest()
    if not remaining[1] then return nil end
    local bestI, bestD = 1, math.huge
    for i, g in ipairs(remaining) do
      local d = M.facDistanceBetween(employment, cursor, stringDestOf(g))
      if d < bestD then bestI, bestD = i, d end
    end
    return table.remove(remaining, bestI)
  end
  local function pullCluster(anchor)
    local from = stringDestOf(anchor)
    local i = 1
    while i <= #remaining do
      local d = M.facDistanceBetween(employment, from, stringDestOf(remaining[i]))
      if d <= STRING_CLUSTER_M then
        local g = table.remove(remaining, i)
        table.insert(ordered, g)
        cursor = stringDestOf(g) or cursor
        from = cursor
      else
        i = i + 1
      end
    end
  end
  while remaining[1] do
    local pick = pickNearest()
    table.insert(ordered, pick)
    cursor = stringDestOf(pick) or cursor
    pullCluster(pick)
  end
  return ordered
end

function M.applyStop(employment, shift, stopIndex)
  if not shift or not shift.stops then return end
  local stop = shift.stops[stopIndex]
  if not stop then return end
  shift.stopIndex = stopIndex
  shift.destFacId = stop.destFacId
  shift.destPsPath = stop.destPsPath
  shift.destLocation = stop.destLocation
  local total = tonumber(shift.stringStopTotal) or #shift.stops
  local completed = tonumber(shift.stopsCompleted) or 0
  local current = math.min(total, completed + 1)
  local destName = (employment.labels.destination and employment.labels.destination(stop.destLocation))
    or (employment.labels.facility and employment.labels.facility(stop.destFacId))
  shift.outboundLabel = string.format("Stop %d/%d: deliver to %s", current, total, destName)
  shift.outboundSubtext = string.format("%d this stop · %d on truck",
    #(stop.cargoIds or {}),
    #(shift.assignedCargoIds or {}))
end

-- Cargo that the drop-off reports as delivered leaves the shift, its string membership and every stop.
function M.pruneDelivered(_ctx, shift, dropOffData)
  if not shift or not shift.stringMode then return end
  local delivered = {}
  local assigned = assignedSetFromShift(shift)
  for _, cargo in ipairs((dropOffData and dropOffData.cargo) or {}) do
    if cargo then
      if cargo.id and assigned[cargo.id] then
        delivered[cargo.id] = true
      end
      for _, cargoId in ipairs(cargo.ids or {}) do
        if assigned[cargoId] then
          delivered[cargoId] = true
        end
      end
    end
  end
  if not next(delivered) then return end
  shift.assignedCargoIds = withoutDelivered(shift.assignedCargoIds, delivered)
  if shift.stringCargoIds then
    shift.stringCargoIds = withoutDelivered(shift.stringCargoIds, delivered)
  end
  for _, stop in ipairs(shift.stops or {}) do
    stop.cargoIds = withoutDelivered(stop.cargoIds, delivered)
  end
end

function M.currentStopHasRemaining(shift)
  if not shift or not shift.stops then return false end
  local stop = shift.stops[shift.stopIndex or 1]
  if not stop then return false end
  return #(stop.cargoIds or {}) > 0
end

function M.advanceStop(employment, shift)
  if not shift or not shift.stops then return false end
  local start = (shift.stopIndex or 1) + 1
  for i = start, #shift.stops do
    if #(shift.stops[i].cargoIds or {}) > 0 then
      M.applyStop(employment, shift, i)
      return true
    end
  end
  return false
end

-- String planning ---------------------------------------------------------------------------------

local function membershipFromShift(shift)
  local membership = {}
  for _, cargoId in ipairs(shift.stringCargoIds or shift.assignedCargoIds or {}) do
    membership[cargoId] = true
  end
  return membership
end

-- Adds one cargo to its destination group, creating the group on first sight.
local function addCargoToGroup(byDest, cargo, dest)
  local key = tostring(dest.facId) .. "|" .. tostring(dest.psPath)
  local group = byDest[key]
  if not group then
    group = {
      destination = dest,
      destFacId = dest.facId,
      destPsPath = dest.psPath,
      destLocation = dest,
      items = {},
      cargoIds = {},
      cargoSet = {},
    }
    byDest[key] = group
  end
  if not group.cargoSet[cargo.id] then
    group.cargoSet[cargo.id] = true
    table.insert(group.items, cargo)
    table.insert(group.cargoIds, cargo.id)
  end
end

-- Groups the string's cargo still riding in the vehicle by destination; timed cargo goes back to the origin.
local function groupLiveCargo(employment, shift, membership, parcelMgr)
  local byDest = {}
  local liveIds, liveSet = {}, {}
  local cargoHasTimed = employment.prepare.cargoHasTimedModifier
  local function consider(cargo)
    if not (cargo and cargo.id and membership[cargo.id]) then return end
    if cargoHasTimed and cargoHasTimed(cargo) then
      if cargo.location and cargo.location.type == "vehicle" and shift.originLocation and parcelMgr.changeCargoLocation then
        parcelMgr.changeCargoLocation(cargo.id, shift.originLocation)
      end
      return
    end
    if not (cargo.location and cargo.location.type == "vehicle") then return end
    local dest = cargo.destination
    if not (dest and dest.facId and dest.psPath) then return end
    if not liveSet[cargo.id] then
      liveSet[cargo.id] = true
      table.insert(liveIds, cargo.id)
    end
    addCargoToGroup(byDest, cargo, dest)
  end

  if parcelMgr.getAllCargoInVehicles then
    for _, cargo in ipairs(parcelMgr.getAllCargoInVehicles(true) or {}) do
      consider(cargo)
    end
  end
  for cargoId in pairs(membership) do
    if not liveSet[cargoId] then
      consider(parcelMgr.getCargoById(cargoId))
    end
  end
  return byDest, liveIds
end

local function stopsFromGroups(ordered)
  local stops = {}
  for _, group in ipairs(ordered) do
    table.insert(stops, {
      destFacId = group.destFacId,
      destPsPath = group.destPsPath,
      destLocation = group.destLocation,
      cargoIds = group.cargoIds,
    })
  end
  return stops
end

function M.planFromTruck(employment, shift, fromLoc)
  if not shift or not shift.stringMode then return false end
  local parcelMgr = employment.services.parcelManager and employment.services.parcelManager()
  if not (parcelMgr and parcelMgr.getCargoById) then return false end

  local membership = membershipFromShift(shift)
  if not next(membership) then
    shift.stops = {}
    shift.assignedCargoIds = {}
    shift.stopIndex = 1
    shift.stringRouteLocked = true
    return false
  end

  local byDest, liveIds = groupLiveCargo(employment, shift, membership, parcelMgr)
  shift.assignedCargoIds = liveIds
  shift.stringCargoIds = {}
  for _, cargoId in ipairs(liveIds) do
    table.insert(shift.stringCargoIds, cargoId)
  end
  local groups = {}
  for _, group in pairs(byDest) do
    group.cargoSet = nil
    table.insert(groups, group)
  end
  if not groups[1] then
    shift.stops = {}
    shift.stopIndex = 1
    shift.stringStopTotal = 0
    shift.stopsCompleted = 0
    shift.stringRouteLocked = true
    return false
  end

  local ordered = M.orderGroups(employment, groups, fromLoc or shift.originLocation or shift.originFacId)
  shift.stops = stopsFromGroups(ordered)
  shift.stringStopTotal = #shift.stops
  shift.stopsCompleted = 0
  shift.stopIndex = 1
  shift.stringRouteLocked = true
  M.applyStop(employment, shift, 1)
  return true
end

-- Job creation -----------------------------------------------------------------------------------

-- Picks destination groups in order until the truck or the stop limit is full; each stop keeps a share of slots.
local function selectStopGroups(ordered, capacity, level)
  local maxStops = M.maxStopsForLevel(level)
  local maxPerDest = M.maxSlotsPerDest(capacity, level)
  local selected = {}
  local usedSlots = 0
  local allIds = {}
  for i, group in ipairs(ordered) do
    if #selected >= maxStops then break end
    local remainSlots = capacity - usedSlots
    if remainSlots <= 0 then break end
    local moreDests = i < #ordered and (#selected + 1) < maxStops
    local slotBudget = remainSlots
    if moreDests then
      slotBudget = math.min(remainSlots, maxPerDest)
    end
    local take, takeSlots = M.takeItems(group.items, slotBudget)
    if not take[1] then
      take, takeSlots = M.takeOneItem(group.items, remainSlots)
    end
    if take[1] then
      table.insert(selected, {
        destination = group.destination,
        items = take,
        facId = group.facId,
      })
      usedSlots = usedSlots + takeSlots
      for _, item in ipairs(take) do
        table.insert(allIds, item.id)
      end
    end
  end
  return selected, usedSlots, allIds
end

local function stopsFromSelected(selected)
  local stops = {}
  for _, group in ipairs(selected) do
    local ids = {}
    for _, item in ipairs(group.items or {}) do table.insert(ids, item.id) end
    table.insert(stops, {
      destFacId = group.destination.facId,
      destPsPath = group.destination.psPath,
      destLocation = group.destination,
      cargoIds = ids,
    })
  end
  return stops
end

local function jobFromStops(employment, facId, stops, selected, usedSlots, allIds)
  local first = stops[1]
  local stopCount = #stops
  return {
    kind = "parcel",
    stringMode = true,
    stops = stops,
    stopIndex = 1,
    cargoIds = allIds,
    destFacId = first.destFacId,
    destPsPath = first.destPsPath,
    destLocation = first.destLocation,
    originLocation = selected[1].items[1] and selected[1].items[1].origin
      or { type = "facilityParkingspot", facId = facId },
    needsRemotePickup = false,
    pickupFacId = facId,
    label = stopCount > 1
      and string.format("Parcel string: %d stops", stopCount)
      or string.format("Deliver assigned parcels to %s",
        (employment.labels.destination and employment.labels.destination(first.destLocation)) or "the destination"),
    subtext = string.format("%d parcels · %d slots · empty return after last stop",
      #allIds, usedSlots),
  }
end

function M.buildJob(employment, facId)
  local gen = employment.services.generator and employment.services.generator()
  local fac = gen and gen.getFacilityById and gen.getFacilityById(facId)
  if not fac then return nil end
  local groups = employment.prepare.parcelGroups and employment.prepare.parcelGroups(facId) or {}
  if not groups[1] then return nil end
  local capacity = M.resolveCapacity(employment, fac)
  local levelFn = employment.prepare and employment.prepare.deliveryLevel
  local level = levelFn and levelFn() or nil
  local yardLoc = M.resolveFacilityLocation(employment, facId) or facId
  local ordered = M.orderGroups(employment, groups, yardLoc)
  local selected, usedSlots, allIds = selectStopGroups(ordered, capacity, level)
  if not selected[1] or not allIds[1] then return nil end
  local caps = employment.services.loanerCapabilities and employment.services.loanerCapabilities()
  if not (caps and caps.canIssueLoanersForFacility(fac, "parcel", { targetLoad = usedSlots })) then
    return nil
  end
  return jobFromStops(employment, facId, stopsFromSelected(selected), selected, usedSlots, allIds)
end

-- Exports -----------------------------------------------------------------------------------------

M.STRING_CLUSTER_M = STRING_CLUSTER_M
M.LEVEL_STOPS_FULL = LEVEL_STOPS_FULL
M.LEVEL_STOPS_MIN = LEVEL_STOPS_MIN
M.LEVEL_STOPS_MAX = LEVEL_STOPS_MAX
M.FALLBACK_SLOTS = FALLBACK_SLOTS

-- Binding -----------------------------------------------------------------------------------------

function M.new(inputs)
  return require("overhaul/career/work/employment/operations").new {
    api = inputs.api,
    operations = M,
    context = function() return inputs.backhaul.parcelStringContext() end,
    withContext = {
      resolveCapacity = true,
      trimItems = true,
      resolveFacilityLocation = true,
      facDistanceBetween = true,
      orderGroups = true,
      applyStop = true,
      pruneDelivered = true,
      advanceStop = true,
      planFromTruck = true,
      buildJob = true,
    },
  }
end

return M
