local M = {}


M.dependencies = {'career_career'}

local function switchMap(levelName)
    local currentLevel = getCurrentLevelIdentifier()
    if currentLevel == levelName then return end
    gameplay_parking.resetAll()
    career_career.switchCareerLevel(levelName)
end

local function isOverhaulAddonActive(levelName)
    local mods = core_modmanager.getMods()
    for modName, modData in pairs(mods) do
        local OverhaulAddon = "rls_career_overhaul_" .. levelName
        print(OverhaulAddon)
        print(modName:lower():find(OverhaulAddon))
        if modName:lower():find(OverhaulAddon) and modData.active then
            return true
        end
    end
    return false
end

local function onBeamNGTrigger(data)
    if be:getPlayerVehicleID(0) ~= data.subjectID then
        return
    end
    if gameplay_walk.isWalking() then return end
    if career_career.isActive() and not career_modules_inventory.getInventoryIdFromVehicleId(data.subjectID) then return end
    if data.event ~= "exit" then
        return
    end
    local triggerName = data.triggerName
    
    if triggerName:match("^switchTo_") or triggerName:match("^switchMaps") then
        simTimeAuthority.pause(true)
        guihooks.trigger('ChangeState', {state = 'level-switch'})
        return
    end
end

local function onExtensionLoaded()
    print("Switch Map Extension Loaded")
end

function M.onGetRawPoiListForLevel(levelIdentifier, elements)
    -- Find any object with switchTo_ prefix by checking available maps
    local switchToObj = nil
    
    -- Look for any switchTo_ object from the available maps
    switchToObj = scenetree.findObject("switchMaps")
    if not switchToObj then
        for level, levelName in pairs(careerMaps.getOtherAvailableMaps()) do
            local obj = scenetree.findObject("switchTo_" .. level)
            if obj then
                switchToObj = obj
                break
            end
        end
    end
    
    if not switchToObj then return end
    
    local pos = switchToObj:getPosition()
    if not pos then return end
    
    -- Create description listing all available maps
    local description = "Available maps to switch to:\n"
    local mapCount = 0
    for level, levelName in pairs(careerMaps.getOtherAvailableMaps(levelIdentifier)) do
        description = description .. "• " .. levelName .. "\n"
        mapCount = mapCount + 1
    end
    
    if mapCount > 0 then
        local preview = "/levels/" .. levelIdentifier .. "/facilities/switchMap.jpg"
        
        local poi = {
            id = "map_switcher",
            data = {
                type = "travel",
                facility = {}
            },
            markerInfo = {
                bigmapMarker = {
                    pos = pos,
                    icon = "poi_fasttravel_round_orange_green",
                    name = "Map Switcher",
                    description = description,
                    previews = {preview},
                    thumbnail = preview
                }
            }
        }

        dump(poi)
        
        table.insert(elements, poi)
    end
end

M.switchMap = switchMap
M.onBeamNGTrigger = onBeamNGTrigger
M.onWorldReadyState = onWorldReadyState
M.onExtensionLoaded = onExtensionLoaded

return M