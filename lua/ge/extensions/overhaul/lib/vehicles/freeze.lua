-- Owns temporary controller freezes. Callers release only their own hold; vehicle and career lifetimes end it too.
local M = {}
local lifecycle = require('overhaul/lib/lifecycle/host')
local vehicles = {}

local function findVehicle(id) return getObjectByID(id) end

local function applyFreeze(vehicle, enabled)
  -- A late restore can outlive the level bridge; the vehicle command still owns its controller.
  if core_vehicleBridge then
    core_vehicleBridge.executeAction(vehicle, 'setFreeze', enabled)
  else
    vehicle:queueLuaCommand(enabled and 'controller.setFreeze(1)' or 'controller.setFreeze(0)')
  end
end

local function hasFreezingHold(record)
  for hold in pairs(record.holds) do if hold.freezing then return true end end
  return false
end

local function finish(hold, reason, discardVehicle)
  if not hold.active then return false end
  hold.active = false
  hold.reason = reason
  if reason == 'timed out' then
    log('W', 'vehicleFreeze', string.format('Released expired freeze for %s on vehicle %s', hold.owner, tostring(hold.vehicleId)))
  end
  lifecycle.done(hold.lifetime)
  local record = vehicles[hold.vehicleId]
  if record == hold.record then
    record.holds[hold] = nil
    if record.frozen and not hasFreezingHold(record) then
      record.frozen = false
      if not discardVehicle and findVehicle(hold.vehicleId) == record.vehicle then
        applyFreeze(record.vehicle, false)
      end
    end
    if not next(record.holds) then vehicles[hold.vehicleId] = nil end
  end
  if hold.onReleased and reason ~= 'lifetime ended' and reason ~= 'owner unloaded' then
    local ok, err = xpcall(function() hold.onReleased(reason) end, debug.traceback)
    if not ok then log('E', 'vehicleFreeze', tostring(err)) end
  end
  return true
end

function M.acquire(owner, vehicleId, options)
  options = options or {}
  local vehicle = findVehicle(vehicleId)
  if not vehicle then return nil end
  local record = vehicles[vehicleId]
  if record and record.vehicle ~= vehicle then
    M.vehicleChanged(vehicleId)
    record = vehicles[vehicleId]
  end
  if not record then
    record = {vehicle = vehicle, holds = {}}
    vehicles[vehicleId] = record
  end
  local hold = {owner = owner, vehicleId = vehicleId, active = true, record = record,
    freezing = not options.deferred,
    remaining = not options.deferred and options.timeoutS or nil,
    onReleased = options.onReleased, surviveReset = options.surviveReset,
    instance = extensions and rawget(extensions, owner)}
  record.holds[hold] = true
  if hold.freezing and not record.frozen then
    record.frozen = true
    applyFreeze(vehicle, true)
  end
  hold.lifetime = lifecycle.track(owner, {'career', 'map', 'profile'}, {
    onEnded = function() finish(hold, 'lifetime ended') end,
  })
  function hold.release() return finish(hold, 'released') end
  function hold.isCurrent()
    if hold.active and findVehicle(vehicleId) ~= record.vehicle then M.vehicleChanged(vehicleId) end
    return hold.active
  end
  function hold.setTimeout(seconds)
    if hold.active then hold.remaining = seconds end
  end
  -- Queued operations bind their lifetime now and begin their physical hold only when ready.
  function hold.activate(activationOptions)
    if not hold.isCurrent() then return false end
    if hold.freezing then return true end
    activationOptions = activationOptions or {}
    hold.freezing = true
    hold.remaining = activationOptions.timeoutS
    hold.onReleased = activationOptions.onReleased
    if not record.frozen then
      record.frozen = true
      applyFreeze(record.vehicle, true)
    end
    return true
  end
  return hold
end

function M.releaseOwner(owner, vehicleId)
  local pending = {}
  for id, record in pairs(vehicles) do
    if not vehicleId or id == vehicleId then
      for hold in pairs(record.holds) do
        if hold.owner == owner then pending[#pending + 1] = hold end
      end
    end
  end
  for _, hold in ipairs(pending) do hold.release() end
end

-- Long-lived previews have one idempotent hold; asynchronous work uses acquire's distinct handles.
function M.set(owner, vehicleId, enabled, options)
  if not enabled then M.releaseOwner(owner, vehicleId); return end
  local record = vehicles[vehicleId]
  for hold in pairs(record and record.holds or {}) do
    if hold.owner == owner and hold.freezing and hold.isCurrent() then return hold end
  end
  return M.acquire(owner, vehicleId, options or {surviveReset = true})
end

function M.setVehicle(owner, vehicle, enabled, options)
  if not vehicle then return end
  local vehicleId = vehicle:getID()
  if not enabled and not vehicles[vehicleId] then return end
  if findVehicle(vehicleId) == vehicle then return M.set(owner, vehicleId, enabled, options) end
end

function M.vehicleChanged(vehicleId)
  local record = vehicles[vehicleId]
  if not record then return end
  vehicles[vehicleId] = nil
  -- Reset/replacement can reuse the scene object while an earlier freeze command is still queued.
  if record.frozen and findVehicle(vehicleId) == record.vehicle then applyFreeze(record.vehicle, false) end
  local pending = {}
  for hold in pairs(record.holds) do pending[#pending + 1] = hold end
  for _, hold in ipairs(pending) do finish(hold, 'vehicle changed', true) end
end

function M.vehicleReset(vehicleId)
  local record = vehicles[vehicleId]
  if not record then return end
  if findVehicle(vehicleId) ~= record.vehicle then M.vehicleChanged(vehicleId); return end
  local pending = {}
  for hold in pairs(record.holds) do
    if not hold.surviveReset then pending[#pending + 1] = hold end
  end
  for _, hold in ipairs(pending) do finish(hold, 'vehicle changed') end
  -- A preview is still open across a physics reset; its eventual handoff must retain a release handle.
  if vehicles[vehicleId] == record and record.frozen then applyFreeze(record.vehicle, true) end
end

function M.clear()
  local pending = {}
  for _, record in pairs(vehicles) do
    for hold in pairs(record.holds) do pending[#pending + 1] = hold end
  end
  for _, hold in ipairs(pending) do finish(hold, 'lifetime ended') end
end

-- Reused every frame so watching holds never allocates; counts mark the live part of each list.
local dueHolds, dueReasons, changedIds, changedRecords = {}, {}, {}, {}

function M.update(dtReal)
  if next(vehicles) == nil then return end
  local dueCount, changedCount = 0, 0
  for vehicleId, record in pairs(vehicles) do
    if findVehicle(vehicleId) ~= record.vehicle then
      changedCount = changedCount + 1
      changedIds[changedCount], changedRecords[changedCount] = vehicleId, record
    else
      for hold in pairs(record.holds) do
        local reason
        if hold.instance and rawget(extensions, hold.owner) ~= hold.instance then
          reason = 'owner unloaded'
        elseif hold.remaining then
          hold.remaining = hold.remaining - dtReal
          if hold.remaining <= 0 then reason = 'timed out' end
        end
        if reason then
          dueCount = dueCount + 1
          dueHolds[dueCount], dueReasons[dueCount] = hold, reason
        end
      end
    end
  end
  -- Completion callbacks can acquire another vehicle, so run them after scanning records.
  for index = 1, changedCount do
    local vehicleId, record = changedIds[index], changedRecords[index]
    changedIds[index], changedRecords[index] = nil, nil
    if vehicles[vehicleId] == record then M.vehicleChanged(vehicleId) end
  end
  for index = 1, dueCount do
    local hold, reason = dueHolds[index], dueReasons[index]
    dueHolds[index], dueReasons[index] = nil, nil
    finish(hold, reason)
  end
end

return M
