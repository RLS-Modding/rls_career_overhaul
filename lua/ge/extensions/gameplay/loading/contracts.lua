local M = {}

local Config = gameplay_loading_config

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

local function isCareerMode()
  local career = career_career
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
      local orgId = firstGroup.associatedOrganization
      local org = freeroam_organizations and freeroam_organizations.getOrganization(orgId)
      if org and org.reputation and org.reputation.level ~= nil then
        local repLevel = org.reputation.level
        if repLevel == -1 or repLevel == 0 then
          maxTier = 1
        elseif repLevel == 1 then
          maxTier = 2
        elseif repLevel == 2 then
          maxTier = 3
        elseif repLevel == 3 then
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
  local current = 0
  for i = 1, maxTier do
    local tier = contractsConfig.tiers[i]
    if tier then
      local weight = tier.weight or 0
      current = current + weight
      if roll <= current then
        return i
      end
    end
  end
  return nil
end

local function getCurrentGameHour()
  if core_environment and core_environment.getTimeOfDay then
    local tod = core_environment.getTimeOfDay()
    if tod and type(tod) == "table" and tod.time then
      return tod.time * 24
    elseif tod and type(tod) == "number" then
      return tod * 24
    end
  end
  local contractsConfig = Config.contracts or {}
  return contractsConfig.defaultGameHour or 12
end

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
    print(string.format("[Loading] No facility found for zone '%s'; cannot get pay multiplier.", zoneTag or "unknown"))
    return nil
  end
  if facility.payMultiplier == nil then
    print(string.format("[Loading] Facility '%s' missing payMultiplier; cannot get pay multiplier.", facility.name or "unknown"))
    return nil
  end
  return facility.payMultiplier
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

local function generateContract(availableGroups, expirationOffset)
  if not availableGroups or #availableGroups == 0 then return nil end
  if not Config.materials or next(Config.materials) == nil then
    print("[Loading] No materials configured in JSON; cannot generate contract.")
    return nil
  end

  local contractsConfig = getContractsConfigFromGroups(availableGroups)
  if not contractsConfig or not contractsConfig.tiers or #contractsConfig.tiers == 0 then
    print("[Loading] No contracts config or tiers defined; cannot generate contract.")
    return nil
  end
  
  expirationOffset = expirationOffset or 0
  local tier = pickTier(contractsConfig, availableGroups)
  if not tier then
    print("[Loading] Failed to pick valid tier; cannot generate contract.")
    return nil
  end
  
  local tierData = contractsConfig.tiers[tier]
  if not tierData then
    print(string.format("[Loading] Tier %d data not found; cannot generate contract.", tier))
    return nil
  end
  
  local tierStr = tostring(tier)

  if contractsConfig.bulkChance == nil then
    print("[Loading] bulkChance not defined in contracts config; cannot generate contract.")
    return nil
  end
  local isBulk = math.random() < contractsConfig.bulkChance
  
  if tierData.mixChance == nil then
    print(string.format("[Loading] mixChance not defined for tier %d; cannot generate contract.", tier))
    return nil
  end
  local mixChance = tierData.mixChance

  local zoneTag = availableGroups[1] and availableGroups[1].secondaryTag
  local availableMaterialKeys = getFacilityMaterials(zoneTag)

  local validMaterialsByType = {}
  for matKey, matConfig in pairs(Config.materials) do
    if availableMaterialKeys[matKey] then
      local tierRange = matConfig.tiers and matConfig.tiers[tierStr]
      if tierRange and type(tierRange) == "table" and #tierRange == 2 then
        local minVal = tierRange[1]
        local maxVal = tierRange[2]
        if minVal > 0 and maxVal >= minVal then
          local typeName = matConfig.typeName
          if typeName then
            if not validMaterialsByType[typeName] then
              validMaterialsByType[typeName] = {}
            end
            if matConfig.contractChance == nil then
              print(string.format("[Loading] Material '%s' missing contractChance; skipping.", matKey))
            else
              table.insert(validMaterialsByType[typeName], {
                key = matKey,
                config = matConfig,
                range = tierRange,
                weight = matConfig.contractChance
              })
            end
          end
        end
      end
    end
  end

  local availableTypeNames = {}
  for typeName, _ in pairs(validMaterialsByType) do
    table.insert(availableTypeNames, typeName)
  end
  
  if #availableTypeNames == 0 then
    print(string.format("[Loading] No materials with valid tier %s ranges available in zones", tierStr))
    return nil
  end
  
  local selectedTypeName = availableTypeNames[math.random(#availableTypeNames)]
  local validMaterials = validMaterialsByType[selectedTypeName]
  
  if #validMaterials == 0 then
    print(string.format("[Loading] No valid materials for typeName '%s' tier %s", selectedTypeName, tierStr))
    return nil
  end

  local shouldMix = #validMaterials >= 2 and math.random() < mixChance
  
  local selectedMaterials = {}
  if shouldMix then
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
      local current = 0
      for j = #remainingMaterials, 1, -1 do
        local entry = remainingMaterials[j]
        current = current + entry.weight
        if roll <= current then
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
  else
    local totalWeight = 0
    for _, entry in ipairs(validMaterials) do
      totalWeight = totalWeight + entry.weight
    end
    
    local roll = math.random() * totalWeight
    local current = 0
    for _, entry in ipairs(validMaterials) do
      current = current + entry.weight
      if roll <= current then
        table.insert(selectedMaterials, entry)
        break
      end
    end
    
    if #selectedMaterials == 0 then
      table.insert(selectedMaterials, validMaterials[1])
    end
  end
  
  if #selectedMaterials == 0 then
    print(string.format("[Loading] Failed to select materials for typeName '%s' tier %s", selectedTypeName, tierStr))
    return nil
  end
  
  local primaryMaterial = selectedMaterials[1]
  local materialType = primaryMaterial.key
  local matConfig = primaryMaterial.config
  
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
    print(string.format("[Loading] No groups available for typeName '%s'", selectedTypeName))
    return nil
  end
  
  local group = compatibleGroups[math.random(#compatibleGroups)]
  if not group then return nil end

  if not tierData.payMultiplier or not tierData.payMultiplier.min or not tierData.payMultiplier.max then
    print(string.format("[Loading] payMultiplier not properly defined for tier %d; cannot generate contract.", tier))
    return nil
  end
  local payMultiplier = math.random(tierData.payMultiplier.min * 100, tierData.payMultiplier.max * 100) / 100
  
  if tierData.basePay == nil then
    print(string.format("[Loading] basePay not defined for tier %d; cannot generate contract.", tier))
    return nil
  end
  local basePay = tierData.basePay

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
      print(string.format("[Loading] No valid material quantities generated for typeName '%s' tier %s", selectedTypeName, tierStr))
      return nil
    end
    
    estimatedTrips = 1
    requiredTons = 0
  else
    local tierRange = matConfig.tiers and matConfig.tiers[tierStr]
    if not tierRange or type(tierRange) ~= "table" or #tierRange ~= 2 then
      print("[Loading] Warning: No contract ranges for mass material " .. materialType .. " tier " .. tierStr)
      return nil
    end
    
    requiredTons = math.random(tierRange[1], tierRange[2])
    if not matConfig.targetLoad then
      print(string.format("[Loading] Material '%s' missing targetLoad; cannot generate contract.", materialType))
      return nil
    end
    estimatedTrips = math.ceil(requiredTons / (matConfig.targetLoad / 1000))
  end

  local unitPay = 0
  if matConfig.unitType == "item" then
    for matKey, matRequiredItems in pairs(materialRequirements) do
      local matConfigForPay = Config.materials[matKey]
      if matConfigForPay then
        if matConfigForPay.payPerUnit == nil then
          print(string.format("[Loading] Material '%s' missing payPerUnit; cannot generate contract.", matKey))
          return nil
        end
        unitPay = unitPay + (matRequiredItems * matConfigForPay.payPerUnit)
      end
    end
  else
    if matConfig.payPerUnit == nil then
      print(string.format("[Loading] Material '%s' missing payPerUnit; cannot generate contract.", materialType))
      return nil
    end
    unitPay = requiredTons * matConfig.payPerUnit
  end
  
  local facilityPayMultiplier = getFacilityPayMultiplier(group.secondaryTag)
  if not facilityPayMultiplier then
    print(string.format("[Loading] Could not get facility pay multiplier for zone '%s'; cannot generate contract.", group.secondaryTag or "unknown"))
    return nil
  end
  local totalPayout = math.floor((basePay + (unitPay * payMultiplier)) * facilityPayMultiplier)

  if not selectedTypeName then
    print(string.format("[Loading] Material '%s' missing typeName; cannot generate contract.", materialType))
    return nil
  end
  local name = selectedTypeName
  if isBulk then name = "Bulk " .. name end

  if contractsConfig.contractTTL == nil then
    print("[Loading] contractTTL not specified in contracts config; cannot generate contract.")
    return nil
  end
  local contractTTL = contractsConfig.contractTTL
  local createdAtSimTime = ContractSystem.simTimeAccumulator
  local expiresAtSimTime = createdAtSimTime + (contractTTL * 3600)
  local expirationHours = contractTTL

  local facilityId = getFacilityIdForZone(group.secondaryTag)
  if not facilityId then
    print(string.format("[Loading] Warning: Could not find facility ID for zone '%s'; contract may not save correctly.", group.secondaryTag or "unknown"))
  end

  return {
    id = os.time() + math.random(1000, 9999),
    name = name,
    tier = tier,
    material = materialType,
    materialTypeName = selectedTypeName,
    requiredTons = requiredTons,
    requiredItems = requiredItems,
    materialRequirements = materialRequirements,
    unitType = matConfig.unitType,
    units = matConfig.units,
    isBulk = isBulk,
    basePay = basePay,
    unitPay = unitPay,
    payMultiplier = payMultiplier,
    facilityPayMultiplier = facilityPayMultiplier,
    totalPayout = totalPayout,
    facilityId = facilityId,
    destination = {
      pos = group.destination and group.destination.pos and vec3(group.destination.pos) or nil,
      name = group.destination and group.destination.name or nil,
      originZoneTag = group.secondaryTag,
    },
    group = nil,
    groupTag = group.secondaryTag,
    estimatedTrips = estimatedTrips,
    createdAtSimTime = createdAtSimTime,
    expiresAtSimTime = expiresAtSimTime,
    expirationHours = expirationHours,
    createdAt = getCurrentGameHour(),
  }
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
  print(string.format("[Loading] Generated %d initial contracts. Next contract spawn in %.2f seconds", 
    #ContractSystem.availableContracts, secondsPerContract))
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
      Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Mission_Unlock_01')
      
      print(string.format("[Loading] Spawned new contract: %s (Tier %d). Next spawn in %.2f seconds", 
        contract.name, contract.tier, secondsPerContract))
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
      print("[Loading] Contract expired: " .. (contract.name or "Unknown"))
      table.insert(expiredContracts, contract.id)
      if guihooks then
        guihooks.trigger('contractExpired', {
          contractId = contract.id,
          contractData = formatContractForUI(contract)
        })
      end
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

local function acceptContract(contractIndex, getZonesByTypeName)
  local contract = ContractSystem.availableContracts[contractIndex]
  if not contract then return end

  local contractTypeName = contract.materialTypeName
  if not contractTypeName then
    print("[Loading] Error: Contract missing materialTypeName field")
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
  
  local loanerCut = 0
  if isCareerMode() then
    local vehId = be:getPlayerVehicleID(0)
    if vehId then
      local inventoryId = career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId(vehId)
      if inventoryId then
        local vehicle = career_modules_inventory.getVehicle(inventoryId)
        if vehicle and vehicle.owningOrganization then
          local org = freeroam_organizations and freeroam_organizations.getOrganization(vehicle.owningOrganization)
          if org and org.reputation and org.reputation.level ~= nil and org.reputationLevels then
            local repLevel = org.reputation.level
            local levelIndex = repLevel + 2
            if org.reputationLevels[levelIndex] and org.reputationLevels[levelIndex].loanerCut then
              loanerCut = org.reputationLevels[levelIndex].loanerCut.value or 0
            end
          end
        end
      end
    end
  end
  
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
  
  print(string.format("[Loading] Contract accepted. TypeName: %s. Compatible zones: %s", 
    contractTypeName, table.concat(zoneNames, ", ")))
  
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
    local career = career_career
    if career and type(career.isActive) == "function" and career.isActive() then
      local paymentModule = career_modules_payment
      if paymentModule and type(paymentModule.reward) == "function" and penaltyAmount > 0 then
        paymentModule.reward({
          money = { amount = -penaltyAmount, canBeNegative = true }
        }, { label = "Contract Abandonment", tags = {"gameplay", "mission", "penalty"} })
      end
    end
  end)
  if not success then
    print("[Loading] Warning: Could not apply abandonment penalty: " .. tostring(err))
  end

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

  local success, err = pcall(function()
    local career = career_career
    if career and type(career.isActive) == "function" and career.isActive() then
      local paymentModule = career_modules_payment
      if paymentModule and type(paymentModule.pay) == "function" and penalty ~= 0 then
        paymentModule.pay(-math.abs(penalty), {label = "Contract Failure"})
      end
    end
  end)
  if not success then
    print("[Loading] Warning: Could not apply failure penalty: " .. tostring(err))
  end

  PlayerData.contractsFailed = (PlayerData.contractsFailed or 0) + 1
  ContractSystem.activeContract = nil
  ContractSystem.contractProgress = {deliveredTons = 0, totalPaidSoFar = 0, deliveryCount = 0, deliveredItems = 0}

  if onCleanup then onCleanup(true) end
end

local function completeContract(onCleanup, onClearProps)
  if not ContractSystem.activeContract then return end
  local contract = ContractSystem.activeContract

  local zoneTag = contract.loadingZoneTag or contract.groupTag
  local facilityPayMultiplier = getFacilityPayMultiplier(zoneTag)
  local totalPay = math.floor((contract.totalPayout or 0) * facilityPayMultiplier)

  local loanerCut = ContractSystem.contractProgress.loanerCut or 0
  if loanerCut > 0 then
    totalPay = math.floor(totalPay * (1 - loanerCut))
  end

  local careerPaid = false
  local success, err = pcall(function()
    local career = career_career
    if career and type(career.isActive) == "function" and career.isActive() then
      local paymentModule = career_modules_payment
      if paymentModule and type(paymentModule.reward) == "function" then
        local xpMultiplier = 10
        local xpReward = 0
        if contract.unitType == "item" then
          xpReward = math.floor((contract.requiredItems or 0) * xpMultiplier)
        else
          xpReward = math.floor((contract.requiredTons or 0) * xpMultiplier)
        end
        
        local rewardData = {
          money = { amount = totalPay, canBeNegative = false },
          labor = { amount = xpReward, canBeNegative = false }
        }
        
        local Zones = gameplay_loading_zones
        if Zones and Zones.availableGroups then
          local activeGroup = nil
          for _, group in ipairs(Zones.availableGroups) do
            if group.secondaryTag == zoneTag then
              activeGroup = group
              break
            end
          end
          
          if activeGroup and activeGroup.associatedOrganization then
            local orgId = activeGroup.associatedOrganization
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
              local repKey = orgId .. "Reputation"
              rewardData[repKey] = { amount = totalRepGain }
            end
          end
        end
        
        paymentModule.reward(rewardData, { label = string.format("Contract: %s", contract.name), tags = {"gameplay", "mission", "reward"} })
        careerPaid = true
        Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')
        ui_message(string.format("CONTRACT COMPLETE! Earned $%d", totalPay), 8, "success")
      end
    end
  end)
  
  if not success then
    print("[Loading] Warning: Could not apply contract reward: " .. tostring(err))
  end
  
  if not careerPaid then
    Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Mission_End_Success')
    ui_message(string.format("SANDBOX: Contract payout: $%d", totalPay), 6, "success")
  end

  PlayerData.contractsCompleted = (PlayerData.contractsCompleted or 0) + 1

  ContractSystem.activeContract = nil
  ContractSystem.contractProgress = {deliveredTons = 0, totalPaidSoFar = 0, deliveryCount = 0, deliveredItems = 0}

  if onClearProps then onClearProps() end
  if onCleanup then onCleanup(true) end
end

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
M.onExtensionLoaded = onExtensionLoaded
local function onExtensionLoaded()
  log("I", "Loading Extension: contracts loaded")
end
M.loadingConfigLoaded = function()
  Config = gameplay_loading_config
end

return M


