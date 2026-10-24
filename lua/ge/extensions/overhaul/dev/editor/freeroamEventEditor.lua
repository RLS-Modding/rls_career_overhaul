-- Freeroam event editor: authors the events in the base race_data.json (road checkpoints, triggers, rewards, options).
-- Only the legacy base file is written; runtime reads go through lib/events/raceDataCatalog, so add-ons never leak in.
local M = {}

local roadFactory = require("overhaul/lib/events/course/roadCheckpoints")
local checkpointFactory = require("overhaul/lib/events/course/checkpointManager")
local rewardPolicy = require("overhaul/lib/events/rewardPolicy").create(
  function() return overhaul_career_career.isActive() end,
  function() return overhaul_career_economyAdjuster end,
  function() return overhaul_career_economy_globalEconomy end
)
local eventHelpers = require("overhaul/lib/events/helpers")
local imgui = ui_imgui

-- Config ------------------------------------------------------------------------------------------

local LOG_TAG = "overhaul_dev_editor_freeroamEventEditor"
local TOOL_WINDOW_NAME = "editor_freeroamEventEditor_window"
local EDITOR_UPDATE_INTERVAL_SECONDS = 5
local TRIGGER_PREFIXES = {
  start = "fre_start_",
  staging = "fre_staging_",
  finish = "fre_finish_",
  pit = "fre_pits_",
}
local RACE_TEMPLATE = {
  bestTime = 60,
  reward = 1000,
  label = "New Event",
  checkpointRoad = nil,
  type = { "motorsport" },
  timeout = 10,
}

-- State -------------------------------------------------------------------------------------------

-- Each epoch owns route state; checkpoint scene groups also belong to the engine mission lifetime.
local function createCoursePreview(callbacks)
  callbacks = callbacks or {}
  local current = true
  local function isCurrent() return current end
  local function notifyBuilt(payload)
    if current and callbacks.onCheckpointsBuilt then callbacks.onCheckpointsBuilt(payload) end
  end
  local function notifyWarning(text)
    if current and callbacks.onCriticalWarning then callbacks.onCriticalWarning(text) end
  end
  local road = roadFactory.create({preview = true, isCurrent = isCurrent, onCriticalWarning = notifyWarning})
  local checkpoints = checkpointFactory.create({preview = true, isCurrent = isCurrent, onCheckpointsBuilt = notifyBuilt}).api
  local function dispose()
    current = false
    local removed = checkpoints.removeCheckpoints()
    road.reset()
    return removed
  end
  return {roadCheckpoints = road, checkpointManager = checkpoints, dispose = dispose}
end

local races = {}
local currentRaceName = nil
local modified = false
local raceTypes = { "motorsport", "drift", "drag", "offroad", "rally" }
local levelTriggers = {}
local levelDecalRoads = {}
local pendingTriggerType = nil
local pendingTriggerRace = nil
local showTriggerPlacementHelp = false
local showingRaceCheckpoints = false
local showingCheckpointsEditor = false
local checkpoints = {}
local altCheckpoints = {}
local roadNodes = {}
local altRoadNodes = {}
local previewLifetime = {instance = createCoursePreview(), closed = false, unloaded = false, worldReady = true}
local roadFilterText = ""

-- Reward preview and toggles shown in the reward section; they are not saved with the race.
local bestTimeSession = imgui.BoolPtr(false)
local inRange = imgui.BoolPtr(false)
local realTime = imgui.FloatPtr(0)
local driftScore = imgui.IntPtr(1000)
local lapCount = imgui.IntPtr(1)
local hardcore = imgui.BoolPtr(false)
local damagePercentage = imgui.FloatPtr(0.0)
local lastOsTime = os.time()

-- Helpers -----------------------------------------------------------------------------------------

-- Array search for the road rescan; the load and event-type paths keep calling the engine's global tableContains.
local function listContains(list, value)
  if not list then return false end
  for _, item in ipairs(list) do
    if item == value then return true end
  end
  return false
end

local function tableIndexOf(list, value)
  for index, item in ipairs(list) do
    if item == value then return index end
  end
end

local function countTableEntries(t)
  local count = 0
  if t then
    for _ in pairs(t) do count = count + 1 end
  end
  return count
end

local function triggerExists(prefix, raceName)
  return scenetree.findObject(prefix .. raceName) ~= nil
end

local function clearPendingTrigger()
  pendingTriggerType = nil
  pendingTriggerRace = nil
  showTriggerPlacementHelp = false
end

-- Race data files ---------------------------------------------------------------------------------

local function raceDataPath(level)
  return "levels/" .. level .. "/race_data.json"
end

local function createNewRace()
  local newRaceName = "event_" .. os.time()
  races[newRaceName] = deepcopy(RACE_TEMPLATE)
  races[newRaceName].label = "New Event"
  currentRaceName = newRaceName
  modified = true
  log("I", LOG_TAG, "Created new event: " .. newRaceName)
  return newRaceName
end

local function createNewRaceData()
  races = {}
  currentRaceName = nil
  modified = true
  log("I", LOG_TAG, "Created new race data")
end

local function loadRaceData()
  local level = getCurrentLevelIdentifier()
  if not level then return end

  local raceData = jsonReadFile(raceDataPath(level)) or { races = {} }
  races = raceData.races or {}
  modified = false

  for _, race in pairs(races) do
    for _, raceType in ipairs(race.type) do
      if not tableContains(raceTypes, raceType) then table.insert(raceTypes, raceType) end
    end
  end
  log("I", LOG_TAG, "Loaded race data for level: " .. level)
end

local function saveRaceData()
  local level = getCurrentLevelIdentifier()
  if not level then
    log("E", LOG_TAG, "No level loaded!")
    return
  end

  local filePath = raceDataPath(level)
  jsonWriteFile(filePath, { races = races }, true)
  modified = false
  log("I", LOG_TAG, "Saved race data to: " .. filePath)
end

-- Scene objects -----------------------------------------------------------------------------------

-- Visits every object under MissionGroup, descending into groups.
local function walkSceneObjects(visit)
  local missionGroup = scenetree.findObject("MissionGroup")
  if not missionGroup then return end

  local function visitGroup(group)
    for _, objName in ipairs(group:getObjects()) do
      local obj = scenetree.findObject(objName)
      if obj then
        visit(obj)
        if obj:getClassName() == "SimGroup" then visitGroup(obj) end
      end
    end
  end
  visitGroup(missionGroup)
end

local function findLevelObjects()
  levelTriggers = {}
  levelDecalRoads = {}
  walkSceneObjects(function(obj)
    if obj:getClassName() == "BeamNGTrigger" then
      table.insert(levelTriggers, obj:getName())
    elseif obj:getClassName() == "DecalRoad" then
      table.insert(levelDecalRoads, obj:getName())
    end
  end)
end

local function findDecalRoads()
  levelDecalRoads = {}
  walkSceneObjects(function(obj)
    if obj:getClassName() == "DecalRoad" then table.insert(levelDecalRoads, obj:getName()) end
  end)
end

-- Trigger placement -------------------------------------------------------------------------------

local function drawPlacementCrosshair(pos)
  local lineWidth = editor.getPreference("gizmos.general.lineThicknessScale") * 4
  debugDrawer:drawLineInstance((pos - vec3(2, 0, 0)), (pos + vec3(2, 0, 0)), lineWidth, ColorF(1, 0, 0, 1))
  debugDrawer:drawLineInstance((pos - vec3(0, 2, 0)), (pos + vec3(0, 2, 0)), lineWidth, ColorF(0, 1, 0, 1))
  debugDrawer:drawLineInstance((pos - vec3(0, 0, 2)), (pos + vec3(0, 0, 2)), lineWidth, ColorF(0, 0, 1, 1))
end

-- A new trigger goes under the selected group, or under MissionGroup when the selection is not a group.
local function placementParent()
  local parent = scenetree.MissionGroup
  local selection = editor.selection
  if selection and selection.object and #selection.object > 0 then
    local selected = scenetree.findObjectById(selection.object[1])
    if selected and selected:isSubClassOf("SimGroup") then
      parent = selected
    elseif selected then
      local group = selected:getGroup()
      if group and group:getName() ~= "MissionCleanup" then parent = group end
    end
  end
  return parent
end

local function createTriggerAt(pos)
  local triggerName = TRIGGER_PREFIXES[pendingTriggerType] .. pendingTriggerRace
  local obj = worldEditorCppApi.createObject("BeamNGTrigger")
  if not obj then return end

  obj:setName(triggerName)
  obj:registerObject("")
  obj:setPosition(pos)
  local parent = placementParent()
  if parent then parent:addObject(obj) end
  editor.selectObjectById(obj:getID())
  table.insert(levelTriggers, triggerName)
  log("I", LOG_TAG, "Created new trigger: " .. triggerName)
  clearPendingTrigger()
end

-- Runs each frame while a trigger waits for a click on the map.
local function triggerPlacementUpdate()
  if not pendingTriggerType or not pendingTriggerRace then return end
  getCameraMouseRay()

  local hit = cameraMouseRayCast(true)
  if not hit or not hit.pos then return end
  local pos = vec3(worldEditorCppApi.snapPositionToGrid(hit.pos))
  drawPlacementCrosshair(pos)

  if imgui.IsMouseClicked(0) and editor.isViewportHovered() then createTriggerAt(pos) end
end

-- Selects the trigger when it exists; otherwise the next map click places it.
local function createOrSelectTrigger(triggerType, raceName)
  if not raceName then return end

  local triggerName = TRIGGER_PREFIXES[triggerType] .. raceName
  local existingTrigger = scenetree.findObject(triggerName)
  if existingTrigger then
    editor.selectObjectById(existingTrigger:getID())
    log("I", LOG_TAG, "Selected trigger: " .. triggerName)
    return
  end

  pendingTriggerType = triggerType
  pendingTriggerRace = raceName
  showTriggerPlacementHelp = true
  log("I", LOG_TAG, "Ready to place " .. triggerType .. " trigger for race: " .. raceName)
  editor.showNotification("Click on the map to place " .. triggerType .. " trigger")
end

-- Race completeness -------------------------------------------------------------------------------

local function isRaceComplete(raceName, race)
  local hasCheckpointRoad = race.checkpointRoad ~= nil and race.checkpointRoad ~= ""
  local hasStartTrigger = triggerExists(TRIGGER_PREFIXES.start, raceName)
  local hasStagingTrigger = triggerExists(TRIGGER_PREFIXES.staging, raceName)
  local hasPitTrigger = not race.hasPits or triggerExists(TRIGGER_PREFIXES.pit, raceName)

  if race.hotlap then
    return hasCheckpointRoad and hasStartTrigger and hasStagingTrigger and hasPitTrigger
  end
  local hasFinishTrigger = triggerExists(TRIGGER_PREFIXES.finish, raceName)
  return hasCheckpointRoad and hasStartTrigger and hasStagingTrigger and hasFinishTrigger and hasPitTrigger
end

local function getMissingComponents(raceName, race)
  local missing = {}
  if not race.checkpointRoad or race.checkpointRoad == "" then table.insert(missing, "Checkpoint road") end
  if not triggerExists(TRIGGER_PREFIXES.start, raceName) then table.insert(missing, "Start trigger") end
  if not triggerExists(TRIGGER_PREFIXES.staging, raceName) then table.insert(missing, "Staging trigger") end
  if not race.hotlap and not triggerExists(TRIGGER_PREFIXES.finish, raceName) then
    table.insert(missing, "Finish trigger")
  end
  if race.hasPits and not triggerExists(TRIGGER_PREFIXES.pit, raceName) then
    table.insert(missing, "Pit trigger")
  end
  return missing
end

-- Checkpoints -------------------------------------------------------------------------------------

-- Keep failed deletion ownership until a later teardown can finish it.
local function disposePreview()
  previewLifetime.closed = true
  if not previewLifetime.instance then return true end
  local complete = previewLifetime.instance.dispose()
  if complete then previewLifetime.instance = nil end
  return complete
end

local function getPreview()
  if previewLifetime.unloaded or not previewLifetime.worldReady then
    error("Editor checkpoint preview is unavailable outside its lifetime.", 0)
  end
  if previewLifetime.closed then
    if not disposePreview() then error("Editor checkpoint preview cleanup is incomplete.", 0) end
    previewLifetime.instance = createCoursePreview()
    previewLifetime.closed = false
  end
  return previewLifetime.instance
end

local function showRaceCheckpoints()
  if not currentRaceName then return end
  dump(races[currentRaceName])

  local preview = getPreview()
  checkpoints, altCheckpoints = preview.roadCheckpoints.getCheckpoints(races[currentRaceName])
  preview.checkpointManager.createCheckpoints(checkpoints, altCheckpoints)

  roadNodes = preview.roadCheckpoints.getRoadNodesFromRace(races[currentRaceName])
  if races[currentRaceName].altRoute then
    altRoadNodes = preview.roadCheckpoints.getRoadNodesFromRace(races[currentRaceName].altRoute)
  end
end

local function removeRaceCheckpoints()
  if previewLifetime.closed then return disposePreview() end
  local preview = previewLifetime.instance
  local complete = preview.checkpointManager.removeCheckpoints()
  preview.roadCheckpoints.reset()
  return complete
end

-- Renames the triggers that follow the race id; the pit trigger keeps its own name, as before.
local function renameTriggers(oldRaceName, newRaceName)
  for _, prefix in ipairs({ TRIGGER_PREFIXES.start, TRIGGER_PREFIXES.staging, TRIGGER_PREFIXES.finish }) do
    local oldTriggerName = prefix .. oldRaceName
    local newTriggerName = prefix .. newRaceName
    local trigger = scenetree.findObject(oldTriggerName)
    if trigger then
      trigger:setName(newTriggerName)
      for index, name in ipairs(levelTriggers) do
        if name == oldTriggerName then
          levelTriggers[index] = newTriggerName
          break
        end
      end
      log("I", LOG_TAG, "Renamed trigger from " .. oldTriggerName .. " to " .. newTriggerName)
    end
  end
end

-- Returns true when the race was renamed.
local function renameRace(race, newRaceName)
  if newRaceName == currentRaceName or newRaceName == "" or races[newRaceName] then return false end

  renameTriggers(currentRaceName, newRaceName)
  races[newRaceName] = deepcopy(race)
  races[currentRaceName] = nil
  local oldRaceName = currentRaceName
  currentRaceName = newRaceName
  log("I", LOG_TAG, "Renamed race from " .. oldRaceName .. " to " .. newRaceName)
  return true
end

-- Hover help for Damage Factor; a modal popup opened from the "?" button.
local function drawDamageFactorHelp()
  if imgui.Button("?##damageFactor") then imgui.OpenPopup("Damage Factor Help") end
  if not imgui.BeginPopupModal("Damage Factor Help", nil, imgui.WindowFlags_AlwaysAutoResize) then return end

  imgui.Text("Damage Factor determines how damage affects scoring:")
  imgui.Separator()
  imgui.BulletText("0.0 = Time only (traditional time trial)")
  imgui.BulletText("0.5 = 50% time, 50% damage (balanced)")
  imgui.BulletText("1.0 = Damage only (no damage = full reward)")
  imgui.Separator()
  imgui.Text("Higher values prioritize avoiding damage over speed.")
  if imgui.Button("Close") then imgui.CloseCurrentPopup() end
  imgui.EndPopup()
end

-- Timeout hover help; a modal popup opened from the "?" button.
local function drawTimeoutHelp()
  if imgui.Button("?##timeout") then imgui.OpenPopup("Timeout Help") end
  if not imgui.BeginPopupModal("Timeout Help", nil, imgui.WindowFlags_AlwaysAutoResize) then return end

  imgui.Text("Stationary Timeout determines how long a player can remain")
  imgui.Text("stationary before the race is automatically cancelled.")
  imgui.Separator()
  imgui.BulletText("Lower values (5-10s): Fast-paced events")
  imgui.BulletText("Higher values (15-30s): Methodical/technical events")
  imgui.BulletText("Default: 10 seconds")
  imgui.Separator()
  imgui.Text("Players get countdown warnings before timeout.")
  if imgui.Button("Close") then imgui.CloseCurrentPopup() end
  imgui.EndPopup()
end

-- Editor sections ---------------------------------------------------------------------------------

local function drawFileMenu()
  if not imgui.BeginMenuBar() then return end
  if imgui.BeginMenu("File") then
    if imgui.MenuItem1("New") then createNewRaceData() end
    if imgui.MenuItem1("Load...") then loadRaceData() end
    if imgui.MenuItem1("Save") then saveRaceData() end
    imgui.EndMenu()
  end
  imgui.EndMenuBar()
end

local function drawLevelStatus(level)
  if modified then imgui.TextColored(imgui.ImVec4(1, 1, 0, 1), "Modified (unsaved)") end
  imgui.Text("Current Level: " .. level)
end

-- Missing components are shown in red until the race is complete.
local function drawEventListItem(raceName, race)
  local complete = isRaceComplete(raceName, race)
  if not complete then
    imgui.PushStyleColor2(imgui.Col_Button, imgui.ImVec4(0.8, 0.2, 0.2, 1.0))
    imgui.PushStyleColor2(imgui.Col_ButtonHovered, imgui.ImVec4(0.9, 0.3, 0.3, 1.0))
    imgui.PushStyleColor2(imgui.Col_ButtonActive, imgui.ImVec4(1.0, 0.4, 0.4, 1.0))
  end

  if imgui.Button((race.label or "Unnamed") .. "##" .. raceName, imgui.ImVec2(imgui.GetContentRegionAvailWidth(), 0)) then
    currentRaceName = raceName
    if showingRaceCheckpoints then removeRaceCheckpoints() end
  end

  if not complete then imgui.PopStyleColor(3) end

  if imgui.IsItemHovered() then
    imgui.BeginTooltip()
    imgui.Text("Event ID: " .. raceName)
    if complete then
      imgui.TextColored(imgui.ImVec4(0.4, 1, 0.4, 1), "Complete race")
    else
      imgui.TextColored(imgui.ImVec4(1, 0.4, 0.4, 1), "Incomplete race! Missing:")
      for _, component in ipairs(getMissingComponents(raceName, race)) do
        imgui.BulletText(component)
      end
    end
    imgui.EndTooltip()
  end
end

local function drawEventList(leftPanelWidth)
  imgui.BeginChild1("EventsList", imgui.ImVec2(leftPanelWidth, imgui.GetContentRegionAvail().y), true)

  if imgui.Button("Create New Event", imgui.ImVec2(imgui.GetContentRegionAvailWidth(), 0)) then
    createNewRace()
  end
  imgui.Separator()

  imgui.Text("Events (" .. countTableEntries(races) .. "):")
  for raceName, race in pairs(races) do
    drawEventListItem(raceName, race)
  end

  imgui.EndChild()
end

-- Returns true when the event ID or the event's own fields changed.
local function drawRaceIdField(race)
  imgui.PushID1(currentRaceName .. "_id")
  local changed = false
  local raceNameBuf = imgui.ArrayChar(128, currentRaceName)
  if imgui.InputText("Event ID", raceNameBuf, 128, imgui.InputTextFlags_EnterReturnsTrue) then
    changed = renameRace(race, ffi.string(raceNameBuf))
  end
  imgui.PopID()
  return changed
end

local function drawDriftGoal(race)
  local changed = false
  local isDriftGoal = imgui.BoolPtr(race.driftGoal ~= nil)
  if imgui.Checkbox("Drift Event", isDriftGoal) then
    race.driftGoal = isDriftGoal[0] and 1.0 or nil
    changed = true
  end

  if isDriftGoal[0] then
    local driftGoal = imgui.IntPtr(race.driftGoal or 1000)
    if imgui.InputInt("Drift Goal", driftGoal, 100, 10000) then
      race.driftGoal = driftGoal[0]
      changed = true
    end
  end
  return changed
end

local function drawDamageFactor(race)
  local changed = false
  local hasDamageFactor = imgui.BoolPtr(race.damageFactor ~= nil)
  if imgui.Checkbox("Enable Damage Factor", hasDamageFactor) then
    race.damageFactor = hasDamageFactor[0] and 0.5 or nil
    changed = true
  end
  if not hasDamageFactor[0] then return changed end

  local damageFactor = imgui.FloatPtr(race.damageFactor or 0.5)
  if imgui.SliderFloat("Damage Factor", damageFactor, 0.0, 1.0, "%.2f") then
    race.damageFactor = damageFactor[0]
    changed = true
  end
  imgui.SameLine()
  drawDamageFactorHelp()
  return changed
end

-- Event details ---------------------------------------------------------------------------------

local function drawBasicEventInformation(race)
  if not imgui.CollapsingHeader1("Basic Event Information") then return false end
  local changed = drawRaceIdField(race)

  local eventLabel = imgui.ArrayChar(128, race.label or "")
  if imgui.InputText("Event Label", eventLabel) then
    race.label = ffi.string(eventLabel)
    changed = true
  end

  local bestTime = imgui.FloatPtr(race.bestTime or 60)
  if imgui.InputFloat("Best Time (seconds)", bestTime, 1, 5, "%.1f") then
    race.bestTime = bestTime[0]
    changed = true
  end

  changed = drawDriftGoal(race) or changed
  changed = drawDamageFactor(race) or changed
  return changed
end

-- Reward preview --------------------------------------------------------------------------------

-- Estimated reward for the preview inputs: the scoring formula depends on the race's drift and damage settings.
local function previewReward(race)
  if race.driftGoal then
    imgui.InputInt("Drift Score", driftScore, 100, 10000)
    return rewardPolicy.driftReward(race, realTime[0], driftScore[0])
  end
  if race.damageFactor and race.damageFactor > 0 then
    imgui.SliderFloat("Damage % (Preview)", damagePercentage, 0.0, 1.0, "%.1f")
    imgui.SameLine()
    imgui.Text(string.format("(%.1f%%)", damagePercentage[0] * 100))
    local reward = rewardPolicy.hybridRaceReward(race.bestTime, race.reward, realTime[0], race.damageFactor, damagePercentage[0])
    imgui.Text(string.format("Damage Factor: %.2f | Time Factor: %.2f", race.damageFactor, 1.0 - race.damageFactor))
    return reward
  end
  return rewardPolicy.raceReward(race.bestTime, race.reward, realTime[0])
end

local function drawReward(race)
  if not imgui.CollapsingHeader1("Reward") then return false end
  local changed = false
  local rewardPtr = imgui.IntPtr(race.reward or 1000)
  if imgui.InputInt("Reward ($)", rewardPtr, 100, 1000) then
    race.reward = rewardPtr[0]
    changed = true
  end

  imgui.Text("Reward Calculation:")
  imgui.InputFloat("Time (seconds)", realTime, 1, 5, "%.1f")
  local reward = previewReward(race)

  imgui.InputInt("Lap Count", lapCount, 1, 100)
  reward = reward * eventHelpers.hotlapMultiplier(lapCount[0])

  imgui.Checkbox("Best Time Session", bestTimeSession)
  imgui.Checkbox("In Range", inRange)
  imgui.Checkbox("Hardcore", hardcore)
  if bestTimeSession[0] then reward = reward * 1.2 end
  if inRange[0] then reward = reward * 1.05 end
  if hardcore[0] then reward = reward * 0.5 end

  imgui.Text(string.format("Calculated Reward: %.0f", reward))

  if race.damageFactor and race.damageFactor > 0 then
    imgui.Separator()
    imgui.TextColored(imgui.ImVec4(0.7, 0.7, 1.0, 1.0), "Damage-Based Scoring Enabled")
    imgui.Text(string.format("- Time Component: %.0f%%", (1.0 - race.damageFactor) * 100))
    imgui.Text(string.format("- Damage Component: %.0f%%", race.damageFactor * 100))
  end
  return changed
end

-- Event options ---------------------------------------------------------------------------------

local function drawEventOptions(race)
  if not imgui.CollapsingHeader1("Event Options") then return false end
  local changed = false
  local hasApexOffset = imgui.BoolPtr(race.apexOffset ~= nil)
  if imgui.Checkbox("Use Apex Offset", hasApexOffset) then
    race.apexOffset = hasApexOffset[0] and 1.0 or nil
    changed = true
  end

  if hasApexOffset[0] then
    local apexOffset = imgui.FloatPtr(race.apexOffset or 1.0)
    if imgui.InputFloat("Apex Offset (Nodes)", apexOffset, 0.1, 1.0, "%.1f") then
      race.apexOffset = apexOffset[0]
      changed = true
    end
  end

  local runningStart = imgui.BoolPtr(race.runningStart or false)
  if imgui.Checkbox("Running Start", runningStart) then
    race.runningStart = runningStart[0]
    changed = true
  end

  local reverse = imgui.BoolPtr(race.reverse or false)
  if imgui.Checkbox("Reverse", reverse) then
    race.reverse = reverse[0]
    changed = true
  end

  local timeout = imgui.IntPtr(race.timeout or 10)
  if imgui.InputInt("Stationary Timeout (seconds)", timeout, 1, 5) then
    race.timeout = math.max(1, timeout[0])
    changed = true
  end
  imgui.SameLine()
  drawTimeoutHelp()
  return changed
end

-- Event types -----------------------------------------------------------------------------------

local function drawEventTypes(race)
  if not imgui.CollapsingHeader1("Event Type") then return false end
  local changed = false
  local customType = imgui.ArrayChar(128, "")
  if imgui.InputText("Custom Type", customType, 128, imgui.InputTextFlags_EnterReturnsTrue) then
    table.insert(raceTypes, ffi.string(customType))
    table.insert(race.type, ffi.string(customType))
    changed = true
  end

  for _, raceType in ipairs(race.type) do
    if not tableContains(raceTypes, raceType) then table.insert(raceTypes, raceType) end
  end

  -- Lay the checkboxes out in as many columns as the width fits, at least 150 px each.
  local availableWidth = imgui.GetContentRegionAvail().x
  local minCheckboxWidth = 150
  local columnsPerRow = math.max(1, math.floor(availableWidth / minCheckboxWidth))
  local columnWidth = availableWidth / columnsPerRow
  local rowCount = 0

  for _, raceType in ipairs(raceTypes) do
    if not race.type then race.type = { "motorsport" } end

    local isSelected = imgui.BoolPtr(tableContains(race.type, raceType))
    local typeChanged = false

    if rowCount % columnsPerRow ~= 0 then
      imgui.SameLine()
      imgui.SetCursorPosX((rowCount % columnsPerRow) * columnWidth)
    end

    if imgui.Checkbox(raceType, isSelected) then
      if isSelected[0] then
        if not tableContains(race.type, raceType) then
          table.insert(race.type, raceType)
          typeChanged = true
        end
      elseif tableContains(race.type, raceType) then
        table.remove(race.type, tableIndexOf(race.type, raceType))
        typeChanged = true
      end
    end

    rowCount = rowCount + 1
    if typeChanged then changed = true end
  end
  return changed
end

-- Checkpoint roads ------------------------------------------------------------------------------

-- Hotlap is a timed loop; the hotlap time defaults to 90% of the best time.
local function drawLoopMode(race)
  local changed = false
  imgui.Text("Checkpoint Road:")
  local loopSelected = imgui.IntPtr(race.hotlap and 1 or 2)

  if imgui.RadioButton2("Looped", loopSelected, imgui.Int(1)) then
    race.hotlap = race.hotlap or (race.bestTime * 0.9)
    changed = true
  end
  imgui.SameLine()
  if imgui.RadioButton2("Point-to-Point", loopSelected, imgui.Int(2)) then
    race.hotlap = nil
    changed = true
  end

  if race.hotlap then
    local hotlap = imgui.FloatPtr(race.hotlap or (race.bestTime * 0.9))
    if imgui.InputFloat("Hotlap Time (seconds)", hotlap, 1, 5, "%.1f") then
      race.hotlap = hotlap[0]
      changed = true
    end
  end
  return changed
end

-- Returns the filter text in lower case, for the road combos.
local function drawRoadFilter()
  local roadFilter = imgui.ArrayChar(128, roadFilterText)
  if imgui.InputText("Filter Roads", roadFilter, 128) then
    roadFilterText = ffi.string(roadFilter)
  end
  return roadFilterText:lower()
end

-- Lists the matching roads for one combo; returns true when a road was picked.
local function drawRoadComboItems(race, index, roadName, filterText)
  local changed = false
  local foundAny = false

  if roadName and roadName ~= "" and (filterText == "" or string.find(roadName:lower(), filterText)) then
    imgui.Selectable1(roadName .. " (current)", true)
    imgui.Separator()
    foundAny = true
  end

  for _, availableRoad in ipairs(levelDecalRoads) do
    if availableRoad ~= "" and (filterText == "" or string.find(availableRoad:lower(), filterText)) then
      foundAny = true
      if imgui.Selectable1(availableRoad, availableRoad == roadName) then
        race.checkpointRoad[index] = availableRoad
        changed = true
      end
    end
  end

  if not foundAny then imgui.Text("No roads match your filter") end
  return changed
end

local function drawRoadSelectors(race, filterText)
  local changed = false
  if race.checkpointRoad and type(race.checkpointRoad) ~= "table" then
    race.checkpointRoad = { race.checkpointRoad }
  elseif not race.checkpointRoad then
    race.checkpointRoad = {}
  end

  for index, roadName in ipairs(race.checkpointRoad) do
    local comboLabel = "Select Road #" .. index
    local currentRoad = roadName or "Choose a road"

    if index > 1 then
      if imgui.Button("X##remove" .. index, imgui.ImVec2(24, 0)) then
        table.remove(race.checkpointRoad, index)
        changed = true
        break
      end
      imgui.SameLine()
    end

    if imgui.BeginCombo(comboLabel, currentRoad) then
      -- Roads are validated later in onEditorUpdate, not while the list is open.
      if drawRoadComboItems(race, index, roadName, filterText) then changed = true end
      imgui.EndCombo()
    end
  end

  if imgui.Button("+ Add Road", imgui.ImVec2(imgui.GetContentRegionAvailWidth(), 0)) then
    table.insert(race.checkpointRoad, "")
    changed = true
  end
  return changed
end

-- Checkpoint controls ---------------------------------------------------------------------------

-- Manual checkpoint list: each row removes or inserts a checkpoint index and rebuilds the road checkpoints.
local function showCheckpointsEditor(race)
  if not showingCheckpointsEditor then return end
  if not race.checkpointIndexs then
    race.checkpointIndexs = {}
    for i, checkpoint in ipairs(checkpoints) do
      race.checkpointIndexs[i] = checkpoint.index
    end
  end

  imgui.Text("Editing Checkpoints")
  if imgui.CollapsingHeader1("Checkpoints") then
    for i in ipairs(checkpoints) do
      -- A unique ID per row keeps the buttons apart.
      imgui.PushID1("checkpoint_" .. tostring(i))
      imgui.Text("Checkpoint " .. tostring(i))
      imgui.SameLine()

      if imgui.Button("X##remove" .. i, imgui.ImVec2(24, 0)) then
        table.remove(race.checkpointIndexs, i)
        removeRaceCheckpoints()
        showRaceCheckpoints()
        break
      end
      imgui.SameLine()

      imgui.SetNextItemWidth(imgui.GetContentRegionAvailWidth() / 2)
      local index = imgui.IntPtr(race.checkpointIndexs[i])
      if imgui.InputInt("##Index", index, 1, 10) then
        race.checkpointIndexs[i] = index[0]
        removeRaceCheckpoints()
        showRaceCheckpoints()
      end
      imgui.SameLine()

      if imgui.Button("Add##add" .. i, imgui.ImVec2(60, 0)) then
        table.insert(race.checkpointIndexs, i + 1, race.checkpointIndexs[i] + 1)
        removeRaceCheckpoints()
        showRaceCheckpoints()
        break
      end
      imgui.PopID()
    end
  end
end

local function drawCheckpointButtons(race)
  imgui.Spacing()
  if imgui.Button("Show Checkpoints", imgui.ImVec2(imgui.GetContentRegionAvailWidth() / 2, 0)) then
    showingRaceCheckpoints = true
    showRaceCheckpoints()
  end
  imgui.SameLine()
  if imgui.Button("Hide Checkpoints", imgui.ImVec2(imgui.GetContentRegionAvailWidth(), 0)) then
    showingRaceCheckpoints = false
    removeRaceCheckpoints()
    roadNodes = nil
    altRoadNodes = nil
  end

  if not showingRaceCheckpoints then return end
  local buttonText = not showingCheckpointsEditor and "Manual Edit Checkpoints" or "Use Auto Checkpoints"
  if imgui.Button(buttonText, imgui.ImVec2(imgui.GetContentRegionAvailWidth(), 0)) then
    if not showingCheckpointsEditor then
      showingCheckpointsEditor = true
    else
      race.checkpointIndexs = nil
      showingCheckpointsEditor = false
    end
  end
  showCheckpointsEditor(race)
end

local function drawCheckpointSettings(race)
  if not imgui.CollapsingHeader1("Checkpoint Settings") then return false end
  local changed = drawLoopMode(race)
  local filterText = drawRoadFilter()
  changed = drawRoadSelectors(race, filterText) or changed
  drawCheckpointButtons(race)
  return changed
end

-- Trigger controls ------------------------------------------------------------------------------

-- One trigger button: select or create the trigger, or cancel a placement already in progress.
local function drawTriggerButton(triggerType, word)
  local exists = triggerExists(TRIGGER_PREFIXES[triggerType], currentRaceName)
  local isPending = pendingTriggerType == triggerType and pendingTriggerRace == currentRaceName
  local buttonText
  if isPending then
    buttonText = "Cancel " .. word .. " Trigger Placement"
  else
    buttonText = (exists and "Select " or "Create ") .. word .. " Trigger"
  end

  imgui.PushStyleColor2(imgui.Col_Text, exists and imgui.ImVec4(0.2, 0.8, 0.2, 1.0) or imgui.ImVec4(0.8, 0.2, 0.2, 1.0))
  if imgui.Button(buttonText, imgui.ImVec2(imgui.GetContentRegionAvailWidth(), 0)) then
    if isPending then
      clearPendingTrigger()
    else
      createOrSelectTrigger(triggerType, currentRaceName)
    end
  end
  imgui.PopStyleColor()
end

local function drawTriggerManagement(race)
  if not imgui.CollapsingHeader1("Trigger Management") then return end
  drawTriggerButton("start", "Start")
  drawTriggerButton("staging", "Staging")
  if not race.hotlap then drawTriggerButton("finish", "Finish") end

  if showTriggerPlacementHelp then
    imgui.TextColored(imgui.ImVec4(1, 1, 0, 1), "Click on the map to place the trigger")
  end
end

local function drawPitSpeedLimit(race)
  local changed = false
  local pitSpeedLimit = imgui.IntPtr(race.pitSpeedLimit or 60)
  if imgui.InputInt("Pit Speed Limit", pitSpeedLimit, 5, 10) then
    race.pitSpeedLimit = math.max(5, pitSpeedLimit[0])
    race.pitSpeedLimitUnit = race.pitSpeedLimitUnit or race.pitSpeedUnit or "KPH"
    race.pitSpeedUnit = nil
    changed = true
  end

  local unitOptions = { "KPH", "MPH" }
  local currentUnit = race.pitSpeedLimitUnit or race.pitSpeedUnit or "KPH"
  if imgui.BeginCombo("Speed Unit", currentUnit) then
    for _, unit in ipairs(unitOptions) do
      local isSelected = unit == currentUnit
      if imgui.Selectable1(unit, isSelected) then
        race.pitSpeedLimitUnit = unit
        race.pitSpeedUnit = nil
        changed = true
      end
      -- Initial focus lands on the current unit when the combo opens.
      if isSelected then imgui.SetItemDefaultFocus() end
    end
    imgui.EndCombo()
  end
  return changed
end

local function drawPitsManagement(race)
  if not imgui.CollapsingHeader1("Pits Management") then return false end
  local changed = false
  local hasPits = imgui.BoolPtr(race.hasPits or false)
  if imgui.Checkbox("Enable Pit Lane Speed Limit", hasPits) then
    race.hasPits = hasPits[0]
    changed = true
  end

  if race.hasPits then
    if drawPitSpeedLimit(race) then changed = true end
    drawTriggerButton("pit", "Pit")
  end
  return changed
end

-- Event actions ---------------------------------------------------------------------------------

-- Delete asks for confirmation in a modal before the race is removed.
local function drawEventActions()
  local changed = false
  if imgui.Button("Delete Event", imgui.ImVec2(imgui.GetContentRegionAvailWidth(), 0)) then
    imgui.OpenPopup("Delete Event Confirmation")
  end

  if imgui.BeginPopupModal("Delete Event Confirmation", nil, imgui.WindowFlags_AlwaysAutoResize) then
    imgui.Text("Are you sure you want to delete this event?")
    imgui.Text("This action cannot be undone.")
    imgui.Separator()

    if imgui.Button("Yes, Delete Event", imgui.ImVec2(imgui.GetContentRegionAvailWidth() / 2, 0)) then
      races[currentRaceName] = nil
      currentRaceName = nil
      changed = true
      imgui.CloseCurrentPopup()
    end
    imgui.SameLine()
    if imgui.Button("Cancel", imgui.ImVec2(imgui.GetContentRegionAvailWidth(), 0)) then
      imgui.CloseCurrentPopup()
    end
    imgui.EndPopup()
  end
  return changed
end

-- Draws the selected race's sections; every section runs, so an earlier edit never skips a later one.
local function drawSelectedRace()
  if not (currentRaceName and races[currentRaceName]) then return end
  local race = races[currentRaceName]
  imgui.Text("Editing Event: " .. currentRaceName)
  imgui.Separator()

  local changed = drawBasicEventInformation(race)
  changed = drawReward(race) or changed
  changed = drawEventOptions(race) or changed
  changed = drawEventTypes(race) or changed
  changed = drawCheckpointSettings(race) or changed
  drawTriggerManagement(race)
  changed = drawPitsManagement(race) or changed
  changed = drawEventActions() or changed
  if changed then modified = true end
end

-- Editor window -----------------------------------------------------------------------------------

local function onEditorGui()
  if not editor.isWindowVisible(TOOL_WINDOW_NAME) then return end
  M.onEditorUpdate()
  if not editor.beginWindow(TOOL_WINDOW_NAME, "Freeroam Event Editor", imgui.WindowFlags_MenuBar) then return end

  local level = getCurrentLevelIdentifier()
  if not level then
    imgui.Text("No level loaded!")
    editor.endWindow()
    return
  end

  drawFileMenu()
  drawLevelStatus(level)

  local leftPanelWidth = imgui.GetContentRegionAvailWidth() * 0.3
  drawEventList(leftPanelWidth)
  imgui.SameLine()
  imgui.BeginChild1("RaceDetails", imgui.ImVec2(0, imgui.GetContentRegionAvail().y), true)
  drawSelectedRace()

  editor.endWindow()
end

local function onActivate()
  log("I", LOG_TAG, "Freeroam Event Editor activated")
  findLevelObjects()
end

local function onWindowMenuItem()
  editor.showWindow(TOOL_WINDOW_NAME)
end

local function onEditorInitialized()
  editor.registerWindow(TOOL_WINDOW_NAME, imgui.ImVec2(600, 600))
  editor.addWindowMenuItem("Freeroam Event Editor", onWindowMenuItem)
  log("I", LOG_TAG, "Freeroam Event Editor initialized")
  loadRaceData()
  findLevelObjects()
end

-- Legacy string roads and table roads both drop the entries the level no longer has.
local function dropMissingCheckpointRoads(race)
  if type(race.checkpointRoad) == "string" then
    if race.checkpointRoad ~= "" and not listContains(levelDecalRoads, race.checkpointRoad) then
      race.checkpointRoad = nil
      modified = true
    end
  elseif type(race.checkpointRoad) == "table" then
    local validRoads = {}
    for _, roadName in ipairs(race.checkpointRoad) do
      if roadName == "" or listContains(levelDecalRoads, roadName) then table.insert(validRoads, roadName) end
    end
    if #validRoads ~= #race.checkpointRoad then
      race.checkpointRoad = validRoads
      modified = true
    end
  end
end

-- Update ------------------------------------------------------------------------------------------

-- Runs every frame: placement while a trigger waits for a click, and a road rescan every few seconds.
function M.onEditorUpdate()
  if pendingTriggerType and pendingTriggerRace then triggerPlacementUpdate() end
  if os.time() - lastOsTime <= EDITOR_UPDATE_INTERVAL_SECONDS then return end

  lastOsTime = os.time()
  findDecalRoads()
  for _, race in pairs(races) do
    if race.checkpointRoad then dropMissingCheckpointRoads(race) end
  end
end

-- Lifecycle ---------------------------------------------------------------------------------------

local function onExtensionLoaded()
  loadRaceData()
end

local function onWorldReadyState(worldReadyState)
  if worldReadyState ~= 2 or previewLifetime.unloaded then return end
  local complete = disposePreview()
  previewLifetime.worldReady = true
  showingRaceCheckpoints, showingCheckpointsEditor = false, false
  loadRaceData()
  if not complete then return false end
end

local function onEditorDeactivated()
  showingRaceCheckpoints, showingCheckpointsEditor = false, false
  return disposePreview()
end

local function onClientEndMission()
  previewLifetime.worldReady = false
  return onEditorDeactivated()
end

local function prepareForUnload()
  return disposePreview()
end

local function onExtensionUnloaded()
  -- Never skip disposal on repeated unloads: a failed group deletion can be retried.
  previewLifetime.unloaded = true
  local complete = onEditorDeactivated()
  if not complete then
    log("E", LOG_TAG, "Editor preview cleanup failed; the engine does not wait for an unload-hook refusal.")
  end
  return complete
end

-- Game hooks --------------------------------------------------------------------------------------

M.onEditorGui = onEditorGui
M.onEditorInitialized = onEditorInitialized
M.onWindowMenuItem = onWindowMenuItem
M.onActivate = onActivate
M.onExtensionLoaded = onExtensionLoaded
M.onWorldReadyState = onWorldReadyState
M.onEditorDeactivated = onEditorDeactivated
M.onClientEndMission = onClientEndMission
M.onExtensionUnloaded = onExtensionUnloaded
M.prepareForUnload = prepareForUnload

return M
