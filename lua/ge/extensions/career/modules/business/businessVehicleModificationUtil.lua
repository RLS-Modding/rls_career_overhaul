local M = {}

M.dependencies = {
  'career_career',
  'career_saveSystem',
  'core_jobsystem'
}

local function finalizePurchase(businessId, vehicleId, callback)
  if not businessId or not vehicleId then
    if callback then callback(false) end
    return
  end

  -- Put away the vehicle (removes the object)
  career_modules_business_businessInventory.putAwayVehicle(businessId)

  -- Wait a frame or so to ensure cleanup, then pull it back out (respawns with new config)
  core_jobsystem.create(function(job)
    job.sleep(0.1) -- Small delay to ensure despawn is processed
    
    local businessType = "tuningShop" -- Common default for this context

    local success = career_modules_business_businessInventory.pullOutVehicle(businessType, businessId, vehicleId)
    
    if success then
      -- After successful respawn, clear caches to ensure fresh data
      career_modules_business_businessPartCustomization.clearPreviewVehicle(businessId)
      
      -- Re-initialize the preview vehicle immediately to ensure we have the correct config cached
      -- This ensures that subsequent UI requests (like requestVehiclePartsTree) see the updated custom config
      career_modules_business_businessPartCustomization.initializePreviewVehicle(businessId, vehicleId)
      
      career_modules_business_businessVehicleTuning.clearTuningDataCache()
      -- Save the game state
      career_saveSystem.saveCurrent()
      
      if callback then callback(true) end
    else
      if callback then callback(false) end
    end
  end)
end

M.finalizePurchase = finalizePurchase

return M

