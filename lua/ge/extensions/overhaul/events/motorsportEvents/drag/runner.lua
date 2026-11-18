-- Owns physical drag passes and owned NPC cleanup.
-- drag/parking.lua supplies racers; drag/staging.lua and drag/recovery.lua manage staging; the coordinator receives results.
local M = {}
-- Toasts join the Event display stack (motorsportEvents/notify.lua); it is loaded when the first one is sent.
local function toast(text, kind, seconds) return require('overhaul/events/motorsportEvents/notify')(text, kind, seconds) end
local session, callback, originalStart, startWrapper, stagingRouteToken
local lastPass
local elapsed, generation, clearing = 0, 0, false
local owned = {}
local patchRegistered, saveHold
local saveStore = require('overhaul/lib/save/store')
local spectator = require('overhaul/events/motorsportEvents/drag/spectator')
local parking = require('overhaul/events/motorsportEvents/drag/parking')
local approach = require('overhaul/events/motorsportEvents/drag/approach')
local recovery = require('overhaul/events/motorsportEvents/drag/recovery')
local roster = require('overhaul/events/motorsportEvents/drag/roster')
local finishOrder = require('overhaul/events/motorsportEvents/drag/finishOrder')
local interference = require('overhaul/events/motorsportEvents/drag/interference')
local laneZones = require('overhaul/events/motorsportEvents/drag/laneZones')
local staging = require('overhaul/events/motorsportEvents/drag/staging')
local vehicleSettings = require('overhaul/events/motorsportEvents/vehicleSettings')
local releaseZones, releaseStaging, releaseReaction
local dragReaction = require('overhaul/lib/events/dragReaction')
local finishSample, winnerExtension, originalWinner, winnerWrapper = 0
local RUNTIME_FILE = '/settings/motorsportEvents/runtime.dragSettings.json'
local MAX_NPC_STOP_SECONDS = 20

local function core() return gameplay_drag_core end
local function resultLabel(reason)
  if reason == 'missions.dragRace.gameplay.disqualified.jumping' then return 'Red light' end
  if reason == 'missions.dragRace.gameplay.disqualified.outOfLane' then return 'Out of lane' end
  return reason
end
M.isWatching = spectator.isWatching
M.setWatching = spectator.setWatching
M.cycleSpectatorCamera = spectator.cycleCamera
M.spectatorCameraState = spectator.cameraState

local function skipNativeStop(row, racer)
  if row.entrant.player or row.id == be:getPlayerVehicleID(0) or row.stopPrepared == racer then return end
  -- Event NPCs brake in their lane instead of following the native return waypoint.
  for _, phase in ipairs(racer.phases or {}) do
    if phase.name == 'stop' or phase.name == 'emergencyStop' then phase.started, phase.completed = true, true end
  end
  row.stopPrepared = racer
end

function M.getPlayerLane(stripId)
  local vehicle = be:getPlayerVehicle(0)
  if not vehicle or vehicle:getVelocity():length() > 3 then return nil end
  for _, data in pairs(core().getDragDataForLevel(getCurrentLevelIdentifier()) or {}) do
    if data.strip and data.strip.id == stripId then
      local nearest, distance = nil, 8
      for lane, row in ipairs(data.strip.lanes) do
        local d = vehicle:getPosition():distance(row.waypoints.stage.transform.pos)
        if d < distance then nearest, distance = lane, d end
      end
      return nearest
    end
  end
end

local function ownsPlayerPractice(request)
  local data = core().getData()
  if not data or data.context ~= 'freeroam' or not data.strip or data.strip.id ~= request.stripId then return false end
  if data.isCompleted then return true end
  local playerId = be:getPlayerVehicleID(0)
  for id in pairs(data.racers or {}) do if id ~= playerId then return false end end
  for _, entrant in ipairs(request.entrants) do
    if entrant.player then return roster.matchesVehicle(entrant, be:getPlayerVehicle(0)) end
  end
  return false
end

local function deleteOwned(ids)
  for _, id in ipairs(ids) do
    local obj = be:getObjectByID(id)
    if obj and id ~= be:getPlayerVehicleID(0) then obj:delete() end
  end
end

function M.stop()
  lastPass = nil
  if releaseStaging then releaseStaging(); releaseStaging = nil end
  if releaseZones then releaseZones(); releaseZones = nil end
  if releaseReaction then releaseReaction(); releaseReaction = nil end
  if winnerExtension and winnerExtension.generateWinData == winnerWrapper then winnerExtension.generateWinData = originalWinner end
  winnerExtension, originalWinner, winnerWrapper = nil, nil, nil
  if saveHold then saveHold.release(); saveHold = nil end
  if stagingRouteToken ~= nil and core_groundMarkers and core_groundMarkers.clearOwnedPath then
    core_groundMarkers.clearOwnedPath(stagingRouteToken)
  end
  stagingRouteToken = nil
  if spectator.resetView then spectator.resetView() end
  if recovery.clear then recovery.clear() end
  if approach.clear then approach.clear(session and session.racers) end
  for _, row in ipairs(session and session.racers or {}) do
    if row.startupStarted then
      local vehicle = be:getObjectByID(row.id)
      if vehicle then vehicle:queueLuaCommand("extensions.unload('overhaulMotorsportStartup')") end
    end
    if row.launchStarted then
      local vehicle = be:getObjectByID(row.id)
      if vehicle then vehicle:queueLuaCommand("extensions.unload('overhaulMotorsportLaunch')") end
    end
    if row.braking and not row.entrant.player then
      local vehicle = be:getObjectByID(row.id)
      if vehicle then vehicle:queueLuaCommand("extensions.unload('overhaulMotorsportCooldown')") end
    end
  end
  generation = generation + 1
  local ids, wasRunning = owned, session and session.phase ~= 'armed'
  owned, session, callback = {}, nil, nil
  elapsed, clearing = 0, true
  local drag = core()
  if drag and wasRunning then
    local ext = drag.getExtension()
    if ext and ext.resetDragRace then ext.resetDragRace() end
    drag.clear({hooks = true, transitionLock = true, data = true, context = true, extensions = true, ui = true, treeLightStaging = true})
  end
  deleteOwned(ids)
  clearing = false
end

local function finish(result)
  local done = callback
  local snapshot = session and M.status().timeslip
  M.stop()
  lastPass = not result.error and snapshot or nil
  if done then done(result) end
  if lastPass and not lastPass.graded then M.recordResult(result) end
end

function M.recordResult(result)
  if lastPass and result and not result.error then
    for _, lane in ipairs(lastPass.lanes) do
      for _, row in ipairs(result.rows or {}) do
        if row.entrantId == lane.entrantId then
          lane.result = resultLabel(row.reason or row.nativeReason or (row.qualifyingRedLight and 'Red light')) or lane.result
        end
      end
      lane.winner = result.winnerId ~= nil and result.winnerId == lane.entrantId
    end
    lastPass.graded = true
  end
end

local function loadStrip()
  local data = jsonReadFile(session.stripFile)
  if type(data) ~= 'table' then return nil, 'Drag strip data is unavailable.' end
  data.context, data.dragType, data.racers = 'activity', 'headsUpRace', {}
  data.prefabs = data.prefabs or {}
  data.prefabs.christmasTree = data.prefabs.christmasTree or {}
  data.prefabs.christmasTree.treeType = session.entrants[1].leagueId == 'pro_league' and '.400' or '.500'
  if not FS:directoryExists('/settings/motorsportEvents') then FS:directoryCreate('/settings/motorsportEvents', true) end
  if not jsonWriteFile(RUNTIME_FILE, data, true) then return nil, 'Could not prepare the event strip.' end
  return core().loadDragDataForMission(RUNTIME_FILE)
end

local function begin()
  if core().getDragIsStarted() and ownsPlayerPractice(session) then
    local ext = core().getExtension()
    if ext and ext.resetDragRace then ext.resetDragRace() end
    core().clear({hooks = true, transitionLock = true, data = true, context = true, extensions = true, ui = true, treeLightStaging = true})
    session.interrupted = nil
  end
  local data, err = loadStrip()
  if not data then return false, err or 'Could not load the event strip.' end
  releaseReaction = dragReaction.attach(data)
  releaseZones = laneZones.attach(data)
  session.phase, session.racers = 'preparing', {}
  local leftLane = 2
  local lanes = data.strip.lanes
  local forward = lanes[1].stageToEndNormalized
  session.raceDirection = forward
  if forward then
    local offset = lanes[1].waypoints.stage.transform.pos - lanes[2].waypoints.stage.transform.pos
    leftLane = offset:dot(vec3(-forward.y, forward.x, 0)) > 0 and 1 or 2
  end
  for lane, row in ipairs(data.strip.lanes) do
    if tostring(row.longName or row.shortName or row.name or row.label):lower():find('left') then leftLane = lane end
  end
  local firstSide = parking.getSide(session.entrants[1].id) or 'left'
  local firstLane = firstSide == 'left' and leftLane or 3 - leftLane
  for i, entrant in ipairs(session.entrants) do
    local lane = i == 1 and firstLane or 3 - firstLane
    local id, atLaneSpawn
    if entrant.player then
      local player = be:getPlayerVehicle(0)
      if not roster.matchesVehicle(entrant, player) then
        return false, roster.mismatchReason(entrant, player)
      end
      id = player:getID()
      session.playerLane = lane == leftLane and 'Left' or 'Right'
      if core_groundMarkers then
        stagingRouteToken = core_groundMarkers.setPath(data.strip.lanes[lane].waypoints.spawn.transform.pos, {clearPathOnReachingTarget = true})
      end
    else
      local err
      id, err, atLaneSpawn = parking.take(entrant, data.strip.lanes[lane].waypoints.spawn.transform)
      if not id then return false, err end
      owned[#owned + 1] = id
    end
    local laneData = data.strip.lanes[lane]
    local origin = laneData.waypoints.endLine and laneData.waypoints.endLine.transform and laneData.waypoints.endLine.transform.pos
    local direction = laneData.stageToEndNormalized
    session.racers[#session.racers + 1] = {id = id, lane = lane, entrant = entrant, arrived = atLaneSpawn,
      cooldownLane = origin and direction and {origin = {origin.x, origin.y, origin.z}, direction = {direction.x, direction.y, direction.z}} or nil}
    if not entrant.player then
      local vehicle = be:getObjectByID(id)
      if vehicle then
        vehicle:queueLuaCommand("extensions.load('overhaulMotorsportStartup'); overhaulMotorsportStartup.start()")
        session.racers[#session.racers].startupStarted = true
      end
    end
  end
  releaseStaging = staging.attach(data, session.racers)
  local token = generation
  core_jobsystem.create(function(job)
    job.sleep(0.5)
    if token ~= generation or not session then return end
    local current = core().getData()
    if current ~= data then finish({error = 'Race interrupted while spawning.'}); return end
    approach.start(session.racers, data)
    session.phase, elapsed = 'approaching', 0
  end)
  return true
end

function M.init()
  if patchRegistered then return end
  overhaul_shell_patches.registerFields('motorsportDragStart', core, {startDragRaceActivity = function(original)
    originalStart = original
    startWrapper = function(lane, ...)
      if session then
        if session.phase ~= 'armed' then return true end
        local data = core().getData()
        if not data or not data.strip or data.strip.id ~= session.stripId then
          toast('Wrong strip. Your event runs at ' .. session.stripName .. '.', 'bad', 6)
          return false
        end
        local ok, err = begin(lane)
        if not ok then finish({error = err}) end
        return ok
      end
      if overhaul_events_motorsportEvents and overhaul_events_motorsportEvents.isDragDispatchActive() then return false end
      return original(lane, ...)
    end
    return startWrapper
  end})
  patchRegistered = true
end

function M.start(request, onResult)
  if session then return false, 'A pass is already active.' end
  M.init()
  if core().getDragIsStarted() and not ownsPlayerPractice(request) then return false, 'Finish or leave the current drag race first.' end
  lastPass = nil
  generation = generation + 1
  session, callback, elapsed = request, onResult, 0
  saveHold = saveStore.hold(M, 'motorsport drag pass', {stage = 'beforeRoute'})
  for _, entrant in ipairs(request.entrants) do
    if entrant.player then
      M.setWatching(false)
      local ok, err = begin()
      if not ok then M.stop() end
      if ok then toast('Head to the ' .. string.lower(session.playerLane) .. ' lane. ' .. (#request.entrants > 1 and 'Your opponent is on the way.' or 'Solo pass, no opponent.'), 'warn', 10) end
      return ok, err
    end
  end
  local ok, err = begin()
  if not ok then M.stop() end
  return ok, err
end

local function timeslip(data)
  if not data then return nil end
  local cache = session.timeslipCache
  if not cache or cache.data ~= data or cache.timerDefinitions ~= data.timers or cache.racers ~= session.racers
    or cache.racerCount ~= #(session.racers or {}) then
    local tree = data.prefabs and data.prefabs.christmasTree and data.prefabs.christmasTree.treeType
    local slip = {strip = session.stripName or (data.strip and data.strip.name),
      tree = tree and (tree .. (tree == '.400' and ' Pro Tree' or ' Sportsman Tree')) or nil,
      raceType = 'Heads up', lanes = {}}
    cache = {data = data, timerDefinitions = data.timers, racers = session.racers, racerCount = #(session.racers or {}), slip = slip, rawValues = {}}
    session.timeslipCache = cache
    for _, def in ipairs(data.timers or {}) do
      if def.id == (data.importantTimerId or data.raceEndTimerId or 'time_1_4') then slip.distance = def.label or def.shortLabel end
    end
    for _, row in ipairs(session.racers or {}) do
      local lane = {entrantId = row.entrant.id, lane = 'L' .. tostring(row.lane), name = row.entrant.name,
        player = row.entrant.player == true, timers = {}}
      for _, def in ipairs(data.timers or {}) do
        local label = def.shortLabel or def.label or def.id
        if def.id and label then lane.timers[#lane.timers + 1] = {label = label, value = '—'} end
      end
      slip.lanes[#slip.lanes + 1] = lane
      cache.rawValues[#cache.rawValues + 1] = {}
    end
  end
  for index, row in ipairs(session.racers or {}) do
    local lane = cache.slip.lanes[index]
    local racer = (data.racers and data.racers[row.id]) or row.nativeRacer
    local timerIndex = 0
    for _, def in ipairs(data.timers or {}) do
      local label = def.shortLabel or def.label or def.id
      if def.id and label then
        timerIndex = timerIndex + 1
        local timer = racer and racer.timers and racer.timers[def.id]
        local value = timer and timer.isSet and tonumber(timer.value) or false
        if cache.rawValues[index][timerIndex] ~= value then
          cache.rawValues[index][timerIndex] = value
          lane.timers[timerIndex].value = value and string.format(def.type == 'velocity' and '%.1f mph' or '%.3f', def.type == 'velocity' and value * 2.23694 or value) or '—'
        end
      end
    end
    local result = row.completedResult
    lane.result = resultLabel(result and (result.reason or result.nativeReason or (result.qualifyingRedLight and 'Red light')) or row.failureReason)
  end
  return cache.slip
end

function M.status()
  if not session then return {phase = 'idle', timeslip = lastPass} end
  local rows, data, treeLive = {}, core().getData(), false
  for _, row in ipairs(session.racers or {}) do
    local racer = (data and data.racers and data.racers[row.id]) or row.nativeRacer
    if row.entrant.player and racer and (racer.treeStarted or racer.timersStarted) then treeLive = true end
    local vehicle = be:getObjectByID(row.id)
    rows[#rows + 1] = {entrantId = row.entrant.id, lane = row.lane,
      player = row.entrant.player == true,
      staged = racer and racer.beamState and racer.beamState[racer.frontWheelId] and racer.beamState[racer.frontWheelId].stage == true or false,
      phase = row.failureReason and 'DNF' or racer and racer.phases and racer.phases[racer.currentPhase] and racer.phases[racer.currentPhase].name,
      speed = vehicle and vehicle:getVelocity():length() or 0}
  end
  local playerPass = false
  for _, entrant in ipairs(session.entrants) do if entrant.player then playerPass = true end end
  return {phase = session.phase, racers = rows, elapsed = elapsed, playerPass = playerPass, playerLane = session.playerLane, treeLive = treeLive, timeslip = timeslip(data)}
end

local function qualifyingBoundary(row, racer, dtSim)
  if not session.qualifying or row.qualifyingFinished then return end
  if racer.currentPhase ~= 2 and racer.currentPhase ~= 3 and not racer.timersStarted then return end
  local handler = gameplay_drag_phaseHandlers
  if not handler or type(handler.isRacerInsideBoundary) ~= 'function' or type(handler.getFrontWheelDistanceFromStagePos) ~= 'function' then
    row.qualifyingBoundaryUnknown = true
  else
    local ok, inside = pcall(handler.isRacerInsideBoundary, racer)
    local distanceOk, distance = pcall(handler.getFrontWheelDistanceFromStagePos, racer)
    if not ok or type(inside) ~= 'boolean' or not distanceOk or type(distance) ~= 'number' or distance ~= distance
      or distance == math.huge or distance == -math.huge then
      row.qualifyingBoundaryUnknown = true
    else
      row.qualifyingBoundaryKnown = true
      if not inside or distance < -.33 then row.qualifyingBoundaryViolation = true end
    end
  end
  local phase = racer.phases and racer.phases[racer.currentPhase]
  if racer.currentPhase == 3 and not phase then row.qualifyingTelemetryUnknown = true end
  if phase and phase.name == 'race' and phase.started and not racer.isFinished then
    if not racer.vehDirectionVectorUp or type(racer.vehDirectionVectorUp.z) ~= 'number'
      or racer.vehDirectionVectorUp.z ~= racer.vehDirectionVectorUp.z or math.abs(racer.vehDirectionVectorUp.z) == math.huge
      or not racer.vehPos or type(racer.vehPos.distance) ~= 'function' then
      row.qualifyingTelemetryUnknown = true
    else
      row.qualifyingTelemetryKnown = true
      row.qualifyingStuckTimer = (row.qualifyingStuckTimer or 0) + dtSim
      if row.qualifyingStuckTimer >= 3 then
        row.qualifyingStuckTimer = 0
        if racer.vehDirectionVectorUp.z < .2 then row.qualifyingOtherFoul = row.qualifyingOtherFoul or 'missions.dragRace.gameplay.disqualified.crashed'
        elseif row.qualifyingStuckPosition then
          local moved = racer.vehPos:distance(row.qualifyingStuckPosition)
          row.qualifyingStuckPosition:set(racer.vehPos)
          if moved ~= moved or moved == math.huge then row.qualifyingTelemetryUnknown = true
          elseif moved < 3 then row.qualifyingOtherFoul = row.qualifyingOtherFoul or 'missions.dragRace.gameplay.disqualified.stationaryTooLong' end
        else row.qualifyingStuckPosition = vec3(racer.vehPos) end
      end
    end
  end
  local timer = racer.timers and racer.timers.time_1_4
  if timer and timer.isSet then row.qualifyingFinished = true end
end

local function updateNpcLaunch(row, racer)
  local phase = racer.phases and racer.phases[racer.currentPhase]
  if row.startupStarted and phase and phase.name ~= 'stage' then
    local vehicle = be:getObjectByID(row.id)
    if vehicle then vehicle:queueLuaCommand("extensions.unload('overhaulMotorsportStartup')") end
    row.startupStarted = nil
  end
  if row.launchStarted or row.braking or row.entrant.player or row.id == be:getPlayerVehicleID(0) then return end
  local recoveryRate = vehicleSettings.launchRate(row.entrant)
  if not recoveryRate then return end
  if not phase or phase.name ~= 'race' or not phase.started or racer.isFinished or racer.isDisqualified or racer.isDesqualified then return end
  local vehicle = be:getObjectByID(row.id)
  if not vehicle then return end
  vehicle:queueLuaCommand("extensions.load('overhaulMotorsportLaunch'); overhaulMotorsportLaunch.start(" .. tostring(recoveryRate) .. ")")
  row.launchStarted = true
end

local function brakeNpc(row, racer)
  if row.entrant.player or row.id == be:getPlayerVehicleID(0) or row.braking then return end
  local vehicle = be:getObjectByID(row.id)
  if vehicle then
    staging.clear({row})
    if row.startupStarted then
      vehicle:queueLuaCommand("extensions.unload('overhaulMotorsportStartup')")
      row.startupStarted = nil
    end
    if row.launchStarted then
      vehicle:queueLuaCommand("extensions.unload('overhaulMotorsportLaunch')")
      row.launchStarted = nil
    end
    local quarter = racer and racer.timers and racer.timers.time_1_4
    local up = racer and racer.vehDirectionVectorUp
    local measured = not row.failureReason and quarter and quarter.isSet and type(quarter.value) == 'number' and quarter.value > 0
      and quarter.value < math.huge and up and type(up.z) == 'number' and up.z > .2 and up.z < math.huge
    local lane = measured and row.cooldownLane and serialize(row.cooldownLane) or ''
    vehicle:queueLuaCommand("extensions.load('overhaulMotorsportCooldown'); if not playerInfo.anyPlayerSeated then ai:scriptStop(true, false); ai.setMode('disabled'); if overhaulMotorsportCooldown.start(" .. lane .. ") then electrics.values.jatoInput = 0; input.event('throttle', 0, 2); input.event('brake', 0.8, 2); input.event('parkingbrake', 0, 2) end end")
  end
  row.braking, row.brakingSeconds = true, 0
  if racer then racer.isFinished, racer.currentPhase = true, #(racer.phases or {}) + 1 end
end

local function updateTimingBoard(row, racer)
  if row.timingBoardUpdated then return end
  local timer = racer and racer.timers and racer.timers.time_1_4
  local display = gameplay_drag_display
  if timer and timer.isSet and type(timer.value) == 'number' and timer.value > 0 and timer.value < math.huge
    and display and display.dragRaceEndLineReached then
    display.dragRaceEndLineReached(row.id)
    row.timingBoardUpdated = true
  end
end

local function updateNpcBrake(row, vehicle, dtSim)
  if not row.braking then return end
  row.brakingSeconds = row.brakingSeconds + dtSim
  local speed = vehicle:getVelocity():length()
  if speed < 1 and not row.parkingBrake then
    vehicle:queueLuaCommand("if not playerInfo.anyPlayerSeated then electrics.values.brakeOverride = 1; input.event('brake', 1, 2); input.event('parkingbrake', 1, 2) end")
    row.parkingBrake = true
  end
  row.stoppedSeconds = speed < 0.5 and (row.stoppedSeconds or 0) + dtSim or 0
  row.stopped = speed < 0.5
end

local function stopFailedNpc(row, racer, reason)
  if row.entrant.player or row.id == be:getPlayerVehicleID(0) or row.failureReason then return end
  row.failureReason = reason
  brakeNpc(row, racer)
  if racer then
    if not racer.isDisqualified and not racer.isDesqualified then
      racer.isDisqualified, racer.isDesqualified = true, true
      racer.disqualifiedReason, racer.desqualifiedReason = reason, reason
    end
    racer.isFinished, racer.currentPhase = true, #(racer.phases or {}) + 1
  end
end

local function installWinnerOrder()
  local extension = core().getExtension()
  if not extension or type(extension.generateWinData) ~= 'function' then return end
  winnerExtension, originalWinner = extension, extension.generateWinData
  local original = originalWinner
  winnerWrapper = function(data)
    local winners = original(data)
    if not session or data ~= core().getData() then return winners end
    local candidates = {}
    for _, row in ipairs(session.racers) do
      local racer = data.racers[row.id]
      if row.completedResult then
        local result = row.completedResult
        if result.nativeValid then
          candidates[#candidates + 1] = {entrantId = row.id, finishOrder = result.finishOrder, time = result.time, reaction = result.reaction}
        end
      elseif racer then
        finishOrder.observe(row, racer, finishSample + 1)
        local timer = racer.timers and racer.timers.time_1_4
        if timer and timer.isSet and timer.value > 0 and not racer.isDisqualified and not racer.isDesqualified and not racer.vehicleRemoved then
          candidates[#candidates + 1] = {entrantId = row.id, finishOrder = row.finishOrder, time = timer.value,
            reaction = racer.timers.reactionTime and racer.timers.reactionTime.value}
        end
      end
    end
    local winner = finishOrder.winner(candidates)
    for index, row in ipairs(winners or {}) do
      if row.vehId == winner then table.insert(winners, 1, table.remove(winners, index)); break end
    end
    return winners
  end
  extension.generateWinData = winnerWrapper
end

local function failStagingNpc(row, data)
  stopFailedNpc(row, data.racers[row.id], 'Did not stage')
  if not session.qualifying then
    for _, player in ipairs(session.racers) do
      if player.entrant.player then
        finish({walkover = true, winnerId = player.entrant.id, rows = {
          {entrantId = player.entrant.id, valid = true, nativeValid = false, walkover = true, reason = 'Opponent DNF'},
          {entrantId = row.entrant.id, valid = false, nativeValid = false, reason = 'Did not stage', nativeReason = 'Did not stage'},
        }})
        toast("Your opponent didn't stage. You win the heat.", 'good', 8)
        return
      end
    end
  end
  toast(session.qualifying and "Your opponent didn't stage. Your pass runs solo." or "A driver didn't stage.", 'info', 8)
end

function M.onUpdate(dtSim)
  if not session then
    if spectator.update then spectator.update(nil, 'idle', dtSim) end
    return
  end
  if spectator.update then spectator.update(session.racers, session.phase, dtSim, session.raceDirection) end
  if session.interrupted then finish({error = 'Pass interrupted. You can run it again.'}); return end
  if session.phase == 'armed' then
    local lane = M.getPlayerLane(session.stripId)
    if lane then
      local ok, err = begin(lane)
      if not ok then finish({error = err}) end
    end
    return
  end
  elapsed = elapsed + dtSim
  if session.phase == 'preparing' then return end
  local data = core().getData()
  if not data or not data.racers then finish({error = 'Pass interrupted. You can run it again.'}); return end
  if session.phase == 'racing' then staging.update(session.racers, data) end
  if session.phase == 'approaching' then
    local ready, err = approach.update(session.racers, dtSim)
    if err then finish({error = err}); return end
    if not ready then return end
    if approach.clear then approach.clear(session.racers) end
    for _, row in ipairs(session.racers) do
      core().setupRacer(row.id, row.lane)
      local racer = data.racers[row.id]
      if not racer then finish({error = 'Could not register both racers.'}); return end
      racer.isPlayable = row.entrant.player == true
      racer.niceName, racer.timers.dial.value = row.entrant.name, row.entrant.dial or 10
      skipNativeStop(row, racer)
    end
    if not originalStart(nil) then finish({error = 'Native drag race failed to start.'}); return end
    if ui_appContainers and ui_appContainers.hideApp and ui_appContainers.getAppVisibility then
      if ui_appContainers.getAppVisibility('topLeft', 'dragInfo') then ui_appContainers.hideApp('topLeft', 'dragInfo') end
      if ui_appContainers.getAppVisibility('topLeft', 'dragDialControl') then ui_appContainers.hideApp('topLeft', 'dragDialControl') end
    end
    session.phase, elapsed = 'racing', 0
    finishSample = 0
    installWinnerOrder()
    return
  end
  if session.phase == 'cooldown' then
    local stopped = true
    for _, row in ipairs(session.racers) do
      if not row.entrant.player and row.id ~= be:getPlayerVehicleID(0) then
        local vehicle = be:getObjectByID(row.id)
        if vehicle then
          local racer = data.racers[row.id]
          brakeNpc(row, racer)
          updateNpcBrake(row, vehicle, dtSim)
          if row.stopped or row.brakingSeconds >= MAX_NPC_STOP_SECONDS then vehicle:delete() else stopped = false end
        end
      end
    end
    if stopped then finish(session.result) end
    return
  end
  local ready, err = recovery.updateStaging(session.racers, data, dtSim, failStagingNpc)
  if not session then return end
  if err then finish({error = err}); return end
  for _, row in ipairs(session.racers) do
    local racer = data.racers[row.id]
    if racer then skipNativeStop(row, racer) end
  end
  if not ready then elapsed = 0; return end
  if not session.qualifying then
    session.incident = session.incident or {}
    local incident = interference.observe(session.incident, session.racers, data)
    if incident then
      for _, row in ipairs(session.racers) do
        if row.entrant.id == incident.offenderId then stopFailedNpc(row, data.racers[row.id], 'missions.dragRace.gameplay.disqualified.outOfLane') end
      end
      session.result, session.phase, elapsed = interference.result(incident), 'cooldown', 0
      return
    end
  end
  finishSample = finishSample + 1
  local finished, rows, anyValid = true, {}, false
  for _, row in ipairs(session.racers) do
    local racer = data.racers[row.id]
    if row.completedResult then
      local vehicle = not row.entrant.player and row.id ~= be:getPlayerVehicleID(0) and be:getObjectByID(row.id)
      if vehicle then
        updateNpcBrake(row, vehicle, dtSim)
        if row.stopped or row.brakingSeconds >= MAX_NPC_STOP_SECONDS then vehicle:delete() end
      end
      rows[#rows + 1] = row.completedResult
      anyValid = anyValid or row.completedResult.valid
    else
      local missing = not racer or not be:getObjectByID(row.id)
      if racer then row.nativeRacer = racer else racer = row.nativeRacer or {timers = {}} end
      if not missing then finishOrder.observe(row, racer, finishSample) end
      if not missing then updateTimingBoard(row, racer) end
      if not missing then qualifyingBoundary(row, racer, dtSim) end
      local timer = racer.timers[data.raceEndTimerId or 'time_1_4']
      local dq = racer.isDisqualified or racer.isDesqualified or racer.vehicleRemoved
      local reason = racer.disqualifiedReason or racer.desqualifiedReason or 'Disqualified'
      local redLightQualifier = session.qualifying and reason == 'missions.dragRace.gameplay.disqualified.jumping'
      local otherFoul = row.qualifyingOtherFoul or row.qualifyingBoundaryViolation and 'missions.dragRace.gameplay.disqualified.outOfLane'
      local terminal = missing or otherFoul or dq and not redLightQualifier
      if terminal then stopFailedNpc(row, racer, missing and 'Vehicle left the race' or otherFoul or reason) end
      local ended = terminal or timer and timer.isSet or racer.isFinished or elapsed >= 180
      if ended then brakeNpc(row, racer) end
      local vehicle = not row.entrant.player and row.id ~= be:getPlayerVehicleID(0) and be:getObjectByID(row.id)
      if vehicle then updateNpcBrake(row, vehicle, dtSim) end
      if not ended then updateNpcLaunch(row, racer); finished = false end
      local time = racer.timers.time_1_4 and racer.timers.time_1_4.value or 0
      local valid = not missing and not terminal and not dq and timer and timer.isSet and time > 0
      local nativeValid = valid == true
      local nativeReason = missing and 'Vehicle left the race' or dq and reason or otherFoul or not valid and 'Did not finish' or nil
      local reason, qualifyingRedLight = nativeReason, false
      local quarter = racer.timers.time_1_4
      if session.qualifying and nativeReason == 'missions.dragRace.gameplay.disqualified.jumping' then
        local present = not racer.vehicleRemoved and racer.vehId and be:getObjectByID(row.id)
        qualifyingRedLight = present and quarter and quarter.isSet and time > 0 and time < math.huge
          and row.qualifyingBoundaryKnown and not row.qualifyingBoundaryUnknown and not row.qualifyingBoundaryViolation
          and row.qualifyingTelemetryKnown and not row.qualifyingTelemetryUnknown and not row.qualifyingOtherFoul
        if qualifyingRedLight then valid, reason = true, nil
        elseif row.qualifyingBoundaryViolation then reason = 'missions.dragRace.gameplay.disqualified.outOfLane'
        elseif row.qualifyingOtherFoul then reason = row.qualifyingOtherFoul end
      end
      anyValid = anyValid or valid
      local result = {entrantId = row.entrant.id, time = time, finishOrder = row.finishOrder,
        reaction = racer.timers.reactionTime and racer.timers.reactionTime.value or 0,
        valid = valid == true, reason = reason, nativeValid = nativeValid, nativeReason = nativeReason,
        retired = not session.qualifying and ended and not valid and reason ~= 'missions.dragRace.gameplay.disqualified.jumping' or nil,
        qualifyingRedLight = qualifyingRedLight == true, boundaryViolation = row.qualifyingBoundaryViolation == true,
        qualifyingFoulReason = row.qualifyingOtherFoul}
      rows[#rows + 1] = result
      if ended then
        row.completedResult = result
        if vehicle and row.stopped then vehicle:delete() end
      end
    end
  end
  if not finished then return end
  local winnerId
  if anyValid and #rows > 1 then
    local candidates = {}
    for _, row in ipairs(rows) do if row.valid then candidates[#candidates + 1] = row end end
    winnerId = finishOrder.winner(candidates)
  end
  session.result = {rows = rows, winnerId = winnerId}
  session.phase, elapsed = 'cooldown', 0
end

function M.onDragClear()
  if session and not clearing then session.interrupted = true end
end

function M.shutdown()
  M.setWatching(false)
  M.stop()
  if patchRegistered then overhaul_shell_patches.unregister('motorsportDragStart') end
  patchRegistered = nil
  startWrapper, originalStart = nil, nil
  FS:removeFile(RUNTIME_FILE)
end

return M
