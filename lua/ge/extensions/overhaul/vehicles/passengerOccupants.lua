-- Default player-seat visibility and job-owned passenger drawing, with layouts retained between claims.
-- Read seat ownership, layouts and meshes, claims and slot filling, update, then public API and hooks.
local M = {}
M.dependencies = {'overhaul_vehicles_legacyDriverSeat'}

-- gameplay_seatOccupants is a level preset, so it is read at call time and not a dependency.

-- Config ------------------------------------------------------------------------------------------

local OCCUPANT_PART = 'occupant_generic'

-- State -------------------------------------------------------------------------------------------

local groups = {}
local restoredGroups
local elapsed = 0
local pendingFills = {}
local pendingVisibility = {}
-- Render/reconcile only active jobs; defer orphan-claim cleanup one frame after load.
local onUpdate
local function refreshUpdateHook()
  local callback = (next(groups) or restoredGroups) and onUpdate or nil
  if M.onUpdate == callback then return end
  M.onUpdate = callback
  if extensions and extensions.hookUpdate then extensions.hookUpdate('onUpdate') end
end
-- Draw layouts per owner; they outlive the claims, so a stopped driver keeps its drawing.
local layouts = {}

-- Seat ownership ----------------------------------------------------------------------------------

local function getSeats(vehicleId)
  if overhaul_vehicles_legacyDriverSeat then overhaul_vehicles_legacyDriverSeat.refresh(vehicleId) end
  local api = gameplay_seatOccupants
  return api and api.getSeats and api.getSeats(vehicleId) or {}
end

-- Job passengers stay visible even when the seat occupants setting hides vanilla ones.
local function refreshOwnedSeats(group, seats)
  local owned, current = group.owned, group.current
  table.clear(owned)
  table.clear(current)
  local api = gameplay_seatOccupants
  seats = seats or (api and api.getSeats and api.getSeats(group.vehicleId)) or {}
  group.seatList = seats
  for _, seat in ipairs(seats) do current[seat.seatId] = seat end
  for _, id in ipairs(group.seats) do
    if current[id] and current[id].occupantType == 'dummy' then owned[id .. 'Occupant'] = id end
  end
  return owned
end

-- Passenger seats nobody else sits in (the owner's own claims count as free for drawing).
local function drawable(group, seat)
  return seat ~= nil and not seat.isDriver and seat.defaultPermissionMode == 'passenger'
    and (not seat.occupied or group.owned[seat.seatId .. 'Occupant'] ~= nil)
end

-- A seat someone else sits in now (a player, another job's passenger): its meshes are theirs.
local function takenByOther(group, seatId)
  local seat = group.current[seatId]
  return seat ~= nil and seat.occupied and group.owned[seatId .. 'Occupant'] == nil
end

-- Meshes ------------------------------------------------------------------------------------------

local function layoutFor(group)
  local layout = group.owner and layouts[group.owner]
  if layout and layout.vehicleId == group.vehicleId then return layout end
end

-- The occupant meshes of the claimed seats; with a layout, of every seat it may draw.
local function findMeshes(group)
  table.clear(group.meshes)
  table.clear(group.paths)
  local data = core_vehicle_manager.getVehicleData(group.vehicleId)
  if not data or not data.vdata then return end
  local owned, paths = group.owned, group.paths
  local everySeat = layoutFor(group) ~= nil or next(group.drawn) ~= nil
  for _, container in pairs(data.vdata.cargoStorage or {}) do
    if type(container.partPath) == 'string' and container.partPath:find('occupant_generic', 1, true) then
      local seatId = owned[container.groupId]
      if not seatId and everySeat and type(container.groupId) == 'string' then seatId = container.groupId:match('^(.*)Occupant$') end
      if seatId then paths[container.partPath] = seatId end
    end
  end
  local function add(mesh)
    local kind = mesh.originalMesh or mesh.mesh
    local seatId = paths[mesh.partPath]
    if seatId and mesh.mesh and (kind == 'character_torso' or kind == 'character_head') then
      group.meshes[#group.meshes + 1] = {groupId = seatId .. 'Occupant', seatId = seatId, mesh = mesh.mesh}
    end
  end
  for _, mesh in pairs(data.vdata.flexbodies or {}) do add(mesh) end
  for _, mesh in pairs(data.vdata.props or {}) do add(mesh) end
end

local function drawMesh(veh, entry, visible, color)
  for bit = 0, 7 do veh:setMeshHiddenInRenderView(entry.mesh, bit, not visible) end
  veh:setMeshAlpha(visible and 1 or 0, entry.mesh)
  if visible and color then veh:setMeshColor(entry.mesh, color, color, color) end
end

-- Draw layouts ------------------------------------------------------------------------------------

-- Layouts draw from their own seeded stream, never math.random, and never change the claims.
local function nextRandom(layout)
  layout.seed = layout.seed * 16807 % 2147483647
  return layout.seed
end

-- A passenger keeps one colour while drawn: a claimed seat's own colour from the seat system, else one from the layout's stream.
local function colorFor(layout, seat)
  local r, g, b
  if seat and type(seat.color) == 'string' then
    local hr, hg, hb = seat.color:match('^#(%x%x)(%x%x)(%x%x)$')
    if hr then r, g, b = tonumber(hr, 16), tonumber(hg, 16), tonumber(hb, 16) end
  end
  if not r then
    r, g, b = 64 + nextRandom(layout) % 177, 64 + nextRandom(layout) % 177, 64 + nextRandom(layout) % 177
  end
  return ColorI and ColorI(r, g, b, 255) or {r, g, b}
end

local function newLayout(owner, group)
  local layout = {vehicleId = group.vehicleId, seats = {}, colors = {}, seed = 9973 + (tonumber(group.vehicleId) or 0)}
  for _, id in ipairs(group.seats) do
    local seat = group.current[id]
    if seat and seat.occupantType == 'dummy' then
      layout.seats[#layout.seats + 1] = id
      layout.colors[id] = colorFor(layout, seat)
    end
  end
  layouts[owner] = layout
  return layout
end

-- Random leavers first, then random free seats for boarders, until the layout holds `count`.
local function resize(layout, group, count)
  while #layout.seats > count do
    local id = table.remove(layout.seats, 1 + nextRandom(layout) % #layout.seats)
    layout.colors[id] = nil
  end
  if #layout.seats >= count then return end
  local taken, free = {}, {}
  for _, id in ipairs(layout.seats) do taken[id] = true end
  for _, seat in ipairs(group.seatList or {}) do
    if not taken[seat.seatId] and drawable(group, seat) then free[#free + 1] = seat end
  end
  while #layout.seats < count and #free > 0 do
    local seat = table.remove(free, 1 + nextRandom(layout) % #free)
    layout.seats[#layout.seats + 1] = seat.seatId
    layout.colors[seat.seatId] = colorFor(layout, seat)
  end
end

-- A drawn passenger whose seat someone else took moves to a random free seat (render only). With no free seat the entry stays, undrawn while taken, and is drawn again once the seat is free.
local function relocate(layout, group)
  for i = #layout.seats, 1, -1 do
    local id = layout.seats[i]
    if takenByOther(group, id) then
      local taken, free = {}, {}
      for _, other in ipairs(layout.seats) do taken[other] = true end
      for _, seat in ipairs(group.seatList or {}) do
        if not taken[seat.seatId] and drawable(group, seat) then free[#free + 1] = seat end
      end
      if #free > 0 then
        local seat = free[1 + nextRandom(layout) % #free]
        local color = layout.colors[id]
        table.remove(layout.seats, i)
        layout.colors[id] = nil
        layout.seats[#layout.seats + 1] = seat.seatId
        layout.colors[seat.seatId] = color or colorFor(layout, seat)
      end
    end
  end
end

-- Mesh drawing ------------------------------------------------------------------------------------

local function showMeshes(group, ownershipCurrent)
  if not group.meshes or #group.meshes == 0 then return end
  local veh = scenetree.findObjectById(group.vehicleId)
  if not veh then return end
  local owned = ownershipCurrent and group.owned or refreshOwnedSeats(group)
  local layout = layoutFor(group)
  local view, drawn = group.view, group.drawn
  table.clear(view)
  if layout then
    relocate(layout, group)
    -- a layout left short of its count (no free seat at the time) fills up once a seat is free
    if layout.target and #layout.seats < layout.target then resize(layout, group, layout.target) end
    for _, id in ipairs(layout.seats) do if drawable(group, group.current[id]) then view[id] = true end end
  end
  for _, entry in ipairs(group.meshes) do
    local seatId = entry.seatId
    if view[seatId] then
      drawn[seatId] = true
      drawMesh(veh, entry, true, layout.colors[seatId])
    elseif layout and owned[entry.groupId] then
      drawMesh(veh, entry, false) -- claimed, but nobody is drawn in this seat
    elseif owned[entry.groupId] then
      drawMesh(veh, entry, true)
    elseif drawn[seatId] and takenByOther(group, seatId) then
      drawn[seatId] = nil -- someone else sits there now: their meshes are left alone
    elseif drawn[seatId] then
      drawMesh(veh, entry, false) -- a seat only the layout drew
    end
  end
  for seatId in pairs(drawn) do if not view[seatId] then drawn[seatId] = nil end end
end

-- Hides what only a layout drew (the seat system hides the claims itself when they are cleared).
local function undraw(group)
  if not next(group.drawn) then return end
  local veh = scenetree.findObjectById(group.vehicleId)
  if veh then
    refreshOwnedSeats(group) -- live occupancy: never hide someone who sits in a seat now
    for _, entry in ipairs(group.meshes) do
      local seatId = entry.seatId
      if group.drawn[seatId] and not group.owned[entry.groupId] and not takenByOther(group, seatId) then
        drawMesh(veh, entry, false)
      end
    end
  end
  table.clear(group.drawn)
end

-- Claims ------------------------------------------------------------------------------------------

local function clearClaims(group)
  local api = gameplay_seatOccupants
  local claims = group.seats
  group.seats = {}
  if api and api.clearDummyOccupant then
    for _, seatId in ipairs(claims) do
      api.clearDummyOccupant(group.vehicleId, seatId)
    end
  end
end

-- keepLayout: the driver only stepped away; the layout is drawn again when the claims come back.
local function clear(owner, keepLayout)
  local group = groups[owner]
  groups[owner] = nil
  refreshUpdateHook()
  if not keepLayout then layouts[owner] = nil end
  if group then
    undraw(group)
    clearClaims(group)
  end
end

-- Hides the seats a layout drew on a vehicle (after a Lua reload the layout's owner is gone).
local function hideDrawn(vehicleId, seatIds)
  if not vehicleId or not seatIds or #seatIds == 0 then return end
  local group = {vehicleId = vehicleId, seats = {}, owned = {}, current = {}, meshes = {}, paths = {}, view = {}, drawn = {}}
  for _, seatId in ipairs(seatIds) do group.drawn[seatId] = true end
  findMeshes(group)
  undraw(group)
end

local ownedVehicles = {}
local ownershipInventory
local function invalidateOwnership()
  ownedVehicles = {}
end

local function clearAll()
  invalidateOwnership()
  pendingVisibility = {}
  table.clear(pendingFills)
  table.clear(layouts)
  local previous = groups
  groups = {}
  for _, group in pairs(previous) do undraw(group) clearClaims(group) end
  for _, group in pairs(restoredGroups or {}) do clearClaims(group) end
  restoredGroups = nil
  refreshUpdateHook()
end

local function reconcile(group)
  local api = gameplay_seatOccupants
  if not api or not api.getSeats or not api.setDummyOccupant then return 0 end

  local seats = getSeats(group.vehicleId)
  table.sort(seats, function(a, b) return a.seatId < b.seatId end)
  local byId = group.current
  table.clear(byId)
  for _, seat in ipairs(seats) do byId[seat.seatId] = seat end
  local kept, owned = group.spareSeats, group.owned
  table.clear(kept)
  table.clear(owned)
  for _, seatId in ipairs(group.seats) do
    local seat = byId[seatId]
    if seat and seat.occupantType == 'dummy' then
      if not seat.isDriver and seat.defaultPermissionMode == 'passenger' and #kept < group.count then
        kept[#kept + 1] = seatId
        owned[seatId] = true
      else
        api.clearDummyOccupant(group.vehicleId, seatId)
        seat.occupied = false
      end
    end
  end
  group.spareSeats, group.seats = group.seats, kept
  for _, seat in ipairs(seats) do
    if #kept >= group.count then break end
    if not seat.isDriver and seat.defaultPermissionMode == 'passenger'
        and not seat.occupied and not owned[seat.seatId] then
      if api.setDummyOccupant(group.vehicleId, seat.seatId) then
        kept[#kept + 1] = seat.seatId
        owned[seat.seatId] = true
        seat.occupied, seat.occupantType = true, 'dummy'
      end
    end
  end
  refreshOwnedSeats(group, seats)
  findMeshes(group)
  showMeshes(group, true)
  return #kept
end

local function newGroup(owner, vehicleId)
  local group = {owner = owner, vehicleId = vehicleId, count = 0, seats = {}, spareSeats = {}, owned = {}, current = {},
    meshes = {}, paths = {}, view = {}, drawn = {}}
  groups[owner] = group
  refreshUpdateHook()
  return group
end

local function setPassengers(owner, vehicleId, count)
  count = tonumber(count) or 0
  if count ~= count or count == math.huge then count = 0 end
  count = math.max(0, math.floor(count))
  if not vehicleId or vehicleId == -1 or count == 0 then
    clear(owner)
    return 0
  end
  local group = groups[owner]
  if group and group.vehicleId ~= vehicleId then clear(owner); group = nil end
  group = group or newGroup(owner, vehicleId)
  group.count = count
  local seated = reconcile(group)
  -- A drawn layout follows a count set outside a countdown (render only).
  local layout = layoutFor(group)
  if layout and not layout.saved and (#layout.seats ~= count or layout.target ~= count) then
    layout.target = count
    resize(layout, group, count)
    showMeshes(group, true)
  end
  return seated
end

-- Draws `count` passengers for `owner` in its layout without changing any claim. The first call of a countdown remembers the layout, so displayRestore can put it back if the stop is interrupted.
local function display(owner, vehicleId, count)
  if not vehicleId or vehicleId == -1 then return end
  local group = groups[owner]
  if group and group.vehicleId ~= vehicleId then clear(owner); group = nil end
  group = group or newGroup(owner, vehicleId)
  refreshOwnedSeats(group, getSeats(vehicleId))
  local layout = layoutFor(group) or newLayout(owner, group)
  if not layout.saved then
    local seats, colors = {}, {}
    for i, id in ipairs(layout.seats) do seats[i] = id end
    for id, color in pairs(layout.colors) do colors[id] = color end
    layout.saved = {seats = seats, colors = colors, target = layout.target}
  end
  layout.target = math.max(0, math.floor(tonumber(count) or 0))
  resize(layout, group, layout.target)
  findMeshes(group)
  showMeshes(group, true)
end

local function displayRestore(owner)
  local layout = layouts[owner]
  if not layout or not layout.saved then return end
  layout.seats, layout.colors, layout.target, layout.saved = layout.saved.seats, layout.saved.colors, layout.saved.target, nil
  local group = groups[owner]
  if group and group.vehicleId == layout.vehicleId then
    refreshOwnedSeats(group)
    findMeshes(group)
    showMeshes(group, true)
    if group.count == 0 and #group.seats == 0 and #layout.seats == 0 then groups[owner] = nil; refreshUpdateHook() end
  end
end

-- displayCommit keeps the new layout once the stop's own setPassengers call has run.
local function displayCommit(owner)
  local layout = layouts[owner]
  if layout then layout.saved = nil end
end

-- Seat slots --------------------------------------------------------------------------------------

-- A seat exists for the seat system only once its seat_occupant slot holds the occupant part, so empty slots are not seats.
local function eachSeatSlot(node, visit)
  if type(node) ~= 'table' then return end
  if type(node.id) == 'string' and node.id:find('^seat_occupant_') then return visit(node) end
  for _, child in pairs(node.children or {}) do eachSeatSlot(child, visit) end
end

local function isFillable(node)
  if (node.chosenPartName or '') ~= '' then return false end
  if type(node.suitablePartNames) ~= 'table' then return true end
  for _, name in ipairs(node.suitablePartNames) do
    if name == OCCUPANT_PART then return true end
  end
  return false
end

local function scanSeatSlots(partsTree)
  local scan = {total = 0, empty = {}}
  eachSeatSlot(partsTree, function(node)
    scan.total = scan.total + 1
    if isFillable(node) then scan.empty[#scan.empty + 1] = node.path or node.id end
  end)
  return scan
end

-- Every seat slot but the driver's carries passengers; one driver is assumed until the seat system reports seats.
local function countPassengerSeats(vehicleId, slotCount)
  slotCount = tonumber(slotCount) or 0
  if slotCount <= 0 then return 0 end
  local drivers = 0
  for _, seat in ipairs(vehicleId and getSeats(vehicleId) or {}) do
    if seat.isDriver or seat.defaultPermissionMode == 'driver' then drivers = drivers + 1 end
  end
  return math.max(0, slotCount - math.max(1, drivers))
end

-- Respawns the vehicle in place with the occupant part in every empty seat slot, carrying part conditions (wear, damage, fuel) across like the career part shop. Returns how many slots are being filled, or false.
local function fillEmptySeatSlots(vehicleId, partsTree, onDone)
  local veh = vehicleId and be:getObjectByID(vehicleId)
  local vehicleData = veh and core_vehicle_manager.getVehicleData(vehicleId)
  if not vehicleData or type(vehicleData.config) ~= 'table' or type(partsTree) ~= 'table' then return false end
  local tree, filled = deepcopy(partsTree), 0
  eachSeatSlot(tree, function(node)
    if isFillable(node) then
      node.chosenPartName = OCCUPANT_PART
      filled = filled + 1
    end
  end)
  if filled == 0 then return false end
  local config = deepcopy(vehicleData.config)
  config.parts = nil -- a flat parts map would take priority over the tree on spawn
  config.partsTree = tree
  pendingFills[vehicleId] = {model = veh.JBeam, config = config, onDone = onDone,
    licenseText = core_vehicles.getVehicleLicenseText(veh)}
  veh:queueLuaCommand(string.format(
    "obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(%d, 'seatFillConditions', '%d,' .. serialize(partCondition.getConditions())))",
    require('overhaul/lib/vehicles/callbacks').open('seatFillConditions', {owner = 'passengerOccupants', timeout = false}), vehicleId))
  return filled
end

local function onSeatFillConditions(vehicleId, partConditions)
  local fill = pendingFills[vehicleId]
  pendingFills[vehicleId] = nil
  local veh = fill and be:getObjectByID(vehicleId)
  if not veh then return end
  core_vehicles.replaceVehicle(fill.model, {config = fill.config, licenseText = fill.licenseText, keepOtherVehRotation = true}, veh)
  veh = be:getObjectByID(vehicleId) or veh
  if type(partConditions) == 'table' and next(partConditions) then
    local painting = overhaul_career_parts_painting
    local primer = painting and painting.getPrimerColor and painting.getPrimerColor() or nil
    core_vehicleBridge.executeAction(veh, 'initPartConditions', partConditions, nil, nil, nil, primer)
  end
  if fill.onDone then
    core_vehicleBridge.requestValue(veh, function() fill.onDone(vehicleId) end, 'ping')
  end
end

-- Default visibility -----------------------------------------------------------------------------

-- Whole-vehicle fades and part highlights reset mesh alpha after the stock seat
-- system has hidden empty seats. Reassert the player default after those writes;
-- live dummy claims, seated passengers and job layouts explicitly opt in.
local playerMeshes = {}
local function isPlayerVehicle(id)
  if not id then return false end
  local inventory = overhaul_career_garage_inventory
  if inventory ~= ownershipInventory then
    invalidateOwnership()
    ownershipInventory = inventory
  end
  -- Cache misses as well as hits: unowned traffic fades must not poll inventory.
  if ownedVehicles[id] == nil then
    ownedVehicles[id] = not not (inventory and inventory.getInventoryIdFromVehicleId
      and inventory.getInventoryIdFromVehicleId(id))
  end
  return ownedVehicles[id] or id == be:getPlayerVehicleID(0)
end

local function onVehicleVisible(id)
  if not isPlayerVehicle(id) then return end
  local data = core_vehicle_manager.getVehicleData(id)
  local veh = scenetree and scenetree.findObjectById(id)
  if data and data.vdata and veh then
    local cached = playerMeshes[id]
    if not cached or cached.data ~= data.vdata then
      local group = {vehicleId = id, owned = {}, meshes = {}, paths = {}, drawn = {all = true}}
      findMeshes(group)
      cached = {data = data.vdata, meshes = group.meshes}
      playerMeshes[id] = cached
    end
    local allowed = {}
    local api = gameplay_seatOccupants
    for _, seat in ipairs(api and api.getSeats and api.getSeats(id) or {}) do
      if seat.occupantType == 'dummy' or (seat.occupantType == 'player' and not seat.isDriver) then
        allowed[seat.seatId] = true
      end
    end
    for _, entry in ipairs(cached.meshes) do
      if not allowed[entry.seatId] then drawMesh(veh, entry, false) end
    end
  end
  for _, group in pairs(groups) do
    if group.vehicleId == id then showMeshes(group) end
  end
end

-- Stock seat rendering also runs in an asynchronous cargo reply after camera
-- changes and rebuilds. Queue one ping after that event's handlers have run, so
-- its reply restores our default after the stock reply, without an idle hook.
local function restoreAfterSeatSync(id)
  if not id or id == -1 or pendingVisibility[id] or not isPlayerVehicle(id) then return end
  if not core_jobsystem or not core_vehicleBridge then return end
  local token = {}
  pendingVisibility[id] = token
  core_jobsystem.create(function(job)
    job.sleep(0)
    if pendingVisibility[id] ~= token then return end
    local vehicle = scenetree.findObjectById(id)
    if not vehicle then pendingVisibility[id] = nil; return end
    core_vehicleBridge.requestValue(vehicle, function()
      if pendingVisibility[id] ~= token then return end
      pendingVisibility[id] = nil
      onVehicleVisible(id)
    end, 'ping')
  end)
end

-- Per-frame update --------------------------------------------------------------------------------

onUpdate = function(dtReal)
  -- Vanilla restores its claims separately; wait until all deserialization hooks finish.
  if restoredGroups then
    for _, group in pairs(restoredGroups) do
      hideDrawn(group.vehicleId, group.previewed)
      clearClaims(group)
    end
    restoredGroups = nil
    refreshUpdateHook()
  end
  elapsed = elapsed + (dtReal or 0)
  if elapsed < 0.5 then
    for _, group in pairs(groups) do showMeshes(group) end
    return
  end
  elapsed = 0
  if not next(groups) then return end
  local vehicleId = be:getPlayerVehicleID(0)
  for owner, group in pairs(groups) do
    if group.vehicleId ~= vehicleId then clear(owner, true) else reconcile(group) end
  end
end

-- Lifecycle and serialization ---------------------------------------------------------------------

-- Claims are cleared; a draw layout survives so a driver returning to the same vehicle sees it again.
local function onVehicleSwitched(_, newId, player)
  if player and player ~= 0 then return end
  for owner, group in pairs(groups) do
    if group.vehicleId ~= newId then clear(owner, true) end
  end
  onVehicleVisible(newId)
  restoreAfterSeatSync(newId)
end

local function onVehicleDestroyed(vehicleId)
  pendingFills[vehicleId] = nil
  ownedVehicles[vehicleId] = nil
  playerMeshes[vehicleId] = nil
  pendingVisibility[vehicleId] = nil
  -- also the layouts kept for a roleplay pause, which have no live group
  for owner, layout in pairs(layouts) do
    if layout.vehicleId == vehicleId then layouts[owner] = nil end
  end
  for owner, group in pairs(groups) do
    if group.vehicleId == vehicleId then clear(owner) end
  end
end

local function onSerialize()
  local claims = {}
  for owner, group in pairs(groups) do
    local seats = {}
    for i, seatId in ipairs(group.seats) do seats[i] = seatId end
    claims[owner] = {vehicleId = group.vehicleId, seats = seats}
    local previewed = {}
    for seatId in pairs(group.drawn) do
      if not group.owned[seatId .. 'Occupant'] then previewed[#previewed + 1] = seatId end
    end
    if #previewed > 0 then
      table.sort(previewed)
      claims[owner].previewed = previewed
    end
  end
  return {claims = claims}
end

local function onDeserialized(data)
  local claims = {}
  for owner, group in pairs(data and data.claims or {}) do
    local seats = {}
    for i, seatId in ipairs(group.seats or {}) do seats[i] = seatId end
    claims[owner] = {vehicleId = group.vehicleId, seats = seats, previewed = group.previewed}
  end
  clearAll()
  restoredGroups = next(claims) and claims or nil
  refreshUpdateHook()
end

-- Public API --------------------------------------------------------------------------------------

M.setPassengers = setPassengers
M.display = display
M.displayRestore = displayRestore
M.displayCommit = displayCommit
-- Read-only: the seats drawn for `owner` (its layout, else its claims), for scenarios and tools.
M.drawnSeats = function(owner)
  local out, layout, group = {}, layouts[owner], groups[owner]
  local list = layout and (not group or layout.vehicleId == group.vehicleId) and layout.seats or (group and group.seats) or {}
  for i, id in ipairs(list) do out[i] = id end
  return out
end
M.clear = clear
M.scanSeatSlots = scanSeatSlots
M.countPassengerSeats = countPassengerSeats
M.fillEmptySeatSlots = fillEmptySeatSlots
M.onSeatFillConditions = onSeatFillConditions

-- Game hooks --------------------------------------------------------------------------------------

M.onOverhaulInventoryBindingsChanged = invalidateOwnership
M.onOverhaulVehicleAdded = invalidateOwnership
M.onOverhaulVehicleRemoved = invalidateOwnership
M.onOverhaulSetupInventoryFinished = invalidateOwnership
M.onVehicleVisible = onVehicleVisible
local function onVehicleRebuilt(id)
  ownedVehicles[id] = nil
  playerMeshes[id] = nil
  pendingVisibility[id] = nil -- a replaced vehicle can drop the old ping reply
  onVehicleVisible(id)
  restoreAfterSeatSync(id)
end
M.onVehicleSpawned = onVehicleRebuilt
M.onVehicleReplaced = onVehicleRebuilt
M.onCameraChanged = function(player)
  if player and player ~= 0 then return end
  restoreAfterSeatSync(be:getPlayerVehicleID(0))
end
M.onSeatOccupantEnter = function(_, id) restoreAfterSeatSync(id) end
M.onSeatOccupantExit = M.onSeatOccupantEnter
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleDestroyed = onVehicleDestroyed
M.onOverhaulBeforeSetProfile = clearAll
M.onClientEndMission = clearAll
M.onExtensionUnloaded = clearAll
M.onOverhaulActive = function(active) if active == false then clearAll() end end
M.onSettingsChanged = function() for _, group in pairs(groups) do reconcile(group) end end
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.onExtensionLoaded = function(data) if data then onDeserialized(data) end end

return M
