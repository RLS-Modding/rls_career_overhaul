-- Ambulance calls, patient transport, driving quality and paramedic rewards.
-- Read admission and config, state, call phases, update, lifecycle and public hooks.
local recordCall = require("overhaul/lib/progression/logbookFeed").register("overhaul.ambulanceCallCompleted", {
  title = "Ambulance call completed", label = "Jobs", icon = "checkmark"
}, "jobs/ambulance.lua")

local M = {}
local shared = {}
M.dependencies = {'overhaul_vehicles_passengerOccupants'}
local sitesManager = require('overhaul/lib/world/sitesManager').sitesManager
local capabilities = require('overhaul/lib/platform/capabilities')
local levelData = require('overhaul/lib/world/levelData')
local facilityRole = require('overhaul/lib/logistics/facilityRole')

local core_groundMarkers = require('core/groundMarkers')
local jobSkillRewards = require('overhaul/lib/jobs/skillRewards')

-- Config ----------------------------------------------------------------------------------------

local PARAMEDIC_REWARD_CONFIG_PATH = "gameplay/overhaul/paramedic/rewardConfig.json"
local PARAMEDIC_SKILL_PATH_IDS = {"careerSkills-emergency", "emergency"}
local SUBCONTRACTOR_MIN_PARAMEDIC_SKILL_LEVEL = 20
local STANDARD_GRAVITY_MS2 = 9.81
-- Re-arm below the lower acceleration threshold so one bump counts once.
local ROUGH_EVENT_THRESHOLD_G = 1.2
local ROUGH_EVENT_REARM_RATIO = 0.8
local PLAYER_OWNED_AMBULANCE_DECLINE_MSG = "Player owned ambulance requires level 20"
local paramedicRewardConfig = nil

local function getParamedicRewardConfig()
  if paramedicRewardConfig ~= nil then
    return paramedicRewardConfig
  end
  paramedicRewardConfig = jobSkillRewards.loadRewardConfig(PARAMEDIC_REWARD_CONFIG_PATH)
  return paramedicRewardConfig
end

local function getParamedicSkillContext()
  local skillConfig = jobSkillRewards.getSkillConfig(getParamedicRewardConfig())
  local attributeKey = jobSkillRewards.getAttributeKey(skillConfig, "careerSkills-emergency")
  local skillLevel = jobSkillRewards.getSkillLevel(attributeKey, PARAMEDIC_SKILL_PATH_IDS)
  return skillConfig, attributeKey, skillLevel
end

local function isLoanerVehicle(vehId)
  if not vehId or not (overhaul_career_career and overhaul_career_career.isActive()) then
    return false
  end
  local vehicleLoans = capabilities.get("vehicleLoans")
  if not vehicleLoans or not vehicleLoans.getLoaningOrgsOfVehicle then return false end
  local loaningOrgs = vehicleLoans.getLoaningOrgsOfVehicle(vehId)
  return loaningOrgs ~= nil and next(loaningOrgs) ~= nil
end

local function isOffroadRecoveryTarget(vehId)
  return overhaul_jobs_recovery.blocksJobShifts(vehId) == true
end

local function canStartParamedicShift(vehId, silent)
  if isOffroadRecoveryTarget(vehId) then
    return false
  end
  local emp = overhaul_career_work_employment
  if emp and emp.blocksRoleplay() then
    if not silent then
      ui_message("Finish your company shift before starting paramedic work.", 6, "warning")
    end
    return false
  end
  if isLoanerVehicle(vehId) then
    return true
  end
  if not jobSkillRewards.isPlayerOwnedInventoryVehicle(vehId) then
    return true
  end
  local _, _, skillLevel = getParamedicSkillContext()
  if skillLevel >= SUBCONTRACTOR_MIN_PARAMEDIC_SKILL_LEVEL then
    return true
  end
  if not silent then
    ui_message(PLAYER_OWNED_AMBULANCE_DECLINE_MSG, 8, "error", "error")
  end
  return false
end

local config = {
  pickupDuration = 10,
  dropoffDuration = 6,
  stopSettleDelay = 2.5,
  minDelay = 20,
  maxDelay = 90,

  stopRadius = 8,

  baseFare = 1500,
  timeBonusPerSec = 10,
  roughRidePenaltyFactor = 0.1,
  maxPenaltyFactor = 0.75,
  callCompletionXpBase = 20,
  callCompletionRoughReference = 8,
  -- Org/skill thresholds are logistics-sized; scale progression so calls feel rewarding.
  progressionMultiplier = 20,

  maxStopSpeed = 0.5
}

local function findPaintDesign(node)
  if not node or not node.children then
    return nil
  end
  if node.children.paint_design then
    return node.children.paint_design
  end
  for _, child in pairs(node.children) do
    local result = findPaintDesign(child)
    if result then
      return result
    end
  end
  return nil
end

local function isAmbulancePaintDesign(vehicleId)
  local id = vehicleId
  if not id then
    local playerVehicle = be:getPlayerVehicle(0)
    if not playerVehicle then
      return false
    end
    id = playerVehicle:getId()
  end
  local vehData = core_vehicle_manager.getVehicleData(id)
  local partsTree = vehData and vehData.config and vehData.config.partsTree
  local paintDesign = findPaintDesign(partsTree)
  local chosenPaintDesign = paintDesign and paintDesign.chosenPartName
  return chosenPaintDesign and type(chosenPaintDesign) == "string" and chosenPaintDesign:lower():find("ambulance") ~= nil
end

local currentFare = nil
local state = "ready"
local locationData, locationMap
local destinationSpawns = {}
local pickupTimer = nil
local pickupMessageShown = false
local missionTriggeredForVehicle = false
local stopMonitorActive = false
local stopSettleTimer = 0

-- Cached ambulance state (updated on load and vehicle switch)
local inAmbulance = false
local disposeVehiclePolicy -- set where the policy is registered, near the exports
local pausedAmbulanceId = nil
local currentLoanerCut = 0

M.initDelay = nil
M.initDelayDuration = nil
M.delayTimer = nil
M.delayDuration = nil
M.minDelay = config.minDelay
M.maxDelay = config.maxDelay

M.rideData = {}

local function calculateLoanerCut(vehId)
  if not vehId then return 0 end

  if not (overhaul_career_career and overhaul_career_career.isActive()) then
    return 0
  end

  local vehicleLoans = capabilities.get("vehicleLoans")
  if not vehicleLoans or not vehicleLoans.getLoaningOrgsOfVehicle then return 0 end
  local loaningOrgs = vehicleLoans.getLoaningOrgsOfVehicle(vehId)
  if not loaningOrgs or not next(loaningOrgs) then
    return 0
  end

  local totalCut = 0
  for organizationId, _ in pairs(loaningOrgs) do
    local organization = overhaul_world_organizations.getOrganization(organizationId)
    if organization and organization.reputation and organization.reputationLevels then
      local level = organization.reputation.level
      local levelIndex = level + 2
      if organization.reputationLevels[levelIndex] and organization.reputationLevels[levelIndex].loanerCut then
        local orgCut = organization.reputationLevels[levelIndex].loanerCut.value or 0.5
        totalCut = totalCut + orgCut
      end
    end
  end

  return math.min(totalCut, 1.0)
end

-- Start Ride ----------------------------------------------------------------------
shared.startRide = function(fare)
  if not fare then
    return
  end
  currentFare = fare
  local playerVehicle = be:getPlayerVehicle(0)
  if not playerVehicle then

    return
  end

  state = "pickup"
  pickupTimer = 0
  pickupMessageShown = false

  currentFare.playerStartPos = playerVehicle:getPosition()

  M.rideData = {}
  M.rideData.roughEvents = 0

  if fare.pickup and fare.pickup.pos then
    core_groundMarkers.setPath(fare.pickup.pos, { clearPathOnReachingTarget = true })
  end

  ui_message("Medical assistance needed! Proceed to the pickup.", 6, "info", "info")
end

-- Generate Fare ----------------------------------------------------------------------
local function loadLocations()
  local mapId = levelData.currentMapKey()
  if mapId ~= locationMap then
    locationData, locationMap = nil, mapId
    destinationSpawns = {}
  end
  if locationData ~= nil then return locationData or nil end
  local data = mapId and jsonReadFile(levelData.assetPath(mapId, "overhaul/ambulance.json"))
  if type(data) ~= "table" or data.version ~= 1 or type(data.pickupSites) ~= "table"
      or type(data.destinations) ~= "table" then
    log("W", "ambulance", "Ambulance calls disabled: missing or invalid level configuration")
    locationData = false
    return nil
  end
  locationData = data
  return data
end

local function collectPickupSpots(data)
  local validPickups = {}
  for _, file in ipairs(data.pickupSites) do
    local path = levelData.assetPath(locationMap, file)
    local sites = path and sitesManager().loadSites(path)
    for _, spot in pairs(sites and sites.parkingSpots and sites.parkingSpots.objects or {}) do
      if spot.pos and not spot.missing then table.insert(validPickups, spot) end
    end
  end
  return validPickups
end

local function collectDestinations(data, playerVehicle, emp)
  local destinations = {}
  local vehicleLoans = capabilities.get("vehicleLoans")
  local loaningOrgs = vehicleLoans and vehicleLoans.getLoaningOrgsOfVehicle(playerVehicle:getId())
  for _, definition in ipairs(data.destinations) do
    if type(definition) == "table" and type(definition.sitesFile) == "string"
        and type(definition.parkingSpotName) == "string" then
      if destinationSpawns[definition] == nil then
        destinationSpawns[definition] = levelData.resolveSpawn(definition, locationMap) or false
      end
      local spawn = destinationSpawns[definition]
      local binding = {organizationId = definition.organizationId, facilityId = definition.facilityId}
      if binding.organizationId == nil and not binding.facilityId then binding.organizationId = data.organizationId end
      local shift = binding.organizationId == nil and not binding.facilityId
        and emp and emp.isRoleplayShift() and emp.getUiState()
      local employer = shift and {facilityId = shift.homeFacId, organizationId = shift.employerOrgId}
      local orgId = facilityRole.operator("paramedic", loaningOrgs, binding, employer)
      if spawn and orgId then
        destinations[#destinations + 1] = {spawn = spawn, definition = definition, organizationId = orgId}
      end
    end
  end
  return destinations
end

shared.generateFare = function(emp)
  local data = loadLocations()
  if not data then return nil end
  local playerVehicle = be:getPlayerVehicle(0)
  if not playerVehicle then
    return nil
  end

  local validPickups = collectPickupSpots(data)
  if #validPickups == 0 then
    log("W", "ambulance", "Ambulance calls disabled: no configured pickup spots available")
    return nil
  end
  local destinations = collectDestinations(data, playerVehicle, emp)
  if #destinations == 0 then
    log("W", "ambulance", "Ambulance calls disabled: no configured hospital/operator available")
    return nil
  end
  local pickupSpot = validPickups[math.random(#validPickups)]
  local destination = destinations[#destinations == 1 and 1 or math.random(#destinations)]

  return {
    pickup = {
      pos = pickupSpot.pos
    },
    destination = {
      pos = destination.spawn.pos,
      facilityId = destination.definition.facilityId,
      parkingSpotName = destination.definition.parkingSpotName,
    },
    organizationId = destination.organizationId,
    baseFare = config.baseFare,
    passengers = 1,
    passengerType = "STANDARD",
    passengerTypeName = "Standard",
    passengerDescription = "Patient"
  }
end

-- Start Next Mission ----------------------------------------------------------------------
shared.startNextMission = function()
  local ambulanceMultiplier = (overhaul_career_economyAdjuster and overhaul_career_economyAdjuster.getSectionMultiplier("ambulance")) or 1.0
  if ambulanceMultiplier == 0 then
    ui_message("Ambulance missions are currently disabled.", 5, "error", "error")

    return
  end

  currentFare = nil
  state = "ready"
  pickupTimer = nil
  pickupMessageShown = false
  core_groundMarkers.resetAll()
  local emp = overhaul_career_work_employment
  if emp and emp.isEndingDay() then return end
  local fare = shared.generateFare(emp)
  if fare then
    shared.startRide(fare)
  else
    ui_message("No valid ambulance missions available!", 5, "info", "info")
  end
end

-- Update Markers & State ----------------------------------------------------------------------

-- Sensor Data Handling ----------------------------------------------------------------------
local function updateSensorData()
  if not currentFare or state ~= "enRoute" then
    return
  end

  local vehicle = be:getPlayerVehicle(0)
  if not vehicle then return end

  vehicle:queueLuaCommand([[
        local sensors = require('sensors')
        if sensors then
            local gx, gy, gz = sensors.gx or 0, sensors.gy or 0, sensors.gz or 0
            local gx2, gy2, gz2 = sensors.gx2 or 0, sensors.gy2 or 0, sensors.gz2 or 0
            obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(]] .. require('overhaul/lib/vehicles/callbacks').open('ambulanceSensorData', {owner = 'ambulance', vehId = vehicle:getID()}) .. [[, 'ambulanceSensorData', gx..','..gy..','..gz..','..gx2..','..gy2..','..gz2))
        end
    ]])
end

local function processSensorData(gx, gy, gz, gx2, gy2, gz2)
  local grav = STANDARD_GRAVITY_MS2
  M.rideData.currentSensorData = {
    gx = gx / grav, gy = gy / grav, gz = gz / grav,
    gx2 = gx2 / grav, gy2 = gy2 / grav, gz2 = gz2 / grav,
    timestamp = os.time()
  }

  if not M.rideData.roughEvents then
    M.rideData.roughEvents = 0
  end

  local peak = math.max(math.abs(gx2 / grav), math.abs(gy2 / grav), math.abs(gz2 / grav))
  if M.rideData.isRoughEventActive then
    if peak < ROUGH_EVENT_THRESHOLD_G * ROUGH_EVENT_REARM_RATIO then
      M.rideData.isRoughEventActive = false
    end
  elseif peak > ROUGH_EVENT_THRESHOLD_G then
    M.rideData.roughEvents = M.rideData.roughEvents + 1
    M.rideData.isRoughEventActive = true
  end
end

-- Patient pickup -----------------------------------------------------------------
local function finishPatientPickup()
  state = "enRoute"
  overhaul_vehicles_passengerOccupants.setPassengers('ambulance', be:getPlayerVehicleID(0), 1)
  core_groundMarkers.resetAll()
  if currentFare.destination and currentFare.destination.pos then
    core_groundMarkers.setPath(currentFare.destination.pos, { clearPathOnReachingTarget = true })
  end
  ui_message("Patient picked up, now enRoute", 8, "info", "info")
  pickupTimer = nil
  stopMonitorActive = false
  stopSettleTimer = 0
  M.rideData.roughEvents = 0
end

local function handlePickup(dtSim, vehiclePos, speed)
  if not currentFare or not currentFare.pickup then return end

  local distToPickup = (vehiclePos - currentFare.pickup.pos):length()

  if distToPickup > config.stopRadius then
    pickupTimer = 0
    stopMonitorActive = false
    stopSettleTimer = 0
    return
  end

  if speed > config.maxStopSpeed then
    ui_message("Come to a complete stop before securing the patient.", 2, "info", "info")
    pickupTimer = nil
    stopMonitorActive = false
    stopSettleTimer = 0
    return
  end

  if not stopMonitorActive then
    stopMonitorActive = true
    stopSettleTimer = 0
    ui_message("Hold still to secure the patient...", config.stopSettleDelay, "info", "info")
    return
  end

  stopSettleTimer = stopSettleTimer + (dtSim or 0)
  if stopSettleTimer < config.stopSettleDelay then
    return
  end

  if not pickupMessageShown then
    pickupMessageShown = true
    currentFare.elapsedTime = 0
  end
  if not pickupTimer then
    pickupTimer = 0
  end
  pickupTimer = pickupTimer + (dtSim or 0)

  local totalTime = config.pickupDuration
  if pickupTimer < totalTime then
    local remaining = math.ceil(math.max(0, totalTime - pickupTimer))
    ui_message(string.format("Securing patient... %ds", remaining), 1, "info", "info")
    return
  end

  finishPatientPickup()
end

-- Patient dropoff ----------------------------------------------------------------
local function patientDropoffReady(dtSim, vehiclePos, speed)
  if not currentFare or not currentFare.destination then return false end

  currentFare.elapsedTime = (currentFare.elapsedTime or 0) + (dtSim or 0)
  local distToDropoff = (vehiclePos - currentFare.destination.pos):length()

  if distToDropoff > config.stopRadius then -- Increased radius slightly
    currentFare.dropoffTimer = nil
    stopMonitorActive = false
    stopSettleTimer = 0
    return false
  end

  -- Must be fully stopped before dropoff
  if speed > config.maxStopSpeed then
    ui_message("Come to a complete stop to offload the patient.", 2, "info", "info")
    currentFare.dropoffTimer = nil
    stopMonitorActive = false
    stopSettleTimer = 0
    return false
  end

  if not stopMonitorActive then
    stopMonitorActive = true
    stopSettleTimer = 0
    ui_message("Hold still to offload the patient...", 2.5, "info", "info")
    return false
  else
    stopSettleTimer = stopSettleTimer + (dtSim or 0)
    if stopSettleTimer < config.stopSettleDelay then
      return false
    end
  end

  -- extra dropoff dwell after settling
  currentFare.dropoffTimer = (currentFare.dropoffTimer or 0) + (dtSim or 0)
  local dropoffDuration = config.dropoffDuration
  if currentFare.dropoffTimer < dropoffDuration then
    local remaining = math.ceil(math.max(0, dropoffDuration - currentFare.dropoffTimer))
    ui_message(string.format("Stabilizing patient... %ds", remaining), 1, "info", "info")
    return false
  end

  return true
end

local function calculatePatientPay()
  local distToPickup = (currentFare.playerStartPos - currentFare.pickup.pos):length()
  local distToHospital = (currentFare.pickup.pos - currentFare.destination.pos):length()
  local distanceKM = (distToPickup + distToHospital) / 1000
  local basePayout = math.floor(config.baseFare * distanceKM)

  local ambulanceMultiplier = (overhaul_career_economyAdjuster and overhaul_career_economyAdjuster.getSectionMultiplier("ambulance")) or 1.0
  basePayout = math.floor(basePayout * ambulanceMultiplier + 0.5)

  local timeBonus = 0
  if currentFare.elapsedTime then
    local expectedTime = math.max(60, distanceKM * 60) -- 60 sec/km, minimum 60 sec
    if currentFare.elapsedTime < expectedTime then
      local timeSaved = expectedTime - currentFare.elapsedTime
      timeBonus = math.floor(timeSaved * config.timeBonusPerSec)
      timeBonus = math.min(timeBonus, math.floor(basePayout * 0.5)) -- Cap at 50% of base
    end
  end

  local roughEvents = M.rideData.roughEvents or 0
  local penalty = math.floor(roughEvents * config.roughRidePenaltyFactor * 100)
  local maxPenalty = math.floor((basePayout + timeBonus) * config.maxPenaltyFactor)
  penalty = math.min(penalty, maxPenalty)
  local finalPayout = math.max(0, basePayout + timeBonus - penalty)

  local skillConfig, paramedicAttributeKey, paramedicSkillLevel = getParamedicSkillContext()
  local moneyBonus = jobSkillRewards.getJobMoneyBonusMultiplier(skillConfig, paramedicSkillLevel)
  local progressionPayout = finalPayout
  finalPayout = math.floor(finalPayout * moneyBonus + 0.5)

  return distanceKM, basePayout, timeBonus, penalty, finalPayout, skillConfig, paramedicAttributeKey, progressionPayout, roughEvents
end

local function recordPatientProgress(basePayout, finalPayout, skillConfig, progressionPayout, roughEvents)
  -- Employment-only cash: escrow on shift, otherwise no freelance payout.
  local grossPayout = finalPayout
  local emp = overhaul_career_work_employment
  local escrowRoleplay = emp and emp.shouldEscrowRoleplayPay()
  finalPayout = 0

  local displayBasePayout = basePayout
  local progressionMult = config.progressionMultiplier or 1

  local repGain = math.floor(progressionPayout / 100) * progressionMult
  local baseSkillXp = jobSkillRewards.getSkillRewardAmount(skillConfig, progressionPayout)
  local roughReference = math.max(1, config.callCompletionRoughReference or 8)
  local smoothMult = 1 + math.max(0, 1 - roughEvents / roughReference)
  local completionXp = math.max(1, math.floor((config.callCompletionXpBase or 20) * smoothMult + 0.5))
  local paramedicSkillXp = (baseSkillXp + completionXp) * progressionMult
  local surgeText = (overhaul_career_economy_activityHeat and overhaul_career_economy_activityHeat.formatSurgeBonusText("ambulance")) or ""
  local escrowKeep = 0
  if escrowRoleplay then
    escrowKeep = emp.depositRoleplayEscrow("Paramedic call", grossPayout) or 0
  end
  return escrowRoleplay, displayBasePayout, progressionMult, repGain, completionXp, paramedicSkillXp, surgeText, escrowKeep
end

local function settlePatientCall(escrowRoleplay, escrowKeep, timeBonus, penalty, surgeText, repGain, paramedicAttributeKey, paramedicSkillXp)
  if overhaul_career_career and overhaul_career_career.isActive() then
    local orgId = currentFare.organizationId
    local reputationAttribute = orgId .. "Reputation"
    local rewardData = {
      money = {
        amount = 0
      },
      [reputationAttribute] = {
        amount = repGain
      },
    }
    jobSkillRewards.addJobSkillXpToRewardData(rewardData, paramedicAttributeKey, paramedicSkillXp)
    overhaul_career_economy_difficultyMode.scalePaymentRewardData(rewardData, {includeMoney = false})
    local payLabel
    if escrowRoleplay then
      payLabel = string.format("$%d added to your shift wages. Paid when you End Day. | Time bonus: $%d | Rough ride penalty: -$%d", escrowKeep, timeBonus, penalty) .. surgeText
    else
      payLabel = "Clock in at the station for call pay" .. surgeText
    end
    local skillXpByAttribute = {}
    for attribute, entry in pairs(rewardData) do
      if attribute ~= "money" and attribute ~= reputationAttribute then
        skillXpByAttribute[attribute] = entry.amount
      end
    end
    local paid, problem = overhaul_career_economy_payment.payout(require("overhaul/lib/finance/metadata").tagPayout({
      amount = rewardData.money.amount,
      orgId = orgId,
      rep = rewardData[reputationAttribute].amount,
      xp = skillXpByAttribute,
      label = payLabel,
      tags = {"transport", "ambulance", "gameplay"},
      fullReward = true,
    }, "activity:ambulance", {vehicleRole = "player"}))
    if paid ~= true then
      -- Preserve completion on refusal; replaying drop-off would repeat the wage deposit too.
      log("W", "ambulance", "Call payout refused: " .. tostring(problem))
    elseif not escrowRoleplay then
      recordCall({detail = currentFare.destination and currentFare.destination.name or "Patient delivered", money = rewardData.money.amount})
    end
  end

end

local function presentPatientDelivery(escrowRoleplay, distanceKM, displayBasePayout, surgeText, timeBonus, penalty, escrowKeep, repGain, completionXp, progressionMult)
  local msg
  if escrowRoleplay then
    msg = string.format(
      "Patient delivered!\nDistance: %.2f km\nBase: $%d%s\nTime Bonus: $%d\nPenalty: -$%d\n$%d added to your shift wages. Paid when you End Day.\nReputation +%d\nBonus XP: +%d",
      distanceKM, displayBasePayout, surgeText, timeBonus, penalty, escrowKeep, repGain, completionXp * progressionMult)
  else
    msg = string.format(
      "Patient delivered!\nDistance: %.2f km\nBase: $%d%s\nTime Bonus: $%d\nPenalty: -$%d\nClock in at the station for call pay.\nReputation +%d\nBonus XP: +%d",
      distanceKM, displayBasePayout, surgeText, timeBonus, penalty, repGain, completionXp * progressionMult)
  end
  ui_message(msg, 6, "info", "info")

end

local function finishPatientDropoff()
  currentFare.dropoffTimer = nil
  state = "completed"
  overhaul_vehicles_passengerOccupants.clear('ambulance')
  core_groundMarkers.resetAll()
  stopMonitorActive = false
  stopSettleTimer = 0
  if not M.delayTimer then
    M.delayTimer = 0
    M.delayDuration = math.random(M.minDelay, M.maxDelay)
  end
end

local function handleDropoff(dtSim, vehiclePos, speed)
  if not patientDropoffReady(dtSim, vehiclePos, speed) then return end
  local distanceKM, basePayout, timeBonus, penalty, finalPayout, skillConfig, paramedicAttributeKey, progressionPayout, roughEvents = calculatePatientPay()
  local escrowRoleplay, displayBasePayout, progressionMult, repGain, completionXp, paramedicSkillXp, surgeText, escrowKeep = recordPatientProgress(
    basePayout, finalPayout, skillConfig, progressionPayout, roughEvents)
  settlePatientCall(escrowRoleplay, escrowKeep, timeBonus, penalty, surgeText, repGain, paramedicAttributeKey, paramedicSkillXp)
  presentPatientDelivery(escrowRoleplay, distanceKM, displayBasePayout, surgeText, timeBonus, penalty, escrowKeep, repGain, completionXp, progressionMult)
  finishPatientDropoff()
end

shared.updateMarkers = function(_dtReal, dtSim, _dtRaw)
  if not currentFare then
    return
  end
  local playerVehicle = be:getPlayerVehicle(0)
  if not playerVehicle then
    return
  end
  local vehiclePos = playerVehicle:getPosition()
  local velocity = playerVehicle:getVelocity()
  local speed = velocity:length()

  if state == "enRoute" then
    updateSensorData()
  end

  if state == "pickup" then
    handlePickup(dtSim, vehiclePos, speed)
  elseif state == "enRoute" then
    handleDropoff(dtSim, vehiclePos, speed)
  elseif state == "completed" and M.delayTimer then
    M.delayTimer = M.delayTimer + (dtSim or 0)
    if M.delayTimer >= M.delayDuration then
      core_groundMarkers.resetAll()
      shared.startNextMission()
      -- Only set state to ready if startNextMission didn't change it (e.g. early return)
      if state == "completed" then
        state = "ready"
      end
      M.delayTimer = nil
      M.delayDuration = nil
      missionTriggeredForVehicle = false
    end
  end
end

-- Extension Loaded ----------------------------------------------------------------------
local function onExtensionLoaded()
  inAmbulance = false
  currentLoanerCut = 0
  local vehicle = be:getPlayerVehicle(0)
  if vehicle then
    local vehId = vehicle:getId()
    if isAmbulancePaintDesign(vehId) and canStartParamedicShift(vehId, true) then
      inAmbulance = true
      currentLoanerCut = calculateLoanerCut(vehId)
    end
  end
  ui_message("Ambulance module loaded. Waiting for 911 vehicle...", 3, "info", "info")
end

-- Extension Unloaded (Cleanup) ----------------------------------------------------------------------
local function resetSessionState()
  if overhaul_vehicles_passengerOccupants then overhaul_vehicles_passengerOccupants.clear('ambulance') end
  pausedAmbulanceId = nil
  currentFare = nil
  state = "ready"
  locationData, locationMap = nil, nil
  destinationSpawns = {}
  pickupTimer = nil
  pickupMessageShown = false
  missionTriggeredForVehicle = false
  stopMonitorActive = false
  stopSettleTimer = 0
  M.rideData = {}
  inAmbulance = false
  currentLoanerCut = 0

  M.initDelay = nil
  M.initDelayDuration = nil
  M.delayTimer = nil
  M.delayDuration = nil

  core_groundMarkers.resetAll()
end

local function onExtensionUnloaded()
  disposeVehiclePolicy()
  resetSessionState()
end

local function onClientEndMission()
  resetSessionState()
end

local function onOverhaulActive(active)
  if active == false then resetSessionState() end
end

-- Vehicle Switched ----------------------------------------------------------------------
-- Updates the cached ambulance paint design state when the player switches vehicles.
local function onVehicleSwitched(oldId, newId, player)
  if player and player ~= 0 then return end
  if oldId ~= newId then overhaul_vehicles_passengerOccupants.clear('ambulance') end
  local emp = overhaul_career_work_employment
  if pausedAmbulanceId and emp and emp.isRoleplayShift() then
    if newId ~= pausedAmbulanceId then
      if isAmbulancePaintDesign(newId) and canStartParamedicShift(newId) then
        M.cancelActiveCall("ambulance replaced")
        inAmbulance = true
        currentLoanerCut = calculateLoanerCut(newId)
        missionTriggeredForVehicle = false
        ui_message("Replacement ambulance ready. A new call will arrive shortly.", 6, "info")
        return
      end
      inAmbulance = false
      return
    end
    if emp.blocksRoleplay and emp.blocksRoleplay() then return end
    pausedAmbulanceId = nil
    inAmbulance = true
    if state == 'enRoute' then
      overhaul_vehicles_passengerOccupants.setPassengers('ambulance', newId, 1)
    end
    currentLoanerCut = calculateLoanerCut(newId)
    local target = currentFare and (state == "pickup" and currentFare.pickup or state == "enRoute" and currentFare.destination)
    if target and target.pos then
      core_groundMarkers.setPath(target.pos, { clearPathOnReachingTarget = true })
    end
    ui_message("Call resumed.", 4, "info")
    return
  end
  if oldId ~= newId and inAmbulance and missionTriggeredForVehicle
    and emp and emp.isRoleplayShift() then
    pausedAmbulanceId = oldId
    inAmbulance = false
    ui_message("Call paused. Return to your ambulance to continue; use End Day in Phone > Employment to finish.", 8, "info")
    return
  end
  if not isAmbulancePaintDesign(newId) then
    inAmbulance = false
    currentLoanerCut = 0
    return
  end
  if canStartParamedicShift(newId) then
    inAmbulance = true
    currentLoanerCut = calculateLoanerCut(newId)
  else
    inAmbulance = false
    currentLoanerCut = 0
  end
end

-- Ambulance duty skips fines and pursuit while retaining recorded offenses.
disposeVehiclePolicy = require('overhaul/lib/vehicles/policy').register('ambulance', {
  speedImmune = function() return inAmbulance end,
  pursuitImmune = function(vehId)
    if not inAmbulance then return false end
    local playerVehicle = be:getPlayerVehicle(0)
    return playerVehicle ~= nil and vehId == playerVehicle:getId()
  end,
}, 'loaded')

-- Public API ----------------------------------------------------------------------
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onOverhaulBeforeSetProfile = resetSessionState
M.onClientEndMission = onClientEndMission
M.onOverhaulActive = onOverhaulActive
M.onVehicleSwitched = onVehicleSwitched
M.isAmbulancePaintDesign = isAmbulancePaintDesign
M.canUsePersonalVehicle = function(vehId)
  return isAmbulancePaintDesign(vehId) and canStartParamedicShift(vehId)
end
M.updateSensorData = updateSensorData
M.receiveSensorData = processSensorData

-- Returns the cached ambulance state (updated on load and vehicle switch)
function M.isInAmbulance()
  return inAmbulance
end

function M.isAmbulanceJobActive()
  return currentFare ~= nil and state ~= "ready"
end

function M.hasPatientOnboard()
  return currentFare ~= nil and state == "enRoute"
end

function M.getEmploymentTaskGuidance()
  if pausedAmbulanceId then
    return {label = "Call paused", subtext = "Return to your ambulance to continue the call"}
  elseif currentFare and state == "pickup" then
    return {label = "Pick up the patient", subtext = "Drive to the marked pickup and stop to load the patient"}
  elseif M.hasPatientOnboard() then
    local emp = overhaul_career_work_employment
    local ending = emp and emp.isEndingDay()
    return {label = "Deliver the patient to the hospital", subtext = ending
      and "Complete this drop-off to collect pay and end the day"
      or "Follow the hospital route and stop to unload the patient"}
  elseif inAmbulance then
    return {label = "Waiting for a medical call", subtext = "Dispatch will send your next pickup; use End Day to finish"}
  end
  return {label = "Enter your ambulance", subtext = "Get in your assigned or personal ambulance to begin responding"}
end

function M.cancelActiveCall(_reason)
  overhaul_vehicles_passengerOccupants.clear('ambulance')
  pausedAmbulanceId = nil
  local hadWork = currentFare ~= nil or M.initDelay ~= nil or missionTriggeredForVehicle
  if not hadWork then return false end
  currentFare = nil
  state = "ready"
  pickupTimer = nil
  pickupMessageShown = false
  missionTriggeredForVehicle = false
  stopMonitorActive = false
  stopSettleTimer = 0
  M.initDelay = nil
  M.initDelayDuration = nil
  M.delayTimer = nil
  M.delayDuration = nil
  M.rideData = {}
  core_groundMarkers.resetAll()

  return true
end

function M.requestEndDay()
  if M.hasPatientOnboard() then
    if currentFare.destination and currentFare.destination.pos then
      core_groundMarkers.setPath(currentFare.destination.pos, { clearPathOnReachingTarget = true })
    end
    return
  end
  M.cancelActiveCall("end day before patient pickup")
  inAmbulance = false
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  local emp = overhaul_career_work_employment
  if emp and emp.isRoleplayShift() and emp.isEndingDay()
    and not M.hasPatientOnboard() then
    M.requestEndDay()
    return
  end
  if emp and emp.blocksRoleplay() then
    if currentFare or M.initDelay or missionTriggeredForVehicle then
      M.cancelActiveCall("company logistics shift")
    end
    return
  end

  local playerVehicle = be:getPlayerVehicle(0)

  if playerVehicle and inAmbulance and not missionTriggeredForVehicle then
    missionTriggeredForVehicle = true
    M.initDelay = 0
    M.initDelayDuration = 0.1

    local trafficVehicle = gameplay_traffic.getTrafficData()[playerVehicle:getId()]
    if trafficVehicle then
      trafficVehicle:setRole("emt")
    end
  end

  -- Keep the call and its timers paused while the player is outside.
  if not inAmbulance and missionTriggeredForVehicle then
    if emp and emp.isRoleplayShift() then return end
    M.cancelActiveCall("left ambulance")
    ui_message("Ambulance mission abandoned.", 4, "warning", "warning")
  end

  -- Handle initial mission delay after vehicle enter
  if M.initDelay ~= nil then
    M.initDelay = M.initDelay + (dtSim or 0)
    if M.initDelay >= M.initDelayDuration then
      shared.startNextMission()
      M.initDelay = nil
      M.initDelayDuration = nil
    end
  end

  shared.updateMarkers(dtReal, dtSim, dtRaw)
end

M.activity = require('overhaul/jobs/ambulance/activity')(M)

return M
