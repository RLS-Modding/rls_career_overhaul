-- Employment preference and migration for the current career profile.
-- Retired opt-out preferences become enabled while profile paths and save bytes retain their format.
local M = {}

-- The profile registry owns this file even before the career is active.
require("overhaul/lib/save/store").registerKeys({
  {key = "options.employmentMode", owner = "overhaul_career_work_logisticsEmploymentMode", files = {"career/rls_career/logisticsEmploymentMode.json"}, phase = "profile", required = true},
})

local store = require("overhaul/lib/save/optionsStore").new("logisticsEmploymentMode.json")

local apprenticeship = false
local choiceLocked = false
local saveData = {}

local function nowSim()
  if overhaul_career_logistics_general then
    return overhaul_career_logistics_general.time()
  end
  return os.time()
end

local function readSaveFile(savePath)
  if not savePath then return nil end
  local data = store.read(savePath)
  if type(data) ~= "table" or data.apprenticeship == nil then
    return nil
  end
  return data
end

local function writeSaveFile(savePath, enabled, source, writer)
  if not savePath then return false end
  store.ensureDir(savePath, writer)
  local payload = {
    apprenticeship = enabled == true,
    chosenAt = nowSim(),
    source = source or "profile",
  }
  local ok = store.write(savePath, payload) == true
  if ok then
    saveData = payload
    apprenticeship = payload.apprenticeship
    choiceLocked = true
  end
  return ok
end

local function applyState(data)
  if type(data) ~= "table" or data.apprenticeship == nil then
    apprenticeship = false
    choiceLocked = false
    saveData = {}
    return
  end
  saveData = data
  apprenticeship = data.apprenticeship == true
  choiceLocked = true
end

local function resolveSaveFolderPath(profileName, saveFolderName)
  if not profileName or profileName == "" then return nil, nil end
  local root = overhaul_career_saveSystem.getSaveRootDirectory()
  local slotPath = root .. profileName
  if saveFolderName and saveFolderName ~= "" then
    local savePath = slotPath .. "/" .. saveFolderName
    if FS:fileExists(savePath .. "/info.json") then
      return savePath, saveFolderName
    end
    return nil, nil
  end
  local folders = overhaul_career_saveSystem.getAllSaveFolders(profileName) or {}
  local bestPath, bestFolder, bestDate
  for _, data in ipairs(folders) do
    local folderName = data and data.name
    if folderName and folderName ~= "" then
      local savePath = slotPath .. "/" .. folderName
      local date = tostring(data.date or "0")
      if not bestDate or date > bestDate then
        bestDate = date
        bestPath = savePath
        bestFolder = folderName
      end
    end
  end
  return bestPath, bestFolder
end

local function loadPreferenceData()
  overhaul_career_career.pendingEmploymentApprenticeship = nil
  local savePath = store.currentSavePath()
  if not savePath then
    applyState(nil)
    return
  end

  local loaded = readSaveFile(savePath)
  if loaded and loaded.apprenticeship == true then
    applyState(loaded)
    return
  end

  -- Employment is no longer optional; migrate retired off/unset preferences.
  applyState({apprenticeship = true, chosenAt = nowSim(), source = "employmentAlwaysEnabled"})
  if not writeSaveFile(savePath, true, saveData.source) then
    log("W", "logisticsEmploymentMode", "Could not persist employment migration; will retry on save.")
  end
end

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  if not choiceLocked or not currentSavePath then return end
  writeSaveFile(currentSavePath, apprenticeship, saveData.source or "profile", writer)
end

local function onCareerActivated()
  if not overhaul_career_career.isActive() then return end
  loadPreferenceData()
end

local function onOverhaulActive(active)
  if not active then
    applyState(nil)
    return false
  end
  loadPreferenceData()
end

M.writeApprenticeshipToSave = function(savePath, _enabled, source)
  return writeSaveFile(savePath, true, source)
end

M.getEmploymentModePreflight = function(profileName, saveFolderName)
  local savePath, folder = resolveSaveFolderPath(profileName, saveFolderName)
  if not savePath then
    return {needsChoice = false, profile = profileName, saveFolder = saveFolderName}
  end
  return {
    needsChoice = false,
    profile = profileName,
    saveFolder = folder or saveFolderName,
  }
end

M.isApprenticeshipEnabled = function()
  return choiceLocked and apprenticeship == true
end

M.isLegacyFreelance = function()
  return choiceLocked and apprenticeship ~= true
end

M.hasChosen = function()
  return choiceLocked == true
end

M.getSaveSnapshot = function()
  return {
    apprenticeship = apprenticeship == true,
    chosen = choiceLocked == true,
  }
end

M.onCareerActivated = onCareerActivated
M.onOverhaulActive = onOverhaulActive
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile

return M
