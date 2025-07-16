local M = {}

local isDev = true
local levelsRoot = 'levels/'

local function getSettings()
    return rlsSettings.getSetting('mapDevMode')
end

local function clearLevels()
    local isDev = getSettings()
    if not isDev then
        if not FS:directoryExists(levelsRoot) then
            print("Levels directory does not exist")
            return
        end
        local maps = careerMaps.getCompatibleMaps()
        for map, mapName in pairs(maps) do
            if FS:directoryExists(levelsRoot .. map) then
                FS:directoryRemove(levelsRoot .. map)
            end
        end
    end
end

M.changeDevMode = function(devMode)
    isDev = devMode
end

M.onExtensionLoaded = clearLevels
M.clearLevels = clearLevels

return M