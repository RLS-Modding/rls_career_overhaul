local M = {}

local compatibleMaps = {
  ["west_coast_usa"] = "West Coast USA"
}

local function retrieveCompatibleMaps()
  compatibleMaps = {
    ["west_coast_usa"] = "West Coast USA"
  }
  extensions.hook("onGetMaps")
end

local function returnCompatibleMap(maps)
  local newMapsWithOverrides = {}

  for map, mapName in pairs(maps) do
    if not compatibleMaps[map] then
      compatibleMaps[map] = mapName

      local mapOverridePath = "/overriden/levels/" .. map
      if FS:directoryExists(mapOverridePath) then
        table.insert(newMapsWithOverrides, map)
      end
    end
  end

  overhaul_overrideManager.handleMapOverrides(newMapsWithOverrides)
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
  
  local function getCompatibleMaps()
    return compatibleMaps
  end

local function getMapsExcludingWestCoast()
  local maps = {}
  for map, mapName in pairs(compatibleMaps) do
    if map ~= "west_coast_usa" then
      maps[map] = mapName
    end
  end
  return maps
end

local function onExtensionLoaded()
  retrieveCompatibleMaps()
end

M.onExtensionLoaded = onExtensionLoaded
M.onModActivated = retrieveCompatibleMaps
M.onWorldReadyState = retrieveCompatibleMaps
M.onUiReady = retrieveCompatibleMaps

M.returnCompatibleMap = returnCompatibleMap
M.getCompatibleMaps = getCompatibleMaps
M.getOtherAvailableMaps = getOtherAvailableMaps
M.getMapsExcludingWestCoast = getMapsExcludingWestCoast

return M