local M = {}

local CONSTANTS = {
  COP_PITY_MULTIPLIER = 30,
  CRIMINAL_REWARD_MULTIPLIER = 11,
  ARREST_BONUS_MULTIPLIER = 180,
  ARREST_BONUS_MAX = 430,
  ARREST_BONUS_MIN = 215,
  ARREST_SKILL_BONUS_PER_LEVEL = 0.25,
  ARREST_REPUTATION_BONUS_SCALE = 0.05,
  POLICE_PAYOUT_MULTIPLIER = 0.70,
  REWARD_DIVISOR = 6,
  POLICE_SKILL_XP_DIVISOR = 60,
  COP_PROXIMITY_DISTANCE = 15,
  LICENSE_PLATE_EVADE_BONUS = 55,
  NO_LICENSE_PLATE_EVADE_PENALTY = 35,
  POLICE_LOANER_ORG_NAME = "policeLoaner",
  REPUTATION_BONUS_AMOUNT = 10,
  POLICE_SKILL_MAX_LEVEL = 50,
  POLICE_SKILL_ATTRIBUTE_KEY = "careerSkills-police",
  POLICE_SKILL_PATH_IDS = {"careerSkills-police", "police", "freestyle-police"},
}

local function applyDifficultyProgressionRewardData(rewardData)
  if not (career_modules_difficultyMode and career_modules_difficultyMode.scalePaymentRewardData) then
    return rewardData
  end
  return career_modules_difficultyMode.scalePaymentRewardData(rewardData, {includeMoney = false})
end

local function isPoliceDisabled()
  local disabled = false
  local reason = ""

  -- Check if player is walking (highest priority)
  if gameplay_walk and gameplay_walk.isWalking() then
      disabled = true
      reason = "Police service is not available while walking"
      return disabled, reason
  end

  -- Check if police multiplier is 0
  if career_economyAdjuster then
      local policeMultiplier = career_economyAdjuster.getSectionMultiplier("police") or 1.0
      if policeMultiplier == 0 then
          disabled = true
          reason = "Police multiplier is set to 0"
      end
  end

  return disabled, reason
end

local function resetPursuit()
  local vehId = be:getPlayerVehicleID(0)
  local playerTrafficData = gameplay_traffic.getTrafficData()[vehId]

  if playerTrafficData and playerTrafficData.pursuit then
    playerTrafficData.pursuit.mode = 0
    playerTrafficData.pursuit.score = 0
  end
end

local function hasLicensePlate(inventoryId)
  for partId, part in pairs(career_modules_partInventory.getInventory()) do
    if part.location == inventoryId and string.find(part.name, "licenseplate") then
      return true
    end
  end
  return false
end

local function calculateRewardAmount(baseAmount, multiplier, sectionName)
  local jobMarketIndex = career_modules_globalEconomy and career_modules_globalEconomy.getJobMarketIndex() or 1.0
  local sectionMultiplier = 1.0
  if career_economyAdjuster and career_economyAdjuster.getSectionMultiplier and sectionName then
    sectionMultiplier = career_economyAdjuster.getSectionMultiplier(sectionName) or 1.0
  end
  return math.floor(baseAmount * multiplier * jobMarketIndex * sectionMultiplier) / 100
end

local function createRewardPayment(rewardData, label, tags)
  career_modules_payment.reward(rewardData, {
    label = label,
    tags = tags
  }, true)
end

local function calculatePoliceSkillXp(amount)
  return math.floor(amount / CONSTANTS.POLICE_SKILL_XP_DIVISOR)
end

local function getBranchLevelByPathIds(pathIds)
  if not career_branches or not career_branches.getBranchLevel then
    return 0
  end

  for _, skillPathId in ipairs(pathIds or {}) do
    local branchLevel = career_branches.getBranchLevel(skillPathId)
    local level = tonumber(branchLevel)
    if level then
      return math.max(0, math.floor(level))
    end
  end

  return 0
end

local function getPoliceSkillLevel()
  local level = getBranchLevelByPathIds(CONSTANTS.POLICE_SKILL_PATH_IDS)
  if level > 0 then
    return level
  end

  if career_modules_playerAttributes and career_modules_playerAttributes.getAttributeValue and career_branches and career_branches.calcBranchLevelFromValue then
    local value = tonumber(career_modules_playerAttributes.getAttributeValue(CONSTANTS.POLICE_SKILL_ATTRIBUTE_KEY)) or 0
    for _, skillPathId in ipairs(CONSTANTS.POLICE_SKILL_PATH_IDS) do
      local branchLevel = career_branches.calcBranchLevelFromValue(value, skillPathId)
      level = math.max(level, tonumber(branchLevel) or 0)
    end
  end

  return math.max(0, math.floor(level))
end

local function calculateArrestReputationBonus(rawBonus)
  rawBonus = tonumber(rawBonus) or 1
  if rawBonus <= 1 then
    return 1
  end
  return 1 + ((rawBonus - 1) * CONSTANTS.ARREST_REPUTATION_BONUS_SCALE)
end

local function calculatePoliceSkillPayoutMultiplier(policeSkillLevel)
  local clampedLevel = math.min(math.max(tonumber(policeSkillLevel) or 0, 0), CONSTANTS.POLICE_SKILL_MAX_LEVEL)
  return 1 + (clampedLevel * CONSTANTS.ARREST_SKILL_BONUS_PER_LEVEL)
end

local function handleCopEvadeReward(data)
  local pityAmount = calculateRewardAmount(data.score, CONSTANTS.COP_PITY_MULTIPLIER, "police")
  pityAmount = math.floor(pityAmount * CONSTANTS.POLICE_PAYOUT_MULTIPLIER)

  local rewardData = {
    money = { amount = pityAmount },
    beamXP = { amount = math.floor(pityAmount / CONSTANTS.REWARD_DIVISOR) },
    [CONSTANTS.POLICE_SKILL_ATTRIBUTE_KEY] = { amount = calculatePoliceSkillXp(pityAmount) },
    specialized = { amount = math.floor(pityAmount / CONSTANTS.REWARD_DIVISOR) }
  }
  rewardData = applyDifficultyProgressionRewardData(rewardData)
  pityAmount = rewardData.money.amount

  createRewardPayment(rewardData,
    "The suspect got away, Here is " .. pityAmount .. " for repairs",
    {"gameplay", "reward", "police"}
  )
  career_saveSystem.saveCurrent()
  ui_message("The suspect got away, Here is " .. pityAmount .. " for repairs", 5, "Police")
end

local function handleCriminalEvadeReward(vehId, data, inventoryId)
  if vehId ~= be:getPlayerVehicleID(0) then
    return
  end

  if career_economyAdjuster.getTypeMultiplier("criminal") == 0 then
    ui_message("Criminal work is disabled", 8, "Criminal", "warning")
    return
  end

  local rewardAmount = calculateRewardAmount(data.score or 10, CONSTANTS.CRIMINAL_REWARD_MULTIPLIER, "criminal")

  local rewardData = {
    money = { amount = rewardAmount },
    beamXP = { amount = math.floor(rewardAmount / CONSTANTS.REWARD_DIVISOR) },
    criminal = { amount = math.floor(rewardAmount / CONSTANTS.REWARD_DIVISOR) },
    adventurer = { amount = math.floor(rewardAmount / CONSTANTS.REWARD_DIVISOR) }
  }
  rewardData = applyDifficultyProgressionRewardData(rewardData)
  rewardAmount = rewardData.money.amount

  createRewardPayment(rewardData,
    "You sold your dashcam footage for $" .. rewardAmount,
    {"gameplay", "reward", "criminal"}
  )

  ui_message("You sold your dashcam footage for $" .. rewardAmount, 5, "Criminal")
  career_modules_inventory.addEvade(inventoryId)
end

local function handleArrestReward(data, playerData)
  local baseBonus = calculateRewardAmount(data.score, CONSTANTS.ARREST_BONUS_MULTIPLIER)
  local bonus = math.max(CONSTANTS.ARREST_BONUS_MAX - baseBonus, CONSTANTS.ARREST_BONUS_MIN)
  local policeSkillLevel = getPoliceSkillLevel()
  local policeSkillMultiplier = calculatePoliceSkillPayoutMultiplier(policeSkillLevel)

  local org = freeroam_organizations.getOrganization(CONSTANTS.POLICE_LOANER_ORG_NAME)
  local level = org.reputationLevels[org.reputation.level + 2]
  local reputationBonus = calculateArrestReputationBonus(level.deliveryBonus and level.deliveryBonus.value)
  bonus = bonus * reputationBonus * policeSkillMultiplier

  local loanerCut = 0
  local vehicle = career_modules_inventory.getVehicle(playerData.inventoryId)
  if vehicle.owningOrganization then
    loanerCut = level.loanerCut.value
  end
  bonus = math.floor(bonus * (1 - loanerCut))
  bonus = math.floor(bonus * CONSTANTS.POLICE_PAYOUT_MULTIPLIER)
  bonus = calculateRewardAmount(bonus, 100, "police")

  local rewardData = {
    money = { amount = bonus },
    beamXP = { amount = math.floor(bonus / CONSTANTS.REWARD_DIVISOR) },
    [CONSTANTS.POLICE_SKILL_ATTRIBUTE_KEY] = { amount = calculatePoliceSkillXp(bonus) },
    specialized = { amount = math.floor(bonus / CONSTANTS.REWARD_DIVISOR) },
    policeLoanerReputation = { amount = CONSTANTS.REPUTATION_BONUS_AMOUNT }
  }
  rewardData = applyDifficultyProgressionRewardData(rewardData)
  bonus = rewardData.money.amount

  createRewardPayment(rewardData, "Arrest Bonus", {"gameplay", "reward", "police"})

  local message = "Arrest Bonus: $" .. bonus
  if loanerCut > 0 then
    message = message .. " (Loaner Cut: " .. math.floor(loanerCut * 100) .. "%)"
  end
  if reputationBonus ~= 1 then
    message = message .. " (Reputation Bonus: " .. math.floor((reputationBonus - 1) * 100) .. "%)"
  end
  if policeSkillMultiplier > 1 then
    message = message .. " (Police Skill Bonus: " .. math.floor((policeSkillMultiplier - 1) * 100) .. "%)"
  end

  ui_message(message, 5, "Police")
  career_modules_inventory.addSuspectCaught(playerData.inventoryId)
  career_saveSystem.saveCurrent()
end

local function onPursuitAction(vehId, action, data)
  if gameplay_cab and gameplay_cab.inCab() then
    return
  end

  local playerData = {
    isCop = career_modules_playerDriving.getPlayerIsCop(),
    inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
  }

  local policeDisabled, disabledReason = isPoliceDisabled()
  if policeDisabled and playerData.isCop then
    ui_message("Police service disabled: " .. disabledReason, 8, "Police", "warning")
    return
  end

  if not playerData.inventoryId then
    playerData.inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(be:getPlayerVehicleID(0))
  end

  if vehId ~= be:getPlayerVehicleID(0) and playerData.isCop then
    local vehicle = scenetree.findObjectById(vehId)
    local playerVeh = getPlayerVehicle(0)
    if not vehicle or not playerVeh then return end

    local distance = vehicle:getPosition():distance(playerVeh:getPosition())
    if distance > CONSTANTS.COP_PROXIMITY_DISTANCE then
      return
    end
  elseif vehId ~= be:getPlayerVehicleID(0) and not playerData.isCop then
    return
  end

  if action == "start" then
    gameplay_parking.disableTracking(vehId)

    local evadeLimit = hasLicensePlate(playerData.inventoryId)
      and CONSTANTS.LICENSE_PLATE_EVADE_BONUS
      or CONSTANTS.NO_LICENSE_PLATE_EVADE_PENALTY

    gameplay_police.setPursuitVars({ evadeLimit = evadeLimit })

    log("I", "career", "Police pursuing player, now deactivating recovery prompt buttons")

  elseif action == "reset" then
    if not gameplay_walk.isWalking() then
      gameplay_parking.enableTracking(vehId)
    end

    log("I", "career", "Pursuit ended, now activating recovery prompt buttons")
    resetPursuit()

  elseif action == "evade" then
    if not gameplay_walk.isWalking() then
      gameplay_parking.enableTracking(vehId)
    end

    if playerData.isCop then
      handleCopEvadeReward(data)
    else
      handleCriminalEvadeReward(vehId, data, playerData.inventoryId)
    end

    resetPursuit()

  elseif action == "arrest" then
    if playerData.isCop then
      handleArrestReward(data, playerData)
    end
  end
end

M.onPursuitAction = onPursuitAction
M.Constants = CONSTANTS
M.isPoliceDisabled = isPoliceDisabled

return M
