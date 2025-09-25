local M = {}

local logTag = 'overrideManager'

local overrides = {}
local originalLoad = nil
local originalReload = nil
local originalReloadUI = nil

local MOD_OVERRIDES_DIR = "/overrides/"
local LOCAL_OVERRIDEN_ROOT = "/overriden/"
local mountedRoot = false

local ourMod = nil

local function isExtensionFormat(path)
  return path:find('_') and not path:find('/')
end

local function convertFormat(path)
  if isExtensionFormat(path) then
    return path:gsub('_', '/')
  else
    return path:gsub('/', '_')
  end
end

local function setOverride(originalPath, overridePath, overrideType)
  if not originalPath or not overridePath then
    return false
  end

  if not overrideType then
    overrideType = isExtensionFormat(originalPath) and 'extension' or 'require'
  end

  local convertedPath = convertFormat(originalPath)
  local isExtensionType = (overrideType == 'extension')

  local originalPreload = package.preload[convertedPath]
  local entry = {
    override = overridePath,
    originalFormat = originalPath,
    convertedFormat = convertedPath,
    isExtension = isExtensionType,
    originalPreload = originalPreload
  }

  overrides[originalPath] = entry
  overrides[convertedPath] = entry

  package.preload[convertedPath] = function(...)
    if convertedPath:find('career_modules_') and (not career_career or not career_career.isActive()) then
      return nil
    end

    local success, result = pcall(require, overridePath)

    if not success then
      return nil
    end

    return result
  end

  local absolutePath = '/lua/ge/extensions/' .. convertedPath
  package.preload[absolutePath] = package.preload[convertedPath]

  return true
end

local function clearDirectory(dirPath)
  if FS:directoryExists(dirPath) then
    FS:remove(dirPath)
    return true
  end
  return false
end

local function clearOverride(originalPath)
  local entry = overrides[originalPath]
  if not entry then
    return false
  end

  overrides[entry.originalFormat] = nil
  overrides[entry.convertedFormat] = nil

  if entry.originalPreload then
    package.preload[entry.convertedFormat] = entry.originalPreload
  else
    package.preload[entry.convertedFormat] = nil
  end

  local absolutePath = '/lua/ge/extensions/' .. entry.convertedFormat
  package.preload[absolutePath] = nil

  log('I', logTag, 'Cleared override for: ' .. originalPath)
  return true
end

local function copyFiles(srcDir, dstDir, logMsg)
  if not FS:directoryExists(srcDir) then
    return 0
  end

  if not FS:directoryExists(dstDir) then
    FS:directoryCreate(dstDir, true)
  end

  local copied = 0
  local srcFiles = FS:findFiles(srcDir, '*', -1, true, false)
  for _, srcPath in ipairs(srcFiles) do
    local rel = srcPath:gsub("^" .. srcDir, "")
    if rel and rel ~= "" then
      local dstPath = dstDir .. rel
      local dstDir = dstPath:match("(.+)/[^/]+$")
      if dstDir and not FS:directoryExists(dstDir) then
        FS:directoryCreate(dstDir, true)
      end

      local doCopy = false
      local srcStat = FS:stat(srcPath)
      local dstExists = FS:fileExists(dstPath)
      if not dstExists then
        doCopy = true
      else
        local dstStat = FS:stat(dstPath)
        local srcTime = srcStat and srcStat.modtime or 0
        local dstTime = dstStat and dstStat.modtime or 0
        if srcTime > dstTime then
          doCopy = true
        end
      end

      if doCopy then
        local content = readFile(srcPath)
        if content and writeFile(dstPath, content) then
          copied = copied + 1
        end
      end
    end
  end

  return copied
end

local function applyUIOverrides()
  local uiSrcDir = MOD_OVERRIDES_DIR .. "ui/"
  local uiDstDir = "/ui/"

  local uiFiles = FS:findFiles(uiSrcDir, "*", -1, true, false)
  for _, srcFile in ipairs(uiFiles or {}) do
    local relPath = srcFile:gsub("^" .. uiSrcDir, "")
    if relPath ~= "" then
      local dstFile = uiDstDir .. relPath

      local dstDir = dstFile:match("(.+)/[^/]+$")
      if dstDir and not FS:directoryExists(dstDir) then
        FS:directoryCreate(dstDir, true)
      end

      FS:copyFile(srcFile, dstFile)
    end
  end
  return true
end

local function mountCustomOverrides()
  local copied = copyFiles(MOD_OVERRIDES_DIR, LOCAL_OVERRIDEN_ROOT)

  if not FS:directoryExists(LOCAL_OVERRIDEN_ROOT) then
    return false
  end

  if not FS:isMounted(LOCAL_OVERRIDEN_ROOT) then
    if FS:mount(LOCAL_OVERRIDEN_ROOT) then
      mountedRoot = true      

      if career_career and career_career.isActive() then
        guihooks.trigger('ChangeState', {
          state = 'play',
          params = {}
        })
      end
    else
      return false
    end
  else
    mountedRoot = true
  end
  return false
end

local function overrideLoad(...)
  local args = {...}
  local modifiedArgs = {}

  for _, arg in ipairs(args) do
    if type(arg) == 'string' then
      if arg:find('career_') == 1 and (not career_career or not career_career.isActive()) then
      else
        local entry = overrides[arg]
        if entry then
          table.insert(modifiedArgs, entry.override)
        else
          table.insert(modifiedArgs, arg)
        end
      end
    else
      table.insert(modifiedArgs, arg)
    end
  end

  return originalLoad(unpack(modifiedArgs))
end

local function overrideReload(extPath)
  if extPath:find('career_') == 1 and (not career_career or not career_career.isActive()) then
    return false
  end

  local entry = overrides[extPath]
  if entry then
    return originalReload(entry.override)
  else
    return originalReload(extPath)
  end
end

local function overrideReloadUI()
  applyUIOverrides()
  originalReloadUI()
end

local function installSystem()
  if originalLoad or originalReload or originalReloadUI then
    log('E', logTag, 'Override system already installed')
    return false
  end

  originalReloadUI = reloadUI
  if originalReloadUI then
    reloadUI = overrideReloadUI
    reloadUI()
  end

  originalLoad = extensions.load
  if originalLoad then
    extensions.load = overrideLoad
  end

  originalReload = extensions.reload
  if originalReload then
    extensions.reload = overrideReload
  end

  local overridesDir = '/lua/ge/extensions/overrides/'
  local luaFiles = FS:findFiles(overridesDir, '*.lua', -1, true, false)

  local overrideCount = 0
  if luaFiles and #luaFiles > 0 then
    for _, overrideFile in ipairs(luaFiles) do
      local modulePath = overrideFile:gsub('^/lua/ge/extensions/', 'lua.ge.extensions.'):gsub('%.lua$', ''):gsub('/',
        '.')
      local originalPath = modulePath:gsub('%.overrides%.', '.')
      local extensionPath = originalPath:gsub('lua%.ge%.extensions%.', ''):gsub('%.', '_')

      if setOverride(extensionPath, modulePath) then
        overrideCount = overrideCount + 1
      end
    end
  end

  clearDirectory(LOCAL_OVERRIDEN_ROOT)
  mountCustomOverrides()

  return true
end

local function unmountCustomOverrides()
  if FS:unmount(LOCAL_OVERRIDEN_ROOT) then
    mountedRoot = false
    return true
  end
  return false
end

local function clearNonLevelOverrides()
  if not FS:directoryExists(LOCAL_OVERRIDEN_ROOT) then
    return
  end

  local entries = FS:findFiles(LOCAL_OVERRIDEN_ROOT, '*', 0, true, false)
  for _, entry in ipairs(entries) do
    local entryName = entry:match("([^/]+)$")
    if entryName and entryName ~= "levels" then
      FS:remove(entry)
    end
  end
end

local function handleMapOverrides(newMapsWithOverrides)
  if #newMapsWithOverrides == 0 then
    return true
  end

  local wasMount = FS:isMounted(LOCAL_OVERRIDEN_ROOT)
  if wasMount then
    unmountCustomOverrides()
  end
  clearNonLevelOverrides()

  for _, levelName in ipairs(newMapsWithOverrides) do
    clearDirectory(LOCAL_OVERRIDEN_ROOT .. "levels/" .. levelName)
  end

  if wasMount then
    mountCustomOverrides()
  end
  return true
end

local function unloadOverrides()
  if not originalLoad then
    return false
  end

  reloadUI = originalReloadUI
  originalReloadUI = nil

  extensions.load = originalLoad
  originalLoad = nil

  extensions.reload = originalReload
  originalReload = nil

  local pathsToClear = {}
  for path, _ in pairs(overrides) do
    table.insert(pathsToClear, path)
  end

  for _, path in ipairs(pathsToClear) do
    clearOverride(path)
  end

  unmountCustomOverrides()

  loadManualUnloadExtensions()
  reloadUI()

  return true
end

local function onModDeactivated(modData)
  if not ourMod then
    return
  end

  if (ourMod.name and modData.modname == ourMod.name) or
    (ourMod.id and modData.modData and modData.modData.tagid == ourMod.id) then
    unloadOverrides()
  end
end

local function onExtensionLoaded()
  ourMod = overhaul_extensionManager.getModData()
  installSystem()
end

M.onUIInitialised = function()
  clearDirectory("/ui/")
end

M.onExtensionLoaded = onExtensionLoaded
M.onModDeactivated = onModDeactivated

M.handleMapOverrides = handleMapOverrides

return M
