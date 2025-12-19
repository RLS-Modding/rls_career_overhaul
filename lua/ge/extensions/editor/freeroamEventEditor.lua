-- World Editor Freeroam Event Creator

-- TODO:
-- Alt Route Handling

local M = {}
local logTag = 'editor_freeroamEventEditor' -- this is used for logging as a tag
local im = ui_imgui -- shortcut for imgui
local toolWindowName = "editor_freeroamEventEditor_window"

local processRoad = require('gameplay/events/freeroam/processRoad')
local checkpointManager = require('gameplay/events/freeroam/checkpointManager')
local utils = require('gameplay/events/freeroam/utils')
local races = {}
local currentRaceName = nil
local modified = false
local raceTypes = {"motorsport", "drift", "drag", "offroad", "rally"}
local levelTriggers = {}
local levelDecalRoads = {}
local pendingTriggerType = nil
local pendingTriggerRace = nil
local pendingTriggerName = nil
local showTriggerPlacementHelp = false
local showingRaceCheckpoints = false
local showingCheckpointsEditor = false
local checkpoints = {}
local altCheckpoints = {}
local roadNodes = {}
local altRoadNodes = {}

local bestTimeSession = im.BoolPtr(false)
local inRange = im.BoolPtr(false)
local realTime = im.FloatPtr(0)
local driftScore = im.IntPtr(1000)
local lapCount = im.IntPtr(1)
local hardcore = im.BoolPtr(false)
local damagePercentage = im.FloatPtr(0.0)

local lookingForRoad = false

-- Outside any function, at the top-level scope with other state variables
local roadFilterText = ""

-- Template for new race
local raceTemplate = {
  bestTime = 60,
  reward = 1000,
  label = "New Event",
  checkpointRoad = nil,
  type = {"motorsport"},
  timeout = 10
}

-- Function to create a new race
local function createNewRace()
  local newRaceName = "event_" .. os.time()
  races[newRaceName] = deepcopy(raceTemplate)
  races[newRaceName].label = "New Event"
  currentRaceName = newRaceName
  modified = true
  log('I', logTag, "Created new event: " .. newRaceName)
  return newRaceName
end

-- Function to load race data from file
local function loadRaceData()
  local level = getCurrentLevelIdentifier()
  if not level then return end
  
  local filePath = "levels/" .. level .. "/race_data.json"
  local raceData = jsonReadFile(filePath) or {races = {}}
  races = raceData.races or {}
  modified = false

  for raceName, race in pairs(races) do
    for _, rType in ipairs(race.type) do
      if not tableContains(raceTypes, rType) then
        table.insert(raceTypes, rType)
      end
    end
  end
  
  log('I', logTag, "Loaded race data for level: " .. level)
end

-- Function to save race data to file
local function saveRaceData()
  local level = getCurrentLevelIdentifier()
  if not level then 
    log('E', logTag, "No level loaded!")
    return 
  end
  
  local filePath = "levels/" .. level .. "/race_data.json"
  local raceData = {races = races}
  jsonWriteFile(filePath, raceData, true)
  modified = false
  log('I', logTag, "Saved race data to: " .. filePath)
end

-- Function to create new empty race data
local function createNewRaceData()
  races = {}
  currentRaceName = nil
  modified = true
  log('I', logTag, "Created new race data")
end

-- Count the number of entries in a table
local function countTableEntries(t)
  local count = 0
  if t then
    for _ in pairs(t) do count = count + 1 end
  end
  return count
end

local function showRaceCheckpoints()
  if not currentRaceName then return end
  dump(races[currentRaceName])

  checkpoints, altCheckpoints = processRoad.getCheckpoints(races[currentRaceName])
  checkpointManager.createCheckpoints(checkpoints, altCheckpoints)

  roadNodes = processRoad.getRoadNodesFromRace(races[currentRaceName])
  if races[currentRaceName].altRoute then
    altRoadNodes = processRoad.getRoadNodesFromRace(races[currentRaceName].altRoute)
  end
end

local function removeRaceCheckpoints()
  checkpointManager.removeCheckpoints()
  processRoad.reset()
end

-- Function to find all triggers and decal roads in the level
local function findLevelObjects()
  -- Find all triggers and decal roads
  levelTriggers = {}
  levelDecalRoads = {}
  
  -- The correct way to iterate through objects in BeamNG
  local missionGroup = scenetree.findObject("MissionGroup")
  if not missionGroup then return end
  
  -- Recursive function to search for objects
  local function searchObjects(group)
    for i, objName in ipairs(group:getObjects()) do
      local obj = scenetree.findObject(objName)
      if obj then
        if obj:getClassName() == "BeamNGTrigger" then
          table.insert(levelTriggers, obj:getName())
        elseif obj:getClassName() == "DecalRoad" then
          table.insert(levelDecalRoads, obj:getName())
        end
        -- If this is a group, search inside it
        if obj:getClassName() == "SimGroup" then
          searchObjects(obj)
        end
      end
    end
  end
  
  searchObjects(missionGroup)
end

local function findDecalRoads()
  levelDecalRoads = {}
  local missionGroup = scenetree.findObject("MissionGroup")
  if not missionGroup then return end

  local function searchObjects(group)
    for i, objName in ipairs(group:getObjects()) do
      local obj = scenetree.findObject(objName)
      if obj then
        if obj:getClassName() == "DecalRoad" then
          table.insert(levelDecalRoads, obj:getName())
        end
        -- If this is a group, search inside it
        if obj:getClassName() == "SimGroup" then
          searchObjects(obj)
        end
      end
    end
  end
  
  searchObjects(missionGroup)
end

-- Function to create a trigger with a specific name (used as callback)
local function createTriggerWithName(instance)
  if instance and pendingTriggerName then
    instance:setName(pendingTriggerName)
    log('I', logTag, "Created trigger with name: " .. pendingTriggerName)
    
    -- Add to levelTriggers list if it exists
    if levelTriggers then
      table.insert(levelTriggers, pendingTriggerName)
    end
    
    -- Clear pending name
    pendingTriggerName = nil
  end
end

-- Our custom object placement system
local function triggerPlacementUpdate()
  if not pendingTriggerType or not pendingTriggerRace then return end
  
  -- Get ray from camera to mouse position
  local res = getCameraMouseRay()
  
  -- Cast ray against scene
  local hit = cameraMouseRayCast(true)

  local pos = vec3(worldEditorCppApi.snapPositionToGrid(hit.pos))
  local lineWidth = editor.getPreference("gizmos.general.lineThicknessScale") * 4
  debugDrawer:drawLineInstance((pos - vec3(2, 0, 0)), (pos + vec3(2, 0, 0)), lineWidth, ColorF(1, 0, 0, 1))
  debugDrawer:drawLineInstance((pos - vec3(0, 2, 0)), (pos + vec3(0, 2, 0)), lineWidth, ColorF(0, 1, 0, 1))
  debugDrawer:drawLineInstance((pos - vec3(0, 0, 2)), (pos + vec3(0, 0, 2)), lineWidth, ColorF(0, 0, 1, 1))
  
  -- Create object on mouse click
  if im.IsMouseClicked(0) and editor.isViewportHovered() then
    -- Create the trigger name based on type and race
    local prefix
    if pendingTriggerType == "start" then
      prefix = "fre_start_"
    elseif pendingTriggerType == "staging" then
      prefix = "fre_staging_"
    elseif pendingTriggerType == "finish" then
      prefix = "fre_finish_"
    elseif pendingTriggerType == "pit" then
      prefix = "fre_pits_"
    end
    
    local triggerName = prefix .. pendingTriggerRace
    
    -- Create the trigger object
    local obj = worldEditorCppApi.createObject("BeamNGTrigger")
    if obj then
      -- Set name and register
      obj:setName(triggerName)
      obj:registerObject("")
      
      -- Position at hit location
      obj:setPosition(pos)
      
      -- Get appropriate parent
      local parent = scenetree.MissionGroup
      local selection = editor.selection
      if selection and selection.object and #selection.object > 0 then
        local sel = scenetree.findObjectById(selection.object[1])
        if sel and sel:isSubClassOf("SimGroup") then
          parent = sel
        elseif sel then
          local group = sel:getGroup()
          if group and group:getName() ~= "MissionCleanup" then
            parent = group
          end
        end
      end
      
      -- Add to parent
      if parent then
        parent:addObject(obj)
      end
      
      -- Select the new trigger
      editor.selectObjectById(obj:getID())
      
      -- Add to level triggers list
      if levelTriggers then
        table.insert(levelTriggers, triggerName)
      end
      
      -- Log creation
      log('I', logTag, "Created new trigger: " .. triggerName)
      
      -- Clear pending state
      pendingTriggerType = nil
      pendingTriggerRace = nil
      showTriggerPlacementHelp = false
    end
  end
end

-- Function to initiate trigger creation
local function createOrSelectTrigger(triggerType, raceName)
  if not raceName then return end
  
  -- Trigger prefix based on type
  local prefix
  if triggerType == "start" then
    prefix = "fre_start_"
  elseif triggerType == "staging" then
    prefix = "fre_staging_"
  elseif triggerType == "finish" then
    prefix = "fre_finish_"
  elseif triggerType == "pit" then
    prefix = "fre_pits_"
  end
  
  local triggerName = prefix .. raceName
  
  -- Check if the trigger already exists
  local existingTrigger = scenetree.findObject(triggerName)
  
  if existingTrigger then
    -- Select the existing trigger
    editor.selectObjectById(existingTrigger:getID())
    log('I', logTag, "Selected trigger: " .. triggerName)
  else
    -- Set pending state for custom placement
    pendingTriggerType = triggerType
    pendingTriggerRace = raceName
    showTriggerPlacementHelp = true
    log('I', logTag, "Ready to place " .. triggerType .. " trigger for race: " .. raceName)
    editor.showNotification("Click on the map to place " .. triggerType .. " trigger")
  end
end

-- Helper function to get the currently selected parent object
local function getCurrentSelectedParent()
  if editor.selection and editor.selection.object and #editor.selection.object > 0 then
    local obj = scenetree.findObjectById(editor.selection.object[1])
    if obj and (obj:getClassName() == "SimGroup" or obj:isSubClassOf("SimGroup")) then
      return obj
    end
    if obj then
      local group = obj:getGroup()
      if group and group:getName() ~= "MissionCleanup" then
        return group
      end
    end
  end
  -- Default to MissionGroup
  return scenetree.MissionGroup
end

local function tableIndexOf(table, value)
  for i, v in ipairs(table) do
    if v == value then
      return i
    end
  end
end

-- Function to check if a race is complete
local function isRaceComplete(raceName, race)
  -- Check for required components
  local hasCheckpointRoad = race.checkpointRoad ~= nil and race.checkpointRoad ~= ""
  
  -- Check for triggers
  local hasStartTrigger = scenetree.findObject("fre_start_" .. raceName) ~= nil
  local hasStagingTrigger = scenetree.findObject("fre_staging_" .. raceName) ~= nil
  
  -- Pit trigger is only required if pits are enabled
  local hasPitTrigger = true
  if race.hasPits then
    hasPitTrigger = scenetree.findObject("fre_pits_" .. raceName) ~= nil
  end
  
  -- Point-to-point specific requirements
  if not race.hotlap then
    local hasFinishTrigger = scenetree.findObject("fre_finish_" .. raceName) ~= nil
    return hasCheckpointRoad and hasStartTrigger and hasStagingTrigger and hasFinishTrigger and hasPitTrigger
  else
    return hasCheckpointRoad and hasStartTrigger and hasStagingTrigger and hasPitTrigger
  end
end

-- Helper function to get missing components list
local function getMissingComponents(raceName, race)
  local missing = {}
  
  if not race.checkpointRoad or race.checkpointRoad == "" then
    table.insert(missing, "Checkpoint road")
  end
  
  if not scenetree.findObject("fre_start_" .. raceName) then
    table.insert(missing, "Start trigger")
  end
  
  if not scenetree.findObject("fre_staging_" .. raceName) then
    table.insert(missing, "Staging trigger")
  end
  
  if not race.hotlap then
    if not scenetree.findObject("fre_finish_" .. raceName) then
      table.insert(missing, "Finish trigger")
    end
  end
  
  if race.hasPits and not scenetree.findObject("fre_pits_" .. raceName) then
    table.insert(missing, "Pit trigger")
  end
  
  return missing
end

local function showCheckpointsEditor(race)
  if not showingCheckpointsEditor then return end
  if not race.checkpointIndexs then 
    race.checkpointIndexs = {}
    for i, checkpoint in ipairs(checkpoints) do
      race.checkpointIndexs[i] = checkpoint.index
    end
  end

  im.Text("Editing Checkpoints")
  if im.CollapsingHeader1("Checkpoints") then
    for i, checkpoint in ipairs(checkpoints) do
      -- Use a unique ID for each checkpoint row
      im.PushID1("checkpoint_" .. tostring(i))
      
      im.Text("Checkpoint " .. tostring(i))
      im.SameLine()

      if im.Button("X##remove"..i, im.ImVec2(24, 0)) then
        table.remove(race.checkpointIndexs, i)
        removeRaceCheckpoints()
        showRaceCheckpoints()
        break
      end
      im.SameLine()
      
      -- Set the width of the input field to half the available width
      im.SetNextItemWidth(im.GetContentRegionAvailWidth() / 2)
      local index = im.IntPtr(race.checkpointIndexs[i])
      if im.InputInt("##Index", index, 1, 10) then
        race.checkpointIndexs[i] = index[0]
        removeRaceCheckpoints()
        showRaceCheckpoints()
      end
      im.SameLine()

      if im.Button("Add##add"..i, im.ImVec2(60, 0)) then
        table.insert(race.checkpointIndexs, i + 1, race.checkpointIndexs[i] + 1)
        removeRaceCheckpoints()
        showRaceCheckpoints()
        break
      end
      
      im.PopID()
    end
  end
end

-- Main editor GUI function
local function onEditorGui()
  if not editor.isWindowVisible(toolWindowName) then return end
  M.onEditorUpdate()
  
  if editor.beginWindow(toolWindowName, "Freeroam Event Editor", im.WindowFlags_MenuBar) then
    local level = getCurrentLevelIdentifier()
    if not level then
      im.Text("No level loaded!")
      editor.endWindow()
      return
    end
    
    -- Menu Bar
    if im.BeginMenuBar() then
      if im.BeginMenu("File") then
        if im.MenuItem1("New") then
          createNewRaceData()
        end
        if im.MenuItem1("Load...") then
          loadRaceData()
        end
        if im.MenuItem1("Save") then
          saveRaceData()
        end
        im.EndMenu()
      end
      im.EndMenuBar()
    end

    if modified then
        im.TextColored(im.ImVec4(1, 1, 0, 1), "Modified (unsaved)")
    end
    
    im.Text("Current Level: " .. level)
    
    -- Split the window into two columns
    local windowWidth = im.GetContentRegionAvailWidth()
    local leftPanelWidth = windowWidth * 0.3
    
    -- Left panel - Event List
    im.BeginChild1("EventsList", im.ImVec2(leftPanelWidth, im.GetContentRegionAvail().y), true)
    
    -- Create new race button
    if im.Button("Create New Event", im.ImVec2(im.GetContentRegionAvailWidth(), 0)) then
      createNewRace()
    end
    
    im.Separator()
    
    -- Display races count
    local raceCount = countTableEntries(races)
    im.Text("Events (" .. raceCount .. "):")
    
    -- Display each race with a simpler UI
    for raceName, race in pairs(races) do
      local complete = isRaceComplete(raceName, race)    
      
      if not complete then
        im.PushStyleColor2(im.Col_Button, im.ImVec4(0.8, 0.2, 0.2, 1.0))
        im.PushStyleColor2(im.Col_ButtonHovered, im.ImVec4(0.9, 0.3, 0.3, 1.0))
        im.PushStyleColor2(im.Col_ButtonActive, im.ImVec4(1.0, 0.4, 0.4, 1.0))
      end

      if im.Button(race.label or "Unnamed" .. "##" .. raceName, im.ImVec2(im.GetContentRegionAvailWidth(), 0)) then
        currentRaceName = raceName
        if showingRaceCheckpoints then
            removeRaceCheckpoints()
        end
      end
      
      if not complete then
        im.PopStyleColor(3)
      end
      
      -- Show tooltip with missing components
      if im.IsItemHovered() then
        im.BeginTooltip()
        im.Text("Event ID: " .. raceName)
        
        if not complete then
          im.TextColored(im.ImVec4(1, 0.4, 0.4, 1), "Incomplete race! Missing:")
          local missing = getMissingComponents(raceName, race)
          for _, component in ipairs(missing) do
            im.BulletText(component)
          end
        else
          im.TextColored(im.ImVec4(0.4, 1, 0.4, 1), "Complete race")
        end
        im.EndTooltip()
      end
    end
    
    im.EndChild()
    
    im.SameLine()
    
    im.BeginChild1("RaceDetails", im.ImVec2(0, im.GetContentRegionAvail().y), true)
    
    -- Edit the currently selected race
    if currentRaceName and races[currentRaceName] then
      local race = races[currentRaceName]
      im.Text("Editing Event: " .. currentRaceName)

      im.Separator()
      local changed = false
      
      -- SECTION: Basic Event Information
      if im.CollapsingHeader1("Basic Event Information") then
        -- Edit Event ID directly
        im.PushID1(currentRaceName .. "_id")
        local raceNameBuf = im.ArrayChar(128, currentRaceName)
        if im.InputText("Event ID", raceNameBuf, 128, im.InputTextFlags_EnterReturnsTrue) then
          local newRaceName = ffi.string(raceNameBuf)
          if newRaceName ~= currentRaceName and newRaceName ~= "" and not races[newRaceName] then
            -- First, check for and rename any associated triggers
            local prefixes = {"fre_start_", "fre_staging_", "fre_finish_"}
            
            for _, prefix in ipairs(prefixes) do
              local oldTriggerName = prefix .. currentRaceName
              local newTriggerName = prefix .. newRaceName
              
              -- Find the trigger with old name
              local trigger = scenetree.findObject(oldTriggerName)
              if trigger then
                -- Rename the trigger
                trigger:setName(newTriggerName)
                
                -- Update levelTriggers list if we have it
                if levelTriggers then
                  for i, name in ipairs(levelTriggers) do
                    if name == oldTriggerName then
                      levelTriggers[i] = newTriggerName
                      break
                    end
                  end
                end
                
                log('I', logTag, "Renamed trigger from " .. oldTriggerName .. " to " .. newTriggerName)
              end
            end
            
            -- Now proceed with race renaming
            -- Create copy of race data with new name
            races[newRaceName] = deepcopy(race)
            -- Remove old race data
            races[currentRaceName] = nil
            -- Update current race name
            currentRaceName = newRaceName
            changed = true
            
            -- Log the changes
            log('I', logTag, "Renamed race from " .. currentRaceName .. " to " .. newRaceName)
          end
        end
        im.PopID()
        
        -- Edit Event Label
        local eventLabel = im.ArrayChar(128, race.label or "")
        if im.InputText("Event Label", eventLabel) then
          race.label = ffi.string(eventLabel)
          changed = true
        end
        
        -- Best Time
        local bestTime = im.FloatPtr(race.bestTime or 60)
        if im.InputFloat("Best Time (seconds)", bestTime, 1, 5, "%.1f") then
          race.bestTime = bestTime[0]
          changed = true
        end

        local isDriftGoal = im.BoolPtr(race.driftGoal ~= nil)
        if im.Checkbox("Drift Event", isDriftGoal) then
          if isDriftGoal[0] then
            race.driftGoal = 1.0
          else
            race.driftGoal = nil
          end
          changed = true
        end
        
        if isDriftGoal[0] then
          local driftGoal = im.IntPtr(race.driftGoal or 1000)
          if im.InputInt("Drift Goal", driftGoal, 100, 10000) then
            race.driftGoal = driftGoal[0]
            changed = true
          end
        end
        
        -- Damage Factor
        local hasDamageFactor = im.BoolPtr(race.damageFactor ~= nil)
        if im.Checkbox("Enable Damage Factor", hasDamageFactor) then
          if hasDamageFactor[0] then
            race.damageFactor = 0.5
          else
            race.damageFactor = nil
          end
          changed = true
        end
        
        if hasDamageFactor[0] then
          local damageFactor = im.FloatPtr(race.damageFactor or 0.5)
          if im.SliderFloat("Damage Factor", damageFactor, 0.0, 1.0, "%.2f") then
            race.damageFactor = damageFactor[0]
            changed = true
          end
          im.SameLine()
          if im.Button("?##damageFactor") then
            im.OpenPopup("Damage Factor Help")
          end
          if im.BeginPopupModal("Damage Factor Help", nil, im.WindowFlags_AlwaysAutoResize) then
            im.Text("Damage Factor determines how damage affects scoring:")
            im.Separator()
            im.BulletText("0.0 = Time only (traditional time trial)")
            im.BulletText("0.5 = 50% time, 50% damage (balanced)")
            im.BulletText("1.0 = Damage only (no damage = full reward)")
            im.Separator()
            im.Text("Higher values prioritize avoiding damage over speed.")
            if im.Button("Close") then
              im.CloseCurrentPopup()
            end
            im.EndPopup()
          end
        end
      end

      if im.CollapsingHeader1("Reward") then
        -- Reward
        local reward = im.IntPtr(race.reward or 1000)
        if im.InputInt("Reward ($)", reward, 100, 1000) then
          race.reward = reward[0]
          changed = true
        end

        im.Text("Reward Calculation:")

        im.InputFloat("Time (seconds)", realTime, 1, 5, "%.1f")

        local reward
        if race.driftGoal then
          im.InputInt("Drift Score", driftScore, 100, 10000)
          reward = utils.driftReward(race, realTime[0], driftScore[0])
        elseif race.damageFactor and race.damageFactor > 0 then
          im.SliderFloat("Damage % (Preview)", damagePercentage, 0.0, 1.0, "%.1f")
          im.SameLine()
          im.Text(string.format("(%.1f%%)", damagePercentage[0] * 100))
          reward = utils.hybridRaceReward(race.bestTime, race.reward, realTime[0], race.damageFactor, damagePercentage[0])
          im.Text(string.format("Damage Factor: %.2f | Time Factor: %.2f", 
            race.damageFactor, 1.0 - race.damageFactor))
        else
          reward = utils.raceReward(race.bestTime, race.reward, realTime[0])
        end

        im.InputInt("Lap Count", lapCount, 1, 100)

        reward = reward * utils.hotlapMultiplier(lapCount[0])
        
        im.Checkbox("Best Time Session", bestTimeSession)
        im.Checkbox("In Range", inRange)
        im.Checkbox("Hardcore", hardcore)

        if bestTimeSession[0] then
          reward = reward * 1.2
        end

        if inRange[0] then
          reward = reward * 1.05
        end

        if hardcore[0] then
          reward = reward * 0.5
        end

        im.Text(string.format("Calculated Reward: %.0f", reward))
        
        if race.damageFactor and race.damageFactor > 0 then
          im.Separator()
          im.TextColored(im.ImVec4(0.7, 0.7, 1.0, 1.0), "Damage-Based Scoring Enabled")
          im.Text(string.format("- Time Component: %.0f%%", (1.0 - race.damageFactor) * 100))
          im.Text(string.format("- Damage Component: %.0f%%", race.damageFactor * 100))
        end
      end
      -- SECTION: Event Options
      if im.CollapsingHeader1("Event Options") then
        -- Apex Offset
        local hasApexOffset = im.BoolPtr(race.apexOffset ~= nil)
        if im.Checkbox("Use Apex Offset", hasApexOffset) then
          if hasApexOffset[0] then
            race.apexOffset = 1.0
          else
            race.apexOffset = nil
          end
          changed = true
        end
        
        if hasApexOffset[0] then
          local apexOffset = im.FloatPtr(race.apexOffset or 1.0)
          if im.InputFloat("Apex Offset (Nodes)", apexOffset, 0.1, 1.0, "%.1f") then
            race.apexOffset = apexOffset[0]
            changed = true
          end
        end
        
        -- Running Start
        local runningStart = im.BoolPtr(race.runningStart or false) -- Default to true
        if im.Checkbox("Running Start", runningStart) then
          race.runningStart = runningStart[0]
          changed = true
        end

        -- Reverse
        local reverse = im.BoolPtr(race.reverse or false)
        if im.Checkbox("Reverse", reverse) then
          race.reverse = reverse[0]
          changed = true
        end
        
        -- Stationary Timeout
        local timeout = im.IntPtr(race.timeout or 10)
        if im.InputInt("Stationary Timeout (seconds)", timeout, 1, 5) then
          race.timeout = math.max(1, timeout[0]) -- Ensure minimum value of 1 second
          changed = true
        end
        im.SameLine()
        if im.Button("?##timeout") then
          im.OpenPopup("Timeout Help")
        end
        if im.BeginPopupModal("Timeout Help", nil, im.WindowFlags_AlwaysAutoResize) then
          im.Text("Stationary Timeout determines how long a player can remain")
          im.Text("stationary before the race is automatically cancelled.")
          im.Separator()
          im.BulletText("Lower values (5-10s): Fast-paced events")
          im.BulletText("Higher values (15-30s): Methodical/technical events")
          im.BulletText("Default: 10 seconds")
          im.Separator()
          im.Text("Players get countdown warnings before timeout.")
          if im.Button("Close") then
            im.CloseCurrentPopup()
          end
          im.EndPopup()
        end
      end
      
      -- SECTION: Event Type
      if im.CollapsingHeader1("Event Type") then
        local customType = im.ArrayChar(128, "")
        if im.InputText("Custom Type", customType, 128, im.InputTextFlags_EnterReturnsTrue) then
          table.insert(raceTypes, ffi.string(customType))
          table.insert(race.type, ffi.string(customType))
          changed = true
        end

        for _, rType in ipairs(race.type) do
          if not tableContains(raceTypes, rType) then
            table.insert(raceTypes, rType)
          end
        end

        -- Multi-row checkboxes layout for race types
        local availableWidth = im.GetContentRegionAvail().x
        local minCheckboxWidth = 150 -- Minimum width in pixels for each checkbox
        local columnsPerRow = math.max(1, math.floor(availableWidth / minCheckboxWidth))
        local columnWidth = availableWidth / columnsPerRow
        local rowCount = 0

        for i, rType in ipairs(raceTypes) do
          -- Initialize type if it doesn't exist
          if not race.type then race.type = {"motorsport"} end
          
          local isSelected = im.BoolPtr(tableContains(race.type, rType))
          local typeChanged = false
          
          -- Start of a new row
          if rowCount % columnsPerRow ~= 0 then
            im.SameLine()
            im.SetCursorPosX((rowCount % columnsPerRow) * columnWidth)
          end
          
          if im.Checkbox(rType, isSelected) then
            if isSelected[0] then
              if not tableContains(race.type, rType) then
                table.insert(race.type, rType)
                typeChanged = true
              end
            else
              if tableContains(race.type, rType) then
                table.remove(race.type, tableIndexOf(race.type, rType))
                typeChanged = true
              end
            end
          end
          
          rowCount = rowCount + 1
          
          if typeChanged then
            changed = true
          end
        end
      end
      
      -- SECTION: Checkpoint Settings
      if im.CollapsingHeader1("Checkpoint Settings") then
        im.Text("Checkpoint Road:")
        local loopSelected = im.IntPtr(race.hotlap and 1 or 2)
        
        if im.RadioButton2("Looped", loopSelected, im.Int(1)) then
          race.hotlap = race.hotlap or (race.bestTime * 0.9)
          changed = true
        end
        
        im.SameLine()
        
        if im.RadioButton2("Point-to-Point", loopSelected, im.Int(2)) then
          race.hotlap = nil
          changed = true
        end

        if race.looped == true then
          local hotlap = im.FloatPtr(race.hotlap or (race.bestTime * 0.9))
          if not race.hotlap then
              race.hotlap = hotlap[0]
          end
          if im.InputFloat("Hotlap Time (seconds)", hotlap, 1, 5, "%.1f") then
            race.hotlap = hotlap[0]
            changed = true
          end
        end
        
        -- Road selection with filter
        local roadFilter = im.ArrayChar(128, roadFilterText)
        if im.InputText("Filter Roads", roadFilter, 128) then
          roadFilterText = ffi.string(roadFilter)
        end
        local filterText = roadFilterText:lower()

        -- Initialize checkpoint roads as a table if needed
        if race.checkpointRoad and type(race.checkpointRoad) ~= "table" then
          race.checkpointRoad = {race.checkpointRoad}
        elseif not race.checkpointRoad then
          race.checkpointRoad = {}
        end
        
        -- Display all road selections
        for i, roadName in ipairs(race.checkpointRoad) do
          local comboLabel = "Select Road #" .. i
          local currentRoad = roadName or "Choose a road"
          
          -- Display a remove button for roads after the first one
          if i > 1 then
            if im.Button("X##remove"..i, im.ImVec2(24, 0)) then
              table.remove(race.checkpointRoad, i)
              changed = true
              break -- Break to avoid iterating over modified table
            end
            im.SameLine()
          end
          
          if im.BeginCombo(comboLabel, currentRoad) then
            -- Don't check and invalidate the road here - we do that in onEditorUpdate
            -- if roadName and not tableContains(levelDecalRoads, roadName) then
            --   -- Road doesn't exist anymore, mark for update
            --   changed = true
            -- end
            
            lookingForRoad = true
            local foundAny = false
            
            -- First show the current selection if it exists
            if roadName and roadName ~= "" then
              if filterText == "" or string.find(roadName:lower(), filterText) then
                if im.Selectable1(roadName .. " (current)", true) then
                  -- Keep the current selection
                end
                im.Separator()
                foundAny = true
              end
            end
            
            -- Then show filtered options
            for _, availableRoad in ipairs(levelDecalRoads) do
              if availableRoad == "" then goto continue end
              
              -- Apply filter
              if filterText ~= "" and not string.find(availableRoad:lower(), filterText) then
                goto continue
              end
              
              foundAny = true
              if im.Selectable1(availableRoad, availableRoad == roadName) then
                race.checkpointRoad[i] = availableRoad
                changed = true
              end
              ::continue::
            end
            
            if not foundAny then
              im.Text("No roads match your filter")
            end
            
            im.EndCombo()
          else
            lookingForRoad = false
          end
        end
        
        -- Add the plus button to add more roads
        if im.Button("+ Add Road", im.ImVec2(im.GetContentRegionAvailWidth(), 0)) then
          table.insert(race.checkpointRoad, "")
          changed = true
        end

        im.Spacing()
        if im.Button("Show Checkpoints", im.ImVec2(im.GetContentRegionAvailWidth()/2, 0)) then
          showingRaceCheckpoints = true
          showRaceCheckpoints()
        end
        im.SameLine()
        if im.Button("Hide Checkpoints", im.ImVec2(im.GetContentRegionAvailWidth(), 0)) then
          showingRaceCheckpoints = false
          removeRaceCheckpoints()
          roadNodes = nil
          altRoadNodes = nil
        end

        if showingRaceCheckpoints then
          local buttonText = not showingCheckpointsEditor and "Manual Edit Checkpoints" or "Use Auto Checkpoints"
          if im.Button(buttonText, im.ImVec2(im.GetContentRegionAvailWidth(), 0)) then
            if not showingCheckpointsEditor then
              showingCheckpointsEditor = true
            else
              race.checkpointIndexs = nil
              showingCheckpointsEditor = false
            end
          end
          showCheckpointsEditor(race)
        end

      end

      local function triggerExists(prefix, raceName)
        return scenetree.findObject(prefix .. raceName) ~= nil
      end
      
      -- SECTION: Trigger Management
      if im.CollapsingHeader1("Trigger Management") then
        -- Start trigger
        local startExists = triggerExists("fre_start_", currentRaceName)
        local buttonText = startExists and "Select Start Trigger" or "Create Start Trigger"
        if pendingTriggerType == "start" and pendingTriggerRace == currentRaceName then
          buttonText = "Cancel Start Trigger Placement"
        end
        
        im.PushStyleColor2(im.Col_Text, startExists and im.ImVec4(0.2, 0.8, 0.2, 1.0) or im.ImVec4(0.8, 0.2, 0.2, 1.0))
        if im.Button(buttonText, im.ImVec2(im.GetContentRegionAvailWidth(), 0)) then
          if pendingTriggerType == "start" and pendingTriggerRace == currentRaceName then
            -- Cancel placement
            pendingTriggerType = nil
            pendingTriggerRace = nil
            showTriggerPlacementHelp = false
          else
            createOrSelectTrigger("start", currentRaceName)
          end
        end
        im.PopStyleColor()

        -- Staging trigger
        local stagingExists = triggerExists("fre_staging_", currentRaceName)
        buttonText = stagingExists and "Select Staging Trigger" or "Create Staging Trigger"
        if pendingTriggerType == "staging" and pendingTriggerRace == currentRaceName then
          buttonText = "Cancel Staging Trigger Placement"
        end
        
        im.PushStyleColor2(im.Col_Text, stagingExists and im.ImVec4(0.2, 0.8, 0.2, 1.0) or im.ImVec4(0.8, 0.2, 0.2, 1.0))
        if im.Button(buttonText, im.ImVec2(im.GetContentRegionAvailWidth(), 0)) then
          if pendingTriggerType == "staging" and pendingTriggerRace == currentRaceName then
            -- Cancel placement
            pendingTriggerType = nil
            pendingTriggerRace = nil
            showTriggerPlacementHelp = false
          else
            createOrSelectTrigger("staging", currentRaceName)
          end
        end
        im.PopStyleColor()

        -- Finish trigger (only for point-to-point races)
        if not race.hotlap then
          local finishExists = triggerExists("fre_finish_", currentRaceName)
          buttonText = finishExists and "Select Finish Trigger" or "Create Finish Trigger"
          if pendingTriggerType == "finish" and pendingTriggerRace == currentRaceName then
            buttonText = "Cancel Finish Trigger Placement"
          end
          
          im.PushStyleColor2(im.Col_Text, finishExists and im.ImVec4(0.2, 0.8, 0.2, 1.0) or im.ImVec4(0.8, 0.2, 0.2, 1.0))
          if im.Button(buttonText, im.ImVec2(im.GetContentRegionAvailWidth(), 0)) then
            if pendingTriggerType == "finish" and pendingTriggerRace == currentRaceName then
              -- Cancel placement
              pendingTriggerType = nil
              pendingTriggerRace = nil
              showTriggerPlacementHelp = false
            else
              createOrSelectTrigger("finish", currentRaceName)
            end
          end
          im.PopStyleColor()
        end
        
        -- Show help text if placing trigger
        if showTriggerPlacementHelp then
          im.TextColored(im.ImVec4(1, 1, 0, 1), "Click on the map to place the trigger")
        end
      end
      
      -- SECTION: Pits Management
      if im.CollapsingHeader1("Pits Management") then
        -- Enable/disable pits toggle
        local hasPits = im.BoolPtr(race.hasPits or false)
        if im.Checkbox("Enable Pit Lane Speed Limit", hasPits) then
          race.hasPits = hasPits[0]
          changed = true
        end
        
        -- Only show pit settings if enabled
        if race.hasPits then
          -- Speed limit value
          local pitSpeedLimit = im.IntPtr(race.pitSpeedLimit or 60)
          if im.InputInt("Pit Speed Limit", pitSpeedLimit, 5, 10) then
            race.pitSpeedLimit = math.max(5, pitSpeedLimit[0]) -- Ensure minimum value
            changed = true
          end
          
          -- Speed limit unit selection using BeginCombo
          local unitOptions = {"KPH", "MPH"}
          local currentUnit = race.pitSpeedUnit or "KPH"
          
          if im.BeginCombo("Speed Unit", currentUnit) then
            for _, unit in ipairs(unitOptions) do
              local isSelected = (unit == currentUnit)
              if im.Selectable1(unit, isSelected) then
                race.pitSpeedUnit = unit
                changed = true
              end
              
              -- Set initial focus when opening the combo
              if isSelected then
                im.SetItemDefaultFocus()
              end
            end
            im.EndCombo()
          end
          
          -- Pit trigger
          local pitExists = triggerExists("fre_pits_", currentRaceName)
          local buttonText = pitExists and "Select Pit Trigger" or "Create Pit Trigger"
          if pendingTriggerType == "pit" and pendingTriggerRace == currentRaceName then
            buttonText = "Cancel Pit Trigger Placement"
          end
          
          im.PushStyleColor2(im.Col_Text, pitExists and im.ImVec4(0.2, 0.8, 0.2, 1.0) or im.ImVec4(0.8, 0.2, 0.2, 1.0))
          if im.Button(buttonText, im.ImVec2(im.GetContentRegionAvailWidth(), 0)) then
            if pendingTriggerType == "pit" and pendingTriggerRace == currentRaceName then
              -- Cancel placement
              pendingTriggerType = nil
              pendingTriggerRace = nil
              showTriggerPlacementHelp = false
            else
              createOrSelectTrigger("pit", currentRaceName)
            end
          end
          im.PopStyleColor()
        end
      end
      
      -- SECTION: Actions
      if im.Button("Delete Event", im.ImVec2(im.GetContentRegionAvailWidth(), 0)) then
        im.OpenPopup("Delete Event Confirmation")
      end
      
      if im.BeginPopupModal("Delete Event Confirmation", nil, im.WindowFlags_AlwaysAutoResize) then
        im.Text("Are you sure you want to delete this event?")
        im.Text("This action cannot be undone.")
        im.Separator()
        
        if im.Button("Yes, Delete Event", im.ImVec2(im.GetContentRegionAvailWidth()/2, 0)) then
          races[currentRaceName] = nil
          currentRaceName = nil
          changed = true
          im.CloseCurrentPopup()
        end
        
        im.SameLine()
        
        if im.Button("Cancel", im.ImVec2(im.GetContentRegionAvailWidth(), 0)) then
          im.CloseCurrentPopup()
        end
        
        im.EndPopup()
      end
      
      if changed then
        modified = true
      end
    end
    
    editor.endWindow()
  end
end

-- Helper function to check if a value exists in a table
local function tableContains(table, val)
  if not table then return false end
  for _, v in ipairs(table) do
    if v == val then return true end
  end
  return false
end

-- Called when editor activates this tool
local function onActivate()
  log('I', logTag, "Freeroam Event Editor activated")
  findLevelObjects()
end

-- Window menu item callback
local function onWindowMenuItem()
  editor.showWindow(toolWindowName)
end

-- Called when editor initializes
local function onEditorInitialized()
  editor.registerWindow(toolWindowName, im.ImVec2(600, 600))
  editor.addWindowMenuItem("Freeroam Event Editor", onWindowMenuItem)
  log('I', logTag, "Freeroam Event Editor initialized")
  loadRaceData()
  findLevelObjects()
end

local internal_onEditorUpdate = 5
local lastOsTime = os.time()

-- Add onEditorUpdate function for our trigger placement
function M.onEditorUpdate()
  if pendingTriggerType and pendingTriggerRace then
    triggerPlacementUpdate()
  end
  if os.time() - lastOsTime > internal_onEditorUpdate then
    lastOsTime = os.time()
    findDecalRoads()

    for raceName, race in pairs(races) do
      if race.checkpointRoad then
        -- Handle both string and table cases
        if type(race.checkpointRoad) == "string" then
          -- Legacy format (single road as string)
          if race.checkpointRoad ~= "" and not tableContains(levelDecalRoads, race.checkpointRoad) then
            race.checkpointRoad = nil
          end
        elseif type(race.checkpointRoad) == "table" then
          -- New format (multiple roads as table)
          local validRoads = {}
          for _, roadName in ipairs(race.checkpointRoad) do
            if roadName ~= "" and tableContains(levelDecalRoads, roadName) then
              table.insert(validRoads, roadName)
            end
          end
          
          -- Only update if we need to remove some roads
          if #validRoads ~= #race.checkpointRoad then
            race.checkpointRoad = validRoads  -- Always keep as table, even if empty
          end
        end
      end
    end
  end
end

local function onExtensionLoaded()
  loadRaceData()
end

local function onWorldReadyState(state)
  if state == 2 then
    loadRaceData()
    utils.onExtensionLoaded()
  end
end

M.onEditorGui = onEditorGui
M.onEditorInitialized = onEditorInitialized
M.onWindowMenuItem = onWindowMenuItem
M.onActivate = onActivate
M.onExtensionLoaded = onExtensionLoaded

return M 