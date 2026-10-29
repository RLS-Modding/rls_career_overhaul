-- Racer script geometry, driving parameters, freeze and delayed cleanup.
-- The racer load owns state; read geometry, parameter steps, cleanup, drive commands and the service factory.
local lib = {}

-- Sent as the AI, so a ride-along that admits only AI input still releases the team car.
local RELEASE_PARKING_BRAKE_AS_AI = "input.event('parkingbrake', 0, 1, nil, nil, nil, 'ai')"

function lib.create(ownerServices)
  local M = ownerServices.M
  local DEFAULT_CONFIG = ownerServices.DEFAULT_CONFIG
  local racerState = ownerServices.racerState

  -- Build script path: first point = vehicle position + dir + up (so game does not move the car). Then track points from nearest, close loop.
  local function nearestScriptPathNode(path, px, py, pz)
    local bestI, bestD = 1, 1e30
    for i, node in ipairs(path) do
      local dx = (node.x or 0) - px
      local dy = (node.y or 0) - py
      local dz = (node.z or 0) - pz
      local d = dx * dx + dy * dy + dz * dz
      if d < bestD then
        bestD, bestI = d, i
      end
    end
    return bestI
  end

  local function buildScriptPathNoTeleport(path, vpos, vdir, vup)
    if not path or #path == 0 or not vpos then return nil end
    local cfg = ownerServices.parts.config.getCurrentLevelConfig()
    local pathWidth = tonumber(cfg.scriptPathWidth) or DEFAULT_CONFIG.scriptPathWidth or 2.5
    local px, py, pz = vpos.x, vpos.y, vpos.z
    local bestI = nearestScriptPathNode(path, px, py, pz)
    local function addRadius(node)
      local n = type(node) == "table" and node or { x = 0, y = 0, z = 0 }
      if n.r == nil then n.r = pathWidth end
      return n
    end
    local out = {}
    -- First points are local bootstrap points so script mode keeps heading and avoids start-line snaps.
    local first = addRadius({ x = px, y = py, z = pz })
    local dirx, diry, dirz
    if vdir and (vdir.x or vdir.y or vdir.z) then
      dirx, diry, dirz = vdir.x or 0, vdir.y or 0, vdir.z or 0
      first.dir = { x = dirx, y = diry, z = dirz }
      first.up = vup and { x = vup.x or 0, y = vup.y or 0, z = vup.z or 0 } or nil
    end
    if not dirx then
      local nextNode = path[bestI] or path[1]
      local dx = (nextNode.x or px) - px
      local dy = (nextNode.y or py) - py
      local dz = (nextNode.z or pz) - pz
      local mag = math.sqrt(dx * dx + dy * dy + dz * dz)
      if mag > 0.001 then
        dirx, diry, dirz = dx / mag, dy / mag, dz / mag
        first.dir = { x = dirx, y = diry, z = dirz }
      end
    end
    table.insert(out, first)
    if dirx and diry and dirz then
      local bootstrap = math.max(1, tonumber(cfg.scriptBootstrapDistance) or DEFAULT_CONFIG.scriptBootstrapDistance)
      table.insert(
        out,
        addRadius({
          x = px + dirx * math.min(2.5, bootstrap * 0.5),
          y = py + diry * math.min(2.5, bootstrap * 0.5),
          z = pz + dirz * math.min(2.5, bootstrap * 0.5),
        })
      )
      table.insert(out, addRadius({ x = px + dirx * bootstrap, y = py + diry * bootstrap, z = pz + dirz * bootstrap }))
    end
    for i = bestI, #path do
      table.insert(out, addRadius(path[i]))
    end
    for i = 1, bestI - 1 do
      table.insert(out, addRadius(path[i]))
    end
    table.insert(out, out[1])
    return out
  end

  local function clamp(n, minValue, maxValue)
    if n < minValue then return minValue end
    if n > maxValue then return maxValue end
    return n
  end

  local function randomAggression(cfg, race)
    local minAgg = tonumber((race and race.aggressionMin) or cfg.aggressionMin) or DEFAULT_CONFIG.aggressionMin
    local maxAgg = tonumber((race and race.aggressionMax) or cfg.aggressionMax) or DEFAULT_CONFIG.aggressionMax
    if maxAgg < minAgg then maxAgg = minAgg end
    local raw = minAgg + math.random() * (maxAgg - minAgg)
    return clamp(raw, 0.2, 1.5)
  end

  local function makeBaseRacingParameters(config)
    local accelerationScale = tonumber(config.raceAccelScale)
    if accelerationScale == nil or accelerationScale <= 0 then accelerationScale = 1.1 end
    local throttleGain = tonumber(config.raceThrottleKp)
    if throttleGain == nil or throttleGain <= 0 then throttleGain = 1.12 end
    local throttleRateMultiplier = tonumber(config.raceThrottleRateMult)
    if throttleRateMultiplier == nil or throttleRateMultiplier <= 0 then throttleRateMultiplier = 4 end
    local throttleRecoveryMultiplier = tonumber(config.raceThrottleRecoveryMult)
    if throttleRecoveryMultiplier == nil or throttleRecoveryMultiplier <= 0 then throttleRecoveryMultiplier = 1.9 end
    local parameters = {
      raceAccelScale = accelerationScale,
      raceThrottleKp = throttleGain,
      raceThrottleRateMult = throttleRateMultiplier,
      raceThrottleRecoveryMult = throttleRecoveryMultiplier,
    }
    return parameters
  end

  local function applyWideLineParameters(config, parameters)
    local wideLineTrafficBlend = tonumber(config.raceWideLineTrafficBlend)
    if wideLineTrafficBlend == nil then wideLineTrafficBlend = tonumber(DEFAULT_CONFIG.raceWideLineTrafficBlend) or 0.4 end
    if wideLineTrafficBlend > 0 then
      parameters.raceWideLineTrafficBlend = wideLineTrafficBlend
      local lateralStartM = tonumber(config.raceWideLineLateralStartM)
      parameters.raceWideLineLateralStartM = (lateralStartM ~= nil and lateralStartM > 0) and lateralStartM
        or (tonumber(DEFAULT_CONFIG.raceWideLineLateralStartM) or 0.9)
      local lateralEndM = tonumber(config.raceWideLineLateralEndM)
      parameters.raceWideLineLateralEndM = (lateralEndM ~= nil and lateralEndM > 0) and lateralEndM
        or (tonumber(DEFAULT_CONFIG.raceWideLineLateralEndM) or 2.6)
    end
    local understeerRelax = tonumber(config.raceWideLineUndersteerRelax)
    if understeerRelax == nil then understeerRelax = tonumber(DEFAULT_CONFIG.raceWideLineUndersteerRelax) or 0.45 end
    if understeerRelax > 0 then
      parameters.raceWideLineUndersteerRelax = understeerRelax
      if not parameters.raceWideLineLateralStartM then
        parameters.raceWideLineLateralStartM = tonumber(config.raceWideLineLateralStartM)
          or tonumber(DEFAULT_CONFIG.raceWideLineLateralStartM)
          or 0.9
        parameters.raceWideLineLateralEndM = tonumber(config.raceWideLineLateralEndM)
          or tonumber(DEFAULT_CONFIG.raceWideLineLateralEndM)
          or 2.6
      end
    end
  end

  local function applyThrottleFloorParameters(config, parameters)
    local throttleFloor = tonumber(config.raceThrottleFloor)
    if throttleFloor ~= nil and throttleFloor > 0 and throttleFloor < 1 then
      parameters.raceThrottleFloor = throttleFloor
      local highSpeedThreshold = tonumber(config.raceHighSpeedThreshold)
      if highSpeedThreshold ~= nil and highSpeedThreshold > 0 then
        parameters.raceHighSpeedThreshold = highSpeedThreshold
        local highSpeedThrottleFloor = tonumber(config.raceHighSpeedThrottleFloor)
        if highSpeedThrottleFloor ~= nil and highSpeedThrottleFloor > 0 and highSpeedThrottleFloor < 1 then parameters.raceHighSpeedThrottleFloor = highSpeedThrottleFloor end
      end
    end
  end

  local function applyCornerLineParameters(config, parameters)
    local cornerLineLiftMaxM = tonumber(config.raceCornerLineLiftMaxM)
    if cornerLineLiftMaxM == nil then cornerLineLiftMaxM = tonumber(DEFAULT_CONFIG.raceCornerLineLiftMaxM) or 0.22 end
    if cornerLineLiftMaxM > 0 then
      parameters.raceCornerLineLiftMaxM = cornerLineLiftMaxM
      parameters.raceCornerCurvStart = tonumber(config.raceCornerCurvStart)
        or tonumber(DEFAULT_CONFIG.raceCornerCurvStart)
        or 0.022
      parameters.raceCornerCurvEnd = tonumber(config.raceCornerCurvEnd) or tonumber(DEFAULT_CONFIG.raceCornerCurvEnd) or 0.10
      local cornerLineLiftScale = tonumber(config.raceCornerLineLiftScale)
      if cornerLineLiftScale ~= nil then parameters.raceCornerLineLiftScale = cornerLineLiftScale end
    end
  end

  local function applyTrafficPassingParameters(config, parameters)
    local trafficPassBlend = tonumber(config.raceTrafficPassBlend)
    if trafficPassBlend == nil then trafficPassBlend = tonumber(DEFAULT_CONFIG.raceTrafficPassBlend) end
    if trafficPassBlend ~= nil then parameters.raceTrafficPassBlend = clamp(trafficPassBlend, 0, 0.88) end
    local clearanceScaleMin = tonumber(config.raceClearanceScaleMin)
    if clearanceScaleMin == nil then clearanceScaleMin = tonumber(DEFAULT_CONFIG.raceClearanceScaleMin) end
    if clearanceScaleMin ~= nil then parameters.raceClearanceScaleMin = clamp(clearanceScaleMin, 0.22, 0.95) end
  end

  local function applyAlternatePlanningParameters(config, parameters)
    local alternatePlanSpeedMargin = tonumber(config.raceAltPlanSpeedMargin)
    if alternatePlanSpeedMargin == nil then alternatePlanSpeedMargin = tonumber(DEFAULT_CONFIG.raceAltPlanSpeedMargin) end
    if alternatePlanSpeedMargin ~= nil and alternatePlanSpeedMargin > 0 then parameters.raceAltPlanSpeedMargin = alternatePlanSpeedMargin end
    local alternatePlanTimeMargin = tonumber(config.raceAltPlanTimeMargin)
    if alternatePlanTimeMargin == nil then alternatePlanTimeMargin = tonumber(DEFAULT_CONFIG.raceAltPlanTimeMargin) end
    if alternatePlanTimeMargin ~= nil and alternatePlanTimeMargin > 0 then parameters.raceAltPlanTimeMargin = alternatePlanTimeMargin end
    local awarenessCoefficientScale = tonumber(config.raceAwarenessCoefScale)
    if awarenessCoefficientScale == nil then awarenessCoefficientScale = tonumber(DEFAULT_CONFIG.raceAwarenessCoefScale) end
    if awarenessCoefficientScale ~= nil and awarenessCoefficientScale > 0 then parameters.raceAwarenessCoefScale = awarenessCoefficientScale end
  end

  local function applyBrakingGripParameters(config, parameters)
    local brakingDistance = tonumber(config.raceBlockedAheadDistMax)
    if brakingDistance == nil then brakingDistance = tonumber(DEFAULT_CONFIG.raceBlockedAheadDistMax) end
    if brakingDistance ~= nil and brakingDistance > 2 then parameters.raceBlockedAheadDistMax = brakingDistance end
    local clearancePassMinGainM = tonumber(config.raceClearancePassMinGainM)
    if clearancePassMinGainM == nil then clearancePassMinGainM = tonumber(DEFAULT_CONFIG.raceClearancePassMinGainM) end
    if clearancePassMinGainM ~= nil and clearancePassMinGainM >= 0 then parameters.raceClearancePassMinGainM = clearancePassMinGainM end
    local clearancePassTrafficEpsilon = tonumber(config.raceClearancePassTrafficEps)
    if clearancePassTrafficEpsilon == nil then clearancePassTrafficEpsilon = tonumber(DEFAULT_CONFIG.raceClearancePassTrafficEps) end
    if clearancePassTrafficEpsilon ~= nil and clearancePassTrafficEpsilon >= 0 then parameters.raceClearancePassTrafficEps = clearancePassTrafficEpsilon end
    local brakeGain = tonumber(config.raceBrakeGain)
    if brakeGain == nil then brakeGain = tonumber(DEFAULT_CONFIG.raceBrakeGain) end
    if brakeGain ~= nil then parameters.raceBrakeGain = clamp(brakeGain, 0.35, 1.25) end
    local cornerGripUtilization = tonumber(config.raceCornerGripUtil)
    if cornerGripUtilization == nil then cornerGripUtilization = tonumber(DEFAULT_CONFIG.raceCornerGripUtil) end
    if cornerGripUtilization ~= nil and cornerGripUtilization > 0 then parameters.raceCornerGripUtil = clamp(cornerGripUtilization, 1, 1.55) end
  end

  local function applyCornerCommitParameters(config, parameters)
    local cornerPlanBoost = tonumber(config.raceCornerPlanBoost)
    if cornerPlanBoost ~= nil and cornerPlanBoost > 0 then parameters.raceCornerPlanBoost = clamp(cornerPlanBoost, 1, 1.15) end
    if type(config.raceCommitCorners) == "boolean" then parameters.raceCommitCorners = config.raceCommitCorners end
    if config.raceCornerExitPush == false then parameters.raceCornerExitPush = false end
    local cornerExitPushMinGain = tonumber(config.raceCornerExitPushMinGain)
    if cornerExitPushMinGain ~= nil and cornerExitPushMinGain >= 0 then parameters.raceCornerExitPushMinGain = clamp(cornerExitPushMinGain, 0, 4) end
    local cornerExitPushOvershoot = tonumber(config.raceCornerExitPushOvershoot)
    if cornerExitPushOvershoot ~= nil and cornerExitPushOvershoot > 0 then parameters.raceCornerExitPushOvershoot = clamp(cornerExitPushOvershoot, 1, 1.08) end
    local cornerExitPushRiseRate = tonumber(config.raceCornerExitPushRiseRate)
    if cornerExitPushRiseRate ~= nil and cornerExitPushRiseRate > 0 then parameters.raceCornerExitPushRiseRate = clamp(cornerExitPushRiseRate, 4, 40) end
    local cornerExitPushSlipMax = tonumber(config.raceCornerExitPushSlipMax)
    if cornerExitPushSlipMax ~= nil and cornerExitPushSlipMax > 0 then parameters.raceCornerExitPushSlipMax = clamp(cornerExitPushSlipMax, 0.6, 1.2) end
    local understeerSlipMin = tonumber(config.raceUndersteerSlipMin)
    if understeerSlipMin ~= nil and understeerSlipMin > 0 then parameters.raceUndersteerSlipMin = clamp(understeerSlipMin, 0.5, 1.6) end
    local gripLiveRiseRate = tonumber(config.raceGripLiveRiseRate)
    if gripLiveRiseRate ~= nil and gripLiveRiseRate > 0 then parameters.raceGripLiveRiseRate = gripLiveRiseRate end
    local commitTargetOvershoot = tonumber(config.raceCommitTargetOvershoot)
    if commitTargetOvershoot ~= nil and commitTargetOvershoot > 0 then parameters.raceCommitTargetOvershoot = clamp(commitTargetOvershoot, 1, 1.2) end
    local commitSpeedFloorFraction = tonumber(config.raceCommitSpeedFloorPct)
    if commitSpeedFloorFraction ~= nil and commitSpeedFloorFraction > 0 then parameters.raceCommitSpeedFloorPct = clamp(commitSpeedFloorFraction, 0.9, 1) end
    local slipTarget = tonumber(config.raceSlipTarget)
    if slipTarget ~= nil and slipTarget > 0 then parameters.raceSlipTarget = clamp(slipTarget, 0.9, 1.4) end
    local slipGain = tonumber(config.raceSlipGain)
    if slipGain ~= nil and slipGain > 0 then parameters.raceSlipGain = clamp(slipGain, 0.1, 0.6) end
    local frictionMultiplier = tonumber(config.raceFrictionMult)
    if frictionMultiplier ~= nil and frictionMultiplier > 0 then parameters.raceFrictionMult = clamp(frictionMultiplier, 1, 1.15) end
  end

  local function getRacingParameters(config, race)
    if not config or config.useRacingParameters == false then return {} end
    local parameters = makeBaseRacingParameters(config)
    applyWideLineParameters(config, parameters)
    applyThrottleFloorParameters(config, parameters)
    applyCornerLineParameters(config, parameters)
    applyTrafficPassingParameters(config, parameters)
    applyAlternatePlanningParameters(config, parameters)
    applyBrakingGripParameters(config, parameters)
    applyCornerCommitParameters(config, parameters)
    return parameters
  end

  -- Freeze or unfreeze the player vehicle (e.g. during countdown until GO, same moment as AI release). Uses same pattern as bus.lua.
  function M.setPlayerFreeze(freeze)
    if not core_vehicleBridge or not core_vehicleBridge.executeAction then return end
    local veh = be:getPlayerVehicle(0)
    if veh then core_vehicleBridge.executeAction(veh, "setFreeze", freeze and true or false) end
  end

  local function getObjectSpeedMps(vehId)
    if not vehId then return 0 end
    local v, vy, vz = be:getObjectVelocityXYZ(vehId)
    if type(v) == "number" then
      vy, vz = tonumber(vy) or 0, tonumber(vz) or 0
      return math.sqrt(v * v + vy * vy + vz * vz)
    end
    if type(v) == "table" then
      local x = v.x or v[1] or 0
      local y = v.y or v[2] or 0
      local z = v.z or v[3] or 0
      return math.sqrt(x * x + y * y + z * z)
    end
    return 0
  end

  local function isUpsideDown(vehObj)
    if not vehObj or not vehObj.getDirectionVectorUp then return false end
    local up = vehObj:getDirectionVectorUp()
    if not up then return false end
    local upZ = up.z or up[3] or 0
    return upZ < 0
  end

  local function resetDelayedDespawnState()
    racerState.mDelayedDespawnActive = false
    racerState.mDelayedDespawnWaiting = false
    racerState.mDelayedDespawnTimer = 0
    racerState.mDelayedDespawnStaggerSeconds = 4.0
  end

  racerState.cancelDelayedDespawn = function()
    if not racerState.mDelayedDespawnActive then return end
    resetDelayedDespawnState()
  end

  racerState.queueEngineStart = function(vehObj)
    if not vehObj then return end
    -- One-shot ignition command to avoid visible restart cycling.
    if core_vehicleBridge and core_vehicleBridge.executeAction then
      pcall(function()
        core_vehicleBridge.executeAction(vehObj, "setIgnitionLevel", 3)
      end)
    end
    vehObj:queueLuaCommand("if electrics and electrics.setIgnitionLevel then electrics.setIgnitionLevel(3) end")
  end

  local function despawnSingleVehicle()
    local vehId = racerState.mSpawnedAiVehicleIds[1]
    if not vehId then return false end
    local obj = be:getObjectByID(vehId)
    if obj then
      if racerState.mDnfCallback then pcall(racerState.mDnfCallback, vehId) end
      obj:delete()
      table.remove(racerState.mSpawnedAiVehicleIds, 1)
      racerState.mEverSpawnedAiVehicleIdsSweep[vehId] = nil
      racerState.mRecoveryStateByVehId[vehId] = nil
      racerState.mRetiredUpsideDownByVehId[vehId] = nil
      racerState.mVehicleLaneIndexByVehId[vehId] = nil
      racerState.mNavStateByVehId[vehId] = nil
      return true
    end
    -- Transient nil object: drop this slot anyway so the delayed-despawn job can progress, but preserve
    -- the sweep-set entry so clearSpawned() will retry deletion if the vehicle resurfaces.
    log(
      "W",
      "aiRacers",
      string.format(
        "despawnSingleVehicle: deleting bookkeeping for vehId %s (getObjectByID returned nil); sweep set retains entry",
        tostring(vehId)
      )
    )
    table.remove(racerState.mSpawnedAiVehicleIds, 1)
    racerState.mRecoveryStateByVehId[vehId] = nil
    racerState.mRetiredUpsideDownByVehId[vehId] = nil
    racerState.mVehicleLaneIndexByVehId[vehId] = nil
    racerState.mNavStateByVehId[vehId] = nil
    return true
  end

  local function updateDelayedDespawn(step)
    if not racerState.mDelayedDespawnActive then return false end
    if #racerState.mSpawnedAiVehicleIds == 0 then
      resetDelayedDespawnState()
      racerState.mRecoveryMonitorEnabled = false
      return true
    end
    racerState.mDelayedDespawnTimer = (racerState.mDelayedDespawnTimer or 0) - step
    if racerState.mDelayedDespawnTimer > 0 then return true end
    if racerState.mDelayedDespawnWaiting then
      racerState.mDelayedDespawnWaiting = false
      racerState.mDelayedDespawnTimer = racerState.mDelayedDespawnStaggerSeconds
      return true
    end
    despawnSingleVehicle()
    if #racerState.mSpawnedAiVehicleIds == 0 then
      resetDelayedDespawnState()
      racerState.mRecoveryMonitorEnabled = false
      racerState.mRecoveryStateByVehId = {}
      racerState.mRetiredUpsideDownByVehId = {}
      racerState.mVehicleLaneIndexByVehId = {}
      racerState.mNavStateByVehId = {}
      racerState.mActiveRaceForRecovery = nil
      racerState.mActiveLapCountForRecovery = 1
    else
      racerState.mDelayedDespawnTimer = racerState.mDelayedDespawnStaggerSeconds
    end
    return true
  end

  local function despawnAiVehiclesById(toDespawn)
    if type(toDespawn) ~= "table" or next(toDespawn) == nil then return end
    for i = #racerState.mSpawnedAiVehicleIds, 1, -1 do
      local vehId = racerState.mSpawnedAiVehicleIds[i]
      if toDespawn[vehId] then
        local obj = be:getObjectByID(vehId)
        if obj then
          -- Resolvable — fire DNF and fully despawn, dropping all bookkeeping.
          if racerState.mDnfCallback then pcall(racerState.mDnfCallback, vehId) end
          obj:delete()
          table.remove(racerState.mSpawnedAiVehicleIds, i)
          racerState.mEverSpawnedAiVehicleIdsSweep[vehId] = nil
          racerState.mRecoveryStateByVehId[vehId] = nil
          racerState.mRetiredUpsideDownByVehId[vehId] = nil
          racerState.mVehicleLaneIndexByVehId[vehId] = nil
          racerState.mNavStateByVehId[vehId] = nil
        else
          -- Keep missing ids for the next recovery tick; teardown catches those that never reappear.
          log(
            "W",
            "aiRacers",
            string.format(
              "despawnAiVehiclesById: deferring delete for vehId %s (getObjectByID returned nil)",
              tostring(vehId)
            )
          )
        end
      end
    end
  end

  local function buildNavWpTargetListFromPath(path)
    if not path or #path < 2 then return nil end
    local wpTargetList = {}
    local seenConsecutive = nil
    -- Denser path (was 50) so AI follows track smoothly and does not cut between sparse waypoints.
    local step = math.max(1, math.floor(#path / 120))
    for i = 1, #path, step do
      local node = path[i]
      if node and node.x and node.y and node.z then
        local _, nodeIdx = map.findClosestRoad(vec3(node.x, node.y, node.z))
        if nodeIdx and nodeIdx ~= seenConsecutive then
          table.insert(wpTargetList, nodeIdx)
          seenConsecutive = nodeIdx
        end
      end
    end
    local lastNode = path[#path]
    if lastNode and lastNode.x and lastNode.y and lastNode.z then
      local _, lastNodeIdx = map.findClosestRoad(vec3(lastNode.x, lastNode.y, lastNode.z))
      if lastNodeIdx and lastNodeIdx ~= seenConsecutive then table.insert(wpTargetList, lastNodeIdx) end
    end
    if #wpTargetList < 2 then return nil end
    return wpTargetList
  end

  local function getMapNodePos(mapData, nodeId)
    if not mapData or not mapData.nodes then return nil end
    local n = mapData.nodes[nodeId]
    if not n or not n.pos then return nil end
    return vec3(n.pos)
  end

  local function nearestVehicleWaypointIndex(mapData, wpTargetList, vpos)
    local nearestIdx, nearestDist = 1, math.huge
    for i, nodeId in ipairs(wpTargetList) do
      local npos = getMapNodePos(mapData, nodeId)
      if npos then
        local dx = (npos.x or 0) - (vpos.x or 0)
        local dy = (npos.y or 0) - (vpos.y or 0)
        local dz = (npos.z or 0) - (vpos.z or 0)
        local d = dx * dx + dy * dy + dz * dz
        if d < nearestDist then
          nearestDist = d
          nearestIdx = i
        end
      end
    end

    return nearestIdx
  end

  local function orientWpTargetListForVehicle(wpTargetList, vehObj)
    if not wpTargetList or #wpTargetList < 2 or not vehObj then return wpTargetList end
    local mapData = map.getMap()
    if not mapData or not mapData.nodes then return wpTargetList end
    local vpos = vehObj:getPosition()
    if not vpos then return wpTargetList end

    local nearestIdx = nearestVehicleWaypointIndex(mapData, wpTargetList, vpos)

    local rotated = {}
    for i = nearestIdx, #wpTargetList do
      rotated[#rotated + 1] = wpTargetList[i]
    end
    for i = 1, nearestIdx - 1 do
      rotated[#rotated + 1] = wpTargetList[i]
    end

    local vdir = vehObj.getDirectionVector and vehObj:getDirectionVector() or nil
    if vdir and #rotated >= 3 then
      local p0 = getMapNodePos(mapData, rotated[1])
      local pNext = getMapNodePos(mapData, rotated[2])
      local pPrev = getMapNodePos(mapData, rotated[#rotated])
      if p0 and pNext and pPrev then
        local toNext = pNext - p0
        local toPrev = pPrev - p0
        local nextLen = toNext:length()
        local prevLen = toPrev:length()
        if nextLen > 0.001 and prevLen > 0.001 then
          toNext = toNext / nextLen
          toPrev = toPrev / prevLen
          local dotNext = (vdir.x or 0) * (toNext.x or 0)
            + (vdir.y or 0) * (toNext.y or 0)
            + (vdir.z or 0) * (toNext.z or 0)
          local dotPrev = (vdir.x or 0) * (toPrev.x or 0)
            + (vdir.y or 0) * (toPrev.y or 0)
            + (vdir.z or 0) * (toPrev.z or 0)
          if dotNext < dotPrev then
            local reversed = { rotated[1] }
            for i = #rotated, 2, -1 do
              reversed[#reversed + 1] = rotated[i]
            end
            rotated = reversed
          end
        end
      end
    end

    return rotated
  end

  local function queueNavDriveForVehicle(vehObj, path, noOfLaps, cfg, race)
    if not vehObj or not path or #path < 2 then return false end
    local wpTargetList = buildNavWpTargetListFromPath(path)
    if not wpTargetList or #wpTargetList < 2 then return false end
    wpTargetList = orientWpTargetListForVehicle(wpTargetList, vehObj)
    if not wpTargetList or #wpTargetList < 2 then return false end
    if wpTargetList[#wpTargetList] ~= wpTargetList[1] then wpTargetList[#wpTargetList + 1] = wpTargetList[1] end
    local wpTargetListStr = serialize(wpTargetList)
    -- Full aggression: state-based speed (no route speed limit). Rubberband later by player XP.
    local aggression = 1.0
    local driveInLane = tostring(cfg.driveInLane or DEFAULT_CONFIG.driveInLane)
    local avoidCars = tostring(cfg.avoidCars or DEFAULT_CONFIG.avoidCars)
    local targetSpeedSmootherRate = tonumber(cfg.targetSpeedSmootherRate)
      or DEFAULT_CONFIG.targetSpeedSmootherRate
      or 18
    vehObj:queueLuaCommand(RELEASE_PARKING_BRAKE_AS_AI)

    vehObj:queueLuaCommand("ai.setAggression(" .. tostring(aggression) .. ")")
    vehObj:queueLuaCommand("ai.setRacing(true)")
    vehObj:queueLuaCommand('ai.setAvoidCars("' .. avoidCars .. '")')

    vehObj:queueLuaCommand([[
          local wpTargetList = ]] .. wpTargetListStr .. [[
          local noOfLaps = ]] .. tostring(noOfLaps) .. [[
          if wpTargetList and #wpTargetList > 1 and ai and ai.driveUsingPath then
              ai.driveUsingPath({
                  wpTargetList = wpTargetList,
                  avoidCars = ']] .. avoidCars .. [[',
                  driveInLane = ']] .. driveInLane .. [[',
                  aggression = ]] .. tostring(aggression) .. [[,
                  noOfLaps = noOfLaps,
                  targetSpeedSmootherRate = ]] .. tostring(targetSpeedSmootherRate) .. [[
              })
          end
      ]])
    -- driveUsingPath resets AI parameters; apply race tuning afterward.
    if cfg.useRacingParameters ~= false and DEFAULT_CONFIG.useRacingParameters ~= false then
      vehObj:queueLuaCommand("ai.setParameters(" .. serialize(getRacingParameters(cfg, race)) .. ")")
    end
    return true
  end

  local function queueRacingScript(vehObj, pathStr, noOfLaps, racingParameters, avoidCars, driveInLane, aggression, targetSpeedSmootherRate)
    vehObj:queueLuaCommand([[
          local path = ]] .. pathStr .. [[
          local noOfLaps = ]] .. tostring(noOfLaps) .. [[
          if path and #path > 0 and ai and ai.driveUsingPath then
              ai.driveUsingPath({
                  script = path,
                  racingParameters = ]] .. serialize(racingParameters) .. [[,
                  avoidCars = ']] .. avoidCars .. [[',
                  driveInLane = ']] .. driveInLane .. [[',
                  aggression = ]] .. tostring(aggression) .. [[,
                  noOfLaps = noOfLaps,
                  targetSpeedSmootherRate = ]] .. tostring(targetSpeedSmootherRate) .. [[
              })
          end
      ]])
  end

  local function queueDriveForVehicle(vehObj, race, noOfLaps, cfg, laneIndex)
    if not vehObj or not race then return end
    local pathKey = ownerServices.parts.config.getRacePathKey(race)
    if not pathKey then return end
    if
      type(laneIndex) == "number"
      and race.checkpointRoadLanes
      and type(race.checkpointRoadLanes) == "table"
      and #race.checkpointRoadLanes > 0
    then
      pathKey = pathKey .. "_lane_" .. tostring(laneIndex)
    end
    local path = ownerServices.mPathCache[pathKey]
    if not path or #path == 0 then
      M.preloadPathForRace(race)
      path = ownerServices.mPathCache[pathKey]
    end
    if not path or #path == 0 then return end

    if cfg.useNavgraphPathfinding ~= false then
      if queueNavDriveForVehicle(vehObj, path, noOfLaps, cfg, race) then return end
    end

    local vpos = vehObj:getPosition()
    local vdir, vup
    if vehObj.getDirectionVector and vehObj.getDirectionVectorUp then
      vdir = vehObj:getDirectionVector()
      vup = vehObj:getDirectionVectorUp()
    end
    local scriptPath = buildScriptPathNoTeleport(path, vpos, vdir, vup)
    if not scriptPath or #scriptPath < 2 then return end

    local pathStr = serialize(scriptPath)
    local racingParameters = cfg.useRacingParameters ~= false
        and DEFAULT_CONFIG.useRacingParameters ~= false
        and getRacingParameters(cfg, race)
      or nil
    -- Full aggression: state-based speed (no route speed limit). Rubberband later by player XP.
    local aggression = 1.0
    local driveInLane = tostring(cfg.driveInLane or DEFAULT_CONFIG.driveInLane)
    local avoidCars = tostring(cfg.avoidCars or DEFAULT_CONFIG.avoidCars)
    local targetSpeedSmootherRate = tonumber(cfg.targetSpeedSmootherRate)
      or DEFAULT_CONFIG.targetSpeedSmootherRate
      or 18
    vehObj:queueLuaCommand(RELEASE_PARKING_BRAKE_AS_AI)

    vehObj:queueLuaCommand("ai.setAggression(" .. tostring(aggression) .. ")")
    vehObj:queueLuaCommand("ai.setRacing(true)")
    vehObj:queueLuaCommand('ai.setAvoidCars("' .. avoidCars .. '")')

    queueRacingScript(vehObj, pathStr, noOfLaps, racingParameters, avoidCars, driveInLane, aggression,
      targetSpeedSmootherRate)
  end

  -- Call at countdown GO: release spawned AI for this race using script path. When race has checkpointRoadLanes, each AI gets a lane path by spawn index (laneIndex = (i-1) % numLanes).
  -- Player stays frozen and is unfrozen 0.5s after AI go to account for AI reaction time (slightly behind).
  function M.releaseAndDrive(race, lapCount)
    if not race then return end
    local cfg = ownerServices.parts.config.getMergedConfigForRace(race)
    if cfg.enabled == false then
      M.setPlayerFreeze(false)
      return
    end
    racerState.cancelDelayedDespawn()
    M.preloadPathForRace(race)
    local pathKey = ownerServices.parts.config.getRacePathKey(race)
    if not pathKey then
      M.setPlayerFreeze(false)
      return
    end
    local numLanes = (race.checkpointRoadLanes and type(race.checkpointRoadLanes) == "table")
        and #race.checkpointRoadLanes
      or 0
    -- Use a high lap count so AI keep lapping after race distance; leaderboard still uses required laps from triggers.
    local requiredLaps = (type(lapCount) == "number" and lapCount > 0) and lapCount or 1
    local noOfLaps = math.max(requiredLaps, 99)
    racerState.mActiveRaceForRecovery = race
    racerState.mActiveLapCountForRecovery = requiredLaps
    racerState.mRecoveryMonitorEnabled = true
    racerState.mRecoveryCheckAccumulator = 0
    racerState.mRecoveryGraceTimer =
      math.max(0, tonumber(cfg.launchRecoveryGraceSeconds) or DEFAULT_CONFIG.launchRecoveryGraceSeconds)
    for i, vehId in ipairs(racerState.mSpawnedAiVehicleIds) do
      local vehObj = be:getObjectByID(vehId)
      if vehObj then
        if cfg.startEngineOnSpawn ~= false then racerState.queueEngineStart(vehObj) end
        local laneIndex = (numLanes > 0) and ((i - 1) % numLanes) or nil
        racerState.mVehicleLaneIndexByVehId[vehId] = laneIndex
        queueDriveForVehicle(vehObj, race, noOfLaps, cfg, laneIndex)
      end
    end
    local proxyRide = overhaul_events_competitiveTrackFlow
      and overhaul_events_competitiveTrackFlow.isRacingTeamProxyRaceSessionActive
      and overhaul_events_competitiveTrackFlow.isRacingTeamProxyRaceSessionActive()
    if not proxyRide then
      racerState.mPlayerUnfreezeAt = os.clock() + 0.5
      M.setPlayerFreeze(true)
    end
  end

  --- Same path and AI as grid rivals, for the player vehicle during racing-team ride-along (input locked separately).
  --- driveOpts.useScriptPath skips navgraph (player grid orientation is unreliable with map-node rotation).
  function M.driveVehicleOnRacePath(vehId, race, lapCount, laneIndex, driveOpts)
    if not vehId or not race then return end
    local mergedCfg = ownerServices.parts.config.getMergedConfigForRace(race)
    if not mergedCfg or mergedCfg.enabled == false then return end
    local cfg = mergedCfg
    if type(driveOpts) == "table" and driveOpts.useScriptPath == true then
      cfg = {}
      for k, v in pairs(mergedCfg) do
        cfg[k] = v
      end
      cfg.useNavgraphPathfinding = false
    end
    M.preloadPathForRace(race)
    local requiredLaps = (type(lapCount) == "number" and lapCount > 0) and lapCount or 1
    local noOfLaps = math.max(requiredLaps, 99)
    local vehObj = be:getObjectByID(vehId)
    if not vehObj then return end
    -- Grid staging already gave the team car its rivals' AI (prepareTeamCarOnGrid); this covers a
    -- start that skipped staging. The race now owns the car, so a staging abort must not release it.
    if overhaul_shell_extensionManager and overhaul_shell_extensionManager.applyOverrideAI then
      overhaul_shell_extensionManager.applyOverrideAI(vehId)
    end
    racerState.mGridTeamCarVehId = nil
    if cfg.startEngineOnSpawn ~= false then racerState.queueEngineStart(vehObj) end
    racerState.mVehicleLaneIndexByVehId[vehId] = laneIndex
    queueDriveForVehicle(vehObj, race, noOfLaps, cfg, laneIndex)
  end

  return {
    getObjectSpeedMps = getObjectSpeedMps,
    isUpsideDown = isUpsideDown,
    resetDelayedDespawnState = resetDelayedDespawnState,
    updateDelayedDespawn = updateDelayedDespawn,
    despawnAiVehiclesById = despawnAiVehiclesById,
    queueDriveForVehicle = queueDriveForVehicle,
  }
end

return lib
