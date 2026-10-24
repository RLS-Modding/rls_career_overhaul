-- Facility truck road scripts, stopping and navigation.
-- Queued vehicle commands retain their argument order and text.
local truckCommands = require('overhaul/lib/jobs/truckCommands')
return function(core_groundMarkers, toVec3)
  local function setNavigationPath(targetPos)
    if not core_groundMarkers or not core_groundMarkers.setPath then return end
    if targetPos then
      core_groundMarkers.setPath(toVec3(targetPos), { clearPathOnReachingTarget = false })
    else
      core_groundMarkers.setPath(nil)
    end
  end

  local function resolveDropTriggers(triggerNames)
    local out = {}
    if not triggerNames or type(triggerNames) ~= "table" then return out end
    for _, name in ipairs(triggerNames) do
      if type(name) == "string" and name ~= "" then
        local obj = scenetree.findObject(name)
        if obj and obj.getId then
          out[name] = obj
        end
      end
    end
    return out
  end

  local function getRoadNodes(roadName)
    if not roadName or roadName == "" then return nil end
    local road = scenetree.findObject(roadName)
    if not road or (road.getClassName and road:getClassName() ~= "DecalRoad") then return nil end
    local nodeCount = (road.getNodeCount and road:getNodeCount()) or 0
    if not nodeCount or nodeCount < 1 then return nil end
    local nodes = {}
    for i = 0, nodeCount - 1 do
      local pos = road:getNodePosition(i)
      if pos then
        table.insert(nodes, { x = pos.x, y = pos.y, z = pos.z })
      end
    end
    return #nodes > 0 and nodes or nil
  end

  local function buildScriptPath(nodes, fromIdx, toIdx)
    if not nodes or fromIdx < 1 or toIdx > #nodes or fromIdx > toIdx then return nil end
    local script = {}
    for i = fromIdx, toIdx do
      local n = nodes[i]
      if n then
        local x = n.x or n[1] or 0
        local y = n.y or n[2] or 0
        local z = n.z or n[3] or 0
        table.insert(script, { x = x, y = y, z = z })
      end
    end
    return #script > 0 and script or nil
  end

  local function serializeScriptPath(script)
    if not script or #script == 0 then return "{}" end
    local parts = {}
    for _, p in ipairs(script) do
      local x = p.x or p[1] or 0
      local y = p.y or p[2] or 0
      local z = p.z or p[3] or 0
      table.insert(parts, string.format("{x=%s,y=%s,z=%s}", x, y, z))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end

  local function sendTruckDriveScript(vehObj, scriptPath, opts)
    if not vehObj or not scriptPath or #scriptPath == 0 then return end
    local serialized = (type(serialize) == "function" and serialize(scriptPath)) or serializeScriptPath(scriptPath)
    local optStr = (opts and opts.startFromCurrentPosition) and ", startFromCurrentPosition = true" or ""
    vehObj:queueLuaCommand("if not ai then extensions.load('ai') end")
    vehObj:queueLuaCommand("input.event('parkingbrake', 0, 1)")
    vehObj:queueLuaCommand("if ai.setAvoidCars then ai.setAvoidCars('off') end")
    vehObj:queueLuaCommand("ai.driveUsingPath({ script = " .. serialized .. ", avoidCars = 'off', routeSpeedMode = 'limit', routeSpeed = 14, aggression = 0.2" .. optStr .. " })")
  end

  local function sendTruckStop(vehObj)
    if not vehObj then return end
    vehObj:queueLuaCommand("if ai and ai.setMode then ai.setMode('stop') end")
    vehObj:queueLuaCommand("input.event('parkingbrake', 1, 1)")
  end

  -- Drive from current position to target (no teleport). Used for exit leg to avoid script-path jump.
  local function sendTruckDriveToPosition(vehObj, targetPos)
    if not vehObj or not targetPos then return end
    local x = targetPos.x or targetPos[1] or 0
    local y = targetPos.y or targetPos[2] or 0
    local z = targetPos.z or targetPos[3] or 0
    -- Pass vec3(...) so driver gets same type as loading (getPointToPointPath expects vec3, not table)
    local posStr = string.format("vec3(%s,%s,%s)", x, y, z)
    print("[facilityWork] truck AI: sendTruckDriveToPosition exit target " .. string.format("%.1f, %.1f, %.1f", x, y, z))
    vehObj:queueLuaCommand('if not overhaulDriver then extensions.load("overhaulDriver") end')
    vehObj:queueLuaCommand("input.event('parkingbrake', 0, 1)")
    vehObj:queueLuaCommand("if ai and ai.setPullOver then ai.setPullOver(false) end")
    -- Leave stop mode so driver's path is followed (overhaulAi in stop mode never applies throttle)
    vehObj:queueLuaCommand("if ai and ai.setMode then ai.setMode('manual') end")
    core_jobsystem.create(function(job)
      job.sleep(0.5)
      print("[facilityWork] truck AI: queueing setAvoidCars off and overhaulDriver.returnTargetPosition")
      vehObj:queueLuaCommand("if ai.setAvoidCars then ai.setAvoidCars('off') end")
      job.sleep(0.1)
      vehObj:queueLuaCommand(truckCommands.returnTargetPosition(posStr))
    end)
  end

  return {buildScriptPath = buildScriptPath, getRoadNodes = getRoadNodes,
    resolveDropTriggers = resolveDropTriggers, sendTruckDriveScript = sendTruckDriveScript,
    sendTruckDriveToPosition = sendTruckDriveToPosition, sendTruckStop = sendTruckStop,
    setNavigationPath = setNavigationPath}

end
