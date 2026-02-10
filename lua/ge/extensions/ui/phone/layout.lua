local M = {}

local saveDir = "/career/rls_career"
local saveFile = saveDir .. "/phoneLayout.json"
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

local function loadLayout()
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then return getDefaultLayout() end
  local data = jsonReadFile(currentSavePath .. saveFile)
  if data then
    layoutData = data
    return data
  end
  layoutData = getDefaultLayout()
  return layoutData
end

local function saveLayout(data)
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then return end
  ensureSaveDir(currentSavePath)
  jsonWriteFileSafe(currentSavePath .. saveFile, data, true)
  layoutData = data
end

local function requestLayout()
  guihooks.trigger('phoneLayoutData', loadLayout())
end

local function updateLayout(data)
  saveLayout(data)
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
