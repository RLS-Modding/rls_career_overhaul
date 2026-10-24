-- The phone's saved state: installed apps, home-screen placement, settings and notification routing.
-- Start at loadLayout and saveLayout, then updateLayout and updateSettings (phone UI) and fireNotification.
local M = {}

local context = require('overhaul/lib/career/context')
local optional = require('overhaul/lib/platform/optional')
local appCatalog = require('overhaul/lib/phone/appCatalog')

-- Config ------------------------------------------------------------------------------------------

local LAYOUT_VERSION = 12
local SCALE_MIN, SCALE_MAX, SCALE_STEP = 0.5, 2, 0.1
local NOTIFICATION_DISPLAY_MIN, NOTIFICATION_DISPLAY_MAX, NOTIFICATION_DISPLAY_DEFAULT = 2, 15, 8
local DND_DURATION_VALUES = { [0] = true, [60] = true, [120] = true, [240] = true }

local saveDir = "/career/rls_career"
local saveFile = saveDir .. "/phoneLayout.json"
local settingsRoot = "settings/RLS/"
local globalFile = settingsRoot .. "phoneLayout.json"

local backgroundsDir = "/Phone/Backgrounds/"
local imagePatterns = { "*.png", "*.jpg", "*.jpeg", "*.webp" }

-- State -------------------------------------------------------------------------------------------

-- The layout and where it was loaded from; the catalog is derived once per extension instance.
local state = { layoutData = nil, layoutDataSource = nil }
local shellLayout, shellLayoutOwner = nil, nil
local catalog = nil

local function getCatalog()
  if not catalog then
    catalog = appCatalog.derive(appCatalog.scan())
  end
  return catalog
end

-- Do-not-disturb values ---------------------------------------------------------------------------

local function normalizeDndDurationMinutes(value)
  local n = tonumber(value)
  if not n or n < 0 or not DND_DURATION_VALUES[n] then return 0 end
  return n
end

local function normalizeDndUntil(value)
  if value == nil or value == "" then return nil end
  local n = tonumber(value)
  if not n or n <= 0 then return nil end
  return math.floor(n)
end

-- Settings normalization --------------------------------------------------------------------------

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

local function clampNotificationDisplaySeconds(value)
  local n = tonumber(value)
  if not n then return NOTIFICATION_DISPLAY_DEFAULT end
  return math.max(NOTIFICATION_DISPLAY_MIN, math.min(NOTIFICATION_DISPLAY_MAX, math.floor(n + 0.5)))
end

local function getDefaultSettings()
  return {
    phoneSize = 1,
    horizontalPosition = 1,
    backgroundColor = "#1509fb",
    backgroundImage = "",
    notifications = {},
    doNotDisturb = false,
    doNotDisturbDurationMinutes = 0,
    doNotDisturbUntil = nil,
    lockScreenNotificationsEnabled = true,
    lockScreenContentMode = "show",
    lockScreenDisplaySeconds = NOTIFICATION_DISPLAY_DEFAULT,
    bannerNotificationsEnabled = true,
    bannerDisplaySeconds = NOTIFICATION_DISPLAY_DEFAULT,
  }
end

local function normalizeLockScreenContentMode(value)
  if value == "hide" then return "hide" end
  return "show"
end

local function migrateLegacyNotificationSettings(settings)
  local out = {}
  if type(settings) == "table" then
    for k, v in pairs(settings) do
      out[k] = v
    end
  end
  if out.doNotDisturb == nil and settings.notificationsEnabled == false then
    out.doNotDisturb = true
  end
  if out.lockScreenContentMode == nil and settings.notificationsSimple == true then
    out.lockScreenContentMode = "hide"
  end
  local legacySeconds = settings.notificationDisplaySeconds
  if out.lockScreenDisplaySeconds == nil then
    out.lockScreenDisplaySeconds = legacySeconds or NOTIFICATION_DISPLAY_DEFAULT
  end
  if out.bannerDisplaySeconds == nil then
    out.bannerDisplaySeconds = legacySeconds or NOTIFICATION_DISPLAY_DEFAULT
  end
  if out.doNotDisturb == nil then
    out.doNotDisturb = false
  end
  if out.lockScreenNotificationsEnabled == nil then
    out.lockScreenNotificationsEnabled = true
  end
  if out.bannerNotificationsEnabled == nil then
    out.bannerNotificationsEnabled = true
  end
  if out.doNotDisturbDurationMinutes == nil then
    out.doNotDisturbDurationMinutes = 0
  end
  if out.lockScreenContentMode == nil then
    out.lockScreenContentMode = "show"
  end
  return out
end

local function normalizeNotifications(raw)
  local out = {}
  if type(raw) == "table" then
    for key, value in pairs(raw) do
      if type(key) == "string" then
        out[key] = value ~= false
      end
    end
  end
  return out
end

local function normalizeSettings(rawSettings)
  local settings = migrateLegacyNotificationSettings(type(rawSettings) == "table" and rawSettings or {})
  local defaults = getDefaultSettings()

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

  local doNotDisturb = settings.doNotDisturb == true
  local doNotDisturbUntil = normalizeDndUntil(settings.doNotDisturbUntil)
  if doNotDisturb and doNotDisturbUntil ~= nil and os.time() >= doNotDisturbUntil then
    doNotDisturb = false
    doNotDisturbUntil = nil
  end

  return {
    phoneSize = phoneSize,
    horizontalPosition = horizontalPosition,
    backgroundColor = backgroundColor,
    backgroundImage = backgroundImage,
    notifications = normalizeNotifications(settings.notifications),
    doNotDisturb = doNotDisturb,
    doNotDisturbDurationMinutes = normalizeDndDurationMinutes(settings.doNotDisturbDurationMinutes),
    doNotDisturbUntil = doNotDisturbUntil,
    lockScreenNotificationsEnabled = settings.lockScreenNotificationsEnabled ~= false,
    lockScreenContentMode = normalizeLockScreenContentMode(settings.lockScreenContentMode),
    lockScreenDisplaySeconds = clampNotificationDisplaySeconds(settings.lockScreenDisplaySeconds),
    bannerNotificationsEnabled = settings.bannerNotificationsEnabled ~= false,
    bannerDisplaySeconds = clampNotificationDisplaySeconds(settings.bannerDisplaySeconds),
  }
end

-- Saved notifications -----------------------------------------------------------------------------

local function normalizeDiscoveredNotifications(raw)
  local out = {}
  if type(raw) == "table" then
    for key, meta in pairs(raw) do
      if type(key) == "string" and key ~= "" and type(meta) == "table" then
        out[key] = {
          label = type(meta.label) == "string" and meta.label or key,
          source = type(meta.source) == "string" and meta.source or "",
        }
      end
    end
  end
  return out
end

local function normalizePendingNotifications(raw)
  local out = {}
  if type(raw) ~= "table" then return out end
  for channelKey, entry in pairs(raw) do
    if type(channelKey) == "string" and channelKey ~= "" and type(entry) == "table" then
      local storedOpts = nil
      if type(entry.opts) == "table" and type(entry.opts.appId) == "string" and entry.opts.appId ~= "" then
        storedOpts = { appId = entry.opts.appId }
      end
      out[channelKey] = {
        payload = type(entry.payload) == "table" and entry.payload or {},
        opts = storedOpts,
        queuedAt = tonumber(entry.queuedAt) or 0,
      }
    end
  end
  return out
end

-- Installed IDs -----------------------------------------------------------------------------------

local function normalizeInstalledAppIds(raw)
  local out = {}
  local seen = {}
  if type(raw) == "table" then
    for _, id in ipairs(raw) do
      if type(id) == "string" and id ~= "" and not seen[id] then
        seen[id] = true
        out[#out + 1] = id
      end
    end
  end
  return out
end

local function collectInstalledFromLayout(layout)
  local seen = {}
  local out = {}
  local function addId(id)
    if type(id) ~= "string" or id == "" or seen[id] then return end
    seen[id] = true
    out[#out + 1] = id
  end
  for _, id in ipairs(getCatalog().systemIds) do
    addId(id)
  end
  if type(layout) == "table" then
    for _, id in ipairs(normalizeInstalledAppIds(layout.installedAppIds)) do
      addId(id)
    end
    if type(layout.dock) == "table" then
      for _, id in ipairs(layout.dock) do
        addId(id)
      end
    end
    for _, page in ipairs(layout.pages or {}) do
      local apps = type(page) == "table" and page.apps or nil
      if type(apps) == "table" then
        for _, id in ipairs(apps) do
          addId(id)
        end
      end
    end
  end
  return out
end

-- Defaults ----------------------------------------------------------------------------------------

local function getPreinstalledAppIds()
  local out = {}
  for _, id in ipairs(getCatalog().systemIds) do
    out[#out + 1] = id
  end
  return out
end

local function getDefaultInstalledAppIds()
  local out = getPreinstalledAppIds()
  for _, entry in ipairs(getCatalog().defaultHome) do
    out[#out + 1] = entry.id
  end
  return out
end

local function getDefaultHomePageApps()
  local apps = {}
  for i = 1, 16 do
    apps[i] = ""
  end
  for _, entry in ipairs(getCatalog().defaultHome) do
    if apps[entry.slot + 1] == "" then
      apps[entry.slot + 1] = entry.id
    end
  end
  return apps
end

local function getDefaultDockApps()
  local out = {}
  for _, id in ipairs(getCatalog().dockIds) do
    out[#out + 1] = id
  end
  return out
end

local function getDefaultLayout()
  return {
    version = LAYOUT_VERSION,
    wallpaper = "default",
    pages = {
      { apps = getDefaultHomePageApps() }
    },
    dock = getDefaultDockApps(),
    installedAppIds = getDefaultInstalledAppIds(),
    seenApps = {},
    removedAppIds = {},
    settings = getDefaultSettings(),
    discoveredNotifications = {},
    -- Latest notification per channel, held until the owning app is installed.
    pendingNotifications = {},
  }
end

-- App placement -----------------------------------------------------------------------------------

local function hasApp(layout, appId)
  if type(layout) ~= "table" or type(appId) ~= "string" or appId == "" then
    return false
  end

  for _, page in ipairs(layout.pages or {}) do
    for _, entry in ipairs((type(page) == "table" and page.apps) or {}) do
      if entry == appId then
        return true
      end
    end
  end

  for _, entry in ipairs(layout.dock or {}) do
    if entry == appId then
      return true
    end
  end

  return false
end

local function ensureFirstPageApps(layout)
  if type(layout.pages) ~= "table" then
    layout.pages = {}
  end
  if type(layout.pages[1]) ~= "table" then
    layout.pages[1] = {apps = {}}
  end
  if type(layout.pages[1].apps) ~= "table" then
    layout.pages[1].apps = {}
  end
  return layout.pages[1].apps
end

local function insertMissingApp(layout, appId, anchorAppId)
  if hasApp(layout, appId) then
    return false
  end

  local apps = ensureFirstPageApps(layout)
  if type(anchorAppId) == "string" and anchorAppId ~= "" then
    for idx, entry in ipairs(apps) do
      if entry == anchorAppId and idx < 16 and (apps[idx + 1] == nil or apps[idx + 1] == "") then
        apps[idx + 1] = appId
        return true
      end
    end
  end

  for _, page in ipairs(layout.pages) do
    if type(page) == "table" and type(page.apps) == "table" then
      for index = 1, 16 do
        if page.apps[index] == nil or page.apps[index] == "" then
          page.apps[index] = appId
          return true
        end
      end
    end
  end
  layout.pages[#layout.pages + 1] = {apps = {appId}}
  return true
end

local function removeApp(layout, appId)
  if type(layout) ~= "table" or type(appId) ~= "string" or appId == "" then
    return false
  end

  local changed = false
  for _, page in ipairs(layout.pages or {}) do
    local apps = type(page) == "table" and page.apps or nil
    if type(apps) == "table" then
      for i = #apps, 1, -1 do
        if apps[i] == appId then
          table.remove(apps, i)
          changed = true
        end
      end
    end
  end

  if type(layout.dock) == "table" then
    for i = #layout.dock, 1, -1 do
      if layout.dock[i] == appId then
        table.remove(layout.dock, i)
        changed = true
      end
    end
  end

  return changed
end

local function clearPreinstalledFromRemoved(layout)
  if type(layout.removedAppIds) ~= "table" then return false end
  local blocked = {}
  for _, entry in ipairs(getCatalog().defaultHome) do
    if entry.required then blocked[entry.id] = true end
  end
  for _, id in ipairs(getCatalog().systemIds) do
    blocked[id] = true
  end
  local kept = {}
  local changed = false
  for _, id in ipairs(layout.removedAppIds) do
    if blocked[id] then
      changed = true
    else
      kept[#kept + 1] = id
    end
  end
  if changed then
    layout.removedAppIds = kept
  end
  return changed
end

local function ensureDefaultAppsPlaced(layout)
  if type(layout) ~= "table" then
    return false
  end

  local changed = clearPreinstalledFromRemoved(layout)
  if type(layout.dock) ~= "table" then
    layout.dock = getDefaultDockApps()
    changed = true
  end

  local removed = {}
  for _, id in ipairs(normalizeInstalledAppIds(layout.removedAppIds)) do removed[id] = true end

  -- Default home apps in slot order, each placed after the previous one when that slot is free.
  local anchor = nil
  for _, entry in ipairs(getCatalog().defaultHome) do
    if (entry.required or not removed[entry.id]) and insertMissingApp(layout, entry.id, anchor) then
      changed = true
    end
    anchor = entry.id
  end

  local ids = normalizeInstalledAppIds(layout.installedAppIds)
  local seen = {}
  for _, id in ipairs(ids) do
    seen[id] = true
  end
  for _, id in ipairs(getDefaultInstalledAppIds()) do
    if not seen[id] and not removed[id] then
      ids[#ids + 1] = id
      changed = true
    end
  end
  layout.installedAppIds = ids

  return changed
end

local function applyPhoneOverhaulLayout(layout)
  ensureDefaultAppsPlaced(layout)
end

-- Version migrations ------------------------------------------------------------------------------

local function applyLayoutVersionMigrations(normalized, version, changed)
  if version < 2 then
    insertMissingApp(normalized, "fre-contracts", "freeroam-events")
    changed = true
  end

  if removeApp(normalized, "scene-invites") then
    changed = true
  end

  if version < 7 then
    normalized.installedAppIds = collectInstalledFromLayout(normalized)
    changed = true
  end

  if version < 8 then
    applyPhoneOverhaulLayout(normalized)
    changed = true
  end

  if version < 9 then
    if ensureDefaultAppsPlaced(normalized) then
      changed = true
    end
  end

  if version < 10 then
    if clearPreinstalledFromRemoved(normalized) then
      changed = true
    end
    if ensureDefaultAppsPlaced(normalized) then
      changed = true
    end
  end

  if version < 11 then
    if ensureDefaultAppsPlaced(normalized) then
      changed = true
    end
  end

  if ensureDefaultAppsPlaced(normalized) then
    changed = true
  end

  return changed
end

local function migrateLayoutData(data)
  local normalized = type(data) == "table" and data or getDefaultLayout()
  local changed = false
  local version = math.floor(tonumber(normalized.version) or 1)
  if version < LAYOUT_VERSION then
    changed = true
  end

  changed = applyLayoutVersionMigrations(normalized, version, changed)
  normalized.version = LAYOUT_VERSION

  normalized.settings = normalizeSettings(normalized.settings)
  normalized.discoveredNotifications = normalizeDiscoveredNotifications(normalized.discoveredNotifications)
  normalized.pendingNotifications = normalizePendingNotifications(normalized.pendingNotifications)
  normalized.installedAppIds = normalizeInstalledAppIds(normalized.installedAppIds)
  if #normalized.installedAppIds == 0 then
    normalized.installedAppIds = collectInstalledFromLayout(normalized)
  end
  return normalized, changed
end

local function normalizeLayoutData(data)
  local normalized = migrateLayoutData(data)
  return normalized
end

local function sanitizeLayoutData(data)
  local normalized = type(data) == "table" and data or getDefaultLayout()
  local version = math.floor(tonumber(normalized.version) or LAYOUT_VERSION)
  if version > LAYOUT_VERSION then
    version = LAYOUT_VERSION
  end
  normalized.version = version
  normalized.settings = normalizeSettings(normalized.settings)
  normalized.discoveredNotifications = normalizeDiscoveredNotifications(normalized.discoveredNotifications)
  normalized.pendingNotifications = normalizePendingNotifications(normalized.pendingNotifications)
  normalized.installedAppIds = normalizeInstalledAppIds(normalized.installedAppIds)
  if #normalized.installedAppIds == 0 then
    normalized.installedAppIds = collectInstalledFromLayout(normalized)
  end
  return normalized
end

-- File writes -------------------------------------------------------------------------------------

local function ensureSaveDir(currentSavePath, writer)
  local dir = currentSavePath .. saveDir
  if writer then
    if not writer.exists(dir) then writer.mkdir(dir, true) end
  elseif not FS:directoryExists(dir) then
    FS:directoryCreate(dir, true)
  end
end

local function ensureSettingsDir()
  if not FS:directoryExists(settingsRoot) then
    FS:directoryCreate(settingsRoot, true)
  end
end

local function getCurrentSavePath()
  -- Reload can read layout settings before the save owner has been reconstructed.
  local currentSaveSystem = overhaul_career_saveSystem
  if not currentSaveSystem then return nil end
  local _, currentSavePath = currentSaveSystem.getCurrentProfile()
  return currentSavePath
end

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

local function writeSlotLayoutFile(path, data)
  return overhaul_career_saveSystem.jsonWriteFileSafe(path, data, true)
end

local function writeGlobalLayoutFile(data)
  ensureSettingsDir()
  return jsonWriteFile(globalFile, data, true)
end

-- Profile source ----------------------------------------------------------------------------------

local function getLayoutSource()
  local currentSavePath = getCurrentSavePath()
  if not currentSavePath then return false, nil end
  local profile = overhaul_career_saveSystem.getCurrentProfile()
  return profile or currentSavePath, currentSavePath
end

-- Loading -----------------------------------------------------------------------------------------

local function loadLayout(force)
  local source, currentSavePath = getLayoutSource()
  if not force and type(state.layoutData) == "table" and state.layoutDataSource == source then
    return deepcopy(state.layoutData)
  end
  state.layoutDataSource = source

  -- 1) Career-specific layout (highest priority)
  if currentSavePath then
    local careerData = jsonReadFile(currentSavePath .. saveFile)
    if careerData then
      state.layoutData = migrateLayoutData(careerData)
      return deepcopy(state.layoutData)
    end
  end

  -- 2) Global freeroam/default layout in settings
  local globalData = jsonReadFile(globalFile)
  if globalData then
    local migrated
    state.layoutData, migrated = migrateLayoutData(globalData)
    if migrated and not currentSavePath then
      writeGlobalLayoutFile(state.layoutData)
    end
    return deepcopy(state.layoutData)
  end

  -- 3) Hardcoded default layout
  state.layoutData = normalizeLayoutData(getDefaultLayout())
  return deepcopy(state.layoutData)
end

-- Saved state -------------------------------------------------------------------------------------

local function saveLayout(data)
  if not data then return end
  if type(data) == "table" and data.pendingNotifications == nil and type(state.layoutData) == "table" then
    data.pendingNotifications = state.layoutData.pendingNotifications
  end
  data = sanitizeLayoutData(sanitizeFromJS(data))
  local source, currentSavePath = getLayoutSource()

  -- Freeroam/no active save: write the global layout. A career keeps it in memory until its next save.
  if not currentSavePath and not writeGlobalLayoutFile(data) then
    log('E', 'overhaul_phone_apps_layout', string.format("Failed to write phone layout to '%s'", globalFile))
    return false
  end

  state.layoutData = data
  state.layoutDataSource = source
  return true
end

local function getCachedLayout()
  local source = getLayoutSource()
  if type(state.layoutData) == "table" and state.layoutDataSource == source then
    return state.layoutData
  end
  loadLayout()
  return state.layoutData
end

-- Notifications stay with their owner; opening the shell only needs placement and settings.
-- The layout owner replaces its table on writes and profile loads, invalidating this projection.
local function getShellLayout()
  local data = getCachedLayout()
  if shellLayoutOwner ~= data then
    shellLayoutOwner = data
    shellLayout = {}
    for _, key in ipairs({ 'version', 'wallpaper', 'pages', 'dock', 'installedAppIds', 'seenApps', 'removedAppIds', 'settings' }) do
      shellLayout[key] = deepcopy(data[key])
    end
  end
  return deepcopy(shellLayout)
end

-- Lifecycle storage -------------------------------------------------------------------------------

local function seedCareerPhoneLayout(newSave)
  local currentSavePath = getCurrentSavePath()
  if not currentSavePath then return end
  if newSave and not jsonReadFile(currentSavePath .. saveFile) then
    state.layoutData = normalizeLayoutData(getDefaultLayout())
    state.layoutDataSource = getLayoutSource()
    return
  end
  local data = loadLayout(true) or getDefaultLayout()
  if ensureDefaultAppsPlaced(data) then
    saveLayout(data)
  end
end

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  if state.layoutData then
    ensureSaveDir(currentSavePath, writer)
    local ok = writeSlotLayoutFile(currentSavePath .. saveFile, state.layoutData)
    if not ok then
      log('E', 'overhaul_phone_apps_layout', string.format("Failed to write phone layout on save-slot commit to '%s'", tostring(currentSavePath .. saveFile)))
    end
  end
end

-- App queries -------------------------------------------------------------------------------------

local function getInstalledIdSet(data)
  local set = {}
  if type(data) ~= "table" then return set end
  for _, id in ipairs(normalizeInstalledAppIds(data.installedAppIds)) do
    set[id] = true
  end
  return set
end

local function isAppInstalled(appId)
  if type(appId) ~= "string" or appId == "" then
    return true
  end
  for _, id in ipairs(getCatalog().systemIds) do
    if id == appId then
      return true
    end
  end
  local data = getCachedLayout()
  if type(data) ~= "table" then
    return false
  end
  for _, id in ipairs(normalizeInstalledAppIds(data.installedAppIds)) do
    if id == appId then
      return true
    end
  end
  return false
end

local function getInstalledAppIds()
  local data = getCachedLayout()
  if type(data) ~= "table" then
    return getPreinstalledAppIds()
  end
  local seen = {}
  local out = {}
  local function addId(id)
    if type(id) ~= "string" or id == "" or seen[id] then return end
    seen[id] = true
    out[#out + 1] = id
  end
  for _, id in ipairs(getCatalog().systemIds) do
    addId(id)
  end
  for _, id in ipairs(normalizeInstalledAppIds(data.installedAppIds)) do
    addId(id)
  end
  return out
end

-- Current settings --------------------------------------------------------------------------------

local function getSettings()
  local data = getCachedLayout()
  if type(data) ~= "table" then
    return getDefaultSettings()
  end
  return normalizeSettings(data.settings)
end

-- Notification gate -------------------------------------------------------------------------------

local function isDoNotDisturbActive()
  local settings = getSettings()
  if type(settings) ~= "table" or settings.doNotDisturb ~= true then
    return false
  end
  local untilTs = normalizeDndUntil(settings.doNotDisturbUntil)
  if untilTs == nil then
    return true
  end
  return os.time() < untilTs
end

local function isNotificationsMasterEnabled()
  return not isDoNotDisturbActive()
end

-- Channel keys ------------------------------------------------------------------------------------

local function getBaseNotificationChannelKey(channelKey)
  if type(channelKey) ~= "string" or channelKey == "" then
    return channelKey
  end
  local base = channelKey:match("^([^:]+)")
  return base or channelKey
end

local function buildPendingQueueKey(channelKey, payload, opts)
  local base = getBaseNotificationChannelKey(channelKey)
  if not getCatalog().perEntity[base] then
    return base
  end
  local entityId = nil
  if type(opts) == "table" and opts.entityId ~= nil then
    entityId = tostring(opts.entityId)
  elseif type(payload) == "table" and payload.entityId ~= nil then
    entityId = tostring(payload.entityId)
  end
  if entityId and entityId ~= "" then
    return base .. ":" .. entityId
  end
  return base
end

-- Channel policy ----------------------------------------------------------------------------------

local function resolveNotificationAppId(channelKey, opts)
  if type(opts) == "table" and type(opts.appId) == "string" and opts.appId ~= "" then
    return opts.appId
  end
  if type(channelKey) == "string" and channelKey ~= "" then
    local base = getBaseNotificationChannelKey(channelKey)
    local channelApps = getCatalog().channelApps
    return channelApps[base] or channelApps[channelKey]
  end
  return nil
end

local function isNotificationAppInstalled(channelKey, opts)
  local appId = resolveNotificationAppId(channelKey, opts)
  if not appId then
    return true
  end
  return isAppInstalled(appId)
end

local function isNotificationEnabled(category)
  if type(category) ~= "string" or category == "" then return true end
  local base = getBaseNotificationChannelKey(category)
  local settings = getSettings()
  if type(settings) == "table" and type(settings.notifications) == "table" then
    local value = settings.notifications[base]
    if value == nil then
      value = settings.notifications[category]
    end
    if value ~= nil then
      return value ~= false
    end
  end
  return true
end

-- Channel discovery -------------------------------------------------------------------------------

local function registerDiscoveredChannel(channelKey, payload)
  if type(channelKey) ~= "string" or channelKey == "" then return end
  channelKey = getBaseNotificationChannelKey(channelKey)

  -- Fast path: already known in memory, skip the disk round-trip.
  if type(state.layoutData) == "table" and type(state.layoutData.discoveredNotifications) == "table"
     and state.layoutData.discoveredNotifications[channelKey] ~= nil then
    return
  end

  local data = loadLayout()
  if type(data) ~= "table" then return end
  if type(data.discoveredNotifications) ~= "table" then
    data.discoveredNotifications = {}
  end
  if data.discoveredNotifications[channelKey] ~= nil then
    return
  end

  local source, label = "", channelKey
  if type(payload) == "table" then
    if type(payload.source) == "string" then source = payload.source end
    if type(payload.title) == "string" and payload.title ~= "" then label = payload.title end
  end
  data.discoveredNotifications[channelKey] = { label = label, source = source }
  saveLayout(data)
end

local function getKnownNotificationChannels()
  local data = loadLayout()
  local out = {}
  if type(data) == "table" and type(data.discoveredNotifications) == "table" then
    for key, meta in pairs(data.discoveredNotifications) do
      out[#out + 1] = {
        key = key,
        label = (type(meta) == "table" and type(meta.label) == "string") and meta.label or key,
        source = (type(meta) == "table" and type(meta.source) == "string") and meta.source or "",
      }
    end
  end
  return out
end

-- Pending queues ----------------------------------------------------------------------------------

local function queuePendingNotification(channelKey, payload, opts)
  if type(channelKey) ~= "string" or channelKey == "" then return false end
  local data = loadLayout()
  if type(data) ~= "table" then return false end
  if type(data.pendingNotifications) ~= "table" then
    data.pendingNotifications = {}
  end
  local storedOpts = nil
  if type(opts) == "table" and type(opts.appId) == "string" and opts.appId ~= "" then
    storedOpts = { appId = opts.appId }
  end
  data.pendingNotifications[channelKey] = {
    payload = type(payload) == "table" and payload or {},
    opts = storedOpts,
    queuedAt = os.time(),
  }
  return saveLayout(data)
end

-- Dispatch ----------------------------------------------------------------------------------------

local function fireNotification(channelKey, payload, opts)
  if isDoNotDisturbActive() then
    return false
  end
  local fromQueue = type(opts) == "table" and opts._fromPendingQueue == true
  local baseChannelKey = getBaseNotificationChannelKey(channelKey)
  if channelKey then
    if not fromQueue and not isNotificationAppInstalled(baseChannelKey, opts) then
      registerDiscoveredChannel(baseChannelKey, payload)
      if getCatalog().neverQueue[baseChannelKey] then
        return false
      end
      local queueKey = buildPendingQueueKey(baseChannelKey, payload, opts)
      queuePendingNotification(queueKey, payload, opts)
      return false
    end
    registerDiscoveredChannel(baseChannelKey, payload)
    if not isNotificationEnabled(baseChannelKey) then
      return false
    end
  end
  local triggerPayload = {}
  if type(payload) == "table" then
    for k, v in pairs(payload) do
      triggerPayload[k] = v
    end
  end
  if type(baseChannelKey) == "string" and baseChannelKey ~= "" then
    triggerPayload.channelKey = baseChannelKey
  end
  if type(opts) == "table" and type(opts.appId) == "string" and opts.appId ~= "" then
    triggerPayload.appId = opts.appId
  end
  guihooks.trigger("PhoneLockNotification", triggerPayload)
  return true
end

-- Pending queue delivery --------------------------------------------------------------------------

local function clearPendingNotificationsForApp(appId)
  if type(appId) ~= "string" or appId == "" then return end
  local data = loadLayout()
  if type(data) ~= "table" or type(data.pendingNotifications) ~= "table" then return end
  local changed = false
  for channelKey, entry in pairs(data.pendingNotifications) do
    if resolveNotificationAppId(channelKey, type(entry) == "table" and entry.opts or nil) == appId then
      data.pendingNotifications[channelKey] = nil
      changed = true
    end
  end
  if changed then
    saveLayout(data)
  end
end

local function flushPendingNotificationsForApp(appId)
  if type(appId) ~= "string" or appId == "" then return false end
  local data = loadLayout()
  if type(data) ~= "table" or type(data.pendingNotifications) ~= "table" then return false end

  local toFlush = {}
  for channelKey, entry in pairs(data.pendingNotifications) do
    if type(channelKey) == "string" and type(entry) == "table" then
      if resolveNotificationAppId(channelKey, entry.opts) == appId then
        toFlush[#toFlush + 1] = { channelKey = channelKey, entry = entry }
      end
    end
  end
  if #toFlush == 0 then return false end

  for _, item in ipairs(toFlush) do
    data.pendingNotifications[item.channelKey] = nil
  end
  saveLayout(data)

  for _, item in ipairs(toFlush) do
    local flushOpts = type(item.entry.opts) == "table" and item.entry.opts or {}
    flushOpts._fromPendingQueue = true
    local baseKey = getBaseNotificationChannelKey(item.channelKey)
    fireNotification(baseKey, item.entry.payload, flushOpts)
  end
  return true
end

-- Install synchronization -------------------------------------------------------------------------

local function syncNotificationsOnPhoneAppInstall(appId)
  local sync = getCatalog().installSync[appId]
  if not sync then
    return
  end
  if not sync.loadOnlyInCareer or overhaul_career_career.isActive() then
    pcall(extensions.load, sync.extension)
  end
  local owner = optional(sync.extension)
  if owner and owner[sync.call] then
    pcall(owner[sync.call])
  end
end

-- Installation changes ----------------------------------------------------------------------------

local function handleAppInstallSideEffects(beforeData, afterData)
  local before = getInstalledIdSet(beforeData)
  local after = getInstalledIdSet(afterData)
  local installStateChanged = false

  for appId in pairs(before) do
    if not after[appId] then
      installStateChanged = true
      clearPendingNotificationsForApp(appId)
    end
  end

  for appId in pairs(after) do
    if not before[appId] then
      installStateChanged = true
      if getCatalog().installSync[appId] then
        clearPendingNotificationsForApp(appId)
        syncNotificationsOnPhoneAppInstall(appId)
      else
        flushPendingNotificationsForApp(appId)
      end
    end
  end

  if installStateChanged then
    extensions.hook("onPhoneAppInstallStateChanged", before, after)
  end
end

-- Background images -------------------------------------------------------------------------------

local function ensureBackgroundsDir()
  if not FS:directoryExists(backgroundsDir) then
    FS:directoryCreate(backgroundsDir, true)
  end
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

-- Background folder -------------------------------------------------------------------------------

local function getBackgroundFolder(_)
  ensureBackgroundsDir()
  local fsInfo = Engine.Platform.getFSInfo()
  if type(fsInfo) == "table" then
    for _, key in ipairs({ "userPath", "userpath", "workingDir", "workingDirectory", "cwd", "homePath" }) do
      if type(fsInfo[key]) == "string" and fsInfo[key] ~= "" then
        return joinPath(fsInfo[key], "Phone/Backgrounds/")
      end
    end
  end
  return backgroundsDir
end

local function openBackgroundFolder(_)
  ensureBackgroundsDir()

  local candidates = {}
  local seen = {}
  addCandidate(candidates, seen, backgroundsDir)
  addCandidate(candidates, seen, FS:getFileRealPath(backgroundsDir))

  local fsInfo = Engine.Platform.getFSInfo()
  if type(fsInfo) == "table" then
    for _, key in ipairs({ "userPath", "userpath", "workingDir", "workingDirectory", "cwd", "homePath" }) do
      if type(fsInfo[key]) == "string" and fsInfo[key] ~= "" then
        addCandidate(candidates, seen, joinPath(fsInfo[key], "Phone/Backgrounds/"))
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

-- UI commands -------------------------------------------------------------------------------------

local function emitLoadedLayout()
  local loaded = loadLayout()
  guihooks.trigger('phoneLayoutData', loaded)
  return loaded
end

local function requestLayout()
  emitLoadedLayout()
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
  if not saveLayout(data) then
    return false
  end
  emitLoadedLayout()
  return true
end

local function updateLayout(data)
  local before = loadLayout()
  if not saveLayout(data) then
    return false
  end
  local loaded = emitLoadedLayout()
  handleAppInstallSideEffects(before, loaded)
  return true
end

local function installApp(appId)
  if type(appId) ~= "string" or appId == "" then
    return false
  end
  local data = loadLayout() or getDefaultLayout()
  local ids = normalizeInstalledAppIds(data.installedAppIds)
  local already = false
  for _, id in ipairs(ids) do
    if id == appId then
      already = true
      break
    end
  end
  if not already then
    ids[#ids + 1] = appId
  end
  data.installedAppIds = ids
  if type(data.removedAppIds) == "table" then
    local kept = {}
    for _, id in ipairs(data.removedAppIds) do
      if id ~= appId then
        kept[#kept + 1] = id
      end
    end
    data.removedAppIds = kept
  end
  insertMissingApp(data, appId)
  return updateLayout(data)
end

local function ensureDefaultAppsPlacedForUi()
  local data = loadLayout() or getDefaultLayout()
  if ensureDefaultAppsPlaced(data) then
    saveLayout(data)
  end
  emitLoadedLayout()
  return true
end

-- Lifecycle ---------------------------------------------------------------------------------------

local function onOverhaulModulesActivated()
  loadLayout(true)
  local data = state.layoutData or getDefaultLayout()
  if ensureDefaultAppsPlaced(data) then
    saveLayout(data)
  end
end

local function onOverhaulActive(active, newSave)
  if not active then return end
  seedCareerPhoneLayout(newSave == true)
  emitLoadedLayout()
end

-- Public API --------------------------------------------------------------------------------------

M.requestLayout = requestLayout
M.getShellLayout = getShellLayout
M.updateLayout = updateLayout
M.getSettings = getSettings
M.updateSettings = updateSettings
M.isNotificationEnabled = isNotificationEnabled
M.isDoNotDisturbActive = isDoNotDisturbActive
M.isNotificationsMasterEnabled = isNotificationsMasterEnabled
M.isAppInstalled = isAppInstalled
M.installApp = installApp
M.getInstalledAppIds = getInstalledAppIds
M.fireNotification = fireNotification
M.getKnownNotificationChannels = getKnownNotificationChannels
M.listBackgroundImages = listBackgroundImages
M.getBackgroundFolder = getBackgroundFolder
M.openBackgroundFolder = openBackgroundFolder
M.getCareerActive = context.isCareerActive
M.getCurrentLevelId = context.currentLevelId
M.ensureDefaultAppsPlaced = ensureDefaultAppsPlacedForUi

-- Game hooks --------------------------------------------------------------------------------------

M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.onOverhaulModulesActivated = onOverhaulModulesActivated
M.onOverhaulActive = onOverhaulActive

return M
