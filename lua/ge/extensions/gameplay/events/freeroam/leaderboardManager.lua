local M = {}

local leaderboardFile = "career/rls_career/races_leaderboard.json"
local leaderboard = {}

local level

local function loadLeaderboard()
    if not career_career or not career_career.isActive() then
        return
    end
    local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()
    local file = savePath .. '/' .. leaderboardFile
    leaderboard = jsonReadFile(file)
end

local function saveLeaderboard(currentSavePath)
    if not leaderboard then
        leaderboard = {}
    end
    career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/" .. leaderboardFile, leaderboard, true)
end

local function isBestTime(entry)
    level = getCurrentLevelIdentifier()
    if not leaderboard then
        leaderboard = {}
    end
    local leaderboardEntry = leaderboard[level] or {}
    if not leaderboardEntry then
        return true
    end

    leaderboardEntry = leaderboardEntry[tostring(entry.inventoryId)] or {}
    if not leaderboardEntry then
        return true
    end

    leaderboardEntry = leaderboardEntry[entry.raceLabel] or {}
    if not leaderboardEntry then
        return true
    end

    if entry.driftScore and entry.driftScore > 0 then
        if not leaderboardEntry.driftScore then
            return true
        end
        return entry.driftScore > leaderboardEntry.driftScore
    end

    -- Handle top speed races
    if entry.topSpeed and entry.topSpeed > 0 then
        local utils = require('gameplay/events/freeroam/utils')
        local races = utils.loadRaceData()
        local race = races[entry.raceName]
        
        if race and race.topSpeed then
            if not leaderboardEntry.topSpeed then
                return true
            end
            return entry.topSpeed > leaderboardEntry.topSpeed
        end
    end

    -- Handle damage-based races
    if entry.damageFactor and entry.damageFactor > 0 then
        -- If this is a damage-based race, compare based on the hybrid system
        local utils = require('gameplay/events/freeroam/utils')
        
        -- Get the race data to know the goal time and reward
        local races = utils.loadRaceData()
        local race = races[entry.raceName]
        if not race then
            return true
        end
        
        local goalTime = race.bestTime
        local baseReward = race.reward
        
        -- Handle alt route and hotlap variations
        if entry.isAltRoute and race.altRoute then
            goalTime = race.altRoute.bestTime
            baseReward = race.altRoute.reward
        end
        if entry.isHotlap and race.hotlap then
            goalTime = race.hotlap
        end
        
        -- Calculate current entry's hybrid score
        local currentScore = utils.hybridRaceReward(goalTime, baseReward, entry.time, entry.damageFactor, entry.damagePercentage)
        
        -- Calculate existing leaderboard entry's hybrid score if it exists
        if not leaderboardEntry.time then
            return true
        end
        
        local existingDamagePercentage = leaderboardEntry.damagePercentage or 0
        local existingScore = utils.hybridRaceReward(goalTime, baseReward, leaderboardEntry.time, entry.damageFactor, existingDamagePercentage)
        
        return currentScore > existingScore
    end

    -- Default time-based comparison
    if not leaderboardEntry.time then
        return true
    end
    return entry.time < leaderboardEntry.time
end


local function addLeaderboardEntry(entry)
    level = getCurrentLevelIdentifier()

    if career_career and career_career.isActive() then
        career_modules_inventory.saveFRETimeToVehicle(entry.raceLabel, entry.inventoryId, entry.time, entry.driftScore)
    end
    
    gameplay_events_freeroam_dataCollection.collectDataFromEntry(entry)
    
    if not leaderboard then
        leaderboard = {}
    end
    if not leaderboard[level] then 
        leaderboard[level] = {}
    end
    if not leaderboard[level][tostring(entry.inventoryId)] then
        leaderboard[level][tostring(entry.inventoryId)] = {}
    end
    local leaderboardEntry = leaderboard[level][tostring(entry.inventoryId)]
    if isBestTime(entry) then
        local raceLabel = entry.raceLabel
        leaderboardEntry[raceLabel] = leaderboardEntry[raceLabel] or {}
        leaderboardEntry[raceLabel].time = entry.time
        leaderboardEntry[raceLabel].splitTimes = entry.splitTimes
        leaderboardEntry[raceLabel].driftScore = entry.driftScore
        leaderboardEntry[raceLabel].damagePercentage = entry.damagePercentage
        leaderboardEntry[raceLabel].damageFactor = entry.damageFactor
        leaderboardEntry[raceLabel].topSpeed = entry.topSpeed
        return true
    end
    return false
end

local function clearLeaderboardForVehicle(inventoryId)
    level = getCurrentLevelIdentifier()
    if not leaderboard then
        leaderboard = {}
    end
    if not leaderboard[level] or not leaderboard[level][tostring(inventoryId)] then
        return
    end
    leaderboard[level][tostring(inventoryId)] = nil
end

local function onExtensionLoaded()
    print("Initializing Leaderboard Manager")
    level = getCurrentLevelIdentifier()
    if level then
        loadLeaderboard()
    end
end

local function onWorldReadyState(state)
    if state == 2 then
        level = getCurrentLevelIdentifier()
        loadLeaderboard()
    end
end

local function onSaveCurrentSaveSlot(currentSavePath)
    saveLeaderboard(currentSavePath)
end

local function getLeaderboardEntry(inventoryId, raceLabel)
    level = getCurrentLevelIdentifier()
    if not leaderboard then
        leaderboard = {}
    end
    if not leaderboard[level] or not leaderboard[level][tostring(inventoryId)] then
        return {}
    end
    return leaderboard[level][tostring(inventoryId)][raceLabel]
end

local function onCareerActive(active)
    if active then
        loadLeaderboard()
    else
        leaderboard = {}
    end
end

M.onVehicleRemoved = clearLeaderboardForVehicle
M.onCareerActive = onCareerActive

M.onExtensionLoaded = onExtensionLoaded
M.onWorldReadyState = onWorldReadyState

M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.addLeaderboardEntry = addLeaderboardEntry

M.isBestTime = isBestTime
M.getLeaderboardEntry = getLeaderboardEntry

return M