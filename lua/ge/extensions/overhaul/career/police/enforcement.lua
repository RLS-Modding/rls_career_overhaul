-- Handles pursuit rewards and restores the pursuit settings changed for the player.
-- Map: config and state, pursuit settings, rewards, public API and game hooks.
local M = {}

local jobSkillRewards = require("overhaul/lib/jobs/skillRewards")
local facilityRole = require("overhaul/lib/logistics/facilityRole")
local policy = require("overhaul/lib/vehicles/policy")

-- Config ------------------------------------------------------------------------------------------

local POLICE_REWARD_CONFIG_PATH = "gameplay/overhaul/police/rewardConfig.json"
local DEFAULT_EVADE_TIME_S = 40

local config = {
  COP_PITY_MULTIPLIER = 30,
  CRIMINAL_REWARD_MULTIPLIER = 11,
  ARREST_BONUS_MULTIPLIER = 180,
  ARREST_BONUS_MAX = 430,
  ARREST_BONUS_MIN = 215,
  ARREST_REPUTATION_BONUS_SCALE = 0.05,
  POLICE_PAYOUT_MULTIPLIER = 3.0,
  REWARD_DIVISOR = 6,
  POLICE_SKILL_XP_DIVISOR = 60,
  ARREST_POLICE_SKILL_XP_DIVISOR = 1.2,
  COP_PROXIMITY_DISTANCE = 15,
  LICENSE_PLATE_EVADE_BONUS = 55,
  NO_LICENSE_PLATE_EVADE_PENALTY = 35,
  REPUTATION_BONUS_AMOUNT = 10,
  SUSPECT_FREQUENCY = 1.0,
  POLICE_SKILL_ATTRIBUTE_KEY = "careerSkills-emergency",
  POLICE_SKILL_PATH_IDS = {"careerSkills-emergency", "emergency"},
}

-- State -------------------------------------------------------------------------------------------

-- Loaded on first use, then kept for the session.
local policeRewardConfig
-- Evade time saved when a chase starts, restored when it ends; nil when no chase is active.
local preChaseEvadeTime = nil
local evadeTimeVehicleId = nil

-- Helpers -----------------------------------------------------------------------------------------

local function applyDifficultyProgressionRewardData(rewardData)
  return overhaul_career_economy_difficultyMode.scalePaymentRewardData(rewardData, {includeMoney = false})
end

local function applyPoliceInteractionFrequency()
  if overhaul_integration_services_police then
    overhaul_integration_services_police.setPursuitVars({suspectFrequency = config.SUSPECT_FREQUENCY})
  end
end

local function isPoliceDisabled()
  -- Walking is checked first, so its reason wins over a zero police multiplier.
  if gameplay_walk and gameplay_walk.isWalking() then
    return true, "Police service is not available while walking"
  end

  local policeMultiplier = overhaul_career_economyAdjuster.getSectionMultiplier("police") or 1.0
  if policeMultiplier == 0 then
    return true, "Police multiplier is set to 0"
  end
  return false, ""
end

local function resetPursuit()
  local vehicleId = be:getPlayerVehicleID(0)
  local playerTrafficData = gameplay_traffic.getTrafficData()[vehicleId]

  if playerTrafficData and playerTrafficData.pursuit then
    playerTrafficData.pursuit.mode = 0
    playerTrafficData.pursuit.score = 0
  end
end

local function restoreEvadeTime()
  if preChaseEvadeTime == nil then return end
  if overhaul_integration_services_police then
    overhaul_integration_services_police.setPursuitVars({ evadeTime = preChaseEvadeTime })
  end
  preChaseEvadeTime = nil
  evadeTimeVehicleId = nil
end

local function hasLicensePlate(inventoryId)
  for _, part in pairs(overhaul_career_parts_partInventory.getInventory()) do
    if part.location == inventoryId and string.find(part.name, "licenseplate") then
      return true
    end
  end
  return false
end

local function getSectionMultiplier(sectionName)
  if sectionName then
    return overhaul_career_economyAdjuster.getSectionMultiplier(sectionName) or 1.0
  end
  return 1.0
end

local function calculateRewardAmount(baseAmount, multiplier, sectionName)
  local jobMarketIndex = overhaul_career_economy_globalEconomy.getJobMarketIndex() or 1.0
  local sectionMultiplier = getSectionMultiplier(sectionName)
  return math.floor(baseAmount * multiplier * jobMarketIndex * sectionMultiplier) / 100
end

local function createRewardPayment(rewardData, label, tags, source)
  overhaul_career_economy_payment.reward(rewardData, {
    category = "activity:" .. source,
    finance = {source = source,
      vehicleId = overhaul_career_garage_inventory.getCurrentVehicle()},
    label = label,
    tags = tags
  }, true)
end

local function calculatePoliceSkillXp(amount)
  return math.floor(amount / config.POLICE_SKILL_XP_DIVISOR)
end

local function calculateArrestPoliceSkillXp(amount)
  return math.floor(amount / config.ARREST_POLICE_SKILL_XP_DIVISOR)
end

local function getPoliceRewardConfig()
  if policeRewardConfig == nil then
    policeRewardConfig = jobSkillRewards.loadRewardConfig(POLICE_REWARD_CONFIG_PATH)
  end
  return policeRewardConfig
end

local function calculateArrestReputationBonus(rawBonus)
  rawBonus = tonumber(rawBonus) or 1
  if rawBonus <= 1 then
    return 1
  end
  return 1 + ((rawBonus - 1) * config.ARREST_REPUTATION_BONUS_SCALE)
end

local function calculatePoliceSkillPayoutMultiplier()
  local skillConfig = jobSkillRewards.getSkillConfig(getPoliceRewardConfig())
  local attributeKey = jobSkillRewards.getAttributeKey(skillConfig, config.POLICE_SKILL_ATTRIBUTE_KEY)
  local policeSkillLevel = jobSkillRewards.getSkillLevel(attributeKey, config.POLICE_SKILL_PATH_IDS)
  return jobSkillRewards.getJobMoneyBonusMultiplier(skillConfig, policeSkillLevel)
end

-- The police organization that gets the arrest: the vehicle's own loaner org first, then the map station.
local function getArrestPoliceOrganization(vehicle)
  local owningOrganizationId = vehicle and vehicle.owningOrganization
  if facilityRole.isPoliceOrganizationId(owningOrganizationId) then
    local owningOrganization = overhaul_world_organizations.getOrganization(owningOrganizationId)
    if owningOrganization then return owningOrganizationId, owningOrganization end
    log("W", "career", "Police loaner organization is unavailable: " .. owningOrganizationId)
    return nil, nil
  end

  local generator = overhaul_career_logistics_generator
  local facilities = generator and generator.getFacilities and generator.getFacilities() or {}
  local mapPoliceFacility
  for _, facility in ipairs(facilities) do
    if facility.roleplayType == "police" then
      mapPoliceFacility = facility
      break
    end
    if not mapPoliceFacility and facilityRole.resolve(facility) == "police" then
      mapPoliceFacility = facility
    end
  end
  if mapPoliceFacility then
    local orgId = mapPoliceFacility.associatedOrganization
    if type(orgId) ~= "string" or orgId == "" then
      log("W", "career", "Map police facility has no organization: " .. tostring(mapPoliceFacility.id))
      return nil, nil
    end
    local policeOrganization = overhaul_world_organizations.getOrganization(orgId)
    if policeOrganization then return orgId, policeOrganization end
    log("W", "career", "Map police organization is unavailable: " .. orgId)
    return nil, nil
  end

  local levelId = getCurrentLevelIdentifier()
  local localPolicy = levelId and jsonReadFile("/levels/" .. levelId .. "/police.json")
  local defaultId = localPolicy and localPolicy.defaultArrestOrganizationId
  if defaultId then
    local organization = overhaul_world_organizations.getOrganization(defaultId)
    if organization then return defaultId, organization end
    log("W", "career", "Declared arrest organization is unavailable: " .. tostring(defaultId))
  else
    log("W", "career", "No local police organization; arrest credit has no organization recipient")
  end
  return nil, nil
end

-- Other vehicles only count for a cop chasing within range; the player's own vehicle always counts.
local function isPursuitRelevant(vehicleId, isCop)
  if vehicleId == be:getPlayerVehicleID(0) then return true end
  if not isCop then return false end

  local vehicle = scenetree.findObjectById(vehicleId)
  local playerVehicle = getPlayerVehicle(0)
  if not vehicle or not playerVehicle then return false end

  local distance = vehicle:getPosition():distance(playerVehicle:getPosition())
  if distance > config.COP_PROXIMITY_DISTANCE then
    return false
  end
  return true
end

-- Pursuit settings --------------------------------------------------------------------------------

-- Tracking stays off while the player is on foot and resumes once they are back in a vehicle.
local function resumeParkingTracking(vehicleId)
  if not gameplay_walk.isWalking() then
    overhaul_integration_services_parking.enableTracking(vehicleId)
  end
end

-- Evade time depends on whether the car has a plate; the pre-chase value is saved so it can be restored.
local function beginPursuitSettings(vehicleId, playerData)
  overhaul_integration_services_parking.disableTracking(vehicleId)

  if not playerData.isCop then
    local evadeTime = hasLicensePlate(playerData.inventoryId)
      and config.LICENSE_PLATE_EVADE_BONUS
      or config.NO_LICENSE_PLATE_EVADE_PENALTY
    if preChaseEvadeTime == nil then
      local pursuitVariables = overhaul_integration_services_police.getPursuitVars and overhaul_integration_services_police.getPursuitVars()
      preChaseEvadeTime = pursuitVariables and tonumber(pursuitVariables.evadeTime) or DEFAULT_EVADE_TIME_S
    end
    evadeTimeVehicleId = vehicleId
    overhaul_integration_services_police.setPursuitVars({ evadeTime = evadeTime })
  end

  log("I", "career", "Police pursuing player, now deactivating recovery prompt buttons")
end

-- Rewards -----------------------------------------------------------------------------------------

local function handleCopEvadeReward(data)
  local pityAmount = calculateRewardAmount(data.score, config.COP_PITY_MULTIPLIER, "police")
  pityAmount = math.floor(pityAmount * config.POLICE_PAYOUT_MULTIPLIER)

  local policeSkillXp = calculatePoliceSkillXp(pityAmount)
  local rewardData = {
    money = { amount = pityAmount }
  }
  jobSkillRewards.addJobSkillXpToRewardData(rewardData, config.POLICE_SKILL_ATTRIBUTE_KEY, policeSkillXp)
  rewardData = applyDifficultyProgressionRewardData(rewardData)
  pityAmount = rewardData.money.amount

  local surgeText = overhaul_career_economy_activityHeat.formatSurgeBonusText("police")
  createRewardPayment(rewardData,
    "The suspect got away, Here is " .. pityAmount .. " for repairs" .. surgeText,
    {"gameplay", "reward", "police"}, "police"
  )
  require("overhaul/lib/save/store").request("enforcement:handleCopEvadeReward")
  ui_message("The suspect got away, Here is $" .. pityAmount .. " for repairs" .. surgeText, 5, "Police")
end

local function handleCriminalEvadeReward(vehicleId, data, inventoryId)
  if vehicleId ~= be:getPlayerVehicleID(0) then
    return
  end

  if overhaul_career_economyAdjuster.getTypeMultiplier("criminal") == 0 then
    ui_message("Criminal work is disabled", 8, "Criminal", "warning")
    return
  end

  local rewardAmount = calculateRewardAmount(data.score or 10, config.CRIMINAL_REWARD_MULTIPLIER, "criminal")

  local rewardData = {
    money = { amount = rewardAmount }
  }
  rewardData = applyDifficultyProgressionRewardData(rewardData)
  rewardAmount = rewardData.money.amount

  local surgeText = overhaul_career_economy_activityHeat.formatSurgeBonusText("criminal")
  createRewardPayment(rewardData,
    "You sold your dashcam footage for $" .. rewardAmount .. surgeText,
    {"gameplay", "reward", "criminal"}, "criminal"
  )

  ui_message("You sold your dashcam footage for $" .. rewardAmount .. surgeText, 5, "Criminal")
  overhaul_career_garage_inventory.addEvade(inventoryId)
end

-- The bonus shrinks as the chase's base reward grows, floored at the minimum.
local function arrestBonusFromScore(score)
  local baseBonus = calculateRewardAmount(score, config.ARREST_BONUS_MULTIPLIER)
  return math.max(config.ARREST_BONUS_MAX - baseBonus, config.ARREST_BONUS_MIN)
end

local function arrestPayout(bonus, reputationBonus, policeSkillMultiplier)
  bonus = bonus * reputationBonus * policeSkillMultiplier
  bonus = math.floor(bonus * config.POLICE_PAYOUT_MULTIPLIER)
  return calculateRewardAmount(bonus, 100, "police")
end

-- Returns the reputation multiplier with the police organization that receives the arrest (nil when unknown).
local function arrestReputation(playerData)
  local vehicle = overhaul_career_garage_inventory.getVehicle(playerData.inventoryId)
  local policeOrgName, policeOrganization = getArrestPoliceOrganization(vehicle)
  local level = policeOrganization and policeOrganization.reputationLevels
    and policeOrganization.reputationLevels[(policeOrganization.reputation and policeOrganization.reputation.level or 0) + 2]
  local reputationBonus = calculateArrestReputationBonus(level and level.deliveryBonus and level.deliveryBonus.value)
  return reputationBonus, policeOrgName, policeOrganization
end

local function arrestRewardData(policeOrgName, policeOrganization, policeSkillXp)
  local rewardData = {money = { amount = 0 }}
  if policeOrgName and policeOrganization then
    rewardData[policeOrgName .. "Reputation"] = { amount = config.REPUTATION_BONUS_AMOUNT }
  end
  jobSkillRewards.addJobSkillXpToRewardData(rewardData, config.POLICE_SKILL_ATTRIBUTE_KEY, policeSkillXp)
  return applyDifficultyProgressionRewardData(rewardData)
end

-- Roleplay shifts hold the arrest pay in escrow until the shift ends; otherwise the player is told to clock in.
local function arrestMessage(employment, escrowRoleplay, bonus, surgeText)
  if escrowRoleplay and employment.depositRoleplayEscrow then
    local escrowAmount = employment.depositRoleplayEscrow("Arrest bonus", bonus) or 0
    return "Arrest Bonus: $" .. escrowAmount .. " (held until End day)" .. surgeText
  end
  return "Clock in at the station to earn arrest pay." .. surgeText
end

local function arrestBonusNotes(reputationBonus, policeSkillMultiplier)
  local notes = ""
  if reputationBonus ~= 1 then
    notes = notes .. " (Reputation Bonus: " .. math.floor((reputationBonus - 1) * 100) .. "%)"
  end
  if policeSkillMultiplier > 1 then
    notes = notes .. " (Police Skill Bonus: " .. math.floor((policeSkillMultiplier - 1) * 100) .. "%)"
  end
  return notes
end

local function handleArrestReward(data, playerData)
  local bonus = arrestBonusFromScore(data.score)
  local policeSkillMultiplier = calculatePoliceSkillPayoutMultiplier()
  local reputationBonus, policeOrgName, policeOrganization = arrestReputation(playerData)
  bonus = arrestPayout(bonus, reputationBonus, policeSkillMultiplier)

  local policeSkillXp = calculateArrestPoliceSkillXp(bonus / math.max(1, policeSkillMultiplier))
  local employment = overhaul_career_work_employment
  local escrowRoleplay = employment and employment.shouldEscrowRoleplayPay and employment.shouldEscrowRoleplayPay()
  local rewardData = arrestRewardData(policeOrgName, policeOrganization, policeSkillXp)
  createRewardPayment(rewardData, "Arrest Bonus" .. overhaul_career_economy_activityHeat.formatSurgeBonusText("police"), {"gameplay", "reward", "police"}, "police")

  local surgeText = overhaul_career_economy_activityHeat.formatSurgeBonusText("police")
  local message = arrestMessage(employment, escrowRoleplay, bonus, surgeText)
  message = message .. arrestBonusNotes(reputationBonus, policeSkillMultiplier)

  ui_message(message, 5, "Police")
  overhaul_career_garage_inventory.addSuspectCaught(playerData.inventoryId)
  require("overhaul/lib/save/store").request("enforcement:handleArrestReward")
end

-- Public API --------------------------------------------------------------------------------------

M.Constants = config
M.isPoliceDisabled = isPoliceDisabled

-- Game hooks --------------------------------------------------------------------------------------

local function onPursuitAction(vehicleId, action, data)
  if vehicleId == evadeTimeVehicleId and (action == "reset" or action == "evade" or action == "arrest") then
    restoreEvadeTime()
  end
  if policy.query("pursuitOutcomeIgnored", vehicleId) then return end

  local playerData = {
    isCop = overhaul_career_police_playerDriving.getPlayerIsCop(),
    inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehicleId)
  }

  local policeDisabled, disabledReason = isPoliceDisabled()
  if policeDisabled and playerData.isCop then
    ui_message("Police service disabled: " .. disabledReason, 8, "Police", "warning")
    return
  end

  if not playerData.inventoryId then
    playerData.inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(be:getPlayerVehicleID(0))
  end
  if not isPursuitRelevant(vehicleId, playerData.isCop) then return end

  if action == "start" then
    beginPursuitSettings(vehicleId, playerData)
  elseif action == "reset" then
    resumeParkingTracking(vehicleId)
    log("I", "career", "Pursuit ended, now activating recovery prompt buttons")
    resetPursuit()
  elseif action == "evade" then
    resumeParkingTracking(vehicleId)
    if playerData.isCop then
      handleCopEvadeReward(data)
    else
      handleCriminalEvadeReward(vehicleId, data, playerData.inventoryId)
    end
    resetPursuit()
  elseif action == "arrest" and playerData.isCop then
    handleArrestReward(data, playerData)
  end
end

M.onPursuitAction = onPursuitAction
M.onExtensionUnloaded = restoreEvadeTime
M.onExtensionLoaded = applyPoliceInteractionFrequency
M.onCareerActivated = applyPoliceInteractionFrequency

return M
