-- Guards stock DSE against missing recovery wheels during initialization and reset.
-- Loaded from auto/ before physics; unloads immediately outside recovery spawns.

local M = {}

local isRecovery = false

local function controllerType(c)
  return tostring(c and c.typeName or "")
end

local function configIsRecovery()
  local cfg = v and v.config
  return cfg and cfg.isRecovery == true
end

local function hasIncompleteCornerWheels()
  if not controller or not controller.getAllControllers then return false end
  for _, c in pairs(controller.getAllControllers()) do
    if controllerType(c) == "drivingDynamics/sensors/vehicleData" then
      if c.isActive ~= true then return true end
      local access = c.wheelAccess
      if not access then return true end
      return not access.frontLeft or not access.frontRight or not access.rearLeft or not access.rearRight
    end
  end
  return false
end

local function disarmDrivingDynamics()
  if not controller or not controller.getAllControllers then return end
  local changed = false
  for _, c in pairs(controller.getAllControllers()) do
    if controllerType(c):find("drivingDynamics/", 1, true) then
      if c.shutdown then pcall(c.shutdown) end
      if c.updateFixedStep then
        c.updateFixedStep = nil
        changed = true
      end
      if c.update then
        c.update = nil
        changed = true
      end
      if c.updateGFX then
        c.updateGFX = nil
        changed = true
      end
    end
  end
  if changed and controller.cacheAllControllerFunctions then
    controller.cacheAllControllerFunctions()
  end
end

local function apply()
  if not isRecovery then return end
  if hasIncompleteCornerWheels() then
    disarmDrivingDynamics()
  end
end

function M.onExtensionLoaded()
  if not configIsRecovery() then
    return false
  end
  isRecovery = true
  apply()
  return true
end

function M.onReset()
  apply()
end

return M
