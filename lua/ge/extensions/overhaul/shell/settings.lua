-- Overhaul player settings: one JSON file holds every value, and the settings catalog validates each change.
-- Saved paths, validation order and rollback remain owned by this extension.
local M = {}

local optional = require('overhaul/lib/platform/optional')
local schema = require("overhaul/shell/settings/catalog").create()

local settingsRoot = "settings/RLS/"
local settingsFile = "careerOverhaul.json"
local settingsFilePath = settingsRoot .. settingsFile

local settings = schema.defaults
local settingsLoaded = false

local function saveSettings()
  if not FS:directoryExists(settingsRoot) then
    FS:directoryCreate(settingsRoot)
  end
  if jsonWriteFile(settingsFilePath, settings, true) then
    log("I", "rlsSettings", "Settings saved to: " .. settingsFilePath)
    return true
  end
  log("E", "rlsSettings", "Failed to save settings to: " .. settingsFilePath)
  return false
end

-- Runs the setting's onChange callback, if the catalog names one and its owner is loaded.
local function applySettingSideEffects(key)
  local callback = schema.onChange(key)
  if not callback then return end
  local owner = optional(callback.extension)
  if owner and owner[callback.call] then
    pcall(owner[callback.call])
  end
end

-- Copies the saved values the catalog accepts; returns the two retired-setting flags for logging and saving.
local function applySavedValues(data)
  local retiredNoPoliceMode = data.noPoliceMode ~= nil
  local migrateWalkingCameraBob = data.walkingCameraBob ~= nil and data.realisticWalkingCamera == nil
  for key, value in pairs(data) do
    if settings[key] ~= nil and schema.acceptsLoaded(key, value) then
      settings[key] = value
    end
  end
  if migrateWalkingCameraBob and type(data.walkingCameraBob) == "boolean" then
    settings.realisticWalkingCamera = data.walkingCameraBob
  end
  return retiredNoPoliceMode, migrateWalkingCameraBob
end

local function logLegacyMigrations(retiredNoPoliceMode, migrateWalkingCameraBob)
  if retiredNoPoliceMode then
    log("I", "rlsSettings", "Removed retired noPoliceMode setting; police preference is now stored per career save")
  end
  if migrateWalkingCameraBob then
    log("I", "rlsSettings", "Migrated walkingCameraBob to realisticWalkingCamera")
  end
end

local function loadSettings()
  settingsLoaded = true
  local data = jsonReadFile(settingsFilePath)
  if not data then
    log("I", "rlsSettings", "No settings file found, using defaults")
    saveSettings()
    return
  end
  local retiredNoPoliceMode, migrateWalkingCameraBob = applySavedValues(data)
  log("I", "rlsSettings", "Settings loaded from: " .. settingsFilePath)
  logLegacyMigrations(retiredNoPoliceMode, migrateWalkingCameraBob)
  -- Saving writes the retired and migrated keys out of the file.
  if retiredNoPoliceMode or migrateWalkingCameraBob then saveSettings() end
end

-- A failed save puts the previous value back, so memory never disagrees with the file.
local function setSetting(key, value)
  if not schema.acceptsSingle(key, value) then return false end
  if settings[key] == nil then
    log("W", "rlsSettings", "Ignoring unknown or retired setting: " .. tostring(key))
    return false
  end
  if settings[key] == value then return true end

  local previousValue = settings[key]
  settings[key] = value
  if not saveSettings() then
    settings[key] = previousValue
    return false
  end
  log("I", "rlsSettings", "Setting " .. key .. " set to: " .. tostring(value))
  applySettingSideEffects(key)
  return true
end

-- Applies every valid value in memory and returns what it replaced, so a failed save can undo it.
local function stageValidChanges(values)
  local previousValues, changedKeys = {}, {}
  for key, value in pairs(values) do
    if settings[key] == nil then
      log("W", "rlsSettings", "Ignoring unknown or retired setting: " .. tostring(key))
    elseif type(value) ~= type(settings[key]) or not schema.acceptsConstraints(key, value) then
      log("W", "rlsSettings", "Ignoring invalid value for setting: " .. tostring(key))
    elseif settings[key] ~= value then
      previousValues[key] = settings[key]
      settings[key] = value
      table.insert(changedKeys, key)
    end
  end
  return previousValues, changedKeys
end

local function setSettings(values)
  if type(values) ~= "table" then return false end
  local previousValues, changedKeys = stageValidChanges(values)
  if #changedKeys == 0 then return true end
  if not saveSettings() then
    for key, value in pairs(previousValues) do settings[key] = value end
    return false
  end
  for _, key in ipairs(changedKeys) do
    log("I", "rlsSettings", "Setting " .. key .. " set to: " .. tostring(settings[key]))
    applySettingSideEffects(key)
  end
  return true
end

local function getSetting(key)
  return settings[key]
end

local function getSettings()
  return deepcopy(settings)
end

M.getSetting = getSetting
M.getSettings = getSettings
M.getSchema = schema.list
M.setSetting = setSetting
M.setSettings = setSettings
M.loadSettings = loadSettings
M.isLoaded = function() return settingsLoaded end

M.onExtensionLoaded = function()
  loadSettings()
end

return M
