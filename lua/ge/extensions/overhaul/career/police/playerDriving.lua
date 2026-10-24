-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Coordinates player traffic, police roles, pursuit fines and garage camera transitions.
-- Fork of stock lua/ge/extensions/career/modules/playerDriving.lua (BeamNG 0.40).
local M = {}
M.dependencies = {"overhaul_career_career"}

local facilityRole = require('overhaul/lib/logistics/facilityRole')
local policy = require('overhaul/lib/vehicles/policy')

local playerData = {maxTrafficAmount = 0, maxParkingAmount = 0, defaultTrafficAmount = 1, trafficActive = 0}
local trafficSetupInProgress = false
local trafficSetupStartedAt = nil
local TRAFFIC_SETUP_TIMEOUT_SECONDS = 180
local function setTrafficSetupInProgress(active)
  trafficSetupInProgress = active
  trafficSetupStartedAt = active and os.clockhp() or nil
end
-- A setup whose ready callback never fires must not lock traffic setup for the session.
local function isTrafficSetupInProgress()
  if trafficSetupInProgress and trafficSetupStartedAt and os.clockhp() - trafficSetupStartedAt > TRAFFIC_SETUP_TIMEOUT_SECONDS then
    log("W", "career", "Traffic setup did not report ready; releasing it")
    setTrafficSetupInProgress(false)
  end
  return trafficSetupInProgress
end
local testTrafficAmounts = {
  traffic = 1,
  police = 0,
  parkedCars = 1,
  active = 1
}

M.ensureTraffic = false
M.preStart = true
M.debugMode = not shipping_build

local function getPlayerData()
  return playerData
end

-- gameplay_walk is a level preset and is absent outside a level.
local function isWalking()
  return gameplay_walk ~= nil and gameplay_walk.isWalking()
end

local function setPlayerData(newId, oldId)
  playerData.isParked = overhaul_integration_services_parking.getCurrentParkingSpot(newId) and true or false

  if oldId then
    overhaul_integration_services_parking.disableTracking(oldId)
  end
  if not isWalking() then
    overhaul_integration_services_parking.enableTracking(newId)
  end

  if not gameplay_traffic.getTrafficData()[newId] then
    gameplay_traffic.insertTraffic(newId, true)
  end

  playerData.traffic = gameplay_traffic.getTrafficData()[newId]
  playerData.parking = overhaul_integration_services_parking.getTrackingData()[newId]
end

local function isPoliceLoanerVehicle(vehId)
  if not vehId then return false end
  local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)
  local inventoryVehicle = inventoryId and overhaul_career_garage_inventory.getVehicles()[inventoryId]
  if inventoryVehicle and facilityRole.isPoliceOrganizationId(inventoryVehicle.owningOrganization) then
    return true
  end
  if not overhaul_career_logistics_loanerVehicles or not overhaul_career_logistics_loanerVehicles.getLoaningOrgsOfVehicle then
    return false
  end
  local loaningOrgs = overhaul_career_logistics_loanerVehicles.getLoaningOrgsOfVehicle(vehId)
  if not loaningOrgs then
    return false
  end
  for orgId, _ in pairs(loaningOrgs) do
    if facilityRole.isPoliceOrganizationId(orgId) then
      return true
    end
  end
  return false
end

local function getPlayerIsCop(switchContext)
  switchContext = switchContext or {}
  local vehId = be:getPlayerVehicleID(0)
  if vehId and gameplay_traffic.getTrafficData()[vehId] and overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId) then
    local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)
    local trafficVehicle = gameplay_traffic.getTrafficData()[vehId]
    local certifiedRole = overhaul_career_garage_inventory.getVehicleRole(inventoryId)
    local certifiedPolice = certifiedRole == 'police' or isPoliceLoanerVehicle(vehId)

    local pursuitMode = trafficVehicle.pursuit and trafficVehicle.pursuit.mode or 0
    if pursuitMode == 0 and switchContext.switchOldId then
      local oldTraffic = gameplay_traffic.getTrafficData()[switchContext.switchOldId]
      if oldTraffic and oldTraffic.pursuit then
        pursuitMode = oldTraffic.pursuit.mode or 0
      end
    end

    -- Certified / loaner police stay on duty; clear residual pursuit heat instead of
    -- demoting them to suspect (that made AI backup treat the player as the chase target).
    if certifiedPolice then
      -- Designated repo carriers keep normal targeting even with custom plates.
      if policy.hasRole("repoCarrier", vehId) then
        return false
      end
      if trafficVehicle then
        if not trafficVehicle.role or trafficVehicle.role.name ~= 'police' then
          trafficVehicle:setRole('police')
        end
        trafficVehicle.ignorePolice = true
        if trafficVehicle.pursuit and (trafficVehicle.pursuit.mode ~= 0 or (trafficVehicle.pursuit.score or 0) > 0) then
          if overhaul_integration_services_police then
            overhaul_integration_services_police.setPursuitMode(0, vehId)
          else
            trafficVehicle.pursuit.mode = 0
            trafficVehicle.pursuit.score = 0
          end
        end
      end
      if not gameplay_traffic.getTrafficVars().enableRandomEvents then
        gameplay_traffic.setTrafficVars({
          enableRandomEvents = true
        })
      end
      return true
    end

    if pursuitMode ~= 0 then
      if pursuitMode > 0 and trafficVehicle.role and trafficVehicle.role.name ~= 'suspect' then
        trafficVehicle:setRole('suspect')
        overhaul_shell_extensionManager.applyOverrideAI(vehId)
      end
      if policy.hasRole("repoCarrier", vehId) then
        return false
      end
      gameplay_traffic.setTrafficVars({
        enableRandomEvents = false
      })
      return false
    end
    local vehicleRole = overhaul_career_garage_inventory.getVehicleRole(inventoryId)
    if vehicleRole ~= nil then
      if trafficVehicle then
        trafficVehicle:setRole(vehicleRole)
      end
    end
    if policy.hasRole("repoCarrier", vehId) then
      return false
    end
    local trafficEntry = gameplay_traffic.getTrafficData()[vehId]
    local role = trafficEntry and trafficEntry.role and trafficEntry.role.name
    if role == 'police' then
      if trafficVehicle then
        trafficVehicle:setRole('standard')
      end
      if switchContext.switchOldId ~= nil then
        ui_message("This vehicle is not certified for police work", 8, "Police", "info")
      end
      gameplay_traffic.setTrafficVars({
        enableRandomEvents = false
      })
      return false
    else
      gameplay_traffic.setTrafficVars({
        enableRandomEvents = false
      })
      return false
    end
  end
  return false
end

local function setTrafficVars()
  local spawnValue = clamp(6 / math.max(6, gameplay_traffic.getTrafficAmount(true)), 0.1, 1)
  gameplay_traffic.setTrafficVars({enableRandomEvents = false, spawnValue = spawnValue})
  overhaul_integration_services_police.setPursuitVars({arrestRadius = 15, evadeTime = 40})
  overhaul_integration_services_parking.setParkingVars({precision = 0.2})
end

-- Vanilla taxi registers its reserved vehicles during onTrafficSpecialVehiclesProviders.
-- Career loads traffic before overhaul_integration_services_taxi is pulled in, so hail can spawn a car with
-- no provider/UI state unless we load the extension and refresh after traffic is ready.
local function ensureVanillaTaxiReady()
  if not extensions.isExtensionLoaded("overhaul_integration_services_taxi") then
    local ok, err = pcall(extensions.load, "overhaul_integration_services_taxi")
    if not ok then log("E", "playerDriving", "Taxi service failed to load: " .. tostring(err)) end
  end
  if not overhaul_integration_services_taxi then return false end
  if gameplay_traffic.getState() == "on" then
    if overhaul_integration_services_taxi.onTrafficStarted then
      overhaul_integration_services_taxi.onTrafficStarted()
    end
    if overhaul_integration_services_taxi.onTrafficSpecialVehiclesProviders then
      overhaul_integration_services_taxi.onTrafficSpecialVehiclesProviders()
    end
  end
  return true
end

local function isNoPoliceModActive()
  if overhaul_career_career.hardcoreMode or overhaul_career_economy_difficultyMode.isHardcoreMode() then
    return false
  end
  return not overhaul_career_police_policePreference.isEnabled()
end

local function isNoParkedModActive()
  return settings.getValue('trafficParkedVehicles') == false
    or overhaul_shell_settings.getSetting('noParkedMode')
end

local function getFallbackTrafficAmounts()
  local trafficAmount = settings.getValue('trafficAmount')
  if trafficAmount == 0 then
    trafficAmount = gameplay_traffic.getIdealSpawnAmount()
  end
  if not getAllVehiclesByType()[1] then
    trafficAmount = trafficAmount - 1
  end
  trafficAmount = math.max(0, trafficAmount)

  local parkingAmount = tonumber(settings.getValue('trafficParkingAmount')) or 0
  if isNoParkedModActive() then
    parkingAmount = 0
  else
    if parkingAmount == 0 then
      parkingAmount = clamp(gameplay_traffic.getIdealSpawnAmount(nil, true), 4, 20)
    end
  end

  return trafficAmount, parkingAmount
end

local function setupTraffic(forceSetup)
  -- Several 0.39 career lifecycle hooks can arrive during the same level load.
  -- setupTrafficHelper is asynchronous, so maxTrafficAmount is still zero while
  -- later hooks run; without a lock each hook starts another complete batch.
  if isTrafficSetupInProgress() then return end
  if not forceSetup and playerData.maxTrafficAmount > 0 then return end
  if forceSetup and gameplay_traffic.getState() == "on" and gameplay_traffic.getTrafficAmount() > 0 then
    M.ensureTraffic = false
    return
  end

  log("I", "career", "Now spawning traffic for career mode")
  if core_gamestate.loading() then core_gamestate.requestEnterLoadingScreen('careerVehicles') end

  local restrict = settings.getValue('trafficRestrictForCareer')
  if shipping_build then restrict = false end

  local trafficAmount, parkingAmount = getFallbackTrafficAmounts()
  if restrict then
    trafficAmount, parkingAmount = testTrafficAmounts.traffic, testTrafficAmounts.parkedCars
  end

  playerData.trafficActive = restrict and testTrafficAmounts.active or trafficAmount
  playerData.desiredParkingAmount = parkingAmount

  local trafficOptions = {
    simpleVehs = true,
    autoLoadFromFile = true,
    police = not isNoPoliceModActive()
  }
  setTrafficSetupInProgress(true)
  local ok, err = xpcall(function()
    gameplay_traffic.setupTrafficHelper(trafficAmount, trafficOptions, parkingAmount, nil)
    gameplay_traffic.setActiveAmount(trafficAmount)
    overhaul_integration_services_parking.setActiveAmount(parkingAmount)
    setTrafficVars()
  end, debug.traceback)
  if not ok then
    setTrafficSetupInProgress(false)
    error(err, 0)
  end
  M.ensureTraffic = false
end

local function onSettingsChanged()
  if not overhaul_career_career.isActive() then return end
  local trafficAmount, parkingAmount = getFallbackTrafficAmounts()
  local restrict = settings.getValue('trafficRestrictForCareer')
  if shipping_build then restrict = false end
  if restrict then
    trafficAmount, parkingAmount = testTrafficAmounts.traffic, testTrafficAmounts.parkedCars
  end

  playerData.trafficActive = restrict and testTrafficAmounts.active or trafficAmount
  playerData.desiredParkingAmount = parkingAmount

  if gameplay_traffic.getState() == "on" then
    gameplay_traffic.setActiveAmount(playerData.trafficActive)
  end

  -- Loading with parking off leaves the pool inactive. A later ON setting
  -- must be able to create that pool, as well as resize an existing one.
  overhaul_integration_services_parking.setActiveAmount(parkingAmount)
  if overhaul_integration_services_parking.syncParkedCount then
    overhaul_integration_services_parking.syncParkedCount()
  end
end

local function setPoliceProbability(value)
  for id, tData in pairs(gameplay_traffic.getTrafficData()) do
    if tData.role and tData.role.name == "police" then
      tData.activeProbability = value
      if value == 0 then
        local veh = getObjectByID(id)
        if veh then
          veh:setActive(0)
        end
      end
    end
  end
end

local function playerPursuitActive()
  return playerData.traffic and playerData.traffic.pursuit and playerData.traffic.pursuit.mode ~= 0
end

local function resetPlayerState()
  setPlayerData(be:getPlayerVehicleID(0))
  setTrafficVars()
  if playerData.traffic then
    playerData.traffic:resetAll()
  end
end

local function retrieveFavoriteVehicle()
  local inventory = overhaul_career_garage_inventory
  local favoriteVehicleInventoryId = inventory.getFavoriteVehicle()
  if not favoriteVehicleInventoryId then
    return
  end
  local inventoryVehicle = inventory.getVehicles()[favoriteVehicleInventoryId]
  if not inventoryVehicle then
    return
  end

  local routePrice = 0
  local targetPos
  local existingVehId = inventory.getVehicleIdFromInventoryId(favoriteVehicleInventoryId)
  local existingVeh = existingVehId and getObjectByID(existingVehId)
  if existingVeh then
    targetPos = existingVeh:getPosition()
  elseif inventoryVehicle.location then
    local garage = overhaul_world_facilities.getFacility("garage", inventoryVehicle.location)
    targetPos = garage and overhaul_world_facilities.getGaragePosRot(garage) or nil
  end
  if targetPos and overhaul_career_garage_quickTravel then
    routePrice = overhaul_career_garage_quickTravel.getPriceForQuickTravel(targetPos) or 0
  end
  if not existingVehId and (inventoryVehicle.timeToAccess or overhaul_career_repair_insurance.inventoryVehNeedsRepair(favoriteVehicleInventoryId)) then
    return
  end
  local vehId = existingVehId
  if vehId then
    local playerVehObj = getPlayerVehicle(0)
    if not existingVeh or not playerVehObj then return end
    spawn.safeTeleport(existingVeh, playerVehObj:getPosition(), quatFromDir(playerVehObj:getDirectionVector()),
      nil, nil, nil, nil, false)
    inventory.useVehicleRetrievalService(
      favoriteVehicleInventoryId, routePrice, "Retrieved favorite vehicle with towing service")
    core_vehicleBridge.executeAction(getObjectByID(vehId), 'setIgnitionLevel', 0)
  elseif not inventoryVehicle.timeToAccess and not overhaul_career_repair_insurance.inventoryVehNeedsRepair(favoriteVehicleInventoryId) then
    inventory.spawnVehicle(favoriteVehicleInventoryId, nil, function()
      local playerVehObj = getPlayerVehicle(0)
      local vehId = inventory.getVehicleIdFromInventoryId(favoriteVehicleInventoryId)
      local vehObj = vehId and getObjectByID(vehId)
      if not vehObj or not playerVehObj then return end
      spawn.safeTeleport(vehObj, playerVehObj:getPosition(),
        quatFromDir(playerVehObj:getDirectionVector()), nil, nil, nil, nil, false)
      inventory.useVehicleRetrievalService(
        favoriteVehicleInventoryId, routePrice, "Retrieved favorite vehicle with towing service")
    end)
  end
end

local function getFavoriteVehicleRetrievalPrice()
  local inventory = overhaul_career_garage_inventory
  local inventoryId = inventory and inventory.getFavoriteVehicle and inventory.getFavoriteVehicle()
  if not inventoryId then return {} end
  local inventoryVehicle = inventory.getVehicles()[inventoryId]
  if not inventoryVehicle then return {} end

  local targetPos
  local vehId = inventory.getVehicleIdFromInventoryId(inventoryId)
  local veh = vehId and getObjectByID(vehId)
  if veh then
    targetPos = veh:getPosition()
  elseif inventoryVehicle.location then
    local garage = overhaul_world_facilities.getFacility("garage", inventoryVehicle.location)
    targetPos = garage and overhaul_world_facilities.getGaragePosRot(garage) or nil
  end
  local routePrice = targetPos and overhaul_career_garage_quickTravel and
    overhaul_career_garage_quickTravel.getPriceForQuickTravel(targetPos) or 0
  local quote = inventory.getVehicleRetrievalQuote(inventoryId, routePrice)
  if quote.coveredByInsurance then return {} end
  return {money = {amount = quote.cost, canBeNegative = true}}
end

local function teleportToGarage(garageId, veh, resetVeh, callback)
  extensions.load('overhaul_career_garage_vehicleTransport')
  return overhaul_career_garage_vehicleTransport.tow(garageId, veh, function(success)
    if success then
      freeroam_bigMapMode.navigateToMission(nil)
      core_camera.resetCamera(0)
      core_vehicleBridge.executeAction(veh, 'setIgnitionLevel', 0)
      overhaul_career_maintenance_fuel.minimumRefuelingCheck(veh:getId())
      extensions.hook("onTeleportedToGarage", garageId, veh)
    end
    if callback then callback(success) end
  end, resetVeh)
end

local function onVehicleParkingStatus(vehId, data)
  if vehId == be:getPlayerVehicleID(0) then
    if data.event == "valid" then
      if not playerData.isParked then
        playerData.isParked = true
      end
    elseif data.event == "exit" then
      playerData.isParked = false
    end
  end
end

local function onTrafficStarted()
  local updateAmount = playerData.maxTrafficAmount == 0
  do
    updateAmount = true
    resetPlayerState()
    setPoliceProbability(isNoPoliceModActive() and 0 or 0.15)
    if playerData.trafficActive and playerData.trafficActive > 0 then
      gameplay_traffic.setActiveAmount(playerData.trafficActive)
    end
  end
  if updateAmount then
    playerData.maxTrafficAmount = gameplay_traffic.getTrafficAmount(true)
    playerData.maxParkingAmount = overhaul_integration_services_parking.getParkingAmount(true)
  end
end

local function onTrafficStopped()
  if playerData.traffic then
    table.clear(playerData.traffic)
  end

  -- A helper may stop the old batch as part of its own asynchronous setup.
  -- Do not interpret that intermediate event as a request for another batch.
  if M.ensureTraffic and not isTrafficSetupInProgress() then
    setupTraffic(true)
  end
end

local function calculateSuspectPursuitFine(pursuitData)
  local violations = math.max(1, tonumber(pursuitData.uniqueOffensesCount) or tonumber(pursuitData.offensesCount) or 1)
  local score = math.max(0, tonumber(pursuitData.score) or 0)
  local mode = math.max(1, tonumber(pursuitData.mode) or 1)
  local globalIndex = overhaul_career_economy_globalEconomy.getGlobalIndex() or 1
  local sectionMult = overhaul_career_economyAdjuster.getSectionMultiplier("police") or 1
  local base = violations * 100 + score * 0.5 + mode * 75
  local fine = math.floor(base * globalIndex * sectionMult)
  return math.max(150, math.min(fine, 750000))
end

local function onPursuitAction(vehId, action, data)
  if policy.query('pursuitOutcomeIgnored', vehId) then return end
  if vehId ~= be:getPlayerVehicleID(0) then
    -- Walking players leave the pursuit attached to their previous car.
    local walkHandoffVehId = isWalking() and overhaul_integration_services_police.getWalkHandoffVehId and overhaul_integration_services_police.getWalkHandoffVehId()
    if not walkHandoffVehId or vehId ~= walkHandoffVehId then
      return
    end
  end
  if action == "start" then
    overhaul_integration_services_parking.disableTracking(vehId)
    log("I", "career", "Police pursuing player, now deactivating recovery prompt buttons")
  elseif action == "reset" or action == "evade" then
    if not isWalking() then
      overhaul_integration_services_parking.enableTracking(vehId)
    end
    log("I", "career", "Pursuit ended, now activating recovery prompt buttons")
  elseif action == "arrest" then
    if getPlayerIsCop() then
      return
    end
    local fine = calculateSuspectPursuitFine(data)
    overhaul_career_economy_payment.pay({money = {amount = fine, canBeNegative = true}}, require("overhaul/lib/finance/metadata").tag({label = "Police fine", tags = {"fine"}}, "fine", {vehicleRole = "player"}))
    local mode = tonumber(data.mode) or 1
    local prefix = mode == 1 and "Citation fine" or "Arrest fine"
    ui_message(
      string.format("%s: $%d (%d violations, pursuit score %.0f)", prefix, fine,
        math.max(1, tonumber(data.uniqueOffensesCount) or tonumber(data.offensesCount) or 1),
        math.max(0, tonumber(data.score) or 0)),
      5, "careerPursuit")
    local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)
    if inventoryId then
      if mode == 1 then
        overhaul_career_garage_inventory.addTicket(inventoryId)
      else
        overhaul_career_garage_inventory.addArrest(inventoryId)
      end
    end
  end
end

local PARKED_SPAWN_GATE_TIMEOUT_SECONDS = 60
local careerVehiclesGateWait = nil

local function releaseCareerVehiclesGate()
  careerVehiclesGateWait = nil
  if not core_gamestate.getLoadingStatus('careerVehicles') then return end
  log("I", "career", "Traffic is now ready for career mode")
  core_gamestate.requestExitLoadingScreen('careerVehicles')
  -- The parked-car wait runs in a job that can finish after a level switch has unloaded this preset.
  if freeroam_specialTriggers then
    for k, v in pairs(freeroam_specialTriggers.getTriggers()) do
      freeroam_specialTriggers.setTriggerActive(k, false, true)
    end
  end
end

-- Parked cars queued while the load was running (a top-up group) finish spawning under the
-- loading screen; each spawn is a long frame that would otherwise land right after the fade.
local function releaseCareerVehiclesGateAfterParking()
  local parking = overhaul_integration_services_parking
  if not (parking and parking.isSpawnPending and parking.isSpawnPending()) then
    releaseCareerVehiclesGate()
    return
  end
  local wait = {startedAt = os.clockhp()}
  careerVehiclesGateWait = wait
  log("I", "career", "Keeping the loading screen until the queued parked cars have spawned")
  core_jobsystem.create(function(job)
    while careerVehiclesGateWait == wait and parking.isSpawnPending()
        and os.clockhp() - wait.startedAt < PARKED_SPAWN_GATE_TIMEOUT_SECONDS do
      job.sleep(0.1)
    end
    if careerVehiclesGateWait == wait then releaseCareerVehiclesGate() end
  end)
end

local function onTrafficOrParkingReady()
  -- setupTrafficHelper is finished only after both asynchronous groups are
  -- ready. onTrafficStarted can arrive earlier while parking is still spawning.
  setTrafficSetupInProgress(false)
  local parkingAmount = playerData.desiredParkingAmount
  if not parkingAmount then
    parkingAmount = select(2, getFallbackTrafficAmounts())
  end
  overhaul_integration_services_parking.setActiveAmount(parkingAmount)
  if core_gamestate.getLoadingStatus('careerVehicles') then
    releaseCareerVehiclesGateAfterParking()
  end
  ensureVanillaTaxiReady()
end

local function onVehicleSwitched(oldId, newId)
  -- Garage respawns briefly switch the player to vehicle id -1.
  if not newId or newId < 0 or be:getPlayerVehicleID(0) ~= newId then
    return
  end
  do
    setPlayerData(newId, oldId)
    setTrafficVars()
    local playerIsCop = getPlayerIsCop({switchOldId = oldId})
    if playerIsCop then
      local trafficVehicle = gameplay_traffic.getTrafficData()[newId]
      if trafficVehicle then
        trafficVehicle.ignorePolice = true
        if trafficVehicle.pursuit and trafficVehicle.pursuit.mode ~= 0 then
          overhaul_integration_services_police.setPursuitMode(0, newId)
        elseif trafficVehicle.pursuit then
          trafficVehicle.pursuit.mode = 0
          trafficVehicle.pursuit.score = 0
        end
      end
      -- Drop any AI units that were still locked onto this player-cop.
      local policeUnits = overhaul_integration_services_police.getPoliceVehicles and overhaul_integration_services_police.getPoliceVehicles()
      if policeUnits then
        for policeVehicleId, policeVehicle in pairs(policeUnits) do
          if policeVehicleId ~= newId and policeVehicle.role and policeVehicle.role.targetId == newId then
            policeVehicle.role:resetAction()
          end
        end
      end
      local policeDisabled, disabledReason = overhaul_career_police_enforcement.isPoliceDisabled()
      if policeDisabled then
        ui_message("Police service disabled: " .. disabledReason, 8, "Police", "warning")
      else
        ui_message("You are now a cop", 5, "Police", "info")
      end
    end
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if M.preStart and freeroam_specialTriggers and playerData.traffic then
    if not playerData.preStartTicks then
      playerData.preStartTicks = 6
    end
    playerData.preStartTicks = playerData.preStartTicks - 1
    for k, v in pairs(freeroam_specialTriggers.getTriggers()) do
      if not v.vehIds[be:getPlayerVehicleID(0)] then
        if playerData.preStartTicks == 3 then
          freeroam_specialTriggers.setTriggerActive(k, true, true)
        elseif playerData.preStartTicks == 0 then
          freeroam_specialTriggers.setTriggerActive(k, false, true)
          M.preStart = false
        end
      end
    end
    if playerData.preStartTicks == 0 then
      playerData.preStartTicks = nil
    end
  end

  if not playerPursuitActive() then
    return
  end

  if not playerData.pursuitStuckTimer then
    playerData.pursuitStuckTimer = 0
  end
  local policeClosing = false
  local sight = playerData.traffic.pursuit.sight
  if sight and sight.policeId and sight.dist and sight.dist < math.huge then
    local policeDistanceMeters = math.sqrt(sight.dist) -- sight.dist is squared
    local policeVars = overhaul_integration_services_police.getPoliceVars and overhaul_integration_services_police.getPoliceVars()
    local closeRadius = ((policeVars and policeVars.arrestRadius) or 15) * 3
    local lastDist = playerData.pursuitLastPoliceDist
    if policeDistanceMeters <= closeRadius or (playerData.traffic.pursuit.policeVisible and policeDistanceMeters <= 200) then
      policeClosing = true
    elseif lastDist and dtSim > 0 and (lastDist - policeDistanceMeters) / dtSim > 1 then
      policeClosing = true
    end
    playerData.pursuitLastPoliceDist = policeDistanceMeters
  else
    playerData.pursuitLastPoliceDist = nil
  end
  if (not policeClosing and playerData.traffic.speed < 3 and playerData.traffic.pursuit.timers.arrest == 0 and
    playerData.traffic.pursuit.timers.evade == 0) then
    playerData.pursuitStuckTimer = playerData.pursuitStuckTimer + dtSim
    if playerData.pursuitStuckTimer >= 10 then
      log("I", "career", "Ending pursuit early due to stalemate")
      overhaul_integration_services_police.evadeVehicle(be:getPlayerVehicleID(0), true)
      playerData.pursuitStuckTimer = 0
    end
  else
    playerData.pursuitStuckTimer = 0
  end
end

local function onOverhaulActive(active)
  if not active then
    setTrafficSetupInProgress(false)
    if careerVehiclesGateWait then releaseCareerVehiclesGate() end
  end
  if active then
    M.ensureTraffic = true
    if playerData.maxTrafficAmount == 0 then
      setupTraffic()
    end
  end
  if core_gamestate.loading() and freeroam_specialTriggers then
    for k, v in pairs(freeroam_specialTriggers.getTriggers()) do
      freeroam_specialTriggers.setTriggerActive(k, true, true)
    end
  end
end

-- Career activate handoffs (map switch, exit→reload, deferred profile load) all
-- disable freeroam traffic and expect playerDriving to spawn it. Stock .39 only
-- spawns when maxTrafficAmount == 0; force respawn on every module activate.
local function onOverhaulModulesActivated(alreadyInLevel)
  M.ensureTraffic = true
  setupTraffic(true)
end

local function onClientStartMission()
  setupTraffic()
end

local function onWorldReadyState(state)
  if state == 2 and overhaul_career_career.isActive() then
    setupTraffic()
  end
end

local function buildCamPath(targetPos, endDir)
  local path = {
    looped = false,
    manualFov = false
  }
  local startPos = core_camera.getPosition() + vec3(0, 0, 30)

  local m1 = {
    fov = 30,
    movingEnd = false,
    movingStart = false,
    positionSmooth = 0.5,
    pos = startPos,
    rot = quatFromDir(targetPos - startPos),
    time = 0,
    trackPosition = false
  }
  local m2 = {
    fov = 30,
    movingEnd = false,
    movingStart = false,
    positionSmooth = 0.5,
    pos = startPos,
    rot = quatFromDir(targetPos - startPos),
    time = 0.5,
    trackPosition = false
  }
  local m3 = {
    fov = core_camera.getFovDeg(),
    movingEnd = false,
    movingStart = false,
    positionSmooth = 0.5,
    pos = core_camera.getPosition(),
    rot = endDir and quatFromDir(endDir) or core_camera.getQuat(),
    time = 5.5,
    trackPosition = false
  }
  path.markers = {m1, m2, m3}

  return path
end

local function showPosition(pos)
  local camDir = pos - getPlayerVehicle(0):getPosition()
  if isWalking() then
    gameplay_walk.setRot(camDir)
  end

  local camDirLength = camDir:length()
  local rayDist = castRayStatic(getPlayerVehicle(0):getPosition(), camDir, camDirLength)

  if rayDist < camDirLength then
    local camPath = buildCamPath(pos, camDir)
    local initData = {}
    initData.finishedPath = function(this)
      core_camera.setVehicleCameraByIndexOffset(0, 1)
    end
    core_paths.playPath(camPath, 0, initData)
  end
end

M.getPlayerData = getPlayerData
M.isTrafficSetupInProgress = isTrafficSetupInProgress
M.retrieveFavoriteVehicle = retrieveFavoriteVehicle
M.getFavoriteVehicleRetrievalPrice = getFavoriteVehicleRetrievalPrice
M.playerPursuitActive = playerPursuitActive
M.resetPlayerState = resetPlayerState
M.teleportToGarage = teleportToGarage
M.showPosition = showPosition
M.getPlayerIsCop = getPlayerIsCop
M.ensureVanillaTaxiReady = ensureVanillaTaxiReady

M.onTrafficOrParkingReady = onTrafficOrParkingReady
M.onTrafficStarted = onTrafficStarted
M.onTrafficStopped = onTrafficStopped
M.onPursuitAction = onPursuitAction
M.onVehicleParkingStatus = onVehicleParkingStatus
M.onVehicleSwitched = onVehicleSwitched
M.onOverhaulActive = onOverhaulActive
M.onOverhaulModulesActivated = onOverhaulModulesActivated
M.onClientStartMission = onClientStartMission
M.onWorldReadyState = onWorldReadyState
M.onSettingsChanged = onSettingsChanged
M.onUpdate = onUpdate

return M
