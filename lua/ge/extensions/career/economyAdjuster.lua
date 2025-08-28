local M = {}

-- ================================
-- DYNAMIC ECONOMY ADJUSTER MODULE
-- ================================
-- This module automatically discovers and manages economy multipliers for all race types
-- and activity categories across all career maps and activities.

-- ================================
-- DYNAMIC TYPE DISCOVERY
-- ================================

-- Discovered types from all sources
local discoveredTypes = {}
local defaultTypeMultipliers = {}
local typeMultipliers = {}
local typeSources = {} -- Track where each type comes from

-- ================================
-- TYPE DISCOVERY FUNCTIONS
-- ================================

-- Discover race types from all career maps
local function discoverRaceTypes()
    print("Economy Adjuster: Discovering race types from career maps...")

    -- Get all compatible maps from careerMaps module
    local compatibleMaps = {}
    if careerMaps then
        compatibleMaps = careerMaps.getCompatibleMaps() or {}
    end

    -- Always include current level
    local currentLevel = getCurrentLevelIdentifier()
    if currentLevel then
        compatibleMaps[currentLevel] = currentLevel
    end

    local raceTypesFound = {}

    -- Check each map for race_data.json
    for mapName, mapDisplayName in pairs(compatibleMaps) do
        local raceDataPath = string.format("/levels/%s/race_data.json", mapName)

        if FS:fileExists(raceDataPath) then
            local raceData = jsonReadFile(raceDataPath)
            if raceData and raceData.races then
                print(string.format("  Scanning %s (%s)...", mapDisplayName, mapName))

                for raceName, raceInfo in pairs(raceData.races) do
                    if raceInfo.type and type(raceInfo.type) == "table" then
                        for _, raceType in ipairs(raceInfo.type) do
                            if type(raceType) == "string" then
                                raceTypesFound[raceType] = true
                                typeSources[raceType] = typeSources[raceType] or {}
                                typeSources[raceType][string.format("race_%s", mapName)] = true
                            end
                        end
                    end
                end
            end
        end
    end

    print(string.format("Economy Adjuster: Found %d race types", tableSize(raceTypesFound)))
    return raceTypesFound
end

-- Discover activity types from various modules
local function discoverActivityTypes()
    print("Economy Adjuster: Discovering activity types from modules...")

    local activityTypesFound = {}

    -- Taxi types - discover individual passenger types
    if gameplay_taxi then
        -- Also check for passenger types in taxi
        if gameplay_taxi.getPassengerTypes then
            local passengerTypes = gameplay_taxi.getPassengerTypes()
            if passengerTypes and type(passengerTypes) == "table" then
                for _, passengerType in ipairs(passengerTypes) do
                    if passengerType.key then
                        local passengerTypeKey = string.format("taxi_%s", passengerType.key:lower())
                        activityTypesFound[passengerTypeKey] = true
                        typeSources[passengerTypeKey] = typeSources[passengerTypeKey] or {}
                        typeSources[passengerTypeKey]["taxi_passenger"] = true
                        print(string.format("Economy Adjuster: Discovered taxi passenger type: %s (%s)", passengerType.name, passengerTypeKey))
                    end
                end
            end
        end

        -- Only add generic "taxi" if no specific passenger types found
        if not next(typeSources) or not typeSources["taxi_business"] then
            activityTypesFound["taxi"] = true
            typeSources["taxi"] = typeSources["taxi"] or {}
            typeSources["taxi"]["taxi_module"] = true
        end
    end

    -- Repo types
    if gameplay_repo then
        activityTypesFound["repo"] = true
        typeSources["repo"] = typeSources["repo"] or {}
        typeSources["repo"]["repo_module"] = true
    end

    -- Delivery types (from milestones data)
    if career_modules_delivery_progress then
        local deliveryTypes = {"parcel", "vehicle", "trailer", "fluid", "dryBulk", "cement", "cash"}
        for _, deliveryType in ipairs(deliveryTypes) do
            activityTypesFound[string.format("delivery_%s", deliveryType)] = true
            typeSources[string.format("delivery_%s", deliveryType)] = typeSources[string.format("delivery_%s", deliveryType)] or {}
            typeSources[string.format("delivery_%s", deliveryType)]["delivery_module"] = true
        end
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

    print(string.format("Economy Adjuster: Found %d activity types", tableSize(activityTypesFound)))
    return activityTypesFound
end

-- Initialize all discovered types with default multipliers
local function initializeDiscoveredTypes()
    print("Economy Adjuster: Initializing discovered types...")

    discoveredTypes = {}

    -- Discover race types
    local raceTypes = discoverRaceTypes()
    for typeName, _ in pairs(raceTypes) do
        discoveredTypes[typeName] = true
        defaultTypeMultipliers[typeName] = 1.0
    end

    -- Discover activity types
    local activityTypes = discoverActivityTypes()
    for typeName, _ in pairs(activityTypes) do
        discoveredTypes[typeName] = true
        defaultTypeMultipliers[typeName] = 1.0
    end

    print(string.format("Economy Adjuster: Total discovered types: %d", tableSize(discoveredTypes)))
end

-- Save data structure
local saveDataTemplate = {
    typeMultipliers = {},
    enabled = true,
    lastModified = 0
}

-- ================================
-- STATE VARIABLES
-- ================================
local typeMultipliers = {}
local isEnabled = true
local initialized = false

-- ================================
-- UTILITY FUNCTIONS
-- ================================

-- Get table size (number of key-value pairs)
local function tableSize(tbl)
    if not tbl or type(tbl) ~= "table" then return 0 end
    local count = 0
    for _ in pairs(tbl) do
        count = count + 1
    end
    return count
end

-- Deep copy a table
local function deepCopy(original)
    local copy = {}
    for k, v in pairs(original) do
        if type(v) == "table" then
            copy[k] = deepCopy(v)
        else
            copy[k] = v
        end
    end
    return copy
end

-- Load multipliers from save data
local function loadMultipliers()
    if not career_career or not career_career.isActive() then
        -- Use defaults if not in career mode
        typeMultipliers = deepCopy(defaultTypeMultipliers)
        return
    end

    local slot, path = career_saveSystem.getCurrentSaveSlot()
    if not path then
        typeMultipliers = deepCopy(defaultTypeMultipliers)
        return
    end

    local filePath = path .. "/career/rls_career/economyAdjuster.json"
    local data = jsonReadFile(filePath) or {}

    -- Load multipliers or use defaults
    typeMultipliers = deepCopy(data.typeMultipliers or defaultTypeMultipliers)

    -- Ensure all discovered types are present (for new types discovered later)
    for typeName, defaultValue in pairs(defaultTypeMultipliers) do
        if typeMultipliers[typeName] == nil then
            typeMultipliers[typeName] = defaultValue
        end
    end

    -- Also ensure saved types that are no longer discovered still exist (for backwards compatibility)
    if data.typeMultipliers then
        for typeName, savedValue in pairs(data.typeMultipliers) do
            if typeMultipliers[typeName] == nil then
                typeMultipliers[typeName] = savedValue
                discoveredTypes[typeName] = true -- Keep legacy types
                print(string.format("Economy Adjuster: Preserving legacy type: %s", typeName))
            end
        end
    end

    isEnabled = data.enabled ~= false -- Default to true
    initialized = true
end

-- Save multipliers to career save
local function saveMultipliers()
    if not career_career or not career_career.isActive() then return end
    if not initialized then return end

    local slot, path = career_saveSystem.getCurrentSaveSlot()
    if not path then return end

    local dirPath = path .. "/career/rls_career"
    if not FS:directoryExists(dirPath) then
        FS:directoryCreate(dirPath)
    end

    local data = {
        typeMultipliers = deepCopy(typeMultipliers),
        enabled = isEnabled,
        lastModified = os.time()
    }

    career_saveSystem.jsonWriteFileSafe(dirPath .. "/economyAdjuster.json", data, true)
end

-- ================================
-- CORE FUNCTIONS
-- ================================

-- Calculate adjusted reward for a race
local function calculateAdjustedReward(raceData, baseReward)
    if not raceData then
        return baseReward or 0
    end

    local multiplier = getEffectiveSectionMultiplier(raceData.type or {})
    local adjustedReward = (baseReward or raceData.reward or 0) * multiplier

    return math.floor(adjustedReward + 0.5) -- Round to nearest integer
end

-- ================================
-- CONFIGURATION FUNCTIONS
-- ================================

-- Set multiplier for a specific type
local function setTypeMultiplier(typeName, multiplier)
    if not typeName then return false end

    -- Ensure multiplier is a valid number between 0 and 10
    multiplier = math.max(0, math.min(10, tonumber(multiplier) or 1.0))

    typeMultipliers[typeName] = multiplier
    saveMultipliers()
    print(string.format("Economy Adjuster: Set %s multiplier to %.2f", typeName, multiplier))
    return true
end

-- Get multiplier for a specific type
local function getTypeMultiplier(typeName)
    if not typeName then return 1.0 end
    return typeMultipliers[typeName] or 1.0
end

-- Set all type multipliers at once
local function setAllTypeMultipliers(multipliers)
    if not multipliers or type(multipliers) ~= "table" then return false end

    for typeName, multiplier in pairs(multipliers) do
        if type(multiplier) == "number" then
            setTypeMultiplier(typeName, multiplier)
        end
    end

    return true
end

-- Reset all multipliers to defaults
local function resetToDefaults()
    typeMultipliers = deepCopy(defaultTypeMultipliers)
    saveMultipliers()
    print("Economy Adjuster: Reset all multipliers to defaults")
    return true
end

-- Enable or disable the economy adjuster system
local function setEnabled(enabled)
    isEnabled = enabled == true
    saveMultipliers()
    print(string.format("Economy Adjuster: %s", isEnabled and "Enabled" or "Disabled"))
    return true
end

-- ================================
-- BATCH OPERATIONS
-- ================================

-- Enable only specific types, disable all others
local function enableOnlyTypes(enabledTypes)
    if not enabledTypes or type(enabledTypes) ~= "table" then return false end

    -- First, set all multipliers to 0
    for typeName, _ in pairs(typeMultipliers) do
        typeMultipliers[typeName] = 0
    end

    -- Then enable the specified types
    for _, typeName in ipairs(enabledTypes) do
        if typeMultipliers[typeName] ~= nil then
            typeMultipliers[typeName] = 1.0
        end
    end

    saveMultipliers()
    print("Economy Adjuster: Enabled only types: " .. table.concat(enabledTypes, ", "))
    return true
end

-- Disable specific types (set to 0)
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

-- ================================
-- UTILITY FUNCTIONS
-- ================================

-- Get all available type names (sorted)
local function getAvailableTypes()
    local types = {}
    for typeName, _ in pairs(discoveredTypes) do
        table.insert(types, typeName)
    end
    table.sort(types)
    return types
end

-- Get types grouped by source
local function getTypesBySource()
    local bySource = {}
    for typeName, sources in pairs(typeSources) do
        for sourceName, _ in pairs(sources) do
            bySource[sourceName] = bySource[sourceName] or {}
            table.insert(bySource[sourceName], typeName)
        end
    end

    -- Sort types within each source
    for sourceName, types in pairs(bySource) do
        table.sort(types)
    end

    return bySource
end

-- Get current configuration summary
local function getConfigurationSummary()
    local summary = {
        enabled = isEnabled,
        multipliers = deepCopy(typeMultipliers),
        availableTypes = getAvailableTypes(),
        typesBySource = getTypesBySource(),
        discoveredTypes = tableSize(discoveredTypes)
    }
    return summary
end

-- Print current configuration with detailed type information
local function printConfiguration()
    print("\n=== Economy Adjuster Configuration ===")
    print(string.format("System Enabled: %s", isEnabled and "Yes" or "No"))
    print(string.format("Total Discovered Types: %d", tableSize(discoveredTypes)))

    -- Print types by source
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

-- ================================
-- SECTION MULTIPLIER FUNCTIONS
-- ================================

-- Get the current multiplier for a specific section/type
local function getSectionMultiplier(sectionName)
    if not sectionName then return 1.0 end
    return typeMultipliers[sectionName] or 1.0
end

-- Get multipliers for multiple sections at once
local function getSectionMultipliers(sections)
    if not sections or type(sections) ~= "table" then return {} end

    local multipliers = {}
    for _, sectionName in ipairs(sections) do
        multipliers[sectionName] = getSectionMultiplier(sectionName)
    end
    return multipliers
end

-- Calculate effective multiplier for a race/activity with multiple types
local function getEffectiveSectionMultiplier(sectionTypes)
    if not sectionTypes or type(sectionTypes) ~= "table" then
        return 1.0
    end

    if not isEnabled then
        return 1.0
    end

    local highestMultiplier = 0
    local hasEnabledType = false

    -- Check each type in the section's type array
    for _, sectionType in ipairs(sectionTypes) do
        local multiplier = getSectionMultiplier(sectionType)
        if multiplier > 0 then
            hasEnabledType = true
            if multiplier > highestMultiplier then
                highestMultiplier = multiplier
            end
        end
    end

    -- If no types are enabled, return 0 to disable the section
    -- Otherwise return the highest multiplier found
    return hasEnabledType and highestMultiplier or 0
end

-- Check if a section is enabled (has at least one type with multiplier > 0)
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

-- ================================
-- RACE DATA INTEGRATION
-- ================================

-- Adjust race data based on current multipliers
local function adjustRaceData(raceData)
    if not raceData then return raceData end

    local adjusted = deepCopy(raceData)
    local multiplier = getEffectiveSectionMultiplier(raceData.type or {})

    if multiplier == 0 then
        -- Race is disabled
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

-- Filter race list to only include enabled races
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

-- ================================
-- INITIALIZATION
-- ================================

local function initialize()
    if initialized then return end

    -- Discover all types first
    initializeDiscoveredTypes()

    -- Load multipliers (will use discovered types as defaults)
    loadMultipliers()

    print("Economy Adjuster module initialized with " .. tableSize(discoveredTypes) .. " discovered types")
end

-- Refresh discovered types (useful if new maps or modules are loaded)
local function refreshDiscoveredTypes()
    print("Economy Adjuster: Refreshing discovered types...")
    initializeDiscoveredTypes()

    -- Ensure all newly discovered types have multipliers
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
    saveMultipliers()
end



-- ================================
-- MODULE EXPORTS
-- ================================

-- Core functionality
M.calculateAdjustedReward = calculateAdjustedReward

-- Section multiplier functions (main API)
M.getSectionMultiplier = getSectionMultiplier
M.getSectionMultipliers = getSectionMultipliers
M.getEffectiveSectionMultiplier = getEffectiveSectionMultiplier
M.isSectionEnabled = isSectionEnabled

-- Configuration
M.setTypeMultiplier = setTypeMultiplier
M.getTypeMultiplier = getTypeMultiplier
M.setAllTypeMultipliers = setAllTypeMultipliers
M.resetToDefaults = resetToDefaults
M.setEnabled = setEnabled

-- Batch operations
M.enableOnlyTypes = enableOnlyTypes
M.disableTypes = disableTypes

-- Utility
M.getAvailableTypes = getAvailableTypes
M.getTypesBySource = getTypesBySource
M.getConfigurationSummary = getConfigurationSummary
M.printConfiguration = printConfiguration

-- Race data integration
M.adjustRaceData = adjustRaceData
M.filterEnabledRaces = filterEnabledRaces

-- Discovery and refresh
M.refreshDiscoveredTypes = refreshDiscoveredTypes

-- State
M.isEnabled = function() return isEnabled end
M.getTypeMultipliers = function() return deepCopy(typeMultipliers) end
M.getDiscoveredTypes = function() return deepCopy(discoveredTypes) end
M.getTypeSources = function() return deepCopy(typeSources) end

-- Test function for individual passenger type multipliers
M.testPassengerTypeMultipliers = function()
    print("\n=== TESTING INDIVIDUAL PASSENGER TYPE MULTIPLIERS ===")

    -- First refresh to discover all passenger types
    refreshDiscoveredTypes()

    -- Get all available passenger types from taxi system
    local passengerTypes = {}
    if gameplay_taxi and gameplay_taxi.getPassengerTypes then
        passengerTypes = gameplay_taxi.getPassengerTypes() or {}
    end

    if #passengerTypes == 0 then
        print("❌ No passenger types found")
        return false
    end

    print(string.format("✅ Found %d passenger types:", #passengerTypes))

    -- Test each passenger type with different multipliers
    local testMultipliers = {0.5, 0.8, 1.0, 1.2, 1.5}

    for _, passengerType in ipairs(passengerTypes) do
        local passengerTypeKey = string.format("taxi_%s", passengerType.key:lower())
        print(string.format("\n--- Testing %s (%s) ---", passengerType.name, passengerTypeKey))

        for _, mult in ipairs(testMultipliers) do
            -- Set the multiplier for this specific passenger type
            setTypeMultiplier(passengerTypeKey, mult)

            -- Calculate what the fare would be with this multiplier
            local baseMultiplier = passengerType.baseMultiplier or 1.0
            local totalMultiplier = baseMultiplier * mult

            print(string.format("  Economy %.1fx: passenger %.1fx × economy %.1fx = %.1fx total",
                mult, baseMultiplier, mult, totalMultiplier))
        end

        -- Reset to default
        setTypeMultiplier(passengerTypeKey, 1.0)
    end

    print("\n=== INDIVIDUAL PASSENGER TYPE MULTIPLIERS TEST COMPLETE ===")
    print("💡 Each passenger type can now have its own economy multiplier!")
    print("   Examples: taxi_business, taxi_family, taxi_vip, etc.")
    return true
end

-- Lifecycle
M.onExtensionLoaded = onExtensionLoaded
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

return M