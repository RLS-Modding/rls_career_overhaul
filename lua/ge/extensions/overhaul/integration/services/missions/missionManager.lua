-- Inert mission manager facade: Overhaul has no missions, but stock-fork callers still ask whether one runs.
-- No dependencies, no hooks, no traffic, police, parking, fade or save work.
local M = {}

local logTag = "missionManager"

-- Every start entry refuses with a truthy result (true = "did not start"), the convention of the removed startWithFade.
local function refuse(name)
  return function()
    log("W", logTag, name .. " ignored: missions are not part of Overhaul")
    return true
  end
end

local function noop() end

M.start = refuse("start")
M.startWithFade = refuse("startWithFade")
M.startAsScenario = refuse("startAsScenario")
M.startFromWithinMission = refuse("startFromWithinMission")
M.startInstant = refuse("startInstant")
M.startWithLoadingLevel = refuse("startWithLoadingLevel")

M.stop = noop
M.attemptAbandonMissionWithFade = noop
M.stopForegroundMissionInstantly = noop

M.getForegroundMissionId = function() return nil end
M.isCurrentlyProcessingStep = function() return false end
M.getCurrentTaskdataTypeOrNil = function() return nil end

M.allowMissionInteraction = function()
  if core_gamestate.state and core_gamestate.state.state ~= "freeroam" then
    return false
  end
  return true
end

return M
