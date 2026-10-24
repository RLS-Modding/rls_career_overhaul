-- Scoring policy binds live economy readers without owning career or event state.
-- Callers supply the active career and current economy providers; arithmetic stays in raceScoring.
local raceScoring = require("overhaul/lib/events/raceScoring")
local M = {}

function M.create(careerIsActive, getEconomy, getJobMarket)
  local function getCareerJobMarketMultiplier()
    if not getJobMarket() then return 1.0 end

    local ok, jobMarketIndex = pcall(getJobMarket().getJobMarketIndex)
    if not ok or type(jobMarketIndex) ~= "number" then return 1.0 end

    return jobMarketIndex
  end

  local function calculateAverageMultiplier(raceTypes)
    if
      not careerIsActive()
      or not getEconomy()
      or not raceTypes
      or #raceTypes == 0
    then
      return 1.0
    end

    local totalMultiplier = 0
    local nonZeroCount = 0

    for _, raceType in ipairs(raceTypes) do
      local typeMultiplier = getEconomy().getEffectiveSectionMultiplier({ raceType })
      if typeMultiplier > 0 then
        totalMultiplier = totalMultiplier + typeMultiplier
        nonZeroCount = nonZeroCount + 1
      end
    end

    -- Disabled disciplines do not dilute the enabled disciplines.
    local activityMultiplier = nonZeroCount > 0 and (totalMultiplier / nonZeroCount) or 0
    if activityMultiplier == 0 then return 0 end

    return activityMultiplier * getCareerJobMarketMultiplier()
  end

  local function raceReward(goal, reward, time, raceTypes)
    local multiplierFor = raceTypes and getEconomy() and calculateAverageMultiplier or nil
    return raceScoring.raceReward(goal, reward, time, raceTypes, multiplierFor)
  end

  local function driftReward(race, time, driftScore)
    local multiplierFor = race
        and race.type
        and function(raceTypes)
          if careerIsActive() and getEconomy() then
            return calculateAverageMultiplier(raceTypes)
          end
          return 1
        end
      or nil
    return raceScoring.driftReward(race, time, driftScore, multiplierFor)
  end

  local function topSpeedReward(goalSpeed, baseReward, actualSpeed, raceTypes)
    local multiplierFor = raceTypes and getEconomy() and calculateAverageMultiplier or nil
    return raceScoring.topSpeedReward(goalSpeed, baseReward, actualSpeed, raceTypes, multiplierFor)
  end

  local function hybridRaceReward(goalTime, baseReward, actualTime, damageFactor, damagePercentage, raceTypes)
    local multiplierFor = raceTypes and getEconomy() and calculateAverageMultiplier or nil
    return raceScoring.hybridRaceReward(
      goalTime,
      baseReward,
      actualTime,
      damageFactor,
      damagePercentage,
      raceTypes,
      multiplierFor
    )
  end

  return {
    calculateAverageMultiplier = calculateAverageMultiplier,
    raceReward = raceReward,
    driftReward = driftReward,
    topSpeedReward = topSpeedReward,
    hybridRaceReward = hybridRaceReward,
  }
end

return M
