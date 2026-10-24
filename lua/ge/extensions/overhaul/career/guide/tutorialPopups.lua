-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/career/modules/tutorialPopups.lua (BeamNG 0.40).
-- Intro popups: seen-flags per save, popups opened the first time a screen is used, and a debug browser.

local M = {}

-- SaveStore keys for the files this module writes (metadata only).
require("overhaul/lib/save/store").registerKeys({
  {key = "guide.tutorialPopups", owner = "overhaul_career_guide_tutorialPopups", files = {"career/tutorialData.json"}, phase = "profile", required = true},
})

M.dependencies = {'ui_popup'}

local im = ui_imgui
local logTag = "tutorial_popups"
local saveFile = "/career/tutorialData.json"

-- Keys are the stock hook names that open each popup the first time.
local introPopupTable = {
  -- shown when opening the refueling UI the first time
  onOverhaulRefuelingStartTransaction = {"refueling"},

  -- shown when opening parts tuning the first time
  onOverhaulTuningStarted = {"tuning"},

  -- shown when opening the garage the first time
  garageModeStartStep = {"garage"},

  -- shown when opening the cargo screen for the first time
  onEnterCargoOverviewScreen = {"delivery/cargoScreen"},
  onOverhaulComputerInsurance = {"insurance"},
  onOverhaulVehiclePaintingUiOpened = {"vehiclePainting"},
}

local introPopupFiles = {
  {"bigmap", "When opening Bigmap"},
  {"refueling", "When opening Refueling screen"},
  {"dealership", "When opening Dealership Screen"},
  {"computer", "When opening Computer"},
  {"partShopping", "When opening Shopping"},
  {"delivery/intro", "Delivery intro"},
  {"logbook", "Logbook"},
  {"performanceIndex", "Performance index"},
  {},
  {"delivery/cargoScreen", "Opening Cargo Screen for the first time"},
  {"delivery/parcelDeliveryHelp", "Parcel delivery help"},
  {"delivery/vehicleDeliveryHelp", "Vehicle delivery help"},
  {"delivery/trailerDeliveryHelp", "trailer delivery help"},
  {"delivery/materialsDeliveryHelp", "materials delivery help"},
  {"delivery/loanerHelp", "loaner help"},
  {},
  {"vehiclePainting", "Opening Painting for the first time"},
  {"tuning", "Opening Tuning menu for the first time"},
  {"insurance", "Opening Insurance Menu for the first time"},
  {"driverScore", "Driver Score Help"},
  {},
  {"milestones", "(NO LONGER USED)"},
  {"progress", "(NO LONGER USED)"},
}

M.allTutorialFlags = {
  "welcome", "driving", "crashRecover", "bigmap", "refueling", "missions", "postMission",
  "dealership", "computer", "partShopping", "finishing", "delivery/intro", "logbook",
  "welcomeNoTutorial", "performanceIndex", "delivery/cargoScreen", "delivery/parcelDeliveryHelp",
  "delivery/vehicleDeliveryHelp", "delivery/trailerDeliveryHelp", "delivery/materialsDeliveryHelp",
  "delivery/loanerHelp", "vehiclePainting", "tuning", "insurance", "driverScore",
  "milestones", "progress", "leagues"
}

local popupFlags = {}

local function setFlagsTable(flagsTable)
  popupFlags = flagsTable or {}
end

local function getTutorialFlag(key)
  return popupFlags[key]
end

local function setTutorialFlag(key, value)
  popupFlags[key] = value
end

M.wasIntroPopupsSeen = function(pages)
  for _, page in ipairs(pages or {}) do
    if not getTutorialFlag(page) then
      return false
    end
  end
  return true
end

local function onExtensionLoaded()
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  local saveData = (savePath and jsonReadFile(savePath .. saveFile)) or {}
  popupFlags = saveData.flags or {}
end

local function onOverhaulSaveCurrentProfile(currentSavePath)
  local saveData = {}
  saveData.flags = popupFlags
  overhaul_career_saveSystem.jsonWriteFileSafe(currentSavePath .. saveFile, saveData, true)
end

-- Kept as a no-op because the popup UI calls it whenever an intro popup closes.
function M.onIntroPopupCareerClosed(id) end

M.introPopup = function(id, force)
  if not force and M.getTutorialFlag(id) then return end

  M.setTutorialFlag(id, true)

  log("D", logTag, "Intro Popup: " .. id)
  extensions.ui_popup.openPopupById(id, {
    root = "/gameplay/tutorials/pages/",
  })
end

M.introPopupSequence = function(ids, force)
  if type(ids) ~= "table" or #ids == 0 then return end
  for _, id in ipairs(ids) do
    if force or not M.getTutorialFlag(id) then
      M.setTutorialFlag(id, true)
    end
  end
  log("D", logTag, "Intro Popup Sequence: " .. table.concat(ids, ", "))
  extensions.ui_popup.openPopupsByIds(ids, {
    root = "/gameplay/tutorials/pages/",
  })
end

for key, values in pairs(introPopupTable) do
  M[key] = function()
    for _, popupId in ipairs(values) do
      M.introPopup(popupId)
    end
  end
end

M.showAllSplashscreensAndLogbookEntries = function()
  for _, key in ipairs(M.allTutorialFlags) do
    popupFlags[key] = false
  end
  for key, _ in pairs(introPopupTable) do
    M[key]()
  end
end

local function drawSeparatorRow()
  im.Dummy(im.ImVec2(1, 3))
  im.Separator()
  im.Dummy(im.ImVec2(1, 3))
end

local function drawPopupRow(file)
  local folder = file[1]
  if im.Checkbox("##Seen " .. folder, im.BoolPtr(M.getTutorialFlag(folder) or false)) then
    M.setTutorialFlag(folder, not M.getTutorialFlag(folder))
  end
  im.SameLine()
  if im.Button("Edit##" .. folder) then
    Engine.Platform.exploreFolder("/gameplay/tutorials/pages/" .. folder .. "/content.html")
  end
  im.SameLine()
  if im.Selectable1("View " .. folder) then
    M.introPopup(folder, true)
  end
  im.tooltip(file[2])
end

M.drawDebugFunctions = function()
  if im.BeginMenu("> Intro Popups...") then
    if im.Selectable1("View All In Order") then
      for _, file in ipairs(introPopupFiles) do
        if next(file) then
          M.introPopup(file[1], true)
        end
      end
    end

    if im.Selectable1("Un-view all") then
      for _, file in ipairs(introPopupFiles) do
        if next(file) then
          M.setTutorialFlag(file[1], false)
        end
      end
    end

    drawSeparatorRow()
    for _, file in ipairs(introPopupFiles) do
      if not next(file) then
        drawSeparatorRow()
      else
        drawPopupRow(file)
      end
    end
    im.EndMenu()
  end
end

M.setFlagsTable = setFlagsTable
M.getTutorialFlag = getTutorialFlag
M.setTutorialFlag = setTutorialFlag

M.onExtensionLoaded = onExtensionLoaded
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile

return M
