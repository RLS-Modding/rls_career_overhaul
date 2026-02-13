-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local leaderboardFolder = "/career/speedTrapLeaderboards/"
local core_vehicles = require('core/vehicles')

M.dependencies = {'career_career', 'gameplay_speedTraps', 'gameplay_traffic'}

-- Determine whether the player's vehicle is using the ambulance paint design.
-- @return `true` if the player's vehicle has the ambulance paint design, `false` otherwise.
local function isInAmbulance()
  if gameplay_ambulance and gameplay_ambulance.isInAmbulance then
    return gameplay_ambulance.isInAmbulance()
  end
  return false
end
local fines = {
  {overSpeed = 6.7056, fine = {money = {amount = 750, canBeNegative = true}}},
  {overSpeed = 11.176, fine = {money = {amount = 2000, canBeNegative = true}}},
}
local maxFine = {money = {amount = 2000, canBeNegative = true}}
local playerPursuiting = false

local function getFineFromSpeed(overSpeed)
  for _, fineInfo in ipairs(fines) do
    if overSpeed <= fineInfo.overSpeed then
      fineInfo.fine.money.amount = fineInfo.fine.money.amount
      return deepcopy(fineInfo.fine)
    end
  end
  return deepcopy(maxFine)
end

local function hasLicensePlate(inventoryId)
  for partId, part in pairs(career_modules_partInventory.getInventory()) do
    if part.location == inventoryId then
      if string.find(part.name, "licenseplate") then
        return true
      end
    end
  end
end

-- Handles a triggered speed trap: validates context and vehicle, then issues fines or reputation penalties, adds tickets, plays audio, shows UI messages, and updates speed-trap leaderboards.
-- @param speedTrapData Table containing at least `speedLimit` (speed in meters per second) and `subjectID` (vehicle id) for the speed trap.
-- @param playerSpeed Player vehicle speed in meters per second.
-- @param overSpeed Amount by which `playerSpeed` exceeds the speed limit, in meters per second.
local function onSpeedTrapTriggered(speedTrapData, playerSpeed, overSpeed)
  if gameplay_cab and gameplay_cab.inCab() then
    return
  end
  if isInAmbulance() then
    return
  end
  if not speedTrapData.speedLimit then 
    return 
  end
  local vehId = speedTrapData.subjectID
  if not vehId then
    return
  end

  local playerRole = gameplay_traffic.getTrafficData()[be:getPlayerVehicleID(0)].role.name
  if playerPursuiting and playerRole == "police" then
    return
  end

  if vehId ~= be:getPlayerVehicleID(0) then
    return
  end
  local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)

  local veh = getPlayerVehicle(0)
  local vehInfo = career_modules_inventory.getVehicles()[inventoryId]

  local penaltyType
  if not inventoryId then
    penaltyType = "default"
  elseif hasLicensePlate(inventoryId) then
    if vehInfo.owned then
      penaltyType = "default"
    elseif vehInfo.loanType == "work" then
      penaltyType = "workVehicle"
    end
  else
    penaltyType = "noLicensePlate"
  end

  if penaltyType == "default" then
    local fine = getFineFromSpeed(overSpeed)
    fine.money.amount = fine.money.amount * (career_modules_hardcore.isHardcoreMode() and 10 or 1)
    -- Scale fine by global economy index
    local globalIndex = career_modules_globalEconomy and career_modules_globalEconomy.getGlobalIndex() or 1.0
    fine.money.amount = math.floor(fine.money.amount * globalIndex)
    local message = ""
    
    local speedStr = string.format("%.0f km/h (%.0f mph)", playerSpeed * 3.6, playerSpeed * 2.23694)
    local limitStr = string.format("%.0f km/h (%.0f mph)", speedTrapData.speedLimit * 3.6, speedTrapData.speedLimit * 2.23694)

    if playerRole == "police" then
      message = string.format("Traffic Violation (Officer Misconduct): \n - %q | Fine %d$\n - %s | (Limit: %s)\n - Abuse of power is not permitted", core_vehicles.getVehicleLicenseText(veh), fine.money.amount, speedStr, limitStr)
    else
      message = string.format("Traffic Violation (Speeding): \n - %q | Fine %d$\n - %s | (Limit: %s)", core_vehicles.getVehicleLicenseText(veh), fine.money.amount, speedStr, limitStr)
    end
    
    career_modules_payment.pay(fine, {label="Fine for speeding", tags={"fine"}})
    ui_message(message, 10, "speedTrap")
    Engine.Audio.playOnce('AudioGui','event:>UI>Career>Speedcam_Snapshot')
    career_modules_inventory.addTicket(inventoryId)
  elseif penaltyType == "noLicensePlate" then
    ui_message({txt="ui.career.speedTrap.noLicensePlateMessage", context={recordedSpeed = playerSpeed, speedLimit = speedTrapData.speedLimit}}, 10, 'speedTrap')
    Engine.Audio.playOnce('AudioGui','event:>UI>Career>Speedcam_Snapshot')

  elseif penaltyType == "workVehicle" then
    if vehInfo.owningOrganization then
      local fine = {}
      fine[vehInfo.owningOrganization .. "Reputation"] = {amount = 10, canBeNegative = true}
      career_modules_payment.pay(fine, {label="Reputation cost for speeding", tags={"fine"}})
      ui_message(string.format("Traffic Violation (Speeding): \n - %q | Reputation Loss: 10 (%s)", core_vehicles.getVehicleLicenseText(veh), vehInfo.owningOrganization), 10, "speedTrap")
    end
  end

  local highscore, leaderboard = gameplay_speedTrapLeaderboards.addRecord(speedTrapData, playerSpeed, overSpeed, veh)

  local message
  if highscore then
    if leaderboard[2] then
      message = {txt="ui.freeroam.speedTrap.newRecord", context={recordedSpeed = playerSpeed, previousSpeed = leaderboard[2].speed}}
    else
      message = {txt="ui.freeroam.speedTrap.newRecordNoOld", context={recordedSpeed = playerSpeed}}
    end
  else
    message = {txt="ui.freeroam.speedTrap.noNewRecord", context={recordedSpeed = playerSpeed, recordSpeed = leaderboard[1].speed}}
  end

  ui_message(message, 10, 'speedTrapRecord')
end

-- Handles a red-light camera trigger for the player vehicle, applying fines or showing messages as appropriate.
-- If the triggering vehicle is the player's, not in a cab or ambulance, and not a police officer evading pursuit, this will attempt to issue a fine (or report inability to issue if no license plate), charge payment, play the speedcam snapshot audio, and display the corresponding UI message.
-- @param speedTrapData Table containing trigger information; expects `subjectID` identifying the triggering vehicle.
-- @param playerSpeed Number representing the player's current speed.
local function onRedLightCamTriggered(speedTrapData, playerSpeed)
  if gameplay_cab and gameplay_cab.inCab() then
    return
  end
  if isInAmbulance() then
    return
  end
  local vehId = speedTrapData.subjectID
  if not vehId then
    return
  end

  local playerRole = gameplay_traffic.getTrafficData()[be:getPlayerVehicleID(0)].role.name
  if playerPursuiting and playerRole == "police" then
    return
  end

  if vehId ~= be:getPlayerVehicleID(0) then
    return
  end
  local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)

  local veh = getPlayerVehicle(0)
  if not inventoryId or hasLicensePlate(inventoryId) then
    local redLightGlobalIndex = career_modules_globalEconomy and career_modules_globalEconomy.getGlobalIndex() or 1.0
    local fine = {money = {amount = math.floor(500 * (career_modules_hardcore.isHardcoreMode() and 2 or 1) * redLightGlobalIndex), canBeNegative = true}}
    local message = ""
    
    if playerRole == "police" then
      message = string.format("Traffic Violation (Officer Misconduct): \n - %q | Fine %d$\n - Abuse of power is not permitted", core_vehicles.getVehicleLicenseText(veh), fine.money.amount)
    else
      message = string.format("Traffic Violation (Failure to stop at Red Light): \n - %q | Fine %d$", core_vehicles.getVehicleLicenseText(veh), fine.money.amount)
    end
    
    career_modules_payment.pay(fine, {label="Fine for driving over a red light", tags={"fine"}})
    Engine.Audio.playOnce('AudioGui','event:>UI>Career>Speedcam_Snapshot')
    ui_message(message, 10, "speedTrap")
  else
    ui_message(string.format("Traffic Violation (Failure to stop at Red Light): \n - No license plate detected | Fine could not be issued"), 10, "speedTrap")
  end
end

local function onExtensionLoaded()
  if not career_career.isActive() then return false end
  local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()

  gameplay_speedTrapLeaderboards.loadLeaderboards(savePath .. leaderboardFolder)
end

local function onSaveCurrentSaveSlot(currentSavePath)
  -- TODO maybe add option to only save file for current level
  gameplay_speedTrapLeaderboards.saveLeaderboards(currentSavePath .. leaderboardFolder, true)
end

local function onPursuitAction(id, pursuitData)
  local playerVehicleId = be:getPlayerVehicleID(0)

  if id ~= playerVehicleId then
      if pursuitData.type == "start" then
          playerPursuiting = true
      elseif pursuitData.type == "evade" or pursuitData.type == "reset" then
          playerPursuiting = false
      elseif pursuitData.type == "arrest" then
          playerPursuiting = false
      end
  end
end

M.onSpeedTrapTriggered = onSpeedTrapTriggered
M.onRedLightCamTriggered = onRedLightCamTriggered
M.onExtensionLoaded = onExtensionLoaded
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

return M