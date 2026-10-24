-- Shared maintenance categories: matching, installed hardware and mileage weighting.
-- GE and vehicle Lua use the same definitions so the shop and wear simulation agree.
local M = {}

M.categoryOrder = {"engine", "radiator", "transmission"}

-- Body, storage and brake parts must not inherit their parent's hardware age.
M.inheritanceExcludeKeywords = {"frunk", "trunk", "storage", "brakes"}

M.definitions = {
  engine = {
    keywords = {"engine", "longblock", "cylinderhead", "headgasket", "block", "oilpan", "turbo", "supercharger", "intake", "exhaust"},
    -- Exclude cosmetic engine words so body-kit names cannot add chassis age to engine wear.
    boundaryExcludeKeywords = {
      "brake", "hood", "bumper", "fender", "fascia", "coilover", "swaybar", "hub", "interior",
      "gauge", "checkengine", "digidash", "lettering", "skin", "spoiler", "tailgate",
      "licenseplate", "rollcage", "fueltank", "headlight", "badge", "layout", "door", "panel",
      "grill", "bedliner", "trim", "wheeldata", "engcover", "transfer",
    },
    rootKeywords = {"engine", "longblock", "block", "cylinderhead", "headgasket"},
    installedKeywords = {"engine", "longblock", "cylinderhead", "headgasket", "block"},
    installedSlotSuffixes = {"engine"},
    installedPowertrainDevices = {"combustionEngine"},
    requiredPowertrainDevices = {"combustionEngine"},
    installedExcludeKeywords = {
      "subframe", "mount", "ecu", "motor", "intake", "exhaust", "oilpan", "turbo", "supercharger",
      "radiator", "intercooler", "transmission", "gearbox", "transaxle", "compressor", "wastegate",
      "nitrous", "n2o", "fan", "hose", "shroud", "cooler",
    },
  },
  radiator = {
    keywords = {"radiator", "cooler", "coolant", "hose", "fan", "shroud"},
    rootKeywords = {"radiator", "coolant", "hose"},
    -- Keep substring fan matching for radFan while excluding fancy fenders and roof antennas.
    boundaryExcludeKeywords = {"intercooler", "oilcooler", "oil_cooler", "fancy", "antenna"},
    installedKeywords = {"radiator"},
    installedExcludeKeywords = {"fan", "hose", "shroud", "intercooler", "oilcooler", "oil_cooler"},
    -- EV radiators have no combustion cooling model to maintain.
    requiredPowertrainDevices = {"combustionEngine"},
  },
  transmission = {
    -- Manual gearboxes declare their device; matching the word also captures roofs, mirrors and locking hubs.
    keywords = {"gearbox", "transmission", "transaxle", "differential", "finaldrive", "final_drive", "flywheel", "clutch", "torqueconverter", "torque_converter", "dct", "rangebox", "cvt"},
    -- Clutch pedal boxes, access panels and chassis braces named after the drivetrain.
    boundaryExcludeKeywords = {"pedal", "panel", "brace"},
    rootKeywords = {"gearbox", "transmission", "transaxle", "differential", "finaldrive", "final_drive", "flywheel", "clutch", "torqueconverter", "torque_converter", "dct", "cvt"},
    installedKeywords = {"gearbox", "transmission", "transaxle", "dct", "cvt", "rangebox"},
    installedExcludeKeywords = {"mount", "shifter", "linkage", "tunnel"},
    -- Recognize EV reduction boxes by their declared device because their part names vary.
    installedPowertrainDevices = {"rangeBox"},
  },
}

local function lower(value)
  return string.lower(tostring(value or ""))
end

local function containsAny(text, keywords)
  text = lower(text)
  if text == "" then return false end
  for _, keyword in ipairs(keywords or {}) do
    if string.find(text, lower(keyword), 1, true) then return true end
  end
  return false
end

local function containsKeywordToken(text, keyword)
  text, keyword = lower(text), lower(keyword)
  if keyword == "" then return false end
  local startPos = 1
  while true do
    local foundAt = string.find(text, keyword, startPos, true)
    if not foundAt then return false end
    local afterPos = foundAt + #keyword
    if (foundAt == 1 or not text:sub(foundAt - 1, foundAt - 1):match("[%w]")) and
       (afterPos > #text or not text:sub(afterPos, afterPos):match("[%w]")) then
      return true
    end
    startPos = foundAt + 1
  end
end

local function containsAnyToken(text, keywords)
  for _, keyword in ipairs(keywords or {}) do
    if containsKeywordToken(text, keyword) then return true end
  end
  return false
end

function M.getImmediateSlotName(path)
  return lower(tostring(path or ""):match("([^/]+)/?$") or "")
end

function M.matchesDirect(partInfo, keywords, excludeKeywords)
  -- Use structural names so a dashboard Differential Lock label cannot count as drivetrain hardware.
  local haystacks = {
    lower(partInfo and partInfo.partName),
    lower(partInfo and partInfo.slotName),
  }
  for _, haystack in ipairs(haystacks) do
    if containsAny(haystack, keywords) and not containsAny(haystack, excludeKeywords) then
      return true, haystack
    end
  end
  return false
end

-- Match the part itself; descendants inherit the nearest subsystem boundary.
function M.getDirectCategory(partInfo)
  for _, categoryName in ipairs({"radiator", "transmission", "engine"}) do
    local definition = M.definitions[categoryName]
    if M.matchesDirect(partInfo, definition.keywords, definition.boundaryExcludeKeywords) then
      return categoryName
    end
  end
  return nil
end

function M.matchesInstalledHardware(categoryName, partName, slotName)
  local definition = M.definitions[categoryName]
  if not definition or not definition.installedKeywords then return true end
  for _, haystack in ipairs({lower(partName), lower(slotName)}) do
    if containsAnyToken(haystack, definition.installedKeywords) and
       not containsAny(haystack, definition.installedExcludeKeywords) then
      return true, haystack
    end
  end

  local lowerSlotName = lower(slotName)
  if not containsAny(lowerSlotName, definition.installedExcludeKeywords) then
    for _, suffix in ipairs(definition.installedSlotSuffixes or {}) do
      if containsKeywordToken(lowerSlotName, suffix) then return true, lowerSlotName end
    end
  end
  return false
end

-- The vehicle model and garage computer must agree about installed category hardware.
function M.hasInstalledHardware(categoryName, partIds, getPartInfo)
  local definition = M.definitions[categoryName]
  if not definition or not definition.installedKeywords then return true end
  for _, partId in ipairs(partIds or {}) do
    local info = getPartInfo and getPartInfo(partId) or nil
    if info and M.matchesInstalledHardware(categoryName, info.partName, info.slotName) then
      return true, partId
    end
  end
  return false
end

function M.blocksInheritance(partInfo)
  for _, haystack in ipairs({lower(partInfo and partInfo.partName), lower(partInfo and partInfo.slotName)}) do
    if containsAnyToken(haystack, M.inheritanceExcludeKeywords) then return true end
  end
  return false
end

-- Purchase seeding and newly discovered hardware share the same age bounds.
M.initialWearSeedStartMiles = 50000
M.initialWearSeedFullRangeMiles = 250000
M.initialWearSeedMinimumValue = 0.70

-- Heavy-vehicle age curves use normalized mileage; odometers and service intervals keep real mileage.
M.classAgeMileageScale = {
  passenger = 1,
  lightTruck = 1.3,
  mediumTruck = 2,
  heavyTruck = 3.5,
}

function M.getClassAgeMiles(miles, profile)
  local className = type(profile) == "table" and profile.class or profile
  local scale = M.classAgeMileageScale[className] or 1
  return (tonumber(miles) or 0) / scale
end

function M.getInitialWearSeedValue(avgMiles)
  avgMiles = tonumber(avgMiles) or 0
  if avgMiles <= M.initialWearSeedStartMiles then return 1 end
  local span = M.initialWearSeedFullRangeMiles - M.initialWearSeedStartMiles
  if span <= 0 then return M.initialWearSeedMinimumValue end
  local progress = (avgMiles - M.initialWearSeedStartMiles) / span
  if progress > 1 then progress = 1 end
  if progress < 0 then progress = 0 end
  return 1 + progress * (M.initialWearSeedMinimumValue - 1)
end

function M.partDataHasDeviceType(partData, deviceType)
  if type(partData) ~= "table" or type(deviceType) ~= "string" or deviceType == "" then
    return false
  end
  local target = lower(deviceType)
  local function walk(value)
    if type(value) == "string" then
      return string.find(lower(value), target, 1, true) ~= nil
    end
    if type(value) ~= "table" then return false end
    for _, child in pairs(value) do
      if walk(child) then return true end
    end
    return false
  end
  return walk(partData.powertrain)
end

-- Hardware-free devices must not lend their slot category to child parts.
function M.walkPartsTree(partsTree, visitor, passesCategory)
  local function walkNode(node, currentPath, currentTreePath, inheritedCategory)
    if type(node) ~= "table" then return end
    currentPath = currentPath or "/"
    currentTreePath = currentTreePath or "/"
    local nodePath = node.path or currentTreePath
    local slotName = M.getImmediateSlotName(nodePath ~= "/" and nodePath or currentPath)
    local chosenPartName = node.chosenPartName
    local ownerCategory = inheritedCategory
    local childCategory = inheritedCategory

    if type(chosenPartName) == "string" and chosenPartName ~= "" then
      local partInfo = {
        partName = chosenPartName,
        slotName = slotName,
        slotPath = currentPath,
        treePath = node.path or currentPath,
        constructedPartId = currentPath .. chosenPartName,
        treePartId = node.partPath or (nodePath .. chosenPartName),
      }
      partInfo.directCategory = M.getDirectCategory(partInfo)
      ownerCategory = partInfo.directCategory or (not M.blocksInheritance(partInfo) and inheritedCategory or nil)
      partInfo.ownerCategory = ownerCategory
      visitor(partInfo)
      childCategory = ownerCategory
      if passesCategory and passesCategory(partInfo) == false then childCategory = nil end
    end

    local childKeys = {}
    for childSlotName in pairs(node.children or {}) do table.insert(childKeys, childSlotName) end
    table.sort(childKeys)
    for _, childSlotName in ipairs(childKeys) do
      walkNode(node.children[childSlotName], currentPath .. tostring(childSlotName) .. "/",
        nodePath .. tostring(childSlotName) .. "/", childCategory)
    end
  end
  walkNode(partsTree, "/", "/", nil)
end

return M
