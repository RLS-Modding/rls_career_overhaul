-- Player's police on/off preference, saved with the career and applied at the next load.
-- A pending choice from the new-save screen wins over the saved file; starting options seed the default.
local M = {}

-- SaveStore keys over the files this module writes today (metadata only).
require("overhaul/lib/save/store").registerKeys({
  {key = "options.policePreference", owner = "overhaul_career_police_policePreference", files = {"career/rls_career/policePreference.json"}, phase = "profile", required = true},
})

local store = require("overhaul/lib/save/optionsStore").new("policePreference.json")

local DEFAULT_ENABLED = true

-- Live preference, and the table written to the save file.
local enabled = DEFAULT_ENABLED
local saveData = {enabled = DEFAULT_ENABLED}
-- Preference written from the profile UI; applied on next career load, not mid-session.
local deferredEnabled = nil

local function applyPoliceState()
  overhaul_career_career.policeEnabled = enabled == true

  overhaul_career_economy_economyAdjusterPolicy.rebuild()
end

local function broadcastState()
  applyPoliceState()
  extensions.hook("onOverhaulPolicePreferenceChanged", enabled)
end

local function savePreferenceData(currentSavePath, overrideEnabled, writer)
  local savePath = currentSavePath or store.currentSavePath()
  if not savePath then return end

  store.ensureDir(savePath, writer)
  -- Career save hooks pass a second argument that is not the preference, so only a real boolean counts.
  local value
  if type(overrideEnabled) == "boolean" then
    value = overrideEnabled
  elseif deferredEnabled ~= nil then
    value = deferredEnabled
  else
    value = enabled
  end
  saveData.enabled = value == true
  store.write(savePath, saveData)
end

-- Consumes the new-save choice, so it applies to exactly one load.
local function readPendingValue()
  local pendingValue = overhaul_career_career.pendingPoliceEnabled
  overhaul_career_career.pendingPoliceEnabled = nil
  return pendingValue
end

local function resolveStartingOptionsPolice()
  local options = overhaul_career_career.startingOptions
  if type(options) == "table" and options.policeEnabled ~= nil then
    return options.policeEnabled == true
  end
  return nil
end

local function setEnabled(value, skipSave)
  deferredEnabled = nil
  enabled = value == true
  saveData.enabled = enabled
  if not skipSave then
    savePreferenceData()
  end
  broadcastState()
  return enabled
end

-- Persist preference for next load without changing mid-session police behavior.
local function setEnabledForNextLoad(value)
  deferredEnabled = value == true
  savePreferenceData(nil, deferredEnabled)
  return deferredEnabled
end

-- Seeds the save before modules activate, so an early autosave cannot overwrite a pending choice.
local function writeEnabledToSave(savePath, value)
  if not savePath then return false end
  store.ensureDir(savePath)
  local payload = {enabled = value == true}
  return store.write(savePath, payload) == true
end

local function loadPreferenceData(allowPendingValue)
  deferredEnabled = nil
  local savePath = store.currentSavePath()
  if not savePath then
    enabled = DEFAULT_ENABLED
    saveData = {enabled = DEFAULT_ENABLED}
    broadcastState()
    return
  end

  -- A new-save choice wins over any file an earlier module save wrote with the default.
  if allowPendingValue then
    local pendingValue = readPendingValue()
    if pendingValue ~= nil then
      enabled = pendingValue == true
      saveData = {enabled = enabled}
      savePreferenceData(savePath)
      broadcastState()
      return
    end
  end

  local loadedData = store.read(savePath)
  if type(loadedData) == "table" and loadedData.enabled ~= nil then
    enabled = loadedData.enabled == true
    saveData = {enabled = enabled}
    broadcastState()
    return
  end

  local fromStarting = resolveStartingOptionsPolice()
  if fromStarting ~= nil then
    enabled = fromStarting
  else
    enabled = DEFAULT_ENABLED
  end
  saveData = {enabled = enabled}
  savePreferenceData(savePath)
  broadcastState()
end

function M.isEnabled()
  return enabled == true
end

function M.getSavedEnabled()
  if deferredEnabled ~= nil then
    return deferredEnabled == true
  end
  return enabled == true
end

M.setEnabled = setEnabled
M.setEnabledForNextLoad = setEnabledForNextLoad
M.writeEnabledToSave = writeEnabledToSave

local function onCareerActivated()
  if not overhaul_career_career.isActive() then
    return
  end

  loadPreferenceData(true)
end

local function onOverhaulActive(active, newSave)
  if not active then
    return false
  end

  loadPreferenceData(newSave == true)
end

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  savePreferenceData(currentSavePath, nil, writer)
end

M.onCareerActivated = onCareerActivated
M.onOverhaulActive = onOverhaulActive
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile

return M
