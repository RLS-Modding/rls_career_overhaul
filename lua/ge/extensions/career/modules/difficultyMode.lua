local M = {}

M.dependencies = {'career_career'}

local SAVE_FILE = "difficultyMode.json"
local LEGACY_HARDCORE_FILE = "hardcore.json"

local DIFFICULTY_MODES = {
  easy = {rewardMultiplier = 3.0, xpMultiplier = 2.0, startingCapital = 25000},
  normal = {rewardMultiplier = 1.0, xpMultiplier = 1.0, startingCapital = 15000},
  hard = {rewardMultiplier = 0.5, xpMultiplier = 0.5, startingCapital = 10000},
  hardcore = {rewardMultiplier = 0.5, xpMultiplier = 0.25, startingCapital = 0},
}

local mode = "normal"
local modeData = {}
local branchAttributeKeys = nil

local function resolveMode(candidate)
  if type(candidate) ~= "string" then return "normal" end
  local normalized = candidate:lower()
  if DIFFICULTY_MODES[normalized] then
    return normalized
  end
  return "normal"
end

local function isChallengeActive()
  if not career_challengeModes or not career_challengeModes.isChallengeActive then
    return false
  end
  return career_challengeModes.isChallengeActive() == true
end

local function getCurrentSavePath()
  local _, savePath = career_saveSystem.getCurrentSaveSlot()
  return savePath
end

local function getSaveFilePath(savePath)
  return savePath .. "/career/rls_career/" .. SAVE_FILE
end

local function getLegacyHardcorePath(savePath)
  return savePath .. "/career/rls_career/" .. LEGACY_HARDCORE_FILE
end

local function getModeConfig(modeName)
  return DIFFICULTY_MODES[resolveMode(modeName)] or DIFFICULTY_MODES.normal
end

local function cacheBranchAttributeKeys()
  if branchAttributeKeys ~= nil then
    return branchAttributeKeys
  end
  branchAttributeKeys = {}
  for _, branch in ipairs(career_branches.getSortedBranches() or {}) do
    if type(branch.attributeKey) == "string" and branch.attributeKey ~= "" then
      branchAttributeKeys[branch.attributeKey] = true
    end
  end
  return branchAttributeKeys
end

local function isProgressionKey(key)
  if type(key) ~= "string" then return false end
  if key == "beamXP" then return true end
  if key:endswith("Reputation") then return true end
  if cacheBranchAttributeKeys()[key] then return true end
  return false
end

local function saveModeData(currentSavePath)
  local savePath = currentSavePath or getCurrentSavePath()
  if not savePath then return end

  local dirPath = savePath .. "/career/rls_career"
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end

  modeData.mode = resolveMode(modeData.mode or mode)
  modeData.lastModified = os.time()
  career_saveSystem.jsonWriteFileSafe(getSaveFilePath(savePath), modeData, true)
end

local function loadModeData()
  modeData = {mode = "normal"}
  if not career_career or not career_career.isActive() then
    mode = "normal"
    return
  end

  local savePath = getCurrentSavePath()
  if not savePath then
    mode = resolveMode(career_career.hardcoreMode and "hardcore" or "normal")
    modeData.mode = mode
    return
  end

  local saveData = jsonReadFile(getSaveFilePath(savePath))
  if type(saveData) == "table" and next(saveData) then
    modeData = saveData
    modeData.mode = resolveMode(modeData.mode)
    mode = modeData.mode
    return
  end

  local legacyData = jsonReadFile(getLegacyHardcorePath(savePath))
  if type(legacyData) == "table" and legacyData.hardcoreMode == true then
    mode = "hardcore"
  elseif career_career.hardcoreMode then
    mode = "hardcore"
  else
    mode = "normal"
  end

  modeData.mode = mode
  saveModeData(savePath)
end

local function applyEconomyPreset(modeName, force)
  if not force and not M.isDifficultyActive() then
    return false
  end
  if not career_economyAdjuster or not career_economyAdjuster.getAvailableTypes then
    return false
  end

  local config = getModeConfig(modeName or mode)
  local availableTypes = career_economyAdjuster.getAvailableTypes() or {}
  if #availableTypes == 0 then
    return false
  end

  local multipliers = {}
  for _, typeName in ipairs(availableTypes) do
    multipliers[typeName] = config.rewardMultiplier
  end

  if career_economyAdjuster.setAllTypeMultipliers then
    career_economyAdjuster.setAllTypeMultipliers(multipliers)
    return true
  end
  return false
end

local function setMode(newMode, skipSave)
  local resolvedMode = resolveMode(newMode)
  mode = resolvedMode
  modeData.mode = resolvedMode
  if career_career then
    career_career.hardcoreMode = resolvedMode == "hardcore"
  end
  if not skipSave then
    saveModeData()
  end

  extensions.hook("onHardcoreModeChanged", resolvedMode == "hardcore")
  applyEconomyPreset(resolvedMode)
  return resolvedMode
end

local function scaleNumeric(value, multiplier)
  if type(value) ~= "number" then return value end
  if value <= 0 then return value end
  return value * multiplier
end

local function scaleFlatRewards(rewardTable, options)
  local opts = options or {}
  local includeMoney = opts.includeMoney == true
  if not M.isDifficultyActive() then
    return rewardTable
  end

  local rewardMultiplier = M.getRewardMultiplier()
  local xpMultiplier = M.getXPMultiplier()
  for key, amount in pairs(rewardTable or {}) do
    if type(amount) == "number" and amount > 0 then
      if key == "money" and includeMoney then
        rewardTable[key] = scaleNumeric(amount, rewardMultiplier)
      elseif isProgressionKey(key) then
        rewardTable[key] = scaleNumeric(amount, xpMultiplier)
      end
    end
  end
  return rewardTable
end

local function scalePaymentRewardData(rewardData, options)
  local opts = options or {}
  local includeMoney = opts.includeMoney == true
  if not M.isDifficultyActive() then
    return rewardData
  end

  local rewardMultiplier = M.getRewardMultiplier()
  local xpMultiplier = M.getXPMultiplier()
  for key, info in pairs(rewardData or {}) do
    if type(info) == "table" and type(info.amount) == "number" and info.amount > 0 then
      if key == "money" and includeMoney then
        info.amount = scaleNumeric(info.amount, rewardMultiplier)
      elseif isProgressionKey(key) then
        info.amount = scaleNumeric(info.amount, xpMultiplier)
      end
    end
  end
  return rewardData
end

local function onCareerActivated()
  loadModeData()
  branchAttributeKeys = nil
  if career_career then
    career_career.hardcoreMode = M.isHardcoreMode()
  end
  extensions.hook("onHardcoreModeChanged", M.isHardcoreMode())
  applyEconomyPreset(mode)
end

local function onCareerActive(active)
  if not active then
    return
  end
  loadModeData()
  branchAttributeKeys = nil
  if career_career then
    career_career.hardcoreMode = M.isHardcoreMode()
  end
  extensions.hook("onHardcoreModeChanged", M.isHardcoreMode())
  applyEconomyPreset(mode)
end

local function onChallengeModeStateChanged(isActive)
  if isActive then
    return true
  end
  return applyEconomyPreset(mode, true)
end

M.getModes = function() return deepcopy(DIFFICULTY_MODES) end
M.getMode = function() return mode end
M.setMode = setMode
M.getRewardMultiplier = function() return getModeConfig(mode).rewardMultiplier end
M.getXPMultiplier = function() return getModeConfig(mode).xpMultiplier end
M.getEconomyMultiplier = function() return M.getRewardMultiplier() end
M.getStartingCapital = function()
  return getModeConfig(mode).startingCapital
end
M.isHardcoreMode = function() return mode == "hardcore" end
M.isDifficultyActive = function()
  if not career_career or not career_career.isActive() then
    return false
  end
  return not isChallengeActive()
end
M.applyEconomyPreset = applyEconomyPreset
M.scaleFlatRewards = scaleFlatRewards
M.scalePaymentRewardData = scalePaymentRewardData
M.onChallengeModeStateChanged = onChallengeModeStateChanged
M.onCareerActivated = onCareerActivated
M.onCareerActive = onCareerActive
M.onSaveCurrentSaveSlot = saveModeData

return M
