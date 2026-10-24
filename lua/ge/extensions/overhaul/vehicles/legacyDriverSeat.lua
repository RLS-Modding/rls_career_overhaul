-- Restores a runtime driver seat on legacy all-passenger occupant layouts.
-- Read selection, owned metadata, presence refresh, then lifecycle and public API.
local M = {}
M.dependencies = {'core_vehicle_manager', 'core_camera'}

-- The seat system is a level preset, so it is read at call time.
local repairs, pending = {}, {}
local stopping = false

local function singleLocalPlayer()
  if multiplayer_sessionManager and multiplayer_sessionManager.getCurrentSession
      and multiplayer_sessionManager.getCurrentSession() then return false end
  if core_multiseat and core_multiseat.isMultiseatActive and core_multiseat.isMultiseatActive() then return false end
  local players = core_multiseat and core_multiseat.getPlayers and core_multiseat.getPlayers() or {0}
  return #players <= 1
end

local function chooseSeat(slots, camera, enteredSeat, allowEntryFallback)
  if not slots or not next(slots) then return nil, 'no_occupant_slots' end
  for _, slot in pairs(slots) do
    if slot.defaultPermissionMode == 'driver' or slot.defaultPermissionMode == 'unrestricted' then
      return nil, 'native_driver_present'
    end
  end
  if camera and camera.camNodeID ~= nil then
    local seatId = camera.rightHandCamera and 'FR' or 'FL'
    if slots[seatId] then return seatId, 'legacy_driver_camera' end
    local side = camera.rightHandCamera and 'right' or 'left'
    local candidate
    for id, slot in pairs(slots) do
      -- A rear seat's side alone is not evidence that it belongs to the driver.
      if slot.driverSide == side then
        if candidate then return nil, 'ambiguous_driver_side' end
        candidate = id
      end
    end
    if candidate then return candidate, 'explicit_driver_side' end
  end
  if allowEntryFallback and enteredSeat and slots[enteredSeat] then
    return enteredSeat, 'first_entered_seat'
  end
  return nil, 'awaiting_seat_entry'
end

local function vehicleData(vehicleId)
  local vehicle = scenetree.findObjectById(vehicleId)
  if not vehicle or vehicle:getJBeamFilename() == 'unicycle' or vehicle.playerUsable == false then return end
  local data = core_vehicle_manager.getVehicleData(vehicleId)
  return data and data.vdata
end

local function writeOwned(record, target, key, value)
  for _, change in ipairs(record.changes) do
    if change.target == target and change.key == key then return end
  end
  if target[key] == value then return end
  record.changes[#record.changes + 1] = {target = target, key = key, before = target[key], after = value}
  target[key] = value
end

local function restoreMetadata(record)
  for i = #record.changes, 1, -1 do
    local change = record.changes[i]
    if change.target[change.key] == change.after then change.target[change.key] = change.before end
  end
end

local function refresh(vehicleId, enteredSeat)
  if stopping then return end
  local vdata = vehicleData(vehicleId)
  if not vdata then return end
  local record = repairs[vehicleId]
  if record and record.vdata ~= vdata then
    restoreMetadata(record)
    repairs[vehicleId], record = nil, nil
  end
  local slots = vdata.occupantSlotsById
  local cameras = core_camera.getCameraDataById(vehicleId)
  local driverCamera = cameras and cameras['onboard.driver']
  if not record then
    local seatId = chooseSeat(slots, driverCamera, enteredSeat, singleLocalPlayer())
    if not seatId then return end
    record = {vdata = vdata, seatId = seatId, changes = {}}
    writeOwned(record, slots[seatId], 'defaultPermissionMode', 'driver')
    repairs[vehicleId] = record
  end
  local slot = slots and slots[record.seatId]
  local camera = slot and cameras and cameras[slot.cameraName or ('occupant.' .. record.seatId)]
  if camera then
    writeOwned(record, camera, 'defaultPermissionMode', 'driver')
    if driverCamera then writeOwned(record, camera, 'rightHandCamera', driverCamera.rightHandCamera == true) end
  end
  return record
end

local function refreshSeatedPlayer(vehicleId, record)
  local api = gameplay_seatOccupants
  if not api then return end
  for _, seat in ipairs(api.getSeats(vehicleId) or {}) do
    if seat.player ~= nil and seat.seatId == record.seatId then
      local presence = api.getPlayerPresence(seat.player)
      if presence and not presence.permissionOverride then
        api.setOccupied(vehicleId, seat.seatId, seat.player, seat.weight)
      end
    end
  end
end

local function onPlayerVehiclePresenceChanged(_, _, presence)
  if stopping or not presence or presence.permissionOverride then return end
  local record = refresh(presence.vehicleId, presence.seatId)
  if record and record.seatId == presence.seatId and presence.permissionMode == 'passenger' then
    -- Native setOccupied emits this table before synchronizing controls; no sticky override or recursive hook.
    presence.permissionMode = 'driver'
  end
end

local function queueVehicle(vehicleId)
  if stopping or not vehicleId or vehicleId == -1 then return end
  local record = refresh(vehicleId)
  local api = gameplay_seatOccupants
  if not record and api then
    for _, seat in ipairs(api.getSeats(vehicleId) or {}) do
      local presence = seat.player ~= nil and api.getPlayerPresence(seat.player)
      if presence and not presence.permissionOverride then
        record = refresh(vehicleId, seat.seatId)
        if record then break end
      end
    end
  end
  if record then refreshSeatedPlayer(vehicleId, record) end
  pending[vehicleId] = true
end

local function onUpdate()
  if not next(pending) then return end
  local batch = pending
  pending = {}
  -- One attempt per lifecycle event covers camera initialization without polling the fleet.
  for vehicleId in pairs(batch) do
    local record = refresh(vehicleId)
    if record then refreshSeatedPlayer(vehicleId, record) end
  end
end

local function restoreAll()
  stopping = true
  pending = {}
  for vehicleId, record in pairs(repairs) do
    restoreMetadata(record)
    if vehicleData(vehicleId) == record.vdata then refreshSeatedPlayer(vehicleId, record) end
  end
  repairs = {}
  stopping = false
end

local function onExtensionLoaded()
  stopping = false
  for _, vehicle in ipairs(getAllVehicles()) do queueVehicle(vehicle:getId()) end
end

M.chooseSeat = chooseSeat
M.refresh = refresh
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = function() restoreAll(); stopping = true end
M.onClientEndMission = restoreAll
M.onPlayerVehiclePresenceChanged = onPlayerVehiclePresenceChanged
M.onVehicleSpawned = queueVehicle
M.onVehicleReplaced = queueVehicle
M.onVehicleResetted = queueVehicle
M.onVehicleSwitched = function(_, newId) queueVehicle(newId) end
M.onVehicleDestroyed = function(vehicleId)
  local record = repairs[vehicleId]
  if record then restoreMetadata(record) end
  repairs[vehicleId], pending[vehicleId] = nil, nil
end
M.onUpdate = onUpdate

return M
