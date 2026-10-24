-- Maintenance quotes: which hardware is installed, what tracked parts are worth and what a service costs.
-- Map: Installed hardware; Tracked parts and values; Service prices; Public API.

local partFactory = {}

function partFactory.new(inputs)
  local computerState = inputs.state

  -- Installed hardware -----------------------------------------------------------------------------

  local function collectInstalledPartNames(vehicleData)
    local partNames = {}
    local seen = {}

    local function addName(name)
      if type(name) == "string" and name ~= "" and not seen[name] then
        seen[name] = true
        table.insert(partNames, name)
      end
    end

    local function walkNode(node)
      if type(node) ~= "table" then
        return
      end
      addName(node.chosenPartName)
      for _, child in pairs(node.children or {}) do
        walkNode(child)
      end
    end

    local partsTree = vehicleData and vehicleData.config and vehicleData.config.partsTree
    if type(partsTree) == "table" and next(partsTree) ~= nil then
      walkNode(partsTree)
    else
      local flatParts = vehicleData and vehicleData.config and vehicleData.config.parts
      if type(flatParts) == "table" then
        for _, chosenPartName in pairs(flatParts) do
          addName(chosenPartName)
        end
      end
    end

    return partNames
  end

  -- Returns found, the match, and whether the powertrain data says anything about the vehicle at all.
  local function categoryHasInstalledPowertrainDevice(vehicleData, deviceTypes)
    if type(deviceTypes) ~= "table" or not deviceTypes[1] then
      return false, nil, false
    end

    local hasPowertrainMetadata = false
    local activePartsData = vehicleData and vehicleData.vdata and vehicleData.vdata.activePartsData
    if type(activePartsData) == "table" then
      for _, partData in pairs(activePartsData) do
        hasPowertrainMetadata = hasPowertrainMetadata or
                                    (type(partData) == "table" and type(partData.powertrain) == "table")
        for _, deviceType in ipairs(deviceTypes) do
          if inputs.partDataHasDeviceType(partData, deviceType) then
            return true, {source = "activePartsData", deviceType = deviceType}, true
          end
        end
      end
    end

    local ioCtx = inputs.getVehicleIoCtx(vehicleData)
    if not ioCtx then
      return false, nil, hasPowertrainMetadata
    end

    for _, partName in ipairs(collectInstalledPartNames(vehicleData)) do
      local ok, partData = pcall(computerState.jbeamIO.getPart, ioCtx, partName)
      if ok and type(partData) == "table" then
        hasPowertrainMetadata = hasPowertrainMetadata or type(partData.powertrain) == "table"
        for _, deviceType in ipairs(deviceTypes) do
          if inputs.partDataHasDeviceType(partData, deviceType) then
            return true, {source = "jbeam", partName = partName, deviceType = deviceType}, true
          end
        end
      end
    end

    return false, nil, hasPowertrainMetadata
  end

  -- False when the powertrain data rules the hardware out. Otherwise true, plus the device match if one was found.
  local function powertrainGateVerdict(vehicleData, categoryDefinition)
    -- Hardware that only matters beside a given device, such as a radiator beside a combustion engine, is nothing to service without one. Unknown powertrain data falls through to the part names.
    if categoryDefinition.requiredPowertrainDevices then
      local hasDevice, _, hasPowertrainMetadata = categoryHasInstalledPowertrainDevice(
        vehicleData,
        categoryDefinition.requiredPowertrainDevices
      )
      if hasPowertrainMetadata and not hasDevice then
        return false
      end
    end

    if categoryDefinition.installedPowertrainDevices then
      local hasDevice, deviceMatch, hasPowertrainMetadata = categoryHasInstalledPowertrainDevice(
        vehicleData,
        categoryDefinition.installedPowertrainDevices
      )
      if hasDevice then
        return true, deviceMatch
      end
      -- Only where the listed devices are the whole story: no combustion device means no engine, full stop. Elsewhere the list is one more way to spot hardware the keywords miss, so a miss must still fall through rather than hide the category.
      if hasPowertrainMetadata and categoryDefinition.powertrainDevicesAuthoritative then
        return false
      end
    end

    return true, nil
  end

  -- Scans the part names and slot names for the category's keywords; returns the first match.
  local function findHardwareByName(vehicleData, categoryName)
    local match = nil

    local function inspectPart(partName, slotName, path, source)
      if match then
        return
      end
      local matched, haystack = inputs.partCategories.matchesInstalledHardware(categoryName, partName, slotName)
      if matched then
        match = {
          source = source,
          partName = partName,
          slotName = slotName,
          path = path,
          haystack = haystack,
        }
      end
    end

    local partsTree = vehicleData and vehicleData.config and vehicleData.config.partsTree
    if type(partsTree) == "table" and next(partsTree) ~= nil then
      inputs.partCategories.walkPartsTree(partsTree, function(partInfo)
        inspectPart(partInfo.partName, partInfo.slotName, partInfo.treePath, "partsTree")
      end)
      return match
    end

    local flatParts = vehicleData and vehicleData.config and vehicleData.config.parts
    if type(flatParts) == "table" then
      for slotName, chosenPartName in pairs(flatParts) do
        if type(chosenPartName) == "string" and chosenPartName ~= "" then
          local immediateSlotName = inputs.partCategories.getImmediateSlotName(slotName)
          inspectPart(chosenPartName, immediateSlotName, slotName, "parts")
          if match then break end
        end
      end
    end
    return match
  end

  local function logHardwareMatch(categoryName, foundMatch)
    if foundMatch then
      log("D", "maintenanceComputer", string.format(
        "categoryHardwareIsInstalled(%s) = true via %s: partName=%s slotName=%s path=%s haystack=%s deviceType=%s",
        categoryName,
        tostring(foundMatch.source),
        tostring(foundMatch.partName),
        tostring(foundMatch.slotName),
        tostring(foundMatch.path),
        tostring(foundMatch.haystack),
        tostring(foundMatch.deviceType)
      ))
    end
  end

  local function categoryHardwareIsInstalled(vehicleData, categoryName)
    local categoryDefinition = inputs.config.categoryDefinitions[categoryName]
    if not (categoryDefinition and categoryDefinition.installedKeywords) then
      return true
    end

    local gateAllows, deviceMatch = powertrainGateVerdict(vehicleData, categoryDefinition)
    if not gateAllows then
      return false
    end

    local foundMatch = deviceMatch or findHardwareByName(vehicleData, categoryName)
    logHardwareMatch(categoryName, foundMatch)
    return foundMatch ~= nil
  end

  -- Tracked parts and values ------------------------------------------------------------------------

  local function buildPartClassification(vehicleData)
    local categories = {}
    local partInfosById = {}
    for _, categoryName in ipairs(inputs.config.categoryOrder) do
      categories[categoryName] = {}
    end

    local function addPart(categoryName, partInfo)
      categories[categoryName][partInfo.partId] = partInfo
    end

    if type(vehicleData.config) == "table" and type(vehicleData.config.partsTree) == "table" then
      inputs.partCategories.walkPartsTree(vehicleData.config.partsTree, function(walkInfo)
        local partId = walkInfo.treePartId
        local partInfo = {
          partId = partId,
          partName = walkInfo.partName,
          slotName = walkInfo.slotName,
          slotPath = partId:match("^(.*[/])[^/]+$") or "/",
          treePath = walkInfo.treePath,
          ownerCategory = walkInfo.ownerCategory,
        }
        partInfosById[partId] = partInfo
        if partInfo.ownerCategory then addPart(partInfo.ownerCategory, partInfo) end
      end)
    end

    local orderedCategoryParts = {}
    for _, categoryName in ipairs(inputs.config.categoryOrder) do
      orderedCategoryParts[categoryName] = {}
      for partId in pairs(categories[categoryName]) do
        table.insert(orderedCategoryParts[categoryName], partId)
      end
      table.sort(orderedCategoryParts[categoryName])
    end

    return orderedCategoryParts, partInfosById
  end

  local function listsEqual(left, right)
    if #left ~= #right then
      return false
    end
    for index = 1, #left do
      if left[index] ~= right[index] then
        return false
      end
    end
    return true
  end

  -- Keeps each category's cached part ids in step with the vehicle; returns the ids, the part info and whether anything changed.
  local function getTrackedPartData(vehicleData, maintenanceState)
    local rebuiltPartIdsByCategory, partInfosById = buildPartClassification(vehicleData)
    local changed = false
    local trackedPartIdsByCategory = {}

    for _, categoryName in ipairs(inputs.config.categoryOrder) do
      local categoryState = maintenanceState.categories[categoryName]
      local validSet = {}
      for _, rebuiltPartId in ipairs(rebuiltPartIdsByCategory[categoryName] or {}) do
        validSet[rebuiltPartId] = true
      end

      local primaryPartIds = {}
      local seen = {}
      local function tryAdd(partId)
        if partId and validSet[partId] and not seen[partId] then
          seen[partId] = true
          table.insert(primaryPartIds, partId)
        end
      end

      for _, cachedPartId in ipairs(categoryState.cachedPartIds or {}) do
        tryAdd(cachedPartId)
      end
      tryAdd(categoryState.rootPartId)
      table.sort(primaryPartIds)

      if #primaryPartIds == 0 then
        primaryPartIds = inputs.deepCopy(rebuiltPartIdsByCategory[categoryName] or {})
        table.sort(primaryPartIds)
      end

      trackedPartIdsByCategory[categoryName] = primaryPartIds

      if not listsEqual(categoryState.cachedPartIds or {}, primaryPartIds) then
        categoryState.cachedPartIds = inputs.deepCopy(primaryPartIds)
        changed = true
      end

      local nextRootPartId = categoryState.rootPartId
      if not nextRootPartId or not seen[nextRootPartId] then
        nextRootPartId = primaryPartIds[1]
      end
      if categoryState.rootPartId ~= nextRootPartId then
        categoryState.rootPartId = nextRootPartId
        changed = true
      end
    end

    return trackedPartIdsByCategory, partInfosById, changed
  end

  local function getFallbackPartValue(vehicleData, partId, partInfo)
    local baseValue = 700
    local activeParts = vehicleData.vdata and vehicleData.vdata.activeParts or nil
    local activePartsData = vehicleData.vdata and vehicleData.vdata.activePartsData or nil
    local activePartIdx = activeParts and activeParts[partId] or nil
    if activePartIdx and activePartsData and activePartsData[activePartIdx] and activePartsData[activePartIdx].information then
      baseValue = activePartsData[activePartIdx].information.value or baseValue
    end

    return {
      name = partInfo and partInfo.partName or partId,
      value = baseValue,
      partCondition = vehicleData.partConditions and vehicleData.partConditions[partId] or nil,
      vehicleModel = vehicleData.model,
    }
  end

  local function valueTrackedPart(vehicleData, partId, partInfo, partCondition)
    local part = nil
    local isBusinessRecord = vehicleData.vehicleId ~= nil and vehicleData.id == nil
    if not isBusinessRecord and partInfo and partInfo.treePath then
      part = overhaul_career_parts_partInventory.getPart(vehicleData.id, partInfo.treePath)
    end
    part = inputs.deepCopy(part or getFallbackPartValue(vehicleData, partId, partInfo))
    part.partCondition = partCondition
    part.vehicleModel = vehicleData.model

    local success, result = pcall(overhaul_career_market_valueCalculator.getPartValue, part, true)
    if success then
      return tonumber(result) or 0
    end
    log("W", "maintenanceComputer", string.format("Failed to value maintenance part '%s': %s", tostring(partId), tostring(result)))
    return tonumber(part.value) or 0
  end

  local function calculateTrackedPartsValue(vehicleData, maintenanceState, categoryName)
    local trackedPartIdsByCategory, partInfosById, cacheChanged = getTrackedPartData(vehicleData, maintenanceState)
    local trackedPartIds = trackedPartIdsByCategory[categoryName] or {}
    local totalValue = 0

    for _, partId in ipairs(trackedPartIds) do
      local partCondition = vehicleData.partConditions and vehicleData.partConditions[partId] or nil
      if partCondition then
        totalValue = totalValue + valueTrackedPart(vehicleData, partId, partInfosById[partId], partCondition)
      end
    end

    return inputs.roundMoney(totalValue), trackedPartIds, cacheChanged
  end

  -- Service prices ----------------------------------------------------------------------------------

  local function roundServicePrice(amount)
    amount = inputs.max(tonumber(amount) or 0, 0)
    local increment = amount < 500 and 5 or 10
    return inputs.floor(amount / increment + 0.5) * increment
  end

  local function powertrainGradeMultiplier(profile, vehicleData)
    local powerHp = tonumber(profile.powerHp) or tonumber(vehicleData and vehicleData.certifications and vehicleData.certifications.power) or 0
    if powerHp > 10000 then
      powerHp = powerHp / 745.7
    end
    local gradeMultiplier = (profile.isDiesel == true or profile.fuelType == "diesel" or powerHp >= 700) and 1.25 or 1
    if powerHp >= 3000 then
      gradeMultiplier = 2
    elseif powerHp >= 1500 then
      gradeMultiplier = 1.5
    end
    return gradeMultiplier
  end

  -- Labour, filter and fluid for each service item; `fluidLevel` items only top up what is missing.
  local function serviceItemRates(itemName, capacities, currentValue)
    local fillFraction = 1 - inputs.max(0, math.min(1, tonumber(currentValue) or 0))
    if itemName == "oilLevel" then
      return 15, 0, 11, inputs.max(tonumber(capacities.oil) or 4, 0) * fillFraction
    elseif itemName == "oilCondition" then
      return 75, 25, 11, inputs.max(tonumber(capacities.oil) or 4, 0)
    elseif itemName == "coolantLevel" then
      return 15, 0, 8, inputs.max(tonumber(capacities.coolant) or 5, 0) * fillFraction
    elseif itemName == "coolantIntegrity" then
      return 85, 0, 13, inputs.max(tonumber(capacities.coolant) or 5, 0)
    elseif itemName == "fluidLevel" then
      return 25, 0, 16, inputs.max(tonumber(capacities.transmission) or 6, 0) * fillFraction
    elseif itemName == "fluidCondition" then
      return 105, 50, 16, inputs.max(tonumber(capacities.transmission) or 6, 0)
    end
    return nil
  end

  local function complexityCharge(itemName, trackedValue)
    if itemName == "oilCondition" then
      return math.min(inputs.max(trackedValue - 10000, 0) * 0.005, 250)
    elseif itemName == "coolantIntegrity" then
      return math.min(inputs.max(trackedValue - 5000, 0) * 0.005, 200)
    elseif itemName == "fluidCondition" then
      return math.min(inputs.max(trackedValue - 8000, 0) * 0.0075, 350)
    end
    return 0
  end

  local function legacyServicePrice(trackedPartsValue, itemDefinition)
    local rawFallback = (tonumber(trackedPartsValue) or 0) * ((tonumber(itemDefinition and itemDefinition.servicePricePct) or 0) / 100)
    local floorPrice = tonumber(itemDefinition and itemDefinition.servicePriceFloor) or 0
    return inputs.max(floorPrice, inputs.roundWholeMoney(rawFallback)), {legacy = true}
  end

  local function calculateServicePrice(vehicleData, maintenanceState, categoryName, itemDefinition, trackedPartsValue)
    local profile = maintenanceState and maintenanceState.profile or {}
    local capacities = type(profile.capacities) == "table" and profile.capacities or {}
    local itemName = itemDefinition and itemDefinition.name or ""
    local currentValue = maintenanceState and maintenanceState.categories and maintenanceState.categories[categoryName] and
                             maintenanceState.categories[categoryName].maintenance[itemName] or 1
    local labor, filter, materialRate, fluidLiters = serviceItemRates(itemName, capacities, currentValue)
    if not labor then
      return legacyServicePrice(trackedPartsValue, itemDefinition)
    end

    local gradeMultiplier = powertrainGradeMultiplier(profile, vehicleData)
    local complexity = complexityCharge(itemName, inputs.max(tonumber(trackedPartsValue) or 0, 0))
    local material = fluidLiters * materialRate * gradeMultiplier
    local rawPrice = labor + filter + material + complexity
    return roundServicePrice(rawPrice), {
      labor = inputs.roundMoney(labor),
      filter = inputs.roundMoney(filter),
      material = inputs.roundMoney(material),
      materialRate = materialRate,
      fluidLiters = inputs.roundMoney(fluidLiters),
      gradeMultiplier = gradeMultiplier,
      complexity = inputs.roundMoney(complexity),
      rawPrice = inputs.roundMoney(rawPrice),
    }
  end

  -- Public API --------------------------------------------------------------------------------------

  return {
    calculateServicePrice = calculateServicePrice,
    calculateTrackedPartsValue = calculateTrackedPartsValue,
    categoryHardwareIsInstalled = categoryHardwareIsInstalled,
    getTrackedPartData = getTrackedPartData,
  }
end

return partFactory
