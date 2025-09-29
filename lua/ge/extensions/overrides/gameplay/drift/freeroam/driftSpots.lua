-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
M.dependencies = {
  "gameplay_drift_general",
  "gameplay_drift_drift",
  "gameplay_drift_scoring",
  "gameplay_drift_saveLoad"
}

local im = ui_imgui

local options = {
  maxWrongWayDist = 5,
  maxDistToIntendedRoad = 30,
  concludingPhaseDuration = 2.5,
  stopTimeToAbort = 1
}

local plVel = vec3()

local isBeingDebugged = true
local profiler = LuaProfiler("Drift driftSpots profiler")
local gc = 0
local driftDebugInfo = {
  default = false,
  canBeChanged = true
}

local improperEndReasons = {
  wrongWay = {
    msg = "Drift terminated: You drove back up the course"
  },
  outOfBounds = {
    msg = "Drift zone exited"
  },
  stopped = {
    msg = "Drift terminated: you have stopped moving"
  },
  vehReset = {
    msg = "Drift zone canceled: you reset your vehicle"
  }
}

-- sanitized data, better for processing
local lines = {}

local activeLine -- this line is constantly checked to see if player is crossing it
local finishLineName -- reckoned finish line depending on starting line

local isInTheConcludingPhase = false
local isInFreeroamChallenge = false
local hasAlreadyShownNewRecord = false

local plPos = vec3()

local currStopTimeToAbort = 0
local lastFrameLevel = nil
local function isPointInsideRectangle(vehPos, pos, scl, rot)
  local inverseRot = rot:inversed()

  local translatedPoint = vehPos - pos

  local localPoint = inverseRot * vec3(translatedPoint.x / scl.x, translatedPoint.y / scl.y, translatedPoint.z / scl.z)
  return math.abs(localPoint.x) <= 1 and math.abs(localPoint.y) <= 1 and math.abs(localPoint.z) <= 1
end

local function getHighestScoreData()
  local spot = gameplay_drift_saveLoad.getDriftSpotById(activeLine.spotName)
  return spot.saveData.scores[1] or {score = 0, licensePlate = ""}
end

local function findNearestStartLine()
  local closest = math.huge
  for lineName, lineData in pairs(lines) do
    local dist = lineData.pos:distance(plPos)
    if dist < closest then
      closest = dist
      activeLine = lineData
      activeLine.name = lineName
    end
  end
end

local function updateTaskList()
  local spot = gameplay_drift_saveLoad.getDriftSpotById(activeLine.spotName)
  local highestScore = getHighestScoreData()
  local label = highestScore.score > 0 and string.format("Highest score by \"".. highestScore.licensePlate .. "\": %i", highestScore.score) or "No highscore yet, rip it!"
  guihooks.trigger("SetTasklistTask", {
    clear = false,
    label = label,
    active = true,
    id = "driftHighscore",
    type = "message"
  })
  for _, obj in ipairs(spot.info.objectives or {}) do
    local completed = spot.saveData.objectivesCompleted[obj.id]
      guihooks.trigger("SetTasklistTask", {
        label = {txt='missions.drift.stars.bronze', context = {bronzePoints = obj.score}},
        done = completed,
        active = true,
        id = "objective_"..obj.id,
        type = "goal",
      })
  end
end

local function delayedUpdateTaskList(job)
  job.sleep(0.2)
  updateTaskList()
end

local function startFreeroamChallenge(line)
  hasAlreadyShownNewRecord = false
  log("I","","Started freeroam drift zone: " .. dumps(line.id))
  gameplay_drift_general.setContext("inFreeroamChallenge")
  gameplay_drift_general.reset()
  gameplay_drift_bounds.setBounds(line.bounds, false) -- false for don't draw bounds
  gameplay_drift_destination.setRacePath({filePath = line.racePath, reverse = line.name == "lineTwo", maxWrongWayDist = options.maxWrongWayDist}) -- true or false for reversed race path or not

  isInFreeroamChallenge = true
  activeLine = line

  -- we need to delay the updateTaskList call otherwise it doesn't show
  core_jobsystem.create(delayedUpdateTaskList, 1)
end

local function end_()
  gameplay_drift_general.setContext("inFreeroam")
  guihooks.trigger('ClearTasklist')
  isInFreeroamChallenge = false
  isInTheConcludingPhase = false
  activeLine = nil
end

local function resetDriftZoneScores(spotName)
  local spot = gameplay_drift_saveLoad.getDriftSpotById(spotName)
  spot.saveData.scores = {}
  gameplay_drift_saveLoad.saveDriftSpotsScoresForSpotById(spotName)
end

local function addNewScore(spotName, score)
  local spot = gameplay_drift_saveLoad.getDriftSpotById(spotName)

  table.insert(spot.saveData.scores,
    {
      score = score,
      licensePlate = core_vehicles.getVehicleLicenseText(gameplay_drift_drift.getPlVeh()),
      date = os.time(),
    } )
  table.sort(spot.saveData.scores, function(a, b) return a.score > b.score end)

  local anyObjectiveReached = false
  if spot.info.objectives then
    local rewards = {}
    for _, obj in ipairs(spot.info.objectives) do
      if not spot.saveData.objectivesCompleted[obj.id] then
        if score >= obj.score then
          for k, v in pairs(obj.rewards) do
            rewards[k] = (rewards[k] or 0) + v
          end
          spot.saveData.objectivesCompleted[obj.id] = true
          anyObjectiveReached = true
        end
      end
    end
    if career_career.isActive() then
      local spotName = translateLanguage(spot.info.name, spot.info.name, true)
      career_modules_playerAttributes.addAttributes(rewards, {tags={"gameplay", "drift"}, label="Objective completed on " .. spotName})
    end
  end

  -- only keep 10 scores
  for i = 10, #spot.saveData.scores do
    table.remove(spot.saveData.scores, 10)
  end

  gameplay_drift_saveLoad.saveDriftSpotsScoresForSpotById(spotName)

    -- reeavaluate if unlocked new stuff, if any objective was reached
--[[
  if anyObjectiveReached and career_career.isActive() then
    career_branches_leagues.onAfterDriftSpotsLoaded(gameplay_drift_saveLoad.getDriftSpotsById())
    gameplay_rawPois.clear()
  end
  ]]
end

local function properEnd()
  core_jobsystem.create(function(job)
    isInTheConcludingPhase = true

    if gameplay_drift_scoring.wrapUpWithText() then
      job.sleep(1.7)
    end

    local scoreGained = gameplay_drift_scoring.getScore().score
    local spot = gameplay_drift_saveLoad.getDriftSpotById(activeLine.spotName)

    extensions.hook("onFreeroamChallengeCompleted",
    {
      duration = options.concludingPhaseDuration,
      score = scoreGained,
      newRecord = scoreGained > getHighestScoreData().score
    })
    job.sleep(options.concludingPhaseDuration)
    addNewScore(activeLine.spotName, scoreGained)
    end_()
  end
)
end

local function improperEnd(reason)
  if not isInFreeroamChallenge or isInTheConcludingPhase then return end

  core_jobsystem.create(function(job)
    isInTheConcludingPhase = true

    extensions.hook("onFreeroamChallengeTerminated", reason, options.concludingPhaseDuration)
    local spot = gameplay_drift_saveLoad.getDriftSpotById(activeLine.spotName)
    for _, obj in ipairs(spot.info.objectives or {}) do
      local completed = spot.saveData.objectivesCompleted[obj.id]
      if not completed then
        guihooks.trigger("SetTasklistTask", {
          fail = not completed,
          id = "objective_"..obj.id,
        })
      end
    end
    job.sleep(options.concludingPhaseDuration)
    end_()
    end
  )
end

-- "Proper" end means going through the finish line, not out of bounds or wrong way
local function detectStart(lineId)
  local line = lines[lineId]
  if not line then
    log("E","","Could not find drift line with id " .. dumps(lineId))
    return
  end
  if isInFreeroamChallenge then
    return
  end
  if isPointInsideRectangle(plPos, line.pos, line.scl, line.rot) then
    local dot = plVel:dot(line.startDir)
    if dot > 0 then
      if gameplay_drift_drift.getIsDrifting() then
        startFreeroamChallenge(line)
      end
    end
  end
end


local function detectProperEnd()
  local finishLine = lines[activeLine.correspondingLineName]
  if finishLine then
    if isPointInsideRectangle(plPos, finishLine.pos, finishLine.scl, finishLine.rot) then
      local dot = plVel:dot(finishLine.startDir)
      if not isInTheConcludingPhase and isInFreeroamChallenge and dot <= 0 then
        properEnd()
        return
      end
    end
  end
end

local function improperEndChecks(dtSim)
  if not isInFreeroamChallenge or isInTheConcludingPhase then return end

  -- if the player stops moving
  if gameplay_drift_drift.getVehData().vel:length() < 2 then
    currStopTimeToAbort = currStopTimeToAbort + dtSim
    if currStopTimeToAbort > options.stopTimeToAbort then
      improperEnd(improperEndReasons.stopped)
    end
  else
    currStopTimeToAbort = 0
  end

  if gameplay_drift_destination and gameplay_drift_destination.getWrongWayFail() then
    improperEnd(improperEndReasons.wrongWay)
  end

  if gameplay_drift_destination and gameplay_drift_destination.getDistToIntendedRoad() > options.maxDistToIntendedRoad then
    improperEnd(improperEndReasons.outOfBounds)
  end
end


-- create a list of "lines" to check for afterward
local function loadAndSanitizeData()
  if career_career.isActive() then
    return
  end

  for _, spotData in ipairs(gameplay_drift_saveLoad.loadAndSanitizeDriftFreeroamSpotsCurrMap()) do
    for lineName, lineData in pairs(spotData.spatialInfo.lines) do
      local spotName = spotData.id
      local newLineData = {
        id = spotName .. " - " .. lineName,
        pos = vec3(lineData.pos),
        scl = vec3(lineData.scl),
        rot = quat(lineData.rot),
        startDir = vec3(lineData.startDir),

        markerObjects = lineData.markerObjects or {},

        spotName = spotName,
        name = lineName,
        racePath = spotData.racePath,
        bounds = spotData.bounds,
        correspondingLineName = lineName == "lineOne" and spotName.."lineTwo" or spotName.."lineOne",
      }

      lines[spotName..lineName] = newLineData
    end
  end
end

local function imguiDebug()
  if not isBeingDebugged then return end

  if im.Begin("Drift freeroam") then
    if activeLine then
      debugDrawer:drawSphere(activeLine.pos, 0.1, ColorF(0,0.5,1,0.5))
      im.Text("Active line: " .. activeLine.name)
    else
      im.Text("No active line")
    end

    im.Text("Challenge started : " .. tostring(isInFreeroamChallenge))
    if activeLine then
      if im.Button("Reset drift zone scores") then
        resetDriftZoneScores(activeLine.spotName)
        loadAndSanitizeData()
      end
    end
    if isInFreeroamChallenge then
      im.Text("Current spot scores : ")

      local spot = gameplay_drift_saveLoad.getDriftSpotById(activeLine.spotName)

      for _, data in ipairs(spot.saveData.scores) do
        im.Text(tostring(data.score))
      end
    end
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  isBeingDebugged = gameplay_drift_general.getExtensionDebug("gameplay_drift_freeroam_driftSpots")
  imguiDebug()
  if gameplay_drift_general.getGeneralDebug() then profiler:start() end
  if getCurrentLevelIdentifier() ~= nil and getCurrentLevelIdentifier() ~= lastFrameLevel then
    loadAndSanitizeData()
  end
  lastFrameLevel = getCurrentLevelIdentifier()
  if not gameplay_drift_drift.getVehPos() then return end

  plPos:set(gameplay_drift_drift.getVehPos())
  plVel:set(gameplay_drift_drift.getVehVel())

  if activeLine and isInFreeroamChallenge then
    detectProperEnd(dtSim)
    improperEndChecks(dtSim)
  end

  if gameplay_drift_general.getGeneralDebug() then
    profiler:add("Drift driftSpots")
    gc = profiler.sections[1].garbage
    profiler:finish(false)
  end
end

local function getDriftDebugInfo()
  return driftDebugInfo
end

local function getIsInTheConcludingPhase()
  return isInTheConcludingPhase
end

local function getGC()
  return gc
end

local function getIsInFreeroamChallenge()
  return isInFreeroamChallenge
end

local function onVehicleResetted(id)
  if id == gameplay_drift_drift.getVehId() then
    improperEnd(improperEndReasons.vehReset)
  end
end

local function getBigMapTpPosRot(poi, veh)
  local spot = gameplay_drift_saveLoad.getDriftSpotById(poi.spotId)
  if spot then
    return vec3(spot.spatialInfo.bigMapTp.pos), quat(spot.spatialInfo.bigMapTp.rot)
  end
  return nil, nil
end

local function onGetRawPoiListForLevel(levelIdentifier, elements)
  loadAndSanitizeData()
  -- todo: (optional) load data only when its requested by this function
  -- todo. filter lines so only the current level lines are added
  if career_career.isActive() or settings.getValue("enableDriftInFreeroam") then
    for id, line in pairs(lines) do
      local spot = gameplay_drift_saveLoad.getDriftSpotById(line.spotName)
      local poi = {
        data = {type = "driftSpot"},
        id = "driftLineMarker##"..id,
        spotId = line.spotName,
        lineId = id,
        markerInfo = {
          driftLineMarker = {
            pos = line.pos,
            radius = line.scl:length()+2,
            startDir = line.startDir,
            markerObjects = line.markerObjects or {}
          },
          -- TODO: optional: add bigmap markers (if we want that)
        }
      }

      if line.name == "lineOne" then
        poi.markerInfo.bigmapMarker = { pos = line.pos, icon = "mission_drift_triangle", name = spot.info.name, description = "A drift spot on the map.", thumbnail = spot.info.preview, previews = {spot.info.preview}, quickTravelPosRotFunction = getBigMapTpPosRot}
        if spot.saveData.scores[1] then
          poi.markerInfo.bigmapMarker.description = poi.markerInfo.bigmapMarker.description .. "\n" .. string.format("Current Highscore: %d by %s.", spot.saveData.scores[1].score, spot.saveData.scores[1].licensePlate)
        end
        poi.markerInfo.bigmapMarker.aggregatePrimary = {label = 'bigMap.progressLabels.bestPoints', value = spot.saveData.scores[1] and spot.saveData.scores[1].score or "-"}
      end

      table.insert(elements, poi)
    end
  end
end

-- when whole drift chain done
local function onDriftCompletedScored()
  if isInFreeroamChallenge then
    local spot = gameplay_drift_saveLoad.getDriftSpotById(activeLine.spotName)
    for _, obj in ipairs(spot.info.objectives or {}) do
      local completed = spot.saveData.objectivesCompleted[obj.id] or gameplay_drift_scoring.getScore().score >= obj.score
        guihooks.trigger("SetTasklistTask", {
          done = completed,
          id = "objective_"..obj.id,
        })
    end
  end
  if not hasAlreadyShownNewRecord and not isInTheConcludingPhase and isInFreeroamChallenge and gameplay_drift_scoring.getScore().score > getHighestScoreData().score and getHighestScoreData().score > 0 then
    extensions.hook("onFreeroamDriftZoneNewHighscore")
    guihooks.trigger("SetTasklistTask", {
      label = "New Highscore!",
      done = completed,
      id = "driftHighscore",
    })
    hasAlreadyShownNewRecord = true
  end
end

local function onDeserialized(data)
  if data.isInFreeroamChallenge then
    end_()
  end
end

local function onSerialize()
  return {
    isInFreeroamChallenge = isInFreeroamChallenge
  }
end


M.detectStart = detectStart

M.onUpdate = onUpdate
M.onVehicleResetted = onVehicleResetted
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel
M.onDeserialized = onDeserialized
M.onSerialize = onSerialize

M.getDriftDebugInfo = getDriftDebugInfo
M.getIsInTheConcludingPhase = getIsInTheConcludingPhase
M.getIsInFreeroamChallenge = getIsInFreeroamChallenge
M.getGC = getGC

M.onDriftCompletedScored = onDriftCompletedScored
return M