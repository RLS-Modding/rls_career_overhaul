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
local validPhoneSizes = { small = true, normal = true, large = true }

local function getDefaultSettings()
  return {
    phoneSize = "normal",
    backgroundColor = "#1509fb",
    backgroundImage = "",
  }
end

local function normalizeSettings(rawSettings)
  local defaults = getDefaultSettings()
  local settings = type(rawSettings) == "table" and rawSettings or {}

  local phoneSize = validPhoneSizes[settings.phoneSize] and settings.phoneSize or defaults.phoneSize
  local backgroundColor = settings.backgroundColor
  if type(backgroundColor) ~= "string" or not string.match(backgroundColor, "^#%x%x%x%x%x%x$") then
    backgroundColor = defaults.backgroundColor
  else
    backgroundColor = string.lower(backgroundColor)
  end

  local backgroundImage = settings.backgroundImage
  if type(backgroundImage) ~= "string" then
    backgroundImage = defaults.backgroundImage
  end

  return {
    phoneSize = phoneSize,
    backgroundColor = backgroundColor,
    backgroundImage = backgroundImage,
  }
end

local function getDefaultLayout()
  return {
    version = 1,
    wallpaper = "default",
    pages = {
      { apps = {"loans", "repo", "marketplace", "car-meet", "quarry", "tuning-shop"} }
    },
    dock = {"guide", "beam-eats", "taxi", "bank"},
    seenApps = {},
    settings = getDefaultSettings(),
  }
end

local function normalizeLayoutData(data)
  local normalized = type(data) == "table" and data or getDefaultLayout()
  normalized.settings = normalizeSettings(normalized.settings)
  return normalized
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
      layoutData = normalizeLayoutData(careerData)
      return layoutData
    end
  end

  -- 2) Global freeroam/default layout in settings
  local globalData = jsonReadFile(globalFile)
  if globalData then
    layoutData = normalizeLayoutData(globalData)
    return layoutData
  end

  -- 3) Hardcoded default layout
  layoutData = normalizeLayoutData(getDefaultLayout())
  return layoutData
end

local function saveLayout(data)
  if not data then return end
  data = normalizeLayoutData(sanitizeFromJS(data))
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

local function getSettings()
  local data = loadLayout()
  if type(data) ~= "table" then
    return getDefaultSettings()
  end
  return normalizeSettings(data.settings)
end

local function updateSettings(settings)
  local data = loadLayout() or getDefaultLayout()
  local merged = normalizeSettings(data.settings)
  if type(settings) == "table" then
    for key, value in pairs(settings) do
      merged[key] = value
    end
  end
  data.settings = normalizeSettings(merged)
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
M.getSettings = getSettings
M.updateSettings = updateSettings
M.getCareerActive = isCareerActive

return M
