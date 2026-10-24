-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Fork of stock lua/ge/extensions/career/startingModes/apmOnboarding.lua (BeamNG 0.40).
-- Starting mode: no starting capital, with onboarding placement authored by the current level.

return {
  id = "apmOnboarding",
  order = 100,
  tier = "major",
  image = "images/career/start_apm.jpg",
  initPlayerAttributes = function(playerAttributes)
    playerAttributes.setAttributes({money = 0}, {label = "Starting Capital", tags = {"startingFunds"}, finance = {category = "starting_funds", vehicleRelated = false}})
  end,
  setupInventory = function()
    local levelData = require("overhaul/lib/world/levelData")
    local level = getCurrentLevelIdentifier()
    local config = level and jsonReadFile("/levels/" .. level .. "/overhaul/stockStartingModes.json")
    local mode = config and config.version == 1 and config.modes and config.modes.apmOnboarding
    local playerPose = mode and levelData.resolveSpawn(mode.playerSpawn, level)
    local vehicle = mode and mode.vehicle
    local vehiclePose = vehicle and levelData.resolveSpawn(vehicle.spawn, level)
    if not playerPose or not vehiclePose or not vehicle.model or not vehicle.config then
      log("W", "apmOnboarding", "Onboarding placement is not configured on this level.")
      return false
    end
    local setup = gameplay_tutorial_setup
    setup.vehicleSetupComplete = false
    setup.loadingScreenFadeoutComplete = false
    local options = sanitizeVehicleSpawnOptions(vehicle.model, {
      config = vehicle.config, pos = vehiclePose.pos, rot = vehiclePose.rot,
      licenseText = "TUTORIAL", vehicleName = "TutorialVehicle"
    })
    options.autoEnterVehicle = false
    local veh = core_vehicles.spawnNewVehicle(vehicle.model, options)
    if not veh then return false end
    setup.tutorialVehicleId = veh:getID()
    core_vehicleBridge.requestValue(veh, function()
      core_vehicleBridge.executeAction(veh, "setGearboxMode", "realistic")
      core_vehicleBridge.executeAction(veh, "setFreeze", true)
      core_vehicleBridge.executeAction(veh, "setIgnitionLevel", 0)
      gameplay_walk.setWalkingMode(true, playerPose.pos, playerPose.rot, true)
      setup.vehicleSetupComplete = true
    end, "mainController", "gearboxMode")
    return true
  end,
}
