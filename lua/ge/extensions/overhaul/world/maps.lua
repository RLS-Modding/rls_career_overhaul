-- Keeps the list of maps Overhaul can run, and mounts the level files that map mods ship for it while a level is pending.
-- Config, the map registry, filesystem helpers, optional features, the map list, override lifecycle, then the hooks and public API.
local M = {}
local modIdentity = require("overhaul/lib/platform/modIdentity")
local levelData = require('overhaul/lib/world/levelData')
local sharedMaterials = require('overhaul/lib/world/sharedMaterials')

-- Level files that map mods ship for Overhaul under /overrides/. A copy in the mod's temp folder is
-- mounted only while Overhaul loads or plays a level.
local MOD_OVERRIDES_DIR = '/overrides/'
local OVERRIDES_ROOT = "/temp/rls_career/mapOverrides/"

local DEFAULT_MAP_PREVIEW = '/ui/ui-vue/mods/rls_career_overhaul/overhaul/assets/profilePreview_rls_west_coast.jpg'
local PROFILE_PREVIEW_NAMES = {rls_west_coast = 'WCUSA', west_coast_usa = 'WCUSA'}

local compatibleMaps = {}
local mapMetadata = {}
local unavailableProviders = {}

local function getMapMetadata(levelId)
  return mapMetadata[levelId or getCurrentLevelIdentifier()]
end

local function profilePreview(levelId)
  local name = PROFILE_PREVIEW_NAMES[levelId] or levelId
  local candidate = '/ui/modules/career/profilePreview_' .. name .. '.jpg'
  if FS:fileExists(candidate) then return candidate end
  -- Existing map artwork sometimes capitalizes its level name differently from the installed directory.
  for _, file in ipairs(FS:findFiles('/ui/modules/career/', 'profilePreview_*.jpg', 0, true, false) or {}) do
    if file:lower() == candidate:lower() and FS:fileExists(file) then return file end
  end
end

local function resolveMapAsset(levelId, field)
  levelId = levelId or getCurrentLevelIdentifier()
  if not levelId then return nil end
  local metadata = getMapMetadata(levelId)
  local configured = metadata and levelData.assetPath(levelId, metadata[field])
  if configured and FS:fileExists(configured) then return configured end
  if field ~= 'preview' and field ~= 'travelPreview' then return nil end
  local generalPreview = metadata and levelData.assetPath(levelId, metadata.preview)
  if generalPreview and FS:fileExists(generalPreview) then return generalPreview end
  local existingPreview = profilePreview(levelId)
  if existingPreview then return existingPreview end
  for _, filename in ipairs({'facilities/images/switchMap.jpg', 'facilities/images/switchMap.png'}) do
    local candidate = levelData.assetPath(levelId, filename)
    if FS:fileExists(candidate) then return candidate end
  end
  local level = core_levels.getLevelByName(levelId)
  for _, candidate in ipairs(level and level.previews or {}) do
    if FS:fileExists(candidate) then return candidate end
  end
  return FS:fileExists(DEFAULT_MAP_PREVIEW) and DEFAULT_MAP_PREVIEW or nil
end

local function getMapCatalog()
  local entries = {}
  for id, label in pairs(compatibleMaps) do
    local entry = deepcopy(mapMetadata[id] or {id = id, label = label})
    entry.preview = resolveMapAsset(id, 'preview')
    entry.travelPreview = resolveMapAsset(id, 'travelPreview')
    for mode, preview in pairs(entry.startPreviews or {}) do
      local candidate = levelData.assetPath(id, preview)
      entry.startPreviews[mode] = candidate and FS:fileExists(candidate) and candidate or entry.preview
    end
    entry.startPolicies = {hardcore = levelData.startPolicy(id, 'hardcore')}
    entries[#entries + 1] = entry
  end
  table.sort(entries, function(a, b) return a.id < b.id end)
  return entries
end

local function getDefaultMap()
  local selected
  for id, metadata in pairs(mapMetadata) do
    if compatibleMaps[id] and metadata.defaultStart then
      if selected then
        log('E', 'overhaul_world_maps', 'Multiple default start maps; select one in metadata')
        return nil
      end
      selected = id
    end
  end
  if not selected then log('W', 'overhaul_world_maps', 'No installed default career map') end
  return selected
end

local function removeTree(root)
  if not FS:directoryExists(root) then return false end
  for _, file in ipairs(FS:findFiles(root, "*", -1, true, false) or {}) do FS:removeFile(file) end
  local dirs = FS:findFiles(root, "*", -1, false, true) or {}
  table.sort(dirs, function(a, b) return #a > #b end)
  for _, dir in ipairs(dirs) do FS:directoryRemove(dir) end
  FS:directoryRemove(root)
  return true
end

local function copyFiles(srcDir, dstDir)
  local srcRoot = srcDir:gsub('\\', '/')
  if srcRoot:sub(-1) ~= '/' then srcRoot = srcRoot .. '/' end
  local dstRoot = dstDir:gsub('\\', '/')
  if dstRoot:sub(-1) ~= '/' then dstRoot = dstRoot .. '/' end
  if not FS:directoryExists(srcRoot) then return 0 end
  if not FS:directoryExists(dstRoot) then FS:directoryCreate(dstRoot, true) end

  local copied = 0
  for _, file in ipairs(FS:findFiles(srcRoot, '*', -1, true, false)) do
    local fileContent = readFile(file)
    local target = dstRoot .. file:sub(srcRoot:len() + 1)
    if fileContent and writeFile(target, fileContent) then
      copied = copied + 1
    else
      log('W', 'overhaul_world_maps', 'Failed to write map override file ' .. target)
    end
  end
  return copied
end

local function mountMapOverrides()
  if not FS:directoryExists(OVERRIDES_ROOT) then return false end
  if FS:isMounted(OVERRIDES_ROOT) then return true end
  if not FS:mountList({{srcPath = OVERRIDES_ROOT}}) then return false end
  if overhaul_career_career and overhaul_career_career.isActive() then
    guihooks.trigger('ChangeState', {state = 'play', params = {}})
  end
  return true
end

local function unmountMapOverrides()
  if FS:isMounted(OVERRIDES_ROOT) then return FS:unmount(OVERRIDES_ROOT) end
  return false
end

-- Removes everything in the overrides folder except levels/, which is the only part maps use.
local function clearNonLevelOverrides()
  if not FS:directoryExists(OVERRIDES_ROOT) then return end
  for _, entry in ipairs(FS:findFiles(OVERRIDES_ROOT, '*', 0, true, false)) do
    local entryName = entry:match("([^/]+)/?$")
    if entryName and entryName ~= "levels" then
      if FS:directoryExists(entry) then removeTree(entry) else FS:removeFile(entry) end
    end
  end
end

-- A map that now reports compatibility itself drops the copied overrides for its level.
local function handleMapOverrides(newMapsWithOverrides)
  if #newMapsWithOverrides == 0 then return true end
  local wasMounted = FS:isMounted(OVERRIDES_ROOT)
  if wasMounted then unmountMapOverrides() end
  clearNonLevelOverrides()
  for _, levelName in ipairs(newMapsWithOverrides) do
    removeTree(OVERRIDES_ROOT .. 'levels/' .. levelName .. '/')
  end
  if wasMounted then mountMapOverrides() end
  return true
end

local function getOptionalFeatureExtension(featureId)
  local metadata = getMapMetadata()
  local feature = metadata and metadata.optionalFeatures and metadata.optionalFeatures[featureId]
  return feature and feature.provider or nil
end

local function getOptionalFeatureConfig(featureId)
  local metadata = getMapMetadata()
  local feature = metadata and metadata.optionalFeatures and metadata.optionalFeatures[featureId]
  return feature and levelData.assetPath(metadata.id, feature.config) or nil
end

local function hasOptionalFeature(featureId)
  local extensionName = getOptionalFeatureExtension(featureId)
  if not extensionName then return false end
  local configPath = getOptionalFeatureConfig(featureId)
  if configPath and not FS:fileExists(configPath) then
    local key = getCurrentLevelIdentifier() .. ':' .. featureId
    if not unavailableProviders[key] then
      log('W', 'overhaul_world_maps', 'Optional feature ' .. featureId .. ' unavailable: config ' .. configPath .. ' is not installed')
      unavailableProviders[key] = true
    end
    return false
  end
  -- Indexing `extensions` tries to load a missing extension and logs it, so ask the loaded-state API instead.
  if extensions.isExtensionLoaded(extensionName) then return true end
  local extensionPath = '/lua/ge/extensions/' .. extensionName:gsub('_', '/') .. '.lua'
  if FS:fileExists(extensionPath) then return true end
  local key = getCurrentLevelIdentifier() .. ':' .. featureId
  if not unavailableProviders[key] then
    log('W', 'overhaul_world_maps', 'Optional feature ' .. featureId .. ' unavailable: provider ' .. extensionName .. ' is not installed')
    unavailableProviders[key] = true
  end
  return false
end

local function retrieveCompatibleMaps()
  levelData.invalidateCatalogs()
  compatibleMaps = {}
  unavailableProviders = {}
  mapMetadata = levelData.loadMaps()
  for id, metadata in pairs(mapMetadata) do
    if metadata.careerCompatible then
      if core_levels.getLevelByName(id) then
        compatibleMaps[id] = metadata.label
      else
        log('W', 'overhaul_world_maps', 'Career map is not installed: ' .. id)
      end
    end
  end
  extensions.hook('onGetMaps')
  guihooks.trigger('OverhaulMapCatalogChanged')
end

local function returnCompatibleMap(maps)
  local newMapsWithOverrides = {}

  for map, mapName in pairs(maps) do
    if not compatibleMaps[map] then
      compatibleMaps[map] = mapName

      local mapOverridePath = OVERRIDES_ROOT .. 'levels/' .. map
      if FS:directoryExists(mapOverridePath) then
        table.insert(newMapsWithOverrides, map)
      end
    end
  end

  handleMapOverrides(newMapsWithOverrides)
  guihooks.trigger('OverhaulMapCatalogChanged')
end

local function getCompatibleMaps()
  return compatibleMaps
end

local function getOtherAvailableMaps()
  local maps = {}
  local currentMap = getCurrentLevelIdentifier()
  for map, mapName in pairs(compatibleMaps) do
    if map ~= currentMap then
      maps[map] = mapName
    end
  end
  return maps
end

local function getMapsWithoutBuiltIn()
  local maps = {}
  for map, mapName in pairs(compatibleMaps) do
    if not (mapMetadata[map] and mapMetadata[map].builtIn) then
      maps[map] = mapName
    end
  end
  return maps
end

local function enableOverrides()
  if FS:isMounted(OVERRIDES_ROOT) then return true end
  removeTree(OVERRIDES_ROOT)
  copyFiles(MOD_OVERRIDES_DIR, OVERRIDES_ROOT)
  local mounted = mountMapOverrides()
  retrieveCompatibleMaps()
  return mounted
end

local function disableOverrides()
  unmountMapOverrides()
  removeTree(OVERRIDES_ROOT)
end

-- Overhaul is starting, travelling between maps or playing.
local function overhaulLevelPending()
  local career = rawget(_G, 'overhaul_career_career')
  if type(career) ~= 'table' then return false end
  if type(career.isActive) == 'function' and career.isActive() then return true end
  if type(career.isStarting) == 'function' and career.isStarting() then return true end
  local switch = type(career.getLevelSwitchState) == 'function' and career.getLevelSwitchState()
  return type(switch) == 'table' and switch.phase ~= nil and switch.phase ~= 'idle'
end

local function refreshOverrides()
  if overhaulLevelPending() then enableOverrides() else disableOverrides() end
end

-- A map loaded earlier can leave game-wide materials pointing at its own textures.
local function onClientPostStartMission()
  if overhaulLevelPending() then sharedMaterials.repair(getCurrentLevelIdentifier()) end
end

local function onFilesChanged(files)
  for _, file in ipairs(files or {}) do
    local filename = file.filename:gsub('\\', '/'):gsub('^/', '')
    if filename:find('gameplay/overhaul/maps/', 1, true) == 1
      or filename:find('gameplay/overhaul/save/locationAliases/', 1, true) == 1 then
      retrieveCompatibleMaps()
      return
    end
  end
end

M.enableOverrides = enableOverrides
M.disableOverrides = disableOverrides
M.handleMapOverrides = handleMapOverrides
M.returnCompatibleMap = returnCompatibleMap
M.getCompatibleMaps = getCompatibleMaps
M.getMapMetadata = getMapMetadata
M.getMapCatalog = getMapCatalog
M.getDefaultMap = getDefaultMap
M.resolveMapAsset = resolveMapAsset
M.retrieveCompatibleMaps = retrieveCompatibleMaps
M.getOtherAvailableMaps = getOtherAvailableMaps
M.getMapsWithoutBuiltIn = getMapsWithoutBuiltIn
M.hasOptionalFeature = hasOptionalFeature
M.getOptionalFeatureExtension = getOptionalFeatureExtension
M.getOptionalFeatureConfig = getOptionalFeatureConfig

M.onExtensionLoaded = retrieveCompatibleMaps
M.onOverhaulMapCatalogChanged = retrieveCompatibleMaps
M.onExtensionUnloaded = disableOverrides
M.onOverhaulSetProfile = function(savePath) if savePath then enableOverrides() end end
M.onOverhaulBeforeCareerActivate = enableOverrides
M.onOverhaulBeforeCareerLevelSwitch = enableOverrides
M.onClientPreStartMission = refreshOverrides
M.onClientEndMission = refreshOverrides
M.onClientPostStartMission = onClientPostStartMission
M.onSerialize = function() return {overrides = FS:isMounted(OVERRIDES_ROOT)} end
M.onDeserialized = function(data) if data and data.overrides then enableOverrides() end end
M.onModActivated = retrieveCompatibleMaps
M.onModDeactivated = function(modData)
  if modIdentity.isOwnMod(modData) then return end
  return retrieveCompatibleMaps()
end
M.onFilesChanged = onFilesChanged
M.onWorldReadyState = retrieveCompatibleMaps
M.onUiReady = retrieveCompatibleMaps

return M
