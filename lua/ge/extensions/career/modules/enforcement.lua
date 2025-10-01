local M = {}

local CONSTANTS = {
  COP_PITY_MULTIPLIER = 30,
  CRIMINAL_REWARD_MULTIPLIER = 110,
  ARREST_BONUS_MULTIPLIER = 180,
  ARREST_BONUS_MAX = 5000,
  ARREST_BONUS_MIN = 1000,
  REWARD_DIVISOR = 20,
  COP_PROXIMITY_DISTANCE = 15,
  LICENSE_PLATE_EVADE_BONUS = 55,
  NO_LICENSE_PLATE_EVADE_PENALTY = 35,
  POLICE_LOANER_ORG_NAME = "policeLoaner",
  REPUTATION_BONUS_AMOUNT = 10,
}

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

local function calculateRewardAmount(baseAmount, multiplier)
  return math.floor(baseAmount * multiplier) / 100
end

local function createRewardPayment(rewardData, label, tags)
  career_modules_payment.reward(rewardData, {
    label = label,
    tags = tags
  }, true)
end

local function handleCopEvadeReward(data)
  local pityAmount = calculateRewardAmount(data.score, CONSTANTS.COP_PITY_MULTIPLIER)

  local rewardData = {
    money = { amount = pityAmount },
    beamXP = { amount = math.floor(pityAmount / CONSTANTS.REWARD_DIVISOR) },
    police = { amount = math.floor(pityAmount / CONSTANTS.REWARD_DIVISOR) },
    specialized = { amount = math.floor(pityAmount / CONSTANTS.REWARD_DIVISOR) }
  }

  createRewardPayment(rewardData,
    "The suspect got away, Here is " .. pityAmount .. " for repairs",
    {"gameplay", "reward", "police"}
  )

  ui_message("The suspect got away, Here is " .. pityAmount .. " for repairs", 5, "Police")
  career_saveSystem.saveCurrent()
end

local function handleCriminalEvadeReward(vehId, data, inventoryId)
  if vehId ~= be:getPlayerVehicleID(0) then
    return
  end

  local rewardAmount = calculateRewardAmount(data.score or 10, CONSTANTS.CRIMINAL_REWARD_MULTIPLIER)

  local rewardData = {
    money = { amount = rewardAmount },
    beamXP = { amount = math.floor(rewardAmount / CONSTANTS.REWARD_DIVISOR) },
    criminal = { amount = math.floor(rewardAmount / CONSTANTS.REWARD_DIVISOR) },
    adventurer = { amount = math.floor(rewardAmount / CONSTANTS.REWARD_DIVISOR) }
  }

  createRewardPayment(rewardData,
    "You sold your dashcam footage for $" .. rewardAmount,
    {"gameplay", "reward", "criminal"}
  )

  ui_message("You sold your dashcam footage for $" .. rewardAmount, 5, "Criminal")
  career_modules_inventory.addEvade(inventoryId)
  career_saveSystem.saveCurrent()
end

local function handleArrestReward(data, playerData)
  local baseBonus = calculateRewardAmount(data.score, CONSTANTS.ARREST_BONUS_MULTIPLIER)
  local bonus = math.max(CONSTANTS.ARREST_BONUS_MAX - baseBonus, CONSTANTS.ARREST_BONUS_MIN)

  local org = freeroam_organizations.getOrganization(CONSTANTS.POLICE_LOANER_ORG_NAME)
  local level = org.reputationLevels[org.reputation.level + 2]
  local reputationBonus = level.deliveryBonus.value
  bonus = bonus * reputationBonus

  local loanerCut = 0
  local vehicle = career_modules_inventory.getVehicle(playerData.inventoryId)
  if vehicle.owningOrganization then
    loanerCut = level.loanerCut.value
  end
  bonus = math.floor(bonus * (1 - loanerCut))

  local rewardData = {
    money = { amount = bonus },
    beamXP = { amount = math.floor(bonus / CONSTANTS.REWARD_DIVISOR) },
    police = { amount = math.floor(bonus / CONSTANTS.REWARD_DIVISOR) },
    specialized = { amount = math.floor(bonus / CONSTANTS.REWARD_DIVISOR) },
    policeLoanerReputation = { amount = CONSTANTS.REPUTATION_BONUS_AMOUNT }
  }

  createRewardPayment(rewardData, "Arrest Bonus", {"gameplay", "reward", "police"})

  local message = "Arrest Bonus: $" .. bonus
  if loanerCut > 0 then
    message = message .. " (Loaner Cut: " .. math.floor(loanerCut * 100) .. "%)"
  end
  if reputationBonus ~= 1 then
    message = message .. " (Reputation Bonus: " .. math.floor((reputationBonus - 1) * 100) .. "%)"
  end

  ui_message(message, 5, "Police")
  career_modules_inventory.addSuspectCaught(playerData.inventoryId)

  if career_modules_insurance then
    career_modules_insurance.incrementPoliceStop(playerData.inventoryId)
  end
end

local function onPursuitAction(vehId, action, data)
  if gameplay_cab and gameplay_cab.inCab() then
    return
  end

  local playerData = {
    isCop = career_modules_playerDriving.getPlayerIsCop(),
    inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
  }

  if not playerData.inventoryId then
    playerData.inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(be:getPlayerVehicleID(0))
  end

  if vehId ~= be:getPlayerVehicleID(0) and playerData.isCop then
    local vehicle = scenetree.findObjectById(vehId)
    if not vehicle then return end

    local distance = vehicle:getPosition():distance(getPlayerVehicle(0):getPosition())
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

    career_saveSystem.saveCurrent()
  end
end

M.onPursuitAction = onPursuitAction
M.Constants = CONSTANTS

return M
