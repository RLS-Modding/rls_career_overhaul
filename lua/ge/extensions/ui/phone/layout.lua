local M = {}

local saveDir = "/career/rls_career"
local saveFile = saveDir .. "/phoneLayout.json"
local settingsRoot = "settings/RLS/"
local globalFile = settingsRoot .. "phoneLayout.json"
local layoutData = nil

local function getDefaultLayout()
  return {
    version = 1,
    wallpaper = "default",
    pages = {
      { apps = {"loans", "bank", "marketplace", "car-meet", "repo", "taxi", "quarry", "beam-eats"} }
    },
    dock = {"repo", "bank", "marketplace", "taxi"},
    seenApps = {}
  }
end

local function ensureSaveDir(currentSavePath)
  local dir = currentSavePath .. saveDir
  if not FS:directoryExists(dir) then
    FS:directoryCreate(dir, true)
  end
end

local function ensureSettingsDir()
  if not FS:directoryExists(settingsRoot) then
    FS:directoryCreate(settingsRoot, true)
  end
end

local function getCurrentSavePath()
  if not career_saveSystem or not career_saveSystem.getCurrentSaveSlot then
    return nil
  end
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  return currentSavePath
end

local function clone(data)
  if type(data) ~= "table" then return data end
  local out = {}
  for k, v in pairs(data) do
    out[k] = clone(v)
  end
  return out
end

local function loadLayout()
  local currentSavePath = getCurrentSavePath()

  -- 1) Career-specific layout (highest priority)
  if currentSavePath then
    local careerData = jsonReadFile(currentSavePath .. saveFile)
    if careerData then
      layoutData = careerData
      return clone(careerData)
    end
  end

  -- 2) Global freeroam/default layout in settings
  local globalData = jsonReadFile(globalFile)
  if globalData then
    layoutData = globalData
    return clone(globalData)
  end

  -- 3) Hardcoded default layout
  layoutData = getDefaultLayout()
  return clone(layoutData)
end

local function saveLayout(data)
  if not data then return end
  local currentSavePath = getCurrentSavePath()

  if currentSavePath then
    -- Career mode: write per-save layout
    ensureSaveDir(currentSavePath)
    jsonWriteFileSafe(currentSavePath .. saveFile, data, true)
  else
    -- Freeroam/no active save: write global layout
    ensureSettingsDir()
    jsonWriteFileSafe(globalFile, data, true)
  end

  layoutData = clone(data)
end

local function requestLayout()
  guihooks.trigger('phoneLayoutData', loadLayout())
end

local function updateLayout(data)
  saveLayout(data)
  guihooks.trigger('phoneLayoutData', clone(layoutData))
end

M.onSaveCurrentSaveSlot = function(currentSavePath)
  if layoutData then
    ensureSaveDir(currentSavePath)
    jsonWriteFileSafe(currentSavePath .. saveFile, layoutData, true)
  end
end

M.onCareerModulesActivated = function()
  loadLayout()
end

M.requestLayout = requestLayout
M.updateLayout = updateLayout

return M
