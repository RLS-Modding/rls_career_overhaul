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
local Assets = activeAssets.ActiveAssets.new()

local timerActive = false
local mActiveRace
local staged = nil
local in_race_time = 0

local speedUnit = 2.2369362921
local lapCount = 0
local currCheckpoint = nil
local mHotlap = nil
local mAltRoute = nil
local mSplitTimes = {}
local isLoop = false
local checkpointsHit = 0
local totalCheckpoints = 0
local currentExpectedCheckpoint = 1
local invalidLap = false

local mInventoryId = nil
local newBestSession = false

local races = nil
local isReplay = false

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

local function payoutRace()
    if not mActiveRace then
        return 0
    end

    local race = races[mActiveRace]
    local time = race.bestTime
    local reward = race.reward
    local raceLabel = race.label

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

    -- Calculate scores and rewards
    local driftScore = 0
    if race.driftGoal then
        driftScore = getDriftScore()
        reward = utils.driftReward(races[mActiveRace], time, driftScore)
    else
        reward = utils.raceReward(time, reward, in_race_time)
    end

    -- Handle leaderboard
    local leaderboardEntry = leaderboardManager.getLeaderboardEntry(mInventoryId, raceLabel)

    local oldTime = leaderboardEntry and leaderboardEntry.time or 0
    local oldScore = leaderboardEntry and leaderboardEntry.driftScore or 0

    local newEntry = {
        raceName = mActiveRace,
        raceLabel = raceLabel,
        isAltRoute = mAltRoute,
        isHotlap = mHotlap == mActiveRace,
        time = in_race_time,
        splitTimes = mSplitTimes,
        driftScore = driftScore,
        inventoryId = mInventoryId
    }

    local newBest = leaderboardManager.addLeaderboardEntry(newEntry)

    -- Build the base message that's shown regardless of career mode
    local message = invalidLap and "Lap Invalidated\n" or ""

    if race.driftGoal then
        message = message ..
                      string.format("%s\nDrift Score: %d\nTime: %s", raceLabel, driftScore,
                utils.formatTime(in_race_time))
        if oldScore and oldTime then
            message = message ..
                          string.format("\nPrevious Best Score: %d\nPrevious Best Time: %s", oldScore,
                    utils.formatTime(oldTime))
        end
    else
        if newBest and not invalidLap then
            message = message .. "New Best Time!\n"
        end
        if race.hotlap then
            message = message ..
                          string.format("%s\nTime: %s\nLap: %d", raceLabel, utils.formatTime(in_race_time), lapCount)
        else
            message = message .. string.format("%s\nTime: %s", raceLabel, utils.formatTime(in_race_time))
        end
        if newBest and not invalidLap and oldTime ~= math.huge then
            message = message .. string.format("\nPrevious Best: %s", utils.formatTime(oldTime))
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
            local xp = math.floor(reward / 20)
            local totalReward = {
                money = {
                    amount = reward
                },
                beamXP = {
                    amount = math.floor(xp / 10)
                },
                vouchers = {
                    amount = (oldTime == 0 or oldTime > time) and in_race_time < time and 1 or 0
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
    if career_career.isActive() then
        vehId = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
    end

    local leaderboardEntry = leaderboardManager.getLeaderboardEntry(vehId, races["drag"].label)
    local oldTime = leaderboardEntry and leaderboardEntry.time or 0

    local newEntry = {
        raceLabel = races["drag"].label,
        raceName = raceName,
        time = finishTime,
        splitTimes = mSplitTimes,
        inventoryId = vehId
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
    local reward = utils.raceReward(targetTime, baseReward, finishTime)
    if reward <= 0 then
        reward = baseReward / 2 -- Minimum reward for completion
    end

    reward = reward / (career_modules_hardcore.isHardcoreMode() and 2 or 1)

    reward = newBestTime and reward or reward / 2

    -- Calculate experience points
    local xp = math.floor(reward / 20)

    -- Prepare total reward
    local totalReward = {
        money = {
            amount = reward
        },
        beamXP = {
            amount = math.floor(xp / 10)
        },
        vouchers = {
            amount = newBestTime and 1 or 0
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

local function exitRace()
    if mActiveRace then
        utils.setActiveLight(mActiveRace, "red")
        lapCount = 0
        mActiveRace = nil
        timerActive = false
        mHotlap = nil
        currCheckpoint = nil
        mSplitTimes = {}
        mAltRoute = false
        invalidLap = false
        mInventoryId = nil
        Assets:hideAllAssets()
        checkpointManager.removeCheckpoints()
        utils.displayMessage("You exited the race zone, Race cancelled", 3)
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
    end
end

local function onBeamNGTrigger(data)
    if be:getPlayerVehicleID(0) ~= data.subjectID or isReplay then
        return
    end
    if gameplay_walk.isWalking() then return end
    if career_career.isActive() then
        if not career_modules_inventory.getInventoryIdFromVehicleId(data.subjectID) then
            return
        end
        local vehicle = career_modules_inventory.getVehicles()[career_modules_inventory.getInventoryIdFromVehicleId(data.subjectID)]
        if vehicle.loanType then
            return
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
            if utils.isPlayerInPursuit() then
                utils.displayMessage("You cannot stage for an event while in a pursuit.", 2)
                return
            end

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

            -- Initialize displays if drag race
            if raceName == "drag" then
                utils.initDisplays()
                utils.resetDisplays()
            end

            -- Set staged race
            staged = raceName
            -- print("Staged race: " .. raceName)
            local vehId = data.subjectID
            if career_career.isActive() then
                vehId = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
            end
            utils.displayStagedMessage(vehId, raceName)
            utils.setActiveLight(raceName, "yellow")
        elseif event == "exit" then
            staged = nil
            if not mActiveRace then
                utils.displayMessage("You exited the staging zone", 4)
                utils.setActiveLight(raceName, "red")
            end
        end
    elseif triggerType == "start" then
        if event == "enter" and mActiveRace == raceName and not utils.hasFinishTrigger(raceName) then
            if not currCheckpoint or checkpointsHit ~= totalCheckpoints then
                -- Player hasn't completed all checkpoints yet
                if not invalidLap then
                    utils.displayMessage("You have not completed all checkpoints!", 5)
                    return
                end
            end
            checkpointManager.setRace(races[raceName], raceName)
            Assets:displayAssets(data)
            utils.playCheckpointSound()
            timerActive = false
            lapCount = lapCount + 1
            local reward = payoutRace()
            currCheckpoint = nil
            mSplitTimes = {}
            mActiveRace = raceName
            checkpointManager.setAltRoute(false)
            mAltRoute = false
            in_race_time = 0
            timerActive = true
            checkpointsHit = 0
            totalCheckpoints = checkpointManager.calculateTotalCheckpoints()
            currentExpectedCheckpoint = 0
            if races[raceName].hotlap then
                mHotlap = raceName
                currentExpectedCheckpoint = checkpointManager.enableCheckpoint(0)
            end
            invalidLap = false
        elseif event == "enter" and staged == raceName then
            -- Start the race
            if career_career.isActive() then
                career_modules_pauseTime.enablePauseCounter(true)
            end
            utils.saveAndSetTrafficAmount(0)
            checkpointManager.setRace(races[raceName], raceName)
            Assets:displayAssets(data)
            timerActive = true
            in_race_time = 0
            mActiveRace = raceName
            lapCount = 0
            mInventoryId = career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId(data.subjectID) or data.subjectID
            invalidLap = false

            utils.displayStartMessage(raceName)
            utils.setActiveLight(raceName, "green")

            -- Handle drift races
            if utils.tableContains(races[raceName].type, "drift") then
                gameplay_drift_general.setContext("inChallenge")
                gameplay_drift_general.reset()
                if gameplay_drift_drift then
                    gameplay_drift_drift.setVehId(data.subjectID)
                end
            end

            -- Initialize checkpoints if applicable
            if races[raceName].checkpointRoad then
                -- Clear existing nodes and checkpoints
                processRoad.reset()
                local checkpoints, altCheckpoints = processRoad.getCheckpoints(races[raceName])

                checkpointManager.createCheckpoints(checkpoints, altCheckpoints)

                isLoop = processRoad.isLoop()
                currCheckpoint = 0
                checkpointsHit = 0
                totalCheckpoints = checkpointManager.calculateTotalCheckpoints(races[raceName])
                currentExpectedCheckpoint = 1
                mAltRoute = false -- Initialize alt route flag
                checkpointManager.setAltRoute(mAltRoute)

                currentExpectedCheckpoint = checkpointManager.enableCheckpoint(0)
            end
        else
            -- Player is not staged or race is not active
            utils.setActiveLight(raceName, "red")
        end
    elseif triggerType == "checkpoint" and checkpointIndex then
        if event == "enter" and mActiveRace == raceName then
            -- Ensure that the checkpoint is the expected one
            if (checkpointIndex == currentExpectedCheckpoint) or (checkpointIndex == 1 and isAlt) or
                (isAlt and (currentExpectedCheckpoint == races[raceName].altRoute.mergeCheckpoints[1])) then
                checkpointsHit = checkpointsHit + 1
                currCheckpoint = checkpointIndex
                mSplitTimes[checkpointsHit] = in_race_time
                utils.playCheckpointSound()

                -- Prepare the next checkpoint
                if isAlt then
                    currentExpectedCheckpoint = checkpointIndex
                end

                currentExpectedCheckpoint = checkpointManager.enableCheckpoint(checkpointIndex, isAlt)
                if isAlt and not mAltRoute then
                    mAltRoute = true
                    checkpointManager.setAltRoute(true)
                    totalCheckpoints = checkpointManager.calculateTotalCheckpoints(races[raceName])
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
            -- Finish the race
            timerActive = false
            currCheckpoint = nil
            payoutRace()
            Assets:hideAllAssets()

            if raceName == "drag" then
                -- For drag races, update the display
                local side = "l" -- Determine side based on context if necessary
                utils.updateDisplay(side, in_race_time, math.abs(be:getObjectVelocityXYZ(data.subjectID)) * speedUnit)
            end
            if utils.tableContains(races[raceName].type, "drift") then
                local finalScore = getDriftScore()
                if gameplay_drift_general.getContext() == "inChallenge" then
                    gameplay_drift_general.setContext("inFreeRoam")
                    -- print("Final Drift Score: " .. tostring(math.floor(finalScore)), 1, "info")
                end
            end

            mSplitTimes = {}
            mActiveRace = nil
            utils.setActiveLight(raceName, "red")
            core_jobsystem.create(function(job)
                job.sleep(10)
            utils.restoreTrafficAmount()
            end)
            if career_career.isActive() then
                career_modules_pauseTime.enablePauseCounter()
            end
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

local function onWorldReadyState(state)
    if state == 2 then
        races = utils.loadRaceData()
    end
end

local function loadExtensions()
    print("Initializing Freeroam Events Modules")

    local freeroamPath = "/lua/ge/extensions/gameplay/events/freeroam/"
    local files = FS:findFiles(freeroamPath, "*.lua", -1, true, false)
    
    if files then
        for _, filePath in ipairs(files) do
            local filename = string.match(filePath, "([^/]+)%.lua$")

            if filename then
                local extensionName = "gameplay_events_freeroam_" .. filename
                setExtensionUnloadMode(extensionName, "manual")
                print("Loaded extension: " .. extensionName)
            end
        end
    end
    loadManualUnloadExtensions()
end

local function onExtensionLoaded()
    print("Initializing Freeroam Events Main")
    loadExtensions()
    if getCurrentLevelIdentifier() then
        races = utils.loadRaceData()
        if races ~= {} then
            print("Race data loaded for level: " .. getCurrentLevelIdentifier())
        else
            print("No race data found for level: " .. getCurrentLevelIdentifier())
        end
    end
end

local function onUpdate(dtReal, dtSim, dtRaw)

    -- This function updates the race time.
    -- It increments the in_race_time if the timer is active.
    --
    -- Parameters:
    --   dtReal (number): Real delta time.
    --   dtSim (number): Simulated delta time.
    --   dtRaw (number): Raw delta time.
    if mActiveRace and races[mActiveRace].checkpointRoad then
        if processRoad.checkPlayerOnRoad() == false then
            exitRace()
        end
    end
    if timerActive == true then
        in_race_time = in_race_time + dtSim
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

M.onReplayStateChanged = onReplayStateChanged
M.onBeamNGTrigger = onBeamNGTrigger
M.onUpdate = onUpdate

M.payoutRace = payoutRace
M.payoutDragRace = payoutDragRace
M.onWorldReadyState = onWorldReadyState
M.getRace = function(raceName) return races[raceName] end

M.onExtensionLoaded = onExtensionLoaded

return M