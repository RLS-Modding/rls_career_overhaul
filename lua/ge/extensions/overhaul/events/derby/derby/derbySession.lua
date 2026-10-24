-- Demolition derby session helpers: AI activation and clearing, stats, entry fee, player loaner, own-car damage and winner repair.
-- derby.lua creates one instance per load with its event state table, so a reloaded derby never shares state with the old load.

local capabilities = require("overhaul/lib/platform/capabilities")
local lib = {}

function lib.create(ownerServices)
  local derby = ownerServices
  local derbyState = ownerServices.derbyState
  local derbyUi = ownerServices.derbyUi
  local derbyDamageScoring = ownerServices.derbyDamageScoring

  local function activateAllAi()
    derby._log("I", "Activating AI chase behavior for " .. tostring(#derbyState.spawnedAiIds) .. " vehicles")
    for _, vehId in ipairs(derbyState.spawnedAiIds) do
      if not derbyState.eliminatedIds[vehId] then
        local vehObj = be:getObjectByID(vehId)
        if vehObj then vehObj:queueLuaCommand("input.event('parkingbrake', 0, 1)") end
        local targetId = derby.derbyAi.pickTargetForAi(vehId, true)
        derby.derbyAi.setAiChaseTarget(vehId, targetId)
        local info = derbyState.spawnedAiInfo[vehId]
        if info then
          info.retargetTimer = 0
          info.retargetInterval = derby.derbyRewards.getAiRetargetInterval(vehId)
        end
      end
    end
    derbyState.aiActivated = true
  end

  local function clearAllAi()
    for _, id in ipairs(derbyState.spawnedAiIds) do
      derby.derbyParticipants.despawnVehicle(id)
    end
    derbyState.spawnedAiIds = {}
    derbyState.spawnedAiInfo = {}
    derbyState.eliminatedIds = {}
    derbyState.playerPlacement = nil
    derbyState.totalParticipants = 0
    derbyState.nextPlacement = 0
    derbyState.eventElapsedTime = 0
    derbyState.rewardsSettled = false
    derbyState.lastRewardSummary = nil
    derbyState.playerInventoryId = nil
    derbyState.playerDerbyVehicleId = nil
    derbyState.originalPlayerVehicleId = nil
    derbyState.playerLoanerVehicleId = nil
    derbyState.stagedPlayerTransform = nil
    derbyState.firstAiEliminationElapsed = nil
    derbyState.eventFinishReason = nil
    derbyUi.clearDerbyCountdownWarnings()
    derbyDamageScoring.damageDealtById = {}
    derbyDamageScoring.lastRawDamageById = {}
    derbyDamageScoring.scoreDataById = {}
    derbyState.aiActivated = false
    derbyState.aiActivationTimer = 0
    derbyState.stagedAiCount = 0
    derbyState.activeWinnerRepairInsurance = false
  end

  local function recordDerbyStats(playerWasEliminated, playerPlace)
    if not overhaul_career_career.isActive() then return end
    local place = tonumber(playerPlace)
    if not place or place < 1 then place = math.max(1, derbyState.totalParticipants) end
    local elapsed = derby.getElapsedEventTime()
    local raceLabel = tostring(
      (derbyState.activeEventCfg and derbyState.activeEventCfg.label) or derbyState.activeEvent or "Demolition Derby"
    )
    local inventoryId = derbyState.playerInventoryId
    if not inventoryId then inventoryId = derby.resolveSessionInventoryFromSpawnId(be:getPlayerVehicleID(0)) end
    if not inventoryId then return end
    capabilities.get("raceRecords").updateDemoDerbyStats(inventoryId, raceLabel, {
      placement = place,
      eliminated = playerWasEliminated == true,
      survivalTime = elapsed,
      fastestEliminationTime = derbyState.firstAiEliminationElapsed,
    })
  end

  local function payEntryFee(modeCfg)
    local fee = math.max(0, math.floor(tonumber(modeCfg and modeCfg.entryFee) or 0))
    if fee <= 0 then return true end
    if not overhaul_career_career.isActive() then return true end
    return overhaul_career_economy_payment.pay({ money = { amount = fee, canBeNegative = false } }, require("overhaul/lib/finance/metadata").tag({
      label = "Demolition Derby Entry Fee",
      tags = { "gameplay", "fre", "demo", "entryFee" },
    }, "service", {vehicleRole = "player"}))
  end

  local function spawnPlayerLoaner(pos, rot)
    local poolKey = derbyState.activeEntryModeCfg and derbyState.activeEntryModeCfg.playerPool or "rlsDerby100"
    local pool = derby.derbyParticipants.getConfiguredVehiclePool(poolKey)
    if not pool or #pool == 0 then return nil end
    local spec = derby.derbyParticipants.normalizeVehiclePoolEntry(pool[math.random(1, #pool)])
    if not spec.model then return nil end
    local spawnOptions = { pos = pos, rot = rot, autoEnterVehicle = true }
    if spec.config then spawnOptions.config = spec.config end
    local ok, veh = pcall(function()
      return core_vehicles.spawnNewVehicle(spec.model, spawnOptions)
    end)
    if ok and veh and veh.getID then
      local vehId = veh:getID()
      derbyState.playerLoanerVehicleId = vehId
      derbyState.playerDerbyVehicleId = vehId
      derby.derbyAi.setVehicleStopped(vehId, false)
      return vehId
    end
    derby._log("W", "Failed to spawn derby loaner: " .. tostring(veh))
    return nil
  end

  local function persistOwnCarDamage()
    if
      derbyState.activeEntryModeCfg
      and derbyState.activeEntryModeCfg.persistDamage == true
      and derbyState.playerInventoryId
      and overhaul_career_career.isActive()
    then
      pcall(function()
        overhaul_career_repair_damageManager.saveDamageState(derbyState.playerInventoryId)
      end)
    end
  end

  local function resetPartConditionsToNew(partConditions)
    for _, condition in pairs(partConditions) do
      if type(condition) == "table" then
        condition.integrityValue = 1
        condition.integrityState = nil
        condition.visualValue = 1
        condition.visualState = nil
      end
    end
  end

  local function repairPartConditions(vehicleInfo)
    local repaired = false
    if overhaul_career_repair_insurance then
      repaired = pcall(function()
        overhaul_career_repair_insurance.repairPartConditions({
          partConditions = vehicleInfo.partConditions,
          paintRepair = true,
          inventoryId = derbyState.playerInventoryId,
        })
      end)
    end
    if not repaired then resetPartConditionsToNew(vehicleInfo.partConditions) end
  end

  local function findOwnCarObject()
    local vehId = overhaul_career_garage_inventory
        and overhaul_career_garage_inventory.getVehicleIdFromInventoryId(derbyState.playerInventoryId)
      or derbyState.playerDerbyVehicleId
    return vehId and be:getObjectByID(vehId) or nil
  end

  -- Tries an instant repair, then a respawn from the inventory, then pushes the part conditions to the live car.
  local function reloadRepairedVehicle(vehicleInfo)
    local didReload = false
    if overhaul_career_repair_insurance then
      didReload = pcall(function()
        overhaul_career_repair_insurance.startRepairInstant(vehicleInfo, function(success)
          if success == false then return end
          derby.saveCareerProgress("winner repair")
        end, true)
      end)
    end
    if not didReload and overhaul_career_garage_inventory then
      didReload = pcall(function()
        overhaul_career_garage_inventory.spawnVehicle(derbyState.playerInventoryId, 2, function(success)
          if success == false then return end
          derby.saveCareerProgress("winner repair")
        end)
      end)
    end
    if not didReload then
      local vehObj = findOwnCarObject()
      if vehObj and core_vehicleBridge then
        core_vehicleBridge.executeAction(vehObj, "initPartConditions", vehicleInfo.partConditions, 0, 1, 1)
      end
    end
  end

  local function finishRepair(vehicleInfo, partConditions)
    vehicleInfo.partConditions = partConditions or vehicleInfo.partConditions or {}
    repairPartConditions(vehicleInfo)
    if overhaul_career_repair_damageManager then
      pcall(function()
        overhaul_career_repair_damageManager.clearDamageState(derbyState.playerInventoryId)
      end)
    end
    if overhaul_career_garage_inventory then
      pcall(function()
        overhaul_career_garage_inventory.setVehicleDirty(derbyState.playerInventoryId)
      end)
    end
    reloadRepairedVehicle(vehicleInfo)
  end

  local function repairWinningOwnCar()
    if not derbyState.activeWinnerRepairInsurance then return false end
    if
      not (
        derbyState.activeEntryModeCfg
        and derbyState.activeEntryModeCfg.persistDamage == true
        and derbyState.playerInventoryId
      )
    then
      return false
    end
    if not overhaul_career_career.isActive() or not core_vehicleBridge then return false end
    local vehicles = overhaul_career_garage_inventory.getVehicles()
    local vehicleInfo = vehicles and vehicles[derbyState.playerInventoryId]
    if not vehicleInfo then return false end

    local vehObj = findOwnCarObject()
    if vehObj then
      core_vehicleBridge.requestValue(vehObj, function(response)
        finishRepair(vehicleInfo, response and response.result or vehicleInfo.partConditions)
      end, "getPartConditions")
    else
      finishRepair(vehicleInfo, vehicleInfo.partConditions)
    end
    ui_message("Your car has been fully repaired.", 5, "demoWinnerRepair", "check")
    return true
  end

  return {
    activateAllAi = activateAllAi,
    clearAllAi = clearAllAi,
    recordDerbyStats = recordDerbyStats,
    payEntryFee = payEntryFee,
    spawnPlayerLoaner = spawnPlayerLoaner,
    persistOwnCarDamage = persistOwnCarDamage,
    repairWinningOwnCar = repairWinningOwnCar,
  }
end

return lib
