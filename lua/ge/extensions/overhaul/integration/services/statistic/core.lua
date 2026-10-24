-- Statistics core: metrics, timers, callbacks, the mode/map/activity timers, the hooks and
-- the debug window of BeamNG's gameplay/statistic.lua (bCDDL), kept stock-derived and tracked as such
-- (registered fork: stock has no seam to run its private metric/timer state against a second,
-- per-career data set). Differences from stock are the ctx seams below; the career save and
-- activation, and the Overhaul gating, live in the owner (integration/services/statistic.lua).
--
-- statisticCore.create(owner, ctx) builds one instance for the extension table `owner`; every piece of state is
-- local to that call, so a reloaded or replaced owner starts from fresh state. This library is never
-- an extension: it returns the instance's functions (`api`, stock's export names, hooks included)
-- and the owner exports them; calls between them go through the owner's table, as stock's go
-- through its M. ctx:
--   im                     ui_imgui (debug window)
--   loadData()             the general data table to count into (stock: the cloud file)
--   saveData(fileData)     persist the general data (stock: the cloud file)
--   loadSubmodules()       start the statistic workload modules (stock: gameplay/statisticModules)
--   foregroundMissionId()  the foreground mission, if any
--   careerIsActive()       whether a career runs
-- Returns api, career: the career seam {getCareerData, setCareerData, save, endCareer}.
--
-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local statisticCore = {}

function statisticCore.create(owner, ctx)
local imgui = ctx.im

local realTimeSeconds = 0
local simulationTimeSeconds = 0

local fileData = {version = 1, entries = {}}
local sortedEntries = {}

local fileDataCareer = nil
local currentActivity = nil
local currentLevel = nil
local currentMod = nil
local timers = {}
local windowOpen = imgui.BoolPtr(false)
local initialWindowSize = imgui.ImVec2(300, 100)
local max = math.max
local min = math.min
local callbacks = {}
local callbacksCareer = {}
local callbackWildcard = {}
local currentPlayerVehicleId = nil
local currentPlayerVehicleObj = nil
local scheduledTasks = {}
local scheduledTaskCount=0
local currentScheduleIndex=1
local SAVE_DECAY_INTERVAL_SECONDS = 60*1
local lastSaveTime = 0
local dirtyMetrics = {}
local dirtyMetricCount = 0

local function _loadData()
  fileData = ctx.loadData()
  lastSaveTime = os.clock()
end

local function _saveData() ctx.saveData(fileData) end

local function onFirstUpdate()
  log("I", "onFirstUpdate", "loading data")
  _loadData()
end

local function _save()
  lastSaveTime = os.clock()
  owner.forceTimerUpdate()
  _saveData()
  dirtyMetrics={}
  dirtyMetricCount = 0
end

local function onExit()
  if currentActivity then
    owner.onClientEndMission()
  end
  _save()
end

local function onExtensionUnloaded()
  _save()
end

local function onSerialize()
  _save()
  local data = {}
  data.currentActivity = currentActivity
  data.currentLevel = currentLevel
  data.currentMod = currentMod
  data.windowOpen = windowOpen[0]
  data.realtimer = realTimeSeconds
  data.simtimer = simulationTimeSeconds
  return data
end

local function onDeserialized(data)
  _loadData()
  if data.currentActivity then currentActivity = data.currentActivity end
  if data.currentLevel then currentLevel = data.currentLevel end
  if data.currentMod then currentMod = data.currentMod end
  if data.realtimer then realTimeSeconds = data.realtimer end
  if data.simtimer then simulationTimeSeconds = data.simtimer end
  if data.windowOpen ~= nil then windowOpen[0] = data.windowOpen end
  if data.currentLevel then owner.onClientStartMission() end
  if fileDataCareer then
    owner.onGameStateUpdate()
  end
end

local function markDirty(name)
  if dirtyMetrics[name] then return end
  dirtyMetrics[name] = true
  dirtyMetricCount = dirtyMetricCount + 1
end

local function addSchedule(fn)
  scheduledTasks[#scheduledTasks +1] = fn
  scheduledTaskCount = #scheduledTasks
end

local function removeSchedule(fn)
  for i in ipairs(scheduledTasks) do
    if scheduledTasks[i] == fn then
      table.remove(scheduledTasks, i)
      scheduledTaskCount = #scheduledTasks
      return true
    end
  end
  return false
end

local function loadSubmodules() ctx.loadSubmodules() end

local function _runCallback(name, oldEntry, newEntry, career)
  local metricCallbacks = nil

  if career then
    metricCallbacks = callbacksCareer[name]
  else
    metricCallbacks = callbacks[name]
  end

  for  cb in pairs(callbackWildcard) do
    if string.match(name, callbackWildcard[cb].name) then
      if not callbackWildcard[cb].trigger or (callbackWildcard[cb].trigger and newEntry.value >= callbackWildcard[cb].trigger) then
        callbackWildcard[cb].func(name, oldEntry, newEntry)
        if callbackWildcard[cb] and callbackWildcard[cb].trigger then
          callbackWildcard[cb] = nil
        end
      end
    end
  end
  if not metricCallbacks then return end
  local callbackEntry = deepcopy(newEntry)
  callbackEntry.career = career

  for callbackIndex in pairs(metricCallbacks) do
    if not metricCallbacks[callbackIndex].trigger or newEntry.value >= metricCallbacks[callbackIndex].trigger then
      metricCallbacks[callbackIndex].func(name, oldEntry, callbackEntry)
      if metricCallbacks[callbackIndex] and metricCallbacks[callbackIndex].trigger then -- The callback may remove its own registration.
        metricCallbacks[callbackIndex] = nil
      end
    end
  end
end

local function _metricAdd(entry,name,value,aggregate)
  if not entry then
    entry = {value=value}
    if aggregate then
      entry.last=value
      entry.count=1
      entry.min=value
      entry.max=value
    end
    return entry
  else
    -- Older odometer entries may have no value; accumulate from zero.
    entry.value = (value or 0) + (entry.value or 0)
  end
  if aggregate then
    entry.last = value
    entry.count = (entry.count or 0) + 1
    entry.min= min(entry.min or math.huge, value)
    entry.max= max(entry.max or -math.huge, value)
  end
  return entry
end

local function metricAdd(name,value,aggregate)
  if name==nil then log("E", "metricAdd", "invalid metric name") return end
  if value==nil then log("E", "metricAdd", "invalid value metric="..dumps(name)) return end
  local oldEntry = deepcopy(fileData.entries[name])
  local updatedEntry = _metricAdd(fileData.entries[name],name,value,aggregate)
  if not oldEntry then
    fileData.entries[name] = updatedEntry
  end

  markDirty(name)
  _runCallback(name,oldEntry,updatedEntry,false)

  if fileDataCareer then
    oldEntry = deepcopy(fileDataCareer.entries[name])
    updatedEntry = _metricAdd(fileDataCareer.entries[name],name,value,aggregate)
    if not oldEntry then
      fileDataCareer.entries[name] = updatedEntry
    end
    _runCallback(name,oldEntry,updatedEntry,true)
  end
end

local function _metricSet(entry,name,value,aggregate)
  if not entry then
    entry = {value=value}
    if aggregate then
      entry.count=1
      entry.min=value
      entry.max=value
    end
    return entry
  else
    entry.value = value
  end
  if aggregate then
    entry.count = (entry.count or 0) + 1
    entry.min= min(entry.min or math.huge, value)
    entry.max= max(entry.max or -math.huge, value)
  end
  return entry
end

local function metricSet(name,value,aggregate)
  if name==nil then log("E", "metricSet", "invalid metric name") return end
  if value==nil then log("E", "metricSet", "invalid value") return end
  local oldEntry = deepcopy(fileData.entries[name])
  fileData.entries[name] = _metricSet(fileData.entries[name],name,value,aggregate)
  markDirty(name)

  _runCallback(name,oldEntry,fileData.entries[name],false)

  if fileDataCareer then
    oldEntry = deepcopy(fileDataCareer.entries[name])
    local updatedEntry = _metricSet(fileDataCareer.entries[name],name,value,aggregate)
    if not oldEntry then
      fileDataCareer.entries[name] = updatedEntry
    end
    _runCallback(name,oldEntry,updatedEntry,true)
  end
end

local function metricGet(name, career)
  local entry = nil
  if fileDataCareer and career then
    entry = fileDataCareer.entries[name]
  else
    entry = fileData.entries[name]
  end
  if not entry then
    return nil
  else
    return deepcopy(entry)
  end
end

local function metricGetMatchPattern(namePattern, career)
  local entries = {}
  local matchingEntries = {}
  if fileDataCareer and career then
    entries = fileDataCareer.entries
  else
    entries = fileData.entries
  end
  for name, entry in pairs(entries) do
    if string.match(name, namePattern) then
      matchingEntries[name] = deepcopy(entry)
    end
  end
  return matchingEntries
end

local function timerStart(name, increment, aggregate, useSimTime)
  if name==nil then log("E", "timerStart", "invalid timer name") return end
  if useSimTime==nil then useSimTime=false end
  if increment==nil then increment=true end
  if aggregate==nil then aggregate=false end
  if timers[name] then
    log("W","timerStart", "Timer "..dumps(name).." already started. will be ignored")
    return
  end
  timers[name] = {sim=useSimTime,increment=increment,start= (useSimTime and simulationTimeSeconds or realTimeSeconds),aggregate=aggregate}
end

local function _timerSave(name)
  local value = (timers[name].sim and simulationTimeSeconds or realTimeSeconds) - timers[name].start
  if timers[name].increment then
    metricAdd(name, value, timers[name].aggregate)
  else
    metricSet(name, value, timers[name].aggregate)
  end
  timers[name].start = (timers[name].sim and simulationTimeSeconds or realTimeSeconds)
  return value
end

local function timerStop(name)
  if not timers[name] then
    log("W","timerStop", "Timer "..dumps(name).." not started. will be ignored")
    return 0
  end
  local value = _timerSave(name)
  timers[name] = nil
  return value
end

local function callbackRegister(name, trigger, callbackFunction, career)
  local entry = {}
  if name:find("*") then
    callbackWildcard[name..tostring(trigger)..tostring(callbackFunction)] = {name=name, trigger=trigger, func=callbackFunction}
    return
  end
  if career then
    if not callbacksCareer[name]then
      callbacksCareer[name]= {}
    end
  else
    if not callbacks[name] then
      callbacks[name]= {}
    end
  end

  entry.trigger = trigger
  entry.func = callbackFunction
  if career then
    callbacksCareer[name][tostring(trigger)..tostring(callbackFunction)] = entry
  else
    callbacks[name][tostring(trigger)..tostring(callbackFunction)] = entry
  end
end

local function callbackRemove(name, trigger, callbackFunction, career)
  local target
  if name:find("*") then
    for cb in pairs(callbackWildcard) do
      if name == callbackWildcard[cb].name and callbackFunction == callbackWildcard[cb].func then
        callbackWildcard[cb] = nil
        return true
      end
    end
    return false
  end
  if career then
    target = callbacksCareer[name]
  else
    target = callbacks[name]
  end
  if not target then
    log("E", "callbackRemove", "no callback registered for `"..dumps(name).."`")
    return false
  end

  for e in pairs( target ) do
    if target[e].trigger == trigger and target[e].func == callbackFunction then
      target[e] = nil
      return true
    end
  end
  log("E", "callbackRemove", "callback not found for `"..dumps(name).."`")
  return false
end

-- ############################

local function endActivity()
  if not currentActivity then return end
  if timers[currentActivity] then
    timerStop(currentActivity)
  end
  currentActivity = nil
end

local function startActivity(levelPath)
  local levelFolder = getCurrentLevelIdentifier()
  if currentMod and timers["general/mode/"..currentMod..".time"] then
    timerStop("general/mode/"..currentMod..".time")
    currentMod = nil
  end
  if currentLevel and timers["general/map/"..currentLevel..".time"] then
    timerStop("general/map/"..currentLevel..".time")
    currentLevel = nil
  end
  if not levelFolder then
    if currentActivity then
      endActivity()
    end

    return
  end
  local missionId = ctx.foregroundMissionId()
  local activityType
  local activityDetail = ""
  if missionId then
    activityType = "scenario"
    activityDetail = "/fg"..missionId:sub(levelFolder:len()+1):gsub("/","@")
  elseif scenario_scenarios and scenario_scenarios.getScenario() then
    local scenario = scenario_scenarios.getScenario()
    if scenario.scenarioName then
      activityType = "scenario"
      activityDetail = "/"..scenario.scenarioName
    elseif scenario.isQuickRace then
      activityType = "timetrial"
    else
      activityType = "scenario"
      activityDetail = "/unknown"
    end
  elseif ctx.careerIsActive() then
    activityType = "career"
  else
    activityType = extensions.core_gamestate.state.state
  end

  if currentActivity then
    endActivity()
  end
  if not activityType then
    if currentMod then
      activityType = currentMod
      log("W","startActivity","Assumed `activityType` didn't change")
    else
      log("E","startActivity","Could not determine activityType")
      return
    end
  end
  currentActivity = activityType .."/".. levelFolder .. activityDetail ..".time"
  timerStart(currentActivity)

  if activityType~= currentMod or not timers["general/mode/"..currentMod..".time"] then
    if currentMod and timers["general/mode/"..currentMod..".time"] then
      timerStop("general/mode/"..currentMod..".time")
    end
    currentMod = activityType
    timerStart("general/mode/"..currentMod..".time")
  end

  if levelFolder~= currentLevel or not timers["general/map/"..currentLevel..".time"]then
    if currentLevel and timers["general/mapmap/"..currentLevel..".time"]then
      timerStop("general/map/"..currentLevel..".time")
    end
    currentLevel = levelFolder
    timerStart("general/map/"..currentLevel..".time")
  end
end

local function onClientStartMission(levelPath)
  startActivity(levelPath)
end

local function onClientEndMission(levelPath)
  endActivity()
  _save()
end

local function onClientPostStartMission(levelPath)
  startActivity(levelPath)

  loadSubmodules()
end

local function onWorldReadyState(worldReadyState)
end

local function onEditorActivated()
  timerStart("general/editor.time")
end

local function onEditorDeactivated()
  timerStop("general/editor.time")
end

local function onUiChangedState(toState, fromState)
  if "scenario.start" == toState then
  end
end

local function onScenarioLoaded(scenario)
  startActivity()
end

local function onScenarioFinished(scenario)
  metricAdd("scenario/finished",1)
  startActivity()
end

local function onScenarioRestarted(scenario)
  startActivity()
  metricAdd("scenario/restarted",1)
end

local function onGameStateUpdate(newState)
  if realTimeSeconds == 0 and fileDataCareer then
    return--fix start before onSerialize only in career
  end
  startActivity()
end

local function onVehicleSelectorSpawnNew()
  metricAdd("vehicle/spawned",1)
end
local function onVehicleSelectorReplaceCurrent()
  metricAdd("vehicle/spawned",1)
end
local function onPlayerVehicleCloned()
  metricAdd("vehicle/spawned",1)
end
local function onSpawnDefaultVehicle()
  metricAdd("vehicle/spawned",1)
end

local sortedEntries = {}
local function onUpdate(dtReal, dtSim, dtRaw)

  realTimeSeconds = realTimeSeconds + dtReal
  simulationTimeSeconds = simulationTimeSeconds + dtSim

  if currentPlayerVehicleId ~= -1 and scheduledTaskCount>0 and currentPlayerVehicleObj and currentPlayerVehicleObj.playerUsable and currentPlayerVehicleObj:isPlayerControlled() and dtSim~=0 then
    scheduledTasks[currentScheduleIndex](currentPlayerVehicleObj, currentPlayerVehicleId, dtSim)
    currentScheduleIndex=currentScheduleIndex +1
    if currentScheduleIndex > scheduledTaskCount then currentScheduleIndex = 1 end
  end


  if windowOpen[0] ~= true then return end
  imgui.SetNextWindowSize(initialWindowSize, imgui.Cond_FirstUseEver)
  imgui.SetNextWindowPos(initialWindowSize, imgui.Cond_FirstUseEver)
  if( imgui.Begin("gameplay_statistic Debugger", windowOpen) ) then
    if imgui.BeginTabBar("shapeeditor##") then
      if imgui.BeginTabItem("module") then
        imgui.TextUnformatted("activity: "..dumps(currentActivity))
        imgui.TextUnformatted("mod: "..dumps(currentMod))
        imgui.TextUnformatted("level: "..dumps(currentLevel))
        imgui.TextUnformatted("save age: "..string.format("%.0f", os.clock() - lastSaveTime))
        imgui.TextUnformatted("dirtEntries: "..dumps(dirtyMetricCount))
        if imgui.TreeNode1("Timers") then
          for k,v in pairs(timers) do
            imgui.TextUnformatted(k..": "..dumps(v))
          end
          imgui.TreePop()
        end
        imgui.EndTabItem()
      end
      if imgui.BeginTabItem("entries") then
        if imgui.Button("Sort/refresh")then
          sortedEntries = {}

          for k,v in pairs(fileData.entries) do
            table.insert(sortedEntries, k)
          end
          table.sort(sortedEntries, function(a,b) return a < b end)
        end
        local v
        for _,k in ipairs(sortedEntries) do
          v = fileData.entries[k]
          if not v then goto continue_dbgentries end
          if v.max then
            imgui.TextUnformatted(k..": "..dumps(v))
          else
            imgui.TextUnformatted(k..": v="..dumps(v.value))
          end
          ::continue_dbgentries::
        end
        imgui.EndTabItem()
      end
      if imgui.BeginTabItem("entries career") then
        if fileDataCareer then
          for k,v in pairs(fileDataCareer.entries) do
            if v.max then
              imgui.TextUnformatted(k..": "..dumps(v))
            else
              imgui.TextUnformatted(k..": v="..dumps(v.value))
            end
          end
        end
        imgui.EndTabItem()
      end
      if imgui.BeginTabItem("callback") then
        if imgui.TreeNode1("callbacks general") then
          for k,v in pairs(callbacks) do
            imgui.TextUnformatted(k..": v="..dumps(v))
          end
          imgui.TreePop()
        end
        if imgui.TreeNode1("callbacks career") then
          for k,v in pairs(callbacksCareer) do
            imgui.TextUnformatted(k..": v="..dumps(v))
          end
          imgui.TreePop()
        end
        if imgui.TreeNode1("callbacks general wildcard") then
          for k,v in pairs(callbackWildcard) do
            imgui.TextUnformatted(k..": v="..dumps(v))
          end
          imgui.TreePop()
        end
        imgui.EndTabItem()
      end
      imgui.EndTabBar()
    end
  end
  imgui.End()
end

local function onVehicleSpawned(vid, v)
end

local function onVehicleSwitched(oldid, newid, player)
  if player==0 then
    currentPlayerVehicleId = newid
    if newid == -1 or not newid then
      currentPlayerVehicleObj = nil
    else
      currentPlayerVehicleObj = getObjectByID(newid)
    end
    metricAdd("vehicle/switch",1)
  end
end

local function onVehicleResetted(vid)
  if currentPlayerVehicleId==vid then metricAdd("vehicle/reset",1) end
end

local function onVehicleDestroyed(vid)
  if currentPlayerVehicleId==vid then
    currentPlayerVehicleId=-1
    currentPlayerVehicleObj = nil
  end
end

local function setDebug(newValue)
  if newValue then
    windowOpen[0] = true
  else
    windowOpen[0] = false
  end
end

local function sendGUIState()
  if dirtyMetricCount>0 or (os.clock() - lastSaveTime > SAVE_DECAY_INTERVAL_SECONDS) then
    _save()
  end
  local data = {general= fileData.entries}
  if fileDataCareer then
    data.career = fileDataCareer.entries
  end
  guihooks.trigger('StatisticData', data )

end

local function onExtensionLoaded()
  loadSubmodules()
end

local function forceTimerUpdate()
  for k in pairs(timers) do
    _timerSave(k)
  end
end

-- Career seam: the owner loads, saves and drops the career copy.
local function getCareerData()
  return fileDataCareer
end

local function setCareerData(data)
  fileDataCareer = data
end

-- The career ended: drop the career copy, every timer, the career callbacks and the activity.
local function endCareer()
  fileDataCareer = nil
  timers = {}
  callbacksCareer = {}
  currentActivity = nil
  currentMod = nil
  currentLevel = nil
end

local api = {}
api.onFirstUpdate = onFirstUpdate
api.onExit = onExit
api.onExtensionUnloaded = onExtensionUnloaded
api.onSerialize = onSerialize
api.onDeserialized = onDeserialized
api.onExtensionLoaded = onExtensionLoaded


api.onClientStartMission = onClientStartMission
api.onClientEndMission = onClientEndMission
api.onClientPostStartMission = onClientPostStartMission
api.onWorldReadyState = onWorldReadyState
api.onEditorActivated = onEditorActivated
api.onEditorDeactivated = onEditorDeactivated
api.onScenarioLoaded = onScenarioLoaded
api.onScenarioFinished = onScenarioFinished
api.onScenarioRestarted = onScenarioRestarted
api.onUpdate = onUpdate
api.onVehicleSpawned = onVehicleSpawned
api.onVehicleSwitched = onVehicleSwitched
api.onVehicleResetted = onVehicleResetted
api.onVehicleDestroyed = onVehicleDestroyed
api.onGameStateUpdate = onGameStateUpdate
api.onSpawnDefaultVehicle = onSpawnDefaultVehicle

api.onVehicleSelectorSpawnNew = onVehicleSelectorSpawnNew
api.onVehicleSelectorReplaceCurrent = onVehicleSelectorReplaceCurrent
api.onPlayerVehicleCloned = onPlayerVehicleCloned

api.sendGUIState = sendGUIState
api.forceTimerUpdate = forceTimerUpdate

api.metricAdd = metricAdd
api.metricSet = metricSet
api.metricGet = metricGet
api.metricGetMatchPattern = metricGetMatchPattern
api.timerStart = timerStart
api.timerStop = timerStop
api.callbackRegister = callbackRegister
api.callbackRemove = callbackRemove

api.addSchedule = addSchedule
api.removeSchedule = removeSchedule

api.setDebug = setDebug

return api, {getCareerData = getCareerData, setCareerData = setCareerData, save = _save, endCareer = endCareer}
end

return statisticCore
