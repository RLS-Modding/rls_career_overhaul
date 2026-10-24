-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/career/modules/debug/vehicleSpawn.lua (BeamNG 0.40).

local M = {}
M.debugName = "Vehicle Spawn"
M.debugOrder = 12
M.dependencies = {"gameplay_sites_sitesManager"}

local im = ui_imgui
local ps = nil
local selectedLevel
local levelData = require("overhaul/lib/world/levelData")

-- poi list stuff
local function onGetRawPoiListForLevel(levelIdentifier, elements)
  if levelIdentifier ~= selectedLevel or not ps then
    --log("E","","No parking marker for debug!")
    return
  end
  table.insert(elements, {
    id = "debugVehicleSpawn",
    data = {type = "debugVehicleSpawn", id = "debugVehicleSpawn"},
    markerInfo = {
      parkingMarker = {path = ps:getPath(), pos = ps.pos, rot = ps.rot, scl = ps.scl },
    }
  })
end
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel

local function drawDebugMenu()
  local level = getCurrentLevelIdentifier()
  if selectedLevel ~= level then
    selectedLevel = level
    local config = level and jsonReadFile("/levels/" .. level .. "/overhaul/debug.json")
    local pose = config and config.version == 1 and levelData.resolveSpawn(config.debugSpawn, level)
    ps = pose and pose.spot
    if not ps then log("W", "vehicleSpawn", "Debug parking marker is not configured on this level.") end
    gameplay_rawPois.clear()
  end

  if im.Begin("Vehicle Spawn") then
    if im.Button("Spawn and rent a vehicle") then
      M.spawnVehicle("sunburst", "race_M", true)
    end
  end
  im.End()
end
M.drawDebugMenu = drawDebugMenu

local function spawnVehicle(model, config, addToInventory)
  extensions.load("util_stepHandler")
  local partConditionsDone = false
  local sequence = {
    -- fade to black
    util_stepHandler.makeStepFadeToBlack(),
    -- spawn vehicle and trigger initialization
    util_stepHandler.makeStepSpawnVehicleSimple(model, config,
      function(step, vehId)
        local vehObj = scenetree.findObjectById(vehId)
        core_vehicleBridge.executeAction(vehObj, 'initPartConditions', {}, 0, 1, 1)
        core_vehicleBridge.requestValue(vehObj,
          function(res)
            partConditionsDone = true
            if addToInventory then
              overhaul_career_garage_inventory.addVehicle(vehId, nil, {owned = false})
            end
          end
          , 'ping')
      end
      ),
    -- wait until initialization is done
    util_stepHandler.makeStepReturnTrueFunction(
      function() return partConditionsDone end
      ),
    util_stepHandler.makeStepFadeFromBlack()
  }
  -- start sequence
  util_stepHandler.startStepSequence(sequence)
end
M.spawnVehicle = spawnVehicle

local buttonOptions = {}
M.buttonPressed = function(i)
  buttonOptions[i]()
end

local function onPoiDetailPromptOpening(elemData, promptData)
  local valid = false
  for _, elem in ipairs(elemData) do
    if elem.type == "debugVehicleSpawn" then
      valid = true
    end
  end
  if not valid then return end

  local ret = {}
  ret.label = "Debug"
  ret.buttonText = "Open Debug Menu"
  ret.buttonFun = function()
    local buttons = {}
    table.clear(buttonOptions)


    table.insert(buttons, {
      label = "Spawn 'Rented' Vehicle",
      luaCallback = "overhaul_dev_debug_vehicleSpawn.spawnVehicle('sunburst','race_M')",
      enabled = true,
    })

    table.insert(buttons, {
      label = "Spawn 'Rented' Trailer",
      luaCallback = "overhaul_dev_debug_vehicleSpawn.spawnVehicle('boxutility','loaded_200')",
      enabled = true,
    })

    table.insert(buttons, {
      label = "Spawn Trailer and add to Inventory",
      luaCallback = "overhaul_dev_debug_vehicleSpawn.spawnVehicle('boxutility','loaded_200', true)",
      enabled = true,
    })


    local data = {text = "Debug Tester", buttons = buttons, class = "recoveryPrompt"}
    guihooks.trigger('showConfirmationDialog', data)
    overhaul_integration_services_markerInteraction.closeViewDetailPrompt(true)
  end
  table.insert(promptData, ret)
end

M.onPoiDetailPromptOpening = onPoiDetailPromptOpening

return M
