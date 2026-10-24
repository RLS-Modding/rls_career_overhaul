-- Experimental maintenance mode: the career-wide switch that turns on the maintenance systems, saved per save.
-- The tire, computer and vehicle systems read this flag; this file owns its save and the change hook.
local M = {}

-- SaveStore keys over the files this module writes today (metadata only).
require("overhaul/lib/save/store").registerKeys({
  {key = "options.maintenanceMode", owner = "overhaul_career_maintenance_maintenanceMode", files = {"career/rls_career/maintenanceMode.json"}, phase = "profile", required = true},
})

local store = require("overhaul/lib/save/optionsStore").new("maintenanceMode.json")

local enabled = false
local saveData = {enabled = false}

-- Mirrors the flag onto the career and tells listeners it changed.
local function broadcastState()
  overhaul_career_career.experimentalMaintenanceEnabled = enabled
  extensions.hook("onOverhaulExperimentalMaintenanceModeChanged", enabled)
end

-- Writes the flag into the save folder; does nothing without a save path.
local function saveModeData(currentSavePath, _, writer)
  local savePath = currentSavePath or store.currentSavePath()
  if not savePath then return end

  store.ensureDir(savePath, writer)
  saveData.enabled = enabled == true
  store.write(savePath, saveData)
end

-- Sets the flag, saves it unless asked not to, and broadcasts the change. Returns the new value.
local function setEnabled(value, skipSave)
  enabled = value == true
  saveData.enabled = enabled
  if not skipSave then
    saveModeData()
  end
  broadcastState()
  return enabled
end

-- The career's pending value (set before the career loaded) is consumed once, so it cannot apply twice.
local function readPendingValue()
  local pendingValue = overhaul_career_career.pendingExperimentalMaintenanceEnabled
  overhaul_career_career.pendingExperimentalMaintenanceEnabled = nil
  return pendingValue
end

-- Reads the flag from the save. A save without one takes the pending value (new saves only) and writes it out.
local function loadModeData(allowPendingValue)
  local savePath = store.currentSavePath()
  if not savePath then
    enabled = false
    saveData = {enabled = false}
    broadcastState()
    return
  end

  local loadedData = store.read(savePath)
  if type(loadedData) == "table" and loadedData.enabled ~= nil then
    enabled = loadedData.enabled == true
    saveData = {enabled = enabled}
    broadcastState()
    return
  end

  local pendingValue = allowPendingValue and readPendingValue() or nil
  enabled = pendingValue == true
  saveData = {enabled = enabled}
  saveModeData(savePath)
  broadcastState()
end

local function onCareerActivated()
  if not overhaul_career_career.isActive() then
    return
  end

  loadModeData(true)
end

local function onOverhaulActive(active, newSave)
  if not active then
    return false
  end

  loadModeData(newSave == true)
end

M.isEnabled = function()
  return enabled == true
end
M.setEnabled = setEnabled
M.onCareerActivated = onCareerActivated
M.onOverhaulActive = onOverhaulActive
M.onOverhaulSaveCurrentProfile = saveModeData

return M
