-- GE API: returnTargetPosition(target, race, speedMode, noTraffic), driveExactPath(routePoints, target, targetDir, options), cancelExactPathAssist().
-- returnTargetPosition returns true only after navigation creates the requested route.
-- Owns exact-path steering assistance; read target helpers, path control, then public actions/updateGFX.
local M = {}
local exactPath = require("common/overhaul/exactPath")

local destination = nil

local drivability = 0
local dirMult = 10000
local penaltyAboveCutoff = 1000
local penaltyBelowCutoff = 100000
local wZ = 1
local exactPathReleaseTimer = 0

local function onExtensionLoaded()
    if not mapmgr.mapData then
        mapmgr.requestMap()
    end
end

local function updateGFX(dt)
    if exactPathReleaseTimer <= 0 then
        return
    end

    exactPathReleaseTimer = math.max(0, exactPathReleaseTimer - (dt or 0))
    -- The scripted-path reset can reapply brakes or ignition, so release them after initialization too.
    if electrics and electrics.setIgnitionLevel then
        electrics.setIgnitionLevel(3)
    end
    input.event("parkingbrake", 0, 1)
end

-- Stop the post-exact-path ignition/PB release assist (auction arrive hold).
local function cancelExactPathAssist()
    exactPathReleaseTimer = 0
end

local function goToTarget(speedMode, noTraffic)
    local path = mapmgr.getPointToPointPath(
        obj:getPosition(),
        destination,
        drivability,
        dirMult,
        penaltyAboveCutoff,
        penaltyBelowCutoff,
        wZ
    )
    if not path or #path < 2 then return false end
    table.remove(path, 1)
    ai.setPath(path)
    if noTraffic then
        ai.driveUsingPath({
            wpTargetList = path,
            avoidCars = "on",
            driveInLane = "on",
            routeSpeedMode = speedMode or 'legal'
        })
        ai.setParameters({
            lookAheadKv = 0.03,
            awarenessForceCoef = 0.1,
        })
    else
        ai.driveUsingPathWithTraffic({
            wpTargetList = path,
            routeSpeedMode = speedMode or 'legal'
        })
        ai.setParameters({
            trafficWaitTime = 0.005,
            lookAheadKv = 0.01,
            awarenessForceCoef = 0.02, 
            driveStyle = "offRoad"
        })
    end
    return ai.createPendingRoute() and ai.mode == (noTraffic and 'manual' or 'manualTraffic')
end

local function raceToTarget()
    local path = mapmgr.getPointToPointPath(
        obj:getPosition(),
        destination,
        drivability,
        dirMult,
        penaltyAboveCutoff,
        penaltyBelowCutoff,
        wZ
    )
    if not path or #path < 2 then return false end
    table.remove(path, 1)
    ai.setPath(path)
    ai.setMode("manual")
    ai.setAvoidCars("on")
    ai.setSpeedMode("off")
    ai.driveInLane("on")
    ai.setParameters({
        lookAheadKv = 0.03,
        awarenessForceCoef = 0.1,
    })
    return ai.createPendingRoute() and ai.mode == 'manual'
end

local function returnTargetPosition(target, race, speedMode, noTraffic)
    destination = target
    if race then
        return raceToTarget()
    else
        return goToTarget(speedMode, noTraffic)
    end
end

-- AI scripts follow the front reference; offset the trajectory so the vehicle origin stops on the target.
local function buildExactPathScript(routePoints, options, pathRadius, targetPos, finalDir)
  local finalUp = options.targetUp and vec3(options.targetUp) or vec3(0, 0, 1)
  finalUp:normalize()

  local frontRel = obj:getOriginalFrontPositionRelative()
  local frontOffset =
      finalDir * (-frontRel.y) +
      finalUp * frontRel.z +
      finalDir:cross(finalUp) * (-frontRel.x)

  local currentFront = obj:getFrontPosition()
  local currentDir = obj:getDirectionVector()
  local currentUp = obj:getDirectionVectorUp()
  local script = {
      {
          x = currentFront.x,
          y = currentFront.y,
          z = currentFront.z,
          dir = {x = currentDir.x, y = currentDir.y, z = currentDir.z},
          up = {x = currentUp.x, y = currentUp.y, z = currentUp.z},
          r = pathRadius
      }
  }

  for _, point in ipairs(exactPath.points(routePoints, targetPos, finalDir, options)) do
      local offset = point.terminal and frontOffset or vec3(0, 0, 0)
      table.insert(script, {
          x = point.x + offset.x,
          y = point.y + offset.y,
          z = point.z + offset.z,
          r = pathRadius,
          v = point.v
      })
  end
  return script
end

local function driveExactPath(routePoints, target, targetDir, options)
    if type(routePoints) ~= "table" or not target or not targetDir then
        return false
    end

    options = type(options) == "table" and options or {}
    local routeSpeed = tonumber(options.routeSpeed) or 4.4352
    local pathRadius = math.max(0.05, tonumber(options.pathRadius) or 0.1)
    local aggression = tonumber(options.aggression) or 0.3

    local targetPos = vec3(target)
    local finalDir = vec3(targetDir):z0()
    if finalDir:squaredLength() < 0.01 then
        return false
    end
    finalDir:normalize()

    local script = buildExactPathScript(routePoints, options, pathRadius, targetPos, finalDir)

    if #script < 3 then
        return false
    end

    if electrics and electrics.setIgnitionLevel then
        electrics.setIgnitionLevel(3)
    end
    input.event("brake", 0, 1)
    input.event("parkingbrake", 0, 1)
    ai.driveUsingPath({
        script = script,
        routeSpeed = routeSpeed,
        routeSpeedMode = "limit",
        aggression = aggression,
        avoidCars = options.avoidCars or "off"
    })
    exactPathReleaseTimer = 1
    return true
end

local function driveToTarget(drivability, dirMult, penaltyAboveCutoff, penaltyBelowCutoff, wZ)
    drivability = drivability or 0
    dirMult = dirMult or 10000
    penaltyAboveCutoff = penaltyAboveCutoff or 1000
    penaltyBelowCutoff = penaltyBelowCutoff or 100000
    wZ = wZ or 1

    obj:queueGameEngineLua([[
        local target = core_groundMarkers.getTargetPos()
        local obj = getObjectByID("]] .. obj:getID() .. [[")
        obj:queueLuaCommand("overhaulDriver.returnTargetPosition(" .. serialize(target) .. ")")
    ]])
end

local function driveFastToTarget(drivability, dirMult, penaltyAboveCutoff, penaltyBelowCutoff, wZ)
    drivability = drivability or 0.1
    dirMult = dirMult or 1
    penaltyAboveCutoff = penaltyAboveCutoff or 1
    penaltyBelowCutoff = penaltyBelowCutoff or 1
    wZ = wZ or 1

    obj:queueGameEngineLua([[
        local target = core_groundMarkers.getTargetPos()
        local obj = getObjectByID("]] .. obj:getID() .. [[")
        obj:queueLuaCommand("overhaulDriver.returnTargetPosition(" .. serialize(target) .. ", true)")
    ]])
end



M.driveToTarget = driveToTarget
M.driveFastToTarget = driveFastToTarget
M.returnTargetPosition = returnTargetPosition
M.driveExactPath = driveExactPath
M.cancelExactPathAssist = cancelExactPathAssist
M.onExtensionLoaded = onExtensionLoaded
M.updateGFX = updateGFX

return M
