-- Tuning shop kit quotes: compares a kit with the car's parts and prices the swap.
-- Read the pure tree helpers, the vehicle and pricing steps, then new(), which reads this load's owner helpers.
local installer = {}

-- Config ------------------------------------------------------------------------------------------


-- Seconds to fit one changed part: a base time, cut by each quick-installs level, never under the minimum.
local BASE_SECONDS_PER_PART = 25
local QUICK_INSTALL_SECONDS_PER_LEVEL = 5
local MIN_SECONDS_PER_PART = 5
-- Value used for a part whose data has no information value.
local FALLBACK_PART_VALUE = 100
-- Quoted part prices round to the nearest step, then a cent comes off.
local PRICE_ROUNDING_STEP = 5
local PRICE_CENT_OFFSET = 0.01
-- The shop credits this share of the old parts' value against the new ones.
local TRADE_IN_SHARE = 0.9

-- Pure tree helpers -------------------------------------------------------------------------------

local function comparePartsTree(kitNode, currentNode, slotPath, differingParts)
  slotPath = slotPath or "/"
  differingParts = differingParts or {}

  if not kitNode then
    return differingParts
  end

  local kitPart = kitNode.chosenPartName or ""
  local currentPart = currentNode and currentNode.chosenPartName or ""

  if kitPart ~= "" and kitPart ~= currentPart then
    differingParts[slotPath] = {
      partName = kitPart,
      oldPartName = currentPart ~= "" and currentPart or nil
    }
  end

  if kitNode.children then
    for slotName, kitChild in pairs(kitNode.children) do
      local childPath = slotPath .. slotName .. "/"
      local currentChild = currentNode and currentNode.children and currentNode.children[slotName] or nil
      comparePartsTree(kitChild, currentChild, childPath, differingParts)
    end
  end

  return differingParts
end

local function mergeKitIntoConfig(kitNode, configNode, slotPath)
  slotPath = slotPath or "/"
  if not kitNode then
    return configNode
  end

  local kitPart = kitNode.chosenPartName
  local configPart = configNode and configNode.chosenPartName or ""

  if kitPart and kitPart ~= "" then
    if kitPart ~= configPart then
      if not configNode then
        configNode = {}
      end
      configNode.chosenPartName = kitPart
    end
  end

  if kitNode.children then
    if not configNode then
      configNode = {}
    end
    if not configNode.children then
      configNode.children = {}
    end

    for slotName, kitChild in pairs(kitNode.children) do
      local childPath = slotPath .. slotName .. "/"
      configNode.children[slotName] = mergeKitIntoConfig(kitChild, configNode.children[slotName], childPath)
    end
  end

  return configNode
end

local function findSlotInTree(tree, slotName)
  if not tree or not tree.children then
    return nil
  end

  if tree.children[slotName] then
    return tree.children[slotName]
  end

  for _, childNode in pairs(tree.children) do
    local found = findSlotInTree(childNode, slotName)
    if found then
      return found
    end
  end

  return nil
end

-- Vehicle and kit lookup --------------------------------------------------------------------------


-- The shared table comes from this kit owner; lookup steps read its helpers at call time.
local function findKit(parts, businessId, kitId)
  for _, kit in ipairs(parts.kits.loadBusinessKits(businessId)) do
    if kit.id == kitId then
      return kit
    end
  end
  return nil
end

-- A personal car must be the active personal vehicle; its mileage comes from the garage inventory.
local function resolvePersonalQuoteVehicle(parts, businessId, vehicleId)
  local vehicle = parts.kits.getPersonalVehicleData(vehicleId, businessId)
  if not vehicle then
    return nil
  end
  local vehObj = nil
  local spawnedId = parts.kits.getSpawnedIdFromPersonalVehicleId(vehicleId)
  if spawnedId then
    vehObj = be:getObjectByID(spawnedId)
  end
  local vehicleMileage = 0
  if vehicle.inventoryId then
    local invVehicles = overhaul_career_garage_inventory.getVehicles()
    if invVehicles and invVehicles[vehicle.inventoryId] then
      vehicleMileage = tonumber(invVehicles[vehicle.inventoryId].mileage or 0)
    end
  end
  return {vehicle = vehicle, vehObj = vehObj, vehicleMileage = vehicleMileage}
end

local function resolveFleetQuoteVehicle(businessId, vehicleId)
  local vehicle = overhaul_career_business_fleet.getVehicleById(businessId, vehicleId)
  if not vehicle then
    return nil
  end
  local vehObj = nil
  local spawnedVehicleId = overhaul_career_business_fleet.getSpawnedVehicleId(businessId, vehicleId)
  if spawnedVehicleId then
    vehObj = getObjectByID(spawnedVehicleId)
  end
  return {vehicle = vehicle, vehObj = vehObj, vehicleMileage = tonumber(vehicle.mileage or 0)}
end

local function resolveQuoteVehicle(parts, businessId, vehicleId)
  if parts.kits.isPersonalVehicleId(vehicleId) then
    return resolvePersonalQuoteVehicle(parts, businessId, vehicleId)
  end
  return resolveFleetQuoteVehicle(businessId, vehicleId)
end

-- Pricing steps -----------------------------------------------------------------------------------

local function partBaseValue(jbeamData)
  return jbeamData.information and jbeamData.information.value or FALLBACK_PART_VALUE
end

-- Parts the kit changes, keyed by slot path, with the part each one would replace.
local function collectDifferingParts(kit, currentPartsTree)
  local differingParts = {}
  for slotName, kitNode in pairs(kit.parts) do
    local slotPath = "/" .. slotName .. "/"
    local currentNode = findSlotInTree(currentPartsTree, slotName)
    comparePartsTree(kitNode, currentNode, slotPath, differingParts)
  end
  return differingParts
end

-- Shop price of a part to fit, with the supplier discount; nil when the part has no data.
local function newPartPrice(jbeamIO, ioCtx, partName, vehicleModel, discountMultiplier)
  local jbeamData = jbeamIO.getPart(ioCtx, partName)
  if not jbeamData then
    return nil
  end
  local partForValueCalc = {
    name = partName,
    value = partBaseValue(jbeamData),
    partCondition = {
      integrityValue = 1,
      odometer = 0,
      visualValue = 1
    },
    vehicleModel = vehicleModel
  }
  local price = math.max(roundNear(overhaul_career_market_valueCalculator.getPartValue(partForValueCalc), PRICE_ROUNDING_STEP) - PRICE_CENT_OFFSET, 0)
  return price * discountMultiplier
end

-- Trade-in value of the part the car has now, at its mileage; nil when the part has no data.
local function oldPartValue(jbeamIO, ioCtx, partName, vehicleModel, vehicleMileage)
  local jbeamData = jbeamIO.getPart(ioCtx, partName)
  if not jbeamData then
    return nil
  end
  local partForValueCalc = {
    name = partName,
    value = partBaseValue(jbeamData),
    partCondition = {
      integrityValue = 1,
      odometer = vehicleMileage,
      visualValue = 1
    },
    vehicleModel = vehicleModel
  }
  return math.max(roundNear(overhaul_career_market_valueCalculator.getPartValue(partForValueCalc, true), PRICE_ROUNDING_STEP) - PRICE_CENT_OFFSET, 0)
end

-- Sums the new parts' cost and the old parts' trade-in value, in the same order as the parts table.
local function priceDifferingParts(jbeamIO, ioCtx, differingParts, vehicleModel, vehicleMileage, discountMultiplier)
  local newPartsCost = 0
  local oldPartsValue = 0
  for _, partInfo in pairs(differingParts) do
    local newPrice = newPartPrice(jbeamIO, ioCtx, partInfo.partName, vehicleModel, discountMultiplier)
    if newPrice then
      newPartsCost = newPartsCost + newPrice
    end

    if partInfo.oldPartName then
      local oldValue = oldPartValue(jbeamIO, ioCtx, partInfo.oldPartName, vehicleModel, vehicleMileage)
      if oldValue then
        oldPartsValue = oldPartsValue + oldValue
      end
    end
  end
  return newPartsCost, oldPartsValue
end

-- Seconds the shop spends fitting the changed parts, after the quick-installs skill.
local function installTimeFor(businessId, changedPartsCount)
  local quickInstallsLevel = overhaul_career_business_skillTree.getNodeProgress(businessId, "quality-of-life", "quick-installs") or 0
  local timePerPart = math.max(MIN_SECONDS_PER_PART, BASE_SECONDS_PER_PART - (quickInstallsLevel * QUICK_INSTALL_SECONDS_PER_LEVEL))
  return changedPartsCount * timePerPart
end

local function buildQuote(businessId, newPartsCost, oldPartsValue, changedPartsCount)
  local tradeInCredit = oldPartsValue * TRADE_IN_SHARE
  return {
    newPartsCost = newPartsCost,
    oldPartsValue = oldPartsValue,
    tradeInCredit = tradeInCredit,
    totalCost = math.max(newPartsCost - tradeInCredit, 0),
    changedPartsCount = changedPartsCount,
    installTimeSeconds = installTimeFor(businessId, changedPartsCount)
  }
end

-- Installed once per facade load: the closure below reads this load's sibling helpers.
function installer.new(inputs)
  local jbeamIO = inputs.jbeamIO
  -- The owner installs its helpers before any quote is requested.
  local parts = inputs.parts

  -- Quote -----------------------------------------------------------------------------------------

  local function getKitCostBreakdown(businessId, vehicleId, kitId)
    businessId = parts.kits.normalizeBusinessId(businessId)
    if not businessId or not vehicleId or not kitId then
      return nil
    end

    local kit = findKit(parts, businessId, kitId)
    if not kit or not kit.parts then
      return nil
    end

    local quoteVehicle = resolveQuoteVehicle(parts, businessId, vehicleId)
    if not quoteVehicle or not quoteVehicle.vehObj then
      return nil
    end

    local vehicleData = extensions.core_vehicle_manager.getVehicleData(quoteVehicle.vehObj:getID())
    if not vehicleData or not vehicleData.ioCtx then
      return nil
    end

    local vehicleModel = quoteVehicle.vehObj:getJBeamFilename()
    local discountMultiplier = parts.kits.getPartSupplierDiscountMultiplier(businessId)
    local currentPartsTree = vehicleData.config and vehicleData.config.partsTree or
                             (quoteVehicle.vehicle.config and quoteVehicle.vehicle.config.partsTree or nil)
    local differingParts = collectDifferingParts(kit, currentPartsTree)
    local newPartsCost, oldPartsValue = priceDifferingParts(jbeamIO, vehicleData.ioCtx, differingParts,
      vehicleModel, quoteVehicle.vehicleMileage, discountMultiplier)

    local changedPartsCount = 0
    for _ in pairs(differingParts) do
      changedPartsCount = changedPartsCount + 1
    end
    return buildQuote(businessId, newPartsCost, oldPartsValue, changedPartsCount)
  end

  return {
    getKitCostBreakdown = getKitCostBreakdown,
    mergeKitIntoConfig = mergeKitIntoConfig,
  }
end

return installer
