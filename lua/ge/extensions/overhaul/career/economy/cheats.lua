-- Cheats mode for the current career: Freeroam+ and explicit cheat careers turn it on, and it is saved per career.
-- Read mode resolution and persistence, public toggles, then ordered recovery and vehicle commands.
local M = {}
local capabilities = require("overhaul/lib/platform/capabilities")
local vehicleCommands = require("overhaul/lib/vehicles/vehicleCommands")

local isCheatsMode = false
local saveFile = "cheats.json"
local saveData = {}

-- Freeroam+ implies cheats even when the create flag was lost before the career started.
local function resolveInitialCheatsMode()
  if overhaul_career_career.cheatsMode then
    return true
  end
  local pendingMode = overhaul_career_career.pendingCareerStartMode
  if type(pendingMode) == "string" and string.lower(pendingMode) == "freeroam" then
    return true
  end
  local options = overhaul_career_career.startingOptions
  if type(options) == "table" then
    if options.cheatsMode == true then
      return true
    end
    local startMode = options.careerStartMode or options.startMode
    if type(startMode) == "string" and string.lower(startMode) == "freeroam" then
      return true
    end
  end
  return false
end

local function onOverhaulActive(active)
  if not active then return false end
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  saveData = savePath and jsonReadFile(savePath .. "/career/rls_career/" .. saveFile) or {}

  if not next(saveData) then
    saveData = {
      cheatsMode = resolveInitialCheatsMode()
    }
  elseif saveData.cheatsMode ~= true and resolveInitialCheatsMode() then
    -- A Freeroam+ create can write the seed file as false before the live flag is visible.
    saveData.cheatsMode = true
  end

  if saveData.cheatsMode == nil then
    saveData.cheatsMode = false
  end

  isCheatsMode = saveData.cheatsMode == true
  extensions.hook("onOverhaulCheatsModeChanged", isCheatsMode)
end

local function onOverhaulSaveCurrentProfile(currentSavePath)
  overhaul_career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/rls_career/" .. saveFile, saveData, true)
end

-- Only turns cheats on; passing false does nothing.
function M.enableCheatsMode(enabled)
  if enabled and not isCheatsMode then
    isCheatsMode = true
    saveData.cheatsMode = true
    extensions.hook("onOverhaulCheatsModeChanged", isCheatsMode)
  end
end

function M.isCheatsMode()
  return isCheatsMode or false
end

-- Stock recover resets body meshes, but tires and maintenance reassert afterward, so clear them here.
local function onStopRecovering()
  if not isCheatsMode then
    return
  end

  local veh = getPlayerVehicle(0)
  if not veh then
    return
  end

  local vehId = veh:getID()
  local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)

  if inventoryId then
    capabilities.get("recoveredVehicleTires").onCheatVehicleRecovered(inventoryId)
    capabilities.get("recoveredVehicleMaintenance").onCheatVehicleRecovered(inventoryId)
    capabilities.get("recoveredVehicleDamage").onCheatVehicleRecovered(inventoryId)
  end

  local command = "if overhaulMaintenance then "
    .. vehicleCommands.call("overhaulMaintenance", "debugResetCategory", "engine") .. "; "
    .. vehicleCommands.call("overhaulMaintenance", "debugResetCategory", "radiator") .. "; "
    .. vehicleCommands.call("overhaulMaintenance", "debugResetCategory", "transmission") .. " end; "
    .. "obj:requestReset(RESET_PHYSICS); extensions.load('overhaulDamageState'); "
    .. "if overhaulDamageState then " .. vehicleCommands.call("overhaulDamageState", "reset") .. " end; "
    .. "if not overhaulTires then extensions.load('overhaulTires') end; "
    .. "if overhaulTires and overhaulTires.applyFreshAndInflate then "
    .. vehicleCommands.call("overhaulTires", "applyFreshAndInflate") .. " end"
  veh:queueLuaCommand(command)
end

M.onOverhaulActive = onOverhaulActive
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.onStopRecovering = onStopRecovering

return M
