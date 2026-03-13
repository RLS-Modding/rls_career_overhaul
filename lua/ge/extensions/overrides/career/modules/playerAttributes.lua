-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local dlog = function(m) log("D","",m) end -- set to nop to disable loggin

M.dependencies = {'career_career'}

local attributes
local attributeLog
local baseAttribute = {value = 0, gains = {}, losses = {}}
local attributeKeyAliases = {
  ["delivery"] = "logistics-delivery",
  ["vehicleDelivery"] = "logistics-delivery",
  ["materials"] = "logistics-delivery",
  ["logistics-vehicleDelivery"] = "logistics-delivery",
  ["logistics-materials"] = "logistics-delivery",
  ["police"] = "careerSkills-police"
}

local function normalizeAttributeChange(change)
  local normalized = {}
  for key, value in pairs(change or {}) do
    local normalizedKey = attributeKeyAliases[key] or key
    normalized[normalizedKey] = (normalized[normalizedKey] or 0) + value
  end
  return normalized
end

local nonProgressAttributes = {
  money = true,
  beamXP = true,
  vouchers = true
}

local function isLevelUpEligibleAttribute(attributeKey, delta)
  if type(attributeKey) ~= "string" then return false end
  if type(delta) ~= "number" or delta <= 0 then return false end
  if nonProgressAttributes[attributeKey] then return false end
  if attributeKey:endswith("Reputation") then return false end
  return true
end

local function getBranchForAttributeKey(attributeKey)
  local function isValidBranch(candidate)
    return candidate and not candidate.missing and type(candidate.levels) == "table" and next(candidate.levels)
  end
  local function isCareerSkillsBranch(candidate)
    if type(candidate) ~= "table" then return false end
    if candidate.parentId == "careerSkills" then return true end
    if candidate.domainId == "careerSkills" then return true end
    if candidate.rootId == "careerSkills" then return true end
    if type(candidate.path) == "string" and candidate.path:find("careerSkills", 1, true) then return true end
    return false
  end

  local candidates = {}
  local byId = career_branches.getBranchById(attributeKey)
  if isValidBranch(byId) then
    table.insert(candidates, byId)
  end

  if career_branches.getBranchByPath then
    local byPath = career_branches.getBranchByPath(attributeKey)
    if isValidBranch(byPath) then
      table.insert(candidates, byPath)
    end
  end

  for _, candidate in ipairs(career_branches.getSortedBranches() or {}) do
    if candidate.attributeKey == attributeKey and isValidBranch(candidate) then
      table.insert(candidates, candidate)
    end
  end

  local bestBranch, bestScore = nil, -math.huge
  for _, candidate in ipairs(candidates) do
    local levelCount = #(candidate.levels or {})
    local score = levelCount
    if isCareerSkillsBranch(candidate) then
      score = score + 10000
    end
    if candidate.parentId == "careerSkills" then score = score + 1000 end
    if attributeKey == "logistics-delivery" and candidate.id == "logistics" then score = score + 100 end
    if score > bestScore then
      bestBranch, bestScore = candidate, score
    end
  end

  return bestBranch
end

local function calcBranchLevelSafe(value, branchRef)
  if type(branchRef) ~= "string" or branchRef == "" then return nil end
  local level = career_branches.calcBranchLevelFromValue(value, branchRef)
  if type(level) == "number" then
    return level
  end
  return nil
end

local function resolveBranchLevelFromValue(value, branch, attributeKey)
  -- Prefer attribute key to avoid ID collisions with legacy domain IDs (e.g. "logistics").
  local byAttributeKey = calcBranchLevelSafe(value, attributeKey)
  local byBranchId = calcBranchLevelSafe(value, branch and branch.id or nil)
  if byAttributeKey and byBranchId then
    return math.max(byAttributeKey, byBranchId)
  end
  return byAttributeKey or byBranchId or 0
end

local function sanitizeBranchLevels(levels)
  if type(levels) ~= "table" then return {} end
  local result = {}
  local lastRequiredValue = 0
  for i, levelInfo in ipairs(levels) do
    local entry = type(levelInfo) == "table" and deepcopy(levelInfo) or {}
    if type(entry.requiredValue) ~= "number" then
      entry.requiredValue = lastRequiredValue
    end
    lastRequiredValue = entry.requiredValue
    entry.levelLabel = entry.levelLabel or ("Level " .. i)
    result[#result + 1] = entry
  end
  return result
end

local function normalizeLevelLabel(label, fallbackLevel)
  if type(label) == "string" and label ~= "" then
    return label
  end
  return "Level " .. tostring(fallbackLevel or 0)
end

local function getTranslatedName(name)
  if type(name) ~= "string" then
    return ""
  end
  if translateLanguage then
    return translateLanguage(name, name)
  end
  return name
end

local function buildLevelUpEntry(attributeKey, branch, branchLevels, targetLevel, value)
  local levelLabel = career_branches.getLevelLabel(attributeKey, targetLevel)
  if type(levelLabel) ~= "string" or levelLabel == "" then
    levelLabel = career_branches.getLevelLabel(branch.id, targetLevel)
  end

  local animationData = {
    id = attributeKey,
    name = getTranslatedName(branch.name or attributeKey),
    level = targetLevel,
    levelLabel = normalizeLevelLabel(levelLabel, targetLevel),
    value = value,
    cover = branch.progressCover,
    glyphIcon = branch.icon,
    color = branch.color,
    accentColor = branch.accentColor,
  }

  local icon = career_branches.getBranchIcon(attributeKey) or branch.icon or "beamXPLo"
  local branchName = getTranslatedName(branch.name or attributeKey)
  local kindLabel = branch.isSkill and "Skill" or "Branch"

  return {
    attributeKey = attributeKey,
    branchId = branch.id,
    icon = icon,
    unlockPopupHeader = string.format("%s %s: Level %d", branchName, kindLabel, targetLevel),
    branchLevels = branchLevels,
    animationData = animationData,
    _order = career_branches.getOrder(attributeKey) or branch.order or 9999,
    _targetLevel = targetLevel,
  }
end

local function collectLevelUpCelebrations(change, reason, valueBeforeByAttribute)
  if type(change) ~= "table" then return {} end

  local entries = {}
  for attributeKey, delta in pairs(change) do
    if isLevelUpEligibleAttribute(attributeKey, delta) then
      local branch = getBranchForAttributeKey(attributeKey)
      local branchLevels = branch and sanitizeBranchLevels(branch.levels) or {}
      if branch and #branchLevels > 0 then
        local valueBefore = valueBeforeByAttribute[attributeKey]
        local valueAfter = (attributes[attributeKey] or baseAttribute).value
        if type(valueBefore) ~= "number" then
          valueBefore = valueAfter - delta
        end

        local levelBefore = resolveBranchLevelFromValue(valueBefore, branch, attributeKey)
        local levelAfter = resolveBranchLevelFromValue(valueAfter, branch, attributeKey)

        if levelAfter > levelBefore then
          for targetLevel = levelBefore + 1, levelAfter do
            entries[#entries + 1] = buildLevelUpEntry(attributeKey, branch, branchLevels, targetLevel, valueAfter)
          end
        end
      end
    end
  end

  table.sort(entries, function(a, b)
    if a._order == b._order then
      return (a._targetLevel or 0) < (b._targetLevel or 0)
    end
    return (a._order or 9999) < (b._order or 9999)
  end)

  for _, entry in ipairs(entries) do
    entry._order = nil
    entry._targetLevel = nil
  end

  return entries
end

local function init()
  attributeLog = {}
  attributes = {}
  attributes["beamXP"] = deepcopy(baseAttribute)
  attributes["money"] = deepcopy(baseAttribute)
  attributes["vouchers"] = deepcopy(baseAttribute)
  for _, branch in ipairs(career_branches.getSortedBranches()) do
    attributes[branch.attributeKey] = deepcopy(baseAttribute)
    attributes[branch.attributeKey].value = branch.defaultValue or baseAttribute.value
  end
end

-- reason should be table with label, list of tags
local function addAttributes(change, reason, fullprice)
  change = normalizeAttributeChange(change)

  -- make sure a reason exists!
  if not reason then
    reason = {
      label = "Unknown Reason",
      origin = debug.tracesimple()
    }
    log("W","",string.format("Changed attributes '%s' without giving a reason!", table.concat( tableKeysSorted(change), ", ")))
  end

  -- convert tags into LUT
  if not reason.tags then reason.tags = {} end
  reason.tags = tableValuesAsLookupDict(reason.tags)

  for attributeName, value in pairs(change) do
    if attributeName == "money" and career_modules_cheats and career_modules_cheats.isCheatsMode() then
      change[attributeName] = 0
    end
  end

  local valueBeforeByAttribute = {}
  -- make statistic
  for attributeName, value in pairs(change) do
    attributes[attributeName] = attributes[attributeName] or deepcopy(baseAttribute)
    local attribute = attributes[attributeName]
    valueBeforeByAttribute[attributeName] = attribute.value
    attribute.value = clamp(attribute.value + value, attribute.min or -math.huge, attribute.max or math.huge)
    for tag, en in pairs(reason.tags) do

      if en and value > 0 then
        attribute.gains[tag] = (attribute.gains[tag] or 0) + value
      end
      if en and value < 0 then
        attribute.losses[tag] = (attribute.losses[tag] or 0) + value
      end
    end
    if value > 0 then
      attribute.gains.all = (attribute.gains.all or 0) + value
    end
    if value < 0 then
      attribute.losses.all = (attribute.losses.all or 0) + value
    end

    if attributeName:endswith("Reputation") then
      local orgId = attributeName:sub(1, -11)
      career_career.interactWithOrganization(orgId)
    end
    attributes[attributeName] = attribute
  end

  local levelUpEntries = collectLevelUpCelebrations(change, reason, valueBeforeByAttribute)
  if #levelUpEntries > 0 then
    if guihooks and guihooks.trigger then
      guihooks.trigger("OpenCareerLevelUpCelebration", {entries = levelUpEntries})
    end
  end

  -- log change for logbook etc
  table.insert(attributeLog, {
    attributeChange = change,
    reason = reason,
    time = os.time()
  })

  -- always use the internal log system
  career_modules_log.addLog(reason.label, "playerAttributes")

  -- notify other systems
  extensions.hook("onPlayerAttributesChanged",change, reason)
end

local function setAttributes(newValues, reason)
  local ch = {}
  for attributeName, newValue in pairs(newValues) do
    local attribute = attributes[attributeName] or deepcopy(baseAttribute)
    ch[attributeName] = newValues[attributeName] - attribute.value
  end
  M.addAttributes(ch, reason)
end

local function getAttribute(attributeName)
  return attributes[attributeName]
end
local function getAttributeValue(attributeName)
  if not attributes then
    return 0
  end
  return (attributes[attributeName] or baseAttribute).value
end

local function getAllAttributes()
  return attributes
end

local logisticsSkillMigration = {
  version = 2,
  markerFile = "career/logisticsSkillMigration.json",
  unifiedKey = "logistics-delivery",
  legacyKeys = {
    "delivery",
    "vehicleDelivery",
    "materials",
    "logistics-vehicleDelivery",
    "logistics-materials"
  }
}

local policeSkillMigration = {
  version = 2,
  markerFile = "career/policeSkillMigration.json",
  unifiedKey = "careerSkills-police",
  legacyKey = "police"
}

local freSkillMigration = {
  version = 1,
  markerFile = "career/freSkillMigration.json",
  disciplineKeys = {
    "fre-crawling",
    "fre-roadracing",
    "fre-drift",
    "fre-drag",
    "fre-trail",
    "fre-oval",
    "fre-offroad",
    "fre-rally",
    "fre-landspeed",
    "fre-mudding"
  },
  keyMap = {
    crawl = "fre-crawling",
    crawling = "fre-crawling",
    apexRacing = "fre-roadracing",
    roadracing = "fre-roadracing",
    road_racing = "fre-roadracing",
    drift = "fre-drift",
    drag = "fre-drag",
    trail = "fre-trail",
    oval = "fre-oval",
    offroad = "fre-offroad",
    ["off-road"] = "fre-offroad",
    rally = "fre-rally",
    landspeed = "fre-landspeed",
    land_speed = "fre-landspeed",
    mud = "fre-mudding",
    extremeMud = "fre-mudding",
    extrememud = "fre-mudding",
    mudding = "fre-mudding"
  },
  legacyUnifiedKey = "fres"
}

local function ensureSerializableAttribute(jsonData, attributeKey)
  local attribute = jsonData[attributeKey]
  if type(attribute) ~= "table" then
    local replacement = deepcopy(baseAttribute)
    if type(attribute) == "number" then
      replacement.value = attribute
    end
    jsonData[attributeKey] = replacement
    attribute = replacement
  end
  attribute.gains = type(attribute.gains) == "table" and attribute.gains or {}
  attribute.losses = type(attribute.losses) == "table" and attribute.losses or {}
  return attribute
end

local function mergeLegacyAttribute(jsonData, unifiedKey, legacyKey)
  if legacyKey == unifiedKey then return 0, false end

  local legacyData = jsonData[legacyKey]
  if legacyData == nil then
    return 0, false
  end

  local mergedValue = 0
  if type(legacyData) == "table" then
    mergedValue = tonumber(legacyData.value) or 0
  elseif type(legacyData) == "number" then
    mergedValue = legacyData
  end

  local unifiedAttribute = ensureSerializableAttribute(jsonData, unifiedKey)
  unifiedAttribute.value = (tonumber(unifiedAttribute.value) or 0) + mergedValue

  if type(legacyData) == "table" then
    for gainKey, gainValue in pairs(legacyData.gains or {}) do
      unifiedAttribute.gains[gainKey] = (unifiedAttribute.gains[gainKey] or 0) + (tonumber(gainValue) or 0)
    end
    for lossKey, lossValue in pairs(legacyData.losses or {}) do
      unifiedAttribute.losses[lossKey] = (unifiedAttribute.losses[lossKey] or 0) + (tonumber(lossValue) or 0)
    end
  end

  jsonData[legacyKey] = nil
  return mergedValue, true
end

local function addSharedLegacyAttribute(jsonData, targetKey, legacyData, ratio)
  local targetAttribute = ensureSerializableAttribute(jsonData, targetKey)
  local sharedRatio = tonumber(ratio) or 0
  if sharedRatio <= 0 then
    return
  end

  if type(legacyData) == "table" then
    targetAttribute.value = (tonumber(targetAttribute.value) or 0) + ((tonumber(legacyData.value) or 0) * sharedRatio)
    for gainKey, gainValue in pairs(legacyData.gains or {}) do
      targetAttribute.gains[gainKey] = (targetAttribute.gains[gainKey] or 0) + ((tonumber(gainValue) or 0) * sharedRatio)
    end
    for lossKey, lossValue in pairs(legacyData.losses or {}) do
      targetAttribute.losses[lossKey] = (targetAttribute.losses[lossKey] or 0) + ((tonumber(lossValue) or 0) * sharedRatio)
    end
    return
  end

  if type(legacyData) == "number" then
    targetAttribute.value = (tonumber(targetAttribute.value) or 0) + (legacyData * sharedRatio)
  end
end

local function runLogisticsSkillMigration(savePath, jsonData)
  if not savePath or tableIsEmpty(jsonData or {}) then return end

  local markerPath = savePath .. "/" .. logisticsSkillMigration.markerFile
  local markerData = jsonReadFile(markerPath) or {}
  if (markerData.version or 0) >= logisticsSkillMigration.version then
    return
  end

  local mergedValue = 0
  local changed = false
  for _, legacyKey in ipairs(logisticsSkillMigration.legacyKeys) do
    local legacyMergedValue, legacyChanged = mergeLegacyAttribute(jsonData, logisticsSkillMigration.unifiedKey, legacyKey)
    mergedValue = mergedValue + legacyMergedValue
    changed = changed or legacyChanged
  end

  return {
    path = markerPath,
    saveData = changed,
    data = {
    version = logisticsSkillMigration.version,
    mergedValue = mergedValue,
    migratedAt = os.time()
    }
  }
end

local function runPoliceSkillMigration(savePath, jsonData)
  if not savePath or tableIsEmpty(jsonData or {}) then return end

  local markerPath = savePath .. "/" .. policeSkillMigration.markerFile
  local markerData = jsonReadFile(markerPath) or {}
  if (markerData.version or 0) >= policeSkillMigration.version then
    return
  end

  local legacyData = jsonData[policeSkillMigration.legacyKey]
  if not legacyData then
    return {
      path = markerPath,
      saveData = false,
      data = {
        version = policeSkillMigration.version,
        mergedValue = 0,
        migratedAt = os.time()
      }
    }
  end

  local mergedValue, changed = mergeLegacyAttribute(jsonData, policeSkillMigration.unifiedKey, policeSkillMigration.legacyKey)
  return {
    path = markerPath,
    saveData = changed,
    data = {
    version = policeSkillMigration.version,
    mergedValue = mergedValue,
    migratedAt = os.time()
    }
  }
end

local function runFreSkillMigration(savePath, jsonData)
  if not savePath or tableIsEmpty(jsonData or {}) then return end

  local markerPath = savePath .. "/" .. freSkillMigration.markerFile
  local markerData = jsonReadFile(markerPath) or {}
  if (markerData.version or 0) >= freSkillMigration.version then
    return
  end

  local changed = false
  local migratedValue = 0

  for legacyKey, disciplineKey in pairs(freSkillMigration.keyMap or {}) do
    local mergedValue, didMerge = mergeLegacyAttribute(jsonData, disciplineKey, legacyKey)
    if didMerge then
      changed = true
      migratedValue = migratedValue + (tonumber(mergedValue) or 0)
    end
  end

  local legacyUnifiedKey = freSkillMigration.legacyUnifiedKey
  local legacyUnifiedData = jsonData[legacyUnifiedKey]
  if legacyUnifiedData ~= nil then
    local sourceValue = 0
    if type(legacyUnifiedData) == "table" then
      sourceValue = tonumber(legacyUnifiedData.value) or 0
    elseif type(legacyUnifiedData) == "number" then
      sourceValue = legacyUnifiedData
    end

    local keyCount = #freSkillMigration.disciplineKeys
    if keyCount > 0 then
      local shareRatio = 1 / keyCount
      for _, disciplineKey in ipairs(freSkillMigration.disciplineKeys) do
        addSharedLegacyAttribute(jsonData, disciplineKey, legacyUnifiedData, shareRatio)
      end
      changed = true
      migratedValue = migratedValue + sourceValue
    end
    jsonData[legacyUnifiedKey] = nil
  end

  return {
    path = markerPath,
    saveData = changed,
    data = {
      version = freSkillMigration.version,
      mergedValue = migratedValue,
      migratedAt = os.time()
    }
  }
end

local function onExtensionLoaded()
  if not career_career.isActive() then return false end
  if not attributes then
    init()
  end

  -- load from saveslot
  local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()
  if not saveSlot then return end
  
  local careerDataPath = savePath .. "/career/general.json"
  local careerData = jsonReadFile(careerDataPath) or {}
  local isNewSave = tableIsEmpty(careerData)
  
  if isNewSave then
    init()
    return
  end
  
  local jsonData = (savePath and jsonReadFile(savePath .. "/career/playerAttributes.json")) or {}

  local saveInfo = savePath and jsonReadFile(savePath .. "/info.json")
  if saveInfo and saveInfo.version < 37 then
    -- rename bonusStars to vouchers
    jsonData.vouchers = jsonData.bonusStars
    jsonData.bonusStars = nil
  end

  local pendingMigrationMarkers = {}
  local migrationDataChanged = false

  local logisticsMigrationMarker = runLogisticsSkillMigration(savePath, jsonData)
  if logisticsMigrationMarker then
    pendingMigrationMarkers[#pendingMigrationMarkers + 1] = logisticsMigrationMarker
    migrationDataChanged = migrationDataChanged or logisticsMigrationMarker.saveData
  end

  local policeMigrationMarker = runPoliceSkillMigration(savePath, jsonData)
  if policeMigrationMarker then
    pendingMigrationMarkers[#pendingMigrationMarkers + 1] = policeMigrationMarker
    migrationDataChanged = migrationDataChanged or policeMigrationMarker.saveData
  end

  local freMigrationMarker = runFreSkillMigration(savePath, jsonData)
  if freMigrationMarker then
    pendingMigrationMarkers[#pendingMigrationMarkers + 1] = freMigrationMarker
    migrationDataChanged = migrationDataChanged or freMigrationMarker.saveData
  end

  if savePath and #pendingMigrationMarkers > 0 then
    if migrationDataChanged then
      career_saveSystem.jsonWriteFileSafe(savePath .. "/career/playerAttributes.json", jsonData, true)
    end
    for _, marker in ipairs(pendingMigrationMarkers) do
      career_saveSystem.jsonWriteFileSafe(marker.path, marker.data, true)
    end
  end

  local attributeLogData = (savePath and jsonReadFile(savePath .. "/career/attributeLog.json")) or {}
  if not tableIsEmpty(attributeLogData) then
    attributeLog = attributeLogData
  end
  
  local moneySum = 0
  for _, change in ipairs(attributeLog) do
    if change.attributeChange.money then
      moneySum = moneySum + change.attributeChange.money
    end
  end
  print("moneySum: " .. moneySum)

  if not tableIsEmpty(jsonData) then
    for name, data in pairs(jsonData) do
      attributes[name] = attributes[name] or deepcopy(baseAttribute)
      for k,v in pairs(data) do
        attributes[name][k] = v
      end
      if name == "money" then
        local gains = 0
        if data.gains.all then
          gains = data.gains.all
        end
        local losses = 0
        if data.losses.all then
          losses = -data.losses.all
        end
        attributes[name].value = math.min(data.value, gains - losses, moneySum)
        
        if career_modules_cheats and career_modules_cheats.isCheatsMode() then
          attributes[name].value = 1e12
        end

      end
    end
  end
end

-- this should only be loaded when the career is active
local function onSaveCurrentSaveSlot(currentSavePath)
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/playerAttributes.json", attributes, true)
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/attributeLog.json", attributeLog, true)
end


local function onCareerModulesActivated()
  for orgId, organization in pairs(freeroam_organizations.getOrganizations()) do
    if not attributes[orgId .. "Reputation"] then
      local attribute = deepcopy(baseAttribute)
      attribute.min = career_modules_reputation.getMinimumValue(organization)
      attribute.max = career_modules_reputation.getMaximumValue(organization)
      attributes[orgId .. "Reputation"] = attribute
    else
      attributes[orgId .. "Reputation"].min = career_modules_reputation.getMinimumValue(organization)
      attributes[orgId .. "Reputation"].max = career_modules_reputation.getMaximumValue(organization)
    end
  end
end

local function onCheatsModeChanged(enabled)
  if enabled and attributes and attributes.money then
    attributes.money.value = 1e12
  end
end

-- logbook integration
local function onLogbookGetEntries(list)

  local financialsText = '<span>Below is an overview of how you spent and earned money.<ul><li><b>Earn money</b> by playing Challenges and completing new Objectives, or by selling Vehicles and Parts.</li><li><b>Spend your Money</b> on new Vehicles and Parts, Insurances and Repairs, or by taking a Taxi.</li></ul><span><i>Disclaimer: Financial values are not balanced yet across the whole of career mode. So you might end up with too much or too little money in the long run.</i></span></span>'
  local financialsTable = {
    headers = {'Reason','Change','Time'},
    rows = {}
  }
  for _, change in ipairs(arrayReverse(deepcopy(attributeLog))) do
    if change.attributeChange.money then
      --local changeText = ""
      --local key = "money"
      --changeText = changeText .. string.format('<span><b>%s</b>: %s%0.2f</span>', key, change.attributeChange[key] > 0 and "+" or "", change.attributeChange[key])

      table.insert(financialsTable.rows,
        {change.reason.label, {type="rewards", rewards = {{attributeKey ="money", rewardAmount=change.attributeChange.money}}}, os.date("%c",change.time)}
      )
    end
  end

  local formattedFinancials = {
    entryId = "playerAttributeFinancials",
    type = "progress",
    cardTypeLabel = "ui.career.poiCard.generic",
    title = "Financial History",
    text = financialsText,
    time = os.time(),
    hideInRecent = true,
    tables = {financialsTable}
  }
  table.insert(list, formattedFinancials)

  local gameplayText = '<span style="margin-bottom:0.5em">Below is an overview of rewards you earned from Challenges, Milestones and Deliveries.<ul><li><b>Money</b> can be used to make purchases.</li><li><b>Beam XP</b> is a measure of your overall general progress, but has no use in game currently.</li><li><b>Branch XP</b> for the four branches will let you reach the next tier of that branch, unlocking new missions.</li><li><b>Bonus Stars</b> can currently only be used for fast repairs.</li></ul></span>'
  local gameplayTable = {
    headers = {'Reason','Change','Time'},
    rows = {}
  }
  for _, change in ipairs(arrayReverse(deepcopy(attributeLog))) do
    if change.reason.tags.gameplay then
      --local changeText = ""
      local rewards = {}
      for _, key in ipairs(career_branches.orderAttributeKeysByBranchOrder(tableKeys(change.attributeChange))) do
        if key:endswith("Reputation") then
          table.insert(rewards, {attributeKey = "reputation", rewardAmount = change.attributeChange[key], icon="peopleOutline"})
        else
          table.insert(rewards, {attributeKey = key, rewardAmount = change.attributeChange[key], icon = career_branches.getBranchIcon(key)})
        end
      --  changeText = changeText .. string.format('<span><b>%s</b>: %s%0.2f</span><br>', key, change.attributeChange[key] > 0 and "+" or "", change.attributeChange[key])
      end
      table.insert(gameplayTable.rows,
        {change.reason.label, {type="rewards", rewards = rewards}, os.date("%c",change.time)}
      )
    end
  end

  local formattedGameplay = {
    entryId = "playerAttributeGameplay",
    type = "progress",
    cardTypeLabel = "ui.career.poiCard.generic",
    title = "Rewards History",
    text = gameplayText,
    time = os.time()-1,
    hideInRecent = true,
    tables = {gameplayTable}
  }
  table.insert(list, formattedGameplay)

end

M.addAttributes = addAttributes
M.setAttributes = setAttributes
M.getAttribute = getAttribute
M.getAttributeValue = getAttributeValue
M.getAllAttributes = getAllAttributes
M.getAttributeLog = function() return attributeLog end

M.logAttributeChange = logAttributeChange
M.onLogbookGetEntries = onLogbookGetEntries
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onExtensionLoaded = onExtensionLoaded
M.onCareerModulesActivated = onCareerModulesActivated
M.onCheatsModeChanged = onCheatsModeChanged

return M
