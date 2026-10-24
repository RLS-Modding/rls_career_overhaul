-- Derby vehicle placement, stop/freeze commands, AI spawning and chase targets.
-- The derby load owns state; read vehicle primitives, spawn/cleanup, chase control and the service factory.
local vehicleCommands = require("overhaul/lib/vehicles/vehicleCommands")
local eventConfig = require("overhaul/events/derby/config")
local lib = {}

function lib.create(ownerServices)
  local DEFAULT_AI_PERSONALITIES = ownerServices.DEFAULT_AI_PERSONALITIES
  local derbyState = ownerServices.derbyState

  local function teleportVehicleSafe(veh, pos, rot)
    if not veh or not pos or not rot then return false end
    if spawn and spawn.safeTeleport then
      spawn.safeTeleport(veh, pos, rot, nil, nil, nil, nil, false)
    else
      veh:setPosRot(pos.x, pos.y, pos.z + 0.5, rot.x, rot.y, rot.z, rot.w)
    end
    return true
  end

  local function setVehicleStopped(vehId, destroyed)
    local obj = vehId and be:getObjectByID(vehId) or nil
    if not obj then return end
    obj:queueLuaCommand("if ai then ai.setMode('stop') end")
    obj:queueLuaCommand("input.event('throttle', 0, 1)")
    obj:queueLuaCommand("input.event('brake', 1, 1)")
    obj:queueLuaCommand("input.event('parkingbrake', 1, 1)")
    if destroyed then
      obj:queueLuaCommand("electrics.setIgnitionLevel(0)")
      obj:queueLuaCommand(
        "if fire and fire.explodeVehicle then fire.explodeVehicle() elseif fire and fire.igniteVehicle then fire.igniteVehicle() end"
      )
    end
  end

  local function setPlayerFreeze(freeze)
    local aiRacers = overhaul_events_aiRacers
    if aiRacers then
      pcall(function()
        aiRacers.setPlayerFreeze(freeze == true)
      end)
      return
    end
    local veh = be:getPlayerVehicle(0)
    if veh and core_vehicleBridge then
      pcall(function()
        core_vehicleBridge.executeAction(veh, "setFreeze", freeze == true)
      end)
    end
  end

  local function capturePlayerStagingTransform(veh)
    if not veh then return false end
    derbyState.stagedPlayerTransform = {
      vehicleId = veh:getID(),
      pos = vec3(veh:getPosition()),
      rot = quat(veh:getRotation()),
    }
    return true
  end

  local function restorePlayerToStagingTransform()
    if not derbyState.stagedPlayerTransform then return end

    local restoreVeh = nil
    if derbyState.playerDerbyVehicleId then restoreVeh = be:getObjectByID(derbyState.playerDerbyVehicleId) end
    if not restoreVeh then
      local currentPlayerVehId = be:getPlayerVehicleID(0)
      if currentPlayerVehId then restoreVeh = be:getObjectByID(currentPlayerVehId) end
    end
    if not restoreVeh and derbyState.stagedPlayerTransform.vehicleId then
      restoreVeh = be:getObjectByID(derbyState.stagedPlayerTransform.vehicleId)
    end

    if restoreVeh then
      teleportVehicleSafe(restoreVeh, derbyState.stagedPlayerTransform.pos, derbyState.stagedPlayerTransform.rot)
      pcall(function()
        be:enterVehicle(0, restoreVeh)
      end)
      pcall(function()
        core_camera.resetCamera(0)
      end)
    end

    derbyState.stagedPlayerTransform = nil
  end

  local function restoreOriginalPlayerVehicle()
    if derbyState.playerLoanerVehicleId then
      local loaner = be:getObjectByID(derbyState.playerLoanerVehicleId)
      if loaner then loaner:delete() end
      derbyState.playerLoanerVehicleId = nil
    end

    local restoreVeh = derbyState.originalPlayerVehicleId and be:getObjectByID(derbyState.originalPlayerVehicleId)
      or nil
    if restoreVeh and derbyState.stagedPlayerTransform then
      teleportVehicleSafe(restoreVeh, derbyState.stagedPlayerTransform.pos, derbyState.stagedPlayerTransform.rot)
      pcall(function()
        be:enterVehicle(0, restoreVeh)
      end)
      pcall(function()
        core_camera.resetCamera(0)
      end)
    elseif restoreVeh then
      pcall(function()
        be:enterVehicle(0, restoreVeh)
      end)
    end
    derbyState.stagedPlayerTransform = nil
  end

  local function initializeParkedDerbyAi(vehId)
    pcall(function()
      extensions.core_vehicle_colors.setVehicleColor(0, ownerServices.derbyParticipants.pickRandomColor(), vehId)
    end)

    -- Initial state: AI loaded, parked, engine starting. Chase activation happens after delay.
    local vehObj = be:getObjectByID(vehId)
    if vehObj then
      -- Install the custom AI on event vehicles so they can execute derby recovery commands.
      overhaul_shell_extensionManager.applyOverrideAI(vehId)
      vehObj:queueLuaCommand("ai.setMode('stop')")
      vehObj:queueLuaCommand("input.event('parkingbrake', 1, 1)")
      local shouldStartEngine = derbyState.activeEventCfg and derbyState.activeEventCfg.startEngineOnSpawn
      if shouldStartEngine ~= false then
        vehObj:queueLuaCommand(
          "if electrics and electrics.setIgnitionLevel then electrics.setIgnitionLevel(3) end; if controller.mainController then controller.mainController.setStarter(true) end"
        )
      end
    end
  end

  local function spawnAi(requestedCount, reservedSpotIndex)
    if not derbyState.resolvedSpots or #derbyState.resolvedSpots == 0 then return 0 end
    local poolKey = derbyState.activeEntryModeCfg and derbyState.activeEntryModeCfg.aiPool
      or derbyState.activeEventCfg and derbyState.activeEventCfg.aiPool
    local pool = ownerServices.derbyParticipants.getConfiguredVehiclePool(poolKey)
    local spawned = 0

    for i = 1, #derbyState.resolvedSpots do
      if i ~= reservedSpotIndex then
        local spot = derbyState.resolvedSpots[i]
        if spot and spot.pos and spot.rot then
          local spec = ownerServices.derbyParticipants.normalizeVehiclePoolEntry(pool[((i - 1) % #pool) + 1])
          local modelKey = spec.model
          local pos = vec3(spot.pos[1], spot.pos[2], spot.pos[3])
          local rot = quat(spot.rot[1], spot.rot[2], spot.rot[3], spot.rot[4])
          local spawnOptions = {
            pos = pos,
            rot = rot,
            autoEnterVehicle = false,
          }
          if spec.config then spawnOptions.config = spec.config end
          local ok, veh = pcall(function()
            return core_vehicles.spawnNewVehicle(modelKey, spawnOptions)
          end)
          if ok and veh and veh.getID then
            local vehId = veh:getID()
            local personalityName = ownerServices.derbyRewards.pickAiPersonalityName()
            local personality = ownerServices.derbyRewards.getAiPersonalityProfiles()[personalityName]
              or DEFAULT_AI_PERSONALITIES.opportunist
            local reverseChance = ownerServices.clamp(tonumber(personality.preferReverseChance) or 0.35, 0, 1)
            table.insert(derbyState.spawnedAiIds, vehId)
            derbyState.spawnedAiInfo[vehId] = {
              model = modelKey,
              config = spec.config,
              index = spawned + 1,
              combatState = "idle",
              activeMode = "stop",
              stuckTimer = 0,
              stationaryTimer = 0,
              targetId = nil,
              personalityName = personalityName,
              retargetTimer = 0,
              retargetInterval = 0,
              driveMode = (math.random() < reverseChance and "demoderby_reverse" or "demoderby"),
            }
            spawned = spawned + 1

            initializeParkedDerbyAi(vehId)
          else
            ownerServices._log("W", "Failed to spawn AI at spot " .. tostring(i) .. ": " .. tostring(veh))
          end

          if spawned >= requestedCount then break end
        end
      end
    end
    return spawned
  end

  local function getAliveAiIds()
    local alive = {}
    for _, id in ipairs(derbyState.spawnedAiIds) do
      if not derbyState.eliminatedIds[id] then table.insert(alive, id) end
    end
    return alive
  end

  local function buildTargetCandidatesForAi(aiVehId, excludedId)
    local candidates = {}
    local playerVehId = be:getPlayerVehicleID(0)
    if playerVehId and playerVehId ~= aiVehId and playerVehId ~= excludedId and not derbyState.playerEliminated then
      table.insert(candidates, playerVehId)
    end
    for _, id in ipairs(getAliveAiIds()) do
      if id ~= aiVehId and id ~= excludedId then table.insert(candidates, id) end
    end
    return candidates
  end

  local function isValidTargetForAi(aiVehId, targetId)
    if not targetId or targetId == aiVehId or not be:getObjectByID(targetId) then return false end
    if targetId == be:getPlayerVehicleID(0) then return not derbyState.playerEliminated end
    return not derbyState.eliminatedIds[targetId] and derbyState.spawnedAiInfo[targetId] ~= nil
  end

  local function pickNearestTargetForAi(aiVehId, excludedId)
    local aiObj = be:getObjectByID(aiVehId)
    if not aiObj then return nil end
    local aiPos = aiObj:getPosition()
    local bestId = nil
    local bestDist = math.huge
    for _, id in ipairs(buildTargetCandidatesForAi(aiVehId, excludedId)) do
      local obj = be:getObjectByID(id)
      if obj then
        local pos = obj:getPosition()
        if ownerServices.derbyArena.isInsidePlayZone(pos) then
          local dist = (aiPos - pos):squaredLength()
          if dist < bestDist then
            bestDist = dist
            bestId = id
          end
        end
      end
    end
    return bestId
  end

  local function pickTargetForAi(aiVehId, isFirstTarget, excludedId)
    local nearest = pickNearestTargetForAi(aiVehId, excludedId)
    if nearest and math.random() < 0.50 then return nearest end

    -- Decide: target the player or a random other AI?
    local playerWeight = eventConfig.value(derbyState.activeEventCfg, "aiPlayerTargetWeight")
    local personality = ownerServices.derbyRewards.getAiPersonality(aiVehId)
    playerWeight = playerWeight + (tonumber(personality.playerTargetWeightBonus) or 0)
    playerWeight = ownerServices.clamp(playerWeight, 0, 1)
    if isFirstTarget then playerWeight = 0.25 end
    local playerVehId = be:getPlayerVehicleID(0)
    local playerEligible = playerVehId
      and playerVehId ~= aiVehId
      and playerVehId ~= excludedId
      and not derbyState.playerEliminated
    local aliveAi = getAliveAiIds()

    local otherAi = {}
    for _, id in ipairs(aliveAi) do
      if id ~= aiVehId and id ~= excludedId then table.insert(otherAi, id) end
    end

    if #otherAi == 0 then return playerEligible and playerVehId or nil end
    if not playerEligible then return otherAi[math.random(1, #otherAi)] end

    -- Weighted random: playerWeight chance to target player, rest targets random AI
    if math.random() < playerWeight then
      return playerVehId
    else
      return otherAi[math.random(1, #otherAi)]
    end
  end

  local function getSafestTargetId(aiVehId)
    local center = ownerServices.derbyArena.getPlayzoneCentroid()
    if not center then return nil end
    local bestId = nil
    local bestDist = math.huge

    local candidates = getAliveAiIds()
    local playerVehId = be:getPlayerVehicleID(0)
    if playerVehId and not derbyState.playerEliminated then table.insert(candidates, playerVehId) end

    for _, id in ipairs(candidates) do
      if id ~= aiVehId then
        local obj = be:getObjectByID(id)
        if obj then
          local p = obj:getPosition()
          if ownerServices.derbyArena.isInsidePlayZone(p) then
            local dist = (p - center):length()
            if dist < bestDist then
              bestDist = dist
              bestId = id
            end
          end
        end
      end
    end

    -- Fallback to random if nobody is safe
    if not bestId then return pickTargetForAi(aiVehId, false) end
    return bestId
  end

  local function setAiChaseTarget(aiVehId, targetId)
    local vehObj = be:getObjectByID(aiVehId)
    if not vehObj or not targetId then return end
    local personality = ownerServices.derbyRewards.getAiPersonality(aiVehId)
    local aggression = eventConfig.value(derbyState.activeEventCfg, "aiAggression")
    aggression = aggression * (tonumber(personality.aggressionMultiplier) or 1)
    aggression = math.max(1.6, aggression)
    local avoidCars = eventConfig.value(derbyState.activeEventCfg, "aiAvoidCars")

    local info = derbyState.spawnedAiInfo[aiVehId]
    if info then
      local desiredMode = info.driveMode
      local modeChanged = info.activeMode ~= desiredMode
      info.targetId = targetId
      info.stuckTimer = 0
      info.combatState = desiredMode
      if modeChanged then
        vehicleCommands.queue(vehObj, "ai", "setMode", desiredMode .. "")
        info.activeMode = desiredMode
      end
      vehicleCommands.queue(vehObj, "ai", "setAvoidCars", avoidCars .. "")
    end

    vehicleCommands.queue(vehObj, "ai", "setTargetObjectID", tonumber(tostring(targetId)))
    vehicleCommands.queue(vehObj, "ai", "setAggression", tonumber(tostring(aggression)))
    vehObj:queueLuaCommand("ai.driveInLane('off')")
    vehObj:queueLuaCommand("input.event('parkingbrake', 0, 1)")
  end

  return {
    teleportVehicleSafe = teleportVehicleSafe,
    setVehicleStopped = setVehicleStopped,
    setPlayerFreeze = setPlayerFreeze,
    capturePlayerStagingTransform = capturePlayerStagingTransform,
    restorePlayerToStagingTransform = restorePlayerToStagingTransform,
    restoreOriginalPlayerVehicle = restoreOriginalPlayerVehicle,
    spawnAi = spawnAi,
    isValidTargetForAi = isValidTargetForAi,
    pickNearestTargetForAi = pickNearestTargetForAi,
    pickTargetForAi = pickTargetForAi,
    getSafestTargetId = getSafestTargetId,
    setAiChaseTarget = setAiChaseTarget,
  }
end

return lib
