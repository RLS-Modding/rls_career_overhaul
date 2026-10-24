-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Save-slot lookups and writes for the profile screen: newest save per profile, save state, employment-mode preflight and the slot setters that apply a change to a running career.
-- Reading order: lookups, then writes, then the per-career setters (M.new(ctx)), then the public API.

local M = {}

-- Newest save folder for a profile, plus its save date.
local function getNewestSaveForProfile(profile)
  if type(profile) ~= "string" or profile == "" then return nil end
  local savePath = overhaul_career_saveSystem.getNewestSave(overhaul_career_saveSystem.getSaveRootDirectory() .. profile)
  if not savePath or savePath == "" then return nil end
  local info = jsonReadFile(savePath .. "/info.json")
  return savePath, info and info.date or nil
end

-- "new", "existing", or "unreadable" (save data on disk without a readable info.json).
local function getProfileSaveState(name, specificAutosave)
  local slotPath = overhaul_career_saveSystem.getSaveRootDirectory() .. name
  if specificAutosave then
    if FS:fileExists(slotPath .. "/" .. specificAutosave .. "/info.json") then return "existing" end
    return "unreadable"
  end
  if tableSize(overhaul_career_saveSystem.getAllSaveFolders(name)) > 0 then return "existing" end
  if FS:directoryExists(slotPath) then
    for _, entry in ipairs(FS:directoryList(slotPath, false, true) or {}) do
      if FS:directoryExists(entry .. "/career") then return "unreadable" end
    end
  end
  return "new"
end

local function refuseUnreadableSave(name, specificAutosave)
  log("E", "", string.format("Refusing to load %s/%s: save has no readable info.json", tostring(name), tostring(specificAutosave)))
  guihooks.trigger('toastrMsg', {type='error', title='Save could not be loaded', msg='This save is missing its info file. It was left untouched.'})
end

local function isKnownCareerProfile(profileName)
  if type(profileName) ~= "string" or profileName == "" then
    return false
  end
  for _, name in ipairs(overhaul_career_saveSystem.getAllProfiles()) do
    if name == profileName then
      return true
    end
  end
  return false
end

local function getAutosavesForProfile(profile)
  local res = {}
  for _, saveData in ipairs(overhaul_career_saveSystem.getAllSaveFolders(profile)) do
    local data = jsonReadFile(overhaul_career_saveSystem.getSaveRootDirectory() .. profile .. "/" .. saveData.name .. "/career/playerAttributes.json")
    if data then
      data.id = profile
      data.autosaveName = saveData.name
      table.insert(res, data)
    end
  end
  return res
end

-- Save folders (autosaves) for a profile with what the UI needs to show them and let the player pick one.
local function getSaveFoldersForProfile(profile)
  local res = {}
  if not profile then return res end
  local saveRootDir = overhaul_career_saveSystem.getSaveRootDirectory()
  local curProfile, curSavePath = overhaul_career_saveSystem.getCurrentProfile()
  local curFolderName = curSavePath and string.match(curSavePath, "([^/\\]+)$") or nil
  for _, saveData in ipairs(overhaul_career_saveSystem.getAllSaveFolders(profile)) do
    local folderPath = saveRootDir .. profile .. "/" .. saveData.name
    local entry = {
      id = profile,
      name = saveData.name,
      date = saveData.date,
      creationDate = saveData.creationDate,
      displayName = saveData.displayName or profile,
      corrupted = saveData.corrupted and true or false,
      version = saveData.version,
      isCurrent = (curProfile == profile and curFolderName == saveData.name) or false,
    }
    if saveData.version then
      entry.incompatibleVersion = overhaul_career_saveSystem.getBackwardsCompVersion() > saveData.version
      entry.outdatedVersion = overhaul_career_saveSystem.getSaveSystemVersion() > saveData.version
        or overhaul_career_saveMigration.requiresSaveMigration(folderPath, saveData) or false
      entry.requiresMigration = entry.outdatedVersion
    end

    local attData = jsonReadFile(folderPath .. "/career/playerAttributes.json")
    if attData then
      entry.money = attData.money or {value = 0}
      entry.beamXP = attData.beamXP or {value = 0}
    end

    local vehicleFiles = FS:findFiles(folderPath .. "/career/vehicles/", '*.json', 0, false, false)
    entry.vehicleCount = #vehicleFiles

    table.insert(res, entry)
  end

  -- newest first
  table.sort(res, function(a, b) return (a.date or "0") > (b.date or "0") end)
  return res
end

-- Reads the save file directly, so the profile screen never needs logisticsEmploymentMode loaded.
local function getEmploymentModePreflight(profile, specificSaveFolder)
  if type(profile) ~= "string" or profile == "" then
    return {needsChoice = false, profile = profile, saveFolder = specificSaveFolder}
  end
  local savePath = nil
  local folder = specificSaveFolder
  if folder and folder ~= "" then
    savePath = overhaul_career_saveSystem.getSaveRootDirectory() .. profile .. "/" .. folder
    if not FS:fileExists(savePath .. "/info.json") then
      savePath = nil
      folder = nil
    end
  end
  if not savePath then
    savePath = getNewestSaveForProfile(profile)
    if savePath then
      folder = string.match(savePath, "([^/\\]+)$")
    end
  end
  if not savePath then
    return {needsChoice = false, profile = profile, saveFolder = specificSaveFolder}
  end
  local existing = jsonReadFile(savePath .. "/career/rls_career/logisticsEmploymentMode.json")
  local needsChoice = not (type(existing) == "table" and existing.apprenticeship ~= nil)
  return {
    needsChoice = needsChoice,
    profile = profile,
    saveFolder = folder or specificSaveFolder,
    apprenticeship = (type(existing) == "table" and existing.apprenticeship == true) or nil,
  }
end

-- The rls_career folder inside a save, created when missing. Returns its path.
local function ensureRlsCareerDirectory(savePath)
  local dirPath = savePath .. "/career/rls_career"
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
  return dirPath
end

-- The newest save folder of a known profile, or nil when there is nothing to write to.
local function newestSaveForKnownProfile(slotName)
  if not isKnownCareerProfile(slotName) then
    return nil
  end
  local autosavePath = getNewestSaveForProfile(slotName)
  if not autosavePath or autosavePath == "" then
    return nil
  end
  return autosavePath
end

-- Writes {enabled} to a slot's rls_career file. Returns the save path and the data, or nil on failure.
local function writeEnabledToSaveSlot(slotName, fileName, enabled)
  local autosavePath = newestSaveForKnownProfile(slotName)
  if not autosavePath then return nil end
  local filePath = ensureRlsCareerDirectory(autosavePath) .. "/" .. fileName
  local data = {enabled = enabled == true}
  if not overhaul_career_saveSystem.jsonWriteFileSafe(filePath, data, true) then return nil end
  return autosavePath, data
end

-- One-time write for existing saves missing logisticsEmploymentMode.json.
-- Returns false if already chosen (immutable) or the write fails.
local function setEmploymentApprenticeshipForSaveSlot(slotName)
  local autosavePath = newestSaveForKnownProfile(slotName)
  if not autosavePath then return false end
  local filePath = ensureRlsCareerDirectory(autosavePath) .. "/logisticsEmploymentMode.json"
  local existing = jsonReadFile(filePath)
  if type(existing) == "table" and existing.apprenticeship ~= nil then
    return false
  end
  if overhaul_career_career.isActive() then
    return overhaul_career_work_logisticsEmploymentMode.writeApprenticeshipToSave(autosavePath, true, "profileCard")
  end
  local data = {
    apprenticeship = true,
    chosenAt = os.time(),
    source = "profileCard",
  }
  return overhaul_career_saveSystem.jsonWriteFileSafe(filePath, data, true) == true
end

-- Saves the maintenance choice; the running career follows it at once only for this same save.
local function setMaintenanceModeForSaveSlot(career, slotName, enabled)
  local autosavePath, data = writeEnabledToSaveSlot(slotName, "maintenanceMode.json", enabled)
  if not autosavePath then return false end
  local currentProfile, currentPath = overhaul_career_saveSystem.getCurrentProfile()
  if career.isActive() and currentProfile == slotName and currentPath == autosavePath then
    overhaul_career_maintenance_maintenanceMode.setEnabled(data.enabled)
  end
  return true
end

-- Saves the police choice for the next load and never applies it mid-session.
local function setPoliceEnabledForSaveSlot(career, slotName, enabled)
  local autosavePath, data = writeEnabledToSaveSlot(slotName, "policePreference.json", enabled)
  if not autosavePath then return false end
  local currentProfile, currentPath = overhaul_career_saveSystem.getCurrentProfile()
  if career.isActive() and currentProfile == slotName and currentPath == autosavePath then
    overhaul_career_police_policePreference.setEnabledForNextLoad(data.enabled)
  end
  return true
end

-- One set of slot setters per career module instance; ctx: isActive().
function M.new(ctx)
  local career = ctx
  return {
    setMaintenanceModeForSaveSlot = function(slotName, enabled)
      return setMaintenanceModeForSaveSlot(career, slotName, enabled)
    end,
    setPoliceEnabledForSaveSlot = function(slotName, enabled)
      return setPoliceEnabledForSaveSlot(career, slotName, enabled)
    end,
  }
end

M.getNewestSaveForProfile = getNewestSaveForProfile
M.getProfileSaveState = getProfileSaveState
M.refuseUnreadableSave = refuseUnreadableSave
M.isKnownCareerProfile = isKnownCareerProfile
M.setEmploymentApprenticeshipForSaveSlot = setEmploymentApprenticeshipForSaveSlot
M.getAutosavesForProfile = getAutosavesForProfile
M.getSaveFoldersForProfile = getSaveFoldersForProfile
M.getEmploymentModePreflight = getEmploymentModePreflight

return M
