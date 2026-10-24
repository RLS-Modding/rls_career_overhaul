-- Auction lot vehicle control: freeze, drive locks, purchased-lot hand-off, and the callbacks that run
-- once the vehicle VM has disabled its AI (freeze hold, or transit to a drive start).
local vehicleCommands = require("overhaul/lib/vehicles/vehicleCommands")

local vehicleControl = {}

function vehicleControl.create(deps)
  local api = {}
  local auctionState = deps.auctionState
  local pendingFreezeTokens = deps.pendingFreezeTokens
  local pendingTransitCallbacks = deps.pendingTransitCallbacks
  local transitTokens = {}

  function api.cancelLotTransit(vehId)
    pendingTransitCallbacks[vehId] = nil
    transitTokens[vehId] = (transitTokens[vehId] or 0) + 1
    pendingFreezeTokens[vehId] = (pendingFreezeTokens[vehId] or 0) + 1
  end

  function api.setVehicleFreezeSafe(veh, shouldFreeze)
    if not veh then return end
    local freezeValue = shouldFreeze and true or false
    core_vehicleBridge.executeAction(veh, 'setFreeze', freezeValue)
  end

  local function getDefaultGearboxBehavior()
    local mode = settings and settings.getValue and settings.getValue('defaultGearboxBehavior')
    if mode == 'realistic' or mode == 'arcade' then
      return mode
    end
    return 'arcade'
  end

  function api.restorePlayerGearboxMode(veh)
    if not veh then return end
    -- AI can restore its own saved mode when disabled. Apply the player's
    -- default afterwards, in the same VM queue, including before storage.
    veh:queueLuaCommand(string.format([[
      if ai then ai.setMode("disabled") end
      if controller and controller.mainController then
        controller.mainController.setGearboxMode(%q)
      end
    ]], getDefaultGearboxBehavior()))
  end

  local function getLotByVehId(vehId)
    vehId = tonumber(vehId)
    if not vehId then return nil end
    for _, lot in ipairs(auctionState.lots or {}) do
      if tonumber(lot.vehId) == vehId then
        return lot
      end
    end
    return nil
  end

  function api.normalizePurchasedLotVehicleState(veh, lotIndex)
    if not veh then
      return false
    end

    deps.stopVehicleAI(veh)
    api.setVehicleFreezeSafe(veh, true)

    core_vehicleBridge.executeAction(veh, 'setIgnitionLevel', 0)
    core_vehicleBridge.executeAction(veh, 'setGearboxMode', getDefaultGearboxBehavior())

    veh:queueLuaCommand(string.format([[
    ai.setMode("disabled")
    if electrics then
      electrics.setIgnitionLevel(0)
      if electrics.setLightsState then electrics.setLightsState(0) end
      if electrics.set_warn_signal then electrics.set_warn_signal(0) end
      if electrics.horn then electrics.horn(false) end
      local turnsignal = (electrics.values and electrics.values.turnsignal) or 0
      if turnsignal > 0 and electrics.toggle_right_signal then electrics.toggle_right_signal() end
      if turnsignal < 0 and electrics.toggle_left_signal then electrics.toggle_left_signal() end
    end
    input.event("parkingbrake", 1, 1)
    obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(%d, 'auctionLotFinalized', %d))
  ]], require('overhaul/lib/vehicles/callbacks').open('auctionLotFinalized', {owner = 'usedCarAuction', vehId = veh:getID()}), lotIndex))

    return true
  end

  function api.setLotVehicleDriveLock(veh, mode)
    if not veh then return end

    -- Never allow driving auction lot vehicles while auction is active.
    veh.playerUsable = (mode == 'released')

    if mode == 'transit' then
      -- No unfreeze here: unfreezing while AI owns a plan fatals stock ai.lua:5635; queueSafeLotTransit goes first.
      core_vehicleBridge.executeAction(veh, 'setIgnitionLevel', 3)
      veh:queueLuaCommand([[
      if electrics and electrics.setIgnitionLevel then electrics.setIgnitionLevel(3) end
      input.event("throttle", 0, 1)
      input.event("brake", 0, 1)
      input.event("parkingbrake", 0, 1)
    ]])
      return
    end

    if mode == 'released' then
      api.cancelLotTransit(veh:getID())
      veh:queueLuaCommand('if overhaulDriver and overhaulDriver.cancelExactPathAssist then ' .. vehicleCommands.call("overhaulDriver", "cancelExactPathAssist") .. ' end')
      api.setVehicleFreezeSafe(veh, false)
      api.restorePlayerGearboxMode(veh)
      veh:queueLuaCommand('electrics.setIgnitionLevel(0)')
      -- Placement can reset inputs, so park the purchased car at the final handoff.
      veh:queueLuaCommand('input.event("parkingbrake", 1, 1)')
      return
    end

    -- 'bidding' and 'staged' disable AI on the vehicle VM (clearing its plan), then freeze.
    local vehId = veh:getID()
    local token = (pendingFreezeTokens[vehId] or 0) + 1
    pendingFreezeTokens[vehId] = token
    veh:queueLuaCommand(string.format([[
    if overhaulDriver and overhaulDriver.cancelExactPathAssist then ]] .. vehicleCommands.call("overhaulDriver", "cancelExactPathAssist") .. [[ end
    if ai then ai.setMode("disabled") end
    if electrics then
      electrics.setIgnitionLevel(0)
      if electrics.setLightsState then electrics.setLightsState(1) end
    end
    input.event("throttle", 0, 1)
    input.event("steering", 0, 1)
    if controller and controller.setFreeze then controller.setFreeze(1) end
    obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(%d, 'auctionFreezeReady', '%d, %d'))
  ]], require('overhaul/lib/vehicles/callbacks').open('auctionFreezeReady', {owner = 'usedCarAuction', vehId = vehId}), vehId, token))
  end

  -- Freeze only while the lot still holds: a stale callback must not freeze a driving car (fatal ai.lua:5635).
  function api.afterAiDisabledForFreeze(vehId, token)
    vehId = tonumber(vehId)
    token = tonumber(token)
    if not vehId then return end
    if token and pendingFreezeTokens[vehId] and token ~= pendingFreezeTokens[vehId] then
      return
    end

    local lot = getLotByVehId(vehId)
    local state = lot and lot.state
    if state == 'approaching' or state == 'exiting' then
      return
    end
    -- Hold only while queued on the pad or live on the block.
    if state ~= 'queued' and state ~= 'active' then
      return
    end

    local veh = getObjectByID(vehId)
    if veh then
      api.setVehicleFreezeSafe(veh, true)
      if lot and state == 'active' then lot.blockReady = true end
    end
  end

  -- After the VM disabled AI, finish the unfreeze and start the drive on the next beat (5635 otherwise).
  function api.afterAiDisabledForTransit(vehId)
    vehId = tonumber(vehId)
    local onReady = vehId and pendingTransitCallbacks[vehId] or nil
    local lot = vehId and getLotByVehId(vehId)
    local state = lot and lot.state
    local token = vehId and transitTokens[vehId]
    local function stillCurrent()
      return lot and getLotByVehId(vehId) == lot and lot.state == state
        and (state == 'approaching' or state == 'exiting')
        and auctionState.phase == 'bidding' and transitTokens[vehId] == token
    end
    if vehId then
      pendingTransitCallbacks[vehId] = nil
      pendingFreezeTokens[vehId] = (pendingFreezeTokens[vehId] or 0) + 1
    end
    local veh = vehId and getObjectByID(vehId)
    if not veh or not onReady or not stillCurrent() then
      return
    end

    api.setVehicleFreezeSafe(veh, false)
    api.setLotVehicleDriveLock(veh, 'transit')
    veh:queueLuaCommand([[
    if controller and controller.setFreeze then controller.setFreeze(0) end
    if overhaulDriver and overhaulDriver.cancelExactPathAssist then ]] .. vehicleCommands.call("overhaulDriver", "cancelExactPathAssist") .. [[ end
    if ai then ai.setMode("disabled") end
    if electrics and electrics.setIgnitionLevel then electrics.setIgnitionLevel(3) end
    input.event("throttle", 0, 1)
    input.event("brake", 0, 1)
    input.event("parkingbrake", 0, 1)
    input.event("steering", 0, 1)
  ]])

    if not onReady then
      return
    end

    core_jobsystem.create(function(job)
      job.sleep(0.2)
      local readyVeh = getObjectByID(vehId)
      if readyVeh and stillCurrent() then
        onReady(readyVeh)
      end
    end)
  end

  -- Disables AI to clear a hung plan, then unfreezes; the drive starts after a short delay.
  function api.queueSafeLotTransit(veh, onReady)
    if not veh then
      return false
    end
    local vehId = veh:getID()
    transitTokens[vehId] = (transitTokens[vehId] or 0) + 1
    -- Invalidate any pending bidding or staged freeze callback before the GE callback can land.
    pendingFreezeTokens[vehId] = (pendingFreezeTokens[vehId] or 0) + 1
    pendingTransitCallbacks[vehId] = onReady

    api.setVehicleFreezeSafe(veh, false)

    veh:queueLuaCommand(string.format([[
    if overhaulDriver and overhaulDriver.cancelExactPathAssist then ]] .. vehicleCommands.call("overhaulDriver", "cancelExactPathAssist") .. [[ end
    if ai then ai.setMode("disabled") end
    if controller and controller.setFreeze then controller.setFreeze(0) end
    if electrics and electrics.setIgnitionLevel then electrics.setIgnitionLevel(3) end
    input.event("throttle", 0, 1)
    input.event("brake", 0, 1)
    input.event("parkingbrake", 0, 1)
    obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(%d, 'auctionTransitReady', %d))
  ]], require('overhaul/lib/vehicles/callbacks').open('auctionTransitReady', {owner = 'usedCarAuction', vehId = vehId}), vehId))
    return true
  end

  return api
end

return vehicleControl
