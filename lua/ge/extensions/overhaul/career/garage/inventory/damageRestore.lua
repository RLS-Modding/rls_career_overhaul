-- Damage and actuator pose follow final placement; unloading, restoration and settling release readiness.
-- Map: attempt validity, queued restoration, spawn registration, caller placement signals.
local M = {}
local vehicleCommands = require('overhaul/lib/vehicles/vehicleCommands')
local SETTLE_SECONDS = 0.25
local WAIT_INTERVAL_SECONDS = 0.05
local WAIT_ATTEMPTS = 200
local MECHANISM_WAIT_ATTEMPTS = 900

function M.new(inputs)
  local attempts = inputs.pendingDamageRestore
  local owner = {}
  local run
  local pauseSequence = 0

  -- The global lookup can retain a miss across a vehicle replacement's registration gap.
  local function vehicleObject(vehId)
    if be and be.getObjectByID then return be:getObjectByID(vehId) end
    return getObjectByID(vehId)
  end

  local function valid(attempt)
    local id = attempt.inventoryId
    local tracked = inputs.readiness.get(id)
    return attempts[id] == attempt and inputs.inventoryIdToVehId[id] == attempt.vehId
      and vehicleObject(attempt.vehId) and tracked and not tracked.closed
      and (not inputs.M or overhaul_career_garage_inventory == inputs.M)
  end

  local function finished(attempt, version, mechanismFailed)
    if not valid(attempt) or attempt.version ~= version or attempt.held then return end
    attempt.restored = true
    attempts[attempt.inventoryId] = nil
    attempt.markReady('damageRestored', mechanismFailed and 'mechanismFailed' or (attempt.damaged and 'restored' or 'posed'))
  end

  local function waitForMechanisms(attempt, version, job)
    local reply, waiting
    local checks = 0
    while checks < MECHANISM_WAIT_ATTEMPTS do
      if not valid(attempt) or attempt.version ~= version or attempt.held then return nil end
      local paused = simTimeAuthority and simTimeAuthority.getPause and simTimeAuthority.getPause() == true
      if not paused then
        checks = checks + 1
        if not waiting then
          waiting = true
          core_vehicleBridge.requestValue(vehicleObject(attempt.vehId), function(response)
            reply = response and (response.result or (response.failReason and {complete=true,failed=true}))
            waiting = false
          end, 'getOverhaulMechanismRestoreState')
        end
        job.sleep(WAIT_INTERVAL_SECONDS)
        if reply and reply.complete then return not reply.failed end
      else
        job.sleep(WAIT_INTERVAL_SECONDS)
      end
    end
    vehicleObject(attempt.vehId):queueLuaCommand(vehicleCommands.call('overhaulDamageState','cancelMechanismRestore'))
    log('W', 'inventory', 'Vehicle actuators did not reach their restored targets: ' .. attempt.inventoryId)
    return false
  end

  local function restore(attempt, acknowledge)
    local vehicle = vehicleObject(attempt.vehId)
    -- Changing node positions under momentum can yield an otherwise healthy frame.
    if vehicle.applyClusterVelocityScaleAdd then
      vehicle:applyClusterVelocityScaleAdd(-1, 0, 0, 0, 0)
    end
    if attempt.damaged then overhaul_career_repair_damageManager.loadDamageState(attempt.inventoryId) end
    if attempt.pose then
      vehicle:queueLuaCommand("extensions.load('overhaulDamageState'); "
        .. vehicleCommands.call('overhaulDamageState','restoreMechanismState',attempt.pose))
    end
    core_vehicleBridge.requestValue(vehicle, acknowledge, 'ping')
  end

  local function restoreAtRest(attempt, version, job)
    -- A session capture is authoritative even before its file exists. Keep save protection
    -- until that reply lands; a pristine replacement must never supersede the outgoing shape.
    local manager = overhaul_career_repair_damageManager
    local function capturePending()
      return manager.isDamageCapturePending and manager.isDamageCapturePending(attempt.inventoryId)
    end
    for _ = 1, WAIT_ATTEMPTS do
      if not valid(attempt) or attempt.version ~= version or attempt.held then return end
      if not capturePending() then break end
      job.sleep(WAIT_INTERVAL_SECONDS)
    end
    if capturePending() then return end
    pauseSequence = pauseSequence + 1
    local pauseId = 'inventoryRestore:' .. tostring(owner) .. ':' .. pauseSequence
    local paused = simTimeAuthority and simTimeAuthority.pushPauseRequest and simTimeAuthority.popPauseRequest
    local function release()
      if not paused then return end
      paused = false
      simTimeAuthority.popPauseRequest(pauseId)
    end
    if paused then simTimeAuthority.pushPauseRequest(pauseId) end
    if job.setExitCallback then job.setExitCallback(release) end
    local acknowledged = false
    local ok, err = pcall(restore, attempt, function() acknowledged = true end)
    for _ = 1, WAIT_ATTEMPTS do
      if not ok or acknowledged or not valid(attempt) or attempt.version ~= version then break end
      job.sleep(WAIT_INTERVAL_SECONDS)
    end
    release()
    if not ok then log('E', 'inventory', 'Vehicle restoration failed: ' .. tostring(err)); return end
    if not acknowledged or not valid(attempt) or attempt.version ~= version or attempt.held then return end
    local reached = waitForMechanisms(attempt, version, job)
    if reached == nil then return end
    -- A carried load must wait for the unloaded support to settle after the pose changes.
    local settled = 0
    local function physicsPaused()
      return simTimeAuthority and simTimeAuthority.getPause and simTimeAuthority.getPause() == true
    end
    while settled < SETTLE_SECONDS do
      if not valid(attempt) or attempt.version ~= version or attempt.held then return end
      local running = not physicsPaused()
      job.sleep(WAIT_INTERVAL_SECONDS)
      if running and not physicsPaused() then settled = settled + WAIT_INTERVAL_SECONDS end
    end
    finished(attempt, version, not reached)
  end

  run = function(attempt)
    if attempt.running then return end
    attempt.running = true
    core_jobsystem.create(function(job)
      local restoreQueued = false
      for _ = 1, WAIT_ATTEMPTS do
        if not valid(attempt) then break end
        while simTimeAuthority and simTimeAuthority.getPause and simTimeAuthority.getPause() == true do
          if not valid(attempt) then break end
          job.sleep(WAIT_INTERVAL_SECONDS)
        end
        if not valid(attempt) then break end
        local ready = inputs.readiness.get(attempt.inventoryId).states.veAcknowledged
        if not attempt.held and ready then
          local version = attempt.version
          job.sleep(SETTLE_SECONDS)
          if not valid(attempt) then break end
          if not attempt.held and attempt.version == version then
            restoreAtRest(attempt, version, job)
            -- A caller can finish another reset while the old vehicle reply is in flight.
            restoreQueued = attempt.version == version
            break
          end
        end
        job.sleep(WAIT_INTERVAL_SECONDS)
      end
      attempt.running = false
      if not valid(attempt) and attempts[attempt.inventoryId] == attempt then attempts[attempt.inventoryId] = nil end
      if not restoreQueued and valid(attempt) and not attempt.held
          and inputs.readiness.get(attempt.inventoryId).states.veAcknowledged then run(attempt) end
    end)
  end

  function owner.begin(inventoryId, vehicle, markReady, damaged, held, waitForBinding, pose)
    local attempt = {inventoryId=inventoryId, vehId=vehicle:getID(), markReady=markReady,
      damaged=damaged, pose=pose, held=held == true, version=0, placed=not held}
    attempts[inventoryId] = attempt
    if not held and not inputs.readiness.get(inventoryId).states.placed then markReady('placed') end
    if not damaged then
      overhaul_career_repair_damageManager.clearDamageState(inventoryId)
      if not pose then
        markReady('damageRestored', 'cleared')
        if not held then attempts[inventoryId] = nil end
        return
      end
    end
    if not waitForBinding then run(attempt) end
  end

  function owner.start(inventoryId)
    local attempt = attempts[inventoryId]
    if attempt then run(attempt) end
  end

  function owner.defer(inventoryId, vehId)
    local attempt = attempts[inventoryId]
    local record = inputs.vehicles and inputs.vehicles[inventoryId]
    local damaged = overhaul_career_repair_damageManager.hasDamageState
      and overhaul_career_repair_damageManager.hasDamageState(inventoryId)
    local pose = not damaged and record and record.mechanismState
    if not attempt and inputs.inventoryIdToVehId[inventoryId] == vehId
        and (damaged or pose) then
      local previous = inputs.readiness.get(inventoryId)
      if not previous or previous.closed then return false end
      local markReady = inputs.readiness.begin(inventoryId, vehId)
      for name, value in pairs(previous.states) do
        if name ~= 'placed' and name ~= 'damageRestored' then markReady(name, value) end
      end
      owner.begin(inventoryId, vehicleObject(vehId), markReady, damaged, true, nil, pose)
      attempt = attempts[inventoryId]
    end
    if not attempt or attempt.vehId ~= vehId then return false end
    attempt.held, attempt.version = true, attempt.version + 1
    return true
  end

  function owner.complete(inventoryId, vehId)
    local attempt = attempts[inventoryId]
    if not attempt or attempt.vehId ~= vehId then return false end
    attempt.held = false
    if not attempt.placed then attempt.placed = true; attempt.markReady('placed') end
    if not attempt.damaged and not attempt.pose then attempts[inventoryId] = nil; return true end
    run(attempt)
    return true
  end

  -- A delayed setup reply can restart a bounded wait without releasing a caller's placement hold.
  function owner.setupReady(inventoryId, vehId)
    local attempt = attempts[inventoryId]
    if attempt and attempt.vehId == vehId and not attempt.held then run(attempt) end
  end

  function owner.isPending(inventoryId)
    local attempt = attempts[inventoryId]
    return attempt ~= nil and (attempt.damaged or attempt.pose ~= nil) and not attempt.restored
  end

  return owner
end

return M
