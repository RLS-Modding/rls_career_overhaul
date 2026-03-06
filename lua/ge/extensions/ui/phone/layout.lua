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
local backgroundsDir = "/Phone/Backgrounds/"
local layoutData = nil
local SCALE_MIN, SCALE_MAX, SCALE_STEP = 0.5, 2, 0.1

local function clampScale(value)
  local n = tonumber(value)
  if not n then return 1 end
  local stepped = math.floor((n + SCALE_STEP * 0.5) / SCALE_STEP) * SCALE_STEP
  return math.max(SCALE_MIN, math.min(SCALE_MAX, stepped))
end

local function clampPosition(value)
  local n = tonumber(value)
  if not n then return 1 end
  return math.max(0, math.min(1, n))
end

local imagePatterns = { "*.png", "*.jpg", "*.jpeg", "*.webp" }

local function getDefaultSettings()
  return {
    phoneSize = 1,
    horizontalPosition = 1,
    backgroundColor = "#1509fb",
    backgroundImage = "",
  }
end

local function normalizeSettings(rawSettings)
  local defaults = getDefaultSettings()
  local settings = type(rawSettings) == "table" and rawSettings or {}

  local phoneSize = clampScale(settings.phoneSize)
  local horizontalPosition = clampPosition(settings.horizontalPosition)
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
    horizontalPosition = horizontalPosition,
    backgroundColor = backgroundColor,
    backgroundImage = backgroundImage,
  }
end

local function getDefaultLayout()
  return {
    version = 1,
    wallpaper = "default",
    pages = {
      { apps = {
        "loans",
        "repo",
        "marketplace",
        "car-meet",
        "quarry",
        "tuning-shop",
        "freeroam-events",
        "facility-work",
        "market-watch",
        "real-estate",
      } }
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

local function ensureBackgroundsDir()
  if not FS:directoryExists(backgroundsDir) then
    FS:directoryCreate(backgroundsDir, true)
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

local function normalizeUiPath(path)
  if type(path) ~= "string" then return nil end
  local normalized = string.gsub(path, "\\", "/")
  if string.sub(normalized, 1, 1) ~= "/" then
    normalized = "/" .. normalized
  end
  return normalized
end

local function getFileName(path)
  if type(path) ~= "string" then return "" end
  local normalized = string.gsub(path, "\\", "/")
  return string.match(normalized, "([^/]+)$") or normalized
end

local function addCandidate(candidates, seen, path)
  if type(path) ~= "string" or path == "" then return end
  local normalized = string.gsub(path, "\\", "/")
  if not seen[normalized] then
    seen[normalized] = true
    table.insert(candidates, normalized)
  end
end

local function joinPath(base, tail)
  if type(base) ~= "string" or base == "" then return nil end
  if type(tail) ~= "string" or tail == "" then return base end
  local left = string.gsub(base, "\\", "/")
  local right = string.gsub(tail, "\\", "/")
  if string.sub(left, -1) ~= "/" then left = left .. "/" end
  if string.sub(right, 1, 1) == "/" then right = string.sub(right, 2) end
  return left .. right
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

local function listBackgroundImages()
  ensureBackgroundsDir()
  local found = {}
  local seen = {}

  for _, pattern in ipairs(imagePatterns) do
    local files = FS:findFiles(backgroundsDir, pattern, 0, false, false) or {}
    for _, filePath in ipairs(files) do
      local resolvedPath = filePath
      if type(filePath) == "string" and not string.find(filePath, "/", 1, true) and not string.find(filePath, "\\", 1, true) then
        resolvedPath = backgroundsDir .. filePath
      end
      local uiPath = normalizeUiPath(resolvedPath)
      if uiPath and not seen[uiPath] then
        seen[uiPath] = true
        table.insert(found, {
          name = getFileName(filePath),
          path = uiPath,
        })
      end
    end
  end

  table.sort(found, function(a, b)
    return string.lower(a.name or "") < string.lower(b.name or "")
  end)

  return found
end

local function getBackgroundFolder(_)
  ensureBackgroundsDir()
  if Engine and Engine.Platform and Engine.Platform.getFSInfo then
    local okInfo, fsInfo = pcall(Engine.Platform.getFSInfo)
    if okInfo and type(fsInfo) == "table" then
      for _, key in ipairs({ "userPath", "userpath", "workingDir", "workingDirectory", "cwd", "homePath" }) do
        if type(fsInfo[key]) == "string" and fsInfo[key] ~= "" then
          return joinPath(fsInfo[key], "Phone/Backgrounds/")
        end
      end
    end
  end
  return backgroundsDir
end

local function openBackgroundFolder(_)
  ensureBackgroundsDir()

  if not (Engine and Engine.Platform and Engine.Platform.exploreFolder) then
    return false
  end

  local candidates = {}
  local seen = {}
  addCandidate(candidates, seen, backgroundsDir)

  -- Try filesystem helpers when available to get a real OS path.
  if FS then
    if type(FS.getFileRealPath) == "function" then
      addCandidate(candidates, seen, FS:getFileRealPath(backgroundsDir))
    end
    if type(FS.getAbsolutePath) == "function" then
      addCandidate(candidates, seen, FS:getAbsolutePath(backgroundsDir))
    end
  end

  if Engine.Platform.getFSInfo then
    local okInfo, fsInfo = pcall(Engine.Platform.getFSInfo)
    if okInfo and type(fsInfo) == "table" then
      for _, key in ipairs({ "userPath", "userpath", "workingDir", "workingDirectory", "cwd", "homePath" }) do
        if type(fsInfo[key]) == "string" and fsInfo[key] ~= "" then
          addCandidate(candidates, seen, joinPath(fsInfo[key], "Phone/Backgrounds/"))
        end
      end
    end
  end

  for _, path in ipairs(candidates) do
    local ok = pcall(function()
      Engine.Platform.exploreFolder(string.lower(path))
    end)
    if ok then return true end
  end

  return false
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
M.listBackgroundImages = listBackgroundImages
M.getBackgroundFolder = getBackgroundFolder
M.openBackgroundFolder = openBackgroundFolder
M.getCareerActive = isCareerActive

return M
