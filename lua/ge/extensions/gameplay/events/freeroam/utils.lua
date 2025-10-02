local M = {}

local leaderboardManager = require('gameplay/events/freeroam/leaderboardManager')

local previousTrafficAmount = nil

local leftTimeDigits = {}
local rightTimeDigits = {}
local leftSpeedDigits = {}
local rightSpeedDigits = {}

local races = {}

local checkpointSoundPath = 'art/sound/ui_checkpoint.ogg'

-- Function to play the checkpoint sound
local function playCheckpointSound()
  Engine.Audio.playOnce('AudioGui', checkpointSoundPath, {
    volume = 2
  })
end

local function updateDisplay(side, finishTime, finishSpeed)
  local timeDisplayValue = {}
  local speedDisplayValue = {}
  local timeDigits = {}
  local speedDigits = {}

  if side == "r" then
    timeDigits = rightTimeDigits
    speedDigits = rightSpeedDigits
  elseif side == "l" then
    timeDigits = leftTimeDigits
    speedDigits = leftSpeedDigits
  end

  if finishTime < 10 then
    table.insert(timeDisplayValue, "empty")
  end

  if finishSpeed < 100 then
    table.insert(speedDisplayValue, "empty")
  end

  -- Three decimal points for time
  for num in string.gmatch(string.format("%.3f", finishTime), "%d") do
    table.insert(timeDisplayValue, num)
  end

  -- Two decimal points for speed
  for num in string.gmatch(string.format("%.2f", finishSpeed), "%d") do
    table.insert(speedDisplayValue, num)
  end

  if #timeDisplayValue > 0 and #timeDisplayValue < 6 then
    for i, v in ipairs(timeDisplayValue) do
      timeDigits[i]:preApply()
      timeDigits[i]:setField('shapeName', 0, "art/shapes/quarter_mile_display/display_" .. v .. ".dae")
      timeDigits[i]:setHidden(false)
      timeDigits[i]:postApply()
    end
  end

  for i, v in ipairs(speedDisplayValue) do
    speedDigits[i]:preApply()
    speedDigits[i]:setField('shapeName', 0, "art/shapes/quarter_mile_display/display_" .. v .. ".dae")
    speedDigits[i]:setHidden(false)
    speedDigits[i]:postApply()
  end
end

local function clearDisplay(digits)
  for i = 1, #digits do
    digits[i]:setHidden(true)
  end
end

local function resetDisplays()
  clearDisplay(leftTimeDigits)
  clearDisplay(rightTimeDigits)
  clearDisplay(leftSpeedDigits)
  clearDisplay(rightSpeedDigits)
end

local function initDisplays()
  -- Creating a table for the TStatics that are being used to display drag time and final speed

  if #leftTimeDigits > 0 or #rightTimeDigits > 0 or #leftSpeedDigits > 0 or #rightSpeedDigits > 0 then
    return
  end

  for i = 1, 5 do
    local leftTimeDigit = scenetree.findObject("display_time_" .. i .. "_l")
    table.insert(leftTimeDigits, leftTimeDigit)

    local rightTimeDigit = scenetree.findObject("display_time_" .. i .. "_r")
    table.insert(rightTimeDigits, rightTimeDigit)

    local rightSpeedDigit = scenetree.findObject("display_speed_" .. i .. "_r")
    table.insert(rightSpeedDigits, rightSpeedDigit)

    local leftSpeedDigit = scenetree.findObject("display_speed_" .. i .. "_l")
    table.insert(leftSpeedDigits, leftSpeedDigit)
  end
  resetDisplays()
end

local function displayMessage(message, duration)
  ui_message(message, duration, "info", "info")
end

local function onPursuitAction(id, pursuitData)
  local playerVehicleId = be:getPlayerVehicleID(0)

  if id == playerVehicleId then
    if pursuitData.type == "start" then
      playerInPursuit = true
    elseif pursuitData.type == "evade" or pursuitData.type == "reset" then
      playerInPursuit = false
    elseif pursuitData.type == "arrest" then
      playerInPursuit = false
    end
  end
end

local function hasFinishTrigger(race)
  return scenetree.findObject("fre_finish_" .. race) ~= nil
end

local function saveAndSetTrafficAmount(amount)
  if gameplay_traffic then
    previousTrafficAmount = gameplay_traffic.getNumOfTraffic()
    gameplay_traffic.setActiveAmount(amount or 0)
  else
    print("Warning: gameplay_traffic not available")
  end
end

local function restoreTrafficAmount()
  if gameplay_traffic then
    local settingsAmount = settings.getValue('trafficAmount') == 0 and getMaxVehicleAmount() or
                             settings.getValue('trafficAmount')
    local trafficAmount = settingsAmount or previousTrafficAmount
    local pooledAmount = settings.getValue('trafficExtraAmount') or 0
    gameplay_traffic.setActiveAmount(trafficAmount + pooledAmount, trafficAmount)
  end
end

local function formatTime(seconds)
  local sign = seconds < 0 and "-" or ""
  seconds = math.abs(seconds)

  local minutes = math.floor(seconds / 60)
  local remainingSeconds = seconds % 60
  local wholeSeconds = math.floor(remainingSeconds)
  local hundredths = math.floor((remainingSeconds - wholeSeconds) * 100)

  return string.format("%s%02d:%02d:%02d", sign, minutes, wholeSeconds, hundredths)
end

local function tableContains(tbl, val)
  for _, v in ipairs(tbl) do
    if v == val then
      return true
    end
  end
  return false
end

-- Helper function to calculate average multiplier from non-zero race types
local function calculateAverageMultiplier(raceTypes)
  if not career_economyAdjuster or not raceTypes or #raceTypes == 0 then
    return 1.0
  end

  local totalMultiplier = 0
  local nonZeroCount = 0

  for _, raceType in ipairs(raceTypes) do
    local typeMultiplier = career_economyAdjuster.getEffectiveSectionMultiplier({raceType})
    if typeMultiplier > 0 then
      totalMultiplier = totalMultiplier + typeMultiplier
      nonZeroCount = nonZeroCount + 1
    end
  end

  -- Return average of non-zero multipliers, or 0 if all are disabled
  return nonZeroCount > 0 and (totalMultiplier / nonZeroCount) or 0
end

local function raceReward(goal, reward, time, raceTypes)
  -- The raceReward function calculates the reward based on the time taken to complete the race.
  -- If the actual time is greater than the ideal time, the reward (y) is reduced proportionally.
  -- If the actual time is less than or equal to the ideal time, the reward (y) is increased exponentially.
  --
  -- Parameters:
  --   x (number): Ideal time for the race.
  --   y (number): Base reward for the race.
  --   z (number, optional): Actual time taken to complete the race. Defaults to in_race_time.
  --   raceTypes (table, optional): Array of race types for multiplier calculation
  --
  -- Returns:
  --   number: Calculated reward based on the time taken.
  local x = goal
  local y = reward
  local z = time
  z = z
  if z == 0 then
    return 0
  end

  -- Calculate base reward
  local baseReward
  local ratio = x / z
  if ratio < 1 then
    baseReward = math.floor(ratio * y * 100) / 100
  else
    baseReward = math.floor((math.pow(ratio, (1 + (y / 500)))) * y * 100) / 100
    if baseReward > y * 30 then
      baseReward = y * 30
    end
  end

  -- Apply average multiplier if race types are provided
  if raceTypes and career_economyAdjuster then
    local multiplier = calculateAverageMultiplier(raceTypes)
    baseReward = baseReward * multiplier
    baseReward = math.floor(baseReward + 0.5) -- Round to nearest integer
  end

  return baseReward
end

local function driftReward(race, time, driftScore)
  local goalTime = race.bestTime
  local goalDrift = race.driftGoal
  local timeFactor = (goalTime / time) ^ 1.2
  local driftFactor = (driftScore / goalDrift) ^ 1.2
  return race.reward * timeFactor * driftFactor
end

local function topSpeedReward(goalSpeed, baseReward, actualSpeed, raceTypes)
  if actualSpeed == 0 then
    return 0
  end

  local baseRewardValue
  local ratio = actualSpeed / goalSpeed
  if ratio < 1 then
    baseRewardValue = math.floor(ratio * baseReward * 100) / 100
  else
    baseRewardValue = math.floor((math.pow(ratio, (1 + (baseReward / 500)))) * baseReward * 100) / 100
    if baseRewardValue > baseReward * 30 then
      baseRewardValue = baseReward * 30
    end
  end

  if raceTypes and career_economyAdjuster then
    local multiplier = calculateAverageMultiplier(raceTypes)
    baseRewardValue = baseRewardValue * multiplier
    baseRewardValue = math.floor(baseRewardValue + 0.5)
  end

  return baseRewardValue
end

local function hybridRaceReward(goalTime, baseReward, actualTime, damageFactor, damagePercentage, raceTypes)
  if damageFactor == 0 then
    return raceReward(goalTime, baseReward, actualTime, raceTypes)
  end

  if damageFactor == 1 then
    local damageReward = baseReward * (1 - damagePercentage)
    -- Apply average multiplier to damage reward if race types are provided
    if raceTypes and career_economyAdjuster then
      local multiplier = calculateAverageMultiplier(raceTypes)
      damageReward = damageReward * multiplier
      damageReward = math.floor(damageReward + 0.5)
    end
    return math.max(0, damageReward)
  end

  local timeReward = raceReward(goalTime, baseReward, actualTime, raceTypes)

  local finalReward = (baseReward * (1 - damagePercentage)) + (damageFactor * timeReward)

  return math.max(0, finalReward)
end

local function hotlapMultiplier(lapCount)
  return (10 / (1 + math.exp(-0.07 * (lapCount - 17)))) - 1.35
end

local motivationalMessages = { -- Enthusiastic
"Give it your all!", "Time to shine!", "Let's set a new record!", "It's go time!", -- Funny
"Try not to hit any trees this time!", "Remember, the brake is the other pedal!",
"First one to the finish line gets a cookie!", "Drive like you stole it... wait, you didn't, right?",

-- Passive-aggressive
"Try to keep it on the track this time, okay?", "Let's see if you've improved since last time...",
"Maybe today you'll actually finish the race?",
"I'm sure you'll do better than your last attempt. It can't get worse, right?", -- Encouraging
"Believe in yourself, you've got this!", "Today could be your personal best!",
"Focus and breathe, you're ready for this!", "Every second counts, make them all yours!", -- Challenging
"Think you can handle this? Prove it!", "Show us what you're really made of!",
"This track has beaten you before. Not today!", "Time to separate the rookies from the pros!", -- Quirky
"May the downforce be with you!", "Remember: turn left to go left, right to go right!",
"Gravity is just a suggestion, right?", "If in doubt, flat out! (Results may vary)", -- Intense
"Push it to the limit!", "Leave nothing on the table!", "Drive like your life depends on it!", "It's now or never!"}

local function displayStartMessage(raceName)
  local race = races[raceName]
  local message

  if math.random() < 0.5 then
    message = "GO!"
  else
    message = motivationalMessages[math.random(#motivationalMessages)]
  end

  message = string.format("**%s Event Started!\n%s**", race.label, message)
  displayMessage(message, 5)
end

local function getRaceLabel(raceName, altRoute, hotlap)
  local race = races[raceName]
  local raceLabel = race.label

  if altRoute then
    raceLabel = race.altRoute.label
  end
  if hotlap then
    raceLabel = raceLabel .. " (Hotlap)"
  end
  return raceLabel
end

local function displayStagedMessage(vehId, raceName, getMessage)
  if career_career.isActive() then
    vehId = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
  end
  local race = races[raceName]
  local leaderboardEntry = leaderboardManager.getLeaderboardEntry(vehId, getRaceLabel(raceName)) or {}
  local careerMode = career_career.isActive()

  -- Check if ALL race types are disabled (only disable if every type is 0)
  local allTypesDisabled = false
  local disabledTypes = {}
  if career_economyAdjuster and race.type then
    local totalTypes = 0
    local disabledCount = 0

    for _, raceType in ipairs(race.type) do
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

  local message = ""
  if allTypesDisabled then
    -- Show disabled message
    local typesString = table.concat(disabledTypes, ", ")
    message = string.format("%s is currently disabled due to %s multiplier(s) being set to 0.", race.label, typesString)
    if not getMessage then
      displayMessage(message, 5)
    end
    return getMessage and message or nil
  else
    -- Normal staging message
    if not getMessage then
      message = string.format("Staged for %s.\n", race.label)
    end
  end

  local function addTimeInfo(bestTime, targetTime, reward, label, raceData)

    if not bestTime then
      if careerMode then
        local adjustedBaseReward = raceReward(targetTime, reward, targetTime, raceData and raceData.type or nil)
        return string.format("%sTarget Time: %s\n(Achieve this to earn a reward of $%.2f)", label,
          formatTime(targetTime), adjustedBaseReward)
      else
        return string.format("%sTarget Time: %s", label, formatTime(targetTime))
      end
    elseif bestTime > targetTime then
      if careerMode then
        local adjustedBaseReward = raceReward(targetTime, reward, targetTime, raceData and raceData.type or nil)
        return string.format(
          "%sYour Best Time: %s | Target Time: %s\n(Achieve target to earn a reward of $%.2f)", label,
          formatTime(bestTime), formatTime(targetTime), adjustedBaseReward)
      else
        return string.format("%sYour Best Time: %s | Target Time: %s", label, formatTime(bestTime),
          formatTime(targetTime))
      end
    else
      if careerMode then
        local adjustedPotentialReward = raceReward(targetTime, reward, bestTime, raceData and raceData.type or nil)
        return string.format("%sYour Best Time: %s\n(Improve to earn at least $%.2f)", label, formatTime(bestTime),
          adjustedPotentialReward)
      else
        return string.format("%sYour Best Time: %s", label, formatTime(bestTime))
      end
    end
  end

  local function addHybridRaceInfo(leaderboardEntry, targetTime, reward, label, damageFactor, raceData)
    local bestTime = leaderboardEntry and leaderboardEntry.time or nil
    local bestDamagePercentage = leaderboardEntry and leaderboardEntry.damagePercentage or nil

    if not bestTime then
      if careerMode then
        local adjustedBaseReward = hybridRaceReward(targetTime, reward, targetTime, damageFactor, 0,
          raceData and raceData.type or nil)
        if damageFactor == 1 then
          return string.format(
            "%sTarget Time: %s | Target: No Damage\n(Achieve both to earn a reward of $%.2f and 1 Bonus Star)", label,
            formatTime(targetTime), adjustedBaseReward)
        else
          return string.format(
            "%sTarget Time: %s | Damage Factor: %.0f%%\n(Speed and damage both matter - achieve target time with minimal damage to earn up to $%.2f and 1 Bonus Star)",
            label, formatTime(targetTime), damageFactor * 100, adjustedBaseReward)
        end
      else
        return string.format("%sTarget Time: %s | Damage Factor: %.0f%%", label, formatTime(targetTime),
          damageFactor * 100)
      end
    else
      local damageText = bestDamagePercentage and string.format(" | Best Damage: %.1f%%", bestDamagePercentage * 100) or
                           ""
      if careerMode then
        if damageFactor == 1 then
          return string.format(
            "%sYour Best Time: %s%s | Target: No Damage\n(Improve time or reduce damage to earn more rewards)", label,
            formatTime(bestTime), damageText)
        else
          return string.format(
            "%sYour Best Time: %s%s | Damage Factor: %.0f%%\n(Speed and damage both matter - improve either to earn more rewards)",
            label, formatTime(bestTime), damageText, damageFactor * 100)
        end
      else
        return string.format("%sYour Best Time: %s%s | Damage Factor: %.0f%%", label, formatTime(bestTime), damageText,
          damageFactor * 100)
      end
    end
  end

  if race.topSpeed then
    local bestSpeed = leaderboardEntry and leaderboardEntry.topSpeed or nil
    local bestTime = leaderboardEntry and leaderboardEntry.time or nil
    local targetSpeed = race.topSpeedGoal

    if bestSpeed and bestTime then
      if careerMode then
        local adjustedReward = topSpeedReward(targetSpeed, race.reward, bestSpeed, race.type)
        message = message .. string.format(
          "Your Best Speed: %.2f mph | Target Speed: %.2f mph\nYour Best Time: %s\n(Improve to earn at least $%.2f)",
          bestSpeed, targetSpeed, formatTime(bestTime), adjustedReward)
      else
        message = message .. string.format(
          "Your Best Speed: %.2f mph | Target Speed: %.2f mph\nYour Best Time: %s",
          bestSpeed, targetSpeed, formatTime(bestTime))
      end
    else
      if careerMode then
        local adjustedReward = topSpeedReward(targetSpeed, race.reward, targetSpeed, race.type)
        message = message .. string.format(
          "Target Speed: %.2f mph\n(Achieve this to earn a reward of $%.2f and 1 Bonus Star)",
          targetSpeed, adjustedReward)
      else
        message = message .. string.format("Target Speed: %.2f mph", targetSpeed)
      end
    end
  elseif race.driftGoal then
    -- Handle drift event staging message
    local bestScore = leaderboardEntry.driftScore
    local bestTime = leaderboardEntry.time
    local targetScore = race.driftGoal
    local targetTime = race.driftTargetTime or race.bestTime

    if bestScore and bestTime then
      -- Show player's best score and time
      if careerMode then
        message = message .. string.format(
          "Your Best Drift Score: %d | Target Drift Score: %d\nYour Best Time: %s | Target Time: %s\n(Achieve targets to earn a reward of $%.2f and 1 Bonus Star)",
          bestScore, targetScore, formatTime(bestTime), formatTime(targetTime), race.reward)
      else
        message = message ..
                    string.format(
            "Your Best Drift Score: %d | Target Drift Score: %d\nYour Best Time: %s | Target Time: %s", bestScore,
            targetScore, formatTime(bestTime), formatTime(targetTime))
      end
    else
      -- No previous best score/time
      if careerMode then
        message = message ..
                    string.format(
            "Target Drift Score: %d\nTarget Time: %s\n(Achieve these to earn a reward of $%.2f and 1 Bonus Star)",
            targetScore, formatTime(targetTime), race.reward)
      else
        message = message ..
                    string.format("Target Drift Score: %d\nTarget Time: %s", targetScore, formatTime(targetTime))
      end
    end
  elseif race.damageFactor and race.damageFactor > 0 then
    -- Handle damage-based race staging message
    message = message .. addHybridRaceInfo(leaderboardEntry, race.bestTime, race.reward, "", race.damageFactor, race)
  else
    message = message ..
                addTimeInfo(leaderboardEntry and leaderboardEntry.time or nil, race.bestTime, race.reward, "", race)
  end

  -- Handle hotlap if it exists
  if race.hotlap then
    leaderboardEntry = leaderboardManager.getLeaderboardEntry(vehId, getRaceLabel(raceName, nil, true))
    if race.damageFactor and race.damageFactor > 0 then
      message = message .. "\n\n" ..
                  addHybridRaceInfo(leaderboardEntry, race.hotlap, race.reward, "Hotlap: ", race.damageFactor, race)
    else
      message = message .. "\n\n" ..
                  addTimeInfo(leaderboardEntry and leaderboardEntry.time or nil, race.hotlap, race.reward, "Hotlap: ",
          race)
    end
  end

  -- Handle alternative route if it exists
  if race.altRoute then
    leaderboardEntry = leaderboardManager.getLeaderboardEntry(vehId, getRaceLabel(raceName, true))
    message = message .. "\n\nAlternative Route:\n"
    if race.altRoute.damageFactor and race.altRoute.damageFactor > 0 then
      message = message ..
                  addHybridRaceInfo(leaderboardEntry, race.altRoute.bestTime, race.altRoute.reward, "",
          race.altRoute.damageFactor, race.altRoute)
    else
      message = message ..
                  addTimeInfo(leaderboardEntry and leaderboardEntry.time or nil, race.altRoute.bestTime,
          race.altRoute.reward, "", race.altRoute)
    end

    if race.altRoute.hotlap then
      leaderboardEntry = leaderboardManager.getLeaderboardEntry(vehId, getRaceLabel(raceName, true, true))
      if race.altRoute.damageFactor and race.altRoute.damageFactor > 0 then
        message = message .. "\n\n" ..
                    addHybridRaceInfo(leaderboardEntry, race.altRoute.hotlap, race.altRoute.reward,
            "Alt Route Hotlap: ", race.altRoute.damageFactor, race.altRoute)
      else
        message = message .. "\n\n" ..
                    addTimeInfo(leaderboardEntry and leaderboardEntry.time or nil, race.altRoute.hotlap,
            race.altRoute.reward, "Alt Route Hotlap: ", race.altRoute)
      end
    end
  end

  -- Add note for time-based events in career mode
  if careerMode and not race.driftGoal and not race.topSpeed then
    if race.damageFactor and race.damageFactor > 0 then
      message = message ..
                  "\n\n**Note: All rewards are cut by 50% if they are below your best score. Score is calculated based on both time and damage.**"
    else
      message = message .. "\n\n**Note: All rewards are cut by 50% if they are below your best time.**"
    end
  elseif careerMode and race.topSpeed then
    message = message .. "\n\n**Note: All rewards are cut by 50% if they are below your best speed.**"
  end

  if not getMessage then
    displayMessage(message, 15)
    return
  end
  return message
end

local function setActiveLight(event, color)
  local yellow = scenetree.findObject(event .. "_Yellow")
  local red = scenetree.findObject(event .. "_Red")
  local green = scenetree.findObject(event .. "_Green")
  if yellow then
    yellow:setHidden(color ~= "yellow")
  end
  if red then
    red:setHidden(color ~= "red")
  end
  if green then
    green:setHidden(color ~= "green")
  end

end

local function getVehicleDamage()
  local playerVehicleId = be:getPlayerVehicleID(0)
  return map.objects[playerVehicleId] and map.objects[playerVehicleId].damage or 0
end

local playerInPursuit = false

local function onPursuitAction(id, pursuitData)
  local playerVehicleId = be:getPlayerVehicleID(0)

  if id == playerVehicleId then
    if pursuitData.type == "start" then
      playerInPursuit = true
    elseif pursuitData.type == "evade" or pursuitData.type == "reset" then
      playerInPursuit = false
    elseif pursuitData.type == "arrest" then
      playerInPursuit = false
    end
  end
end

local function loadRaceData()
  if getCurrentLevelIdentifier() then
    local level = "levels/" .. getCurrentLevelIdentifier() .. "/race_data.json"
    local raceData = jsonReadFile(level)
    if raceData then
      races = raceData.races or {}
    end
    return deepcopy(races)
  end
  return {}
end

local function onExtensionLoaded()
  if getCurrentLevelIdentifier() then
    loadRaceData()
  end
  print("Initializing Freeroam Utils and Extensions")
end

M.onPursuitAction = onPursuitAction
M.playCheckpointSound = playCheckpointSound
M.displayStartMessage = displayStartMessage
M.displayStagedMessage = displayStagedMessage
M.displayMessage = displayMessage
M.formatTime = formatTime
M.raceReward = raceReward
M.driftReward = driftReward
M.topSpeedReward = topSpeedReward
M.hybridRaceReward = hybridRaceReward
M.hotlapMultiplier = hotlapMultiplier
M.saveAndSetTrafficAmount = saveAndSetTrafficAmount
M.restoreTrafficAmount = restoreTrafficAmount
M.tableContains = tableContains
M.hasFinishTrigger = hasFinishTrigger
M.setActiveLight = setActiveLight
M.loadRaceData = loadRaceData
M.calculateAverageMultiplier = calculateAverageMultiplier
M.onExtensionLoaded = onExtensionLoaded
M.getVehicleDamage = getVehicleDamage
M.isPlayerInPursuit = function()
  return playerInPursuit
end

return M
