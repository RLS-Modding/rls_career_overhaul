-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/insurance/insurance.lua (BeamNG 0.40).
-- Insurance facade: owns the shared insurance state and exports the functions of its five parts.
-- The policy, premium, repair, policy-change and UI parts live in repair/insurance/ and are bound below.

local M = {}
local dataFiles = require("overhaul/lib/data/dataFiles")

-- Parts return named services for this load; the extension owns their shared runtime state.
local insuranceState = {}

local plInsuranceDataFileName = "insurance"

-- static insurance information
local insuranceRenewalDistance = 50000
local maxAccidentForgiveness = 5
local defaultDriverScore = 64
local groupDiscountTiers = {
  {id = 1, min = 0, max = 50000, discount = 0.10},
  {id = 2, min = 50000, max = 100000, discount = 0.15},
  {id = 3, min = 100000, max = 150000, discount = 0.2},
  {id = 4, min = 150000, max = 500000, discount = 0.25},
  {id = 5, min = 500000, max = math.huge, discount = 0.3},
}

local insuranceEditTime = 600 -- have to wait between coverage editing
local testDriveDamagePlayerShare = 0.5
insuranceState.testDriveBaselineRepair = 0
insuranceState.lastTestDriveCharge = 0
insuranceState.testDriveBaselineReady = false
insuranceState.liveTestDriveCharge = 0
insuranceState.lastTestDriveEstimateRequest = -math.huge
local TEST_DRIVE_ESTIMATE_INTERVAL = 1
local minimumDriverScore = 0
local maximumDriverScore = 100
local insuranceRepairScorePenaltySqrtDivisor = 6250
local insuranceRepairScorePenaltyMax = 25
local quickRepairExtraPrice = 1000
local earlyTerminationPenalty = 25 -- percentage
--loaded default data
insuranceState.availableCoverageOptions = {} -- to avoid copy pasting data in insurances.json, this table comprises coverage options niceName and descriptions
local availableClasses = {}
local availableInsurances = {} -- the default insurance data in game folder
insuranceState.driverScoreTiers = {}

local safeDrivingScoreIncrease = 2
local driverScoreDecreaseDistance = 50000

-- player saved data
insuranceState.plInsurancesData = {} -- the player's saved insurance data
insuranceState.invVehs = {}
insuranceState.housekeepingAccumulator = 0
local HOUSEKEEPING_INTERVAL = 0.25

local function getInvVehDataById(invVehId)
  if invVehId == nil then return end
  local v = insuranceState.invVehs[invVehId]
  if v then return v end
  if type(invVehId) == "string" then
    local n = tonumber(invVehId)
    if n ~= nil then return insuranceState.invVehs[n] end
  end
  return insuranceState.invVehs[tostring(invVehId)]
end

local function normalizeInvVehsKeys()
  if type(insuranceState.invVehs) ~= "table" then
    insuranceState.invVehs = {}
    return
  end

  local needsKeyFix = false
  for k, _ in pairs(insuranceState.invVehs) do
    if type(k) == "string" and tonumber(k) ~= nil then
      needsKeyFix = true
      break
    end
  end

  if not needsKeyFix then
    for _, v in pairs(insuranceState.invVehs) do
      if type(v) == "table" and type(v.id) == "string" then
        local n = tonumber(v.id)
        if n ~= nil then v.id = n end
      end
    end
    return
  end

  local newInvVehs = {}
  for k, v in pairs(insuranceState.invVehs) do
    local nk = k
    if type(k) == "string" then
      local n = tonumber(k)
      if n ~= nil then nk = n end
    end
    if type(v) == "table" then
      if v.id == nil then v.id = nk end
      if type(v.id) == "string" then
        local n = tonumber(v.id)
        if n ~= nil then v.id = n end
      end
    end
    if newInvVehs[nk] == nil then
      newInvVehs[nk] = v
    else
      newInvVehs[k] = v
    end
  end
  insuranceState.invVehs = newInvVehs
end

-- to calculate distance driven
local vec3Zero = vec3(0,0,0)
local lastPos = vec3(0,0,0)

-- active insurance variables
insuranceState.activeInsuranceId = -1

-- loyalty variables
local maxLoyaltyPerCarAndRenewal = 5
local minLoyaltyPerCarAndRenewal = 1

local conditions = {
  applicableValue = function(data, values)
    if not data.vehValue then return false end
    if values.min and values.max then
      return data.vehValue >= values.min and data.vehValue <= values.max
    elseif values.min and not values.max then
      return data.vehValue >= values.min
    elseif values.max and not values.min then
      return data.vehValue <= values.max
    end
  end,
  population = function(data, values)
    if not data.population then return false end
    if values.min and values.max then
      return data.population >= values.min and data.population <= values.max
    elseif values.min and not values.max then
      return data.population >= values.min
    elseif values.max and not values.min then
      return data.population <= values.max
    end
  end,
  bodyStyles = function(data, values)
    if not data.bodyStyle then return false end
    for _, bodyStyle in pairs(values) do
      if data.bodyStyle[bodyStyle] then
        return true
      end
    end
    return false
  end,
  commercialClass = function(data, values)
    if not data.commercialClass then return false end
    for _, commercialClass in pairs(values) do
      if commercialClass == data.commercialClass then
        return true
      end
    end
  end
}

-- gestures are commercial gestures
local gestures = {
  freeRepair = function(plInsuranceData)
    if plInsuranceData.accidentForgiveness >= maxAccidentForgiveness then return false end

    plInsuranceData.accidentForgiveness = plInsuranceData.accidentForgiveness + 1
    local insuranceName = "Unknown"
    if plInsuranceData.insuranceId and availableInsurances[plInsuranceData.insuranceId] then
      insuranceName = availableInsurances[plInsuranceData.insuranceId].name
    end
    overhaul_career_repair_insuranceHistory.addToPlHistory({
      type = "freeRepair",
      title = "Free repair",
      effects = {{type = "freeRepair", label = "Free repair", changedBy = 1, newValue = plInsuranceData.accidentForgiveness}},
      concernedInsuranceName = insuranceName
    })
    ui_message(string.format("'%s' insurance has given you a repair forgiveness due to not having submitted any claim for a while", insuranceName))

    return true
  end
}

local function getPlCoverageOptionValue(invVehId, coverageOptionName)
  if not invVehId then return end
  if not insuranceState.invVehs[invVehId] then return end

  local insuranceId = insuranceState.invVehs[invVehId].insuranceId or -1
  if insuranceId > 0 then -- if insured
    local plInsuranceData = insuranceState.plInsurancesData and insuranceState.plInsurancesData[insuranceId]
    if not plInsuranceData then return end
    local valueId = nil
    if insuranceState.availableCoverageOptions[coverageOptionName].isInsuranceWide then
      valueId = plInsuranceData.coverageOptionsData.currentCoverageOptions[coverageOptionName]
    else
      valueId = insuranceState.invVehs[invVehId].insuranceData.coverageOptionsData.currentCoverageOptions[coverageOptionName]
    end
    return availableInsurances[insuranceId].coverageOptions[coverageOptionName].choices[valueId].value
  end
end

local serviceInputs = {
  policies = {
    state = insuranceState,
  },
  repairs = {
    state = insuranceState,
  },
  premiums = {
    state = insuranceState,
  },
  policyChanges = {
    state = insuranceState,
  },
  ui = {
    state = insuranceState,
  },
}
local services = {}
services.policies = require('overhaul/career/repair/insurance/policies').new(serviceInputs.policies)
services.repairs = require('overhaul/career/repair/insurance/repairs').new(serviceInputs.repairs)
services.premiums = require('overhaul/career/repair/insurance/premiums').new(serviceInputs.premiums)
services.policyChanges = require('overhaul/career/repair/insurance/policyChanges').new(serviceInputs.policyChanges)
services.ui = require('overhaul/career/repair/insurance/ui').new(serviceInputs.ui)

-- Resolve named inputs once, after every service exists.
services.policies.bindInputs({
  M = M,
  availableClasses = availableClasses,
  availableInsurances = availableInsurances,
  dataFiles = dataFiles,
  defaultDriverScore = defaultDriverScore,
  lastPos = lastPos,
  normalizeInvVehsKeys = normalizeInvVehsKeys,
  plInsuranceDataFileName = plInsuranceDataFileName,
})
services.repairs.bindInputs({
  M = M,
  availableInsurances = availableInsurances,
  getInvVehDataById = getInvVehDataById,
  getPlCoverageOptionValue = getPlCoverageOptionValue,
  insuranceRepairScorePenaltyMax = insuranceRepairScorePenaltyMax,
  insuranceRepairScorePenaltySqrtDivisor = insuranceRepairScorePenaltySqrtDivisor,
  minimumDriverScore = minimumDriverScore,
  testDriveDamagePlayerShare = testDriveDamagePlayerShare,
})
services.premiums.bindInputs({
  HOUSEKEEPING_INTERVAL = HOUSEKEEPING_INTERVAL,
  M = M,
  availableClasses = availableClasses,
  availableInsurances = availableInsurances,
  conditions = conditions,
  driverScoreDecreaseDistance = driverScoreDecreaseDistance,
  earlyTerminationPenalty = earlyTerminationPenalty,
  gestures = gestures,
  getDriverScoreTierData = services.repairs.getDriverScoreTierData,
  getInvVehDataById = getInvVehDataById,
  getPlCoverageOptionValue = getPlCoverageOptionValue,
  groupDiscountTiers = groupDiscountTiers,
  insuranceRenewalDistance = insuranceRenewalDistance,
  inventoryVehNeedsRepair = services.repairs.inventoryVehNeedsRepair,
  lastPos = lastPos,
  loadInsurancesData = services.policies.loadInsurancesData,
  maxAccidentForgiveness = maxAccidentForgiveness,
  maxLoyaltyPerCarAndRenewal = maxLoyaltyPerCarAndRenewal,
  maximumDriverScore = maximumDriverScore,
  minLoyaltyPerCarAndRenewal = minLoyaltyPerCarAndRenewal,
  safeDrivingScoreIncrease = safeDrivingScoreIncrease,
  saveInsurancesData = services.policies.saveInsurancesData,
  setActiveInsurance = services.policies.setActiveInsurance,
  vec3Zero = vec3Zero,
})
services.policyChanges.bindInputs({
  M = M,
  availableClasses = availableClasses,
  availableInsurances = availableInsurances,
  calculateAddVehiclePrice = services.premiums.calculateAddVehiclePrice,
  calculateVehiclePremium = services.premiums.calculateVehiclePremium,
  createNoInsuranceCard = services.premiums.createNoInsuranceCard,
  defaultDriverScore = defaultDriverScore,
  getApplicableInsuranceClass = services.premiums.getApplicableInsuranceClass,
  getCoverageRefundPrice = services.premiums.getCoverageRefundPrice,
  getDriverScoreTierData = services.repairs.getDriverScoreTierData,
  getEarlyTerminationPenalty = services.premiums.getEarlyTerminationPenalty,
  getInsuranceGroupDiscountTierData = services.premiums.getInsuranceGroupDiscountTierData,
  getInsuranceSanitizedData = services.premiums.getInsuranceSanitizedData,
  getInsurancesByClass = services.premiums.getInsurancesByClass,
  getInvVehDataById = getInvVehDataById,
  getInvVehsUnderClass = services.premiums.getInvVehsUnderClass,
  getInvVehsUnderInsurance = services.premiums.getInvVehsUnderInsurance,
  getNetRefundPrice = services.premiums.getNetRefundPrice,
  getRenewsIn = services.premiums.getRenewsIn,
  getSanitizedInsuranceDataForPurchase = services.premiums.getSanitizedInsuranceDataForPurchase,
  insuranceEditTime = insuranceEditTime,
  inventoryVehNeedsRepair = services.repairs.inventoryVehNeedsRepair,
})
services.ui.bindInputs({
  M = M,
  TEST_DRIVE_ESTIMATE_INTERVAL = TEST_DRIVE_ESTIMATE_INTERVAL,
  availableInsurances = availableInsurances,
  closeMenu = services.policyChanges.closeMenu,
  defaultDriverScore = defaultDriverScore,
  formatPerkIconData = services.premiums.formatPerkIconData,
  getPlCoverageOptionValue = getPlCoverageOptionValue,
  quickRepairExtraPrice = quickRepairExtraPrice,
  refreshTestDriveChargeEstimate = services.repairs.refreshTestDriveChargeEstimate,
  sendUIData = services.policyChanges.sendUIData,
  testDriveDamagePlayerShare = testDriveDamagePlayerShare,
  tetherRange = services.repairs.tetherRange,
})
local function getInvVehs()
  return insuranceState.invVehs
end

M.genericVehNeedsRepair = services.repairs.genericVehNeedsRepair
M.makeRepairClaim = services.repairs.makeRepairClaim
M.makeTestDriveDamageClaim = services.repairs.makeTestDriveDamageClaim
M.startRepairInstant = services.repairs.startRepairInstant
M.startRepair = services.repairs.startRepair
M.inventoryVehNeedsRepair = services.repairs.inventoryVehNeedsRepair
M.missionStartRepairCallback = services.repairs.missionStartRepairCallback
M.closeMenu = services.policyChanges.closeMenu
M.repairPartConditions = services.repairs.repairPartConditions
M.expediteRepair = services.ui.expediteRepair
M.isRoadSideAssistanceFree = services.ui.isRoadSideAssistanceFree
M.sendChooseInsuranceDataToTheUI = services.policyChanges.sendChooseInsuranceDataToTheUI
M.sendChangeInsuranceDataToTheUI = services.policyChanges.sendChangeInsuranceDataToTheUI
M.calculateAddVehiclePrice = services.premiums.calculateAddVehiclePrice
M.calculateInsurancePremium = services.premiums.calculateInsurancePremium
M.calculateVehiclePremium = services.premiums.calculateVehiclePremium
M.saveNewInsuranceCoverageOptions = services.ui.saveNewInsuranceCoverageOptions
M.saveNewVehicleCoverageOptions = services.ui.saveNewVehicleCoverageOptions
M.openChooseInsuranceScreen = services.ui.openChooseInsuranceScreen
M.useRoadsideAssistance = services.ui.useRoadsideAssistance

M.getInsuranceClassFromVehicleShoppingData = services.premiums.getInsuranceClassFromVehicleShoppingData
M.getInsuranceDataById = services.ui.getInsuranceDataById
M.getVehInsuranceInfo = services.ui.getVehInsuranceInfo
M.getQuickRepairExtraPrice = services.ui.getQuickRepairExtraPrice
M.getInvVehRepairTime = services.ui.getInvVehRepairTime
M.getPlayerInsurancesData = services.ui.getPlayerInsurancesData
M.getPlHistory = function()
  return overhaul_career_repair_insuranceHistory.getPlHistory()
end
M.getTestDriveClaimPrice = services.ui.getTestDriveClaimPrice
M.getTestDriveDamagePlayerShare = services.ui.getTestDriveDamagePlayerShare
M.handleTestDriveEndDamage = services.repairs.handleTestDriveEndDamage
M.refreshTestDriveChargeEstimate = services.repairs.refreshTestDriveChargeEstimate
M.getDefaultInsuranceForClassId = services.ui.getDefaultInsuranceForClassId
M.getDriverScore = services.repairs.getDriverScore
M.resetDriverScore = services.ui.resetDriverScore
M.getPlayerAbstractData = services.policyChanges.getPlayerAbstractData

M.startRepairInPlace = services.repairs.startRepairInPlace
M.startRepairInGarage = services.repairs.startRepairInGarage
M.openMenu = services.ui.openMenu
M.sendUIData = services.policyChanges.sendUIData
M.changeInvVehInsuranceCoverageOptions = services.policyChanges.changeInvVehInsuranceCoverageOptions
M.changeInvVehInsurance = services.policyChanges.changeInvVehInsurance

-- hooks
M.onUpdate = function(...)
  services.repairs.onUpdate(...)
  services.premiums.onUpdate(...)
end
M.onOverhaulActive = function(...)
  services.repairs.onOverhaulActive(...)
  services.premiums.onOverhaulActive(...)
end
M.onClientEndMission = services.repairs.onClientEndMission
M.onExtensionUnloaded = services.repairs.onExtensionUnloaded
M.onOverhaulSaveCurrentProfile = services.premiums.onOverhaulSaveCurrentProfile
M.onOverhaulComputerAddFunctions = services.ui.onOverhaulComputerAddFunctions
M.onVehicleSwitched = services.premiums.onVehicleSwitched
M.onMenuClosed = services.ui.onMenuClosed
M.onExitInsurancesComputerScreen = services.ui.onExitInsurancesComputerScreen
M.onOverhaulVehicleSaveFinished = services.ui.onOverhaulVehicleSaveFinished
M.onOverhaulTestDriveStarted = services.repairs.onOverhaulTestDriveStarted

-- from vehicle inventory
M.onOverhaulVehicleAddedToInventory = services.policyChanges.onOverhaulVehicleAddedToInventory
M.onOverhaulVehicleAdded = services.policyChanges.onOverhaulVehicleAdded
M.onOverhaulVehicleRemoved = services.policyChanges.onVehicleRemovedFromInventory

-- perks
M.getInvVehFuelDiscountData = services.ui.getInvVehFuelDiscountData
M.getPerkValueByInvVehId = services.ui.getPerkValueByInvVehId
M.getPerkValueByInsuranceId = services.ui.getPerkValueByInsuranceId


-- internal use only
M.getActualRepairPrice = services.premiums.getActualRepairPrice
M.getPlCoverageOptionValue = getPlCoverageOptionValue
M.addToPlHistory = function(data)
  return overhaul_career_repair_insuranceHistory.addToPlHistory(data)
end
M.formatPerkIconData = services.premiums.formatPerkIconData
M.getRenewsIn = services.premiums.getRenewsIn
M.topUpRoadsideAssistance = services.ui.topUpRoadsideAssistance
M.getDriverScoreResetCost = services.ui.getDriverScoreResetCost
M.sanitizeCoverageOption = services.premiums.sanitizeCoverageOption

M.getDriverScoreTierData = services.repairs.getDriverScoreTierData
M.doesInsuranceExist = services.ui.doesInsuranceExist
M.getInsuranceName = services.ui.getInsuranceName
M.getAccidentForgivenessCount = services.ui.getAccidentForgivenessCount
M.getInvVehs = getInvVehs

-- career debug
M.resetPlPolicyData = function()
  services.policies.loadInsurancesData(true)
end
M.setDriverScore = services.ui.setDriverScore
M.getInsuranceRepairDriverScorePenalty = services.repairs.getInsuranceRepairDriverScorePenalty

M.activity = require('overhaul/career/repair/insurance/activity')(M)
return M
