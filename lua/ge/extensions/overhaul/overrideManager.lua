local M = {}

local logTag = 'overrideManager'

local overrides = {}
local originalLoad = nil
local originalReload = nil

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

function M.setOverride(originalPath, overridePath, overrideType)
  if not originalPath or not overridePath then
    return false
  end

  -- Auto-detect if not specified
  if not overrideType then
    overrideType = isExtensionFormat(originalPath) and 'extension' or 'require'
  end

  local convertedPath = convertFormat(originalPath)
  local isExtensionType = (overrideType == 'extension')

  -- Store both formats in unified table
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

  -- Set up package.preload for require interception
  package.preload[convertedPath] = function(...)
    -- Check if this is a career module being accessed when career is not active
    if convertedPath:find('career_modules_') and (not career_career or not career_career.isActive()) then
      return nil
    end

    local success, result = pcall(require, overridePath)

    if not success then
      return nil
    end

    return result
  end

  return true
end

function M.clearOverride(originalPath)
  local entry = overrides[originalPath]
  if not entry then return false end

  -- Clear both format entries
  overrides[entry.originalFormat] = nil
  overrides[entry.convertedFormat] = nil

  -- Restore original preload if it existed
  if entry.originalPreload then
    package.preload[entry.convertedFormat] = entry.originalPreload
  else
    package.preload[entry.convertedFormat] = nil
  end

  log('I', logTag, 'Cleared override for: ' .. originalPath)
  return true
end

function M.getOverride(originalPath)
  local entry = overrides[originalPath]
  if not entry then return nil end

  return {
    type = entry.isExtension and 'extension' or 'require',
    override = entry.override,
    originalFormat = entry.originalFormat,
    convertedFormat = entry.convertedFormat
  }
end

function M.listOverrides()
  local result = {}
  local seen = {}

  for path, entry in pairs(overrides) do
    if not seen[entry] then
      seen[entry] = true
      table.insert(result, {
        original = entry.originalFormat,
        override = entry.override,
        type = entry.isExtension and 'extension' or 'require'
      })
    end
  end

  return result
end

function M.installSystem()
  if originalLoad then
    return false
  end

  originalLoad = extensions.load
  originalReload = extensions.reload

  extensions.load = function(...)
    local args = {...}
    local modifiedArgs = {}

    for _, arg in ipairs(args) do
      if type(arg) == 'string' then
        -- Check if this is a career extension being loaded when career is not active
        if arg:find('career_') == 1 and (not career_career or not career_career.isActive()) then
          -- Skip career extensions when career is not active
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

  extensions.reload = function(extPath)
    -- Check if this is a career extension being reloaded when career is not active
    if extPath:find('career_') == 1 and (not career_career or not career_career.isActive()) then
      return false -- Don't reload career extensions when career is not active
    end

    local entry = overrides[extPath]
    if entry then
      return originalReload(entry.override)
    else
      return originalReload(extPath)
    end
  end

  return true
end

function M.onExtensionUnloaded()
  if not originalLoad then
    return false
  end

  extensions.load = originalLoad
  extensions.reload = originalReload
  originalLoad = nil
  originalReload = nil

  -- Clear all overrides
  local pathsToClear = {}
  for path, _ in pairs(overrides) do
    table.insert(pathsToClear, path)
  end

  for _, path in ipairs(pathsToClear) do
    M.clearOverride(path)
  end

  return true
end

return M
