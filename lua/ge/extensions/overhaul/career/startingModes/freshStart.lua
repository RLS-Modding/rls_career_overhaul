-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Fork of stock lua/ge/extensions/career/startingModes/freshStart.lua (BeamNG 0.40).
-- Starting mode: 10000 starting capital, with the player placed in front of the dealership.

return {
  id = "freshStart",
  order = 200,
  tier = "minor",
  image = "images/career/start_fresh.jpg",
  initPlayerAttributes = function(playerAttributes)
    playerAttributes.setAttributes({money = 10000}, {label = "Starting Capital", tags = {"startingFunds"}, finance = {category = "starting_funds", vehicleRelated = false}})
  end,
  setupInventory = function()
    local levelData = require("overhaul/lib/world/levelData")
    local level = getCurrentLevelIdentifier()
    local config = level and jsonReadFile("/levels/" .. level .. "/overhaul/stockStartingModes.json")
    local mode = config and config.version == 1 and config.modes and config.modes.freshStart
    local pose = mode and levelData.resolveSpawn(mode.playerSpawn, level)
    if not pose then
      log("W", "freshStart", "Fresh-start placement is not configured on this level.")
      return false
    end
    spawn.safeTeleport(getPlayerVehicle(0), pose.pos, pose.rot)
    gameplay_walk.setRot(mode.walkingDirection and vec3(mode.walkingDirection) or pose.rot * vec3(0, 1, 0), vec3(0, 0, 1))
    return true
  end,
}
