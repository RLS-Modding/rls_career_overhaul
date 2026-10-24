-- Business computer tuning: tuning data, wheel data extensions, tuning costs and the part customization preview adapters.
-- Reading order: vehicle guards, tuning data and carts, part adapters, wheel data extensions, job completion.
local installer = {}
local vehicleCommands = require("overhaul/lib/vehicles/vehicleCommands")

-- Each construction shares the vehicle helpers with that owner load.
function installer.new(inputs)
  local api = {}

  -- Vehicle guards and tuning data
  function api.requestVehicleTuningData(businessId, vehicleId)
    if inputs.parts.vehicles.shouldPreventVehicleOperation(businessId, vehicleId) then
      return false
    end

    return overhaul_career_business_vehicleTuning.requestVehicleTuningData(businessId, vehicleId)
  end

  function api.getVehicleTuningData(businessId, vehicleId)
    if inputs.parts.vehicles.shouldPreventVehicleOperation(businessId, vehicleId) then
      return nil
    end

    return overhaul_career_business_vehicleTuning.getVehicleTuningData(businessId, vehicleId)
  end

  function api.applyTuningToVehicle(businessId, vehicleId, tuningVars)
    if inputs.parts.vehicles.shouldPreventVehicleOperation(businessId, vehicleId) then
      return false
    end

    return overhaul_career_business_vehicleTuning.applyTuningToVehicle(businessId, vehicleId, tuningVars)
  end

  -- Wheel data extensions
  -- Vehicle id -> { businessId, vehicleId, key } for every vehicle that currently has the wheel data extension.
  local activeWheelDataVehicles = {}

  function api.loadWheelDataExtension(businessId, vehicleId)
    if not businessId or not vehicleId then
      return false
    end

    local vehicleObj = inputs.parts.vehicles.getBusinessVehicleObject(businessId, vehicleId)
    if not vehicleObj then
      return false
    end

    local vehId = vehicleObj:getID()
    local key = businessId .. "_" .. tostring(vehicleId)

    -- A vehicle that held this business's data before a switch loses it first.
    for oldVehId, entry in pairs(activeWheelDataVehicles) do
      if entry.key == key and oldVehId ~= vehId then
        local oldVehicleObj = be:getObjectByID(oldVehId)
        if oldVehicleObj then
          oldVehicleObj:queueLuaCommand([[
          if extensions.overhaulBusinessWheelData then
            extensions.]] .. vehicleCommands.call("overhaulBusinessWheelData", "disableWheelData") .. "\n" .. [[
          end
          extensions.unload("overhaulBusinessWheelData")
        ]])
        end
        activeWheelDataVehicles[oldVehId] = nil
      end
    end

    vehicleObj:queueLuaCommand([[
    if extensions.overhaulBusinessWheelData then
      extensions.]] .. vehicleCommands.call("overhaulBusinessWheelData", "disableWheelData") .. "\n" .. [[
    end
    extensions.unload("overhaulBusinessWheelData")
  ]])

    vehicleObj:queueLuaCommand([[
    extensions.load("overhaulBusinessWheelData")
    if extensions.overhaulBusinessWheelData then
      extensions.]] .. vehicleCommands.call("overhaulBusinessWheelData", "enableWheelData") .. "\n" .. [[
    end
  ]])

    activeWheelDataVehicles[vehId] = {
      businessId = businessId,
      vehicleId = vehicleId,
      key = key
    }

    return true
  end

  function api.unloadWheelDataExtension(businessId, vehicleId)
    if not businessId or not vehicleId then
      return false
    end

    local vehicleObj = inputs.parts.vehicles.getBusinessVehicleObject(businessId, vehicleId)
    if not vehicleObj then
      return false
    end

    local vehId = vehicleObj:getID()
    if not activeWheelDataVehicles[vehId] then
      return false
    end

    vehicleObj:queueLuaCommand([[
    if extensions.overhaulBusinessWheelData then
      extensions.]] .. vehicleCommands.call("overhaulBusinessWheelData", "disableWheelData") .. "\n" .. [[
    end
    extensions.unload("overhaulBusinessWheelData")
  ]])

    activeWheelDataVehicles[vehId] = nil

    return true
  end

  -- Wheel data arrives as JSON from the vehicle; anything unreadable becomes an empty table.
  function api.onVehicleWheelDataUpdate(vehId, dataStr)
    local vehicleInfo = activeWheelDataVehicles[vehId]
    if not vehicleInfo then
      return
    end

    local data = {}
    if dataStr and dataStr ~= "{}" then
      local success, decoded = pcall(function()
        return jsonDecode(dataStr)
      end)
      if success and decoded then
        data = decoded
      end
    end

    guihooks.trigger('businessComputer:onVehicleWheelData', {
      success = true,
      businessId = vehicleInfo.businessId,
      vehicleId = tonumber(vehicleInfo.vehicleId),
      wheelData = data
    })
  end

  -- Tuning costs and carts
  function api.calculateTuningCost(businessId, vehicleId, tuningVars, originalVars)
    return overhaul_career_business_vehicleTuning.calculateTuningCost(businessId, vehicleId, tuningVars,
      originalVars)
  end

  function api.getTuningShoppingCart(businessId, vehicleId, tuningVars, originalVars)
    return overhaul_career_business_vehicleTuning.getShoppingCart(businessId, vehicleId, tuningVars, originalVars)
  end

  function api.addTuningToCart(businessId, vehicleId, currentTuningVars, baselineTuningVars)
    if inputs.parts.vehicles.shouldPreventVehicleOperation(businessId, vehicleId) then
      return {}
    end

    return overhaul_career_business_vehicleTuning.addTuningToCart(businessId, vehicleId, currentTuningVars,
      baselineTuningVars)
  end

  function api.applyVehicleTuning(businessId, vehicleId, tuningVars, accountId)
    if inputs.parts.vehicles.shouldPreventVehicleOperation(businessId, vehicleId) then
      return false
    end

    return overhaul_career_business_vehicleTuning.applyVehicleTuning(businessId, vehicleId, tuningVars, accountId)
  end

  -- Part customization adapters
  function api.getAllRequiredParts(businessId, vehicleId, parts, cartParts)
    return overhaul_career_business_partCustomization.getAllRequiredParts(businessId, vehicleId, parts, cartParts)
  end

  function api.addPartToCart(businessId, vehicleId, currentCart, partToAdd, includeSourceCart)
    if inputs.parts.vehicles.shouldPreventVehicleOperation(businessId, vehicleId) then
      return currentCart or {}
    end

    if includeSourceCart then
      return overhaul_career_business_partCustomization.addPartToCart(businessId, vehicleId, currentCart, partToAdd, true)
    end
    return overhaul_career_business_partCustomization.addPartToCart(businessId, vehicleId, currentCart, partToAdd)
  end

  function api.initializePreviewVehicle(businessId, vehicleId)
    if inputs.parts.vehicles.shouldPreventVehicleOperation(businessId, vehicleId) then
      return false
    end

    return overhaul_career_business_partCustomization.initializePreviewVehicle(businessId, vehicleId)
  end

  function api.resetVehicleToOriginal(businessId, vehicleId)
    if inputs.parts.vehicles.shouldPreventVehicleOperation(businessId, vehicleId) then
      return false
    end

    return overhaul_career_business_partCustomization.resetVehicleToOriginal(businessId, vehicleId)
  end

  function api.applyPartsToVehicle(businessId, vehicleId, parts)
    if inputs.parts.vehicles.shouldPreventVehicleOperation(businessId, vehicleId) then
      return false
    end

    return overhaul_career_business_partCustomization.applyPartsToVehicle(businessId, vehicleId, parts)
  end

  function api.applyCartPartsToVehicle(businessId, vehicleId, parts, onComplete, transaction, operationId)
    if inputs.parts.vehicles.shouldPreventVehicleOperation(businessId, vehicleId) then
      if onComplete then
        onComplete(false)
      end
      return false
    end

    if operationId ~= nil then
      return overhaul_career_business_partCustomization.applyCartPartsToVehicle(businessId, vehicleId, parts, onComplete, transaction, operationId)
    end
    return overhaul_career_business_partCustomization.applyCartPartsToVehicle(businessId, vehicleId, parts, onComplete, transaction)
  end

  -- This separate protocol reports final completion, while the old methods keep their boolean acceptance contract.
  function api.applyBuildToVehicle(businessId, vehicleId, build, operationId)
    if inputs.parts.vehicles.shouldPreventVehicleOperation(businessId, vehicleId) then
      guihooks.trigger('businessComputer:onBuildOperationCompleted', {
        businessId = businessId, vehicleId = vehicleId, operationId = operationId,
        success = false, reason = 'Vehicle operation prevented', nonce = operationId,
      })
      return false
    end
    return overhaul_career_business_partCustomization.applyBuildToVehicle(businessId, vehicleId, build, operationId)
  end

  function api.cancelBuildOperation(businessId, vehicleId, operationId, requestId, nonce)
    return overhaul_career_business_partCustomization.cancelBuildOperation(businessId, vehicleId, operationId, requestId, nonce)
  end

  function api.installPartOnVehicle(businessId, vehicleId, partName, slotPath)
    if inputs.parts.vehicles.shouldPreventVehicleOperation(businessId, vehicleId) then
      return false
    end

    return overhaul_career_business_partCustomization.installPartOnVehicle(businessId, vehicleId, partName,
      slotPath)
  end

  -- Job completion
  function api.invalidateTuningShopJobCompletionIfNeeded(businessId, vehicleId)
    if not businessId or not vehicleId then
      return
    end

    local jobId = overhaul_career_business_fleet.getJobIdFromVehicle(businessId, vehicleId)
    if not jobId then
      return
    end

    if overhaul_career_business_tuningShop_tuningShop and overhaul_career_business_tuningShop_tuningShop.invalidateJobCompletionProof then
      overhaul_career_business_tuningShop_tuningShop.invalidateJobCompletionProof(businessId, jobId)
    end
  end

  return api
end

return installer
