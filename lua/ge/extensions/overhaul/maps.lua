local M = {}

local compatibleMaps = {
    ["west_coast_usa"] = "West Coast USA"
}

local MOD_OVERRIDES_DIR = "/overrides/"
local LOCAL_OVERRIDEN_ROOT = "/overriden/"
local mountedLevels = {}
local mountedRoot = false

local function retrieveCompatibleMaps()
    compatibleMaps = {
        ["west_coast_usa"] = "West Coast USA"
    }
    extensions.hook("onGetMaps")
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

local function clearDirectory(dirPath, logMsg)
    if FS:directoryExists(dirPath) then
        FS:remove(dirPath)
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

local function mountCustomOverrides()
    local copied = copyFiles(MOD_OVERRIDES_DIR, LOCAL_OVERRIDEN_ROOT)

    if not FS:directoryExists(LOCAL_OVERRIDEN_ROOT) then
        return false
    end

    if not FS:isMounted(LOCAL_OVERRIDEN_ROOT) then
        if FS:mount(LOCAL_OVERRIDEN_ROOT) then
            mountedRoot = true
        else
            return false
        end
    else
        mountedRoot = true
    end
    return false
end

local function unmountCustomOverrides()
    if FS:isMounted(LOCAL_OVERRIDEN_ROOT) then
        if FS:unmount(LOCAL_OVERRIDEN_ROOT) then
            mountedLevels = {}
            mountedRoot = false
            return true
        end
    end
    return false
end

local function removeLevelFromOverride(levelName)
    local levelPath = LOCAL_OVERRIDEN_ROOT .. "levels/" .. levelName
    if FS:directoryExists(levelPath) then
        FS:remove(levelPath)
        mountedLevels[levelName] = nil
        return true
    end
    return false
end

local function returnCompatibleMap(maps)
    local newMapsWithOverrides = {}

    for map, mapName in pairs(maps) do
        if not compatibleMaps[map] then
            compatibleMaps[map] = mapName

            local mapOverridePath = MOD_OVERRIDES_DIR .. "levels/" .. map
            if FS:directoryExists(mapOverridePath) then
                table.insert(newMapsWithOverrides, map)
            end
        end
    end

    if #newMapsWithOverrides > 0 then
        local wasMount = FS:isMounted(LOCAL_OVERRIDEN_ROOT)
        if wasMount then
            unmountCustomOverrides()
        end

        clearNonLevelOverrides()

        for _, levelName in ipairs(newMapsWithOverrides) do
            removeLevelFromOverride(levelName)
            copyFiles(MOD_OVERRIDES_DIR .. "levels/" .. levelName, LOCAL_OVERRIDEN_ROOT .. "levels/" .. levelName)
        end

        copyFiles(MOD_OVERRIDES_DIR, LOCAL_OVERRIDEN_ROOT)

        if wasMount then
            mountCustomOverrides()
        end
    end
end

local function onExtensionLoaded()
    retrieveCompatibleMaps()

    for map, _ in pairs(compatibleMaps) do
        removeLevelFromOverride(map)
    end
    clearNonLevelOverrides()
    
    mountCustomOverrides()
end

M.onExtensionLoaded = onExtensionLoaded
M.onModActivated = retrieveCompatibleMaps
M.onWorldReadyState = retrieveCompatibleMaps

M.returnCompatibleMap = returnCompatibleMap
M.getCompatibleMaps = function() return compatibleMaps end
M.getOtherAvailableMaps = function()
    local maps = {}
    local currentMap = getCurrentLevelIdentifier()
    for map, mapName in pairs(compatibleMaps) do
        if map ~= currentMap then
            maps[map] = mapName
        end
    end
    return maps
end

M.mountCustomOverrides = mountCustomOverrides
M.unmountCustomOverrides = unmountCustomOverrides
M.removeLevelFromOverride = removeLevelFromOverride

return M