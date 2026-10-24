-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Profile read models for the pause and select screens: BeamXP levels, the profile skill rows and the
-- save-derived figures on the profile cards. These only read; nothing here writes a save.
local M = {}

-- BeamXP needed to reach each level; level 1 starts at 0.
local BEAM_XP_LEVELS = {
  {requiredValue = 0},
  {requiredValue = 100},
  {requiredValue = 300},
  {requiredValue = 600},
  {requiredValue = 1000},
}

local SKILL_DOMAINS_DIRS = {
  "/gameplay/overhaul/domains/careerSkills/skills/",
}

-- Older and short skill names that resolve to the canonical skill attribute key.
local skillAttributeKeyAliases = {
  ["police"] = "careerSkills-emergency",
  ["bus"] = "careerSkills-passenger",
  ["paramedic"] = "careerSkills-emergency",
  ["ambulance"] = "careerSkills-emergency",
  ["delivery"] = "logistics-delivery",
  ["vehicleDelivery"] = "logistics-delivery",
  ["materials"] = "logistics-delivery",
}

-- The BeamXP level reached, the progress into it and the XP still needed for the next one; -1 when unknown.
local function getBeamXPLevel(xp)
  local level = -1
  local neededForNext = -1
  local curLvlProgress = -1
  for i, lvl in ipairs(BEAM_XP_LEVELS) do
    if xp >= lvl.requiredValue then
      level = i
    end
  end
  if BEAM_XP_LEVELS[level + 1] then
    neededForNext = BEAM_XP_LEVELS[level + 1].requiredValue
    curLvlProgress = xp - BEAM_XP_LEVELS[level].requiredValue
  end
  return level, curLvlProgress, neededForNext
end

-- The level a value reaches on sorted thresholds, the progress into it and the span to the next threshold.
local function levelFromThresholds(value, thresholds)
  local level = 0
  local prevT, nextT = 0, nil
  for i, threshold in ipairs(thresholds) do
    if value >= threshold then
      level = i
      prevT = threshold
    else
      nextT = threshold
      break
    end
  end
  local curProg, needNext = 0, 1
  if nextT then
    needNext = math.max(1, nextT - prevT)
    curProg = math.max(0, value - prevT)
  elseif level > 0 then
    curProg, needNext = 1, 1
  end
  return level, curProg, needNext
end

-- The skill's value: live from the career when useLive, else from the saved attribute data.
local function menuSkillReadValue(attData, attKey, useLive)
  if useLive then
    if not overhaul_career_career.isActive() then return 0 end
    return tonumber(overhaul_career_economy_playerAttributes.getAttributeValue(attKey)) or 0
  end
  if type(attData) ~= "table" or type(attKey) ~= "string" then return 0 end
  -- The canonical saved key first, then the fixed legacy name and the skill aliases.
  local tryKeys = {attKey}
  local legacyKey = overhaul_career_progression_skills.newAttributeNamesToOldNames[attKey]
  if legacyKey then table.insert(tryKeys, legacyKey) end
  if skillAttributeKeyAliases[attKey] then
    table.insert(tryKeys, skillAttributeKeyAliases[attKey])
  end
  for alias, canonical in pairs(skillAttributeKeyAliases) do
    if canonical == attKey then table.insert(tryKeys, alias) end
  end
  for _, key in ipairs(tryKeys) do
    local blob = attData[key]
    if type(blob) == "table" then return tonumber(blob.value) or 0 end
    if type(blob) == "number" then return blob end
  end
  return 0
end

-- The profile card rows (the stock pause profile overview renders data.branches): the canonical skills.
local function profileSkillRows(skills)
  local rows = {}
  for _, skill in ipairs(skills or {}) do
    table.insert(rows, {id = skill.skillKey, label = skill.label, icon = skill.icon, color = skill.color, value = skill.value,
      level = skill.level, curLvlProgress = skill.curLvlProgress, neededForNext = skill.neededForNext, levelLabel = skill.levelLabel})
  end
  return rows
end

local function thresholdsOf(levels)
  local thresholds = {}
  for _, entry in ipairs(levels) do
    local requiredValue = tonumber(entry.requiredValue)
    if requiredValue then table.insert(thresholds, requiredValue) end
  end
  table.sort(thresholds)
  return thresholds
end

-- The menu skill for one info.json, or nil when it is hidden, unnamed, a duplicate or has no levels.
local function menuSkillFromInfo(filePath, info, seen)
  if type(info) ~= "table" or info.isSkill ~= true or type(info.levels) ~= "table" or not info.levels[1] then return nil end
  local name = info.name or ""
  if name:lower():find("coming soon") then return nil end

  local folderId = filePath:match("/([^/]+)/info%.json$")
  if not folderId then return nil end

  local attKey = info.attributeKey
  if not attKey or attKey == "" then
    attKey = skillAttributeKeyAliases[folderId] or ("careerSkills-" .. folderId)
  end
  if seen[attKey] then return nil end
  seen[attKey] = true

  return {
    id = folderId,
    label = name,
    attributeKey = attKey,
    icon = info.icon or "racing",
    color = info.color or nil,
    order = tonumber(info.order) or 9999,
    thresholds = thresholdsOf(info.levels),
    hideUntilProgress = info.hideUntilProgress == true,
  }
end

-- Every skill with a readable info.json, in declared order. Cached on the instance that asks first.
local function discoverMenuSkills(state)
  if state.skills then return state.skills end
  local skills, seen = {}, {}
  state.skills = skills
  for _, dir in ipairs(SKILL_DOMAINS_DIRS) do
    for _, filePath in ipairs(FS:findFiles(dir, "info.json", 1, false, false) or {}) do
      local skill = menuSkillFromInfo(filePath, jsonReadFile(filePath), seen)
      if skill then table.insert(skills, skill) end
    end
  end
  table.sort(skills, function(left, right) return left.order < right.order end)
  return skills
end

-- One profile row: level and progress from the value, with the branch's icon and colour when the catalog has them.
local function menuSkillRow(skill, value, includeMaxLevel)
  local level, curProg, needNext = levelFromThresholds(value, skill.thresholds)
  local icon, color, accentColor = skill.icon, skill.color, nil
  local branch = overhaul_career_progression_skills.getBranchById(skill.attributeKey)
    or overhaul_career_progression_skills.getBranchByPath(skill.attributeKey)
  if type(branch) == "table" then
    if branch.icon then icon = branch.icon end
    if branch.color then color = branch.color end
    accentColor = branch.accentColor
  end
  local row = {
    id = skill.id,
    label = skill.label,
    skillKey = skill.attributeKey,
    icon = icon,
    color = color,
    level = level,
    value = value,
    curLvlProgress = curProg,
    neededForNext = needNext,
    levelLabel = {txt = "ui.career.lvlLabel", context = {lvl = level}},
  }
  if includeMaxLevel then
    row.maxLevel = level >= #skill.thresholds
    row.accentColor = accentColor
  end
  return row
end

-- Sets data.freSkills to the profile skill rows, leaving out skills that stay hidden until they have progress.
local function fillMenuProfileSkills(state, data, attData, useLive)
  data.freSkills = {}
  for _, skill in ipairs(discoverMenuSkills(state)) do
    local value = menuSkillReadValue(attData, skill.attributeKey, useLive)
    if not (skill.hideUntilProgress and (tonumber(value) or 0) <= 0) then
      table.insert(data.freSkills, menuSkillRow(skill, value, state.includeMaxLevel))
    end
  end
end

-- purchasedGarages.json stores {garages = {[id] = true}}, so the owned count is the number of keys.
local function countPurchasedGarages(autosavePath)
  local data = jsonReadFile(autosavePath .. "/career/rls_career/purchasedGarages.json")
  if type(data) ~= "table" or type(data.garages) ~= "table" then return 0 end
  return tableSize(data.garages)
end

-- Walk history backward because the file grows for the whole life of a save.
local function summariseRecentMoney(attributeLog, limit)
  local res = {}
  if type(attributeLog) ~= "table" then return res end
  limit = limit or 5

  for i = #attributeLog, 1, -1 do
    local entry = attributeLog[i]
    local amount = type(entry) == "table" and type(entry.attributeChange) == "table"
      and tonumber(entry.attributeChange.money) or nil
    -- Either a translation key or a {txt, context} table; the UI translates it.
    local label = type(entry) == "table" and type(entry.reason) == "table" and entry.reason.label or nil
    -- Unlabelled entries (fuel, incidental charges) would render as a row reading "Transaction" and a number.
    if amount and amount ~= 0 and label then
      table.insert(res, {amount = amount, label = label, time = entry.time})
      if #res >= limit then break end
    end
  end

  return res
end

-- What one vehicle is worth now: age and mileage only, computed the same way whether or not the save is running.
local function vehicleAssetValue(vehicle)
  local base = tonumber(vehicle and vehicle.configBaseValue) or 0
  if base <= 0 then return 0 end
  if not overhaul_career_career.isActive() then
    return base
  end
  return tonumber(overhaul_career_market_valueCalculator.getQuickVehicleValue(base, vehicle.year, vehicle.mileage)) or base
end

-- Save paths are stored relative; the UI needs one it can put in an img src.
local function toUiPath(path)
  if type(path) ~= "string" or path == "" then return nil end
  if path:sub(1, 1) ~= "/" then return "/" .. path end
  return path
end

-- Only use a saved thumbnail when the profile contains one.
local function currentVehicleHighlight(autosavePath, vehicle, currentId)
  if not currentId then return nil end
  local res = {
    name = vehicle and (vehicle.niceName or vehicle.model) or nil,
    location = vehicle and vehicle.niceLocation or nil,
  }
  local base = autosavePath .. "/career/vehicles/" .. tostring(currentId)
  for _, ext in ipairs({".jpg", ".png"}) do
    if FS:fileExists(base .. ext) then
      res.image = toUiPath(base .. ext)
      break
    end
  end
  if not res.name and not res.image then return nil end
  return res
end

-- One instance per career module: its skill list cache is not shared with other instances.
function M.new(options)
  local state = {includeMaxLevel = options and options.includeMaxLevel}
  return {
    fillMenuProfileSkills = function(data, attData, useLive)
      fillMenuProfileSkills(state, data, attData, useLive)
    end,
  }
end

M.getBeamXPLevel = getBeamXPLevel
M.profileSkillRows = profileSkillRows
M.countPurchasedGarages = countPurchasedGarages
M.summariseRecentMoney = summariseRecentMoney
M.vehicleAssetValue = vehicleAssetValue
M.toUiPath = toUiPath
M.currentVehicleHighlight = currentVehicleHighlight

return M
