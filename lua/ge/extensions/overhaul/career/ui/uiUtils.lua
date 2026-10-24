-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/uiUtils.lua (BeamNG 0.40).
-- Data for the career UI: status and skill stats, pause-menu buttons and the current level name.
-- Read status projections, pause-button helpers and public UI queries in order.

local M = {}

local skillLookup = require("overhaul/lib/progression/skillLookup")

local careerPauseContextButtonFunctions = {}

-- Vue CareerStatus component.
local function getCareerStatusData()
  local data = {}
  data.money = overhaul_career_economy_playerAttributes.getAttributeValue("money")
  data.beamXP = overhaul_career_economy_playerAttributes.getAttributeValue("beamXP")
  data.vouchers = overhaul_career_economy_playerAttributes.getAttributeValue("vouchers")
  data.insuranceScore = overhaul_career_repair_insurance.getDriverScore()
  return data
end

-- Vue CareerSimpleStats component: the Skills page's careerSkills digest, one row per branch.
local function getCareerSimpleStats()
  local currentSaveSlot, _ = overhaul_career_saveSystem.getCurrentProfile()
  local data = {
    saveSlotName = overhaul_career_saveSystem.getCurrentDisplayName() or currentSaveSlot,
    branches = {}
  }

  local page = overhaul_career_progression_skillsPage.getLandingPageData("careerSkills")
  for _, entry in ipairs(page and page.branches or {}) do
    local branch = overhaul_career_progression_skills.getBranchById(entry.id)
    if branch and not branch.missing then
      local value = skillLookup.attributeValue(branch.attributeKey)
      local level, _, _, min, max = skillLookup.levelFromValue(value, branch.id)
      table.insert(data.branches, {
        name = branch.name,
        levelLabel = {txt='ui.career.lvlLabel', context={lvl=level}},
        min = min,
        value = value,
        max = max,
      })
    end
  end
  return data
end

local function addMapButton(buttons)
  if overhaul_career_logistics_general.isDeliveryModeActive() then
    table.insert(buttons, {
      label = "ui.career.pause.mapMyCargo",
      icon = "map",
      fun = function() overhaul_career_logistics_cargoScreen.enterMyCargo() end
    })
  else
    table.insert(buttons, {
      label = "ui.career.pause.map",
      icon = "map",
      fun = function() freeroam_bigMapMode.enterBigMap({instant=true}) end
    })
  end
end

local function addProgressButtons(buttons)
  table.insert(buttons, {
    label = "ui.career.landingPage.name",
    icon = "progress",
    fun = function() extensions.ui_router.navigate('overhaul.domainSelection') end,
    showIndicator = overhaul_career_progression_milestones_milestones.unclaimedMilestonesCount() > 0
  })

  table.insert(buttons, {
    label = "ui.career.milestones.title",
    icon = "trophy",
    fun = function() extensions.ui_router.navigate('overhaul.milestones') end,
    showIndicator = overhaul_career_progression_milestones_milestones.unclaimedMilestonesCount() > 0
  })
end

local function addActiveTestButtons(buttons)
  if overhaul_career_parts_vehiclePerformance.isTestInProgress() then
    table.insert(buttons, {
      label = "ui.career.pause.cancelCertification",
      icon = "cancel",
      fun = function() overhaul_career_parts_vehiclePerformance.cancelTest() end,
      showIndicator = true
    })
  end

  if overhaul_career_market_testDrive.isActive() then
    table.insert(buttons, {
      label = "ui.career.pause.cancelTestDrive",
      icon = "cancel",
      fun = function() overhaul_career_market_testDrive.stop() end,
      showIndicator = true
    })
  end
end

local function storeCareerPauseContextButtons(data)
  table.clear(careerPauseContextButtonFunctions)
  for index, button in ipairs(data.buttons) do
    button.functionId = index
    careerPauseContextButtonFunctions[index] = button.fun
  end
end

local function callCareerPauseContextButtons(functionId)
  local fun = careerPauseContextButtonFunctions[functionId]
  if fun then fun() end
end

local function getCareerPauseContextButtons()
  local data = {buttons = {}}
  addMapButton(data.buttons)
  table.insert(data.buttons, {
    label = "ui.career.logbook.subHeading",
    icon = "book",
    fun = function() extensions.ui_router.navigate('overhaul.logbook') end
  })
  if overhaul_career_career.hasBoughtStarterVehicle() then
    addProgressButtons(data.buttons)
  end
  addActiveTestButtons(data.buttons)

  storeCareerPauseContextButtons(data)
  return data
end

local function getCareerCurrentLevelName()
  for _, level in ipairs(core_levels.getList()) do
    if string.lower(level.levelName) == getCurrentLevelIdentifier() then
      return level
    end
  end
end

M.getCareerStatusData = getCareerStatusData
M.getCareerSimpleStats = getCareerSimpleStats
M.storeCareerPauseContextButtons = storeCareerPauseContextButtons
M.callCareerPauseContextButtons = callCareerPauseContextButtons
M.getCareerPauseContextButtons = getCareerPauseContextButtons
M.getCareerCurrentLevelName = getCareerCurrentLevelName

return M
