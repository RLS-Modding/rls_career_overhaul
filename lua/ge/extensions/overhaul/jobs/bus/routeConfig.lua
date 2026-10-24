-- Bus route files, scene stops, random route selection and loaner revenue shares.
-- Read loaner policy and file lookup, scene discovery, route selection and ordered route construction.
local capabilities = require('overhaul/lib/platform/capabilities')

return function()
  local function calculateLoanerCut(vehId)
    if not vehId then
      return 0
    end

    if not overhaul_career_career.isActive() then
      return 0
    end

    local loaningOrgs = capabilities.get('vehicleLoans').getLoaningOrgsOfVehicle(vehId)
    if not loaningOrgs or not next(loaningOrgs) then
      return 0
    end

    local totalCut = 0
    for organizationId, _ in pairs(loaningOrgs) do
      local organization = overhaul_world_organizations.getOrganization(organizationId)
      if organization and organization.reputation and organization.reputationLevels then
        local level = organization.reputation.level
        local levelIndex = level + 2
        if organization.reputationLevels[levelIndex] and organization.reputationLevels[levelIndex].loanerCut then
          local orgCut = organization.reputationLevels[levelIndex].loanerCut.value or 0.5
          totalCut = totalCut + orgCut
        end
      end
    end

    return math.min(totalCut, 1.0)
  end

  -- Keep filename search order so existing map route files retain their precedence.
  local function loadRoutesFromJSON()
    local currentMap = getCurrentLevelIdentifier()
    log('D', 'bus', string.format("Current map identifier: %s", tostring(currentMap)))
    if not currentMap then
      log('D', 'bus', "No current map identifier found")
      return nil
    end

    local possibleFiles = {string.format("/levels/%s/%sBusRoutes.json", currentMap, currentMap:gsub("_", "")),
                string.format("/levels/%s/busRoutes.json", currentMap),
                string.format("/levels/%s/%s_bus_routes.json", currentMap, currentMap)}

    local shortPrefix = currentMap:gsub("([^_])[^_]*_?", "%1")

    if #shortPrefix > 1 and shortPrefix ~= currentMap then
      table.insert(possibleFiles, 1, string.format("/levels/%s/%sBusRoutes.json", currentMap, shortPrefix))
    end

    local routeFile = nil
    for _, path in ipairs(possibleFiles) do
      if FS:fileExists(path) then
        routeFile = path
        break
      end
    end

    if not routeFile then
      log('D', 'bus', string.format("No route file found for map: %s", currentMap))
      log('D', 'bus', string.format("Searched paths: %s", table.concat(possibleFiles, ", ")))
      return nil
    end

    log('D', 'bus', string.format("Loading route file: %s", routeFile))
    local routeData = jsonReadFile(routeFile)
    if not routeData then
      log('D', 'bus', string.format("Failed to read route file: %s", routeFile))
      return nil
    end
    if not routeData.routes then
      log('D', 'bus', string.format("Route file %s does not contain 'routes' key", routeFile))
      return nil
    end

    log('D', 'bus', string.format("Successfully loaded routes from %s", routeFile))
    return routeData.routes
  end

  local function collectScenetreeObjects()
    local allTriggers = {}
    local allWaypoints = {}

    -- Ignore unresolvable scene names so partially mounted maps expose their remaining stops.
    local function processObject(obj)
      local objRef = type(obj) == "string" and scenetree.findObject(obj) or obj
      if not objRef then
        return
      end
      local name = objRef:getName() or ""
      if name:match("_bs_%d+$") or name:match("_bs_%d+_b$") then
        allTriggers[name] = objRef
      elseif name:match("_wp_") or name:match("_waypoint_") then
        allWaypoints[name] = objRef
      end
    end

    for _, obj in ipairs(scenetree.findClassObjects("BeamNGTrigger") or {}) do
      processObject(obj)
    end

    for _, obj in ipairs(scenetree.findClassObjects("BeamNGWaypoint") or {}) do
      processObject(obj)
    end

    for _, obj in ipairs(scenetree.findClassObjects("SimObject") or {}) do
      processObject(obj)
    end

    return allTriggers, allWaypoints
  end

  -- Choose from the same unordered route table without adding another random draw.
  local function selectRandomRoute(routes)
    local routeKeys = {}
    for k in pairs(routes) do
      table.insert(routeKeys, k)
    end
    if #routeKeys == 0 then
      return nil, nil
    end

    local selectedRouteKey = routeKeys[math.random(#routeKeys)]
    local selectedRoute = routes[selectedRouteKey]
    return selectedRoute, selectedRouteKey
  end

  -- Preserve input order and preceding stop indices while skipping only missing scene objects.
  local function routeItemNames(stopData)
    local itemType = "stop"
    local stopName, displayName

    if type(stopData) == "table" then
      if stopData[1] == "wp" then
        itemType = "waypoint"
        stopName = stopData[2]
        displayName = stopData[3]
      else
        stopName = stopData[1]
        displayName = stopData[2]
        if stopName:match("_wp_") or stopName:match("_waypoint_") then
          itemType = "waypoint"
        end
      end
    elseif type(stopData) == "string" then
      stopName = stopData
      displayName = stopData
      if stopName:match("_wp_") or stopName:match("_waypoint_") then
        itemType = "waypoint"
      end
    end
    return itemType, stopName, displayName
  end

  local function buildRouteFromConfig(selectedRoute, allTriggers, allWaypoints)
    local triggers = {}
    local items = {}
    local displayNames = {}
    local missingStops = {}
    local missingWaypoints = {}
    local stopIndex = 0

    for _, stopData in ipairs(selectedRoute.stops) do
      local itemType, stopName, displayName = routeItemNames(stopData)

      if itemType == "waypoint" then
        local waypointObj = allWaypoints[stopName]
        if waypointObj then
          local waypointPos = waypointObj:getPosition()
          table.insert(items, {
            type = "waypoint",
            waypointName = stopName,
            position = waypointPos,
            precedingStopIndex = stopIndex
          })
          if displayName then
            displayNames[stopName] = displayName
          end

        else
          table.insert(missingWaypoints, stopName)
          log('D', 'bus', string.format("Waypoint '%s' not found - skipping (will navigate directly to next stop)", stopName))
        end
      else
        local trigger = allTriggers[stopName]
        if trigger then
          stopIndex = stopIndex + 1
          table.insert(triggers, trigger)
          table.insert(items, {
            type = "stop",
            trigger = trigger,
            position = trigger:getPosition(),
            precedingStopIndex = stopIndex
          })
          if displayName then
            displayNames[stopName] = displayName
          end
        else
          table.insert(missingStops, stopName)
        end
      end
    end

    if #missingWaypoints > 0 then
      log('D', 'bus', string.format("Skipped %d missing waypoints: %s", #missingWaypoints, table.concat(missingWaypoints, ", ")))
    end
    if #missingStops > 0 then
      log('W', 'bus', string.format("Warning: %d stops not found: %s", #missingStops, table.concat(missingStops, ", ")))
    end

    return triggers, items, displayNames
  end

  return {buildRouteFromConfig = buildRouteFromConfig, calculateLoanerCut = calculateLoanerCut,
    collectScenetreeObjects = collectScenetreeObjects, loadRoutesFromJSON = loadRoutesFromJSON,
    selectRandomRoute = selectRandomRoute}
end
