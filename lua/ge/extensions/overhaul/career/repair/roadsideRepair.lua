-- Roadside repair: destinations, arrival checks and service access.
-- The activity descriptor delegates to the extension load that owns the active repair request.
local M = {}

local MARKER_ICON = "poi_garage_2_round"
local RAY_UP = 3
local RAY_DOWN = 40
local MIN_PAD_WIDTH = 2.0
local MIN_PAD_LENGTH = 3.5
local MIN_PAD_HEIGHT = 2.0
local OPENING_TIMEOUT_S = 10

local opening = false
-- updatePartConditions has no timeout if the vehicle is deleted, so each open gets a token.
local openingToken = 0
local activeTriggerName = nil

local function resolveInventoryId(subjectId)
  local inventory = overhaul_career_garage_inventory
  local invId = inventory.getCurrentVehicle()
  if invId then
    return invId
  end
  if subjectId then
    return inventory.getInventoryIdFromVehicleId(subjectId)
  end
  local playerVehId = be:getPlayerVehicleID(0)
  if playerVehId and playerVehId > 0 then
    return inventory.getInventoryIdFromVehicleId(playerVehId)
  end
  return nil
end

-- Only owned vehicles and the service's own loaner types can use a spot.
local function isServiceableVehicle(vehicle)
  if not vehicle or vehicle.owned ~= false then return true end
  local loanType = vehicle.loanType
  return loanType == "work" or loanType == "company" or loanType == "rental"
end

-- Gives up on the open if the part-condition reply never comes back.
local function armOpeningTimeout(token)
  core_jobsystem.create(function(job)
    job.sleep(OPENING_TIMEOUT_S)
    if opening and token == openingToken then
      opening = false
      openingToken = openingToken + 1
      log("W", "roadsideRepair", "tryOpenService: part condition request timed out")
      ui_message("Roadside Service could not inspect the vehicle. Try again.", 5, "Roadside Service", "info")
    end
  end)
end

local function showMenu(invId, triggerName)
  overhaul_career_repair_roadsideService.openMenu(invId, triggerName or activeTriggerName)
end

-- Runs once the part conditions are fresh; a superseded open does nothing.
local function onPartConditionsReady(token, invId, triggerName)
  if token ~= openingToken then
    return
  end
  opening = false
  local vehicle = overhaul_career_garage_inventory.getVehicles()[invId]
  if not vehicle then
    return
  end
  showMenu(invId, triggerName)
end

local function tryOpenService(subjectId, triggerName)
  if opening then
    return
  end
  if not overhaul_career_career.isActive() then
    return
  end

  if not overhaul_career_repair_roadsideService.loadConfig().spots[triggerName] then
    log("W", "roadsideRepair", "Service trigger is not configured: " .. tostring(triggerName))
    return
  end

  local invId = resolveInventoryId(subjectId)
  if not invId then
    ui_message("Enter a player or loaner vehicle to use Roadside Service.", 5, "Roadside Service", "info")
    return
  end

  local vehicle = overhaul_career_garage_inventory.getVehicles()[invId]
  if not isServiceableVehicle(vehicle) then
    ui_message("This vehicle cannot be serviced here.", 5, "Roadside Service", "info")
    return
  end

  opening = true
  openingToken = openingToken + 1
  local token = openingToken
  armOpeningTimeout(token)
  overhaul_career_garage_inventory.updatePartConditions(nil, invId, function()
    onPartConditionsReady(token, invId, triggerName)
  end)
end

-- Ground level under the trigger, found by a short ray down from above it.
local function groundPosFromTrigger(obj)
  local pos = obj:getPosition()
  local start = vec3(pos.x, pos.y, pos.z + RAY_UP)
  local hit = castRayStatic(start, vec3(0, 0, -1), RAY_DOWN)
  if hit and hit < RAY_DOWN then
    return vec3(pos.x, pos.y, start.z - hit + 0.02)
  end
  return vec3(pos.x, pos.y, pos.z)
end

-- The horizontal part of an axis, or the fallback when the axis is missing or vertical.
local function flattenAxis(axis, fallback)
  if not axis then
    return fallback
  end
  local flat = vec3(axis.x, axis.y, 0)
  if flat:length() > 0.001 then
    return flat:normalized()
  end
  return fallback
end

-- Pad direction and size: the long side of the trigger is the drive-in direction.
local function padFrameFromTrigger(obj)
  local scl = obj.getScale and obj:getScale() or nil
  local sx = math.abs((scl and scl.x) or 3)
  local sy = math.abs((scl and scl.y) or 6)
  local sz = math.abs((scl and scl.z) or 2)

  local axisX, axisY
  if obj.getTransform then
    local tf = obj:getTransform()
    if tf and tf.getColumn then
      axisX = tf:getColumn(0)
      axisY = tf:getColumn(1)
    end
  end
  if not axisY and obj.getDirectionVector then
    axisY = obj:getDirectionVector()
  end
  if not axisX and axisY and obj.getDirectionVectorUp then
    local up = obj:getDirectionVectorUp()
    if up then
      axisX = up:cross(axisY)
    end
  end

  local xFlat = flattenAxis(axisX, vec3(1, 0, 0))
  local yFlat = flattenAxis(axisY, vec3(0, 1, 0))

  local forward, width, length
  if sx >= sy then
    forward = xFlat
    width = sy
    length = sx
  else
    forward = yFlat
    width = sx
    length = sy
  end

  if forward:length() < 0.001 then
    forward = vec3(0, 1, 0)
  else
    forward = forward:normalized()
  end

  return forward, vec3(math.max(width, MIN_PAD_WIDTH), math.max(length, MIN_PAD_LENGTH), math.max(sz, MIN_PAD_HEIGHT))
end

-- Configured triggers are the complete discovery list; unrelated scene names never add services.
local function collectRepairTriggerNames()
  local names = {}
  for name in pairs(overhaul_career_repair_roadsideService.loadConfig().spots) do names[#names + 1] = name end
  table.sort(names)
  return names
end

local function onGetRawPoiListForLevel(levelIdentifier, elements)
  if not overhaul_career_career.isActive() then
    return
  end
  for _, name in ipairs(collectRepairTriggerNames()) do
    local obj = scenetree.findObject(name)
    if obj then
      local pos = groundPosFromTrigger(obj)
      local forward, scale = padFrameFromTrigger(obj)
      -- Share the service menu's configured name and fallback for every map.
      local label = overhaul_career_repair_roadsideService.getSpotConfig(name).name
      table.insert(elements, {
        id = "roadsideService-" .. name,
        data = {
          type = "repairSpot",
          triggerName = name,
          name = label,
        },
        markerInfo = {
          parkingMarker = {
            path = "roadsideService#" .. name,
            pos = pos,
            rot = quatFromDir(forward, vec3(0, 0, 1)),
            scl = scale,
            icon = MARKER_ICON,
          },
          bigmapMarker = {
            pos = pos,
            icon = MARKER_ICON,
            name = label,
            description = "Park here to service your vehicle.",
            cardIcon = "wrench",
          },
        },
      })
    else
      log("W", "roadsideRepair", "Configured roadside trigger unavailable: " .. name)
    end
  end
end

local function onActivityAcceptGatherData(elemData, activityData)
  for _, elem in ipairs(elemData or {}) do
    if elem.type == "repairSpot" then
      local triggerName = elem.triggerName
      table.insert(activityData, {
        icon = MARKER_ICON,
        heading = elem.name or "Roadside Service",
        preheadings = {"Roadside Service"},
        buttonLabel = "Service your vehicle",
        buttonFun = function()
          activeTriggerName = triggerName
          tryOpenService(nil, triggerName)
        end,
        sorting = {
          type = elem.type,
          id = triggerName,
        },
      })
    end
  end
end

M.onGetRawPoiListForLevel = onGetRawPoiListForLevel
M.onActivityAcceptGatherData = onActivityAcceptGatherData
M.openService = tryOpenService

M.activity = require('overhaul/career/repair/roadsideRepair/activity')()

return M
