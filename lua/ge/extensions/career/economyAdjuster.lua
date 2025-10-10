local M = {}

local discoveredTypes = {}
local defaultTypeMultipliers = {}
local typeMultipliers = {}
local typeSources = {}
local isEnabled = true
local initialized = false

local function tableSize(tbl)
    if not tbl or type(tbl) ~= "table" then return 0 end
    local count = 0
    for _ in pairs(tbl) do
        count = count + 1
    end
    return count
end

local function discoverRaceTypes()
    local compatibleMaps = {}
    if overhaul_maps then
        compatibleMaps = overhaul_maps.getCompatibleMaps() or {}
    end

    local currentLevel = getCurrentLevelIdentifier()
    if currentLevel then
        compatibleMaps[currentLevel] = currentLevel
    end

    local raceTypesFound = {}

    for mapName, mapDisplayName in pairs(compatibleMaps) do
        local raceDataPath = string.format("/levels/%s/race_data.json", mapName)

        if FS:fileExists(raceDataPath) then
            local raceData = jsonReadFile(raceDataPath)
            if raceData and raceData.races then
                for raceName, raceInfo in pairs(raceData.races) do
                    if raceInfo.type and type(raceInfo.type) == "table" then
                        for _, raceType in ipairs(raceInfo.type) do
                            if type(raceType) == "string" then
                                raceTypesFound[raceType] = true
                                typeSources[raceType] = typeSources[raceType] or {}
                                typeSources[raceType]["freeroam_module"] = true
                                typeSources[raceType][string.format("race_%s", mapName)] = true
                            end
                        end
                    end
                end
            end
        end
    end

    return raceTypesFound
end

local function discoverActivityTypes()
    local activityTypesFound = {}

    if gameplay_taxi then
        activityTypesFound["taxi"] = true
        typeSources["taxi"] = typeSources["taxi"] or {}
        typeSources["taxi"]["taxi_module"] = true
        
        if gameplay_taxi.getPassengerTypes then
            local passengerTypes = gameplay_taxi.getPassengerTypes()
            if passengerTypes and type(passengerTypes) == "table" then
                for _, passengerType in ipairs(passengerTypes) do
                    if passengerType.key then
                        local passengerTypeKey = string.format("taxi_%s", passengerType.key:lower())
                        activityTypesFound[passengerTypeKey] = true
                        typeSources[passengerTypeKey] = typeSources[passengerTypeKey] or {}
                        typeSources[passengerTypeKey]["taxi_module"] = true
                    end
                end
            end
        end
    end

    -- Repo types
    if gameplay_repo then
        activityTypesFound["repo"] = true
        typeSources["repo"] = typeSources["repo"] or {}
        typeSources["repo"]["repo_module"] = true
    end

    local deliveryTypes = {"parcel", "vehicle", "trailer", "fluid", "dryBulk", "cement", "cash"}
    for _, deliveryType in ipairs(deliveryTypes) do
        activityTypesFound[string.format("delivery_%s", deliveryType)] = true
        typeSources[string.format("delivery_%s", deliveryType)] = typeSources[string.format("delivery_%s", deliveryType)] or {}
        typeSources[string.format("delivery_%s", deliveryType)]["delivery_module"] = true
    end

    -- Freeroam activities
    activityTypesFound["freeroam"] = true
    typeSources["freeroam"] = typeSources["freeroam"] or {}
    typeSources["freeroam"]["freeroam_module"] = true

    -- Police activities
    activityTypesFound["police"] = true
    typeSources["police"] = typeSources["police"] or {}
    typeSources["police"]["police_module"] = true

    activityTypesFound["criminal"] = true
    typeSources["criminal"] = typeSources["criminal"] or {}
    typeSources["criminal"]["criminal_module"] = true

    return activityTypesFound
end

-- Initialize all discovered types with default multipliers
local function initializeDiscoveredTypes()
    local raceTypes = discoverRaceTypes()
    for typeName, _ in pairs(raceTypes) do
        if not discoveredTypes[typeName] then
            discoveredTypes[typeName] = true
            defaultTypeMultipliers[typeName] = 1.0
            if typeMultipliers[typeName] == nil then
                typeMultipliers[typeName] = 1.0
            end
        end
    end

    local activityTypes = discoverActivityTypes()
    for typeName, _ in pairs(activityTypes) do
        if not discoveredTypes[typeName] then
            discoveredTypes[typeName] = true
            defaultTypeMultipliers[typeName] = 1.0
            if typeMultipliers[typeName] == nil then
                typeMultipliers[typeName] = 1.0
            end
        end
    end
end

local function loadMultipliers()
    if not career_career or not career_career.isActive() then
        typeMultipliers = deepcopy(defaultTypeMultipliers)
        return
    end

    local slot, path = career_saveSystem.getCurrentSaveSlot()
    if not path then
        typeMultipliers = deepcopy(defaultTypeMultipliers)
        return
    end

    local filePath = path .. "/career/rls_career/economyAdjuster.json"
    local data = jsonReadFile(filePath) or {}

    typeMultipliers = deepcopy(data.typeMultipliers or defaultTypeMultipliers)

    for typeName, defaultValue in pairs(defaultTypeMultipliers) do
        if typeMultipliers[typeName] == nil then
            typeMultipliers[typeName] = defaultValue
        end
    end

    if data.typeMultipliers then
        for typeName, savedValue in pairs(data.typeMultipliers) do
            if typeMultipliers[typeName] == nil then
                typeMultipliers[typeName] = savedValue
                discoveredTypes[typeName] = true
                print(string.format("Economy Adjuster: Preserving legacy type: %s", typeName))
            end
        end
    end

    isEnabled = data.enabled ~= false
    initialized = true
end

local function saveMultipliers(currentSavePath)
    if not career_career or not career_career.isActive() then return end
    if not initialized then return end

    if not currentSavePath then
        local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
        if not currentSavePath then return end
    end

    local dirPath = currentSavePath .. "/career/rls_career"
    if not FS:directoryExists(dirPath) then
        FS:directoryCreate(dirPath)
    end

    local data = {
        typeMultipliers = deepcopy(typeMultipliers),
        enabled = isEnabled,
        lastModified = os.time()
    }

    career_saveSystem.jsonWriteFileSafe(dirPath .. "/economyAdjuster.json", data, true)
end

local function calculateAdjustedReward(raceData, baseReward)
    if not raceData then
        return baseReward or 0
    end

    local multiplier = getEffectiveSectionMultiplier(raceData.type or {})
    local adjustedReward = (baseReward or raceData.reward or 0) * multiplier

    return math.floor(adjustedReward + 0.5)
end

local function setTypeMultiplier(typeName, multiplier)
    if not typeName then return false end

    multiplier = math.max(0, math.min(10, tonumber(multiplier) or 1.0))

    typeMultipliers[typeName] = multiplier
    saveMultipliers()
    print(string.format("Economy Adjuster: Set %s multiplier to %.2f", typeName, multiplier))
    return true
end

local function getTypeMultiplier(typeName)
    if not typeName then return 1.0 end
    return typeMultipliers[typeName] or 1.0
end

local function setAllTypeMultipliers(multipliers)
    if not multipliers or type(multipliers) ~= "table" then return false end

    for typeName, multiplier in pairs(multipliers) do
        if type(multiplier) == "number" then
            setTypeMultiplier(typeName, multiplier)
        end
    end

    return true
end

local function resetToDefaults()
    typeMultipliers = deepcopy(defaultTypeMultipliers)
    saveMultipliers()
    print("Economy Adjuster: Reset all multipliers to defaults")
    return true
end

local function setEnabled(enabled)
    isEnabled = enabled == true
    saveMultipliers()
    print(string.format("Economy Adjuster: %s", isEnabled and "Enabled" or "Disabled"))
    return true
end

local function enableOnlyTypes(enabledTypes)
    if not enabledTypes or type(enabledTypes) ~= "table" then return false end

    for typeName, _ in pairs(typeMultipliers) do
        typeMultipliers[typeName] = 0
    end

    for _, typeName in ipairs(enabledTypes) do
        if typeMultipliers[typeName] ~= nil then
            typeMultipliers[typeName] = 1.0
        end
    end

    saveMultipliers()
    print("Economy Adjuster: Enabled only types: " .. table.concat(enabledTypes, ", "))
    return true
end

local function disableTypes(disabledTypes)
    if not disabledTypes or type(disabledTypes) ~= "table" then return false end

    for _, typeName in ipairs(disabledTypes) do
        if typeMultipliers[typeName] ~= nil then
            typeMultipliers[typeName] = 0
        end
    end

    saveMultipliers()
    print("Economy Adjuster: Disabled types: " .. table.concat(disabledTypes, ", "))
    return true
end

local function getAvailableTypes()
    initializeDiscoveredTypes()
    
    local types = {}
    for typeName, _ in pairs(discoveredTypes) do
        table.insert(types, typeName)
    end
    table.sort(types)
    return types
end

local function getTypesBySource()
    initializeDiscoveredTypes()
    
    local bySource = {}
    for typeName, sources in pairs(typeSources) do
        for sourceName, _ in pairs(sources) do
            bySource[sourceName] = bySource[sourceName] or {}
            table.insert(bySource[sourceName], typeName)
        end
    end

    for sourceName, types in pairs(bySource) do
        table.sort(types)
    end

    return bySource
end

local function getConfigurationSummary()
    local summary = {
        enabled = isEnabled,
        multipliers = deepcopy(typeMultipliers),
        availableTypes = getAvailableTypes(),
        typesBySource = getTypesBySource(),
        discoveredTypes = tableSize(discoveredTypes)
    }
    return summary
end

local function printConfiguration()
    print("\n=== Economy Adjuster Configuration ===")
    print(string.format("System Enabled: %s", isEnabled and "Yes" or "No"))
    print(string.format("Total Discovered Types: %d", tableSize(discoveredTypes)))

    local typesBySource = getTypesBySource()
    for sourceName, types in pairs(typesBySource) do
        print(string.format("\n%s (%d types):", sourceName, #types))
        for _, typeName in ipairs(types) do
            local multiplier = typeMultipliers[typeName] or 1.0
            print(string.format("  %s: %.2f", typeName, multiplier))
        end
    end

    print("\n=== Quick Reference ===")
    print("Available types: " .. table.concat(getAvailableTypes(), ", "))
    print("=====================================\n")
end

local function getSectionMultiplier(sectionName)
    if not sectionName then return 1.0 end
    return typeMultipliers[sectionName] or 1.0
end

local function getSectionMultipliers(sections)
    if not sections or type(sections) ~= "table" then return {} end

    local multipliers = {}
    for _, sectionName in ipairs(sections) do
        multipliers[sectionName] = getSectionMultiplier(sectionName)
    end
    return multipliers
end

local function getEffectiveSectionMultiplier(sectionTypes)
    if not sectionTypes or type(sectionTypes) ~= "table" then
        return 1.0
    end

    if not isEnabled then
        return 1.0
    end

    local highestMultiplier = 0
    local hasEnabledType = false

    for _, sectionType in ipairs(sectionTypes) do
        local multiplier = getSectionMultiplier(sectionType)
        if multiplier > 0 then
            hasEnabledType = true
            if multiplier > highestMultiplier then
                highestMultiplier = multiplier
            end
        end
    end

    return hasEnabledType and highestMultiplier or 0
end

local function isSectionEnabled(sectionTypes)
    if not sectionTypes or type(sectionTypes) ~= "table" then
        return true
    end

    if not isEnabled then
        return true
    end

    for _, sectionType in ipairs(sectionTypes) do
        local multiplier = getSectionMultiplier(sectionType)
        if multiplier > 0 then
            return true
        end
    end

    return false
end

local function adjustRaceData(raceData)
    if not raceData then return raceData end

    local adjusted = deepcopy(raceData)
    local multiplier = getEffectiveSectionMultiplier(raceData.type or {})

    if multiplier == 0 then
        adjusted.disabled = true
        adjusted.adjustedReward = 0
    else
        adjusted.disabled = false
        adjusted.originalReward = adjusted.reward
        adjusted.adjustedReward = calculateAdjustedReward(raceData, adjusted.reward)
        adjusted.multiplier = multiplier
    end

    return adjusted
end

local function filterEnabledRaces(races)
    if not races then return {} end

    local enabledRaces = {}
    for raceName, raceData in pairs(races) do
        if isSectionEnabled(raceData.type or {}) then
            enabledRaces[raceName] = adjustRaceData(raceData)
        end
    end

    return enabledRaces
end

local function initialize()
    if initialized then return end

    initializeDiscoveredTypes()
    loadMultipliers()

    print("Economy Adjuster module initialized with " .. tableSize(discoveredTypes) .. " discovered types")
end

local function refreshDiscoveredTypes()
    print("Economy Adjuster: Refreshing discovered types...")
    initializeDiscoveredTypes()

    for typeName, _ in pairs(discoveredTypes) do
        if typeMultipliers[typeName] == nil then
            typeMultipliers[typeName] = 1.0
        end
    end

    saveMultipliers()
    print("Economy Adjuster: Refreshed types, now managing " .. tableSize(discoveredTypes) .. " total types")
end

local function onExtensionLoaded()
    initialize()
end

local function onSaveCurrentSaveSlot(currentSavePath)
    saveMultipliers(currentSavePath)
end

M.calculateAdjustedReward = calculateAdjustedReward
M.getSectionMultiplier = getSectionMultiplier
M.getSectionMultipliers = getSectionMultipliers
M.getEffectiveSectionMultiplier = getEffectiveSectionMultiplier
M.isSectionEnabled = isSectionEnabled
M.setTypeMultiplier = setTypeMultiplier
M.getTypeMultiplier = getTypeMultiplier
M.setAllTypeMultipliers = setAllTypeMultipliers
M.resetToDefaults = resetToDefaults
M.setEnabled = setEnabled
M.enableOnlyTypes = enableOnlyTypes
M.disableTypes = disableTypes
M.getAvailableTypes = getAvailableTypes
M.getTypesBySource = getTypesBySource
M.getConfigurationSummary = getConfigurationSummary
M.printConfiguration = printConfiguration
M.adjustRaceData = adjustRaceData
M.filterEnabledRaces = filterEnabledRaces
M.refreshDiscoveredTypes = refreshDiscoveredTypes
M.isEnabled = function() return isEnabled end
M.getTypeMultipliers = function() return deepcopy(typeMultipliers) end
M.getDiscoveredTypes = function() return deepcopy(discoveredTypes) end
M.getTypeSources = function() return deepcopy(typeSources) end
M.onExtensionLoaded = onExtensionLoaded
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

return M