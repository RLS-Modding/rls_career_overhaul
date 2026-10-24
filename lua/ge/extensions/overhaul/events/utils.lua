-- Freeroam staging text, live reward policy, scene lights and traffic/pursuit state.
-- Read owned state, bound reward policy, staging projections, scene/lifecycle operations and public policy APIs.
local optional = require("overhaul/lib/platform/optional")
local raceDataCatalog = require("overhaul/lib/events/raceDataCatalog")
local eventHelpers = require("overhaul/lib/events/helpers")
local M = {}
M.dependencies = { "overhaul_events_leaderboards" }

-- Config ------------------------------------------------------------------------------------------

local checkpointSoundPath = "art/sound/ui_checkpoint.ogg"

-- State -------------------------------------------------------------------------------------------

local previousTrafficAmount = nil
local previousActiveTrafficAmount = nil

local leftTimeDigits = {}
local rightTimeDigits = {}
local leftSpeedDigits = {}
local rightSpeedDigits = {}

local races = {}

-- Checkpoint sound and traffic ----------------------------------------------------------------------

-- playOnce only accepts source groups like AudioGui (AudioOther is not valid and is silent).
-- Scale by Other so Options → Other still controls this cue.
local function playCheckpointSound()
  local otherVol = tonumber(settings.getValue("AudioOtherVol"))
    or Engine.Audio.getChannelVolume("AudioChannelOther", false)
    or 1
  Engine.Audio.playOnce("AudioGui", checkpointSoundPath, {
    volume = 2 * otherVol,
  })
end

local function hasFinishTrigger(race)
  for _, name in ipairs(eventHelpers.sceneTriggerNames(race, races[race], "finish")) do
    if scenetree.findObject(name) then return true end
  end
  return false
end

-- Lets a delayed restore notice that another activity cut traffic after it was scheduled.
local trafficCutCount = 0
local function getTrafficCutCount()
  return trafficCutCount
end

local function saveAndSetTrafficAmount(amount)
  trafficCutCount = trafficCutCount + 1
  if gameplay_traffic then
    previousTrafficAmount = gameplay_traffic.getNumOfTraffic()
    local vars = gameplay_traffic.getTrafficVars and gameplay_traffic.getTrafficVars()
    local activeAmount = vars and tonumber(vars.activeAmount)
    if activeAmount and activeAmount > 0 then previousActiveTrafficAmount = activeAmount end
    gameplay_traffic.setActiveAmount(amount or 0)
  else
    log("W", "freeroamUtils", "gameplay_traffic not available")
  end
end

-- Restore the visible traffic cap, not the pooled vehicle count.
local function restoreTrafficAmount()
  if not gameplay_traffic then return end
  local activeAmount = nil
  if
    overhaul_career_career
    and overhaul_career_career.isActive()
    and overhaul_career_police_playerDriving
    and overhaul_career_police_playerDriving.getPlayerData
  then
    local playerData = overhaul_career_police_playerDriving.getPlayerData()
    local careerActive = playerData and tonumber(playerData.trafficActive)
    if careerActive and careerActive > 0 then activeAmount = careerActive end
  end
  if not activeAmount and previousActiveTrafficAmount and previousActiveTrafficAmount > 0 then
    activeAmount = previousActiveTrafficAmount
  end
  if not activeAmount then
    local settingsAmount = settings.getValue("trafficAmount") == 0 and getMaxVehicleAmount()
      or settings.getValue("trafficAmount")
    activeAmount = settingsAmount or previousTrafficAmount
  end
  previousActiveTrafficAmount = nil
  gameplay_traffic.setActiveAmount(activeAmount)
end

local formatTime = eventHelpers.formatTime

local rewardPolicy = require("overhaul/lib/events/rewardPolicy").create(
  function() return overhaul_career_career.isActive() end,
  function() return overhaul_career_economyAdjuster end,
  function() return overhaul_career_economy_globalEconomy end
)

local motivationalMessages = { -- Enthusiastic
  "Give it your all!",
  "Time to shine!",
  "Let's set a new record!",
  "It's go time!", -- Funny
  "Try not to hit any trees this time!",
  "Remember, the brake is the other pedal!",
  "First one to the finish line gets a cookie!",
  "Drive like you stole it... wait, you didn't, right?",

  -- Passive-aggressive
  "Try to keep it on the track this time, okay?",
  "Let's see if you've improved since last time...",
  "Maybe today you'll actually finish the race?",
  "I'm sure you'll do better than your last attempt. It can't get worse, right?", -- Encouraging
  "Believe in yourself, you've got this!",
  "Today could be your personal best!",
  "Focus and breathe, you're ready for this!",
  "Every second counts, make them all yours!", -- Challenging
  "Think you can handle this? Prove it!",
  "Show us what you're really made of!",
  "This track has beaten you before. Not today!",
  "Time to separate the rookies from the pros!", -- Quirky
  "May the downforce be with you!",
  "Remember: turn left to go left, right to go right!",
  "Gravity is just a suggestion, right?",
  "If in doubt, flat out! (Results may vary)", -- Intense
  "Push it to the limit!",
  "Leave nothing on the table!",
  "Drive like your life depends on it!",
  "It's now or never!",
}

-- Race labels and start messages --------------------------------------------------------------------

local function displayStartMessage(raceName)
  local race = races[raceName]
  local message

  if math.random() < 0.5 then
    message = "GO!"
  else
    message = motivationalMessages[math.random(#motivationalMessages)]
  end

  message = string.format("**%s Event Started!\n%s**", race.label, message)
  M.displayMessage(message, 5)
end

local function getRaceStartBannerText(raceName)
  local race = races[raceName]
  if not race then return "GO!" end
  local msg
  if math.random() < 0.5 then
    msg = "GO!"
  else
    msg = motivationalMessages[math.random(#motivationalMessages)]
  end
  return race.label .. " — " .. msg
end

local function getRaceLabel(raceName, altRoute, hotlap)
  local race = races[raceName]
  if not race then return tostring(raceName or "") end
  local raceLabel = race.label

  if altRoute then raceLabel = race.altRoute.label end
  if hotlap then raceLabel = raceLabel .. " (Hotlap)" end
  return raceLabel
end

-- Staging HUD projections ---------------------------------------------------------------------------

local function buildStagingEntry(label, targetValue, pbValue, rewardValue)
  return {
    label = label,
    targetValue = targetValue,
    personalBestValue = pbValue,
    rewardValue = rewardValue,
  }
end

local function buildStagingSection(title, entries)
  if not entries or #entries == 0 then return nil end
  return {
    title = title,
    entries = entries,
  }
end

local function buildTimeGoalEntry(label, bestTime, targetTime, reward, raceData, careerMode)
  local rewardValue = nil
  if careerMode then
    local rewardTime = bestTime and math.min(bestTime, targetTime) or targetTime
    rewardValue = rewardPolicy.raceReward(targetTime, reward, rewardTime, raceData and raceData.type or nil)
  end
  return buildStagingEntry(label, formatTime(targetTime), bestTime and formatTime(bestTime) or nil, rewardValue)
end

local function buildHybridEntry(label, leaderboardEntry, targetTime, reward, damageFactor, raceData, careerMode)
  local bestTime = leaderboardEntry and leaderboardEntry.time or nil
  local rewardValue = nil
  if careerMode then
    local rewardTime = bestTime and math.min(bestTime, targetTime) or targetTime
    rewardValue = rewardPolicy.hybridRaceReward(targetTime, reward, rewardTime, damageFactor, 0, raceData and raceData.type or nil)
  end
  return buildStagingEntry(label, formatTime(targetTime), bestTime and formatTime(bestTime) or nil, rewardValue)
end

local function buildTopSpeedEntry(label, leaderboardEntry, race, careerMode)
  local bestSpeed = leaderboardEntry and leaderboardEntry.topSpeed
  local rewardValue = nil
  if careerMode then
    rewardValue = rewardPolicy.topSpeedReward(race.topSpeedGoal, race.reward, bestSpeed or race.topSpeedGoal, race.type)
  end
  local targetValue = string.format("%.1f mph", race.topSpeedGoal)
  local pbValue = bestSpeed and string.format("%.1f mph", bestSpeed) or nil
  return buildStagingEntry(label, targetValue, pbValue, rewardValue)
end

local function buildDriftEntry(label, leaderboardEntry, race, careerMode, targetTimeOverride)
  local bestScore = leaderboardEntry and leaderboardEntry.driftScore
  local rewardValue = nil
  local targetTime = targetTimeOverride or race.driftTargetTime or race.bestTime
  if careerMode and not race.burnoutComp then
    rewardValue = rewardPolicy.driftReward(race, targetTime, bestScore or race.driftGoal)
  end
  local targetValue = race.burnoutComp and "Open score" or tostring(race.driftGoal)
  local pbValue = bestScore and tostring(math.floor((tonumber(bestScore) or 0) + 0.5)) or nil
  return buildStagingEntry(label, targetValue, pbValue, rewardValue)
end

local function disabledRaceTypes(race)
  local allTypesDisabled = false
  local disabledTypes = {}
  if overhaul_career_economyAdjuster and race.type then
    local totalTypes = 0
    local disabledCount = 0
    for _, raceType in ipairs(race.type) do
      totalTypes = totalTypes + 1
      local multiplier = overhaul_career_economyAdjuster.getEffectiveSectionMultiplier({ raceType })
      if multiplier == 0 then
        disabledCount = disabledCount + 1
        table.insert(disabledTypes, raceType)
      end
    end
    allTypesDisabled = totalTypes > 0 and disabledCount == totalTypes
  end

  return allTypesDisabled, disabledTypes
end

local function buildMainStagingEntries(id, raceName, race, leaderboardEntry, careerMode)
  local mainEntries = {}

  if race.topSpeed then
    table.insert(mainEntries, buildTopSpeedEntry("Speed", leaderboardEntry, race, careerMode))
  elseif race.driftGoal then
    table.insert(
      mainEntries,
      buildDriftEntry(race.burnoutComp and "Score" or "Run", leaderboardEntry, race, careerMode)
    )
  elseif race.damageFactor and race.damageFactor > 0 then
    table.insert(
      mainEntries,
      buildHybridEntry("Lap", leaderboardEntry, race.bestTime, race.reward, race.damageFactor, race, careerMode)
    )
  else
    table.insert(
      mainEntries,
      buildTimeGoalEntry("Lap", leaderboardEntry.time, race.bestTime, race.reward, race, careerMode)
    )
  end

  if race.hotlap then
    local leH = overhaul_events_leaderboards.getLeaderboardEntry(id, getRaceLabel(raceName, nil, true)) or {}
    if race.damageFactor and race.damageFactor > 0 then
      table.insert(
        mainEntries,
        buildHybridEntry("Hotlap", leH, race.hotlap, race.reward, race.damageFactor, race, careerMode)
      )
    else
      table.insert(mainEntries, buildTimeGoalEntry("Hotlap", leH.time, race.hotlap, race.reward, race, careerMode))
    end
  end
  return mainEntries
end

local function buildAlternativeStagingSection(id, raceName, race, careerMode)
  if race.altRoute then
    local aiRacers = race.altRoute
    local altSectionTitle = (type(aiRacers.label) == "string" and aiRacers.label ~= "") and aiRacers.label
      or "Alternative route"
    local leA = overhaul_events_leaderboards.getLeaderboardEntry(id, getRaceLabel(raceName, true)) or {}
    local altEntries = {}
    if aiRacers.damageFactor and aiRacers.damageFactor > 0 then
      table.insert(
        altEntries,
        buildHybridEntry("Lap", leA, aiRacers.bestTime, aiRacers.reward, aiRacers.damageFactor, aiRacers, careerMode)
      )
    elseif aiRacers.driftGoal then
      table.insert(
        altEntries,
        buildDriftEntry("Run", leA, aiRacers, careerMode, aiRacers.driftTargetTime or aiRacers.bestTime)
      )
    elseif aiRacers.topSpeedGoal then
      table.insert(altEntries, buildTopSpeedEntry("Speed", leA, aiRacers, careerMode))
    else
      table.insert(
        altEntries,
        buildTimeGoalEntry("Lap", leA.time, aiRacers.bestTime, aiRacers.reward, aiRacers, careerMode)
      )
    end
    if aiRacers.hotlap then
      local leAH = overhaul_events_leaderboards.getLeaderboardEntry(id, getRaceLabel(raceName, true, true)) or {}
      if aiRacers.damageFactor and aiRacers.damageFactor > 0 then
        table.insert(
          altEntries,
          buildHybridEntry(
            "Hotlap",
            leAH,
            aiRacers.hotlap,
            aiRacers.reward,
            aiRacers.damageFactor,
            aiRacers,
            careerMode
          )
        )
      else
        table.insert(
          altEntries,
          buildTimeGoalEntry("Hotlap", leAH.time, aiRacers.hotlap, aiRacers.reward, aiRacers, careerMode)
        )
      end
    end
    return buildStagingSection(altSectionTitle, altEntries)
  end
end

local function getStagingHudBreakdown(vehId, raceName)
  local empty = { sections = {} }
  if not raceName or not races[raceName] then return empty end
  local race = races[raceName]

  local id = vehId
  if overhaul_career_career.isActive() then
    id = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId) or vehId
  end
  local careerMode = overhaul_career_career.isActive()

  local allTypesDisabled, disabledTypes = disabledRaceTypes(race)
  if allTypesDisabled then
    local typesString = table.concat(disabledTypes, ", ")
    return {
      disabled = true,
      disabledReason = string.format("%s is disabled — %s multiplier(s) set to 0.", race.label, typesString),
      sections = {},
    }
  end

  local out = { sections = {} }
  local leaderboardEntry = overhaul_events_leaderboards.getLeaderboardEntry(id, getRaceLabel(raceName)) or {}
  local mainEntries = buildMainStagingEntries(id, raceName, race, leaderboardEntry, careerMode)
  local mainSection = buildStagingSection("", mainEntries)
  if mainSection then table.insert(out.sections, mainSection) end
  local alternativeSection = buildAlternativeStagingSection(id, raceName, race, careerMode)
  if alternativeSection then table.insert(out.sections, alternativeSection) end
  return out
end

-- Staging message projections -----------------------------------------------------------------------

local function formatStagedTimeInfo(careerMode, bestTime, targetTime, reward, label, raceData)
  if not bestTime then
    if careerMode then
      local adjustedBaseReward = rewardPolicy.raceReward(targetTime, reward, targetTime, raceData and raceData.type or nil)
      return string.format(
        "%sTarget Time: %s\n(Achieve this to earn a reward of $%.2f)",
        label,
        formatTime(targetTime),
        adjustedBaseReward
      )
    else
      return string.format("%sTarget Time: %s", label, formatTime(targetTime))
    end
  elseif bestTime > targetTime then
    if careerMode then
      local adjustedBaseReward = rewardPolicy.raceReward(targetTime, reward, targetTime, raceData and raceData.type or nil)
      return string.format(
        "%sYour Best Time: %s | Target Time: %s\n(Achieve target to earn a reward of $%.2f)",
        label,
        formatTime(bestTime),
        formatTime(targetTime),
        adjustedBaseReward
      )
    else
      return string.format(
        "%sYour Best Time: %s | Target Time: %s",
        label,
        formatTime(bestTime),
        formatTime(targetTime)
      )
    end
  else
    if careerMode then
      local adjustedPotentialReward = rewardPolicy.raceReward(targetTime, reward, bestTime, raceData and raceData.type or nil)
      return string.format(
        "%sYour Best Time: %s\n(Improve to earn at least $%.2f)",
        label,
        formatTime(bestTime),
        adjustedPotentialReward
      )
    else
      return string.format("%sYour Best Time: %s", label, formatTime(bestTime))
    end
  end
end

local function formatStagedHybridTarget(careerMode, targetTime, reward, label, damageFactor, raceData)
  if careerMode then
    local adjustedBaseReward =
      rewardPolicy.hybridRaceReward(targetTime, reward, targetTime, damageFactor, 0, raceData and raceData.type or nil)
    if damageFactor == 1 then
      return string.format(
        "%sTarget Time: %s | Target: No Damage\n(Achieve both to earn a reward of $%.2f and 1 Bonus Star)",
        label,
        formatTime(targetTime),
        adjustedBaseReward
      )
    else
      return string.format(
        "%sTarget Time: %s | Damage Factor: %.0f%%\n(Speed and damage both matter - achieve target time with minimal damage to earn up to $%.2f and 1 Bonus Star)",
        label,
        formatTime(targetTime),
        damageFactor * 100,
        adjustedBaseReward
      )
    end
  else
    return string.format(
      "%sTarget Time: %s | Damage Factor: %.0f%%",
      label,
      formatTime(targetTime),
      damageFactor * 100
    )
  end
end

local function formatStagedHybridInfo(careerMode, leaderboardEntry, targetTime, reward, label, damageFactor, raceData)
  local bestTime = leaderboardEntry and leaderboardEntry.time or nil
  local bestDamagePercentage = leaderboardEntry and leaderboardEntry.damagePercentage or nil

  if not bestTime then
    return formatStagedHybridTarget(careerMode, targetTime, reward, label, damageFactor, raceData)
  else
    local damageText = bestDamagePercentage and string.format(" | Best Damage: %.1f%%", bestDamagePercentage * 100)
      or ""
    if careerMode then
      if damageFactor == 1 then
        return string.format(
          "%sYour Best Time: %s%s | Target: No Damage\n(Improve time or reduce damage to earn more rewards)",
          label,
          formatTime(bestTime),
          damageText
        )
      else
        return string.format(
          "%sYour Best Time: %s%s | Damage Factor: %.0f%%\n(Speed and damage both matter - improve either to earn more rewards)",
          label,
          formatTime(bestTime),
          damageText,
          damageFactor * 100
        )
      end
    else
      return string.format(
        "%sYour Best Time: %s%s | Damage Factor: %.0f%%",
        label,
        formatTime(bestTime),
        damageText,
        damageFactor * 100
      )
    end
  end
end

local function appendTopSpeedStagedMessage(message, race, leaderboardEntry, careerMode)
  local bestSpeed = leaderboardEntry and leaderboardEntry.topSpeed or nil
  local bestTime = leaderboardEntry and leaderboardEntry.time or nil
  local targetSpeed = race.topSpeedGoal

  if bestSpeed and bestTime then
    if careerMode then
      local adjustedReward = rewardPolicy.topSpeedReward(targetSpeed, race.reward, bestSpeed, race.type)
      message = message
        .. string.format(
          "Your Best Speed: %.2f mph | Target Speed: %.2f mph\nYour Best Time: %s\n(Improve to earn at least $%.2f)",
          bestSpeed,
          targetSpeed,
          formatTime(bestTime),
          adjustedReward
        )
    else
      message = message
        .. string.format(
          "Your Best Speed: %.2f mph | Target Speed: %.2f mph\nYour Best Time: %s",
          bestSpeed,
          targetSpeed,
          formatTime(bestTime)
        )
    end
  else
    if careerMode then
      local adjustedReward = rewardPolicy.topSpeedReward(targetSpeed, race.reward, targetSpeed, race.type)
      message = message
        .. string.format(
          "Target Speed: %.2f mph\n(Achieve this to earn a reward of $%.2f and 1 Bonus Star)",
          targetSpeed,
          adjustedReward
        )
    else
      message = message .. string.format("Target Speed: %.2f mph", targetSpeed)
    end
  end
  return message
end

local function appendDriftStagedMessage(message, race, leaderboardEntry, careerMode)
  local bestScore = leaderboardEntry.driftScore
  local bestTime = leaderboardEntry.time
  local targetScore = race.driftGoal
  local targetTime = race.driftTargetTime or race.bestTime
  local adjustedTargetReward = rewardPolicy.driftReward(race, targetTime, targetScore)
  local adjustedBestReward = bestScore and bestTime and rewardPolicy.driftReward(race, bestTime, bestScore) or nil

  if bestScore and bestTime then
    -- Show player's best score and time
    if careerMode then
      message = message
        .. string.format(
          "Your Best Drift Score: %d | Target Drift Score: %d\nYour Best Time: %s | Target Time: %s\n(Improve targets to earn at least $%.2f)",
          bestScore,
          targetScore,
          formatTime(bestTime),
          formatTime(targetTime),
          adjustedBestReward or adjustedTargetReward
        )
    else
      message = message
        .. string.format(
          "Your Best Drift Score: %d | Target Drift Score: %d\nYour Best Time: %s | Target Time: %s",
          bestScore,
          targetScore,
          formatTime(bestTime),
          formatTime(targetTime)
        )
    end
  else
    -- No previous best score/time
    if careerMode then
      message = message
        .. string.format(
          "Target Drift Score: %d\nTarget Time: %s\n(Achieve these to earn a reward of $%.2f and 1 Bonus Star)",
          targetScore,
          formatTime(targetTime),
          adjustedTargetReward
        )
    else
      message = message
        .. string.format("Target Drift Score: %d\nTarget Time: %s", targetScore, formatTime(targetTime))
    end
  end
  return message
end

-- Route messages ------------------------------------------------------------------------------------

local function appendMainStagedMessage(message, race, leaderboardEntry, careerMode)
  if race.topSpeed then
    message = appendTopSpeedStagedMessage(message, race, leaderboardEntry, careerMode)
  elseif race.driftGoal then
    message = appendDriftStagedMessage(message, race, leaderboardEntry, careerMode)
  elseif race.damageFactor and race.damageFactor > 0 then
    message = message
      .. formatStagedHybridInfo(careerMode, leaderboardEntry, race.bestTime, race.reward, "", race.damageFactor, race)
  else
    message = message
      .. formatStagedTimeInfo(
        careerMode,
        leaderboardEntry and leaderboardEntry.time or nil,
        race.bestTime,
        race.reward,
        "",
        race
      )
  end

  return message
end

local function appendStagedRouteHotlap(message, vehId, raceName, routeRace, careerMode, altRoute, label)
  if routeRace.hotlap then
    local leaderboardEntry = overhaul_events_leaderboards.getLeaderboardEntry(vehId, getRaceLabel(raceName, altRoute, true))
    if routeRace.damageFactor and routeRace.damageFactor > 0 then
      message = message
        .. "\n\n"
        .. formatStagedHybridInfo(
          careerMode,
          leaderboardEntry,
          routeRace.hotlap,
          routeRace.reward,
          label,
          routeRace.damageFactor,
          routeRace
        )
    else
      message = message
        .. "\n\n"
        .. formatStagedTimeInfo(
          careerMode,
          leaderboardEntry and leaderboardEntry.time or nil,
          routeRace.hotlap,
          routeRace.reward,
          label,
          routeRace
        )
    end
  end

  return message
end

local function appendAlternativeStagedMessage(message, vehId, raceName, race, careerMode)
  if race.altRoute then
    local leaderboardEntry = overhaul_events_leaderboards.getLeaderboardEntry(vehId, getRaceLabel(raceName, true))
    message = message .. "\n\nAlternative Route:\n"
    if race.altRoute.damageFactor and race.altRoute.damageFactor > 0 then
      message = message
        .. formatStagedHybridInfo(
          careerMode,
          leaderboardEntry,
          race.altRoute.bestTime,
          race.altRoute.reward,
          "",
          race.altRoute.damageFactor,
          race.altRoute
        )
    else
      message = message
        .. formatStagedTimeInfo(
          careerMode,
          leaderboardEntry and leaderboardEntry.time or nil,
          race.altRoute.bestTime,
          race.altRoute.reward,
          "",
          race.altRoute
        )
    end

    message = appendStagedRouteHotlap(message, vehId, raceName, race.altRoute, careerMode, true, "Alt Route Hotlap: ")

  end

  return message
end

local function appendRewardCutNote(message, race, careerMode)
  -- Add note for time-based events in career mode
  if careerMode and not race.driftGoal and not race.topSpeed then
    if race.damageFactor and race.damageFactor > 0 then
      message = message
        .. "\n\n**Note: All rewards are cut by 50% if they are below your best score. Score is calculated based on both time and damage.**"
    else
      message = message .. "\n\n**Note: All rewards are cut by 50% if they are below your best time.**"
    end
  elseif careerMode and race.topSpeed then
    message = message .. "\n\n**Note: All rewards are cut by 50% if they are below your best speed.**"
  end

  return message
end

local function displayStagedMessage(vehId, raceName, getMessage)
  if overhaul_career_career.isActive() then
    vehId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId) or vehId
  end
  local race = races[raceName]
  local leaderboardEntry = overhaul_events_leaderboards.getLeaderboardEntry(vehId, getRaceLabel(raceName)) or {}
  local careerMode = overhaul_career_career.isActive()

  local allTypesDisabled, disabledTypes = disabledRaceTypes(race)

  local message = ""
  if allTypesDisabled then
    -- Show disabled message
    local typesString = table.concat(disabledTypes, ", ")
    message = string.format("%s is currently disabled due to %s multiplier(s) being set to 0.", race.label, typesString)
    if not getMessage then M.displayMessage(message, 5) end
    return getMessage and message or nil
  else
    -- Normal staging message
    if not getMessage then message = string.format("Staged for %s.\n", race.label) end
  end

  message = appendMainStagedMessage(message, race, leaderboardEntry, careerMode)

  message = appendStagedRouteHotlap(message, vehId, raceName, race, careerMode, nil, "Hotlap: ")
  message = appendAlternativeStagedMessage(message, vehId, raceName, race, careerMode)
  message = appendRewardCutNote(message, race, careerMode)

  if not getMessage then
    M.displayMessage(message, 15)
    return
  end
  return message
end

-- Scene lights and pursuit --------------------------------------------------------------------------

local function setActiveLight(event, color)
  local lights = races[event] and races[event].lights
  if type(lights) ~= "table" then
    log("W", "freeroamUtils", "Event lights unavailable: no bindings for " .. tostring(event))
    return
  end
  for _, lightColor in ipairs({ "yellow", "red", "green" }) do
    local name = lights[lightColor]
    if name then
      local light = scenetree.findObject(name)
      if light then
        light:setHidden(color ~= lightColor)
      else
        log("W", "freeroamUtils", "Event light unavailable: " .. tostring(name))
      end
    end
  end
end

local function getVehicleDamage()
  local playerVehicleId = be:getPlayerVehicleID(0)
  return map.objects[playerVehicleId] and map.objects[playerVehicleId].damage or 0
end

local playerInPursuit = false

local function onPursuitAction(id, action, data)
  local playerVehicleId = be:getPlayerVehicleID(0)

  if id == playerVehicleId then
    if action == "start" then
      playerInPursuit = true
    elseif action == "evade" or action == "reset" or action == "release" then
      playerInPursuit = false
    elseif action == "arrest" then
      playerInPursuit = false
    end
  end
end

-- Lifecycle -----------------------------------------------------------------------------------------

local function resetSceneBoundCaches()
  table.clear(leftTimeDigits)
  table.clear(rightTimeDigits)
  table.clear(leftSpeedDigits)
  table.clear(rightSpeedDigits)
end

local function loadRaceData()
  races = {}
  if getCurrentLevelIdentifier() then
    races = raceDataCatalog.loadRaces(getCurrentLevelIdentifier())
    return deepcopy(races)
  end
  return {}
end

local function onExtensionLoaded()
  if getCurrentLevelIdentifier() then loadRaceData() end
end

-- Public API --------------------------------------------------------------------------------------

M.onPursuitAction = onPursuitAction
M.playCheckpointSound = playCheckpointSound
M.displayStartMessage = displayStartMessage
M.getRaceStartBannerText = getRaceStartBannerText
M.getStagingHudBreakdown = getStagingHudBreakdown
M.displayStagedMessage = displayStagedMessage
function M.displayMessage(message, duration)
  ui_message(message, duration, "FRE", "info")
end
M.raceReward = rewardPolicy.raceReward
M.driftReward = rewardPolicy.driftReward
M.topSpeedReward = rewardPolicy.topSpeedReward
M.hybridRaceReward = rewardPolicy.hybridRaceReward
M.saveAndSetTrafficAmount = saveAndSetTrafficAmount
M.restoreTrafficAmount = restoreTrafficAmount
M.getTrafficCutCount = getTrafficCutCount
M.hasFinishTrigger = hasFinishTrigger
M.setActiveLight = setActiveLight
M.loadRaceData = loadRaceData
M.resetSceneBoundCaches = resetSceneBoundCaches
M.calculateAverageMultiplier = rewardPolicy.calculateAverageMultiplier
M.onExtensionLoaded = onExtensionLoaded
M.getVehicleDamage = getVehicleDamage
M.isPlayerInPursuit = function()
  if gameplay_traffic and gameplay_traffic.getTrafficData then
    local playerVehId = be:getPlayerVehicleID(0)
    local trafficVeh = playerVehId and gameplay_traffic.getTrafficData()[playerVehId]
    if trafficVeh and trafficVeh.pursuit then return (tonumber(trafficVeh.pursuit.mode) or 0) > 0 end
  end
  return playerInPursuit
end

-- Spawned Car Jockey / vehicle-delivery task cars are not the player's.
function M.isCarJockeyVehicle(vehId)
  if not vehId then return false end
  if not overhaul_career_career or not overhaul_career_career.isActive() then return nil end
  return overhaul_career_logistics_vehicleTasks.isVehicleDeliveryVehicle(vehId) == true
end

-- Walkabout blocks starting a new race; an already-running event keeps its session.
M.isExternalActivityBlockingFreeroam = function()
  local walkabout = optional("gameplay_walkabout")
  if walkabout and type(walkabout.isActive) == "function" and walkabout.isActive() then return true end
  return false
end

return M
