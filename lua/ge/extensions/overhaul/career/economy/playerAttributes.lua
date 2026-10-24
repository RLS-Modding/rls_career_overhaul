-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/playerAttributes.lua (BeamNG 0.40).
-- Player attribute values (money, XP, reputation) with their change log; every money change posts to the wallet.
-- Keeps the stock layout on purpose so it still diffs against stock.

local M = {}
require("overhaul/lib/progression/logbookRegistry").registerType("overhaul.levelUp", function(data)
  if type(data.name) ~= "string" or type(data.level) ~= "number" then return end
  local fallback = "Level " .. tostring(data.level)
  local label = data.levelLabel
  local text = type(label) == "string" and label ~= ""
    and translateLanguage(label, label:match("^ui%.") and fallback or label) or fallback
  return {icon = "checkmark", title = string.format("%s: Level %d", data.name, data.level), label = "Level up", text = text}
end, "overhaul.playerAttributes")
-- Debug log helper; replace the body with a no-op to silence it.
local dlog = function(m) log("D","",m) end

local attributes
local attributeLog
local ledgerAuthority = require("overhaul/lib/ledger/authority")
local moneyCategories = require("overhaul/lib/ledger/categories")
local financeMetadata = require("overhaul/lib/finance/metadata")
local financeReadModel = require("overhaul/lib/finance/readModel")
local baseAttribute = {value = 0, gains = {}, losses = {}}
local skillLookup = require("overhaul/lib/progression/skillLookup")
local skillMigrations = require("overhaul/career/economy/playerAttributes/skillMigrations")

-- Persisted attribute aliases and branch-path aliases stay separate because their namespaces differ.
local canonicalAttributeKeyByLegacyKey = {
  ["delivery"] = "logistics-delivery",
  ["vehicleDelivery"] = "logistics-delivery",
  ["materials"] = "logistics-delivery",
  ["logistics-vehicleDelivery"] = "logistics-delivery",
  ["logistics-materials"] = "logistics-delivery",
  ["police"] = "careerSkills-emergency",
  ["careerSkills-police"] = "careerSkills-emergency",
  ["careerSkills-paramedic"] = "careerSkills-emergency",
  ["careerSkills-bus"] = "careerSkills-passenger",
  ["careerSkills-taxi"] = "careerSkills-passenger",
  ["careerSkills-repo"] = "careerSkills-recovery",
  ["careerSkills-offroadRecovery"] = "careerSkills-recovery",
  ["careerSkills-drag"] = "careerSkills-speed",
  ["careerSkills-drift"] = "careerSkills-mayhem",
  ["careerSkills-roadracing"] = "careerSkills-circuitRacing",

  -- Older FRE and map-expansion XP tags keep working while new content writes the parent skill directly.
  ["fre-offroad"] = "careerSkills-offroad",
  ["fre-rally"] = "careerSkills-offroad",
  ["fre-crawling"] = "careerSkills-offroad",
  ["fre-mudding"] = "careerSkills-offroad",
  ["fre-trail"] = "careerSkills-offroad",
  ["fre-drag"] = "careerSkills-speed",
  ["fre-landspeed"] = "careerSkills-speed",
  ["fre-drift"] = "careerSkills-mayhem",
  ["fre-burnout"] = "careerSkills-mayhem",
  ["fre-demo"] = "careerSkills-mayhem",
  ["fre-roadracing"] = "careerSkills-circuitRacing",
  ["fre-oval"] = "careerSkills-circuitRacing",
  crawl = "careerSkills-offroad",
  crawling = "careerSkills-offroad",
  offroad = "careerSkills-offroad",
  ["off-road"] = "careerSkills-offroad",
  rally = "careerSkills-offroad",
  trail = "careerSkills-offroad",
  mud = "careerSkills-offroad",
  mudding = "careerSkills-offroad",
  extremeMud = "careerSkills-offroad",
  extrememud = "careerSkills-offroad",
  drag = "careerSkills-speed",
  landspeed = "careerSkills-speed",
  land_speed = "careerSkills-speed",
  drift = "careerSkills-mayhem",
  burnout = "careerSkills-mayhem",
  burnoutComp = "careerSkills-mayhem",
  burnoutcomp = "careerSkills-mayhem",
  demo = "careerSkills-mayhem",
  demolition = "careerSkills-mayhem",
  demolitionderby = "careerSkills-mayhem",
  apexRacing = "careerSkills-circuitRacing",
  roadracing = "careerSkills-circuitRacing",
  road_racing = "careerSkills-circuitRacing",
  oval = "careerSkills-circuitRacing"
}

-- Keys that are not skill progress: money, BeamXP and vouchers never raise a skill level.
local nonProgressAttributes = {
  money = true,
  beamXP = true,
  vouchers = true
}

local function canonicalAttributeKey(attributeName)
  return canonicalAttributeKeyByLegacyKey[attributeName] or attributeName
end

-- Sums a change table under canonical keys, so legacy and canonical names of one skill add together.
local function normalizeAttributeChange(change)
  local normalized = {}
  for key, value in pairs(change or {}) do
    local normalizedKey = canonicalAttributeKey(key)
    normalized[normalizedKey] = (normalized[normalizedKey] or 0) + value
  end
  return normalized
end

-- A positive change to a skill attribute, excluding money, BeamXP, vouchers and reputation.
local function isLevelUpEligibleAttribute(attributeKey, delta)
  if type(attributeKey) ~= "string" then return false end
  if type(delta) ~= "number" or delta <= 0 then return false end
  if nonProgressAttributes[attributeKey] then return false end
  if attributeKey:endswith("Reputation") then return false end
  return true
end


-- Level-up celebrations: one entry per crossed skill level, in skill order.

-- careerSkills branches win; "logistics-delivery" resolves to the logistics branch.
local function getBranchForAttributeKey(attributeKey)
  return skillLookup.findBranchForAttributeKey(attributeKey, {logisticsDelivery = true})
end

local function levelLabelFor(level)
  return "Level " .. level
end

local function calcBranchLevelSafe(value, branchRef)
  if type(branchRef) ~= "string" or branchRef == "" then return nil end
  local level = skillLookup.levelFromValue(value, branchRef)
  if type(level) == "number" then
    return level
  end
  return nil
end

-- Prefer the attribute key over the branch id: legacy domain ids such as "logistics" can collide.
local function resolveBranchLevelFromValue(value, branch, attributeKey)
  local byAttributeKey = calcBranchLevelSafe(value, attributeKey)
  local byBranchId = calcBranchLevelSafe(value, branch and branch.id or nil)
  if byAttributeKey and byBranchId then
    return math.max(byAttributeKey, byBranchId)
  end
  return byAttributeKey or byBranchId or 0
end


local function normalizeLevelLabel(label, fallbackLevel)
  local fallback = "Level " .. tostring(fallbackLevel or 0)
  if type(label) ~= "string" or label == "" then return fallback end
  return translateLanguage(label, label:match("^ui%.") and fallback or label)
end

local function getTranslatedName(name)
  if type(name) ~= "string" then
    return ""
  end
  return translateLanguage(name, name)
end

local function buildLevelUpEntry(attributeKey, branch, branchLevels, targetLevel, value)
  local levelLabel = overhaul_career_progression_skills.getLevelLabel(attributeKey, targetLevel)
  if type(levelLabel) ~= "string" or levelLabel == "" then
    levelLabel = overhaul_career_progression_skills.getLevelLabel(branch.id, targetLevel)
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

  -- The owning branch decides the icon; its id can differ from the attribute key's branch.
  local icon = branch.icon or overhaul_career_progression_skills.getBranchIcon(attributeKey) or "beamXPLo"
  local branchName = getTranslatedName(branch.name or attributeKey)
  local kindLabel = branch.isSkill and "Skill" or "Branch"

  return {
    attributeKey = attributeKey,
    branchId = branch.id,
    icon = icon,
    unlockPopupHeader = string.format("%s %s: Level %d", branchName, kindLabel, targetLevel),
    branchLevels = branchLevels,
    animationData = animationData,
    _order = overhaul_career_progression_skills.getOrder(attributeKey) or branch.order or 9999,
    _targetLevel = targetLevel,
  }
end

-- attributes: the career's attribute table after the change (values read only).
local function collectLevelUpCelebrations(change, reason, valueBeforeByAttribute, attributes)
  if type(change) ~= "table" then return {} end

  local entries = {}
  for attributeKey, delta in pairs(change) do
    if isLevelUpEligibleAttribute(attributeKey, delta) then
      local branch = getBranchForAttributeKey(attributeKey)
      local branchLevels = branch and skillLookup.sanitizeLevels(branch.levels, levelLabelFor) or {}
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


local function getRewardDisplayName(attributeKey)
  if attributeKey == "money" then return "ui.pause.career.historyRewardMoney" end
  if attributeKey == "beamXP" then return "ui.pause.career.historyRewardBeamXp" end
  if attributeKey == "vouchers" then return "ui.pause.career.historyRewardVouchers" end
  if attributeKey == "reputation" then return "ui.pause.career.historyRewardReputation" end

  local branch = getBranchForAttributeKey(canonicalAttributeKey(attributeKey))
  if branch then
    return {
      txt = "ui.pause.career.historyRewardBranchXp",
      context = {branchName = branch.branchHeading or branch.name},
    }
  end

  return attributeKey
end

local function formatReward(reward)
  if not reward then return nil end
  reward.displayName = reward.displayName or getRewardDisplayName(reward.attributeKey)
  return reward
end

local function init()
  attributeLog = {}
  attributes = {}
  attributes["beamXP"] = deepcopy(baseAttribute)
  attributes["money"] = deepcopy(baseAttribute)
  attributes["vouchers"] = deepcopy(baseAttribute)
  for _, branch in ipairs(overhaul_career_progression_skills.getSortedBranches()) do
    attributes[branch.attributeKey] = deepcopy(baseAttribute)
    attributes[branch.attributeKey].value = branch.defaultValue or baseAttribute.value
  end
  local modeData = overhaul_career_career.getCurrentStartingModeData()
  local initPlayerAttributesFn = modeData and (modeData.initPlayerAttributes or modeData.initiPlayerAttributes)

  -- Stock start modes seed $10k as "Starting Capital". RLS applies the real
  -- amount later (sandbox Starting Cash / difficulty / challenge). Strip money
  -- from this pass so the financial log only gets one Starting Capital entry.
  if type(initPlayerAttributesFn) == "function" then
    local originalSetAttributes = M.setAttributes
    M.setAttributes = function(newValues, reason)
      if type(newValues) ~= "table" then
        return
      end
      local filtered = {}
      for key, value in pairs(newValues) do
        if key ~= "money" then
          filtered[key] = value
        end
      end
      if next(filtered) then
        originalSetAttributes(filtered, reason)
      end
    end
    initPlayerAttributesFn(M)
    M.setAttributes = originalSetAttributes
  end
  -- Money stays at base (0) until career.lua / challengeModes grant starting capital.
end

-- The attribute mutation primitive: value with clamping, raw-delta gain/loss counters per
-- enabled tag and in total, organization interaction for reputation.
local function applyAttributeChange(attributeName, value, tags)
  local attribute = attributes[attributeName]
  local previousValue = attribute.value
  attribute.value = clamp(attribute.value + value, attribute.min or -math.huge, attribute.max or math.huge)
  for tag, en in pairs(tags) do

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
    extensions.hook("onOverhaulOrganizationReputationChanged", orgId, previousValue, attribute.value)
    overhaul_career_career.interactWithOrganization(orgId)
  end
  attributes[attributeName] = attribute
end

-- The wallet is the Ledger's "wallet" account; its primitive is the money attribute change.
-- This module instance keeps its own handle (see lib/ledger/authority).
local walletAccount = ledgerAuthority.bind("wallet", {
  get = function()
    local money = attributes and attributes.money
    return (money and money.value) or 0
  end,
  apply = function(delta, op)
    applyAttributeChange("money", delta, op.meta.tags)
  end,
})

-- reason should be table with label, list of tags
local function addAttributes(change, reason, fullprice, onRecorded)
  change = normalizeAttributeChange(change)

  -- make sure a reason exists!
  if not reason then
    reason = {
      label = "ui.career.attributeLog.unknownReason",
      origin = debug.tracesimple()
    }
    log("W","",string.format("Changed attributes '%s' without giving a reason!", table.concat( tableKeysSorted(change), ", ")))
  end

  -- convert tags into LUT
  if not reason.tags then reason.tags = {} end
  reason.tags = tableValuesAsLookupDict(reason.tags)

  local valueBeforeByAttribute = {}
  -- make statistic; money goes through the Ledger, which runs applyAttributeChange
  for attributeName, value in pairs(change) do
    attributes[attributeName] = attributes[attributeName] or deepcopy(baseAttribute)
    valueBeforeByAttribute[attributeName] = attributes[attributeName].value
    if attributeName == "money" then
      ledgerAuthority.post(walletAccount, value, reason)
      -- Keep the real posting in history and statistics. The cheat balance is
      -- a checkpoint adjustment, not income or an expense of its own.
      M.onOverhaulCheatsModeChanged(overhaul_career_economy_cheats and overhaul_career_economy_cheats.isCheatsMode())
    else
      applyAttributeChange(attributeName, value, reason.tags)
    end
  end

  local levelUpEntries = collectLevelUpCelebrations(change, reason, valueBeforeByAttribute, attributes)
  if #levelUpEntries > 0 then
    for _, entry in ipairs(levelUpEntries) do
      local ok, problem = pcall(extensions.hook, "onOverhaulLogbookEvent", "overhaul.levelUp", entry.animationData)
      if not ok and log then log("W", "playerAttributes", tostring(problem)) end
    end
    guihooks.trigger("OpenCareerLevelUpCelebration", {entries = levelUpEntries})
  end

  -- Translate for the log line only. Keep reason.label in its original key/table
  -- form so history UI can compose demand suffixes from dedicated fields.
  local logLabel = reason.label
  if type(logLabel) == "table" then
    logLabel = core_locales.translateWithOrWithoutContext(logLabel)
  elseif type(logLabel) == "string" then
    logLabel = _tr(logLabel)
  end

  -- Opportunity economy: append demand % when job pay was market-adjusted,
  -- and surface a short confirmation when high-demand rates applied.
  local moneyDelta = change.money
  if type(moneyDelta) == "number" and moneyDelta > 0 then
    local jobId, factor
    -- Prefer stamped demand from delivery drop-off (baked at offer generation).
    if type(reason.demandFactor) == "number" and reason.demandFactor > 0 then
      factor = reason.demandFactor
      jobId = reason.demandJobId
      if not jobId and overhaul_career_economy_activityHeat then
        local okClassify, classified = pcall(overhaul_career_economy_activityHeat.classifyEarningTags, reason.tags)
        if okClassify then jobId = classified end
      end
      jobId = jobId or "delivery"
    elseif overhaul_career_economy_activityHeat then
      local ok = pcall(function()
        jobId, factor = overhaul_career_economy_activityHeat.getDemandFactorForTags(reason.tags)
      end)
      if not ok then jobId, factor = nil, nil end
    end
    if jobId then reason.demandJobId = jobId end
    if type(factor) == "number" then reason.demandFactor = factor end
    if jobId and type(factor) == "number" and math.abs(factor - 1.0) > 0.01 then
      local pct = math.floor(math.abs(factor - 1.0) * 100 + 0.5)
      if factor > 1.0 then
        logLabel = tostring(logLabel or "") .. string.format(_tr(" (+%d%% high demand)"), pct)
        if overhaul_career_economy_activityHeat then
          pcall(overhaul_career_economy_activityHeat.notifyHighDemandPayout, jobId, moneyDelta, factor)
        end
      else
        logLabel = tostring(logLabel or "") .. string.format(_tr(" (−%d%% market)"), pct)
      end
    end
  end

  -- The snapshot owns vehicle/facility data. Retain only an explicit nested
  -- category in the saved reason, since legacy inference needs its provenance.
  local savedReason = {}
  for key, value in pairs(reason) do if key ~= "finance" then savedReason[key] = value end end
  if type(reason.finance) == "table" and reason.finance.category ~= nil then
    savedReason.finance = {category = reason.finance.category}
  end
  local logRow = {
    attributeChange = change,
    reason = savedReason,
    time = os.time()
  }
  if type(change.money) == "number" then
    logRow.finance = financeMetadata.capture(reason, logRow.time, change.money)
  end
  -- Money rows keep a category only when the caller named one, for the statistics view.
  if change.money ~= nil and reason.category ~= nil then
    logRow.category = moneyCategories.normalize(reason.category)
  end
  table.insert(attributeLog, logRow)
  -- Optional in-process receipt for owners that must finish asynchronous metadata.
  -- Kept out of reason/save data; the existing return contract stays unchanged.
  if type(onRecorded) == "function" then
    local ok, problem = pcall(onRecorded, logRow)
    if not ok then log("E", "career.playerAttributes", "Finance receipt callback failed: " .. tostring(problem)) end
  end
  if type(change.money) == "number" and change.money ~= 0 then
    guihooks.trigger("OverhaulFinancialHistoryChanged")
  end

  if overhaul_career_ui_log then
    overhaul_career_ui_log.addLog(logLabel, "playerAttributes")
  end

  -- notify other systems
  extensions.hook("onOverhaulPlayerAttributesChanged",change, reason)

  if reason.tags.gameplay and change.money and gameplay_achievement then
    gameplay_achievement.unlockAchievement("FIRST_ASSIGNMENT")
  end

  if reason.tags.fine and change.money and gameplay_achievement then
    gameplay_achievement.unlockAchievement("PAID_THE_PRICE")
  end
end

local function setAttributes(newValues, reason)
  local changes = {}
  for attributeName, newValue in pairs(newValues) do
    local normalizedName = canonicalAttributeKey(attributeName)
    local attribute = attributes[normalizedName] or deepcopy(baseAttribute)
    changes[normalizedName] = newValue - attribute.value
  end
  M.addAttributes(changes, reason)
end

local function getAttribute(attributeName)
  return attributes[canonicalAttributeKey(attributeName)]
end
local function getAttributeValue(attributeName)
  if not attributes then
    return 0
  end
  return (attributes[canonicalAttributeKey(attributeName)] or baseAttribute).value
end

local function getAllAttributes()
  return attributes
end


-- The stock reward pill only has units for these keys; any other reward needs an icon,
-- or the pill prints BngUnit's "Unknown unit type" error instead of the amount.
local stockRewardUnits = {money = true, beamXP = true, vouchers = true}
local fallbackRewardIcon = "star"

-- Skill attribute keys often differ from the skill's path id (stamina, fre-*, delivery),
-- so look the skill up by attribute key, not by path.
local function gameplayRewardIcon(attributeKey)
  if stockRewardUnits[attributeKey] then return nil end
  local branch = getBranchForAttributeKey(canonicalAttributeKey(attributeKey))
  return branch and branch.icon or fallbackRewardIcon
end

local function buildGameplayRewards(attributeChange)
  local rewards = {}
  for _, key in ipairs(overhaul_career_progression_skills.orderAttributeKeysByBranchOrder(tableKeys(attributeChange or {}))) do
    if key:endswith("Reputation") then
      table.insert(rewards, formatReward({attributeKey = "reputation", rewardAmount = attributeChange[key], icon="peopleOutline"}))
    else
      table.insert(rewards, formatReward({attributeKey = key, rewardAmount = attributeChange[key], icon = gameplayRewardIcon(key)}))
    end
  end
  return rewards
end

local function historyReasonLabel(reason)
  local label = reason and reason.label
  if type(label) == "table" then
    label = core_locales.translateWithOrWithoutContext(label)
  elseif type(label) == "string" then
    label = _tr(label)
  else
    label = _tr("ui.career.attributeLog.unknownReason")
  end
  local factor = tonumber(reason and reason.demandFactor)
  if type(factor) == "number" and math.abs(factor - 1.0) > 0.01 then
    local pct = math.floor(math.abs(factor - 1.0) * 100 + 0.5)
    if factor > 1.0 then
      label = tostring(label or "") .. string.format(_tr(" (+%d%% high demand)"), pct)
    else
      label = tostring(label or "") .. string.format(_tr(" (−%d%% market)"), pct)
    end
  end
  return label
end

local function getCareerHistoryChanges(historyType, limit)
  local maxEntries = tonumber(limit)
  local rows = {}
  if not attributeLog then return rows end

  for logIndex = #attributeLog, 1, -1 do
    local change = attributeLog[logIndex]
    local attributeChange = change.attributeChange or {}
    local reason = change.reason or {}
    local rewards
    if historyType == "financial" and attributeChange.money then
      rewards = {
        formatReward({
          attributeKey = "money",
          rewardAmount = attributeChange.money,
        })
      }
    elseif historyType == "gameplay" and reason.tags and reason.tags.gameplay then
      rewards = buildGameplayRewards(attributeChange)
    end

    if rewards and #rewards > 0 then
      table.insert(rows, {
        reason = historyReasonLabel(reason),
        time = change.time,
        rewards = rewards,
      })
      if maxEntries and #rows >= maxEntries then
        break
      end
    end
  end

  return rows
end

local function getRecentFinancialChanges(limit)
  return getCareerHistoryChanges("financial", limit or 5)
end

local function getFinancialHistory(limit)
  return getCareerHistoryChanges("financial", limit)
end

local function getFinancialHistoryView(options)
  return financeReadModel.page(attributeLog, options, {
    balance = getAttributeValue("money"), label = historyReasonLabel,
  })
end

local function getGameplayHistory(limit)
  return getCareerHistoryChanges("gameplay", limit)
end

local function getCareerHistoryInfo(historyType)
  if historyType == "gameplay" then
    return {
      title = "ui.pause.career.gameplayHistory",
    }
  end
  return {
    title = "ui.pause.career.financialHistory",
  }
end

local runLogisticsSkillMigration = skillMigrations.runLogisticsSkillMigration
local runPoliceSkillMigration = skillMigrations.runPoliceSkillMigration
local runFreSkillMigration = skillMigrations.runFreSkillMigration
local runSkillHierarchyMigration = skillMigrations.runSkillHierarchyMigration

local function onExtensionLoaded()
  if not overhaul_career_career.isActive() then return false end
  if not attributes then
    init()
  end

  -- load from saveslot
  local saveSlot, savePath = overhaul_career_saveSystem.getCurrentProfile()
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


  local hierarchyMigrationMarker = runSkillHierarchyMigration(savePath, jsonData)
  if hierarchyMigrationMarker then
    pendingMigrationMarkers[#pendingMigrationMarkers + 1] = hierarchyMigrationMarker
    migrationDataChanged = migrationDataChanged or hierarchyMigrationMarker.saveData
  end

  if savePath and #pendingMigrationMarkers > 0 then
    local attributeWriteSucceeded = true
    if migrationDataChanged then
      attributeWriteSucceeded = overhaul_career_saveSystem.jsonWriteFileSafe(savePath .. "/career/playerAttributes.json", jsonData, true) == true
    end
    if attributeWriteSucceeded then
      for _, marker in ipairs(pendingMigrationMarkers) do
        overhaul_career_saveSystem.jsonWriteFileSafe(marker.path, marker.data, true)
      end
    else
      log("E", "career.playerAttributes", "Skill migration data could not be saved; migration markers were not written so the migration can retry.")
    end
  end

  local attributeLogData = (savePath and jsonReadFile(savePath .. "/career/attributeLog.json")) or {}
  if type(attributeLogData) ~= "table" then attributeLogData = {} end
  attributeLog = {}
  if not tableIsEmpty(attributeLogData) then
    attributeLog = attributeLogData
  end
  
  local moneySum, loggedGains, loggedLosses = 0, 0, 0
  local ledgerValid = type(attributeLogData) == "table" and #attributeLogData > 0
  for _, change in ipairs(attributeLog) do
    if type(change) ~= "table" then ledgerValid = false
    elseif type(change.attributeChange) == "table" and change.attributeChange.money then
      local amount = change.attributeChange.money
      if type(amount) ~= "number" or amount ~= amount or math.abs(amount) == math.huge then
        ledgerValid = false
      else
        moneySum = moneySum + amount
        loggedGains = loggedGains + math.max(amount, 0)
        loggedLosses = loggedLosses + math.min(amount, 0)
      end
    end
  end
  log("D", "career.playerAttributes", "moneySum: " .. tostring(moneySum))

  if not tableIsEmpty(jsonData) then
    for name, data in pairs(jsonData) do
      attributes[name] = attributes[name] or deepcopy(baseAttribute)
      for k,v in pairs(data) do
        attributes[name][k] = v
      end
      if name == "money" then
        local gains = 0
        if type(data.gains) == "table" and data.gains.all then
          gains = data.gains.all
        end
        local losses = 0
        if type(data.losses) == "table" and data.losses.all then
          losses = -data.losses.all
        end
        local completeLedger = ledgerValid and type(data.gains) == "table" and type(data.losses) == "table"
          and type(data.gains.all) == "number" and type(data.losses.all) == "number"
          and math.abs(loggedGains - data.gains.all) < 0.01
          and math.abs(loggedLosses - data.losses.all) < 0.01
        if completeLedger then
          attributes[name].value = math.min(data.value, gains - losses, moneySum)
        end
        
        if overhaul_career_economy_cheats.isCheatsMode() then
          attributes[name].value = 1e12
        end

      end
    end
  end
end

-- this should only be loaded when the career is active
local function onOverhaulSaveCurrentProfile(currentSavePath)
  overhaul_career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/playerAttributes.json", attributes, true)
  overhaul_career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/attributeLog.json", attributeLog, true)
end


local function onOverhaulActive(active)
  if not active then return end
  for orgId, organization in pairs(overhaul_world_organizations.getOrganizations()) do
    if not attributes[orgId .. "Reputation"] then
      local attribute = deepcopy(baseAttribute)
      attribute.min = overhaul_career_progression_reputation.getMinimumValue(organization)
      attribute.max = overhaul_career_progression_reputation.getMaximumValue(organization)
      attributes[orgId .. "Reputation"] = attribute
    else
      attributes[orgId .. "Reputation"].min = overhaul_career_progression_reputation.getMinimumValue(organization)
      attributes[orgId .. "Reputation"].max = overhaul_career_progression_reputation.getMaximumValue(organization)
    end
  end
end

local function onOverhaulCheatsModeChanged(enabled)
  if enabled and attributes and attributes.money then
    attributes.money.value = 1e12
    ledgerAuthority.rebase(walletAccount)
  end
end

-- logbook integration
local function onOverhaulLogbookGetEntries(_)
end

M.addAttributes = addAttributes
M.setAttributes = setAttributes
M.getAttribute = getAttribute
M.getAttributeValue = getAttributeValue
M.getPauseCardSummary = function()
  return {kind = 'value', label = 'Balance', format = 'money', value = getAttributeValue('money')}
end
M.canonicalAttributeKey = canonicalAttributeKey
M.getAllAttributes = getAllAttributes
M.getRewardDisplayName = getRewardDisplayName
M.getRecentFinancialChanges = getRecentFinancialChanges
M.getFinancialHistory = getFinancialHistory
M.getFinancialHistoryView = getFinancialHistoryView
M.getGameplayHistory = getGameplayHistory
M.getCareerHistoryInfo = getCareerHistoryInfo
M.getAttributeLog = function() return attributeLog end

M.logAttributeChange = logAttributeChange
M.onOverhaulLogbookGetEntries = onOverhaulLogbookGetEntries
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
-- The loaded wallet (save, new career, cheats, migrations) opens the Ledger checkpoint.
M.onExtensionLoaded = function()
  local result = onExtensionLoaded()
  ledgerAuthority.rebase(walletAccount)
  return result
end
M.onOverhaulActive = onOverhaulActive
M.onOverhaulCheatsModeChanged = onOverhaulCheatsModeChanged

return M
