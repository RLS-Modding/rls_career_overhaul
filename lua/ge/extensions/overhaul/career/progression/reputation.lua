-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/reputation.lua (BeamNG 0.40).
-- Reputation per organization: events, levels and labels, with the Overhaul value rules plugged in.
-- Keeps the stock layout on purpose so it still diffs against stock.

local recordTier = require("overhaul/lib/progression/logbookFeed").register("overhaul.reputationTierChanged", {
  title = "Reputation tier changed", label = "Organizations", icon = "peopleOutline"
}, "career/progression/reputation.lua")

local M = {}

-- RLS rules replace stock's value range, event values and level defaults here.
-- Their state is created with this extension, so a reload starts with fresh organization values and normal mode.
local MINIMUM_VALUE = -1000
local MAXIMUM_VALUE = 350000

-- Level thresholds and delivery bonuses. Loaner cuts live in LOANER_CUT because they depend on hardcore mode.
local LEVEL_DEFAULTS = {
  [-1] = {label = "ui.career.organizations.reputation.questionable", requiredValue = MINIMUM_VALUE, deliveryBonus = 0.9},
  [0] = {label = "ui.career.organizations.reputation.neutral", requiredValue = 0, deliveryBonus = 1},
  [1] = {label = "ui.career.organizations.reputation.reliable", requiredValue = 3900, deliveryBonus = 1.1},
  [2] = {label = "ui.career.organizations.reputation.preferred", requiredValue = 11600, deliveryBonus = 1.2},
  [3] = {label = "ui.career.organizations.reputation.partner", requiredValue = 44600, deliveryBonus = 1.4},
}

-- Loaner cut and company share per level, as {normal, hardcore}.
local LOANER_CUT = { [-1] = {0.5, 0.95}, [0] = {0.35, 0.8}, [1] = {0.25, 0.7}, [2] = {0.15, 0.6}, [3] = {0, 0.5} }
local COMPANY_SHARE = { [-1] = {0.5, 0.8}, [0] = {0.4, 0.7}, [1] = {0.3, 0.6}, [2] = {0.2, 0.5}, [3] = {0.1, 0.4} }

-- Picks the normal or hardcore entry of a {normal, hardcore} pair.
local function pickMode(pair, isHardcore)
  if isHardcore then return pair[2] end
  return pair[1]
end

-- Levels outside the table use the top level's value.
local function loanerCutForLevel(level, isHardcore)
  return pickMode(LOANER_CUT[level] or LOANER_CUT[3], isHardcore)
end

local function companyShareForLevel(level, isHardcore)
  return pickMode(COMPANY_SHARE[level] or COMPANY_SHARE[3], isHardcore)
end

-- Fresh level tables for one instance. The loaner cut starts at its normal value until updateLevelDefaults runs.
local function buildLevelDefaults()
  local levels = {}
  for level, fields in pairs(LEVEL_DEFAULTS) do
    levels[level] = {
      label = fields.label,
      levelLabel = {txt = "ui.career.organizations.reputation.levelLabel", context = {level = level}},
      requiredValue = fields.requiredValue,
      loanerCut = {value = LOANER_CUT[level][1], icon = "boxPickUp03"},
      deliveryBonus = {value = fields.deliveryBonus},
    }
  end
  return levels
end

local function installLevelApi(rules, state)
  function rules.getCompanyShareValue(level)
    return companyShareForLevel(level, state.isHardcore)
  end

  function rules.updateLevelDefaults()
    for level, lvl in pairs(rules.levelDefaults) do
      lvl.loanerCut.value = loanerCutForLevel(level, state.isHardcore)
    end
  end

  function rules.setHardcore(hardcoreMode)
    state.isHardcore = hardcoreMode
    rules.updateLevelDefaults()
  end
end

local function installOrganizationApi(rules, state)
  -- Per-organization event value, nil when the organization has none.
  function rules.getOrgValueForEvent(eventId, orgId)
    local orgValues = orgId and state.organizationValues[orgId]
    if orgValues and orgValues[eventId] ~= nil then
      return orgValues[eventId]
    end
  end

  -- The vehicle shop caches offers per reputation level, so a level change must clear that cache.
  function rules.noteLevel(organization, level)
    local previousLevel = organization.reputation and organization.reputation.level
    if previousLevel ~= nil and previousLevel ~= level then
      log("I", "Reputation", string.format("Organization %s reputation level changed from %d to %d, invalidating vehicle cache", organization.id, previousLevel, level))
      if overhaul_career_market_vehicleShopping then
        overhaul_career_market_vehicleShopping.invalidateVehicleCache()
      end
    end
  end

  function rules.rememberOrgValues(organization)
    if organization.reputationValues and organization.id then
      state.organizationValues[organization.id] = organization.reputationValues
    end
  end

  -- Fills one default into a level attribute. Loaner cut: hardcore uses the organization's hardcoreValue (or the default), normal mode keeps the value it has. Other keys only fill gaps.
  function rules.mergeDefault(attributes, attributeKey, key, value)
    if attributeKey ~= "loanerCut" then
      if attributes[key] == nil then
        attributes[key] = value
      end
      return
    end
    if key ~= "value" then return end
    if not state.isHardcore then
      attributes[key] = attributes[key] or value
    elseif attributes["hardcoreValue"] then
      attributes[key] = attributes["hardcoreValue"]
    else
      attributes[key] = value
    end
  end

  -- Organization ranges are optional; nil means the stock range applies.
  function rules.orgMinimum(organization)
    local levels = organization and organization.reputationLevels
    local first = type(levels) == "table" and levels[1] or nil
    if type(first) == "table" and first.min ~= nil then
      return first.min
    end
  end

  function rules.orgMaximum(organization)
    local levels = organization and organization.reputationLevels
    local last = type(levels) == "table" and levels[#levels] or nil
    if type(last) == "table" and last.max ~= nil then
      return last.max
    end
  end
end

local function createReputationRules()
  local rules = {
    minimumValue = MINIMUM_VALUE,
    maximumValue = MAXIMUM_VALUE,
    reputationValues = { returnLoanerDamaged = -300, discardDeliveryVehicle = -200 },
    levelDefaults = buildLevelDefaults(),
  }
  local state = { isHardcore = false, organizationValues = {} }
  installLevelApi(rules, state)
  installOrganizationApi(rules, state)
  return rules
end

local rules = createReputationRules()
local minimumValue, maximumValue = rules.minimumValue, rules.maximumValue -- RLS
local reputationValues, levelDefaults = rules.reputationValues, rules.levelDefaults -- RLS

local function getValueForEvent(eventId, orgId) -- RLS: orgId
  local orgValue = rules.getOrgValueForEvent(eventId, orgId) -- RLS: per-organization values
  if orgValue ~= nil then return orgValue end -- RLS
  return reputationValues[eventId]
end

local function calcLevelFromReputationValue(val, organization)
  local level = -1

  local levels = organization.reputationLevels or {}
  for i, lvl in ipairs(levels) do
    if not lvl.requiredValue or val >= lvl.requiredValue then
      level = i
    end
  end
  if level == -1 then -- RLS: below every threshold counts as the first level
    level = 1
  end
  local currentLevelRequiredValue = (levels[level] and levels[level].requiredValue) or minimumValue -- RLS
  local nextLevelRequiredValue = levels[level+1] and levels[level+1].requiredValue or maximumValue

  local prevThreshold = currentLevelRequiredValue
  local neededForNext = nextLevelRequiredValue - currentLevelRequiredValue
  local curLvlProgress = val - currentLevelRequiredValue
  local nextThreshold = nextLevelRequiredValue
  return level - 2, curLvlProgress, neededForNext, prevThreshold, nextThreshold
end

local function addReputationToOrg(organization)
  if not organization then
    return
  end

  local value = overhaul_career_economy_playerAttributes.getAttributeValue(organization.id .. "Reputation")
  local level, curLvlProgress, neededForNext, prevThreshold, nextThreshold = calcLevelFromReputationValue(value, organization)
  rules.noteLevel(organization, level) -- RLS: a level change refreshes the vehicle shop

  local data = {
    value = value,
    level = level,
    curLvlProgress = curLvlProgress,
    neededForNext = neededForNext,
    prevThreshold = prevThreshold,
    nextThreshold = nextThreshold
  }

  rules.rememberOrgValues(organization) -- RLS
  rules.updateLevelDefaults() -- RLS

  for i, levelInfo in ipairs(organization.reputationLevels or {}) do -- RLS: or {}
    for attributeKey, attributeValue in pairs(levelDefaults[i-2] or levelDefaults[3]) do -- RLS: levels past 3 use 3's
      if levelInfo[attributeKey] then
        if type(levelInfo[attributeKey]) == "table" then
          for key, value in pairs(attributeValue) do
            rules.mergeDefault(levelInfo[attributeKey], attributeKey, key, value) -- RLS: hardcore loaner cut
          end
        end
      else
        levelInfo[attributeKey] = attributeValue
      end
    end
    if levelInfo.label then
      levelInfo.label = core_locales.translateWithOrWithoutContext(levelInfo.label)
    end
    if levelInfo.levelLabel then
      levelInfo.levelLabel = core_locales.translateWithOrWithoutContext(levelInfo.levelLabel)
    end
  end
  organization.reputation = data
end

local function getLabel(lvl)
  rules.updateLevelDefaults() -- RLS
  local defaults = levelDefaults[lvl] or levelDefaults[3] or levelDefaults[0] or levelDefaults[-1] -- RLS
  if not defaults or not defaults.label then return "" end
  return core_locales.translateWithOrWithoutContext(defaults.label)
end

local function getMinimumValue(organization) -- RLS: optional per-organization minimum
  local orgMinimum = rules.orgMinimum(organization) -- RLS
  if orgMinimum ~= nil then return orgMinimum end -- RLS
  return minimumValue
end

local function getMaximumValue(organization) -- RLS: optional per-organization maximum
  local orgMaximum = rules.orgMaximum(organization) -- RLS
  if orgMaximum ~= nil then return orgMaximum end -- RLS
  return maximumValue
end

-- Only committed attribute mutations create journal entries. UI reads and profile/map
-- reconciliation may refresh a cached tier, but must never invent a new achievement.
function M.onOverhaulOrganizationReputationChanged(orgId, before, after)
  local organization = overhaul_world_organizations.getOrganization(orgId)
  if not organization then return end
  local previous = calcLevelFromReputationValue(before, organization)
  local current = calcLevelFromReputationValue(after, organization)
  if previous == current then return end
  local tier = (organization.reputationLevels or {})[current + 2]
  recordTier({detail = (organization.name or organization.id) .. " / " .. tostring(previous) .. " to " .. tostring(current)
    .. (tier and tier.label and (" / " .. core_locales.translateWithOrWithoutContext(tier.label)) or "")})
end

M.onOverhaulHardcoreModeChanged = rules.setHardcore -- RLS
M.addReputationToOrg = addReputationToOrg
M.getLabel = getLabel
M.getMinimumValue = getMinimumValue
M.getMaximumValue = getMaximumValue
M.getValueForEvent = getValueForEvent
M.getCompanyShareValue = rules.getCompanyShareValue -- RLS

return M
