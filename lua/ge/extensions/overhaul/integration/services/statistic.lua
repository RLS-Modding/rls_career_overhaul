-- Counts stock metric deltas once into the career slot while stock keeps the cloud statistics.
-- Owns career activation and save readiness; the stock-derived metric core lives beside this facade.
-- Fork of stock lua/ge/extensions/gameplay/statistic.lua (BeamNG 0.40).

local M = {}
-- Save ownership follows the existing career statistics file.
require("overhaul/lib/save/store").registerKeys({
  {key = "statistic.career", owner = "overhaul_integration_services_statistic", files = {"career/gameplay_stat.json"}, phase = "profile", required = true},
})

local active = false

local api, careerStats = require("overhaul/integration/services/statistic/core").create(M, {
  im = ui_imgui,
  -- The general copy lives in memory only: stock owns and saves the cloud data.
  loadData = function() return {version = 1, entries = {}} end,
  saveData = function() end,
  loadSubmodules = function() end,
  foregroundMissionId = function()
    if overhaul_integration_services_missions_missionManager then
      return overhaul_integration_services_missions_missionManager.getForegroundMissionId()
    end
  end,
  careerIsActive = function() return overhaul_career_career and overhaul_career_career.isActive() end,
})
-- The extension's API and hooks are the core instance's (stock export names).
for name, fn in pairs(api) do M[name] = fn end

local function onOverhaulSaveCurrentProfile(currentSavePath)
  M.forceTimerUpdate()
  local careerSaveFilePath = currentSavePath .. "/career/gameplay_stat.json"
  if not require("overhaul/lib/save/store").writeSlot(careerSaveFilePath, careerStats.getCareerData()) then
    log("E","save","failed to write career json!")
  end
end


local function onOverhaulActive(value)
  active = value == true
  if active then
    local saveSlot, savePath = overhaul_career_saveSystem.getCurrentProfile()
    if not saveSlot or not savePath then
      careerStats.setCareerData({version = 1, entries = {}})
      return
    end
    local careerData = jsonReadFile(savePath.. "/career/gameplay_stat.json")
    if not careerData or not careerData.entries or type(careerData.entries)~="table" or not careerData.version then
      careerData = {version=1, entries={}}
    end
    careerStats.setCareerData(careerData)
  else
    if careerStats.getCareerData() then
      careerStats.save()
    end
    -- if career is deactivated, remove local career data (and its timers, callbacks and activity).
    careerStats.endCareer()
  end
end

M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.onOverhaulActive = onOverhaulActive


M.ensureReady = function()
  if not careerStats.getCareerData() then onOverhaulActive(true) end
  return careerStats.getCareerData()
end
-- Recover career statistics before activation or save, including a mid-career reload.
M.ensureCareerReady = function()
  local career = overhaul_career_career
  if career and career.isActive and career.isActive() then return M.ensureReady() end
end
local saveProfile = M.onOverhaulSaveCurrentProfile
M.onOverhaulSaveCurrentProfile = function(savePath)
  if not active then return end
  M.ensureReady()
  return saveProfile(savePath)
end
local activate = M.onOverhaulActive
M.onOverhaulActive = function(value)
  activate(value)
  if value then M.onGameStateUpdate() end
end
for name, fn in pairs(M) do
  if type(fn) == "function" and name:match("^on") and not name:match("^onOverhaul") then
    M[name] = function(...) if active then return fn(...) end end
  end
end
return M
