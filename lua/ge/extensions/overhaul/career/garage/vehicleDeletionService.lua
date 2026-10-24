-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/vehicleDeletionService.lua (BeamNG 0.40).

-- Deletes flagged vehicles once they are far behind the camera, or when a mission starts.
-- Read flagging and the per-frame check first, then the mission and vehicle hooks; onUpdate is hooked only while a vehicle is flagged.

local M = {}

local deleteDistance = 100

local flaggedVehicles = {}

local function onExtensionLoaded()
  if not overhaul_career_career.isActive() then return false end
end

local function deleteVehicle(vehId)
  local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)
  if inventoryId then
    overhaul_career_garage_inventory.removeVehicleObject(inventoryId)
  else
    local obj = getObjectByID(vehId)
    if obj then
      obj:delete()
    end
  end
end

local vehPos = vec3()
local camPos = vec3()
local camDir = vec3()
local checkOnUpdateFunction
local function onUpdate()
  local vanished = false
  for vehId, data in pairs(flaggedVehicles) do
    local obj = getObjectByID(vehId)
    if not obj then
      flaggedVehicles[vehId] = nil
      vanished = true
    else
      camPos:set(core_camera.getPositionXYZ())
      vehPos:set(obj:getPositionXYZ())

      if camPos:distance(vehPos) > deleteDistance then
        camDir:set(core_camera.getForwardXYZ())
        local camToVeh = vehPos - camPos
        if camDir:dot(camToVeh) < 0 then
          data.callback()
          deleteVehicle(vehId)
        end
      end
    end
  end
  if vanished then checkOnUpdateFunction() end
end

checkOnUpdateFunction = function()
  if tableIsEmpty(flaggedVehicles) then
    if M.onUpdate then
      M.onUpdate = nil
      extensions.hookUpdate("onUpdate")
    end
  else
    if not M.onUpdate then
      M.onUpdate = onUpdate
      extensions.hookUpdate("onUpdate")
    end
  end
end

local function deleteFlaggedVehicles()
  for vehId, _ in pairs(flaggedVehicles) do
    deleteVehicle(vehId)
  end
end

local function flagForDeletion(vehId, callback)
  flaggedVehicles[vehId] = flaggedVehicles[vehId] or {}
  flaggedVehicles[vehId].delete = true
  flaggedVehicles[vehId].callback = callback or nop
  checkOnUpdateFunction()
end

local function clearFlags(vehId)
  flaggedVehicles[vehId] = nil
  checkOnUpdateFunction()
end

local function onClientStartMission()
  table.clear(flaggedVehicles)
  checkOnUpdateFunction()
end

local function onAnyMissionChanged(state, mission)
  if not (overhaul_career_career and overhaul_career_career.isActive()) then return end
  if mission and state == "started" then
    deleteFlaggedVehicles()
  end
end

local function onVehicleDestroyed(vehId)
  clearFlags(vehId)
end

M.flagForDeletion = flagForDeletion
M.clearFlags = clearFlags
M.deleteFlaggedVehicles = deleteFlaggedVehicles

M.onExtensionLoaded = onExtensionLoaded
M.onAnyMissionChanged = onAnyMissionChanged
M.onClientStartMission = onClientStartMission
M.onVehicleDestroyed = onVehicleDestroyed

return M