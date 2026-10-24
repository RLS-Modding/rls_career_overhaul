-- Starts a taxi ride straight to the destination already set on the map, instead of asking again in big map mode.
-- Wraps the big map's enterBigMap through the shell patch registry; the wrapper falls back to the stock call.
local M = {}
M.dependencies = {'overhaul_shell_patches', 'freeroam_bigMapMode'}

local PATCH_ID = 'taxiExistingDestination'
local ARRIVED_DISTANCE_M = 12

local function vecFromWaypoint(waypoint)
  if waypoint == nil then return nil end
  if waypoint.x and waypoint.y then
    return vec3(waypoint.x, waypoint.y, waypoint.z or 0)
  end
  if type(waypoint) == "string" then
    local nodes = map.getMap() and map.getMap().nodes
    local node = nodes and nodes[waypoint]
    return node and node.pos and vec3(node.pos) or nil
  end
  if type(waypoint) == "table" and waypoint[1] and waypoint[2] then
    return vec3(waypoint[1], waypoint[2], waypoint[3] or 0)
  end
  return nil
end

local function getExistingNavDestination()
  local groundMarkers = core_groundMarkers
  if not groundMarkers then return nil end
  if groundMarkers.currentlyHasTarget and not groundMarkers.currentlyHasTarget() then
    return nil
  end
  local endWaypoints = groundMarkers.endWP
  if type(endWaypoints) == "table" and endWaypoints[1] then
    return vecFromWaypoint(endWaypoints[#endWaypoints]) or vecFromWaypoint(endWaypoints[1])
  end
  if groundMarkers.getTargetPos then
    return vecFromWaypoint(groundMarkers.getTargetPos())
  end
  return nil
end

-- Already at the destination: let the stock big map open so the player can pick a new one.
local function isPlayerAt(destination)
  local playerVeh = be:getPlayerVehicle(0)
  if not playerVeh then return false end
  local here = playerVeh:getPosition()
  return here and here.distance and here:distance(destination) < ARRIVED_DISTANCE_M or false
end

local function startRoute(taxi)
  if taxi.startTaxiWithCurrentRoute then
    taxi.startTaxiWithCurrentRoute()
  elseif taxi.confirmTaxiDestination then
    taxi.confirmTaxiDestination()
  else
    return false
  end
  return true
end

local function tryConfirmExistingTaxiDestination()
  local destination = getExistingNavDestination()
  local taxi = overhaul_integration_services_taxi
  if not destination or not taxi then return false end
  if not taxi.onSetBigmapNavFocus then return false end
  if isPlayerAt(destination) then return false end
  taxi.onSetBigmapNavFocus(destination)
  return startRoute(taxi)
end

local function wrapEnterBigMap(original)
  if type(original) ~= 'function' then return end
  return function(opts, ...)
    if opts and opts.mode == 'taxi' and tryConfirmExistingTaxiDestination() then
      return
    end
    return original(opts, ...)
  end
end

function M.onExtensionLoaded()
  overhaul_shell_patches.registerFields(PATCH_ID, function() return rawget(_G, 'freeroam_bigMapMode') end, {
    enterBigMap = wrapEnterBigMap,
  })
end

function M.onExtensionUnloaded()
  if overhaul_shell_patches then overhaul_shell_patches.unregister(PATCH_ID) end
end

M.getExistingNavDestination = getExistingNavDestination

return M
