-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Reward normalization, logistics bonuses, branch animation and popup sanitizing.
-- Read mergeDefaults, normalizeRewardKey, normalizeRewardTable, getLogisticsMoneyBonusState, applyLogisticsMoneyBonusToEntry in order.

-- Part of the Overhaul fork of stock lua/ge/extensions/career/modules/delivery/progress.lua.

local rewards = {}

-- Factory -------------------------------------------------------------------------------------

-- Each progress owner captures its rule providers and owns its helpers and mutable popup tables.
function rewards.new(inputs)
  local deliveryText = require("overhaul/lib/logistics/resultTranslations")
  local _tr = deliveryText.text
  local core_locales = {contextTranslate = deliveryText.context}
  local skillLookup = require("overhaul/lib/progression/skillLookup")
  local xpConfig = inputs.xpConfig
  local balance = inputs.balance

  -- Config ------------------------------------------------------------------------------------------

  -- Keep delivery reward keys aligned with the unified logistics skill track.
  local rewardKeyAliases = {
    ["logistics"] = "logistics-delivery",
    ["delivery"] = "logistics-delivery",
    ["vehicleDelivery"] = "logistics-delivery",
    ["materials"] = "logistics-delivery",
    ["logistics-vehicleDelivery"] = "logistics-delivery",
    ["logistics-materials"] = "logistics-delivery"
  }

  -- Multiplier metadata living on rewards tables must not be summed as payout attributes.
  local rewardMetaKeys = {
    economyMultiplier = true,
    moneyMultiplier = true,
    economyBaseMoney = true,
  }

  local api = {}

  function api.mergeDefaults(defaults, saved)
    if type(defaults) ~= "table" then
      if saved == nil then return deepcopy(defaults) end
      return saved
    end
    local result = {}
    for k, v in pairs(defaults) do
      result[k] = api.mergeDefaults(v, saved and saved[k])
    end
    if type(saved) == "table" then
      for k, v in pairs(saved) do
        if result[k] == nil then result[k] = v end
      end
    end
    return result
  end

  local function normalizeRewardKey(key)
    return rewardKeyAliases[key] or key
  end

  function api.normalizeRewardTable(rewardTable, breakdown, additiveAliases)
    local normalized = {}
    local aliased = {}
    for key, amount in pairs(rewardTable or {}) do
      if not rewardMetaKeys[key] and type(amount) == "number" then
        local normalizedKey = normalizeRewardKey(key)
        if key ~= normalizedKey then
          aliased[normalizedKey] = (aliased[normalizedKey] or 0) + amount
        else
          normalized[normalizedKey] = (normalized[normalizedKey] or 0) + amount
        end
      end
    end
    -- Canonical keys win when a legacy table stamped both the alias and its target.
    for key, amount in pairs(aliased) do
      if additiveAliases or normalized[key] == nil then
        normalized[key] = (normalized[key] or 0) + amount
      end
    end
    -- Precision deltas are additive; legacy base aliases stay duplicates.
    for _, bd in ipairs(breakdown or {}) do
      if bd.precisionData then
        for key, amount in pairs(bd.rewards or {}) do
          local canonical = normalizeRewardKey(key)
          if key ~= canonical and type(amount) == "number" and rewardTable and rewardTable[key] ~= nil and rewardTable[canonical] ~= nil then
            normalized[canonical] = (normalized[canonical] or 0) + amount
          end
        end
      end
    end
    return normalized
  end

  -- Logistics money bonus -----------------------------------------------------------------------

  function api.getLogisticsMoneyBonusState()
    local level = xpConfig.getLogisticsLevel()
    return balance.getLevelBonus(level), level
  end

  function api.applyLogisticsMoneyBonusToEntry(entry, multiplier)
    if type(entry) ~= "table" or multiplier <= 0 then
      return 0
    end

    entry.adjustedRewards = api.normalizeRewardTable(entry.adjustedRewards, entry.breakdown)
    local baseMoney = entry.adjustedRewards.money or 0
    if baseMoney <= 0 then
      return 0
    end

    local roundingMode = xpConfig.getConfig().rounding.moneyFinal
    local bonusAmount = xpConfig.applyRounding(baseMoney * multiplier, roundingMode)
    if bonusAmount <= 0 then
      return 0
    end

    entry.adjustedRewards.money = baseMoney + bonusAmount
    entry.breakdown = entry.breakdown or {}
    table.insert(entry.breakdown, {
      label = string.format("Logistics Level Bonus (+%g%%)", multiplier * 100),
      rewards = {money = bonusAmount},
      simpleBreakdownType = "branch"
    })

    return bonusAmount
  end

  -- Branch animation ----------------------------------------------------------------------------

  function api.getBranchForAttributeKey(attributeKey)
    return skillLookup.findBranchForAttributeKey(attributeKey, {logisticsDelivery = true})
  end

  function api.sanitizeBranchLevels(levels)
    return skillLookup.sanitizeLevels(levels, function(i)
      return core_locales.contextTranslate("ui.career.delivery.progress.level", {level = i})
    end)
  end

  local function calcBranchLevelSafe(value, branchRef)
    if type(branchRef) ~= "string" or branchRef == "" then return nil end
    local level, _, _, min, max = skillLookup.levelFromValue(value, branchRef)
    if type(level) ~= "number" then return nil end
    return level, min, max
  end

  -- The attribute key and the branch id can each name the level; the higher one wins.
  local function branchLevelAndRange(attributeKey, branch, currentValue)
    local levelByKey, minByKey, maxByKey = calcBranchLevelSafe(currentValue, attributeKey)
    local levelById, minById, maxById = calcBranchLevelSafe(currentValue, branch.id)

    local level = levelByKey or levelById or 0
    local min = minByKey or minById or 0
    local max = maxByKey or maxById or 0
    if levelByKey and levelById then
      level = math.max(levelByKey, levelById)
      if level == levelByKey then
        min = minByKey or min
        max = maxByKey or max
      else
        min = minById or min
        max = maxById or max
      end
    end
    return level, min, max
  end

  local function branchLevelLabel(attributeKey, branch, level)
    local levelLabel = overhaul_career_progression_skills.getLevelLabel(attributeKey, level)
    if type(levelLabel) ~= "string" or levelLabel == "" then
      levelLabel = overhaul_career_progression_skills.getLevelLabel(branch.id, level)
    end
    if type(levelLabel) ~= "string" or levelLabel == "" then
      levelLabel = core_locales.contextTranslate("ui.career.delivery.progress.level", {level = level})
    end
    return levelLabel
  end

  function api.getAnimationDataForBranch(attributeKey, branch, branchLevels)
    local currentValue = skillLookup.attributeValue(attributeKey)
    local level, min, max = branchLevelAndRange(attributeKey, branch, currentValue)
    local levelLabel = branchLevelLabel(attributeKey, branch, level)
    return {
      id = attributeKey,
      name = translateLanguage(branch.name, branch.name),
      level = level,
      levelLabel = levelLabel,
      value = currentValue,
      min = min,
      max = max,
      cover = branch.progressCover,
      glyphIcon = branch.icon,
      color = branch.color,
      accentColor = branch.accentColor,
      isMaxLevel = level >= #branchLevels,
      unlocked = branch.unlocked,
    }
  end

  -- Fresh hidden/suppressed lists keep reward-popup projections independent.
  local function legacyDeliveryKeys()
    return {
      logistics = true,
      delivery = true,
      vehicleDelivery = true,
      materials = true,
      ["logistics-vehicleDelivery"] = true,
      ["logistics-materials"] = true,
    }
  end
  local hiddenDeliveryPopupAttributes = legacyDeliveryKeys()

  -- Prevent level-up popup animations for deprecated delivery keys.
  local suppressedDeliveryLevelPopupAttributes = legacyDeliveryKeys()

  -- Popup sanitizing ----------------------------------------------------------------------------

  local function stripHiddenPopupRewardKeys(rewardTable)
    if type(rewardTable) ~= "table" then return rewardTable end
    for key, _ in pairs(hiddenDeliveryPopupAttributes) do
      rewardTable[key] = nil
    end
    return rewardTable
  end

  -- Employee reputation delta -------------------------------------------------------------------

  -- The reputation key this payout moved: the employer's first, else the first nonzero one.
  local function findReputationGain(payoutSum)
    local emp = overhaul_career_work_employment
    local preferredOrgId = emp and emp.getEmployerOrgId() or nil
    if preferredOrgId then
      local key = preferredOrgId .. "Reputation"
      local amount = tonumber(payoutSum[key]) or 0
      if math.abs(amount) > 0.0001 then return key, amount end
    end
    for key, amount in pairs(payoutSum) do
      if type(key) == "string" and key:endswith("Reputation") then
        local value = tonumber(amount) or 0
        if math.abs(value) > 0.0001 then return key, value end
      end
    end
    return nil, 0
  end

  -- Visible level and label for a reputation value; reputationLevels[1] is usually a sentinel.
  local function reputationLevelFor(levels, value)
    local numeric = tonumber(value) or 0
    local levelIndex = 0
    for i, level in ipairs(levels) do
      local required = tonumber(level and level.requiredValue)
      if required and numeric >= required then
        levelIndex = i - 1
      else
        break
      end
    end
    local visibleLevel = math.max(0, levelIndex - 1)
    local entry = levels[levelIndex + 1]
    local label = entry and (entry.label or entry.levelLabel) or nil
    return visibleLevel, label
  end

  function api.buildEmployeeRepDelta(payoutSum, branchInfo)
    if type(payoutSum) ~= "table" then return nil end
    local repKey, gain = findReputationGain(payoutSum)
    if not repKey then return nil end

    local orgId = repKey:sub(1, -11)
    local info = type(branchInfo) == "table" and branchInfo[repKey] or nil
    local after = info and info.animationData and tonumber(info.animationData.value) or nil
    local organization = overhaul_world_organizations.getOrganization(orgId)
    if after == nil and organization and organization.reputation then
      after = tonumber(organization.reputation.value) or 0
    end
    after = tonumber(after) or 0
    local before = after - gain
    local levels = organization and organization.reputationLevels or (info and info.branchLevels) or {}

    local beforeLevel, beforeLabel = reputationLevelFor(levels, before)
    local afterLevel, afterLabel = reputationLevelFor(levels, after)
    return {
      orgId = orgId,
      before = before,
      after = after,
      gain = gain,
      beforeLevel = beforeLevel,
      afterLevel = afterLevel,
      beforeLabel = beforeLabel,
      afterLabel = afterLabel,
    }
  end

  local function sanitizePopupBreakdown(breakdown)
    if type(breakdown) ~= "table" then return end
    for _, bd in ipairs(breakdown) do
      if type(bd) == "table" and type(bd.rewards) == "table" then
        if bd.precisionData then bd.rewards = api.normalizeRewardTable(bd.rewards, {bd}) end
        stripHiddenPopupRewardKeys(bd.rewards)
      end
    end
  end

  function api.sanitizePopupRewardContainer(entry)
    if type(entry) ~= "table" then return end
    if type(entry.rewards) == "table" then stripHiddenPopupRewardKeys(entry.rewards) end
    if type(entry.originalRewards) == "table" then stripHiddenPopupRewardKeys(entry.originalRewards) end
    if type(entry.adjustedRewards) == "table" then stripHiddenPopupRewardKeys(entry.adjustedRewards) end
    sanitizePopupBreakdown(entry.breakdown)
  end

  api.hiddenDeliveryPopupAttributes = hiddenDeliveryPopupAttributes
  api.suppressedDeliveryLevelPopupAttributes = suppressedDeliveryLevelPopupAttributes
  return api
end

return rewards
