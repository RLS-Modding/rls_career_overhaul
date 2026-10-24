-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- One-time skill XP merges, guarded by marker files in the save.
-- The caller writes the attributes first and the marker only after that write succeeds.
local M = {}

local baseAttribute = {value = 0, gains = {}, losses = {}}

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
  version = 2,
  markerFile = "career/freSkillMigration.json",
  disciplineKeys = {
    "fre-crawling",
    "fre-roadracing",
    "fre-drift",
    "fre-burnout",
    "fre-drag",
    "fre-trail",
    "fre-oval",
    "fre-offroad",
    "fre-rally",
    "fre-landspeed",
    "fre-mudding",
    "fre-demo"
  },
  keyMap = {
    crawl = "fre-crawling",
    crawling = "fre-crawling",
    apexRacing = "fre-roadracing",
    roadracing = "fre-roadracing",
    road_racing = "fre-roadracing",
    drift = "fre-drift",
    burnout = "fre-burnout",
    burnoutComp = "fre-burnout",
    burnoutcomp = "fre-burnout",
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
    mudding = "fre-mudding",
    demo = "fre-demo",
    demolition = "fre-demo",
    demolitionderby = "fre-demo"
  },
  legacyUnifiedKey = "fres"
}

local skillHierarchyMigration = {
  version = 1,
  markerFile = "career/skillHierarchyMigration.json",
  groups = {
    {target = "careerSkills-offroad", sources = {"fre-offroad", "fre-rally", "fre-crawling", "fre-mudding", "fre-trail"}},
    {target = "careerSkills-speed", sources = {"fre-drag", "fre-landspeed"}},
    {target = "careerSkills-mayhem", sources = {"fre-drift", "fre-burnout", "fre-demo"}},
    {target = "careerSkills-circuitRacing", sources = {"fre-roadracing", "fre-oval"}},
    {target = "careerSkills-emergency", sources = {"careerSkills-police", "careerSkills-paramedic"}},
    {target = "careerSkills-passenger", sources = {"careerSkills-bus", "careerSkills-taxi"}},
    {target = "careerSkills-operator", sources = {"labor"}},
    {target = "careerSkills-recovery", sources = {"careerSkills-repo", "careerSkills-offroadRecovery"}}
  }
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

-- A legacy attribute is either a {value, gains, losses} table or a bare number.
local function legacyNumericValue(legacyData)
  if type(legacyData) == "table" then
    return tonumber(legacyData.value) or 0
  elseif type(legacyData) == "number" then
    return legacyData
  end
  return 0
end

local function mergeLegacyAttribute(jsonData, unifiedKey, legacyKey)
  if legacyKey == unifiedKey then return 0, false end

  local legacyData = jsonData[legacyKey]
  if legacyData == nil then
    return 0, false
  end

  local mergedValue = legacyNumericValue(legacyData)
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

-- Shares a legacy attribute into a target, scaled by ratio (the fre split).
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

-- The marker path when this migration still has to run for the save; nil when it already ran.
local function pendingMarkerPath(savePath, jsonData, migration)
  if not savePath or tableIsEmpty(jsonData or {}) then return nil end
  local markerPath = savePath .. "/" .. migration.markerFile
  local markerData = jsonReadFile(markerPath) or {}
  if (markerData.version or 0) >= migration.version then return nil end
  return markerPath
end

-- The marker the caller writes after the attributes; summary holds the migration's own counters.
local function migrationResult(migration, markerPath, changed, summary)
  local data = {version = migration.version, migratedAt = os.time()}
  for key, value in pairs(summary) do data[key] = value end
  return {path = markerPath, saveData = changed, data = data}
end

local function runLogisticsSkillMigration(savePath, jsonData)
  local markerPath = pendingMarkerPath(savePath, jsonData, logisticsSkillMigration)
  if not markerPath then return end

  local mergedValue = 0
  local changed = false
  for _, legacyKey in ipairs(logisticsSkillMigration.legacyKeys) do
    local legacyMergedValue, legacyChanged = mergeLegacyAttribute(jsonData, logisticsSkillMigration.unifiedKey, legacyKey)
    mergedValue = mergedValue + legacyMergedValue
    changed = changed or legacyChanged
  end

  return migrationResult(logisticsSkillMigration, markerPath, changed, {mergedValue = mergedValue})
end

local function runPoliceSkillMigration(savePath, jsonData)
  local markerPath = pendingMarkerPath(savePath, jsonData, policeSkillMigration)
  if not markerPath then return end

  -- Nothing legacy to move: still write the marker so this save is not checked again.
  if not jsonData[policeSkillMigration.legacyKey] then
    return migrationResult(policeSkillMigration, markerPath, false, {mergedValue = 0})
  end

  local mergedValue, changed = mergeLegacyAttribute(jsonData, policeSkillMigration.unifiedKey, policeSkillMigration.legacyKey)
  return migrationResult(policeSkillMigration, markerPath, changed, {mergedValue = mergedValue})
end

local function runFreSkillMigration(savePath, jsonData)
  local markerPath = pendingMarkerPath(savePath, jsonData, freSkillMigration)
  if not markerPath then return end

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
    local sourceValue = legacyNumericValue(legacyUnifiedData)
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

  return migrationResult(freSkillMigration, markerPath, changed, {mergedValue = migratedValue})
end

local function runSkillHierarchyMigration(savePath, jsonData)
  local markerPath = pendingMarkerPath(savePath, jsonData, skillHierarchyMigration)
  if not markerPath then return end

  local changed = false
  local mergedBySkill = {}
  for _, group in ipairs(skillHierarchyMigration.groups) do
    local total = 0
    for _, source in ipairs(group.sources) do
      local amount, didMerge = mergeLegacyAttribute(jsonData, group.target, source)
      total = total + (tonumber(amount) or 0)
      changed = changed or didMerge
    end
    mergedBySkill[group.target] = total
  end
  return migrationResult(skillHierarchyMigration, markerPath, changed, {mergedBySkill = mergedBySkill})
end

M.runLogisticsSkillMigration = runLogisticsSkillMigration
M.runPoliceSkillMigration = runPoliceSkillMigration
M.runFreSkillMigration = runFreSkillMigration
M.runSkillHierarchyMigration = runSkillHierarchyMigration

return M
