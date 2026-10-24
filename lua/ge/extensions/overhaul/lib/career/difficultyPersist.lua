-- Difficulty-mode save paths and schema, shared by career.lua and the difficulty extension. A plain require
-- module rather than an extension, so career.lua can read it before the difficulty extension loads.
local optionsStore = require("overhaul/lib/save/optionsStore")

local M = {}

M.SAVE_FILE = "difficultyMode.json"
M.LEGACY_HARDCORE_FILE = "hardcore.json"
M.RELATIVE_DIR = optionsStore.RELATIVE_DIR

local modeStore = optionsStore.new(M.SAVE_FILE)
local hardcoreStore = optionsStore.new(M.LEGACY_HARDCORE_FILE)

M.VALID_MODES = {
  easy = true,
  normal = true,
  hard = true,
  hardcore = true,
}

M.getDirPath = optionsStore.dirPath
M.getSaveFilePath = modeStore.path
M.getLegacyHardcorePath = hardcoreStore.path
M.ensureDir = modeStore.ensureDir

-- A known mode name in any case; otherwise hardcore when the legacy flag says so, else normal.
local function resolveMode(candidate, hardcoreFallback)
  if type(candidate) == "string" then
    local normalized = string.lower(candidate)
    if M.VALID_MODES[normalized] then
      return normalized
    end
  end
  if hardcoreFallback then
    return "hardcore"
  end
  return "normal"
end

-- Sync hardcoreMode onto the live career core (career core is a boot service, so it is always there).
local function publishHardcoreFlag(isHardcore)
  overhaul_career_career.hardcoreMode = isHardcore == true
end

-- The mode saved in the difficulty file, else the legacy hardcore file, else nil.
local function readModeFromSave(savePath)
  if not savePath then
    return nil
  end
  local difficultyData = modeStore.read(savePath)
  if type(difficultyData) == "table" and type(difficultyData.mode) == "string" then
    return resolveMode(difficultyData.mode, false)
  end
  local hardcoreData = hardcoreStore.read(savePath)
  if type(hardcoreData) == "table" and hardcoreData.hardcoreMode == true then
    return "hardcore"
  end
  return nil
end

-- Keeps only the positive reward and XP multipliers and the non-negative starting capital.
local function normalizeOverridesForPayload(overrides)
  local normalized = {}
  if type(overrides) ~= "table" then
    return normalized
  end
  if type(overrides.rewardMultiplier) == "number" and overrides.rewardMultiplier > 0 then
    normalized.rewardMultiplier = overrides.rewardMultiplier
  end
  if type(overrides.xpMultiplier) == "number" and overrides.xpMultiplier > 0 then
    normalized.xpMultiplier = overrides.xpMultiplier
  end
  if type(overrides.startingCapital) == "number" and overrides.startingCapital >= 0 then
    normalized.startingCapital = overrides.startingCapital
  end
  return normalized
end

local function writeLegacyHardcoreFlag(savePath, isHardcore)
  hardcoreStore.write(savePath, {
    hardcoreMode = isHardcore == true,
  })
end

local function writeModeToSave(savePath, modeName, overrides)
  if not savePath or not modeName then
    return
  end
  modeStore.ensureDir(savePath)
  local payload = {mode = modeName, lastModified = os.time()}
  for key, value in pairs(normalizeOverridesForPayload(overrides)) do
    payload[key] = value
  end
  modeStore.write(savePath, payload)
  writeLegacyHardcoreFlag(savePath, modeName == "hardcore")
end

-- Writes a full modeData table (runtime save from difficultyMode.lua).
local function writeModeDataTable(savePath, modeData, writer)
  if not savePath or type(modeData) ~= "table" then
    return
  end
  modeStore.ensureDir(savePath, writer)
  modeStore.write(savePath, modeData)
  writeLegacyHardcoreFlag(savePath, modeData.mode == "hardcore")
end

M.resolveMode = resolveMode
M.publishHardcoreFlag = publishHardcoreFlag
M.readModeFromSave = readModeFromSave
M.writeModeToSave = writeModeToSave
M.writeModeDataTable = writeModeDataTable

return M
