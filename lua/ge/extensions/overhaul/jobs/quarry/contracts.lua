-- Quarry offers, delivery progress, payout and saved contract state.
-- Read config and state, generation steps, acceptance, delivery, settlement and public exports.
local recordJob = require("overhaul/lib/progression/logbookFeed").register("overhaul.quarryContractCompleted", {
  title = "Quarry contract completed", label = "Jobs", icon = "deliveryTruck"
}, "jobs/quarry/contracts.lua")

local M = {}

-- Config ------------------------------------------------------------------------------------------

local Config = overhaul_jobs_quarry_config
local skillRewards = require("overhaul/lib/jobs/skillRewards")

-- State -------------------------------------------------------------------------------------------

local ContractSystem = {
  availableContracts = {},
  activeContract = nil,
  lastRefreshDay = -999,
  contractProgress = {
    deliveredTons = 0,
    totalPaidSoFar = 0,
    startTime = 0,
    deliveryCount = 0,
    deliveredItems = 0
  },
  nextContractSpawnSimTime = nil,
  contractsGeneratedToday = 0,
  expiredContractsTotal = 0,
  initialContractsGenerated = false,
  simTimeAccumulator = 0,
}

local PlayerData = {
  contractsCompleted = 0,
  contractsFailed = 0
}

-- Shared helpers ---------------------------------------------------------------------------------

local function isCareerMode()
  local career = overhaul_career_career
  return career and type(career.isActive) == "function" and career.isActive()
end

local function pickTier(contractsConfig, availableGroups)
  if not contractsConfig or not contractsConfig.tiers or #contractsConfig.tiers == 0 then
    return nil
  end
  local maxTier = #contractsConfig.tiers
  if isCareerMode() and availableGroups and #availableGroups > 0 then
    local firstGroup = availableGroups[1]
    if firstGroup and firstGroup.associatedOrganization then
      local organizationId = firstGroup.associatedOrganization
      local organization = overhaul_world_organizations.getOrganization(organizationId)
      if organization and organization.reputation and organization.reputation.level ~= nil then
        local reputationLevel = organization.reputation.level
        if reputationLevel == -1 or reputationLevel == 0 then
          maxTier = 1
        elseif reputationLevel == 1 then
          maxTier = 2
        elseif reputationLevel == 2 then
          maxTier = 3
        elseif reputationLevel == 3 then
          maxTier = 4
        end
        maxTier = math.min(maxTier, #contractsConfig.tiers)
      end
    end
  end
  local totalWeight = 0
  for i = 1, maxTier do
    local tier = contractsConfig.tiers[i]
    if tier then
      local weight = tier.weight or 0
      totalWeight = totalWeight + weight
    end
  end
  if totalWeight <= 0 then return nil end
  local roll = math.random() * totalWeight
  local cumulativeWeight = 0
  for i = 1, maxTier do
    local tier = contractsConfig.tiers[i]
    if tier then
      local weight = tier.weight or 0
      cumulativeWeight = cumulativeWeight + weight
      if roll <= cumulativeWeight then
        return i
      end
    end
  end
  return nil
end

local function getCurrentGameHour()
  if core_environment then
    local timeOfDay = core_environment.getTimeOfDay()
    if timeOfDay and type(timeOfDay) == "table" and timeOfDay.time then
      return timeOfDay.time * 24
    elseif timeOfDay and type(timeOfDay) == "number" then
      return timeOfDay * 24
    end
  end
  local contractsConfig = Config.contracts or {}
  return contractsConfig.defaultGameHour or 12
end

-- Facilities, materials and reward scaling ------------------------------------------------------

local function getFacilityForZone(zoneTag)
  if not zoneTag then return nil end
  local facilities = Config.facilities
  if not facilities then return nil end
  for _, facility in pairs(facilities) do
    if facility.sites and facility.sites[zoneTag] then
      return facility
    end
  end
  return nil
end

local function getFacilityIdForZone(zoneTag)
  if not zoneTag then return nil end
  local facilities = Config.facilities
  if not facilities then return nil end
  for facilityKey, facility in pairs(facilities) do
    if facility.sites and facility.sites[zoneTag] then
      return facility.id or facilityKey
    end
  end
  return nil
end

local function getFacilityPayMultiplier(zoneTag)
  local facility = getFacilityForZone(zoneTag)
  if not facility then
    return nil
  end
  if facility.payMultiplier == nil then
    return nil
  end
  return facility.payMultiplier
end

local function scaleMoneyForDifficulty(amount)
  local value = math.max(0, math.floor(tonumber(amount) or 0))
  if not overhaul_career_career.isActive() then
    return value
  end
  local rewardData = { money = { amount = value, canBeNegative = false } }
  overhaul_career_economy_difficultyMode.scalePaymentRewardData(rewardData, {includeMoney = true})
  return math.max(0, math.floor((rewardData.money and rewardData.money.amount or value) + 0.5))
end

local function scaleProgressionForDifficulty(amount)
  local value = math.max(0, math.floor(tonumber(amount) or 0))
  if not overhaul_career_career.isActive() then
    return value
  end
  local rewardData = { ["careerSkills-operator"] = { amount = value, canBeNegative = false } }
  overhaul_career_economy_difficultyMode.scalePaymentRewardData(rewardData, {includeMoney = false})
  return math.max(0, math.floor((rewardData["careerSkills-operator"] and rewardData["careerSkills-operator"].amount or value) + 0.5))
end

local function getContractsConfig(zoneTag)
  local facility = getFacilityForZone(zoneTag)
  if facility and facility.contracts then
    return facility.contracts
  end
  return Config.contracts or {}
end

local function getContractsConfigFromGroups(availableGroups)
  if availableGroups and #availableGroups > 0 then
    local zoneTag = availableGroups[1].secondaryTag
    if zoneTag then
      return getContractsConfig(zoneTag)
    end
  end
  return Config.contracts or {}
end

local function getFacilityMaterials(zoneTag)
  local facility = getFacilityForZone(zoneTag)
  if not facility or not facility.sites then return {} end
  local facilityMaterials = {}
  for siteTag, siteData in pairs(facility.sites) do
    if siteData.materials then
      for matKey, _ in pairs(siteData.materials) do
        facilityMaterials[matKey] = true
      end
    end
  end
  return facilityMaterials
end

local function getMaterialsByTypeName(typeName)
  local materials = {}
  if not Config.materials then return materials end
  for matKey, matConfig in pairs(Config.materials) do
    if matConfig.typeName == typeName then
      table.insert(materials, matKey)
    end
  end
  return materials
end

local function getTypeNameFromMaterial(materialType)
  if not materialType then return nil end
  local matConfig = Config.materials and Config.materials[materialType]
  return matConfig and matConfig.typeName or nil
end

-- Contract generation ---------------------------------------------------------------------------

local function newContractId()
  local function taken(id)
    if ContractSystem.activeContract and ContractSystem.activeContract.id == id then return true end
    for _, contract in ipairs(ContractSystem.availableContracts or {}) do
      if contract.id == id then return true end
    end
    return false
  end
  local id = os.time() + math.random(1000, 9999)
  while taken(id) do id = id + 1 end
  return id
end

-- field ends generation after the draws already made.
local function chooseContractTier(contractsConfig, availableGroups)
  local tier = pickTier(contractsConfig, availableGroups)
  if not tier then
    return nil
  end
  local tierData = contractsConfig.tiers[tier]
  if not tierData then
    return nil
  end
  local tierStr = tostring(tier)
  if contractsConfig.bulkChance == nil then
    return nil
  end
  local isBulk = math.random() < contractsConfig.bulkChance
  if tierData.mixChance == nil then
    return nil
  end
  local mixChance = tierData.mixChance
  return {tier = tier, tierData = tierData, tierStr = tierStr, isBulk = isBulk, mixChance = mixChance}
end

local function appendValidMaterial(validMaterialsByType, matKey, matConfig, tierStr)
  local tierRange = matConfig.tiers and matConfig.tiers[tierStr]
  if not tierRange or type(tierRange) ~= "table" or #tierRange ~= 2 then return end
  local minVal, maxVal = tierRange[1], tierRange[2]
  if not (minVal > 0 and maxVal >= minVal) then return end
  local typeName = matConfig.typeName
  if not typeName then return end
  if not validMaterialsByType[typeName] then validMaterialsByType[typeName] = {} end
  if matConfig.contractChance ~= nil then
    table.insert(validMaterialsByType[typeName], {
      key = matKey, config = matConfig, range = tierRange, weight = matConfig.contractChance
    })
  end
end

local function collectValidMaterialsByType(tierStr, zoneTag)
  local availableMaterialKeys = getFacilityMaterials(zoneTag)
  local validMaterialsByType = {}
  for matKey, matConfig in pairs(Config.materials) do
    if availableMaterialKeys[matKey] then appendValidMaterial(validMaterialsByType, matKey, matConfig, tierStr) end
  end
  local availableTypeNames = {}
  for typeName, _ in pairs(validMaterialsByType) do
    table.insert(availableTypeNames, typeName)
  end
  return validMaterialsByType, availableTypeNames
end

local function pickMaterialType(validMaterialsByType, availableTypeNames)
  if #availableTypeNames == 0 then
    return nil
  end
  local selectedTypeName = availableTypeNames[math.random(#availableTypeNames)]
  local validMaterials = validMaterialsByType[selectedTypeName]
  if #validMaterials == 0 then
    return nil
  end
  return selectedTypeName, validMaterials
end

-- Two to N materials, each drawn by weight without repeats; topped up in candidate order when short.
local function pickMixedMaterials(validMaterials)
  local selectedMaterials = {}
  local numToSelect = math.random(2, #validMaterials)
  local remainingMaterials = {}
  for _, entry in ipairs(validMaterials) do
    table.insert(remainingMaterials, entry)
  end
  for i = 1, numToSelect do
    if #remainingMaterials == 0 then break end
    local totalWeight = 0
    for _, entry in ipairs(remainingMaterials) do
      totalWeight = totalWeight + entry.weight
    end
    local roll = math.random() * totalWeight
    local cumulativeWeight = 0
    for j = #remainingMaterials, 1, -1 do
      local entry = remainingMaterials[j]
      cumulativeWeight = cumulativeWeight + entry.weight
      if roll <= cumulativeWeight then
        table.insert(selectedMaterials, entry)
        table.remove(remainingMaterials, j)
        break
      end
    end
  end
  if #selectedMaterials < 2 then
    for _, entry in ipairs(validMaterials) do
      local found = false
      for _, sel in ipairs(selectedMaterials) do
        if sel.key == entry.key then found = true break end
      end
      if not found then
        table.insert(selectedMaterials, entry)
        if #selectedMaterials >= 2 then break end
      end
    end
  end
  return selectedMaterials
end

-- One material drawn by weight; when no weight reaches the roll, the first candidate is used.
local function pickSingleMaterial(validMaterials)
  local selectedMaterials = {}
  local totalWeight = 0
  for _, entry in ipairs(validMaterials) do
    totalWeight = totalWeight + entry.weight
  end
  local roll = math.random() * totalWeight
  local cumulativeWeight = 0
  for _, entry in ipairs(validMaterials) do
    cumulativeWeight = cumulativeWeight + entry.weight
    if roll <= cumulativeWeight then
      table.insert(selectedMaterials, entry)
      break
    end
  end
  if #selectedMaterials == 0 then
    table.insert(selectedMaterials, validMaterials[1])
  end
  return selectedMaterials
end

-- Mix or single pick. The mix draw happens only when the candidates allow a mix.
local function pickMaterialSelection(validMaterials, mixChance)
  local shouldMix = #validMaterials >= 2 and math.random() < mixChance
  local selectedMaterials
  if shouldMix then
    selectedMaterials = pickMixedMaterials(validMaterials)
  else
    selectedMaterials = pickSingleMaterial(validMaterials)
  end
  if #selectedMaterials == 0 then
    return nil
  end
  return selectedMaterials
end

-- A group can take the drawn type when one of its materials has that type name; one is drawn uniformly.
local function pickCompatibleGroup(availableGroups, selectedTypeName)
  local compatibleGroups = {}
  for _, g in ipairs(availableGroups) do
    if g.materials then
      for _, matKey in ipairs(g.materials) do
        local gMatConfig = Config.materials[matKey]
        if gMatConfig and gMatConfig.typeName == selectedTypeName then
          table.insert(compatibleGroups, g)
          break
        end
      end
    elseif g.materialType then
      local gMatConfig = Config.materials[g.materialType]
      if gMatConfig and gMatConfig.typeName == selectedTypeName then
        table.insert(compatibleGroups, g)
      end
    end
  end
  if #compatibleGroups == 0 then
    return nil
  end
  return compatibleGroups[math.random(#compatibleGroups)]
end

local function rollPayTerms(tierData)
  if not tierData.payMultiplier or not tierData.payMultiplier.min or not tierData.payMultiplier.max then
    return nil
  end
  local payMultiplier = math.random(tierData.payMultiplier.min * 100, tierData.payMultiplier.max * 100) / 100
  if tierData.basePay == nil then
    return nil
  end
  local basePay = tierData.basePay
  return payMultiplier, basePay
end

local function rollRequiredLoad(matConfig, selectedMaterials, tierStr)
  local requiredTons = 0
  local requiredItems = 0
  local estimatedTrips = 1
  local materialRequirements = {}
  if matConfig.unitType == "item" then
    for _, entry in ipairs(selectedMaterials) do
      local matRequiredItems = math.random(entry.range[1], entry.range[2])
      materialRequirements[entry.key] = matRequiredItems
      requiredItems = requiredItems + matRequiredItems
    end
    if requiredItems == 0 then
      return nil
    end
    estimatedTrips = 1
    requiredTons = 0
  else
    local tierRange = matConfig.tiers and matConfig.tiers[tierStr]
    if not tierRange or type(tierRange) ~= "table" or #tierRange ~= 2 then
      return nil
    end
    requiredTons = math.random(tierRange[1], tierRange[2])
    if not matConfig.targetLoad then
      return nil
    end
    estimatedTrips = math.ceil(requiredTons / (matConfig.targetLoad / 1000))
  end
  return requiredTons, requiredItems, estimatedTrips, materialRequirements
end

local function calculateUnitPay(matConfig, materialRequirements, requiredTons)
  local unitPay = 0
  if matConfig.unitType == "item" then
    for matKey, matRequiredItems in pairs(materialRequirements) do
      local matConfigForPay = Config.materials[matKey]
      if matConfigForPay then
        if matConfigForPay.payPerUnit == nil then
          return nil
        end
        unitPay = unitPay + (matRequiredItems * matConfigForPay.payPerUnit)
      end
    end
  else
    if matConfig.payPerUnit == nil then
      return nil
    end
    unitPay = requiredTons * matConfig.payPerUnit
  end
  return unitPay
end

local function calculateTotalPayout(basePay, unitPay, payMultiplier, facilityPayMultiplier)
  local totalPayout = math.floor((basePay + (unitPay * payMultiplier)) * facilityPayMultiplier)
  local contractJobIndex = overhaul_career_career.isActive() and overhaul_career_economy_globalEconomy.getJobMarketIndex() or 1.0
  totalPayout = math.floor((totalPayout * contractJobIndex) + 0.5)
  return scaleMoneyForDifficulty(totalPayout)
end

local function calculateXpReward(matConfig, requiredItems, requiredTons)
  local xpReward = 0
  if matConfig.unitType == "item" then
    xpReward = math.floor((requiredItems or 0) * 10)
  else
    xpReward = math.floor((requiredTons or 0) * 10)
  end
  return scaleProgressionForDifficulty(xpReward)
end

-- Contract generation -----------------------------------------------------------------------------

local function buildGeneratedContract(prepared)
  return {
    id = newContractId(),
    name = prepared.name,
    tier = prepared.tier,
    material = prepared.materialType,
    materialTypeName = prepared.selectedTypeName,
    requiredTons = prepared.requiredTons,
    requiredItems = prepared.requiredItems,
    materialRequirements = prepared.materialRequirements,
    unitType = prepared.matConfig.unitType,
    units = prepared.matConfig.units,
    isBulk = prepared.isBulk,
    basePay = prepared.basePay,
    unitPay = prepared.unitPay,
    payMultiplier = prepared.payMultiplier,
    facilityPayMultiplier = prepared.facilityPayMultiplier,
    totalPayout = prepared.totalPayout,
    xpReward = prepared.xpReward,
    facilityId = prepared.facilityId,
    destination = {
      pos = prepared.group.destination and prepared.group.destination.pos and vec3(prepared.group.destination.pos) or nil,
      name = prepared.group.destination and prepared.group.destination.name or nil,
      originZoneTag = prepared.group.secondaryTag,
    },
    group = nil,
    groupTag = prepared.group.secondaryTag,
    estimatedTrips = prepared.estimatedTrips,
    createdAtSimTime = prepared.createdAtSimTime,
    expiresAtSimTime = prepared.expiresAtSimTime,
    expirationHours = prepared.expirationHours,
    createdAt = getCurrentGameHour(),
  }
end

local function generateContract(availableGroups, expirationOffset)
  if not availableGroups or #availableGroups == 0 then return nil end
  if not Config.materials or next(Config.materials) == nil then return nil end
  local contractsConfig = getContractsConfigFromGroups(availableGroups)
  if not contractsConfig or not contractsConfig.tiers or #contractsConfig.tiers == 0 then return nil end
  expirationOffset = expirationOffset or 0
  local terms = chooseContractTier(contractsConfig, availableGroups)
  if not terms then return nil end
  local tier, tierData, tierStr = terms.tier, terms.tierData, terms.tierStr
  local isBulk, mixChance = terms.isBulk, terms.mixChance
  local zoneTag = availableGroups[1] and availableGroups[1].secondaryTag
  local validMaterialsByType, availableTypeNames = collectValidMaterialsByType(tierStr, zoneTag)
  local selectedTypeName, validMaterials = pickMaterialType(validMaterialsByType, availableTypeNames)
  if not selectedTypeName then return nil end
  local selectedMaterials = pickMaterialSelection(validMaterials, mixChance)
  if not selectedMaterials then return nil end
  local primaryMaterial = selectedMaterials[1]
  local materialType = primaryMaterial.key
  local matConfig = primaryMaterial.config
  local group = pickCompatibleGroup(availableGroups, selectedTypeName)
  if not group then return nil end
  local payMultiplier, basePay = rollPayTerms(tierData)
  if not payMultiplier then return nil end
  local requiredTons, requiredItems, estimatedTrips, materialRequirements = rollRequiredLoad(matConfig, selectedMaterials, tierStr)
  if not estimatedTrips then return nil end
  local unitPay = calculateUnitPay(matConfig, materialRequirements, requiredTons)
  if not unitPay then return nil end
  local facilityPayMultiplier = getFacilityPayMultiplier(group.secondaryTag)
  if not facilityPayMultiplier then return nil end
  local totalPayout = calculateTotalPayout(basePay, unitPay, payMultiplier, facilityPayMultiplier)
  local xpReward = calculateXpReward(matConfig, requiredItems, requiredTons)
  local name = selectedTypeName
  if isBulk then name = "Bulk " .. name end
  if contractsConfig.contractTTL == nil then return nil end
  local contractTTL = contractsConfig.contractTTL
  local createdAtSimTime = ContractSystem.simTimeAccumulator
  local expiresAtSimTime = createdAtSimTime + (contractTTL * 3600)
  local expirationHours = contractTTL
  local facilityId = getFacilityIdForZone(group.secondaryTag)
  return buildGeneratedContract({
    name = name, tier = tier, materialType = materialType, selectedTypeName = selectedTypeName,
    requiredTons = requiredTons, requiredItems = requiredItems, materialRequirements = materialRequirements, matConfig = matConfig,
    isBulk = isBulk, basePay = basePay, unitPay = unitPay, payMultiplier = payMultiplier,
    facilityPayMultiplier = facilityPayMultiplier, totalPayout = totalPayout, xpReward = xpReward, facilityId = facilityId,
    group = group, estimatedTrips = estimatedTrips, createdAtSimTime = createdAtSimTime, expiresAtSimTime = expiresAtSimTime,
    expirationHours = expirationHours,
  })
end

local function sortContracts()
  table.sort(ContractSystem.availableContracts, function(a, b)
    if a.tier == b.tier then return a.totalPayout < b.totalPayout end
    return a.tier < b.tier
  end)
end

local function generateInitialContracts(availableGroups)
  ContractSystem.availableContracts = {}
  if not availableGroups or #availableGroups == 0 then return end
  local contractsConfig = getContractsConfigFromGroups(availableGroups)
  local initialCount = contractsConfig.initialContracts or 4
  local generateInterval = contractsConfig.generateInterval or 2
  local secondsPerContract = generateInterval > 0 and (3600 / generateInterval) or 1800
  for i = 1, initialCount do
    local expirationOffset = i - 1
    local contract = generateContract(availableGroups, expirationOffset)
    if contract then
      table.insert(ContractSystem.availableContracts, contract)
    end
  end
  sortContracts()
  ContractSystem.nextContractSpawnSimTime = ContractSystem.simTimeAccumulator + secondsPerContract
  ContractSystem.contractsGeneratedToday = initialCount
  ContractSystem.initialContractsGenerated = true
end

local function trySpawnNewContract(availableGroups)
  local contractsConfig = getContractsConfigFromGroups(availableGroups)
  if #ContractSystem.availableContracts >= (contractsConfig.maxActiveContracts or 6) then
    return false
  end
  local generateInterval = contractsConfig.generateInterval or 2
  local secondsPerContract = generateInterval > 0 and (3600 / generateInterval) or 1800
  if not ContractSystem.nextContractSpawnSimTime then
    ContractSystem.nextContractSpawnSimTime = ContractSystem.simTimeAccumulator + secondsPerContract
    return false
  end
  local secondsUntilSpawn = ContractSystem.nextContractSpawnSimTime - ContractSystem.simTimeAccumulator
  if secondsUntilSpawn <= 0 then
    local contract = generateContract(availableGroups)
    if contract then
      table.insert(ContractSystem.availableContracts, contract)
      sortContracts()
      ContractSystem.nextContractSpawnSimTime = ContractSystem.simTimeAccumulator + secondsPerContract
      ContractSystem.contractsGeneratedToday = (ContractSystem.contractsGeneratedToday or 0) + 1
      ui_message("New contract available: " .. contract.name, 4, "info")
      -- formatContractForUI is defined further down, so reach it through M.
      guihooks.trigger('contractGenerated', { contractData = M.formatContractForUI(contract) })
      Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Mission_Unlock_01')
      return true
    end
  end
  return false
end

local function getContractHoursRemaining(contract)
  if not contract or not contract.expiresAtSimTime then return 99 end
  local currentSimTime = ContractSystem.simTimeAccumulator
  local secondsRemaining = contract.expiresAtSimTime - currentSimTime
  if secondsRemaining < 0 then return 0 end
  return secondsRemaining / 3600
end

local function formatContractForUI(contract)
  if not contract then return nil end
  return {
    id = contract.id,
    name = contract.name,
    tier = contract.tier,
    material = contract.material,
    materialTypeName = contract.materialTypeName,
    requiredTons = contract.requiredTons,
    requiredItems = contract.requiredItems,
    isBulk = contract.isBulk,
    totalPayout = contract.totalPayout,
    paymentType = contract.paymentType,
    groupTag = contract.groupTag,
    estimatedTrips = contract.estimatedTrips,
    expiresAtSimTime = contract.expiresAtSimTime,
    hoursRemaining = getContractHoursRemaining(contract),
    expirationHours = contract.expirationHours,
    destinationName = contract.destination and contract.destination.name or nil,
    originZoneTag = contract.destination and contract.destination.originZoneTag or contract.groupTag,
  }
end

local function checkContractExpiration()
  local expiredCount = 0
  local remainingContracts = {}
  local expiredContracts = {}
  local currentSimTime = ContractSystem.simTimeAccumulator
  for _, contract in ipairs(ContractSystem.availableContracts) do
    local expiresAtSimTime = contract.expiresAtSimTime
    if expiresAtSimTime and currentSimTime >= expiresAtSimTime then
      expiredCount = expiredCount + 1
      ContractSystem.expiredContractsTotal = (ContractSystem.expiredContractsTotal or 0) + 1
      table.insert(expiredContracts, contract.id)
      guihooks.trigger('contractExpired', {
        contractId = contract.id,
        contractData = formatContractForUI(contract)
      })
    else
      table.insert(remainingContracts, contract)
    end
  end
  if expiredCount > 0 then
    ContractSystem.availableContracts = remainingContracts
    ui_message(expiredCount .. " contract" .. (expiredCount > 1 and "s" or "") .. " expired", 3, "warning")
    return expiredCount
  end
  return 0
end

local function shouldRefreshContracts(zoneTag)
  return false
end

local function checkContractCompletion()
  if not ContractSystem.activeContract then return false end
  local contract = ContractSystem.activeContract
  local p = ContractSystem.contractProgress
  if contract.unitType == "item" then
    local delivered = p.deliveredItems or 0
    return delivered >= (contract.requiredItems or 0)
  end
  return (p and p.deliveredTons or 0) >= (contract.requiredTons or math.huge)
end

local function activeVehicleLoanerCut()
  if not isCareerMode() then return 0 end
  local vehId = be:getPlayerVehicleID(0)
  if not vehId then return 0 end
  local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)
  if not inventoryId then return 0 end
  local vehicle = overhaul_career_garage_inventory.getVehicle(inventoryId)
  if not vehicle or not vehicle.owningOrganization then return 0 end
  local organization = overhaul_world_organizations.getOrganization(vehicle.owningOrganization)
  if not organization or not organization.reputation or organization.reputation.level == nil or not organization.reputationLevels then return 0 end
  local levelIndex = organization.reputation.level + 2
  if organization.reputationLevels[levelIndex] and organization.reputationLevels[levelIndex].loanerCut then
    return organization.reputationLevels[levelIndex].loanerCut.value or 0
  end
  return 0
end

local function acceptContract(contractIndex, getZonesByTypeName)
  if ContractSystem.activeContract then return nil end
  local contract = ContractSystem.availableContracts[contractIndex]
  if not contract then return end
  if isCareerMode() then
    local operatorLevel = skillRewards.getSkillLevelRaw("careerSkills-operator", {"careerSkills-operator", "operator"})
    if operatorLevel < 10 then
      ui_message("Reach Operator level 10 to accept Quarry Work contracts.", 6, "Quarry Work Locked", "warning")
      return nil
    end
  end
  local contractTypeName = contract.materialTypeName
  if not contractTypeName then
    return nil
  end
  local compatibleZones = getZonesByTypeName(contractTypeName)
  if #compatibleZones == 0 then
    ui_message(string.format("No zones available for %s!", contractTypeName:upper()), 5, "error")
    return nil
  end
  table.remove(ContractSystem.availableContracts, contractIndex)
  contract.group = nil
  contract.loadingZoneTag = nil
  local loanerCut = activeVehicleLoanerCut()
  ContractSystem.activeContract = contract
  ContractSystem.contractProgress = {
    deliveredTons = 0,
    totalPaidSoFar = 0,
    startTime = os.clock(),
    deliveryCount = 0,
    deliveredItems = 0,
    loanerCut = loanerCut
  }
  Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Mission_Start_01')
  local zoneNames = {}
  for _, z in ipairs(compatibleZones) do
    table.insert(zoneNames, z.secondaryTag or "Unknown")
  end
  ui_message(string.format("Contract accepted! Drive to any %s zone to load: %s",
    contractTypeName:upper(), table.concat(zoneNames, ", ")), 8, "info")
  return contract, compatibleZones
end

local function abandonContract(onCleanup)
  if not ContractSystem.activeContract then return end
  local contract = ContractSystem.activeContract
  local zoneTag = contract.loadingZoneTag or contract.groupTag
  local totalPay = contract.totalPayout or 0
  local contractsConfig = getContractsConfig(zoneTag)
  local abandonPenaltyPercent = contractsConfig.abandonPenalty or 0
  local penaltyAmount = math.floor(totalPay * abandonPenaltyPercent)
  ui_message(string.format("Contract abandoned! Penalty: $%d", penaltyAmount), 6, "warning")
  local success, err = pcall(function()
    local career = overhaul_career_career
    if career and type(career.isActive) == "function" and career.isActive() then
      local paymentModule = overhaul_career_economy_payment
      if paymentModule and type(paymentModule.reward) == "function" and penaltyAmount > 0 then
        paymentModule.reward({
          money = { amount = -penaltyAmount, canBeNegative = true }
        }, require("overhaul/lib/finance/metadata").tag({ label = "Contract Abandonment", tags = {"gameplay", "mission", "penalty"} }, "fine"))
      end
    end
  end)
  PlayerData.contractsFailed = (PlayerData.contractsFailed or 0) + 1
  ContractSystem.activeContract = nil
  ContractSystem.contractProgress = {deliveredTons = 0, totalPaidSoFar = 0, deliveryCount = 0, deliveredItems = 0}
  if onCleanup then onCleanup(true) end
end

local function failContract(penalty, message, msgType, onCleanup)
  if not ContractSystem.activeContract then
    if onCleanup then onCleanup(true) end
    return
  end
  penalty = penalty or 0
  msgType = msgType or "warning"
  if message then ui_message(message, 5, msgType) end
  local penaltyAmount = math.abs(tonumber(penalty) or 0)
  local career = overhaul_career_career
  if penaltyAmount > 0 and career and type(career.isActive) == "function" and career.isActive() then
    local paymentModule = overhaul_career_economy_payment
    if paymentModule and type(paymentModule.reward) == "function" then
      paymentModule.reward({
        money = { amount = -penaltyAmount, canBeNegative = true }
      }, require("overhaul/lib/finance/metadata").tag({ label = "Contract Failure", tags = {"gameplay", "mission", "penalty"} }, "fine"))
    end
  end
  PlayerData.contractsFailed = (PlayerData.contractsFailed or 0) + 1
  ContractSystem.activeContract = nil
  ContractSystem.contractProgress = {deliveredTons = 0, totalPaidSoFar = 0, deliveryCount = 0, deliveredItems = 0}
  if onCleanup then onCleanup(true) end
end

local function deliveryReputation(zoneTag, contract)
  local organizationId, reputationGain
  local Zones = overhaul_jobs_quarry_zones
  if Zones and Zones.availableGroups then
    local activeGroup = nil
    for _, group in ipairs(Zones.availableGroups) do
      if group.secondaryTag == zoneTag then
        activeGroup = group
        break
      end
    end
    if activeGroup and activeGroup.associatedOrganization then
      organizationId = activeGroup.associatedOrganization
      local totalRepGain = 0
      local p = ContractSystem.contractProgress
      if contract.unitType == "item" and p.deliveredItemsByMaterial then
        for matKey, count in pairs(p.deliveredItemsByMaterial) do
          local matConfig = Config.materials and Config.materials[matKey]
          if matConfig and matConfig.reputationGain then
            totalRepGain = totalRepGain + (count * matConfig.reputationGain)
          end
        end
      elseif contract.unitType == "mass" and p.deliveredTons then
        local materialType = contract.material
        local matConfig = materialType and Config.materials and Config.materials[materialType]
        if matConfig and matConfig.reputationGain then
          totalRepGain = totalRepGain + (p.deliveredTons * matConfig.reputationGain)
        end
      end
      if totalRepGain > 0 then
        reputationGain = scaleProgressionForDifficulty(totalRepGain)
      end
    end
  end
  return organizationId, reputationGain
end

local function postContractPayout(contract, zoneTag, xpReward, settlement)
  local career = overhaul_career_career
  if career and type(career.isActive) == "function" and career.isActive() then
    local paymentModule = overhaul_career_economy_payment
    if paymentModule and type(paymentModule.payout) == "function" then
      local operatorLevel = skillRewards.getSkillLevel("careerSkills-operator", {"careerSkills-operator", "operator"})
      settlement.money = math.floor(settlement.money * skillRewards.getOperatorMoneyBonusMultiplier(2, operatorLevel) + 0.5)
      local organizationId, reputationGain
      organizationId, reputationGain = deliveryReputation(zoneTag, contract)
      -- The loaner cut can push the pay below zero; the contract still completes with a net debit.
      local accepted, problem = paymentModule.payout(require("overhaul/lib/finance/metadata").tagPayout({
        amount = settlement.money,
        xp = {["careerSkills-operator"] = xpReward},
        orgId = organizationId,
        rep = reputationGain,
        label = string.format("Contract: %s", contract.name),
        tags = {"gameplay", "mission", "reward", "delivery_dryBulk"},
        allowNetDebit = true,
      }, "activity:quarry", {vehicleRole = "player", locationId = getFacilityIdForZone(zoneTag)}))
      -- A refusal posts nothing, so the contract stays active for another attempt.
      if accepted ~= true then error("contract payout refused: " .. tostring(problem), 0) end
      settlement.paid = true
      recordJob({name = contract.name, money = settlement.money})
      Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')
      ui_message(string.format("CONTRACT COMPLETE! Earned $%d", settlement.money), 8, "success")
    end
  end
end

-- Contract settlement -----------------------------------------------------------------------------

local function completeContract(onCleanup, onClearProps)
  if not ContractSystem.activeContract then return end
  local contract = ContractSystem.activeContract
  local zoneTag = contract.loadingZoneTag or contract.groupTag
  local totalPay = math.floor(tonumber(contract.totalPayout) or 0)
  local xpReward = tonumber(contract.xpReward)
  if xpReward == nil then
    if contract.unitType == "item" then
      xpReward = math.floor((contract.requiredItems or 0) * 10)
    else
      xpReward = math.floor((contract.requiredTons or 0) * 10)
    end
    xpReward = scaleProgressionForDifficulty(xpReward)
  end
  xpReward = math.max(0, math.floor(xpReward or 0))
  local loanerCut = ContractSystem.contractProgress.loanerCut or 0
  if loanerCut > 0 then
    totalPay = math.floor(totalPay * (1 - loanerCut))
  end
  local settlement = {money = totalPay, paid = false}
  local success, err = pcall(function()
    postContractPayout(contract, zoneTag, xpReward, settlement)
  end)
  if not success and not settlement.paid then
    log("E", "loading", "Contract payout failed: " .. tostring(err))
    ui_message("Contract payout failed. The contract is still active; finish it again to collect the pay.", 8, "error")
    return false
  end
  if not settlement.paid then
    Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Mission_End_Success')
    ui_message(string.format("SANDBOX: Contract payout: $%d", settlement.money), 6, "success")
  end
  PlayerData.contractsCompleted = (PlayerData.contractsCompleted or 0) + 1
  ContractSystem.activeContract = nil
  ContractSystem.contractProgress = {deliveredTons = 0, totalPaidSoFar = 0, deliveryCount = 0, deliveredItems = 0}
  if onClearProps then onClearProps() end
  if onCleanup then onCleanup(true) end
end

-- Public API and game hooks ----------------------------------------------------------------------

M.ContractSystem = ContractSystem
M.PlayerData = PlayerData

M.getCurrentGameHour = getCurrentGameHour
M.generateContract = generateContract
M.sortContracts = sortContracts
M.generateInitialContracts = generateInitialContracts
M.trySpawnNewContract = trySpawnNewContract
M.checkContractExpiration = checkContractExpiration
M.getContractHoursRemaining = getContractHoursRemaining
M.shouldRefreshContracts = shouldRefreshContracts
M.checkContractCompletion = checkContractCompletion
M.acceptContract = acceptContract
M.abandonContract = abandonContract
M.failContract = failContract
M.completeContract = completeContract
M.getMaterialsByTypeName = getMaterialsByTypeName
M.getTypeNameFromMaterial = getTypeNameFromMaterial
M.updateSimTime = function(dt)
  ContractSystem.simTimeAccumulator = ContractSystem.simTimeAccumulator + dt
end
M.getSimTime = function()
  return ContractSystem.simTimeAccumulator
end
M.formatContractForUI = formatContractForUI
local function serializeVec3(vec)
  if not vec then return nil end
  return {x = vec.x, y = vec.y, z = vec.z}
end

local function deserializeVec3(tbl)
  if not tbl or not tbl.x or not tbl.y or not tbl.z then return nil end
  return vec3(tbl.x, tbl.y, tbl.z)
end

local function serializeContract(contract)
  if not contract then return nil end
  local serialized = {}
  for k, v in pairs(contract) do
    if k == "destination" and v and v.pos then
      serialized[k] = {
        pos = serializeVec3(v.pos),
        name = v.name,
        originZoneTag = v.originZoneTag
      }
    elseif k == "group" then
      serialized[k] = nil
    else
      serialized[k] = v
    end
  end
  if contract.groupTag and contract.groupTag:find("::", 1, true) then serialized.locationVersion = 2 end
  return serialized
end

local function deserializeContract(serialized)
  if not serialized then return nil end
  local contract = {}
  for k, v in pairs(serialized) do
    if k == "destination" and v and v.pos then
      contract[k] = {
        pos = deserializeVec3(v.pos),
        name = v.name,
        originZoneTag = v.originZoneTag
      }
    else
      contract[k] = v
    end
  end
  return contract
end

M.getFacilityPayMultiplier = getFacilityPayMultiplier
M.getContractsConfig = getContractsConfig
M.getContractsConfigFromGroups = getContractsConfigFromGroups
M.getFacilityIdForZone = getFacilityIdForZone
M.isCareerMode = isCareerMode
M.serializeContract = serializeContract
M.deserializeContract = deserializeContract
local function onExtensionLoaded()
end
M.onExtensionLoaded = onExtensionLoaded
M.loadingConfigLoaded = function()
  Config = overhaul_jobs_quarry_config
end

return M
