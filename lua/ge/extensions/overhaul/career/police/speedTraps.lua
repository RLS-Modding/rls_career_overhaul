-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Speed traps: fines, reputation penalties and leaderboards for the player's speed-trap passes.
-- Fork of stock lua/ge/extensions/career/modules/speedTraps.lua (BeamNG 0.40); read the helpers, then the trap handler and hooks.
local M = {}
-- SaveStore keys over the files this module writes today (metadata only).
require("overhaul/lib/save/store").registerKeys({
  {key = "police.speedTrapLeaderboards", owner = "overhaul_career_police_speedTraps", files = {"career/speedTrapLeaderboards/*.json"}, phase = "profile", required = true},
})

local policy = require('overhaul/lib/vehicles/policy')

local leaderboardFolder = "/career/speedTrapLeaderboards/"
local core_vehicles = require('core/vehicles')

M.dependencies = {'overhaul_integration_services_speedTraps', 'overhaul_integration_services_speedTrapLeaderboards'}

local function isHardcoreMode()
  return overhaul_career_economy_difficultyMode.isHardcoreMode() == true
end

local fines = {
  {overSpeed = 6.7056, fine = {money = {amount = 750, canBeNegative = true}}},
  {overSpeed = 11.176, fine = {money = {amount = 2000, canBeNegative = true}}},
}
local maxFine = {money = {amount = 2000, canBeNegative = true}}

-- Traffic restores pursuits without replaying start hooks after a Lua reload.
local function hasActiveSuspect()
  local playerId = be:getPlayerVehicleID(0)
  for id, vehicle in pairs(gameplay_traffic.getTrafficData()) do
    if id ~= playerId and vehicle.pursuit and (tonumber(vehicle.pursuit.mode) or 0) > 0 then return true end
  end
  return false
end

local function getFineFromSpeed(overSpeed)
  for _, fineInfo in ipairs(fines) do
    if overSpeed <= fineInfo.overSpeed then
      fineInfo.fine.money.amount = fineInfo.fine.money.amount
      return deepcopy(fineInfo.fine)
    end
  end
  return deepcopy(maxFine)
end

local function hasLicensePlate(inventoryId, vehicle)
  -- Owned vehicles have their plate part in the career part inventory. Work
  -- loaners are temporary inventory records, however, so their installed plate
  -- never appears there even though it is visible and readable in the world.
  for _, part in pairs(overhaul_career_parts_partInventory.getInventory() or {}) do
    if part.location == inventoryId and type(part.name) == "string" and string.find(part.name, "licenseplate") then
      return true
    end
  end

  local plateText = vehicle and core_vehicles.getVehicleLicenseText(vehicle)
  return type(plateText) == "string" and plateText:match("%S") ~= nil
end

-- Handles a triggered speed trap: validates context and vehicle, then issues fines or reputation penalties, adds tickets, plays audio, shows UI messages, and updates speed-trap leaderboards.
-- @param speedTrapData Table containing at least `speedLimit` (speed in meters per second) and `subjectID` (vehicle id) for the speed trap.
-- @param playerSpeed Player vehicle speed in meters per second.
-- @param overSpeed Amount by which `playerSpeed` exceeds the speed limit, in meters per second.
local function onSpeedTrapTriggered(speedTrapData, playerSpeed, overSpeed)
  if policy.query('speedImmune', be:getPlayerVehicleID(0)) then
    return
  end
  if not speedTrapData.speedLimit then 
    return 
  end
  local vehId = speedTrapData.subjectID
  if not vehId then
    return
  end

  local trafficVehicle = gameplay_traffic.getTrafficData()[be:getPlayerVehicleID(0)]
  local playerRole = trafficVehicle and trafficVehicle.role and trafficVehicle.role.name
  if playerRole == "police" and hasActiveSuspect() then
    return
  end

  if vehId ~= be:getPlayerVehicleID(0) then
    return
  end
  local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)

  local veh = getPlayerVehicle(0)
  local vehInfo = overhaul_career_garage_inventory.getVehicles()[inventoryId]

  local penaltyType
  if not inventoryId then
    penaltyType = "default"
  elseif hasLicensePlate(inventoryId, veh) then
    if vehInfo and (vehInfo.owned or vehInfo.loanType == "company" or vehInfo.loanType == "rental") then
      penaltyType = "default"
    elseif vehInfo and vehInfo.loanType == "work" then
      penaltyType = "workVehicle"
    end
  else
    penaltyType = "noLicensePlate"
  end

  if penaltyType == "default" then
    local fine = getFineFromSpeed(overSpeed)
    fine.money.amount = fine.money.amount * (isHardcoreMode() and 10 or 1)
    -- Scale fine by global economy index
    local globalIndex = overhaul_career_economy_globalEconomy.getGlobalIndex() or 1.0
    fine.money.amount = math.floor(fine.money.amount * globalIndex)
    local message = ""
    
    local speedStr = string.format("%.0f km/h (%.0f mph)", playerSpeed * 3.6, playerSpeed * 2.23694)
    local limitStr = string.format("%.0f km/h (%.0f mph)", speedTrapData.speedLimit * 3.6, speedTrapData.speedLimit * 2.23694)

    if playerRole == "police" then
      message = string.format("Traffic Violation (Officer Misconduct): \n - %q | Fine %d$\n - %s | (Limit: %s)\n - Abuse of power is not permitted", core_vehicles.getVehicleLicenseText(veh), fine.money.amount, speedStr, limitStr)
    else
      message = string.format("Traffic Violation (Speeding): \n - %q | Fine %d$\n - %s | (Limit: %s)", core_vehicles.getVehicleLicenseText(veh), fine.money.amount, speedStr, limitStr)
    end
    
    overhaul_career_economy_payment.pay(fine, require("overhaul/lib/finance/metadata").tag({label="ui.career.attributeLog.fineSpeeding", tags={"fine"}}, "fine", {vehicleRole = "player"}))
    ui_message(message, 10, "speedTrap")
    Engine.Audio.playOnce('AudioGui','event:>UI>Career>Speedcam_Snapshot')
    overhaul_career_garage_inventory.addTicket(inventoryId)
  elseif penaltyType == "noLicensePlate" then
    ui_message({txt="ui.career.speedTrap.noLicensePlateMessage", context={recordedSpeed = playerSpeed, speedLimit = speedTrapData.speedLimit}}, 10, 'speedTrap')
    Engine.Audio.playOnce('AudioGui','event:>UI>Career>Speedcam_Snapshot')

  elseif penaltyType == "workVehicle" then
    if vehInfo.owningOrganization then
      local fine = {}
      fine[vehInfo.owningOrganization .. "Reputation"] = {amount = 150, canBeNegative = true}
      overhaul_career_economy_payment.pay(fine, {label="ui.career.attributeLog.reputationCostSpeeding", tags={"fine"}})
      ui_message(string.format("Traffic Violation (Speeding): \n - %q | Reputation Loss: 150 (%s)", core_vehicles.getVehicleLicenseText(veh), vehInfo.owningOrganization), 10, "speedTrap")
    end
  end

  local highscore, leaderboard = overhaul_integration_services_speedTrapLeaderboards.addRecord(speedTrapData, playerSpeed, overSpeed, veh)

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
-- If the triggering vehicle is the player's, not speed-immune (a hired cab ride, an ambulance shift), and not a police officer evading pursuit, this will attempt to issue a fine (or report inability to issue if no license plate), charge payment, play the speedcam snapshot audio, and display the corresponding UI message.
-- @param speedTrapData Table containing trigger information; expects `subjectID` identifying the triggering vehicle.
-- @param playerSpeed Number representing the player's current speed.
local function onRedLightCamTriggered(speedTrapData, playerSpeed)
  if policy.query('speedImmune', be:getPlayerVehicleID(0)) then
    return
  end
  local vehId = speedTrapData.subjectID
  if not vehId then
    return
  end

  local trafficVehicle = gameplay_traffic.getTrafficData()[be:getPlayerVehicleID(0)]
  local playerRole = trafficVehicle and trafficVehicle.role and trafficVehicle.role.name
  if playerRole == "police" and hasActiveSuspect() then
    return
  end

  if vehId ~= be:getPlayerVehicleID(0) then
    return
  end
  local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)

  local veh = getPlayerVehicle(0)
  if not inventoryId or hasLicensePlate(inventoryId, veh) then
    local redLightGlobalIndex = overhaul_career_economy_globalEconomy.getGlobalIndex() or 1.0
    local fine = {money = {amount = math.floor(500 * (isHardcoreMode() and 2 or 1) * redLightGlobalIndex), canBeNegative = true}}
    local message = ""
    
    if playerRole == "police" then
      message = string.format("Traffic Violation (Officer Misconduct): \n - %q | Fine %d$\n - Abuse of power is not permitted", core_vehicles.getVehicleLicenseText(veh), fine.money.amount)
    else
      message = {
        txt = "ui.career.speedTrap.redLightMessage",
        context = {licensePlate = core_vehicles.getVehicleLicenseText(veh), fine = fine.money.amount}
      }
    end
    
    overhaul_career_economy_payment.pay(fine, require("overhaul/lib/finance/metadata").tag({label="ui.career.attributeLog.fineRedLight", tags={"fine"}}, "fine", {vehicleRole = "player"}))
    Engine.Audio.playOnce('AudioGui','event:>UI>Career>Speedcam_Snapshot')
    ui_message(message, 10, "speedTrap")
  else
    ui_message(_tr("ui.career.speedTrap.redLightNoLicensePlateMessage"), 10, "speedTrap")
  end
end

local function onExtensionLoaded()
  if not overhaul_career_career.isActive() then return false end
  local saveSlot, savePath = overhaul_career_saveSystem.getCurrentProfile()

  overhaul_integration_services_speedTrapLeaderboards.loadLeaderboards(savePath .. leaderboardFolder)
end

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  -- TODO maybe add option to only save file for current level
  overhaul_integration_services_speedTrapLeaderboards.saveLeaderboards(currentSavePath .. leaderboardFolder, true, writer)
end

M.onSpeedTrapTriggered = onSpeedTrapTriggered
M.onRedLightCamTriggered = onRedLightCamTriggered
M.onExtensionLoaded = onExtensionLoaded
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile

return M
