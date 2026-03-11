-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.dependencies = {}

local processRoad = require('gameplay/events/freeroam/processRoad')
local leaderboardManager = require('gameplay/events/freeroam/leaderboardManager')
local activeAssets = require('gameplay/events/freeroam/activeAssets')
local checkpointManager = require('gameplay/events/freeroam/checkpointManager')
local utils = require('gameplay/events/freeroam/utils')
local pits = require('gameplay/events/freeroam/pits')
local aiRacers = nil
do
    local ok, ar = pcall(function() return require('gameplay/events/freeroam/aiRacers') end)
    if ok and ar then aiRacers = ar end
end
local Assets = activeAssets.ActiveAssets.new()

local loadedExtensions = {}

local timerActive = false
local mActiveRace
local staged = nil
local in_race_time = 0

local speedUnit = 2.2369362921
local lapCount = 0
local currCheckpoint = nil
local mHotlap = nil
local mAltRoute = nil
local mCurrentRouteName = nil
local mSplitTimes = {}
local isLoop = false
local checkpointsHit = 0
local totalCheckpoints = 0
local currentExpectedCheckpoint = 1
local invalidLap = false

local initialVehicleDamage = 0

local mInventoryId = nil
local newBestSession = false

local maxSpeed = 0
local mTotalRaceTime = 0
local mBestLapThisRun = nil
local mSuppressOffRoadExitUntil = 0

local races = nil
local isReplay = false

local previousGameState = nil
local saveGameState = false

local FREEROAM_HUB_PREFS_FILE = "career/rls_career/freeroam_hub_prefs.json"
local mFreeroamHubPrefs = { autoShow = true, addedOnce = false }
local mFreeroamHubPracticeMode = false
local mFreeroamHubUseAltRoute = false
local mFreeroamHubRaceSelected = false
local mFreeroamHubShowingResult = false
local mFreeroamHubShowingHistory = false
local mFreeroamCountdownDelay = nil
local mFreeroamCountdownEndTime = nil
local mFreeroamCountdownStartClock = nil
local mFreeroamStagedAtStart = false
local mFreeroamPendingStart = nil
local mFreeroamStagingSubjectID = nil

local function getFreeroamHubPrefsPath()
    if not career_saveSystem or not career_saveSystem.getCurrentSaveSlot then return nil end
    local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()
    if not savePath then return nil end
    return savePath .. "/" .. FREEROAM_HUB_PREFS_FILE
end

local function loadFreeroamHubPrefs()
    local path = getFreeroamHubPrefsPath()
    if not path then return end
    local d = jsonReadFile(path)
    if d then
        if d.autoShow ~= nil then mFreeroamHubPrefs.autoShow = d.autoShow end
        if d.addedOnce ~= nil then mFreeroamHubPrefs.addedOnce = d.addedOnce end
    end
end

local function saveFreeroamHubPrefs()
    local path = getFreeroamHubPrefsPath()
    if not path or not career_saveSystem or not career_saveSystem.jsonWriteFileSafe then return end
    career_saveSystem.jsonWriteFileSafe(path, mFreeroamHubPrefs, true)
end

local function isFreeroamHubActive()
    if not career_career or not career_career.isActive() then return false end
    if not getFreeroamHubPrefsPath() then return false end
    loadFreeroamHubPrefs()
    return mFreeroamHubPrefs.autoShow ~= false
end

local function isFreeroamHubRaceMode()
    return isFreeroamHubActive() and not mFreeroamHubPracticeMode
end

local function getGameplayAppContainers()
    if not extensions then return nil end
    local names = { "ui_gameplayAppContainers", "ge_extensions_ui_gameplayAppContainers" }
    for _, n in ipairs(names) do
        local gc = extensions[n]
        if gc and gc.showApp then return gc end
    end
    return nil
end
local function showStagedFlashMessage()
    local gc = getGameplayAppContainers()
    if gc and gc.showApp then gc.showApp("gameplayApps", "countdown")
    elseif guihooks and guihooks.trigger then guihooks.trigger("setGameplayAppVisibility", { appId = "countdown", visible = true }) end
    if guihooks and guihooks.trigger then guihooks.trigger("ScenarioFlashMessage", {{ "Staged", 30 }}) end
    utils.displayMessage("Staged", 5)
end
local function hideStagedFlashMessage()
    if guihooks and guihooks.trigger then guihooks.trigger("ScenarioFlashMessageClear") end
    local gc = getGameplayAppContainers()
    if gc and gc.hideApp then gc.hideApp("gameplayApps", "flashMessage") gc.hideApp("gameplayApps", "countdown") end
end
local function triggerRaceCountdown()
    hideStagedFlashMessage()
    local gc = getGameplayAppContainers()
    if gc and gc.showApp then gc.showApp("gameplayApps", "countdown")
    elseif guihooks and guihooks.trigger then guihooks.trigger("setGameplayAppVisibility", { appId = "countdown", visible = true }) end
    if guihooks and guihooks.trigger then
        guihooks.trigger("ScenarioFlashMessage", {
            { 3, 0.8, false, true },
            { 2, 0.8, false, true },
            { 1, 0.8, false, true },
            { "GO", 0.6, false, true },
        })
    end
    if core_jobsystem and core_jobsystem.create then
        core_jobsystem.create(function(job)
            utils.displayMessage("3", 0.8)
            job.sleep(0.8)
            utils.displayMessage("2", 0.8)
            job.sleep(0.8)
            utils.displayMessage("1", 0.8)
            job.sleep(0.8)
            utils.displayMessage("GO!", 0.6)
        end)
    end
    mFreeroamCountdownEndTime = 3.0
    mFreeroamCountdownStartClock = (os and os.clock) and os.clock() or nil
end

local function rewardLabel(raceName, newBestTime)
    local raceLabel = races[raceName].label
    local timeLabel = utils.formatTime(in_race_time)
    local performanceLabel = newBestTime and "New Best Time!" or "Completion"

    local label = string.format("%s - %s: %s", raceLabel, performanceLabel, timeLabel)

    if mAltRoute then
        label = label .. " (Alternative Route)"
    end

    if mHotlap == raceName then
        label = label .. " (Hotlap)"
    end

    return label
end

local function getDriftScore()
    local finalScore = 0
    if gameplay_drift_scoring then
        local scoreData = gameplay_drift_scoring.getScore()
        if scoreData then
            finalScore = scoreData.score or 0
            if scoreData.cachedScore then
                finalScore = finalScore + math.floor(scoreData.cachedScore * scoreData.combo)
            end
            gameplay_drift_general.reset()
        end
    end
    return finalScore
end

local function getRaceLabel()
    local race = races[mActiveRace]
    local raceLabel = race.label

    if mAltRoute then
        raceLabel = race.altRoute.label
    end
    if mHotlap == mActiveRace then
        raceLabel = raceLabel .. " (Hotlap)"
    end
    return raceLabel
end

local function getBusinessAccountFromVehicle(spawnedVehicleId)
    if not career_career.isActive() or not career_modules_business_businessInventory then
        return nil
    end
    
    local businessId, vehicleId = career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId(spawnedVehicleId)
    if not businessId or not vehicleId then
        return nil
    end
    
    if not career_modules_bank then
        return nil
    end
    
    local businessTypes = {"tuningShop"}
    for _, businessType in ipairs(businessTypes) do
        local businessAccount = career_modules_bank.getBusinessAccount(businessType, businessId)
        if businessAccount then
            return businessAccount, businessType, businessId
        end
    end
    
    return nil
end

local function payoutRace(completedLapTime)
    if not mActiveRace then
        return 0
    end

    local race = races[mActiveRace]
    local time = race.bestTime
    local lapTime = (completedLapTime ~= nil and completedLapTime >= 0) and completedLapTime or in_race_time
    local reward = race.reward
    local raceLabel = race.label
    local damageFactor = race.damageFactor or 0

    -- Get appropriate time and reward values based on route type
    if mHotlap == mActiveRace then
        time = race.hotlap
    end
    if mAltRoute then
        time = race.altRoute.bestTime
        reward = race.altRoute.reward
        raceLabel = race.altRoute.label
        if mHotlap == mActiveRace then
            time = race.altRoute.hotlap
        end
    end
    if mHotlap == mActiveRace then
        raceLabel = raceLabel .. " (Hotlap)"
    end

    -- Calculate damage percentage if damage factor is used
    local damagePercentage = 0
    if damageFactor > 0 then
        local currentDamage = utils.getVehicleDamage()
        local damageTaken = math.max(0, currentDamage - initialVehicleDamage)
        local maxDamage = 100000 -- Default max damage
        
        -- Try to get vehicle value as max damage if in career mode
        if career_career and career_career.isActive() and career_modules_valueCalculator then
            maxDamage = career_modules_valueCalculator.getInventoryVehicleValue(mInventoryId, true)
        end
        
        -- Calculate percentage of damage taken (0 = no damage, 1 = maximum damage)
        damagePercentage = math.min(1, damageTaken / maxDamage)
    end

    -- Calculate scores and rewards
    local driftScore = 0
    if race.topSpeed then
        reward = utils.topSpeedReward(race.topSpeedGoal, reward, maxSpeed, race.type)
    elseif race.driftGoal then
        driftScore = getDriftScore()
        reward = utils.driftReward(races[mActiveRace], time, driftScore)
    elseif damageFactor > 0 then
        reward = utils.hybridRaceReward(time, reward, lapTime, damageFactor, damagePercentage, race.type)
    else
        reward = utils.raceReward(time, reward, lapTime, race.type)
    end

    -- Handle leaderboard
    local inventoryIdToUse = mInventoryId
    
        -- If mInventoryId is already a business job identifier, use it directly
        -- Otherwise, check if this is a business vehicle (check current player vehicle)
        if mInventoryId and tostring(mInventoryId):match("^business_.+_job_") then
            -- Already a business job identifier, use it as-is
            inventoryIdToUse = mInventoryId
        elseif career_modules_business_businessInventory then
            local playerVehicleId = be:getPlayerVehicleID(0)
            if playerVehicleId then
                local businessId, vehicleId = career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId(playerVehicleId)
                if businessId and vehicleId then
                    local jobId = career_modules_business_businessInventory.getJobIdFromVehicle(businessId, vehicleId)
                    if jobId then
                        inventoryIdToUse = career_modules_business_businessInventory.getBusinessJobIdentifier(businessId, jobId)
                    else
                        inventoryIdToUse = career_modules_business_businessInventory.getBusinessVehicleIdentifier(businessId, vehicleId)
                    end
                elseif mInventoryId and not tostring(mInventoryId):match("^business_") then
                    -- If mInventoryId is not already a business identifier, try to convert it
                    -- This handles the case where the race started with a regular vehicle but we want to check business vehicles
                    inventoryIdToUse = mInventoryId
                end
            end
        end
    
    local leaderboardEntry = leaderboardManager.getLeaderboardEntry(inventoryIdToUse, raceLabel)

    local oldTime = leaderboardEntry and leaderboardEntry.time or 0
    local oldScore = leaderboardEntry and leaderboardEntry.driftScore or 0

    local newEntry = {
        raceName = mActiveRace,
        raceLabel = raceLabel,
        isAltRoute = mAltRoute,
        isHotlap = mHotlap == mActiveRace,
        time = lapTime,
        splitTimes = mSplitTimes,
        driftScore = driftScore,
        inventoryId = inventoryIdToUse,
        damagePercentage = damagePercentage,
        damageFactor = damageFactor,
        topSpeed = maxSpeed,
        reward = reward
    }

    -- Only qualify lap time for leaderboard when lap is completed (not invalid)
    local newBest = false
    if not invalidLap then
        newBest = leaderboardManager.addLeaderboardEntry(newEntry)
    end

    -- Build the base message that's shown regardless of career mode
    local message = invalidLap and "Lap Invalidated\n" or ""

    if race.topSpeed then
        message = message ..
                      string.format("%s\nTop Speed: %.2f mph\nTime: %s", raceLabel, maxSpeed, utils.formatTime(lapTime))
        if oldTime then
            local oldSpeed = leaderboardEntry and leaderboardEntry.topSpeed or 0
            message = message ..
                          string.format("\nPrevious Best Speed: %.2f mph\nPrevious Best Time: %s", oldSpeed,
                    utils.formatTime(oldTime))
        end
    elseif race.driftGoal then
        message = message ..
                      string.format("%s\nDrift Score: %d\nTime: %s", raceLabel, driftScore,
                utils.formatTime(lapTime))
        if oldScore and oldTime then
            message = message ..
                          string.format("\nPrevious Best Score: %d\nPrevious Best Time: %s", oldScore,
                    utils.formatTime(oldTime))
        end
    else
        if newBest and not invalidLap then
            if damageFactor > 0 then
                message = message .. "New Best Score!\n"
            else
                message = message .. "New Best Time!\n"
            end
        end
        
        -- Build basic time information
        if race.hotlap then
            message = message ..
                          string.format("%s\nTime: %s\nLap: %d", raceLabel, utils.formatTime(lapTime), lapCount)
        else
            message = message .. string.format("%s\nTime: %s", raceLabel, utils.formatTime(lapTime))
        end
        
        -- Add damage information for damage-based races
        if damageFactor > 0 then
            message = message .. string.format("\nDamage Taken: %.1f%% | Damage Factor: %.0f%%", 
                damagePercentage * 100, damageFactor * 100)
        end
        
        -- Show previous best information
        if newBest and not invalidLap and oldTime ~= math.huge then
            if damageFactor > 0 then
                local oldDamagePercentage = leaderboardEntry and leaderboardEntry.damagePercentage or 0
                message = message .. string.format("\nPrevious Best Time: %s | Previous Best Damage: %.1f%%", 
                    utils.formatTime(oldTime), oldDamagePercentage * 100)
            else
                message = message .. string.format("\nPrevious Best: %s", utils.formatTime(oldTime))
            end
        end
    end

    local hotlapMessage = ""
    -- Handle career mode specific rewards
    if career_career.isActive() then
        if not newBest or mHotlap then
            reward = reward / 2
        end
        reward = invalidLap and 0 or reward
        lapCount = invalidLap and 1 or lapCount
        if race.hotlap then
            -- Hotlap Multiplier
            reward = reward * utils.hotlapMultiplier(lapCount)
            hotlapMessage = string.format("\nHotlap Multiplier: %.2f", utils.hotlapMultiplier(lapCount))
        end

        if newBest and not newBestSession then
            -- New Best Bonus
            newBestSession = true
        end

        if newBestSession then
            -- New Best Bonus
            reward = reward * 1.2
            hotlapMessage = hotlapMessage .. "\nNew Best Session Bonus: 20%"
        end

        if oldTime and (newEntry.time - (oldTime * 0.025) < oldTime) then
            -- In Range Bonus
            reward = reward * 1.05
            hotlapMessage = hotlapMessage .. "\nIn Range Bonus: 5%"
        end

        reward = reward / (career_modules_hardcore.isHardcoreMode() and 2 or 1)

        if reward > 0 then
            local playerVehicleId = be:getPlayerVehicleID(0)
            local businessAccount, businessType, businessId = getBusinessAccountFromVehicle(playerVehicleId)
            
            if businessAccount then
                local businessReward = math.floor(reward * 0.5)
                local xp = math.floor(reward / 20)
                
                local xpReward = {
                    beamXP = {
                        amount = math.floor(xp / 10)
                    }
                }
                for _, type in ipairs(race.type) do
                    xpReward[type] = {
                        amount = xp
                    }
                end
                
                career_modules_payment.reward(xpReward, {
                    label = rewardLabel(mActiveRace, newBest),
                    tags = {"gameplay", "reward", "mission"}
                }, true)
                
                if career_modules_bank then
                    career_modules_bank.rewardToAccount({
                        money = {
                            amount = businessReward
                        }
                    }, businessAccount.id, "Event Reward", rewardLabel(mActiveRace, newBest))
                end
                
                message = message .. string.format("\nXP: %d | Business Reward: $%.2f (50%% to business account)", xp, businessReward)
                if career_modules_hardcore.isHardcoreMode() then
                    message = message .. "\nHardcore mode is enabled, all rewards are halved."
                end
            else
                local xp = math.floor(reward / 20)
                local totalReward = {
                    money = {
                        amount = reward
                    },
                    beamXP = {
                        amount = math.floor(xp / 10)
                    }
                }
                for _, type in ipairs(race.type) do
                    totalReward[type] = {
                        amount = xp
                    }
                end

                career_modules_payment.reward(totalReward, {
                    label = rewardLabel(mActiveRace, newBest),
                    tags = {"gameplay", "reward", "mission"}
                }, true)

                message = message .. string.format("\nXP: %d | Reward: $%.2f", xp, reward)
                if career_modules_hardcore.isHardcoreMode() then
                    message = message .. "\nHardcore mode is enabled, all rewards are halved."
                end
            end
            career_saveSystem.saveCurrent()
        end
    end

    mActiveRace = nil
    utils.displayMessage(message, 20, "Reward")
    if hotlapMessage ~= "" then
        ui_message(hotlapMessage, 5, "Hotlap Multiplier")
    end
    return reward
end

-- Simplified payoutRace function for drag races
local function payoutDragRace(raceName, finishTime, finishSpeed, vehId)
    -- Load the leaderboard
    local inventoryIdToUse = vehId
    
    if career_career.isActive() then
        -- Check if this is a business vehicle first
        if career_modules_business_businessInventory then
            local businessId, vehicleId = career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId(vehId)
            if businessId and vehicleId then
                local jobId = career_modules_business_businessInventory.getJobIdFromVehicle(businessId, vehicleId)
                if jobId then
                    inventoryIdToUse = career_modules_business_businessInventory.getBusinessJobIdentifier(businessId, jobId)
                else
                    inventoryIdToUse = career_modules_business_businessInventory.getBusinessVehicleIdentifier(businessId, vehicleId)
                end
            else
                inventoryIdToUse = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
            end
        else
            inventoryIdToUse = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
        end
    end

    local leaderboardEntry = leaderboardManager.getLeaderboardEntry(inventoryIdToUse, races["drag"].label)
    local oldTime = leaderboardEntry and leaderboardEntry.time or 0

    local newEntry = {
        raceLabel = races["drag"].label,
        raceName = raceName,
        time = finishTime,
        splitTimes = mSplitTimes,
        inventoryId = inventoryIdToUse
    }

    local newBestTime = leaderboardManager.addLeaderboardEntry(newEntry)

    if not career_career.isActive() then
        local message = string.format("%s\nTime: %s\nSpeed: %.2f mph", races[raceName].label, utils.formatTime(finishTime),
            finishSpeed)
        utils.displayMessage(message, 10)
        return 0
    end

    -- Get race data
    local raceData = races[raceName]
    local targetTime = raceData.bestTime
    local baseReward = raceData.reward

    -- Calculate reward based on performance
    local reward = utils.raceReward(targetTime, baseReward, finishTime, raceData.type)
    if reward <= 0 then
        reward = baseReward / 2 -- Minimum reward for completion
    end

    reward = reward / (career_modules_hardcore.isHardcoreMode() and 2 or 1)

    reward = newBestTime and reward or reward / 2

    -- Calculate experience points
    local xp = math.floor(reward / 20)

    -- Check if this is a business vehicle
    local businessAccount, businessType, businessId = getBusinessAccountFromVehicle(vehId)
    
    if businessAccount then
        local businessReward = math.floor(reward * 0.5)
        
        local xpReward = {
            beamXP = {
                amount = math.floor(xp / 10)
            }
        }
        
        local reason = {
            label = raceData.label .. (newBestTime and " - New Best Time!" or " - Completion"),
            tags = {"gameplay", "reward", "drag"}
        }
        
        career_modules_payment.reward(xpReward, reason, true)
        
        if career_modules_bank then
            career_modules_bank.rewardToAccount({
                money = {
                    amount = businessReward
                }
            }, businessAccount.id, "Event Reward", raceData.label .. (newBestTime and " - New Best Time!" or " - Completion"))
        end
        
        local message = string.format("%s\n%s\nTime: %s\nSpeed: %.2f mph\nXP: %d | Business Reward: $%.2f (50%% to business account)",
            newBestTime and "Congratulations! New Best Time!" or "", raceData.label, utils.formatTime(finishTime), finishSpeed,
            xp, businessReward)
        
        if career_modules_hardcore.isHardcoreMode() then
            message = message .. "\nHardcore mode is enabled, all rewards are halved."
        end
        
        ui_message(message, 20, "Reward")
    else
        -- Prepare total reward
        local totalReward = {
            money = {
                amount = reward
            },
            beamXP = {
                amount = math.floor(xp / 10)
            }
        }

        -- Create reason for reward
        local reason = {
            label = raceData.label .. (newBestTime and " - New Best Time!" or " - Completion"),
            tags = {"gameplay", "reward", "drag"}
        }

        -- Process the reward
        career_modules_payment.reward(totalReward, reason, true)

        -- Prepare the completion message
        local message = string.format("%s\n%s\nTime: %s\nSpeed: %.2f mph\nXP: %d | Reward: $%.2f",
            newBestTime and "Congratulations! New Best Time!" or "", raceData.label, utils.formatTime(finishTime), finishSpeed,
            xp, reward)

        if career_modules_hardcore.isHardcoreMode() then
            message = message .. "\nHardcore mode is enabled, all rewards are halved."
        end

        -- Display the message
        ui_message(message, 20, "Reward")
    end

    -- Save the leaderboard and game state
    career_saveSystem.saveCurrent()

    return reward
end

local function getDifference(raceName, currentCheckpointIndex)
    local raceLabel = getRaceLabel()
    local leaderboardEntry = leaderboardManager.getLeaderboardEntry(mInventoryId, raceLabel)
    if not leaderboardEntry then
        return nil
    end

    local splitTimes = leaderboardEntry.splitTimes

    if not splitTimes or not splitTimes[currentCheckpointIndex] then
        return nil
    end

    -- Calculate the time difference for this split
    local currentSplitDiff
    if not mSplitTimes[currentCheckpointIndex] or not splitTimes[currentCheckpointIndex] then
        return nil
    end

    if currentCheckpointIndex == 1 then
        -- For first checkpoint, compare directly
        currentSplitDiff = mSplitTimes[currentCheckpointIndex] - splitTimes[currentCheckpointIndex]
    else
        -- Check if we have the previous checkpoint times before calculating
        if not mSplitTimes[currentCheckpointIndex - 1] or not splitTimes[currentCheckpointIndex - 1] then
            return nil
        end

        -- For subsequent checkpoints, compare the differences between splits
        local previousBestSplit = splitTimes[currentCheckpointIndex] - splitTimes[currentCheckpointIndex - 1]
        local currentSplit = mSplitTimes[currentCheckpointIndex] - mSplitTimes[currentCheckpointIndex - 1]
        currentSplitDiff = currentSplit - previousBestSplit
    end

    return currentSplitDiff
end

local function formatSplitDifference(diff)
    local sign = diff >= 0 and "+" or "-"
    return string.format("%s%s", sign, utils.formatTime(math.abs(diff)))
end

-- Returns the display name for the route from race_data.json (label for main, altRoute.label for alt).
local function getRouteDisplayName(race, isAlt)
    if not race then return nil end
    if isAlt and race.altRoute and race.altRoute.label then
        return race.altRoute.label
    end
    return race.label
end

-- Start the race (staging -> start line). Used by both trigger and onUpdate (countdown-finished). Keeps original logic; hub-only behavior is guarded by isFreeroamHubRaceMode/isFreeroamHubActive.
local function beginFreeroamRace(raceNameArg, subjectID)
    if not races[raceNameArg] then return end
    local raceName = raceNameArg
    if career_career.isActive() then
        career_modules_pauseTime.enablePauseCounter(true)
    end
    initialVehicleDamage = utils.getVehicleDamage()
    utils.saveAndSetTrafficAmount(0)
    checkpointManager.setRace(races[raceName], raceName)
    Assets:displayAssets({ subjectID = subjectID, triggerName = "fre_start_" .. raceName })
    timerActive = true
    in_race_time = 0
    maxSpeed = 0
    mActiveRace = raceName
    lapCount = 0
    mCurrentRouteName = nil
    mTotalRaceTime = 0
    mBestLapThisRun = nil
    -- Suppress off-road exit briefly at race start so we don't exit (and clear AI) on first frame
    mSuppressOffRoadExitUntil = os.time() + 5
    if career_modules_business_businessInventory then
        local businessId, vehicleId = career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId(subjectID)
        if businessId and vehicleId then
            local jobId = career_modules_business_businessInventory.getJobIdFromVehicle(businessId, vehicleId)
            if jobId then
                mInventoryId = career_modules_business_businessInventory.getBusinessJobIdentifier(businessId, jobId)
            else
                mInventoryId = career_modules_business_businessInventory.getBusinessVehicleIdentifier(businessId, vehicleId)
            end
        else
            mInventoryId = career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId(subjectID) or subjectID
        end
    else
        mInventoryId = career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId(subjectID) or subjectID
    end
    invalidLap = false
    utils.displayStartMessage(raceName)
    utils.setActiveLight(raceName, "green")
    if utils.tableContains(races[raceName].type, "drift") then
        gameplay_drift_general.setContext("inChallenge")
        gameplay_drift_general.reset()
        if gameplay_drift_drift then gameplay_drift_drift.setVehId(subjectID) end
    end
    if races[raceName].checkpointRoad then
        processRoad.reset()
        processRoad.setStationaryTimeout(races[raceName].timeout)
        local checkpoints, altCheckpoints = processRoad.getCheckpoints(races[raceName])
        local routeOnly = nil
        if isFreeroamHubActive() and not mFreeroamHubPracticeMode then
            routeOnly = mFreeroamHubUseAltRoute and "alt" or "main"
        end
        local isLocked = isFreeroamHubActive() and not mFreeroamHubPracticeMode
        if checkpointManager.setRouteLocked then checkpointManager.setRouteLocked(isLocked) end
        checkpointManager.createCheckpoints(checkpoints, altCheckpoints, routeOnly)
        isLoop = processRoad.isLoop()
        currCheckpoint = 0
        checkpointsHit = 0
        totalCheckpoints = checkpointManager.calculateTotalCheckpoints()
        currentExpectedCheckpoint = 1
        mAltRoute = false
        checkpointManager.setAltRoute(mAltRoute)
        if isFreeroamHubActive() and mFreeroamHubUseAltRoute and races[raceName].altRoute then
            mAltRoute = true
            checkpointManager.setAltRoute(true)
            totalCheckpoints = checkpointManager.calculateTotalCheckpoints()
        end
        currentExpectedCheckpoint = checkpointManager.enableCheckpoint(0, mAltRoute)
    end
end

local function exitRace(isCompletion, customMessage, raceData, subjectID)
    -- Clear hub countdown state whenever we exit (race or staging)
    mFreeroamCountdownDelay = nil
    mFreeroamCountdownEndTime = nil
    mFreeroamCountdownStartClock = nil
    mFreeroamStagedAtStart = false
    mFreeroamPendingStart = nil
    mFreeroamStagingSubjectID = nil
    if mActiveRace then
        local raceName = mActiveRace
        local raceLabel = getRaceLabel()
        
        -- Build final UI state before we clear mActiveRace (same label/lap as game message)
        local isLapRace = raceData and ((raceData.lapCount and raceData.lapCount > 0) or raceData.hotlap)
        local sectorDeltas = {}
        for i = 1, checkpointsHit do
            local d = getDifference(raceName, i)
            if d then sectorDeltas[i] = d end
        end
        local lbEntry = mInventoryId and leaderboardManager.getLeaderboardEntry(mInventoryId, raceLabel) or {}
        local lapNum = isLapRace and (lapCount + 1) or 1
        local finalState = {
            inRace = false,
            staged = false,
            raceId = raceName,
            raceLabel = raceLabel,
            currentLap = isLapRace and lapCount or 0,
            displayLap = lapNum,
            totalLaps = isLapRace and raceData.lapCount or 1,
            totalCheckpoints = totalCheckpoints,
            currentLapTime = in_race_time,
            topSpeedThisLap = maxSpeed,
            bestLapFromHistory = lbEntry.time,
            invalidLap = invalidLap,
            routeName = mCurrentRouteName,
            splits = mSplitTimes,
            sectorDeltas = sectorDeltas
        }
        
        local finalResult = nil

        if isCompletion then
            -- Include last lap in best when finishing via finish line (no lap-complete block ran for it)
            if in_race_time and (mBestLapThisRun == nil or in_race_time < mBestLapThisRun) then
                mBestLapThisRun = in_race_time
            end
            -- Race completion logic
            local rewardData = payoutRace()
            
            -- If payoutRace() returned something useful we can put it in the result ticket
            local rewardAmt = 0
            if type(rewardData) == "number" then rewardAmt = rewardData end

            local totalTime = (mTotalRaceTime or 0) + in_race_time
            local lapsTotalVal = isLapRace and (raceData.lapCount and raceData.lapCount > 0 and raceData.lapCount or lapCount) or 1

            finalResult = {
                lapsCompleted = isLapRace and lapCount or 1,
                lapsTotal = lapsTotalVal,
                totalTime = totalTime,
                bestLap = mBestLapThisRun,
                newBest = newBestSession,
                invalidLap = invalidLap,
                reward = rewardAmt,
                xp = 0,
                leaderboard = {}
            }

            -- Race-specific completion handling
            if raceName == "drag" and raceData and subjectID then
                local side = "l"
                utils.updateDisplay(side, in_race_time, math.abs(be:getObjectVelocityXYZ(subjectID)) * speedUnit)
            end

            if raceData and utils.tableContains(raceData.type, "drift") then
                local finalScore = getDriftScore()
                if gameplay_drift_general.getContext() == "inChallenge" then
                    gameplay_drift_general.setContext("inFreeRoam")
                end
            end

            if customMessage then
                utils.displayMessage(customMessage, 10, "Reward")
            end
        else
            -- Race cancellation logic; if at least one lap completed, still show result screen + Next
            local message = customMessage or "You exited the race zone, Race cancelled"
            utils.displayMessage(message, 3)
            if lapCount >= 1 and (raceData or races[raceName]) then
                local rd = raceData or races[raceName]
                local isLap = rd and ((rd.lapCount and rd.lapCount > 0) or rd.hotlap)
                local totalTimePartial = (mTotalRaceTime or 0) + in_race_time
                local lapsTotalVal = isLap and (rd.lapCount and rd.lapCount > 0 and rd.lapCount or lapCount) or 1
                finalResult = {
                    raceLabel = raceLabel,
                    lapsCompleted = isLap and lapCount or 1,
                    lapsTotal = lapsTotalVal,
                    totalTime = totalTimePartial,
                    bestLap = mBestLapThisRun,
                    newBest = false,
                    invalidLap = invalidLap,
                    reward = 0,
                    xp = 0,
                    leaderboard = {}
                }
            end
        end

        -- Push the final state and result to the UI app (only when hub is active)
        if isFreeroamHubActive() then
            guihooks.trigger("FreeroamHubRaceState", finalState)
            if finalResult then
                mFreeroamHubShowingResult = true
                mFreeroamHubRaceSelected = false
                guihooks.trigger("FreeroamHubRaceResult", finalResult)
            end
            -- If opted in and no result to show, close the app when event ends
            if not finalResult then
                guihooks.trigger("FreeroamHubCloseApp")
                local gc = getGameplayAppContainers()
                if gc and gc.hideApp then gc.hideApp("gameplayApps", "freeroamEventHub") end
            end
        end

        utils.setActiveLight(raceName, "red")
        lapCount = 0
        mActiveRace = nil
        timerActive = false
        mHotlap = nil
        currCheckpoint = nil
        mSplitTimes = {}
        mAltRoute = false
        mCurrentRouteName = nil
        invalidLap = false
        mInventoryId = nil
        maxSpeed = 0
        mTotalRaceTime = 0
        mBestLapThisRun = nil
        mSuppressOffRoadExitUntil = 0
        if aiRacers then
            if aiRacers.setDnfCallback then aiRacers.setDnfCallback(nil) end
            if aiRacers.clearSpawned then aiRacers.clearSpawned() end
        end
        Assets:hideAllAssets()
        checkpointManager.removeCheckpoints()

        -- Common cleanup tasks
        core_jobsystem.create(function(job)
            job.sleep(10)
            utils.restoreTrafficAmount()
        end)
        pits.clearSpeedLimit()
        newBestSession = false
        if gameplay_drift_general.getContext() == "inChallenge" then
            gameplay_drift_general.setContext("inFreeRoam")
            gameplay_drift_general.reset()
        end
        if career_career.isActive() then
            career_modules_pauseTime.enablePauseCounter()
        end
        if previousGameState and not mFreeroamHubShowingResult then
            core_gamestate.setGameState(previousGameState.state, previousGameState.appLayout, previousGameState.menuItems, previousGameState.options)
            previousGameState = nil
            saveGameState = false
        end
    end
end

local function onBeamNGTrigger(data)
    if be:getPlayerVehicleID(0) ~= data.subjectID or isReplay then
        return
    end
    if gameplay_walk.isWalking() then return end
    if career_career.isActive() then
        -- Check if it's a business vehicle first
        local isBusinessVehicle = false
        if career_modules_business_businessInventory then
            local businessId, vehicleId = career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId(data.subjectID)
            if businessId and vehicleId then
                isBusinessVehicle = true
            end
        end
        
        -- If not a business vehicle, check if it's an inventory vehicle
        if not isBusinessVehicle then
            if not career_modules_inventory.getInventoryIdFromVehicleId(data.subjectID) then
                return
            end
            local vehicle = career_modules_inventory.getVehicles()[career_modules_inventory.getInventoryIdFromVehicleId(data.subjectID)]
            if vehicle.loanType then
                return
            end
        end
    end

    local triggerName = data.triggerName
    local event = data.event

    if not triggerName:match("^fre_") then
        -- Not a free roam event trigger, ignore
        return
    end

    -- Remove the 'fre_' prefix for processing
    triggerName = triggerName:sub(5)

    -- Extract trigger information
    local triggerType, raceName, rest = triggerName:match("^([^_]+)_([^_]+)(.*)$")

    if not triggerType or not raceName then
        -- print("Trigger name doesn't match expected pattern.")
        return
    end

    -- Initialize altFlag and index
    local altFlag = nil
    local index = nil

    -- Process the rest of the trigger name
    if rest ~= "" then
        -- Remove leading underscores
        rest = rest:gsub("^_+", "")

        -- Check if rest starts with 'alt'
        if rest:sub(1, 3) == "alt" then
            altFlag = "alt"
            rest = rest:sub(4) -- Remove 'alt' and move forward
            rest = rest:gsub("^_+", "") -- Remove any additional underscores
        end

        -- If there's still something left, it's the index
        if rest ~= "" then
            index = rest
        end
    end

    -- Convert index to number if it exists
    local checkpointIndex = index and tonumber(index) or nil

    local isAlt = altFlag == "alt" -- TEMP must change to acount for alt routes that intersect with the main route multiple times

    if triggerType == "staging" then
        if event == "enter" and mActiveRace == nil then
            if isFreeroamHubActive() and mFreeroamHubShowingResult then return end
            if utils.isPlayerInPursuit() then
                utils.displayMessage("You cannot stage for an event while in a pursuit.", 2)
                return
            end

            saveGameState = true
            core_gamestate.requestGameState()

            local vehicleSpeed = math.abs(be:getObjectVelocityXYZ(data.subjectID)) * speedUnit
            if vehicleSpeed > 5 and mActiveRace then
                return
            end
            mHotlap = nil
            if vehicleSpeed > 5 then
                if races[raceName].runningStart then
                    utils.displayMessage("Hotlap Staged", 2)
                    if races[raceName].hotlap then
                        mHotlap = raceName
                    end
                else
                    utils.displayMessage("You are too fast to stage.\nPlease back up and slow down to stage.", 2)
                    staged = nil
                    return
                end
            end
            Assets:hideAllAssets()
            lapCount = 0

            -- Check if ALL race types are disabled (only disable if every type is 0)
            local allTypesDisabled = false
            local disabledTypes = {}
            if career_economyAdjuster and races[raceName].type then
                local totalTypes = 0
                local disabledCount = 0

                for _, raceType in ipairs(races[raceName].type) do
                    totalTypes = totalTypes + 1
                    local multiplier = career_economyAdjuster.getEffectiveSectionMultiplier({raceType})
                    if multiplier == 0 then
                        disabledCount = disabledCount + 1
                        table.insert(disabledTypes, raceType)
                    end
                end

                -- Only disable if ALL types are disabled
                allTypesDisabled = totalTypes > 0 and disabledCount == totalTypes
            end

            if allTypesDisabled then
                -- Don't allow staging for disabled races
                local typesString = table.concat(disabledTypes, ", ")
                utils.displayMessage(string.format("%s is disabled due to %s multiplier(s) being set to 0.", races[raceName].label, typesString), 5)
                return
            end

            -- Initialize displays if drag race
            if raceName == "drag" then
                utils.initDisplays()
                utils.resetDisplays()
            end

            -- Set staged race
            staged = raceName
            -- Hub race mode: show Staged flash and start countdown only after player selected Track or Short track
            if isFreeroamHubRaceMode() and mFreeroamHubRaceSelected then
                showStagedFlashMessage()
                mFreeroamCountdownDelay = 1.0
                mFreeroamStagedAtStart = false
                mFreeroamPendingStart = nil
                mFreeroamStagingSubjectID = data.subjectID
            end
            -- print("Staged race: " .. raceName)
            local vehId = data.subjectID
            if career_career.isActive() then
                -- Check if it's a business vehicle first
                if career_modules_business_businessInventory then
                    local businessId, vehicleId = career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId(data.subjectID)
                    if businessId and vehicleId then
                        vehId = career_modules_business_businessInventory.getBusinessVehicleIdentifier(businessId, vehicleId)
                    else
                        vehId = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
                    end
                else
                    vehId = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
                end
            end
            
            local race = races[raceName] or {}
            local raceLabel = race.label or raceName
            local state = { inRace = false, staged = true, raceId = raceName, raceLabel = raceLabel }
            state.stagedMessage = utils.displayStagedMessage(vehId, raceName, true)
            state.showRaceSelection = isFreeroamHubActive() and not mFreeroamHubRaceSelected

            if isFreeroamHubActive() then
                guihooks.trigger("FreeroamHubAddApp")
                guihooks.trigger("appContainer:addApp", "freeroamEventHub")
                guihooks.trigger("FreeroamHubSetAvailable", { available = true })
                if not mFreeroamHubPrefs.addedOnce then
                    mFreeroamHubPrefs.addedOnce = true
                    saveFreeroamHubPrefs()
                end
                local gc = getGameplayAppContainers()
                if gc and gc.showApp then
                    gc.showApp("gameplayApps", "freeroamEventHub")
                else
                    guihooks.trigger("setGameplayAppVisibility", { appId = "freeroamEventHub", visible = true })
                end
                guihooks.trigger("FreeroamHubRaceState", state)
            end

            utils.displayStagedMessage(vehId, raceName)
            utils.setActiveLight(raceName, "yellow")
        elseif event == "exit" then
            -- If they chose a race and are driving to the start line (or are already in the race), don't clear staged/countdown/AI when exiting staging
            local drivingToStart = (mFreeroamHubRaceSelected and (mFreeroamCountdownDelay or mFreeroamCountdownEndTime or mFreeroamPendingStart)) or (mActiveRace == raceName)
            if not drivingToStart then
                staged = nil
                mFreeroamHubRaceSelected = false
                if isFreeroamHubRaceMode() then
                    hideStagedFlashMessage()
                    mFreeroamCountdownDelay = nil
                    mFreeroamCountdownEndTime = nil
                    mFreeroamCountdownStartClock = nil
                    mFreeroamStagedAtStart = false
                    mFreeroamPendingStart = nil
                    if aiRacers and aiRacers.clearSpawned then aiRacers.clearSpawned() end
                end
                if not mActiveRace and not mFreeroamHubShowingResult and not mFreeroamHubShowingHistory then
                    if isFreeroamHubActive() then
                        guihooks.trigger("FreeroamHubSetAvailable", { available = false })
                        guihooks.trigger("FreeroamHubRaceState", { inRace = false })
                        local gc = getGameplayAppContainers()
                        if gc and gc.hideApp then gc.hideApp("gameplayApps", "freeroamEventHub") end
                    end
                    utils.displayMessage("You exited the staging zone", 4)
                    utils.setActiveLight(raceName, "red")
                end
            end
        end
    elseif triggerType == "start" then
        if event == "enter" and mActiveRace == raceName and not utils.hasFinishTrigger(raceName) then
            if not currCheckpoint or checkpointsHit < totalCheckpoints then
                -- Player hasn't completed all checkpoints yet
                if not invalidLap then
                    utils.displayMessage("You have not completed all checkpoints!", 5)
                    return
                end
            end
            -- Freeze lap time at completion so we don't count time after you stop
            local completedLapTime = in_race_time
            timerActive = false
            -- Suppress off-road exit briefly so crossing start line doesn't trigger exitRace
            mSuppressOffRoadExitUntil = os.time() + 2
            if not invalidLap then
                mTotalRaceTime = (mTotalRaceTime or 0) + completedLapTime
                if mBestLapThisRun == nil or completedLapTime < mBestLapThisRun then
                    mBestLapThisRun = completedLapTime
                end
            end
            initialVehicleDamage = utils.getVehicleDamage()
            processRoad.setStationaryTimeout(races[raceName].timeout)
            checkpointManager.setRace(races[raceName], raceName)
            if not data.triggerName then data.triggerName = "fre_start_" .. raceName end
            Assets:displayAssets(data)
            utils.playCheckpointSound()
            lapCount = lapCount + 1
            -- Hub race mode: if we have a required lap count and just reached it, complete the race and show result screen
            if isFreeroamHubActive() and not mFreeroamHubPracticeMode then
                local race = races[raceName]
                local requiredLaps = (race.lapCount and race.lapCount > 0) and race.lapCount or 3
                if lapCount >= requiredLaps then
                    exitRace(true, nil, race, data.subjectID)
                    return
                end
            end
            local reward = payoutRace(completedLapTime)
            currCheckpoint = nil
            mSplitTimes = {}
            mActiveRace = raceName
            -- Next lap: keep alt route if hub selected Short track, else reset to main
            if not (isFreeroamHubActive() and mFreeroamHubUseAltRoute) then
                checkpointManager.setAltRoute(false)
                mAltRoute = false
            end
            in_race_time = 0
            maxSpeed = 0
            timerActive = true
            checkpointsHit = 0
            totalCheckpoints = checkpointManager.calculateTotalCheckpoints()
            currentExpectedCheckpoint = 0
            if races[raceName].hotlap then
                mHotlap = raceName
                currentExpectedCheckpoint = checkpointManager.enableCheckpoint(0, mAltRoute)
            end
            invalidLap = false
        elseif event == "enter" and staged == raceName and mActiveRace ~= raceName then
            if isFreeroamHubRaceMode() and not mFreeroamHubRaceSelected then
                utils.setActiveLight(raceName, "red")
                return
            end
            -- Hub race mode: Staged flash + countdown (American Road style). Practice or no hub: original logic, start immediately.
            if isFreeroamHubRaceMode() then
                if mFreeroamCountdownEndTime and mFreeroamCountdownEndTime > 0 and mFreeroamCountdownStartClock and os and os.clock then
                    local elapsed = os.clock() - mFreeroamCountdownStartClock
                    if elapsed < 3.0 then
                        utils.displayMessage("False start! Wait for the countdown.", 4)
                        hideStagedFlashMessage()
                        mFreeroamCountdownDelay = nil
                        mFreeroamCountdownEndTime = nil
                        mFreeroamCountdownStartClock = nil
                        mFreeroamStagedAtStart = false
                        mFreeroamPendingStart = nil
                        staged = nil
                        return
                    end
                end
                if mFreeroamCountdownEndTime == nil or not mFreeroamCountdownStartClock then
                    -- Countdown not run yet: wait at start line; countdown will run from onUpdate, then we start from onUpdate when 3s elapsed
                    mFreeroamStagedAtStart = true
                    mFreeroamPendingStart = { raceName = raceName, subjectID = data.subjectID }
                    return
                end
                -- Countdown finished and 3s elapsed: clear and proceed with start below
                mFreeroamCountdownEndTime = nil
                mFreeroamCountdownStartClock = nil
                mFreeroamStagedAtStart = false
                mFreeroamPendingStart = nil
            end
            -- Start the race (original logic in beginFreeroamRace; hub-only route/lap behavior is guarded there)
            beginFreeroamRace(raceName, data.subjectID)
        else
            -- Player is not staged or race is not active
            utils.setActiveLight(raceName, "red")
        end
    elseif triggerType == "checkpoint" and checkpointIndex then
        if event == "enter" and mActiveRace == raceName then
            -- Already have full lap; don't count another (lets start-trigger handle lap complete / finish)
            if checkpointsHit >= totalCheckpoints then return end
            -- Ensure that the checkpoint is the expected one
            if (checkpointIndex == currentExpectedCheckpoint) or (checkpointIndex == 1 and isAlt) or
                (isAlt and (currentExpectedCheckpoint == races[raceName].altRoute.mergeCheckpoints[1])) then
                -- Route-switch detection (end run + start other route) disabled: alt route merges with main
                -- and shares checkpoints, so (checkpointIndex, isAlt) alone is unreliable. Would need to use
                -- race_data.json checkpoint/altRoute definitions to know which checkpoints belong to which route.
                checkpointsHit = checkpointsHit + 1
                currCheckpoint = checkpointIndex
                mSplitTimes[checkpointsHit] = in_race_time
                if checkpointsHit == 1 then
                    mCurrentRouteName = getRouteDisplayName(races[raceName], isAlt)
                end
                utils.playCheckpointSound()

                -- Prepare the next checkpoint
                if isAlt then
                    currentExpectedCheckpoint = checkpointIndex
                end

                currentExpectedCheckpoint = checkpointManager.enableCheckpoint(checkpointIndex, isAlt)
                if isAlt and not mAltRoute then
                    mAltRoute = true
                    checkpointManager.setAltRoute(true)
                    totalCheckpoints = checkpointManager.calculateTotalCheckpoints()
                end

                -- Display checkpoint message
                local checkpointMessage = ""
                local splitDiff = getDifference(raceName, checkpointsHit)
                if splitDiff then
                    local totalDiff = nil
                    local raceLabel = getRaceLabel()
                    local leaderboardEntry = leaderboardManager.getLeaderboardEntry(mInventoryId, raceLabel)
                    totalDiff = in_race_time - (leaderboardEntry.splitTimes[checkpointsHit] or 0)

                    checkpointMessage = string.format("Checkpoint %d/%d - Time: %s\nSplit: %s | Total: %s",
                        checkpointsHit, totalCheckpoints, utils.formatTime(in_race_time), formatSplitDifference(splitDiff),
                        formatSplitDifference(totalDiff))
                else
                    checkpointMessage = string.format("Checkpoint %d/%d - Time: %s", checkpointsHit, totalCheckpoints,
                        utils.formatTime(in_race_time))
                end
                utils.displayMessage(checkpointMessage, 7)
                if not data.triggerName then
                    data.triggerName = "fre_checkpoint_" .. raceName .. (isAlt and "_alt_" or "_") .. checkpointIndex
                end
                Assets:displayAssets(data)
            else
                local missedCheckpoints = checkpointIndex - currentExpectedCheckpoint
                if missedCheckpoints > 0 then
                    -- Mark lap as invalid but continue with correct checkpoints
                    invalidLap = true

                    -- Update current checkpoint and hit count
                    currCheckpoint = checkpointIndex
                    currentExpectedCheckpoint = currentExpectedCheckpoint + missedCheckpoints
                    checkpointsHit = math.min(checkpointsHit + missedCheckpoints + 1, totalCheckpoints)

                    -- Enable next checkpoint
                    currentExpectedCheckpoint = checkpointManager.enableCheckpoint(checkpointIndex, isAlt)

                    -- Display message about invalid lap but continuing
                    local message = string.format("Missed a checkpoint\nLap Invalidated.", checkpointIndex)
                    local checkpointMessage = string.format("Checkpoint %d/%d - Time: %s", checkpointsHit,
                        totalCheckpoints, utils.formatTime(in_race_time))
                    message = message .. "\n" .. checkpointMessage
                    utils.displayMessage(message, 10)
                end
            end
        end

    elseif triggerType == "finish" then
        if event == "enter" and mActiveRace == raceName then
            exitRace(true, nil, races[raceName], data.subjectID)
        end
    elseif triggerType == "pits" then
        if event == "enter" and mActiveRace == raceName then
            -- Handle pit entry
            local obj = be:getPlayerVehicle(0)
            if obj then
                obj:queueLuaCommand("obj:setGhostEnabled(true)")
            end
            if races[raceName].pitSpeedLimit then
                pits.stopThenLimit(races[raceName].pitSpeedLimit, races[raceName].pitSpeedLimitUnit)
            else
                pits.stopThenLimit(37, "MPH")
            end
        elseif event == "exit" and mActiveRace == raceName then
            -- Handle pit exit
            pits.toggleSpeedLimit()
            local obj = be:getPlayerVehicle(0)
            if obj then
                obj:queueLuaCommand("obj:setGhostEnabled(false)")
            end
        end    
    else
        -- print("Unknown trigger type: " .. triggerType)
    end
end

-- Preload AI paths for track (and alt) when level has track race with AI config (e.g. west_coast_usa).
local function preloadFreeroamAiPathsForTrack()
    if not aiRacers or not aiRacers.preloadPathForRace then return end
    local levelId = getCurrentLevelIdentifier()
    if not levelId or not races or not races.track then return end
    aiRacers.preloadPathForRace(races.track)
    if races.track.altRoute and races.track.altRoute.checkpointRoad then
        aiRacers.preloadPathForRace(races.track.altRoute)
    end
end

local function onWorldReadyState(state)
    if state == 2 then
        races = utils.loadRaceData()
        preloadFreeroamAiPathsForTrack()
    end
end

local function loadExtensions()
    local freeroamPath = "/lua/ge/extensions/gameplay/events/freeroam/"
    local files = FS:findFiles(freeroamPath, "*.lua", -1, true, false)
    
    if files then
        for _, filePath in ipairs(files) do
            local filename = string.match(filePath, "([^/]+)%.lua$")

            if filename then
                local extensionName = "gameplay_events_freeroam_" .. filename
                setExtensionUnloadMode(extensionName, "manual")
                extensions.unload(extensionName)
                table.insert(loadedExtensions, extensionName)
            end
        end
    end
    loadManualUnloadExtensions()
end

local function unloadExtensions()
    for _, extensionName in ipairs(loadedExtensions) do
        extensions.unload(extensionName)
    end
end

local function onExtensionLoaded()
    loadExtensions()
    if getCurrentLevelIdentifier() then
        races = utils.loadRaceData()
        preloadFreeroamAiPathsForTrack()
    end
end

local function onExtensionUnloaded()
    unloadExtensions()
end

local function onUpdate(dtReal, dtSim, dtRaw)
    _G.freeroamHubSuppressUIMessages = isFreeroamHubActive()
    if aiRacers and aiRacers.onUpdate then aiRacers.onUpdate(dtReal or 0) end
    -- Hub race mode: staged flash + countdown (American Road style); use dtReal so it advances when paused
    if mFreeroamCountdownDelay then
        mFreeroamCountdownDelay = mFreeroamCountdownDelay - (dtReal or 0)
        if mFreeroamCountdownDelay <= 0 then
            mFreeroamCountdownDelay = nil
            if staged == "track" and aiRacers and aiRacers.startEnginesForSpawned then
                aiRacers.startEnginesForSpawned()
            end
            triggerRaceCountdown()
        end
    end
    if mFreeroamCountdownEndTime then
        mFreeroamCountdownEndTime = mFreeroamCountdownEndTime - (dtReal or 0)
        if mFreeroamCountdownEndTime <= 0 then
            mFreeroamCountdownEndTime = nil
            mFreeroamCountdownStartClock = nil
            local rn, sid
            if mFreeroamPendingStart and races[mFreeroamPendingStart.raceName] then
                rn = mFreeroamPendingStart.raceName
                sid = mFreeroamPendingStart.subjectID
            elseif staged and mFreeroamHubRaceSelected then
                rn = staged
                if not races[rn] and mFreeroamHubUseAltRoute then
                    for raceId, raceData in pairs(races) do
                        if raceData.altRoute then
                            rn = raceId
                            break
                        end
                    end
                end
                if races[rn] then
                    sid = mFreeroamStagingSubjectID or (be and be:getPlayerVehicleID(0))
                else
                    rn = nil
                end
            end
            mFreeroamPendingStart = nil
            mFreeroamStagedAtStart = false
            mFreeroamStagingSubjectID = nil
            if rn and sid then
                staged = nil
                beginFreeroamRace(rn, sid)
                -- Release AI racers on GO (track = main route or alt Short Track)
                if rn == "track" and aiRacers and aiRacers.releaseAndDrive and races and races.track then
                    local raceForAi = races.track
                    if mFreeroamHubUseAltRoute and races.track.altRoute and races.track.altRoute.checkpointRoad then
                        raceForAi = races.track.altRoute
                    end
                    local aiLaps = (raceForAi.lapCount and raceForAi.lapCount > 0) and raceForAi.lapCount or 3
                    aiRacers.releaseAndDrive(raceForAi, aiLaps)
                end
            end
        end
    end
    if mActiveRace and races[mActiveRace].checkpointRoad then
        if os.time() >= mSuppressOffRoadExitUntil and processRoad.checkPlayerOnRoad() == false then
            exitRace(false)
        end
    end
    if timerActive == true then
        in_race_time = in_race_time + dtSim
        local playerVehicleId = be:getPlayerVehicleID(0)
        if playerVehicleId then
            local currentSpeed = math.abs(be:getObjectVelocityXYZ(playerVehicleId)) * speedUnit
            if currentSpeed > maxSpeed then
                maxSpeed = currentSpeed
            end
        end
        
        -- Push live UI state: use same lap count and label as freeroamEvents UI message (e.g. "Short Track (Hotlap)", "Lap: 2")
        local race = races[mActiveRace] or {}
        local isLapRace = (race.lapCount and race.lapCount > 0) or race.hotlap
        local raceLabel = getRaceLabel()
        local leaderboardEntry = mInventoryId and leaderboardManager.getLeaderboardEntry(mInventoryId, raceLabel) or {}
        local bestLapFromHistory = leaderboardEntry.time

        -- Only push state periodically (e.g. every ~100ms) to avoid lagging the UI (only when hub active)
        if isFreeroamHubActive() and (in_race_time % 0.1) < dtSim then
            local sectorDeltas = {}
            for i = 1, checkpointsHit do
                local d = getDifference(mActiveRace, i)
                if d then sectorDeltas[i] = d end
            end
            -- displayLap = current lap number as shown in game (lapCount + 1); currentLap = lapCount for compatibility
            local lapNum = isLapRace and (lapCount + 1) or 1
            local state = {
                inRace = true,
                isPractice = false, -- freeroam events are always races
                staged = false,
                raceId = mActiveRace,
                raceLabel = raceLabel,
                currentLap = isLapRace and lapCount or 0,
                displayLap = lapNum,
                totalLaps = isLapRace and race.lapCount or 1,
                totalCheckpoints = totalCheckpoints,
                currentLapTime = in_race_time,
                topSpeedThisLap = maxSpeed,
                bestLapThisRun = mBestLapThisRun,
                bestLapFromHistory = bestLapFromHistory,
                invalidLap = invalidLap,
                routeName = mCurrentRouteName,
                splits = mSplitTimes,
                sectorDeltas = sectorDeltas
            }
            guihooks.trigger("FreeroamHubRaceState", state)
        end
    else
        in_race_time = 0
    end
end

local function formatEventPoi(raceName, race)
    local startObj = scenetree.findObject("fre_start_" .. raceName)
    local pos = startObj and startObj:getPosition() or nil
    
    if not pos then return nil end

    local levelIdentifier = getCurrentLevelIdentifier()
    local preview = "/levels/" .. levelIdentifier .. "/facilities/freeroamEvents/" .. raceName .. ".jpg"

    local vehId = be:getPlayerVehicleID(0) or 0
    if career_career.isActive() then
        vehId = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
    end

    return {
        id = raceName,
        data = {
            type = "events",
            facility = {}
        },
        markerInfo = {
            bigmapMarker = {
                pos = pos,
                icon = "mission_cup_triangle",
                name = race.label,
                description = utils.displayStagedMessage(vehId, raceName, true),
                previews = {preview},
                thumbnail = preview
            }
        }
    }
end

function M.onGetRawPoiListForLevel(levelIdentifier, elements)
    if not races then
        return
    end
    for raceName, race in pairs(races) do
        local poi = formatEventPoi(raceName, race)
        if poi then
            table.insert(elements, poi)
        end
    end
end

local function onReplayStateChanged(state)
    if not isReplay and state.state == "playback" then
        isReplay = true
    elseif isReplay and state.state == "inactive" then
        isReplay = false
    end
end

local function onGameStateUpdate(state)
    if saveGameState then
        saveGameState = false
        previousGameState = state
    end
end

M.onGameStateUpdate = onGameStateUpdate

M.onReplayStateChanged = onReplayStateChanged
M.onBeamNGTrigger = onBeamNGTrigger
M.onUpdate = onUpdate

M.payoutRace = payoutRace
M.payoutDragRace = payoutDragRace
M.onWorldReadyState = onWorldReadyState
M.getRace = function(raceName) return races[raceName] end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

M.onFreeroamHubRequestRaceHistory = function()
    mFreeroamHubShowingResult = false
    mFreeroamHubShowingHistory = true
    if not isFreeroamHubActive() then return end
    local inventoryId = mInventoryId
    if not inventoryId and career_modules_inventory then
        local vehId = be:getPlayerVehicleID(0)
        if vehId then
            inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
        end
    end
    local entries = {}
    if inventoryId then
        entries = leaderboardManager.getLeaderboardEntriesForVehicle(inventoryId)
    end
    guihooks.trigger("FreeroamHubRaceHistory", { entries = entries })
end

M.onFreeroamHubReady = function()
    loadFreeroamHubPrefs()
    -- Always send prefs so UI can show checkbox (e.g. opt back in when app opened from menu)
    guihooks.trigger("FreeroamHubPrefs", { autoShow = mFreeroamHubPrefs.autoShow })
    -- Only push hub state when hub is active (not opted out)
    if not isFreeroamHubActive() then return end
    if mActiveRace then
        local race = races[mActiveRace] or {}
        local isLapRace = (race.lapCount and race.lapCount > 0) or race.hotlap
        local raceLabel = getRaceLabel()
        local sectorDeltas = {}
        for i = 1, checkpointsHit do
            local d = getDifference(mActiveRace, i)
            if d then sectorDeltas[i] = d end
        end
        local leaderboardEntry = mInventoryId and leaderboardManager.getLeaderboardEntry(mInventoryId, raceLabel) or {}
        local bestLapFromHistory = leaderboardEntry.time
        local lapNum = isLapRace and (lapCount + 1) or 1
        local state = {
            inRace = true,
            isPractice = false,
            staged = false,
            raceId = mActiveRace,
            raceLabel = raceLabel,
            currentLap = isLapRace and lapCount or 0,
            displayLap = lapNum,
            totalLaps = isLapRace and race.lapCount or 1,
            totalCheckpoints = totalCheckpoints,
            currentLapTime = in_race_time,
            topSpeedThisLap = maxSpeed,
            bestLapThisRun = mBestLapThisRun,
            bestLapFromHistory = bestLapFromHistory,
            invalidLap = invalidLap,
            routeName = mCurrentRouteName,
            splits = mSplitTimes,
            sectorDeltas = sectorDeltas
        }
        guihooks.trigger("FreeroamHubSetAvailable", { available = true })
        guihooks.trigger("FreeroamHubRaceState", state)
    elseif staged then
        local race = races[staged] or {}
        local raceLabel = race.label or staged
        local state = { inRace = false, staged = true, raceId = staged, raceLabel = raceLabel }
        local vehId = be:getPlayerVehicleID(0)
        if vehId then
            state.stagedMessage = utils.displayStagedMessage(vehId, staged, true)
        end
        state.showRaceSelection = not mFreeroamHubRaceSelected
        guihooks.trigger("FreeroamHubSetAvailable", { available = true })
        guihooks.trigger("FreeroamHubRaceState", state)
    end
end

M.onFreeroamHubSetAutoShow = function(enable)
    if not getFreeroamHubPrefsPath() then return end
    loadFreeroamHubPrefs()
    mFreeroamHubPrefs.autoShow = (enable == true)
    saveFreeroamHubPrefs()
    if not mFreeroamHubPrefs.autoShow then
        utils.displayMessage("You can add the app later from the UI menu", 5, true)
    end
end

M.onFreeroamHubEndEvent = function()
    if not mActiveRace then return end
    if isFreeroamHubActive() then
        exitRace(false)
    end
end

-- Freeroam hub: set route to practice (unlimited laps, current behavior)
M.onFreeroamHubSelectPractice = function()
    mFreeroamHubPracticeMode = true
    mFreeroamHubUseAltRoute = false
    mFreeroamHubRaceSelected = false
end

-- Freeroam hub: set route to main track (e.g. set laps event, main route)
-- Spawn AI racers for track when player selects Track or Short Track and is staged at track (west_coast_usa style).
local function prepareFreeroamAiForTrack()
    if not aiRacers or not races or not races.track then return end
    if aiRacers.spawnForStagingWithPlayerHp then
        aiRacers.spawnForStagingWithPlayerHp("track", races.track, "track", function() end)
    elseif aiRacers.spawnForStaging then
        aiRacers.spawnForStaging("track", races.track, "track")
    end
end

M.onFreeroamHubSelectTrack = function()
    mFreeroamHubPracticeMode = false
    mFreeroamHubUseAltRoute = false
    mFreeroamHubRaceSelected = true
    if staged == "track" then
        prepareFreeroamAiForTrack()
    end
    -- If already in staging zone, show Staged and start countdown now
    if staged then
        showStagedFlashMessage()
        mFreeroamCountdownDelay = 1.0
        mFreeroamStagedAtStart = false
        mFreeroamPendingStart = nil
        mFreeroamStagingSubjectID = be and be:getPlayerVehicleID(0) or nil
    end
end

-- Freeroam hub: set route to short track / alt route
M.onFreeroamHubSelectShortTrack = function()
    mFreeroamHubPracticeMode = false
    mFreeroamHubUseAltRoute = true
    mFreeroamHubRaceSelected = true
    if staged == "track" then
        prepareFreeroamAiForTrack()
    end
    -- If already in staging zone, show Staged and start countdown now
    if staged then
        showStagedFlashMessage()
        mFreeroamCountdownDelay = 1.0
        mFreeroamStagedAtStart = false
        mFreeroamPendingStart = nil
        mFreeroamStagingSubjectID = be and be:getPlayerVehicleID(0) or nil
    end
end

-- Freeroam hub: Back button / clear selection
M.onFreeroamHubClearSelection = function()
    mFreeroamHubRaceSelected = false
    mFreeroamHubShowingResult = false
    hideStagedFlashMessage()
    mFreeroamCountdownDelay = nil
    mFreeroamCountdownEndTime = nil
    mFreeroamCountdownStartClock = nil
    mFreeroamStagedAtStart = false
    mFreeroamPendingStart = nil
    mFreeroamStagingSubjectID = nil
    if aiRacers and aiRacers.clearSpawned then aiRacers.clearSpawned() end
end

M.onFreeroamHubClosed = function()
    mFreeroamHubShowingResult = false
    mFreeroamHubShowingHistory = false
    if previousGameState then
        core_gamestate.setGameState(previousGameState.state, previousGameState.appLayout, previousGameState.menuItems, previousGameState.options)
        previousGameState = nil
        saveGameState = false
    end
end

return M