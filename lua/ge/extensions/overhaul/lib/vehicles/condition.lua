-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Vehicle crash repair and maintenance sanitization with separate field ownership.
-- Crash repairs preserve fuel; disabling maintenance clears only its powertrain failures.
local capabilities = require('overhaul/lib/platform/capabilities')
local partConditionCompatibility = require('overhaul/lib/parts/conditionCompatibility')

local clearIntegrityStateKeepFuel = require('overhaul/lib/parts/repairCondition').clearIntegrityStateKeepFuel

local M = {}

local function repairPartConditions(data)
  if not data.partConditions then return end
  if data.paintRepair == nil then data.paintRepair = true end

  for partPath, partCondition in pairs(data.partConditions) do
    if partCondition.integrityValue then
      if partCondition.integrityValue == 0 then

        local inventoryPart = nil
        if data.inventoryId then
          local partId = overhaul_career_parts_partInventory.getPartPathToPartIdMap()[data.inventoryId][partPath]
          inventoryPart = overhaul_career_parts_partInventory.getInventory()[partId]
          inventoryPart.repairCount = inventoryPart.repairCount or 0
          inventoryPart.repairCount = inventoryPart.repairCount + 1
          local vehicle = overhaul_career_garage_inventory.getVehicles()[data.inventoryId]
          vehicle.changedSlots[inventoryPart.containingSlot] = true
        end

        -- Only crash-broken parts lose their damaged finish.
        if partCondition.visualState then
          if partCondition.visualState.paint and partCondition.visualState.paint.originalPaints then
            if data.paintRepair then
              partCondition.visualState = {paint = {originalPaints = partCondition.visualState.paint.originalPaints}}
            else
              local paintLayerCount = tableSize(partCondition.visualState.paint.originalPaints)
              partCondition.visualState = {paint = {originalPaints = {}}}
              for index = 1, paintLayerCount do
                partCondition.visualState.paint.originalPaints[index] = capabilities.get("paintFinishes").getPrimerColor()
              end

              if inventoryPart then
                inventoryPart.primered = true
              end
            end
            partCondition.visualState.paint.odometer = 0
          else
            -- Without saved original paints, discard the damaged visual state.
            partCondition.visualState = nil
            partCondition.visualValue = 1
          end
        end
      end

      clearIntegrityStateKeepFuel(partCondition)
      partCondition.integrityValue = 1
    end
  end
end

local function isMaintenanceFailureType(categoryName, failureType)
  if type(categoryName) ~= "string" or type(failureType) ~= "string" then
    return false
  end
  return string.find(failureType, categoryName, 1, true) ~= nil or string.find(failureType, "break", 1, true) ~= nil
end

local function looksLikeMaintenancePowertrainFailure(categoryName, partCondition)
  local powertrainState = partCondition and partCondition.integrityState and partCondition.integrityState.powertrain
  if type(powertrainState) ~= "table" then
    return false
  end

  for _, deviceState in pairs(powertrainState) do
    if type(deviceState) == "table" then
      if categoryName == "engine" then
        if deviceState.isBroken == true or type(deviceState.thermals) == "table" or deviceState.damageFrictionCoef ~= nil or
            deviceState.damageDynamicFrictionCoef ~= nil or deviceState.damageIdleAVReadErrorRangeCoef ~= nil then
          return true
        end
      elseif categoryName == "radiator" then
        if deviceState.radiatorDamage ~= nil or deviceState.coolantMass ~= nil then
          return true
        end
      elseif categoryName == "transmission" then
        if deviceState.isBroken == true or deviceState.damageGearRatioChangeRateCoef ~= nil or
            deviceState.damageClutchFreePlayCoef ~= nil or deviceState.damageLockTorqueCoef ~= nil or
            deviceState.damageFrictionCoef ~= nil or deviceState.synchroWear ~= nil or
            deviceState.clutchPermanentlyDamaged ~= nil then
          return true
        end
      end
    end
  end

  return false
end

local function sanitizeMaintenanceConditionEntry(categoryName, partCondition, hasMaintenanceMarker)
  if type(partCondition) ~= "table" or not hasMaintenanceMarker then
    return false
  end

  local didSanitize = false
  local integrityValue = tonumber(partCondition.integrityValue)
  if integrityValue ~= nil and integrityValue < 1 then
    partCondition.integrityValue = 1
    didSanitize = true
  end

  if type(partCondition.integrityState) == "table" and partCondition.integrityState.powertrain then
    local powertrainState = partCondition.integrityState.powertrain
    partCondition.integrityState.powertrain = nil
    if not next(partCondition.integrityState) then
      partCondition.integrityState = nil
    elseif type(powertrainState) == "table" then
      local healthyState = {}
      for deviceName in pairs(powertrainState) do healthyState[deviceName] = 1 end
      partCondition.integrityState.powertrain = healthyState
    end
    didSanitize = true
  end

  return didSanitize
end

local function sanitizeMaintenancePartConditionsForVehicle(vehicleData, partConditions)
  partConditionCompatibility.normalizeEmptyIntegrityStates(partConditions)
  if type(vehicleData) ~= "table" or type(partConditions) ~= "table" then
    return partConditions
  end

  local maintenanceState = vehicleData.maintenanceState
  if type(maintenanceState) ~= "table" or type(maintenanceState.categories) ~= "table" then
    return partConditions
  end

  for categoryName, categoryState in pairs(maintenanceState.categories) do
    if type(categoryState) == "table" then
      local didSanitizeCategory = false
      local shouldPreservePersistentDamage = categoryState.persistentCareerDamage == true
      local candidatePartIds = {}

      if categoryState.rootPartId then
        table.insert(candidatePartIds, categoryState.rootPartId)
      end

      if type(categoryState.cachedPartIds) == "table" then
        for _, candidatePartId in ipairs(categoryState.cachedPartIds) do
          if candidatePartId ~= categoryState.rootPartId then
            table.insert(candidatePartIds, candidatePartId)
          end
        end
      end

      for _, partId in ipairs(candidatePartIds) do
        local partCondition = partConditions[partId]
        local looksLikeFailure = isMaintenanceFailureType(categoryName, categoryState.lastFailureType) or
                                     looksLikeMaintenancePowertrainFailure(categoryName, partCondition)
        if not shouldPreservePersistentDamage and sanitizeMaintenanceConditionEntry(categoryName, partCondition, looksLikeFailure) then
          partConditions[partId] = partCondition
          didSanitizeCategory = true
        end
      end

      if didSanitizeCategory and not shouldPreservePersistentDamage then
        categoryState.lastFailureType = nil
        categoryState.lastFailureTime = 0
      end
    end
  end

  return partConditionCompatibility.normalizeEmptyIntegrityStates(partConditions)
end

M.repairCrashDamage = repairPartConditions
M.isMaintenanceFailureType = isMaintenanceFailureType
M.looksLikeMaintenancePowertrainFailure = looksLikeMaintenancePowertrainFailure
M.sanitizeMaintenanceConditionEntry = sanitizeMaintenanceConditionEntry
M.sanitizeMaintenancePartConditionsForVehicle = sanitizeMaintenancePartConditionsForVehicle

return M
