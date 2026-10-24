-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/debug/vehicleDebug.lua (BeamNG 0.40).
local M = {}
local im = ui_imgui
M.debugOrder = 2
M.debugName = "Vehicles"

M.drawDebugMenu = function()
  if im.Button("Add this Vehicle as new vehicle to inventory") then
    local inventoryId = overhaul_career_garage_inventory.addVehicle(be:getPlayerVehicleID(0))
    overhaul_career_garage_inventory.enterVehicle(inventoryId)
  end

  if im.Button("Respawn Current Vehicle") then
    overhaul_career_garage_inventory.debugRespawnCurrentVehicle()
  end

  local currentVehicle = overhaul_career_garage_inventory.getCurrentVehicle()

  if currentVehicle then
    im.Text("Current Vehicle: " .. currentVehicle .. " (" .. overhaul_career_garage_inventory.getVehicles()[currentVehicle].model .. ")")
  end

  local vehicleToSell
  if im.BeginChild1("Owned Vehicles", im.ImVec2(0, 150), true) then
    im.Text("Change to one of your vehicles")

    for id, data in pairs(overhaul_career_garage_inventory.getVehicles()) do
      if im.Button("id " .. id .. " (" .. data.model .. ")") then
        overhaul_career_garage_inventory.enterVehicle(id)
      end
      im.SameLine()

      if im.Button(string.format("sell ##%d",  id)) then
        vehicleToSell = id
      end
    end
  end
  im.EndChild()

  if vehicleToSell then
    overhaul_career_garage_inventory.sellVehicleFromInventory(vehicleToSell)
  end
end

return M