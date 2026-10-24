-- Transfer a recovery target into owned inventory after its fuel handoff.
return function(targetVehicle, persistence, releaseRuntime)
  local function promote(job, finalConditions, isCurrent, callback)
    local vehicle = job.vehicleId and getObjectByID(job.vehicleId)
    if not vehicle then
      callback(nil)
      return
    end
    -- Teleports, resets, and other recovery tools may replenish fuel. Enforce the reward rule again at handoff so the awarded vehicle always has one litre, regardless of how it reached the yard.
    targetVehicle.setOneLiter(job, vehicle, function()
      if not isCurrent() then return end
      local temporaryId = job.inventoryId
      local noFreeSlot = not overhaul_career_garage_inventory.hasFreeSlot()
      local newInventoryId = overhaul_career_garage_inventory.addVehicle(vehicle:getID(), nil, {
        owned = true,
        takesNoInventorySpace = noFreeSlot,
        skipPartConditionInit = true,
        finalPrice = 0
      })
      if not newInventoryId then
        callback(nil)
        return
      end
      local record = overhaul_career_garage_inventory.getVehicles()[newInventoryId]
      if record then
        record.partConditions = deepcopy(finalConditions or {})
        local finalMileage = tonumber(job.mileage) or 0
        for _, condition in pairs(finalConditions or {}) do
          finalMileage = math.max(finalMileage, tonumber(condition.odometer) or 0)
        end
        record.year = job.year
        record.mileage = finalMileage
        record.purchasePrice = 0
        record.rewardSource = "Off-Road Recovery"
        record.offroadRecoveryContract = nil
        record.offroadRecoveryJobId = nil
        if record.config then record.config.isRecovery = nil end
        if noFreeSlot then record.takesNoInventorySpace = true end
      end
      if temporaryId and overhaul_career_garage_inventory.getVehicles()[temporaryId] then
        overhaul_career_garage_inventory.removeVehicle(temporaryId)
      end
      -- Must register explicitly as uninsured. Without this, a recycled numeric inventory id can inherit a previous vehicle's insurance.json entry.
      extensions.hook("onOverhaulVehicleAddedToInventory", {
        inventoryId = newInventoryId,
        purchaseData = {insuranceId = -1},
      })
      releaseRuntime(vehicle:getID())
      local pathName = persistence.sessionDamageFilePath(job.id)
      if pathName and FS:fileExists(pathName) then FS:removeFile(pathName) end
      -- Callback first: finalize's isCurrent() still expects the temporary inventoryId.
      callback(newInventoryId)
      job.inventoryId = nil
    end, isCurrent)
  end
  return promote
end
