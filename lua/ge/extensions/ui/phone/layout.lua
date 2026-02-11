local M = {}

local function isCareerActive()
  local state = core_gamestate and core_gamestate.state and core_gamestate.state.state
  if state == 'freeroam' then return false end
  if state == 'career' then return true end
  return career_career and career_career.isActive()
end

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
      { apps = {"loans", "repo", "marketplace", "car-meet", "quarry", "tuning-shop"} }
    },
    dock = {"guide", "beam-eats", "taxi", "bank"},
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

-- Sanitize data from JS while preserving empty-string slot placeholders.
local function sanitizeFromJS(data)
  if type(data) ~= "table" then
    return data
  end
  local out = {}
  for k, v in pairs(data) do
    out[k] = sanitizeFromJS(v)
  end
  return out
end

local function writeLayoutFile(path, data)
  if career_saveSystem and career_saveSystem.jsonWriteFileSafe then
    return career_saveSystem.jsonWriteFileSafe(path, data, true)
  end
  if jsonWriteFileSafe then
    return jsonWriteFileSafe(path, data, true)
  end
  if jsonWriteFile then
    return jsonWriteFile(path, data, true)
  end
  return false
end

local function loadLayout()
  local currentSavePath = getCurrentSavePath()

  -- 1) Career-specific layout (highest priority)
  if currentSavePath then
    local careerData = jsonReadFile(currentSavePath .. saveFile)
    if careerData then
      layoutData = careerData
      return layoutData
    end
  end

  -- 2) Global freeroam/default layout in settings
  local globalData = jsonReadFile(globalFile)
  if globalData then
    layoutData = globalData
    return layoutData
  end

  -- 3) Hardcoded default layout
  layoutData = getDefaultLayout()
  return layoutData
end

local function saveLayout(data)
  if not data then return end
  data = sanitizeFromJS(data)
  local currentSavePath = getCurrentSavePath()
  local writePath = nil
  local ok = false

  if currentSavePath then
    -- Career mode: write per-save layout
    ensureSaveDir(currentSavePath)
    writePath = currentSavePath .. saveFile
    ok = writeLayoutFile(writePath, data)
  else
    -- Freeroam/no active save: write global layout
    ensureSettingsDir()
    writePath = globalFile
    ok = writeLayoutFile(writePath, data)
  end

  if not ok then
    log('E', 'ui_phone_layout', string.format("Failed to write phone layout to '%s'", tostring(writePath)))
    return false
  end

  layoutData = data
  return true
end

local function requestLayout()
  guihooks.trigger('phoneLayoutData', loadLayout())
end

local function updateLayout(data)
  return saveLayout(data)
end

M.onSaveCurrentSaveSlot = function(currentSavePath)
  if layoutData then
    ensureSaveDir(currentSavePath)
    local ok = writeLayoutFile(currentSavePath .. saveFile, layoutData)
    if not ok then
      log('E', 'ui_phone_layout', string.format("Failed to write phone layout on save-slot commit to '%s'", tostring(currentSavePath .. saveFile)))
    end
  end
end

M.onCareerModulesActivated = function()
  loadLayout()
end

M.requestLayout = requestLayout
M.updateLayout = updateLayout
M.getCareerActive = isCareerActive

return M
