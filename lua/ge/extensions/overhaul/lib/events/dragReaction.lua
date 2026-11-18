-- Release owned AI before the real tree green; native countdown still owns fouls and clocks.
local M = {}
local TUNING_FILE = 'gameplay/overhaul/events/drag.json'
local DEFAULT_ADVANCE_MS = 150
-- A pro tree shows amber 400 ms before green; never release before amber.
local MAX_ADVANCE_MS = 400

local function launchAdvanceSeconds()
  local manifest = type(jsonReadFile) == 'function' and jsonReadFile(TUNING_FILE)
  local ms = type(manifest) == 'table' and manifest.aiLaunchAdvanceMs
  if type(ms) == 'number' and ms >= 0 and ms < MAX_ADVANCE_MS then return ms / 1000 end
  if type(log) == 'function' then
    log('W', 'dragReaction', 'Invalid aiLaunchAdvanceMs at ' .. TUNING_FILE .. '; using ' .. DEFAULT_ADVANCE_MS)
  end
  return DEFAULT_ADVANCE_MS / 1000
end

local function release(racer, lane)
  local vehicle = racer.vehObj
  vehicle:queueLuaCommand("extensions.unload('overhaulMotorsportStagingHold')")
  vehicle:queueLuaCommand('if electrics.values.jatoInput then electrics.values.jatoInput = 1 end')
  vehicle:queueLuaCommand([[
    local tb = controller.getController('transbrake')
    if tb then tb.toggleTransbrake() else controller.setFreeze(0) end
  ]])
  vehicle:queueLuaCommand('electrics.values.throttleOverride = 1')
  racer._aiThrottle = 1
  local finish = lane.waypoints.endLine
  vehicle:queueLuaCommand('ai.setSpeed(' .. finish.waypoint.speed .. ')')
  vehicle:queueLuaCommand('ai.setSpeedMode(' .. string.format('%q', finish.waypoint.mode) .. ')')
  vehicle:queueLuaCommand('ai.setTarget(' .. string.format('%q', finish.name) .. ')')
  racer.rlsReactionReleased = true
end

function M.attach(data)
  local handler = gameplay_drag_phaseHandlers
  if not handler or type(handler.race) ~= 'function' or type(handler.countdown) ~= 'function' then
    return function() end
  end
  local originalRace, originalCountdown = handler.race, handler.countdown
  local active, launches = true, {}
  local advanceSeconds = launchAdvanceSeconds()
  local function owns(racer)
    return active and gameplay_drag_core.getData() == data and data.racers
      and data.racers[racer.vehId] == racer and not racer.isPlayable
  end
  local function countdown(phase, racer, dt)
    if owns(racer) and not phase.started then
      launches[racer] = nil
      racer.rlsReactionReleased, racer.rlsLaunchAdvanceSeconds = nil, nil
    end
    local result = originalCountdown(phase, racer, dt)
    if not owns(racer) or phase.completed or not phase.started or not racer.treeStarted
      or racer.isDisqualified or racer.isDesqualified or racer.vehicleRemoved or not racer.vehObj
      or not racer.inLane then return result end
    local lights = data.strip.treeLights and data.strip.treeLights[racer.lane]
    local timers = lights and lights.timers
    if not timers or not timers.laneTimer or (timers.dialOffset or 0) > 0 then return result end
    local treeType = data.prefabs and data.prefabs.christmasTree and data.prefabs.christmasTree.treeType or '.500'
    local greenAt = 2.5
    if treeType == '.400' then
      -- Pro trees randomize amber onset. Follow this lane's actual amber (one update precision).
      if not timers.laneTimerFlag then return result end
      launches[racer] = launches[racer] or timers.laneTimer
      local drag = gameplay_drag_core.getDragGamemode and gameplay_drag_core.getDragGamemode()
      local synced = drag and drag.getSynchronizedRandValue and drag.getSynchronizedRandValue()
      greenAt = (synced or launches[racer]) + .4
    end
    if not racer.rlsReactionReleased and timers.laneTimer >= greenAt - advanceSeconds then
      release(racer, data.strip.lanes[racer.lane])
      racer.rlsLaunchAdvanceSeconds = advanceSeconds
      racer.rlsReleaseTreeTime = timers.laneTimer
      -- Do not finish countdown or start race clocks early. Native beam checks may red-light us.
    end
    return result
  end
  local function race(phase, racer, dt)
    if owns(racer) and not phase.started and not phase.completed and not racer.vehicleRemoved
      and racer.vehObj and racer.inLane then
      -- If a tree was unavailable, launch at green without adding a random wait.
      if not racer.rlsReactionReleased then release(racer, data.strip.lanes[racer.lane]) end
      phase.started = true
      extensions.hook('dragRaceStarted', racer.vehId)
    end
    return originalRace(phase, racer, dt)
  end
  handler.countdown, handler.race = countdown, race
  return function()
    active = false
    launches = {}
    if handler.race == race then handler.race = originalRace end
    if handler.countdown == countdown then handler.countdown = originalCountdown end
  end
end

return M
