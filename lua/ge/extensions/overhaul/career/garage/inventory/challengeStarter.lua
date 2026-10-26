-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Starter gifts for new careers: the shared worn-out inventory entry and the challenge starter vehicle.
-- Read in order: inventory entry, challenge starter selection, placement, spawning, grant and setup retries.
local challengeStarter = {}
local levelData = require('overhaul/lib/world/levelData')
local challengeStartRules = require('overhaul/career/start/challengeStartRules')

-- Gifted starters are worn out like the hardcore car, so their value stays at beater level.
local STARTER_MILEAGE_METERS = 900000 * 1609.344
local STARTER_VISUAL_CONDITION = 0.5
-- Distance ahead of the player when a map configures no starter vehicle spawn.
local STARTER_FALLBACK_DISTANCE = 6
-- A garage spot this close to the player is the one they were teleported onto.
local STARTER_SPOT_CLEARANCE = 4

function challengeStarter.new(inputs)
  -- Inputs ----------------------------------------------------------------------------------------
  local M = inputs.M
  local teleportPlayerToStartingGarage = inputs.teleportPlayerToStartingGarage
  local positionPlayer = inputs.positionPlayer

  -- Inventory entry -------------------------------------------------------------------------------

  -- Conditions are queued before addVehicle so its default condition request does not replace them.
  local function addStarterToInventory(veh)
    veh:queueLuaCommand(string.format("partCondition.initConditions(nil, %d, nil, %f)",
      STARTER_MILEAGE_METERS, STARTER_VISUAL_CONDITION))
    local inventoryId = M.addVehicle(veh:getID(), nil, {
      starter = true
    })
    if not inventoryId then return nil end
    -- Starter cars are gifts, not insured purchases.
    extensions.hook("onOverhaulVehicleAddedToInventory", {
      inventoryId = inventoryId,
      purchaseData = {insuranceId = -1},
    })
    overhaul_career_career.setBoughtStarterVehicle(true)
    return inventoryId
  end

  -- Challenge starter ------------------------------------------------------------------------------
  -- The grant is recorded on the active challenge, which is saved with the career, so it happens once per save.

  local function owedChallengeStarter()
    local challengeModes = overhaul_career_challengeModes
    if not (challengeModes and challengeModes.isChallengeActive()) then return nil end
    local challenge = challengeModes.getActiveChallenge()
    if not (challenge and type(challenge.starterVehicles) == "table" and #challenge.starterVehicles > 0) then return nil end
    return challenge
  end

  local function pickChallengeStarter(challenge)
    local candidates = {}
    for _, entry in ipairs(challenge.starterVehicles) do
      local config, model, configKey = challengeStartRules.starterVehiclePath(entry)
      if config and FS:fileExists(config) then
        table.insert(candidates, {model = model, key = configKey, config = config})
      else
        log("W", "career.inventory", "Challenge starter: skipping missing vehicle config " .. tostring(entry))
      end
    end
    if #candidates == 0 then return nil end
    return candidates[math.random(#candidates)]
  end

  -- A map's challenge spawns win; otherwise the hardcore spawns serve the same homeless start.
  local function configuredStarterSpawns(levelName)
    local data = levelData.loadStart(levelName)
    local modes = data and data.modes or {}
    for _, modeId in ipairs({"challenge", "hardcore"}) do
      local mode = modes[modeId]
      if mode and mode.playerSpawn and mode.vehicleSpawn then
        local playerSpawn = levelData.resolveSpawn(mode.playerSpawn, levelName)
        local vehicleSpawn = levelData.resolveSpawn(mode.vehicleSpawn, levelName)
        if playerSpawn and vehicleSpawn then return playerSpawn, vehicleSpawn end
      end
    end
    return nil
  end

  -- Called after the player reached the garage, so the gift takes a spot the player is not standing on.
  local function garageVehicleSpawn(garageId)
    local garage = overhaul_world_facilities.getFacilityIfExists("garage", garageId)
    local player = getPlayerVehicle(0)
    if not (garage and player) then return nil end
    local ok, spots = pcall(overhaul_world_facilities.getParkingSpotsForFacility, garage)
    if not ok or not spots then return nil end
    local playerPos = vec3(player:getPosition())
    for _, spot in ipairs(spots) do
      if spot.pos and spot.rot and vec3(spot.pos):distance(playerPos) > STARTER_SPOT_CLEARANCE then
        return {pos = spot.pos, rot = spot.rot}
      end
    end
    return nil
  end

  local function spawnAheadOfPlayer()
    local player = getPlayerVehicle(0)
    if not player then return nil end
    local direction = vec3(player:getDirectionVector())
    direction.z = 0
    if direction:length() < 0.01 then direction = vec3(1, 0, 0) end
    direction:normalize()
    return {pos = vec3(player:getPosition()) + direction * STARTER_FALLBACK_DISTANCE, rot = quatFromDir(direction)}
  end

  -- Returns where the gift goes, or nil when the player could not be placed yet and the setup should retry.
  local function placeChallengeStarterPlayer(levelName)
    local garageId = overhaul_career_garage_garageManager.getPrimaryStartingGarageId(levelName)
    if garageId then
      if not teleportPlayerToStartingGarage(levelName) then return nil end
      return garageVehicleSpawn(garageId) or spawnAheadOfPlayer()
    end
    local playerSpawn, vehicleSpawn = configuredStarterSpawns(levelName)
    if playerSpawn then
      if positionPlayer(playerSpawn) then return vehicleSpawn end
      return nil
    end
    if teleportPlayerToStartingGarage(levelName) then return spawnAheadOfPlayer() end
    return nil
  end

  local function spawnChallengeStarter(starter, placement)
    local options = sanitizeVehicleSpawnOptions(starter.model, {
      config = starter.config,
      licenseText = "Starter",
      vehicleName = "Starter Car",
      pos = placement.pos,
      rot = placement.rot
    })
    options.autoEnterVehicle = false
    local ok, veh = pcall(core_vehicles.spawnNewVehicle, starter.model, options)
    if not ok then
      log("E", "career.inventory", "Challenge starter spawn failed: " .. tostring(veh))
      return nil
    end
    if not veh then return nil end
    core_vehicleBridge.executeAction(veh, 'setIgnitionLevel', 0)
    core_vehicles.setPlateText("Starter", veh:getID())
    return veh
  end

  -- Returns true when the gift was delivered, false when it never will be, nil when the setup should retry.
  local function grantChallengeStarter(challenge, levelName)
    local placement = placeChallengeStarterPlayer(levelName)
    if not placement then return nil end

    local starter = pickChallengeStarter(challenge)
    if not starter then
      log("E", "career.inventory", "Challenge starter: no listed vehicle config exists")
      return false
    end

    local veh = spawnChallengeStarter(starter, placement)
    if not veh then
      log("E", "career.inventory", "Challenge starter: could not spawn " .. starter.config)
      return false
    end
    -- A gift that cannot be owned must not stay in the world as a free, unsaved car.
    if not addStarterToInventory(veh) then
      log("E", "career.inventory", "Challenge starter spawned but failed to enter inventory")
      veh:delete()
      return false
    end

    overhaul_career_challengeModes.markStarterVehicleGranted()
    log("I", "career.inventory", "Challenge starter granted: " .. starter.config)
    return true
  end

  local function finalizeChallengeStarter(challenge, levelName)
    if challenge.starterVehicleGranted then
      log("I", "career.inventory", "setupInventory retry: challenge starter already granted")
      if not placeChallengeStarterPlayer(levelName) then inputs.state.inventorySetupDone = false end
      return
    end
    local granted = grantChallengeStarter(challenge, levelName)
    if granted == nil then
      inputs.state.inventorySetupDone = false
    elseif not granted then
      ui_message("Your starter vehicle could not be delivered.", nil, "vehicleInventory")
      teleportPlayerToStartingGarage(levelName)
    end
  end

  -- Public API ------------------------------------------------------------------------------------

  -- Returns true when the active challenge owes a starter vehicle and this call handled its placement.
  local function finalize(levelName)
    local challenge = owedChallengeStarter()
    if not challenge then return false end
    finalizeChallengeStarter(challenge, levelName)
    return true
  end

  return {
    addStarterToInventory = addStarterToInventory,
    finalize = finalize,
  }
end

return challengeStarter
